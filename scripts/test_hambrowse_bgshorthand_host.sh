#!/usr/bin/env bash
# scripts/test_hambrowse_bgshorthand_host.sh — FAST, QEMU-free gate for the
# `background:` SHORTHAND colour extraction in the native browser cascade
# (lib/web/css/cascade.ad). Before this the shorthand only parsed a colour at
# the FIRST token, so `background: no-repeat #333` / `background: center/cover
# #333` (colour last, after keywords or a '/') rendered with NO fill. Real CSS
# routinely orders the colour last, so a regression must fail here with no QEMU
# boot. _bg_shorthand_color now scans every space/'/'-separated token for the
# first that parses as a colour (named / #hex / rgb()/hsl() with internal
# spaces), while `background: none` still yields no fill.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_bgshorthand.html"
mkdir -p "$OUT"

echo "[hb-bgsh] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/bgsh_compile.log"; then
    echo "[hb-bgsh] FAIL: host harness did not compile"; cat "$OUT/bgsh_compile.log"; exit 1
fi
echo "[hb-bgsh] PASS host harness compiled -> $BIN"

echo "[hb-bgsh] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/bgsh_native.log"; then
    echo "[hb-bgsh] FAIL: native hambrowse did not compile"; cat "$OUT/bgsh_native.log"; exit 1
fi
echo "[hb-bgsh] PASS native hambrowse still compiles"

fail=0
D0="$OUT/bgsh_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-bgsh] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E '^FILL|^SEG' "$D0" || true

seg_line() { grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | head -1; }
assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-bgsh] PASS $2"
    else
        echo "[hb-bgsh] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_seg() {    # text  regex  message
    local ln; ln="$(seg_line "$1")"
    if [ -z "$ln" ]; then
        echo "[hb-bgsh] FAIL $3 (no segment for |$1|)"; fail=1; return
    fi
    if echo "$ln" | grep -Eq -- "$2"; then
        echo "[hb-bgsh] PASS $3"
    else
        echo "[hb-bgsh] FAIL $3 (seg: $ln)"; fail=1
    fi
}

assert_grep 'FILL 0 1 8 800 #ffcc00'  "colour as the FIRST token still works"
assert_grep 'FILL 1 2 8 800 #33cc99'  "colour as the LAST token (after no-repeat)"
assert_grep 'FILL 2 3 8 800 #cc3366'  "colour after a '/' (position/size shorthand)"
assert_grep 'FILL 3 4 8 800 #ff0000'  "colour first with a url() present"
assert_grep 'FILL 4 5 8 800 #4682b4'  "NAMED colour after a repeat keyword (steelblue)"
assert_grep 'FILL 5 6 8 800 #0a78c8' "rgb() colour mid-shorthand (internal spaces)"
# `background: none` must NOT fabricate a fill.
assert_seg "background none no fill" 'bg- ' "background: none yields no fill"
if grep -Eq '^FILL 12 ' "$D0"; then
    echo "[hb-bgsh] FAIL background: none emitted a FILL"; fail=1
else
    echo "[hb-bgsh] PASS background: none emitted no FILL row"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-bgsh] RESULT: FAIL"; exit 1
fi
echo "[hb-bgsh] RESULT: PASS"
