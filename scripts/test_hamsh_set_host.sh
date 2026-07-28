#!/usr/bin/env bash
# scripts/test_hamsh_set_host.sh — FAST, QEMU-free host gate for the hamsh
# Python-style `set` type (user/hamsh.ad, §Set): set()/{…} construction with
# dedup, membership (`x in s` / `x not in s`), the |/&/- algebra (union /
# intersection / difference), len(s), add/discard/remove mutation, iteration
# (`for x in s`), set comprehensions, and issubset/issuperset.
#
# Sibling of scripts/test_hamsh_pyesque_host.sh: the SAME shell source that runs
# as /init on-device is compiled for the `x86_64-linux` Adder target and driven
# DIRECTLY on the host in milliseconds — no boot, no QEMU. It also re-compiles
# the NATIVE shell for x86_64-adder-user to prove the byte-identical /init
# (device) build is unaffected.
#
# We drive the shell over a stdin PIPE with `--no-echo`, exactly as the pyesque
# host gate does: every marker below is produced by the tree-walking evaluator.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_set_host"
SCRIPT="$OUT/hamsh_set.hsh"
mkdir -p "$OUT"
fail=0

echo "[set-host] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/set_compile.log"; then
    echo "[set-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/set_compile.log"; exit 1
fi
echo "[set-host] PASS host hamsh compiled -> $BIN"

echo "[set-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_set_native.elf" 2>"$OUT/set_native.log"; then
    echo "[set-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/set_native.log"; exit 1
fi
echo "[set-host] PASS native hamsh still compiles (device build unaffected)"

cat > "$SCRIPT" <<'HSH'
s = set([1, 2, 2, 3])
echo SET_LEN ${ len(s) }
echo IN_YES ${ 2 in s }
echo IN_NO ${ 9 in s }
echo NOTIN ${ 5 not in s }
echo DEDUP ${ len(set([1, 1, 1, 1])) }
echo EMPTY ${ len(set()) }
u = {1, 2} | {2, 3}
echo UNION ${ join(sorted(u), ",") }
i = {1, 2, 3} & {2, 3, 4}
echo INTER ${ join(sorted(i), ",") }
d = {1, 2, 3} - {2}
echo DIFF ${ join(sorted(d), ",") }
echo RENDER ${ {1, 2, 3} }
s.add(5)
echo ADD ${ join(sorted(s), ",") }
s.add(2)
echo ADD_DUP ${ join(sorted(s), ",") }
s.discard(1)
echo DISCARD ${ join(sorted(s), ",") }
s.remove(3)
echo REMOVE ${ join(sorted(s), ",") }
s.discard(999)
echo DISCARD_ABSENT ${ join(sorted(s), ",") }
tot = 0
for x in {10, 20, 30} { tot = tot + x }
echo ITER_LIT $tot
cnt = 0
for y in set([4, 4, 5, 6]) { cnt = cnt + 1 }
echo ITER_SET $cnt
sq = {n * n for n in [1, 2, 3, 2, 1]}
echo SETCOMP ${ join(sorted(sq), ",") }
echo SUBSET_Y ${ issubset({1, 2}, {1, 2, 3}) }
echo SUBSET_N ${ issubset({1, 4}, {1, 2, 3}) }
echo SUPERSET_Y ${ issuperset({1, 2, 3}, {1, 2}) }
echo UNION_METHOD ${ join(sorted(union({1, 2}, [3, 4])), ",") }
echo EQ_Y ${ {1, 2} == {2, 1} }
echo EQ_N ${ {1, 2} == {1, 2, 3} }
echo NE_Y ${ {1, 2} != {3, 4} }
echo NE_N ${ {1, 2, 3} != {3, 2, 1} }
echo EQ_EMPTY ${ set() == set() }
echo SYMDIFF ${ join(sorted({1, 2, 3} ^ {2, 3, 4}), ",") }
echo SYMDIFF_METHOD ${ join(sorted(symmetric_difference({1, 2}, [2, 3])), ",") }
echo XOR_PREC ${ join(sorted({1, 2} ^ {2, 3} & {3, 9}), ",") }
fs = frozenset([1, 2, 2, 3])
echo FROZEN_LEN ${ len(fs) }
echo "FROZEN_RENDER ${ fs }"
echo "FROZEN_EMPTY ${ frozenset() }"
echo FROZEN_IN ${ 2 in fs }
echo FROZEN_EQ ${ frozenset([1, 2]) == {1, 2} }
echo FROZEN_ALG ${ join(sorted(fs | {4}), ",") }
fs.add(99)
echo FROZEN_IMMUT ${ len(fs) }
m = {1, 2}
m.update([3, 4, 2])
echo UPDATE ${ join(sorted(m), ",") }
c = m.copy()
c.add(7)
echo COPY_INDEP ${ join(sorted(m), ",") }
m.clear()
echo CLEAR ${ len(m) }
w = {7, 8, 9}
wt = 0
for z in w { wt = wt + z }
echo ITER_BAREVAR $wt
exit
HSH

DUMP="$OUT/set_dump.txt"
timeout 30 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>"$OUT/set_stderr.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[set-host] FAIL: host shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[set-host] --- shell stdout ---"
cat "$DUMP"
echo "[set-host] --- end output ---"

check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[set-host] OK: $2"
    else
        echo "[set-host] WRONG (want '$1'): $2"; fail=1
    fi
}

check "SET_LEN 3"          "set([1,2,2,3]) dedups to length 3"
check "IN_YES true"        "2 in s"
check "IN_NO false"        "9 not a member"
check "NOTIN true"         "5 not in s"
check "DEDUP 1"            "set([1,1,1,1]) collapses to one element"
check "EMPTY 0"            "set() is an empty set"
check "UNION 1,2,3"        "{1,2} | {2,3} == {1,2,3}"
check "INTER 2,3"          "{1,2,3} & {2,3,4} == {2,3}"
check "DIFF 1,3"           "{1,2,3} - {2} == {1,3}"
check "RENDER {1, 2, 3}"   "a set renders Python-style"
check "ADD 1,2,3,5"        "s.add(5) inserts"
check "ADD_DUP 1,2,3,5"    "s.add(2) is a no-op on a present member"
check "DISCARD 2,3,5"      "s.discard(1) removes"
check "REMOVE 2,5"         "s.remove(3) removes"
check "DISCARD_ABSENT 2,5" "s.discard(999) is a no-op when absent"
check "ITER_LIT 60"        "for x in {10,20,30} sums 60"
check "ITER_SET 3"         "for y in set([4,4,5,6]) runs 3 times (deduped)"
check "SETCOMP 1,4,9"      "{n*n for n in [1,2,3,2,1]} == {1,4,9}"
check "SUBSET_Y true"      "{1,2}.issubset({1,2,3})"
check "SUBSET_N false"     "{1,4} is not a subset of {1,2,3}"
check "SUPERSET_Y true"    "{1,2,3}.issuperset({1,2})"
check "UNION_METHOD 1,2,3,4" "union(set, list) accepts any iterable"
check "EQ_Y true"          "{1,2} == {2,1} order-independent"
check "EQ_N false"         "{1,2} == {1,2,3} differs on cardinality"
check "NE_Y true"          "{1,2} != {3,4}"
check "NE_N false"         "{1,2,3} != {3,2,1} is false (equal)"
check "EQ_EMPTY true"      "set() == set()"
check "SYMDIFF 1,4"        "{1,2,3} ^ {2,3,4} == {1,4}"
check "SYMDIFF_METHOD 1,3" "symmetric_difference({1,2},[2,3]) == {1,3}"
check "XOR_PREC 1,2"       "^ binds looser than & : {1,2} ^ ({2,3}&{3,9}) == {1,2}"
check "FROZEN_LEN 3"       "frozenset([1,2,2,3]) dedups to 3"
check "FROZEN_RENDER frozenset({1, 2, 3})" "frozenset renders wrapped"
check "FROZEN_EMPTY frozenset()" "empty frozenset renders frozenset()"
check "FROZEN_IN true"     "membership on a frozenset"
check "FROZEN_EQ true"     "frozenset([1,2]) == {1,2} (cross-type equality)"
check "FROZEN_ALG 1,2,3,4" "frozenset | set algebra works"
check "FROZEN_IMMUT 3"     "fs.add(99) is a no-op on a frozenset"
check "UPDATE 1,2,3,4"     "m.update([3,4,2]) adds in place, deduped"
check "COPY_INDEP 1,2,3,4" "c = m.copy(); c.add(7) leaves m unchanged"
check "CLEAR 0"            "m.clear() empties in place"
check "ITER_BAREVAR 24"    "for z in w (bare set var) iterates typed elements, sum 24"

if [ "$fail" -ne 0 ]; then
    echo "[set-host] FAIL"
    exit 1
fi
echo "[set-host] PASS"
