#!/usr/bin/env bash
# scripts/test_uefi_bigmem.sh - Boot build/hamnix.iso under OVMF (UEFI) with
#                              -m 1G and assert that the kernel actually
#                              SEES (and pools into memblock) more RAM than
#                              the pre-M16.155 240 MiB fallback ceiling.
#
# This is the regression test for the M16.155 EFI memory-map walker. Before
# this change, e820_init's UEFI branch installed a hardcoded 2..240 MiB
# memblock window regardless of how much RAM the firmware actually
# reported — every UEFI boot wasted everything above 240 MiB. The walker
# parses the EFI_MEMORY_DESCRIPTOR array the stub captured via
# GetMemoryMap right before ExitBootServices, classifies each entry's
# Type, and feeds memblock the largest free-RAM region (EfiConventional /
# EfiBootServicesCode / EfiBootServicesData) the firmware advertised.
#
# We boot OVMF with `-m 1G` (so the firmware advertises ~960 MiB of free
# RAM after its own reservations) and assert FOUR things in order:
#   1. "[hamnix] EFI: memory map handed off"  - stub populated
#                                               efi_mmap_info before
#                                               ExitBootServices.
#   2. "e820: EFI memory map @"               - kernel side actually
#                                               started parsing the
#                                               descriptors (proves the
#                                               handoff slot wiring is
#                                               live end-to-end).
#   3. "[memblock] free: NNN MiB" with NNN  - the smoke test. Pre-fix
#                                  >= 512    this maxed at 240 MiB.
#                                            Post-fix on `-m 1G` OVMF
#                                            it should report close to
#                                            931 MiB (the largest single
#                                            EfiConventional chunk).
#                                            We use a conservative
#                                            512 MiB floor — that's
#                                            still 2.1× the old cap and
#                                            leaves room for future OVMF
#                                            layout changes.
#   4. "[hamsh] M16.35 shell ready"          - kernel reached userland,
#                                              i.e. nothing regressed.
#
# Pass marker:    [test_uefi_bigmem] PASS
# Fail marker:    [test_uefi_bigmem] FAIL
#
# Env overrides:
#   HAMNIX_ISO          iso path                  (default: build/hamnix.iso)
#   BIGMEM_BOOT_TIMEOUT seconds for the run       (default: 60)
#   BIGMEM_BOOT_MEM     qemu -m value             (default: 1G)
#   BIGMEM_FREE_MIN_MIB free-MiB lower bound      (default: 512)
#   OVMF_FD             OVMF firmware path        (default: /usr/share/ovmf/OVMF.fd)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
BIGMEM_BOOT_TIMEOUT="${BIGMEM_BOOT_TIMEOUT:-60}"
BIGMEM_BOOT_MEM="${BIGMEM_BOOT_MEM:-1G}"
BIGMEM_FREE_MIN_MIB="${BIGMEM_FREE_MIN_MIB:-512}"

# OVMF path resolution (same convention as test_uefi_boot.sh).
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
    echo "[test_uefi_bigmem] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    echo "[test_uefi_bigmem] SKIP"
    exit 0
fi

# Always rebuild the ISO unless caller opts out — match the rest of the
# boot-test convention so we never PASS on a stale artifact.
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_uefi_bigmem] rebuilding ISO via scripts/build_iso.sh"
    rm -f "$HAMNIX_ISO"
    bash "$PROJ_ROOT/scripts/build_iso.sh"
fi
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_uefi_bigmem] FAIL: $HAMNIX_ISO missing after build_iso.sh." >&2
    exit 1
fi
# Stale-artifact guard: HAMNIX_SKIP_BUILD=1 reuses whatever ISO/rootfs is
# already on disk. Say so LOUDLY when it predates the tree under test.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_warn_if_stale "$HAMNIX_ISO" "[uefi_bigmem]"

OVMF_RW=$(mktemp --tmpdir hamnix-uefi-bigmem.ovmf.XXXXXX.fd)
LOGFILE=$(mktemp --tmpdir hamnix-uefi-bigmem.XXXXXX.log)
cleanup() { rm -f "$OVMF_RW" "$LOGFILE"; }
trap cleanup EXIT
cp "$OVMF_FD" "$OVMF_RW"

echo "[test_uefi_bigmem] === UEFI -m $BIGMEM_BOOT_MEM (timeout ${BIGMEM_BOOT_TIMEOUT}s, min_free=${BIGMEM_FREE_MIN_MIB} MiB) ==="
echo "[test_uefi_bigmem]   firmware  = $OVMF_FD"

set +e
timeout "${BIGMEM_BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -bios "$OVMF_RW" \
    -cdrom "$HAMNIX_ISO" \
    -m "$BIGMEM_BOOT_MEM" \
    -nographic \
    -no-reboot \
    -monitor none \
    -serial stdio \
    2>&1 | tee "$LOGFILE"
rc=${PIPESTATUS[0]}
set -e

# rc=124 (timeout) is the expected "kernel kept running after hamsh came
# up" signal; rc=0 means QEMU clean-exited. Anything else is a real fault.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_uefi_bigmem] FAIL: qemu exited rc=$rc" >&2
    echo "[test_uefi_bigmem] FAIL"
    exit 1
fi

# Belt-and-braces: any kernel TRAP / kernel-PF should fail the test even
# if the markers below happen to line up. The point of more RAM is more
# allocations — a regression there would crash later in boot.
if grep -a -q -E "^\[?[0-9]*\]?[[:space:]]*TRAP:" "$LOGFILE"; then
    echo "[test_uefi_bigmem] FAIL: kernel TRAP detected." >&2
    grep -a -E "TRAP:" "$LOGFILE" | head -5 >&2
    echo "[test_uefi_bigmem] FAIL"
    exit 1
fi

# Strict-order check helper. Same shape as test_uefi_boot.sh.
check_marker() {
    local label="$1" regex="$2" prev_line="${3:-0}"
    local line
    line=$(grep -a -n -E "$regex" "$LOGFILE" | head -1 | cut -d: -f1)
    if [ -z "$line" ]; then
        echo "[test_uefi_bigmem] FAIL: $label marker (\"$regex\") not detected." >&2
        return 1
    fi
    if [ "$prev_line" -gt 0 ] && [ "$line" -le "$prev_line" ]; then
        echo "[test_uefi_bigmem] FAIL: $label marker (\"$regex\") appears at or before prior marker (line $line <= $prev_line)." >&2
        return 1
    fi
    echo "[test_uefi_bigmem] $label marker detected at line $line."
    MARKER_LINE="$line"
    return 0
}

MARKER_LINE=0
check_marker "stub-handoff"  "\[hamnix\] EFI: memory map handed off" 0           || { echo "[test_uefi_bigmem] FAIL"; exit 1; }
check_marker "kernel-walker" "e820: EFI memory map @"                "$MARKER_LINE" || { echo "[test_uefi_bigmem] FAIL"; exit 1; }

# The smoking gun: capture the [memblock] free line's MiB value.
# Format: "[memblock] free: NNN MiB"
FREE_LINE=$(grep -a -E "\[memblock\] free:" "$LOGFILE" | head -1)
if [ -z "$FREE_LINE" ]; then
    echo "[test_uefi_bigmem] FAIL: '[memblock] free:' line not emitted." >&2
    echo "[test_uefi_bigmem] FAIL"
    exit 1
fi
echo "[test_uefi_bigmem] memblock line: $FREE_LINE"

# Pull out the MiB integer. Format is "...[memblock] free: NNN MiB".
FREE_MIB=$(echo "$FREE_LINE" | sed -n 's/.*\[memblock\] free: \([0-9]\+\) MiB.*/\1/p')
if [ -z "$FREE_MIB" ]; then
    echo "[test_uefi_bigmem] FAIL: could not parse MiB integer from '$FREE_LINE'." >&2
    echo "[test_uefi_bigmem] FAIL"
    exit 1
fi
if [ "$FREE_MIB" -lt "$BIGMEM_FREE_MIN_MIB" ]; then
    echo "[test_uefi_bigmem] FAIL: free RAM ${FREE_MIB} MiB < minimum ${BIGMEM_FREE_MIN_MIB} MiB." >&2
    echo "[test_uefi_bigmem] FAIL: this is the EFI-memmap-walker regression — pre-M16.155 the EFI path capped at 240 MiB regardless of -m." >&2
    echo "[test_uefi_bigmem] FAIL"
    exit 1
fi
echo "[test_uefi_bigmem] free RAM ${FREE_MIB} MiB >= ${BIGMEM_FREE_MIN_MIB} MiB threshold."

# Finally, prove no later boot stage regressed: hamsh must come up.
check_marker "hamsh"         "\[hamsh\] M16.35 shell ready"          "$MARKER_LINE" || { echo "[test_uefi_bigmem] FAIL"; exit 1; }

echo "[test_uefi_bigmem] PASS"
