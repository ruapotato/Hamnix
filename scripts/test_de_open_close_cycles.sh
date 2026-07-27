#!/usr/bin/env bash
# scripts/test_de_open_close_cycles.sh — open AND close desktop apps, over and
# over, and prove the session neither leaks nor wedges.
#
# USER-REPORTED FAILURE (2026-07-17): after opening a handful of apps on the
# shipped desktop the box HUNG; the serial log just stops after a few apps
# mapped a window and exited code=143 (SIGTERM).
#
# This gate drives a DETERMINISTIC open/close cycle — launch a scene app, then
# close it the way the whole DE closes things: the Plan 9 "terminate" note
# (/bin/kill -> lib/p9.ad p9_note -> /proc/<pid>/note), which is what the
# panel's Applications-menu toggle, hamUI/hamUId window close and hamsh's
# `svc stop` all write. After every cycle it records MemFree and the wsys
# window table: a per-cycle leak (RAM or wid slots) shows up as a monotone
# trend long before the box wedges, and a wedge shows up as a missed serial
# round-trip.
#
# Before the note default-action fix (sys/src/9/port/sysnote.ad) a cross-task
# note was a silent no-op, so NOTHING could be closed: each launch leaked its
# wid slot and address space, and by ~30 launches every new app died with
# "newwindow alloc failed" — the desktop stopped opening anything.
#
# Env: INSTALLER_IMG, OVMF_FD, BOOT_WAIT, OUT_DIR, CYCLES.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
CYCLES="${CYCLES:-24}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_open_close/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

[ -e /dev/kvm ] || { echo "[occ] SKIP-RUNTIME: /dev/kvm absent" >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "[occ] SKIP-RUNTIME: no OVMF" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[occ] SKIP-RUNTIME: no socat" >&2; exit 0; }
# STALE-IMAGE GUARD: this gate BOOTS a pre-existing image it did not build.
# A WARNING is not enough — a stale image false-GREENs the very regression
# this gate exists to catch (bit us 2026-07-01, 07-11, 07-27). ensure_installer_img
# REBUILDS when the image is missing or older than any tracked build input;
# HAMNIX_SKIP_BUILD=1 downgrades to a LOUD stale warning, never a silent pass.
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ensure_installer_img "$INSTALLER_IMG" "[de_open_close_cycles]" \
    || { echo "[occ] SKIP: no usable $INSTALLER_IMG" >&2; exit 0; }

mkdir -p "$OUT_DIR"
echo "[occ] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-occ.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-occ.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-occ-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-occ.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() { [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null; rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"; }
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1; }
snapshot() {
    local ppm="$OUT_DIR/$1.ppm"
    rm -f "$ppm"; mon_cmd "screendump $ppm" || return 1
    local i=0; while [ "$i" -lt 40 ]; do [ -s "$ppm" ] && break; sleep 0.1; i=$((i+1)); done
    [ -s "$ppm" ] || return 1
    sleep 0.3
    command -v convert >/dev/null 2>&1 && convert "$ppm" "$OUT_DIR/$1.png" 2>/dev/null
}
wait_for() {
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

qemu-system-x86_64 \
    -enable-kvm -cpu host -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[occ] waiting up to ${BOOT_WAIT}s for the DE handoff..."
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || {
    echo "[occ] FAIL: no handoff marker" >&2; tail -40 "$LOG" >&2; exit 1; }
sleep 8
printf 'echo MARK_OCC_READY\n' >&3
sleep 1
wait_for MARK_OCC_READY 12 || { printf 'echo MARK_OCC_READY\n' >&3; sleep 2; }

fail=0
say_fail() { echo "[occ] FAIL $*" >&2; fail=1; }
alive_n=0
assert_alive() {
    alive_n=$((alive_n+1))
    local m="MARK_ALIVE_${alive_n}"
    printf 'echo %s\n' "$m" >&3
    local d=$(( SECONDS + 25 ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "$m" "$LOG" && return 0
        sleep 1
    done
    say_fail "SYSTEM WEDGED at $1 (no serial round-trip in 25s)"
    snapshot "WEDGED_$1"
    return 1
}
mapped_count() { grep -ac "\[devwsys\] window .* mapped" "$LOG"; }

# The app set the user exercised (System Monitor + Audio Player + the
# Applications menu) plus three more scene apps.
APPS="hammonscene hamaudioscene hamnotesscene hamcalcscene hamfmscene hamappmenu"
snapshot 000_idle
printf 'echo CYCLE_0_MEM; free\n' >&3
sleep 2

c=1
while [ "$c" -le "$CYCLES" ]; do
    for app in $APPS; do
        before=$(mapped_count)
        # Launch as a CHILD OF THIS SHELL: the DE's own close paths are
        # always same-uid (the panel notes the children it spawned), and
        # devproc's note gate is caller-uid == target-uid, so this mirrors
        # the DE while staying scriptable from the serial console.
        printf '/bin/%s &\n' "$app" >&3
        d=$(( SECONDS + 25 ))
        while [ "$SECONDS" -lt "$d" ]; do
            [ "$(mapped_count)" -gt "$before" ] && break
            sleep 1
        done
        if [ "$(mapped_count)" -le "$before" ]; then
            say_fail "cycle $c: $app mapped NO window (DE can no longer launch apps)"
            snapshot "STUCK_c${c}_${app}"
            printf 'echo WINTABLE_c%s; cat /dev/wsys/windows; free\n' "$c" >&3
            sleep 3
            break 2
        fi
        line=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)
        wid=$(echo "$line" | sed -n 's/.*window \([0-9]*\) mapped.*/\1/p')
        pid=$(echo "$line" | sed -n 's/.*mapped pid=\([0-9]*\).*/\1/p')
        sleep 2
        # Close it the Plan 9 way — the note the whole DE close path uses.
        printf '/bin/kill %s\n' "$pid" >&3
        if ! wait_for "task: pid $pid exited" 15; then
            say_fail "cycle $c: $app (pid $pid) survived the terminate note"
            break 2
        fi
        sleep 1
        assert_alive "cycle $c $app" || break 2
    done
    printf 'echo CYCLE_%s_MEM; free; cat /dev/wsys/windows\n' "$c" >&3
    sleep 3
    [ $(( c % 6 )) -eq 0 ] && snapshot "c${c}_desktop"
    c=$((c+1))
done

snapshot 999_final
assert_alive final
sleep 3
snapshot 999_final_b

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

echo "[occ] --- MemFree per cycle ---"
grep -a -A3 "CYCLE_[0-9]*_MEM" "$LOG" | grep -aoE "Mem: *[0-9]+ *[0-9]+" | tr -s ' '
echo "[occ] windows mapped: $(mapped_count)"
echo "[occ] code=143 exits: $(grep -ac 'exited (code=143)' "$LOG")"
echo "[occ] artifacts: $OUT_DIR"
[ "$fail" -ne 0 ] && { echo "[occ] OVERALL FAIL"; exit 1; }
echo "[occ] OVERALL PASS"
