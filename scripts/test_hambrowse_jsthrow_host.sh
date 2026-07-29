#!/usr/bin/env bash
# scripts/test_hambrowse_jsthrow_host.sh — FAST, QEMU-free gate that PINS the JS
# exception model: engine-raised errors (ReferenceError / TypeError) must be
# first-class, CATCHABLE JavaScript exceptions, and an UNCAUGHT one must abort
# only the current <script>, never the rest of the page.
#
# WHY. The 2026-07-25 real-web review (docs/hambrowse_real_web_review_2026-07-25.md
# §6.3) flagged the single biggest blocker to running real minified bundles: a
# `ReferenceError` from a missing global supposedly aborted the ENTIRE remaining
# script and could NOT be caught by try/catch — one missing global detonated the
# whole bundle from that point on. That behaviour has since been fixed in
# lib/web/js/interp.ad (engine errors now unwind to the nearest try/catch, expose
# a real Error object with .name/.message/instanceof, and when uncaught terminate
# ONLY the current script). This gate exists so that fix can never silently
# regress — there was previously NO gate covering try/catch around engine errors.
#
# ORACLE. Every expected value below came from node (V8 == Chrome's engine):
#     node -e '<the same expressions as tests/fixtures/hambrowse_jsthrow.html>'
# Do NOT re-derive them from hambrowse's own output — that would make this gate
# self-confirming.
#
# NO QEMU — runs the SAME lib/web engine the native browser uses, through the
# x86_64-linux host harness (user/hambrowse_host.ad).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_jsthrow.html"
mkdir -p "$OUT"

echo "[hb-throw] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/jsthrow_compile.log"; then
    echo "[hb-throw] FAIL: host harness did not compile"; cat "$OUT/jsthrow_compile.log"; exit 1
fi
echo "[hb-throw] PASS host harness compiled -> $BIN"

echo "[hb-throw] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native_bin.elf" 2>"$OUT/jsthrow_native.log"; then
    echo "[hb-throw] FAIL: native hambrowse did not compile"; cat "$OUT/jsthrow_native.log"; exit 1
fi
echo "[hb-throw] PASS native hambrowse still compiles"

D0="$OUT/jsthrow_run.txt"
if ! "$BIN" "$FIX" 880 >"$D0" 2>&1; then
    echo "[hb-throw] FAIL: render exited non-zero"; cat "$D0"; exit 1
fi

fail=0
grep -E 'JSLOG|JSERR' "$D0" || true

want() {   # want <JSLOG line body> <description>
    if grep -Fxq "JSLOG $1" "$D0"; then
        echo "[hb-throw] PASS $2"
    else
        echo "[hb-throw] FAIL $2 — want 'JSLOG $1', got '$(grep -F "JSLOG ${1%% *}" "$D0" | head -1)'"
        fail=1
    fi
}
absent() { # absent <exact JSLOG line body> <description>
    if grep -Fxq "JSLOG $1" "$D0"; then
        echo "[hb-throw] FAIL $2 — 'JSLOG $1' must NOT appear (script kept running past an uncaught throw)"
        fail=1
    else
        echo "[hb-throw] PASS $2"
    fi
}

# ---- Script A: engine-raised ReferenceError is CATCHABLE + first-class -------
want "A_REF ReferenceError | someUndefinedGlobal is not defined | true | true" \
     "missing-global ReferenceError caught; .name/.message + instanceof Error/ReferenceError"
want "A_AFTER" "code after the try/catch keeps running (the whole point)"

# ---- Script B: engine-raised TypeError (property of null) --------------------
want "B_TYPE TypeError | true | true" \
     "null.x throws a catchable TypeError (instanceof TypeError AND Error)"
want "B_AFTER" "code after the TypeError try/catch keeps running"

# ---- Script C/D: an UNCAUGHT engine error aborts ONLY the current script -----
want   "C_BEFORE"            "script C ran up to the point of the uncaught throw"
absent "C_SHOULD_NOT_PRINT"  "uncaught ReferenceError aborts the REST of script C"
want   "D_RAN"              "the NEXT <script> still runs — engine did NOT die"
want "D_CUSTOM TypeError | boom | true" \
     "user-thrown new TypeError round-trips (name/message/instanceof) after an uncaught error"
want "D_AFTER" "engine keeps evaluating to the end of the page"

# The uncaught error must be surfaced (not swallowed), but must NOT be an
# unrecoverable JSERR that kills the run — it is reported and evaluation resumes.
if grep -q 'Uncaught ReferenceError' "$D0"; then
    echo "[hb-throw] PASS uncaught ReferenceError is reported (not silently swallowed)"
else
    echo "[hb-throw] FAIL uncaught ReferenceError was not reported at all"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-throw] RESULT: PASS"
    exit 0
fi
echo "[hb-throw] RESULT: FAIL"
exit 1
