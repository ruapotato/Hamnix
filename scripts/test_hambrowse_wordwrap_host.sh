#!/usr/bin/env bash
# scripts/test_hambrowse_wordwrap_host.sh — FAST, QEMU-free gate for three
# rendering-fidelity fixes in the native browser engine:
#
#   (A) TEXT WORD-WRAP (lib/web/layout/box.ad::_emit_word). Real browsers break a
#       line at WHITESPACE (word boundaries). A word wider than a narrow column
#       must NOT split mid-run under the DEFAULT overflow-wrap:normal — it wraps
#       as a whole word and OVERFLOWS the box. Pre-fix, "Platform" char-broke into
#       "Platf|orm" inside any narrow column (infobox). Mid-word breaking is now
#       an OPT-IN, gated on overflow-wrap:break-word / word-wrap:break-word /
#       word-break:break-all (cascade.ad g_break_word).
#
#   (B) TABLE INTER-ROW RULES (lib/htmlpage.ad + lib/web/layout/tables.ad). An
#       internal bordered cell is painted spanning its FULL content rows, so a
#       cell's bottom rule coincides EXACTLY with the row-below cell's top rule —
#       one clean shared horizontal line, not two offset rules a row-band apart
#       (the "slightly doubled" divider). Sampled via the pixel gfx backend.
#
#   (C) <figure> UA-DEFAULT MARGIN (lib/web/css/cascade.ad). A bare <figure> is
#       inset ~40px on each side (real browsers' `figure { margin: 1em 40px }`),
#       instead of sitting at the body left margin.
#
# Builds BOTH the text host harness AND the native hambrowse so a break in either
# backend is caught, plus the pixel gfx backend for the table sampling.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_wordwrap.html"
TBL="tests/fixtures/hambrowse_wwtable.html"
mkdir -p "$OUT"
fail=0

echo "[hb-ww] compiling text host harness ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ww_compile.log"; then
    echo "[hb-ww] FAIL: host harness did not compile"; cat "$OUT/ww_compile.log"; exit 1
fi
echo "[hb-ww] PASS text host harness compiled"

echo "[hb-ww] compiling pixel gfx backend ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/ww_gfx.log"; then
    echo "[hb-ww] FAIL: gfx backend did not compile"; cat "$OUT/ww_gfx.log"; exit 1
fi
echo "[hb-ww] PASS pixel gfx backend compiled"

echo "[hb-ww] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ww_native.log"; then
    echo "[hb-ww] FAIL: native hambrowse did not compile"; cat "$OUT/ww_native.log"; exit 1
fi
echo "[hb-ww] PASS native hambrowse still compiles"

# ---------------------------------------------------------------------------
# (A) + (C): text SEG dump. SEG lines are "SEG line x color ... |text|".
# ---------------------------------------------------------------------------
D="$OUT/wordwrap.txt"
"$BIN" "$FIX" 500 >"$D" 2>&1 || { echo "[hb-ww] FAIL: render exited non-zero"; cat "$D"; exit 1; }
grep -E 'SEG [0-9]+ [0-9]+ #.*\|[A-Za-z]' "$D" || true

# (A) DEFAULT: "Platform" survives as ONE whole-word segment (never split).
if grep -qE '\|Platform\|' "$D"; then
    echo "[hb-ww] PASS (A) default: over-wide 'Platform' stays intact on one line (word-boundary wrap, overflows box)"
else
    echo "[hb-ww] FAIL (A) 'Platform' was split mid-word under the default overflow-wrap:normal"; fail=1
fi
# And it is NOT char-broken — no partial 'Platf' fragment segment.
if grep -qE '\|Platf\|' "$D"; then
    echo "[hb-ww] FAIL (A) found a mid-word fragment '|Platf|' — default must not char-break"; fail=1
else
    echo "[hb-ww] PASS (A) no mid-word fragment of 'Platform' (default never char-breaks)"
fi

# (A') overflow-wrap:break-word OPT-IN: the over-wide word DOES split -> the
# whole word 'Breakword' is absent and a leading fragment '|Break|' appears.
if grep -qE '\|Break\|' "$D" && ! grep -qE '\|Breakword\|' "$D"; then
    echo "[hb-ww] PASS (A') overflow-wrap:break-word still char-breaks the over-wide word"
else
    echo "[hb-ww] FAIL (A') overflow-wrap:break-word opt-in did not break 'Breakword' mid-run"; fail=1
fi

# (A'') word-break:break-all OPT-IN: same — 'Wordbreak' splits into '|Wordb|' ...
if grep -qE '\|Wordb\|' "$D" && ! grep -qE '\|Wordbreak\|' "$D"; then
    echo "[hb-ww] PASS (A'') word-break:break-all still char-breaks the over-wide word"
else
    echo "[hb-ww] FAIL (A'') word-break:break-all opt-in did not break 'Wordbreak' mid-run"; fail=1
fi

# (C) <figure> UA default margin: caption is inset ~40px (x = 8 + 40 = 48),
# while the body paragraphs stay at the left margin (x = 8).
fig_x=$(grep -E 'SEG [0-9]+ [0-9]+ #.*\|Figure caption' "$D" | awk '{print $3}' | head -1)
intro_x=$(grep -E 'SEG [0-9]+ [0-9]+ #.*\|Intro paragraph' "$D" | awk '{print $3}' | head -1)
echo "[hb-ww] (C) figure caption x=$fig_x  intro paragraph x=$intro_x (expect 48 / 8)"
if [ "$fig_x" = "48" ]; then
    echo "[hb-ww] PASS (C) <figure> is inset ~40px from the body left margin (x=48)"
else
    echo "[hb-ww] FAIL (C) <figure> not inset 40px (caption x=$fig_x, want 48)"; fail=1
fi
if [ "$intro_x" = "8" ]; then
    echo "[hb-ww] PASS (C) body paragraph stays at the left margin (x=8)"
else
    echo "[hb-ww] FAIL (C) body paragraph x=$intro_x (want 8)"; fail=1
fi

# ---------------------------------------------------------------------------
# (B): pixel BORDER dump. "BORDER i x0 .. y0 T x1 .. y1 B edge C inside C".
# A 3-row bordered table -> 6 cell rects + 1 frame. Vertically-adjacent cells
# in the SAME column must share their inter-row edge exactly (upper cell y1 ==
# lower cell y0), i.e. a single clean horizontal rule, not a doubled band.
# ---------------------------------------------------------------------------
DT="$OUT/wwtable.txt"
"$GFX" "$TBL" "$OUT/wwtable.ppm" 600 >"$DT" 2>&1 || { echo "[hb-ww] FAIL: table render exited non-zero"; cat "$DT"; exit 1; }
grep -E '^BORDER' "$DT" || true

# left-column cells are BORDER 0 (row1), 2 (row2), 4 (row3): x0==10.
ry() { awk -v i="$1" '$1=="BORDER" && $2==i {for(k=1;k<=NF;k++){if($k=="y0")t=$(k+1);if($k=="y1")b=$(k+1)} print t, b}' "$DT"; }
read r1t r1b < <(ry 0)
read r2t r2b < <(ry 2)
read r3t r3b < <(ry 4)
echo "[hb-ww] (B) left-column cell y-extents: r1=[$r1t,$r1b] r2=[$r2t,$r2b] r3=[$r3t,$r3b]"
if [ -n "$r1b" ] && [ "$r1b" = "$r2t" ] && [ "$r2b" = "$r3t" ]; then
    echo "[hb-ww] PASS (B) internal horizontal rules coincide (r1.bot==r2.top==$r1b, r2.bot==r3.top==$r2b) — single clean line"
else
    echo "[hb-ww] FAIL (B) inter-row rules do not coincide (r1.bot=$r1b r2.top=$r2t ; r2.bot=$r2b r3.top=$r3t) — doubled divider"; fail=1
fi
# Sanity: the rule band is thin (the two adjacent cells meet on one row line, so
# the gap between r1.bot and r2.top is 0 — no fat white band).
gap=$(( r2t - r1b ))
echo "[hb-ww] (B) inter-row gap = $gap px (expect 0)"
if [ "$gap" -eq 0 ]; then
    echo "[hb-ww] PASS (B) zero-width inter-row band (no doubled/thick divider)"
else
    echo "[hb-ww] FAIL (B) inter-row band is $gap px wide (want 0)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-ww] ALL PASS"
    exit 0
fi
echo "[hb-ww] FAILURES above"
exit 1
