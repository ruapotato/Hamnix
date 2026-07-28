#!/usr/bin/env bash
# scripts/test_hambrowse_matches_host.sh — FAST, QEMU-free gate for
# Element.matches(selector) + Element.closest(selector) (W3C dom-core; both were
# listed missing). Event-delegation code (e.target.closest('.item'),
# if(el.matches(sel))) is ubiquitous in modern sites/frameworks. Reuses the same
# selector machinery as querySelector (tag/class/id/[attr]/compound; descendant
# combinator degrades to the rightmost compound). Exact console.log oracle.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_matches.html"
mkdir -p "$OUT"

echo "[hb-mat] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/mat_compile.log"; then
    echo "[hb-mat] FAIL: host harness did not compile"; cat "$OUT/mat_compile.log"; exit 1
fi
echo "[hb-mat] PASS host harness compiled -> $BIN"

echo "[hb-mat] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/mat_native.log"; then
    echo "[hb-mat] FAIL: native hambrowse did not compile"; cat "$OUT/mat_native.log"; exit 1
fi
echo "[hb-mat] PASS native hambrowse still compiles"

fail=0
D0="$OUT/mat_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-mat] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-mat] PASS $2"; else echo "[hb-mat] FAIL $2 (missing: $1)"; fail=1; fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# matches()
assert_grep '^JSLOG M1 true$'   "matches('li') tag selector"
assert_grep '^JSLOG M2 true$'   "matches('.item') class selector"
assert_grep '^JSLOG M3 true$'   "matches('.active') second class"
assert_grep '^JSLOG M4 true$'   "matches('li.item.active') compound"
assert_grep '^JSLOG M5 true$'   "matches('#li1') id selector"
assert_grep '^JSLOG M6 false$'  "matches('.active') is false on the other li"
assert_grep '^JSLOG M7 true$'   "matches('[id=\"lbl\"]') attribute selector"

# closest()
assert_grep '^JSLOG C1 lbl$'    "closest('.label') matches self"
assert_grep '^JSLOG C2 li1$'    "closest('li') finds nearest ancestor li"
assert_grep '^JSLOG C3 panel$'  "closest('.panel') finds ancestor by class"
assert_grep '^JSLOG C4 app$'    "closest('#app') finds far ancestor by id"
assert_grep '^JSLOG C5 true$'   "closest('.nope') returns null on no match"

# event-delegation via closest()
assert_grep '^JSLOG DELEGATE li1$' "e.target.closest('.item') resolves the delegated item"

if [ "$fail" -ne 0 ]; then echo "[hb-mat] RESULT: FAIL"; exit 1; fi
echo "[hb-mat] RESULT: PASS"
