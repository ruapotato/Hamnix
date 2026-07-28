#!/usr/bin/env bash
# scripts/test_hambrowse_formvalid_host.sh — FAST, QEMU-free gate for HTML FORM
# POST SUBMISSION + the CONSTRAINT VALIDATION API (browser W3C campaign). This is
# what login/signup/checkout forms depend on. Everything is driven from the page
# <script>; an exact-output oracle on the harness NAV/BODY/JSLOG lines.
#
#   (A) method=POST — a POST form serializes its named controls into a REQUEST
#       BODY (application/x-www-form-urlencoded), leaving the action query-free.
#       Host prints "NAV POST <action>" + "BODY a=1&b=2...". GET stays a query
#       string (proven by the sibling formsubmit gate + the novalidate case here).
#   (B) Constraint Validation API — required blocks submission on empty;
#       checkValidity()/reportValidity() on form + control; a live `validity`
#       object (valueMissing/typeMismatch/badInput/rangeUnderflow/tooLong/
#       customError); setCustomValidity() forces/clears a custom error;
#       type=email rejects "abc", type=number rejects non-numeric + honours
#       min/max, maxlength enforces tooLong.
#   (C) a required-empty form BLOCKS submit() (no navigation) — the signup guard.
#   (D) `novalidate` bypasses validation: an invalid form still submits.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler; a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-fv] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/fv_compile.log"; then
    echo "[hb-fv] FAIL: host harness did not compile"; cat "$OUT/fv_compile.log"; exit 1
fi
echo "[hb-fv] PASS host harness compiled -> $BIN"

echo "[hb-fv] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/fv_native.log"; then
    echo "[hb-fv] FAIL: native hambrowse did not compile"; cat "$OUT/fv_native.log"; exit 1
fi
echo "[hb-fv] PASS native hambrowse still compiles"

fail=0
FP="$OUT/form_post.txt"
FVL="$OUT/form_validate.txt"
FB="$OUT/form_block.txt"
FN="$OUT/form_novalidate.txt"
"$BIN" tests/fixtures/hambrowse_formpost.html     880 >"$FP"  2>&1 || { echo "[hb-fv] FAIL: formpost render exited non-zero"; cat "$FP"; exit 1; }
"$BIN" tests/fixtures/hambrowse_formvalidate.html 880 >"$FVL" 2>&1 || { echo "[hb-fv] FAIL: formvalidate render exited non-zero"; cat "$FVL"; exit 1; }
"$BIN" tests/fixtures/hambrowse_formblock.html    880 >"$FB"  2>&1 || { echo "[hb-fv] FAIL: formblock render exited non-zero"; cat "$FB"; exit 1; }
"$BIN" tests/fixtures/hambrowse_formnovalidate.html 880 >"$FN" 2>&1 || { echo "[hb-fv] FAIL: formnovalidate render exited non-zero"; cat "$FN"; exit 1; }

assert() {    # file pattern message
    if grep -Eq -- "$2" "$1"; then
        echo "[hb-fv] PASS $3"
    else
        echo "[hb-fv] FAIL $3 (missing: $2)"; fail=1
    fi
}
assert_no() { # file pattern message
    if grep -Eq -- "$2" "$1"; then
        echo "[hb-fv] FAIL $3 (present: $2)"; fail=1
    else
        echo "[hb-fv] PASS $3"
    fi
}

grep -E 'JSERR|Uncaught' "$FP" "$FVL" "$FB" "$FN" || true

# ---- (A) method=POST -> request body, query-free action -------------------
assert    "$FP" '^NAV POST /login$'          "POST form navigates to bare action (no query string)"
assert    "$FP" '^BODY a=1&b=2&agree=yes$'   "POST form serializes named controls into a urlencoded BODY"
assert_no "$FP" '/login\?'                   "the POST action carries NO query string"
assert_no "$FP" '^JSERR'                     "no uncaught JS error on POST submit"

# ---- (B) Constraint Validation API ----------------------------------------
assert "$FVL" '^JSLOG EMPTY-FORM-VALID false$'        "required-empty form: form.checkValidity() is false"
assert "$FVL" '^JSLOG EMAIL-MISSING true$'            "validity.valueMissing set for the empty required control"
assert "$FVL" '^JSLOG EMAIL-ABC-VALID false$'         "type=email rejects \"abc\" (checkValidity false)"
assert "$FVL" '^JSLOG EMAIL-ABC-TYPEMISMATCH true$'   "validity.typeMismatch set for a bad e-mail"
assert "$FVL" '^JSLOG EMAIL-GOOD-VALID true$'         "a well-formed e-mail passes"
assert "$FVL" '^JSLOG AGE-XYZ-VALID false$'           "type=number rejects a non-numeric value"
assert "$FVL" '^JSLOG AGE-XYZ-BADINPUT true$'         "validity.badInput set for non-numeric number input"
assert "$FVL" '^JSLOG AGE-9-VALID false$'             "number below min is invalid"
assert "$FVL" '^JSLOG AGE-9-UNDERFLOW true$'          "validity.rangeUnderflow set below min"
assert "$FVL" '^JSLOG AGE-25-VALID true$'             "an in-range number passes"
assert "$FVL" '^JSLOG NICK-LONG-VALID false$'         "maxlength exceeded is invalid"
assert "$FVL" '^JSLOG NICK-LONG-TOOLONG true$'        "validity.tooLong set past maxlength"
assert "$FVL" '^JSLOG NICK-OK-VALID true$'            "a short-enough value passes maxlength"
assert "$FVL" '^JSLOG FULL-FORM-VALID true$'          "form.checkValidity() true once every control is valid"
assert "$FVL" '^JSLOG FULL-FORM-REPORT true$'         "form.reportValidity() agrees with checkValidity()"
assert "$FVL" '^JSLOG CUSTOM-VALID false$'            "setCustomValidity(msg) forces the control invalid"
assert "$FVL" '^JSLOG CUSTOM-ERROR true$'             "validity.customError set by setCustomValidity"
assert "$FVL" '^JSLOG CUSTOM-MSG nope$'               "validationMessage reflects the custom message"
assert "$FVL" '^JSLOG CUSTOM-CLEARED-VALID true$'     "setCustomValidity('') clears the custom error"
assert "$FVL" '^NAV POST /signup$'                    "a now-valid POST form submits"
assert "$FVL" '^BODY email=me_site.com&age=25&nick=ok$' "the valid POST body carries the current control values"
assert_no "$FVL" '^JSERR'                             "no uncaught JS error across the validation script"

# ---- (C) required-empty BLOCKS submit() (no navigation) -------------------
assert    "$FB" '^JSLOG AFTER-BLOCKED-SUBMIT ok$'     "submit() ran on the invalid form"
assert_no "$FB" '^NAV '                               "a required-empty form BLOCKS navigation (no NAV)"
assert_no "$FB" '^BODY '                              "no request body is built for a blocked submit"

# ---- (D) novalidate bypasses validation -----------------------------------
assert    "$FN" '^NAV /signup\?email=$'               "novalidate submits an invalid form (GET query)"
assert_no "$FN" '^JSERR'                              "no uncaught JS error in the novalidate path"

if [ "$fail" -ne 0 ]; then
    echo "[hb-fv] RESULT: FAIL"; exit 1
fi
echo "[hb-fv] RESULT: PASS"
