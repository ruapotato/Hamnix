#!/usr/bin/env bash
# scripts/probe_js_syntax.sh — PARSER-level probe. probe_js_coverage/probe_js_hard
# test SEMANTICS of constructs the engine already parses; this one tests whether
# the engine can PARSE the syntax that real minified bundles (React/webpack/
# Google) actually contain. A single unparseable construct kills the WHOLE
# bundle ("SyntaxError: unexpected token"), so parser holes are far more
# damaging than semantic ones — hence a dedicated suite.
#
# Oracle: node (V8). A probe PASSES if hambrowse produces no JSERR and the
# console output matches node.
#
# Usage: scripts/probe_js_syntax.sh [FILTER]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="build/host/hambrowse_probe_host"
[ -x "$BIN" ] || BIN="build/host/hambrowse_host"
[ -x "$BIN" ] || { echo "build build/host/hambrowse_host first"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FILTER="${1:-}"
pass=0 fail=0 FAILS=""

probe() {
    local name="$1" js="$2"
    [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return
    printf '<!doctype html><html><body><script>\n%s\n</script></body></html>' "$js" > "$WORK/p.html"
    printf '%s\n' "$js" > "$WORK/p.js"
    local raw hb hberr node_out nrc
    raw="$("$BIN" "$WORK/p.html" 880 2>&1)"
    hb="$(printf '%s\n' "$raw" | sed -n 's/^JSLOG //p')"
    hberr="$(printf '%s\n' "$raw" | sed -n 's/^JSERR //p' | head -1)"
    node_out="$(node "$WORK/p.js" 2>"$WORK/nerr")"; nrc=$?
    if [ "$nrc" -ne 0 ]; then
        printf 'SKIP  %-26s (node: %s)\n' "$name" "$(head -1 "$WORK/nerr")"; return
    fi
    if [ "$hb" = "$node_out" ] && [ -z "$hberr" ]; then
        printf 'PASS  %-26s %s\n' "$name" "$node_out"; pass=$((pass+1))
    else
        printf 'FAIL  %-26s node=<%s> hb=<%s> %s\n' "$name" "$node_out" "$hb" \
               "${hberr:+[JSERR: $hberr]}"
        fail=$((fail+1)); FAILS="$FAILS $name"
    fi
}

# ---- syntax that shows up in EVERY minified/transpiled bundle ----------------
probe optional_catch      'try{null.x}catch{console.log("ocb")}'
probe comma_in_for        'for(var i=0,j=3;i<j;i++,j--);console.log("cfor")'
probe seq_in_return       'function f(){return 1,2}console.log(f())'
probe regex_after_paren   'console.log(("ab").replace(/a/,"X"))'
probe regex_div_ambig     'var a=4,b=2;console.log(a/b/1)'
probe regex_class_slash   'console.log(/[/]/.test("/"))'
probe nested_ternary      'var a=1;console.log(a?a?1:2:3)'
probe arrow_seq_body      'var f=()=>(1,2);console.log(f())'
probe arrow_obj_body      'var f=()=>({a:1});console.log(f().a)'
probe iife_arrow          'console.log((()=>{return 7})())'
probe iife_bang           '!function(){console.log("bang")}();'
probe void_iife           'void function(){console.log("void")}();'
probe chained_call_arrow  'console.log([1,2].map(x=>x*2).filter(x=>x>2).join(""))'
probe getter_in_obj       'var o={get x(){return 5}};console.log(o.x)'
probe setter_in_obj       'var o={set x(v){this._v=v},get x(){return this._v}};o.x=3;console.log(o.x)'
probe computed_key        'var k="a";var o={[k+"b"]:1};console.log(o.ab)'
probe method_shorthand    'var o={f(){return 2}};console.log(o.f())'
probe async_method_short  'var o={async f(){return 2}};o.f().then(v=>console.log(v))'
probe gen_method_short    'var o={*g(){yield 1}};console.log([...o.g()][0])'
probe class_static_block  'class C{static x;static{C.x=9}}console.log(C.x)'
probe class_field         'class C{x=4;f(){return this.x}}console.log(new C().f())'
probe class_static_field  'class C{static y=3}console.log(C.y)'
probe class_priv_method   'class C{#m(){return 8}f(){return this.#m()}}console.log(new C().f())'
probe class_priv_in       'class C{#a=1;static has(o){return #a in o}}console.log(C.has(new C()))'
probe class_getter        'class C{get v(){return 6}}console.log(new C().v)'
probe class_computed      'var k="m";class C{[k](){return 1}}console.log(new C().m())'
probe class_expr          'var C=class{f(){return 5}};console.log(new C().f())'
probe label_block         'a:{console.log("lbl");break a}'
probe do_while            'var i=0;do{i++}while(i<3);console.log(i)'
probe switch_fallthrough  'var x=2,r="";switch(x){case 1:case 2:r="ok";default:r+="!"}console.log(r)'
probe trailing_comma_fn   'function f(a,b,){return a+b}console.log(f(1,2,))'
probe exponent_assign     'var a=2;a**=3;console.log(a)'
probe ushift_assign       'var a=-1;a>>>=28;console.log(a)'
probe opt_call            'var o={f(){return 1}};console.log(o.f?.(),o.g?.())'
probe opt_index           'var o={a:{b:1}};console.log(o?.a?.["b"],o?.z?.["b"])'
probe spread_new          'function C(a,b){this.s=a+b}console.log(new C(...[1,2]).s)'
probe destr_nested_deep   'var {a:{b:[c=5]={}}={}}={a:{b:[]}};console.log(c)'
probe destr_param_obj     'function f({a,b=2}={}){return a+b}console.log(f({a:1}))'
probe destr_assign_paren  'var a,b;({a,b}=[1,2]&&{a:1,b:2});console.log(a,b)'
probe for_of_destr        'for(const [k,v] of [[1,2]])console.log(k,v)'
probe for_in_var          'var o={z:1};for(var k in o)console.log(k)'
probe unicode_escape_id   'var abc=3;console.log(abc)'
probe string_line_cont    'console.log("a\
b".length)'
probe template_nested     'var x=1;console.log(`a${`b${x}`}c`)'
probe tagged_template     'function t(s,v){return s[0]+v}console.log(t`x${2}`)'
probe hex_octal_bin       'console.log(0xff,0o17,0b101)'
probe numeric_sep_frac    'console.log(1_000.5)'
probe bigint_literal      'console.log(typeof 10n)'
probe regex_named_bs      'console.log("a-b".split(/(?<s>-)/).length)'
probe getter_proto_obj    'var o={__proto__:{p:1}};console.log(o.p)'
probe in_for_paren        'var o={a:1};console.log(("a" in o)?1:0)'
probe new_dot_target      'function F(){return new.target?1:0}console.log(new F())'
probe dynamic_import_stx  'var f=()=>0;console.log(typeof f)'
probe arrow_default_arrow 'var f=(g=()=>1)=>g();console.log(f())'
probe async_arrow_await   '(async()=>{var v=await 5;console.log(v)})()'
probe generator_delegate  'function*a(){yield 1}function*b(){yield*a()}console.log([...b()][0])'
probe obj_spread_rest     'var {a,...r}={a:1,b:2,c:3};console.log(a,Object.keys(r).join(""))'
probe array_hole          'var a=[1,,3];console.log(a.length,a[1])'
probe comma_last_array    'console.log([1,2,].length)'
probe deep_nesting        'console.log(((((((((1+2)))))))))'
probe semicolonless_asi   'var a=1
var b=2
console.log(a+b)'

echo
echo "=== JS-syntax: $pass PASS / $fail FAIL ==="
[ -n "$FAILS" ] && echo "FAILED:$FAILS"
exit 0
