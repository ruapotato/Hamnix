#!/usr/bin/env bash
# scripts/test_de_cursor_nudge.sh — measure REAL cursor refresh Hz by
# driving the cursor through /dev/mouse (the canonical Plan 9 writable-mouse
# capability) and reading the compositor's own [de_perf] cursor_fps line.
#
# A.1 consolidation: the old in-guest `nudge`/`nudge_report` ctl verbs on
# /dev/wsys/ctl were RETIRED — they duplicated /dev/mouse (devmouse_write),
# which drives the SAME mouse_rx_push_abs input queue. Cursor-FPS now lives
# entirely in the compositor (user/hamUId.ad): it counts cursor-present
# events and emits "[de_perf] cursor_fps=N presents=X window_cs=Z" once per
# second, decoupled from how the mouse moved.
#
# Why this exists: the previous DE-perf harnesses (test_de_mouse_refresh.sh,
# test_de_fps.sh, test_de_multi_apps_load.sh) drive cursor motion through
# the QEMU monitor `mouse_move` HMP command. Under UEFI/OVMF + -vga std +
# virtio that command does NOT reach the guest input stack, so the perf
# numbers were noise instead of a cursor-refresh signal.
#
# This harness drives motion FROM INSIDE the guest:
#   1. Boot build/hamnix-kernel.elf via QEMU -kernel multiboot (the fast
#      path; matches test_de_runtime_smoke.sh).
#   2. Wait for the hamsh prompt.
#   3. Write N absolute-move lines to /dev/mouse:
#         echo "<ax> <ay> 0 0 1" > /dev/mouse
#      abs=1 → ax/ay are 0..32767 tablet coords, pushed via mouse_rx_push_abs
#      (devmouse_write). The compositor's /dev/mouse reader consumes each
#      event and re-presents the cursor.
#   4. The compositor emits "[de_perf] cursor_fps=N ..." once per second on
#      the serial log on its own — no report verb. Grep it and surface N.
#
# Skips cleanly when /dev/kvm is missing.
#
# Env overrides:
#   ELF                kernel ELF path   (default: build/hamnix-kernel.elf)
#   BOOT_WAIT          hamsh prompt wait s (default: 120)
#   NUDGE_COUNT        synthetic events  (default: 100)
#   NUDGE_GAP_MS       sleep between moves in ms (default: 20)
#   APPS_TO_OPEN       extra hamterm load (default: 0)
#   OUT_REPORT         summary path      (default: build/de_cursor_nudge.txt)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF="${ELF:-build/hamnix-kernel.elf}"
BOOT_WAIT="${BOOT_WAIT:-120}"
NUDGE_COUNT="${NUDGE_COUNT:-100}"
NUDGE_GAP_MS="${NUDGE_GAP_MS:-20}"
APPS_TO_OPEN="${APPS_TO_OPEN:-0}"
OUT_REPORT="${OUT_REPORT:-build/de_cursor_nudge.txt}"

# --- structural pre-check (always runs, even when no QEMU/boot path) ----
# These greps fail loud if a refactor silently drops the /dev/mouse
# absolute-write path or the compositor cursor-FPS emitter. They're the
# SAME shape every DE v2 guard uses: "the source carries the load-bearing
# breadcrumb."
DEVMOUSE=sys/src/9/port/devmouse.ad
HAMUID=user/hamUId.ad
struct_fail=0
if ! grep -aFq 'def devmouse_write(' "$DEVMOUSE"; then
    echo "[test_de_cursor_nudge] FAIL: structural marker missing: devmouse_write (in $DEVMOUSE)" >&2
    struct_fail=1
fi
if ! grep -aFq 'mouse_rx_push_abs(' "$DEVMOUSE"; then
    echo "[test_de_cursor_nudge] FAIL: structural marker missing: mouse_rx_push_abs (in $DEVMOUSE)" >&2
    struct_fail=1
fi
for marker in \
    'DE_CURSOR_PRESENTS' \
    '[de_perf] cursor_fps=' ; do
    if ! grep -aFq "$marker" "$HAMUID"; then
        echo "[test_de_cursor_nudge] FAIL: structural marker missing: $marker (in $HAMUID)" >&2
        struct_fail=1
    fi
done
if [ "$struct_fail" -ne 0 ]; then
    exit 1
fi
echo "[test_de_cursor_nudge] structural markers OK (/dev/mouse abs-write + compositor cursor_fps wired)."

# --- gates --------------------------------------------------------------
if [ ! -f "$ELF" ]; then
    echo "[test_de_cursor_nudge] SKIP: $ELF absent (build via test_de_runtime_smoke or build_user+build_modules+build_initramfs+adder compile init/main.ad)" >&2
    exit 0
fi
# Stale-artifact guard: a PRESENT-but-OLD kernel ELF is booted silently otherwise,
# which is exactly the 2026-07-24 false-negative class. See _installer_img.sh.
# shellcheck source=_installer_img.sh
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
installer_img_warn_if_stale "$ELF" "[de_cursor_nudge]"

# Probe the multiboot/VBE host-QEMU limit (project_qemu_multiboot_vbe_limit):
# QEMU 10.x rejects 64-bit kernel ELFs through -kernel because the stub
# advertises VBE. If we hit that, fall back to STRUCTURAL-only PASS — the
# orchestrator's authoritative UEFI/GOP gate
# (scripts/test_installer_de_runlevel5.sh) covers the live boot path.
if ! timeout 5 qemu-system-x86_64 -kernel "$ELF" -smp 1 -vga none -display none \
        -no-reboot -m 256M -monitor none -serial stdio < /dev/null \
        > /tmp/.nudge_probe.$$ 2>&1; then
    :
fi
if grep -q "multiboot knows VBE" /tmp/.nudge_probe.$$ 2>/dev/null; then
    rm -f /tmp/.nudge_probe.$$
    echo "[test_de_cursor_nudge] SKIP-RUNTIME: host QEMU rejects -kernel 64-bit ELF (multiboot/VBE limit); structural PASS recorded."
    mkdir -p "$(dirname "$OUT_REPORT")"
    {
        echo "test_de_cursor_nudge"
        echo "status=structural_only"
        echo "reason=qemu_multiboot_vbe_limit"
    } > "$OUT_REPORT"
    exit 0
fi
rm -f /tmp/.nudge_probe.$$

LOG=$(mktemp --tmpdir hamnix-de-nudge.XXXXXX.log)
FIFO=$(mktemp -u --tmpdir hamnix-de-nudge.XXXXXX).in
mkfifo "$FIFO"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$FIFO"
    if [ -n "${KEEP_LOG:-}" ]; then
        cp "$LOG" "${KEEP_LOG}" 2>/dev/null || true
    fi
    [ -n "${KEEP_LOG:-}" ] || rm -f "$LOG"
}
trap cleanup EXIT

# Keep FIFO open so QEMU stdin doesn't EOF when we close.
exec 4<>"$FIFO"
exec 3>"$FIFO"

KVM_FLAGS=""
if [ -e /dev/kvm ]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

# QEMU multiboot can't load a 64-bit ELF when -vga std requests the VBE
# extension on this host's QEMU 10.x (the standing limit recorded in
# project_qemu_multiboot_vbe_limit). Use -nographic, like the heartbeat
# test does: the cursor-FPS metric is event-driven (compositor printk on
# its cursor-present count) so it does NOT need a framebuffer.
qemu-system-x86_64 \
    -kernel "$ELF" \
    $KVM_FLAGS \
    -smp 2 \
    -vga none \
    -display none \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

wait_for() {
    local pat="$1" timeout="$2"
    local deadline=$(( SECONDS + timeout ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

echo "[test_de_cursor_nudge] waiting up to ${BOOT_WAIT}s for hamsh prompt..."
if ! wait_for 'hamsh\$' "$BOOT_WAIT"; then
    echo "[test_de_cursor_nudge] FAIL: hamsh prompt not seen in ${BOOT_WAIT}s" >&2
    tail -40 "$LOG" >&2
    exit 1
fi

# Wake the freshly-booted shell (drops first line).
printf 'echo MARK_NUDGE_READY\n' >&3
sleep 0.5
# Re-send if needed to ensure shell is responsive.
if ! wait_for 'MARK_NUDGE_READY' 10; then
    printf 'echo MARK_NUDGE_READY\n' >&3
    sleep 1
fi

# Optional extra load: spawn hamterm windows.
i=0
while [ "$i" -lt "$APPS_TO_OPEN" ]; do
    printf 'hamterm &\n' >&3
    sleep 0.3
    i=$((i + 1))
done
sleep 1

# Capture log offset so we only consider compositor cursor_fps lines emitted
# AFTER injection begins.
RESET_OFFSET=$(wc -c < "$LOG")

step=$(( 32767 / NUDGE_COUNT ))
if [ "$step" -lt 1 ]; then step=1; fi
GAP_SLEEP=$(awk -v ms="$NUDGE_GAP_MS" 'BEGIN{ printf "%.3f", ms/1000.0 }')

echo "[test_de_cursor_nudge] injecting ${NUDGE_COUNT} /dev/mouse abs moves (gap=${NUDGE_GAP_MS}ms)..."

INJ_START_NS=$(date +%s%N)

# Drive the cursor via /dev/mouse absolute moves: "<ax> <ay> 0 0 1".
n=0
while [ "$n" -lt "$NUDGE_COUNT" ]; do
    x=$(( n * step ))
    y=$(( (n * step) % 32768 ))
    printf 'echo "%d %d 0 0 1" > /dev/mouse\n' "$x" "$y" >&3 2>/dev/null || break
    sleep "$GAP_SLEEP" 2>/dev/null || sleep 0.02
    n=$((n + 1))
done

# Let the last events flush + let the compositor's once-per-second tick fire
# at least one [de_perf] cursor_fps line over the injection window.
sleep 2

# Wait for a cursor_fps line to actually appear in the log after injection.
deadline=$(( SECONDS + 10 ))
while [ "$SECONDS" -lt "$deadline" ]; do
    tail -c +$((RESET_OFFSET + 1)) "$LOG" | grep -aqE '^\[de_perf\] cursor_fps=' && break
    sleep 0.5
done

INJ_END_NS=$(date +%s%N)
WALL_WINDOW_S=$(awk -v s="$INJ_START_NS" -v e="$INJ_END_NS" 'BEGIN{ printf "%.3f", (e-s)/1.0e9 }')

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 4; kill -9 "$QEMU_PID" 2>/dev/null ) &
WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

mkdir -p "$(dirname "$OUT_REPORT")"
TAIL_LOG=$(tail -c +$((RESET_OFFSET + 1)) "$LOG")

# Pick the cursor_fps line with the largest N over the injection window (the
# compositor emits one per second; the busiest reflects the injection rate).
REPORT_LINE_A=$(printf '%s\n' "$TAIL_LOG" \
    | grep -aE '^\[de_perf\] cursor_fps=' \
    | sort -t= -k2 -n | tail -1 || true)

if [ -z "$REPORT_LINE_A" ]; then
    echo "[test_de_cursor_nudge] FAIL: no '[de_perf] cursor_fps=' line found" >&2
    echo "--- tail of serial log ---" >&2
    tail -60 "$LOG" >&2
    exit 1
fi

CURSOR_FPS=$(printf '%s' "$REPORT_LINE_A" | sed -nE 's/.*cursor_fps=([0-9]+).*/\1/p')
PRESENTS=$(printf '%s' "$REPORT_LINE_A" | sed -nE 's/.*presents=([0-9]+).*/\1/p')
WINDOW_CS=$(printf '%s' "$REPORT_LINE_A" | sed -nE 's/.*window_cs=([0-9]+).*/\1/p')

CURSOR_FPS=${CURSOR_FPS:-0}
PRESENTS=${PRESENTS:-0}
WINDOW_CS=${WINDOW_CS:-0}

{
    echo "test_de_cursor_nudge"
    echo "injected=$NUDGE_COUNT"
    echo "gap_ms=$NUDGE_GAP_MS"
    echo "apps_load=$APPS_TO_OPEN"
    echo "wall_window_s=$WALL_WINDOW_S"
    echo "compositor_window_cs=$WINDOW_CS"
    echo "presents=$PRESENTS"
    echo "cursor_fps=$CURSOR_FPS"
    echo "raw_report=$REPORT_LINE_A"
} > "$OUT_REPORT"

echo "[test_de_cursor_nudge] cursor_fps=$CURSOR_FPS presents=$PRESENTS window_cs=$WINDOW_CS"
echo "[test_de_cursor_nudge] report: $OUT_REPORT"
echo "[test_de_cursor_nudge] PASS"
exit 0
