#!/usr/bin/env bash
# scripts/test_hambrowse_evtcapture_host.sh — FAST, QEMU-free gate for the DOM
# THREE-PHASE event propagation model (browser campaign round 9). Round 8 shipped
# multi-listener dispatch + BUBBLING + stop/preventDefault, but capture was a
# no-op (the useCapture flag was stored and ignored — every listener fired in a
# single bubble-only pass) and event.eventPhase was never set. Real sites use
# CAPTURING delegation (`el.addEventListener(t, fn, true)`) and read e.eventPhase,
# so this gate proves the genuine W3C DOM propagation ordering:
#   - CAPTURE (root->target's parent) fires only capture:true listeners, then
#     TARGET fires EVERY listener on the target in REGISTRATION order (capture &
#     bubble alike), then BUBBLE (target's parent->root) fires only capture:false
#     listeners. Single packed accumulator: "cO cM tA tB bM bO".
#   - event.eventPhase is 1 (CAPTURING) / 2 (AT_TARGET) / 3 (BUBBLING) per hop,
#     with currentTarget re-pointed each hop while target stays the origin.
#   - stopPropagation() DURING the capture phase halts before the target ever
#     runs (WSTOP == 'C').
#   - bubbles:false (new Event default) suppresses the bubble hop but capture +
#     target still run (NB == 'ct').
#   - removeEventListener(fn, true) drops a capture listener (RM == 'B').
# The deterministic trigger is el.dispatchEvent(...) from the page <script>; a
# real pointer click routes through the SAME _dispatch_event core.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler; a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_evtcapture.html"
mkdir -p "$OUT"

echo "[hb-cap] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/cap_compile.log"; then
    echo "[hb-cap] FAIL: host harness did not compile"; cat "$OUT/cap_compile.log"; exit 1
fi
echo "[hb-cap] PASS host harness compiled -> $BIN"

echo "[hb-cap] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/cap_native.log"; then
    echo "[hb-cap] FAIL: native hambrowse did not compile"; cat "$OUT/cap_native.log"; exit 1
fi
echo "[hb-cap] PASS native hambrowse still compiles"

fail=0
D0="$OUT/cap_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-cap] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-cap] PASS $2"
    else
        echo "[hb-cap] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-cap] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-cap] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- (1) full three-phase order: capture(root->parent) target(both, reg order)
#          bubble(parent->root) ------------------------------------------------
assert_grep '^JSLOG ORDER cO cM tA tB bM bO$' "capture cO,cM -> target tA,tB (reg order) -> bubble bM,bO"

# ---- (2) eventPhase + currentTarget per hop -------------------------------
assert_grep '^JSLOG CAP phase=1 ct=p1 tg=p3$' "capture hop: eventPhase===1, currentTarget===p1, target stays #p3"
assert_grep '^JSLOG AT phase=2 ct=p3$'        "target hop: eventPhase===2 (AT_TARGET), currentTarget===p3"
assert_grep '^JSLOG BUB phase=3 ct=p1$'       "bubble hop: eventPhase===3 (BUBBLING), currentTarget===p1"

# ---- (3) stopPropagation during CAPTURE halts before target ---------------
assert_grep '^JSLOG WSTOP C$'    "stopPropagation() in the capture phase runs neither the target nor bubble hops"
assert_nogrep '^JSLOG WSTOP CT'  "the target listener did not run after a capture-phase stop"

# ---- (4) bubbles:false suppresses the bubble hop (capture+target still run) --
assert_grep '^JSLOG NB ct$'      "bubbles:false: capture + target fire (c,t) but the bubble hop is suppressed"

# ---- (5) removeEventListener drops a capture listener ---------------------
assert_grep '^JSLOG RM B$'       "removeEventListener(fn, true) removed the capture listener; only the bubble one ran"

# ---- (6) no uncaught error -----------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the propagation script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing event API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-cap] RESULT: FAIL"; exit 1
fi
echo "[hb-cap] RESULT: PASS"
