#!/usr/bin/env bash
# scripts/test_jsengine_json_host.sh — FAST, QEMU-free gate for the native JS
# engine's JSON support (JSON.parse / JSON.stringify in lib/jsengine.ad), via
# the x86_64-linux host driver (user/js_host.ad).
#
# Real web apps lean on JSON constantly, so this gate exercises the corners:
#   * stringify of nested objects/arrays, numbers (int/float/exp/negative),
#     bool/null, and the full escape set (" \ / \n \t \r \b \f \uXXXX + other
#     control chars). Cross-checked against Python's json.dumps (canonicalised
#     to JS-compact spacing) so the oracle is independent of the engine.
#   * stringify semantics: undefined/functions omit their object key and render
#     as null inside arrays.
#   * the pretty-print indent form JSON.stringify(v, null, 2).
#   * parse of a real JSON blob yields the right field values, all escapes and
#     number forms decode correctly, and parse(stringify(v)) round-trips.
#   * malformed input throws a SyntaxError (not silent garbage).
#
# Built with the frozen Python seed compiler (compiles 100% of the tree) so the
# gate is dependency-light and runs in milliseconds without QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[json-host] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/json_compile.log"; then
    echo "[json-host] FAIL: host driver did not compile"; cat "$OUT/json_compile.log"; exit 1
fi
echo "[json-host] PASS host driver compiled -> $BIN"

fail=0

# assert_eq NAME  EXPECTED  <<< js-on-stdin
assert_eq() {
    local name="$1"; local exp="$2"
    local js="$OUT/json_$name.js"
    cat > "$js"
    local got; got="$("$BIN" "$js" 2>&1)"
    if [ "$got" = "$exp" ]; then
        echo "[json-host] PASS $name"
    else
        echo "[json-host] FAIL $name"
        echo "  expected: $exp"
        echo "  got:      $got"
        fail=1
    fi
}

# ---------------------------------------------------------------------------
# 1. stringify of a nested structure, cross-checked against Python json.dumps.
#    Python preserves dict insertion order (3.7+); we render compact (no spaces)
#    to match JS's default JSON.stringify separators.
NEST_JS='var v={name:"hamnix",version:2,tags:["os","p9",null],meta:{ok:true,ratio:1.5,neg:-3,exp:2000},empty:{},list:[]};console.log(JSON.stringify(v));'
NEST_REF="$(python3 - <<'PY'
import json,collections
v=collections.OrderedDict([
 ("name","hamnix"),("version",2),("tags",["os","p9",None]),
 ("meta",collections.OrderedDict([("ok",True),("ratio",1.5),("neg",-3),("exp",2000)])),
 ("empty",collections.OrderedDict()),("list",[]),
])
print(json.dumps(v,separators=(',',':')))
PY
)"
echo "$NEST_JS" | assert_eq nested "$NEST_REF"

# ---------------------------------------------------------------------------
# 2. every escape type, cross-checked against Python json.dumps of the same
#    code points. We build the source string on the JS side by parsing an
#    escaped literal, then re-stringify it.
ESC_REF="$(python3 - <<'PY'
import json
s='q"\\/'+"\n\t\r\b\f"+chr(1)+chr(31)+'x'
print(json.dumps(s))
PY
)"
# JSON source for that same string (parse -> value -> stringify round-trip).
printf '%s\n' 'var s=JSON.parse("\"q\\\"\\\\\\/\\n\\t\\r\\b\\f\\u0001\\u001fx\"");console.log(JSON.stringify(s));' \
    | assert_eq escapes "$ESC_REF"

# ---------------------------------------------------------------------------
# 3. numbers: int, float, negative, exponent.
echo 'console.log(JSON.stringify([0,42,-7,3.5,-0.5,2000,12500]));' \
    | assert_eq numbers '[0,42,-7,3.5,-0.5,2000,12500]'

# ---------------------------------------------------------------------------
# 4. undefined/function semantics: object drops the key, array becomes null.
echo 'var v={a:1,b:undefined,c:function(){},d:2};console.log(JSON.stringify(v));console.log(JSON.stringify([1,undefined,function(){},4]));' \
    | assert_eq undef_omit '{"a":1,"d":2}
[1,null,null,4]'

# ---------------------------------------------------------------------------
# 5. pretty-print indent form, cross-checked against Python json.dumps(indent=2).
IND_REF="$(python3 - <<'PY'
import json,collections
v=collections.OrderedDict([("a",1),("b",[2,3]),("c",collections.OrderedDict([("d",True)]))])
print(json.dumps(v,indent=2))
PY
)"
echo 'var v={a:1,b:[2,3],c:{d:true}};console.log(JSON.stringify(v,null,2));' \
    | assert_eq indent "$IND_REF"

# ---------------------------------------------------------------------------
# 6. parse of a real JSON blob -> correct field values.
echo 'var p=JSON.parse("{\"nums\":[5,10,15],\"name\":\"parsed\",\"flag\":true,\"nil\":null,\"nested\":{\"x\":-2.5}}");console.log(p.nums[2],p.name,p.nums.length,p.flag,p.nil,p.nested.x);' \
    | assert_eq parse_fields '15 parsed 3 true null -2.5'

# ---------------------------------------------------------------------------
# 7. round-trip: parse(stringify(v)) structurally equals v.
echo 'var v={a:1,b:"two",c:[3,4,{e:5}],d:{f:true,g:null},h:-1.5e2};var r=JSON.parse(JSON.stringify(v));console.log(r.a,r.b,r.c[2].e,r.d.f,r.d.g,r.h);console.log(JSON.stringify(r)===JSON.stringify(v));' \
    | assert_eq roundtrip '1 two 5 true null -150
true'

# ---------------------------------------------------------------------------
# 8. malformed inputs throw SyntaxError (each caught and reported by name).
echo 'function t(s){try{JSON.parse(s);return "NOTHROW";}catch(e){return e.name;}}console.log(t("{bad}"),t("[1,2"),t("nul"),t("{\"a\":}"),t("\"abc"),t("[1 2]"),t("123x"));' \
    | assert_eq malformed 'SyntaxError SyntaxError SyntaxError SyntaxError SyntaxError SyntaxError SyntaxError'

# ---------------------------------------------------------------------------
# 9. valid inputs do NOT throw (guard against over-eager error reporting).
echo 'function t(s){try{JSON.parse(s);return "OK";}catch(e){return "THROW";}}console.log(t("{}"),t("[]"),t("  { \"a\" : [ 1 , 2 ] } "),t("true"),t("null"),t("-3.14e2"));' \
    | assert_eq valid_no_throw 'OK OK OK OK OK OK'

if [ "$fail" -eq 0 ]; then
    echo "[json-host] RESULT: PASS"
    exit 0
else
    echo "[json-host] RESULT: FAIL"
    exit 1
fi
