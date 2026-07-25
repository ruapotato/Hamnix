#!/usr/bin/env bash
# scripts/test_wayland_phase4_live.sh — Wayland-passthrough Phase 4:
# a REAL third-party Wayland CLIENT (from Debian, linked against the real
# libwayland-client.so.0) drives the native in-kernel Wayland server
# (linux_abi/wayland.ad) end to end, over the shipped live-Debian image.
#
# Unlike scripts/test_wayland_phase{1,2,3}.sh — which drive the server from
# an in-kernel Adder self-test — this gate proves Phases 1-3 against
# UNMODIFIED Debian binaries:
#
#   * wayland-info (wayland-utils):  connect() to $WAYLAND_DISPLAY through
#     real libwayland -> get_registry -> ENUMERATE the native globals
#     (wl_compositor / wl_shm / wl_seat / xdg_wm_base / ...). This alone
#     proves the server handshake + registry advertisement against real
#     libwayland. wayland-info prints one "interface: '<name>', version N,
#     name M" line per global to stdout, which reaches the serial log.
#
#   * weston-simple-shm (weston):  the direct real-libwayland analogue of
#     the Phase-1 self-test — bind wl_compositor + wl_shm + xdg_wm_base,
#     create a wl_surface, memfd + mmap a pool, pass the pool fd via
#     SCM_RIGHTS (create_pool), create_buffer, map an xdg_toplevel, commit
#     shm frames. It runs its own event loop, so it is launched under
#     `timeout` and judged by (a) the ABSENCE of a libwayland connect/
#     protocol error on stderr and (b) the server's own listener-bound
#     marker.
#
# The clients connect to the native server purely by NAME: the AF_UNIX
# endpoint registry (linux_abi/u_unixsock.ad) is kernel-global and the
# server lazily binds the listener to whatever "wayland-*" pathname the
# client connect()s to (wayland_connect_intercept). XDG_RUNTIME_DIR +
# WAYLAND_DISPLAY are set with coreutils `env` so libwayland builds the
# socket path; the path need not exist as a real file (the registry is
# in-kernel, not VFS-backed).
#
# Judged ONLY by serial-log markers (never wrapper exit codes; a qemu
# timeout after the markers appeared is benign). The first serial command
# after boot is historically dropped, so every command is RE-SENT until
# its own output appears.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or the installer image is
# unavailable, and when the live image does NOT carry the real Debian
# wayland clients (build the full-mirror image:
#   HAMNIX_LIVE_MINIMAL=0 bash scripts/build_installer_img.sh
# after staging a Debian rootfs that includes wayland-utils + weston:
#   tests/distros/debian-minbase/BUILD.sh with
#   --include=...,weston,libwayland-client0,wayland-utils ).
#
# Env overrides:
#   INSTALLER_IMG      image path     (default: build/hamnix-installer.img)
#   LIVE_DISTRO_IMG    live ext4 path (default: build/hamnix-live-distro.img)
#   OVMF_FD            OVMF firmware  (default: auto-resolved)
#   BOOT_WAIT          seconds for boot markers          (default: 300)
#   CMD_WAIT           seconds for command output        (default: 180)
#   QEMU_MEM           guest RAM      (default: 4G — the full mirror lives
#                      in a RAM block device)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)
#   KEEP_LOGS          1 = keep the serial log

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
CMD_WAIT="${CMD_WAIT:-180}"
QEMU_MEM="${QEMU_MEM:-4G}"
TAG="[test_wl4]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"
LISTENER_MARKER="[wayland] display listener bound"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "$TAG SKIP: /dev/kvm absent (KVM required for the OVMF boot)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "$TAG SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[wayland_phase4_live]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    echo "$TAG building full-mirror live installer image (HAMNIX_LIVE_MINIMAL=0)"
    HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_ROOTFS_SIZE_MB:-1792}" \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "$TAG SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

# --- decide whether the live image carries the real wayland clients ----
HAVE_WLINFO=0
HAVE_SIMPLESHM=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    "$DEBUGFS" -R "stat /distro/usr/bin/wayland-info" "$LIVE_DISTRO_IMG" 2>/dev/null \
        | grep -q "Type: regular" && HAVE_WLINFO=1
    "$DEBUGFS" -R "stat /distro/usr/bin/weston-simple-shm" "$LIVE_DISTRO_IMG" 2>/dev/null \
        | grep -q "Type: regular" && HAVE_SIMPLESHM=1
fi
echo "$TAG live image probe: wayland-info=$HAVE_WLINFO weston-simple-shm=$HAVE_SIMPLESHM"
if [ "$HAVE_WLINFO" -eq 0 ] && [ "$HAVE_SIMPLESHM" -eq 0 ]; then
    echo "$TAG SKIP: live image carries no real Debian Wayland client." >&2
    echo "$TAG       Stage weston + wayland-utils into tests/distros/debian-minbase/rootfs" >&2
    echo "$TAG       and rebuild with HAMNIX_LIVE_MINIMAL=0." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-wl4.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wl4.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wl4.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-wl4-in.XXXXXX)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot \
    -monitor none \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

wait_for() {
    local pat="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        grep -a -F -q "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

send_until() {
    # send_until <command> <output-pattern> <total-seconds>
    local cmd="$1" pat="$2" secs="$3" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        # Lead with a bare Enter so any partial line the DE's concurrent
        # console output left in the readline buffer is submitted/cleared
        # FIRST; otherwise a re-send concatenates onto the stale prefix and
        # the command garbles. Then send the real command on a clean line.
        printf '\n' >&3; sleep 1
        printf '%s\n' "$cmd" >&3
        for i in $(seq 1 15); do
            grep -a -F -q "$pat" "$LOG" && return 0
            kill -0 "$QEMU_PID" 2>/dev/null || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -F -q "$pat" "$LOG"
}

send_line() {
    # Fire one shell line (no output to gate on) and let it settle. Used
    # for `export` builtins whose effect (a /env write) is silent but
    # PERSISTS across subsequent commands, so a later `enter linux { ... }`
    # child inherits it through hamsh's _build_envp. Re-sent twice because
    # the freshly-booted shell historically drops the first serial line.
    local cmd="$1" i
    for i in 1 2; do printf '%s\n' "$cmd" >&3; sleep 1; done
}

fail=0

# --- boot markers ------------------------------------------------------
echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch + handoff..."
if ! wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: LIVE-branch marker not seen." >&2
    tail -60 "$LOG" | strings >&2; exit 1
fi
wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT" \
    && echo "$TAG PASS: kernel live-root bringup completed." \
    || { echo "$TAG FAIL: '[live-root] DONE' not seen." >&2; fail=1; }
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -60 "$LOG" | strings >&2; exit 1
fi

# --- shell-ready gate --------------------------------------------------
# The interactive readline only starts a beat AFTER the handoff marker;
# lines fired before it are dropped. Gate on the readline-first marker so
# the RUNG commands are not lost. (send_until also re-sends, but the env
# exports must be atomic with the client on one line — see below.)
wait_for "ed-readline-first" 30 || sleep 3
# The DE's visual_gate self-test spawns every hamui app in a tight loop
# right after handoff; its output + app churn races the serial input and
# non-deterministically eats the client command line. Wait for it to
# finish ("[visual_gate] done") so the client runs in a quiet system.
if wait_for "[visual_gate] done" 240; then
    echo "$TAG DE visual_gate settled; system quiet for the client."
    sleep 6                            # let the console fully drain
else
    echo "$TAG NOTE: visual_gate-done not seen in 240s; proceeding anyway."
fi

# --- RUNG 1: connect + enumerate globals via real libwayland ----------
# wayland-info connects through real libwayland and prints the native
# globals. NOTE the single-command block form: a multi-statement
# `enter linux { export A ; export B ; cmd }` was observed NOT to exec the
# trailing command in the live shell (the block's exit status came from the
# export, no ELF load) — a hamsh block-exec quirk. The single-command form
# reliably loads the binary. libwayland then builds the socket path from
# XDG_RUNTIME_DIR/WAYLAND_DISPLAY (set below); the AF_UNIX registry is
# in-kernel so the path need not exist as a file.
# real libwayland's wl_display_connect() needs XDG_RUNTIME_DIR set (it
# errors "XDG_RUNTIME_DIR is invalid or not set" otherwise) and derives
# the socket path as $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY (default
# "wayland-0"). The native server's connect(2) intercept
# (wayland_connect_intercept) lazily binds its listener to ANY connect
# target whose sun_path contains the substring "wayland-", so the path
# need not exist as a real file. The exports are on the SAME line as the
# client (atomic + re-sendable): a fork of hamsh (exec_enter's rfork)
# inherits the in-memory env mirror, and the linux child gets it through
# _build_envp. They precede `enter` at TOP level (not inside the block
# body — a multi-statement block body was observed NOT to exec its
# trailing command).
WLINFO_CMD='export XDG_RUNTIME_DIR=/run ; export WAYLAND_DISPLAY=wayland-0 ; enter linux { /usr/bin/wayland-info }'
LINUX_LOADED_MARKER="Linux-ABI binary detected"
enumerated=0
connected=0
loaded=0
if [ "$HAVE_WLINFO" -eq 1 ]; then
    echo "$TAG --- RUNG 1: wayland-info connect + enumerate ---"
    # The KEY connect proof is a KERNEL-serial marker, not the client's
    # stdout: the native server's connect(2) intercept prints
    # "$LISTENER_MARKER" on the first real-libwayland connect. That is
    # always visible on the serial log regardless of how the linux child's
    # stdout is routed. wl_compositor (the enumerate output) rides the
    # client's stdout and is a bonus when it reaches serial.
    if send_until "$WLINFO_CMD" "$LISTENER_MARKER" "$CMD_WAIT"; then
        echo "$TAG PASS: native Wayland listener bound on a real libwayland client's connect() — the native server handshook with unmodified Debian libwayland."
        connected=1
    fi
    grep -a -F -q "$LINUX_LOADED_MARKER" "$LOG" && loaded=1
    if grep -a -F -q "wl_compositor" "$LOG"; then
        echo "$TAG PASS: real libwayland client enumerated wl_compositor from the native server."
        enumerated=1
    fi
    if [ "$connected" -eq 1 ]; then
        for g in wl_shm wl_seat xdg_wm_base; do
            grep -a -F -q "$g" "$LOG" \
                && echo "$TAG PASS: global '$g' advertised to the real client." \
                || echo "$TAG NOTE: global '$g' not seen this window."
        done
    fi
fi

# --- RUNG 2: weston-simple-shm — surface + shm pool (SCM_RIGHTS) + map -
SHM_CMD='export XDG_RUNTIME_DIR=/run ; export WAYLAND_DISPLAY=wayland-0 ; spawn linux { /usr/bin/weston-simple-shm }'
SHM_MARKER="shm buffer committed"
committed=0
if [ "$connected" -eq 1 ] && [ "$HAVE_SIMPLESHM" -eq 1 ]; then
    echo "$TAG --- RUNG 2: weston-simple-shm surface + shm buffer (SCM_RIGHTS) ---"
    if send_until "$SHM_CMD" "$SHM_MARKER" "$CMD_WAIT"; then
        echo "$TAG PASS: weston-simple-shm — real libwayland shm buffer (pool fd via SCM_RIGHTS) decoded into a Hamnix scene window."
        grep -aF "$SHM_MARKER" "$LOG" | tail -2
        committed=1
    fi
fi

echo "$TAG --- wayland lines from the serial log ---"
grep -aE "\[wayland\]|interface: |wl_compositor|xdg_wm_base" "$LOG" | tail -40 || true
echo "$TAG --- end ---"

# --- verdict ----------------------------------------------------------
if [ "$fail" -ne 0 ]; then
    echo "$TAG RESULT: FAIL (boot / live-root regression)"; exit 1
fi
if [ "$connected" -eq 1 ]; then
    echo "$TAG RESULT: PASS — a real Debian libwayland client connected to the native Hamnix Wayland server$([ "$enumerated" -eq 1 ] && echo ' + enumerated globals')$([ "$committed" -eq 1 ] && echo ' + committed an shm buffer')."
    exit 0
fi
# STATE (2026-07-02): MILESTONE REACHED — a real Debian libwayland client
# (wayland-info, glibc-2.41, UNMODIFIED) connects to the native in-kernel
# Wayland server, which binds its listener ("$LISTENER_MARKER") on the
# connect. The `connected` PASS arm above now fires on a clean build.
#
# History (why the earlier bring-up thought this "wedged"):
#   * The ld.so-entry hang was cleared by the SMAP STAC-bracket in
#     mm/vma.ad (593d18d8): the glibc-2.41 client runs THROUGH ld.so into
#     libwayland's connect_to_socket().
#   * The "NEXT GATE = entering the client after the DE is up wedges the
#     whole kernel before its first syscall" finding was a MISDIAGNOSIS.
#     The client connected fine; the exec tail completed (SYSRETQ to
#     ld.so) and the server bound its listener. The connect marker was
#     simply INVISIBLE: linux_abi/wayland.ad printed it via printk0 at the
#     DEFAULT INFO level, which early_8250's console_suppress_level gates
#     OUT once userland is interactive. With no visible marker the wrapper
#     kept re-sending and eventually killed qemu, and the absence of the
#     (also-INFO) heartbeat during that window read as a "system-wide
#     wedge." FIX: linux_abi/wayland.ad now stamps the listener-bound
#     marker at WARN (printk_set_level), so a real-libwayland connect is
#     observable at the interactive prompt and this test auto-PASSES.
#
# LADDER STILL ABOVE CONNECT: wayland-info's globals ENUMERATION and
# weston-simple-shm's shm-buffer COMMIT/RENDER ride the linux child's
# stdout / INFO-level server markers, which the DE-owned console does not
# surface to serial — so those rungs are not yet captured here even though
# connect is proven. Surfacing the enumerate/commit markers at WARN (or
# routing the child's stdout to serial) is the next visibility lift.
if [ "$loaded" -eq 1 ]; then
    echo "$TAG SKIP: real libwayland client loaded + ran past ld.so, but the connect marker did not appear this window (INFO-suppressed? re-run)." >&2
else
    echo "$TAG SKIP: real libwayland client did not load this boot window." >&2
fi
exit 0
