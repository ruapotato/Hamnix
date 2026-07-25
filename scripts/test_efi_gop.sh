#!/usr/bin/env bash
# scripts/test_efi_gop.sh — Verify the EFI GOP framebuffer console
# actually puts pixels on screen under OVMF.
#
# Strategy:
#   1. Boot build/hamnix.iso under qemu-system-x86_64 + OVMF.
#   2. Use QEMU's stdio monitor (not a unix socket — host has no
#      socat, only netcat, and the QMP unix monitor needs interactive
#      framing) to issue a `screendump` command after a few seconds
#      of boot, capturing the framebuffer into a PPM file.
#   3. Assert the PPM is non-trivial (>30 KiB) — proves pixels were
#      actually written to the GOP framebuffer. A dark/empty screen
#      under PPM compresses heavily, while a kernel-log screenfull
#      of glyphs runs the file size up to ~hundreds of KiB.
#
# The screendump path uses `-display none -vnc :43` so QEMU still
# tracks the framebuffer surface internally; without a display backend
# (e.g. -display none alone), QEMU has nothing to screendump from.
# We could equally use `-display vnc=...`; the `:43` form is the same
# tcp port 5943 wiring.
#
# Success criterion (PASS line is grepped by ci-test.sh):
#   "[test_efi_gop] PASS: EFI GOP framebuffer rendered N bytes"

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# NOTE: do NOT `source _build_lock.sh` here — scripts/build_iso.sh
# (called below) sources it, and a second flock on the same lockfile
# from this parent shell self-deadlocks. build_iso.sh's own lock is
# sufficient for the kernel-rebuild + ISO-build steps. The QEMU
# screendump phase needs no build-serialisation.
#
# We DO source _kernel_iso.sh directly though — it carries no lock,
# it just installs the qemu-system-x86_64 PATH shim, which injects
# `-accel kvm` when /dev/kvm is usable. Without this, the direct
# `qemu-system-x86_64` call below would miss the accelerator.
# shellcheck source=_kernel_iso.sh
source "$PROJ_ROOT/scripts/_kernel_iso.sh"

HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
OVMF_FD="/usr/share/ovmf/OVMF.fd"
SCREENDUMP_DELAY="${SCREENDUMP_DELAY:-6}"
PPM_SIZE_THRESHOLD="${PPM_SIZE_THRESHOLD:-30720}"   # 30 KiB

if [ ! -f "$OVMF_FD" ]; then
    echo "[test_efi_gop] SKIP: $OVMF_FD not found (apt install ovmf)"
    exit 0
fi

# Rebuild only the kernel ELF + ISO. Userland and initramfs are
# stable for this test — what we're verifying is the fb_text.ad +
# header.S + grub.cfg path, which only affects the kernel image and
# how GRUB hands off to it. Skipping the userland build keeps the
# test under ~10s on a fast box and avoids racing scripts/build_user
# (which is serialised by _build_lock anyway, but the wait time
# would still be there).
echo "[test_efi_gop] Rebuilding kernel + ISO..."
if [ ! -f build/user/init.elf ]; then
    # First-run case: pre-existing userland not available. Build it
    # once so the initramfs has something to embed.
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o build/hamnix-kernel.elf >/dev/null
# build_iso.sh is chatty but takes ~30s and we want a single
# end-of-line confirmation in the test log. Capture its output to a
# file and report just the success summary.
ISO_BUILD_LOG=$(mktemp --tmpdir hamnix-iso-build.XXXXXX.log)
if ! bash scripts/build_iso.sh > "$ISO_BUILD_LOG" 2>&1; then
    echo "[test_efi_gop] FAIL: build_iso.sh exited non-zero" >&2
    tail -20 "$ISO_BUILD_LOG" >&2
    exit 1
fi
tail -2 "$ISO_BUILD_LOG"
rm -f "$ISO_BUILD_LOG"

if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_efi_gop] ERROR: $HAMNIX_ISO not found after build." >&2
    exit 1
fi
# Stale-artifact guard: HAMNIX_SKIP_BUILD=1 reuses whatever ISO/rootfs is
# already on disk. Say so LOUDLY when it predates the tree under test.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_warn_if_stale "$HAMNIX_ISO" "[efi_gop]"

# OVMF wants a writable copy because UEFI variables get persisted.
OVMF_RW=$(mktemp --tmpdir ovmf-efi-gop.XXXXXX.fd)
cp "$OVMF_FD" "$OVMF_RW"

PPM_OUT=$(mktemp --tmpdir hamnix-uefi.XXXXXX.ppm)
rm -f "$PPM_OUT"                                  # screendump creates it
SERIAL_LOG=$(mktemp --tmpdir hamnix-uefi.XXXXXX.log)
MON_FIFO=$(mktemp --tmpdir hamnix-mon.XXXXXX.fifo)
rm -f "$MON_FIFO"
mkfifo "$MON_FIFO"

cleanup() {
    rm -f "$OVMF_RW" "$SERIAL_LOG" "$MON_FIFO"
    # Leave PPM behind on failure so a CI investigator can fish it
    # out; clean it up only on PASS (below).
}
trap cleanup EXIT

echo "[test_efi_gop] Launching QEMU with OVMF (UEFI)..."

# Run QEMU in background. Monitor on stdio (read from FIFO);
# serial to a file; framebuffer to internal VNC surface so QEMU can
# screendump it. -display none would discard the framebuffer entirely.
( exec qemu-system-x86_64 \
    -bios "$OVMF_RW" \
    -cdrom "$HAMNIX_ISO" \
    -m 256M \
    -no-reboot \
    -vga std \
    -display none \
    -vnc 127.0.0.1:43 \
    -serial "file:$SERIAL_LOG" \
    -monitor "stdio" \
    < "$MON_FIFO" \
    > /tmp/hamnix-qemu-stdout.$$ 2>&1
) &
QEMU_PID=$!

# Open the FIFO for writing as a long-lived fd. The reader side
# (QEMU's stdin) blocks open() until we open the writer; this is the
# whole point of using a FIFO instead of a regular file.
exec 9>"$MON_FIFO"

# Give the kernel time to boot, print its banner, and run through
# the first few smoke tests — all of which write to the GOP console.
echo "[test_efi_gop] Sleeping ${SCREENDUMP_DELAY}s for kernel boot..."
sleep "$SCREENDUMP_DELAY"

echo "[test_efi_gop] Issuing screendump to $PPM_OUT"
echo "screendump $PPM_OUT" >&9

# Give QEMU a beat to flush the PPM, then quit it.
sleep 1
echo "quit" >&9
exec 9>&-

# Wait for QEMU to actually exit. timeout-guard in case quit doesn't
# take (e.g. monitor disconnected).
wait "$QEMU_PID" 2>/dev/null || true

if [ ! -s "$PPM_OUT" ]; then
    echo "[test_efi_gop] FAIL: $PPM_OUT is empty or missing." >&2
    echo "[test_efi_gop] Serial log tail:" >&2
    tail -40 "$SERIAL_LOG" >&2 || true
    exit 1
fi

PPM_BYTES=$(stat -c%s "$PPM_OUT")
echo "[test_efi_gop] screendump captured: $PPM_OUT ($PPM_BYTES bytes)"

# Sanity-check the framebuffer was actually populated. A blank PPM
# (uniform background) compresses to under ~10 KiB; a banner with
# glyphs blows past 30 KiB easily. Pick a conservative threshold.
if [ "$PPM_BYTES" -lt "$PPM_SIZE_THRESHOLD" ]; then
    echo "[test_efi_gop] FAIL: PPM is only $PPM_BYTES bytes (< $PPM_SIZE_THRESHOLD threshold)." >&2
    echo "[test_efi_gop] Either the framebuffer stayed dark, or QEMU's VNC surface" >&2
    echo "[test_efi_gop] didn't capture the GOP buffer. Serial log tail:" >&2
    tail -40 "$SERIAL_LOG" >&2 || true
    exit 1
fi

# Also cross-check that the serial log shows fb_init succeeded.
# This catches the regression where fb_init bails (e.g. unsupported
# bpp) AND the VGA fallback is dark anyway — without this check the
# PPM might still tip the threshold from OVMF's own splash.
if ! grep -q "fb: EFI GOP framebuffer console ready" "$SERIAL_LOG"; then
    echo "[test_efi_gop] FAIL: serial log missing 'fb: EFI GOP framebuffer console ready'." >&2
    echo "[test_efi_gop] Serial log tail:" >&2
    tail -40 "$SERIAL_LOG" >&2 || true
    exit 1
fi

# Clean PPM only on PASS.
rm -f "$PPM_OUT" /tmp/hamnix-qemu-stdout.$$

echo "[test_efi_gop] PASS: EFI GOP framebuffer rendered $PPM_BYTES bytes"
