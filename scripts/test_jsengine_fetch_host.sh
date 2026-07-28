#!/usr/bin/env bash
# scripts/test_jsengine_fetch_host.sh — FAST, QEMU-free gate for the JS engine's
# fetch() API (lib/jsengine.ad) via the x86_64-linux host driver (user/js_host.ad).
#
# fetch is the most-used async web API. With #186 Promises + #187 async/await in
# the engine, `fetch(url).then(r => r.json())` and `await fetch(url)` must work.
# The engine is extern-free + dual-target, so fetch resolves DETERMINISTICALLY
# from a JS-settable FIXTURE table (__setFetchFixture(url, {status, body, ...}))
# rather than wall-clock network — a gate can assert exact bytes. Each body
# method returns its OWN Promise settled on the SAME #178 microtask queue, so
# .then/await compose. An unmatched url (or a status-0 network-error row) rejects
# with a TypeError so `.catch` fires. On-device this same fixture path is the
# sole data source (the engine takes no externs); real http9 traffic lives in a
# front-end such as hambrowse, NOT the engine.
#
# Assertions are cross-checked against browser fetch semantics:
#   - fetch(u).then(r => r.status)      -> the fixture status (after drain)
#   - r.ok is true for 2xx, false for 404
#   - r.text()  -> Promise<string> of the body
#   - r.json()  -> Promise<parsed> (reuses JSON.parse); a field reads back
#   - async/await: `await fetch` then `await r.json()` composes
#   - an unmatched url and a network-error row both reject -> `.catch`
#   - r.headers.get(name) is case-insensitive
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-fetch] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_fetch_compile.log"; then
    echo "[js-fetch] FAIL: host driver did not compile"; cat "$OUT/js_fetch_compile.log"; exit 1
fi
echo "[js-fetch] PASS host driver compiled -> $BIN"

fail=0
# assert_full <name> <js-src> <expected-full-output-joined-by-|>
assert_full() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_fetch_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_fetch_case.js" 2>&1 | paste -sd'|' -)"
    if [ "$got" = "$exp" ]; then
        echo "[js-fetch] PASS $name"
    else
        echo "[js-fetch] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

FX="__setFetchFixture('u',{status:200,body:'{\"x\":42,\"field\":\"hi\"}'});"

# fetch resolves to a Response carrying the fixture status/ok/statusText/url.
assert_full status      "$FX fetch('u').then(r=>console.log(r.status,r.ok,r.statusText,r.url));" '200 true OK u'
# .text() resolves to the raw body string.
assert_full text        "$FX fetch('u').then(r=>r.text()).then(t=>console.log(t));" '{"x":42,"field":"hi"}'
# .json() resolves to the parsed object (JSON.parse reuse); a field reads back.
assert_full json        "$FX fetch('u').then(r=>r.json()).then(o=>console.log(o.field));" 'hi'
# async/await: await fetch then await r.json() composes (fetch + await + json).
assert_full await_json  "$FX async function g(){ let r = await fetch('u'); let d = await r.json(); return d.x } g().then(v=>console.log(v));" '42'
# .ok is false for a 404 fixture.
assert_full ok_404      "__setFetchFixture('nf',{status:404,body:'x'}); fetch('nf').then(r=>console.log(r.ok,r.status));" 'false 404'
# an unmatched url rejects -> .catch sees a TypeError.
assert_full reject_miss "fetch('gone').then(()=>console.log('NO')).catch(e=>console.log(e.name));" 'TypeError'
# a status-0 row models a network error and rejects -> .catch.
assert_full reject_neterr "__setFetchFixture('e',{status:0}); fetch('e').then(()=>console.log('NO')).catch(e=>console.log('caught'));" 'caught'
# headers.get is case-insensitive; content-type defaults to text/plain.
assert_full headers     "$FX fetch('u').then(r=>console.log(r.headers.get('Content-Type')));" 'text/plain'
# a fixture-supplied contentType flows through headers.get.
assert_full headers_ct  "__setFetchFixture('j',{status:200,body:'{}',contentType:'application/json'}); fetch('j').then(r=>console.log(r.headers.get('content-type')));" 'application/json'
# .json() on a bad body rejects -> .catch (JSON.parse SyntaxError).
assert_full json_bad    "__setFetchFixture('b',{status:200,body:'not json'}); fetch('b').then(r=>r.json()).then(()=>console.log('NO')).catch(e=>console.log(e.name));" 'SyntaxError'
# .arrayBuffer() resolves to a byte-value array of the body.
assert_full arraybuffer "__setFetchFixture('a',{status:200,body:'AB'}); fetch('a').then(r=>r.arrayBuffer()).then(x=>console.log(x[0],x[1],x.length));" '65 66 2'

if [ "$fail" -eq 0 ]; then
    echo "[js-fetch] RESULT: PASS"
    exit 0
else
    echo "[js-fetch] RESULT: FAIL"
    exit 1
fi
