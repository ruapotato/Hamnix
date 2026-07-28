#!/usr/bin/env bash
# scripts/test_hambrowse_stylemedia_host.sh — FAST, QEMU-free gate proving Chrome-
# parity for the RESPONSIVE `<style media="…">` ELEMENT ATTRIBUTE (the responsive
# stylesheet idiom used by MDN/news/marketing sites that ship a desktop nav AND a
# mobile nav and gate one of them via a media-attributed <style>/<link> block):
#
#   a `<style media="(max-width: 799px)">` block applies its rules ONLY when the
#   live viewport matches the query (the SAME semantics as wrapping the body in
#   `@media (max-width: 799px) { … }`), instead of being applied UNCONDITIONALLY.
#
# Before the fix, cascade.ad `_collect_css` scanned the <style> opening tag but
# ignored its `media` attribute, so a media-gated block always cascaded — a
# `media="(max-width:799px)"` `display:none` hid the desktop nav even on a WIDE
# viewport (both navs mangled, article pushed down / element wrongly collapsed).
# The fix reads the element's `media` attr and evaluates it via the existing
# _media_matches (live bw×bh viewport); a non-matching block is skipped, a
# matching one still applies (BOTH directions gated).
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports each painted background box
# as `POSFILL <i> z <z> x0 .. y0 .. col #RRGGBB ...`. The fixture paints three
# nav bars: RED .mq (hidden by a max-width block when narrow), GREEN .rev
# (revealed by a min-width block when wide), BLUE .ctl (no media attr — always
# shown). We render the SAME page at TWO widths and assert which bars appear —
# so the gate is discriminating on the VIEWPORT, not a constant. No net, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-stylemedia] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/stylemedia_compile.log"; then
    echo "[hb-stylemedia] FAIL: driver did not compile"; cat "$OUT/stylemedia_compile.log"; exit 1
fi

FIX="tests/fixtures/hambrowse_stylemedia.html"
WIDE_DUMP="$OUT/stylemedia_wide.txt"
NARROW_DUMP="$OUT/stylemedia_narrow.txt"
"$BIN" "$FIX" "$OUT/stylemedia_wide.ppm"   1000 >"$WIDE_DUMP"   2>&1 || { echo "[hb-stylemedia] FAIL: wide render nonzero";   cat "$WIDE_DUMP";   exit 1; }
"$BIN" "$FIX" "$OUT/stylemedia_narrow.ppm"  640 >"$NARROW_DUMP" 2>&1 || { echo "[hb-stylemedia] FAIL: narrow render nonzero"; cat "$NARROW_DUMP"; exit 1; }

# 1 iff a POSFILL box of colour $2 exists in dump $1, else 0.
has_box() { awk -v want="$2" 'BEGIN{f=0}/^POSFILL/{c="";for(i=1;i<=NF;i++)if($i=="col")c=$(i+1);if(c==want)f=1}END{print f}' "$1"; }

RED="#cc0000"    # .mq  — desktop nav, hidden by max-width block when narrow
GREEN="#00cc00"  # .rev — wide-only nav, revealed by min-width block when wide
BLUE="#0000cc"   # .ctl — control, no media attr, always shown

W_RED=$(has_box "$WIDE_DUMP" "$RED");   W_GREEN=$(has_box "$WIDE_DUMP" "$GREEN");   W_BLUE=$(has_box "$WIDE_DUMP" "$BLUE")
N_RED=$(has_box "$NARROW_DUMP" "$RED"); N_GREEN=$(has_box "$NARROW_DUMP" "$GREEN"); N_BLUE=$(has_box "$NARROW_DUMP" "$BLUE")

echo "[hb-stylemedia] WIDE(1000):  mq(RED)=$W_RED rev(GREEN)=$W_GREEN ctl(BLUE)=$W_BLUE  (want 1 0 1)"
echo "[hb-stylemedia] NARROW(640):  mq(RED)=$N_RED rev(GREEN)=$N_GREEN ctl(BLUE)=$N_BLUE  (want 0 1 1)"

# --- WIDE: max-width block must NOT match => desktop .mq SHOWS ------------------
if [ "$W_RED" = "1" ]; then
    echo "[hb-stylemedia] PASS wide: max-width \"(max-width:799px)\" block skipped, .mq nav shows"
else
    echo "[hb-stylemedia] FAIL wide: .mq nav hidden — media-attr block applied unconditionally"; fail=1
fi

# --- WIDE: min-width block MUST match => .rev revealed (matching block applies) -
if [ "$W_GREEN" = "1" ]; then
    echo "[hb-stylemedia] PASS wide: min-width \"(min-width:800px)\" block applied, .rev nav revealed"
else
    echo "[hb-stylemedia] FAIL wide: min-width block did not apply — matching media wrongly ignored"; fail=1
fi

# --- NARROW: max-width block MUST match => desktop .mq HIDDEN (collapse) --------
if [ "$N_RED" = "0" ]; then
    echo "[hb-stylemedia] PASS narrow: max-width block applied, .mq nav collapses (display:none honored)"
else
    echo "[hb-stylemedia] FAIL narrow: .mq nav still shows — matching media block not applied"; fail=1
fi

# --- NARROW: min-width block must NOT match => .rev stays hidden ----------------
if [ "$N_GREEN" = "0" ]; then
    echo "[hb-stylemedia] PASS narrow: min-width block skipped, .rev nav stays hidden"
else
    echo "[hb-stylemedia] FAIL narrow: .rev nav shown — non-matching media block applied"; fail=1
fi

# --- CONTROL: a no-media <style> always applies at BOTH widths ------------------
if [ "$W_BLUE" = "1" ] && [ "$N_BLUE" = "1" ]; then
    echo "[hb-stylemedia] PASS control: no-media <style> always applies (BLUE at both widths) — gating is scoped"
else
    echo "[hb-stylemedia] FAIL control: no-media <style> not applied (wide=$W_BLUE narrow=$N_BLUE)"; fail=1
fi

# --- native hambrowse still compiles ------------------------------------------
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse.ad -o "$OUT/hambrowse_native_stylemedia" 2>"$OUT/stylemedia_native.log"; then
    echo "[hb-stylemedia] PASS native hambrowse compiles"
else
    echo "[hb-stylemedia] FAIL native hambrowse did not compile"; cat "$OUT/stylemedia_native.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-stylemedia] RESULT: PASS"
else
    echo "[hb-stylemedia] RESULT: FAIL"; exit 1
fi
