#!/usr/bin/env bash
# scripts/capture_release_screenshots_batched.sh [out-root]
#
# Runs scripts/capture_release_screenshots.sh five times, six-ish apps per
# boot, into build/release_shots/<ts>/b1..b5.
#
# WHY BATCHES.  A launched app's window cannot be dismissed from the driver:
# `kill <pid>` does not unmap a scene client's window and the `free <wid>`
# ctl verb is hostowner-gated (a serial hamsh does not pass it).  Capturing
# all 26 launchers in ONE boot therefore ends with 26 overlapping windows —
# the later screenshots are unreadable and the per-app crop starts picking
# up neighbours.  Six per boot keeps the desktop legible.
#
# The first batch also captures the text evidence (app dir, /etc/desktop.icons,
# hpm list, free, uname) and the Applications-menu frames; the rest skip it.
set -u
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT" || exit 1
ROOT="${1:-build/release_shots/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$ROOT"

B1="audioplayer browser calculator calendar coindash"
B2="control-center editor files ham2048 hamchess"
B3="hamgamesnake haminput hammine hamsheet hamslides"
B4="hamsnake hamtetris hamwrite installer logviewer"
B5="notes packagemanager screenshot sysmon terminal videoplayer"

i=0
for batch in "$B1" "$B2" "$B3" "$B4" "$B5"; do
    i=$((i + 1))
    echo "===== batch $i: $batch"
    if [ "$i" = 1 ]; then
        env HAMNIX_SKIP_BUILD=1 OUT_DIR="$ROOT/b$i" ONLY="$batch" \
            MENU_FILTER="a" \
            bash scripts/capture_release_screenshots.sh
    else
        env HAMNIX_SKIP_BUILD=1 OUT_DIR="$ROOT/b$i" ONLY="$batch" \
            SKIP_TEXT=1 \
            bash scripts/capture_release_screenshots.sh
    fi
done
echo "===== batches complete under $ROOT"
