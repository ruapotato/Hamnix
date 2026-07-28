#!/usr/bin/env bash
# scripts/test_hambrowse_contains_host.sh — FAST, QEMU-free gate for
# Node.contains(other) (W3C DOM). Returns true iff `other` is the node itself or
# a descendant; false for an ancestor, a sibling, or a null/non-element arg.
# Ubiquitous in click-outside / focus-trap / event-delegation code. Resolved
# over the structural tx tree. Exact console.log oracle; builds host + native.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"; BIN="$OUT/hambrowse_host"; FIX="tests/fixtures/hambrowse_contains.html"
mkdir -p "$OUT"

echo "[hb-cnt] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/cnt_compile.log"; then
    echo "[hb-cnt] FAIL: host harness did not compile"; cat "$OUT/cnt_compile.log"; exit 1
fi
echo "[hb-cnt] PASS host harness compiled -> $BIN"

echo "[hb-cnt] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/cnt_native.log"; then
    echo "[hb-cnt] FAIL: native hambrowse did not compile"; cat "$OUT/cnt_native.log"; exit 1
fi
echo "[hb-cnt] PASS native hambrowse still compiles"

fail=0; D0="$OUT/cnt_run.txt"
"$BIN" "$FIX" 600 >"$D0" 2>&1 || { echo "[hb-cnt] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
assert_grep(){ if grep -Eq -- "$1" "$D0"; then echo "[hb-cnt] PASS $2"; else echo "[hb-cnt] FAIL $2 (missing: $1)"; fail=1; fi; }

grep -E 'JSLOG|JSERR' "$D0" || true
assert_grep '^JSLOG self=true$'   "contains(self) is true"
assert_grep '^JSLOG child=true$'  "contains(direct child) is true"
assert_grep '^JSLOG deep=true$'   "contains(deep descendant) is true"
assert_grep '^JSLOG rev=false$'   "descendant.contains(ancestor) is false"
assert_grep '^JSLOG sib=false$'   "contains(sibling) is false"

if [ "$fail" -ne 0 ]; then echo "[hb-cnt] RESULT: FAIL"; exit 1; fi
echo "[hb-cnt] RESULT: PASS"
