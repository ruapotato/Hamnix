#!/usr/bin/env bash
# scripts/test_smp_de_runlevel5.sh
#
# SMP DE-image boot gate — boots the FULL live/installer desktop image
# under -smp 2 (multicore) and asserts it reaches the graphical runlevel
# WITHOUT wedging.
#
# WHY THIS GATE EXISTS
#
# The other SMP CI (scripts/test_smp.sh) boots only a `-kernel`/cpio
# image at -smp 2 — that path survives multicore fine, so it never
# caught the real regression the user hit as "newshell hostowner takes
# 30-60s". That stall is a runlevel-5 fork+exec app-launch storm that
# only wedges/stalls on the FULL DE image at -smp>1 (sub-second at
# -smp 1). scripts/test_installer_de_runlevel5.sh boots the DE image but
# at the QEMU default of ONE cpu, so it too misses the multicore wedge.
# This gate closes that hole: same image, same markers, but -smp 2.
#
# One measured contributor was LAPIC-timer MIScalibration: a flaky PIT
# gate under KVM could yield a periodic count ~18-30x too small, so the
# LAPIC fired (and `jiffies` advanced) ~18-30x too fast, driving a
# per-CPU timer-IRQ storm. arch/x86/kernel/apic.ad now cross-checks the
# PIT-derived rate against the TSC-measured window and clamps it. This
# gate is the multicore end-to-end guard that the DE image still reaches
# runlevel 5 under -smp 2. (If a separate scheduler/IPC deadlock remains,
# this gate is where it will surface.)
#
# PASS = the DE image, under -smp 2, reaches "[init] entering runlevel 5"
# and "hamUI stack started by supervisor" within BOOT_WAIT seconds, with
# no kernel panic. A wedge/stall shows up as the runlevel-5 markers never
# appearing before the timeout -> FAIL.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or the installer image is
# unavailable and cannot be built.
#
# Env overrides:
#   INSTALLER_IMG      image path        (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware     (default: auto-resolved)
#   SMP                cpu count         (default: 2)
#   BOOT_WAIT          seconds to wait for the runlevel-5 marker (default: 360)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)
#   KEEP_LOGS          1 = keep the serial log on PASS

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
SMP="${SMP:-2}"
# -smp>1 DE boots are slower (and, while a wedge exists, can hang until
# the timeout), so budget generously.
BOOT_WAIT="${BOOT_WAIT:-360}"
RL5_MARKER="[init] entering runlevel 5"
HAMUI_MARKER="hamUI stack started by supervisor"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_smp_de_rl5] SKIP: /dev/kvm absent (KVM required; -vga std DE boot too slow without it)" >&2
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
    echo "[test_smp_de_rl5] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- ensure the installer image exists --------------------------------
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[smp_de_runlevel5]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[test_smp_de_rl5] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    echo "[test_smp_de_rl5] installer image absent; building via build_installer_img.sh (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_smp_de_rl5] SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-smp-de.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-smp-de.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-smp-de.XXXXXX.log)
cp "$OVMF_FD" "$OVMF_RW"
# Fresh writable COPY of the image (never mutate the shipped artifact).
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill -9 "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW"
}
trap cleanup EXIT

echo "[test_smp_de_rl5] booting DE image at -smp ${SMP} (KVM, -cpu host), waiting up to ${BOOT_WAIT}s for runlevel 5..."

# Mirror the user's ship command (-enable-kvm -cpu host -bios OVMF -drive
# raw/virtio -vga std -serial stdio -no-reboot) but at -smp ${SMP} and
# with -display none for headless CI.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -smp "$SMP" \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "${HAMNIX_VM_MEM:-2G}" \
    -vga std -display none -no-reboot \
    -serial stdio \
    > "$LOG" 2>&1 < /dev/null &
QEMU_PID=$!

booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -F "$RL5_MARKER" "$LOG" && grep -a -q -F "$HAMUI_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_smp_de_rl5] FAIL: qemu exited before reaching runlevel 5 under -smp ${SMP}." >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done

kill -9 "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

fail=0

if [ "$booted" -ne 1 ]; then
    echo "[test_smp_de_rl5] FAIL: DE image did NOT reach runlevel 5 within ${BOOT_WAIT}s at -smp ${SMP} — multicore boot wedged/stalled." >&2
    echo "[test_smp_de_rl5] --- last 60 serial lines ---" >&2
    tail -60 "$LOG" >&2
    exit 1
fi

echo "[test_smp_de_rl5] PASS: reached '$RL5_MARKER' + '$HAMUI_MARKER' under -smp ${SMP}."

# LAPIC calibration sanity: the programmed periodic count must be the
# ~100 Hz value (~500k-800k at a few-GHz LAPIC input), not an 18-30x-too-
# small count. Print the calibration lines for the record; fail only on an
# explicit implausible/clamp-to-fallback outcome (a genuinely broken clock).
echo "[test_smp_de_rl5] --- LAPIC/TSC calibration ---"
grep -a -E "LAPIC:|tsc: calibrated" "$LOG" || echo "(no calibration lines captured)"
if grep -a -q -E "calibration implausible \(count=" "$LOG"; then
    echo "[test_smp_de_rl5] FAIL: LAPIC calibration fell through to the hard fallback count — both PIT and TSC were degenerate." >&2
    fail=1
fi

# No real panic on the way up (the benign uaccess-smoke "no panic" line
# is excluded).
if grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | grep -aq .; then
    echo "[test_smp_de_rl5] FAIL: kernel panic during -smp ${SMP} boot:" >&2
    grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | head >&2
    fail=1
else
    echo "[test_smp_de_rl5] PASS: no kernel panic during -smp ${SMP} boot."
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_smp_de_rl5] PASS"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_smp_de_rl5] FAIL (serial log: $LOG)" >&2
    exit 1
fi
