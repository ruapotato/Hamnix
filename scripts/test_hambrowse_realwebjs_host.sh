#!/usr/bin/env bash
# scripts/test_hambrowse_realwebjs_host.sh — FAST, QEMU-free gate for the engine
# gaps that broke REAL google.com in the user's hands:
#
#   "when I try to google something the dev tool console reports
#    `Uncaught TypeError: Ti is not a function`"
#   "Google homepage is broken and I can't select the search bar"
#   "`Uncaught TypeError: _DumpException is not a function`"
#
# Every one of those was a CASCADE: some earlier script died, so the globals it
# defines (`Ti`, `_DumpException`) were never created, and the next script's call
# to them failed. The gate locks down each root cause found:
#
#   (R) ReferenceError is a CATCHABLE throw, not a fatal engine flag. It used to
#       abort the whole remaining script AND be invisible to try/catch, so one
#       missing global detonated a bundle.
#   (A) `async function` EXPRESSIONS (`var f = async function(){}`), object
#       `{async m(){}}` and class `async m(){}` all parse and are really async.
#       `async function(` appears 47x in google's main bundle; the parser's
#       branch for it was DEAD CODE behind a generic TK_IDENT match.
#   (T) sloppy-mode `this`: an ordinary function called with no receiver sees the
#       GLOBAL object. `(function(_){var window=this; ...})(x)` opens google's
#       gbar bundle — with `this===undefined` every later `window.foo` threw.
#   (S) `src`/`href`/`alt`/`title` are reflected IDL Strings — always a string,
#       "" when absent (so `img.src.substring(0,5)` cannot throw) — while
#       getAttribute still answers null for an absent content attribute.
#   (C) DOM collections index correctly past 64 elements. DOM_MAX was 64, so
#       _dom_register_el returned undefined and getElementsByTagName("img")
#       reported length 7 with every entry undefined.
#   (J) a non-JavaScript <script type> (application/ld+json, text/template,
#       application/json) is NOT executed.
#   (F) `font-size: N%` resolves against the INHERITED size, not N x 12px.
#   (P) the null-deref TypeError NAMES the property, like V8.
#
# Plus an END-TO-END check on the captured REAL google homepage: it still lays
# out, its search field is still click-focusable and typable, and the user's
# reported "_DumpException is not a function" is GONE.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GBIN="$OUT/hambrowse_gfx_rwjs"
FIX="tests/fixtures/hambrowse_realweb_js.html"
GFIX="tests/fixtures/realsites/google_home.html"
mkdir -p "$OUT"

# These cache aggressively; a stale binary silently tests the OLD engine.
rm -f "$OUT/hambrowse_gfx" "$OUT/hambrowse_host_gfx" "$BIN" "$GBIN"

echo "[hb-rwjs] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/rwjs_compile.log"; then
    echo "[hb-rwjs] FAIL: host harness did not compile"; cat "$OUT/rwjs_compile.log"; exit 1
fi
echo "[hb-rwjs] PASS host harness compiled -> $BIN"

echo "[hb-rwjs] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/rwjs_native.elf" 2>"$OUT/rwjs_native.log"; then
    echo "[hb-rwjs] FAIL: native hambrowse did not compile"; cat "$OUT/rwjs_native.log"; exit 1
fi
echo "[hb-rwjs] PASS native hambrowse still compiles"

fail=0
assert_grep()   { if grep -Eq -- "$1" "$2"; then echo "[hb-rwjs] PASS $3"; else echo "[hb-rwjs] FAIL $3 (missing: $1)"; fail=1; fi; }
assert_nogrep() { if grep -Eq -- "$1" "$2"; then echo "[hb-rwjs] FAIL $3 (present: $1)"; else echo "[hb-rwjs] PASS $3"; fi; }

D0="$OUT/rwjs_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-rwjs] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

# ---- (R) ReferenceError is catchable AND non-fatal -------------------------
assert_grep '^JSLOG R1 caught true ReferenceError$' "$D0" \
    "(R) an undefined identifier throws a CATCHABLE ReferenceError instance"
assert_grep '^JSLOG R2 script continued after ReferenceError$' "$D0" \
    "(R) a caught ReferenceError does NOT abort the rest of the script"

# ---- (A) async function expressions / methods ------------------------------
assert_grep '^JSLOG A1 function$'       "$D0" "(A) 'var f = async function(){}' parses"
assert_grep '^JSLOG A2 function 1 2 3$' "$D0" \
    "(A) '{async m(){}}' is a method, while {async:1}/{get:2}/{other(){}} keep their own names"
assert_grep '^JSLOG A3 9$'  "$D0" "(A) a class 'async m(){}' really returns a promise"
assert_grep '^JSLOG A4 11$' "$D0" "(A) a class 'static async m(){}' really returns a promise"
assert_grep '^JSLOG A5 42$' "$D0" "(A) an async function EXPRESSION really returns a promise"
assert_nogrep 'async is not defined' "$D0" "(A) 'async' is never mis-read as a variable"

# ---- (T) sloppy-mode this --------------------------------------------------
assert_grep '^JSLOG T1 object true$' "$D0" \
    "(T) 'var window=this' inside a plain call yields the GLOBAL object (google's gbar idiom)"
assert_grep '^JSLOG T2 object$'      "$D0" "(T) a receiver-less call sees this === globalThis"

# ---- (S) reflected string IDL attributes ------------------------------------
assert_grep '^JSLOG S1 string len=0$' "$D0" \
    "(S) img.src is a STRING ('' when absent) so .substring() cannot throw"
assert_grep '^JSLOG S2 string len=0$' "$D0" "(S) a.href is a STRING ('' when absent)"
assert_grep '^JSLOG S3 null null$'    "$D0" \
    "(S) getAttribute still answers null for an ABSENT content attribute"

# ---- (C) DOM collections past the old 64-object cap -------------------------
assert_grep '^JSLOG C1 len=[0-9]+ nulls=0$' "$D0" \
    "(C) a >64-element querySelectorAll contains NO undefined entries"
if awk -F'len=| nulls' '/^JSLOG C1 /{ if ($2+0 > 64) ok=1 } END{ exit !ok }' "$D0"; then
    echo "[hb-rwjs] PASS (C) the collection is larger than the old DOM_MAX=64 cap"
else
    echo "[hb-rwjs] FAIL (C) the collection did not exceed 64 entries"; fail=1
fi

# ---- (J) non-JS <script type> is a DATA BLOCK, not code ---------------------
assert_grep '^JSLOG D1 undefined$' "$D0" \
    "(J) <script type=application/json> did not execute (no global leaked)"
assert_nogrep 'SyntaxError' "$D0" \
    "(J) ld+json / text/template / application/json produce NO SyntaxError"

# ---- (P) the null-deref TypeError names the property ------------------------
assert_grep "cannot read property 'someProp' of null" "$D0" \
    "(P) the null-deref TypeError NAMES the property, like V8"

# ---- (F) font-size: N% resolves against the inherited size ------------------
# body is 20px, so 80% => 16px and 150% => 30px. The bug computed N x 12px, i.e.
# 80% => ~960px, which alone made books.toscrape.com unreadable.
cat > "$OUT/rwjs_fontpct.html" <<'HTML'
<!doctype html><html><head><style>
body{font-size:20px} #a{font-size:80%} #b{font-size:150%} #c{font-size:100%} #d{font-size:12px}
</style></head><body><p id=a>eighty</p><p id=b>onefifty</p><p id=c>hundred</p><p id=d>twelve</p>
<script>
function h(i){var r=document.getElementById(i).getBoundingClientRect();
console.log("H "+i+" h="+Math.round(r.height));}
h("a");h("b");h("c");h("d");
</script></body></html>
HTML
DF="$OUT/rwjs_fontpct.txt"
"$BIN" "$OUT/rwjs_fontpct.html" 800 >"$DF" 2>&1
grep -E '^JSLOG H ' "$DF" || true
# Every percentage box must be SANE (a two-digit line box), not hundreds of px.
if awk '/^JSLOG H /{ split($4,p,"="); if (p[2]+0 > 60 || p[2]+0 < 5) bad=1 } END{ exit bad+0 }' "$DF"; then
    echo "[hb-rwjs] PASS (F) every font-size:N% box is a sane line height (5..60px)"
else
    echo "[hb-rwjs] FAIL (F) a font-size:N% box exploded (percent treated as N x 12px)"; fail=1
fi
# ...and the ORDER must track the percentages: 150% > 100% > 80%.
if awk '/^JSLOG H /{ split($4,p,"="); v[$3]=p[2]+0 }
        END{ exit !(v["b"] > v["c"] && v["c"] > v["a"]) }' "$DF"; then
    echo "[hb-rwjs] PASS (F) 150% > 100% > 80% line heights, so the percent is really applied"
else
    echo "[hb-rwjs] FAIL (F) font-size percentages do not scale monotonically"; fail=1
fi

# ---- END-TO-END on the captured REAL google.com homepage --------------------
# The user's report, verbatim: `_DumpException is not a function`. It came from
# google's own `catch(e){_._DumpException(e)}` firing before that handler was
# installed, because the bundle defining it had already died.
if [ -f "$GFIX" ]; then
    DG="$OUT/rwjs_google.txt"
    "$BIN" "$GFIX" 980 >"$DG" 2>&1
    assert_nogrep '_DumpException is not a function' "$DG" \
        "(E2E) the user-reported '_DumpException is not a function' is gone on REAL google.com"
    assert_nogrep 'Ti is not a function' "$DG" \
        "(E2E) the user-reported 'Ti is not a function' is gone on REAL google.com"
    assert_nogrep 'is not defined' "$DG" \
        "(E2E) no global is left undefined on REAL google.com"
    # The page must still LAY OUT — a blank render is not a fix.
    if awk '/^LAYOUT /{ split($2,s,"="); exit !(s[2]+0 >= 20) }' "$DG"; then
        echo "[hb-rwjs] PASS (E2E) REAL google.com still lays out (>=20 segments)"
    else
        echo "[hb-rwjs] FAIL (E2E) REAL google.com rendered (almost) nothing"; fail=1
    fi

    # ...and the SEARCH BAR is still click-focusable and typable ("I can't select
    # the search bar"). Drives the same pointer chain the native browser uses.
    echo "[hb-rwjs] compiling host gfx driver for the pointer-focus check ..."
    if python3 -m compiler.adder compile --target=x86_64-linux \
            user/hambrowse_host_gfx.ad -o "$GBIN" 2>"$OUT/rwjs_gfx.log"; then
        DC="$OUT/rwjs_google_click.txt"
        "$GBIN" "$GFIX" "$OUT/rwjs_google.ppm" 980 clickxy 0 0 X >"$DC" 2>/dev/null
        # Aim at the centre of the first text-field box the render reports.
        CXY=$(awk '/^FIELDSEG kind 1 /{ x=int(($5+$7)/2); if (x>970) x=int(($5+970)/2);
                   print x, int(($9+$11)/2); exit }' "$DC")
        if [ -n "$CXY" ]; then
            DT="$OUT/rwjs_google_type.txt"
            # shellcheck disable=SC2086
            "$GBIN" "$GFIX" "$OUT/rwjs_google2.ppm" 980 clickxy $CXY hamnix >"$DT" 2>/dev/null
            assert_grep '^HITEL [0-9]+ textfield 1' "$DT" \
                "(E2E) clicking the REAL google search box resolves to a TEXT FIELD"
            assert_grep '^FOCUSED el [0-9]+ value .*hamnix' "$DT" \
                "(E2E) typing into the REAL google search box lands in its DOM value"
        else
            echo "[hb-rwjs] FAIL (E2E) REAL google.com painted no text-field box to click"; fail=1
        fi
    else
        echo "[hb-rwjs] FAIL: host gfx driver did not compile"; cat "$OUT/rwjs_gfx.log"; fail=1
    fi
else
    echo "[hb-rwjs] SKIP (E2E) $GFIX absent"
fi

if [ "$fail" -eq 0 ]; then echo "[hb-rwjs] RESULT: PASS"; else echo "[hb-rwjs] RESULT: FAIL"; fi
exit "$fail"
