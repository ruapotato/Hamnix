#!/usr/bin/env bash
# scripts/test_hambrowse_google_host.sh — FAST, QEMU-free gate for the CORE
# google.com interaction in the native browser engine (lib/htmlengine.ad):
# a search form must (a) render its query box + submit button, (b) accept a
# typed query, and (c) SUBMIT to the form's action -> a results URL.
#
# Regression guard for the "you can load google.com but it's not usable" bug:
# _serialize_form dropped the form's `action`, so submitting the search box
# navigated to the current page's "?q=cats" instead of "/search?q=cats" (the
# results page). The fix prepends the action path; this gate asserts the
# NAV target is "/search?q=...", not a bare "?q=...".
#
# Builds with the frozen Python seed compiler for both the host harness
# (x86_64-linux) and the native browser (x86_64-adder-user), so a regression
# in either target fails here without a QEMU boot.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_google.html"
mkdir -p "$OUT"

echo "[hb-google] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-google] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-google] PASS host harness compiled -> $BIN"

echo "[hb-google] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-google] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-google] PASS native hambrowse still compiles"

fail=0
assert_grep() {   # pattern file message
    if grep -Eq -- "$1" "$2"; then
        echo "[hb-google] PASS $3"
    else
        echo "[hb-google] FAIL $3 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern file message
    if grep -Eq -- "$1" "$2"; then
        echo "[hb-google] FAIL $3 (present: $1)"; fail=1
    else
        echo "[hb-google] PASS $3"
    fi
}

# (a) The homepage renders: heading, the query box, and a submit button.
D0="$OUT/g_render.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-google] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
cat "$D0"
assert_grep 'TITLE Google'                       "$D0" "title is Google"
assert_grep '\[cats_+\]'                          "$D0" "query box renders with its value"
assert_grep '\[ Google Search \]'                "$D0" "submit button renders"
# THE noscript FIX: hambrowse runs JS (jsengine is always wired), so the
# <noscript> "Please enable JavaScript" fallback that real sites ship MUST be
# suppressed exactly like a JS-enabled browser. Before the fix this text leaked
# into the render flow (the user's "it tells me to turn on JavaScript" bug) and
# added a stray block that skewed the layout.
assert_nogrep 'enable JavaScript'                "$D0" "noscript 'enable JavaScript' fallback is NOT rendered (JS is on)"
assert_nogrep 'does not support it'              "$D0" "noscript fallback body is fully skipped"

# (b) Typing a query updates the box (oninput/DOM value flows to the render).
D1="$OUT/g_type.txt"
"$BIN" "$FIX" 880 setval q "plan 9 os" >"$D1" 2>&1
assert_grep '\[plan 9 os_+\]'                    "$D1" "typed query appears in the (20-col UA default) box"

# (c) THE FIX: submitting the search form navigates to the action's results
# URL (/search?q=...), carrying the query — NOT a bare "?q=..." on the
# homepage. This is what made google "unusable" before.
D2="$OUT/g_submit.txt"
"$BIN" "$FIX" 880 submit tsf >"$D2" 2>&1
cat "$D2" | grep -E 'SUBMIT|NAV' || true
assert_grep '^NAV /search\?q=cats'               "$D2" "submit navigates to /search?q=cats (action path prepended)"
assert_grep 'hl=en'                              "$D2" "hidden field carried into the results URL"
# Regression: the NAV must carry the action path, never a bare '?q='.
assert_nogrep '^NAV \?q='                        "$D2" "NAV is not a bare ?q= (action dropped) regression"

# (d) THE FRONT-END WIRING (#216): the native front-end no longer drives the
# engine by element id — it hit-tests a pointer click to a DOM element INDEX,
# classifies it (text field vs submit button), types into it by index, resolves
# the enclosing <form>, submits, and consumes he_nav_*. The `fieldnav` verb runs
# that exact index-based chain (with click-links on, so fields are wrapped in
# the "#__evt_N" links the pointer hit-test resolves). This guards the path the
# user actually exercises on-device: click box -> type -> Enter -> navigate.
D3="$OUT/g_fieldnav.txt"
"$BIN" "$FIX" 880 fieldnav q "plan 9 os" >"$D3" 2>&1
grep -E 'FIELDNAV' "$D3" || true
assert_grep '^FIELDNAV id=q idx=[0-9]+ textfield=1' \
    "$D3" "the query control classifies as a text field (focus/typing target)"
assert_grep '^FIELDNAV form=[0-9]+' \
    "$D3" "the field's enclosing <form> resolves by index"
assert_grep '^FIELDNAV NAV /search\?q=plan\+9\+os' \
    "$D3" "index-based type+submit navigates to /search?q=plan+9+os (front-end path)"
assert_grep 'hl=en'                              "$D3" "hidden field carried on the index path"
# The field is now pointer-reachable: after the click-links re-layout its box
# segment carries a link (l>=0), so the front-end's _hit_link resolves it.
assert_grep '\[plan 9 os_+\] *\|' "$D3" "typed text renders in the field box (set_value_index)"

# (e) UA: the HTTP client must present a browser-like "Mozilla/5.0" User-Agent
# so sites that sniff the UA (Google) serve the modern scripting variant rather
# than a degraded no-JS page. Static guard on the request builder.
assert_grep 'User-Agent: Mozilla/5\.0'           "user/http9.ad" "http9 sends a browser-like Mozilla User-Agent"

# (f) #317 REAL-GOOGLE SCRIPT COMPAT: a fixture shaped like google.com's inline
# scripts (labeled block+break, |=, .call, switch, for-in, window.google) plus
# SCRIPT ISOLATION — an early <script> deliberately throws and must NOT stop the
# later script that wires the page. The final script computes a status via
# textContent, so a clean run is visible in the render as "g5-five-k2".
D4="$OUT/g_scripts.txt"
"$BIN" "tests/fixtures/hambrowse_google_js.html" 880 >"$D4" 2>&1
grep -E 'JSLOG|g5-five-k2' "$D4" || true
assert_grep 'g5-five-k2' "$D4" \
    "google-shaped scripts run end-to-end (labeled block/|=/.call/switch/for-in/window.google)"
assert_nogrep 'SyntaxError' "$D4" \
    "no SyntaxError: void/delete/switch/labels/compound-assign/for-in all parse"
# The status text was REPLACED by the final script (proving script isolation:
# the earlier deliberate throw did not abort the wiring), so the placeholder is
# gone from the render.
assert_nogrep '\|pending\|' "$D4" \
    "final script ran despite the earlier throw (status placeholder replaced)"

# (g) #317 NAME-BASED FIELD RESOLUTION: real google identifies its query control
# by `name="q"` (no id) inside `<form name="f">`. The native type+submit chain
# must fall back to `name`, classify it as a text field, resolve the enclosing
# form, and navigate to /search?q=... — proven against the id-less shape.
D5="$OUT/g_named.txt"
"$BIN" "tests/fixtures/hambrowse_google_named.html" 880 fieldnav q "plan 9 os" >"$D5" 2>&1
grep -E 'FIELDNAV' "$D5" || true
assert_grep '^FIELDNAV id=q idx=[0-9]+ textfield=1' "$D5" \
    "id-less query field resolves by name= and classifies as a text field"
assert_grep '^FIELDNAV NAV /search\?q=plan\+9\+os' "$D5" \
    "type+submit on a name-only field navigates to /search?q=plan+9+os (real-google shape)"

# (h) BIG-PAGE SOURCE CAP (desktop google.com renders BLANK regression): the
# full desktop google.com is ~1.5 MB because it ships ~1.1 MB of inline JS
# BEFORE the visible <body>. The engine's working-source buffer (_strip_comments
# cs_buf) used to cap at 256 KiB, so everything past byte 262144 — including the
# entire rendered body — was silently truncated away. With JS on this looked
# exactly like "the script wiped the DOM" (textrows 0) while the JS-stripped page
# (small enough to fit) rendered fine. The fix raises the source cap to 4 MiB.
# This gate distills the pattern: a >256 KiB inline <script> followed by a
# sentinel paragraph that MUST still render.
BIG="$OUT/g_bigpage.html"
{
  printf '<!doctype html><html><head><title>Big</title>'
  printf '<script>var _pad="'
  # ~300 KiB of filler inside a string literal (well past the old 256 KiB cap)
  yes 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123' \
    | head -c 300000 | tr -d '\n'
  printf '";window._ok=1;</script></head><body>'
  printf '<p>BIGPAGE_SENTINEL_TEXT_VISIBLE</p></body></html>'
} > "$BIG"
D6="$OUT/g_bigpage.txt"
"$BIN" "$BIG" 880 >"$D6" 2>&1
assert_grep 'BIGPAGE_SENTINEL_TEXT_VISIBLE' "$D6" \
    "content AFTER a >256 KiB inline script still renders (source not truncated)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-google] RESULT: FAIL"; exit 1
fi
echo "[hb-google] RESULT: PASS"
