#!/usr/bin/env bash
# scripts/test_hambrowse_flexgap_host.sh — FAST, QEMU-free gate for the round-5
# web-standards rungs in the native browser engine (lib/htmlengine.ad):
#
#   (1) AUTHOR LINK COLOUR — a styled anchor (`a{color:…}` / `.nav a{color:…}` /
#       inline style="color:…") now overrides the default link blue, while a
#       PLAIN link keeps its blue role colour AND an inherited ancestor colour
#       (body{color:…}) does NOT leak onto plain links. Correctness win affecting
#       virtually every themed site whose links are not default blue.
#
#   (2) FLEX `gap` / `column-gap` — an author `gap:<n>px` on a `display:flex`
#       container is honoured as the inter-item gutter instead of the fixed 8px
#       default (nav bars / button rows / chip strips with custom spacing).
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-flexgap] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexgap] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexgap] PASS host harness compiled -> $BIN"

echo "[hb-flexgap] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexgap] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexgap] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexgap.txt"
"$BIN" tests/fixtures/hambrowse_flexgap.html 800 >"$D" 2>&1 \
    || { echo "[hb-flexgap] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# ---- (2) custom gap (40px) widens the inter-item advance ----------------------
# "wide" row: One@108, then +width(3*8=24)+gap(40) => Two@172, Three@236.
mapfile -t WIDEX < <(grep -E 'SEG [0-9]+ [0-9]+ #cc2244 .*\|(One|Two|Three)\|' "$D" | awk '{print $3}')
if [ "${#WIDEX[@]}" -lt 3 ]; then
    echo "[hb-flexgap] FAIL: wide row links missing (got ${#WIDEX[@]})"; grep -E '#cc2244' "$D"; exit 1
fi
echo "[hb-flexgap] wide (gap:40) x: One=${WIDEX[0]} Two=${WIDEX[1]} Three=${WIDEX[2]}"
if [ "$(( WIDEX[1] - WIDEX[0] ))" -eq 64 ] && [ "$(( WIDEX[2] - WIDEX[1] ))" -eq 64 ]; then
    echo "[hb-flexgap] PASS custom gap:40px honoured (advance 24w+40gap=64)"
else
    echo "[hb-flexgap] FAIL custom gap not applied (expected advance 64)"; fail=1
fi

# ---- default gap (8px) unchanged ---------------------------------------------
mapfile -t TIGHTX < <(grep -E 'SEG [0-9]+ [0-9]+ #118844 .*\|(One|Two|Three)\|' "$D" | awk '{print $3}')
echo "[hb-flexgap] tight (default gap) x: One=${TIGHTX[0]} Two=${TIGHTX[1]} Three=${TIGHTX[2]}"
if [ "$(( TIGHTX[1] - TIGHTX[0] ))" -eq 32 ]; then
    echo "[hb-flexgap] PASS default gap stays 8px (advance 24w+8gap=32)"
else
    echo "[hb-flexgap] FAIL default gap changed (expected advance 32)"; fail=1
fi

# ---- (1) author link colour overrides default blue ---------------------------
if [ "${#WIDEX[@]}" -ge 3 ]; then
    echo "[hb-flexgap] PASS author link colour #cc2244 applied to flex links"
else
    echo "[hb-flexgap] FAIL author link colour not applied"; fail=1
fi
if grep -Eq 'SEG [0-9]+ [0-9]+ #118844 .*\|One\|' "$D"; then
    echo "[hb-flexgap] PASS second author link colour #118844 applied"
else
    echo "[hb-flexgap] FAIL second author link colour missing"; fail=1
fi

# ---- plain link stays blue; body colour does NOT leak onto it ----------------
if grep -Eq 'SEG [0-9]+ [0-9]+ #1a4fd0 .*\|( plainlink|plainlink)\|' "$D"; then
    echo "[hb-flexgap] PASS plain link keeps default blue (#1a4fd0, no body-colour leak)"
else
    echo "[hb-flexgap] FAIL plain link lost its default blue"; grep -E 'plainlink' "$D"; fail=1
fi
# control: the body colour DID apply to non-link text.
if grep -Eq 'SEG [0-9]+ [0-9]+ #333333 .*\|text\|' "$D"; then
    echo "[hb-flexgap] PASS body colour applies to ordinary text"
else
    echo "[hb-flexgap] FAIL body colour missing on ordinary text"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexgap] RESULT: FAIL"; exit 1
fi
echo "[hb-flexgap] RESULT: PASS"
