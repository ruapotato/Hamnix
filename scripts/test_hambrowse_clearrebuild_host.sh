#!/usr/bin/env bash
# scripts/test_hambrowse_clearrebuild_host.sh — FAST, QEMU-free gate for the
# "clear the container, then rebuild it from data" idiom (browser campaign
# round 12, audit finding #3). This is THE dominant JS list-update pattern
# (React/Vue/vanilla): `el.innerHTML = ''` followed by createElement()+
# appendChild() of the fresh rows. Before this round the innerHTML= setter
# replaced only the JS .children array; the RENDER still walked the old
# appendChild ap_*/cc_* created-node edges, so a re-render DOUBLED content
# ("7 rendered lines for 4 tasks"). The fix detaches the prior created subtree
# from the render tree when innerHTML is assigned.
#
# This gate double-renders at LOAD (render(3) then render(4)) — no click/event
# needed — and proves the container shows EXACTLY 4 rows in the RENDER (a SEG
# readback: the OLD 3 rows must be gone), not just in the JS array. It also
# covers the two bundled CSS fixes:
#   - list-style:none  (#5) suppresses the <li> bullet markers on #list, while a
#     sibling <ul> without it keeps its bullet (control).
#   - text-decoration:line-through (#4) sets the strike flag on a styled inline
#     element the same way <s>/<del>/<strike> does (SEG `s1` column).
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Machine-readable oracle on SEG/JSLOG.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_clearrebuild.html"
mkdir -p "$OUT"

echo "[hb-cr] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/cr_compile.log"; then
    echo "[hb-cr] FAIL: host harness did not compile"; cat "$OUT/cr_compile.log"; exit 1
fi
echo "[hb-cr] PASS host harness compiled -> $BIN"

echo "[hb-cr] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/cr_native.log"; then
    echo "[hb-cr] FAIL: native hambrowse did not compile"; cat "$OUT/cr_native.log"; exit 1
fi
echo "[hb-cr] PASS native hambrowse still compiles"

fail=0
D0="$OUT/cr_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-cr] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-cr] PASS $2"
    else
        echo "[hb-cr] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-cr] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-cr] PASS $2"
    fi
}
assert_count() {  # pattern expected message
    got=$(grep -Ec -- "$1" "$D0")
    if [ "$got" -eq "$2" ]; then
        echo "[hb-cr] PASS $3 (count=$got)"
    else
        echo "[hb-cr] FAIL $3 (pattern: $1 — got $got, want $2)"; fail=1
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- THE 4-NOT-7 PROOF: the RENDER shows exactly 4 rebuilt rows -----------
# Each rebuilt <li> lays out its 'ROWITEM' text as its own SEG. Pre-fix the
# render doubled to 7 (old 3 ap-edges + new 4). Post-fix: exactly 4.
assert_count '^SEG .* \|ROWITEM\|$' 4 "clear+rebuild renders EXACTLY 4 rows (not 7) — innerHTML='' detached the old created children"

# JS-side childNodes was already correct pre-fix (the setter rebuilt the array);
# assert it too so a future regression that breaks BOTH is caught.
assert_grep '^JSLOG cn 4$'          "list.childNodes length is 4 after the clear+rebuild"

# ---- list-style:none (#5) ------------------------------------------------
# #list has list-style:none -> its rebuilt rows draw NO bullet marker. The
# FLOW dump paints a '-' placeholder only for a real disc marker; the ROWITEM
# rows must have none, while the sibling #plain <ul> keeps its bullet.
assert_nogrep '^FLOW +- +ROWITEM' "list-style:none suppresses the <li> bullet on #list"
assert_grep   '^FLOW +- +bulletitem' "a sibling <ul> WITHOUT list-style:none still draws its bullet (control)"

# ---- text-decoration:line-through (#4) -----------------------------------
# The CSS class .done{text-decoration:line-through} strikes a styled inline
# element (SEG strike column s1), the same as the <s> tag. Both must be s1.
assert_grep '^SEG .* s1 .*classstrike\|' "text-decoration:line-through (CSS class) sets the strike flag"
assert_grep '^SEG .* s1 .*\| tagstrike\|'  "<s> tag strike still fires (regression guard)"
# Round 13: <li> now applies its OWN class cascade, so the ONE rebuilt row with
# className='done' (i===1) is struck + greyed, while the other THREE plain rows
# stay default. This both proves <li class> styling AND guards the style-stack
# leak: if the strike bled past the done <li>, MORE than one ROWITEM would be s1.
assert_count '^SEG .* s1 .*\|ROWITEM\|$' 1 "exactly the className='done' row is struck (<li> class cascade)"
assert_count '^SEG .* s0 .*\|ROWITEM\|$' 3 "the other three plain rows stay unstruck (no strike leak past the done <li>)"

# ---- no uncaught error ---------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the clear+rebuild script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from the setter path"

if [ "$fail" -ne 0 ]; then
    echo "[hb-cr] RESULT: FAIL"; exit 1
fi
echo "[hb-cr] RESULT: PASS"
