#!/usr/bin/env bash
# scripts/test_jsengine_date_host.sh — FAST, QEMU-free gate for the JS engine's
# Date object (lib/jsengine.ad) via the x86_64-linux host driver
# (user/js_host.ad).
#
# Real interactive pages use Date constantly (timestamps, formatting, timers).
# This gate asserts the Date implementation against node/python semantics with
# self-contained inline assertions (no external oracle to drift). Dates are
# UTC-based; the civil<->days conversion is Howard Hinnant's exact algorithm
# (no 365.25 approximation), so leap years / century rules are correct — the
# leap-day case (2020-02-29) below would fail an approximate implementation.
#
# Date.now() has no wall-clock source in the extern-free engine (it returns a
# monotonic counter), so it is asserted only to be a plausible increasing
# number — never against wall-clock.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-date] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_date_compile.log"; then
    echo "[js-date] FAIL: host driver did not compile"; cat "$OUT/js_date_compile.log"; exit 1
fi
echo "[js-date] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_date_case.js"
    local got
    got="$("$BIN" "$OUT/js_date_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-date] PASS $name"
    else
        echo "[js-date] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- epoch 0 (1970-01-01T00:00:00.000Z, a Thursday=4) ----
assert epoch0_iso     'console.log(new Date(0).toISOString())'                 '1970-01-01T00:00:00.000Z'
assert epoch0_gettime 'console.log(new Date(0).getTime())'                     '0'
assert epoch0_valueof 'console.log(new Date(0).valueOf())'                     '0'
assert epoch0_day     'console.log(new Date(0).getDay())'                      '4'

# ---- 2021-01-01T00:00:00.000Z (a Friday=5) ----
assert y2021_year     'console.log(new Date(1609459200000).getFullYear())'     '2021'
assert y2021_month    'console.log(new Date(1609459200000).getMonth())'        '0'
assert y2021_date     'console.log(new Date(1609459200000).getDate())'         '1'
assert y2021_day      'console.log(new Date(1609459200000).getDay())'          '5'
assert y2021_iso      'console.log(new Date(1609459200000).toISOString())'     '2021-01-01T00:00:00.000Z'

# ---- leap day: 2020-02-29 (would be wrong with a 365.25 approximation) ----
assert leap_fields    'var d=new Date(1582934400000);console.log(d.getFullYear(),d.getMonth(),d.getDate())' '2020 1 29'
assert leap_iso       'console.log(new Date(1582934400000).toISOString())'     '2020-02-29T00:00:00.000Z'

# ---- time-of-day on a known ms: 2021-01-01 01:01:01.500 ----
assert hms            'var d=new Date(1609462861500);console.log(d.getHours(),d.getMinutes(),d.getSeconds(),d.getMilliseconds())' '1 1 1 500'

# ---- negative epoch (pre-1970) exercises floor division + negative-era path ----
assert neg_iso        'console.log(new Date(-86400000).toISOString())'         '1969-12-31T00:00:00.000Z'
assert neg_day        'console.log(new Date(-86400000).getDay())'              '3'

# ---- far-future / leap-century (year 9999) ----
assert y9999_iso      'console.log(new Date(253402300799999).toISOString())'   '9999-12-31T23:59:59.999Z'

# ---- component constructor (treated as UTC) ----
assert comp_iso       'console.log(new Date(2021,0,1).toISOString())'          '2021-01-01T00:00:00.000Z'
assert comp_full      'console.log(new Date(2020,1,29,12,30,15,250).toISOString())' '2020-02-29T12:30:15.250Z'
assert comp_ovf       'console.log(new Date(2020,13,1).toISOString())'         '2021-02-01T00:00:00.000Z'

# ---- copy constructor ----
assert copy_ctor      'var a=new Date(1234567);console.log(new Date(a).getTime())' '1234567'

# ---- toString: ES 21.4.4.41 ToDateString, verbatim ----
# This used to pin "1970-01-01 00:00:00 UTC" — a spelling NO engine produces.
# It only survived because nothing depended on it: `String(date)` went through
# the console inspect renderer (ISO), not through Date.prototype.toString. Once
# ToPrimitive routed string coercion through toString the invented format became
# user-visible, so it now matches node v20 under TZ=UTC character for character.
# (This engine has no timezone database; its local time IS UTC, hence +0000.)
assert tostring       'console.log(new Date(0).toString())'                    'Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)'
assert tostring_coerce 'console.log(""+new Date(0) === new Date(0).toString())' 'true'
assert tostring_invalid 'console.log(new Date(NaN).toString())'                'Invalid Date'
assert display        'console.log(new Date(1609459200000))'                   '2021-01-01T00:00:00.000Z'

# ---- Date.now(): a plausible, strictly increasing number (NOT wall-clock) ----
assert now_type       'console.log(typeof Date.now())'                         'number'
assert now_increasing 'var a=Date.now(),b=Date.now();console.log(b>a)'         'true'

if [ "$fail" -eq 0 ]; then
    echo "[js-date] RESULT: PASS"
    exit 0
else
    echo "[js-date] RESULT: FAIL"
    exit 1
fi
