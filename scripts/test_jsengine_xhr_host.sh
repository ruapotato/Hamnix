#!/usr/bin/env bash
# scripts/test_jsengine_xhr_host.sh — FAST, QEMU-free gate for the JS engine's
# XMLHttpRequest API (lib/web/js/builtins/xhr.ad) via the x86_64-linux host
# driver (user/js_host.ad).
#
# WHY THIS MATTERS: real-site bundles (google, jQuery-era code, analytics
# beacons) reference `XMLHttpRequest` unconditionally. A missing global throws
# ReferenceError and aborts the whole referencing <script>. XHR is now a real
# constructor whose send() routes through the SAME transport/__setFetchFixture
# path as fetch(), so a gate can seed a deterministic fixture and read it back.
#
# Asserts the spec surface directly (no oracle):
#   - typeof XMLHttpRequest === 'function' (the global is DEFINED — no ReferenceError)
#   - the readyState constants (UNSENT..DONE) on the instance AND the constructor
#   - an async GET: readyState progresses 1->2->3->4 (readystatechange each), then
#     load + loadend fire; status/statusText/responseText delivered from the fixture
#   - an async POST with a Content-Type request header, statusText, header reads
#   - getResponseHeader (case-insensitive) + getAllResponseHeaders
#   - responseType='json' parses `response`
#   - a status-0 (network-error) row fires `error` (not load), status stays 0
#   - synchronous send (async=false) resolves inline before send() returns
#   - abort() before delivery fires `abort` and suppresses load
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-xhr] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_xhr_compile.log"; then
    echo "[js-xhr] FAIL: host driver did not compile"; cat "$OUT/js_xhr_compile.log"; exit 1
fi
echo "[js-xhr] PASS host driver compiled -> $BIN"

fail=0
# assert_full <name> <js-src> <expected-full-output-joined-by-|>
assert_full() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_xhr_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_xhr_case.js" 2>&1 | paste -sd'|' -)"
    if [ "$got" = "$exp" ]; then
        echo "[js-xhr] PASS $name"
    else
        echo "[js-xhr] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

FX="__setFetchFixture('u',{status:200,body:'{\"x\":42,\"field\":\"hi\"}'});"

# XMLHttpRequest is a DEFINED global (the whole point — no ReferenceError).
assert_full defined     "console.log(typeof XMLHttpRequest);" 'function'
# readyState constants on the instance and the constructor.
assert_full constants   "var x=new XMLHttpRequest(); console.log(x.UNSENT,x.OPENED,x.HEADERS_RECEIVED,x.LOADING,x.DONE,XMLHttpRequest.DONE);" '0 1 2 3 4 4'
# initial readyState is 0 (UNSENT); open() advances to 1 (OPENED).
assert_full open_state  "var x=new XMLHttpRequest(); var a=x.readyState; x.open('GET','u'); console.log(a,x.readyState);" '0 1'
# async GET: readyState progression 1,2,3,4 captured via readystatechange, then load.
assert_full progression "$FX var x=new XMLHttpRequest(); var s=[]; x.addEventListener('readystatechange',function(){s.push(x.readyState)}); x.addEventListener('load',function(){console.log('load '+x.status)}); x.open('GET','u'); x.send(); setTimeout(function(){console.log('states '+s.join(','))},50);" 'load 200|states 1,2,3,4'
# on DONE the fixture status/statusText/responseText are delivered.
assert_full delivered   "$FX var x=new XMLHttpRequest(); x.onreadystatechange=function(){ if(x.readyState===4) console.log(x.status,x.statusText,x.responseText) }; x.open('GET','u'); x.send();" '200 OK {"x":42,"field":"hi"}'
# loadend fires after load.
assert_full loadend     "$FX var x=new XMLHttpRequest(); x.onload=function(){console.log('load')}; x.onloadend=function(){console.log('loadend')}; x.open('GET','u'); x.send();" 'load|loadend'
# POST with a request Content-Type + statusText from the fixture.
assert_full post        "__setFetchFixture('api',{status:201,body:'{}',statusText:'Created'}); var x=new XMLHttpRequest(); x.onload=function(){console.log(x.status,x.statusText)}; x.open('POST','api'); x.setRequestHeader('Content-Type','application/json'); x.send('{}');" '201 Created'
# getResponseHeader is case-insensitive; getAllResponseHeaders serializes the block.
assert_full headers     "__setFetchFixture('j',{status:200,body:'{}',contentType:'application/json'}); var x=new XMLHttpRequest(); x.onload=function(){console.log(x.getResponseHeader('Content-Type')); console.log(x.getAllResponseHeaders().trim())}; x.open('GET','j'); x.send();" 'application/json|content-type: application/json'
# responseType='json' parses the body into `response`.
assert_full resptype    "__setFetchFixture('j',{status:200,body:'{\"ok\":1}'}); var x=new XMLHttpRequest(); x.responseType='json'; x.onload=function(){console.log(typeof x.response, x.response.ok)}; x.open('GET','j'); x.send();" 'object 1'
# a status-0 (network error) row fires error (not load); status stays 0.
assert_full error       "__setFetchFixture('e',{status:0}); var x=new XMLHttpRequest(); x.onload=function(){console.log('NO')}; x.onerror=function(){console.log('error '+x.status)}; x.open('GET','e'); x.send();" 'error 0'
# an unmatched url (no fixture) also fires error.
assert_full nofixture   "var x=new XMLHttpRequest(); x.onerror=function(){console.log('err')}; x.onload=function(){console.log('NO')}; x.open('GET','gone'); x.send();" 'err'
# synchronous send (async=false) resolves INLINE before send() returns.
assert_full sync        "$FX var x=new XMLHttpRequest(); x.open('GET','u',false); x.send(); console.log(x.readyState,x.status,x.responseText);" '4 200 {"x":42,"field":"hi"}'
# abort() before delivery fires abort and suppresses load.
assert_full abort       "$FX var x=new XMLHttpRequest(); x.onabort=function(){console.log('abort')}; x.onload=function(){console.log('NO')}; x.open('GET','u'); x.send(); x.abort();" 'abort'
# instanceof works via the wired prototype.
assert_full instanceof  "var x=new XMLHttpRequest(); console.log(x instanceof XMLHttpRequest);" 'true'

if [ "$fail" -eq 0 ]; then
    echo "[js-xhr] RESULT: PASS"
    exit 0
else
    echo "[js-xhr] RESULT: FAIL"
    exit 1
fi
