#!/usr/bin/env bash
# scripts/test_htermsel_host.sh — FAST, QEMU-free host unit test for the #323
# terminal grid-text SELECTION model in lib/htermsel.ad ("copy an error message
# out of a terminal"). Compiles the pure selection logic (anchor/caret cell
# model, pixel->cell map, text-flow span test, cell-span->text extraction) for
# x86_64-linux and runs deterministic assertions in milliseconds — no DE, no
# compositor, no mouse-injection flakiness, no font engine. The extractor walks
# the cell grid (not pixels), so the proof is font-independent.
#
# It also confirms lib/htermsel.ad still compiles NATIVE (x86_64-adder-user) via
# the real terminal user/hamtermscene.ad, so the host harness can't drift from
# the shipped, on-device code path.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/htermsel_host"
mkdir -p "$OUT"

echo "[htsel-host] compiling host unit test (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/htermsel_host.ad "$BIN" 2>"$OUT/htsel_compile.log"; then
    echo "[htsel-host] FAIL: host harness did not compile"; cat "$OUT/htsel_compile.log"; exit 1
fi

echo "[htsel-host] confirming the terminal (uses lib/htermsel) compiles NATIVE ..."
if ! adder_bin x86_64-adder-user user/hamtermscene.ad "$OUT/hamtermscene_native.elf" 2>"$OUT/htsel_native.log"; then
    echo "[htsel-host] FAIL: native hamtermscene (uses htermsel) did not compile"
    cat "$OUT/htsel_native.log"; exit 1
fi
echo "[htsel-host] PASS native compile"

echo "[htsel-host] running host unit test ..."
DUMP="$OUT/htsel_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[htsel-host] host unit test reported failures:"; cat "$DUMP"; exit 1
fi
cat "$DUMP"
if ! grep -q "^\[htsel-host\] RESULT PASS" "$DUMP"; then
    echo "[htsel-host] FAIL: RESULT PASS marker missing"; exit 1
fi
echo "PASS: #323 hamtermscene grid-selection + copy host unit test"
