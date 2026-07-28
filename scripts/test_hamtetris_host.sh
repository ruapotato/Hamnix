#!/usr/bin/env bash
# scripts/test_hamtetris_host.sh — FAST, QEMU-free host gate for the Tetris
# scene app (lib/hamtetriscore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Mirrors scripts/test_hamsnake_host.sh: it compiles the
# app's core for the x86_64-linux host target, renders the well to PNGs a
# human/agent can LOOK at, drives SCRIPTED input (keyboard wire lines + ticks +
# an on-screen button), asserts the game state evolved (piece moves, rotates,
# gravity drops it, a full row clears + scores, spawning into a blocked top is
# game over, New restarts), AND confirms the NATIVE Hamnix build still compiles
# from the same core — all in milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only — no image tools).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamtetris_host"
mkdir -p "$OUT"
fail=0

echo "[tetris-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamtetrisscene_host.ad "$BIN" 2>"$OUT/tetris_compile.log"; then
    echo "[tetris-host] FAIL: host harness did not compile"; cat "$OUT/tetris_compile.log"; exit 1
fi
echo "[tetris-host] PASS host harness compiled -> $BIN"

echo "[tetris-host] compiling NATIVE hamtetrisscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamtetrisscene.ad "$OUT/hamtetris_native.elf" 2>"$OUT/tetris_native.log"; then
    echo "[tetris-host] FAIL: native hamtetrisscene did not compile"; cat "$OUT/tetris_native.log"; exit 1
fi
echo "[tetris-host] PASS native hamtetrisscene still compiles (device dual-target intact)"

echo "[tetris-host] running host harness ..."
DUMP="$OUT/tetris_dump.txt"
BEFORE="$OUT/tetris_before.ppm"
AFTER="$OUT/tetris_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[tetris-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/tetris_$f.ppm" "$OUT/tetris_$f.png" 2>"$OUT/tetris_png.log"; then
        echo "[tetris-host] PASS rendered $OUT/tetris_$f.png ($(file -b "$OUT/tetris_$f.png" 2>/dev/null))"
    else
        echo "[tetris-host] FAIL png conversion ($f)"; cat "$OUT/tetris_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[tetris-host] PASS $msg"
    else
        echo "[tetris-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Layout / build assertions (on the raw scene display list) -----------
assert_grep '^# scene v1 hamui'                   "scene header emitted"
assert_grep '^fill 0 0 360 470 #1b1b2e'           "full-window navy backdrop"
assert_grep '^fill 90 56 180 360 #101024'         "well backing panel at expected geometry"
assert_grep '^glyphs 12 14 \"Tetris\" #e8e8f0 b'  "bold title 'Tetris' at header"
assert_grep '^glyphs 90 16 \"Score 0'             "live score readout starts at 0"
assert_grep '^fill 91 399 16 16 #ff5252'          "locked Z-red block at cell (0,19)"
assert_grep '^fill 145 75 16 16 #23d6d6'          "falling I-piece cell (3,1) drawn cyan"
assert_grep '^glyphs 175 439 \"Rot\"'             "Rot control button label"
assert_grep '^glyphs 315 439 \"Drop\"'            "Drop control button label"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([2-9][0-9]|[1-9][0-9][0-9])' "rasterizer drew the scene primitives"
assert_grep '^PIX 4 4 #1b1b2e'                    "raster backdrop pixel = navy"
assert_grep '^PIX 95 241 #101024'                 "raster empty well cell = dark well"
assert_grep '^PIX 95 403 #ff5252'                 "raster locked block = Z-red"
assert_grep '^PIX 149 79 #23d6d6'                 "raster falling I cell = cyan"

# --- Initial state -------------------------------------------------------
assert_grep '^CURPIECE0 0'                        "forced falling piece = I"
assert_grep '^CURX0 3'                            "falling piece spawn origin x = 3"
assert_grep '^SCORE0 0'                           "initial score is 0"
assert_grep '^GAMEOVER0 0'                        "game starts live"

# --- Control button hit-test ---------------------------------------------
assert_grep '^BTNAT_180_440 2'                    "pointer press hit-tests the Rot button (index 2)"

# --- MOVE / ROTATE / GRAVITY ---------------------------------------------
assert_grep '^KEYMOVE 1'                          "keyboard 'a' moved the piece"
assert_grep '^CURX1 2'                            "left move decremented the piece origin x"
assert_grep '^ROT 1'                              "rotate accepted (with wall kick if needed)"
assert_grep '^CURROT1 1'                          "rotation state advanced to 1"
assert_grep '^DROPPED_ONE 1'                      "a gravity tick dropped the piece exactly one row"

# --- LINE CLEAR + SCORING ------------------------------------------------
assert_grep '^CLR_LINES 1'                        "completing the bottom row cleared exactly one line"
assert_grep '^CLR_SCORE 40'                       "single-line clear scored 40 (level 0)"
assert_grep '^CELL_0_19_AFTER 0'                  "cleared row was removed + rows shifted down"

# --- GAME OVER on a blocked spawn ----------------------------------------
assert_grep '^SPAWN_BLOCKED_GAMEOVER 1'           "spawning into a stacked top ends the game"
assert_grep '^DEAD_TICK 0'                        "a tick while dead is a no-op"

# --- RESTART clears game over --------------------------------------------
assert_grep '^NEW_GAMEOVER 0'                     "New clears game over"
assert_grep '^NEW_SCORE 0'                        "New resets the score"
assert_grep '^NEW_LINES 0'                        "New resets the line count"

# --- Non-blank PNG (a healthy count of non-background pixels) -------------
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
bg=(0x1b,0x1b,0x2e); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>12 or abs(px[k+1]-bg[1])>12 or abs(px[k+2]-bg[2])>12: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=300 else 1)
PY
then
    echo "[tetris-host] PASS frame is non-blank (well + piece + block + HUD pixels present)"
else
    echo "[tetris-host] FAIL frame looks blank"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[tetris-host] RESULT: PASS"
    exit 0
else
    echo "[tetris-host] RESULT: FAIL"
    exit 1
fi
