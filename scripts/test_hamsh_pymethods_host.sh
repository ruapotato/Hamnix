#!/usr/bin/env bash
# scripts/test_hamsh_pymethods_host.sh — FAST, QEMU-free host gate for a NEW
# slice of hamsh Python-esque method expressiveness (user/hamsh.ad):
#
#   * str.format()  — positional `{}` (auto-numbered), `{0}` (explicit index),
#     `{name}` (keyword) fields, with `{{`/`}}` brace escaping. A trailing
#     `:spec` is accepted but IGNORED (no alignment/precision yet).
#   * str.swapcase() / str.rfind(sub) / str.rsplit(sep[, maxsplit]).
#   * list.sort()  — IN PLACE, returns nil (vs the sorted() builtin which
#     returns a NEW list); honours key= and reverse=.
#   * list.reverse() — IN PLACE, returns nil (vs reversed()).
#   * list.extend(iterable) — IN PLACE append of every item; returns nil.
#   * list.remove(x) — delete the FIRST equal element IN PLACE (tolerant of
#     a missing value — no raise, matching hamsh's index()/count() convention).
#
# The mutate-vs-return distinction is the headline: sort()/reverse() return
# nil and mutate the receiver, while sorted()/reversed() leave it untouched.
#
# Sibling of scripts/test_hamsh_pystr_host.sh / test_hamsh_pyesque_host.sh: the
# SAME shell source that runs as /init on-device is compiled for x86_64-linux
# and driven DIRECTLY on the host in milliseconds — no boot, no QEMU. It also
# re-compiles the NATIVE (device) build to prove /init is byte-unaffected.
#
# NOTE: hamsh's boolean literals are lowercase `true`/`false` (Python's capital
# `True`/`False` are NOT hamsh keywords), so reverse=true is used below.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_pymethods_host"
SCRIPT="$OUT/hamsh_pymethods.hsh"
mkdir -p "$OUT"
fail=0

echo "[pymethods-host] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/pymethods_compile.log"; then
    echo "[pymethods-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/pymethods_compile.log"; exit 1
fi
echo "[pymethods-host] PASS host hamsh compiled -> $BIN"

echo "[pymethods-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_pymethods_native.elf" 2>"$OUT/pymethods_native.log"; then
    echo "[pymethods-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/pymethods_native.log"; exit 1
fi
echo "[pymethods-host] PASS native hamsh still compiles (device build unaffected)"

cat > "$SCRIPT" <<'HSH'
# --- str.format() ---------------------------------------------------
echo FMT_AUTO ${ "{} and {}".format("a", "b") }
echo FMT_IDX ${ "{1}-{0}".format("x", "y") }
echo FMT_NAME ${ "{name}={val}".format(name="k", val=7) }
echo FMT_REPEAT ${ "{0}{0}{1}".format("a", "b") }
echo FMT_ESC ${ "{{lit}} {}".format(9) }
echo FMT_SPEC ${ "[{:>5}]".format("hi") }
echo FMT_MISS ${ "x{}y".format() }
# --- str.swapcase / rfind / rsplit ----------------------------------
echo SWAP ${ swapcase("Hello World") }
echo SWAP_M ${ "AbC123".swapcase() }
echo RFIND ${ rfind("a.b.c", ".") }
echo RFIND_M ${ rfind("abc", "z") }
echo RFIND_E ${ rfind("abc", "") }
echo RSPLIT2 ${ join(rsplit("a.b.c.d", ".", 2), "|") }
echo RSPLIT0 ${ join(rsplit("a.b.c", ".", 0), "|") }
echo RSPLIT_ALL ${ join(rsplit("a b c", " "), "|") }
echo RSPLIT_M ${ join("w-x-y-z".rsplit("-", 1), "|") }
# --- list.sort() IN PLACE (returns nil) vs sorted() (returns new) ---
nums = [3, 1, 2]
snew = ${ sorted(nums) }
echo SORTED_NEW ${ join(snew, ",") }
echo SORTED_ORIG ${ join(nums, ",") }
ret = ${ nums.sort() }
echo SORT_INPLACE ${ join(nums, ",") }
echo SORT_RETNIL nil=${ ret }end
nums.sort(reverse=true)
echo SORT_REV ${ join(nums, ",") }
words = ["bb", "a", "ccc"]
words.sort(key=len)
echo SORT_KEY ${ join(words, ",") }
words.sort(key=len, reverse=true)
echo SORT_KEYREV ${ join(words, ",") }
mt = []
mt.sort()
echo SORT_EMPTY_LEN ${ len(mt) }
# aliasing: in-place sort shows through a second name (reference semantics)
al = [3, 1, 2]
alias = al
al.sort()
echo SORT_ALIAS ${ join(alias, ",") }
# --- list.reverse() IN PLACE (returns nil) vs reversed() ------------
rl = [1, 2, 3]
rnew = ${ reversed(rl) }
echo REVERSED_NEW ${ join(rnew, ",") }
echo REVERSED_ORIG ${ join(rl, ",") }
rl.reverse()
echo REV_INPLACE ${ join(rl, ",") }
# --- list.extend() IN PLACE ----------------------------------------
ex = [1, 2]
ex.extend([3, 4])
echo EXTEND ${ join(ex, ",") }
selfx = [1, 2]
selfx.extend(selfx)
echo EXTEND_SELF ${ join(selfx, ",") }
strx = [65, 66]
strx.extend("cd")
echo EXTEND_STR ${ len(strx) }
# --- list.remove() IN PLACE (first match; tolerant of missing) -----
rm = [5, 6, 7, 6]
rm.remove(6)
echo REMOVE_FIRST ${ join(rm, ",") }
rm.remove(99)
echo REMOVE_MISS ${ join(rm, ",") }
exit
HSH

DUMP="$OUT/pymethods_dump.txt"
timeout 30 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>"$OUT/pymethods_stderr.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[pymethods-host] FAIL: host shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[pymethods-host] --- shell stdout ---"
cat "$DUMP"
echo "[pymethods-host] --- end output ---"

check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[pymethods-host] OK: $2"
    else
        echo "[pymethods-host] WRONG (want '$1'): $2"; fail=1
    fi
}

# str.format()
check "FMT_AUTO a and b"        "format auto-numbered {} {}"
check "FMT_IDX y-x"             "format explicit {1}-{0} reorders"
check "FMT_NAME k=7"            "format {name} keyword fields"
check "FMT_REPEAT aab"          "format repeats an explicit index {0}{0}{1}"
check "FMT_ESC {lit} 9"         "format {{ }} escape to literal braces"
check "FMT_SPEC [hi]"           "format :spec accepted-but-ignored (no pad)"
check "FMT_MISS xy"             "format with a missing field renders empty"
# str methods
check "SWAP hELLO wORLD"        "swapcase inverts each letter"
check "SWAP_M aBc123"           "swapcase method form"
check "RFIND 3"                 "rfind returns LAST occurrence index"
check "RFIND_M -1"              "rfind miss -> -1"
check "RFIND_E 3"               "rfind('') -> len(s)"
check "RSPLIT2 a.b|c|d"         "rsplit maxsplit=2 counts from the right"
check "RSPLIT0 a.b.c"           "rsplit maxsplit=0 -> no splits"
check "RSPLIT_ALL a|b|c"        "rsplit default (unlimited) == split"
check "RSPLIT_M w-x-y|z"        "rsplit method form, maxsplit=1"
# list.sort() vs sorted()
check "SORTED_NEW 1,2,3"        "sorted() returns a NEW sorted list"
check "SORTED_ORIG 3,1,2"       "sorted() leaves the original UNTOUCHED"
check "SORT_INPLACE 1,2,3"      "list.sort() mutates IN PLACE"
check "SORT_RETNIL nil=end"     "list.sort() returns nil (empty render)"
check "SORT_REV 3,2,1"          "list.sort(reverse=true)"
check "SORT_KEY a,bb,ccc"       "list.sort(key=len)"
check "SORT_KEYREV ccc,bb,a"    "list.sort(key=len, reverse=true)"
check "SORT_EMPTY_LEN 0"        "empty list sort is a no-op (list stays empty)"
check "SORT_ALIAS 1,2,3"        "in-place sort visible through an alias"
# list.reverse() vs reversed()
check "REVERSED_NEW 3,2,1"      "reversed() returns a NEW reversed list"
check "REVERSED_ORIG 1,2,3"     "reversed() leaves the original UNTOUCHED"
check "REV_INPLACE 3,2,1"       "list.reverse() mutates IN PLACE"
# list.extend()
check "EXTEND 1,2,3,4"          "list.extend appends every item"
check "EXTEND_SELF 1,2,1,2"     "self-extend uses pre-extension contents"
check "EXTEND_STR 4"            "extend iterates a string's chars (2+2=4)"
# list.remove()
check "REMOVE_FIRST 5,7,6"      "list.remove deletes the FIRST match only"
check "REMOVE_MISS 5,7,6"       "list.remove of a missing value is a no-op"

if [ "$fail" -ne 0 ]; then
    echo "[pymethods-host] FAIL"
    exit 1
fi
echo "[pymethods-host] PASS"
