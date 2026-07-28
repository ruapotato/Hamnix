#!/usr/bin/env bash
# scripts/test_hamsh_pygame_host.sh — FAST, QEMU-free host gate for the
# pygame-flavored hamSDL bindings in the hamsh shell (user/hamsh.ad:
# builtin_pygame + the rgb()/pixel()/poll_event()/ev_key() expression
# functions).
#
# Mirrors scripts/test_ham2048_host.sh + scripts/test_hamsh_lang_host.sh: the
# SAME hamsh source that runs as /init on-device is compiled for x86_64-linux
# and driven DIRECTLY on the host over a stdin pipe — no boot, no QEMU. A hamsh
# GAME script inits a screen, draws known primitives (a filled rect at a known
# position/colour, a line, some text), flips (rasterizes the built lib/hamscene
# display list through the shared host sink lib/hamui_host.ad), and dumps a PPM.
# We then assert UNFORGEABLE pixels — the rect interior colour at its coords,
# the background elsewhere, the line colour on its row — both via the shell's
# own pixel() function AND by parsing the raw PPM, and render a PNG to LOOK at.
#
# The DEVICE build is untouched: hamsh.ad is byte-identical, and this gate also
# recompiles the NATIVE shell for x86_64-adder-user to prove no regression.
#
# Driven over a stdin PIPE with --no-echo (see test_hamsh_lang_host.sh): the
# host runtime reports fd 0 as a pipe so ed_readline skips its getty-flush, and
# --no-echo keeps the shell from echoing input, so every asserted marker is
# produced by the evaluator + the rasterizer, never by input echo.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_pygame_host"
mkdir -p "$OUT"
fail=0

echo "[pygame-host] compiling hamsh (pygame bindings) for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/pygame_compile.log"; then
    echo "[pygame-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/pygame_compile.log"; exit 1
fi
echo "[pygame-host] PASS host hamsh compiled -> $BIN"

echo "[pygame-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_pygame_native.elf" 2>"$OUT/pygame_native.log"; then
    echo "[pygame-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/pygame_native.log"; exit 1
fi
echo "[pygame-host] PASS native hamsh still compiles (device build unaffected)"

# ---------------------------------------------------------------------------
# (1) DETERMINISTIC PRIMITIVES: draw known shapes, flip, dump a PPM, and echo
#     framebuffer pixels via the shell's pixel() function.
# ---------------------------------------------------------------------------
PRIM="$OUT/pygame_prim.hsh"
PPM="$OUT/pygame_prim.ppm"
cat > "$PRIM" <<HSH
pygame init 100 100
bg  = rgb(0, 0, 0)
red = rgb(255, 0, 0)
grn = rgb(0, 255, 0)
pygame fill \$bg
pygame rect 30 30 40 40 \$red
pygame line 0 90 99 90 \$grn
pygame text 4 4 "HI" \$red
pygame flip
echo COLOR_RED \$red
echo RECT_PIX \${ pixel(50, 50) }
echo RECT_EDGE \${ pixel(30, 30) }
echo BG_PIX \${ pixel(85, 15) }
echo LINE_PIX \${ pixel(50, 90) }
pygame save $PPM
pygame key 259
echo POLL_KIND \${ poll_event() }
echo POLL_KEY \${ ev_key() }
pygame quit
echo POLL_QUIT \${ poll_event() }
exit
HSH

DUMP="$OUT/pygame_prim.txt"
timeout 30 "$BIN" --no-echo <"$PRIM" >"$DUMP" 2>"$OUT/pygame_prim.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[pygame-host] FAIL: primitives shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[pygame-host] --- primitives shell stdout ---"
cat "$DUMP"
echo "[pygame-host] --- end output ---"

check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[pygame-host] OK: $2"
    else
        echo "[pygame-host] WRONG (want '$1'): $2"; fail=1
    fi
}

# rgb(255,0,0) = 0xFF0000FF = 4278190335 ; the framebuffer pixel is 0xRRGGBB.
check "COLOR_RED 4278190335" "rgb(255,0,0) packs to 0xFF0000FF"
check "RECT_PIX 16711680"    "filled rect interior pixel = 0xFF0000 (red)"
check "RECT_EDGE 16711680"   "rect top-left corner pixel = red (geometry correct)"
check "BG_PIX 0"             "empty pixel (85,15), clear of rect/line/text = 0x000000"
check "LINE_PIX 65280"       "line pixel on its row = 0x00FF00 (green)"
check "POLL_KIND 1"          "poll_event() dequeues the scripted KEYDOWN (=1)"
check "POLL_KEY 259"         "ev_key() = 259 (SDLK_RIGHT) for the pushed key"
check "POLL_QUIT 0"          "poll_event() dequeues the scripted QUIT (=0)"

# Guard against a false-green truncated run: the background must NOT read red.
if grep -qF "BG_PIX 16711680" "$DUMP"; then
    echo "[pygame-host] FAIL: background pixel is red (rect leaked / wrong coords)"; fail=1
fi

# --- UNFORGEABLE: parse the raw PPM the game dumped and verify the pixels ---
if [ -e "$PPM" ] && python3 - "$PPM" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
assert d[:2] == b'P6', "not a P6 ppm"
i = 2; vals = []
while len(vals) < 3:
    while i < len(d) and d[i] in b' \t\n\r': i += 1
    if d[i:i+1] == b'#':
        while i < len(d) and d[i] not in b'\n': i += 1
        continue
    s = i
    while i < len(d) and d[i] not in b' \t\n\r': i += 1
    vals.append(int(d[s:i]))
w, h, mx = vals
i += 1
px = d[i:]
def rgb(x, y):
    o = (y*w + x)*3
    return px[o], px[o+1], px[o+2]
assert (w, h) == (100, 100), f"unexpected size {w}x{h}"
# rect interior (30..70, 30..70) is red; centre must be pure red.
assert rgb(50, 50) == (255, 0, 0), f"rect centre not red: {rgb(50,50)}"
assert rgb(31, 31) == (255, 0, 0), f"rect corner not red: {rgb(31,31)}"
# background far from the rect is black.
assert rgb(85, 15) == (0, 0, 0), f"bg not black: {rgb(85,15)}"
assert rgb(90, 20) == (0, 0, 0), f"bg not black: {rgb(90,20)}"
# the green line lives on row 90.
assert rgb(50, 90) == (0, 255, 0), f"line not green: {rgb(50,90)}"
# count the red rect pixels — a solid 40x40 fill is 1600 px.
red = sum(1 for y in range(h) for x in range(w) if rgb(x, y) == (255, 0, 0))
print("PPM-RED-PIXELS", red)
sys.exit(0 if 1500 <= red <= 1700 else 1)
PY
then
    echo "[pygame-host] PASS raw PPM has the rect (red), background (black) + line (green) exactly"
else
    echo "[pygame-host] FAIL raw PPM pixel evidence wrong"; fail=1
fi

# Render the primitives PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$OUT/pygame_prim.png" 2>"$OUT/pygame_png.log"; then
    echo "[pygame-host] PASS rendered $OUT/pygame_prim.png ($(file -b "$OUT/pygame_prim.png" 2>/dev/null))"
else
    echo "[pygame-host] FAIL png conversion (primitives)"; cat "$OUT/pygame_png.log"; fail=1
fi

# ---------------------------------------------------------------------------
# (2) THE EXAMPLE GAME: examples/pygame_bounce.hsh runs a real bouncing-rect
#     loop end to end (init -> event drain -> update -> draw -> flip x90) and
#     dumps a PPM. Prove it ran, moved the ball, and rendered.
# ---------------------------------------------------------------------------
GDUMP="$OUT/pygame_bounce.txt"
( cd "$OUT" && timeout 30 "./$(basename "$BIN")" --no-echo \
    <../../examples/pygame_bounce.hsh ) >"$GDUMP" 2>"$OUT/pygame_bounce.err"
grc=$?
if [ "$grc" -ne 0 ]; then
    echo "[pygame-host] FAIL: bounce game exited rc=$grc"; cat "$GDUMP"; fail=1
fi
echo "[pygame-host] --- bounce game stdout ---"; grep -aE "bounce:" "$GDUMP"

if grep -qaE "bounce: ran 90 frames" "$GDUMP"; then
    echo "[pygame-host] PASS bounce game ran its full 90-frame loop"
else
    echo "[pygame-host] FAIL bounce game did not complete its loop"; fail=1
fi
# The ball starts at x=20; after 90 frames of vx=6 with wall bounces it must
# have MOVED to some other in-bounds column (a real update loop, not a freeze).
bx=$(grep -aoE "ball x=[0-9]+" "$GDUMP" | grep -oE "[0-9]+" | tail -1)
: "${bx:=20}"
if [ "$bx" != "20" ] && [ "$bx" -ge 4 ] && [ "$bx" -le 156 ]; then
    echo "[pygame-host] PASS ball moved from x=20 to in-bounds x=$bx (update loop live)"
else
    echo "[pygame-host] FAIL ball did not move as expected: x=$bx"; fail=1
fi

if [ -e "$OUT/bounce.ppm" ] && \
   python3 scripts/ppm_to_png.py "$OUT/bounce.ppm" "$OUT/pygame_bounce.png" 2>"$OUT/pygame_bounce_png.log"; then
    echo "[pygame-host] PASS rendered $OUT/pygame_bounce.png (LOOK: orange rect on dark field, 'BOUNCE' label)"
else
    echo "[pygame-host] FAIL bounce png conversion"; cat "$OUT/pygame_bounce_png.log" 2>/dev/null; fail=1
fi

# Prove the bounce frame actually RASTERIZED the orange ball (rgb 240,90,60).
if python3 - "$OUT/bounce.ppm" 240 90 60 <<'PY'
import sys
p = sys.argv[1]; tr, tg, tb = (int(sys.argv[i]) for i in (2, 3, 4))
d = open(p, 'rb').read()
assert d[:2] == b'P6'
i = 2; vals = []
while len(vals) < 3:
    while i < len(d) and d[i] in b' \t\n\r': i += 1
    if d[i:i+1] == b'#':
        while i < len(d) and d[i] not in b'\n': i += 1
        continue
    s = i
    while i < len(d) and d[i] not in b' \t\n\r': i += 1
    vals.append(int(d[s:i]))
w, h, mx = vals; i += 1; px = d[i:]
n = sum(1 for k in range(0, len(px)-2, 3)
        if abs(px[k]-tr) <= 4 and abs(px[k+1]-tg) <= 4 and abs(px[k+2]-tb) <= 4)
print("BOUNCE-BALL-PIXELS", n)
# a 40x28 ball is ~1120 px; require a healthy block present.
sys.exit(0 if n >= 900 else 1)
PY
then
    echo "[pygame-host] PASS bounce game rasterized the orange ball"
else
    echo "[pygame-host] FAIL bounce game did not rasterize the ball"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[pygame-host] RESULT: FAIL"
    exit 1
fi
echo "[pygame-host] RESULT: PASS"
