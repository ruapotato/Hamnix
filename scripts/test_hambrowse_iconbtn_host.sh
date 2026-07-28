#!/usr/bin/env bash
# scripts/test_hambrowse_iconbtn_host.sh — FAST, QEMU-free render gate for the
# search-box <button> defects the user saw on live google.com.
#
# WHY THIS GATE EXISTS
#   google's search bar mangled its right-side control cluster:
#     * an icon-only, aria-labelled <button> (voice/image/"Add files and tools")
#       painted a stray "Button" placeholder label — the affordance's accessible
#       name is in aria-label and its face is an <svg>, so there is NO text label
#       to draw. The old code fell back to the literal word "Button".
#     * the "AI Mode" chip (an <svg> icon + a text label, as a flex item) took
#       the block-CTA layout path, where its icon spans LEAKED as flow text and
#       the box ballooned several rows tall, overlapping the whole search box.
#   Root cause both in lib/web/dom/forms.ad: the <button> label fallback did not
#   distinguish icon-only/aria-labelled controls, and a flex-item icon <button>
#   was routed to the block-CTA path instead of the compact [ label ] branch.
#
# ASSERTIONS (on the shipped painter's deterministic seg dump)
#   1. The AI Mode chip renders as ONE compact button seg "[ AI Mode ]"
#      (SEGCTRL kind 2), and NOT as a bare "AI Mode" flow run (which would mean
#      its body leaked out of the button box).
#   2. The icon-only aria-labelled <button> paints NO "Button" placeholder — the
#      only "Button" in the page is the genuinely-empty <input type=button>
#      fallback, so exactly ONE "Button" seg exists (a regression re-adds a 2nd).
#   3. SEGCTRL control kinds in fixture order: textarea field(1), AI Mode chip
#      button(2), empty input button(2) => "1 2 2".
#
# Builds the pixel backend (x86_64-linux) AND native hambrowse
# (x86_64-adder-user) so a regression in either target fails here. NO QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx_iconbtn"
FIX="tests/fixtures/hambrowse_iconbtn.html"
PPM="$OUT/iconbtn.ppm"
PNG="$OUT/iconbtn.png"
mkdir -p "$OUT"
fail=0

echo "[hb-ib] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/iconbtn_compile.log"; then
    echo "[hb-ib] FAIL: pixel backend did not compile"; cat "$OUT/iconbtn_compile.log"; exit 1
fi
echo "[hb-ib] PASS pixel backend compiled"

echo "[hb-ib] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/iconbtn_native.elf" 2>"$OUT/iconbtn_native.log"; then
    echo "[hb-ib] FAIL: native hambrowse did not compile"; cat "$OUT/iconbtn_native.log"; exit 1
fi
echo "[hb-ib] PASS native hambrowse still compiles"

D="$OUT/iconbtn_dump.txt"
if ! "$BIN" "$FIX" "$PPM" 600 >"$D" 2>&1; then
    echo "[hb-ib] FAIL: render exited non-zero"; cat "$D"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-ib] wrote $PNG"

# (1) AI Mode chip = compact button seg, not a leaked flow run.
chip=$(grep -cE '^SEGTXT \[ AI Mode \]$' "$D" || true)
leak=$(grep -cE '^SEGTXT AI Mode$' "$D" || true)
echo "[hb-ib] AI Mode: compact-chip=$chip leaked-flow=$leak"
if [ "$chip" -eq 1 ] && [ "$leak" -eq 0 ]; then
    echo "[hb-ib] PASS AI Mode renders as one compact [ AI Mode ] button (no icon/text leak)"
else
    echo "[hb-ib] FAIL AI Mode chip=$chip leak=$leak (want chip=1 leak=0)"; fail=1
fi

# (2) Exactly ONE "Button" seg — the empty <input type=button> fallback. The
#     icon-only aria-labelled <button> must emit none.
btn=$(grep -E '^SEGTXT ' "$D" | grep -c 'Button' || true)
echo "[hb-ib] 'Button' segs: $btn"
if [ "$btn" -eq 1 ]; then
    echo "[hb-ib] PASS icon-only aria-labelled button emits no stray 'Button' label"
else
    echo "[hb-ib] FAIL $btn 'Button' segs (want 1: only the empty input fallback)"; fail=1
fi

# (3) SEGCTRL control kinds in order: field(1), AI Mode button(2), input(2).
kinds=$(grep -E '^SEGCTRL ' "$D" | awk '{print $2}' | tr '\n' ' ')
echo "[hb-ib] SEGCTRL kinds: ${kinds:-<none>}"
if [ "$(printf '%s' "$kinds")" = "1 2 2 " ]; then
    echo "[hb-ib] PASS control kinds field(1) + AI-Mode button(2) + input button(2)"
else
    echo "[hb-ib] FAIL SEGCTRL kinds '${kinds}' want '1 2 2 '"; fail=1
fi

# (4) The AI Mode chip is a `<button ... border-radius:100px>` — a PILL. A
# <button> must honour its author border-radius (it previously took the geometry
# path that dropped border/radius, so the chip painted as a SQUARE box). Its
# SEGCTRL line must carry a large radius (the 100px author value), proving the
# painter rounds it into a pill rather than the UA 3px default.
airad=$(grep -E '^SEGCTRL 2 ' "$D" | head -1 | sed -E 's/.* rad ([0-9-]+).*/\1/')
echo "[hb-ib] AI Mode chip btnrad: ${airad:-<none>}"
if [ -n "$airad" ] && [ "$airad" -ge 50 ]; then
    echo "[hb-ib] PASS AI Mode <button> honours border-radius:100px (pill, rad=$airad)"
else
    echo "[hb-ib] FAIL AI Mode <button> radius '${airad}' — expected >=50 (border-radius:100px dropped -> square chip)"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-ib] RESULT: FAIL"; exit 1; fi
echo "[hb-ib] RESULT: PASS — icon-only button suppressed, AI Mode compact, empty-input fallback intact"
