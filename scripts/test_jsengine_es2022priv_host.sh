#!/usr/bin/env bash
# scripts/test_jsengine_es2022priv_host.sh — FAST, QEMU-free gate for the JS
# engine's class private members + global-symbol-registry conformance batch
# (lib/web/js/*) via the x86_64-linux host driver (user/js_host.ad).
# Self-contained inline assertions against node semantics (no oracle file).
#
# Covered this round:
#   Language:  class private instance fields (#x = v), private methods (#m(){}),
#              private getters/setters (get #x(){}), private static fields/methods
#              (static #n = v), private-in brand check (#x in obj), the invariant
#              that private slots never surface to Object.keys / for-in /
#              JSON.stringify, and `static { }` initializer blocks (source-order,
#              `this`/class-name self-reference, private-static access).
#   Built-ins: Symbol.for(key) global registry (interning identity) and
#              Symbol.keyFor(sym) reverse lookup; symbol-keyed properties are also
#              (now) hidden from Object.keys / JSON.stringify.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-priv] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_priv_compile.log"; then
    echo "[js-priv] FAIL: host driver did not compile"; cat "$OUT/js_priv_compile.log"; exit 1
fi
echo "[js-priv] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_priv_case.js"
    local got
    got="$("$BIN" "$OUT/js_priv_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-priv] PASS $name"
    else
        echo "[js-priv] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- class private instance fields (#x = v) ----
assert pf_basic     'class C{#x=1;getX(){return this.#x}}console.log(new C().getX())'                    '1'
assert pf_init_expr 'class C{#x=2+3;g(){return this.#x}}console.log(new C().g())'                        '5'
assert pf_set       'class C{#x=1;set(v){this.#x=v}get(){return this.#x}}var c=new C();c.set(9);console.log(c.get())' '9'
assert pf_two       'class C{#a=1;#b=2;sum(){return this.#a+this.#b}}console.log(new C().sum())'         '3'
assert pf_perinst   'class C{#n=0;inc(){this.#n++;return this.#n}}var c=new C();c.inc();console.log(c.inc(),new C().inc())' '2 1'
assert pf_ctor      'class C{#x=1;constructor(v){this.#x=v}g(){return this.#x}}console.log(new C(7).g())' '7'

# ---- class private methods (#m(){}) ----
assert pm_basic     'class C{#inc(n){return n+1}run(){return this.#inc(41)}}console.log(new C().run())' '42'
assert pm_chain     'class C{#a(){return 2}#b(){return this.#a()*3}run(){return this.#b()}}console.log(new C().run())' '6'

# ---- private getters/setters ----
assert pg_getter    'class C{#x=7;get val(){return this.#x}}console.log(new C().val)'                    '7'
assert pg_privget   'class C{#x=5;get #d(){return this.#x*2}run(){return this.#d}}console.log(new C().run())' '10'

# ---- private static fields/methods ----
assert ps_field     'class C{static #n=5;static get(){return C.#n}}console.log(C.get())'                 '5'
assert ps_method    'class C{static #k(){return 8}static run(){return C.#k()}}console.log(C.run())'      '8'

# ---- private brand check (#x in obj) ----
assert pin_true     'class C{#x=1;static has(o){return #x in o}}console.log(C.has(new C()))'            'true'
assert pin_false    'class C{#x=1;static has(o){return #x in o}}console.log(C.has({}))'                 'false'
assert pin_prim     'class C{#x=1;static has(o){return #x in o}}console.log(C.has(5))'                  'false'

# ---- private slots never surface to enumeration/serialization ----
assert ph_keys      'class C{#x=1;a=2}console.log(JSON.stringify(Object.keys(new C())))'                '["a"]'
assert ph_json      'class C{#x=1;a=2}console.log(JSON.stringify(new C()))'                             '{"a":2}'
assert ph_forin     'class C{#x=1;a=2;b=3}var r="";for(var k in new C()){r+=k}console.log(r)'          'ab'

# ---- static initializer blocks (static { ... }) ----
assert sb_basic     'class C{static x;static {C.x=42}}console.log(C.x)'                                   '42'
assert sb_this      'class C{static {this.z=9}}console.log(C.z)'                                          '9'
assert sb_order     'class C{static a=1;static {C.b=C.a+1}}console.log(C.b)'                             '2'
assert sb_multi     'class C{static {this.a=1}static {this.b=this.a+1}}console.log(C.a,C.b)'            '1 2'
assert sb_priv      'class C{static #n=0;static {C.#n=7}static g(){return C.#n}}console.log(C.g())'      '7'
assert sb_selffld   'class C{static a=5;static b=C.a*2}console.log(C.b)'                                 '10'

# ---- Symbol.for / Symbol.keyFor (global symbol registry) ----
assert sf_identity  'console.log(Symbol.for("a")===Symbol.for("a"))'                                     'true'
assert sf_distinct  'console.log(Symbol.for("a")===Symbol.for("b"))'                                     'false'
assert sf_vs_plain  'console.log(Symbol.for("a")===Symbol("a"))'                                        'false'
assert sf_desc      'console.log(Symbol.for("z").description)'                                           'z'
assert sf_askey     'var s=Symbol.for("k");var o={};o[s]=5;console.log(o[Symbol.for("k")])'            '5'
assert kf_reg       'console.log(Symbol.keyFor(Symbol.for("hi")))'                                       'hi'
assert kf_unreg     'console.log(Symbol.keyFor(Symbol("x")))'                                            'undefined'

# ---- symbol-keyed properties also hidden from Object.keys / JSON.stringify ----
assert sh_keys      'var s=Symbol("k");var o={a:1};o[s]=2;console.log(JSON.stringify(Object.keys(o)))'  '["a"]'
assert sh_json      'var s=Symbol("k");var o={a:1};o[s]=2;console.log(JSON.stringify(o))'               '{"a":1}'

if [ "$fail" = 0 ]; then
    echo "[js-priv] RESULT: PASS"
    exit 0
else
    echo "[js-priv] RESULT: FAIL"
    exit 1
fi
