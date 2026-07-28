#!/usr/bin/env bash
# scripts/test_hambrowse_layoutread_host.sh — FAST, QEMU-free gate for the
# LAYOUT-READ (CSSOM geometry) surface: getBoundingClientRect / offsetWidth /
# offsetHeight / offsetLeft / offsetTop / getComputedStyle().width|height|
# padding|display.
#
# WHY THIS MATTERS. docs/browser_gap_analysis_2026-07-24.md ranked "real CSSOM
# read-back" as gap #2 — HIGH impact — because every "measure then position"
# script reads these: dropdown and context menus, sticky headers, tooltips,
# carousels, chart libraries, lazy-loading scroll code, responsive JS. Before
# the ebox registry the engine returned the element's TEXT INK (a
# `div{width:200px;height:80px}` holding one word reported 40x16) or a stub
# constant, and getComputedStyle only ever saw an INLINE `el.style` — a value
# from a <style> rule read back as `0px` / `block`. Measured then:
#
#     #a{width:200px;height:80px;padding:10px;border:2px}
#       getBoundingClientRect()   hb 40x16     chrome 224x104
#       offsetWidth/Height        hb 40,16     chrome 224,104
#       getComputedStyle().width  hb 40px      chrome 200px
#       ...........().padding     hb 0px       chrome 10px
#       ...........().display     hb block     chrome flex   (on #c)
#
# The layout engine now RECORDS each element's real laid-out box (lib/web/
# layout/box.ad, the `ebox_*` registry) and lib/web/dom/query.ad reports it.
#
# ORACLE. Every expected line below was read off real Chrome:
#     chromium --headless --window-size=880,900 --dump-dom \
#         file://$PWD/tests/fixtures/hambrowse_layoutread.html
# (with console.log teed into document.title so --dump-dom carries it). At the
# time of writing hambrowse reproduces all 26 lines BYTE-IDENTICALLY. Re-derive
# them the same way if the fixture is ever edited — do NOT copy them from
# hambrowse's own output, which would make this gate self-confirming.
#
# NO QEMU — runs the SAME lib/web engine the native browser uses, through the
# x86_64-linux host harness (user/hambrowse_host.ad).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_layoutread.html"
mkdir -p "$OUT"

echo "[hb-lr] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/lr_compile.log"; then
    echo "[hb-lr] FAIL: host harness did not compile"; cat "$OUT/lr_compile.log"; exit 1
fi
echo "[hb-lr] PASS host harness compiled -> $BIN"

# The layout-read work touches lib/web/layout + lib/web/dom, which the NATIVE
# browser also compiles. Keep it building.
echo "[hb-lr] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native_lr.elf" 2>"$OUT/lr_native.log"; then
    echo "[hb-lr] FAIL: native hambrowse did not compile"; cat "$OUT/lr_native.log"; exit 1
fi
echo "[hb-lr] PASS native hambrowse still compiles"

D0="$OUT/lr_run.txt"
if ! "$BIN" "$FIX" 880 >"$D0" 2>&1; then
    echo "[hb-lr] FAIL: render exited non-zero"; cat "$D0"; exit 1
fi

fail=0
if grep -q '^JSERR' "$D0"; then
    echo "[hb-lr] FAIL: JS error while measuring"; grep '^JSERR' "$D0"; fail=1
fi

GOT="$OUT/lr_got.txt"
sed -n 's/^JSLOG //p' "$D0" > "$GOT"

# --- Chrome's answers (see ORACLE above) ---------------------------------
EXP="$OUT/lr_expected.txt"
cat > "$EXP" <<'ORACLE'
RECT a=224x104@0,0
RECT b=120x40@0,119
RECT c=300x50@0,159
RECT w=642x362@0,209
RECT c1=276x136@21,230
RECT c2=276x136@21,378
RECT bar=400x24@21,526
RECT h=824x43@0,571
RECT n=816x35@0,614
RECT m=832x102@0,649
RECT p1=800x19@16,665
RECT p2=800x19@16,700
RECT big=812x40@0,751
RECT lh=800x32@0,791
RECT wrap=300x57@0,823
OFF a=224,104,0,0
OFF b=120,40,0,119
OFF c=300,50,0,159
OFF w=642,362,0,209
OFF bar=400,24,21,526
CS a=200px,80px,10px,block
CS b=120px,40px,0px,block
CS c=300px,50px,0px,flex
CS w=600px,320px,20px,block
CS c1=260px,120px,8px,block
CS big=800px,28px,6px,block
ORACLE

nexp="$(wc -l < "$EXP")"
ngot="$(wc -l < "$GOT")"
if [ "$ngot" -ne "$nexp" ]; then
    echo "[hb-lr] FAIL: expected $nexp measurement lines, got $ngot"
    echo "--- got ---"; cat "$GOT"
    fail=1
fi

# Compare line by line so a failure names the exact property that drifted.
i=0
while IFS= read -r want; do
    i=$((i + 1))
    have="$(sed -n "${i}p" "$GOT")"
    if [ "$have" = "$want" ]; then
        echo "[hb-lr] PASS $want"
    else
        echo "[hb-lr] FAIL want '$want'  got '$have'"
        fail=1
    fi
done < "$EXP"

# Guard the specific REGRESSION SHAPE the old engine had: reporting the text ink
# (an 8px char cell / a 16px grid row) instead of the element's box. If any
# sized element ever reports 40x16 or 8x16 again, this fires even if someone
# re-derives the oracle table above.
if grep -Eq '^RECT (a|b|c|w|c1|c2|bar)=(8|16|24|32|40)x16@' "$GOT"; then
    echo "[hb-lr] FAIL: a sized element reported TEXT-INK geometry again"
    grep -E '^RECT ' "$GOT"
    fail=1
else
    echo "[hb-lr] PASS no sized element fell back to text-ink geometry"
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-lr] RESULT: PASS (layout-read geometry matches Chrome exactly)"
    exit 0
fi
echo "[hb-lr] RESULT: FAIL"
exit 1
