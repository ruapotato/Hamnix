#!/usr/bin/env bash
# scripts/test_hamgamesnake_host.sh — FAST, QEMU-free host gate for "Snake", the
# hamGame arcade game layered on hamSDL (lib/hamgamesnake.ad, driven through the
# PUBLIC lib/hamgame.ad Surface + font API + lib/hamgame_host.ad backend). The
# pygame-shaped Surface-backbuffer Snake — the twin of Coin Dash
# (scripts/test_hamgame_host.sh) — as opposed to the hamscene-layer Snake
# (scripts/test_hamsnake_host.sh, lib/hamsnakecore.ad).
#
# It compiles the game's HOST harness for x86_64-linux, renders BEFORE/AFTER game
# frames to PNGs a human/agent can LOOK at, drives a DETERMINISTIC scripted move
# sequence (heading right, eat the first food), and asserts UNFORGEABLE facts:
# the display-Surface backbuffer rasterized (exact sampled cell-centre colours),
# the snake HEAD advanced to the expected cell, the snake GREW a segment, SCORE
# incremented, food RESPAWNED, the HUD SCORE TEXT rasterized (font pixels), and a
# wall collision ends the game. It also recompiles the NATIVE (x86_64-adder-user)
# device build so the dual-target seam can't silently rot. All in milliseconds,
# no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamgamesnake_host"
mkdir -p "$OUT"
fail=0

echo "[snake-host] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamgamesnake_host.ad "$BIN" 2>"$OUT/hamgamesnake_compile.log"; then
    echo "[snake-host] FAIL: host harness did not compile"; cat "$OUT/hamgamesnake_compile.log"; exit 1
fi
echo "[snake-host] PASS host harness compiled -> $BIN"

echo "[snake-host] compiling NATIVE hamgamesnake for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamgamesnake.ad "$OUT/hamgamesnake_native.elf" 2>"$OUT/hamgamesnake_native.log"; then
    echo "[snake-host] FAIL: native hamgamesnake did not compile"; cat "$OUT/hamgamesnake_native.log"; exit 1
fi
echo "[snake-host] PASS native hamgamesnake compiles (device dual-target intact)"

echo "[snake-host] running host harness ..."
DUMP="$OUT/hamgamesnake_dump.txt"
BEFORE="$OUT/hamgamesnake_before.ppm"
AFTER="$OUT/hamgamesnake_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[snake-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hamgamesnake_$f.ppm" "$OUT/hamgamesnake_$f.png" 2>"$OUT/hamgamesnake_png.log"; then
        echo "[snake-host] PASS rendered $OUT/hamgamesnake_$f.png ($(file -b "$OUT/hamgamesnake_$f.png" 2>/dev/null))"
    else
        echo "[snake-host] FAIL png conversion ($f)"; cat "$OUT/hamgamesnake_png.log"; fail=1
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

assert_eq() {
    local k="$1" want="$2" msg="$3" got
    got="$(kv "$k")"
    if [ "$got" = "$want" ]; then
        echo "[snake-host] PASS $msg ($k=$got)"
    else
        echo "[snake-host] FAIL $msg ($k=$got, want $want)"; fail=1
    fi
}

# --- Rasterizer: the display Surface backbuffer was blitted + sampled ------
assert_grep '^PRIMS [1-9]'                    "rasterizer drew the frame image primitive"
assert_grep '^PIX_HEAD0 #8cf078'              "snake head cell = bright green (backbuffer blit)"
assert_grep '^PIX_FOOD0 #e64646'              "food cell = red"
assert_grep '^PIX_BG0 #181c28'                "empty board cell = dark navy backdrop"

# --- Initial state ---------------------------------------------------------
assert_eq LEN0   3 "snake starts length 3"
assert_eq SCORE0 0 "score starts at 0"

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
bg=(0x18,0x1c,0x28); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>12 or abs(px[k+1]-bg[1])>12 or abs(px[k+2]-bg[2])>12: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=300 else 1)
PY
then
    echo "[snake-host] PASS frame is non-blank (snake + food + HUD pixels present)"
else
    echo "[snake-host] FAIL frame looks blank"; fail=1
fi

# --- MOVEMENT: heading right, the head advanced 4 cells to the food cell ----
HC0=$(kv HEADC0); HC1=$(kv HEADC1); FC0=$(kv FOODC0); HR0=$(kv HEADR0); HR1=$(kv HEADR1)
if [ -n "$HC0" ] && [ -n "$HC1" ] && [ "$HC1" -gt "$HC0" ]; then
    echo "[snake-host] PASS RIGHT heading advanced the head: col $HC0 -> $HC1"
else
    echo "[snake-host] FAIL head did not advance right (c0=$HC0 c1=$HC1)"; fail=1
fi
if [ -n "$HC1" ] && [ -n "$FC0" ] && [ "$HC1" = "$FC0" ] && [ "$HR1" = "$HR0" ]; then
    echo "[snake-host] PASS head reached the food cell (col $HC1, row $HR1)"
else
    echo "[snake-host] FAIL head did not reach the food cell (head=$HC1,$HR1 food=$FC0,$HR0)"; fail=1
fi

# --- GROWTH + SCORE: eating the food grew the snake and scored --------------
assert_eq LEN1   4 "eating food grew the snake to length 4"
assert_eq SCORE1 1 "eating food incremented the score to 1"

# --- FOOD RESPAWN: a fresh food exists (deterministic PRNG) -----------------
FC1=$(kv FOODC1); FR1=$(kv FOODR1)
if [ -n "$FC1" ] && [ -n "$FR1" ]; then
    echo "[snake-host] PASS food respawned at a new cell ($FC1,$FR1)"
else
    echo "[snake-host] FAIL food did not respawn"; fail=1
fi

# --- AFTER frame pixels: head green at new cell, a green body segment, red food
assert_grep '^PIX_HEAD1 #8cf078'              "head rasterized green at its new cell"
assert_grep '^PIX_BODY1 #50c85a'              "a grown body segment rasterized green"
assert_grep '^PIX_FOOD1 #e64646'              "respawned food rasterized red"

# --- HUD SCORE TEXT: game_surface_draw_text rasterized font glyphs ----------
HT0=$(kv HUDTEXT0); HT1=$(kv HUDTEXT1)
if [ -n "$HT0" ] && [ "$HT0" -gt 20 ]; then
    echo "[snake-host] PASS HUD score text rasterized ($HT0 glyph pixels)"
else
    echo "[snake-host] FAIL HUD score text missing (pixels=$HT0)"; fail=1
fi
if [ -n "$HT1" ] && [ "$HT1" -gt 20 ]; then
    echo "[snake-host] PASS HUD score text still present after scoring ($HT1 glyph pixels)"
else
    echo "[snake-host] FAIL HUD score text missing after scoring (pixels=$HT1)"; fail=1
fi

# --- COLLISION: driving into the wall ends the game -------------------------
assert_eq GAMEOVER 1 "wall collision ended the game (game over)"

# --- RESTART: the app stays open; 'r' replays in place ----------------------
assert_eq OVER_AFTER_STEER 1 "a steering key does NOT revive a dead snake"
assert_eq OVER_AFTER_R     0 "pressing R starts a fresh round (no relaunch needed)"
assert_eq LEN_AFTER_R      3 "restart resets the snake to length 3"
assert_eq SCORE_AFTER_R    0 "restart rewinds the score to zero"

# --- SOUND EFFECTS: eat / turn / game-over drive DISTINCT mixer tones -------
# Assert on the real PCM the software mixer renders (lib/hammixer.ad): each event
# creates exactly one voice, the rendered buffer is NON-SILENT (peak amplitude),
# and the zero-crossing count tracks the pitch — so eat (880) > turn (520) >
# over (160) is unforgeable from the samples, not just a function-called flag.
assert_eq TURN_VOICES 1   "turn click created one mixer voice"
assert_eq EAT_VOICES  1   "eat blip created one mixer voice"
assert_eq OVER_VOICES 1   "game-over tone created one mixer voice"
assert_eq TURN_FREQ   520 "turn tone frequency (Hz)"
assert_eq EAT_FREQ    880 "eat tone frequency (Hz)"
assert_eq OVER_FREQ   160 "game-over tone frequency (Hz)"
assert_eq EAT_SCORE   1   "eat tone sounded on the scoring step"
assert_eq OVER_FLAG   1   "game-over tone sounded when the game ended"

gt0() {  # gt0 <field> <label>: assert the field's numeric value is > 0
    local v; v="$(kv "$1")"
    if [ -n "$v" ] && [ "$v" -gt 0 ]; then
        echo "[snake-host] PASS $2 ($1=$v)"
    else
        echo "[snake-host] FAIL $2 ($1=$v, want > 0)"; fail=1
    fi
}
gtf() {  # gtf <fieldA> <fieldB> <label>: assert A > B numerically
    local a b; a="$(kv "$1")"; b="$(kv "$2")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -gt "$b" ]; then
        echo "[snake-host] PASS $3 ($1=$a > $2=$b)"
    else
        echo "[snake-host] FAIL $3 ($1=$a not > $2=$b)"; fail=1
    fi
}

# --- CONSTANT-COST RENDERING: the per-step repaint does NOT grow with length --
# The original port shifted the whole body + redrew every cell each step (O(N)),
# so the framerate sagged the more food you collected. Now a step repaints only a
# BOUNDED handful of cells (new head, ex-head, vacated tail, +new food on an eat)
# no matter how long the snake is. The harness grows the snake ~5x with a
# deterministic controller and asserts the per-step dirty-cell count is IDENTICAL
# at length 3 and at the long length, and stayed bounded the whole way.
DS=$(kv DCELLS_SHORT); DL=$(kv DCELLS_LONG); DM=$(kv DCELLS_MAX); LL=$(kv LEN_LONG)
if [ -n "$LL" ] && [ "$LL" -ge 10 ]; then
    echo "[snake-host] PASS snake grew to a long body for the perf test (LEN_LONG=$LL)"
else
    echo "[snake-host] FAIL snake did not grow long enough to test scaling (LEN_LONG=$LL)"; fail=1
fi
if [ -n "$DS" ] && [ -n "$DL" ] && [ "$DS" = "$DL" ]; then
    echo "[snake-host] PASS per-step repaint cost is CONSTANT as the snake grows (len3=$DS == len$LL=$DL cells)"
else
    echo "[snake-host] FAIL per-step repaint cost changed with length (short=$DS long=$DL)"; fail=1
fi
if [ -n "$DM" ] && [ "$DM" -ge 1 ] && [ "$DM" -le 4 ]; then
    echo "[snake-host] PASS worst per-step dirty-cell count stayed bounded across the whole growth run (DCELLS_MAX=$DM)"
else
    echo "[snake-host] FAIL per-step dirty-cell count was unbounded (DCELLS_MAX=$DM, want 1..4)"; fail=1
fi
assert_eq INCR_MATCHES_FULL 1 "incremental damage repaint is pixel-identical to a full redraw"

# --- SOUND SURVIVES A LONG GAME (no per-beep clip leak) ---------------------
assert_eq MANY_VOICES 1   "a tone still sounds after 30 prior events (no clip-table exhaustion)"
assert_eq MANY_FREQ   520 "the surviving late-game tone is the turn pitch"
gt0 MANY_PEAK "late-game tone PCM is non-silent (reusable clips, not a dead mixer)"

gt0 TURN_PEAK "turn tone PCM is non-silent (mixer produced samples)"
gt0 EAT_PEAK  "eat tone PCM is non-silent (mixer produced samples)"
gt0 OVER_PEAK "game-over tone PCM is non-silent (mixer produced samples)"
gtf EAT_ZC  TURN_ZC "eat pitch > turn pitch in the rendered PCM (zero-crossings)"
gtf TURN_ZC OVER_ZC "turn pitch > game-over pitch in the rendered PCM"
gtf EAT_ZC  OVER_ZC "eat pitch > game-over pitch in the rendered PCM"

if [ "$fail" -eq 0 ]; then
    echo "[snake-host] RESULT: PASS"
    exit 0
else
    echo "[snake-host] RESULT: FAIL"
    exit 1
fi
