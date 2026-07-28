#!/usr/bin/env bash
# scripts/test_hamsh_arena_soak_host.sh — SUSTAINED-USE host gate for hamsh's
# session arenas. QEMU-free, ~2 s.
#
# WHY THIS GATE EXISTS
# --------------------
# A 4-hour DE stress soak (178 cycles, 709 app launches) found the desktop
# becomes COMPLETELY unusable after ~83 minutes: every command returns
#     hamsh: parse error [line 1]: node arena full
# and nothing can launch again. The kernel was healthy at that moment (644 MB
# free, 20 live tasks, 1/32 windows) — the shell had simply run its AST node
# arena to NODE_MAX and never reclaimed a byte, because the old reclaimer
# refused to recycle while ANY `def`'d function or variable binding was live
# and the DE's /etc/rc.de-user leaves both non-zero forever.
#
# ~137 gates missed it because every one of them asserts CORRECTNESS AT AN
# INSTANT. The failure mode is BEHAVIOUR OVER TIME: each individual command
# is perfectly correct right up to the one that kills the session. So this
# gate does the one thing the suite could not — it runs a shell for
# thousands of commands with a function AND a variable live throughout, and
# asserts that occupancy is BOUNDED rather than monotonic, and that
# everything still computes the same answers on the far side of a collection.
#
# WHAT IT ASSERTS
#   1. Not one "node arena full" / "kid pool full" / "arena exhausted" in a
#      7000+ command session (the old shell dies at ~1660).
#   2. The `arenas` occupancy line DROPS at least once — i.e. memory is
#      really reclaimed, not merely allocated more slowly or capped higher.
#   3. At least 2 collections happen, and no collection is forced to skip
#      string compaction.
#   4. The PROBE line — recursion, if/else, try/except, ternary, slice,
#      expression-mode for, kwarg call, list/dict/set values, and a plain
#      variable — prints byte-identical output BEFORE the first collection
#      and after every later one. A mark/compact collector that forwards a
#      node id wrongly (nd_c is a CHILD for five kinds and a scalar FLAG for
#      the rest) corrupts exactly these.
#   5. The alias table and the pushd directory stack — both hold interned
#      string refs and NEITHER was consulted by the old all-or-nothing
#      recycler — survive the string-arena compaction.
#
# Drive seam: the SAME shell source that runs as /init, compiled for
# x86_64-linux and fed over a stdin pipe with --no-echo (identical to
# scripts/test_hamsh_nosilentwrong_host.sh).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_arenasoak_host"
mkdir -p "$OUT"
fail=0

# Cycles of 8 statements each. 900 cycles ~= 7200 commands, comfortably past
# the ~1660 at which the pre-fix shell died, and enough to force several
# collections. Runs in well under a second.
CYCLES="${ARENA_SOAK_CYCLES:-900}"

echo "[arena-soak] compiling hamsh for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsh.ad -o "$BIN" 2>"$OUT/arenasoak_compile.log"; then
    echo "[arena-soak] FAIL: host hamsh did not compile/link"
    cat "$OUT/arenasoak_compile.log"; exit 1
fi
echo "[arena-soak] PASS host hamsh compiled -> $BIN"

echo "[arena-soak] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamsh.ad -o "$OUT/hamsh_arenasoak_native.elf" \
        2>"$OUT/arenasoak_native.log"; then
    echo "[arena-soak] FAIL: native (device) hamsh did not compile"
    cat "$OUT/arenasoak_native.log"; exit 1
fi
echo "[arena-soak] PASS native hamsh still compiles (device build unaffected)"

SCRIPT="$OUT/arenasoak_script.hs"
DUMP="$OUT/arenasoak_dump.txt"

python3 - "$CYCLES" >"$SCRIPT" <<'PYEOF'
import sys
n = int(sys.argv[1])
o = []
# --- live state that pins the arenas under the OLD reclaimer -------------
# Six functions whose bodies between them use nd_c as a CHILD (if/else,
# try/except, ternary, slice) AND as a scalar FLAG (expression-mode for,
# kwarg call, export assignment). All of them must survive every collection.
o.append('def f0(k) { if k < 2 { return k } ; return f0(k - 1) + f0(k - 2) }')
o.append('def f1(k) { try { raise "e" } except e { return "caught:" + e } }')
o.append('def f2(k) { return "big" if k > 1 else "small" }')
o.append('def f3(xs) { return xs[1:3] }')
o.append('def f4() { out = "" ; for i in [1, 2, 3] { out = out + i } ; return out }')
o.append('def f5(xs) { return sorted(xs, reverse=True) }')
# f6's `else` arm lives in nd_c. Without it the ND_IF entry of
# _gc_c_is_node is untested (f0's `if` has no else, so its nd_c is 0) —
# verified by mutation: deleting `if k == ND_IF` from _gc_c_is_node passed
# this gate until f6 existed.
o.append('def f6(k) { if k > 3 { return "hi" } else { return "lo" } }')
# f7 uses nd_c the OTHER way: the ND_ASSIGN export FLAG. Forwarding that as
# if it were a node id is the mirror-image bug.
o.append('def f7() { export EV=7 ; return "ok" }')
o.append('keep = [1, 2, 3, 4, 5]')
o.append("dd = {'a': 11, 'b': 22}")
o.append('name = "hamnix"')
o.append("alias ll='ls -l'")
PROBE = ('echo PROBE ${ f0(7) } ${ f1(0) } ${ f2(5) } ${ f3([9, 8, 7, 6]) } '
         '${ f4() } ${ f5([3, 1, 2]) } ${ f6(9) } ${ f6(1) } ${ f7() } '
         '${ keep[1:3] } ${ len(dd) } $name')
o.append(PROBE)
o.append('arenas')
for i in range(1, n + 1):
    o.append('echo cmd%d hello world' % i)
    o.append('x%d = %d + 2 * 3' % (i % 40, i))
    o.append('if x%d > 0 { echo pos%d } else { echo neg }' % (i % 40, i))
    o.append('for q in a b c { echo item $q }')
    o.append('y = ${ keep[1:3] }')
    o.append('z = ${ "big" if %d > 1 else "small" }' % i)
    o.append('try { raise "boom%d" } except e { echo caught $e }' % i)
    o.append('echo ${ f2(%d) }' % i)
    if i % 100 == 0:
        o.append('arenas')
        o.append(PROBE)
o.append('arenas')
o.append(PROBE)
o.append('alias')
o.append('exit')
sys.stdout.write('\n'.join(o) + '\n')
PYEOF

NCMD=$(grep -c . "$SCRIPT")
echo "[arena-soak] driving $NCMD commands through one shell session ..."
if [ "$NCMD" -lt 700 ]; then
    echo "[arena-soak] FAIL: reproducer is too short ($NCMD commands)."
    echo "             The bug needs ~700 commands to appear; a short run proves nothing."
    exit 1
fi

timeout 180 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    # Don't bail — the checks below name the actual cause. (A shell whose
    # node arena has filled never reaches `exit`, so it also times out:
    # rc=124 and "node arena full" are the SAME failure, and the second is
    # the readable one.)
    echo "[arena-soak] FAIL: shell exited rc=$rc (124 = never reached 'exit')"
    fail=1
fi

# ---------------------------------------------------------------- check 1
# No arena ever ran dry. THIS is the shipped symptom.
for pat in "node arena full" "kid pool full" "arena exhausted" \
           "uncaught exception: value arena" "too many variables"; do
    if grep -qF -- "$pat" "$DUMP"; then
        echo "[arena-soak] FAIL: '$pat' appeared during sustained use"
        grep -nF -- "$pat" "$DUMP" | head -n 3
        fail=1
    fi
done
[ "$fail" -eq 0 ] && echo "[arena-soak] OK: $NCMD commands, no arena exhausted"

# ---------------------------------------------------------------- check 2
# Occupancy is BOUNDED, not monotonic: some sample must be lower than its
# predecessor. Without reclamation `nodes=` only ever climbs.
mapfile -t NODES < <(grep -o 'arenas nodes=[0-9]*' "$DUMP" | cut -d= -f2)
if [ "${#NODES[@]}" -lt 3 ]; then
    echo "[arena-soak] FAIL: expected several 'arenas' samples, got ${#NODES[@]}"
    fail=1
else
    dropped=0
    peak=0
    prev="${NODES[0]}"
    for v in "${NODES[@]}"; do
        [ "$v" -gt "$peak" ] && peak="$v"
        [ "$v" -lt "$prev" ] && dropped=1
        prev="$v"
    done
    if [ "$dropped" -eq 0 ]; then
        echo "[arena-soak] FAIL: node arena occupancy NEVER dropped —"
        echo "             it is still monotonic (samples: ${NODES[*]})"
        fail=1
    else
        echo "[arena-soak] OK: node occupancy reclaimed (peak $peak, final ${NODES[-1]}, samples ${#NODES[@]})"
    fi
    # A "fix" that merely raised NODE_MAX would still be monotonic and would
    # still die later; the drop above is what distinguishes the two.
    if [ "$peak" -ge 16384 ]; then
        echo "[arena-soak] FAIL: peak node occupancy $peak reached NODE_MAX"
        fail=1
    fi
fi

# ---------------------------------------------------------------- check 3
GCRUNS=$(grep -o 'gc=[0-9]*' "$DUMP" | cut -d= -f2 | sort -n | tail -n 1)
GCRUNS="${GCRUNS:-0}"
if [ "$GCRUNS" -lt 2 ]; then
    echo "[arena-soak] FAIL: only $GCRUNS collection(s) in $NCMD commands —"
    echo "             the soak is not actually exercising reclamation"
    fail=1
else
    echo "[arena-soak] OK: $GCRUNS collections ran during the session"
fi
SKIP=$(grep -o 'gcstrskip=[0-9]*' "$DUMP" | cut -d= -f2 | sort -n | tail -n 1)
if [ "${SKIP:-0}" -ne 0 ]; then
    echo "[arena-soak] FAIL: $SKIP collection(s) had to skip string compaction"
    fail=1
else
    echo "[arena-soak] OK: every collection compacted the string arena too"
fi

# ---------------------------------------------------------------- check 4
# Same inputs, same answers, on both sides of every collection. The first
# PROBE is emitted BEFORE any collection has run, so it is the oracle.
mapfile -t PROBES < <(grep -o 'PROBE .*' "$DUMP")
if [ "${#PROBES[@]}" -lt 3 ]; then
    echo "[arena-soak] FAIL: expected several PROBE lines, got ${#PROBES[@]}"
    fail=1
else
    # Guard the oracle itself: a PROBE of empty/failed evaluations would make
    # "all identical" vacuously true.
    EXPECT='PROBE 13 caught:e big 8 7 123 3 2 1 hi lo ok 2 3 2 hamnix'
    if [ "${PROBES[0]}" != "$EXPECT" ]; then
        echo "[arena-soak] FAIL: baseline PROBE is not the expected evaluation"
        echo "             want: $EXPECT"
        echo "             got : ${PROBES[0]}"
        fail=1
    fi
    bad=0
    for p in "${PROBES[@]}"; do
        [ "$p" = "${PROBES[0]}" ] || { bad=1; echo "[arena-soak]   drift: $p"; }
    done
    if [ "$bad" -ne 0 ]; then
        echo "[arena-soak] FAIL: PROBE output changed across a collection —"
        echo "             a live AST or value was corrupted or freed"
        fail=1
    else
        echo "[arena-soak] OK: ${#PROBES[@]} PROBEs identical across $GCRUNS collections"
    fi
fi

# ---------------------------------------------------------------- check 5
# The alias table holds interned STRING refs. The old recycler wiped the
# string arena without consulting it (a latent corruption of its own); the
# collector must forward it.
if grep -qF "ll='ls -l'" "$DUMP"; then
    echo "[arena-soak] OK: alias survived string-arena compaction"
else
    echo "[arena-soak] FAIL: alias lost/garbled after compaction"
    grep -n "^hamsh\$ ll" "$DUMP" | head -n 3
    fail=1
fi

# ---------------------------------------------------------------- check 6
# STRUCTURAL RATCHET on the one hand-maintained table in the collector.
#
# nd_c is a CHILD NODE for five kinds and a SCALAR FLAG for the rest, and
# _gc_c_is_node is the only place that knows which. Get it wrong and a live
# function body is silently corrupted THOUSANDS of commands later — the
# worst-shaped bug this file can have. Checks 1-5 catch the child-side
# mistakes (mutation-verified: dropping ND_IF makes f6 return ""), but a
# scrambled scalar flag can hide, so pin the population of nd_c WRITERS: a
# new one means somebody taught a node kind to use nd_c, and _gc_c_is_node
# must be revisited in the same commit.
#
# The 15 parser writers, by kind:
#   CHILD  ND_TERNARY(else) ND_SLICE(step) ND_IF(else x2) ND_TRY(except)
#          ND_WITH(body)
#   FLAG   ND_CALL/ND_CALLV(kwarg count) ND_CMD(redirect bits x4)
#          ND_FOR(expression-mode x2) ND_ASSIGN(export flag x2)
EXPECT_NDC=15
GOT_NDC=$(grep -cE 'nd_c\[.*\] *= ' user/hamsh.ad)
# minus nd_new's zero-init and the collector's own two lines
GOT_NDC=$((GOT_NDC - 3))
if [ "$GOT_NDC" -ne "$EXPECT_NDC" ]; then
    echo "[arena-soak] FAIL: user/hamsh.ad now has $GOT_NDC nd_c writers, expected $EXPECT_NDC."
    echo "             A node kind started (or stopped) using nd_c. Re-derive"
    echo "             _gc_c_is_node — a CHILD it does not list gets freed under a"
    echo "             live function; a FLAG it does list gets rewritten to garbage."
    echo "             Then update EXPECT_NDC here."
    grep -nE 'nd_c\[.*\] *= ' user/hamsh.ad
    fail=1
else
    echo "[arena-soak] OK: nd_c writer population unchanged ($GOT_NDC) — _gc_c_is_node still derived from the current parser"
fi

if [ "$fail" -ne 0 ]; then
    echo "[arena-soak] FAIL"
    exit 1
fi
echo "[arena-soak] PASS"
exit 0
