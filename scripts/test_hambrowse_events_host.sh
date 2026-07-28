#!/usr/bin/env bash
# scripts/test_hambrowse_events_host.sh — FAST, QEMU-free gate for EVENT DISPATCH
# (browser campaign round 8). Rounds 3-7 shipped the DOM tree + node identity +
# innerHTML + selectors-over-created-nodes + element.style; the event surface had
# only registration (addEventListener / el.onclick) and a single-listener
# dispatchEvent with NO bubbling and a no-op stopPropagation. This gate proves the
# real dispatch machinery real pages depend on:
#   - MULTIPLE listeners: two addEventListener('click') + one el.onclick on the
#     same element all fire, in REGISTRATION order (A,B via addEventListener then
#     C via onclick) — packed into one accumulator so ORDER is a single readback.
#   - BUBBLING target -> ancestors: a click dispatched on #btn bubbles up to a
#     listener on ancestor #outer (SEQ ...O), with event.currentTarget re-pointed
#     per level while event.target stays the original.
#   - the Event object: event.type / event.target.id / event.currentTarget.id.
#   - preventDefault(): dispatchEvent() returns false + event.defaultPrevented.
#   - stopPropagation(): a handler on #mid halts bubbling so #outer never runs.
#   - a handler's DOM mutation (e.target.textContent) re-renders (SEG readback,
#     never a glyph-ink pixel).
# The deterministic trigger is el.dispatchEvent({type:'click'}) from the page
# <script> (a real pointer click routes through the SAME dispatch core).
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler; a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_evtdispatch.html"
mkdir -p "$OUT"

echo "[hb-evt] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/evt_compile.log"; then
    echo "[hb-evt] FAIL: host harness did not compile"; cat "$OUT/evt_compile.log"; exit 1
fi
echo "[hb-evt] PASS host harness compiled -> $BIN"

echo "[hb-evt] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/evt_native.log"; then
    echo "[hb-evt] FAIL: native hambrowse did not compile"; cat "$OUT/evt_native.log"; exit 1
fi
echo "[hb-evt] PASS native hambrowse still compiles"

fail=0
D0="$OUT/evt_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-evt] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-evt] PASS $2"
    else
        echo "[hb-evt] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-evt] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-evt] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- (1) multi-listener fire ORDER + onclick-alongside + bubble ----------
# addEventListener a, addEventListener b, el.onclick c fire A,B,C in registration
# order; then the event bubbles to the ancestor #outer listener -> O.
assert_grep '^JSLOG SEQ1 ABCO$'  "two addEventListener + onclick fire in order (ABC), then bubble to ancestor (O)"

# ---- (2) Event object props (type/target/currentTarget) ------------------
assert_grep '^JSLOG PROPS type=click target=btn ctarget=btn$' "event.type/target/currentTarget on the target element"
assert_grep '^JSLOG BUB target=btn ctarget=outer$'            "on a bubbled ancestor: target stays #btn, currentTarget becomes #outer"

# ---- (3) dispatchEvent return + preventDefault ---------------------------
assert_grep '^JSLOG RET1 true$'          "dispatchEvent returns true when not prevented"
assert_grep '^JSLOG PD ret=false dp=true$' "preventDefault() -> dispatchEvent returns false + event.defaultPrevented true"

# ---- (4) stopPropagation halts bubbling ----------------------------------
# dispatch on #mid: #mid handler runs (M) and stops; #outer listener (X) must NOT.
assert_grep '^JSLOG STOP M$'   "stopPropagation() on #mid prevents the ancestor #outer listener from firing"
assert_nogrep '^JSLOG STOP MX' "the stopped ancestor listener did not run"

# ---- (5) no uncaught error -----------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the dispatch script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing event API"

# ---- THE RENDER REFLECTION PROOF -----------------------------------------
# A click handler set e.target.textContent = 'MUTATED-OK'; the mutation must be
# baked into the render (SEG readback, not a glyph-ink pixel).
assert_grep 'MUTATED-OK'    "a handler's textContent mutation reflects in the render"
assert_nogrep '\|start\|'   "the original #box text ('start') is replaced"

if [ "$fail" -ne 0 ]; then
    echo "[hb-evt] RESULT: FAIL"; exit 1
fi
echo "[hb-evt] RESULT: PASS"
