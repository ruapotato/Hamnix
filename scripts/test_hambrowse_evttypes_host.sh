#!/usr/bin/env bash
# scripts/test_hambrowse_evttypes_host.sh — FAST, QEMU-free gate for ARBITRARY
# event-type dispatch (browser campaign round 2 / W3C dom-events depth). Round 1
# wired only 4 integer kinds (click/input/change/submit); any other type set
# ek=-1 and was dropped, and dispatchEvent of an unknown type fired NO listeners.
# This gate proves the string-typed listener table real pages depend on:
#   - a NON-standard type (keydown) registered + dispatched fires, with a live
#     event.type / event.target.
#   - generic types BUBBLE target -> ancestor with currentTarget re-pointed.
#   - distinct types never cross-fire (keyup must not run a keydown listener).
#   - a fully custom application type (my:thing) fires.
#   - removeEventListener(type, fn) removes a generic listener.
#   - stopPropagation() halts a generic bubble.
# Exact-output oracle on console.log lines. Builds host + native targets.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_evttypes.html"
mkdir -p "$OUT"

echo "[hb-evtt] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/evtt_compile.log"; then
    echo "[hb-evtt] FAIL: host harness did not compile"; cat "$OUT/evtt_compile.log"; exit 1
fi
echo "[hb-evtt] PASS host harness compiled -> $BIN"

echo "[hb-evtt] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/evtt_native.log"; then
    echo "[hb-evtt] FAIL: native hambrowse did not compile"; cat "$OUT/evtt_native.log"; exit 1
fi
echo "[hb-evtt] PASS native hambrowse still compiles"

fail=0
D0="$OUT/evtt_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-evtt] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-evtt] PASS $2"; else echo "[hb-evtt] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_nogrep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-evtt] FAIL $2 (present: $1)"; fail=1; else echo "[hb-evtt] PASS $2"; fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep '^JSLOG KD type=keydown target=btn$'        "a non-standard type (keydown) fires with live type/target"
assert_grep '^JSLOG MO ctarget=outer target=btn$'       "a generic type bubbles to ancestor; currentTarget re-points, target stays"
assert_grep '^JSLOG MOSEQ bo$'                          "generic bubble order is target then ancestor"
assert_grep '^JSLOG CROSS U$'                           "distinct types do not cross-fire (dispatching keyup ran only the keyup listener, not keydown)"
assert_grep '^JSLOG CUSTOM ok type=my:thing$'           "a fully custom application event type fires"
assert_grep '^JSLOG REMGEN F$'                          "removeEventListener removed the generic listener (fired once, not twice)"
assert_grep '^JSLOG GSTOP M$'                           "stopPropagation halts a generic bubble (ancestor scroll listener did not run)"
assert_nogrep '^JSLOG GSTOP MX'                         "the stopped ancestor generic listener did not run"
assert_nogrep '^JSERR'                                  "no uncaught JS error across the dispatch script"
assert_nogrep 'Uncaught'                                "no 'Uncaught' TypeError from a missing event API"

if [ "$fail" -ne 0 ]; then echo "[hb-evtt] RESULT: FAIL"; exit 1; fi
echo "[hb-evtt] RESULT: PASS"
