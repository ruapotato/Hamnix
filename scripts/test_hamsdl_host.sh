#!/usr/bin/env bash
# scripts/test_hamsdl_host.sh — FAST, QEMU-free host gate for hamSDL, the
# SDL2-flavored native game library (lib/hamsdl.ad + lib/hamsdl_dev.ad +
# lib/hamsdl_host.ad) and its demo game (lib/sdlpong.ad). Mirrors
# scripts/test_ham2048_host.sh: it compiles the demo's HOST harness for the
# x86_64-linux target, renders game frames to PNGs a human/agent can LOOK at,
# drives SCRIPTED input (raw queue + real DE wire lines through the shared
# parser), and asserts the frame layout/colour, that the world ADVANCES
# (timing/update), and that INPUT changes state — all in milliseconds, no QEMU.
# It also confirms the NATIVE (x86_64-adder-user) device build still compiles
# from the same library, so the dual-target seam can't silently rot.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree).
# PNG conversion uses scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/sdlpong_host"
mkdir -p "$OUT"
fail=0

echo "[hamsdl-host] compiling demo host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/sdlpong_host.ad "$BIN" 2>"$OUT/hamsdl_compile.log"; then
    echo "[hamsdl-host] FAIL: host harness did not compile"; cat "$OUT/hamsdl_compile.log"; exit 1
fi
echo "[hamsdl-host] PASS host harness compiled -> $BIN"

echo "[hamsdl-host] compiling NATIVE sdlpong for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/sdlpong.ad "$OUT/sdlpong_native.elf" 2>"$OUT/hamsdl_native.log"; then
    echo "[hamsdl-host] FAIL: native sdlpong did not compile"; cat "$OUT/hamsdl_native.log"; exit 1
fi
echo "[hamsdl-host] PASS native sdlpong still compiles (device dual-target intact)"

echo "[hamsdl-host] running demo host harness ..."
DUMP="$OUT/hamsdl_dump.txt"
BEFORE="$OUT/hamsdl_before.ppm"
AFTER="$OUT/hamsdl_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[hamsdl-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hamsdl_$f.ppm" "$OUT/hamsdl_$f.png" 2>"$OUT/hamsdl_png.log"; then
        echo "[hamsdl-host] PASS rendered $OUT/hamsdl_$f.png ($(file -b "$OUT/hamsdl_$f.png" 2>/dev/null))"
    else
        echo "[hamsdl-host] FAIL png conversion ($f)"; cat "$OUT/hamsdl_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hamsdl-host] PASS $msg"
    else
        echo "[hamsdl-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Scene display list (proves the hamSDL drawing verbs emit correctly) ---
assert_grep '^# scene v1 hamui'                    "scene header emitted"
assert_grep '^fill 0 0 320 360 #141a26'            "sdl_clear filled the window backdrop"
assert_grep '^glyphs 10 8 \"hamSDL Pong\" #e6ecf5 b' "bold title HUD text"
assert_grep '^glyphs 10 26 \"Score\"'              "Score HUD label"
assert_grep '^line 0 42 320 42 1'                  "field divider line"
assert_grep '^roundrect 154 40 12 12 3 #f0d25a'    "ball rounded rect (gold)"
assert_grep '^roundrect 128 330 64 12 4 #5ac878'   "paddle rounded rect (green)"

# --- Rasterizer sampled pixels (proves lib/hamui_host actually drew it) ----
assert_grep '^PRIMS ([7-9]|[1-9][0-9])'            "rasterizer drew the frame primitives"
assert_grep '^PIX 0 0 #141a26'                     "raster backdrop pixel = dark navy"
assert_grep '^PIX 160 46 #f0d25a'                  "raster ball pixel = gold"
assert_grep '^PIX 160 336 #5ac878'                 "raster paddle pixel = green"

# --- Non-blank PNG (a healthy count of non-background pixels) ---------------
if python3 - "$BEFORE" <<'PY'
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
bg=(0x14,0x1a,0x26); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>10 or abs(px[k+1]-bg[1])>10 or abs(px[k+2]-bg[2])>10: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=400 else 1)
PY
then
    echo "[hamsdl-host] PASS frame is non-blank (ball + paddle + HUD pixels present)"
else
    echo "[hamsdl-host] FAIL frame looks blank"; fail=1
fi

# --- TIMING / update: the world ADVANCES (ball moves every tick) -----------
if grep -Eq '^MOVED ([3-9][0-9]|40)' "$DUMP"; then
    echo "[hamsdl-host] PASS timing/update advances the world (ball moved most/all of 40 ticks)"
else
    echo "[hamsdl-host] FAIL ball did not advance across ticks"; fail=1
fi

# --- INPUT (raw queue): 3 KEYDOWN LEFT slid the paddle left ----------------
PX0=$(awk '/^PADDLEX0 /{print $2}' "$DUMP")
PX1=$(awk '/^PADDLEX1 /{print $2}' "$DUMP")
if [ -n "$PX0" ] && [ -n "$PX1" ] && [ "$PX1" -lt "$PX0" ]; then
    echo "[hamsdl-host] PASS raw-queue KEYDOWN LEFT moved paddle: $PX0 -> $PX1"
else
    echo "[hamsdl-host] FAIL paddle did not move left on KEYDOWN (x0=$PX0 x1=$PX1)"; fail=1
fi

# --- INPUT (wire parser): an ESC-[-C sequence decoded to SDLK_RIGHT --------
assert_grep '^ARROWRIGHT 1'                        "DE wire parser decoded the RIGHT-arrow escape sequence"
PX2=$(awk '/^PADDLEX2 /{print $2}' "$DUMP")
if [ -n "$PX2" ] && [ -n "$PX1" ] && [ "$PX2" -gt "$PX1" ]; then
    echo "[hamsdl-host] PASS RIGHT-arrow moved paddle back right: $PX1 -> $PX2"
else
    echo "[hamsdl-host] FAIL RIGHT-arrow did not move paddle (x1=$PX1 x2=$PX2)"; fail=1
fi

# --- INPUT (pointer parser): a left-click edge became a BUTTONDOWN event ---
assert_grep '^CLICKDOWN 1'                         "pointer parser raised MOUSEBUTTONDOWN on the click edge"
assert_grep '^CLICKX 50'                           "MOUSEBUTTONDOWN carried the click x coordinate"

# --- GAMEPLAY: a descending ball onto the paddle scores a save -------------
assert_grep '^SCOREHIT_BEFORE 0'                   "no score before the save"
assert_grep '^SCOREHIT_AFTER 1'                    "paddle save incremented the score (gameplay works)"

if [ "$fail" -eq 0 ]; then
    echo "[hamsdl-host] RESULT: PASS"
    exit 0
else
    echo "[hamsdl-host] RESULT: FAIL"
    exit 1
fi
