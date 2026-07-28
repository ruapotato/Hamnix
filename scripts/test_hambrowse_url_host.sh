#!/usr/bin/env bash
# scripts/test_hambrowse_url_host.sh — FAST, QEMU-free gate for the self-contained
# Web-platform APIs in the native JS engine (lib/web/js/builtins/url.ad), via the
# x86_64-linux host driver: URL / URLSearchParams (WHATWG URL) and btoa / atob
# (RFC 4648 base64). Real sites reach for these everywhere (routing, query
# manipulation, data: URIs, token codecs).
#
# Covered:
#   * URL component split (protocol/username/password/host/hostname/port/
#     pathname/search/hash/origin) + live searchParams
#   * relative-to-base resolution (path-absolute, relative segment, dot-folding,
#     scheme-relative, fragment-only, query-only) + no-base TypeError
#   * URLSearchParams get/getAll/has/set/append/delete/toString/forEach/sort,
#     entries/keys/values, default for-of iteration, percent + '+' encoding
#   * btoa/atob round-trip, padding edges, atob whitespace tolerance + validation
#
# Limits (documented, honest): searchParams is one-way (reflects the initial query;
# mutating it does not rewrite url.search / url.href). btoa treats each string BYTE
# as a latin1 code unit (this engine stores byte-strings), so the spec's >0xFF
# InvalidCharacterError throw cannot trigger for byte inputs.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-url] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_url_compile.log"; then
    echo "[js-url] FAIL: host driver did not compile"; cat "$OUT/js_url_compile.log"; exit 1
fi
echo "[js-url] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_url_case.js"
    local got
    got="$("$BIN" "$OUT/js_url_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-url] PASS $name"
    else
        echo "[js-url] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- URL component split ----
assert url_split   'var u=new URL("https://u:p@ex.com:8080/a/b?x=1&y=2#h");console.log(u.protocol,u.username,u.password,u.hostname,u.port,u.pathname,u.search,u.hash)' 'https: u p ex.com 8080 /a/b ?x=1&y=2 #h'
assert url_hostorigin 'var u=new URL("https://u:p@ex.com:8080/a/b?x=1&y=2#h");console.log(u.host,u.origin)' 'ex.com:8080 https://ex.com:8080'
assert url_sp      'var u=new URL("https://ex.com/a?x=1&y=2");console.log(u.searchParams.get("x"),u.searchParams.get("y"))' '1 2'
assert url_bare    'var u=new URL("https://ex.com");console.log(u.pathname,u.origin,u.search==="",u.hash==="")' '/ https://ex.com true true'
assert url_ftp     'var u=new URL("ftp://h.net/p");console.log(u.protocol,u.host)' 'ftp: h.net'

# ---- relative-to-base resolution ----
assert url_abs     'console.log(new URL("/c","https://ex.com/a/b").pathname)'        '/c'
assert url_rel     'console.log(new URL("c","https://ex.com/a/b").pathname)'         '/a/c'
assert url_reltr   'console.log(new URL("d","https://ex.com/a/b/").pathname)'        '/a/b/d'
assert url_dotdot  'console.log(new URL("../d","https://ex.com/a/b/c").pathname)'    '/a/d'
assert url_dot     'console.log(new URL("./e","https://ex.com/a/b/c").pathname)'     '/a/b/e'
assert url_schrel  'console.log(new URL("//cdn.x.com/f.js","https://ex.com/a").href)' 'https://cdn.x.com/f.js'
assert url_frag    'console.log(new URL("#frag","https://ex.com/a?q=1").href)'       'https://ex.com/a?q=1#frag'
assert url_query   'console.log(new URL("?z=9","https://ex.com/a/b?x=1").href)'      'https://ex.com/a/b?z=9'
assert url_absurl  'console.log(new URL("https://x.io/p?a=1#h","https://ex.com/base").href)' 'https://x.io/p?a=1#h'
assert url_nobase  'try{new URL("/foo")}catch(e){console.log(e.name)}'               'TypeError'

# ---- URL toString / toJSON ----
assert url_tostr   'console.log(new URL("https://ex.com/p?a=1").toString())'         'https://ex.com/p?a=1'
assert url_tojson  'console.log(new URL("https://ex.com/p?a=1").toJSON())'           'https://ex.com/p?a=1'

# ---- URLSearchParams ----
assert usp_get     'var s=new URLSearchParams("a=1&b=2&a=3");console.log(s.get("a"),s.getAll("a").join(","),s.has("b"),s.has("z"))' '1 1,3 true false'
assert usp_append  'var s=new URLSearchParams("a=1");s.append("a","2");s.append("c","3");console.log(s.toString())' 'a=1&a=2&c=3'
assert usp_delete  'var s=new URLSearchParams("a=1&a=2&b=3");s.delete("a");console.log(s.toString())' 'b=3'
assert usp_set     'var s=new URLSearchParams("a=1&a=2&b=3");s.set("a","9");console.log(s.toString())' 'a=9&b=3'
assert usp_setnew  'var s=new URLSearchParams("a=1&a=2");s.set("c","4");console.log(s.toString())' 'a=1&a=2&c=4'
assert usp_obj     'var s=new URLSearchParams({x:"1",y:"hello world"});console.log(s.toString())' 'x=1&y=hello+world'
assert usp_enc     'var s=new URLSearchParams();s.append("a b","c d");console.log(s.get("a b"),s.toString())' 'c d a+b=c+d'
assert usp_dec     'var s=new URLSearchParams("q=%20%2B%26");console.log(s.get("q"))'  ' +&'
assert usp_order   'var s=new URLSearchParams("b=2&a=1&c=3");var o=[];s.forEach(function(v,k){o.push(k+"="+v)});console.log(o.join("|"))' 'b=2|a=1|c=3'
assert usp_iter    'var s=new URLSearchParams("a=1&b=2");console.log(JSON.stringify(s.entries()),JSON.stringify(s.keys()),JSON.stringify(s.values()))' '[["a","1"],["b","2"]] ["a","b"] ["1","2"]'
assert usp_forof   'var s=new URLSearchParams("a=1&b=2");var o=[];for(var e of s){o.push(e[0]+":"+e[1])}console.log(o.join(","))' 'a:1,b:2'
assert usp_sort    'var s=new URLSearchParams("c=3&a=1&b=2");s.sort();console.log(s.toString())' 'a=1&b=2&c=3'

# ---- btoa / atob ----
assert b64_enc     'console.log(btoa("Hello"))'                'SGVsbG8='
assert b64_dec     'console.log(atob("SGVsbG8="))'             'Hello'
assert b64_pad     'console.log(btoa("M"),btoa("Ma"),btoa("Man"))' 'TQ== TWE= TWFu'
assert b64_round   'console.log(atob(btoa("The quick brown fox")))' 'The quick brown fox'
assert b64_ws      'console.log(atob("  SGVs bG8=\n"))'        'Hello'
assert b64_empty   'console.log(btoa("")+"|"+atob("")+"|")'    '||'
assert b64_bad     'try{atob("@@@")}catch(e){console.log(e.name)}' 'InvalidCharacterError'

if [ "$fail" -eq 0 ]; then
    echo "[js-url] ALL PASS"
else
    echo "[js-url] SOME FAILED"
fi
exit "$fail"
