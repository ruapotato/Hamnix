#!/usr/bin/env bash
# scripts/test_hammouse_cfg.sh — FAST, QEMU-free gate for the Control Center
# MOUSE capplet live sink (/tmp/hamnix-mouse.conf).
#
# The pointer-preference transform law (speed scale, primary L<->R swap,
# Natural-scroll invert) lives in lib/hammouse_cfg.ad, consumed by BOTH the
# kernel /dev/mouse router (sys/src/9/port/devwsys.ad) and the capplet push
# path (user/hamctl.ad -> devmouse_write). This gate compiles that PURE
# helper for the host Linux target and asserts the config->behavior mapping,
# then confirms the native /dev/mouse device still compiles so the wiring
# can't silently break the real build.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/test_hammouse_cfg"

echo "[hammouse-cfg] compiling host unit test ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux tests/test_hammouse_cfg.ad "$BIN" 2>"$OUT/hammouse_cfg_compile.log"; then
    echo "[hammouse-cfg] FAIL: host test did not compile"
    cat "$OUT/hammouse_cfg_compile.log"
    exit 1
fi

echo "[hammouse-cfg] running host unit test ..."
if ! "$BIN"; then
    echo "[hammouse-cfg] FAIL: transform-law assertions failed"
    exit 1
fi

echo "[hammouse-cfg] PASS"
exit 0
