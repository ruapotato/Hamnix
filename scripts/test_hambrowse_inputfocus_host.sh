#!/usr/bin/env bash
# scripts/test_hambrowse_inputfocus_host.sh — FAST, QEMU-free gate proving the
# core browser usability path the DE user needs: CLICK INTO AN <input>/<textarea>
# TO FOCUS IT, THEN TYPE and see the characters land in the field.
#
# Why this gate exists: the pixel-render parity rounds proved the browser PAINTS
# a form control box, but nothing on the fast host path exercised the POINTER
# interaction — coordinate hit-test -> field focus -> per-keystroke value edit ->
# re-render. The native browser (user/hambrowse.ad) wires that chain from its
# /event + /keys loop (_hit_link -> he_link_evt_index -> he_dom_is_textfield ->
# _focus_field -> _field_key -> he_dom_set_value_index); this gate drives the
# IDENTICAL engine chain on the host via the `clickxy X Y TEXT` verb added to
# user/hambrowse_host_gfx.ad, so a regression in the hit-test / focus / typing
# path fails here in milliseconds instead of only on device.
#
# It asserts, for a real <input> and the google <textarea name=q>:
#   * a click at the control's painted box centre resolves to that control
#     (HITEL >= 0, textfield 1),
#   * focusing + typing appends the characters to the DOM value (FOCUSED line +
#     the SEGTXT run shows the typed text inside the field box), and
#   * a click in blank page area focuses NOTHING (HITEL -1) — no false focus.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_gfx_if"
fail=0

echo "[hb-if] compiling host gfx driver (x86_64-linux) ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/if_compile.log"; then
    echo "[hb-if] FAIL: host gfx driver did not compile"; cat "$OUT/if_compile.log"; exit 1
fi
echo "[hb-if] PASS host gfx driver compiled"

echo "[hb-if] compiling native hambrowse (x86_64-adder-user) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/if_native.elf" 2>"$OUT/if_native.log"; then
    echo "[hb-if] FAIL: native browser did not compile"; cat "$OUT/if_native.log"; exit 1
fi
echo "[hb-if] PASS native browser compiles (pointer-focus chain wired)"

# Derive a click point at the CENTRE of the first text-field box from the
# FIELDSEG geometry the driver dumps, so the gate stays robust to layout tweaks.
# Echoes "CX CY" for the field whose kind==1 (text control).
field_center() {
    local fix="$1"
    "$BIN" "$fix" "$OUT/if_probe.ppm" 640 clickxy 0 0 X 2>/dev/null \
        | awk '/^FIELDSEG kind 1 /{ print int(($5+$7)/2), int(($9+$11)/2); exit }'
}

# Run a click+type at (cx,cy) with TEXT; echo the driver dump.
click_type() {
    local fix="$1" cx="$2" cy="$3" txt="$4"
    "$BIN" "$fix" "$OUT/if_out.ppm" 640 clickxy "$cx" "$cy" "$txt" 2>/dev/null
}

check() {  # check <label> <condition-cmd...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "[hb-if] PASS $label"
    else
        echo "[hb-if] FAIL $label"; fail=1
    fi
}

# ---- (1) plain <input type=text> : click the empty box, type, see the text ----
FIX1="tests/fixtures/hambrowse_inputfocus.html"
read -r CX1 CY1 < <(field_center "$FIX1")
echo "[hb-if] input box centre = ($CX1,$CY1)"
D1="$(click_type "$FIX1" "$CX1" "$CY1" hello)"
echo "$D1" | grep -E '^(HITEL|FOCUSED|SEGTXT \[)' | sed 's/^/[hb-if]   /'
check "input: click resolves to a text field" \
    bash -c "printf '%s' \"$D1\" | grep -Eq '^HITEL [0-9]+ textfield 1'"
check "input: field focused + value = typed text" \
    bash -c "printf '%s' \"$D1\" | grep -Eq '^FOCUSED el [0-9]+ value hello$'"
check "input: typed text renders inside the field box" \
    bash -c "printf '%s' \"$D1\" | grep -Fq 'SEGTXT [hello'"

# ---- (2) google <textarea name=q>cats</textarea> : click, type -> appended ----
FIX2="tests/fixtures/hambrowse_google.html"
read -r CX2 CY2 < <(field_center "$FIX2")
echo "[hb-if] google search box centre = ($CX2,$CY2)"
D2="$(click_type "$FIX2" "$CX2" "$CY2" XYZ)"
echo "$D2" | grep -E '^(HITEL|FOCUSED)' | sed 's/^/[hb-if]   /'
check "textarea: click resolves to a text field" \
    bash -c "printf '%s' \"$D2\" | grep -Eq '^HITEL [0-9]+ textfield 1'"
check "textarea: typing appends to the existing value (catsXYZ)" \
    bash -c "printf '%s' \"$D2\" | grep -Eq '^FOCUSED el [0-9]+ value catsXYZ$'"
check "textarea: appended text renders inside the box" \
    bash -c "printf '%s' \"$D2\" | grep -Fq 'SEGTXT [catsXYZ'"

# ---- (3) click in blank page area focuses NOTHING (no false focus) ----
D3="$(click_type "$FIX1" 500 200 nope)"
check "blank-area click focuses nothing (HITEL -1)" \
    bash -c "printf '%s' \"$D3\" | grep -q '^HITEL -1'"
check "blank-area click produces no FOCUSED line" \
    bash -c "! printf '%s' \"$D3\" | grep -q '^FOCUSED'"

if [ "$fail" -ne 0 ]; then
    echo "[hb-if] RESULT: FAIL"; exit 1
fi
echo "[hb-if] RESULT: PASS"
