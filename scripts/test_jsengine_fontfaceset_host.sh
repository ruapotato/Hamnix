#!/usr/bin/env bash
# scripts/test_jsengine_fontfaceset_host.sh — FAST, QEMU-free gate for the DOM
# CSS Font Loading API (`document.fonts` : FontFaceSet), via the x86_64-linux
# hambrowse host driver (user/hambrowse_host.ad). Unlike `performance` (a pure
# JS-engine global testable through js_host), `document.fonts` lives on the
# document object built in the DOM binding layer, so it is exercised through a
# real page load.
#
# WHY THIS MATTERS: real init code probes fonts during startup — e.g. google.com
# runs `document.fonts.load(c+" 10pt "+b, "<emoji>")` in an emoji-font detection
# loop. With `document.fonts` undefined this threw
# "cannot read property 'load' of null or undefined", aborting that script.
# Headless has every font available synchronously, so load()/ready resolve
# immediately and check() is always true.
#
# Asserts the spec surface directly against a hand-built fixture (no oracle):
# document.fonts is an object; check() -> true; load() returns a Promise that
# fulfills with a (FontFace) array; `.ready` is a Promise that resolves; the
# no-op mutators are callable; and — the whole point — the page load produces NO
# uncaught JS error.
#
# Builds with the frozen Python seed compiler for BOTH the host harness
# (x86_64-linux) and the native browser (x86_64-adder-user).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[js-fonts] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/js_fonts_compile.log"; then
    echo "[js-fonts] FAIL: host harness did not compile"; cat "$OUT/js_fonts_compile.log"; exit 1
fi
echo "[js-fonts] PASS host harness compiled -> $BIN"

echo "[js-fonts] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/js_fonts_native.log"; then
    echo "[js-fonts] FAIL: native hambrowse did not compile"; cat "$OUT/js_fonts_native.log"; exit 1
fi
echo "[js-fonts] PASS native hambrowse still compiles"

FIX="$OUT/js_fonts_fixture.html"
cat > "$FIX" <<'HTML'
<!doctype html><html><head><title>Fonts</title></head><body>
<script>
console.log("FONTS type="+(typeof document.fonts));
console.log("FONTS check="+document.fonts.check("10pt Arial"));
console.log("FONTS status="+document.fonts.status);
var p=document.fonts.load("10pt Arial","hi");
console.log("FONTS load-promise="+(typeof p.then==="function"));
p.then(function(r){ console.log("FONTS loaded arr="+Array.isArray(r)); });
document.fonts.ready.then(function(){ console.log("FONTS ready-resolved"); });
console.log("FONTS forEach="+document.fonts.forEach(function(){}));
console.log("FONTS add="+document.fonts.add({}));
// the exact google emoji-probe shape must not throw:
document.fonts.load("Noto Color Emoji"+" 10pt sans","🇺");
console.log("FONTS DONE");
</script>
</body></html>
HTML

D0="$OUT/js_fonts_out.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1

fail=0
assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then echo "[js-fonts] PASS $2"
    else echo "[js-fonts] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then echo "[js-fonts] FAIL $2 (present: $1)"; fail=1
    else echo "[js-fonts] PASS $2"; fi
}

assert_grep '^JSLOG FONTS type=object$'        "document.fonts is an object (FontFaceSet)"
assert_grep '^JSLOG FONTS check=true$'         "check() reports the font available"
assert_grep '^JSLOG FONTS status=loaded$'      ".status is 'loaded'"
assert_grep '^JSLOG FONTS load-promise=true$'  "load() returns a Promise (thenable)"
assert_grep '^JSLOG FONTS loaded arr=true$'    "load() fulfills with a (FontFace) array"
assert_grep '^JSLOG FONTS ready-resolved$'     ".ready is a Promise that resolves"
assert_grep '^JSLOG FONTS forEach=undefined$'  "forEach() is a callable no-op"
assert_grep '^JSLOG FONTS add=undefined$'      "add() is a callable no-op"
assert_grep '^JSLOG FONTS DONE$'               "the google emoji-probe shape ran without throwing"
assert_nogrep '^JSERR'                         "no uncaught JS error on the page"
assert_nogrep "cannot read property.*load"     "no 'cannot read property load of null' (the pre-fix bug)"

if [ "$fail" -eq 0 ]; then
    echo "[js-fonts] RESULT: PASS"; exit 0
else
    echo "[js-fonts] RESULT: FAIL"; exit 1
fi
