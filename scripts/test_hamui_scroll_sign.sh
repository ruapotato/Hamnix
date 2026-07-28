#!/usr/bin/env bash
# scripts/test_hamui_scroll_sign.sh — FAST, QEMU-free gate for BUG #123
# (mouse scroll wheel inverted in EVERY hamUI app).
#
# The shared sign lives in lib/hamscene.ad::hamui_scroll_apply, which
# lib/hamui.ad::_h_route_scroll calls for scrolledwindow + textview. This
# gate compiles that PURE helper for the host Linux target and runs a unit
# test of the sign law (wheel-down increases the offset -> content scrolls
# DOWN through the document), then confirms a NATIVE hamui consumer still
# compiles so the fix can't silently break the real build.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/test_hamui_scroll_sign"

echo "[hamui-scroll-sign] compiling host unit test ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux tests/test_hamui_scroll_sign.ad "$BIN" 2>"$OUT/scroll_sign_compile.log"; then
    echo "[hamui-scroll-sign] FAIL: host test did not compile"
    cat "$OUT/scroll_sign_compile.log"
    exit 1
fi

echo "[hamui-scroll-sign] running host unit test ..."
if ! "$BIN"; then
    echo "[hamui-scroll-sign] FAIL: wheel sign assertions failed"
    exit 1
fi

echo "[hamui-scroll-sign] confirming native hamui consumer still compiles ..."
if ! adder_bin x86_64-adder-user user/hamedit.ad "$OUT/hamedit_native.elf" 2>"$OUT/hamedit_native.log"; then
    echo "[hamui-scroll-sign] FAIL: native hamedit did not compile"
    cat "$OUT/hamedit_native.log"
    exit 1
fi

echo "[hamui-scroll-sign] PASS"
exit 0
