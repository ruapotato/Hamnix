#!/usr/bin/env bash
# scripts/test_hambrowse_formsubmit_host.sh — FAST, QEMU-free gate for FORM
# SUBMISSION + INPUT VALUE ROUND-TRIP (browser campaign round 9). Round 8 shipped
# real event dispatch (bubbling + preventDefault/stopPropagation); this gate proves
# the form behaviors real pages/SPAs depend on, all driven from the page <script>:
#   (A) input.value / textarea.value get AND set from JS — read the current field
#       text, write a new value, read it back, and see the written value BAKED into
#       the render (FLOW/SEG readback, never a glyph-ink pixel). el.name/el.type too.
#   (B) form.submit() from JS gathers every named control into an
#       application/x-www-form-urlencoded query and "navigates" to action?k=v...
#       (the front-end reads he_nav_*; the host harness prints it as a NAV line):
#         - text input value (URL-encoded: space -> '+', reserved -> '_')
#         - a CHECKED checkbox contributes; an UNCHECKED one does not
#         - a CHECKED radio contributes (only the selected group member)
#         - a <select> contributes its selected option
#       and a non-cancelling submit listener still fires (the submit event).
#   (C) a submit listener calling e.preventDefault() STOPS navigation (NO NAV
#       line) — the single most important SPA behavior — and the submit event
#       BUBBLES to an ancestor listener + is cancelable (defaultPrevented true).
#
# Coverage: GET serialization of text/checkbox/radio/select; cancelable+bubbling
# submit event; input/textarea value get/set/reflect. DEFERRED (documented, not
# tested here): POST request bodies, multipart/FormData, <select multiple>, and
# HTML form validation (required/pattern).
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler; a regression in either
# target fails here with no QEMU boot. Exact-output oracle on NAV + console.log.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-form] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/form_compile.log"; then
    echo "[hb-form] FAIL: host harness did not compile"; cat "$OUT/form_compile.log"; exit 1
fi
echo "[hb-form] PASS host harness compiled -> $BIN"

echo "[hb-form] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/form_native.log"; then
    echo "[hb-form] FAIL: native hambrowse did not compile"; cat "$OUT/form_native.log"; exit 1
fi
echo "[hb-form] PASS native hambrowse still compiles"

fail=0
FV="$OUT/form_value.txt"
FS="$OUT/form_submit.txt"
FC="$OUT/form_cancel.txt"
"$BIN" tests/fixtures/hambrowse_formvalue.html  880 >"$FV" 2>&1 || { echo "[hb-form] FAIL: formvalue render exited non-zero"; cat "$FV"; exit 1; }
"$BIN" tests/fixtures/hambrowse_formsubmit.html 880 >"$FS" 2>&1 || { echo "[hb-form] FAIL: formsubmit render exited non-zero"; cat "$FS"; exit 1; }
"$BIN" tests/fixtures/hambrowse_formcancel.html 880 >"$FC" 2>&1 || { echo "[hb-form] FAIL: formcancel render exited non-zero"; cat "$FC"; exit 1; }

assert() {    # file pattern message
    if grep -Eq -- "$2" "$1"; then
        echo "[hb-form] PASS $3"
    else
        echo "[hb-form] FAIL $3 (missing: $2)"; fail=1
    fi
}
assert_no() { # file pattern message
    if grep -Eq -- "$2" "$1"; then
        echo "[hb-form] FAIL $3 (present: $2)"; fail=1
    else
        echo "[hb-form] PASS $3"
    fi
}

grep -E 'JSERR|Uncaught' "$FV" "$FS" "$FC" || true

# ---- (A) input.value / textarea.value get + set + render reflection -------
assert    "$FV" '^JSLOG READ t=orig ta=body-orig$' "read input.value + textarea.value from JS"
assert    "$FV" '^JSLOG SET t=typed ta=edited$'    "write input.value + textarea.value from JS, read back"
assert    "$FV" '^JSLOG META name=t type=text$'    "el.name / el.type reflected as JS props"
assert    "$FV" 'RENDERVAL'                         "a JS input.value write bakes into the render (SEG readback)"
assert_no "$FV" 'NAV '                              "no submit was triggered, so no navigation"
assert_no "$FV" '^JSERR'                            "no uncaught JS error in the value round-trip"

# ---- (B) form.submit() -> urlencoded GET navigation over all control types -
# space -> '+', reserved '&' -> '_'; checked checkbox + checked radio + select
# contribute; the unchecked checkbox (spam) and unselected radio (free) do NOT.
assert    "$FS" '^NAV /search\?q=hello\+world_x&agree=yes&plan=pro&size=large$' \
          "form.submit() serializes text(+encode)/checkbox/radio/select to action?k=v"
assert_no "$FS" 'spam='                             "an UNCHECKED checkbox does not contribute"
assert_no "$FS" 'plan=free'                         "an UNSELECTED radio does not contribute"
assert    "$FS" '^JSLOG SUBMIT-EVT type=submit target=f$' \
          "a non-cancelling submit listener fires (event.type/target)"
assert_no "$FS" '^JSERR'                            "no uncaught JS error on submit"

# ---- (C) preventDefault() in a submit listener STOPS navigation -----------
assert    "$FC" '^JSLOG CANCEL type=submit$'        "submit listener runs + reads event.type"
assert    "$FC" '^JSLOG BUBBLE ctarget=wrap target=f$' \
          "the submit event BUBBLES to an ancestor listener (currentTarget=wrap, target=f)"
assert    "$FC" '^JSLOG AFTER dp=true$'             "the submit event is cancelable (defaultPrevented true)"
assert_no "$FC" 'NAV '                              "preventDefault() blocked the navigation (NO NAV)"
assert_no "$FC" '^JSERR'                            "no uncaught JS error in the cancel path"

if [ "$fail" -ne 0 ]; then
    echo "[hb-form] RESULT: FAIL"; exit 1
fi
echo "[hb-form] RESULT: PASS"
