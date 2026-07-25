#!/usr/bin/env bash
# scripts/test_de_desktop_label_budget_host.sh — QEMU-free host gate: a FULL
# desktop launcher set must render its ICON LABELS, not just the icons.
#
# THE BUG THIS GATES. The wallpaper mosaic, the icons and the icon labels all
# share ONE 16384-byte scene display list (HAMSCENE_CAP == the kernel's
# WSYS_SCENE_SIZE). Labels are emitted LAST, and each label line used to cost
# SIX glyph runs (a 4-way outline + drop shadow + the white text). With the 16
# shipped launchers — most of them two-line labels ("Word Processor", "Package
# Manager", ...) — the list overflowed and hamscene silently dropped the tail:
# the desktop rendered a grid of icons with NO TEXT UNDER THEM. Cheap two-run
# labels + a bigger icon reserve (WP_ICON_RESERVE) fixed it.
#
# WHAT IT ASSERTS (host, via the Python seed compiler — no QEMU):
#   hamdesktop --scene-dump <file> --stress --wall builds the WORST case —
#   MAX_ICONS icons whose labels all wrap onto two lines, over a wallpaper
#   whose every mosaic cell is a different colour (no run-coalescing) — and
#     * the display list stays inside HAMSCENE_CAP (16384), and
#     * EVERY label line is present: 2 glyph runs x 2 lines x 16 icons = 64.
#
# SKIPS CLEANLY when the Python seed compiler is unavailable.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="build/host/de_label_budget"
CAP=16384
WANT_RUNS=64

python3 -c 'import compiler.adder' >/dev/null 2>&1 || {
    echo "[labelbudget] SKIP: Python seed compiler unavailable" >&2; exit 0; }

mkdir -p "$OUT"
echo "[labelbudget] compiling hamdesktop for the host ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamdesktop.ad -o "$OUT/hamdesktop" >"$OUT/compile.log" 2>&1; then
    echo "[labelbudget] FAIL: hamdesktop did not compile" >&2
    tail -20 "$OUT/compile.log" >&2; exit 1
fi

DUMP="$OUT/stress.scene"
rm -f "$DUMP"
if ! "$OUT/hamdesktop" --scene-dump "$DUMP" --stress --wall > "$OUT/run.log" 2>&1; then
    echo "[labelbudget] FAIL: --scene-dump --stress --wall run failed" >&2
    cat "$OUT/run.log" >&2; exit 1
fi
[ -s "$DUMP" ] || { echo "[labelbudget] FAIL: empty display list" >&2; exit 1; }

bytes=$(wc -c < "$DUMP")
runs=$(strings -n 3 "$DUMP" | grep -c '^glyphs ')

fail=0
if [ "$bytes" -le "$CAP" ]; then
    echo "[labelbudget] PASS display list $bytes bytes <= cap $CAP"
else
    echo "[labelbudget] FAIL display list $bytes bytes EXCEEDS cap $CAP" >&2; fail=1
fi
if [ "$runs" -ge "$WANT_RUNS" ]; then
    echo "[labelbudget] PASS all label glyph runs emitted ($runs >= $WANT_RUNS)"
else
    echo "[labelbudget] FAIL only $runs label glyph runs emitted (want $WANT_RUNS)" >&2
    echo "[labelbudget]   -> the scene budget dropped icon labels again" >&2
    fail=1
fi

[ "$fail" -eq 0 ] || { echo "[labelbudget] RESULT: FAIL" >&2; exit 1; }
echo "[labelbudget] RESULT: PASS (artifacts in $OUT)"
exit 0
