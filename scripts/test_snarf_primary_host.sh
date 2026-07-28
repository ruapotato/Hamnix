#!/usr/bin/env bash
# scripts/test_snarf_primary_host.sh — FAST, QEMU-free host unit test proving
# the X11-style PRIMARY selection (task #315): highlighting text SETS a second
# clipboard buffer (/dev/snarf.primary) INDEPENDENT of the CLIPBOARD
# (/dev/snarf, Ctrl+C/Ctrl+V), and a middle-click paste READS it back. It joins
# the three real pieces of the shipped mechanism — the kernel dual-buffer device
# (sys/src/9/port/devsnarf.ad), the toolkit path selectors (lib/htermsel.ad +
# lib/hamtextbox.ad), and the kernel's path->buffer routing — with no DE, no
# compositor, and no flaky mouse injection, then drives the exact put/get
# sequence the widgets make and asserts the two buffers never clobber each other.
#
# It also confirms the browser URL bar (which I extended with middle-click
# PRIMARY paste) still compiles NATIVE, so the host proof can't drift from the
# shipped on-device code path.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/snarf_primary_host"
mkdir -p "$OUT"

echo "[snarf-prim] compiling host unit test (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/snarf_primary_host.ad "$BIN" 2>"$OUT/snarf_prim_compile.log"; then
    echo "[snarf-prim] FAIL: host harness did not compile"
    cat "$OUT/snarf_prim_compile.log"; exit 1
fi

echo "[snarf-prim] confirming the browser (middle-click PRIMARY paste) compiles NATIVE ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/snarf_prim_native.log"; then
    echo "[snarf-prim] FAIL: native hambrowse did not compile"
    cat "$OUT/snarf_prim_native.log"; exit 1
fi
echo "[snarf-prim] PASS native compile"

echo "[snarf-prim] running host unit test ..."
DUMP="$OUT/snarf_prim_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[snarf-prim] host unit test reported failures:"; cat "$DUMP"; exit 1
fi
cat "$DUMP"
if ! grep -q "^\[snarf-prim\] RESULT PASS" "$DUMP"; then
    echo "[snarf-prim] FAIL: RESULT PASS marker missing"; exit 1
fi
echo "PASS: #315 PRIMARY-selection independent-of-CLIPBOARD host unit test"
