#!/usr/bin/env bash
# scripts/test_hambrowse_iface_host.sh — FAST, QEMU-free gate that DOM methods
# and reflected IDL attributes are OFF-INTERFACE where a browser says they are.
#
# WHY: `getContext`, `checkValidity`, `reportValidity`, `setCustomValidity` and
# `submit` lived on HTMLElement.prototype and therefore resolved TRUTHY on every
# element, and `src`/`href`/`alt` were reflected onto every element as strings.
# Real pages feature-detect with exactly these — `if (el.getContext)`,
# `if (el.checkValidity)`, `d.src.substring(0,5) !== "data:"` — so a
# truthy-everywhere surface silently takes the WRONG branch, with no error.
#
# EVERY LINE BELOW IS A MEASURED `chromium --headless --dump-dom` VALUE, taken
# from this exact fixture with the console lines routed into document.title.
# Note in particular that `title` IS "string" on a <div>: it is a global
# HTMLElement attribute, so it stays universal — the only one of the four that
# does. The last case proves a polyfill can still ASSIGN over an off-interface
# method, as it can in a browser.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_iface.html"
mkdir -p "$OUT"

echo "[hb-iface] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/iface_compile.log"; then
    echo "[hb-iface] FAIL: host harness did not compile"; cat "$OUT/iface_compile.log"; exit 1
fi
echo "[hb-iface] PASS host harness compiled -> $BIN"

echo "[hb-iface] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/iface_native.log"; then
    echo "[hb-iface] FAIL: native hambrowse did not compile"; cat "$OUT/iface_native.log"; exit 1
fi
echo "[hb-iface] PASS native hambrowse still compiles"

D0="$OUT/iface_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-iface] FAIL: render exited non-zero"; exit 1; }
grep -E 'JSLOG|JSERR' "$D0" || true

fail=0
assert_line() {
    if grep -Fqx -- "JSLOG $1" "$D0"; then echo "[hb-iface] PASS $2"
    else echo "[hb-iface] FAIL $2"; echo "    want: JSLOG $1"; fail=1; fi
}

assert_line "f cv=function rv=function scv=undefined sub=function gc=undefined src=undefined href=undefined alt=undefined title=string" \
            "<form> interface surface matches chromium"
assert_line "i cv=function rv=function scv=function sub=undefined gc=undefined src=string href=undefined alt=string title=string" \
            "<input> interface surface matches chromium"
assert_line "s cv=function rv=function scv=function sub=undefined gc=undefined src=undefined href=undefined alt=undefined title=string" \
            "<select> interface surface matches chromium"
assert_line "t cv=function rv=function scv=function sub=undefined gc=undefined src=undefined href=undefined alt=undefined title=string" \
            "<textarea> interface surface matches chromium"
assert_line "b cv=function rv=function scv=function sub=undefined gc=undefined src=undefined href=undefined alt=undefined title=string" \
            "<button> interface surface matches chromium"
assert_line "fs cv=function rv=function scv=function sub=undefined gc=undefined src=undefined href=undefined alt=undefined title=string" \
            "<fieldset> interface surface matches chromium"
assert_line "o cv=function rv=function scv=function sub=undefined gc=undefined src=undefined href=undefined alt=undefined title=string" \
            "<output> interface surface matches chromium"
assert_line "c cv=undefined rv=undefined scv=undefined sub=undefined gc=function src=undefined href=undefined alt=undefined title=string" \
            "<canvas> interface surface matches chromium"
assert_line "d cv=undefined rv=undefined scv=undefined sub=undefined gc=undefined src=undefined href=undefined alt=undefined title=string" \
            "<div> interface surface matches chromium"
assert_line "m cv=undefined rv=undefined scv=undefined sub=undefined gc=undefined src=string href=undefined alt=string title=string" \
            "<img> interface surface matches chromium"
assert_line "a cv=undefined rv=undefined scv=undefined sub=undefined gc=undefined src=undefined href=string alt=undefined title=string" \
            "<a> interface surface matches chromium"
assert_line "polyfill function 1" \
            "polyfill assignment over an off-interface method still works"

if grep -q '^JSERR' "$D0"; then
    echo "[hb-iface] FAIL: the page's scripts errored"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "[hb-iface] RESULT: PASS"; exit 0; fi
echo "[hb-iface] RESULT: FAIL"; exit 1
