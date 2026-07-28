#!/usr/bin/env bash
# scripts/test_hambrowse_urlreflect_host.sh — IDL URL-attribute reflection.
#
# WHAT IT CATCHES
# ===============
# `a.href` and `img.src` are URL-VALUED IDL attributes: reading them returns
# the attribute RESOLVED against the document's base URL. We reflected the RAW
# attribute instead, so
#
#     <a href="?a=1">     chromium a.href = file:///…/page.html?a=1
#                         hambrowse a.href = ?a=1
#
# and any page that reads a.href and re-navigates through it got a RELATIVE
# string back. (getAttribute('href') returns the raw value in both, and must
# keep doing so — that half was already right.)
#
# THE ORACLE IS CHROMIUM, VALUE BY VALUE
# ======================================
# Nothing here is a hard-coded expectation. The gate runs the SAME fixture
# through `chromium --headless` and through the engine and compares the two
# result sets STRING BY STRING, so a case the engine and chromium disagree on
# names itself. Without chromium installed the comparison is SKIPped (never
# failed) and only the structural assertions below run.
#
# The document URL is not something the engine can invent: a front-end supplies
# it (user/hambrowse.ad does so from cur_url; the host drivers take an argv
# `url <URL>` pair). With NO document URL supplied the engine reflects the raw
# attribute exactly as before — asserted here too, because that is what keeps
# every other host render byte-identical.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_host_url"
fail=0

echo "[hb-url] compiling host driver (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/url_compile.log"; then
    echo "[hb-url] FAIL: host driver did not compile"; cat "$OUT/url_compile.log"; exit 1
fi
echo "[hb-url] PASS host driver compiled"

CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"

# ham_refs <fixture> <docurl> -> "KEY = VALUE" lines, sorted
ham_refs() {
    "$1" "$2" 880 url "$3" 2>&1 \
        | tr '|' '\n' \
        | sed -n 's/^.*URLREF \(.*[^ ]\) *$/\1/p' \
        | sed 's/ *$//' | sort -u
}

# chrome_refs <fixture> -> the same, read out of chromium's console
chrome_refs() {
    "$CHROMIUM" --headless --no-sandbox --disable-gpu --enable-logging=stderr \
        --dump-dom "file://$(readlink -f "$1")" 2>&1 >/dev/null \
        | sed -n 's/^.*URLREF \(.*\)$/\1/p' \
        | sed 's/", source:.*$//' | sed 's/ *$//' | sort -u
}

compare_against_chromium() {   # compare_against_chromium <fixture> <label>
    local fix="$1" label="$2"
    local url; url="file://$(readlink -f "$fix")"
    ham_refs "$BIN" "$fix" "$url" > "$OUT/url_ham_$label.txt"
    if [ ! -s "$OUT/url_ham_$label.txt" ]; then
        echo "[hb-url] FAIL $label: the engine reported no URLREF lines at all"
        fail=1; return
    fi
    if [ -z "$CHROMIUM" ]; then
        echo "[hb-url] SKIP $label chromium comparison (no chromium installed)"
        return
    fi
    chrome_refs "$fix" > "$OUT/url_chr_$label.txt"
    if [ ! -s "$OUT/url_chr_$label.txt" ]; then
        echo "[hb-url] SKIP $label chromium comparison (chromium logged nothing)"
        return
    fi
    local n; n="$(wc -l < "$OUT/url_chr_$label.txt")"
    if diff -u "$OUT/url_chr_$label.txt" "$OUT/url_ham_$label.txt" > "$OUT/url_diff_$label.txt"; then
        echo "[hb-url] PASS $label: all $n reflected values match chromium exactly"
    else
        echo "[hb-url] FAIL $label: engine and chromium disagree —"
        sed -n '3,60p' "$OUT/url_diff_$label.txt"
        fail=1
    fi
}

# ---------------------------------------------------------------------------
# (1) + (2) the two fixtures, compared value-by-value against chromium.
# ---------------------------------------------------------------------------
compare_against_chromium tests/fixtures/hambrowse_urlreflect.html reflect
compare_against_chromium tests/fixtures/hambrowse_urlbase.html base

# ---------------------------------------------------------------------------
# (3) SPECIFIC INVARIANTS, spelled out so a regression names itself rather than
#     arriving as an anonymous diff line.
# ---------------------------------------------------------------------------
R="$OUT/url_ham_reflect.txt"
want_has() {   # want_has <regex> <description>
    if grep -Eq -- "$1" "$R"; then
        echo "[hb-url] PASS $2"
    else
        echo "[hb-url] FAIL $2 (no line matching: $1)"
        fail=1
    fi
}
want_has '^href2 = file:///.*/hambrowse_urlreflect\.html\?q=1$' \
    'href="?q=1" reflects as the ABSOLUTE document url + query (the reported bug)'
want_has '^href3 = file:///.*/tests/fixtures/p\.html$' \
    'a relative href resolves against the document directory'
want_has '^href5 = file:///.*/tests/p\.html$' \
    '"../p.html" climbs one directory'
want_has '^href8 = http://x/y$' \
    'an already-absolute href is returned unchanged'
want_has '^href9 = file:///.*/tests/fixtures/a/c$' \
    'dot segments are removed ("a/b/../c" -> "a/c")'
want_has '^href13 =$' \
    'an <a> with NO href attribute still reflects the empty string'
want_has '^src0 = file:///.*/tests/fixtures/pic\.png$' \
    'img.src absolutises too'
want_has '^rawhref2 = \?q=1$' \
    'getAttribute("href") STAYS RAW'
want_has '^rawsrc0 = pic\.png$' \
    'getAttribute("src") STAYS RAW'
want_has '^divsrc = undefined$' \
    'a <div> still has no .src (chromium says undefined)'
want_has '^docURL = file:///.*/hambrowse_urlreflect\.html$' \
    'document.URL is the document url'
want_has '^lochref = file:///.*/hambrowse_urlreflect\.html$' \
    'location.href is the document url'

B="$OUT/url_ham_base.txt"
if grep -Eq '^href0 = file:///.*/tests/p\.html$' "$B"; then
    echo "[hb-url] PASS <base href=\"../\"> moves the resolution base up a directory"
else
    echo "[hb-url] FAIL <base href> did not move the resolution base"; fail=1
fi
if grep -Eq '^rawhref0 = p\.html$' "$B"; then
    echo "[hb-url] PASS getAttribute stays raw under a <base href> too"
else
    echo "[hb-url] FAIL getAttribute did not stay raw under <base href>"; fail=1
fi

# ---------------------------------------------------------------------------
# (4) NO DOCUMENT URL => NO RESOLUTION. A front-end that never told the engine
#     its address must get the raw attribute back, unchanged — this is what
#     makes the whole change render-neutral for every existing caller.
# ---------------------------------------------------------------------------
NOURL="$("$BIN" tests/fixtures/hambrowse_urlreflect.html 880 2>&1 \
          | tr '|' '\n' | sed -n 's/^.*URLREF \(.*[^ ]\) *$/\1/p' | sed 's/ *$//')"
if printf '%s\n' "$NOURL" | grep -qx 'href2 = ?q=1'; then
    echo "[hb-url] PASS with no document url supplied, href reflects the RAW attribute"
else
    echo "[hb-url] FAIL with no document url the engine did not fall back to the raw attribute"
    printf '%s\n' "$NOURL" | head -5
    fail=1
fi
if printf '%s\n' "$NOURL" | grep -qx 'lochref = about:blank'; then
    echo "[hb-url] PASS with no document url, location.href stays the about:blank stub"
else
    echo "[hb-url] FAIL location.href moved without a document url"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-url] RESULT: FAIL"; exit 1
fi
echo "[hb-url] RESULT: PASS"
