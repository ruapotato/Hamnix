#!/usr/bin/env bash
# scripts/test_de_panel_clock_host.sh — FAST, QEMU-free host gate for the DE
# panel's MATE-style clock applet (lib/panelclock.ad drawn through
# lib/hamscene.ad + rasterized by lib/hamui_host.ad).
#
# MATE's clock shows the weekday, month, day AND the time
# ("Sat Jul 12  14:30"), not just HH:MM. This gate proves that:
#   1. lib/panelclock.ad's civil-calendar math is correct for several epochs,
#   2. the full date+time string formats + rasterizes to non-blank pixels
#      (rendered to a PNG a human/agent can LOOK at), and
#   3. the NATIVE panel (user/hampanelscene.ad) still compiles from the same
#      pure module — all in milliseconds, no QEMU.
#
# Pre-feature (HH:MM-only clock) this gate FAILS: there is no lib/panelclock.ad
# and the scene carries no "Jul"/weekday glyphs. Post-feature it PASSES.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/panelclock_host"
mkdir -p "$OUT"
fail=0

echo "[panelclock-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/panelclock_host.ad "$BIN" 2>"$OUT/panelclock_compile.log"; then
    echo "[panelclock-host] FAIL: host harness did not compile"
    cat "$OUT/panelclock_compile.log"; exit 1
fi
echo "[panelclock-host] PASS host harness compiled -> $BIN"

echo "[panelclock-host] compiling NATIVE hampanelscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hampanelscene.ad "$OUT/hampanelscene_native.elf" 2>"$OUT/panelclock_native.log"; then
    echo "[panelclock-host] FAIL: native hampanelscene did not compile"
    cat "$OUT/panelclock_native.log"; exit 1
fi
echo "[panelclock-host] PASS native hampanelscene still compiles from panelclock"

# --- Deterministic render at a fixed epoch --------------------------------
# 1752330600 = Sat Jul 12 2025 14:30:00 UTC.
DUMP="$OUT/panelclock_dump.txt"
PPM="$OUT/panelclock.ppm"
if ! "$BIN" "$PPM" 1752330600 >"$DUMP" 2>&1; then
    echo "[panelclock-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$OUT/panelclock.png" \
        2>"$OUT/panelclock_png.log"; then
    echo "[panelclock-host] PASS rendered $OUT/panelclock.png ($(file -b "$OUT/panelclock.png" 2>/dev/null))"
else
    echo "[panelclock-host] FAIL png conversion"; cat "$OUT/panelclock_png.log"; fail=1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[panelclock-host] PASS $msg"
    else
        echo "[panelclock-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Calendar math + formatting (the core feature) ------------------------
assert_grep '^FULL Sat Jul 12  14:30' "full MATE date+time string formats correctly"
assert_grep '^TIME 14:30'             "compact HH:MM time formats correctly"
assert_grep '^YEAR 2025'              "civil-calendar year is correct"
assert_grep '^MONTH 7'                "civil-calendar month is correct"
assert_grep '^DAY 12'                 "civil-calendar day is correct"
assert_grep '^WDAY 6'                 "weekday is Saturday (6)"

# --- Scene display list carries the date glyphs (was HH:MM-only before) ---
assert_grep '^glyphs .* "Sat Jul 12  14:30" #202020' "scene draws the date+time glyphs"
# The rasterizer drew the panel + text (fill + stroke + glyphs => >= 3 prims).
assert_grep '^PRIMS ([3-9]|[1-9][0-9]+)' "rasterizer drew the panel + clock primitives"

# --- A SECOND epoch to prove the calendar math generalizes -----------------
# 0 = Thu Jan 01 1970 00:00:00 UTC (the epoch itself).
DUMP2="$OUT/panelclock_dump_epoch0.txt"
if ! "$BIN" "$OUT/panelclock_epoch0.ppm" 0 >"$DUMP2" 2>&1; then
    echo "[panelclock-host] FAIL: epoch-0 render exited non-zero"; fail=1
else
    if grep -Eq '^FULL Thu Jan 01  00:00' "$DUMP2"; then
        echo "[panelclock-host] PASS epoch 0 formats as 'Thu Jan 01  00:00'"
    else
        echo "[panelclock-host] FAIL epoch 0 wrong ($(grep '^FULL ' "$DUMP2"))"; fail=1
    fi
fi

# --- A leap-day epoch: 1709210096 = Thu Feb 29 2024 12:34:56 UTC ----------
DUMP3="$OUT/panelclock_dump_leap.txt"
if ! "$BIN" "$OUT/panelclock_leap.ppm" 1709210096 >"$DUMP3" 2>&1; then
    echo "[panelclock-host] FAIL: leap-day render exited non-zero"; fail=1
else
    if grep -Eq '^FULL Thu Feb 29  12:34' "$DUMP3"; then
        echo "[panelclock-host] PASS leap-day epoch formats as 'Thu Feb 29  12:34'"
    else
        echo "[panelclock-host] FAIL leap-day wrong ($(grep '^FULL ' "$DUMP3"))"; fail=1
    fi
fi

# --- Non-blank pixels: prove the clock text actually rasterized -----------
# Count distinct-from-background bytes in the PPM body (the #b8b4ac panel is
# 0xb8 b4 ac; any 0x20-ish dark text byte differs). A blank strip would have
# essentially none.
if command -v python3 >/dev/null 2>&1; then
    darkpx=$(python3 - "$PPM" <<'PY'
import sys
data=open(sys.argv[1],'rb').read()
# skip the ascii PPM header (3 newline-terminated lines: P6, "W H", "255")
nl=0;i=0
while nl<3:
    if data[i]==0x0a: nl+=1
    i+=1
body=data[i:]
# count pixels darker than the panel grey (text is ~#202020)
dark=sum(1 for j in range(0,len(body),3) if body[j]<0x60)
print(dark)
PY
)
    if [ "${darkpx:-0}" -ge 40 ]; then
        echo "[panelclock-host] PASS clock text rasterized ($darkpx dark px, expect >=40)"
    else
        echo "[panelclock-host] FAIL clock text did not rasterize ($darkpx dark px)"; fail=1
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "[panelclock-host] RESULT: PASS"
    exit 0
else
    echo "[panelclock-host] RESULT: FAIL"
    exit 1
fi
