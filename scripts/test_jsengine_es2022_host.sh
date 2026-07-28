#!/usr/bin/env bash
# scripts/test_jsengine_es2022_host.sh — FAST, QEMU-free gate for the JS engine's
# round-2 W3C/ECMAScript conformance batch (lib/web/js/*) via the x86_64-linux
# host driver (user/js_host.ad). Self-contained inline assertions against node
# semantics (no external oracle file to drift).
#
# Covered this round:
#   Built-ins: Object.prototype.{hasOwnProperty,propertyIsEnumerable,isPrototypeOf};
#              String.{raw,fromCharCode,fromCodePoint};
#              Symbol() basics (typeof, uniqueness, description, Symbol.iterator,
#              symbol-keyed properties);
#              Array.prototype.{toReversed,toSorted,with} (change-array-by-copy);
#              RegExp `$<name>` named-group replacement in String.replace.
#   Language:  object-literal getters/setters (get x(){}/set x(v){}),
#              computed property/method names {[expr]:v}/{[expr](){}},
#              class instance + static fields (x=v / static y=v),
#              tagged templates (proper template AST: the tag fn receives
#              (strings, ...values) with strings.raw = verbatim chunks).
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-es2022] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_es2022_compile.log"; then
    echo "[js-es2022] FAIL: host driver did not compile"; cat "$OUT/js_es2022_compile.log"; exit 1
fi
echo "[js-es2022] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_es2022_case.js"
    local got
    got="$("$BIN" "$OUT/js_es2022_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-es2022] PASS $name"
    else
        echo "[js-es2022] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- Object.prototype.{hasOwnProperty,propertyIsEnumerable,isPrototypeOf} ----
assert hop_basic    'console.log({a:1}.hasOwnProperty("a"),{a:1}.hasOwnProperty("b"))'                 'true false'
assert hop_array    'console.log([1,2].hasOwnProperty(0),[1,2].hasOwnProperty(5),[1,2].hasOwnProperty("length"))' 'true false true'
assert hop_filter   'var o={a:1,b:2};var r="";for(var k in o){if(o.hasOwnProperty(k))r+=k}console.log(r)' 'ab'
assert hop_override 'var o={hasOwnProperty:function(){return "mine"}};console.log(o.hasOwnProperty("x"))' 'mine'
assert pie_basic    'console.log({a:1}.propertyIsEnumerable("a"),{a:1}.propertyIsEnumerable("z"))'     'true false'
assert ipo_class    'class A{};var a=new A();console.log(A.prototype.isPrototypeOf(a),A.prototype.isPrototypeOf({}))' 'true false'
assert ipo_create   'var p={};var o=Object.create(p);console.log(p.isPrototypeOf(o),o.isPrototypeOf(p))' 'true false'

# ---- class fields (instance `x = v`, static `static y = v`, bare `x;`) ----
assert cf_basic     'class A{x=5;getx(){return this.x}}console.log(new A().getx(),new A().x)'          '5 5'
assert cf_ctor      'class A{x=5;constructor(){this.y=this.x*2}}var a=new A();console.log(a.x,a.y)'    '5 10'
assert cf_bare      'class A{x;}var a=new A();console.log("x"in a,a.x)'                                 'true undefined'
assert cf_static    'class A{static y=9;static get(){return A.y}}console.log(A.y,A.get())'             '9 9'
assert cf_static_nm 'class A{static(){return 7}}console.log(new A().static())'                         '7'
assert cf_expr      'var Z=3;class A{v=Z+1}console.log(new A().v)'                                     '4'
assert cf_mix       'class C{n=10;inc(){this.n++;return this.n}}var c=new C();console.log(c.inc(),c.inc())' '11 12'
assert cf_per_inst  'class A{arr=[]}var a=new A();var b=new A();a.arr.push(1);console.log(a.arr.length,b.arr.length)' '1 0'

# ---- object-literal method shorthand + computed property/method names ----
assert om_method    'var o={f(){return 7}};console.log(o.f())'                                         '7'
assert om_args      'var o={add(a,b){return a+b}};console.log(o.add(3,4))'                             '7'
assert om_this      'var o={n:5,get(){return this.n}};console.log(o.get())'                            '5'
assert oc_key       'var k="x";var o={[k]:5};console.log(o.x)'                                         '5'
assert oc_expr      'var o={["a"+"b"]:9};console.log(o.ab)'                                            '9'
assert oc_method    'var k="m";var o={[k](){return 3}};console.log(o.m())'                             '3'
assert oc_num       'var o={[1+1]:"two"};console.log(o[2])'                                            'two'
assert om_kwkey     'var o={if:1,default:2};console.log(o.if,o.default)'                               '1 2'
assert om_mixed     'var k="c";var o={a:1,b(){return 2},[k]:3};console.log(o.a,o.b(),o.c)'            '1 2 3'

# ---- object-literal getters/setters + Object.defineProperty accessors ----
assert acc_getter   'var o={get x(){return 42}};console.log(o.x)'                                      '42'
assert acc_setter   'var o={_v:0,set x(v){this._v=v*2}};o.x=5;console.log(o._v)'                       '10'
assert acc_getset   'var o={_v:1,get x(){return this._v},set x(v){this._v=v}};o.x=9;console.log(o.x)'  '9'
assert acc_this     'var o={n:10,get d(){return this.n*2}};console.log(o.d)'                           '20'
assert acc_getkey   'var o={get:1,set:2};console.log(o.get,o.set)'                                     '1 2'
assert acc_getmeth  'var o={get(){return 5}};console.log(o.get())'                                     '5'
assert acc_dp_get   'var o={};Object.defineProperty(o,"x",{get:function(){return 7}});console.log(o.x)' '7'
assert acc_dp_set   'var o={_v:0};Object.defineProperty(o,"x",{set:function(v){this._v=v+1}});o.x=4;console.log(o._v)' '5'
assert acc_computed 'var k="y";var o={get [k](){return 8}};console.log(o.y)'                           '8'
assert acc_nosetter 'var o={get x(){return 3}};o.x=99;console.log(o.x)'                                '3'

# ---- class getters/setters (instance + static) ----
assert cg_getter    'class C{get x(){return 42}}console.log(new C().x)'                                '42'
assert cg_setter    'class C{constructor(){this._v=0}set x(v){this._v=v*3}get x(){return this._v}}var c=new C();c.x=5;console.log(c.x)' '15'
assert cg_field     'class C{n=10;get d(){return this.n*2}}console.log(new C().d)'                     '20'
assert cg_static    'class C{static get v(){return 99}}console.log(C.v)'                                '99'
assert cg_getmeth   'class C{get(){return 7}}console.log(new C().get())'                               '7'
assert cg_mixed     'class C{constructor(){this._n=1}get n(){return this._n}set n(v){this._n=v}dbl(){return this._n*2}}var c=new C();c.n=4;console.log(c.n,c.dbl())' '4 8'

# ---- tagged templates (proper template node: strings + values + strings.raw) ----
assert tt_values    'function t(s,x,y){return s[0]+x+s[1]+y+s[2]}console.log(t`a${1}b${2}c`)'          'a1b2c'
assert tt_count     'function t(s,...v){return s.length+":"+v.length}console.log(t`a${1}b${2}c`)'       '3:2'
assert tt_raw       'function t(s){return s.raw[0]}console.log(t`a\nb`)'                                 'a\nb'
assert tt_cooked    'function t(s){return s[0].length+","+s.raw[0].length}console.log(t`x\ty`)'         '3,4'
assert tt_nosub     'function t(s){return s.length+s[0]}console.log(t`hi`)'                              '1hi'
assert tt_expr      'var n=5;function t(s,v){return v*2}console.log(t`${n}`)'                            '10'
assert tt_untagged  'var x=3;console.log(`v=${x+1}!`)'                                                   'v=4!'
assert tt_nested    'var a="Z";console.log(`o${`i${a}`}o`)'                                              'oiZo'
assert sr_basic     'console.log(String.raw`a\n${1}b`)'                                                  'a\n1b'
assert sr_tab       'console.log(String.raw`\t${1+1}A`)'                                                 '\t2A'
assert sr_nosub     'console.log(String.raw`plain\d`)'                                                   'plain\d'

# ---- String.fromCharCode / fromCodePoint ----
assert scc_basic    'console.log(String.fromCharCode(72,105))'                                           'Hi'
assert scc_one      'console.log(String.fromCharCode(65))'                                               'A'
assert scp_basic    'console.log(String.fromCodePoint(97,98,99))'                                        'abc'

# ---- Symbol basics (typeof, uniqueness, description, well-known, symbol keys) ----
assert sym_typeof   'console.log(typeof Symbol())'                                                       'symbol'
assert sym_ctorfn   'console.log(typeof Symbol)'                                                         'function'
assert sym_uniq     'console.log(Symbol()===Symbol(),Symbol("a")===Symbol("a"))'                        'false false'
assert sym_same     'var s=Symbol("x");console.log(s===s)'                                               'true'
assert sym_desc     'console.log(Symbol("hi").description)'                                              'hi'
assert sym_iter     'console.log(typeof Symbol.iterator)'                                                'symbol'
assert sym_iterwk   'console.log(Symbol.iterator===Symbol.iterator)'                                     'true'
assert sym_key      'var s=Symbol();var o={};o[s]=42;console.log(o[s])'                                  '42'
assert sym_key2     'var a=Symbol(),b=Symbol();var o={};o[a]=1;o[b]=2;console.log(o[a],o[b])'           '1 2'
assert sym_wkkey    'var o={};o[Symbol.iterator]=9;console.log(o[Symbol.iterator])'                     '9'

# ---- Array change-by-copy: toReversed / toSorted / with (original untouched) ----
assert acp_torev    'var a=[1,2,3];console.log(a.toReversed().join(","),a.join(","))'                    '3,2,1 1,2,3'
assert acp_tosort   'var a=[3,1,2];console.log(a.toSorted().join(","),a.join(","))'                      '1,2,3 3,1,2'
assert acp_sortcmp  'console.log([3,10,1].toSorted(function(x,y){return x-y}).join(","))'                '1,3,10'
assert acp_with     'var a=[1,2,3];console.log(a.with(1,9).join(","),a.join(","))'                       '1,9,3 1,2,3'
assert acp_withneg  'console.log([1,2,3].with(-1,9).join(","))'                                          '1,2,9'

# ---- RegExp `$<name>` named-group replacement ----
assert rng_swap     'console.log("2020-01".replace(/(?<y>\d+)-(?<m>\d+)/,"$<m>/$<y>"))'                  '01/2020'
assert rng_global   'console.log("HELLO".replace(/(?<a>L)/g,"[$<a>]"))'                                  'HE[L][L]O'
assert rng_unknown  'console.log("ab".replace(/(?<x>a)/,"[$<z>]"))'                                      '[]b'

if [ "$fail" -eq 0 ]; then
    echo "[js-es2022] RESULT: PASS"
    exit 0
else
    echo "[js-es2022] RESULT: FAIL"
    exit 1
fi
