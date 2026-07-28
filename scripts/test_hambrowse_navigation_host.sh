#!/usr/bin/env bash
# scripts/test_hambrowse_navigation_host.sh — FAST, QEMU-free gate for the
# browser-USABILITY tier: link click-navigation + form submission (GET query AND
# POST body). The genuine gap this campaign closed was the FRONT-END glue in
# user/hambrowse.ad — link clicks resolve an <a href> against the current URL and
# _fetch it (already wired), and a form submit now routes GET vs POST correctly:
#   * a GET  submit fetches "action?a=1&b=2" (http_get)
#   * a POST submit fetches the bare "action" and sends "a=1&b=2" as the
#     application/x-www-form-urlencoded request BODY (http_post) — previously the
#     front-end ignored the method and sent every submit as a GET.
#
# The real over-the-wire round-trip is proven by the on-device sibling
# (test_hambrowse_navigation_ondevice.sh); http9 needs the Plan 9 /net stack, so
# this QEMU-free gate proves the two host-observable halves of the same contract:
#   (A) both targets COMPILE — the native browser (x86_64-adder-user), which
#       carries the new _navigate_form/_fetch_post/--click-link glue, and the host
#       harness (x86_64-linux). A regression in either fails here with no boot.
#   (B) the ENGINE serialization the front-end consumes is correct: a captured
#       <a href> link is a clickable link-table entry (the target of _navigate);
#       a GET form serializes to "action?query"; a POST form serializes to a bare
#       action + a NAV POST line + a urlencoded BODY line. These are the exact
#       he_nav_* values _fetch/_fetch_post branch on.
#
# DEFERRED (documented, not exercised): fragment-only (#id) scroll, target=_blank,
# multipart/FormData file upload, JS-driven SPA navigation (location.assign).
#
# Exact-output oracle on the host harness's LAYOUT / SEG / NAV / BODY lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-nav] compiling native hambrowse for x86_64-adder-user ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/nav_native.log"; then
    echo "[hb-nav] FAIL: native hambrowse (nav glue) did not compile"; cat "$OUT/nav_native.log"; exit 1
fi
echo "[hb-nav] PASS native hambrowse compiles (link-nav + form GET/POST glue)"

echo "[hb-nav] compiling host harness for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/nav_compile.log"; then
    echo "[hb-nav] FAIL: host harness did not compile"; cat "$OUT/nav_compile.log"; exit 1
fi
echo "[hb-nav] PASS host harness compiled -> $BIN"

fail=0
FL="$OUT/nav_link.txt"
FG="$OUT/nav_get.txt"
FP="$OUT/nav_post.txt"
"$BIN" tests/fixtures/hambrowse_navlink.html   880 >"$FL" 2>&1 || { echo "[hb-nav] FAIL: navlink render exited non-zero";   cat "$FL"; exit 1; }
"$BIN" tests/fixtures/hambrowse_formsubmit.html 880 >"$FG" 2>&1 || { echo "[hb-nav] FAIL: GET-form render exited non-zero"; cat "$FG"; exit 1; }
"$BIN" tests/fixtures/hambrowse_formpost.html   880 >"$FP" 2>&1 || { echo "[hb-nav] FAIL: POST-form render exited non-zero"; cat "$FP"; exit 1; }

assert() {    # file pattern message
    if grep -Eq -- "$2" "$1"; then
        echo "[hb-nav] PASS $3"
    else
        echo "[hb-nav] FAIL $3 (missing: $2)"; fail=1
    fi
}
assert_no() { # file pattern message
    if grep -Eq -- "$2" "$1"; then
        echo "[hb-nav] FAIL $3 (present: $2)"; fail=1
    else
        echo "[hb-nav] PASS $3"
    fi
}

grep -E 'JSERR|Uncaught' "$FL" "$FG" "$FP" || true

# ---- (A) link is a clickable link-table entry (the target of _navigate) -----
assert    "$FL" 'links=1'                         "an <a href> is captured as a clickable link (target of a click-navigate)"
assert    "$FL" '^SEG .* l0 .*\|go to page two\|$' "the link text is a link-styled segment carrying link index 0"

# ---- (B) GET form submit -> action?query (http_get target) ------------------
assert    "$FG" '^NAV /search\?q=hello\+world_x&agree=yes&plan=pro&size=large$' \
          "a GET form serializes named controls to action?k=v (front-end http_get target)"
assert_no "$FG" '^NAV POST'                       "a GET form is NOT a POST"
assert_no "$FG" '^BODY '                          "a GET form builds no request body"

# ---- (C) POST form submit -> bare action + urlencoded BODY (http_post) ------
assert    "$FP" '^NAV POST /login$'               "a POST form navigates to the bare action (no query string)"
assert    "$FP" '^BODY a=1&b=2&agree=yes$'        "a POST form serializes controls into a urlencoded request BODY (front-end http_post body)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-nav] RESULT: FAIL"; exit 1
fi
echo "[hb-nav] RESULT: PASS — link click-navigation + form GET-query + form POST-body wiring verified host-side"
