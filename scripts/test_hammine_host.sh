#!/usr/bin/env bash
# scripts/test_hammine_host.sh — FAST, QEMU-free host gate for the Minesweeper
# scene app (lib/hamminescore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Mirrors scripts/test_hamtetris_host.sh: it compiles the
# app's core for the x86_64-linux host target, renders the field to PNGs a
# human/agent can LOOK at, drives SCRIPTED input, asserts the RULES engine
# (reveal a 0-cell flood-fills, revealing a mine is a loss, uncovering every
# non-mine is a win, New restarts), AND confirms the NATIVE Hamnix build still
# compiles from the same core — all in milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only — no image tools).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hammine_host"
mkdir -p "$OUT"
fail=0

echo "[mine-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamminescene_host.ad "$BIN" 2>"$OUT/mine_compile.log"; then
    echo "[mine-host] FAIL: host harness did not compile"; cat "$OUT/mine_compile.log"; exit 1
fi
echo "[mine-host] PASS host harness compiled -> $BIN"

echo "[mine-host] compiling NATIVE hamminescene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamminescene.ad "$OUT/hammine_native.elf" 2>"$OUT/mine_native.log"; then
    echo "[mine-host] FAIL: native hamminescene did not compile"; cat "$OUT/mine_native.log"; exit 1
fi
echo "[mine-host] PASS native hamminescene still compiles (device dual-target intact)"

echo "[mine-host] running host harness ..."
DUMP="$OUT/mine_dump.txt"
BEFORE="$OUT/mine_before.ppm"
AFTER="$OUT/mine_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[mine-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/mine_$f.ppm" "$OUT/mine_$f.png" 2>"$OUT/mine_png.log"; then
        echo "[mine-host] PASS rendered $OUT/mine_$f.png ($(file -b "$OUT/mine_$f.png" 2>/dev/null))"
    else
        echo "[mine-host] FAIL png conversion ($f)"; cat "$OUT/mine_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[mine-host] PASS $msg"
    else
        echo "[mine-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Layout / build assertions (on the raw scene display list) -----------
assert_grep '^# scene v1 hamui'                    "scene header emitted"
assert_grep '^fill 0 0 360 470 #1b1b2e'            "full-window navy backdrop"
assert_grep '^fill 36 64 288 288 #101024'          "field backing panel at expected geometry"
assert_grep '^glyphs 12 14 \"Mines\" #e8e8f0 b'    "bold title 'Mines' at header"
assert_grep '^glyphs 76 16 \"Left 9'               "mines-left HUD shows 9 after one flag"
assert_grep '^glyphs 180 16 \"Playing\"'           "status reads Playing while live"
assert_grep '^glyphs 176 202 \"3\" #d62a2a'        "revealed cell (4,4) shows a RED 3"
assert_grep '^fill 46 72 12 18 #e02a2a'            "flag marker drawn on cell (0,0)"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([2-9][0-9]|[1-9][0-9][0-9])'  "rasterizer drew the scene primitives"
assert_grep '^PIX 4 4 #1b1b2e backdrop'            "raster backdrop pixel = navy"
assert_grep '^PIX 84 80 #7f8fb0 covered'           "raster covered cell = raised face"
assert_grep '^PIX 167 195 #c8ccd8 revealed'        "raster revealed cell = light face"
assert_grep '^PIX 52 80 #e02a2a flag'              "raster flag marker = red"

# --- Initial deterministic state -----------------------------------------
assert_grep '^REVEAL_44 1'                          "revealing cell (4,4) changed the board"
assert_grep '^STATE_44 1'                           "cell (4,4) is now revealed"
assert_grep '^COUNT_44 3'                           "cell (4,4) has neighbour-count 3"
assert_grep '^STATE_00 2'                           "cell (0,0) is flagged"
assert_grep '^MINES_LEFT 9'                         "one flag leaves 9 mines to find"
assert_grep '^GAMEOVER0 0'                          "game starts live"

# --- RULE: flood fill ----------------------------------------------------
assert_grep '^FLOOD_REVEALED ([8-9]|[1-9][0-9])'    "revealing a 0-cell flood-filled many cells at once"
assert_grep '^FLOOD_CELL_3_3 1'                     "flood filled the walled-off block (cell 3,3)"
assert_grep '^FLOOD_CELL_8_8 0'                     "flood stopped at the wall (cell 8,8 still covered)"
assert_grep '^FLOOD_GAMEOVER 0'                     "a bounded flood fill did not end the game"

# --- RULE: revealing a mine is a loss ------------------------------------
assert_grep '^LOSS_GAMEOVER 1'                      "revealing a mine ends the game"
assert_grep '^LOSS_WON 0'                           "revealing a mine is a LOSS"
assert_grep '^DEAD_REVEAL 0'                        "a reveal after death is a no-op"

# --- RULE: uncovering every non-mine is a win ----------------------------
assert_grep '^WIN_GAMEOVER 1'                       "revealing all safe cells ends the game"
assert_grep '^WIN_WON 1'                            "revealing all safe cells is a WIN"
assert_grep '^WIN_MINE_HIDDEN 0'                    "the mine stays covered on a win"

# --- Control button hit-test ---------------------------------------------
assert_grep '^BTNAT_50_440 0'                       "pointer press hit-tests the New button (0)"
assert_grep '^BTNAT_150_440 1'                      "pointer press hit-tests the Flag button (1)"

# --- RESTART clears the game ---------------------------------------------
assert_grep '^NEW_GAMEOVER 0'                       "New clears game over"
assert_grep '^NEW_MINES_LEFT 10'                    "New restores all 10 mines to find"
assert_grep '^NEW_REVEALED 0'                       "New re-covers every cell"

# --- Non-blank PNG (a healthy count of non-background pixels) -------------
if python3 - "$AFTER" <<'PY'
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
    echo "[mine-host] PASS frame is non-blank (field + numbers + overlay pixels present)"
else
    echo "[mine-host] FAIL frame looks blank"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[mine-host] RESULT: PASS"
    exit 0
else
    echo "[mine-host] RESULT: FAIL"
    exit 1
fi
