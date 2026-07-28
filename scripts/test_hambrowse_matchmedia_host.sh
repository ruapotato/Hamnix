#!/usr/bin/env bash
# scripts/test_hambrowse_matchmedia_host.sh — FAST, QEMU-free gate for
# window.matchMedia(query) — the JS surface of CSS media queries. Backed by the
# @media evaluator (lib/web/css/cascade.ad he_media_match), exposed on window +
# the global scope in lib/web/dom/canvas.ad.
#
# THE GAP: pages/SPAs branch on window.matchMedia('(min-width:...)').matches for
# responsive JS (lazy-loading, layout mode, prefers-color-scheme). The engine
# exposed @media in CSS but had NO matchMedia, so any such script threw
# (matchMedia is not a function) or read undefined.
#
# THE FEATURE: window.matchMedia(query) returns a MediaQueryList whose `.matches`
# is the LIVE evaluation of the query against the viewport (bw x bh) using the
# SAME evaluator as the stylesheet's @media blocks, plus `.media`, `.onchange`,
# and best-effort no-op add/removeListener + add/removeEventListener +
# dispatchEvent (the headless single render has no timeline, so `change` never
# fires — documented static-render scope).
#
# The gate runs one fixture at TWO viewport widths through the DOM host harness
# (user/hambrowse_host.ad) and asserts each query's `.matches` flips per width,
# exactly matching browser semantics. Exact-output oracle on console.log (JSLOG).
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_matchmedia.html"
mkdir -p "$OUT"
fail=0

echo "[hb-mm] compiling DOM host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/mm_compile.log"; then
    echo "[hb-mm] FAIL: host harness did not compile"; cat "$OUT/mm_compile.log"; exit 1
fi
echo "[hb-mm] PASS host harness compiled -> $BIN"

echo "[hb-mm] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/mm_native.elf" 2>"$OUT/mm_native.log"; then
    echo "[hb-mm] FAIL: native hambrowse did not compile"; cat "$OUT/mm_native.log"; exit 1
fi
echo "[hb-mm] PASS native hambrowse still compiles"

render() {  # render <width> -> $OUT/mm_<width>.txt (JSLOG lines only)
    w="$1"; d="$OUT/mm_${w}.txt"
    "$BIN" "$FIX" "$w" 2>&1 | grep -E 'JSLOG|JSERR' > "$d" || true
    echo "$d"
}

assert_line() {  # assert_line <dumpfile> <exact JSLOG payload> <message>
    if grep -qxF "JSLOG $2" "$1"; then
        echo "[hb-mm] PASS $3"
    else
        echo "[hb-mm] FAIL $3 (missing: 'JSLOG $2')"; fail=1
    fi
}

# ---- viewport 880 wide (landscape, > all min-width breakpoints) ------------
D880="$(render 880)"
cat "$D880"
assert_line "$D880" "minw600 true media=(min-width: 600px)" "min-width:600 matches at 880 + .media echoes query"
assert_line "$D880" "maxw500 false"                          "max-width:500 does NOT match at 880"
assert_line "$D880" "bare true"                              "bare global matchMedia() resolves"
assert_line "$D880" "range true"                             "(min-width:600) and (max-width:900) matches at 880"
assert_line "$D880" "screen true"                            "screen and (min-width:400) matches"
assert_line "$D880" "print false"                            "print media type never matches (screen render)"
assert_line "$D880" "dark false"                             "prefers-color-scheme:dark never matches (light render)"
assert_line "$D880" "light true"                             "prefers-color-scheme:light matches"
assert_line "$D880" "orient true"                            "orientation:landscape matches at 880x600"
assert_line "$D880" "listeners-ok true fired=false"          "listener methods no-op (onchange null, change never fires)"

# ---- viewport 400 wide (portrait, below the breakpoints) -------------------
D400="$(render 400)"
cat "$D400"
assert_line "$D400" "minw600 false media=(min-width: 600px)" "min-width:600 does NOT match at 400"
assert_line "$D400" "maxw500 true"                           "max-width:500 matches at 400"
assert_line "$D400" "bare false"                             "bare global matchMedia flips at 400"
assert_line "$D400" "range false"                            "600..900 range out at 400"
assert_line "$D400" "orient false"                           "orientation:landscape false at 400 (portrait)"

# no JS errors at either width
if grep -q 'JSERR' "$D880" "$D400"; then
    echo "[hb-mm] FAIL: JSERR present"; fail=1
else
    echo "[hb-mm] PASS no JS errors"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-mm] RESULT: FAIL"; exit 1
fi
echo "[hb-mm] RESULT: PASS"
