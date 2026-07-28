#!/usr/bin/env bash
# scripts/test_hamaudiobook_host.sh — FAST, QEMU-free host gate for the
# hamaudiobook player (the FIRST repo-only, NOT-preinstalled Hamnix app).
#
# Proves, in milliseconds with no audio hardware, the two DEFINING audiobook
# features plus the transport, all through the SAME pure core the native app
# ships (lib/hamaudiobookcore.ad, drawn via lib/hamscene.ad + rasterized by
# lib/hamui_host.ad):
#
#   1. RESUME / SAVE POSITION PER BOOK — the pure state-file serialize+lookup
#      (hamaudiobook_state_upsert / _lookup) does a save -> reopen -> resume
#      round trip, an UPDATE (re-save moves the offset, no dup), and MULTI-BOOK
#      (each path keeps its own offset). This is the on-disk resume logic the
#      native driver persists to /var/hamaudiobook.state.
#   2. SLEEP TIMER (night mode) — arm a 30-min preset against a synthetic clock
#      and assert it is NOT expired at 29 min and IS at 30/31 min, with the
#      remaining-time readout.
#   3. TRANSPORT — skip +-30s clamps; Play/Sleep button clicks route the right
#      commands; the scene rasterizes (before=idle+resume note, after=playing
#      mid-book with a lit blue progress bar + an armed-blue sleep button).
#   4. the NATIVE user/hamaudiobook.ad still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamaudiobook_host"
mkdir -p "$OUT"
fail=0

echo "[hamaudiobook-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamaudiobook_host.ad "$BIN" 2>"$OUT/hamaudiobook_compile.log"; then
    echo "[hamaudiobook-host] FAIL: host harness did not compile"; cat "$OUT/hamaudiobook_compile.log"; exit 1
fi
echo "[hamaudiobook-host] PASS host harness compiled -> $BIN"

echo "[hamaudiobook-host] compiling NATIVE hamaudiobook for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamaudiobook.ad "$OUT/hamaudiobook_native.elf" 2>"$OUT/hamaudiobook_native.log"; then
    echo "[hamaudiobook-host] FAIL: native hamaudiobook did not compile"; cat "$OUT/hamaudiobook_native.log"; exit 1
fi
echo "[hamaudiobook-host] PASS native hamaudiobook still compiles"

echo "[hamaudiobook-host] running host harness ..."
DUMP="$OUT/hamaudiobook_dump.txt"
BEFORE="$OUT/hamaudiobook_before.ppm"
AFTER="$OUT/hamaudiobook_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[hamaudiobook-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

# Render the PPMs to PNGs (saved for eyeballing).
for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hamaudiobook_$f.ppm" "$OUT/hamaudiobook_$f.png" 2>"$OUT/hamaudiobook_png.log"; then
        echo "[hamaudiobook-host] PASS rendered $OUT/hamaudiobook_$f.png ($(file -b "$OUT/hamaudiobook_$f.png" 2>/dev/null))"
    else
        echo "[hamaudiobook-host] FAIL png conversion ($f)"; cat "$OUT/hamaudiobook_png.log"; fail=1
    fi
done

field() { grep -E "^$1 " "$DUMP" | head -1 | awk '{print $2}'; }

expect() {  # expect <field> <want> <label>
    local got; got=$(field "$1")
    if [ "$got" = "$2" ]; then
        echo "[hamaudiobook-host] PASS $3: $1=$got"
    else
        echo "[hamaudiobook-host] FAIL $3: $1=$got (want $2)"; fail=1
    fi
}

# --- 1. RESUME round-trip ---
expect RESUME_EMPTY 0     "empty state has no saved position"
expect RESUME_A1 65000    "reopen book A resumes the saved 65s offset"
expect RESUME_A2 65000    "book A offset survives adding book B"
expect RESUME_B1 12000    "book B keeps its own 12s offset"
expect RESUME_A3 90000    "re-saving book A UPDATES its offset to 90s"
expect RESUME_B2 12000    "book B untouched by book A's update"
# The state file must hold exactly 2 records (no duplicate A) after the update.
NREC=$(awk '/^STATE-BEGIN$/{f=1;next} /^STATE-END$/{f=0} f' "$DUMP" | grep -c $'\t')
[ "$NREC" = "2" ] && echo "[hamaudiobook-host] PASS state file dedups to 2 records" || { echo "[hamaudiobook-host] FAIL state file has $NREC records (want 2)"; fail=1; }

# --- 2. SLEEP TIMER ---
expect SLEEP_PRESET 30        "preset cycles to 30 minutes"
expect SLEEP_ARMED 1          "arming the timer marks it armed"
expect SLEEP_EXP_AT_29M 0     "timer NOT expired at 29 min"
expect SLEEP_REMAIN_AT_29M 60000 "60s remaining at 29 min of a 30-min timer"
expect SLEEP_EXP_AT_30M 1     "timer EXPIRES at exactly 30 min"
expect SLEEP_EXP_AT_31M 1     "timer stays expired past 30 min"

# --- 3. skip +-30s clamps ---
expect SKIP_FWD_FROM_10S 40000   "skip +30s from 0:10 -> 0:40"
expect SKIP_BACK_FROM_10S 0      "skip -30s from 0:10 clamps to 0:00"
expect SKIP_FWD_NEAR_END 600000  "skip +30s near end clamps to duration"

# --- 3b. command routing ---
expect CMD_PLAY 1    "Play button enqueues play/pause"
expect CMD_SLEEP 6   "Sleep button enqueues sleep-timer cycle"

# --- 4. SCENE + RASTER proof ---
assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamaudiobook-host] PASS $2";
    else echo "[hamaudiobook-host] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_grep '^# scene v1 hamui'                      "scene header emitted"
assert_grep '^glyphs 12 8 \"Audiobook\"'             "bold Audiobook title"
assert_grep '^glyphs 20 44 \"dune.mp3\"'             "now-playing book name"
assert_grep '^glyphs [0-9]+ [0-9]+ \"Resumed at 1:05\"' "resume note shows the resumed offset"
assert_grep '^glyphs [0-9]+ [0-9]+ \"<<30\"'         "skip-back-30 button drawn"
assert_grep '^glyphs [0-9]+ [0-9]+ \"30>>\"'         "skip-fwd-30 button drawn"
assert_grep '^glyphs [0-9]+ [0-9]+ \"Sleep timer: 30m'  "sleep-timer label drawn"

# Raster: blue progress fill (#3d7dff=4029951) + armed sleep highlight (#25406a=2441322).
expect PIX_BAR 4029951    "progress bar rasterized blue"
expect PIX_SLEEP 2441322  "armed sleep button rasterized blue"

if [ "$fail" -eq 0 ]; then
    echo "[hamaudiobook-host] RESULT: PASS"
    exit 0
else
    echo "[hamaudiobook-host] RESULT: FAIL"
    exit 1
fi
