#!/usr/bin/env bash
# scripts/test_hamsdl_font_host.sh — FAST, QEMU-free host gate for the hamSDL/
# hamGame TEXT renderer (the pygame.font.Font(...).render gap: hamGame could
# blit sprite Surfaces but had no way to rasterize a STRING into one).
#
# It adds an 8x16 monospace bitmap-font renderer (lib/hamfont.ad — the SAME VGA
# ROM glyph table the GOP console draws) wired through hamGame's
# game_render_text (text -> new fg-on-transparent Surface) and the one-call
# game_surface_draw_text convenience (render + game_surface_blit). The gate
# renders "Hi 42" in green and "42" in blue onto a red display Surface,
# rasterizes to a PPM/PNG a human/agent can LOOK at, and asserts UNFORGEABLE
# facts: green strokes exist inside the text box, red background shows through
# BETWEEN strokes (fg-on-transparent, not a filled block), the text lands at the
# requested (x,y) offset (nothing above/left of it), and a second colour renders
# distinctly (blue where blue was drawn, no colour bleed). It also recompiles the
# NATIVE x86_64-adder-user build so the dual-target seam can't rot. All in
# milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsdl_font_host"
PPM="$OUT/hamsdl_font.ppm"
PNG="$OUT/hamsdl_font.png"
DUMP="$OUT/hamsdl_font_dump.txt"
mkdir -p "$OUT"
fail=0

# ---- 1. Compile the host harness -----------------------------------------
echo "[font-host] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsdl_font_host.ad "$BIN" 2>"$OUT/hamsdl_font_compile.log"; then
    echo "[font-host] FAIL: host harness did not compile"; cat "$OUT/hamsdl_font_compile.log"; exit 1
fi
echo "[font-host] PASS host harness compiled -> $BIN"

# ---- 2. Native dual-target compile (lib/hamfont + hamgame on device) -----
echo "[font-host] compiling NATIVE hamgamedemo (exercises lib/hamfont + hamgame) ..."
if ! adder_bin x86_64-adder-user user/hamgamedemo.ad "$OUT/hamgamedemo_font_native.elf" 2>"$OUT/hamsdl_font_native.log"; then
    echo "[font-host] FAIL: native build did not compile"; cat "$OUT/hamsdl_font_native.log"; exit 1
fi
echo "[font-host] PASS native build still compiles (device dual-target intact)"

# ---- 3. Run the harness --------------------------------------------------
echo "[font-host] running text-render harness ..."
if ! "$BIN" "$PPM" >"$DUMP" 2>&1; then
    echo "[font-host] FAIL: harness exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/hamsdl_font_png.log"; then
    echo "[font-host] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[font-host] FAIL png conversion"; cat "$OUT/hamsdl_font_png.log"; fail=1
fi

kv() { awk -v k="$1" '$1==k{print $2}' "$DUMP"; }

assert_eq() {
    local key="$1" want="$2" msg="$3" got
    got="$(kv "$key")"
    if [ "$got" = "$want" ]; then
        echo "[font-host] PASS $msg ($key=$got)"
    else
        echo "[font-host] FAIL $msg ($key: want $want, got '$got')"; fail=1
    fi
}

assert_range() {
    local key="$1" lo="$2" hi="$3" msg="$4" got
    got="$(kv "$key")"
    if [ -n "$got" ] && [ "$got" -ge "$lo" ] && [ "$got" -le "$hi" ]; then
        echo "[font-host] PASS $msg ($key=$got in [$lo,$hi])"
    else
        echo "[font-host] FAIL $msg ($key=$got not in [$lo,$hi])"; fail=1
    fi
}

# --- Surface: text rasterized into a correctly-sized Surface ---------------
assert_eq TXT  0  "text rasterized into a Surface"
assert_eq TXTW 40 "text Surface width = 8px * 5 glyphs (Hi 42)"
assert_eq TXTH 16 "text Surface height = 8x16 glyph cell"
assert_eq PRIMS 1 "frame rasterized one image primitive"

# --- Foreground: green strokes exist, but it is NOT a filled block ---------
# Text box is 40x16 = 640 px. A monospace string of strokes+gaps fills a small
# fraction: enough to be legible, far from a solid rectangle.
assert_range GREEN_N 40 400 "green glyph strokes present (not blank, not a filled block)"

# --- Transparency: red background shows through inside the text box ---------
# The rest of the 640-px box stays red (fg-on-transparent render).
assert_range RED_IN_BOX 240 600 "red background shows through between/around glyphs"

# --- Offset: text lands at the requested (x,y); nothing above or left -------
assert_range GREEN_MINX 8 15 "leftmost green stroke is at the blit offset (first glyph cell)"
assert_range GREEN_MINY 8 14 "topmost green stroke is at/below the blit offset (glyph cell top)"
assert_eq ABOVE_NONRED 0 "nothing rendered above the text offset (all red)"
assert_eq LEFT_NONRED  0 "nothing rendered left of the text offset (all red)"

# --- Colour: the second string renders distinctly in blue ------------------
assert_range BLUE_N 15 250 "blue glyph strokes present in the second string"
assert_eq GREEN_IN_BLUEBOX 0 "no green bled into the blue string"
assert_eq BLUE_IN_GREENBOX 0 "no blue bled into the green string"

# --- Non-blank PNG (a healthy count of non-background pixels) ---------------
if python3 - "$PPM" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
assert d[:2]==b'P6'
i=2; vals=[]
while len(vals)<3:
    while i<len(d) and d[i] in b' \t\n\r': i+=1
    if d[i:i+1]==b'#':
        while i<len(d) and d[i] not in b'\n': i+=1
        continue
    s=i
    while i<len(d) and d[i] not in b' \t\n\r': i+=1
    vals.append(int(d[s:i]))
w,h,mx=vals; i+=1; px=d[i:]
bg=(0xff,0x00,0x00); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>40 or abs(px[k+1]-bg[1])>40 or abs(px[k+2]-bg[2])>40: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=40 else 1)   # glyph strokes for two strings, well over 40
PY
then
    echo "[font-host] PASS frame is non-blank (glyph strokes present in the raster)"
else
    echo "[font-host] FAIL frame looks blank"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[font-host] RESULT: PASS"
    exit 0
else
    echo "[font-host] RESULT: FAIL"
    exit 1
fi
