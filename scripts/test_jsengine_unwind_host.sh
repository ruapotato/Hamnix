#!/usr/bin/env bash
# scripts/test_jsengine_unwind_host.sh — FAST, QEMU-free gate for CONTROL-FLOW
# UNWINDING in the native JS evaluator (lib/web/js/interp.ad), via the
# x86_64-linux host driver (user/js_host.ad).
#
# WHY THIS GATE EXISTS
# The evaluator carries one global completion state (`ctl` = NONE/RETURN/BREAK/
# CONTINUE/THROW plus throw_val/ctl_val). Every construct that "evaluate a
# sub-expression, then set the completion state" is a chance to CLOBBER a
# completion the sub-expression already raised, or to keep running statements /
# side effects while one is unwinding. That class of bug produces SILENT WRONG
# ANSWERS — the interpreter takes the wrong branch, mutates the wrong thing, or
# swallows an exception whole, and reports nothing. An audit of every `ctl`
# assignment site found seven live instances:
#
#   1. ND_RETURN   overwrote a CTL_THROW raised by the returned expression, so
#                  `try { return f() } catch(e){}` never entered the catch.
#   2. ND_THROW    did the same to the THROWN expression: `throw f()` where f()
#                  itself threw re-raised `undefined`.
#   3. exec_stmt   had NO in-flight-completion guard (eval_expr has always had
#                  the CTL_THROW half). Reached via a branch whose CONDITION
#                  threw — `if (t()) a; else break;` runs the else arm because
#                  to_bool(undefined) is false — a bare break/continue/return/
#                  throw overwrote the pending exception, and `else try{}catch{}`
#                  CAUGHT an outer, unrelated exception.
#   4. exec_for    ran the UPDATE expression after the body returned, so
#                  `for (i=0;i<10;i++) { return i }` left i === 1, not 0.
#   5. ND_DOWHILE  evaluated its CONDITION after the body returned, same shape.
#   6. eval_args_into reported the `undefined` placeholders left by a throwing
#                  argument, and the ~40 built-in method dispatchers then MUTATED
#                  with them: `a.push(thrower())` appended an undefined element.
#   7. assign_to   stored a value that never materialized: `s = s.concat(t())`
#                  overwrote `s` with undefined before the exception surfaced.
#
# The same audit found the evaluator re-walked assignment TARGETS instead of
# resolving base+key once, so `a[i++] += 10` bumped `i` twice and wrote the wrong
# element, and compound/update assignment read the old value AFTER the RHS
# instead of before (spec: Evaluate(LHS) -> GetValue -> Evaluate(RHS) -> Put).
#
# EVERY expectation below was produced by running the same one-liner through
# `node` (v20) and pasting its stdout — not from reading the spec. The
# `finally`-overrides-a-pending-completion cases are in here precisely because
# that override is CORRECT and must not be "fixed" away.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-unwind] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/js_host.ad -o "$BIN" 2>"$OUT/js_unwind_compile.log"; then
    echo "[js-unwind] FAIL: host driver did not compile"; cat "$OUT/js_unwind_compile.log"; exit 1
fi
echo "[js-unwind] PASS host driver compiled -> $BIN"

fail=0
ran=0
# assert <name> <js-that-console.logs-ONE-line> <expected-first-line-from-node>
assert() {
    local name="$1" js="$2" exp="$3"
    ran=$((ran + 1))
    echo "$js" > "$OUT/js_unwind_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_unwind_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-unwind] PASS $name"
    else
        echo "[js-unwind] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- 1. a throwing operand must not be clobbered by return/throw ------------
assert ret_throw_native  'function t(){throw new Error("E")}function f(){try{return t()}catch(e){return "caught:"+e.message}}console.log(f())' 'caught:E'
assert ret_throw_user    'function t(){throw "S"}function f(){try{return t()}catch(e){return "caught:"+e}}console.log(f())' 'caught:S'
assert throw_operand_obj 'function t(){throw new Error("inner")}try{throw t()}catch(e){console.log(typeof e, e.message)}' 'object inner'
assert throw_operand_str 'function t(){throw "inner"}try{throw t()}catch(e){console.log(e)}' 'inner'

# ---- 2. exec_stmt must not run a statement while a completion is unwinding --
# reached through the ELSE arm of a branch whose condition threw
assert else_break_clobber    'var log=[];function t(){throw "T"}try{for(var i=0;i<3;i++){if(t())log.push("y");else break;log.push(i)}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert else_continue_clobber 'var log=[];function t(){throw "T"}try{for(var i=0;i<2;i++){if(t())log.push("y");else continue;log.push(i)}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert else_return_clobber   'var log=[];function t(){throw "T"}function f(){if(t())return "y";else return "n"}try{log.push(f())}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert else_throw_clobber    'var log=[];function t(){throw "orig"}try{if(t())log.push("y");else throw "second"}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:orig'
assert else_try_swallow      'var log=[];function t(){throw "T"}try{if(t())log.push("y");else try{log.push("in")}catch(e){log.push("swallowed:"+e)}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert else_switch_noeval    'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{if(t())log.push("y");else switch(k(1)){case k(2):break}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert else_for_noeval       'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{if(t())log.push("y");else for(k(1);k(2)<0;k(3)){}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert else_destructure      'var log=[];function t(){throw new Error("orig")}try{if(t())log.push("y");else{var {q}=undefined}}catch(e){log.push("c:"+e.message)}console.log(log.join(","))' 'c:orig'

# ---- 3. loop headers must not run after the body completed abruptly ---------
assert for_update_after_return   'var i=0;function f(){for(i=0;i<10;i++){return i}}var r=f();console.log(r,i)' '0 0'
assert for_update_after_throw    'var i=0;function f(){for(i=0;i<10;i++){throw "x"}}try{f()}catch(e){}console.log(i)' '0'
assert for_update_nested_return  'var a=0,b=0;function f(){for(a=0;a<3;a++){for(b=0;b<3;b++){return "x"}}}console.log(f(),a,b)' 'x 0 0'
assert for_update_switch_return  'var i=0;function f(){for(i=0;i<3;i++){switch(i){case 0:return "z"}}}console.log(f(),i)' 'z 0'
assert for_update_try_return     'var i=0;function f(){for(i=0;i<5;i++){try{return "a"}finally{}}}console.log(f(),i)' 'a 0'
assert dowhile_cond_after_return 'var n=0;function f(){do{return "r"}while(n++<5)}var r=f();console.log(r,n)' 'r 0'
assert dowhile_cond_after_throw  'var n=0;function f(){do{throw "x"}while(n++<5)}try{f()}catch(e){}console.log(n)' '0'
assert dowhile_labeled_return    'var n=0;function f(){L:do{return "r"}while(n++<3)}console.log(f(),n)' 'r 0'
# ...and the header MUST still run on the normal paths
assert while_cond_runs_first     'var n=0;function f(){while(n++<5){return "r"}}var r=f();console.log(r,n)' 'r 1'
assert dowhile_continue_cond     'var n=0,c=0;do{c++;if(c<3)continue}while(n++<5);console.log(c,n)' '6 6'
assert for_update_break_inner    'var i=0,j=0;for(i=0;i<3;i++){for(j=0;j<3;j++){break}}console.log(i,j)' '3 0'
assert for_labeled_continue      'var i=0;out:for(i=0;i<3;i++){for(var j=0;j<3;j++){continue out}}console.log(i)' '3'
assert label_continue_nested     'var log=[];out:for(var i=0;i<3;i++){for(var j=0;j<3;j++){if(j===1)continue out;log.push(i+":"+j)}}console.log(log.join(","))' '0:0,1:0,2:0'
assert label_break_nested        'var log=[];out:for(var i=0;i<3;i++){for(var j=0;j<3;j++){if(i===1)break out;log.push(i+":"+j)}}console.log(log.join(","))' '0:0,0:1,0:2'
assert label_block_break         'var log=[];L:{log.push(1);break L;log.push(2)}log.push(3);console.log(log.join(","))' '1,3'

# ---- 4. discriminants / iterables / headers that throw ---------------------
assert switch_disc_throws  'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{switch(t()){case k(1):log.push("b1");break;case k(2):break}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert switch_case_throws  'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{switch(9){case t():break;case k(2):break}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert forof_iter_throws   'var log=[];function t(){throw "T"}try{for(const x of t()){log.push(x)}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert forin_obj_throws    'var log=[];function t(){throw "T"}try{for(const k in t()){log.push(k)}}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert getter_throws_in_if 'function mk(){return {get p(){throw new Error("G")}}}var log=[];try{if(mk().p){log.push("t")}else{log.push("f")}}catch(e){log.push("c:"+e.message)}console.log(log.join(","))' 'c:G'

# ---- 5. declarations, arguments and operands that throw --------------------
assert var_second_decl     'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{var a=t(),b=k(2)}catch(e){log.push("c:"+e)}console.log(log.join(","))' 'c:T'
assert var_hoisted_binding 'function t(){throw "T"}try{var a=t()}catch(e){}console.log(typeof a, a)' 'undefined undefined'
assert destr_keeps_error   'function t(){throw new Error("orig")}try{let {x}=t()}catch(e){console.log(e.message)}' 'orig'
assert destr_arr_keeps_err 'function t(){throw new Error("orig")}try{let [x]=t()}catch(e){console.log(e.message)}' 'orig'
assert args_stop           'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}function f(){}try{f(t(),k(2))}catch(e){log.push("c")}console.log(log.join(","))' 'c'
assert new_args_stop       'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}function C(){log.push("ctor")}try{new C(t(),k(2))}catch(e){log.push("c")}console.log(log.join(","))' 'c'
assert tmpl_stop           'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{var s=`${t()}${k(1)}`}catch(e){log.push("c")}console.log(log.join(","))' 'c'
assert seq_stop            'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{(t(),k(1))}catch(e){log.push("c")}console.log(log.join(","))' 'c'
assert objlit_stop         'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{var o={a:t(),b:k(1)}}catch(e){log.push("c")}console.log(log.join(","))' 'c'
assert arrlit_stop         'var log=[];function t(){throw "T"}function k(v){log.push(v);return v}try{var a=[t(),k(1)]}catch(e){log.push("c")}console.log(log.join(","))' 'c'
assert binop_keeps_error   'function t(){throw new Error("orig")}try{var x=t()*2}catch(e){console.log(e.message)}' 'orig'
assert bigint_keeps_error  'function t(){throw new Error("orig")}try{var x=1n+t()}catch(e){console.log(e.message)}' 'orig'
assert typeof_throwing     'function t(){throw new Error("T")}try{console.log(typeof t())}catch(e){console.log("caught "+e.message)}' 'caught T'
assert delete_base_throws  'function t(){throw new Error("T")}try{delete t().x}catch(e){console.log("caught "+e.message)}' 'caught T'
assert delete_key_throws   'var o={};function t(){throw new Error("T")}try{delete o[t()]}catch(e){console.log("caught "+e.message)}' 'caught T'
assert void_throws         'function t(){throw new Error("T")}try{void t()}catch(e){console.log("caught "+e.message)}' 'caught T'
assert classfield_throws   'function t(){throw new Error("CF")}class C{x=t()}try{new C()}catch(e){console.log("caught "+e.message)}' 'caught CF'
assert await_throw         'async function t(){throw new Error("A")}async function f(){try{return await t()}catch(e){return "c:"+e.message}}f().then(v=>console.log(v))' 'c:A'
assert async_ret_throw     'async function t(){throw new Error("A")}async function f(){return await t()}f().catch(e=>console.log("c:"+e.message))' 'c:A'

# ---- 6. a throwing ARGUMENT must not reach a mutating built-in -------------
assert push_arg_throws     'var a=[1];function t(){throw "T"}try{a.push(t())}catch(e){}console.log(a.length,a.join("|"))' '1 1'
assert unshift_arg_throws  'var a=[1];function t(){throw "T"}try{a.unshift(t())}catch(e){}console.log(a.length)' '1'
assert splice_arg_throws   'var a=[1,2,3];function t(){throw "T"}try{a.splice(t(),1)}catch(e){}console.log(a.join(","))' '1,2,3'
assert fill_arg_throws     'var a=[1,2,3];function t(){throw "T"}try{a.fill(t())}catch(e){}console.log(a.join(","))' '1,2,3'
assert sort_arg_throws     'var a=[3,1,2];function t(){throw "T"}try{a.sort(t())}catch(e){}console.log(a.join(","))' '3,1,2'
assert map_set_arg_throws  'var m=new Map();function t(){throw "T"}try{m.set(t(),1)}catch(e){}console.log(m.size)' '0'
assert set_add_arg_throws  'var s=new Set();function t(){throw "T"}try{s.add(t())}catch(e){}console.log(s.size)' '0'
assert concat_arg_throws   'var s="a";function t(){throw "T"}try{s=s.concat(t())}catch(e){}console.log(s)' 'a'
assert replace_arg_throws  'function t(){throw "T"}var s="abc";try{s=s.replace("a",t())}catch(e){}console.log(s)' 'abc'
# ...and the same built-ins must still work normally
assert builtins_still_work 'console.log([1,2,3].map(x=>x*2).join(","), [1,2,3].filter(x=>x>1).join(","), [1,2,3].reduce((a,b)=>a+b,0))' '2,4,6 2,3 6'
assert builtins_more       'console.log([3,1,2].sort().join(","), [1,[2,[3]]].flat(2).join(","), [1,2,3].at(-1), [1,2,3].includes(2))' '1,2,3 1,2,3 3 true'
assert builtins_splice     'var a=[1,2,3,4];console.log(a.splice(1,2).join(","), a.join(","))' '2,3 1,4'
assert builtins_fill       'console.log([1,2,3].fill(0,1).join(","))' '1,0,0'
assert builtins_copywithin 'console.log([1,2,3,4,5].copyWithin(0,3).join(","))' '4,5,3,4,5'
assert builtins_findlast   'console.log([1,2,3,4].findLast(x=>x<3), [1,2,3,4].findLastIndex(x=>x<3))' '2 1'
assert builtins_strings    'console.log("a,b,c".split(",").join("|"), "abc".indexOf("b"), "ab".padStart(4,"-"))' 'a|b|c 1 --ab'
# a callback that throws mid-iteration stops the iteration where node stops it
assert foreach_cb_throws   'var log=[];try{[1,2,3].forEach(function(x){log.push(x);if(x===2)throw "T"})}catch(e){log.push("c")}console.log(log.join(","))' '1,2,c'
assert reduce_cb_throws    'var log=[];try{[1,2,3].reduce(function(a,x){log.push(x);if(x===2)throw "T";return a},0)}catch(e){log.push("c")}console.log(log.join(","))' '1,2,c'
assert replace_cb_throws   'var log=[];try{"aXbXc".replace(/X/g,function(m){log.push(m);throw "T"})}catch(e){log.push("c")}console.log(log.join(","))' 'X,c'

# ---- 7. a store whose value never materialized must not happen -------------
assert assign_not_stored   'var s="a";function t(){throw "T"}try{s=t()}catch(e){}console.log(s)' 'a'
assert member_not_stored   'var o={p:"keep"};function t(){throw "T"}try{o.p=t()}catch(e){}console.log(o.p)' 'keep'
assert compound_not_stored 'var n=5;function t(){throw "T"}try{n+=t()}catch(e){}console.log(n)' '5'
assert logical_not_stored  'var v=0;function t(){throw "T"}try{v||=t()}catch(e){}console.log(v)' '0'
assert destr_not_stored    'var a=1,b=2;function t(){throw "T"}try{[a,b]=t()}catch(e){}console.log(a,b)' '1 2'

# ---- 8. assignment targets evaluate ONCE, and BEFORE the right-hand side ----
assert idx_postinc_compound 'var a=[1,2,3],i=0;a[i++]+=10;console.log(a.join(","),i)' '11,2,3 1'
assert idx_postinc_update   'var a=[1,2,3],i=0;a[i++]++;console.log(a.join(","),i)' '2,2,3 1'
assert idx_postinc_assign   'var a=[1,2,3],i=0;a[i++]=99;console.log(a.join(","),i)' '99,2,3 1'
assert base_evaluated_once  'var n=0;var obj={x:1};function o(){n++;return obj}o().x+=5;console.log(n,obj.x)' '1 6'
assert key_evaluated_once   'var log=[];var obj={a:1};function kk(){log.push("k");return "a"}obj[kk()]+=1;console.log(log.length,obj.a)' '1 2'
assert key_once_update      'var log=[];var obj={a:1};function kk(){log.push("k");return "a"}obj[kk()]++;console.log(log.length,obj.a)' '1 2'
# KNOWN DIVERGENCE, pinned deliberately (see the comment in eval_assign): for a
# PLAIN `=` we evaluate the RHS before the target reference, where node evaluates
# the target first — node prints 'o,r' and 'k,r' for these two. Spec order was
# implemented and then reverted because it makes tests/fixtures/realsites/
# google_search.html (scripts/test_hambrowse_realsite_host.sh) run >45 min
# instead of <1 s: its obfuscated bot-detection VM gets much further and never
# finishes. These two cases pin OUR order so the divergence cannot drift
# unnoticed; flip them back the day that page's slowness is understood.
assert divergence_member_assign 'var log=[];function o(){log.push("o");return {}}function r(){log.push("r");return 1}o().x=r();console.log(log.join(","))' 'r,o'
assert divergence_index_assign  'var log=[];var obj={};function kk(){log.push("k");return "a"}function r(){log.push("r");return 1}obj[kk()]=r();console.log(log.join(","))' 'r,k'
assert order_compound       'var log=[];var obj={a:1};function kk(){log.push("k");return "a"}function r(){log.push("r");return 1}obj[kk()]+=r();console.log(log.join(","))' 'k,r'
assert order_logical_assign 'var log=[];var obj={a:0};function kk(){log.push("k");return "a"}function r(){log.push("r");return 5}obj[kk()]||=r();console.log(log.join(","),obj.a)' 'k,r 5'
assert order_getvalue_first 'var log=[];var o={get p(){log.push("get");return 1},set p(v){log.push("set"+v)}};function r(){log.push("r");return 2}o.p+=r();console.log(log.join(","))' 'get,r,set3'
assert order_plain_no_get   'var log=[];var o={get p(){log.push("get");return 1},set p(v){log.push("set"+v)}};function r(){log.push("r");return 2}o.p=r();console.log(log.join(","))' 'r,set2'
assert order_update_getset  'var log=[];var o={get p(){log.push("get");return 1},set p(v){log.push("set"+v)}};o.p++;console.log(log.join(","))' 'get,set2'
# the same divergence can change a stored VALUE, not just side-effect order:
# node resolves a[i++] (index 0) before reading a[i] (index 1) and stores 2;
# evaluating the RHS first reads index 0 and stores 1. node prints '2,2,3 1'.
assert divergence_idx_value 'var a=[1,2,3],i=0;a[i++]=a[i];console.log(a.join(","),i)' '1,2,3 1'
# the COMPOUND form of the same shape IS spec-ordered (target resolved first)
assert compound_idx_value   'var a=[1,2,3],i=0;a[i++]+=a[i];console.log(a.join(","),i)' '3,2,3 1'
# same divergence, nested: node prints 'ka,kb'
assert divergence_nested    'var log=[];var a={},b={};function ka(){log.push("ka");return "x"}function kb(){log.push("kb");return "y"}a[ka()]=b[kb()]=7;console.log(log.join(","),a.x,b.y)' 'kb,ka 7 7'
assert setter_after_rhs     'var log=[];var o={set p(v){log.push("set"+v)}};function r(){log.push("r");return 1}o.p=r();console.log(log.join(","))' 'r,set1'

# ---- 9. `finally` OVERRIDING a pending completion is CORRECT (do not "fix") -
assert finally_return_over_return 'function f(){try{return 1}finally{return 2}}console.log(f())' '2'
assert finally_return_over_throw  'function f(){try{throw new Error("a")}finally{return 2}}console.log(f())' '2'
assert finally_throw_over_return  'function f(){try{return 1}finally{throw new Error("F")}}try{f()}catch(e){console.log(e.message)}' 'F'
assert finally_break_over_throw   'for(var i=0;i<3;i++){try{throw "x"}finally{break}}console.log("done"+i)' 'done0'
assert finally_normal_keeps_throw 'function f(){try{throw new Error("keep")}finally{var z=1}}try{f()}catch(e){console.log(e.message)}' 'keep'
assert finally_after_catch        'function f(){try{throw 1}catch(e){return "c"}finally{}}console.log(f())' 'c'
assert finally_continue_in_loop   'var log=[];for(var i=0;i<2;i++){try{continue}finally{log.push("f"+i)}}console.log(log.join(","))' 'f0,f1'
assert return_in_try_in_loop      'function f(){for(var i=0;i<3;i++){try{return i}finally{}}}console.log(f())' '0'

# ---- 10. ordinary completions still work end to end ------------------------
assert switch_body_return  'function f(){switch(1){case 1:return "a"}return "b"}console.log(f())' 'a'
assert forof_body_return   'var log=[];function f(){for(const x of [1,2,3]){log.push(x);return x}}var r=f();console.log(r,log.join(","))' '1 1'
assert forin_body_return   'var log=[];function f(){for(const k in {a:1,b:2}){log.push(k);return k}}var r=f();console.log(r,log.join(","))' 'a a'
assert nested_fn_return    'function g(){return 5}function f(){var x=g();return x+1}console.log(f())' '6'
assert gen_return_in_for   'function* g(){for(var i=0;i<5;i++){if(i===2)return;yield i}}console.log([...g()].join(","))' '0,1'
assert gen_next_after_ret  'function* g(){for(var i=0;i<3;i++){yield i}return 9}var it=g();console.log(it.next().value,it.next().value,it.next().value,it.next().value)' '0 1 2 9'
assert setter_throws       'var log=[];var o={set p(v){throw new Error("S")}};try{o.p=1;log.push("no")}catch(e){log.push("c:"+e.message)}console.log(log.join(","))' 'c:S'
assert update_getter_throws 'var log=[];var o={get p(){throw new Error("U")},set p(v){}};try{o.p++}catch(e){log.push("c:"+e.message)}console.log(log.join(","))' 'c:U'
assert json_getter_throws  'try{JSON.stringify({get a(){throw new Error("J")}})}catch(e){console.log(e.message)}' 'J'

# a gate that asserted nothing would be worthless: prove we actually ran cases
if [ "$ran" -lt 90 ]; then
    echo "[js-unwind] FAIL: only $ran assertions ran (expected >= 90)"; exit 1
fi
echo "[js-unwind] $ran assertions executed"

if [ "$fail" -eq 0 ]; then
    echo "[js-unwind] ALL PASS"
else
    echo "[js-unwind] SOME FAILED"
fi
exit "$fail"
