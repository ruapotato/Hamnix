#!/usr/bin/env bash
# scripts/test_hambrowse_realsite_host.sh — FAST, QEMU-free gate that runs the
# ACTUAL bytes real sites serve (captured under tests/fixtures/realsites/) through
# the native browser engine (lib/htmlengine.ad + lib/jsengine.ad).
#
# WHY: prior browser rounds were verified against hand-written synthetic
# fixtures. A user drove the shipped browser to google.com, typed a query, hit
# search, and got a "JS error (see script)" — because the REAL page exercises JS
# constructs / DOM APIs the synthetic fixtures never did (eval, navigator, giant
# machine-generated inline scripts, etc.). This gate locks in real-site compat:
#
#   (a) the engine never crashes on real HTML (a huge eval'd google script used
#       to segfault by overrunning the token/AST arenas),
#   (b) `eval` and `navigator` are defined (real sites feature-detect on them;
#       a missing global is a ReferenceError that aborts the whole script),
#   (c) real google.com's search box renders as a FIELD (shaded surface) and the
#       native type+submit chain navigates to /search?...q=..., i.e. the exact
#       flow the user exercises, and
#   (d) common sites (example.com, wikipedia) render real content.
#
# Deterministic: it runs the CAPTURED HTML, never the live network.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FX="tests/fixtures/realsites"
mkdir -p "$OUT"

echo "[hb-real] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/real_compile.log"; then
    echo "[hb-real] FAIL: host harness did not compile"; cat "$OUT/real_compile.log"; exit 1
fi
echo "[hb-real] PASS host harness compiled -> $BIN"

# The native hambrowse must also still compile (it shares the engine).
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/real_native.log"; then
    echo "[hb-real] FAIL: native hambrowse did not compile"; cat "$OUT/real_native.log"; exit 1
fi
echo "[hb-real] PASS native hambrowse still compiles"

fail=0
assert_grep()   { if grep -Eq -- "$1" "$2"; then echo "[hb-real] PASS $3"; else echo "[hb-real] FAIL $3 (missing: $1)"; fail=1; fi; }
assert_nogrep() { if grep -Eq -- "$1" "$2"; then echo "[hb-real] FAIL $3 (present: $1)"; else echo "[hb-real] PASS $3"; fi; }

run_ok() {  # fixture width [extra args...] -> writes $OUT/real_<name>.txt, asserts rc==0
    local name="$1"; shift
    local page="$1"; shift
    "$BIN" "$page" "$@" >"$OUT/real_${name}.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[hb-real] PASS ${name}: engine ran without crashing (rc=0)"
    else
        echo "[hb-real] FAIL ${name}: engine exited rc=$rc (crash/segfault on real HTML)"; fail=1
    fi
}

# ---- (a) no crash on any captured real page --------------------------------
run_ok google_home "$FX/google_home.html" 980
run_ok google_search "$FX/google_search.html" 980
run_ok example "$FX/example.html" 980
run_ok wikipedia "$FX/wikipedia_plan9.html" 980

# ---- (b) eval + navigator are defined (feature-detection globals) -----------
# A missing global surfaces as "X is not defined" in the JSLOG stream; these
# must NOT appear (they used to abort real scripts wholesale).
for n in google_home google_search wikipedia; do
    assert_nogrep 'navigator is not defined' "$OUT/real_${n}.txt" "${n}: navigator is defined (no ReferenceError)"
    assert_nogrep 'eval is not defined'      "$OUT/real_${n}.txt" "${n}: eval is defined (no ReferenceError)"
done

# Prove eval + navigator actually work (not just stubbed to silence the error).
cat > "$OUT/real_probe.html" <<'HTML'
<html><head><title>probe</title></head><body><p id="r">x</p><script>
var ok = (eval('40+2')===42) && (typeof navigator!=='undefined') &&
         navigator.userAgent.indexOf('Hamnix')>=0;
document.getElementById('r').textContent = ok ? 'PROBE-OK' : 'PROBE-BAD';
</script></body></html>
HTML
"$BIN" "$OUT/real_probe.html" 880 >"$OUT/real_probe.txt" 2>&1
assert_grep 'PROBE-OK'   "$OUT/real_probe.txt" "eval() computes and navigator.userAgent reads (real behaviour, not a stub)"
assert_nogrep 'PROBE-BAD' "$OUT/real_probe.txt" "eval/navigator probe did not fall to the BAD branch"

# ---- ES modules through the HTML path: <script type=module> --------------
# Modern sites' entry point is an ES module; an engine that cannot parse+link
# `import`/`export` blanks the page. A classic <script> and a module <script>
# coexist; the module has its OWN scope, imports a sibling module (resolved from
# the page's directory), and runs deferred. Assert BOTH ran and no JS error.
cat > "$OUT/real_esm_dep.js" <<'JS'
export default function(name){ return "hi " + name; }
export const K = 7;
JS
cat > "$OUT/real_esm.html" <<'HTML'
<html><head><title>esm</title></head><body><h1>ESM page</h1>
<script>console.log("MOD-CLASSIC");</script>
<script type="module">
import greet, { K } from "./real_esm_dep.js";
const label = ["a","b"].map(s => s.toUpperCase()).join("");
console.log("MOD-MODULE " + greet("x") + " K=" + K + " " + label);
</script>
</body></html>
HTML
"$BIN" "$OUT/real_esm.html" 880 >"$OUT/real_esm.txt" 2>&1
assert_grep 'MOD-CLASSIC'                  "$OUT/real_esm.txt" "classic <script> still runs alongside a module"
assert_grep 'MOD-MODULE hi x K=7 AB'       "$OUT/real_esm.txt" "<script type=module> links a sibling import (default+named) and runs"
assert_nogrep 'is not defined'             "$OUT/real_esm.txt" "module scope did not leak / error out"

# ---- (c) THE USER FLOW on REAL google.com HTML -----------------------------
# The real homepage identifies its query control by name="q" inside
# <form action="/search" name="f">. Render must classify it as a text field,
# resolve the form, and the native type+submit must navigate to /search?...q=...
GT="$OUT/real_google_fieldnav.txt"
"$BIN" "$FX/google_home.html" 980 fieldnav q "test" >"$GT" 2>&1
grep -E 'FIELDNAV' "$GT" || true
assert_grep '^FIELDNAV id=q idx=[0-9]+ textfield=1' "$GT" \
    "real google.com query box classifies as a text field"
assert_grep '^FIELDNAV form=[0-9]+' "$GT" \
    "real google.com query field resolves its enclosing <form action=/search>"
assert_grep '^FIELDNAV NAV /search\?.*q=test' "$GT" \
    "typing 'test' + submit navigates to /search?...q=test on REAL google HTML"

# The search box paints as a FIELD, not raw ASCII: its segment carries a
# non-empty background surface (seg_bg), i.e. it reads as an input box.
assert_grep '^SEG [0-9]+ [0-9]+ #[0-9a-f]+ b0 u0 s0 l-1 bg#[0-9a-f]+ \|\[_+\]\|' \
    "$OUT/real_google_home.txt" "the search field renders on a shaded field surface (looks like a box, not ASCII)"

# ---- (d) common sites render actual content --------------------------------
assert_grep 'Example Domain'        "$OUT/real_example.txt"   "example.com renders its heading text"
assert_grep 'Plan 9'                "$OUT/real_wikipedia.txt" "wikipedia article renders its real body text"

# ---- (e) a WIDER real-site corpus (r2): a modern dev site, a real app, and
# the first-ever website. Each must run without crashing and render content.
run_ok cern "$FX/cern_project.html" 980
run_ok hackernews "$FX/hackernews.html" 980
run_ok mdn "$FX/mdn_html.html" 980
assert_grep 'World Wide Web'  "$OUT/real_cern.txt"       "cern first-website renders its heading"
assert_grep 'Hacker News'     "$OUT/real_hackernews.txt" "news.ycombinator renders its masthead"
assert_grep 'HyperText Markup' "$OUT/real_mdn.txt"       "MDN article renders its real title"

# MDN's very first inline <script> reads localStorage un-guarded to set the
# colour theme; before r2 that was a ReferenceError that ABORTED the whole
# script (JSERR). localStorage is now an in-memory Web Storage global.
assert_nogrep 'localStorage is not defined' "$OUT/real_mdn.txt" "MDN: localStorage is defined (no ReferenceError)"
assert_nogrep 'sessionStorage is not defined' "$OUT/real_mdn.txt" "MDN: sessionStorage is defined"

# ---- (f) REGEX: lookahead / lookbehind / named groups / \k backref ----------
# Real site scripts use these constantly; before r2 any such regex literal threw
# an UN-catchable "unsupported regex group" SyntaxError that aborted the script.
cat > "$OUT/real_rx.html" <<'HTML'
<html><head><title>rx</title></head><body><p id="r">x</p><script>
var o=[];
o.push(/foo(?=bar)/.test('foobar')===true && /foo(?=bar)/.test('foobaz')===false ? 'LA-OK':'LA-BAD');
o.push(/foo(?!bar)/.test('foobaz')===true && /foo(?!bar)/.test('foobar')===false ? 'NLA-OK':'NLA-BAD');
var m='2024-03-15'.match(/(?<y>\d{4})-(?<mo>\d{2})-(?<d>\d{2})/);
o.push(m && m.groups.y==='2024' && m.groups.mo==='03' && m.groups.d==='15' ? 'NAMED-OK':'NAMED-BAD');
o.push(/(?<=\$)\d+/.exec('price $42')[0]==='42' ? 'LB-OK':'LB-BAD');
o.push(/(?<q>\w)\k<q>/.test('mississippi')===true && /(?<q>\w)\k<q>/.test('abc')===false ? 'KREF-OK':'KREF-BAD');
document.getElementById('r').textContent = o.join(' ');
</script></body></html>
HTML
"$BIN" "$OUT/real_rx.html" 880 >"$OUT/real_rx.txt" 2>&1
assert_nogrep 'unsupported regex group' "$OUT/real_rx.txt" "regex lookaround/named no longer throws SyntaxError"
assert_grep 'LA-OK'    "$OUT/real_rx.txt" "positive lookahead (?=) matches"
assert_grep 'NLA-OK'   "$OUT/real_rx.txt" "negative lookahead (?!) matches"
assert_grep 'NAMED-OK' "$OUT/real_rx.txt" "named groups (?<name>..) populate .groups"
assert_grep 'LB-OK'    "$OUT/real_rx.txt" "positive lookbehind (?<=) matches"
assert_grep 'KREF-OK'  "$OUT/real_rx.txt" "named backreference \\k<name> matches"

# ---- (g) localStorage / sessionStorage in-memory Web Storage ----------------
cat > "$OUT/real_ls.html" <<'HTML'
<html><head><title>ls</title></head><body><p id="r">x</p><script>
var o=[];
o.push(localStorage.getItem('k')===null ? 'MISS-OK':'MISS-BAD');
localStorage.setItem('k','v1'); localStorage.setItem('k2','v2');
o.push(localStorage.getItem('k')==='v1' && localStorage.length===2 ? 'SET-OK':'SET-BAD');
localStorage.removeItem('k');
o.push(localStorage.getItem('k')===null && localStorage.length===1 ? 'RM-OK':'RM-BAD');
o.push(sessionStorage.getItem('k2')===null ? 'SEP-OK':'SEP-BAD');
document.getElementById('r').textContent = o.join(' ');
</script></body></html>
HTML
"$BIN" "$OUT/real_ls.html" 880 >"$OUT/real_ls.txt" 2>&1
assert_grep 'MISS-OK' "$OUT/real_ls.txt" "localStorage.getItem returns null for absent keys"
assert_grep 'SET-OK'  "$OUT/real_ls.txt" "localStorage set/get + length work"
assert_grep 'RM-OK'   "$OUT/real_ls.txt" "localStorage.removeItem updates store + length"
assert_grep 'SEP-OK'  "$OUT/real_ls.txt" "sessionStorage is a store separate from localStorage"

if [ "$fail" -ne 0 ]; then
    echo "[hb-real] RESULT: FAIL"; exit 1
fi
echo "[hb-real] RESULT: PASS"
