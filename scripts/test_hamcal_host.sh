#!/usr/bin/env bash
# scripts/test_hamcal_host.sh — FAST, QEMU-free host gate for the Calendar
# scene app (lib/hamcalcore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Compiles the core for the host target, renders the month
# grid to a PNG a human/agent can LOOK at, drives a scripted prev-month click,
# asserts the calendar math + navigation, AND confirms the NATIVE Hamnix build
# still compiles from the same core — all in milliseconds, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamcal_host"
mkdir -p "$OUT"
fail=0

echo "[cal-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamcalscene_host.ad "$BIN" 2>"$OUT/cal_compile.log"; then
    echo "[cal-host] FAIL: host harness did not compile"; cat "$OUT/cal_compile.log"; exit 1
fi
echo "[cal-host] PASS host harness compiled -> $BIN"

echo "[cal-host] compiling NATIVE hamcalscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamcalscene.ad "$OUT/hamcal_native.elf" 2>"$OUT/cal_native.log"; then
    echo "[cal-host] FAIL: native hamcalscene did not compile"; cat "$OUT/cal_native.log"; exit 1
fi
echo "[cal-host] PASS native hamcalscene still compiles"

DUMP="$OUT/cal_dump.txt"
if ! "$BIN" "$OUT/cal_before.ppm" "$OUT/cal_after.ppm" >"$DUMP" 2>&1; then
    echo "[cal-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/cal_$f.ppm" "$OUT/cal_$f.png" 2>"$OUT/cal_png.log"; then
        echo "[cal-host] PASS rendered $OUT/cal_$f.png"
    else
        echo "[cal-host] FAIL png conversion ($f)"; cat "$OUT/cal_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[cal-host] PASS $2";
    else echo "[cal-host] FAIL $2 (missing: $1)"; fail=1; fi
}

assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 236 366 #eceef2'         "calendar window background"
assert_grep '^glyphs 82 38 \"July 2026\"'       "title shows the seeded month"
# 2026-07-01 is a Wednesday: day '1' lands in column 3 (x=6+3*32+10=112).
assert_grep '^glyphs 112 81 \"1\"'              "July 1 2026 placed on Wednesday"
# Today (the 12th) is highlighted white on the blue cell.
assert_grep '^glyphs 12 133 \"12\" #ffffff'     "today (12) highlighted"
assert_grep '^MONTH0 7'                         "initial month is July"
assert_grep '^YEAR0 2026'                       "initial year is 2026"
# Modern cohesive headerbar: a cool-blue vertical gradient (was a flat
# #3584e4). Scanline 4 of the azure gradient rasterizes to #618ac5.
assert_grep '^PIX 4 4 #618ac5'                  "raster headerbar pixel = cool-blue gradient"

# --- date selection + RELATIVE TIME ---
assert_grep '^SEL0 12'                          "selection defaults to today (12)"
assert_grep '^glyphs 8 256 \"today\"'           "readout says 'today' for today"
assert_grep '^DAYCLICK 1'                       "click on day-5 cell registered"
assert_grep '^SELDAY 5'                         "clicking July 5 selects the 5th"
assert_grep '^glyphs 8 238 \"Selected 2026-07-05\"' "selected date echoed"
# 2026-07-05 is 7 days before today (12) via days_from_civil, not 365.25.
assert_grep '^glyphs 8 256 \"7 days ago\"'      "relative time = '7 days ago'"

# --- ARROW KEYS (Right +1 day x3: 5->8; Down +7 days: 8->15) ---
assert_grep '^SELDAY_R 8'                       "Right-arrow x3 moved selection 5->8"
assert_grep '^SELDAY_D 15'                      "Down-arrow moved selection +1 week -> 15"
# 2026-07-15 is 3 days AFTER today (12) -> "in 3 days".
assert_grep '^glyphs 8 256 \"in 3 days\"'       "relative time ahead = 'in 3 days'"

# --- STOPWATCH (Start, +250 jiffies = 2.50s; Stop freezes; Reset zeroes) ---
assert_grep '^SWRUN 1'                          "Start button started the stopwatch"
assert_grep '^glyphs 150 284 \"00:02.50\"'      "stopwatch shows 2.50s elapsed"
assert_grep '^SWRUN2 0'                          "Stop button halted the stopwatch"
assert_grep '^glyphs 150 284 \"00:00.00\"'      "Reset button zeroed the stopwatch"
assert_grep '^glyphs 22 310 \"Start\"'          "Start button rendered"
assert_grep '^glyphs 102 310 \"Stop\"'          "Stop button rendered"
assert_grep '^glyphs 174 310 \"Reset\"'         "Reset button rendered"

# --- UPTIME CLOCK (superset of the retired /bin/hamclock; H:MM:SS since boot) -
assert_grep '^glyphs 8 340 \"Uptime\"'          "uptime-clock label rendered"
assert_grep '^glyphs 72 340 \"1:02:03\"'        "uptime clock shows H:MM:SS since boot"

# --- MONTH NAVIGATION (next-month arrow: July -> August) ---
assert_grep '^MONTH1 8'                         "next-month arrow navigated July -> August"

# --- ADJACENT-MONTH SPILL-OVER DAYS (grey, fill the leading/trailing blanks) ---
# July 2026 starts on Wednesday (first_wd=3): row-0 cols 0..2 spill the prior
# month's June 28,29,30 in dimmed grey (#a8acb0). Leading col0 -> (12,81).
assert_grep '^glyphs 12 81 \"28\" #a8acb0'      "leading spill day June 28 rendered grey"
assert_grep '^glyphs 76 81 \"30\" #a8acb0'      "leading spill day June 30 rendered grey"
# Trailing spill: after July 31 the grid fills with next-month Aug 1.. in grey.
assert_grep '^glyphs 208 185 \"1\" #a8acb0'     "trailing spill day Aug 1 rendered grey"
# Clicking a leading grey cell flips to that month and selects the day.
assert_grep '^SPILL_M 6'                        "clicking leading spill cell navigated to June"
assert_grep '^SPILL_D 28'                       "clicking leading spill cell selected June 28"

if [ "$fail" -ne 0 ]; then echo "[cal-host] OVERALL FAIL"; exit 1; fi
echo "[cal-host] OVERALL PASS"
