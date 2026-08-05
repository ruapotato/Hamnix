#!/usr/bin/env bash
# scripts/test_track_boot_armed.sh — prove, ON DEVICE, that the kernel page
# tracker is armed THROUGH BRINGUP (leak pass 22).
#
# WHY THIS GATE EXISTS. For twenty-one leak passes the tracker was
# default-OFF and armed by `echo track full > /proc/meminfo` from a shell
# that only exists once boot is over. Everything allocated during bringup —
# the densest allocation window the system has — was therefore invisible,
# and its frames landed in site 0 (PA_SITE_UNKNOWN) where they funded a
# "re-attribution credit" that made three separate findings INCONCLUSIVE
# (docs/leak_pass21_n_sample_census.md §6.3, which names arming at boot as
# the highest-value item the campaign has left).
#
# WHAT IS ASSERTED, all read from inside the booted guest:
#
#   * The kernel printed its boot-arm marker during bringup, BEFORE the
#     shell handoff — i.e. the arm is on the boot path, not a late write.
#   * /proc/meminfo reports PgTrackBoot: 1. This is the file interface, not
#     a syscall: capabilities are files.
#   * The cumulative alloc counters sum to a number far larger than the
#     live page count. That is the actual proof of coverage: those allocs
#     could only have been counted by a tracker that was already running
#     while bringup allocated them.
#   * Site 0 (UNKNOWN) is a small fraction of the live population. Under
#     late arming site 0 WAS the live population.
#   * The deep-audit knob is OFF, so the per-reap/per-execve page-table
#     walk is not silently enabled on every boot.
#
# 0 GUEST MARKERS IS INCONCLUSIVE, NOT PASS. Every assertion below is
# reached only after a marker proving the guest actually answered; a run
# that produces no guest output exits 125 (inconclusive), never 0.
set -uo pipefail

TAG="[trkboot]"
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
OUT_DIR="${OUT_DIR:-build/track_boot_armed}"
HANDOFF_MARKER="handing off to interactive shell"

[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP-RUNTIME: no $INSTALLER_IMG" >&2; exit 0; }

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    # UNIFIED images FIRST. OVMF_CODE*.fd is a split CODE/VARS pair and
    # cannot be handed to `-bios` — QEMU rejects it with "could not load PC
    # BIOS", the guest never starts, and the gate reports "no handoff
    # marker" as though the KERNEL were broken. Preferring the split image
    # turns this whole gate dark on any host that has both.
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd \
             /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP-RUNTIME: no OVMF" >&2; exit 0; }

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/serial.log"
OVMF_RW=$(mktemp --tmpdir hamnix-tb.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-tb.img.XXXXXX.raw)
MON=$(mktemp --tmpdir -u hamnix-tb-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-tb.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own QEMU, by recorded pid. NEVER a pattern kill — a
    # sibling agent's boot is not ours to end.
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
}
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

wait_for() {
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

BOOT_T0=$(date +%s)
qemu-system-x86_64 \
    -enable-kvm -cpu host -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "$TAG waiting up to ${BOOT_WAIT}s for the shell handoff..."
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG INCONCLUSIVE: no handoff marker in ${BOOT_WAIT}s" >&2
    tail -40 "$LOG" >&2
    exit 125
fi
BOOT_S=$(( $(date +%s) - BOOT_T0 ))
echo "$TAG boot-to-handoff: ${BOOT_S}s"

sleep 8
# hamsh drops the FIRST serial command; burn one on a ready marker.
printf 'echo MARK_TB_READY\n' >&3
sleep 1
wait_for MARK_TB_READY 12 || { printf 'echo MARK_TB_READY\n' >&3; sleep 2; }
if ! grep -aq MARK_TB_READY "$LOG"; then
    echo "$TAG INCONCLUSIVE: guest shell never answered — 0 guest markers" >&2
    exit 125
fi

send() {
    local cmd="$1" mark="$2" to="${3:-30}"
    printf '%s; echo %s\n' "$cmd" "$mark" >&3
    local d=$(( SECONDS + to ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "^${mark}" "$LOG" && { sleep 1; return 0; }
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

send "cat /proc/meminfo" TB_MI 90 || {
    echo "$TAG INCONCLUSIVE: reading /proc/meminfo timed out" >&2; exit 125; }

sleep 2
kill "$QEMU_PID" 2>/dev/null
QEMU_PID=""

python3 scripts/track_boot_armed_report.py "$LOG" "$BOOT_S"
rc=$?
echo "$TAG report exit $rc"
exit $rc
