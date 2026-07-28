#!/usr/bin/env bash
# scripts/test_hambrowse_chipbg_host.sh — FAST, QEMU-free gate proving a
# BORDERLESS, BACKGROUND-LESS inline-block paints NO background fill of its own.
#
# WHY THIS GATE EXISTS
#   The inline-block chip painter filled EVERY chip with the ambient (inherited)
#   `g_bg` — re-drawing its ancestor's already-painted background as an opaque
#   box. Invisible when the chip's geometry is exact, but the moment its
#   shrink-wrapped/flex width over-measured (google's search-bar inline
#   children), that redundant fill bled past the rounded pill and read as a
#   "square box behind"/"nested box" artifact. The fix: a chip paints a fill
#   ONLY from its OWN background (cascade m_bg / a bgcolor attr), never the
#   inherited context; a borderless, background-less inline block paints nothing.
#
# The fixture tests/fixtures/hambrowse_chipbg.html puts three inline-block spans
# in a coloured (#3366cc) bar:
#   .plain  no bg / no border         -> NO fill box
#   .inh    background:inherit        -> NO fill box (inherit is not an own bg)
#   .own    background:#cc2222        -> exactly ONE fill box (#cc2222)
# So the ONLY chip-level fill is the single #cc2222 box; the only other fill is
# the bar's own #3366cc container background.
#
# Built with the frozen Python seed compiler + native hambrowse (dual-target).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_chipbg.html"
DUMP="$OUT/chipbg_dump.txt"
mkdir -p "$OUT"
fail=0

echo "[hb-chipbg] compiling pixel backend ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/chipbg_compile.log"; then
    echo "[hb-chipbg] FAIL: driver did not compile"; cat "$OUT/chipbg_compile.log"; exit 1
fi
echo "[hb-chipbg] PASS pixel backend compiled"

echo "[hb-chipbg] compiling native hambrowse ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse.native" 2>"$OUT/chipbg_native.log"; then
    echo "[hb-chipbg] FAIL: native hambrowse did not compile"; cat "$OUT/chipbg_native.log"; exit 1
fi
echo "[hb-chipbg] PASS native hambrowse compiled"

[ -s "$FIX" ] || { echo "[hb-chipbg] FAIL: missing fixture $FIX"; exit 1; }
if ! "$BIN" "$FIX" "$OUT/chipbg.ppm" 640 >"$DUMP" 2>&1; then
    echo "[hb-chipbg] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

# Count declared fill colours across the POSFILL dump.
red=$(grep -Ec '^POSFILL .* col #cc2222 ' "$DUMP" || true)
blue=$(grep -Ec '^POSFILL .* col #3366cc ' "$DUMP" || true)
total=$(grep -Ec '^POSFILL ' "$DUMP" || true)
echo "[hb-chipbg] POSFILL total=$total red(own)=$red blue(bar)=$blue"

if [ "$red" = "1" ]; then
    echo "[hb-chipbg] PASS exactly ONE own-background chip fill (#cc2222)"
else
    echo "[hb-chipbg] FAIL own-background chip fills = $red (want 1)"; fail=1
fi
if [ "$blue" -ge 1 ]; then
    echo "[hb-chipbg] PASS bar container background painted (#3366cc)"
else
    echo "[hb-chipbg] FAIL bar container background missing"; fail=1
fi
# The plain + inherit chips must add NO fills: total fills = 1 own + 1 bar = 2.
if [ "$total" = "2" ]; then
    echo "[hb-chipbg] PASS borderless/background-less inline blocks paint NO fill (no spurious box)"
else
    echo "[hb-chipbg] FAIL POSFILL total=$total (want 2: only .own + .bar) — a chip painted a spurious inherited-bg box"
    grep -E '^POSFILL ' "$DUMP"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-chipbg] RESULT: FAIL"; exit 1; fi
echo "[hb-chipbg] RESULT: PASS"
