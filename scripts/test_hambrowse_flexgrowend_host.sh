#!/usr/bin/env bash
# scripts/test_hambrowse_flexgrowend_host.sh — FAST, QEMU-free gate for a
# FLEX-GROW SPACER carrying a NESTED right-aligned flex cluster in the native
# browser engine (lib/web/layout/box.ad + lib/web/dom/forms.ad).
#
# This is google.com's top navigation shape: a `display:flex` row holds the
# left-aligned About/Store links, then a `flex-grow:1` SPACER
# (`.AorTac{display:inline-block;flex-grow:1}`) that CONTAINS a nested
# `display:flex; justify-content:flex-end` header holding the right cluster
# (app-grid / sign-in). Two things must hold together:
#
#   (1) the `display:inline-block` on the grow spacer is a FLEX ITEM, so its
#       display is BLOCKIFIED (CSS Flexbox §4) — it stays a flex COLUMN that
#       consumes the row's free space, rather than routing to the inline-block
#       chip path (which shrank it to content and dropped the whole nested
#       cluster into normal flow BELOW the row — the "app grid below the logo"
#       bug).
#   (2) the nested `justify-content:flex-end` flex packs its children flush to
#       the RIGHT edge, on the SAME top row as the left links.
#
# Assertion: About/Store sit top-left on row 0; the nested cluster (APPS +
# SIGNIN) sits on row 0 too, packed against the right edge (cols well past the
# row centre, last fill reaching the 800px content edge).
#
# Builds BOTH targets (host harness + native hambrowse) so a break in either is
# caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-flexgrowend] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexgrowend] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexgrowend] PASS host harness compiled -> $BIN"

echo "[hb-flexgrowend] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexgrowend] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexgrowend] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexgrowend.txt"
"$BIN" tests/fixtures/hambrowse_flexgrowend.html 800 >"$D" 2>&1 \
    || { echo "[hb-flexgrowend] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# Row + col of the first SEG whose text matches $1: SEG <row> <col> ... |text|
seg_row() { grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_col() { grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

AR=$(seg_row About); AC=$(seg_col About)
SR=$(seg_row Store); SC=$(seg_col Store)
PR=$(seg_row APPS);  PC=$(seg_col APPS)
GR=$(seg_row SIGNIN);GC=$(seg_col SIGNIN)
echo "[hb-flexgrowend] About(r$AR,c$AC) Store(r$SR,c$SC) APPS(r$PR,c$PC) SIGNIN(r$GR,c$GC)"

if [ -z "$AR" ] || [ -z "$SR" ] || [ -z "$PR" ] || [ -z "$GR" ]; then
    echo "[hb-flexgrowend] FAIL: a nav element is missing (cluster dropped/hidden)"; cat "$D"; exit 1
fi

# ---- (1) everything on the SAME top row (row 0) ----------------------------
if [ "$AR" = "0" ] && [ "$SR" = "0" ] && [ "$PR" = "0" ] && [ "$GR" = "0" ]; then
    echo "[hb-flexgrowend] PASS left links + right cluster share the top row"
else
    echo "[hb-flexgrowend] FAIL cluster not on the top row (grow spacer collapsed)"; fail=1
fi

# ---- (2) About/Store are top-LEFT (small cols) -----------------------------
if [ "$AC" -lt 100 ] && [ "$SC" -lt 100 ] && [ "$SC" -gt "$AC" ]; then
    echo "[hb-flexgrowend] PASS About/Store packed top-left"
else
    echo "[hb-flexgrowend] FAIL About/Store not top-left (About=$AC Store=$SC)"; fail=1
fi

# ---- (3) the nested cluster is RIGHT-aligned past the row centre ------------
# 800px content width -> centre is 400; the flush-right cluster must start well
# past it, and SIGNIN must sit to the RIGHT of APPS (flex-end DOM order).
if [ "$PC" -gt 400 ] && [ "$GC" -gt "$PC" ] && [ "$PC" -gt "$SC" ]; then
    echo "[hb-flexgrowend] PASS nested justify-content:flex-end cluster is flush-right"
else
    echo "[hb-flexgrowend] FAIL cluster not right-aligned (APPS=$PC SIGNIN=$GC)"; fail=1
fi

# ---- (4) the last cluster fill reaches the right content edge ---------------
# FILL <t> <b> <lx> <rx> #rgb ...  — the sign-in fill's rx must be near 800.
RXMAX=$(grep -E "^FILL 0 " "$D" | awk '{print $5}' | sort -n | tail -1)
echo "[hb-flexgrowend] rightmost fill rx=$RXMAX"
if [ -n "$RXMAX" ] && [ "$RXMAX" -ge 760 ]; then
    echo "[hb-flexgrowend] PASS grow spacer consumed free space to the right edge"
else
    echo "[hb-flexgrowend] FAIL cluster did not reach the right edge (rx=$RXMAX)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexgrowend] RESULT: FAIL"; exit 1
fi
echo "[hb-flexgrowend] RESULT: PASS"
