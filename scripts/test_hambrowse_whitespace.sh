#!/usr/bin/env bash
# scripts/test_hambrowse_whitespace.sh — FAST, QEMU-free gate for the CSS
# `white-space` property in hambrowse. Before this, `white-space` was an
# UNHONOURED property: normal / nowrap / pre / pre-wrap all rendered identically
# (whitespace collapsed, prose wrapped at the viewport). Only the <pre>/<code>
# ELEMENT preserved whitespace, via its monospace-grid pre_mode path.
#
# The engine (lib/htmlengine.ad) now resolves `white-space` on any element and
# inherits it down the cascade:
#   * normal   — collapse whitespace runs to one space, soft-wrap at the measure
#   * nowrap   — collapse, but NEVER wrap (the line overflows the viewport)
#   * pre      — preserve spaces + newlines, never wrap (overflows)
#   * pre-wrap — preserve spaces + newlines, but DO wrap at the measure
# The <pre>/<code> element path is untouched, so unstyled pages are unchanged.
#
# ONE fixture (tests/fixtures/hambrowse_whitespace.html) carries a `.ws`
# paragraph with runs of spaces + a source newline + a line far longer than the
# narrow 400px viewport. The gate renders it FOUR times, sed-swapping the
# white-space value, reads the deterministic "REFLOW pw <> maxx <> overflow <>
# textrows <>" dump, and proves each mode's distinct pixel behaviour — with the
# `normal` render doubling as the CONTROL (wraps, no overflow) so the nowrap/pre
# overflow assertions are not vacuous.
#
# Built with the frozen Python seed compiler. PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_whitespace.html"
# Viewport width. At 400px the (now Chrome-matched, ~12% narrower) sans metric
# packs the long line2 so tightly that `normal` and `pre-wrap` land on the SAME
# row count, making the "pre-wrap keeps the newline as an extra row" proxy tie by
# coincidence. 620px restores an unambiguous signal — line1 ("alpha beta gamma")
# fits on one row so the preserved newline unambiguously adds a row (normal 3 vs
# pre-wrap 4) — while all four modes still exercise their distinct behaviour
# (normal wraps multi-row/no-overflow; nowrap/pre overflow; pre-wrap wraps).
W=620
mkdir -p "$OUT"
fail=0

echo "[hb-whitespace] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/whitespace_compile.log"; then
    echo "[hb-whitespace] FAIL: driver did not compile"; cat "$OUT/whitespace_compile.log"; exit 1
fi
echo "[hb-whitespace] PASS pixel backend compiled"

echo "[hb-whitespace] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/whitespace_native.log"; then
    echo "[hb-whitespace] FAIL: native hambrowse did not compile"; cat "$OUT/whitespace_native.log"; exit 1
fi
echo "[hb-whitespace] PASS native hambrowse still compiles"

# Render one mode; echo "pw maxx overflow rows" parsed from the REFLOW line.
render_mode() {
    local mode="$1"
    local html="$OUT/_ws_${mode}.html"
    local ppm="$OUT/ws_${mode}.ppm"
    local dump="$OUT/ws_${mode}_dump.txt"
    sed "s/white-space: normal;/white-space: ${mode};/" "$FIX" > "$html"
    if ! "$BIN" "$html" "$ppm" "$W" >"$dump" 2>&1; then
        echo "[hb-whitespace] FAIL: render ($mode) exited non-zero" >&2
        cat "$dump" >&2
        return 1
    fi
    python3 scripts/ppm_to_png.py "$ppm" "$OUT/ws_${mode}.png" >/dev/null 2>&1
    awk '/^REFLOW /{ print $3, $5, $7, $9 }' "$dump"
}

read N_PW N_MAXX N_OVF N_ROWS < <(render_mode normal)   || fail=1
read W_PW W_MAXX W_OVF W_ROWS < <(render_mode nowrap)   || fail=1
read P_PW P_MAXX P_OVF P_ROWS < <(render_mode pre)      || fail=1
read Q_PW Q_MAXX Q_OVF Q_ROWS < <(render_mode pre-wrap) || fail=1

echo "[hb-whitespace] normal   : maxx=$N_MAXX overflow=$N_OVF textrows=$N_ROWS (pw=$N_PW)"
echo "[hb-whitespace] nowrap   : maxx=$W_MAXX overflow=$W_OVF textrows=$W_ROWS (pw=$W_PW)"
echo "[hb-whitespace] pre      : maxx=$P_MAXX overflow=$P_OVF textrows=$P_ROWS (pw=$P_PW)"
echo "[hb-whitespace] pre-wrap : maxx=$Q_MAXX overflow=$Q_OVF textrows=$Q_ROWS (pw=$Q_PW)"
echo "[hb-whitespace] wrote $OUT/ws_{normal,nowrap,pre,pre-wrap}.png"

need() { # need <desc> <cond-value> ; cond-value already 1/0
    if [ "$2" -eq 1 ]; then echo "[hb-whitespace] PASS $1"; else echo "[hb-whitespace] FAIL $1"; fail=1; fi
}

# (0) CONTROL: white-space:normal collapses + wraps — NO overflow, within the
# viewport, and the long line occupies MANY rows. This anchors the comparisons.
need "normal wraps within the viewport (overflow=0, maxx<=pw)" \
     "$([ "${N_OVF:-1}" -eq 0 ] && [ "${N_MAXX:-9999}" -le "${N_PW:-0}" ] && echo 1 || echo 0)"
need "normal wraps the long line to many rows (textrows>=3)" \
     "$([ "${N_ROWS:-0}" -ge 3 ] && echo 1 || echo 0)"

# (1) nowrap: collapses like normal BUT never wraps — one line that OVERFLOWS
# the viewport (maxx far past pw). This is the crux: same content, one row.
need "nowrap stays a single line (textrows=1)" \
     "$([ "${W_ROWS:-0}" -eq 1 ] && echo 1 || echo 0)"
need "nowrap overflows the viewport (overflow>=1 and maxx>pw)" \
     "$([ "${W_OVF:-0}" -ge 1 ] && [ "${W_MAXX:-0}" -gt "${W_PW:-999999}" ] && echo 1 || echo 0)"

# (2) pre: preserves the source NEWLINE (two rows, not merged by wrapping) and
# does NOT wrap the long second line (it overflows). Two rows + overflow is a
# combination NO other mode produces here.
need "pre honours the source newline (textrows=2)" \
     "$([ "${P_ROWS:-0}" -eq 2 ] && echo 1 || echo 0)"
need "pre does not wrap the long line (overflow>=1 and maxx>pw)" \
     "$([ "${P_OVF:-0}" -ge 1 ] && [ "${P_MAXX:-0}" -gt "${P_PW:-999999}" ] && echo 1 || echo 0)"

# (3) pre-wrap: wraps like normal (no overflow, within the viewport) BUT the
# preserved newline forces an extra break, so it uses STRICTLY MORE rows than
# normal — proving whitespace was preserved AND wrapping stayed on.
need "pre-wrap wraps within the viewport (overflow=0, maxx<=pw)" \
     "$([ "${Q_OVF:-1}" -eq 0 ] && [ "${Q_MAXX:-9999}" -le "${Q_PW:-0}" ] && echo 1 || echo 0)"
need "pre-wrap keeps the newline as an extra row (textrows>normal=$N_ROWS)" \
     "$([ "${Q_ROWS:-0}" -gt "${N_ROWS:-999}" ] && echo 1 || echo 0)"

if [ "$fail" -eq 0 ]; then
    echo "[hb-whitespace] PASS"
else
    echo "[hb-whitespace] FAIL"; exit 1
fi
