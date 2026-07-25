#!/usr/bin/env bash
# scripts/test_installer_ram_full.sh - INSTALLER EFI RAM-DISCOVERY GATE.
#
# PURPOSE
# -------
# Guard the UEFI RAM-discovery path against regressing to the hardcoded
# 240 MiB "EFI fallback window" (arch/x86/kernel/e820.ad EFI_FALLBACK_*).
#
# On a UEFI/OVMF boot the ONLY way the kernel learns about RAM above
# 240 MiB is the EFI memory-map handoff: the efi_stub (arch/x86/boot/
# efi_stub.S) calls GetMemoryMap, stashes {buf,size,desc_size,present=1}
# into the efi_mmap_info handoff struct right before ExitBootServices,
# and e820_init() (arch/x86/kernel/e820.ad) walks those descriptors and
# feeds EVERY free-RAM region above the kernel-image floor into memblock.
#
# If that handoff breaks (an "old stub" that never sets present=1, a
# GetMemoryMap failure, or a walk that finds no usable region) the kernel
# silently falls back to a conservative 2..240 MiB window and the guest
# sees only ~221 MiB regardless of `qemu -m`, wasting the rest and
# starving the desktop/browser into OOM. That was the daily-driver
# memory-pressure bug this gate exists to catch if it ever returns.
#
# WHAT IT ASSERTS (over the EARLY boot serial, before userspace)
# --------------------------------------------------------------
#   1. "e820: feeding memblock from EFI map" IS present
#         -> the EFI walk succeeded (the stub handoff + descriptor walk
#            both worked). Emitted by e820_init() on the good path.
#   2. NONE of the fallback markers appear:
#         "EFI map absent (old stub?)"                 (handoff missing)
#         "no usable region above floor"               (walk found none)
#         "EFI fallback range"                         (2..240 window fed)
#         "keeping memblock default"                   (floor past 240 MiB)
#   3. "[memblock] free: N MiB" with N >= MIN_FREE_MIB
#         -> the memblock pool the kernel actually installed is far above
#            the 240 MiB fallback ceiling. _log_memblock_free() prints the
#            TOTAL free RAM registered (primary region + every extra EFI
#            region) on the EFI path, so this is the real usable figure.
#   4. No fatal trap (TRAP: vector / #DF / triple fault / cpu_reset).
#
# WHY MIN_FREE_MIB is well below `-m`, not near it
# ------------------------------------------------
# The INSTALLER kernel ELF embeds its live payload as an in-place cpio
# initramfs served DIRECTLY out of the blob (fs/cpio.ad
# initramfs_entry_data), which can never be reclaimed and permanently
# reserves that low RAM. Since the LEAN-cpio reclaim
# (scripts/build_installer_img.sh Stage 6, HAMNIX_CPIO_LEAN=1) the giant
# ~1.1 GiB /var/lib/distros/default Debian GUI tree is NO LONGER embedded
# — only the compact ~21.5 MiB /rootfs.sqfs + native /bin + /lib/modules
# + /iso-packages ride in the cpio, so the fixed footprint is now well
# under ~150 MiB. At -m 2G the kernel therefore registers ~1.8 GiB free
# (was ~800 MiB pre-lean); the free pool scales 1:1 with `-m` offset by
# that much smaller initramfs. The threshold is set safely ABOVE the
# 240 MiB fallback ceiling AND above the pre-lean ~800 MiB footprint (so
# a regression that re-fattened the cpio would also trip it) and BELOW
# the observed ~1.8 GiB, so a regression to the fallback (<=240 MiB, or a
# dropped "[memblock] free" line) fails the gate while the healthy
# lean-initramfs boot passes.
#
# Env overrides
# -------------
#   IMG           installer image      (default: build/hamnix-installer.img)
#   MEM           qemu -m value        (default: 2G)
#   MIN_FREE_MIB  min registered free  (default: 1500) MiB the kernel must
#                 install. 1500 is comfortably above BOTH the 240 MiB
#                 fallback ceiling and the pre-lean ~800 MiB footprint,
#                 and below the ~1.8 GiB seen at -m 2G with the lean cpio
#                 — so a fallback regression OR a re-fattened cpio both
#                 fail it. Raise it together with MEM if you gate a
#                 bigger -m.
#   BOOT_TIMEOUT  deadline seconds for the e820 marker (default: 150). The
#                 e820 lines print very early (pre-userspace) so this is a
#                 generous upper bound; the poll exits the instant the
#                 marker appears.
#   OVMF_FD       OVMF firmware        (default: /usr/share/ovmf/OVMF.fd)
#   QEMU_CPU      -cpu model           (default: max; must expose SMAP)
#   QEMU_ACCEL    set to "kvm" for a fast local boot (CI default: TCG)
#   HAMNIX_SKIP_BUILD=1  do not (re)build the image; graceful SKIP (rc 0) if
#                 IMG is absent -- lets a battery shard with no prebuilt
#                 installer image SKIP cleanly (the full build + OVMF boot
#                 runs in the installer CI job / locally).
#   SERIAL_LOG    evaluate a pre-captured log instead of booting (no QEMU)
#   KEEP_LOG=1    keep the temp serial log on exit (debugging)
#
# Pass marker:  [test_installer_ram_full] PASS
# Fail marker:  [test_installer_ram_full] FAIL

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${IMG:-build/hamnix-installer.img}"
MEM="${MEM:-2G}"
MIN_FREE_MIB="${MIN_FREE_MIB:-1500}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-150}"
OVMF_FD="${OVMF_FD:-/usr/share/ovmf/OVMF.fd}"
QEMU_CPU="${QEMU_CPU:-max}"
QEMU_ACCEL="${QEMU_ACCEL:-}"

say() { echo "[test_installer_ram_full] $*"; }

# EFI-walk-succeeded marker (must appear) and the fallback markers that
# must NOT (each is a distinct failure of the handoff/walk path).
GOOD_RE='e820: feeding memblock from EFI map'
FALLBACK_RE='EFI map absent \(old stub\?\)|no usable region above floor|EFI fallback range|keeping memblock default'
MEMBLOCK_RE='\[memblock\] free: [0-9]+ MiB'
# Only ACTUAL fault signatures -- deliberately NOT the bare "#DF" / "double
# fault" tokens, which also appear in benign boot lines that merely install
# the IST-backed #DF handler ("[trap-df] ... #DF handler installed"). A real
# unrecoverable fault surfaces as a "TRAP: vector 0xNN" print, a firmware
# cpu_reset, or the one-shot "[trap-diag] halting" wedge.
FATAL_RE='TRAP: vector|triple fault|cpu_reset|\[trap-diag\] halting'

# --- evaluate(): PASS/FAIL verdict over a serial log ------------------
# Shared by the live-boot path and the SERIAL_LOG logic-only path so the
# verdict logic is asserted identically either way. Returns 0=PASS,1=FAIL.
evaluate() {
    local log="$1"
    local free_mib

    if grep -aE -q "$FATAL_RE" "$log"; then
        say "FAIL: fatal-trap indication present (matched '$FATAL_RE'):"
        grep -aEn "$FATAL_RE" "$log" | head -6 | sed 's/^/    /' >&2
        return 1
    fi

    if grep -aE -q "$FALLBACK_RE" "$log"; then
        say "FAIL: kernel took the EFI 240 MiB FALLBACK path -- the RAM"
        say "      discovery regressed (stub handoff or EFI-map walk broke)."
        grep -aEn "$FALLBACK_RE" "$log" | head -4 | sed 's/^/    /' >&2
        return 1
    fi

    if ! grep -aE -q "$GOOD_RE" "$log"; then
        say "FAIL: '$GOOD_RE' not seen -- the EFI memory-map walk never"
        say "      fed memblock (handoff absent, or boot died before e820)."
        say "--- last 30 serial lines ---"
        tail -30 "$log" | strings | sed 's/^/    /' >&2
        return 1
    fi

    # Pull the MiB integer from the LAST "[memblock] free: N MiB" line
    # (the EFI path prints exactly one; last-wins is robust regardless).
    free_mib=$(grep -aoE "$MEMBLOCK_RE" "$log" | tail -1 | grep -oE '[0-9]+' || true)
    if [ -z "$free_mib" ]; then
        say "FAIL: no '[memblock] free: N MiB' line found -- cannot confirm"
        say "      the size of the installed memblock pool."
        return 1
    fi
    say "kernel registered $free_mib MiB of free RAM (threshold >= $MIN_FREE_MIB MiB, -m $MEM)."
    if [ "$free_mib" -lt "$MIN_FREE_MIB" ]; then
        say "FAIL: registered $free_mib MiB < $MIN_FREE_MIB MiB -- this is the"
        say "      240 MiB-fallback footprint; full RAM was NOT discovered."
        return 1
    fi

    say "EFI memory-map walk fed the full RAM pool; no fallback, no fatal trap."
    return 0
}

# --- logic-only mode: evaluate a pre-captured log, no QEMU ------------
if [ -n "${SERIAL_LOG:-}" ]; then
    if [ ! -f "$SERIAL_LOG" ]; then
        say "FAIL: SERIAL_LOG=$SERIAL_LOG does not exist"; say "FAIL"; exit 1
    fi
    say "logic-only mode: evaluating $SERIAL_LOG (no QEMU boot)"
    if evaluate "$SERIAL_LOG"; then say "PASS"; exit 0; else say "FAIL"; exit 1; fi
fi

# --- ensure the installer image exists (graceful SKIP if absent) -----
# HAMNIX_SKIP_BUILD=1 keeps this gate a fast, clean SKIP (rc 0) on a
# battery shard that has no prebuilt installer image -- the full image
# build + OVMF boot runs in the installer CI job / locally.
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$IMG" "[installer_ram_full]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        say "SKIP: $IMG absent and HAMNIX_SKIP_BUILD=1 (no prebuilt image here)."
        say "SKIP"; exit 0
    fi
    say "image $IMG absent -- building via scripts/build_installer_img.sh (~14 min)"
    HAMNIX_INSTALLER_IMG_OUT="$IMG" bash scripts/build_installer_img.sh || {
        say "SKIP: installer image build failed/gated."; say "SKIP"; exit 0
    }
fi
if [ ! -f "$IMG" ]; then
    say "SKIP: $IMG still missing after build_installer_img.sh."; say "SKIP"; exit 0
fi

# --- OVMF firmware (writable copy: UEFI persists vars into it) --------
if [ ! -f "$OVMF_FD" ]; then
    if [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ ! -f "$OVMF_FD" ]; then
    say "SKIP: OVMF firmware not found (tried $OVMF_FD; apt install ovmf)."
    say "SKIP"; exit 0
fi

ACCEL_ARGS=()
if [ "$QEMU_ACCEL" = "kvm" ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ACCEL_ARGS=(-enable-kvm)
    else
        say "QEMU_ACCEL=kvm requested but /dev/kvm not accessible; using TCG."
    fi
fi

LOG=$(mktemp --tmpdir hamnix-installer-ramfull.XXXXXX.log)
OVMF_RW=$(mktemp --tmpdir hamnix-installer-ramfull.ovmf.XXXXXX.fd)
QEMU_PID=""
cleanup() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_LOG:-0}" = "1" ]; then
        echo "[test_installer_ram_full] KEEP_LOG: serial log at $LOG" >&2
    else
        rm -f "$LOG"
    fi
    rm -f "$OVMF_RW"
}
trap cleanup EXIT INT TERM
cp "$OVMF_FD" "$OVMF_RW"

say "=== installer EFI RAM-discovery gate ==="
say "  image        = $IMG"
say "  firmware     = $OVMF_FD"
say "  memory       = -m $MEM"
say "  min free RAM = $MIN_FREE_MIB MiB   (must be registered; 240 MiB fallback fails)"
say "  good marker  = '$GOOD_RE'   (must appear)"
say "  fallback     = must NOT appear"
say "  deadline     = ${BOOT_TIMEOUT}s (polled; exits early on first marker)"

: > "$LOG"
qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    -cpu "$QEMU_CPU" \
    -bios "$OVMF_RW" \
    -drive "file=$IMG,format=raw,if=virtio" \
    -m "$MEM" \
    -vga std \
    -display none \
    -serial "file:$LOG" \
    -no-reboot \
    -monitor none \
    >/dev/null 2>&1 &
QEMU_PID=$!

# Poll until the decisive marker (good OR fallback OR fatal) appears, or
# QEMU exits, or the deadline elapses. The e820 lines print very early
# (pre-userspace), so this normally resolves within a few seconds.
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
while :; do
    if [ -f "$LOG" ]; then
        if grep -aE -q "$GOOD_RE|$FALLBACK_RE|$FATAL_RE" "$LOG"; then break; fi
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then QEMU_PID=""; break; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        say "deadline reached (${BOOT_TIMEOUT}s) without an e820 verdict marker."
        break
    fi
    sleep 2
done

# Give the "[memblock] free" line (printed just after the GOOD marker) a
# beat to flush before we evaluate.
sleep 1

if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
fi

if evaluate "$LOG"; then
    say "PASS"
    exit 0
fi
say "FAIL"
exit 1
