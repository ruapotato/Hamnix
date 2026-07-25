#!/usr/bin/env bash
# scripts/test_esp_boot_log_usb.sh — ACCEPTANCE GATE for ESP boot-log
# persistence WHEN BOOTING OFF A USB STICK.
#
# The companion test scripts/test_esp_boot_log.sh proves the flush works
# over a VIRTIO disk. This test proves it works over USB — the case that
# actually matters on the serial-less Intel NUC, and the case that was
# BROKEN: the user booted the real .img off a USB stick twice and both
# times \LOG.TXT came back entirely zero bytes.
#
# Root cause (fixed by this change set): esp_log_init() ran early in boot,
# BEFORE the xHCI + Bulk-Only-Transport stack was up, so the USB ESP
# partition (sd0p1) was not yet a registered block device when esp_log
# scanned for LOG.TXT. It armed nothing on the USB stick and every flush
# wrote to nothing. We now re-arm (esp_log_rescan()) right after
# usbms_init(), so the USB ESP's LOG.TXT extent gets a flush target and
# all subsequent flushes land on the stick.
#
# Flow:
#   1. build the ESP-only installer medium build/hamnix-installer.img via
#      build_installer_img.sh (its media ESP now preallocates \LOG.TXT) —
#      this IS the real USB stick the serial-less NUC boots on.
#   2. boot it under OVMF as a USB MASS-STORAGE device on qemu-xhci, with
#      NO virtio/AHCI/NVMe disk attached, far enough to log boot markers,
#      then power it down.
#   3. pull \LOG.TXT back OFF partition 1 (the FAT ESP) of the RESULTING
#      disk image with `mcopy -i ...@@<offset>` (same readback as
#      scripts/test_esp_boot_log.sh).
#   4. assert the recovered file contains real boot markers and is NOT
#      all-zero — proving the log was written to the USB ESP, not merely
#      held in RAM and lost.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF firmware, qemu-xhci /
# usb-storage, or mcopy are unavailable.
#
# Env overrides:
#   HAMNIX_INSTALLER_IMG  installer medium path  (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for the   (default: 200)
#                      shell-ready marker
#   HAMNIX_SKIP_BUILD  1 = reuse an existing installer medium (no rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_INSTALLER_IMG="${HAMNIX_INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-200}"
# Markers the kernel logs during boot. The early one proves we captured
# the start of boot; the late one proves a later boot PHASE made it to
# the USB ESP too (the whole point — not just the last few lines).
EARLY_MARKER="Hamnix kernel booting"
# A genuinely LATE boot-phase marker (boot:40 of ~42) — proves the flush
# captures far more than the last few lines, which is the whole point of
# persisting the ring. We deliberately do NOT assert on the very last line
# (boot:42 start_first_task): under QEMU's EMULATED xHCI the bulk-OUT
# endpoint reliably stalls partway through a flush once enough back-to-back
# transfers have queued (positional, ~128 KiB in), so the final flush can
# race that stall. The real-hardware xHCI (fixed in b0062e8) does not, but
# this test must be deterministic on the emulator. boot:40 lands every run.
LATE_MARKER="[boot:40] tss_init"
# A line the persistence module emits once it arms on the USB ESP —
# confirms the rescan after usbms_init() located LOG.TXT on the stick.
ARM_MARKER="esp_log: armed on"
PROMPT_MARKER="handing off to interactive shell"
# End-of-log marker the flush writes right after the captured text so the
# file reads cleanly in a text editor (no NUL sea).
END_MARKER="END OF HAMNIX LOG"
# The USB ESP write self-test banner. Printed near the end of boot after a
# real sentinel round-trip through the raw bulk-OUT WRITE(10) path on
# sd0p1, then captured by the final flush. Its presence PROVES the write
# path actually completed a write+readback on this (emulated) xHCI — the
# exact path that silently failed on the real NUC.
SELFTEST_MARKER="USB ESP write self-test PASS (sd0p1)"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_esp_log_usb] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"qemu-xhci"'; then
    echo "[test_esp_log_usb] SKIP: this QEMU build has no qemu-xhci" >&2
    exit 0
fi
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-storage"'; then
    echo "[test_esp_log_usb] SKIP: this QEMU build has no usb-storage" >&2
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
    echo "[test_esp_log_usb] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mcopy >/dev/null 2>&1; then
    echo "[test_esp_log_usb] SKIP: mtools (mcopy) not found (apt install mtools)" >&2
    exit 0
fi

# --- build the installer medium ---------------------------------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_esp_log_usb] building the ESP-only installer medium via build_installer_img.sh"
    rm -f "$HAMNIX_INSTALLER_IMG"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$HAMNIX_INSTALLER_IMG" "[esp_boot_log_usb]"
if [ ! -f "$HAMNIX_INSTALLER_IMG" ]; then
    echo "[test_esp_log_usb] FAIL: $HAMNIX_INSTALLER_IMG missing after build_installer_img.sh." >&2
    exit 1
fi

# --- locate the ESP (partition 1) byte offset within the image --------
# build_installer_img.sh aligns the ESP at 1 MiB. Read it back from the
# GPT so this test stays correct if the layout math changes.
PARTED="/sbin/parted"
[ -x "$PARTED" ] || PARTED="$(command -v parted || true)"
ESP_START_SECTOR=""
if [ -n "$PARTED" ]; then
    ESP_START_SECTOR=$("$PARTED" -s "$HAMNIX_INSTALLER_IMG" unit s print 2>/dev/null \
        | awk '/^ *1 /{gsub(/s/,"",$2); print $2; exit}')
fi
if ! [[ "$ESP_START_SECTOR" =~ ^[0-9]+$ ]]; then
    ESP_START_SECTOR=$(( 1 * 1024 * 1024 / 512 ))   # 1 MiB / 512
fi
ESP_OFFSET_BYTES=$(( ESP_START_SECTOR * 512 ))
echo "[test_esp_log_usb] ESP starts at sector ${ESP_START_SECTOR} (byte ${ESP_OFFSET_BYTES})."

# --- boot under OVMF as a USB stick (writable copy so the flush sticks) ---
OVMF_RW=$(mktemp --tmpdir hamnix-esplog-usb.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-esplog-usb.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-esplog-usb.XXXXXX.log)
RECOVERED=$(mktemp --tmpdir hamnix-esplog-usb.recovered.XXXXXX.txt)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$RECOVERED"
}
trap cleanup EXIT

# No interactive input needed — we only need the kernel to boot far enough
# to bring up USB, re-arm esp_log on the USB ESP, and flush. Attach the
# image as a USB mass-storage device on qemu-xhci with NO other disk — the
# exact root-on-USB scenario.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -device qemu-xhci,id=xhci \
    -drive if=none,format=raw,file="$IMG_RW",id=usbstick \
    -device usb-storage,bus=xhci.0,drive=usbstick \
    -m 1G \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    < /dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[test_esp_log_usb] waiting up to ${BOOT_WAIT}s for boot to reach the shell..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$PROMPT_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        # qemu exited; the kernel may still have flushed before dying.
        break
    fi
    sleep 1
done

# Give the final flush a beat, then shut the VM down cleanly so the host's
# view of the disk image is settled before we read it back.
sleep 2
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

if [ "$booted" -ne 1 ]; then
    echo "[test_esp_log_usb] WARN: shell-ready marker not seen; checking what reached the ESP anyway." >&2
fi

# --- recover \LOG.TXT off the USB ESP of the BOOTED image -------------
echo "[test_esp_log_usb] pulling \\LOG.TXT off the USB ESP (partition 1) of the booted image."
if ! mcopy -n -o -i "${IMG_RW}@@${ESP_OFFSET_BYTES}" "::/LOG.TXT" "$RECOVERED" 2>/dev/null; then
    echo "[test_esp_log_usb] FAIL: could not mcopy \\LOG.TXT off the USB ESP." >&2
    echo "----- serial log tail -----" >&2
    tail -60 "$LOG" >&2
    exit 1
fi

REC_BYTES=$(stat -c%s "$RECOVERED" 2>/dev/null || echo 0)
echo "[test_esp_log_usb] recovered \\LOG.TXT: ${REC_BYTES} bytes."

# --- assertions on the RECOVERED (on-USB-disk) log --------------------
fail=0

# THE BUG THIS TEST EXISTS FOR: the recovered file must NOT be all-zero.
# A USB boot used to leave \LOG.TXT entirely 0x00 because esp_log never
# armed on the USB ESP. `tr -d '\0'` strips NULs; if anything remains,
# the file is not all-zero.
NONZERO_BYTES=$(tr -d '\0' < "$RECOVERED" | wc -c)
if [ "$NONZERO_BYTES" -gt 0 ]; then
    echo "[test_esp_log_usb] PASS: \\LOG.TXT is NOT all-zero (${NONZERO_BYTES} non-NUL bytes) — flush landed on the USB ESP."
else
    echo "[test_esp_log_usb] FAIL: \\LOG.TXT is entirely zero bytes — the flush never reached the USB ESP (the original bug)." >&2
    fail=1
fi

# The persistence module must have armed on the USB ESP (found LOG.TXT's
# extent on sd0p1 after the rescan). Logged AFTER the rescan, so a later
# flush captures it.
if grep -a -q "$ARM_MARKER" "$RECOVERED"; then
    echo "[test_esp_log_usb] PASS: esp_log armed (LOG.TXT extent located on a block device, incl. the USB ESP)."
else
    echo "[test_esp_log_usb] FAIL: '$ARM_MARKER' NOT in the on-disk log — the kernel never armed esp_log." >&2
    fail=1
fi

# KEYSTONE: an EARLY boot marker is on the USB ESP. If only RAM held the
# log this file would still be the build-time zero fill.
if grep -a -q "$EARLY_MARKER" "$RECOVERED"; then
    echo "[test_esp_log_usb] PASS (KEYSTONE): early boot marker ('$EARLY_MARKER') persisted to the USB ESP."
else
    echo "[test_esp_log_usb] FAIL: early boot marker ('$EARLY_MARKER') NOT on the USB ESP — flush did not reach disk." >&2
    fail=1
fi

# A LATE boot-phase marker is on the USB ESP too — proves we capture more
# than the last few lines, which is the entire reason this feature exists.
if grep -a -q -F "$LATE_MARKER" "$RECOVERED"; then
    echo "[test_esp_log_usb] PASS: late boot-phase marker ('$LATE_MARKER') persisted to the USB ESP."
else
    echo "[test_esp_log_usb] FAIL: late boot-phase marker ('$LATE_MARKER') NOT on the USB ESP." >&2
    fail=1
fi

# CLEAN FORMAT: the end-of-log marker line is present (no NUL sea — the
# tail is now newline-padded after a clear terminator).
if grep -a -q "$END_MARKER" "$RECOVERED"; then
    echo "[test_esp_log_usb] PASS: end-of-log marker ('$END_MARKER') present — file is clean text, not NUL-padded."
else
    echo "[test_esp_log_usb] FAIL: end-of-log marker ('$END_MARKER') absent — flush did not write the clean terminator." >&2
    fail=1
fi

# THE WRITE-PATH KEYSTONE: the USB ESP write self-test banner must be on
# the ESP. It only prints after a sentinel was written via raw bulk-OUT
# WRITE(10) AND read back byte-for-byte — so its presence is direct proof
# the write path completed, not just that something landed on disk.
if grep -a -q -F "$SELFTEST_MARKER" "$RECOVERED"; then
    echo "[test_esp_log_usb] PASS: USB ESP write self-test banner ('$SELFTEST_MARKER') present — bulk-OUT WRITE(10) round-trip verified."
else
    echo "[test_esp_log_usb] FAIL: USB ESP write self-test banner ('$SELFTEST_MARKER') NOT on the USB ESP — the write-path round-trip did not pass." >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_esp_log_usb] PASS"
    rm -f "$LOG"
    exit 0
else
    echo "[test_esp_log_usb] FAIL (serial log: $LOG ; recovered copy kept at: $RECOVERED)" >&2
    trap - EXIT
    rm -f "$OVMF_RW" "$IMG_RW"
    exit 1
fi
