#!/usr/bin/env bash
# scripts/test_hambrowse_phase0_host.sh — FAST, QEMU-free gate for the Phase-0
# FUNCTIONAL fixes from docs/browser_gap_analysis_2026-07-24.md: the correctness
# bugs + missing-but-simple APIs that block hambrowse from RUNNING (not just
# painting) the live web. Each assertion below is oracle-checked against V8
# (node) for pure JS and against real `chromium --headless --dump-dom` for the
# DOM/event behaviours (see scripts/probe_js_hard.sh / scripts/probe_dom_api.sh),
# and this gate pins the exact console.log (JSLOG) outputs so a regression fails
# CI. NO QEMU — runs the SAME lib/web engine the native browser uses via the
# x86_64-linux host harness (user/hambrowse_host.ad).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_phase0.html"
mkdir -p "$OUT"

echo "[hb-p0] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/p0_compile.log"; then
    echo "[hb-p0] FAIL: host harness did not compile"; cat "$OUT/p0_compile.log"; exit 1
fi
echo "[hb-p0] PASS host harness compiled -> $BIN"

echo "[hb-p0] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/p0_native.log"; then
    echo "[hb-p0] FAIL: native hambrowse did not compile"; cat "$OUT/p0_native.log"; exit 1
fi
echo "[hb-p0] PASS native hambrowse still compiles"

fail=0
D0="$OUT/p0_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-p0] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

if grep -q '^JSLOG Uncaught' "$D0"; then
    echo "[hb-p0] FAIL: uncaught JS error"; grep '^JSLOG Uncaught' "$D0"; fail=1
fi

assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-p0] PASS $2"; else echo "[hb-p0] FAIL $2 (missing: $1)"; fail=1; fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# --- correctness bug: for(let) per-iteration binding (was 1,2,3; V8 = 0,1,2) ---
assert_grep '^JSLOG FORLET 0,1,2$'   "for(let) fresh per-iteration binding (closure-in-loop)"
# --- programmatic events (were: throw / no-op) ---
assert_grep '^JSLOG CLICK fired$'    "element.click() drives a registered handler (created node)"
assert_grep '^JSLOG BUBBLE c$'       "dispatch bubbles; e.target is the origin (created delegation)"
assert_grep '^JSLOG CUSTOM foo$'     "dispatchEvent(new Event) fires a listener by type"
assert_grep '^JSLOG DETAIL 42$'      "CustomEvent detail propagates to the listener"
assert_grep '^JSLOG PREVENT true$'   "preventDefault sets event.defaultPrevented"
# --- DOM method holes (were: missing / broken) ---
assert_grep '^JSLOG MATCHES true$'   "element.matches() on an innerHTML node"
assert_grep '^JSLOG CLOSEST Y$'      "element.closest() climbs the live parentNode chain"
assert_grep '^JSLOG APPEND Y$'       "element.append(string) adds a text node"
assert_grep '^JSLOG REMOVE 0$'       "element.remove() detaches from parent.children"
assert_grep '^JSLOG NEXTSIB B$'      "nextElementSibling on innerHTML children"
assert_grep '^JSLOG CLSADD a b c$'   "variadic classList.add(a,b,c)"
assert_grep '^JSLOG CHECKED true$'   "input.checked reflects the innerHTML boolean attr"
# --- JS long tail (V8 oracle) ---
assert_grep '^JSLOG NEWTARGET new$'  "new.target parses; is the ctor in a construct call"
assert_grep '^JSLOG NEWTARGETC call$' "new.target is undefined in a plain call"
assert_grep '^JSLOG ERRINSTOF true$' "engine-thrown error is instanceof TypeError"
assert_grep '^JSLOG INOP true$'      "'length' in [] is true"
assert_grep '^JSLOG MAPENT k7$'      "Map.prototype.entries() returns an iterator (.next())"
assert_grep '^JSLOG PROMISEANY ok$'  "Promise.any resolves with the first fulfilment"

if [ "$fail" -ne 0 ]; then echo "[hb-p0] RESULT: FAIL"; exit 1; fi
echo "[hb-p0] RESULT: PASS"
