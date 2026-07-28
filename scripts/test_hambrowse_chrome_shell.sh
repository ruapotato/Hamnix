#!/usr/bin/env bash
# scripts/test_hambrowse_chrome_shell.sh — gate for the Chrome-style browser
# SHELL: (1) the pure ad-block + search-engine logic modules (host unit harness),
# and (2) the shell's overlay chrome — the ⋮ application MENU dropdown and the
# docked DEV-TOOLS panel — rendered by the shared compositor lib/browserwin.ad
# via the host window driver, asserted with deterministic pixel probes. QEMU-free.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT="build/host"; mkdir -p "$OUT"
fail=0

# ---- (1) pure logic modules: ad-block + search engines --------------
UBIN="$OUT/hb_chrome_test"
echo "[hb-shell] compiling module unit harness (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_chrome_test_host.ad "$UBIN" 2>"$OUT/shell_unit.log"; then
    echo "[hb-shell] FAIL: unit harness did not compile"; cat "$OUT/shell_unit.log"; exit 1
fi
U="$OUT/shell_unit.txt"
"$UBIN" >"$U" 2>&1
assert_u() {  # pattern message
    if grep -qx -- "$1" "$U"; then echo "[hb-shell] PASS $2"
    else echo "[hb-shell] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_u 'AB_ON 1'         "ad-block on by default"
assert_u 'AB_MATCH_AD 1'   "blocks googlesyndication ad script"
assert_u 'AB_MATCH_OK 0'   "allows a normal wikipedia URL"
assert_u 'AB_MATCH_TRK 1'  "blocks google-analytics tracker"
assert_u 'AB_BLOCKED 2'    "counts exactly the 2 ad/tracker hits"
assert_u 'AB_OFF_BLOCK 0'  "toggling ad-block off lets ads through"
assert_u 'SE_COUNT 4'      "four search engines registered"
assert_u 'SE_CUR0 0'       "Google is the default engine"
assert_u 'SE_G_PREFIX https://www.google.com/search?q=' "Google prefix routes correctly"
assert_u 'SE_DDG_PREFIX https://duckduckgo.com/?q='     "DuckDuckGo prefix routes correctly"
assert_u 'SE_CYCLE1 3'     "cycle DDG -> Brave"
assert_u 'SE_CYCLE2 0'     "cycle Brave -> Google (wraps)"
assert_u 'DONE'            "unit harness ran to completion"

# ---- (2) overlay chrome: menu + dev-tools panels --------------------
WBIN="$OUT/hambrowse_gfx_window"
echo "[hb-shell] compiling window compositor (x86_64-linux) ..."
if ! adder_bin x86_64-linux user/hambrowse_gfx_window.ad "$WBIN" 2>"$OUT/shell_win.log"; then
    echo "[hb-shell] FAIL: window compositor did not compile"; cat "$OUT/shell_win.log"; exit 1
fi
FIX="tests/fixtures/hambrowse_article.html"

# box_probe PPM cx cy half wantR wantG wantB tol -> pass if any pixel in the box
# is within tol of the target colour.
box_has_color() {
    python3 - "$@" <<'PY'
import sys
f,cx,cy,hb,tr,tg,tb,tol=sys.argv[1],*(int(a) for a in sys.argv[2:9])
p=open(f,'rb'); assert p.readline().strip()==b'P6'
w,h=map(int,p.readline().split()); p.readline(); data=p.read()
for y in range(cy-hb,cy+hb):
    for x in range(cx-hb,cx+hb):
        if 0<=x<w and 0<=y<h:
            o=(y*w+x)*3
            if abs(data[o]-tr)<=tol and abs(data[o+1]-tg)<=tol and abs(data[o+2]-tb)<=tol:
                print("YES"); sys.exit(0)
print("NO")
PY
}

# MENU scene: the ⋮ dropdown paints a blue "Ad block" toggle (#1a73e8) and the
# Google engine brand chip (#4285f4). Neither exists on the plain page there.
"$WBIN" "$FIX" "$OUT/shell_menu.ppm" 1000 700 1 1 0 0 menu >/dev/null 2>&1
python3 scripts/ppm_to_png.py "$OUT/shell_menu.ppm" "$OUT/shell_menu.png" 2>/dev/null
# blue toggle sits in the lower half of the dropdown, right side
if [ "$(box_has_color "$OUT/shell_menu.ppm" 948 480 60 26 115 232 40)" = YES ]; then
    echo "[hb-shell] PASS application menu shows the ad-block toggle (blue)"
else echo "[hb-shell] FAIL menu ad-block toggle not found"; fail=1; fi
if [ "$(box_has_color "$OUT/shell_menu.ppm" 745 367 40 66 133 244 40)" = YES ]; then
    echo "[hb-shell] PASS application menu lists the Google engine chip"
else echo "[hb-shell] FAIL menu engine chip not found"; fail=1; fi

# DEV-TOOLS scene: the docked panel paints a light-grey header (#f1f3f4) with a
# blue "Elements" tab (#1a73e8), across the width — never present on a plain page.
"$WBIN" "$FIX" "$OUT/shell_dt.ppm" 1000 700 1 1 0 0 devtools >/dev/null 2>&1
python3 scripts/ppm_to_png.py "$OUT/shell_dt.ppm" "$OUT/shell_dt.png" 2>/dev/null
if [ "$(box_has_color "$OUT/shell_dt.ppm" 44 418 12 26 115 232 50)" = YES ]; then
    echo "[hb-shell] PASS dev-tools panel shows the blue Elements tab"
else echo "[hb-shell] FAIL dev-tools Elements tab not found"; fail=1; fi
if [ "$(box_has_color "$OUT/shell_dt.ppm" 300 416 8 241 243 244 8)" = YES ]; then
    echo "[hb-shell] PASS dev-tools panel has its grey header bar"
else echo "[hb-shell] FAIL dev-tools header bar not found"; fail=1; fi

# native browser must still compile with all the shell wiring.
echo "[hb-shell] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hb_shell_native.elf" 2>"$OUT/shell_native.log"; then
    echo "[hb-shell] FAIL: native hambrowse did not compile"; cat "$OUT/shell_native.log"; fail=1
else echo "[hb-shell] PASS native hambrowse compiles with the shell wiring"; fi

if [ "$fail" -eq 0 ]; then echo "[hb-shell] RESULT: PASS"; else echo "[hb-shell] RESULT: FAIL"; fi
exit "$fail"
