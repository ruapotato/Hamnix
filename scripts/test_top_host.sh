#!/usr/bin/env bash
# scripts/test_top_host.sh — FAST, QEMU-free host gate for the interactive
# `top` model + renderer (lib/toprender.ad). The full TUI needs a boot (a real
# VT to repaint), but the parse / %CPU-delta / CPU-sort / frame-format logic is
# pure, so we compile the harness (user/toprender_host.ad) for the host Linux
# target and run it directly in milliseconds. It also confirms NATIVE top still
# compiles from the shared engine.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/toprender_host"
mkdir -p "$OUT"
fail=0

echo "[top-host] compiling top model + harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/toprender_host.ad "$BIN" 2>"$OUT/top_compile.log"; then
    echo "[top-host] FAIL: host harness did not compile"; cat "$OUT/top_compile.log"; exit 1
fi
echo "[top-host] PASS host harness compiled -> $BIN"

echo "[top-host] compiling NATIVE top for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/top.ad "$OUT/top_native.elf" 2>"$OUT/top_native.log"; then
    echo "[top-host] FAIL: native top did not compile"; cat "$OUT/top_native.log"; exit 1
fi
echo "[top-host] PASS native top still compiles from the shared model"

DUMP="$OUT/top_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[top-host] FAIL: unit-test harness reported a failure"; cat "$DUMP"; fail=1
fi

echo "[top-host] --- harness output ---"
cat "$DUMP"
echo "[top-host] --- end output ---"

if grep -q '^FAIL ' "$DUMP"; then
    echo "[top-host] FAIL: one or more unit cases failed"; fail=1
fi
if ! grep -q '^RESULT ok$' "$DUMP"; then
    echo "[top-host] FAIL: missing 'RESULT ok' marker"; fail=1
fi

# Spot-check the load-bearing cases (parse, %CPU delta, sort, frame content).
for c in cpu_pid7_700 cpu_pid9_250 sort_pid7_first frame_home frame_cpu70; do
    if ! grep -q "^PASS $c$" "$DUMP"; then
        echo "[top-host] FAIL: case '$c' did not PASS"; fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[top-host] FAIL"
    exit 1
fi
echo "[top-host] PASS"
