#!/usr/bin/env bash
# scripts/test_hambrowse_domlifecycle_host.sh — FAST, QEMU-free gate for two
# dom-events surfaces real pages depend on (browser W3C campaign):
#   (A) DOCUMENT lifecycle events: document.addEventListener('DOMContentLoaded'
#       / 'load', fn) actually fire — AFTER every page <script> runs, and in spec
#       order (DOMContentLoaded then load). The document object is not a registered
#       DOM element, so before this these listeners were silently dropped and the
#       events never fired (the dominant framework/analytics init pattern was dead).
#   (B) el.addEventListener('keydown', fn) + el.dispatchEvent(new Event('keydown'))
#       — an arbitrary (non-legacy) event TYPE constructed via `new Event(...)`
#       fires the matching listener; a distinct type (keyup) does NOT cross-fire.
#   (C) new CustomEvent('foo',{detail:42}) round-trips numeric detail through
#       dispatchEvent to the listener (event.detail === 42).
#   (D) WINDOW lifecycle: window.addEventListener('load', fn) AND window.onload =
#       fn both fire once at load time (the dominant real-page init hook); the
#       onload handler's `this` is the window; window.removeEventListener drops a
#       load listener before it fires.
# Exact-output oracle on console.log lines. Builds host + native targets so a
# regression in either fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_domlifecycle.html"
mkdir -p "$OUT"

echo "[hb-life] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/life_compile.log"; then
    echo "[hb-life] FAIL: host harness did not compile"; cat "$OUT/life_compile.log"; exit 1
fi
echo "[hb-life] PASS host harness compiled -> $BIN"

echo "[hb-life] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/life_native.log"; then
    echo "[hb-life] FAIL: native hambrowse did not compile"; cat "$OUT/life_native.log"; exit 1
fi
echo "[hb-life] PASS native hambrowse still compiles"

fail=0
D0="$OUT/life_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-life] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-life] PASS $2"; else echo "[hb-life] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_nogrep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-life] FAIL $2 (present: $1)"; fail=1; else echo "[hb-life] PASS $2"; fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- (A) document DOMContentLoaded / load fire, in order ---------------------
assert_grep '^JSLOG DCL type=DOMContentLoaded tt=#document$' "document DOMContentLoaded listener fires with live event.type/target(document)"
assert_grep '^JSLOG LIFE DL$'          "DOMContentLoaded fires BEFORE load (document lifecycle order)"

# ---- (B) keydown listener + new Event('keydown') ----------------------------
assert_grep '^JSLOG KD fired type=keydown$' "el.addEventListener('keydown') fires on dispatchEvent(new Event('keydown'))"
assert_grep '^JSLOG KDCOUNT 1$'             "the keydown listener fired exactly once (keyup did NOT cross-fire)"

# ---- (C) new CustomEvent detail round-trip ----------------------------------
assert_grep '^JSLOG CEDETAIL 42$' "new CustomEvent('foo',{detail:42}) carries numeric detail"
assert_grep '^JSLOG CEFIRE 42$'   "dispatchEvent(CustomEvent) delivers detail===42 to the listener"

# ---- (D) window.onload + window.addEventListener('load') fire at load --------
# window.onload runs after the addEventListener('load') listeners; the removed
# listener (wgone -> 'X') must NOT appear, and `this` is the window.
assert_grep '^JSLOG WONLOAD type=load win=true seq=A\(load\)$' "window.onload fires (type=load, this===window) after window.addEventListener('load'); removed listener did not run"

assert_nogrep '^JSERR'   "no uncaught JS error across the lifecycle script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing event API"

if [ "$fail" -ne 0 ]; then echo "[hb-life] RESULT: FAIL"; exit 1; fi
echo "[hb-life] RESULT: PASS"
