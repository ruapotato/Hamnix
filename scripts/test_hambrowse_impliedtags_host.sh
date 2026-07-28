#!/usr/bin/env bash
# scripts/test_hambrowse_impliedtags_host.sh — FAST, QEMU-free gate for W3C
# HTML5 tree-construction ROUND 8 in the native browser engine
# (lib/web/dom/forms.ad + lib/web/layout + lib/web/css): IMPLIED / OPTIONAL END
# TAGS (the WHATWG "generate implied end tags" rules) that real pages rely on
# constantly. Proves the tag scanner synthesises the omitted close so mis-nesting
# does not occur:
#
#   (A) <ul><li>a<li>b<li>c</ul>  — an omitted </li> makes each <li> a SIBLING
#       (three distinct rows, each with a bullet marker), not a nested item.
#   (B) <p>text<h2>…</h2>         — a <p> with an omitted </p> is CLOSED by the
#       following block <h2>; the heading is its own paragraph (later row, heading
#       colour + bold), not swallowed inside the paragraph.
#   (C) <p>a<p>b                  — a second <p> implicitly closes the first (two
#       distinct paragraph rows, no style-stack leak).
#   (D) <dl><dt>t<dd>d<dt>…       — <dd> implicitly closes the open <dt> (its bold
#       drops) and a following <dt> closes the open <dd> (its indent drops); the
#       definitions render NON-bold + indented, the terms bold.
#   (E) <tr><td>x<td>y<tr>…       — omitted </td>/</tr> still lay cells side by
#       side on the row and start a fresh row at the next <tr>.
#
# All via SEG readback (row / x / bold flag), NOT glyph ink. Builds BOTH targets
# (host harness x86_64-linux + native hambrowse x86_64-adder-user) so a
# regression in either fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_impliedtags.html"
mkdir -p "$OUT"

echo "[hb-implied] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/implied_compile.log"; then
    echo "[hb-implied] FAIL: host harness did not compile"; cat "$OUT/implied_compile.log"; exit 1
fi
echo "[hb-implied] PASS host harness compiled -> $BIN"

echo "[hb-implied] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/implied_native.log"; then
    echo "[hb-implied] FAIL: native hambrowse did not compile"; cat "$OUT/implied_native.log"; exit 1
fi
echo "[hb-implied] PASS native hambrowse still compiles"

fail=0
D0="$OUT/implied_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-implied] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

# The text-run SEG line for the item whose text is exactly $1 (skip marker segs).
# Fields: SEG <row> <x> #rrggbb b<0|1> u<0|1> s<0|1> l.. bg..
seg_line() { grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | head -1; }
seg_row()  { seg_line "$1" | awk '{print $2}'; }
seg_x()    { seg_line "$1" | awk '{print $3}'; }

grep -E '^SEG ' "$D0" || true

assert_seg() {  # text  regex  message
    local ln; ln="$(seg_line "$1")"
    if [ -z "$ln" ]; then
        echo "[hb-implied] FAIL $3 (no segment for |$1|)"; fail=1; return
    fi
    if echo "$ln" | grep -Eq -- "$2"; then
        echo "[hb-implied] PASS $3"
    else
        echo "[hb-implied] FAIL $3 (seg: $ln)"; fail=1
    fi
}

need() {  # value  message
    if [ -z "$1" ]; then echo "[hb-implied] FAIL $2 (missing segment)"; fail=1; return 1; fi
    return 0
}

# ---- (A) unclosed <li>: three SIBLINGS on distinct rows -------------------
a1="$(seg_row Uno)"; a2="$(seg_row Dos)"; a3="$(seg_row Tres)"
if need "$a1" "li#1 row" && need "$a2" "li#2 row" && need "$a3" "li#3 row" && \
   [ "$a2" -gt "$a1" ] && [ "$a3" -gt "$a2" ]; then
    echo "[hb-implied] PASS unclosed <li>s are siblings on 3 distinct rows ($a1 < $a2 < $a3)"
else
    echo "[hb-implied] FAIL unclosed <li>s did not stack as siblings (rows $a1 $a2 $a3)"; fail=1
fi

# ---- (B) <p> closed by a following block <h2> -----------------------------
# The heading renders in its heading colour + bold — proving it is NOT swallowed
# as inline text inside the still-open paragraph.
assert_seg "Heading" '#14306e b1 ' "<p> closed by <h2>: heading is its own block (colour+bold)"
pr="$(seg_row 'Para closed by a heading')"; hr="$(seg_row Heading)"; ar="$(seg_row After)"
if need "$pr" "para row" && need "$hr" "heading row" && need "$ar" "after row" && \
   [ "$hr" -gt "$pr" ] && [ "$ar" -gt "$hr" ]; then
    echo "[hb-implied] PASS <p>/<h2>/<p> land on 3 ascending rows ($pr < $hr < $ar)"
else
    echo "[hb-implied] FAIL <p>-closed-by-block rows wrong ($pr $hr $ar)"; fail=1
fi

# ---- (C) <p>a<p>b : second <p> implicitly closes the first ----------------
c1="$(seg_row PfirstNoClose)"; c2="$(seg_row PsecondNoClose)"
if need "$c1" "p#1 row" && need "$c2" "p#2 row" && [ "$c2" -gt "$c1" ]; then
    echo "[hb-implied] PASS <p>a<p>b -> two paragraphs on distinct rows ($c1 < $c2)"
else
    echo "[hb-implied] FAIL consecutive <p> did not separate (rows $c1 $c2)"; fail=1
fi

# ---- (D) <dl>: <dd> closes <dt> (bold drops) + <dt> closes <dd> (indent) ---
assert_seg "TermOne" ' b1 '  "<dt> term #1 is bold"
assert_seg "DefOne"  ' b0 '  "<dd> def #1 is NOT bold (implicit </dt> dropped the term's bold)"
assert_seg "TermTwo" ' b1 '  "<dt> term #2 is bold (fresh term after implicit </dd>)"
assert_seg "DefTwo"  ' b0 '  "<dd> def #2 is NOT bold"
dtx="$(seg_x TermOne)"; ddx="$(seg_x DefOne)"
if need "$dtx" "dt x" && need "$ddx" "dd x" && [ "$ddx" -gt "$dtx" ]; then
    echo "[hb-implied] PASS <dd> is indented past <dt> (x $ddx > $dtx)"
else
    echo "[hb-implied] FAIL <dd> not indented past <dt> (x $dtx $ddx)"; fail=1
fi
# The <p> after the <dl> must be flush-left + non-bold — proves the trailing
# <dd>'s indent AND the <dt> bold were both dropped by the implied </dl> close.
assert_seg "AfterDL" ' b0 ' "content after <dl> is non-bold (no <dt> bold leak)"
adx="$(seg_x AfterDL)"
if need "$adx" "afterdl x" && [ "$adx" -lt "$ddx" ]; then
    echo "[hb-implied] PASS content after <dl> is flush-left (x $adx < dd x $ddx; no indent leak)"
else
    echo "[hb-implied] FAIL content after <dl> kept the <dd> indent (x $adx)"; fail=1
fi

# ---- (E) <tr>/<td> with omitted </td>/</tr> -------------------------------
# Cells on the same row sit side by side; the next <tr> starts a fresh row.
ex="$(seg_row Cellx)"; ey="$(seg_row Celly)"; ez="$(seg_row Cellz)"
cxx="$(seg_x Cellx)"; cyx="$(seg_x Celly)"
if need "$ex" "cellx row" && need "$ey" "celly row" && [ "$ex" -eq "$ey" ] && \
   need "$cxx" "cellx x" && need "$cyx" "celly x" && [ "$cyx" -gt "$cxx" ]; then
    echo "[hb-implied] PASS unclosed <td>s sit side by side on row $ex (x $cxx < $cyx)"
else
    echo "[hb-implied] FAIL row-1 cells not side by side (rows $ex $ey, x $cxx $cyx)"; fail=1
fi
if need "$ez" "cellz row" && [ "$ez" -gt "$ex" ]; then
    echo "[hb-implied] PASS unclosed <tr> starts a fresh row ($ez > $ex)"
else
    echo "[hb-implied] FAIL second <tr> did not start a new row (row $ez vs $ex)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-implied] RESULT: FAIL"; exit 1
fi
echo "[hb-implied] RESULT: PASS"
