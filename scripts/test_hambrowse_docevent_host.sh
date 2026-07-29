#!/usr/bin/env bash
# scripts/test_hambrowse_docevent_host.sh — FAST, QEMU-free gate pinning the
# LIVE-DOM INTERACTION keystone, with the document/window EventTarget surface.
#
# WHY THIS EXISTS
# ===============
# The 2026-07-25 real-web review named "the live DOM is not wired to
# interaction" as THE open blocker. MEASURED on 2026-07-29 against
# chromium --headless: the ELEMENT interaction chain (addEventListener +
# el.click() + el.dispatchEvent(new Event) + bubbling target +
# preventDefault/stopPropagation/stopImmediatePropagation + removeEventListener)
# already matched chromium end to end. The one CONFIRMED-broken link was the
# DOCUMENT / WINDOW half of EventTarget:
#     document.dispatchEvent        -> "not a function"  (undefined)
#     document.removeEventListener  -> undefined
#     window.dispatchEvent          -> undefined
# so `document.dispatchEvent(new Event('visibilitychange'))` and
# `window.dispatchEvent(new Event('resize'))` — the pub/sub spine routers, focus
# traps and framework lifecycles ride — threw or silently no-op'd. The fix
# attaches those methods and routes them through the DOC_EL sentinel listener
# pool, firing the CALLER's event object (so CustomEvent.detail survives) and
# honouring preventDefault / stopImmediatePropagation.
#
# ORACLE: the SAME fixture in `chromium --headless` (console.log surfaces on
# stderr). We diff hambrowse's `JSLOG EV …` lines against chromium's `EV …`
# lines — a live, byte-for-byte behavioural oracle, not a frozen expectation.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_docevent.html"
mkdir -p "$OUT"

echo "[hb-docevent] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/docevent_compile.log"; then
    echo "[hb-docevent] FAIL: host harness did not compile"
    cat "$OUT/docevent_compile.log"; exit 1
fi
echo "[hb-docevent] PASS host harness compiled -> $BIN"

echo "[hb-docevent] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/docevent_native.elf" 2>"$OUT/docevent_native.log"; then
    echo "[hb-docevent] FAIL: native hambrowse did not compile"
    cat "$OUT/docevent_native.log"; exit 1
fi
echo "[hb-docevent] PASS native hambrowse still compiles"

fail=0
D0="$OUT/docevent_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-docevent] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

if grep -q '^JSERR' "$D0"; then
    echo "[hb-docevent] FAIL uncaught JS error"; grep '^JSERR' "$D0"; fail=1
else
    echo "[hb-docevent] PASS no uncaught JS error"
fi

# hambrowse side: the ordered EV lines from the fixture's console.log.
HB="$OUT/docevent_hb.txt"
grep -oE 'JSLOG EV .+' "$D0" | sed 's/^JSLOG //; s/ *$//' >"$HB"

nlines=$(wc -l <"$HB")
if [ "$nlines" -lt 13 ]; then
    echo "[hb-docevent] FAIL: expected 13 EV lines, got $nlines"; cat "$HB"; fail=1
fi

# The interaction chain and the document/window dispatch MUST be present and
# correct even without a chromium on the runner — assert the load-bearing lines
# verbatim (chromium-verified 2026-07-29). The uppercase 'I' in stopImmed is
# intentional (matches the DOM method name in the fixture).
assert_line() {
    if grep -Fxq -- "EV $1" "$HB"; then
        echo "[hb-docevent] PASS $2"
    else
        echo "[hb-docevent] FAIL $2 (missing exact line: EV $1)"; fail=1
    fi
}
assert_line 'el.click.count :: 1'                 "addEventListener('click') fires on el.click()"
assert_line 'el.click.dom :: 1'                   "handler DOM mutation reaches the live tree"
assert_line 'el.dispatch.count :: 2'              "el.dispatchEvent(new Event('click')) fires the listener"
assert_line 'el.bubble :: inner:inner,outer:inner' "click bubbles with event.target = the clicked node"
assert_line 'doc.click :: 1'                      "document.dispatchEvent fires a standard-kind document listener"
assert_line 'doc.keydown :: Enter'                "document.dispatchEvent fires a GEN-kind listener; KeyboardEvent.key survives"
assert_line 'doc.detail :: 42'                    "document dispatch passes the caller's CustomEvent (detail survives)"
assert_line 'doc.pd.ret :: false'                 "preventDefault in a document listener makes dispatchEvent return false"
assert_line 'doc.ok.ret :: true'                  "an unprevented document dispatch returns true"
assert_line 'doc.target :: yes'                   "event.target === document inside a document listener"
assert_line 'doc.stopImmed :: a'                  "stopImmediatePropagation halts later document listeners"
assert_line 'doc.remove :: 0'                     "document.removeEventListener actually unregisters"
assert_line 'win.dispatch :: 1'                   "window.dispatchEvent fires window-level listeners"

# LIVE ORACLE: if chromium is present, require byte-for-byte identical EV lines.
CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
if [ -n "$CHROMIUM" ]; then
    CH="$OUT/docevent_chrome.txt"
    "$CHROMIUM" --headless --no-sandbox --disable-gpu --enable-logging=stderr --v=0 \
        --dump-dom "file://$PWD/$FIX" 2>&1 >/dev/null \
        | grep -oE 'EV [A-Za-z.]+ :: .*' | sed 's/", source:.*$//; s/ *$//' >"$CH" || true
    if [ -s "$CH" ] && diff -q "$HB" "$CH" >/dev/null; then
        echo "[hb-docevent] PASS hambrowse EV output is byte-identical to chromium"
    else
        echo "[hb-docevent] FAIL hambrowse diverges from the chromium oracle:"
        diff "$HB" "$CH" || true
        fail=1
    fi
else
    echo "[hb-docevent] NOTE chromium absent — skipped the live diff (verbatim asserts still ran)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-docevent] RESULT: FAIL"; exit 1
fi
echo "[hb-docevent] RESULT: PASS — element + document + window event dispatch match chromium"
