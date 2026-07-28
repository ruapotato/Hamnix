#!/usr/bin/env bash
# scripts/test_hambrowse_fetch_host.sh — FAST, QEMU-free gate for the JS engine's
# REAL-NETWORK fetch() path (do_fetch's transport branch + make_response_net's
# raw HTTP status/header/body parser + the full Headers get/has/entries).
#
# WHY a host gate for a "networking" feature: fetch() on-device performs an actual
# over-the-wire request through the kernel's Plan-9 /net http9 client
# (user/http9.ad: sys_resolve for DNS, net_dial / net_dial_tls to connect — NO
# sockets). The engine itself stays extern-free: it only calls back into an
# embedder-registered TRANSPORT (js_set_fetch_transport) and PARSES the raw HTTP
# bytes the transport returns. That parse — status line, header block, body slice,
# Headers object — is IDENTICAL whether the bytes came off a real socket via
# http9 on-device or from a canned buffer here. So this gate drives the exact
# on-device code path with a deterministic canned transport (js_host --fetch-net),
# proving the wire-response handling without needing QEMU + a live server. The
# remaining on-device link (registering the http9 http_get bridge as the browser's
# transport) is documented in docs/browser_w3c_conformance.md.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[hb-fetch] compiling engine (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/hb_fetch_compile.log"; then
    echo "[hb-fetch] FAIL: host driver did not compile"; cat "$OUT/hb_fetch_compile.log"; exit 1
fi
echo "[hb-fetch] PASS host driver compiled -> $BIN"

fail=0
# assert_line <name> <js-src> <expected-single-line-substring-match>
# Runs under --fetch-net so absolute http(s):// URLs hit the canned transport;
# each case emits exactly one grep-able line so async ordering does not matter.
assert_line() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/hb_fetch_case.js"
    local got
    got="$(timeout 30 "$BIN" --fetch-net "$OUT/hb_fetch_case.js" 2>&1)"
    if echo "$got" | grep -qxF "$exp"; then
        echo "[hb-fetch] PASS $name"
    else
        echo "[hb-fetch] FAIL $name: expected line [$exp] in:"; echo "$got" | sed 's/^/    /'; fail=1
    fi
}

# A 200 response parsed from raw HTTP: status / ok / statusText / url all read
# out of the wire bytes (not a fixture).
assert_line status  "fetch('http://h.test/hello').then(r=>console.log('R',r.status,r.ok,r.statusText,r.url));" 'R 200 true OK http://h.test/hello'
# Body is sliced past the CRLFCRLF terminator.
assert_line text    "fetch('http://h.test/hello').then(r=>r.text()).then(t=>console.log('T',t));" 'T hello-from-transport'
# Every response header is parsed (not just content-type); get is case-insensitive.
assert_line hget    "fetch('http://h.test/hello').then(r=>console.log('H',r.headers.get('Content-Type'),r.headers.get('X-Test')));" 'H text/plain hamnix'
# has() reports presence; an unknown header reads back null.
assert_line hhas    "fetch('http://h.test/hello').then(r=>console.log('P',r.headers.has('x-test'),r.headers.has('nope'),r.headers.get('nope')));" 'P true false null'
# entries() yields the parsed [name,value] pairs (lowercased names, in order).
assert_line hentries "fetch('http://h.test/hello').then(r=>r.headers.entries()).then(es=>console.log('E',es.length,es[0][0],es[1][0]));" 'E 2 content-type x-test'
# A non-2xx HTTP status FULFILLS (not rejects) with ok=false — Fetch-spec correct.
assert_line ok404   "fetch('http://h.test/404').then(r=>console.log('N',r.ok,r.status,r.statusText));" 'N false 404 Not Found'
# A transport/DNS/connect failure REJECTS with a TypeError -> .catch fires.
assert_line reject  "fetch('http://h.test/fail').then(()=>console.log('NO')).catch(e=>console.log('C',e.name));" 'C TypeError'
# init.method / init.body are forwarded to the transport (POST round-trips a body).
assert_line post    "fetch('http://h.test/echo',{method:'POST',body:'payload'}).then(r=>r.text()).then(t=>console.log('B',t));" 'B posted:payload'
# init.headers['content-type'] is forwarded to the transport (the canned transport
# echoes the received request Content-Type back as X-Req-Content-Type). On-device
# this same value is what http_post writes onto the wire.
assert_line postct  "fetch('http://h.test/echo',{method:'POST',body:'x',headers:{'Content-Type':'application/json'}}).then(r=>console.log('CT',r.headers.get('x-req-content-type')));" 'CT application/json'
# await composes over the real-network path just like the fixture path.
assert_line await   "async function g(){let r=await fetch('http://h.test/hello');let t=await r.text();return t.length} g().then(v=>console.log('A',v));" 'A 20'
# json() parses a JSON body slice off the wire.
assert_line json    "fetch('http://h.test/echo',{method:'POST',body:'{\"k\":7}'}).then(r=>r.text()).then(t=>console.log('J',t));" 'J posted:{"k":7}'

if [ "$fail" -eq 0 ]; then
    echo "[hb-fetch] RESULT: PASS"
    exit 0
else
    echo "[hb-fetch] RESULT: FAIL"
    exit 1
fi
