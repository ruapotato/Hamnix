#!/usr/bin/env bash
# scripts/test_jsengine_reindices_host.sh — FAST, QEMU-free gate for the RegExp
# `d` (hasIndices) flag (ES2022) in the JS engine (lib/web/js/setup.ad), via the
# x86_64-linux host driver (user/js_host.ad). Self-contained inline assertions
# against node semantics.
#
# THE GAP: the VM already tracked per-match capture start/end offsets (re_cap[]),
# but never exposed them — a match result had no `.indices`, and `d` in a flags
# string was ignored (no `hasIndices` reflection). The doc listed it deferred.
#
# THE FEATURE: `/re/d` now sets bit5 of obj_re_flags; js_make_regex reflects
# `hasIndices`; regex_result_array builds a parallel `.indices` array of
# [start,end) pairs per capture group (undefined for a non-participating group),
# plus `.indices.groups` (named-group pairs, or undefined when there are none) —
# ONLY when the `d` flag is present. Threaded through exec() AND matchAll().
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-reidx] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_reidx_compile.log"; then
    echo "[js-reidx] FAIL: host driver did not compile"; cat "$OUT/js_reidx_compile.log"; exit 1
fi
echo "[js-reidx] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_reidx_case.js"
    local got
    got="$("$BIN" "$OUT/js_reidx_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-reidx] PASS $name"
    else
        echo "[js-reidx] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- reflection ----
assert has_indices_on  'console.log(/a/d.hasIndices)'                                   'true'
assert has_indices_off 'console.log(/a/.hasIndices)'                                    'false'
assert flags_has_d     'console.log(/a/gd.flags.indexOf("d")>=0)'                        'true'

# ---- basic .indices ----
assert idx_basic       'console.log(JSON.stringify(/b/d.exec("abc").indices[0]))'       '[1,2]'
assert idx_start0      'console.log(JSON.stringify(/ab/d.exec("abc").indices[0]))'      '[0,2]'

# ---- capture-group indices ----
assert idx_groups      'var m=/(b)(c)/d.exec("abc");console.log(JSON.stringify(m.indices[0]),JSON.stringify(m.indices[1]),JSON.stringify(m.indices[2]))' '[1,3] [1,2] [2,3]'
assert idx_nonpart     'console.log(/(x)?b/d.exec("ab").indices[1])'                    'undefined'

# ---- named-group indices ----
assert idx_named       'console.log(JSON.stringify(/(?<mid>b)/d.exec("abc").indices.groups.mid))' '[1,2]'
assert idx_named2      'var m=/(?<y>\d+)-(?<mo>\d+)/d.exec("2026-07");console.log(JSON.stringify(m.indices.groups.y),JSON.stringify(m.indices.groups.mo))' '[0,4] [5,7]'
assert idx_groups_undef 'console.log(/b/d.exec("abc").indices.groups)'                  'undefined'

# ---- absence: no `.indices` without the flag ----
assert no_d_absent     'console.log(/b/.exec("abc").indices)'                           'undefined'

# ---- matchAll threads the flag ----
assert idx_matchall    'var a=[...("a1b2".matchAll(/(\d)/dg))];console.log(JSON.stringify(a[0].indices[1]),JSON.stringify(a[1].indices[1]))' '[1,2] [3,4]'

# ---- interaction with `i` (ignoreCase) + offset non-zero ----
assert idx_icase       'console.log(JSON.stringify(/XY/id.exec("...xy!").indices[0]))'  '[3,5]'

if [ "$fail" -ne 0 ]; then
    echo "[js-reidx] RESULT: FAIL"; exit 1
fi
echo "[js-reidx] RESULT: PASS"
