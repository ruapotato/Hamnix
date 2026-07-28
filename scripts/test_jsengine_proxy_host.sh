#!/usr/bin/env bash
# scripts/test_jsengine_proxy_host.sh — FAST, QEMU-free gate for ES2015 Proxy in
# the native JS engine (lib/web/js/*), via the x86_64-linux host driver.
#
# Covered (round 7) traps: get, set, has, deleteProperty, ownKeys. A proxy with
# no matching trap forwards the operation to its target. The engine's member-get,
# member-set, `in`, `delete`, and Object.keys/Reflect.ownKeys route through the
# handler when the receiver is a proxy.
#
# Limits (deferred): apply / construct / defineProperty / getOwnPropertyDescriptor
# / getPrototypeOf / setPrototypeOf traps, and Proxy.revocable are NOT wired.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-proxy] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_proxy_compile.log"; then
    echo "[js-proxy] FAIL: host driver did not compile"; cat "$OUT/js_proxy_compile.log"; exit 1
fi
echo "[js-proxy] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_proxy_case.js"
    local got
    got="$("$BIN" "$OUT/js_proxy_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-proxy] PASS $name"
    else
        echo "[js-proxy] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- get trap ----
assert px_get       'var p=new Proxy({a:1},{get(t,k){return k in t?t[k]:99}});console.log(p.a,p.z)'   '1 99'
assert px_get_key   'var p=new Proxy({},{get(t,k){return "got:"+k}});console.log(p.hello)'            'got:hello'
assert px_get_fwd   'var p=new Proxy({x:5},{});console.log(p.x)'                                       '5'
assert px_get_recv  'var p=new Proxy({},{get(t,k,r){return r===p}});console.log(p.any)'               'true'

# ---- set trap ----
assert px_set       'var o={};var p=new Proxy(o,{set(t,k,v){t[k]=v*2;return true}});p.n=5;console.log(o.n,p.n)' '10 10'
assert px_set_fwd   'var o={};var p=new Proxy(o,{});p.q=7;console.log(o.q)'                            '7'

# ---- has trap (the `in` operator) ----
assert px_has       'var p=new Proxy({a:1},{has(t,k){return k==="magic"||k in t}});console.log("a" in p,"magic" in p,"z" in p)' 'true true false'
assert px_has_fwd   'var p=new Proxy({a:1},{});console.log("a" in p,"b" in p)'                         'true false'

# ---- deleteProperty trap ----
assert px_del       'var log="";var p=new Proxy({a:1},{deleteProperty(t,k){log=k;delete t[k];return true}});delete p.a;console.log(log,p.a)' 'a undefined'
assert px_del_fwd   'var o={a:1,b:2};var p=new Proxy(o,{});delete p.a;console.log(o.a,o.b)'            'undefined 2'

# ---- ownKeys trap (Object.keys / Reflect.ownKeys) ----
assert px_ownkeys   'var p=new Proxy({a:1,b:2},{ownKeys(t){return ["x","y","z"]}});console.log(Object.keys(p).join(","))' 'x,y,z'
assert px_ownkeys_r 'var p=new Proxy({a:1},{ownKeys(t){return ["k"]}});console.log(Reflect.ownKeys(p).join(","))' 'k'
assert px_ownkeys_f 'var p=new Proxy({a:1,b:2},{});console.log(Object.keys(p).join(","))'             'a,b'

# ---- Reflect inside a trap (the canonical forwarding idiom) ----
assert px_reflect   'var p=new Proxy({a:1,b:2},{get(t,k){return Reflect.get(t,k)}});console.log(p.a,p.b)' '1 2'

# ---- proxy method access routes through get + this=proxy ----
assert px_method    'var p=new Proxy({v:3,getV(){return this.v}},{});console.log(p.getV())'           '3'

# ---- non-object target/handler throws ----
assert px_throw     'try{new Proxy(5,{})}catch(e){console.log(e.name)}'                                'TypeError'

if [ "$fail" -eq 0 ]; then
    echo "[js-proxy] ALL PASS"
else
    echo "[js-proxy] SOME FAILED"
fi
exit "$fail"
