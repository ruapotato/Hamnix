#!/usr/bin/env bash
# scripts/test_keydemo_host.sh — FAST, QEMU-free host gate for the terminal
# GAME-input protocol (lib/gamekey.ad) that lets a terminal program observe key
# DOWN *and* UP — the capability a cooked Linux tty cannot provide. The full
# path needs a boot (the compositor -> hamtermscene GAME mode -> program), but
# the "d <code>\n" / "u <code>\n" decoder is pure, so we compile the harness
# (user/gamekey_host.ad) for the host and run it in milliseconds. It also
# confirms NATIVE keydemo compiles.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/gamekey_host"
mkdir -p "$OUT"
fail=0

echo "[keydemo-host] compiling game-key decoder + harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/gamekey_host.ad "$BIN" 2>"$OUT/gamekey_compile.log"; then
    echo "[keydemo-host] FAIL: host harness did not compile"; cat "$OUT/gamekey_compile.log"; exit 1
fi
echo "[keydemo-host] PASS host harness compiled -> $BIN"

echo "[keydemo-host] compiling NATIVE keydemo for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/keydemo.ad "$OUT/keydemo_native.elf" 2>"$OUT/keydemo_native.log"; then
    echo "[keydemo-host] FAIL: native keydemo did not compile"; cat "$OUT/keydemo_native.log"; exit 1
fi
echo "[keydemo-host] PASS native keydemo still compiles"

DUMP="$OUT/gamekey_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[keydemo-host] FAIL: unit-test harness reported a failure"; cat "$DUMP"; fail=1
fi

echo "[keydemo-host] --- harness output ---"
cat "$DUMP"
echo "[keydemo-host] --- end output ---"

if grep -q '^FAIL ' "$DUMP"; then
    echo "[keydemo-host] FAIL: one or more unit cases failed"; fail=1
fi
if ! grep -q '^RESULT ok$' "$DUMP"; then
    echo "[keydemo-host] FAIL: missing 'RESULT ok' marker"; fail=1
fi

# The load-bearing proof: key UP is decoded distinctly from key DOWN.
for c in down_a up_a down_q partial_carried; do
    if ! grep -q "^PASS $c$" "$DUMP"; then
        echo "[keydemo-host] FAIL: case '$c' did not PASS"; fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[keydemo-host] FAIL"
    exit 1
fi
echo "[keydemo-host] PASS"
