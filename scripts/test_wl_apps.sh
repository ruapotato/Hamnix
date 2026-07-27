#!/usr/bin/env bash
# scripts/test_wl_apps.sh — boot the full-mirror live image ONCE and bring up a
# BROAD set of simple single-process Wayland GUI apps (staged by
# scripts/stage_wl_apps.sh) as native clients of the in-kernel Wayland server:
#   weston-simple-damage, weston-flower, weston-eventdemo, weston-clickdot,
#   and `foot` (an independent-toolkit wl terminal).
# For each app it: launches it in the Linux ns (WAYLAND_DISPLAY=wayland-0,
# XDG_RUNTIME_DIR=/run), waits for a NEW "shm buffer committed" marker (the
# app mapped + committed a wl_shm buffer → the compositor painted a window),
# and screendumps the framebuffer to a PNG. KVM/OVMF only; kills only its own
# qemu (tracked by PID). A bring-up probe: reports per-app render verdicts.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$PROJ_ROOT"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-360}"; CMD_WAIT="${CMD_WAIT:-120}"; QEMU_MEM="${QEMU_MEM:-3G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"; TAG="[test_wl_apps]"
LIVE_MARKER="booting LIVE environment"; HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"; COMMIT_MARKER="shm buffer committed"

[ -e /dev/kvm ] || { echo "$TAG SKIP: /dev/kvm absent." >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP: socat missing." >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && OVMF_FD="$c" && break; done; fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP: OVMF not found." >&2; exit 0; }
# STALE-IMAGE GUARD: this gate BOOTS a pre-existing image it did not build.
# A WARNING is not enough — a stale image false-GREENs the very regression
# this gate exists to catch (bit us 2026-07-01, 07-11, 07-27). ensure_installer_img
# REBUILDS when the image is missing or older than any tracked build input;
# HAMNIX_SKIP_BUILD=1 downgrades to a LOUD stale warning, never a silent pass.
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ensure_installer_img "$INSTALLER_IMG" "[wl_apps]" \
    || { echo "[wl_apps] SKIP: no usable $INSTALLER_IMG" >&2; exit 0; }

OVMF_RW=$(mktemp --tmpdir hamnix-wlapps.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wlapps.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wlapps.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-wlapps-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-wlapps-mon.XXXXXX.sock)
mkfifo "$FIFO"; cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
cleanup(){ [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null; exec 3>&- 2>/dev/null; rm -f "$OVMF_RW" "$IMG_RW" "$FIFO" "$MON"; [ "${KEEP_LOGS:-0}" = 1 ] || rm -f "$LOG"; }
trap cleanup EXIT

qemu-system-x86_64 -enable-kvm -cpu host -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio -m "$QEMU_MEM" \
    -vga std -display none -no-reboot -monitor "unix:$MON,server,nowait" \
    -serial stdio < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!; exec 3> "$FIFO"
mon(){ printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" 2>/dev/null; }
send(){ printf '%s\n' "$1" >&3; }
wait_for(){ local p="$1" s="$2" i; for i in $(seq 1 "$s"); do grep -aFq "$p" "$LOG" && return 0; kill -0 "$QEMU_PID" 2>/dev/null || return 1; sleep 1; done; return 1; }

echo "$TAG waiting up to ${BOOT_WAIT}s for LIVE + handoff..."
wait_for "$LIVE_MARKER" "$BOOT_WAIT" || { echo "$TAG FAIL: no LIVE marker." >&2; tail -40 "$LOG"|strings >&2; exit 1; }
wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT" && echo "$TAG live-root DONE." || echo "$TAG WARN: live-root not seen." >&2
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || { echo "$TAG FAIL: no handoff." >&2; tail -40 "$LOG"|strings >&2; exit 1; }
wait_for "ed-readline-first" 30 || sleep 3
if wait_for "[visual_gate] done" 240; then echo "$TAG visual_gate settled."; sleep 6; else echo "$TAG NOTE: visual_gate-done not seen; proceeding."; fi

# Persist the client environment ONCE on the shell (survives subsequent lines).
send 'export XDG_RUNTIME_DIR=/run ; export WAYLAND_DISPLAY=wayland-0 ; export XDG_CONFIG_HOME=/run ; export XDG_CACHE_HOME=/etc/fonts/cache ; export SHELL=/bin/sh ; export TERM=foot'
sleep 2

# ONE app per boot: the in-kernel compositor is single-threaded, and an
# animated client (simple-damage/flower) commits ~90 fps forever, starving
# every other client's first buffer-commit. Killing a spawn handle does NOT
# reliably reap a linux-ns wl client, so instead we boot fresh for each app
# (the caller sets APPS to a single "name=/path" spec, or a list to chain).
launch_and_shot(){
    local name="$1" cmd="$2"
    echo "$TAG ============ APP: $name ============"
    local pre; pre=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null | head -1)
    send "spawn linux { $cmd }"
    local got=0 i
    for i in $(seq 1 "$CMD_WAIT"); do
        kill -0 "$QEMU_PID" 2>/dev/null || break
        local now; now=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null | head -1)
        [ "$now" -gt "$pre" ] && { got=1; break; }
        sleep 1
    done
    local wid; wid=$(grep -aF "$COMMIT_MARKER" "$LOG" | tail -1 | grep -aoE 'wid [0-9]+' | awk '{print $2}')
    if [ "$got" = 1 ]; then echo "$TAG PASS render: $name committed a wl_shm buffer (wid ${wid:-?})"; else echo "$TAG WARN: $name did not commit an shm buffer in ${CMD_WAIT}s"; fi
    sleep 3
    local ppm="$OUTDIR/wlapp_${name}.ppm" png="$OUTDIR/wlapp_${name}.png"
    rm -f "$ppm" "$png"; mon "screendump $ppm" >/dev/null; sleep 1
    if command -v pnmtopng >/dev/null 2>&1 && [ -s "$ppm" ]; then pnmtopng "$ppm" > "$png" 2>/dev/null && echo "$TAG PNG: $png"; fi
    echo "$TAG serial (recent app-relevant lines):"; grep -aiE "registry advertised|wl-req|shm buffer committed|xdg get|configure|ack_configure|error|fail|abort|segv|fault|assert|cursor" "$LOG" | grep -avE "hamsh\\$|export XDG" | sed 's/\[K.*//' | tail -12 || true
    RESULTS+=("$name:$got:${wid:-?}")
}

declare -a RESULTS
# APPS: space-separated "name=/abs/path" specs. Default = the full sweep, but
# the caller normally passes ONE spec per boot (see rationale above).
APPS="${APPS:-weston-simple-damage=/usr/bin/weston-simple-damage foot=/usr/bin/foot weston-flower=/usr/bin/weston-flower weston-eventdemo=/usr/bin/weston-eventdemo weston-clickdot=/usr/bin/weston-clickdot}"
for spec in $APPS; do
    launch_and_shot "${spec%%=*}" "${spec#*=}"
done

echo "$TAG ================= VERDICT ================="
for r in "${RESULTS[@]}"; do
    IFS=: read -r n g w <<<"$r"
    echo "$TAG   $n : render=$([ "$g" = 1 ] && echo YES || echo no) wid=$w"
done
echo "$TAG screendumps in $OUTDIR/wlapp_*.png"
exit 0
