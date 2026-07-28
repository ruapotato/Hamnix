#!/usr/bin/env bash
# scripts/test_jsengine_tonumber_host.sh — FAST, QEMU-free gate for ToNumber(String)
# (the ECMAScript StringNumericLiteral grammar) in lib/web/js, via the
# x86_64-linux host driver (user/js_host.ad).
#
# WHY THIS GATE EXISTS
# to_number() used to hand a TAG_STR straight to parse_num_bytes — the LEXER's
# numeric-literal scanner. That scanner reads a numeric PREFIX and ignores
# whatever follows, which is parseInt behavior, not ToNumber: `+"1s"` came out
# as 1 where every engine says NaN. A fuzzer found it, and the shape is
# poisonous because it is SILENT — a page that does `+el.dataset.width` on
# "120px" got 120 instead of NaN and laid out as if the value were valid.
#
# The whole grammar has to be covered together, because a partial fix is its own
# bug: a throwaway diagnostic patch made whole-string consumption strict and
# thereby broke "Infinity"/"-Infinity", which the prefix scanner had never
# handled either. So this gate pins, all at once:
#
#   * whole-string consumption          "1s" "12abc" "1 2" "1.2.3" -> NaN
#   * the empty and all-whitespace string -> +0 (NOT NaN)
#   * Infinity / +Infinity / -Infinity, and that "infinity" and "Infinity1"
#     are still NaN
#   * hex/octal/binary literals, and that a SIGN in front of them is NaN
#     ("0x10" is 16 but "-0x10" is NaN)
#   * ES2021 numeric separators are SOURCE syntax only: Number("1_0") is NaN,
#     while the literal 1_0 is still 10
#   * leading AND trailing trim of the full Unicode WhiteSpace + LineTerminator
#     set (U+00A0 U+1680 U+2000-200A U+2028 U+2029 U+202F U+205F U+3000
#     U+FEFF) but NOT U+200B, which is not whitespace and yields NaN
#   * parseFloat keeps its PREFIX behavior (that is what parseFloat IS) but got
#     its own scanner: it must accept "Infinity" and must NOT accept hex or
#     numeric separators. parseInt is untouched and pinned here too.
#
# EVERY expectation below was produced by running the same one-liner through
# `node` (v20) and pasting its stdout — not from reading the spec.
#
# NOTE ON -0: node's console.log prints the number -0 as "-0" (util.inspect
# special-case) while this engine prints "0". That is a DISPLAY divergence, not
# a ToNumber one, so the two cases that would trip over it assert through
# Object.is(x, -0) instead.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-tonumber] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_tonumber_compile.log"; then
    echo "[js-tonumber] FAIL: host driver did not compile"; cat "$OUT/js_tonumber_compile.log"; exit 1
fi
echo "[js-tonumber] PASS host driver compiled -> $BIN"

fail=0
ran=0
# assert <name> <js-that-console.logs-ONE-line> <expected-first-line-from-node>
assert() {
    local name="$1" js="$2" exp="$3"
    ran=$((ran + 1))
    printf '%s\n' "$js" > "$OUT/js_tonumber_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_tonumber_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-tonumber] PASS $name"
    else
        echo "[js-tonumber] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

assert plus_1s                        'console.log(+"1s")' 'NaN'
assert number_1s                      'console.log(Number("1s"))' 'NaN'
assert mul_1s                         'console.log("1s"*2)' 'NaN'
assert postinc_1s                     'var s="1s";console.log(s++)' 'NaN'
assert number_12abc                   'console.log(Number("12abc"))' 'NaN'
assert number_space_between           'console.log(Number("1 2"))' 'NaN'
assert number_empty                   'console.log(Number(""))' '0'
assert number_ws_only                 'console.log(Number("   "))' '0'
assert number_tabnl_only              'console.log(Number("\t\n\r "))' '0'
assert empty_arith                    'console.log(""*3, ""+1, +"")' '0 1 0'
assert number_infinity                'console.log(Number("Infinity"))' 'Infinity'
assert number_neg_infinity            'console.log(Number("-Infinity"))' '-Infinity'
assert number_plus_infinity           'console.log(Number("+Infinity"))' 'Infinity'
assert number_infinity_ws             'console.log(Number("  Infinity  "), Number(" -Infinity "))' 'Infinity -Infinity'
assert number_infinity_lower          'console.log(Number("infinity"))' 'NaN'
assert number_infinity_trail          'console.log(Number("Infinity1"))' 'NaN'
assert number_infinity_partial        'console.log(Number("Infin"), Number("Infinityy"))' 'NaN NaN'
assert number_infinity_arith          'console.log("Infinity"*1, +"-Infinity", Object.is(1/+"-Infinity",-0))' 'Infinity -Infinity true'
assert number_hex                     'console.log(Number("0x10"), Number("0X1F"), Number("0xff"))' '16 31 255'
assert number_hex_signed              'console.log(Number("-0x10"), Number("+0x10"))' 'NaN NaN'
assert number_hex_empty               'console.log(Number("0x"), Number("0xg"))' 'NaN NaN'
assert number_octal                   'console.log(Number("0o17"), Number("0O17"), Number("0o18"), Number("0o"))' '15 15 NaN NaN'
assert number_binary                  'console.log(Number("0b101"), Number("0B11"), Number("0b12"), Number("0b"))' '5 3 NaN NaN'
assert number_legacy_octal            'console.log(Number("0755"), Number("00"), Number("010"))' '755 0 10'
assert number_seps                    'console.log(Number("1_0"), Number("1_000"), Number("0x1_0"))' 'NaN NaN NaN'
assert number_ws_trim                 'console.log(Number(" 12 "), Number("\n\t 42 \r\n"))' '12 42'
assert number_vt_ff                   'var W=String.fromCharCode;console.log(Number(W(11)+"1"), Number("1"+W(12)))' '1 1'
assert number_unicode_ws              'var W=String.fromCharCode;console.log(Number(W(0xA0)+"1"), Number(W(0x1680)+"1"), Number(W(0x2000)+"1"), Number(W(0x200A)+"1"), Number(W(0x3000)+"1"), Number(W(0xFEFF)+"1"))' '1 1 1 1 1 1'
assert number_lineterm_ws             'var W=String.fromCharCode;console.log(Number(W(0x2028)+"1"), Number(W(0x2029)+"1"))' '1 1'
assert number_nnbsp_mmsp              'var W=String.fromCharCode;console.log(Number(W(0x202F)+"1"), Number(W(0x205F)+"1"))' '1 1'
assert number_zwsp_not_ws             'var W=String.fromCharCode;console.log(Number(W(0x200B)+"1"), Number("1"+W(0x200B)))' 'NaN NaN'
assert number_ws_both_ends            'var W=String.fromCharCode;console.log(Number(W(0xA0)+W(0x3000)+" 2 "+W(0xFEFF)))' '2'
assert number_ws_around_infinity      'var W=String.fromCharCode;console.log(Number(W(0xA0)+"-Infinity"+W(0x2029)))' '-Infinity'
assert number_ws_inside_bad           'var W=String.fromCharCode;console.log(Number("1"+W(0xA0)+"2"))' 'NaN'
assert number_exponent                'console.log(Number("1e3"), Number("1E3"), Number("1e+3"), Number("-1.5e-3"))' '1000 1000 1000 -0.0015'
assert number_exponent_bad            'console.log(Number("1e"), Number("1e+"), Number("1e-"), Number("e5"))' 'NaN NaN NaN NaN'
assert number_dot_forms               'console.log(Number(".5"), Number("5."), Number("."), Number("0.0"), Number("00.5"))' '0.5 5 NaN 0 0.5'
assert number_sign_only               'console.log(Number("-"), Number("+"), Number("--1"), Number("1-"), Number("- 1"))' 'NaN NaN NaN NaN NaN'
assert number_dots                    'console.log(Number("1.2.3"))' 'NaN'
assert number_arabic_digit            'console.log(Number("\u0663"))' 'NaN'
assert number_null_bool_undef         'console.log(Number(null), Number(undefined), Number(true), Number(false))' '0 NaN 1 0'
assert number_no_arg                  'console.log(Number())' '0'
assert isnan_strings                  'console.log(isNaN("1s"), isNaN("12"), isNaN(""), isNaN("Infinity"))' 'true false false false'
assert cmp_relational                 'console.log("1s" < 2, "1s" > 2, "10" < 9, "10" < "9")' 'false false false true'
assert eq_loose                       'console.log("1s" == 1, "1" == 1, "" == 0, "  " == 0, "Infinity" == Infinity)' 'false true true true true'
assert unary_minus                    'console.log(-"1s", -"2", Object.is(-"",-0))' 'NaN -2 true'
assert bitwise_string                 'console.log("1s"|0, "12"|0, ""|0, "Infinity"|0)' '0 12 0 0'
assert math_of_string                 'console.log(Math.abs("1s"), Math.max("1s",1), Math.floor("2.7px"))' 'NaN NaN NaN'
assert date_of_numstring              'console.log(new Date(Number("1s")).getTime())' 'NaN'
assert parsefloat_prefix              'console.log(parseFloat("1s"), parseFloat("  3.5e2xyz"), parseFloat("2.7px"))' '1 350 2.7'
assert parsefloat_infinity            'console.log(parseFloat("Infinity"), parseFloat("-Infinity"), parseFloat("+Infinity"), parseFloat("Inf"))' 'Infinity -Infinity Infinity NaN'
assert parsefloat_nohex               'console.log(parseFloat("0x10"), parseFloat("0b11"))' '0 0'
assert parsefloat_noseps              'console.log(parseFloat("1_0"), parseFloat("1_000"))' '1 1'
assert parsefloat_empty               'console.log(parseFloat(""), parseFloat("   "), parseFloat("abc"))' 'NaN NaN NaN'
assert parsefloat_exp_partial         'console.log(parseFloat("1e"), parseFloat("1e+"), parseFloat("1e3x"))' '1 1 1000'
assert parsefloat_dot                 'console.log(parseFloat(".5"), parseFloat("+.5e-1z"), parseFloat("."))' '0.5 0.05 NaN'
assert parseint_unchanged             'console.log(parseInt("1s"), parseInt("0x10"), parseInt("12abc"), parseInt(""), parseInt("Infinity"))' '1 16 12 NaN NaN'
assert number_roundtrip               'console.log(Number("1234567890123456789"), Number("1e-7"), Number("1e21"))' '1234567890123456800 1e-7 1e+21'
assert json_number_unaffected         'console.log(JSON.parse("[1e3,0.5,-2]").join(","))' '1000,0.5,-2'
assert numeric_literal_seps_still_ok  'console.log(1_000, 0x1_0, 1_0.5_0)' '1000 16 10.5'
assert string_index_key               'var o={};o["1s"]=5;console.log(o["1s"], Object.keys(o).join(","))' '5 1s'
assert array_index_numstring          'var a=[1,2,3];console.log(a["1"], a["1s"])' '2 undefined'

# a gate that asserted nothing would be worthless: prove we actually ran cases
if [ "$ran" -lt 62 ]; then
    echo "[js-tonumber] FAIL: only $ran assertions ran (expected >= 62)"; exit 1
fi
echo "[js-tonumber] $ran assertions executed"

if [ "$fail" -eq 0 ]; then
    echo "[js-tonumber] ALL PASS"
else
    echo "[js-tonumber] SOME FAILED"
fi
exit "$fail"
