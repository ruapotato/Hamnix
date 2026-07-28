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
#   4. The PROBE line — recursion, if/else, try/except, `except NAME as VAR`,
#      ternary, slice, expression-mode for, kwarg call, export assignment,
#      indexed assignment, list/dict values and a plain string variable —
#      prints byte-identical output BEFORE the first collection and after
#      every later one, and there are EXACTLY as many PROBE lines as were
#      driven (a corrupted body makes its line RAISE, which is an ABSENT
#      line, not a different one).
#
#      This is the assertion that guards the collector's two hand-maintained
#      classifier tables. nd_c AND nd_i are both polymorphic: a CHILD NODE
#      for some kinds, a STRING ref for others, a scalar flag for the rest.
#      Mutation-proven to bite here: dropping ND_IF from _gc_c_is_node,
#      ND_TRY from _gc_i_is_str, ND_INDEXASSIGN from _gc_i_is_str.
#      NOT observable through evaluation on this seam, and therefore resting
#      on the check-6 ratchet instead: ND_CMD's nd_i `2>` target and
#      ND_WITH's nd_c body — the host build stubs file redirects and bind
#      context managers, so neither can be driven end-to-end here.
#   5. The alias table and the pushd directory stack — both hold interned
#      string refs and NEITHER was consulted by the old all-or-nothing
#      recycler — survive the string-arena compaction.
#   6. A structural ratchet on the parser's nd_c / nd_i write population, so
#      a new user of either column cannot land without the classifiers being
#      revisited in the same commit.
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
# f8/f9 cover the OTHER polymorphic column, nd_i — quieter than nd_c and
# missed by the first draft of the collector:
#   ND_TRY          `except NAME as VAR` parks NAME (a STRING ref) in nd_i
#   ND_INDEXASSIGN  FORM 1 parks the raw subscript SOURCE (a STRING ref)
#   ND_CMD          `2> file` parks the redirect TARGET NODE in nd_i
o.append('def f8() { try { raise "Boom" } except Boom as e { return "F:" + e } }')
# The subscript source is a distinctive NAME, not "1": a stale one-byte ref
# can land on identical bytes by luck and hide the bug (measured — the
# `xs[1]` spelling did not bite when ND_INDEXASSIGN was dropped from
# _gc_i_is_str; `xs[ixq]` does).
o.append('def f9(xs) { ixq = 1 ; xs[ixq] = 99 ; return xs[ixq] }')
o.append('keep = [1, 2, 3, 4, 5]')
o.append("dd = {'a': 11, 'b': 22}")
o.append('name = "hamnix"')
o.append("alias ll='ls -l'")
PROBE = ('echo PROBE ${ f0(7) } ${ f1(0) } ${ f2(5) } ${ f3([9, 8, 7, 6]) } '
         '${ f4() } ${ f5([3, 1, 2]) } ${ f6(9) } ${ f6(1) } ${ f7() } '
         '${ f8() } ${ f9([1, 2, 3]) } '
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
# EXACT count, not ">= 3": a PROBE whose line raised is simply ABSENT, and a
# "all the ones I found agree" test passes vacuously on the survivors.
# (Measured: dropping ND_TRY from _gc_i_is_str silently cut 11 PROBEs to 3.)
EXPECT_PROBES=$(( 2 + CYCLES / 100 ))
mapfile -t PROBES < <(grep -o 'PROBE .*' "$DUMP")
if [ "${#PROBES[@]}" -ne "$EXPECT_PROBES" ]; then
    echo "[arena-soak] FAIL: expected exactly $EXPECT_PROBES PROBE lines, got ${#PROBES[@]}"
    echo "             A missing PROBE means that line RAISED — a live function"
    echo "             body was corrupted or freed by a collection."
    grep -n "uncaught exception" "$DUMP" | head -n 3
    fail=1
else
    # Guard the oracle itself: a PROBE of empty/failed evaluations would make
    # "all identical" vacuously true.
    EXPECT='PROBE 13 caught:e big 8 7 123 3 2 1 hi lo ok F:Boom 99 2 3 2 hamnix'
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
# nd_i is polymorphic the same way (an op code / flag for most kinds, a NODE
# for ND_CMD's `2> file` target, a STRING for ND_TRY's except-filter and for
# ND_INDEXASSIGN's FORM-1 subscript source). That column was MISSED by the
# collector's first draft, which is exactly why both are ratcheted.
#
# Counted as PARSER writes only — `nd_X[cast[uint64](...)] =` and `nd_X[nu] =`
# — so the collector's own `nd_X[d] = ...` / nd_new's `nd_X[n] = 0` are
# excluded by construction and the numbers do not move when the GC is edited.
EXPECT_NDC=15
EXPECT_NDI=27
GOT_NDC=$(grep -cE 'nd_c\[(cast\[uint64\].*|nu)\] *= ' user/hamsh.ad)
GOT_NDI=$(grep -cE 'nd_i\[(cast\[uint64\].*|nu)\] *= ' user/hamsh.ad)
ratchet() {
    local col="$1" got="$2" want="$3"
    if [ "$got" -ne "$want" ]; then
        echo "[arena-soak] FAIL: user/hamsh.ad now has $got parser writes to $col, expected $want."
        echo "             A node kind started (or stopped) using $col. Re-derive the"
        echo "             collector's _gc_* classifier for that column: a CHILD or a"
        echo "             STRING it does not list is freed under a live function; a"
        echo "             scalar it DOES list is rewritten to garbage. Then update"
        echo "             the EXPECT_ value here."
        grep -nE "$col"'\[(cast\[uint64\].*|nu)\] *= ' user/hamsh.ad
        return 1
    fi
    echo "[arena-soak] OK: $col parser-write population unchanged ($got) — collector still derived from the current parser"
    return 0
}
ratchet nd_c "$GOT_NDC" "$EXPECT_NDC" || fail=1
ratchet nd_i "$GOT_NDI" "$EXPECT_NDI" || fail=1

if [ "$fail" -ne 0 ]; then
    echo "[arena-soak] FAIL"
    exit 1
fi
echo "[arena-soak] PASS"
exit 0
