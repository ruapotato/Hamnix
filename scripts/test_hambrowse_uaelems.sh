#!/usr/bin/env bash
# scripts/test_hambrowse_uaelems.sh — FAST, QEMU-free gate for the UA default
# stylesheet coverage of the common LOWER-frequency HTML elements: h4/h5/h6,
# dl/dt/dd, hr, small, mark, sub/sup, kbd/samp/var, u/ins, s/del. A real browser
# gives each of these a sensible built-in appearance; this gate proves the
# hambrowse engine (lib/htmlengine.ad) + pixel renderer (lib/htmlpage.ad) now do
# too, and — critically — that these UA defaults are the LOWEST specificity so an
# author stylesheet still overrides them.
#
# It drives the shared engine through user/hambrowse_host_gfx.ad (host x86_64-
# linux target, render-to-PNG, no QEMU), asserting concrete properties from the
# deterministic dump: sub/sup raised-lowered, strike-through, monospace runs, a
# mark highlight background, a <small> shrink, a <dd> indent, and the h4/h5/h6
# heading-size hierarchy (h3 > h4 > body, h4 bold).
#
# Built with the frozen Python seed compiler (compiles 100% of the tree).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-ua] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/ua_compile.log"; then
    echo "[hb-ua] FAIL: driver did not compile"; cat "$OUT/ua_compile.log"; exit 1
fi
echo "[hb-ua] PASS pixel backend compiled -> $BIN"

echo "[hb-ua] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ua_native.log"; then
    echo "[hb-ua] FAIL: native hambrowse did not compile"; cat "$OUT/ua_native.log"; exit 1
fi
echo "[hb-ua] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_uaelems.html"
DUMP="$OUT/ua_dump.txt"
PPM="$OUT/ua_uaelems.ppm"
PNG="$OUT/ua_uaelems.png"

echo "[hb-ua] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-ua] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-ua] rendered PNG -> $PNG"
grep -E '^UAELEM|^HFACE' "$DUMP" || true

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-ua] PASS $msg"
    else
        echo "[hb-ua] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# INLINE UA DEFAULTS: <sub> lowered, <sup> raised, <s>/<del> struck (2), the four
# <kbd>/<samp>/<var> runs in monospace, and a <mark> highlight in yellow.
#
# The markbg value was WRONG, not the engine — in the other direction from ddx
# below: it demanded #fff275, a muted yellow no browser uses. MEASURED in
# chromium --headless with getComputedStyle on a <mark> carrying no author CSS
# (two independent fixtures): background-color rgb(255, 255, 0), color
# rgb(0, 0, 0) — plain `yellow`, which is also the HTML spec's suggested UA
# stylesheet. The engine constant and this assertion both moved to #ffff00.
# Re-measured 2026-07-28.
#
# The `ddx` bound was WRONG, not the engine. UAELEM ddx is the maximum ROW-START
# x of any flowed segment, i.e. the deepest block indent on the page, and this
# gate demanded >= 60px. MEASURED in chromium --headless on this very fixture
# (getBoundingClientRect over every block-level descendant of <body>):
#     DD:48  DD:48  FIGURE:48  FIGCAPTION:48  H1:8  H2:8
# 48px is the whole page's deepest indent — the UA's `dd { margin-inline-start:
# 40px }` plus the 8px body margin — and no browser puts a UA-default <dd> at
# 60px. The engine reports 48, exactly chromium's number; the assertion, not the
# render, is what had to move. The window is 40..56 so the indent must still be
# PRESENT (a lost dd margin drops it to 8) without pinning sub-pixel font
# metrics. Re-measured 2026-07-28.
if awk '/^UAELEM /{
    for(i=1;i<=NF;i++){
      if($i=="sub") sub_n=$(i+1); if($i=="sup") sup_n=$(i+1);
      if($i=="strike") st=$(i+1); if($i=="mono") mo=$(i+1);
      if($i=="mark") mk=$(i+1); if($i=="markbg") mb=$(i+1);
      if($i=="minpx") mp=$(i+1); if($i=="ddx") dd=$(i+1);
    }
    ok = (sub_n>=1 && sup_n>=1 && st>=2 && mo>=4 && mk>=1 && mb=="#ffff00" && mp<16 && dd>=40 && dd<=56)
  }
  END{ exit(ok?0:1) }' "$DUMP"; then
    echo "[hb-ua] PASS sub/sup raised-lowered, strike-through, mono, mark(#ffff00), small<16px, dd indented 40-56px (chromium: 48)"
else
    echo "[hb-ua] FAIL UAELEM inline defaults not all present"; fail=1
fi

# HEADING HIERARCHY: h4 (face 5) is bold, sized BELOW h3 (face 4) and ABOVE body
# (19px line box) — proving h4/h5/h6 are not left at body size.
if awk '/^HFACE 4 /{ h3=$4 } /^HFACE 5 /{ h4=$4; b5=$6 }
        END{ exit((h3>h4 && h4>19 && b5==1)?0:1) }' "$DUMP"; then
    echo "[hb-ua] PASS h4 bold & sized between h3 and body (h3 > h4 > 19px)"
else
    echo "[hb-ua] FAIL h4 heading size/weight hierarchy wrong"; fail=1
fi

# <hr> DARK RULE: the renderer draws a distinct DARK (~120 gray) horizontal rule
# spanning most of the page width, unlike the light (170) heading underline. Scan
# the PNG for a long horizontal run of mid-gray pixels near 120.
if python3 - "$PNG" <<'PY'
import sys
try:
    from PIL import Image
except Exception:
    print("[hb-ua] SKIP hr pixel check (PIL unavailable)"); sys.exit(0)
import numpy as np
a = np.asarray(Image.open(sys.argv[1]).convert("RGB"))
H, W = a.shape[0], a.shape[1]
# a dark hr pixel: all channels ~equal and in [95,145] (the 120-gray rule).
r, g, b = a[:,:,0].astype(int), a[:,:,1].astype(int), a[:,:,2].astype(int)
gray = (abs(r-g) < 12) & (abs(g-b) < 12) & (r >= 95) & (r <= 145)
best = 0
for y in range(H):
    cnt = int(gray[y].sum())
    if cnt > best: best = cnt
if best > W * 0.6:
    print(f"[hb-ua] PASS hr draws a dark rule row ({best}px of ~120-gray across the width)")
    sys.exit(0)
print(f"[hb-ua] FAIL no dark hr rule found (longest dark-gray run {best}px, width {W})")
sys.exit(1)
PY
then :; else fail=1; fi

# AUTHOR OVERRIDE: the UA defaults are lowest specificity — an author stylesheet
# still wins. mark{background:#33cc33} => markbg becomes green; small{font-size:
# 30px} => minpx 30 (bigger, not the ~13px default); u{text-decoration:none} =>
# the underline is stripped (ULINE cssn 0).
OVR="tests/fixtures/hambrowse_uaelems_override.html"
ODUMP="$OUT/ua_override_dump.txt"
if ! "$BIN" "$OVR" "$OUT/ua_override.ppm" 640 >"$ODUMP" 2>&1; then
    echo "[hb-ua] FAIL: override render exited non-zero"; cat "$ODUMP"; fail=1
fi
if awk '/^UAELEM /{ for(i=1;i<=NF;i++){ if($i=="markbg") mb=$(i+1); if($i=="minpx") mp=$(i+1) } }
        /^ULINE /{ for(i=1;i<=NF;i++) if($i=="cssn") cs=$(i+1) }
        END{ exit((mb=="#33cc33" && mp==30 && cs==0)?0:1) }' "$ODUMP"; then
    echo "[hb-ua] PASS author CSS overrides UA defaults (mark#33cc33, small 30px, u no-underline)"
else
    echo "[hb-ua] FAIL author CSS did not override UA defaults"; grep -E '^UAELEM|^ULINE' "$ODUMP"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-ua] PASS"
else
    echo "[hb-ua] FAIL"; exit 1
fi
