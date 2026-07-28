#!/usr/bin/env bash
# scripts/test_jsengine_bigint_host.sh — FAST, QEMU-free gate for the JS engine's
# arbitrary-precision BigInt, via the x86_64-linux host driver (user/js_host.ad).
#
# Before this round the `n` suffix lexed but the value was kept as a lossy
# float64 Number, so any integer past 2^53 silently lost precision. This gate
# locks in a TRUE BigInt value type: a sign + base-2^32 limb magnitude, with
# exact + - * / % ** arithmetic (÷ truncates toward zero), two's-complement
# bitwise ops, cross-type comparisons, typeof/String/toString, truthiness, the
# BigInt() conversion + asIntN/asUintN, and the spec-mandated TypeErrors for
# mixing with Number and for JSON.stringify.
#
# Correctness is checked against KNOWN big-number results (powers, factorials).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-bigint] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_bigint_compile.log"; then
    echo "[js-bigint] FAIL: host driver did not compile"; cat "$OUT/js_bigint_compile.log"; exit 1
fi
echo "[js-bigint] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_bigint_case.js"
    local got
    got="$("$BIN" "$OUT/js_bigint_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-bigint] PASS $name"
    else
        echo "[js-bigint] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- exact large-magnitude arithmetic (known results) ----
assert pow2_100     'console.log(2n ** 100n)'                              '1267650600228229401496703205376'
assert pow10_30     'console.log(10n ** 30n)'                              '1000000000000000000000000000000'
assert pow2_64      'console.log(2n ** 64n)'                               '18446744073709551616'
assert fact_25      'let f=1n;for(let i=1n;i<=25n;i++)f*=i;console.log(f)'  '15511210043330985984000000'
assert fact_50      'let f=1n;for(let i=1n;i<=50n;i++)f*=i;console.log(f)'  '30414093201713378043612608166064768844377641568960512000000000000'
assert big_add      'console.log(99999999999999999999n + 1n)'             '100000000000000000000'
assert big_sub      'console.log(100000000000000000000n - 1n)'            '99999999999999999999'
assert big_mul      'console.log(123456789012345678901234567890n * 2n)'  '246913578024691357802469135780'

# ---- division truncates toward zero; modulo takes sign of dividend ----
assert div_trunc    'console.log(7n / 2n, -7n / 2n, 7n / -2n)'            '3 -3 -3'
assert mod_sign     'console.log(7n % 3n, -7n % 3n, 7n % -3n)'           '1 -1 1'
assert div_big      'console.log((10n ** 40n) / (10n ** 20n))'           '100000000000000000000'

# ---- typeof / String / toString / truthiness ----
assert typeof_lit   'console.log(typeof 1n, typeof BigInt(5))'            'bigint bigint'
assert string_ctor  'console.log(String(255n))'                          '255'
assert tostr_radix  'console.log((255n).toString(16), (255n).toString(2))' 'ff 11111111'
assert truthy       'console.log(0n ? "t":"f", 5n ? "t":"f")'            'f t'
assert neg_unary    'console.log(-5n, -(2n**70n))'                       '-5 -1180591620717411303424'

# ---- BigInt() conversions ----
assert from_int     'console.log(BigInt(42), BigInt(0), BigInt(-7))'     '42 0 -7'
assert from_str     'console.log(BigInt("999999999999999999999"))'      '999999999999999999999'
assert from_bool    'console.log(BigInt(true), BigInt(false))'          '1 0'
assert from_hex     'console.log(0xffn, 0b1010n, 0o17n)'                '255 10 15'

# ---- comparisons, incl. BigInt-vs-Number numeric compare + strict/loose eq ----
assert cmp_bi       'console.log(2n < 3n, 10n > 2n, 5n <= 5n, 5n >= 6n)' 'true true true false'
assert cmp_mix      'console.log(2n < 3, 10n > 2, 5n == 5, 5n == 5.0)'   'true true true true'
assert eq_strict    'console.log(5n === 5, 5n === 5n, 5n !== 6n)'        'false true true'
assert eq_big       'console.log(9007199254740993n == 9007199254740993n)' 'true'

# ---- mixing BigInt with Number throws TypeError (per spec) ----
assert mix_add      'try{1n + 1}catch(e){console.log(e.name)}'           'TypeError'
assert mix_mul      'try{2n * 3.5}catch(e){console.log(e.name)}'         'TypeError'
assert mix_pos      'try{+1n}catch(e){console.log(e.name)}'              'TypeError'
assert div_zero     'try{5n / 0n}catch(e){console.log(e.name)}'         'RangeError'

# ---- string concatenation with + keeps BigInt (spec: string-coerce) ----
assert concat_r     'console.log(1n + "x", "n=" + 42n)'                  '1x n=42'

# ---- bitwise (two'\''s-complement, incl. negatives) ----
assert bit_and      'console.log(12n & 10n, 12n | 10n, 12n ^ 10n)'      '8 14 6'
assert bit_shift    'console.log(1n << 40n, 1024n >> 3n, -8n >> 1n)'    '1099511627776 128 -4'
assert bit_notneg   'console.log(~0n, ~5n, -1n & 255n)'                 '-1 -6 255'

# ---- BigInt.asIntN / asUintN ----
assert asintn       'console.log(BigInt.asIntN(8, 256n), BigInt.asIntN(8, 255n))'  '0 -1'
assert asuintn      'console.log(BigInt.asUintN(8, -1n), BigInt.asUintN(4, 17n))'  '255 1'

# ---- JSON.stringify throws on BigInt (per spec) ----
assert json_throw   'try{JSON.stringify(1n)}catch(e){console.log(e.name)}'          'TypeError'
assert json_nested  'try{JSON.stringify({a:1n})}catch(e){console.log(e.name)}'      'TypeError'

if [ "$fail" = 0 ]; then
    echo "[js-bigint] RESULT: PASS"
    exit 0
else
    echo "[js-bigint] RESULT: FAIL"
    exit 1
fi
