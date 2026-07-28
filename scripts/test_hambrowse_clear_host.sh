#!/usr/bin/env bash
# scripts/test_hambrowse_clear_host.sh — FAST, QEMU-free gate for the CSS `clear`
# property (clear:left / clear:right / clear:both) in the native browser engine
# (lib/web/css/cascade.ad parse + winner, lib/web/layout/box.ad _apply_clear),
# driven by the text host harness user/hambrowse_host.ad. Asserts on the STABLE
# element-background FILL display list ("FILL top bot lx rx #col rad") — the
# painted pixel-row rect of each coloured block — not glyph ink, so a regression
# fails without a QEMU boot.
#
# A `clear`ed block must start on a fresh full-width line BELOW the bottom edge of
# the float it clears, instead of flowing beside it. The fixture proves all three
# sides, each against a CONTROL block that flows beside the same float:
#
#   (A) clear:left  — a tall float:left sidebar (#3366cc); a plain paragraph
#       (#dddddd) flows BESIDE it (indented, same top rows); a clear:left block
#       (#22aa22) drops to the float's bottom edge at the LEFT margin.
#   (B) clear:right — a float:right aside (#cc3366); body (#eeeeee) flows in the
#       left channel; a clear:right block (#aa22aa) drops below the float.
#   (C) clear:both  — a simultaneous float:left (#336633) + float:right (#663333)
#       pair; a middle paragraph (#cccccc) flows between them; a clear:both block
#       (#ffaa00) drops below BOTH floats.
#
# Also renders a PNG via the pixel backend for eyeballing. Builds BOTH the host
# harness (x86_64-linux) and native hambrowse (x86_64-adder-user) so a break in
# the shared engine is caught either way.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_clear.html"
DUMP="$OUT/clear_dump.txt"
PPM="$OUT/clear.ppm"
PNG="$OUT/clear.png"
mkdir -p "$OUT"
fail=0

echo "[hb-clear] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/clear_compile.log"; then
    echo "[hb-clear] FAIL: host harness did not compile"; cat "$OUT/clear_compile.log"; exit 1
fi
echo "[hb-clear] PASS host harness compiled -> $BIN"

echo "[hb-clear] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/clear_native.log"; then
    echo "[hb-clear] FAIL: native hambrowse did not compile"; cat "$OUT/clear_native.log"; exit 1
fi
echo "[hb-clear] PASS native hambrowse still compiles"

echo "[hb-clear] rendering $FIX ..."
if ! "$BIN" "$FIX" 640 >"$DUMP" 2>&1; then
    echo "[hb-clear] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^FILL' "$DUMP" || true

# Best-effort PNG for eyeballing (via the pixel backend). Non-fatal.
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$GFX" 2>"$OUT/clear_gfx.log"; then
    "$GFX" "$FIX" "$PPM" 640 >/dev/null 2>&1 && \
        python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
        echo "[hb-clear] wrote $PNG for eyeballing" || true
fi

# Field extractor: given a declared colour, echo "<top> <bot> <lx>" for the FIRST
# FILL line whose colour matches (FILL top bot lx rx #col rad -> $2 $3 $4 / $6).
fill_for() { awk -v c="$1" '$1=="FILL" && $6==c {print $2, $3, $4; exit}' "$DUMP"; }

read -r FL_T FL_B FL_L   < <(fill_for '#3366cc')   # (A) float:left sidebar
read -r BS_T BS_B BS_L   < <(fill_for '#dddddd')   # (A) beside paragraph (control)
read -r CL_T CL_B CL_L   < <(fill_for '#22aa22')   # (A) clear:left block
read -r FR_T FR_B FR_L   < <(fill_for '#cc3366')   # (B) float:right aside
read -r CR_T CR_B CR_L   < <(fill_for '#aa22aa')   # (B) clear:right block
read -r PL_T PL_B PL_L   < <(fill_for '#336633')   # (C) pair float:left
read -r PR_T PR_B PR_L   < <(fill_for '#663333')   # (C) pair float:right
read -r CB_T CB_B CB_L   < <(fill_for '#ffaa00')   # (C) clear:both block

echo "[hb-clear] (A) floatL top=$FL_T bot=$FL_B lx=$FL_L | beside top=$BS_T lx=$BS_L | clearL top=$CL_T lx=$CL_L"
echo "[hb-clear] (B) floatR top=$FR_T bot=$FR_B lx=$FR_L | clearR top=$CR_T lx=$CR_L"
echo "[hb-clear] (C) pairL bot=$PL_B pairR bot=$PR_B | clearBoth top=$CB_T lx=$CB_L"

need() { [ -n "$1" ] || { echo "[hb-clear] FAIL: missing box ($2)"; fail=1; return 1; }; return 0; }
for v in "$FL_T:floatL" "$BS_T:beside" "$CL_T:clearL" "$FR_T:floatR" "$CR_T:clearR" \
         "$PL_B:pairL" "$PR_B:pairR" "$CB_T:clearBoth"; do
    need "${v%%:*}" "${v##*:}" || true
done

# (A0) CONTROL: the plain paragraph flows BESIDE the float — same top rows AND
# indented to the RIGHT of the float's left edge (not cleared).
if [ "$fail" -eq 0 ] && [ "$BS_T" -lt "$FL_B" ] && [ "$BS_L" -gt "$FL_L" ]; then
    echo "[hb-clear] PASS (A) control paragraph flows BESIDE float:left (top $BS_T < floatbot $FL_B, indent lx $BS_L > $FL_L)"
else
    echo "[hb-clear] FAIL (A) control did not flow beside the float (beside top=$BS_T lx=$BS_L floatbot=$FL_B floatlx=$FL_L)"; fail=1
fi

# (A) clear:left drops to the float's bottom edge, at the LEFT margin.
if [ "$fail" -eq 0 ] && [ "$CL_T" -ge "$FL_B" ]; then
    echo "[hb-clear] PASS (A) clear:left drops below the float (clear top $CL_T >= floatbot $FL_B)"
else
    echo "[hb-clear] FAIL (A) clear:left did not drop below the float (clear top=$CL_T floatbot=$FL_B)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$CL_L" -eq "$FL_L" ]; then
    echo "[hb-clear] PASS (A) cleared block is at the left margin, not float-indented (lx $CL_L)"
else
    echo "[hb-clear] FAIL (A) cleared block still indented by the float (clear lx=$CL_L float lx=$FL_L)"; fail=1
fi

# (B) clear:right drops below the float:right.
if [ "$fail" -eq 0 ] && [ "$CR_T" -ge "$FR_B" ]; then
    echo "[hb-clear] PASS (B) clear:right drops below the right float (clear top $CR_T >= floatbot $FR_B)"
else
    echo "[hb-clear] FAIL (B) clear:right did not drop below the right float (clear top=$CR_T floatbot=$FR_B)"; fail=1
fi

# (C) clear:both drops below the DEEPER of the two floats.
DEEP="$PL_B"
if [ -n "${PR_B:-}" ] && [ "$PR_B" -gt "$DEEP" ]; then DEEP="$PR_B"; fi
if [ "$fail" -eq 0 ] && [ "$CB_T" -ge "$DEEP" ]; then
    echo "[hb-clear] PASS (C) clear:both drops below both floats (clear top $CB_T >= deepest floatbot $DEEP)"
else
    echo "[hb-clear] FAIL (C) clear:both did not drop below both floats (clear top=$CB_T deepest=$DEEP)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-clear] RESULT: PASS"; exit 0
else
    echo "[hb-clear] RESULT: FAIL"; exit 1
fi
