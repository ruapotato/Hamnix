#!/usr/bin/env bash
# scripts/test_hamtextbox_host.sh — FAST, QEMU-free host unit test for the
# #315 text-selection substrate in lib/hamtextbox.ad. Compiles the pure logic
# (htb_hit_test click-to-position + the managed-box selection model) for the
# x86_64-linux host and runs deterministic assertions in milliseconds — no DE,
# no compositor, no mouse-injection flakiness. Also confirms lib/hamtextbox.ad
# still compiles NATIVE (x86_64-adder-user) via the reference editor, so the
# host harness can't drift from the shipped code.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamtextbox_host"
mkdir -p "$OUT"

echo "[htb-host] compiling host unit test (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamtextbox_host.ad "$BIN" 2>"$OUT/htb_compile.log"; then
    echo "[htb-host] FAIL: host harness did not compile"; cat "$OUT/htb_compile.log"; exit 1
fi

echo "[htb-host] confirming lib/hamtextbox.ad still compiles NATIVE ..."
if ! adder_bin x86_64-adder-user user/hameditscene.ad "$OUT/hameditscene_native.elf" 2>"$OUT/htb_native.log"; then
    echo "[htb-host] FAIL: native hameditscene (uses hamtextbox) did not compile"
    cat "$OUT/htb_native.log"; exit 1
fi
echo "[htb-host] PASS native compile"

echo "[htb-host] running host unit test ..."
DUMP="$OUT/htb_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[htb-host] host unit test reported failures:"; cat "$DUMP"; exit 1
fi
cat "$DUMP"
if ! grep -q "^\[htb-host\] RESULT PASS" "$DUMP"; then
    echo "[htb-host] FAIL: RESULT PASS marker missing"; exit 1
fi
echo "PASS: #315 hamtextbox hit-test + selection host unit test"
