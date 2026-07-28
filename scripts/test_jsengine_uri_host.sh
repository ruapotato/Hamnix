#!/usr/bin/env bash
# scripts/test_jsengine_uri_host.sh — FAST, QEMU-free gate for the URI-handling
# GLOBALS in the JS engine (lib/web/js/) via the x86_64-linux host driver
# (user/js_host.ad).
#
# WHY: encodeURI / encodeURIComponent / decodeURI / decodeURIComponent /
# escape / unescape were entirely ABSENT — every one of them threw a bare
# ReferenceError. That is fatal on any page that builds a query string, posts
# a form, or fires an analytics beacon, which is most of the real web.
#
# The four functions are pairwise near-identical and the differences are
# exactly where real pages break, so they are all pinned here:
#   * the unreserved sets: encodeURIComponent keeps only alnum + "-_.!~*'()",
#     encodeURI additionally keeps the reserved ";/?:@&=+$,#"
#   * %XX hex is UPPERCASE, and non-ASCII goes out as UTF-8 bytes
#   * decodeURI REFUSES to decode an escape that would produce a reserved
#     character, leaving the escape sequence in place; decodeURIComponent does
#     decode it
#   * escape/unescape are the LEGACY pair and are NOT UTF-8: they work on
#     UTF-16 CODE UNITS ("é" -> "%E9", not "%C3%A9") with %uXXXX above 255,
#     and escape's keep-set ("@*_+-./") is NOT encodeURIComponent's
#   * URIError on a malformed %-sequence, over-long UTF-8, a lone surrogate
#     (in either direction) and an out-of-range code point
#
# EVERY EXPECTATION BELOW WAS REPLAYED THROUGH `node` VALUE-BY-VALUE.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-uri] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/js_host.ad -o "$BIN" 2>"$OUT/js_uri_compile.log"; then
    echo "[js-uri] FAIL: host driver did not compile"; cat "$OUT/js_uri_compile.log"; exit 1
fi
echo "[js-uri] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_uri_case.js"
    local got
    got="$("$BIN" "$OUT/js_uri_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-uri] PASS $name"
    else
        echo "[js-uri] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- they EXIST (this is what used to ReferenceError) ----
assert exists      'console.log(typeof encodeURI, typeof encodeURIComponent, typeof decodeURI, typeof decodeURIComponent, typeof escape, typeof unescape)' 'function function function function function function'

# ---- encodeURIComponent: the unreserved set, and everything else escaped ----
assert euc_query   'console.log(encodeURIComponent("a b&c=d?e/f"))'                       'a%20b%26c%3Dd%3Fe%2Ff'
assert euc_keep    'console.log(encodeURIComponent("-_.!~*()ABZaz09"))'                   "-_.!~*()ABZaz09"
assert euc_utf8    'console.log(encodeURIComponent("café"))'                         'caf%C3%A9'
assert euc_astral  'console.log(encodeURIComponent("\u{1F600}"))'                         '%F0%9F%98%80'
assert euc_empty   'console.log(JSON.stringify(encodeURIComponent("")))'                  '""'
assert euc_coerce  'console.log(encodeURIComponent(null), encodeURIComponent(42))'        'null 42'

# ---- encodeURI: reserved characters SURVIVE ----
assert eu_reserved 'console.log(encodeURI("a b&c=d?e/f#g;h:i@j$k,l+m"))'                  'a%20b&c=d?e/f#g;h:i@j$k,l+m'
assert eu_utf8     'console.log(encodeURI("http://x/café"))'                         'http://x/caf%C3%A9'
assert eu_unsafe   'console.log(encodeURI("[]|\\^`{}\"<>"))'                               '%5B%5D%7C%5C%5E%60%7B%7D%22%3C%3E'

# ---- decodeURIComponent decodes everything; decodeURI keeps reserved ----
assert duc_all     'console.log(decodeURIComponent("%C3%A9%20a%2Fb%3F"))'                 'é a/b?'
assert du_reserved 'console.log(decodeURI("%C3%A9%20a%2Fb%3F%23%26"))'                    'é a%2Fb%3F%23%26'
assert du_plain    'console.log(decodeURI("%41%42"), decodeURIComponent("%41%42"))'       'AB AB'
assert duc_astral  'console.log(decodeURIComponent("%F0%9F%98%80").length, decodeURIComponent("%F0%9F%98%80").codePointAt(0))' '2 128512'
assert duc_plus    'console.log(decodeURIComponent("a+b"))'                               'a+b'
assert roundtrip   'var s="q=a b&r=café/#x";console.log(decodeURIComponent(encodeURIComponent(s))===s)' 'true'

# ---- URIError, in both directions ----
assert err_trunc   'try{decodeURIComponent("%")}catch(e){console.log(e.name, e.message, e instanceof URIError)}' 'URIError URI malformed true'
assert err_hex     'try{decodeURIComponent("%zz")}catch(e){console.log(e.name)}'          'URIError'
assert err_over    'try{decodeURIComponent("%C0%80")}catch(e){console.log(e.name)}'       'URIError'
assert err_short   'try{decodeURIComponent("%E0%A4")}catch(e){console.log(e.name)}'       'URIError'
assert err_surr    'try{decodeURIComponent("%ED%A0%80")}catch(e){console.log(e.name)}'    'URIError'
assert err_cont    'try{decodeURIComponent("%80")}catch(e){console.log(e.name)}'          'URIError'
assert err_enc_lo  'try{encodeURIComponent("\uD800")}catch(e){console.log(e.name)}'       'URIError'
assert err_enc_hi  'try{encodeURIComponent("a\uDC00")}catch(e){console.log(e.name)}'      'URIError'
assert err_du      'try{decodeURI("%C0%80")}catch(e){console.log(e.name)}'                'URIError'

# ---- escape / unescape: LEGACY, code units, NOT UTF-8 ----
assert esc_basic   'console.log(escape("a b/é~*+@-_.!()"))'                          'a%20b/%E9%7E*+@-_.%21%28%29'
assert esc_u4      'console.log(escape("\u{1F600}"), escape("ሴ"))'                     '%uD83D%uDE00 %u1234'
assert esc_latin1  'console.log(escape("ÿ"), escape("ÿ").length)'                     '%FF 3'
assert unesc_mix   'console.log(unescape("a%20b%u1234%zz%"))'                             'a bሴ%zz%'
assert unesc_lat   'console.log(unescape("%u00e9"), unescape("%E9"))'                     'é é'
assert unesc_pair  'console.log(unescape("%uD83D%uDE00").length, unescape("%uD83D%uDE00").codePointAt(0))' '2 128512'

# ---- the ASCII fast path must be untouched ----
assert ascii_all   'console.log(encodeURIComponent("abc123"), decodeURIComponent("abc123"), escape("abc123"), unescape("abc123"))' 'abc123 abc123 abc123 abc123'

if [ "$fail" -eq 0 ]; then
    echo "[js-uri] ALL PASS"
    exit 0
fi
echo "[js-uri] FAILURES present"
exit 1
