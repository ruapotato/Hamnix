#!/usr/bin/env bash
# scripts/test_jsengine_asynciter_host.sh — FAST, QEMU-free gate for two
# ECMAScript features added to the native JS engine (lib/web/js/):
#
#   * `for await (const x of iterable)` async iteration — driving the
#     @@asyncIterator protocol over an async generator, and the async-from-sync
#     wrapper over an array of promises (each value awaited, order preserved).
#     Integrates with the engine's deterministic await (microtask-drain) model.
#   * JSON.stringify(value, replacer[, space]) — the 2nd arg is now honored:
#     a function replacer fn(key,value) called per property, or an array
#     allowlist of object keys. Also honors value.toJSON(key) on the replacer
#     path. Cross-checked against Node/V8 output.
#
# Built with the frozen Python seed compiler so the gate runs in milliseconds
# without QEMU. Acceptance for the on-device engine is the boot gate + browser.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[asynciter-host] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/asynciter_compile.log"; then
    echo "[asynciter-host] FAIL: host driver did not compile"; cat "$OUT/asynciter_compile.log"; exit 1
fi
echo "[asynciter-host] PASS host driver compiled -> $BIN"

fail=0

# assert_eq NAME  EXPECTED  <<< js-on-stdin
assert_eq() {
    local name="$1"; local exp="$2"
    local js="$OUT/asynciter_$name.js"
    cat > "$js"
    local got; got="$("$BIN" "$js" 2>&1)"
    if [ "$got" = "$exp" ]; then
        echo "[asynciter-host] PASS $name"
    else
        echo "[asynciter-host] FAIL $name"
        echo "  expected: $exp"
        echo "  got:      $got"
        fail=1
    fi
}

# ===========================================================================
# for await ... of
# ---------------------------------------------------------------------------
# 1. async generator: sum the yielded values.
echo 'async function* g(){ yield 1; yield 2; yield 3; }
(async()=>{ let sum=0; for await (const x of g()) sum+=x; console.log(sum); })();' \
    | assert_eq forawait_asyncgen '6'

# 2. async generator whose yields are themselves awaited promises.
echo 'async function af(x){ return await Promise.resolve(x*10); }
async function* g(){ yield await af(1); yield await af(2); yield await af(3); }
(async()=>{ let s=0; for await (const v of g()) s+=v; console.log(s); })();' \
    | assert_eq forawait_awaited '60'

# 3. async-from-sync wrapper: an array of promises, each awaited, order kept.
echo '(async()=>{ let out=[]; for await (const x of [Promise.resolve("a"),Promise.resolve("b"),Promise.resolve("c")]) out.push(x); console.log(out.join("")); })();' \
    | assert_eq forawait_array_promises 'abc'

# 4. mixed promise / plain values in the source iterable.
echo '(async()=>{ let out=[]; for await (const x of [Promise.resolve(1),2,Promise.resolve(3)]) out.push(x); console.log(out.join(",")); })();' \
    | assert_eq forawait_mixed '1,2,3'

# 5. `break` out of a for-await loop stops iteration.
echo 'async function* g(){ yield 1; yield 2; yield 3; yield 4; }
(async()=>{ let s=0; for await (const x of g()){ if(x===3) break; s+=x; } console.log(s); })();' \
    | assert_eq forawait_break '3'

# 6. `continue` skips to the next produced value.
echo 'async function* g(){ yield 1; yield 2; yield 3; yield 4; }
(async()=>{ let s=0; for await (const x of g()){ if(x%2===0) continue; s+=x; } console.log(s); })();' \
    | assert_eq forawait_continue '4'

# ===========================================================================
# JSON.stringify(value, replacer)
# ---------------------------------------------------------------------------
# 7. array allowlist selects object keys (and applies at every object level).
echo 'console.log(JSON.stringify({a:1,b:2,c:3}, ["a","c"]));' \
    | assert_eq replacer_allowlist '{"a":1,"c":3}'

# array allowlist filters nested objects too; keys "a","b" kept everywhere.
echo 'console.log(JSON.stringify({a:1,b:{a:2,z:3},z:9}, ["a","b"]));' \
    | assert_eq replacer_allowlist_nested '{"a":1,"b":{"a":2}}'

# 8. function replacer transforms each value.
echo 'console.log(JSON.stringify({a:1,b:2}, (k,v)=>typeof v==="number"?v*2:v));' \
    | assert_eq replacer_fn_double '{"a":2,"b":4}'

# 9. function replacer returning undefined omits the key.
echo 'console.log(JSON.stringify({a:1,b:2,c:3}, (k,v)=> k==="b"?undefined:v));' \
    | assert_eq replacer_fn_omit '{"a":1,"c":3}'

# 10. replacer + pretty-print indent compose.
IND_REF="$(python3 - <<'PY'
import json
print(json.dumps({"a":1}, indent=2))
PY
)"
echo 'console.log(JSON.stringify({a:1,b:2}, ["a"], 2));' \
    | assert_eq replacer_indent "$IND_REF"

# 11. value.toJSON(key) is honored on the replacer path.
echo 'console.log(JSON.stringify({d:{toJSON(){return "X";}}, e:5}, (k,v)=>v));' \
    | assert_eq replacer_tojson '{"d":"X","e":5}'

# 12. no-replacer path is untouched (regression guard vs the fast emitter).
echo 'console.log(JSON.stringify({a:1,b:[2,3],c:{d:true}}));' \
    | assert_eq no_replacer '{"a":1,"b":[2,3],"c":{"d":true}}'

if [ "$fail" -eq 0 ]; then
    echo "[asynciter-host] RESULT: PASS"
    exit 0
else
    echo "[asynciter-host] RESULT: FAIL"
    exit 1
fi
