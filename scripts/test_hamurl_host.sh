#!/usr/bin/env bash
#
# VERDICT 2026-07-28: GATE ROT, not a caret bug — now REGISTERED in
# scripts/ci_battery_manifest.txt (~64 s, QEMU-free).
#
# The 2026-07-28 sweep read the red as "a proportional-advance vs fixed-advance
# mismatch between the forward (index -> px) and reverse (px -> index) walks",
# because the error grew with k (k=13 -> 10, k=16 -> 13, k=20 -> 17) while both
# clamps passed. It is neither. It was ONE stale constant: this test hardcoded
# the address-text origin as `NAV_BAR_W + 5`, and BW_ADDR_PAD moved 5 -> 24 in
# 78f5f299 so the URL text would clear the omnibox site icon. The painter
# (_bw_draw_addr) and the hit-test (browserwin_addr_caret_at) both take that
# pad and stayed exact inverses; only the test was left behind, clicking a
# CONSTANT 19 px left of every caret pixel. Because the 13px advances are
# proportional, a constant pixel shift reads as a growing INDEX error — which
# is what made it look like a proportional-vs-fixed bug.
#
# The origin is now DERIVED from the layout via browserwin_addr_text_x(), so
# this cannot rot the same way again. No assertion was weakened: all 23 checks
# pass against unchanged caret math, and the host render confirms in pixels
# that the selection band covers exactly the requested span.
# scripts/test_hamurl_host.sh — FAST, QEMU-free host gate for the #315 text-
# selection substrate propagated into the browser URL bar (user/hambrowse.ad +
# lib/browserwin.ad). Three checks:
#   1. a deterministic UNIT TEST that browserwin_addr_caret_at (URL click-to-
#      position) is the EXACT inverse of the address text's 13px caret pixels —
#      so a click / arrow lands the caret on the clicked glyph instead of the
#      buffer end (the user-reported "can't move the cursor in the URL" bug);
#   2. the NATIVE browser (arrow nav + Ctrl+A/C/V/X on /dev/snarf) still builds
#      for x86_64-adder-user;
#   3. a host PNG of the window with a SPAN of the URL highlighted (the shared
#      #b4d0f8 selection band) + a caret, rendered by the SAME lib/browserwin.ad
#      the on-device browser paints with.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
fail=0

echo "[url-host] compiling URL hit-test unit test (x86_64-linux) ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamurl_host.ad -o "$OUT/hamurl_host" 2>"$OUT/url_compile.log"; then
    echo "[url-host] FAIL: unit test did not compile"; cat "$OUT/url_compile.log"; exit 1
fi

echo "[url-host] compiling NATIVE hambrowse (URL caret nav + clipboard) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/url_native.log"; then
    echo "[url-host] FAIL: native hambrowse did not compile"; cat "$OUT/url_native.log"; exit 1
fi
echo "[url-host] PASS native hambrowse still compiles"

echo "[url-host] compiling host window compositor harness ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_gfx_window.ad -o "$OUT/hambrowse_gfx_window" \
        2>"$OUT/url_win_compile.log"; then
    echo "[url-host] FAIL: gfx_window did not compile"; cat "$OUT/url_win_compile.log"; exit 1
fi

DUMP="$OUT/url_dump.txt"
if ! "$OUT/hamurl_host" >"$DUMP" 2>&1; then
    echo "[url-host] unit test reported failures:"; cat "$DUMP"; exit 1
fi
cat "$DUMP"
grep -q "^\[url-host\] RESULT PASS" "$DUMP" || { echo "[url-host] FAIL: RESULT PASS missing"; fail=1; }
grep -q "^FAIL " "$DUMP" && { echo "[url-host] FAIL: an assertion failed"; fail=1; }

# Host PNG: focus the URL bar + highlight [7,22) = "tests/fixtures/" of the
# fixture URL (args 8/9 = sel_lo sel_hi).
FIX="tests/fixtures/hambrowse_img.html"
if "$OUT/hambrowse_gfx_window" "$FIX" "$OUT/url_sel.ppm" 880 600 0 0 7 22 \
        >"$OUT/url_render.log" 2>&1; then
    if python3 scripts/ppm_to_png.py "$OUT/url_sel.ppm" "$OUT/url_sel.png" \
            2>>"$OUT/url_render.log"; then
        echo "[url-host] PASS rendered $OUT/url_sel.png (URL selection band)"
    else
        echo "[url-host] FAIL png conversion"; cat "$OUT/url_render.log"; fail=1
    fi
else
    echo "[url-host] FAIL: window render exited non-zero"; cat "$OUT/url_render.log"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[url-host] OVERALL FAIL"; exit 1; fi
echo "[url-host] OVERALL PASS"
