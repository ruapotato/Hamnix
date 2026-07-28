#!/usr/bin/env bash
# scripts/test_hambrowse_construct.sh — QEMU-free gate proving a <script> can
# CONSTRUCT new DOM nodes from data and have them RENDER inside hambrowse's HOST
# pipeline. The fixture fetches a JSON array (fixture-backed, no network) and,
# in the fetch .then, builds a <table> ENTIRELY from script — document.
# createElement / document.createTextNode / element.appendChild (nested:
# table > tr > td > text) / element.textContent / element.className — then
# mounts it under an existing <div>. The gate asserts the built rows/cells (and
# their text) reached the RENDERED segment list.
#
# This exercises node CONSTRUCTION (nodes NOT present in the source HTML) flowing
# through the readback -> rewrite -> relayout -> paint path, distinct from the
# mutation-of-existing-nodes gate (test_hambrowse_dynamic.sh).
#
# CONTROL (false-green guard): the build runs inside the fetch reaction, so it
# is drain-dependent. Re-rendering with the engine's end-of-turn drain DISABLED
# ("nodrain") leaves the mount's ORIGINAL placeholder in place and NO table —
# proving the rendered rows are genuinely script-constructed, not static markup.
#
# Built with the frozen Python seed compiler. Both compile targets are checked.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-con] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/con_compile.log"; then
    echo "[hb-con] FAIL: host driver did not compile"; cat "$OUT/con_compile.log"; exit 1
fi
echo "[hb-con] PASS host pixel backend compiled -> $BIN"

echo "[hb-con] confirming NATIVE hambrowse still compiles (x86_64-adder-user) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/con_native.log"; then
    echo "[hb-con] FAIL: native hambrowse did not compile"; cat "$OUT/con_native.log"; exit 1
fi
echo "[hb-con] PASS native hambrowse still compiles from the shared engine"

PAGE="tests/fixtures/hambrowse_construct.html"
DUMP="$OUT/con_dump.txt"
PPM="$OUT/construct.ppm"
PNG="$OUT/construct.png"

echo "[hb-con] rendering construction page (drain ON) -> $PNG ..."
if ! "$BIN" "$PAGE" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-con] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/con_png.log"; then
    echo "[hb-con] PASS rendered PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-con] FAIL png conversion"; cat "$OUT/con_png.log"; fail=1
fi

assert_seg() {
    local pat="$1" msg="$2"
    if grep -Eq -- "^SEGTXT .*$pat" "$DUMP"; then
        echo "[hb-con] PASS $msg"
    else
        echo "[hb-con] FAIL $msg (missing painted run: $pat)"; fail=1
    fi
}
refute_seg() {
    local pat="$1" msg="$2"
    if grep -Eq -- "^SEGTXT .*$pat" "$DUMP"; then
        echo "[hb-con] FAIL $msg (unexpected painted run: $pat)"; fail=1
    else
        echo "[hb-con] PASS $msg"
    fi
}

# The script-constructed header cells (createElement th + textContent /
# createTextNode) reached the painted segment list:
assert_seg 'NAME_COL'  "createElement(th).textContent header cell painted"
assert_seg 'SCORE_COL' "createElement(th)+createTextNode header cell painted"
# Each data row: a createTextNode name cell + a textContent score cell, built by
# nested createElement/appendChild (table > tr > td > text) from the fetched array.
assert_seg 'Ada'      "row 0 createTextNode name cell painted"
assert_seg 's=1815'   "row 0 textContent score cell painted"
assert_seg 'Grace'    "row 1 createTextNode name cell painted"
assert_seg 's=1906'   "row 1 textContent score cell painted"
assert_seg 'Alan'     "row 2 createTextNode name cell painted"
assert_seg 's=1912'   "row 2 textContent score cell painted"
# The original mount placeholder was cleared by the build:
refute_seg 'MOUNT_EMPTY_PLACEHOLDER' "mount placeholder cleared by the build"

# ---- CONTROL: disable the end-of-turn drain and re-render. The fetch .then
# never runs, so the table is never built: the mount keeps its ORIGINAL
# placeholder and none of the constructed cells appear. This proves the
# drain-ON assertions above are genuinely built by the script (a false-green
# gate that rendered static markup would still show the rows here).
CDUMP="$OUT/con_nodrain_dump.txt"
CPPM="$OUT/construct_nodrain.ppm"
CPNG="$OUT/construct_nodrain.png"
echo "[hb-con] CONTROL: re-rendering with drain DISABLED -> $CPNG ..."
if ! "$BIN" "$PAGE" "$CPPM" 640 nodrain >"$CDUMP" 2>&1; then
    echo "[hb-con] FAIL: control render exited non-zero"; cat "$CDUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$CPPM" "$CPNG" 2>/dev/null || true

cassert() {   # pattern must be PRESENT in the control dump
    local pat="$1" msg="$2"
    if grep -Eq -- "^SEGTXT .*$pat" "$CDUMP"; then
        echo "[hb-con] PASS control: $msg"
    else
        echo "[hb-con] FAIL control: $msg (expected $pat to survive)"; fail=1
    fi
}
crefute() {   # pattern must be ABSENT in the control dump
    local pat="$1" msg="$2"
    if grep -Eq -- "^SEGTXT .*$pat" "$CDUMP"; then
        echo "[hb-con] FAIL control: $msg (constructed $pat appeared without drain)"; fail=1
    else
        echo "[hb-con] PASS control: $msg"
    fi
}
# Without the drain the mount keeps its placeholder ...
cassert 'MOUNT_EMPTY_PLACEHOLDER' "placeholder survives (build reaction never drained)"
# ... and NONE of the script-constructed cells were built.
crefute 'NAME_COL' "header cell absent without drain"
crefute 'Ada'      "row 0 name cell absent without drain"
crefute 's=1815'   "row 0 score cell absent without drain"
crefute 'Alan'     "row 2 name cell absent without drain"

if [ "$fail" -eq 0 ]; then
    echo "[hb-con] PASS"
else
    echo "[hb-con] FAIL"; exit 1
fi
