#!/usr/bin/env bash
# scripts/test_uefi_boot.sh - Boot build/hamnix.iso under OVMF (UEFI) and
#                            assert the Hamnix kernel banner.
#
# This is the "hybrid ISO, UEFI half" half of the M16.70 priority — the
# inverse of scripts/test_bios_boot.sh. Both scripts intentionally have
# the SAME pass-marker format ([test_<label>_boot] PASS) so the cron
# template can grep either output line.
#
# Path under test (M16.125 PATH A — UEFI direct boot, no GRUB-EFI):
#   OVMF firmware  ->  reads GPT, finds ESP partition (FAT12)
#   ->  launches \EFI\BOOT\BOOTX64.EFI = our PE32+ stub
#       (arch/x86/boot/efi_stub.S, built into build/hamnix-bootx64.efi)
#   ->  stub SFSP-opens \hamnix-kernel.elf on the same ESP
#   ->  parses program headers, copies PT_LOAD segments to their LMAs
#   ->  scans for the multiboot1 magic, reads the Hamnix EFI handoff
#       table, patches boot_via_efi = 1
#   ->  GetMemoryMap + ExitBootServices (retry on stale MapKey)
#   ->  builds identity-mapped page tables (1 GiB pages, 4 GiB span)
#   ->  loads kernel-shape GDT (CS=0x08, DS=0x10), sets CR3
#   ->  far-jumps to _x86_start_after_loader
#   ->  start_kernel() and beyond
#
# We assert FOUR markers in order:
#   1. "[hamnix] EFI entry reached"          - PE/COFF entry hit.
#   2. "[hamnix] post-EFI handoff complete"  - ExitBootServices succeeded.
#   3. "Hamnix kernel booting"               - kernel banner; proves the
#                                              EFI ELF loader handed off
#                                              to start_kernel() cleanly.
#   4. "[hamsh] M16.35 shell ready"          - M16.126 gate: hamsh's first
#                                              read+printf round-trip
#                                              completed. This proves
#                                              tss_init(ltr $0x28), the
#                                              syscall MSRs, and iretq
#                                              into user mode all worked
#                                              with the loaded GDT (the
#                                              kernel's gdt64, picked up
#                                              via the +60 handoff slot).
#                                              Pre-M16.126 this trapped
#                                              #GP err=0x28 at tss_init.
# Order matters: a stale fragment of a previous run shouldn't be able
# to satisfy a later check by appearing earlier in the log.
#
# Pass marker:    [test_uefi_boot] PASS
# Fail marker:    [test_uefi_boot] FAIL
#
# Env overrides:
#   HAMNIX_ISO          iso path                  (default: build/hamnix.iso)
#   UEFI_BOOT_TIMEOUT   seconds for the run       (default: 45 — slower
#                                                   than BIOS because OVMF
#                                                   takes ~10s to enumerate)
#   OVMF_FD             OVMF firmware path        (default: /usr/share/ovmf/OVMF.fd)
#   UEFI_BANNER_RE      EFI entry marker         (default: PE-entry marker)
#   UEFI_HANDOFF_RE     post-handoff marker      (default: post-ExitBootServices)
#   KERNEL_BANNER_RE    kernel banner regex       (default: kernel banner)
#   USER_READY_RE       hamsh-ready regex         (default: shell-ready
#                                                  marker — M16.126 gate)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
UEFI_BOOT_TIMEOUT="${UEFI_BOOT_TIMEOUT:-45}"
UEFI_BANNER_RE="${UEFI_BANNER_RE:-\[hamnix\] EFI entry reached}"
UEFI_HANDOFF_RE="${UEFI_HANDOFF_RE:-\[hamnix\] post-EFI handoff complete}"
KERNEL_BANNER_RE="${KERNEL_BANNER_RE:-Hamnix kernel booting}"
# M16.126 gate: hamsh's first line proves we made it through tss_init,
# syscall_init, and iretq into ring-3 — i.e. all the places that would
# have re-tripped a missing GDT slot on the UEFI path.
USER_READY_RE="${USER_READY_RE:-\[hamsh\] M16.35 shell ready}"

# OVMF path resolution: prefer the Debian-style /usr/share/ovmf/OVMF.fd
# (single-file firmware) but fall back to the 4M split-firmware path
# /usr/share/OVMF/OVMF_CODE_4M.fd if only the newer packaging is present.
# The 4M variant is loaded via -drive if=pflash,format=raw,readonly=on,file=...
# which is what `qemu-system-x86_64 -bios` does internally for us anyway.
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
    echo "[test_uefi_boot] SKIP: OVMF firmware not found (tried /usr/share/ovmf/OVMF.fd and /usr/share/OVMF/OVMF_CODE*.fd; apt install ovmf)" >&2
    # SKIP is not a failure for CI plumbing — exit 0 with a clear log
    # line. The caller can differentiate via the PASS marker absence.
    echo "[test_uefi_boot] SKIP"
    exit 0
fi

# Always rebuild the ISO. Skipping the rebuild silently reused stale
# artifacts in past sessions and made hours of post-fix testing look
# like the fix didn't land; never again. Set HAMNIX_SKIP_BUILD=1 to
# explicitly opt out (CI parallelism etc.).
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_uefi_boot] rebuilding ISO via scripts/build_iso.sh"
    rm -f "$HAMNIX_ISO"
    bash "$PROJ_ROOT/scripts/build_iso.sh"
fi
# HAMNIX_SKIP_BUILD=1 reuses whatever ISO is on disk — say so LOUDLY when
# that ISO predates the tree under test (scripts/_installer_img.sh).
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_warn_if_stale "$HAMNIX_ISO" "[uefi_boot]"
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_uefi_boot] FAIL: $HAMNIX_ISO missing after build_iso.sh." >&2
    exit 1
fi

# OVMF wants a writable copy because UEFI variables get persisted to the
# firmware image itself. Using the system copy directly would either
# fail (permissions) or contaminate other runs.
OVMF_RW=$(mktemp --tmpdir hamnix-uefi-boot.ovmf.XXXXXX.fd)
LOGFILE=$(mktemp --tmpdir hamnix-uefi-boot.XXXXXX.log)
cleanup() { rm -f "$OVMF_RW" "$LOGFILE"; }
trap cleanup EXIT
cp "$OVMF_FD" "$OVMF_RW"

echo "[test_uefi_boot] === UEFI boot via OVMF (timeout ${UEFI_BOOT_TIMEOUT}s) ==="
echo "[test_uefi_boot]   firmware  = $OVMF_FD"
echo "[test_uefi_boot]   banner_re = \"$UEFI_BANNER_RE\""
echo "[test_uefi_boot]   handoff_re= \"$UEFI_HANDOFF_RE\""
echo "[test_uefi_boot]   kernel_re = \"$KERNEL_BANNER_RE\""
echo "[test_uefi_boot]   user_re   = \"$USER_READY_RE\""

set +e
timeout "${UEFI_BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -bios "$OVMF_RW" \
    -cdrom "$HAMNIX_ISO" \
    -m 256M \
    -nographic \
    -no-reboot \
    -monitor none \
    -serial stdio \
    2>&1 | tee "$LOGFILE"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_uefi_boot] FAIL: qemu exited rc=$rc" >&2
    echo "[test_uefi_boot] FAIL"
    exit 1
fi

# Strict-order check: each marker must appear AFTER the previous one's
# line number.
check_marker() {
    local label="$1" regex="$2" prev_line="${3:-0}"
    local line
    line=$(grep -a -n -E "$regex" "$LOGFILE" | head -1 | cut -d: -f1)
    if [ -z "$line" ]; then
        echo "[test_uefi_boot] FAIL: $label marker (\"$regex\") not detected." >&2
        return 1
    fi
    if [ "$prev_line" -gt 0 ] && [ "$line" -le "$prev_line" ]; then
        echo "[test_uefi_boot] FAIL: $label marker (\"$regex\") appears at or before prior marker (line $line <= $prev_line)." >&2
        return 1
    fi
    echo "[test_uefi_boot] $label marker detected at line $line (\"$regex\")."
    MARKER_LINE="$line"
    return 0
}

MARKER_LINE=0
check_marker "EFI-entry"    "$UEFI_BANNER_RE"  0           || { echo "[test_uefi_boot] FAIL"; exit 1; }
check_marker "post-handoff" "$UEFI_HANDOFF_RE" "$MARKER_LINE" || { echo "[test_uefi_boot] FAIL"; exit 1; }
check_marker "kernel"       "$KERNEL_BANNER_RE" "$MARKER_LINE" || { echo "[test_uefi_boot] FAIL"; exit 1; }
# M16.126 gate: hamsh actually came up. Pre-fix this would have FAIL'd
# with a #GP at tss_init — the kernel-banner check above passes, but
# tss_init runs LATER, just before start_first_task. Without the
# kernel-gdt handoff, that's where the boot died on UEFI.
check_marker "user"         "$USER_READY_RE"   "$MARKER_LINE" || { echo "[test_uefi_boot] FAIL"; exit 1; }
# The user-facing ISO boots through the hamsh rc system: /init (shim)
# execs hamsh, hamsh-as-PID-1 sources /etc/rc.boot which applies the
# namespace recipe. Assert the recipe marker AFTER shell-ready so the
# UEFI boot gate also covers the rc path.
check_marker "rc-boot"      "rc.boot: namespace recipe applied" "$MARKER_LINE" || { echo "[test_uefi_boot] FAIL"; exit 1; }

# Belt-and-braces: an explicit "no #GP at tss_init" check. Any
# `TRAP: vector 0x0d err=0x28` line in the log is the M16.125 → M16.126
# regression we just fixed; reject it loudly even if the markers
# above somehow lined up.
if grep -a -q -E "TRAP: vector 0x0d err=0x28" "$LOGFILE"; then
    echo "[test_uefi_boot] FAIL: tss_init #GP regression (err=0x28) detected." >&2
    echo "[test_uefi_boot] FAIL"
    exit 1
fi

echo "[test_uefi_boot] PASS"
