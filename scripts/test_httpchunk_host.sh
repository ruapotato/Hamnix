#!/usr/bin/env bash
# scripts/test_httpchunk_host.sh — FAST, QEMU-free gate for the HTTP/1.1
# chunked transfer-decoder (lib/httpchunk.ad) that user/http9.ad uses to
# feed hambrowse/wget/curl.
#
# The decoder is factored into a PURE, I/O-free module so it can be compiled
# for the x86_64-linux host target and unit-tested directly — in particular
# the SECURITY-critical bounds behaviour (an oversized/hostile chunk-size is
# clamped, never an OOB read/write) which is hard to observe from inside a
# full browser boot. It also confirms http9.ad (which imports the decoder)
# still compiles for the native target.
#
# Builds with the frozen Python seed compiler (compiles 100% of the tree; no
# self-host bootstrap), so this gate is dependency-light and needs no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/httpchunk_host"
mkdir -p "$OUT"

echo "[dechunk-host] compiling decoder unit test for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/httpchunk_host.ad "$BIN" 2>"$OUT/dechunk.compile.log"; then
    echo "[dechunk-host] FAIL: host harness did not compile"
    cat "$OUT/dechunk.compile.log"; exit 1
fi
echo "[dechunk-host] PASS host harness compiled -> $BIN"

# Confirm http9.ad (which imports lib/httpchunk) still compiles native.
echo "[dechunk-host] compiling native curl (pulls http9 + httpchunk) ..."
if ! adder_bin x86_64-adder-user user/curl.ad "$OUT/curl_native.elf" 2>"$OUT/dechunk.native.log"; then
    echo "[dechunk-host] FAIL: native http9 consumer did not compile"
    cat "$OUT/dechunk.native.log"; exit 1
fi
echo "[dechunk-host] PASS native http9 consumer still compiles"

echo "[dechunk-host] running decoder unit test ..."
DUMP="$OUT/dechunk.txt"
"$BIN" >"$DUMP" 2>&1
rc=$?
cat "$DUMP"

if [ "$rc" -ne 0 ]; then
    echo "[dechunk-host] RESULT: FAIL (harness exit $rc)"; exit 1
fi
if ! grep -q '^\[dechunk\] RESULT: PASS' "$DUMP"; then
    echo "[dechunk-host] RESULT: FAIL (no PASS summary)"; exit 1
fi
# Guard the specific security cases explicitly.
for c in oversize-src-clamp dstcap-clamp malformed-size in-place multichunk; do
    if ! grep -q "^\[dechunk\] PASS $c" "$DUMP"; then
        echo "[dechunk-host] RESULT: FAIL (case '$c' did not pass)"; exit 1
    fi
done
echo "[dechunk-host] RESULT: PASS"
exit 0
