#!/usr/bin/env bash
# scripts/test_cpio_capacity.sh - cpio NR_FILES capacity regression.
#
# fs/cpio.ad parses the embedded initramfs cpio "newc" archive into a
# fixed-size in-kernel index, file_table. The historical capacity was
# NR_FILES=192 — far too small for a real debootstrap Debian rootfs
# (~5000 files). The table was raised to 8192 slots (top-level BSS, so
# it costs zero image bytes). This test proves the larger table really
# indexes files PAST the old 192-slot cap.
#
# Mechanism:
#   1. scripts/build_initramfs.py honors HAMNIX_CPIO_STRESS_FILES=<N>:
#      it plants N tiny synthetic files at /cpio-stress/file0../file<N-1>
#      in the initramfs. The LAST one carries the payload
#      "CPIO_STRESS_LAST_FILE_OK\n".
#   2. init/main.ad's cpio_capacity_smoke_test() (gated on the presence
#      of /cpio-stress/* files) walks the registered file table and
#      asserts: total file count > 192, a /cpio-stress/* entry exists at
#      index >= 192, and the last-file marker payload reads back
#      correctly via initramfs_entry_data/_size.
#   3. We build the BIOS ISO with the stress files planted, boot it
#      under SeaBIOS, and grep the serial log for `[cpio_cap] PASS`.
#
# Default boots (and every other test) ship NO /cpio-stress/* files, so
# the smoke is a no-op skip there — this fixture is the only thing that
# exercises the past-192 path.
#
# Pass marker:  [test_cpio_capacity] PASS
# Fail marker:  [test_cpio_capacity] FAIL
#
# Env overrides:
#   HAMNIX_CPIO_STRESS_FILES  synthetic file count   (default: 600)
#   CPIO_BOOT_TIMEOUT         seconds for the run    (default: 40)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

# 600 files: comfortably past the old 192 cap (so an entry lands at
# index >= 192) yet small enough that fs/initramfs_blob.S stays tiny
# and the boot is quick. The same path scales to 8192.
STRESS_FILES="${HAMNIX_CPIO_STRESS_FILES:-600}"
CPIO_BOOT_TIMEOUT="${CPIO_BOOT_TIMEOUT:-40}"
HAMNIX_ISO="build/hamnix.iso"

if [ "$STRESS_FILES" -le 192 ]; then
    echo "[test_cpio_capacity] FAIL: HAMNIX_CPIO_STRESS_FILES must exceed 192" >&2
    echo "[test_cpio_capacity] FAIL"
    exit 1
fi

echo "[test_cpio_capacity] Building ISO with $STRESS_FILES synthetic cpio files"
rm -f "$HAMNIX_ISO"
HAMNIX_CPIO_STRESS_FILES="$STRESS_FILES" bash "$PROJ_ROOT/scripts/build_iso.sh"

if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_cpio_capacity] FAIL: $HAMNIX_ISO missing after build_iso.sh." >&2
    echo "[test_cpio_capacity] FAIL"
    exit 1
fi
# Stale-artifact guard: HAMNIX_SKIP_BUILD=1 reuses whatever ISO/rootfs is
# already on disk. Say so LOUDLY when it predates the tree under test.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_warn_if_stale "$HAMNIX_ISO" "[cpio_capacity]"

LOGFILE=$(mktemp --tmpdir hamnix-cpio-capacity.XXXXXX.log)
cleanup() { rm -f "$LOGFILE"; }
trap cleanup EXIT

echo "[test_cpio_capacity] === BIOS boot (timeout ${CPIO_BOOT_TIMEOUT}s) ==="
set +e
timeout "${CPIO_BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -cdrom "$HAMNIX_ISO" \
    -m 256M \
    -nographic \
    -no-reboot \
    -monitor none \
    -serial stdio \
    2>&1 | tee "$LOGFILE"
rc=${PIPESTATUS[0]}
set -e

# rc=124 is the expected timeout kill (kernel keeps running); rc=0 a
# clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_cpio_capacity] FAIL: qemu exited rc=$rc" >&2
    echo "[test_cpio_capacity] FAIL"
    exit 1
fi

# The kernel must have booted at all.
if ! grep -a -q -E "Hamnix kernel booting" "$LOGFILE"; then
    echo "[test_cpio_capacity] FAIL: kernel banner not detected." >&2
    echo "[test_cpio_capacity] FAIL"
    exit 1
fi

# A FAIL line from the smoke is fatal regardless of anything else.
if grep -a -q -E "\[cpio_cap\] FAIL" "$LOGFILE"; then
    echo "[test_cpio_capacity] FAIL: kernel cpio_capacity smoke reported FAIL:" >&2
    grep -a -E "\[cpio_cap\]" "$LOGFILE" >&2 || true
    echo "[test_cpio_capacity] FAIL"
    exit 1
fi

if ! grep -a -q -E "\[cpio_cap\] PASS" "$LOGFILE"; then
    echo "[test_cpio_capacity] FAIL: '[cpio_cap] PASS' not found in serial log." >&2
    grep -a -E "\[cpio_cap\]|cpio: registered" "$LOGFILE" >&2 || true
    echo "[test_cpio_capacity] FAIL"
    exit 1
fi

echo "[test_cpio_capacity] cpio_capacity smoke:"
grep -a -E "\[cpio_cap\]|cpio: registered" "$LOGFILE" | sed 's/^/    /'
echo "[test_cpio_capacity] PASS"
