#!/usr/bin/env bash
# scripts/test_hamchess_host.sh — FAST, QEMU-free host gate for the Chess
# scene app (lib/hamchesscore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Mirrors scripts/test_ham2048_host.sh: it compiles the
# app's rules engine for the x86_64-linux host target, renders the board to
# PNGs a human/agent can LOOK at, drives SCRIPTED moves/clicks through the pure
# engine, and asserts the RULES are correct — legal move applies + flips the
# turn, illegal move is rejected, selection yields the right legal-move counts
# (20 opening moves; b1-knight has 2; e2-pawn has 2), and the classic FOOL'S
# MATE reaches CHECKMATE (Black wins). It also confirms the NATIVE Hamnix build
# still compiles from the same engine — all in milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only — no image tools).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamchess_host"
mkdir -p "$OUT"
fail=0

echo "[chess-host] compiling engine+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamchessscene_host.ad "$BIN" 2>"$OUT/chess_compile.log"; then
    echo "[chess-host] FAIL: host harness did not compile"; cat "$OUT/chess_compile.log"; exit 1
fi
echo "[chess-host] PASS host harness compiled -> $BIN"

echo "[chess-host] compiling NATIVE hamchessscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamchessscene.ad "$OUT/hamchess_native.elf" 2>"$OUT/chess_native.log"; then
    echo "[chess-host] FAIL: native hamchessscene did not compile"; cat "$OUT/chess_native.log"; exit 1
fi
echo "[chess-host] PASS native hamchessscene still compiles (device dual-target intact)"

echo "[chess-host] running host harness ..."
DUMP="$OUT/chess_dump.txt"
START="$OUT/chess_start.ppm"
MATE="$OUT/chess_mate.ppm"
if ! "$BIN" "$START" "$MATE" >"$DUMP" 2>&1; then
    echo "[chess-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in start mate; do
    if python3 scripts/ppm_to_png.py "$OUT/chess_$f.ppm" "$OUT/chess_$f.png" 2>"$OUT/chess_png.log"; then
        echo "[chess-host] PASS rendered $OUT/chess_$f.png ($(file -b "$OUT/chess_$f.png" 2>/dev/null))"
    else
        echo "[chess-host] FAIL png conversion ($f)"; cat "$OUT/chess_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[chess-host] PASS $msg"
    else
        echo "[chess-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Layout / build assertions (on the raw scene display list) -----------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 360 470 #20222b'         "full-window slate backdrop"
assert_grep '^glyphs 12 14 \"Chess\" #eef0f6 b' "bold title 'Chess' at header"
assert_grep '^fill 20 56 40 40 #e9d3ab'         "a8 light square at expected geometry"
assert_grep '^fill 60 56 40 40 #8a6d4a'         "b8 dark square at expected geometry"
assert_grep '^glyphs 12 388 \"White to move\"'  "status line shows White to move"
assert_grep '^glyphs 20 439 \"New Game\"'       "New Game control button label"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([6-9][0-9]|[1-9][0-9][0-9])' "rasterizer drew the board primitives"
assert_grep '^PIX 25 61 #e9d3ab'                "raster a8 corner = light square"
assert_grep '^PIX 65 61 #8a6d4a'                "raster b8 corner = dark square"
assert_grep '^PIX 185 221 #e9d3ab'              "raster empty middle = light square"

# --- Opening position piece census ---------------------------------------
assert_grep '^WKING 6'                          "white king present (e1)"
assert_grep '^BKING -6'                         "black king present (e8)"
assert_grep '^WPAWN_E2 1'                       "white pawn on e2"
assert_grep '^BQUEEN_D8 -5'                     "black queen on d8"
assert_grep '^TURN0 1'                          "white to move at the start"
assert_grep '^OUTCOME0 0'                       "game in progress at the start"

# --- Move generation correctness -----------------------------------------
assert_grep '^KNIGHT_B1_MOVES 2'                "b1 knight has exactly 2 opening moves (a3, c3)"
assert_grep '^PAWN_E2_MOVES 2'                  "e2 pawn has exactly 2 opening moves (e3, e4)"
assert_grep '^OPENING_MOVES 20'                 "White has exactly 20 legal opening moves"
assert_grep '^SELECTED 52'                      "the e2 pawn is selected in the START render"

# --- Legal / illegal move handling ---------------------------------------
assert_grep '^ILLEGAL_RC 0'                     "king cannot move onto its own pawn (illegal rejected)"
assert_grep '^TURN_AFTER_ILLEGAL 1'             "an illegal move does not flip the turn"
assert_grep '^CLICK_MOVE_RC 1'                  "click-drive e2->e4 applied a legal move"
assert_grep '^E4_PIECE 1'                       "the white pawn is now on e4"
assert_grep '^E2_EMPTY 0'                       "the e2 square is now empty"
assert_grep '^TURN_AFTER_MOVE -1'               "a legal move flips the turn to Black"

# --- FOOL'S MATE: 1. f3 e5 2. g4 Qh4# -> Black checkmates White ----------
assert_grep '^MOVE_F3 1'                        "1. f3 applied"
assert_grep '^MOVE_E5 1'                        "1... e5 applied"
assert_grep '^MOVE_G4 1'                        "2. g4 applied"
assert_grep '^PREMATE_WCHECK 0'                 "White is not in check before the mating move"
assert_grep '^MOVE_QH4 1'                       "2... Qh4 applied"
assert_grep '^MATE_WCHECK 1'                    "White is in check after Qh4"
assert_grep '^MATE_OUTCOME 1'                   "the position is checkmate"
assert_grep '^MATE_WINNER -1'                   "Black wins the checkmate"
assert_grep '^MATE_WHITE_MOVES 0'               "White has no legal reply (true mate, not just check)"
assert_grep '^POSTMATE_RC 0'                    "no move is accepted once the game is over"
assert_grep 'glyphs .* \"Checkmate - Black wins\"' "the mate frame renders the result banner"

# --- Non-blank PNG (a healthy count of non-background pixels) -------------
if python3 - "$START" <<'PY'
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
bg=(0x20,0x22,0x2b); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>12 or abs(px[k+1]-bg[1])>12 or abs(px[k+2]-bg[2])>12: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=2000 else 1)
PY
then
    echo "[chess-host] PASS start frame is non-blank (board + 32 pieces + HUD pixels)"
else
    echo "[chess-host] FAIL start frame looks blank"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[chess-host] RESULT: PASS"
    exit 0
else
    echo "[chess-host] RESULT: FAIL"
    exit 1
fi
