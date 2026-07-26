#!/usr/bin/env bash
# scripts/test_sysmon_host.sh — FAST, QEMU-free host gate for the reworked
# MATE/Windows-Task-Manager System Monitor:
#   * the APP (lib/hammoncore.ad) renders a total+per-core CPU% history graph,
#     a memory history graph, and a PID/CPU%/COMMAND process list;
#   * the panel APPLET (lib/sysmonspark.ad) renders a rolling CPU+memory
#     sparkline.
# It feeds synthetic samples, rasterizes each scene to a PPM, converts to PNG
# (to VIEW), and asserts the graphs actually drew (white/green/blue strokes)
# and the process list shows the amber hot-process row. It also confirms the
# NATIVE app + panel still compile (they carry the click-opens-app wiring).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsysmon_host"
mkdir -p "$OUT"
fail=0

echo "[sysmon] compiling host harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsysmon_host.ad -o "$BIN" 2>"$OUT/sysmon_compile.log"; then
    echo "[sysmon] FAIL: host harness did not compile"; cat "$OUT/sysmon_compile.log"; exit 1
fi
echo "[sysmon] PASS host harness compiled -> $BIN"

echo "[sysmon] compiling NATIVE hammonscene (app) + hampanelscene (applet) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hammonscene.ad -o "$OUT/hammonscene_native.elf" 2>"$OUT/sysmon_app_native.log"; then
    echo "[sysmon] FAIL: native hammonscene did not compile"; cat "$OUT/sysmon_app_native.log"; exit 1
fi
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hampanelscene.ad -o "$OUT/hampanelscene_native.elf" 2>"$OUT/sysmon_panel_native.log"; then
    echo "[sysmon] FAIL: native hampanelscene did not compile"; cat "$OUT/sysmon_panel_native.log"; exit 1
fi
echo "[sysmon] PASS native app + panel compile"

# The click-opens-app wiring: the panel must spawn /bin/hammonscene when the
# sysmon widget is clicked.
if grep -q 'WK_SYSMON' user/hampanelscene.ad \
        && grep -A6 'if ak == WK_SYSMON' user/hampanelscene.ad | grep -q '/bin/hammonscene'; then
    echo "[sysmon] PASS click-opens-app wiring present (WK_SYSMON -> /bin/hammonscene)"
else
    echo "[sysmon] FAIL click-opens-app wiring missing"; fail=1
fi

DUMP="$OUT/sysmon_dump.txt"
if ! "$BIN" "$OUT" >"$DUMP" 2>&1; then
    echo "[sysmon] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

for f in sysmon_app sysmon_applet sysmon_applet_idle; do
    python3 scripts/ppm_to_png.py "$OUT/${f}.ppm" "$OUT/${f}.png" 2>"$OUT/sysmon_png.log" \
        && echo "[sysmon] PASS rendered $OUT/${f}.png" \
        || { echo "[sysmon] FAIL png conversion ($f)"; fail=1; }
done

# Assert a COUNT line exists and its value is >= a threshold.
assert_min() {
    local tag="$1" min="$2"
    local v
    v=$(awk -v t="$tag" '$1=="COUNT" && $2==t { print $3 }' "$DUMP")
    if [ -z "$v" ]; then
        echo "[sysmon] FAIL $tag: no COUNT emitted"; fail=1; return
    fi
    if [ "$v" -ge "$min" ]; then
        echo "[sysmon] PASS $tag = $v (>= $min)"
    else
        echo "[sysmon] FAIL $tag = $v (< $min)"; fail=1
    fi
}

# App: CPU graph has a white total line + green per-core line.
assert_min app_cpu_white   40
assert_min app_cpu_green   40
# App: memory graph has blue columns.
assert_min app_mem_blue    60
# App: process list shows the amber hot-process row.
assert_min app_proc_amber  20
# Applet: sparkline has green CPU columns + a blue memory line.
assert_min applet_cpu_green 60
assert_min applet_mem_blue  20

# Assert a COUNT line exists and its value is EXACTLY `want`.
assert_eq() {
    local tag="$1" want="$2"
    local v
    v=$(awk -v t="$tag" '$1=="COUNT" && $2==t { print $3 }' "$DUMP")
    if [ -z "$v" ]; then
        echo "[sysmon] FAIL $tag: no COUNT emitted"; fail=1; return
    fi
    if [ "$v" = "$want" ]; then
        echo "[sysmon] PASS $tag = $v (== $want)"
    else
        echo "[sysmon] FAIL $tag = $v (want $want)"; fail=1
    fi
}

# USER BUG "the cpu monitor in the bar has space between each reading so it
# looks like spikes not a graph": the filled series must be CONTINUOUS — zero
# blank columns between the first and last sample, in the panel applet AND in
# the app's memory area chart.
assert_eq applet_cpu_gap_cols 0
# ...and at IDLE (all-zero samples), where a 0%-draws-nothing series scattered
# into disconnected dots on the real desktop panel.
assert_eq applet_idle_gap_cols 0
assert_eq app_mem_gap_cols    0

# USER BUG "the system monitor app shows the apps by CPU% but in reverse
# order": heaviest process at the TOP. The harness feeds 4%,11%,73%,22% in
# pid order; after the sort row 0 must be the 73% pid-42 process and the CPU%
# column must be non-increasing downwards.
assert_eq app_proc_desc    1
assert_eq app_proc_top_cpu 73
assert_eq app_proc_top_pid 42

if [ "$fail" -ne 0 ]; then echo "[sysmon] OVERALL FAIL"; exit 1; fi
echo "[sysmon] OVERALL PASS"
