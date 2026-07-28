#!/usr/bin/env bash
# scripts/test_hamsh_complete_host.sh — FAST, QEMU-free host gate for the
# PURE completion engine (lib/hamcomplete.ad) behind hamsh's interactive Tab
# completion (user/hamsh.ad :: _ed_complete).
#
# The full interactive completion path needs a boot (scripts/test_hamsh_complete.sh
# drives Tab over the serial console). This gate compiles the matching KERNEL
# for the host Linux target (user/hamcomplete_host.ad) and runs it directly in
# milliseconds — asserting prefix filtering, longest-common-prefix extension,
# empty/one/many candidates, dedup, and empty-field skipping. The on-device
# gather helpers (_cmp_offer*) delegate their prefix test + LCP fold to the
# SAME primitives, so a green host run guards the byte-level matching logic
# without QEMU.
#
# It also confirms the NATIVE hamsh still compiles from the shared engine
# (no regress).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamcomplete_host"
mkdir -p "$OUT"
fail=0

echo "[cmp-host] compiling completion engine + harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamcomplete_host.ad "$BIN" 2>"$OUT/cmp_compile.log"; then
    echo "[cmp-host] FAIL: host harness did not compile"; cat "$OUT/cmp_compile.log"; exit 1
fi
echo "[cmp-host] PASS host harness compiled -> $BIN"

echo "[cmp-host] compiling NATIVE hamsh for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_native.elf" 2>"$OUT/cmp_native.log"; then
    echo "[cmp-host] FAIL: native hamsh did not compile"; cat "$OUT/cmp_native.log"; exit 1
fi
echo "[cmp-host] PASS native hamsh still compiles from the shared engine"

DUMP="$OUT/cmp_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[cmp-host] FAIL: unit-test harness reported a failure"; cat "$DUMP"; fail=1
fi

echo "[cmp-host] --- harness output ---"
cat "$DUMP"
echo "[cmp-host] --- end output ---"

# Every unit case must PASS and the final RESULT marker must be ok.
if grep -q '^FAIL ' "$DUMP"; then
    echo "[cmp-host] FAIL: one or more unit cases failed"; fail=1
fi
if ! grep -q '^RESULT ok$' "$DUMP"; then
    echo "[cmp-host] FAIL: missing 'RESULT ok' marker"; fail=1
fi

# Spot-check a few named cases actually ran (guards a truncated/hung run).
for c in one_match_full many_lcp_ba lcp_extends dedup_echo skip_empty_fields; do
    if ! grep -q "^PASS $c$" "$DUMP"; then
        echo "[cmp-host] FAIL: case '$c' did not PASS"; fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[cmp-host] FAIL"
    exit 1
fi
echo "[cmp-host] PASS"
