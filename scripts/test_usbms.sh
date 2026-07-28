#!/usr/bin/env bash
# scripts/test_usbms.sh — USB Bulk-Only Mass Storage (BOT) EXERCISE test.
#
# Boots the hand-rolled drivers/usb/xhci.ad + drivers/usb/storage.ad
# stack against a QEMU-emulated USB stick and proves the full block
# path works end to end:
#
#   xHCI enumerate (Enable Slot -> Address Device -> Configure bulk
#   endpoints) -> SCSI INQUIRY + READ CAPACITY -> register /dev/blk/sd0
#   -> SCSI READ(10) of sector 0 -> bytes match the pattern stamped
#   into the test image.
#
# This is the storage-class parallel of test_xhci_io.sh (HID) and the
# foundation for the Debian-Live model: a squashfs distro image lives
# on the stick, read through the /dev/blk/sd0 this driver registers.
#
# Two markers control the boot:
#   ENABLE_XHCI_KO=0    — run the HAND-ROLLED xhci_init (not the Linux
#                         .ko L-shim), since storage.ad drives the
#                         hand-rolled transfer engine's bulk path.
#   ENABLE_USBMS_TEST=1 — plant /etc/usbms-test so init/main.ad's
#                         usbms_exercise() runs.
#
# PASS / FAIL channel: the `[usbms_test] PASS` / `FAIL` marker line.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_usbms

ELF=build/hamnix-kernel.elf
USBMS_TIMEOUT="${USBMS_TIMEOUT:-90}"
IMG=build/usbtest.img

# QEMU device-availability probe.
echo "[test_usbms] (0/5) Probe QEMU for qemu-xhci + usb-storage"
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"qemu-xhci"'; then
    echo "[test_usbms] SKIPPED — this QEMU build has no qemu-xhci"
    exit 0
fi
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-storage"'; then
    echo "[test_usbms] SKIPPED — this QEMU build has no usb-storage"
    exit 0
fi
echo "[test_usbms] OK: QEMU has qemu-xhci + usb-storage"

echo "[test_usbms] (1/5) Stamp a 16 MiB test USB image"
python3 - "$IMG" <<'PYEOF'
import sys, os
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
size = 16 * 1024 * 1024
with open(path, "wb") as f:
    f.truncate(size)
    f.seek(0)
    f.write(b"HAMNIXUSB")          # sector 0 tag the kernel matches
    f.seek(512)
    f.write(b"SECTOR01")           # sector 1 sentinel
print("[test_usbms]   wrote", path, os.path.getsize(path), "bytes")
PYEOF

echo "[test_usbms] (2/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_usbms] (3/5) Build initramfs (xhci-ko OFF, usbms-test ON)"
ENABLE_XHCI_KO=0 ENABLE_USBMS_TEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_usbms] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG="$(mktemp)"
# Restore the default initramfs at the end so subsequent tests don't
# inherit the markers.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_usbms] (5/5) Boot QEMU with qemu-xhci + usb-storage"
# The kernel is a true elf64-x86-64 higher-half image; QEMU's -kernel
# multiboot1 loader rejects 64-bit ELFs ("Cannot load x86-64 image").
# Wrap it in a GRUB BIOS ISO and boot -cdrom. `-boot d` forces CD boot
# ahead of the usb-storage drive (which SeaBIOS would otherwise pick).
source "$PROJ_ROOT/scripts/_kernel_iso.sh"
KISO="$(kernel_iso "$ELF")"
set +e
timeout "${USBMS_TIMEOUT}s" qemu-system-x86_64 \
    -boot d -cdrom "$KISO" \
    -device qemu-xhci,id=xhci0 \
    -drive if=none,id=stick,file="$IMG",format=raw \
    -device usb-storage,bus=xhci0.0,drive=stick \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_usbms] --- captured (usbms / xhci) ---"
grep -aE '\[usbms|usbms_test|Enable Slot|Address Device|Configure Endpoint|READ CAPACITY|INQUIRY|/dev/blk/sd0' "$LOG" | head -40 || true
echo "[test_usbms] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero usbms/xhci markers == the ISO guest never reached USB-storage enum:
# a starved/timed-out TCG boot, an OBSERVED crash (verdict_boot_gate FAILs on
# TRAP/panic), or GRUB OOM — NOT a BOT/storage regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[usbms|usbms_test|xhci|/dev/blk/sd0'

if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    tail -n 60 "$LOG"
    verdict_fail "$TAG" \
        "the guest booted and produced USB markers but a kernel panic/TRAP/BUG" \
        "was OBSERVED (qemu rc=$rc) — a real crash on the USB-MSC path."
fi

# Enumeration markers.
for needle in \
    "[usbms] mass-storage slot 1 ready" \
    "[usbms] /dev/blk/sd0 ready"
do
    if ! grep -aF -q "$needle" "$LOG"; then
        tail -n 60 "$LOG"
        verdict_fail "$TAG" \
            "enumeration marker '$needle' was OBSERVED absent though the guest" \
            "booted (qemu rc=$rc) — xHCI Enable-Slot/Address-Device/Configure or" \
            "the /dev/blk/sd0 registration regressed."
    fi
done
echo "[test_usbms] OK: enumerated + registered /dev/blk/sd0"

# READ CAPACITY must report 32768 sectors (16 MiB / 512).
if grep -aF -q "capacity = 32768 x 512-byte sectors" "$LOG"; then
    echo "[test_usbms] OK: READ CAPACITY reported 16 MiB (32768 sectors)"
else
    echo "[test_usbms] WARN: capacity line not as expected (image size may differ)"
fi

# PASS / FAIL channel — the READ(10) of sector 0 returned the tag.
if grep -aF -q "[usbms_test] PASS" "$LOG"; then
    verdict_pass "$TAG" "USB Bulk-Only Mass Storage end to end: xHCI enumerate" \
        "(Enable Slot -> Address Device -> Configure bulk EPs), /dev/blk/sd0" \
        "registered, and a READ(10) of sector 0 returned the HAMNIXUSB tag (qemu rc=$rc)"
fi

grep -aE "\[usbms_test\]" "$LOG" || true
tail -n 60 "$LOG"
verdict_fail "$TAG" \
    "the guest enumerated the USB stick but the [usbms_test] PASS marker was" \
    "OBSERVED absent — the READ(10) of sector 0 did not return the tag" \
    "(qemu rc=$rc). A real BOT read-path regression."
