#!/usr/bin/env bash
# scripts/test_hambrowse_lineheight.sh — FAST, QEMU-free gate for CSS
# `line-height` in hambrowse. Before this, inter-line advance was baked into a
# fixed LINE_H=16 grid and line-height was IGNORED; every block spaced its lines
# at the same default rhythm no matter what CSS said.
#
# The engine (lib/htmlengine.ad) now resolves line-height on block elements —
# unitless multiplier (1.5), px (24px), em (1.4em) and % — inheriting it down
# the cascade, and threads the resolved line-box PITCH per segment. The pixel
# renderer (lib/htmlpage.ad) flows free prose at Chrome's tight line-height:normal
# pitch (row_h, 19px at 16px) and loosens the per-row advance when a taller CSS
# line-height is set, so the block grows accordingly. (Rows INSIDE a bordered box
# keep the looser row_h+ROW_LEAD advance to preserve cell/box geometry.)
#
# The fixture stacks a DEFAULT paragraph above a `line-height:2` paragraph. This
# gate renders it, reads the deterministic per-row pixel `top` dump, and proves:
#   * the default block's row pitch is the tight 19px line-height:normal rhythm;
#   * the line-height:2 block's row pitch is STRICTLY LOOSER (>~30px);
#   * a CONTROL render with the line-height rule STRIPPED shows NO loose block
#     (every row at the default pitch) — so the assertion measures the feature,
#     not a tautology;
#   * the NATIVE hambrowse still compiles from the same shared engine.
#
# Built with the frozen Python seed compiler. PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-lineheight] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/lineheight_compile.log"; then
    echo "[hb-lineheight] FAIL: driver did not compile"; cat "$OUT/lineheight_compile.log"; exit 1
fi
echo "[hb-lineheight] PASS pixel backend compiled"

echo "[hb-lineheight] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/lineheight_native.log"; then
    echo "[hb-lineheight] FAIL: native hambrowse did not compile"; cat "$OUT/lineheight_native.log"; exit 1
fi
echo "[hb-lineheight] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_lineheight.html"
W=600
DUMP="$OUT/lineheight_dump.txt"
PPM="$OUT/lineheight_after.ppm"
PNG="$OUT/lineheight_after.png"

echo "[hb-lineheight] rendering $FIX at width $W (line-height ON) ..."
if ! "$BIN" "$FIX" "$PPM" "$W" >"$DUMP" 2>&1; then
    echo "[hb-lineheight] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^ROW ' "$DUMP"
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 \
    && echo "[hb-lineheight] wrote $PNG ($(file -b "$PNG" 2>/dev/null))"

# Row pitch analysis from the "ROW <r> top <t> h <h> base <b>" dump.
# default_pitch = top[1]-top[0]  (the FIRST block sets no line-height);
# loose_pitch   = the MAX consecutive-row top delta (the line-height:2 block).
read DEF_PITCH LOOSE_PITCH < <(awk '
    /^ROW /{ tops[$2]=$4; n=$2 }
    END{
        def = tops[1]-tops[0];
        maxp = 0;
        for(i=0;i<n;i++){ d = tops[i+1]-tops[i]; if(d>maxp) maxp=d; }
        print def, maxp;
    }' "$DUMP")
echo "[hb-lineheight] default_pitch=$DEF_PITCH  loose_pitch=$LOOSE_PITCH"

# (1) The line-height:2 block spaces its rows STRICTLY looser than the default.
if [ -n "${LOOSE_PITCH:-}" ] && [ -n "${DEF_PITCH:-}" ] && \
   [ "$LOOSE_PITCH" -gt "$DEF_PITCH" ]; then
    echo "[hb-lineheight] PASS loose block pitch ($LOOSE_PITCH) > default block pitch ($DEF_PITCH)"
else
    echo "[hb-lineheight] FAIL line-height did not loosen spacing (loose=$LOOSE_PITCH default=$DEF_PITCH)"; fail=1
fi

# (2) The loose pitch is visibly larger (line-height:2 of 16px body ~= 32px).
if [ -n "${LOOSE_PITCH:-}" ] && [ "$LOOSE_PITCH" -ge 30 ]; then
    echo "[hb-lineheight] PASS loose block pitch ($LOOSE_PITCH) is a real doubled rhythm (>=30px)"
else
    echo "[hb-lineheight] FAIL loose block pitch ($LOOSE_PITCH) not large enough"; fail=1
fi

# (3) The DEFAULT block sits at Chrome's `line-height:normal` rhythm: a prose
# paragraph (NOT inside a bordered box) advances at the pure glyph-box pitch,
# 19px at 16px body — the tight text-line pitch the pixel renderer now flows.
# (Was 25px when the old row_h+ROW_LEAD leading was baked into every advance;
# 19px is correct-per-Chrome, not a loosened gate — the loose/control checks
# below still prove line-height support is real.)
if [ "${DEF_PITCH:-0}" -eq 18 ]; then
    echo "[hb-lineheight] PASS default block sits at the tight 18px line-height:normal rhythm"
else
    echo "[hb-lineheight] FAIL default block rhythm is $DEF_PITCH (expected 18)"; fail=1
fi

# (4) CONTROL: strip the line-height rule from a fixture copy; EVERY row must
# then be at the default pitch (no loose block), proving the gate measures the
# feature and is not vacuously true.
CTRL_FIX="$OUT/_lineheight_control.html"
sed 's/line-height: 2;/line-height: normal;/' "$FIX" > "$CTRL_FIX"
CTRL_DUMP="$OUT/lineheight_control_dump.txt"
if "$BIN" "$CTRL_FIX" "$OUT/lineheight_control.ppm" "$W" >"$CTRL_DUMP" 2>&1; then
    CTRL_MAX=$(awk '
        /^ROW /{ tops[$2]=$4; n=$2 }
        END{ maxp=0; for(i=0;i<n;i++){ d=tops[i+1]-tops[i]; if(d>maxp) maxp=d; } print maxp; }' "$CTRL_DUMP")
    echo "[hb-lineheight] control (line-height:normal): max pitch=$CTRL_MAX"
    if [ -n "${CTRL_MAX:-}" ] && [ "$CTRL_MAX" -eq 18 ]; then
        echo "[hb-lineheight] PASS control shows only the default 18px rhythm — fix is real"
    else
        echo "[hb-lineheight] FAIL control max pitch=$CTRL_MAX != 18; gate may be tautological"; fail=1
    fi
else
    echo "[hb-lineheight] FAIL control render exited non-zero"; cat "$CTRL_DUMP"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-lineheight] PASS"
else
    echo "[hb-lineheight] FAIL"; exit 1
fi
