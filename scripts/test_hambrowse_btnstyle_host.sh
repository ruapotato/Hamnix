#!/usr/bin/env bash
# scripts/test_hambrowse_btnstyle_host.sh — FAST, QEMU-free gate for CSS-styled
# push-button chrome in the native browser engine (lib/web/dom/forms.ad
# _emit_input is_btn path + lib/htmlpage.ad button paint). An <input type=submit>
# now cascade-matches its OWN author CSS so a styled submit button renders with
# its real background / border colour / border-radius / label colour instead of
# the fixed UA button-grey face + 3px grey chrome.
#
# The fixture (tests/fixtures/hambrowse_btnstyle.html) carries google's real
# home-page rule shape:
#   .T14B5e input[type="submit"]{background-color:#f8f9fa;border:1px solid #f8f9fa;
#                                border-radius:8px;color:#3c4043;...}
# over the two "Google Search" / "I'm Feeling Lucky" submit buttons. The gate reads
# the engine's SEGBTN lines (bg / border colour / radius the painter uses) plus the
# SEG label colour, asserting the button carries the #f8f9fa face, a matching
# #f8f9fa border, an 8px radius and the #3c4043 label — the CSS the buttons ship.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_btnstyle.html"
mkdir -p "$OUT"

echo "[hb-btnstyle] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-btnstyle] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-btnstyle] PASS host harness compiled -> $BIN"

echo "[hb-btnstyle] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-btnstyle] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-btnstyle] PASS native hambrowse still compiles"

fail=0
D="$OUT/btnstyle.txt"
"$BIN" "$FIX" 900 >"$D" 2>&1 || { echo "[hb-btnstyle] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# The two styled submit buttons emit the first two SEGBTN lines.
b0=$(grep -E "^SEGBTN 0 " "$D" | head -1)
b1=$(grep -E "^SEGBTN 1 " "$D" | head -1)
echo "[hb-btnstyle] $b0"
echo "[hb-btnstyle] $b1"

check() { # desc haystack needle
    if printf '%s' "$2" | grep -qF "$3"; then echo "[hb-btnstyle] PASS: $1";
    else echo "[hb-btnstyle] FAIL: $1 — got [$2] want [$3]"; fail=1; fi
}

check "Google Search button face = #f8f9fa"      "$b0" "bg#f8f9fa"
check "Google Search button border = #f8f9fa"    "$b0" "bd#f8f9fa"
check "Google Search button radius = 8px"        "$b0" "rad8"
check "Feeling Lucky button face = #f8f9fa"       "$b1" "bg#f8f9fa"
check "Feeling Lucky button border = #f8f9fa"     "$b1" "bd#f8f9fa"
check "Feeling Lucky button radius = 8px"         "$b1" "rad8"

# Label colour (#3c4043) carried on the button's text segment.
seglbl=$(grep -E "^SEG .*Google Search" "$D" | head -1)
check "Google Search label colour = #3c4043"      "$seglbl" "#3c4043"

if [ "$fail" -ne 0 ]; then echo "[hb-btnstyle] RESULT: FAIL"; exit 1; fi
echo "[hb-btnstyle] RESULT: PASS"
