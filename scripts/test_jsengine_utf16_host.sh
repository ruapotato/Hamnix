#!/usr/bin/env bash
# scripts/test_jsengine_utf16_host.sh — FAST, QEMU-free gate for UTF-16 STRING
# SEMANTICS in the JS engine (lib/web/js/) via the x86_64-linux host driver
# (user/js_host.ad).
#
# Strings are STORED as UTF-8 bytes, but ECMAScript defines length, indexing,
# slicing and every position argument over UTF-16 CODE UNITS. Indexing the
# bytes directly did not merely miscount ("©".length was 2, not 1) — it
# SPLIT multi-byte sequences, so charAt/slice/split("") returned invalid
# strings that then propagated. This gate pins the code-unit behaviour:
#   * .length / charCodeAt / codePointAt / charAt / at / [i] / ["i"]
#   * slice / substring / substr / indexOf(+fromIndex) / lastIndexOf
#   * split("") (code UNITS) vs spread & Array.from (code POINTS)
#   * padStart/padEnd with a multi-byte filler
#   * astral characters as SURROGATE PAIRS, incl. half-slicing round-trip
#   * String.fromCharCode / fromCodePoint encode, they do not truncate
#   * regex .index / .lastIndex / .indices in code units, and `.` / classes
#     consuming a WHOLE sequence rather than one byte
#
# Every expectation below was taken from `node` value-by-value.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-utf16] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_utf16_compile.log"; then
    echo "[js-utf16] FAIL: host driver did not compile"; cat "$OUT/js_utf16_compile.log"; exit 1
fi
echo "[js-utf16] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_utf16_case.js"
    local got
    got="$("$BIN" "$OUT/js_utf16_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-utf16] PASS $name"
    else
        echo "[js-utf16] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- length is code units, not bytes ----
assert len_bmp1    'console.log("©".length, "café".length, "ééé".length)'   '1 4 3'
assert len_ascii   'console.log("test".length, "".length, "a b".length)'                             '4 0 3'
assert len_astral  'console.log("\u{1d11e}".length, "\u{1d11e}X".length)'                            '2 3'
assert len_concat  'console.log(("x"+"é"+"y").length)'                                          '3'
assert len_repeat  'console.log("é".repeat(3).length)'                                          '3'
assert len_trim    'console.log("  ©  ".trim().length)'                                         '1'

# ---- charCodeAt / codePointAt ----
assert cca_bmp     'console.log("©".charCodeAt(0), "café".charCodeAt(3))'                  '169 233'
assert cca_oob     'console.log("hello".charCodeAt(0), "hello".charCodeAt(99))'                      '104 NaN'
assert cca_astral  'console.log("\u{1d11e}".charCodeAt(0), "\u{1d11e}".charCodeAt(1))'               '55348 56606'
assert cpa         'console.log("é".codePointAt(0), "café".codePointAt(3))'                '233 233'
assert cpa_astral  'console.log("\u{1d11e}".codePointAt(0), "\u{1d11e}".codePointAt(1))'             '119070 56606'

# ---- indexing: charAt / at / [i] ----
assert idx_num     'console.log("café"[3], "café"[4])'                                     'é undefined'
assert idx_str     'console.log("abc"["1"], "abé"["2"])'                                        'b é'
assert at_neg      'console.log("café".at(-1), "café".charAt(3))'                          'é é'
assert charat_oob  'console.log("hello".charAt(9)+"|", "hello".at(-1))'                              '| o'

# ---- slicing never splits a sequence ----
assert slice_mb    'console.log(JSON.stringify("café".slice(3,4)), JSON.stringify("café".slice(0,3)))' '"é" "caf"'
assert slice_mid   'console.log("éabc".slice(1,3), "abcé".slice(2,4))'                     'ab cé'
assert slice_ascii 'console.log("hello".slice(1,3), "hello".slice(-2), "hello".slice(3,1)+"|")'      'el lo |'
assert substr_mb   'console.log("café".substr(3,1), "café".substring(3))'                  'é é'
assert slice_rt    'var s="\u{1d11e}X"; console.log(s.slice(0,1).length, s.slice(1).length, (s.slice(0,1)+s.slice(1))===s)' '1 2 true'

# ---- indexOf / lastIndexOf report code units, and honour fromIndex ----
assert iof_from    'console.log("abcabc".indexOf("a",1), "abcabc".indexOf("a",4), "abc".indexOf("",1))' '3 -1 1'
assert iof_mb      'console.log("ééé".indexOf("é",1), "ééé".lastIndexOf("é"))' '1 2'
assert iof_astral  'console.log("\u{1d11e}X".indexOf("X"), "\u{1d11e}X".charCodeAt(2))'              '2 88'
assert iof_miss    'console.log("hello".indexOf("z"), "hello".lastIndexOf("z"))'                     '-1 -1'

# ---- split("") is CODE UNITS; spread / Array.from are CODE POINTS ----
assert split_mb    'console.log(JSON.stringify("aé".split("")))'                                '["a","é"]'
assert split_sep   'console.log(JSON.stringify("a,b,,c".split(",")), JSON.stringify("abc".split("")))' '["a","b","","c"] ["a","b","c"]'
assert spread_cp   'console.log([..."abé"].length, Array.from("abé").length, [..."\u{1d11e}"].length)' '3 3 1'
assert forof_cp    'var o="";for (const c of "aéb") o+=c+".";console.log(o)'                    'a.é.b.'
assert from_map    'console.log(Array.from("abé",(c,i)=>i+c).join("|"))'                        '0a|1b|2é'

# ---- padStart/padEnd count code units, filler may be multi-byte ----
assert pad_mb      'console.log("é".padStart(3,"x"), "x".padStart(4,"é"))'                 'xxé éééx'
assert pad_ascii   'console.log("5".padStart(3,"0"), "5".padEnd(3,"ab"), "abc".padStart(2,"x"))'     '005 5ab abc'

# ---- String.fromCharCode / fromCodePoint encode ----
assert fcc         'console.log(String.fromCharCode(169), String.fromCharCode(65,66))'               '© AB'
assert fcc_pair    'console.log(String.fromCharCode(0xd834,0xdd1e).length, String.fromCodePoint(0x1d11e).length)' '2 2'
assert fcp         'console.log(String.fromCodePoint(0x263a,65))'                                    '☺A'

# ---- regex indices are code units; `.` consumes a whole sequence ----
assert re_index    'console.log(/b(c)/.exec("abcd").index, "abcd".search(/cd/), "abcd".search(/zz/))' '1 2 -1'
assert re_index_mb 'var g=/(?<y>\d+)/.exec("é 77"); console.log(g.index, g.groups.y)'           '2 77'
assert re_lastidx  'var r=/o/g,s="foo boo",m,out=[];while((m=r.exec(s)))out.push(m.index);console.log(JSON.stringify(out))' '[1,2,5,6]'
assert re_indices  'var d=/(\d+)/d.exec("é 12"); console.log(d.index, JSON.stringify(d.indices))' '2 [[2,4],[2,4]]'
assert re_dot_mb   'console.log(JSON.stringify("aéb".match(/./g)))'                             '["a","é","b"]'
assert re_cls_mb   'console.log(JSON.stringify("aéb".match(/[^x]/g)), "aéb".replace(/./g,"-"))' '["a","é","b"] ---'
assert re_word     'console.log(JSON.stringify("a1é2b".replace(/\d/g,"#")))'                    '"a#é#b"'

# ---- the ASCII fast path must be untouched ----
assert ascii_all   'var s="The quick brown fox";console.log(s.length, s.indexOf("brown"), s.slice(4,9), s.charCodeAt(0), s.split(" ").length)' '19 10 quick 84 4'

if [ "$fail" -eq 0 ]; then
    echo "[js-utf16] ALL PASS"
    exit 0
fi
echo "[js-utf16] FAILURES present"
exit 1
