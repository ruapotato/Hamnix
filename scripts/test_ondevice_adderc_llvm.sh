#!/usr/bin/env bash
# scripts/test_ondevice_adderc_llvm.sh
#
# PHASE-1 GATE (on-device self-compiling): prove that a user on a booted
# HamnixOS can COMPILE + LINK + RUN an Adder program ON-DEVICE, using the
# LLVM/clang toolchain staged into the Debian / Linux-ABI namespace.
#
# This is the full end-to-end on-device story that Phase-0b
# (test_ondevice_hostac_llvm.sh — host_ac emits .ll on-device) set up:
#
#   enter linux { adderc /hello.ad -o /hello }   # host_ac emits .ll,
#                                                # clang codegen+links -static
#   enter linux { /hello }                       # runs it; exit 42
#
# WHAT IT STAGES (HAMNIX_STAGE_CLANG=1, wired in build_rootfs_img.py::
# _stage_clang_toolchain): host_ac (self-hosted Adder compiler), clang-19 +
# its libLLVM/libclang-cpp/GNU-ld DT_NEEDED closure (~250 MiB), the crt/
# static-lib objects for a -static link, a pre-built adder_llvm_runtime.o,
# and the /usr/bin/adderc driver script. All live in #distro next to
# apt/dpkg/busybox — the Linux namespace.
#
# HEADLINE the gate reports: the serial line
#   ADRC_RESULT cc=<rc> run=<exit> elf=<bytes>
# PASS iff cc=0 (adderc compiled+linked) AND run=42 (the built binary ran
# and returned tests/phase0b_hello.ad's known value). A clean FAILURE with a
# precise root cause (clang ENOSYS under the shim, a missing crt/lib, an OOM,
# a link error) is itself the valuable Phase-1 finding — pin it and stop.
#
# Judged ONLY by serial-log markers. Modelled on scripts/
# test_ondevice_hostac_llvm.sh (same boot/keystroke discipline).
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the installer image, host_ac,
# a host clang, or busybox is unavailable and cannot be built.
#
# Env overrides mirror test_ondevice_hostac_llvm.sh, plus:
#   QEMU_MEM  guest RAM (default 5G — clang's ~240 MiB closure + the live
#             RAM ext4 (now ~250 MiB heavier) + clang's own heap need room)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
CMD_WAIT="${CMD_WAIT:-360}"
QEMU_MEM="${QEMU_MEM:-5G}"
TAG="[test_ondevice_adderc_llvm]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "$TAG SKIP: /dev/kvm absent (KVM required for the OVMF boot)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for f in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$f" ] && { OVMF_FD="$f"; break; }
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "$TAG SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v clang-19 >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
    echo "$TAG SKIP: no host clang (apt install clang-19) to stage" >&2
    exit 0
fi

# --- ensure host_ac.elf exists ----------------------------------------
if [ ! -x build/cutover/host_ac.elf ]; then
    echo "$TAG bootstrapping build/cutover/host_ac.elf (self-hosted compiler)"
    ADDER_CC=adder source "$PROJ_ROOT/scripts/_adder_cc.sh"
    if ! adder_cc_bootstrap || [ ! -x build/cutover/host_ac.elf ]; then
        echo "$TAG SKIP: could not bootstrap host_ac.elf" >&2
        exit 0
    fi
fi

# --- ensure the busybox fixture (for /bin/sh in #distro) --------------
if [ ! -f tests/u-binary/u_busybox_musl ]; then
    echo "$TAG building u_busybox_musl fixture (musl static-PIE)"
    if ! make -C tests/u-binary/src/musl_busybox install >/dev/null 2>&1; then
        echo "$TAG SKIP: u_busybox_musl absent and could not be built" >&2
        exit 0
    fi
fi

# --- rebuild the installer image with the clang toolchain staged ------
if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
    [ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG absent + HAMNIX_SKIP_BUILD=1" >&2; exit 0; }
else
    echo "$TAG rebuilding installer image with HAMNIX_STAGE_CLANG=1 (~8 min, ~250 MiB clang closure)"
    HAMNIX_STAGE_CLANG=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG unavailable" >&2; exit 0; }

# --- confirm the live image carries adderc + clang --------------------
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    for f in /distro/usr/bin/adderc /distro/usr/bin/clang-19 \
             /distro/usr/bin/host_ac /distro/usr/bin/ld; do
        if "$DEBUGFS" -R "stat $f" "$LIVE_DISTRO_IMG" 2>/dev/null | grep -q "Type: regular"; then
            echo "$TAG live probe: $f present"
        else
            echo "$TAG FAIL: $f NOT staged into the live #distro" >&2
            exit 1
        fi
    done
fi

OVMF_RW=$(mktemp --tmpdir hamnix-adrc.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-adrc.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-adrc.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-adrc-in.XXXXXX)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"
}
trap cleanup EXIT

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot -monitor none \
    -serial stdio < "$FIFO" > "$LOG" 2>&1 &
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
    local cmd="$1" pat="$2" secs="$3" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        printf '%s\n' "$cmd" >&3
        for i in $(seq 1 15); do
            grep -a -F -q "$pat" "$LOG" && return 0
            kill -0 "$QEMU_PID" 2>/dev/null || return 1
            sleep 1; waited=$((waited + 1)); [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -F -q "$pat" "$LOG"
}

fail=0
echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch + handoff..."
wait_for "$LIVE_MARKER" "$BOOT_WAIT" || { echo "$TAG FAIL: LIVE-branch marker not seen." >&2; tail -80 "$LOG" | strings >&2; exit 1; }
echo "$TAG PASS: rc.boot took the LIVE branch."
wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT" || { echo "$TAG WARN: '[live-root] DONE' not seen." >&2; }
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || { echo "$TAG FAIL: handoff marker not seen." >&2; tail -80 "$LOG" | strings >&2; exit 1; }
echo "$TAG PASS: interactive handoff reached."

# --- THE PHASE-1 RUN: adderc compiles+links+runs on-device ------------
echo "$TAG --- adderc /hello.ad -o /hello inside enter linux { } ---"
# Assemble the marker so the typed line never contains 'ADRC_RESULT'.
RUN='cd /; adderc /hello.ad -o /hello >/tmp/ac.out 2>/tmp/ac.err; cc=$?; /hello; rr=$?; sz=$(/bin/wc -c < /hello 2>/dev/null); [ -z "$sz" ] && sz=NONE; /bin/printf "ADRC%s cc=%s run=%s elf=%s\n" _RESULT "$cc" "$rr" "$sz"'
if send_until "enter linux { /bin/sh -c '$RUN' }" "ADRC_RESULT" "$CMD_WAIT"; then
    LINE=$(grep -a -F "ADRC_RESULT" "$LOG" | grep -v "/bin/printf" | tail -1)
    echo "$TAG serial result: $LINE"
    CC=$(printf '%s\n' "$LINE" | sed -n 's/.*cc=\([0-9]*\).*/\1/p' | tail -1)
    RR=$(printf '%s\n' "$LINE" | sed -n 's/.*run=\([0-9]*\).*/\1/p' | tail -1)
    if [ "${CC:-X}" = "0" ] && [ "${RR:-X}" = "42" ]; then
        echo "$TAG PASS: adderc COMPILED+LINKED an Adder program on-device and"
        echo "$TAG       the produced binary RAN (exit 42) — on-device self-"
        echo "$TAG       compiling via LLVM/clang in the Linux namespace WORKS."
    else
        echo "$TAG FAIL: on-device compile/run did not succeed (cc=${CC:-?} run=${RR:-?}, expect cc=0 run=42)." >&2
        echo "$TAG       Dumping adderc stderr + shim diagnostics:" >&2
        send_until "enter linux { /bin/sh -c '/bin/cat /tmp/ac.err /tmp/ac.out' }" "hamsh\$" 40 || true
        grep -a -E "ENOSYS|not implemented|failed to map|ENOEXEC|bad system call|segfault|SIGSEGV|Killed|Cannot|cannot|error:" "$LOG" | tail -40 >&2
        fail=1
    fi
else
    echo "$TAG FAIL: no ADRC_RESULT marker in ${CMD_WAIT}s — adderc never" >&2
    echo "$TAG       ran to completion. Diagnostics:" >&2
    grep -a -E "ENOSYS|not implemented|failed to map|ENOEXEC|bad system call|segfault|SIGSEGV|Killed|clang|host_ac|adderc" "$LOG" | tail -40 >&2
    tail -60 "$LOG" | strings >&2
    fail=1
fi

if grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | grep -aq .; then
    echo "$TAG FAIL: kernel panic during the run:" >&2
    grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | head >&2
    fail=1
fi

kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null
if [ "$fail" -eq 0 ]; then
    echo "$TAG PASS"; [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"; exit 0
else
    echo "$TAG FAIL (serial log: $LOG)" >&2; exit 1
fi
