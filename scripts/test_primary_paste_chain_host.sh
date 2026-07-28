#!/usr/bin/env bash
# scripts/test_primary_paste_chain_host.sh — FAST, QEMU-free host gate for the
# FULL cross-surface X11 PRIMARY paste chain (highlight -> middle-click -> paste
# lands), joining the terminal EXTRACTOR + the real devsnarf primary buffer + a
# raw compositor "m x y 4 0" MIDDLE-click wire line + the shared rising-edge
# detector, with a cross-app read from the editor/Notes path selector.
#
# Deterministic, milliseconds, no DE/compositor/mouse-injection. It also
# confirms the new /bin/haminput Input Event Inspector app compiles NATIVE
# (x86_64-adder-user), so the on-device diagnostic can't drift from the tree.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/primary_paste_chain_host"
mkdir -p "$OUT" build/user

echo "[prim-chain] compiling host gate (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/primary_paste_chain_host.ad "$BIN" 2>"$OUT/prim_chain_compile.log"; then
    echo "[prim-chain] FAIL: host gate did not compile"; cat "$OUT/prim_chain_compile.log"; exit 1
fi

echo "[prim-chain] confirming /bin/haminput inspector compiles NATIVE ..."
if ! adder_bin x86_64-adder-user user/haminput.ad "$OUT/haminput_native.elf" 2>"$OUT/prim_chain_native.log"; then
    echo "[prim-chain] FAIL: native haminput did not compile"
    cat "$OUT/prim_chain_native.log"; exit 1
fi
echo "[prim-chain] PASS native haminput compile"

echo "[prim-chain] running host gate ..."
DUMP="$OUT/prim_chain_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[prim-chain] host gate reported failures:"; cat "$DUMP"; exit 1
fi
cat "$DUMP"
if ! grep -q "^\[prim-chain\] RESULT PASS" "$DUMP"; then
    echo "[prim-chain] FAIL: RESULT PASS marker missing"; exit 1
fi
echo "PASS: cross-surface PRIMARY paste chain host gate"
