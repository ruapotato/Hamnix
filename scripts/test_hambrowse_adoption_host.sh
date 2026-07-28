#!/usr/bin/env bash
# scripts/test_hambrowse_adoption_host.sh — FAST, QEMU-free render-to-PNG gate
# for HTML5 misnested-inline recovery (WHATWG tree-construction "adoption agency
# algorithm" + "reconstruct the active formatting elements"). Browser W3C
# campaign round 10, remaining-map item #5.
#
# The canonical misnest  <b>A<i>B</b>C</i>  must produce the spec DOM
#   <b>A<i>B</i></b><i>C</i>
# i.e. the <i> is reconstructed after the </b> so the visible formatting is
#   A = bold, B = bold+italic, C = italic (NOT bold).
# A naive depth-counter that dropped ALL open formatting on the stray </b> would
# leave C unformatted (or still bold); the spec keeps C italic via the
# reconstructed <i> clone. This engine models inline emphasis as INDEPENDENT,
# ORTHOGONAL style counters (bold / italic are separate), and does NOT reset a
# formatting counter on a block boundary — which reproduces the spec's
# adoption-agency + reconstruct VISUAL result exactly. This gate LOCKS that in
# (a regression guard) by asserting the per-run bold/italic flags the pixel
# backend paints (the "SEGFLAGS <bold> <italic> <text>" dump).
#
# Also asserts the block-crossing reconstruct case: a <b> left open across a
# </p><p> boundary is reconstructed in the next block ("Y" stays bold).
#
# Builds the pixel backend (x86_64-linux) AND the native browser
# (x86_64-adder-user) so a regression in either target fails here. NO QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_adoption.html"
PPM="$OUT/adoption.ppm"
PNG="$OUT/adoption.png"
mkdir -p "$OUT"
fail=0

echo "[hb-adopt] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/adopt_compile.log"; then
    echo "[hb-adopt] FAIL: driver did not compile"; cat "$OUT/adopt_compile.log"; exit 1
fi
echo "[hb-adopt] PASS pixel backend compiled"

echo "[hb-adopt] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/adopt_native.elf" 2>"$OUT/adopt_native.log"; then
    echo "[hb-adopt] FAIL: native hambrowse did not compile"; cat "$OUT/adopt_native.log"; exit 1
fi
echo "[hb-adopt] PASS native hambrowse still compiles"

D="$OUT/adopt_dump.txt"
if ! "$BIN" "$FIX" "$PPM" 400 >"$D" 2>&1; then
    echo "[hb-adopt] FAIL: render exited non-zero"; cat "$D"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-adopt] wrote $PNG"

# flags of the run whose text is exactly $1 -> "<bold> <italic>"
flags() { grep -E "^SEGFLAGS [01] [01] $1\$" "$D" | head -1 | awk '{print $2" "$3}'; }

check() { # label text expect
    got=$(flags "$2")
    if [ "$got" = "$3" ]; then echo "[hb-adopt] PASS $1 (bold italic = $got)";
    else echo "[hb-adopt] FAIL $1 — run '$2' got '${got:-MISSING}' want '$3'"; fail=1; fi
}

# Canonical adoption-agency misnest <b>A<i>B</b>C</i>:
check "control <b>1</b> is bold-only"        "1" "1 0"
check "A (inside <b>) is bold-only"          "A" "1 0"
check "B (inside <b><i>) is bold+italic"     "B" "1 1"
check "C (reconstructed <i> after </b>) is italic-not-bold" "C" "0 1"
# Block-crossing reconstruct-the-active-formatting-elements:
check "X (<b> before </p>) is bold"          "X" "1 0"
check "Y (<b> reconstructed in next <p>) stays bold" "Y" "1 0"

if [ "$fail" -ne 0 ]; then echo "[hb-adopt] RESULT: FAIL"; exit 1; fi
echo "[hb-adopt] RESULT: PASS — misnested-inline recovery matches the spec adoption-agency DOM"
