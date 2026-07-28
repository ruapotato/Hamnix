#!/usr/bin/env bash
# scripts/test_hambrowse_dynamic.sh — QEMU-free gate proving a realistic
# DYNAMIC page works END-TO-END inside hambrowse's HOST render pipeline: a
# page <script> that mutates the DOM from a Promise .then, a setTimeout(...,0)
# callback, an async function with await, AND a fixture-backed fetch(url)
# .then(r=>r.json()) — with the browser DRAINING the microtask/timer queue so
# those callbacks run and their DOM mutations reach the RENDERED output.
#
# This exercises the INTEGRATION (lib/htmlengine.ad <script> pipeline +
# lib/jsengine.ad microtask/timer/promise/fetch machinery TOGETHER), not the
# js_host unit harness which drains explicitly. The browser drains inside
# js_eval() after each top-level script, before _dom_readback()/_relayout().
#
# The fixture page seeds each field with a synchronous PENDING_* placeholder
# that its async callbacks OVERWRITE. The gate asserts the final async values
# are painted and NO placeholder survives. As a CONTROL it re-renders with the
# engine's end-of-turn drain DISABLED ("nodrain"): the Promise/timer/fetch
# placeholders then survive, proving the normal render's async DOM mutations
# are genuinely drain-dependent (guards against a false-green gate).
#
# Built with the frozen Python seed compiler. Both compile targets are checked.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-dyn] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/dyn_compile.log"; then
    echo "[hb-dyn] FAIL: host driver did not compile"; cat "$OUT/dyn_compile.log"; exit 1
fi
echo "[hb-dyn] PASS host pixel backend compiled -> $BIN"

echo "[hb-dyn] confirming NATIVE hambrowse still compiles (x86_64-adder-user) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/dyn_native.log"; then
    echo "[hb-dyn] FAIL: native hambrowse did not compile"; cat "$OUT/dyn_native.log"; exit 1
fi
echo "[hb-dyn] PASS native hambrowse still compiles from the shared engine"

PAGE="tests/fixtures/hambrowse_dynamic.html"
DUMP="$OUT/dyn_dump.txt"
PPM="$OUT/dyn.ppm"
PNG="$OUT/dyn.png"

echo "[hb-dyn] rendering dynamic page (drain ON) -> $PNG ..."
if ! "$BIN" "$PAGE" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-dyn] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/dyn_png.log"; then
    echo "[hb-dyn] PASS rendered PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-dyn] FAIL png conversion"; cat "$OUT/dyn_png.log"; fail=1
fi

assert_seg() {
    local pat="$1" msg="$2"
    if grep -Eq -- "^SEGTXT .*$pat" "$DUMP"; then
        echo "[hb-dyn] PASS $msg"
    else
        echo "[hb-dyn] FAIL $msg (missing painted run: $pat)"; fail=1
    fi
}
refute_seg() {
    local pat="$1" msg="$2"
    if grep -Eq -- "^SEGTXT .*$pat" "$DUMP"; then
        echo "[hb-dyn] FAIL $msg (unexpected painted run: $pat)"; fail=1
    else
        echo "[hb-dyn] PASS $msg"
    fi
}

# The async DOM mutations reached the RENDERED (painted) segment list:
assert_seg 'resolved=42'              "Promise .then mutation painted"
assert_seg 'fired-after-timeout'      "setTimeout(...,0) callback mutation painted"
assert_seg 'awaited=42'               "async/await mutation painted"
assert_seg 'Ada Lovelace score=1815' "fixture-backed fetch().then(r=>r.json()) mutation painted"
assert_seg 'done'                     "fetch-chain final status mutation painted"

# NOT ONE synchronous placeholder survived the drain — proves every async
# callback ran and overwrote its field before render.
refute_seg 'PENDING_PROMISE' "no pre-drain Promise placeholder in render"
refute_seg 'PENDING_TIMER'   "no pre-drain setTimeout placeholder in render"
refute_seg 'PENDING_ASYNC'   "no pre-drain async placeholder in render"
refute_seg 'PENDING_FETCH'   "no pre-drain fetch placeholder in render"

# ---- CONTROL: disable the end-of-turn drain and re-render. The Promise/timer/
# fetch callbacks now never run, so their SYNCHRONOUS placeholders survive into
# the painted output. This proves the drain-ON assertions above are genuinely
# drain-dependent (a false-green gate would still pass this render).
CDUMP="$OUT/dyn_nodrain_dump.txt"
CPPM="$OUT/dyn_nodrain.ppm"
CPNG="$OUT/dyn_nodrain.png"
echo "[hb-dyn] CONTROL: re-rendering with drain DISABLED -> $CPNG ..."
if ! "$BIN" "$PAGE" "$CPPM" 640 nodrain >"$CDUMP" 2>&1; then
    echo "[hb-dyn] FAIL: control render exited non-zero"; cat "$CDUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$CPPM" "$CPNG" 2>/dev/null || true

cassert() {   # pattern must be PRESENT in the control dump
    local pat="$1" msg="$2"
    if grep -Eq -- "^SEGTXT .*$pat" "$CDUMP"; then
        echo "[hb-dyn] PASS control: $msg"
    else
        echo "[hb-dyn] FAIL control: $msg (expected placeholder $pat to survive)"; fail=1
    fi
}
crefute() {   # pattern must be ABSENT in the control dump
    local pat="$1" msg="$2"
    if grep -Eq -- "^SEGTXT .*$pat" "$CDUMP"; then
        echo "[hb-dyn] FAIL control: $msg (async value $pat leaked without drain)"; fail=1
    else
        echo "[hb-dyn] PASS control: $msg"
    fi
}
# Without the drain the deferred-callback fields keep their placeholders ...
cassert 'PENDING_PROMISE' "Promise placeholder survives (reaction never drained)"
cassert 'PENDING_TIMER'   "setTimeout placeholder survives (timer never fired)"
cassert 'PENDING_FETCH'   "fetch placeholder survives (fetch reaction never drained)"
# ... and the drain-dependent async values are ABSENT.
crefute 'resolved=42'              "Promise mutation absent without drain"
crefute 'fired-after-timeout'      "setTimeout mutation absent without drain"
crefute 'Ada Lovelace score=1815'  "fetch mutation absent without drain"

if [ "$fail" -eq 0 ]; then
    echo "[hb-dyn] PASS"
else
    echo "[hb-dyn] FAIL"; exit 1
fi
