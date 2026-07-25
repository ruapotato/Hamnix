#!/usr/bin/env bash
# scripts/test_installer_de_runlevel5.sh
#
# REGRESSION GATE for the live installer image booting straight to the
# graphical (MATE/GNOME2) desktop. Boots build/hamnix-installer.img with
# the user's exact ship command:
#
#   qemu-system-x86_64 -enable-kvm -cpu host -bios /usr/share/ovmf/OVMF.fd \
#       -drive file=./build/hamnix-installer.img,format=raw,if=virtio \
#       -m 1G -vga std -serial stdio -no-reboot
#
# (here with -display none + a monitor socket so the framebuffer can be
# screendumped headlessly), and asserts the desktop comes up by default.
#
# This guards TWO load-bearing things that silently regressed before and
# have NO other CI coverage:
#
#   1. The uaccess demand-fault fix (mm/uaccess.ad uaccess_resolve_fault).
#      hamsh's svc loader copy_to_user's a service definition into a
#      never-touched BSS buffer. Before the fix, copy_to_user walked the
#      page tables read-only, hit the not-present page, and returned
#      -EFAULT, so the svc read 0 bytes -> "svc: empty definition file"
#      -> hamuid never started -> NO desktop. The assertion here is the
#      ABSENCE of "empty definition file" in the boot log.
#
#   2. rc.boot.full defaulting to `init 5` (graphical) instead of
#      `init 3` (text). The desktop must come up WITHOUT operator input.
#      Asserted via "[init] entering runlevel 5" + the rc.5 hook's
#      "hamUI stack started by supervisor" line.
#
# Plus a framebuffer screendump that must be non-blank (the DE painted
# real pixels), checked only when socat/nc is available.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or the installer image is
# unavailable and cannot be built.
#
# Env overrides:
#   INSTALLER_IMG      image path        (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware     (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for the handoff marker (default: 240)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)
#   KEEP_LOGS          1 = keep the serial log on PASS

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
HANDOFF_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_de_rl5] SKIP: /dev/kvm absent (KVM required; -vga std boot too slow without it)" >&2
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
    echo "[test_de_rl5] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- ensure the installer image exists --------------------------------
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[installer_de_runlevel5]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[test_de_rl5] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    echo "[test_de_rl5] installer image absent; building via build_installer_img.sh (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_de_rl5] SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-de-rl5.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-de-rl5.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-de-rl5.XXXXXX.log)
MON=$(mktemp --tmpdir -u hamnix-de-rl5-mon.XXXXXX)
SHOT=$(mktemp --tmpdir hamnix-de-rl5.XXXXXX.ppm)
cp "$OVMF_FD" "$OVMF_RW"
# Fresh writable COPY of the image (never mutate the shipped artifact).
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$SHOT"
}
trap cleanup EXIT

# Mirror the user's exact ship command (-enable-kvm -cpu host -bios OVMF
# -drive raw/virtio -m 1G -vga std -serial stdio -no-reboot), adding
# -display none and a monitor socket so we can screendump headlessly.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "${HAMNIX_VM_MEM:-2G}" \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    > "$LOG" 2>&1 < /dev/null &
QEMU_PID=$!

echo "[test_de_rl5] waiting up to ${BOOT_WAIT}s for handoff marker..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$HANDOFF_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_de_rl5] FAIL: qemu exited before reaching the handoff marker." >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[test_de_rl5] FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[test_de_rl5] handoff reached; letting the DE paint, then screendumping."

# HMP command over the monitor unix socket (one-shot; needs socat or nc).
mon_cmd() {
    if command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    else
        return 1
    fi
}

# Give hamuid a moment to paint the desktop into the framebuffer.
sleep 6
SHOT_OK=0
if mon_cmd "screendump $SHOT"; then
    sleep 2
    [ -s "$SHOT" ] && SHOT_OK=1
fi

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

# --- assertions -------------------------------------------------------
fail=0

# (1) The uaccess demand-fault regression: a never-touched BSS user page
# handed to copy_to_user must NOT yield -EFAULT. The svc loader's
# "empty definition file" is the canary — its ABSENCE is the assertion.
if grep -a -q "empty definition file" "$LOG"; then
    echo "[test_de_rl5] FAIL: 'empty definition file' present — uaccess copy_to_user regressed on a not-present user page (svc read 0 bytes)." >&2
    grep -a -n "empty definition file" "$LOG" | head >&2
    fail=1
else
    echo "[test_de_rl5] PASS: no 'empty definition file' (uaccess demand-fault path intact)."
fi

# (2) Default graphical runlevel: the image must enter runlevel 5 on its
# own (rc.boot.full `init 5`).
if grep -a -q -E "\[init\] entering runlevel 5" "$LOG"; then
    echo "[test_de_rl5] PASS: '[init] entering runlevel 5' (graphical by default)."
else
    echo "[test_de_rl5] FAIL: did NOT enter runlevel 5 by default (rc.boot.full not 'init 5'?)." >&2
    fail=1
fi

# (3) The runlevel-5 hook must have started the hamUI/hamuid stack.
if grep -a -q "hamUI stack started by supervisor" "$LOG"; then
    echo "[test_de_rl5] PASS: rc.5 hook started the hamUI stack (hamuid.svc)."
else
    echo "[test_de_rl5] FAIL: rc.5 hamUI-stack-started marker missing — desktop did not autostart." >&2
    fail=1
fi

# No real panic on the way up (the benign uaccess-smoke "EFAULT (no
# panic)" string is excluded).
if grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | grep -aq .; then
    echo "[test_de_rl5] FAIL: kernel panic during boot:" >&2
    grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | head >&2
    fail=1
else
    echo "[test_de_rl5] PASS: no kernel panic during boot."
fi

# DEMAND-BSS regression guard (2026-06-23): the ELF loader must NOT OOM
# while spawning the DE's hamui client apps. Each client links ~8.2 MiB
# of static BSS (lib/hamui.ad h_v2_bb/h_v2_msg); the loader used to
# EAGERLY allocate one ~8 MiB CONTIGUOUS physical region per app and
# zero-fill it, so after a few apps there was no contiguous hole left and
# _load_elf64 printed "elf: OOM" / "elf64: OOM" — the panel app exited
# code=1 and the desktop came up with only the 2 floating demo windows on
# bare teal. The fix demand-pages the BSS tail (zero-on-fault), so its
# ABSENCE from the boot serial is the assertion. Also guard the new
# BSS-demand fault path's own OOM string.
if grep -a -E "elf: OOM|elf64: OOM|demand-page OOM|bss-demand PT prep OOM" "$LOG" \
        | grep -aq .; then
    echo "[test_de_rl5] FAIL: ELF loader OOM during boot — BSS demand-page fix regressed (apps' ~8 MiB contiguous BSS alloc re-exhausted RAM)." >&2
    grep -a -n -E "elf: OOM|elf64: OOM|demand-page OOM|bss-demand PT prep OOM" "$LOG" | head >&2
    fail=1
else
    echo "[test_de_rl5] PASS: no ELF loader OOM (BSS tail demand-paged, not eagerly contiguous-allocated)."
fi

# (4) Framebuffer screendump must be non-blank: more than one distinct
# pixel triple means the DE actually painted. Skipped (not failed) if no
# socat/nc to drive the monitor.
if [ "$SHOT_OK" -eq 1 ]; then
    distinct=$(tail -c +16 "$SHOT" 2>/dev/null \
        | od -An -tx1 -w3 2>/dev/null | sort -u | head -200 | wc -l)
    if [ "${distinct:-0}" -ge 2 ]; then
        echo "[test_de_rl5] PASS: framebuffer screendump non-blank ($distinct+ distinct pixel values — desktop painted)."
    else
        echo "[test_de_rl5] FAIL: framebuffer screendump uniform/blank — nothing painted." >&2
        fail=1
    fi
else
    echo "[test_de_rl5] NOTE: screendump skipped (no socat/nc or empty dump); relying on the log markers above."
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_de_rl5] PASS"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_de_rl5] FAIL (serial log: $LOG)" >&2
    exit 1
fi
