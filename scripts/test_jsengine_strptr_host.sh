#!/usr/bin/env bash
# scripts/test_jsengine_strptr_host.sh — FAST, QEMU-free gate proving
# js_str_ptr() hands out INDEPENDENT scratch buffers for back-to-back reads.
#
# Regression for the shared-scratch bug: two consecutive js_str_ptr() calls used
# to alias one buffer, so the first pointer was clobbered by the second — exactly
# what lib/web/dom does when it reads a key + value (or two adjacent attributes)
# in a row. The probe takes four pointers back-to-back and asserts all four
# survive (prints "OK").
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_strptr_probe"
mkdir -p "$OUT"

echo "[js-strptr] compiling probe for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_strptr_probe.ad "$BIN" 2>"$OUT/js_strptr_compile.log"; then
    echo "[js-strptr] FAIL: probe did not compile"; cat "$OUT/js_strptr_compile.log"; exit 1
fi

got="$("$BIN")"
if [ "$got" = "OK" ]; then
    echo "[js-strptr] PASS (four back-to-back js_str_ptr pointers all survived)"
    echo "[js-strptr] RESULT: PASS"
    exit 0
else
    echo "[js-strptr] FAIL: expected 'OK', got '$got'"
    echo "[js-strptr] RESULT: FAIL"
    exit 1
fi
