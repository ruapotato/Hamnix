#!/usr/bin/env bash
# scripts/test_ondevice_hostac_llvm.sh
#
# PHASE-0b GATE (on-device LLVM-build de-risking): prove that the
# SELF-HOSTED compiler `build/cutover/host_ac.elf` — an x86_64-linux
# static ELF now stamped EI_OSABI=Linux(3) (Phase 0a, commit e1d00476) —
# actually RUNS inside the Debian/Linux namespace ON-DEVICE under the
# linux_abi shim, and can EMIT textual LLVM IR (.ll) there.
#
# WHY THIS MATTERS: Phase 1 stages a ~1 GB clang toolchain into #distro so
# a .ll produced on-device can be compiled to a native ELF on-device. That
# is a big commitment. The single biggest unknown BEFORE making it is:
# does host_ac.elf even LOAD + RUN under the shim (ET_EXEC@0x400000 overlay
# + its ~473 MiB BSS arena + whatever Linux syscalls its emit path issues),
# and does it write a non-empty .ll? This gate answers exactly that. No
# clang is involved here — host_ac itself EMITS the .ll (it is a no-libc
# static ELF); Phase 1 will feed that .ll to clang.
#
# MODELLED ON scripts/test_installer_live_debian.sh (the authoritative
# on-device `enter linux { ... }` pattern): builds an installer-live image
# with a writable RAM #distro, boots it under QEMU/OVMF, drives a command
# inside the linux namespace, and asserts on serial markers.
#
# WHAT IT STAGES (HAMNIX_STAGE_HOSTAC=1, wired in build_rootfs_img.py):
#   /host_ac    build/cutover/host_ac.elf  (self-hosted compiler)
#   /hello.ad   tests/phase0b_hello.ad     (trivial int-only LLVM subset)
# The default (busybox-minimal) live image already ships /bin/sh + wc +
# printf — host_ac is a STATIC ELF, so it needs no Debian libc closure;
# the busybox #distro is a sufficient linux namespace to exec it in.
#
# ON-DEVICE COMMAND (assembled so the typed line never contains the
# contiguous marker — a match is real program OUTPUT):
#   enter linux { /bin/sh -c '/host_ac --backend=llvm /hello.ad /hello.ll;
#       rc=$?; sz=$(/bin/wc -c < /hello.ll); printf P0B%s... _RESULT ... }
#
# HEADLINE the gate reports: the serial line
#   P0B_RESULT rc=<rc> ll_bytes=<bytes>
# PASS iff rc=0 AND ll_bytes>0. A clean FAILURE with a precise root cause
# (ENOEXEC on the overlay, a missing/ENOSYS syscall in the shim, an OOM on
# the BSS arena, an empty .ll) is itself the valuable Phase-0b finding.
#
# Judged ONLY by serial-log markers (never wrapper exit codes; a qemu
# timeout after markers appeared is benign). The first serial command after
# boot is historically dropped, so every command is RE-SENT until its own
# output appears, and keystrokes are gated on boot markers, not sleeps.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or the installer image is
# unavailable and cannot be built, or when the live image carries no
# busybox /bin/sh (no u_busybox_musl fixture and it can't be built).
#
# Env overrides:
#   INSTALLER_IMG      image path     (default: build/hamnix-installer.img)
#   LIVE_DISTRO_IMG    live ext4 path (default: build/hamnix-live-distro.img)
#   OVMF_FD            OVMF firmware  (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for boot markers   (default: 240)
#   CMD_WAIT           seconds to wait for command output (default: 240)
#   QEMU_MEM           guest RAM (default: 3G — host_ac's ~473 MiB BSS
#                      arena + the live RAM ext4 need headroom)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)
#   KEEP_LOGS          1 = keep the serial log on PASS

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
CMD_WAIT="${CMD_WAIT:-240}"
QEMU_MEM="${QEMU_MEM:-3G}"
TAG="[test_ondevice_hostac_llvm]"

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
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "$TAG SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- ensure host_ac.elf exists (it is what we stage + run) ------------
# Bootstrap the self-hosted compiler via the Python seed. It builds with
# --target=x86_64-linux so the emitted ELF carries EI_OSABI=3 (Linux) and
# is classified/routed through the shim on-device. No-op if already built.
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ] || [ ! -x build/cutover/host_ac.elf ]; then
    echo "$TAG bootstrapping build/cutover/host_ac.elf (self-hosted compiler)"
    # shellcheck source=_adder_cc.sh
    ADDER_CC=adder source "$PROJ_ROOT/scripts/_adder_cc.sh"
    if ! adder_cc_bootstrap; then
        echo "$TAG SKIP: could not bootstrap host_ac.elf" >&2
        exit 0
    fi
fi
if [ ! -x build/cutover/host_ac.elf ]; then
    echo "$TAG SKIP: build/cutover/host_ac.elf absent." >&2
    exit 0
fi
# Sanity: confirm it is a Linux-OSABI x86_64 static ELF (else the shim
# would never see it). Byte 7 of e_ident is EI_OSABI; 3 = ELFOSABI_LINUX.
OSABI_BYTE=$(od -An -tu1 -j7 -N1 build/cutover/host_ac.elf 2>/dev/null | tr -d ' ')
echo "$TAG host_ac.elf EI_OSABI byte = ${OSABI_BYTE:-?} (expect 3=Linux)"

# --- ensure the busybox fixture (for /bin/sh in #distro) --------------
# The default live image is busybox-minimal; host_ac is a static ELF so it
# needs no Debian closure, but we need /bin/sh + wc + printf to capture the
# result. Build the fixture on demand (musl-gcc); skip if it can't build.
if [ ! -f tests/u-binary/u_busybox_musl ]; then
    echo "$TAG building u_busybox_musl fixture (musl static-PIE)"
    if ! make -C tests/u-binary/src/musl_busybox install >/dev/null 2>&1; then
        echo "$TAG SKIP: u_busybox_musl absent and could not be built" >&2
        echo "$TAG       (need musl-gcc + network for the busybox tarball)." >&2
        exit 0
    fi
fi

# --- ensure the installer image exists AND is fresh -------------------
# Always REBUILD by default (a stale image would test an old host_ac /
# kernel). HAMNIX_STAGE_HOSTAC=1 injects /host_ac + /hello.ad into #distro
# via scripts/build_rootfs_img.py::_stage_phase0b_hostac. The DEFAULT
# (busybox-minimal, HAMNIX_LIVE_MINIMAL=1) live image is used — no heavy
# real-Debian closure is needed to exec a static compiler.
# shellcheck source=_installer_img.sh
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
    if [ ! -f "$INSTALLER_IMG" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    # Reusing a pre-existing image: say so LOUDLY when it predates the tree.
    installer_img_warn_if_stale "$INSTALLER_IMG" "[ondevice_hostac_llvm]"
else
    echo "$TAG rebuilding installer image with HAMNIX_STAGE_HOSTAC=1 (~6 min)"
    HAMNIX_STAGE_HOSTAC=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "$TAG SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

# --- confirm the live image actually carries /host_ac + /bin/sh -------
HAVE_HOSTAC=0
HAVE_SH=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    if "$DEBUGFS" -R "stat /distro/host_ac" "$LIVE_DISTRO_IMG" 2>/dev/null \
            | grep -q "Type: regular"; then
        HAVE_HOSTAC=1
    fi
    if "$DEBUGFS" -R "stat /distro/bin/busybox" "$LIVE_DISTRO_IMG" 2>/dev/null \
            | grep -q "Type: regular"; then
        HAVE_SH=1
    fi
    echo "$TAG live image probe: host_ac=$HAVE_HOSTAC busybox=$HAVE_SH"
    if [ "$HAVE_HOSTAC" -eq 0 ]; then
        echo "$TAG FAIL: /host_ac was NOT staged into the live #distro — the" >&2
        echo "$TAG       HAMNIX_STAGE_HOSTAC staging hook did not fire." >&2
        exit 1
    fi
else
    echo "$TAG NOTE: cannot inspect $LIVE_DISTRO_IMG (missing image/debugfs);"
    echo "$TAG       proceeding — the boot run is the real assertion."
fi

OVMF_RW=$(mktemp --tmpdir hamnix-hostac.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-hostac.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-hostac.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-hostac-in.XXXXXX)
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
    -vga std -display none -no-reboot \
    -monitor none \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

wait_for() {
    local pat="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        if grep -a -F -q "$pat" "$LOG"; then
            return 0
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

send_until() {
    local cmd="$1" pat="$2" secs="$3"
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
        printf '%s\n' "$cmd" >&3
        local i
        for i in $(seq 1 15); do
            if grep -a -F -q "$pat" "$LOG"; then
                return 0
            fi
            if ! kill -0 "$QEMU_PID" 2>/dev/null; then
                return 1
            fi
            sleep 1
            waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -F -q "$pat" "$LOG"
}

fail=0

# --- boot markers ------------------------------------------------------
echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch + handoff..."
if wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: rc.boot took the LIVE branch."
else
    echo "$TAG FAIL: LIVE-branch marker not seen." >&2
    tail -80 "$LOG" | strings >&2
    exit 1
fi

if wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: kernel live-root bringup completed (#distro posted)."
else
    echo "$TAG FAIL: '[live-root] DONE' not seen — #distro bringup failed." >&2
    grep -a "live-root\|live_distro_up" "$LOG" | tail -20 >&2
    tail -40 "$LOG" | strings >&2
    fail=1
fi

if wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: interactive handoff reached."
else
    echo "$TAG FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -80 "$LOG" | strings >&2
    exit 1
fi

# --- THE PHASE-0b RUN: host_ac under the shim, emitting .ll ------------
if [ "$fail" -eq 0 ]; then
    echo "$TAG --- running host_ac --backend=llvm inside enter linux { } ---"

    # (1) Direct exec first, so any kernel/shim serial diagnostics (an
    #     ENOEXEC on the ET_EXEC overlay, a 'failed to map segment', an
    #     ENOSYS from an unimplemented syscall) print plainly next to the
    #     command. We don't assert on this line's output; it's a probe.
    send_until "enter linux { /host_ac --backend=llvm /hello.ad /hello.ll }" \
               "hamsh\$" 30 || true
    sleep 2

    # (2) Shell wrapper: run host_ac, capture rc + the .ll byte count, and
    #     print the assembled marker (typed line never contains the
    #     contiguous 'P0B_RESULT' — only printf's OUTPUT does).
    RUN='/host_ac --backend=llvm /hello.ad /hello.ll 2>/tmp/hac.err; rc=$?; sz=$(/bin/wc -c < /hello.ll 2>/dev/null); [ -z "$sz" ] && sz=NONE; /bin/printf "P0B%s rc=%s ll_bytes=%s\n" _RESULT "$rc" "$sz"'
    if send_until "enter linux { /bin/sh -c '$RUN' }" "P0B_RESULT" "$CMD_WAIT"; then
        RESULT_LINE=$(grep -a -F "P0B_RESULT" "$LOG" | grep -v "/bin/printf" | tail -1)
        echo "$TAG serial result: $RESULT_LINE"
        RC=$(printf '%s\n' "$RESULT_LINE" | sed -n 's/.*rc=\([0-9]*\).*/\1/p' | tail -1)
        BYTES=$(printf '%s\n' "$RESULT_LINE" | sed -n 's/.*ll_bytes=\([0-9A-Za-z]*\).*/\1/p' | tail -1)
        if [ "${RC:-X}" = "0" ] && [ -n "${BYTES:-}" ] && [ "$BYTES" != "0" ] && [ "$BYTES" != "NONE" ]; then
            echo "$TAG PASS: host_ac RAN under the linux shim and emitted a"
            echo "$TAG       non-empty .ll on-device (rc=$RC, ll_bytes=$BYTES)."
            # Bonus: dump the ADDER_STAT line from the emitted .ll for the record.
            send_until "enter linux { /bin/sh -c '/bin/grep ADDER_STAT /hello.ll' }" \
                       "ADDER_STAT" 30 || true
        else
            echo "$TAG FAIL: host_ac did NOT produce a valid .ll on-device" >&2
            echo "$TAG       (rc=${RC:-?}, ll_bytes=${BYTES:-?}). Dumping shim" >&2
            echo "$TAG       diagnostics + the captured host_ac stderr:" >&2
            # Surface any error host_ac wrote + shim/loader diagnostics.
            send_until "enter linux { /bin/sh -c '/bin/cat /tmp/hac.err' }" \
                       "hamsh\$" 30 || true
            grep -a -E "ENOSYS|not implemented|failed to map|ENOEXEC|bad system call|segfault|SIGSEGV|Killed|Cannot|error" "$LOG" | tail -30 >&2
            fail=1
        fi
    else
        echo "$TAG FAIL: no P0B_RESULT marker in ${CMD_WAIT}s — host_ac never" >&2
        echo "$TAG       ran to completion under the shell wrapper. Diagnostics:" >&2
        grep -a -E "ENOSYS|not implemented|failed to map|ENOEXEC|bad system call|segfault|SIGSEGV|Killed|host_ac" "$LOG" | tail -30 >&2
        tail -60 "$LOG" | strings >&2
        fail=1
    fi
fi

# No real panic on the way up (benign uaccess-smoke line excluded).
if grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | grep -aq .; then
    echo "$TAG FAIL: kernel panic during the run:" >&2
    grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | head >&2
    fail=1
fi

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

if [ "$fail" -eq 0 ]; then
    echo "$TAG PASS"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "$TAG FAIL (serial log: $LOG)" >&2
    exit 1
fi
