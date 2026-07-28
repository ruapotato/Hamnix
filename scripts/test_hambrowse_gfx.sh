#!/usr/bin/env bash
# scripts/test_hambrowse_gfx.sh — FAST, QEMU-free gate for the GRAPHICAL
# (pixel) hambrowse backend: lib/htmlpaint.ad (proportional-font canvas) +
# lib/htmlpage.ad (pixel box-model layout) driven by user/hambrowse_host_gfx.ad.
#
# The legacy scripts/test_hambrowse_host.sh asserts the OLD monospace-grid
# geometry (still valid — the parse/CSS/JS front end is unchanged). THIS gate
# asserts the NEW pixel geometry: real per-row pixel heights (an <h1> row is
# physically taller than a body row), PROPORTIONAL advance widths (narrow vs
# wide runs measure differently — impossible on a fixed 8px grid), and that a
# real RGB PNG is produced. It also confirms the NATIVE hambrowse still
# compiles from the same shared engine.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree; no
# self-host bootstrap). PNG conversion uses scripts/ppm_to_png.py (stdlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-gfx] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/gfx_compile.log"; then
    echo "[hb-gfx] FAIL: driver did not compile"; cat "$OUT/gfx_compile.log"; exit 1
fi
echo "[hb-gfx] PASS pixel backend compiled -> $BIN"

echo "[hb-gfx] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/gfx_native.log"; then
    echo "[hb-gfx] FAIL: native hambrowse did not compile"; cat "$OUT/gfx_native.log"; exit 1
fi
echo "[hb-gfx] PASS native hambrowse still compiles"

ART="tests/fixtures/hambrowse_article.html"
DUMP="$OUT/gfx_dump.txt"
PPM="$OUT/gfx_article.ppm"
PNG="$OUT/gfx_article.png"

echo "[hb-gfx] rendering $ART ..."
if ! "$BIN" "$ART" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-gfx] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/gfx_png.log"; then
    echo "[hb-gfx] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-gfx] FAIL png conversion"; cat "$OUT/gfx_png.log"; fail=1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-gfx] PASS $msg"
    else
        echo "[hb-gfx] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Both BDF faces decoded all 95 printable glyphs (legacy proportional store,
# still used for the ADV proportionality proof below).
assert_grep '^FONTS sans=95 mono=95'  "sans + mono BDF faces loaded (95 glyphs each)"

# The SCALABLE TrueType faces parsed cleanly (rc=0) — this is the path that
# gives continuous font-size + anti-aliasing.
assert_grep '^TTF sans_rc=0 bold_rc=0 mono_rc=0 ok=1'  "TrueType faces parsed (sans/bold/mono)"

# The canvas is a real pixel bitmap tall enough for the multi-section article.
# Width may exceed the requested 640 because proportional TrueType text is wider
# than the engine's 8px grid estimate (canvas grows to avoid clipping glyphs).
assert_grep '^CANVAS [0-9]{3,} [0-9]{3,}'   "pixel canvas WxN with a tall page"

# PIXEL BOX MODEL, scalable faces: row 0 is the <h1> at 32px bold (37px line box
# = Chrome line-height:normal round(32*1.15); round 17 capped it from the 38px
# glyph bounding box)
# — physically TALLER than the 16px body rows (19px line box) stacked below it.
assert_grep '^ROW 0 top 12 h 37 base 42'  "h1 row is 37px tall (32px bold TrueType, Chrome line-height:normal; round 17 capped from the 38px glyph box)"
assert_grep '^ROW 1 top 49 h 18 base 64'  "body row is 18px tall (16px TrueType = Chrome line-height:normal; round 17 lowered from the 19px glyph box), below h1 (flush at h1 bottom; UA h1 bottom-margin is a separate follow-up)"

# PROPORTIONAL TEXT (BDF store): a narrow run (iiii) is NARROWER than a wide run
# (WWWW) in the sans face; in mono they are EQUAL. Impossible on a fixed grid.
assert_grep '^ADV sans iiii=20 WWWW=24 mono_iiii=32 mono_WWWW=32' \
    "proportional sans advance (iiii<WWWW) vs fixed mono (equal)"

# CONTINUOUS FONT-SIZE: the SAME string in the SAME TrueType face measures
# strictly WIDER as the em px grows (12<16<18<24). Not 3 discrete bitmap steps.
if awk '/^TTFADV Hamnix/ {
          split($3,a,"="); split($4,b,"="); split($5,c,"="); split($6,d,"=");
          if (a[2] < b[2] && b[2] < c[2] && c[2] < d[2]) ok=1 }
        END { exit(ok?0:1) }' "$DUMP"; then
    echo "[hb-gfx] PASS continuous font-size (12px < 16px < 18px < 24px widths)"
else
    echo "[hb-gfx] FAIL continuous font-size not monotonic in px"; fail=1
fi

# ANTI-ALIASING: the rendered canvas contains many INTERMEDIATE gray pixels
# (grayscale edge coverage) that a 1-bit bitmap font can never produce.
if awk '/^AAGRAY/ { if ($2+0 > 2000) ok=1 } END { exit(ok?0:1) }' "$DUMP"; then
    echo "[hb-gfx] PASS anti-aliased glyph edges (many intermediate gray pixels)"
else
    echo "[hb-gfx] FAIL too few gray pixels — glyphs look 1-bit, not AA"; fail=1
fi

# A real framebuffer was written and the paper is white.
assert_grep '^WROTE [0-9]{6,}'        "framebuffer written to PPM"
assert_grep '^PIX 0 0 #ffffff'        "top-left pixel is white paper"

# UNORDERED LIST as a real browser draws it: each <li> gets a round bullet DISC
# (not a '-' glyph), and its item text HANGS at an indent so the marker sits in
# its own gutter instead of gluing to the text. The fixture's <ul> has 3 items.
assert_grep '^LIST markers 3 '        "three <li> bullet-disc markers rendered"
# The first bullet disc is actually inked (a dark pixel at its centre), not the
# white paper — proving a real disc was painted, not an empty gutter.
if awk '/^LIST /{ for(i=1;i<=NF;i++) if($i=="discpix"){ c=$(i+1); sub(/^#/,"",c);
          v=strtonum("0x" c); if(v < 0x808080) ok=1 } } END{ exit(ok?0:1) }' "$DUMP"; then
    echo "[hb-gfx] PASS bullet disc is inked (dark centre pixel, not white paper)"
else
    echo "[hb-gfx] FAIL bullet disc centre is not inked"; fail=1
fi
# The list item text hangs at a real indent (well past the 8px left pad), i.e.
# the marker gutter survived the proportional reflow (no '-Ship' gluing).
if awk '/^LIST /{ for(i=1;i<=NF;i++) if($i=="itemx" && $(i+1)+0 >= 40) ok=1 }
        END{ exit(ok?0:1) }' "$DUMP"; then
    echo "[hb-gfx] PASS list item text hangs indented (>=40px, marker gutter kept)"
else
    echo "[hb-gfx] FAIL list item text not indented — gutter collapsed"; fail=1
fi

# Sanity: the CSS page renders too (centered heading via text-align).
CSS="tests/fixtures/hambrowse_css.html"
if "$BIN" "$CSS" "$OUT/gfx_css.ppm" 640 >"$OUT/gfx_css_dump.txt" 2>&1 \
        && python3 scripts/ppm_to_png.py "$OUT/gfx_css.ppm" "$OUT/gfx_css.png" 2>/dev/null; then
    echo "[hb-gfx] PASS rendered CSS page -> $OUT/gfx_css.png"
else
    echo "[hb-gfx] FAIL CSS page render"; fail=1
fi

# CONTINUOUS FONT-SIZE page: distinct CSS px classes (11/13/16/20/28px) + inline
# font-size spans must render and produce AA. This is the flagship of the track.
FS="tests/fixtures/hambrowse_fontsize.html"
FSDUMP="$OUT/gfx_fontsize_dump.txt"
if "$BIN" "$FS" "$OUT/gfx_fontsize.ppm" 640 >"$FSDUMP" 2>&1 \
        && python3 scripts/ppm_to_png.py "$OUT/gfx_fontsize.ppm" "$OUT/gfx_fontsize.png" 2>/dev/null; then
    echo "[hb-gfx] PASS rendered font-size page -> $OUT/gfx_fontsize.png"
else
    echo "[hb-gfx] FAIL font-size page render"; cat "$FSDUMP"; fail=1
fi
# The font-size page must also be anti-aliased.
if awk '/^AAGRAY/ { if ($2+0 > 2000) ok=1 } END { exit(ok?0:1) }' "$FSDUMP"; then
    echo "[hb-gfx] PASS font-size page is anti-aliased"
else
    echo "[hb-gfx] FAIL font-size page not anti-aliased"; fail=1
fi

# TABLE CELL PADDING (the exact #171 defect): in the rendered article PNG the
# bordered <table>'s header text ("Subsystem") must sit INSIDE its left border,
# not overlap/collide with the frame. Locate the table's left border (a tall
# vertical dark run), then the first inked header glyph just to its right, and
# assert the glyph starts at least 2px past the border. Guards the padding fix
# against regressing back to zero-inset "text drawn on the border".
if python3 - "$PNG" <<'PY'
import sys
try:
    from PIL import Image
except Exception:
    print("[hb-gfx] SKIP table-padding pixel check (PIL unavailable)"); sys.exit(0)
import numpy as np
a = np.asarray(Image.open(sys.argv[1]).convert("L"))
H, W = a.shape
# tallest vertical dark run => a table border rule; take the leftmost such x.
best_len = 0; border_x = -1; border_y = -1
for x in range(W):
    col = a[:, x] < 128
    cur = start = 0
    for i, v in enumerate(col):
        if v:
            if cur == 0: start = i
            cur += 1
            if cur > 60 and (border_x < 0 or x < border_x):
                border_x = x; border_y = start; break
        else:
            cur = 0
if border_x < 0:
    print("[hb-gfx] FAIL table-padding: no table border found in PNG"); sys.exit(1)
# scan a header-text band a little below the top border for the first inked
# glyph pixel strictly to the RIGHT of the border.
y0 = border_y + 8
band = a[y0:y0+16, border_x+1:border_x+80] < 128
xs = [border_x+1+dx for dx in range(band.shape[1]) if band[:, dx].any()]
if not xs:
    print("[hb-gfx] FAIL table-padding: no header glyph right of the border"); sys.exit(1)
inset = xs[0] - border_x
if inset >= 2:
    print(f"[hb-gfx] PASS table cell text inset {inset}px inside its border "
          f"(border x={border_x}, first glyph x={xs[0]})")
    sys.exit(0)
print(f"[hb-gfx] FAIL table header text touches the border (inset {inset}px)")
sys.exit(1)
PY
then :; else fail=1; fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-gfx] PASS"
else
    echo "[hb-gfx] FAIL"; exit 1
fi
