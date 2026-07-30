#!/usr/bin/env bash
# scripts/test_hamsh_percmd_floor_host.sh — PER-COMMAND leak gate for hamsh.
# QEMU-free host gate.
#
# WHY THIS GATE EXISTS
# --------------------
# Leak pass 16 retired every kernel COW share path on counted quantities
# (owner-dead = 0, owner-stray = 0, catch-all arm empty) and handed over one
# residue: ~2.4 frames per terminal cycle whose every survivor is mapped by a
# LIVE owner. Its conclusion was that the remaining growth is memory a
# USERLAND process holds, and that the next pass belongs in hamsh.
#
# hamsh already has a mark/compact arena collector (gc_collect), added when a
# 4-hour soak traced an 83-minute desktop death to its AST arena. So the
# question this gate answers is the sharper one: WHAT DOES THAT COLLECTOR NOT
# REACH, per command?
#
# WHY A "FLOOR" AND NOT AN OCCUPANCY SAMPLE
# -----------------------------------------
# scripts/test_hamsh_arena_soak_host.sh asserts occupancy is BOUNDED — that
# the `arenas` line drops at least once. That is the right assertion for "does
# the shell die at 1660 commands", and it is not sufficient here: occupancy is
# a SAWTOOTH (allocate until _maybe_recycle_arenas trips, collect, repeat), so
# any single sample says nothing about whether the sawtooth's BASELINE is
# creeping. A shell that stranded one node per command would still show the
# line dropping, on every collection, forever, while dying a little later each
# time.
#
# The FLOOR — occupancy IMMEDIATELY AFTER a collection — is the quantity that
# separates "allocating" from "leaking", because anything the mark phase
# cannot reach is exactly what survives a collection. `arenas gc` (added with
# this gate) forces a collection and then prints, so the floor is samplable on
# demand instead of only where the sawtooth happens to land.
#
# WHAT IS ASSERTED, AND WHY IT IS AN INTER-SWEEP DELTA
# ---------------------------------------------------
# Two IDENTICAL sweeps of the same 16 command classes, floor sampled after
# each class in each sweep. The assertion is that the floor after sweep 2 is
# BYTE-IDENTICAL to the floor after sweep 1.
#
# It is deliberately NOT "the floor is zero" and NOT a before/after mean:
#   * A floor of zero is the WRONG assertion — sweep 1 legitimately creates
#     live bindings (`c`, `LL`, `DD`, a `def`, an alias). Those are reachable
#     state a user asked for; a collector that dropped them would be a bug.
#     Sweep 2 REBINDS the same names, so anything the collector cannot reach
#     shows up as a non-zero DELTA while everything legitimate cancels.
#   * A soak mean is worthless here: two byte-identical builds of this system
#     differ by ~6.4 pg/cycle. Every number below is a COUNT read out of the
#     shell's own tally, and the comparison is exact equality.
#
# THE POSITIVE CONTROL IS NOT OPTIONAL
# ------------------------------------
# An equality assertion over an instrument that reports constants passes
# vacuously. Pass 16 nearly published two false exonerations for exactly that
# reason. So sweep 3 binds ONE genuinely new name and the gate REQUIRES the
# floor to MOVE. If the plant does not move the floor, the instrument is blind
# and the gate FAILS — a green from a blind instrument is worse than a red.
#
# It also pins two SILENT CAPS closed (both fixed 2026-07-30), because a cap
# that silently stops working is the same class of uptime killer as a leak and
# is harder to notice:
#   * `def` truncated function names at 15 bytes with no error while every
#     lookup compared the FULL name — so a long-named def reported SUCCESS and
#     the call later raised "was its `def` ever run?", AND redefinition took a
#     fresh registry slot every time (a silent cap feeding the hard FN_MAX
#     one). Measured before the fix: DEFOK 0, call raises, fns=2 for one name.
#   * `alias` truncated names at 127 bytes and then LISTED the truncated name,
#     so even reading the table did not reveal the mis-binding.
#
# Drive seam: the SAME shell source that runs as /init, compiled for
# x86_64-linux and fed over a stdin pipe with --no-echo.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_percmdfloor_host"
mkdir -p "$OUT"
fail=0

echo "[percmd-floor] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/percmdfloor_compile.log"; then
    echo "[percmd-floor] FAIL: host hamsh did not compile/link"
    cat "$OUT/percmdfloor_compile.log"; exit 1
fi
echo "[percmd-floor] PASS host hamsh compiled -> $BIN"

SCRIPT="$OUT/percmdfloor_script.hs"
DUMP="$OUT/percmdfloor_dump.txt"

python3 - >"$SCRIPT" <<'PYEOF'
# 16 command classes. Every one either allocates nodes/values/strings or
# touches a session table that gc_collect has to walk (scope, alias, dir
# stack, element pool, function registry). REPS is small on purpose: the
# assertion is an inter-sweep DELTA, not a rate, so 8 repetitions is as
# conclusive as 8000 and the gate stays a host gate.
REPS = 5
CLASSES = [
 ('echo',       lambda i: 'echo cmd%d hello' % i),
 ('assign',     lambda i: 'x = %d + 2 * 3' % i),
 ('strcat',     lambda i: 's = "a%d" + "b"' % i),
 ('list',       lambda i: 'L = [1,2,%d]' % i),
 ('dict',       lambda i: "D = {'k%d': %d}" % (i, i)),
 ('ifelse',     lambda i: 'if %d > 0 { echo p%d } else { echo n }' % (i, i)),
 ('forloop',    lambda i: 'for q in a b c { echo it$q }'),
 ('tryexcept',  lambda i: 'try { raise "b%d" } except e { echo c$e }' % i),
 ('call',       lambda i: 'r = ${ g0(%d) }' % i),
 ('aliascycle', lambda i: "alias a%d='ls -l' ; unalias a%d" % (i, i)),
 ('pushdpopd',  lambda i: 'pushd /tmp ; popd'),
 ('nestcap',    lambda i: 'c = $(echo $(echo n%d))' % i),
 ('listappend', lambda i: 'LL = [] ; LL.append(%d)' % i),
 ('slice',      lambda i: 'q = [1,2,3,4][1:3]'),
 ('cond',       lambda i: 'w = "b" if %d > 1 else "s"' % i),
 ('cmdsub',     lambda i: 'echo pre $(echo mid) post'),
]

o = []
# One live def + one live variable held across EVERY collection, so the
# collector is never running against an empty root set (the shape the old
# all-or-nothing recycler refused to collect at all).
o.append('def g0(k) { return k + 1 }')
o.append('keepv = [1, 2, 3]')

def sweep(tag):
    for name, f in CLASSES:
        for i in range(REPS):
            o.append(f(i))
        o.append('echo ==FLOOR %s %s' % (tag, name))
        o.append('arenas gc')

sweep('S1')
sweep('S2')
# A THIRD sweep so the per-class check has two STEADY-STATE sweeps to compare.
# S1 cannot be compared class-by-class against S2: mid-sweep, S1 is still
# creating each class's binding for the first time, so its intermediate floors
# legitimately differ. By S2 every name exists, so S2 and S3 must agree at
# EVERY class — which is what turns a whole-sweep equality into a per-class
# attribution when it ever goes red.
sweep('S3')
# POSITIVE CONTROL: one genuinely new, genuinely reachable binding. The floor
# MUST move. If it does not, the readout is not measuring what it claims.
o.append('plantvar = "control"')
o.append('echo ==FLOOR PLANT plant')
o.append('arenas gc')

# --- silent-cap probes ---------------------------------------------------
LONGNAME = 'fn_' + 'x' * 22          # 25 chars: fits FN_NAME_MAX=64, did NOT fit 16
o.append('def %s(k) { return k + 10 }' % LONGNAME)
o.append('echo ==LONGDEF st=$status')
o.append('lr = ${ %s(5) }' % LONGNAME)
o.append('echo ==LONGCALL lr=$lr st=$status')
o.append('def %s(k) { return k + 20 }' % LONGNAME)
o.append('lr = ${ %s(5) }' % LONGNAME)
o.append('echo ==LONGREDEF lr=$lr')
o.append('echo ==FLOOR CAPS longdef')
o.append('arenas gc')
o.append('def %s(k) { return k }' % ('z' * 70))
o.append('echo ==OVERDEF st=$status')
o.append("alias %s='ls -l'" % ('a' * 200))
o.append('echo ==OVERALIAS st=$status')
o.append("alias okalias='ls -l'")
o.append('echo ==OKALIAS st=$status')
o.append('echo ==FLOOR CAPS after')
o.append('arenas gc')
# EXPLICIT `exit`, and it is load-bearing for the gate's RUNTIME. On the
# device, sys_read_nb reports 0 = would-block and -1 = EOF (devfd.ad), so the
# REPL exits cleanly at end-of-input. The x86_64-linux shim cannot make that
# distinction for a redirected regular file — a read at EOF returns 0, which
# the editor loop reads as "stdin idle", so the host shell yields forever and
# only the harness timeout ends it. Without this line the gate always burns
# its full driver timeout instead of finishing in a couple of minutes.
o.append('exit')
print('\n'.join(o))
PYEOF

echo "[percmd-floor] driving $(grep -c . "$SCRIPT") statements ..."
timeout 900 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>&1
rc=$?
if [ $rc -ne 0 ] && [ $rc -ne 143 ]; then
    # 143 = the shell was still draining stdin when the pipe closed; the
    # transcript is complete either way and the checks below prove it.
    echo "[percmd-floor] NOTE: driver exited rc=$rc"
fi

# ---- parse: pair every ==FLOOR label with the `arenas` line that follows --
python3 - "$DUMP" >"$OUT/percmdfloor_pairs.txt" <<'PYEOF'
import re, sys
txt = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
toks = re.findall(r'==FLOOR (\S+) (\S+)|arenas (nodes=\S+ .*)', txt)
lbl = None
for a, b, c in toks:
    if a:
        lbl = (a, b)
    elif lbl is not None:
        d = dict(re.findall(r'([a-z]+)=(\d+)', c.replace('/', ' /')))
        keys = ('nodes', 'kids', 'vals', 'elems', 'str', 'scope', 'fns', 'aliases')
        print('%s %s %s' % (lbl[0], lbl[1],
                            ' '.join('%s=%s' % (k, d.get(k, 'NA')) for k in keys)))
        lbl = None
PYEOF

PAIRS="$OUT/percmdfloor_pairs.txt"

# --- check 0: the instrument produced the samples it was asked for --------
n1=$(grep -c '^S1 ' "$PAIRS")
n2=$(grep -c '^S2 ' "$PAIRS")
n3=$(grep -c '^S3 ' "$PAIRS")
if [ "$n1" -ne 16 ] || [ "$n2" -ne 16 ] || [ "$n3" -ne 16 ]; then
    echo "[percmd-floor] FAIL check0: expected 16 floors per sweep, got S1=$n1 S2=$n2 S3=$n3"
    echo "               (an ABSENT sample is a raised command, not a clean run)"
    fail=1
else
    echo "[percmd-floor] PASS check0: 16 + 16 + 16 floor samples present"
fi

# --- check 1: THE ASSERTION — zero inter-sweep floor delta ----------------
f1=$(grep '^S1 cmdsub ' "$PAIRS" | sed 's/^S1 cmdsub //')
f2=$(grep '^S2 cmdsub ' "$PAIRS" | sed 's/^S2 cmdsub //')
f3=$(grep '^S3 cmdsub ' "$PAIRS" | sed 's/^S3 cmdsub //')
if [ -z "$f1" ] || [ -z "$f2" ] || [ -z "$f3" ]; then
    echo "[percmd-floor] FAIL check1: end-of-sweep floor missing"
    fail=1
elif [ "$f1" != "$f2" ] || [ "$f2" != "$f3" ]; then
    echo "[percmd-floor] FAIL check1: hamsh strands session state PER COMMAND"
    echo "               after sweep 1: $f1"
    echo "               after sweep 2: $f2"
    echo "               after sweep 3: $f3"
    echo "               Identical sweeps must leave an identical post-GC"
    echo "               floor. A difference is state gc_collect cannot reach."
    fail=1
else
    echo "[percmd-floor] PASS check1: post-GC floor identical across three identical sweeps"
    echo "               floor: $f1"
fi

# --- check 1b: per-class, so a report NAMES the class that leaked ---------
# S2 vs S3 only (see the sweep('S3') note): both are steady state, so any
# disagreement at a class is that class stranding something.
bad=""
while read -r cls; do
    a=$(grep "^S2 $cls " "$PAIRS" | sed "s/^S2 $cls //")
    b=$(grep "^S3 $cls " "$PAIRS" | sed "s/^S3 $cls //")
    if [ -n "$a" ] && [ "$a" != "$b" ]; then bad="$bad $cls"; fi
done < <(grep '^S2 ' "$PAIRS" | awk '{print $2}')
if [ -n "$bad" ]; then
    echo "[percmd-floor] FAIL check1b: classes with a non-zero inter-sweep delta:$bad"
    fail=1
else
    echo "[percmd-floor] PASS check1b: no command class moves the floor on repeat"
fi

# --- check 2: POSITIVE CONTROL — a real new binding MUST move the floor ---
fp=$(grep '^PLANT plant ' "$PAIRS" | sed 's/^PLANT plant //')
if [ -z "$fp" ]; then
    echo "[percmd-floor] FAIL check2: positive control sample missing"
    fail=1
elif [ "$fp" = "$f3" ]; then
    echo "[percmd-floor] FAIL check2: the planted live binding did NOT move the floor."
    echo "               The readout is BLIND — check1's equality is vacuous and"
    echo "               its green means nothing."
    fail=1
else
    echo "[percmd-floor] PASS check2: positive control moved the floor ($fp)"
fi

# --- check 3: SILENT CAP — long `def` name works and does not burn slots --
if grep -q '==LONGDEF st=0' "$DUMP" && grep -q '==LONGCALL lr=15 st=0' "$DUMP" \
        && grep -q '==LONGREDEF lr=25' "$DUMP"; then
    echo "[percmd-floor] PASS check3: 25-char def registers, calls, and REDEFINES"
else
    echo "[percmd-floor] FAIL check3: long function name is still mis-registered"
    grep -a '==LONGDEF\|==LONGCALL\|==LONGREDEF' "$DUMP"
    fail=1
fi
# ...and redefinition must not consume a second registry slot. Exactly two
# functions exist at this point: g0 and the long-named one.
capfns=$(grep '^CAPS longdef ' "$PAIRS" | tr ' ' '\n' | grep '^fns=')
if [ "$capfns" = "fns=2" ]; then
    echo "[percmd-floor] PASS check3b: redefinition reuses its slot ($capfns)"
else
    echo "[percmd-floor] FAIL check3b: expected fns=2 after one g0 + one redefined"
    echo "               long-named function, got '$capfns' — a silent registry burn"
    fail=1
fi

# --- check 4: a name that STILL does not fit must be REFUSED, not truncated
if grep -q '==OVERDEF st=1' "$DUMP" \
        && grep -qa 'function name too long' "$DUMP"; then
    echo "[percmd-floor] PASS check4: over-long def refused, loudly, with status 1"
else
    echo "[percmd-floor] FAIL check4: over-long def did not report failure"
    grep -a '==OVERDEF' "$DUMP"
    fail=1
fi
if grep -q '==OVERALIAS st=1' "$DUMP" && grep -qa 'alias: name too long' "$DUMP" \
        && grep -q '==OKALIAS st=0' "$DUMP"; then
    echo "[percmd-floor] PASS check5: over-long alias refused; normal alias still binds"
else
    echo "[percmd-floor] FAIL check5: over-long alias name is still silently truncated"
    grep -a '==OVERALIAS\|==OKALIAS' "$DUMP"
    fail=1
fi
# The refused def/alias must not have landed in either table.
after=$(grep '^CAPS after ' "$PAIRS" | sed 's/^CAPS after //')
a_fns=$(echo "$after" | tr ' ' '\n' | grep '^fns=')
a_al=$(echo "$after" | tr ' ' '\n' | grep '^aliases=')
if [ "$a_fns" = "fns=2" ] && [ "$a_al" = "aliases=1" ]; then
    echo "[percmd-floor] PASS check6: refused bindings consumed no table slot"
else
    echo "[percmd-floor] FAIL check6: expected fns=2 aliases=1, got '$a_fns' '$a_al'"
    fail=1
fi

if [ $fail -eq 0 ]; then
    echo "[percmd-floor] PASS -- hamsh strands no session state per command"
    exit 0
fi
echo "[percmd-floor] FAIL"
exit 1
