#!/usr/bin/env bash
# scripts/test_hamsheet_host.sh — FAST, QEMU-free host gate for HamSheet, the
# office SPREADSHEET (lib/hamsheetcore.ad drawn through lib/hamscene.ad +
# rasterized by lib/hamui_host.ad). It renders the empty grid (HamSheet title
# bar + formula bar + A/B/C… column headers + 1/2/3… row headers), enters
# numbers into A1/A2/A3 and a =SUM(A1:A3) formula into B1 (plus AVG / a cell
# arithmetic expression / MAX / COUNT), asserts the COMPUTED results, renders the
# populated grid, SAVES it (Ctrl-S -> a HAMSHEET2 container on a real scratch
# file), CLEARS the sheet, then RE-OPENS the file off disk (Ctrl-O) — proving the
# cell text AND the formulas survive a save->load round-trip and RECOMPUTE to the
# same values.
#
# It then drives the FULL spreadsheet feature set through the same shipping core:
# every formula function (IF/AND/OR/NOT/IFERROR/ROUND/ABS/SQRT/POWER/MOD/LEN/
# LEFT/RIGHT/MID/UPPER/CONCAT/COUNTIF/SUMIF), string literals, the & concat and
# comparison operators, typed error values (#DIV/0! #NAME? #CIRC! #REF!),
# ABSOLUTE refs surviving a fill-down, copy/paste with reference ADJUSTMENT,
# insert/delete row re-pointing formulas, multi-level UNDO, number formats
# (currency/percent/thousands/decimals) + bold + column width, their round-trip
# through the document container, backward compatibility with the older
# HAMSHEET1 container, and CSV export/import (including comma quoting).
# Two PNGs a human/agent can LOOK at are produced, and the NATIVE Hamnix build is
# confirmed to still compile from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsheet_host"
DOC="$OUT/hamsheet_scratch.hsheet"
mkdir -p "$OUT"
rm -f "$DOC"
fail=0

echo "[hamsheet-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsheet_host.ad -o "$BIN" 2>"$OUT/hs_compile.log"; then
    echo "[hamsheet-host] FAIL: host harness did not compile"; cat "$OUT/hs_compile.log"; exit 1
fi
echo "[hamsheet-host] PASS host harness compiled -> $BIN"

echo "[hamsheet-host] compiling NATIVE hamsheet for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamsheet.ad -o "$OUT/hamsheet_native.elf" 2>"$OUT/hs_native.log"; then
    echo "[hamsheet-host] FAIL: native hamsheet did not compile"; cat "$OUT/hs_native.log"; exit 1
fi
echo "[hamsheet-host] PASS native hamsheet still compiles"

DUMP="$OUT/hs_dump.txt"
if ! "$BIN" "$DOC" "$OUT/hs_before.ppm" "$OUT/hs_after.ppm" >"$DUMP" 2>&1; then
    echo "[hamsheet-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hs_$f.ppm" "$OUT/hs_$f.png" 2>"$OUT/hs_png.log"; then
        echo "[hamsheet-host] PASS rendered $OUT/hs_$f.png"
    else
        echo "[hamsheet-host] FAIL png conversion ($f)"; cat "$OUT/hs_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamsheet-host] PASS $2";
    else echo "[hamsheet-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- window chrome / formula bar / grid headers ----------------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 600 384 #dfe3e8'         "hamsheet window background"
assert_grep '^fill 0 0 600 22 #2f7d54'          "green title bar"
assert_grep 'glyphs .*"HamSheet"'               "app title label"
assert_grep 'glyphs .*"budget.hsheet"'          "filename shown in the title bar"
assert_grep 'glyphs .*"Open"'                   "Open toolbar button rendered"
assert_grep 'glyphs .*"Save"'                   "Save toolbar button rendered"
assert_grep 'glyphs .*"A" #'                    "column header A rendered"
assert_grep 'glyphs .*"B" #'                    "column header B rendered"

# --- formula engine: computed values (scaled by 10^6) ----------------------
assert_grep '^SUM_FP 60000000'                  "=SUM(A1:A3) computed 60"
assert_grep '^AVG_FP 20000000'                  "=AVG(A1:A3) computed 20"
assert_grep '^EXPR_FP 50000000'                 "=A1+A2*2 computed 50 (precedence)"
assert_grep '^MAX_FP 30000000'                  "=MAX(A1:A3) computed 30"
assert_grep '^COUNT_FP 3000000'                 "=COUNT(A1:A3) computed 3"
assert_grep '^SUM_DISP 60'                       "SUM displays as \"60\""
assert_grep '^AVG_DISP 20'                       "AVG displays as \"20\""
assert_grep '^EXPR_DISP 50'                      "expression displays as \"50\""
assert_grep '^A4_KIND 2'                         "A4 (\"Total\") classified as TEXT"
# The populated grid must actually DRAW the computed SUM value.
assert_grep 'glyphs [0-9]+ [0-9]+ "60" #'        "computed 60 drawn in the grid"
assert_grep 'glyphs [0-9]+ [0-9]+ "Total" #'     "text label \"Total\" drawn in the grid"

# --- SAVE writes a HAMSHEET1 container to disk -----------------------------
assert_grep '^FILE_LEN [0-9][0-9][0-9]'         "Ctrl-S wrote the document container (>=100 bytes)"

# --- CLEAR + RE-OPEN off disk: round-trip proof ----------------------------
assert_grep '^SUM_AFTER_CLEAR 0'                "sheet cleared before reopen"
assert_grep '^SUM_AFTER_OPEN 60000000'          "Ctrl-O reloaded + recomputed =SUM to 60"
assert_grep '^EXPR_AFTER_OPEN 50000000'         "the cell-arithmetic formula survived the round-trip"

# --- keyboard type-to-edit + recalc cascade --------------------------------
assert_grep '^A1_AFTER_TYPE 5000000'            "typing \"5\"+Enter set A1 to 5 via the key path"
assert_grep '^SUM_AFTER_EDIT 55000000'          "dependent =SUM(A1:A3) recalculated to 55"

# --- the reloaded B1 raw formula matches exactly ---------------------------
if awk '/^B1RAW-BEGIN$/{f=1;next} /^B1RAW-END$/{f=0} f' "$DUMP" \
        | grep -qx '=SUM(A1:A3)'; then
    echo "[hamsheet-host] PASS reloaded B1 formula is byte-exact (=SUM(A1:A3))"
else
    echo "[hamsheet-host] FAIL reloaded B1 formula mismatch"; fail=1
fi

# --- the document file really exists on disk with the magic ----------------
if [ -s "$DOC" ]; then echo "[hamsheet-host] PASS $DOC written on disk";
else echo "[hamsheet-host] FAIL document not written to $DOC"; fail=1; fi
if head -c 9 "$DOC" | grep -qx 'HAMSHEET2'; then
    echo "[hamsheet-host] PASS document carries the HAMSHEET2 magic";
else echo "[hamsheet-host] FAIL document missing HAMSHEET2 magic"; fail=1; fi


# --- formula engine DEPTH: functions, strings, booleans, comparisons -------
assert_grep '^FN_IF small'                       "IF(A1>10,\"big\",\"small\") -> small"
assert_grep '^FN_ROUND 0\.67'                    "ROUND(2/3,2) -> 0.67"
assert_grep '^FN_ABS 7'                          "ABS(0-7) -> 7"
assert_grep '^FN_SQRT 4'                         "SQRT(16) -> 4"
assert_grep '^FN_POWER 1024'                     "POWER(2,10) -> 1024"
assert_grep '^FN_MOD 1'                          "MOD(7,3) -> 1"
assert_grep '^FN_CARET 9'                        "=2^3+1 -> 9 (power binds tighter than +)"
assert_grep '^FN_LEN 5'                          "LEN(\"hello\") -> 5"
assert_grep '^FN_LEFTRIGHT ham-ix'               "LEFT/RIGHT joined with & -> ham-ix"
assert_grep '^FN_MID sheet'                      "MID(\"spreadsheet\",7,5) -> sheet"
assert_grep '^FN_UPPER OK'                       "UPPER(\"ok\") -> OK"
assert_grep '^FN_AND TRUE'                       "AND(1>0,2>1) -> TRUE"
assert_grep '^FN_OR FALSE'                       "OR(FALSE,FALSE) -> FALSE"
assert_grep '^FN_NOT FALSE'                      "NOT(TRUE) -> FALSE"
assert_grep '^FN_CONCAT abc'                     "CONCAT(\"a\",\"b\",\"c\") -> abc"
assert_grep '^FN_IFERROR 42'                     "IFERROR(1/0,42) -> 42 (lazy error)"
assert_grep '^FN_COUNTIF 2'                      "COUNTIF(A1:A3,\">10\") -> 2"
assert_grep '^FN_SUMIF 50'                       "SUMIF(A1:A3,\">10\") -> 50"
assert_grep '^OP_AMP x5'                         "=\"x\"&5 concatenates -> x5"
assert_grep '^OP_EQ TRUE'                        "=3=3 -> TRUE (boolean value)"
assert_grep '^OP_GE TRUE'                        "=A1>=5 -> TRUE"
assert_grep '^OP_PARENS 9'                       "=(1+2)*3 -> 9 (parens)"
assert_grep '^OP_CMPAGG TRUE'                    "=AVG(A1:A3)>10 -> TRUE"

# --- typed ERROR VALUES ----------------------------------------------------
assert_grep '^ERR_DIV0 #DIV/0!'                  "=1/0 reports #DIV/0!"
assert_grep '^ERR_NAME #NAME\?'                  "=FOO(1) reports #NAME?"
assert_grep '^ERR_CIRC #CIRC!'                   "a self-referencing cell reports #CIRC!"

# --- absolute refs + FILL DOWN with reference adjustment -------------------
assert_grep '^FILL_RAW_F3 =E3\*\$H\$1'           "fill-down rewrote E1->E3 and KEPT \$H\$1 absolute"
assert_grep '^FILL_VAL_F2 20'                    "filled F2 computes 2*10 = 20"
assert_grep '^FILL_VAL_F3 30'                    "filled F3 computes 3*10 = 30"
assert_grep '^PASTE_RAW_F5 =E5\*\$H\$1'          "copy/paste adjusted the relative ref (E1->E5)"

# --- insert / delete row re-points formulas --------------------------------
assert_grep '^ROWOPS_BEFORE 200'                 "=B10*2 computes 200 before the row ops"
assert_grep '^INSROW_RAW =B11\*2'                "insert-row re-pointed =B10*2 -> =B11*2"
assert_grep '^INSROW_VAL 200'                    "the re-pointed formula still computes 200"
assert_grep '^DELROW_RAW =B10\*2'                "delete-row re-pointed the formula back"
assert_grep '^DELROW_VAL 200'                    "value preserved across insert+delete row"
assert_grep '^DELROW_REF #REF!'                  "deleting the REFERENCED row yields #REF!"

# --- undo ------------------------------------------------------------------
assert_grep '^UNDO_ROWOPS 200'                   "Ctrl-Z undid the whole delete-row group"
assert_grep '^UNDO_ROWOPS_RAW =B10\*2'           "undo restored the formula text too"
assert_grep '^UNDO_BEFORE 77'                    "typed 77 into C1"
if grep -Eq '^UNDO_AFTER *$' "$DUMP"; then
    echo "[hamsheet-host] PASS Ctrl-Z undid the typed edit (C1 empty again)"
else echo "[hamsheet-host] FAIL undo of the typed edit"; fail=1; fi

# --- number formats / bold / column width ----------------------------------
assert_grep '^FMT_CURRENCY \$1,234\.50'          "currency format renders \$1,234.50"
assert_grep '^FMT_PERCENT 12\.50%'               "percent format renders 12.50%"
assert_grep '^FMT_THOUSANDS 9,876\.54'           "thousands format renders 9,876.54"
assert_grep '^FMT_2DP 3\.00'                     "2-decimal format renders 3.00"
assert_grep '^FMT_BOLD_BIT 12'                   "Ctrl-B set the bold bit on the format byte"
assert_grep '^COLW_A 80'                         "Ctrl-W widened column A to 80px"

# --- save / re-open round-trips formats, widths AND formulas ---------------
assert_grep '^RT_CURRENCY \$1,234\.50'           "currency format survived save->load"
assert_grep '^RT_ABSREF =E3\*\$H\$1'             "absolute reference survived save->load"
assert_grep '^RT_IF small'                       "the IF() formula recomputed after reload"
assert_grep '^RT_COLW_A 80'                      "column width survived save->load"
assert_grep '^RT_FMT_BITS 12'                    "per-cell format bits survived save->load"

# --- backward compatibility with the old HAMSHEET1 container ---------------
assert_grep '^V1_A1 42'                          "a legacy HAMSHEET1 document still loads"
assert_grep '^V1_B1 84'                          "its formula recomputes (=A1*2 -> 84)"

# --- CSV export / import ---------------------------------------------------
if awk '/^CSV-BEGIN$/{f=1;next} /^CSV-END$/{f=0} f' "$DUMP" | grep -qx 'Item,Qty'; then
    echo "[hamsheet-host] PASS CSV export wrote the header row"
else echo "[hamsheet-host] FAIL CSV export header"; fail=1; fi
if awk '/^CSV-BEGIN$/{f=1;next} /^CSV-END$/{f=0} f' "$DUMP" | grep -qx '"nut, bolt",3'; then
    echo "[hamsheet-host] PASS CSV export QUOTED the field containing a comma"
else echo "[hamsheet-host] FAIL CSV quoting"; fail=1; fi
if awk '/^CSV-BEGIN$/{f=1;next} /^CSV-END$/{f=0} f' "$DUMP" | grep -qx 'Total,6'; then
    echo "[hamsheet-host] PASS CSV export emitted the COMPUTED formula value"
else echo "[hamsheet-host] FAIL CSV computed value"; fail=1; fi
assert_grep '^CSVIN_A2 nut, bolt'                "CSV import round-tripped the quoted field"
assert_grep '^CSVIN_B3 6'                        "CSV import round-tripped the numeric column"

# --- the new chrome is actually drawn --------------------------------------
assert_grep 'glyphs .*"CSV"'                     "CSV toolbar button rendered"
assert_grep 'glyphs .*"fx"'                      "formula-bar fx label rendered"
assert_grep 'glyphs .*"\^Z undo \^C/\^V \^D fill"' "status-bar key hints rendered"

if [ "$fail" -ne 0 ]; then echo "[hamsheet-host] OVERALL FAIL"; exit 1; fi
echo "[hamsheet-host] OVERALL PASS"
