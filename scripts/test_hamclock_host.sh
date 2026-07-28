#!/usr/bin/env bash
# scripts/test_hamclock_host.sh — FAST, QEMU-free host gate for HamClock, the
# clock / calendar / timer desktop utility (lib/hamclockcore.ad drawn through
# lib/hamscene.ad + rasterized by lib/hamui_host.ad). It drives the SAME core
# the native app ships with a KNOWN, injected wall-clock epoch so the run is
# deterministic, and asserts:
#   * the digital HH:MM:SS string + the Y/M/D + weekday decoded from the epoch,
#   * the analog hand angles for two known times,
#   * days-in-month + first-of-month weekday for leap AND non-leap February
#     (incl. the 400/100 century rules),
#   * the "today" cell highlight lands on the correct weekday column, and
#   * the stopwatch start / elapsed / stop / reset transitions.
# It renders the CLOCK, CALENDAR and TIMER views to PNGs a human/agent can LOOK
# at, and confirms the NATIVE Hamnix build still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamclock_host"
mkdir -p "$OUT"
fail=0

echo "[hamclock-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamclock_host.ad "$BIN" 2>"$OUT/hc_compile.log"; then
    echo "[hamclock-host] FAIL: host harness did not compile"; cat "$OUT/hc_compile.log"; exit 1
fi
echo "[hamclock-host] PASS host harness compiled -> $BIN"

echo "[hamclock-host] compiling NATIVE hamclock for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamclock.ad "$OUT/hamclock_native.elf" 2>"$OUT/hc_native.log"; then
    echo "[hamclock-host] FAIL: native hamclock did not compile"; cat "$OUT/hc_native.log"; exit 1
fi
echo "[hamclock-host] PASS native hamclock still compiles"

DUMP="$OUT/hc_dump.txt"
if ! "$BIN" "$OUT/hc_clock.ppm" "$OUT/hc_cal.ppm" "$OUT/hc_timer.ppm" >"$DUMP" 2>&1; then
    echo "[hamclock-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in clock cal timer; do
    if python3 scripts/ppm_to_png.py "$OUT/hc_$f.ppm" "$OUT/hc_$f.png" 2>"$OUT/hc_png.log"; then
        echo "[hamclock-host] PASS rendered $OUT/hc_$f.png"
    else
        echo "[hamclock-host] FAIL png conversion ($f)"; cat "$OUT/hc_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamclock-host] PASS $2";
    else echo "[hamclock-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- clock: digital string + broken-down date decoded from the epoch -------
assert_grep '^DIGITAL 03:00:00'     "digital clock string for 03:00:00"
assert_grep '^YEAR 2026'            "year decoded from epoch"
assert_grep '^MONTH 3'              "month decoded from epoch"
assert_grep '^DAY 14'               "day decoded from epoch"
assert_grep '^WDAY 6'               "weekday decoded (2026-03-14 = Saturday)"
assert_grep '^HOUR_ANGLE 90'        "hour hand at 90 deg for 03:00"
assert_grep '^MIN_ANGLE 0'          "minute hand at 0 deg for :00"
assert_grep '^SEC_ANGLE 0'          "second hand at 0 deg for :00"

# --- second known time: 06:15:30 -> 187 / 90 / 180 ------------------------
assert_grep '^DIGITAL2 06:15:30'    "digital clock string for 06:15:30"
assert_grep '^HOUR_ANGLE2 187'      "hour hand at 187 deg for 06:15 (30/hr + 0.5/min)"
assert_grep '^MIN_ANGLE2 90'        "minute hand at 90 deg for :15"
assert_grep '^SEC_ANGLE2 180'       "second hand at 180 deg for :30"

# --- calendar correctness: days-in-month (leap + century) ------------------
assert_grep '^DIM_2024_02 29'       "Feb 2024 has 29 days (leap year)"
assert_grep '^DIM_2023_02 28'       "Feb 2023 has 28 days (non-leap)"
assert_grep '^DIM_2025_02 28'       "Feb 2025 has 28 days (non-leap)"
assert_grep '^DIM_2000_02 29'       "Feb 2000 has 29 days (divisible by 400)"
assert_grep '^DIM_2100_02 28'       "Feb 2100 has 28 days (÷100 but not ÷400)"
assert_grep '^DIM_2026_03 31'       "March 2026 has 31 days"
assert_grep '^FW_2026_03 0'         "March 1 2026 is a Sunday (col 0)"
assert_grep '^FW_2024_02 4'         "Feb 1 2024 is a Thursday (col 4)"

# --- today highlight lands on the correct weekday cell ---------------------
# March 1 2026 = Sunday, so the 14th is row 1, col 6 -> cell x=336,y=148.
assert_grep '^fill 337 149 50 42 #ffd23f' "today (14th) highlight fill on the right cell"
assert_grep '^CLOCK_VIEW 0'         "clock view active for the first render"
assert_grep '^CAL_VIEW 1'           "calendar view after pressing 2"
assert_grep '^PIX_TITLEBAR 2829660' "title-bar pixel is the indigo theme (#2b2d5c)"
assert_grep '^# scene v1 hamui'     "scene header emitted"

# --- stopwatch: start / elapse / stop / reset ------------------------------
assert_grep '^TIMER_VIEW 2'         "timer view after pressing 3"
assert_grep '^T_RUN0 0'             "stopwatch starts stopped"
assert_grep '^T_EL0 0'             "stopwatch starts at 0 elapsed"
assert_grep '^T_RUN1 1'             "Space started the stopwatch"
assert_grep '^T_EL75 75'            "elapsed = 75 s after +75 monotonic seconds"
assert_grep '^T_RUN2 0'             "Space stopped the stopwatch"
assert_grep '^T_EL_HOLD 75'         "elapsed frozen at 75 while stopped"
assert_grep '^T_EL_RST 0'           "R reset the stopwatch to 0"
assert_grep '^T_RUN3 0'             "stopwatch stays stopped after reset"

# --- the three PNGs really exist -------------------------------------------
for f in clock cal timer; do
    if [ -s "$OUT/hc_$f.png" ]; then echo "[hamclock-host] PASS $OUT/hc_$f.png on disk";
    else echo "[hamclock-host] FAIL $OUT/hc_$f.png not written"; fail=1; fi
done

if [ "$fail" -ne 0 ]; then echo "[hamclock-host] OVERALL FAIL"; exit 1; fi
echo "[hamclock-host] OVERALL PASS"
