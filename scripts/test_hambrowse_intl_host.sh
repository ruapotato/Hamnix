#!/usr/bin/env bash
# scripts/test_hambrowse_intl_host.sh — FAST, QEMU-free gate for the JS engine's
# formatting / i18n surface via the x86_64-linux host driver (user/js_host.ad):
#   * Intl.NumberFormat  — grouping, fraction-digit rounding, currency, percent
#   * Intl.DateTimeFormat — common option bags on a FIXED epoch (deterministic)
#   * Date.prototype.toLocale{Date,Time,}String
#   * Date gaps — toISOString, Date.parse (ISO 8601), Date.UTC,
#     getTimezoneOffset (UTC=0), setTime / setUTC* setters
#   * JSON gaps — space indentation, array replacer, function replacer, reviver,
#     and toJSON honored (notably Date serialization on the fast path)
#
# DETERMINISM: every date case uses a FIXED epoch-ms passed explicitly (never
# Date.now()/Math.random()), and the engine is UTC-only (getTimezoneOffset()==0),
# so outputs are reproducible and asserted against exact en-US strings.
#
# LOCALE SIMPLIFICATION (intentional, documented in lib/web/js/builtins/intl.ad):
# only en-US grouping (','), decimal point ('.'), and English month/weekday names
# are implemented; a `locales` argument is accepted but otherwise ignored.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-intl] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_intl_compile.log"; then
    echo "[js-intl] FAIL: host driver did not compile"; cat "$OUT/js_intl_compile.log"; exit 1
fi
echo "[js-intl] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_intl_case.js"
    local got
    got="$("$BIN" "$OUT/js_intl_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-intl] PASS $name"
    else
        echo "[js-intl] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ============================ Intl.NumberFormat ============================
# grouping + default maximumFractionDigits (3)
assert nf_default   'console.log(new Intl.NumberFormat("en-US").format(1234567.891))'   '1,234,567.891'
assert nf_int       'console.log(new Intl.NumberFormat("en-US").format(1234567))'       '1,234,567'
# maximumFractionDigits rounding (ties away from zero: .5678 -> .57)
assert nf_round     'console.log(new Intl.NumberFormat("en-US",{maximumFractionDigits:2}).format(1234.5678))' '1,234.57'
assert nf_roundup   'console.log(new Intl.NumberFormat("en-US",{maximumFractionDigits:0}).format(2.5))'       '3'
# minimumFractionDigits padding
assert nf_min2      'console.log(new Intl.NumberFormat("en-US",{minimumFractionDigits:2}).format(5))'         '5.00'
# currency (USD $, 2 fraction digits by default)
assert nf_usd       'console.log(new Intl.NumberFormat("en-US",{style:"currency",currency:"USD"}).format(1234.5))'  '$1,234.50'
assert nf_negusd    'console.log(new Intl.NumberFormat("en-US",{style:"currency",currency:"USD"}).format(-1234.5))' '-$1,234.50'
assert nf_eur       'console.log(new Intl.NumberFormat("en-US",{style:"currency",currency:"EUR"}).format(9.9))'     '€9.90'
assert nf_gbp       'console.log(new Intl.NumberFormat("en-US",{style:"currency",currency:"GBP"}).format(3))'      '£3.00'
# percent (x100, default 0 fraction digits; with max digits)
assert nf_pct       'console.log(new Intl.NumberFormat("en-US",{style:"percent"}).format(0.1234))'                 '12%'
assert nf_pct1      'console.log(new Intl.NumberFormat("en-US",{style:"percent",maximumFractionDigits:1}).format(0.1234))' '12.3%'
# useGrouping:false disables the thousands separators
assert nf_nogrp     'console.log(new Intl.NumberFormat("en-US",{useGrouping:false}).format(1234567))'              '1234567'

# =========================== Intl.DateTimeFormat ==========================
# All cases use FIXED epoch-ms for determinism.
#   1609459200000 = 2021-01-01T00:00:00.000Z (a Friday)
#   1609462861500 = 2021-01-01T01:01:01.500Z
assert dtf_default  'console.log(new Intl.DateTimeFormat("en-US").format(new Date(1609459200000)))'  '1/1/2021'
assert dtf_long     'console.log(new Intl.DateTimeFormat("en-US",{year:"numeric",month:"long",day:"numeric"}).format(new Date(1609459200000)))'   'January 1, 2021'
assert dtf_short    'console.log(new Intl.DateTimeFormat("en-US",{year:"numeric",month:"short",day:"numeric"}).format(new Date(1609459200000)))'  'Jan 1, 2021'
assert dtf_weekday  'console.log(new Intl.DateTimeFormat("en-US",{weekday:"long",year:"numeric",month:"long",day:"numeric"}).format(new Date(1609459200000)))' 'Friday, January 1, 2021'
assert dtf_time12   'console.log(new Intl.DateTimeFormat("en-US",{hour:"numeric",minute:"2-digit",second:"2-digit"}).format(new Date(1609462861500)))' '1:01:01 AM'
assert dtf_time24   'console.log(new Intl.DateTimeFormat("en-US",{hour:"2-digit",minute:"2-digit",hour12:false}).format(new Date(1609462861500)))'    '01:01'

# ==================== Date.prototype.toLocale*String ======================
assert loc_date     'console.log(new Date(1609459200000).toLocaleDateString("en-US"))'  '1/1/2021'
assert loc_time     'console.log(new Date(1609462861500).toLocaleTimeString("en-US"))'  '1:01:01 AM'
assert loc_both     'console.log(new Date(1609459200000).toLocaleString("en-US"))'      '1/1/2021, 12:00:00 AM'
assert loc_midnite  'console.log(new Date(0).toLocaleTimeString("en-US"))'              '12:00:00 AM'
assert loc_noon     'console.log(new Date(1609502400000).toLocaleTimeString("en-US"))'  '12:00:00 PM'

# ============================== Date gaps =================================
assert iso_fixed    'console.log(new Date(1609459200000).toISOString())'                '2021-01-01T00:00:00.000Z'
assert dparse_full  'console.log(Date.parse("2021-01-01T00:00:00.000Z"))'               '1609459200000'
assert dparse_dateonly 'console.log(Date.parse("2021-01-01"))'                          '1609459200000'
assert dparse_nofrac 'console.log(Date.parse("2021-01-01T01:01:01Z"))'                  '1609462861000'
assert dctor_str    'console.log(new Date("2021-01-01T00:00:00Z").getTime())'           '1609459200000'
assert dutc         'console.log(Date.UTC(2021,0,1))'                                    '1609459200000'
assert dutc_full    'console.log(Date.UTC(2020,1,29,12,30,15,250))'                      '1582979415250'
assert tzoffset     'console.log(new Date(0).getTimezoneOffset())'                       '0'
assert settime      'var d=new Date(0);d.setTime(1609459200000);console.log(d.toISOString())'   '2021-01-01T00:00:00.000Z'
assert setfullyear  'var d=new Date(1609459200000);d.setUTCFullYear(2022);console.log(d.toISOString())' '2022-01-01T00:00:00.000Z'
assert setmonth     'var d=new Date(1609459200000);d.setUTCMonth(5);console.log(d.toISOString())'       '2021-06-01T00:00:00.000Z'
assert sethms       'var d=new Date(1609459200000);d.setUTCHours(13);d.setUTCMinutes(45);console.log(d.toISOString())' '2021-01-01T13:45:00.000Z'

# =============================== JSON gaps ================================
# space indentation (assert the 3 lines individually to keep single-line compare)
assert json_space1  'console.log(JSON.stringify({a:1,b:2},null,2).split("\n")[0])'      '{'
assert json_space2  'console.log(JSON.stringify({a:1,b:2},null,2).split("\n")[1])'      '  "a": 1,'
# array replacer (allowlist filters keys, order = allowlist order per spec is key order)
assert json_reparr  'console.log(JSON.stringify({a:1,b:2,c:3},["a","c"]))'              '{"a":1,"c":3}'
# function replacer (drop a key by returning undefined)
assert json_repfn   'console.log(JSON.stringify({a:1,b:2},function(k,v){return k==="b"?undefined:v;}))' '{"a":1}'
# reviver transforms values bottom-up
assert json_reviver 'var o=JSON.parse("{\"a\":1,\"b\":2}",function(k,v){return typeof v==="number"?v*10:v;});console.log(o.a,o.b)' '10 20'
# toJSON honored — user object (via replacer path) and Date (fast path)
assert json_tojson_user 'console.log(JSON.stringify({t:{toJSON:function(){return "X";}}},function(k,v){return v;}))' '{"t":"X"}'
assert json_tojson_date 'console.log(JSON.stringify({created:new Date(1609459200000)}))' '{"created":"2021-01-01T00:00:00.000Z"}'

if [ "$fail" -eq 0 ]; then
    echo "[js-intl] RESULT: PASS"
    exit 0
else
    echo "[js-intl] RESULT: FAIL"
    exit 1
fi
