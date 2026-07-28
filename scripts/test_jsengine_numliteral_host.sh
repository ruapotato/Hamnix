#!/usr/bin/env bash
# scripts/test_jsengine_numliteral_host.sh — FAST, QEMU-free gate for the JS
# engine's ES2015-2021 NUMERIC LITERAL forms and JSON.parse(text, reviver),
# via the x86_64-linux host driver (user/js_host.ad).
#
# Modern minified/transpiled bundles routinely emit numeric separators
# (1_000_000), binary/octal literals (0b1010 / 0o17), and BigInt-suffixed
# integers (10n). Before this round the lexer split `1_000` into `1` and the
# identifier `_000` (ReferenceError) and treated `0b101` as `0` followed by an
# identifier — a HARD abort of the whole script on the first occurrence.
# JSON.parse's second `reviver` argument was silently ignored, so revived data
# came back untransformed (a correctness bug). This gate locks in both.
#   Literals: numeric separators in dec/hex/binary/octal + fraction + exponent;
#             binary (0b/0B), octal (0o/0O); BigInt `n` suffix (kept as Number).
#   JSON:     JSON.parse(text, reviver) — bottom-up, delete-on-undefined, arrays,
#             holder `this`, root "" key; no-reviver path unchanged.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-numlit] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_numlit_compile.log"; then
    echo "[js-numlit] FAIL: host driver did not compile"; cat "$OUT/js_numlit_compile.log"; exit 1
fi
echo "[js-numlit] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_numlit_case.js"
    local got
    got="$("$BIN" "$OUT/js_numlit_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-numlit] PASS $name"
    else
        echo "[js-numlit] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- numeric separators ----
assert sep_int      'console.log(1_000_000)'                                  '1000000'
assert sep_frac     'console.log(1_00.5 === 100.5, 1_0.2_5 * 4)'            'true 41'
assert sep_exp      'console.log(1e1_0)'                                      '10000000000'
assert sep_hex      'console.log(0xFF_FF)'                                    '65535'
assert sep_mixed    'console.log(1_2 + 3_4)'                                  '46'

# ---- binary literals ----
assert bin_low      'console.log(0b1010)'                                     '10'
assert bin_up       'console.log(0B1111)'                                     '15'
assert bin_sep      'console.log(0b1010_1010)'                                '170'
assert bin_expr     'console.log(0b1 << 4)'                                   '16'

# ---- octal literals ----
assert oct_low      'console.log(0o17)'                                       '15'
assert oct_up       'console.log(0O777)'                                      '511'
assert oct_sep      'console.log(0o1_7)'                                      '15'

# ---- BigInt `n` suffix (now a TRUE arbitrary-precision BigInt; see
#      test_jsengine_bigint_host.sh for the full value-type coverage). The
#      console.log form matches String() semantics (no trailing `n`). ----
assert bigint_add   'console.log(10n + 20n)'                                  '30'
assert bigint_hex   'console.log(0xffn)'                                      '255'

# ---- pre-existing literal forms unaffected ----
assert plain_hex    'console.log(0xff)'                                       '255'
assert plain_float  'console.log(3.14e2)'                                     '314'
assert plain_dot    'console.log(.5 + .5)'                                    '1'

# ---- JSON.parse(text, reviver) ----
assert rv_scale     'console.log(JSON.parse("{\"a\":1,\"b\":2}",function(k,v){return typeof v==="number"?v*10:v}).a)' '10'
assert rv_nested    'var o=JSON.parse("{\"a\":{\"b\":3}}",function(k,v){return typeof v==="number"?v+1:v});console.log(o.a.b)' '4'
assert rv_delete    'var o=JSON.parse("{\"a\":1,\"b\":2}",function(k,v){return k==="b"?undefined:v});console.log(o.a,o.b)' '1 undefined'
assert rv_array     'var a=JSON.parse("[1,2,3]",function(k,v){return typeof v==="number"?v*2:v});console.log(a.join(","))' '2,4,6'
assert rv_this      'JSON.parse("{\"a\":1}",function(k,v){if(k==="a")console.log(typeof this);return v})' 'object'
assert rv_rootkey   'var ks=[];JSON.parse("{\"x\":1}",function(k,v){ks.push(k);return v});console.log(ks.join("|"))' 'x|'
assert rv_none      'console.log(JSON.parse("{\"a\":5}").a)'                  '5'

if [ "$fail" = 0 ]; then
    echo "[js-numlit] RESULT: PASS"
    exit 0
else
    echo "[js-numlit] RESULT: FAIL"
    exit 1
fi
