#!/usr/bin/env bash
# scripts/test_jsengine_formdata_host.sh — FAST, QEMU-free gate for the FormData
# constructor + method suite (lib/web/js/builtins/url.ad), via the x86_64-linux
# host driver (user/js_host.ad). Self-contained inline assertions vs node.
#
# THE GAP: there was no FormData at all — the marquee AJAX form primitive
# (`fetch(url,{body:new FormData()})`, `fd.get(name)`, `fd.append(...)`) threw
# ReferenceError, breaking every single-page / AJAX form path.
#
# THE FEATURE: FormData is registered as a global constructor whose instances
# reuse the EXACT @@k/@@v parallel-array multimap URLSearchParams already
# implements (get/getAll/has/set/append/delete/forEach/entries/keys/values +
# Symbol.iterator), so its prototype binds the same NAT_URLSP_* method ids over
# the shared storage. Empty `new FormData()`, and a plain-object init as an
# extension (the spec's `new FormData(formElement)` DOM-scrape is done by the DOM
# layer, not the engine). Values coerce to strings.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-fd] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_fd_compile.log"; then
    echo "[js-fd] FAIL: host driver did not compile"; cat "$OUT/js_fd_compile.log"; exit 1
fi
echo "[js-fd] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_fd_case.js"
    local got
    got="$("$BIN" "$OUT/js_fd_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-fd] PASS $name"
    else
        echo "[js-fd] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

assert empty_get   'console.log(new FormData().get("x"))'                                             'null'
assert append_get  'var f=new FormData();f.append("a","1");f.append("a","2");console.log(f.get("a"),JSON.stringify(f.getAll("a")))' '1 ["1","2"]'
assert has         'var f=new FormData();f.append("a","1");console.log(f.has("a"),f.has("z"))'        'true false'
assert delete      'var f=new FormData();f.append("a","1");f.delete("a");console.log(f.has("a"))'     'false'
assert set_over    'var f=new FormData();f.append("a","1");f.append("a","2");f.set("a","9");console.log(JSON.stringify(f.getAll("a")))' '["9"]'
assert set_absent  'var f=new FormData();f.set("a","1");console.log(f.get("a"))'                      '1'
assert obj_init    'var f=new FormData({name:"bob",age:3});console.log(f.get("name"),f.get("age"))'   'bob 3'
assert coerce      'var f=new FormData();f.append("n",5);console.log(f.get("n"),typeof f.get("n"))'   '5 string'
assert entries     'var f=new FormData();f.append("a","1");f.append("b","2");console.log(JSON.stringify([...f.entries()]))' '[["a","1"],["b","2"]]'
assert keys_vals   'var f=new FormData();f.append("a","1");f.append("b","2");console.log(JSON.stringify([...f.keys()]),JSON.stringify([...f.values()]))' '["a","b"] ["1","2"]'
assert iterate     'var f=new FormData();f.append("a","1");f.append("b","2");var o="";for(const [k,v] of f)o+=k+"="+v+";";console.log(o)' 'a=1;b=2;'
assert foreach     'var f=new FormData();f.append("a","1");f.append("b","2");var o="";f.forEach(function(v,k){o+=k+":"+v+" "});console.log(o.trim())' 'a:1 b:2'
assert instanceof  'console.log(new FormData() instanceof FormData)'                                  'true'

if [ "$fail" -ne 0 ]; then
    echo "[js-fd] RESULT: FAIL"; exit 1
fi
echo "[js-fd] RESULT: PASS"
