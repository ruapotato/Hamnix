#!/usr/bin/env bash
# scripts/test_hamsnake_host.sh — FAST, QEMU-free host gate for the Snake
# scene app (lib/hamsnakecore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Mirrors scripts/test_ham2048_host.sh: it compiles the
# app's core for the x86_64-linux host target, renders the scene to PNGs a
# human/agent can LOOK at, drives SCRIPTED input (keyboard wire lines + ticks +
# an on-screen button), asserts the game state evolved (snake moves, food eaten
# grows + scores, wall/self collision is game over, New restarts), AND confirms
# the NATIVE Hamnix build still compiles from the same core — all in
# milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only — no image tools).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsnake_host"
mkdir -p "$OUT"
fail=0

echo "[snake-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsnakescene_host.ad "$BIN" 2>"$OUT/snake_compile.log"; then
    echo "[snake-host] FAIL: host harness did not compile"; cat "$OUT/snake_compile.log"; exit 1
fi
echo "[snake-host] PASS host harness compiled -> $BIN"

echo "[snake-host] compiling NATIVE hamsnakescene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamsnakescene.ad "$OUT/hamsnake_native.elf" 2>"$OUT/snake_native.log"; then
    echo "[snake-host] FAIL: native hamsnakescene did not compile"; cat "$OUT/snake_native.log"; exit 1
fi
echo "[snake-host] PASS native hamsnakescene still compiles (device dual-target intact)"

echo "[snake-host] running host harness ..."
DUMP="$OUT/snake_dump.txt"
BEFORE="$OUT/snake_before.ppm"
AFTER="$OUT/snake_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[snake-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/snake_$f.ppm" "$OUT/snake_$f.png" 2>"$OUT/snake_png.log"; then
        echo "[snake-host] PASS rendered $OUT/snake_$f.png ($(file -b "$OUT/snake_$f.png" 2>/dev/null))"
    else
        echo "[snake-host] FAIL png conversion ($f)"; cat "$OUT/snake_png.log"; fail=1
    fi
done

kv() { awk -v k="$1" '$1==k{print $2}' "$DUMP"; }

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[snake-host] PASS $msg"
    else
        echo "[snake-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Layout / build assertions (on the raw scene display list) -----------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 360 470 #1b1b2e'         "full-window navy backdrop"
assert_grep '^fill 20 56 320 320 #101024'       "board backing panel at expected geometry"
assert_grep '^glyphs 12 14 \"Snake\" #e8e8f0 b' "bold title 'Snake' at header"
assert_grep '^glyphs 84 16 \"Score 0\"'         "live score readout starts at 0"
assert_grep '^fill 62 98 16 16 #ff5252'         "food cell (forced to 2,2) drawn red"
assert_grep '^fill 181 217 18 18 #7dff9e'       "snake head cell (8,8) drawn bright green"
assert_grep '^glyphs 107 439 \"Up\"'            "Up control button label"
assert_grep '^glyphs 311 439 \"Right\"'         "Right control button label"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([2-9][0-9]|[1-9][0-9][0-9])' "rasterizer drew the scene primitives"
assert_grep '^PIX 4 4 #1b1b2e'                  "raster backdrop pixel = navy"
assert_grep '^PIX 25 361 #101024'              "raster empty board cell = dark board"
assert_grep '^PIX 186 222 #7dff9e'             "raster head cell = bright green"
assert_grep '^PIX 66 102 #ff5252'              "raster food cell = red"

# --- Initial state -------------------------------------------------------
assert_grep '^HEADX0 8'                         "initial head x = board centre"
assert_grep '^HEADY0 8'                         "initial head y = board centre"
assert_grep '^LEN0 4'                           "initial snake length = START_LEN"
assert_grep '^SCORE0 0'                         "initial score is 0"
assert_grep '^ALIVE0 1'                         "snake starts alive"

# --- Control button hit-test ---------------------------------------------
assert_grep '^BTNAT 110 440 1'                  "pointer press in control row hit-tests the Up button"

# --- EAT: a tick onto food grows the snake + scores ----------------------
assert_grep '^HEADX1 9'                         "head advanced one cell right on the tick"
assert_grep '^LEN1 5'                           "eating food grew the snake by one"
assert_grep '^SCORE1 1'                         "eating food raised the score"

# --- KEYBOARD turn -------------------------------------------------------
assert_grep '^KEYTURN 1'                        "keyboard 's' press applied a heading change"
assert_grep '^HEADY2 9'                         "a down tick advanced the head one cell down"

# --- DEATH on the wall ---------------------------------------------------
assert_grep '^DEATH_ALIVE 0'                    "running into the wall killed the snake"
assert_grep '^DEATH_GAMEOVER 1'                 "wall hit sets game over"
assert_grep '^DEAD_TICK 0'                      "a tick while dead is a no-op"

# --- SELF-COLLISION ------------------------------------------------------
assert_grep '^SELFHIT_ALIVE 0'                  "stepping onto a non-tail body cell is a self-collision death"

# --- RESTART clears game over --------------------------------------------
assert_grep '^NEW_ALIVE 1'                      "New restarts a live snake"
assert_grep '^NEW_GAMEOVER 0'                   "New clears game over"
assert_grep '^NEW_LEN 4'                        "New restores the starting length"

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
    echo "[snake-host] PASS frame is non-blank (board + snake + food + HUD pixels present)"
else
    echo "[snake-host] FAIL frame looks blank"; fail=1
fi

# --- BIG BODY: long snake renders + bounded display list -----------------
BDUMP="$OUT/snake_big_dump.txt"
if ! "$BIN" big "$OUT/snake_big.ppm" >"$BDUMP" 2>&1; then
    echo "[snake-host] FAIL: big harness exited non-zero"; cat "$BDUMP"; fail=1
fi
if python3 scripts/ppm_to_png.py "$OUT/snake_big.ppm" "$OUT/snake_big.png" 2>"$OUT/snake_big_png.log"; then
    echo "[snake-host] PASS rendered long-body frame $OUT/snake_big.png"
else
    echo "[snake-host] FAIL big png conversion"; cat "$OUT/snake_big_png.log"; fail=1
fi
BIGSEG=$(awk '/^BIGSEG /{print $2}' "$BDUMP")
: "${BIGSEG:=0}"
# The whole display list for a full-column snake must stay well under the
# 16384-byte scene cap (past which primitives silently truncate).
if [ "$BIGSEG" -gt 0 ] && [ "$BIGSEG" -lt 12000 ]; then
    echo "[snake-host] PASS long-body display list bounded below the scene cap: BIGSEG=$BIGSEG"
else
    echo "[snake-host] FAIL long-body display list not bounded: BIGSEG=$BIGSEG"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[snake-host] RESULT: PASS"
    exit 0
else
    echo "[snake-host] RESULT: FAIL"
    exit 1
fi
