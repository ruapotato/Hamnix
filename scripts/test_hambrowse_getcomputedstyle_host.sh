#!/usr/bin/env bash
# scripts/test_hambrowse_getcomputedstyle_host.sh — FAST, QEMU-free gate for
# CSSOM window.getComputedStyle(el) RESOLVED / used-value conformance (browser
# W3C campaign). Frameworks and site scripts read getComputedStyle constantly
# (layout measurement, feature detection, animations), so it must return:
#   * COLOURS resolved to rgb() / rgba()  — named + #hex + rgb() -> rgb form.
#   * LENGTHS resolved to USED px          — width:50% of a 400px parent -> 200px;
#                                            margin/padding/font-size in px.
#   * display / position / font-weight (400/700) / visibility / opacity /
#     z-index / font-family computed keywords, with UA defaults when unset.
#   * getPropertyValue(prop) + kebab-case access; '' for an unset/unknown prop.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_getcomputedstyle.html"
mkdir -p "$OUT"

echo "[hb-gcs] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/gcs_compile.log"; then
    echo "[hb-gcs] FAIL: host harness did not compile"; cat "$OUT/gcs_compile.log"; exit 1
fi
echo "[hb-gcs] PASS host harness compiled -> $BIN"

echo "[hb-gcs] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/gcs_native.log"; then
    echo "[hb-gcs] FAIL: native hambrowse did not compile"; cat "$OUT/gcs_native.log"; exit 1
fi
echo "[hb-gcs] PASS native hambrowse still compiles"

fail=0
D0="$OUT/gcs_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-gcs] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-gcs] PASS $2"
    else
        echo "[hb-gcs] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-gcs] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-gcs] PASS $2"
    fi
}

# ---- USED LENGTHS: percentage resolved against the containing block ---------
assert_grep '^JSLOG width 200px$'   "width:50% of a 400px parent resolves to the used 200px (not 50%)"
assert_grep '^JSLOG height 30px$'   "height:30px reports the used 30px"
assert_grep '^JSLOG margin 10px$'   "margin:10px resolves to 10px"
assert_grep '^JSLOG padding 5px$'   "padding:5px resolves to 5px"
assert_grep '^JSLOG fontsize 20px$' "font-size:20px resolves to px"

# ---- COLOURS resolved to rgb() / rgba() -------------------------------------
assert_grep '^JSLOG color rgb\(255, 0, 0\)$'  "color:red -> rgb(255, 0, 0)"
assert_grep '^JSLOG bg rgb\(0, 255, 0\)$'     "background-color:#00ff00 -> rgb(0, 255, 0)"
assert_grep '^JSLOG p_color2 rgb\(0, 0, 255\)$' "named colour blue -> rgb(0, 0, 255)"

# ---- COMPUTED keywords -------------------------------------------------------
assert_grep '^JSLOG display block$'      "display computed (block)"
assert_grep '^JSLOG position relative$'  "position reflects the inline value"
assert_grep '^JSLOG fontweight 700$'     "font-weight:bold -> 700"
assert_grep '^JSLOG visibility hidden$'  "visibility reflects the inline value"
assert_grep '^JSLOG opacity 0.5$'        "opacity reflects the inline value"
assert_grep '^JSLOG zindex 7$'           "z-index reflects the inline value"
assert_grep '^JSLOG fontfamily monospace$' "font-family reports the UA (engine) family"

# ---- getPropertyValue(prop) + kebab access + '' for unset -------------------
assert_grep '^JSLOG gpv_color rgb\(255, 0, 0\)$'   "getPropertyValue('color') == the resolved rgb()"
assert_grep '^JSLOG gpv_fs 20px$'                  "getPropertyValue('font-size') (kebab) works"
assert_grep '^JSLOG gpv_bg rgb\(0, 255, 0\)$'      "getPropertyValue('background-color') resolves"
assert_grep '^JSLOG gpv_unset $'                   "getPropertyValue of an unset custom prop -> '' (empty)"
assert_grep '^JSLOG gpv_this true$'                "getPropertyValue binds this to the declaration object"

# ---- UA DEFAULTS on an unstyled element -------------------------------------
assert_grep '^JSLOG p_display block$'          "unstyled <p> display default (block)"
assert_grep '^JSLOG p_bg rgba\(0, 0, 0, 0\)$'  "background-color default is transparent rgba(0, 0, 0, 0)"
assert_grep '^JSLOG p_margin 0px$'             "margin default 0px"
assert_grep '^JSLOG p_fontsize 16px$'          "font-size default 16px"
assert_grep '^JSLOG p_position static$'        "position default static"
assert_grep '^JSLOG p_visibility visible$'     "visibility default visible"
assert_grep '^JSLOG p_opacity 1$'              "opacity default 1"
assert_grep '^JSLOG p_zindex auto$'            "z-index default auto"
assert_grep '^JSLOG p_fontweight 400$'         "font-weight default 400"
assert_grep '^JSLOG inl_display inline$'       "span display default inline"

# No uncaught JS error anywhere in the script.
assert_nogrep '^JSERR'   "no uncaught JS error across the getComputedStyle script"
assert_nogrep 'Uncaught' "no 'Uncaught' from a missing CSSOM API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-gcs] RESULT: FAIL"; exit 1
fi
echo "[hb-gcs] RESULT: PASS"
