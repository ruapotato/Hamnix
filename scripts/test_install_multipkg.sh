#!/usr/bin/env bash
# scripts/test_install_multipkg.sh
#
# Multi-package install regression test.
#
# Asserts the install_file_to_slot kernel path can lay down MULTIPLE
# distinct files on a freshly-formatted ext4 target partition without
# the dd_blk byte-copy clobbering pattern. This is the proof-of-concept
# for splitting `hamnix-base` into component packages: each `hpm install
# <pkg>` writes its files independently, no last-package-wins.
#
# Stages:
#   A: build ISO + a blank target qcow2 (vdb).
#   B: boot ISO, run /etc/install_multipkg.hamsh (NEW installer that
#      uses install_file_to_slot, NOT dd_blk). The script partitions
#      the target, mkfs's both partitions, then writes from_a.txt and
#      from_b.txt onto the target rootfs one after the other.
#   C: read the target ext4 OFFLINE via host-side debugfs (e2fsprogs)
#      and assert BOTH from_a.txt and from_b.txt are present + carry
#      their SCRATCH_*_PAYLOAD markers. install_multipkg.hamsh doesn't
#      lay down a bootloader, so an in-QEMU "boot from target alone"
#      would dead-end at UEFI; the on-disk check is the right shape.
#
# Markers asserted, Stage B:
#   "[install_multipkg] start"
#   "[gpt] init OK"
#   "mkfs_ext4: /dev/blk/vdbp2 OK"
#   "install_file_to_slot: /dev/blk/vdbp2 <- from_a.txt"
#   "install_file_to_slot: /dev/blk/vdbp2 <- from_b.txt"
#   "[install_multipkg] install complete"
#   "install_file_to_slot ... OK" appears AT LEAST 2x (both packages).
#
# Asserted on the offline disk, Stage C:
#   debugfs `ls /`     must list from_a.txt AND from_b.txt
#   debugfs `cat from_a.txt`  must contain SCRATCH_A_PAYLOAD
#   debugfs `cat from_b.txt`  must contain SCRATCH_B_PAYLOAD
#
# Env overrides:
#   BOOT_TIMEOUT  per-stage seconds         (default: 60)
#   TARGET_SIZE   qcow2 size                (default: 2G)
#   KEEP_LOGS=1   keep log + qcow2 artifacts on PASS

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
TARGET_SIZE="${TARGET_SIZE:-2G}"
HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
TARGET_IMG="${TARGET_IMG:-build/installed-multipkg.qcow2}"

# --- Stage A: build artifacts ----------------------------------------
echo "[test_install_multipkg] Stage A: build ISO + blank target"
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    rm -f "$HAMNIX_ISO"
    bash "$PROJ_ROOT/scripts/build_iso.sh" >/dev/null
fi
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_install_multipkg] FAIL Stage A: ISO not built" >&2
    exit 1
fi
# Stale-artifact guard: HAMNIX_SKIP_BUILD=1 reuses whatever ISO/rootfs is
# already on disk. Say so LOUDLY when it predates the tree under test.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_warn_if_stale "$HAMNIX_ISO" "[install_multipkg]"

rm -f "$TARGET_IMG"
qemu-img create -f qcow2 "$TARGET_IMG" "$TARGET_SIZE" >/dev/null
echo "[test_install_multipkg] Stage A: target $TARGET_IMG ($TARGET_SIZE)"

# --- Stage B: install via install_multipkg.hamsh ---------------------
echo "[test_install_multipkg] Stage B: boot ISO and run install_multipkg.hamsh"
STAGE_B_LOG=$(mktemp --tmpdir hamnix-multipkg-stageB.XXXXXX.log)

set +e
(
    sleep 5
    printf 'hamsh /etc/install_multipkg.hamsh\n'
    sleep 15
    printf 'echo MULTIPKG_DONE\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -drive "file=$HAMNIX_ISO,if=virtio,format=raw,readonly=on" \
    -drive "file=$TARGET_IMG,if=virtio,format=qcow2" \
    -smp 2 -m 512M -nographic -no-reboot -monitor none -serial stdio \
    > "$STAGE_B_LOG" 2>&1
RC_B=$?
set -e

echo "[test_install_multipkg] Stage B QEMU rc=$RC_B (124 = timeout-killed, normal)"

stage_b_fail=0
check_marker() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_B_LOG"; then
        echo "[test_install_multipkg]   OK : $label"
    else
        echo "[test_install_multipkg]   MISS: $label" >&2
        stage_b_fail=1
    fi
}
check_marker '\[install_multipkg\] start' "installer banner"
check_marker '\[gpt\] init OK' "gpt_init"
check_marker 'mkfs_ext4: /dev/blk/vdbp2' "mkfs_ext4 target rootfs"
check_marker 'install_file_to_slot: /dev/blk/vdbp2 <- from_a.txt' "package A install"
check_marker 'install_file_to_slot: /dev/blk/vdbp2 <- from_b.txt' "package B install"
check_marker 'mkdir_at_slot: /dev/blk/vdbp2 mkdir opt/hamnix/emptydir/ OK' "package C mkdir (empty nested dir, trailing slash)"
check_marker '\[install_multipkg\] install complete' "installer complete"

# BUG #132: the install-time mkdir verb (ext4_mkdir_at_slot) used to
# reject the trailing slash tar dir entries carry, logging
# "[ext4_mkdir] slot=N FAIL" for every dir. Assert that FAIL is GONE.
if grep -aE -q '\[ext4_mkdir\] slot=[0-9]+ FAIL' "$STAGE_B_LOG"; then
    echo "[test_install_multipkg]   MISS: [ext4_mkdir] slot=N FAIL present (BUG #132 regression)" >&2
    grep -aE '\[ext4_mkdir\]' "$STAGE_B_LOG" | head -5 >&2 || true
    stage_b_fail=1
else
    echo "[test_install_multipkg]   OK : no [ext4_mkdir] slot=N FAIL lines (BUG #132)"
fi
# Positive: the kernel logged the mkdir OK for the target slot.
check_marker '\[ext4_mkdir\] slot=[0-9]+ OK' "kernel ext4_mkdir OK"

# Both userland-side OK reports for install_file_to_slot must be present —
# that line only prints when the kernel's sys_write into <dev>/ctl
# returned a positive byte count (i.e. ext4_install_file_to_slot succeeded
# in the kernel). Two OK reports = both packages got installed.
ifs_ok=$(grep -aE -c 'install_file_to_slot: /dev/blk/vdbp2 <- .* OK' "$STAGE_B_LOG" || true)
if [ "$ifs_ok" -ge 2 ]; then
    echo "[test_install_multipkg]   OK : install_file_to_slot OK ×$ifs_ok"
else
    echo "[test_install_multipkg]   MISS: install_file_to_slot OK appeared $ifs_ok times (need 2)" >&2
    stage_b_fail=1
fi

if [ "$stage_b_fail" -ne 0 ]; then
    echo "[test_install_multipkg] Stage B FAILED — last 80 lines of log:" >&2
    tail -80 "$STAGE_B_LOG" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG"
    fi
    exit 1
fi
echo "[test_install_multipkg] Stage B: PASS"

# --- Stage C: read the target ext4 offline + verify both files ------
#
# We use debugfs (e2fsprogs) on the target qcow2 directly. The
# install_multipkg.hamsh installer doesn't lay down a bootloader (only
# the rootfs payload), so booting from the target alone would land in
# UEFI's "no boot device" prompt — that's expected. The relevant
# question is whether the bytes hit the ext4 partition correctly, and
# debugfs reads the FS purely offline + cross-checks Linux's own ext4
# parser against the bytes our kernel wrote. If our writer corrupted
# the FS, debugfs would surface it (bad superblock, lost+found, etc).
echo "[test_install_multipkg] Stage C: offline ext4 inspection via debugfs"
STAGE_C_LOG=$(mktemp --tmpdir hamnix-multipkg-stageC.XXXXXX.log)

# Need debugfs from e2fsprogs. Path is normally /sbin/debugfs or
# /usr/sbin/debugfs; fall through to plain `debugfs` for distros that
# expose it on PATH.
DEBUGFS_BIN=""
for cand in /usr/sbin/debugfs /sbin/debugfs debugfs; do
    if command -v "$cand" >/dev/null 2>&1; then
        DEBUGFS_BIN="$cand"
        break
    fi
done
if [ -z "$DEBUGFS_BIN" ]; then
    echo "[test_install_multipkg] Stage C SKIP: debugfs (e2fsprogs) not installed" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG" "$STAGE_C_LOG" "$TARGET_IMG"
    fi
    echo "[test_install_multipkg] ALL STAGES PASS (Stage C skipped — install debugfs to verify offline)"
    exit 0
fi

# Convert qcow2 → raw so debugfs can address it. The raw image carries
# the GPT we wrote in step 2 of the installer, so we need to compute
# the byte offset of partition 2 (the rootfs) and pass it via debugfs's
# `?offset=N` syntax.
TARGET_RAW=$(mktemp --tmpdir hamnix-multipkg-stageC.XXXXXX.img)
qemu-img convert -O raw "$TARGET_IMG" "$TARGET_RAW"

# Read the GPT to find partition 2's start LBA. The kernel installer
# uses GPT partition layout: ESP at LBA 2048, rootfs at LBA 67584
# (defaults baked into hamnix_partition for a 2 GiB disk). Parse it
# from sfdisk for robustness against future layout shifts. sfdisk lives
# under /sbin which isn't always on PATH for non-root shells.
SFDISK_BIN=""
for cand in /usr/sbin/sfdisk /sbin/sfdisk sfdisk; do
    if command -v "$cand" >/dev/null 2>&1; then
        SFDISK_BIN="$cand"
        break
    fi
done
if [ -z "$SFDISK_BIN" ]; then
    echo "[test_install_multipkg] Stage C FAIL: sfdisk (util-linux) not installed" >&2
    rm -f "$TARGET_RAW"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$STAGE_B_LOG" "$STAGE_C_LOG" "$TARGET_IMG"
    exit 1
fi
P2_START_LBA=$("$SFDISK_BIN" -d "$TARGET_RAW" 2>/dev/null | grep -E "^${TARGET_RAW}2 " \
               | sed -E 's/.*start= *([0-9]+).*/\1/' | head -1)
if [ -z "$P2_START_LBA" ]; then
    echo "[test_install_multipkg] Stage C FAIL: cannot read GPT partition 2 start" >&2
    "$SFDISK_BIN" -d "$TARGET_RAW" >&2 || true
    rm -f "$TARGET_RAW"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$STAGE_B_LOG" "$STAGE_C_LOG" "$TARGET_IMG"
    exit 1
fi
P2_OFFSET=$((P2_START_LBA * 512))
echo "[test_install_multipkg]   partition 2 starts at LBA $P2_START_LBA (byte offset $P2_OFFSET)"

stage_c_fail=0
"$DEBUGFS_BIN" -R "ls /" "${TARGET_RAW}?offset=${P2_OFFSET}" >"$STAGE_C_LOG" 2>&1 || true
if grep -aE -q ' from_a.txt' "$STAGE_C_LOG"; then
    echo "[test_install_multipkg]   OK : from_a.txt present on target ext4"
else
    echo "[test_install_multipkg]   MISS: from_a.txt absent from target ext4 root" >&2
    stage_c_fail=1
fi
if grep -aE -q ' from_b.txt' "$STAGE_C_LOG"; then
    echo "[test_install_multipkg]   OK : from_b.txt present on target ext4"
else
    echo "[test_install_multipkg]   MISS: from_b.txt absent from target ext4 root" >&2
    stage_c_fail=1
fi

# Content check: each file must carry its scratch marker. This catches
# a partial-write / wrong-content corner that the dirent-only check
# above would miss.
"$DEBUGFS_BIN" -R "cat from_a.txt" "${TARGET_RAW}?offset=${P2_OFFSET}" \
        > "${STAGE_C_LOG}.from_a" 2>&1 || true
"$DEBUGFS_BIN" -R "cat from_b.txt" "${TARGET_RAW}?offset=${P2_OFFSET}" \
        > "${STAGE_C_LOG}.from_b" 2>&1 || true
if grep -aE -q 'SCRATCH_A_PAYLOAD' "${STAGE_C_LOG}.from_a"; then
    echo "[test_install_multipkg]   OK : from_a.txt content (SCRATCH_A_PAYLOAD marker)"
else
    echo "[test_install_multipkg]   MISS: from_a.txt content corrupt (no SCRATCH_A_PAYLOAD)" >&2
    head -5 "${STAGE_C_LOG}.from_a" >&2 || true
    stage_c_fail=1
fi
if grep -aE -q 'SCRATCH_B_PAYLOAD' "${STAGE_C_LOG}.from_b"; then
    echo "[test_install_multipkg]   OK : from_b.txt content (SCRATCH_B_PAYLOAD marker)"
else
    echo "[test_install_multipkg]   MISS: from_b.txt content corrupt (no SCRATCH_B_PAYLOAD)" >&2
    head -5 "${STAGE_C_LOG}.from_b" >&2 || true
    stage_c_fail=1
fi

# BUG #132: the empty nested dir created via the mkdir verb (with a
# trailing slash) must actually exist on the installed ext4 — proof
# that an empty-dir package is no longer silently dropped. Walk the
# path offline: /opt, /opt/hamnix, /opt/hamnix/emptydir must all be
# directories.
"$DEBUGFS_BIN" -R "ls /opt/hamnix" "${TARGET_RAW}?offset=${P2_OFFSET}" \
        > "${STAGE_C_LOG}.emptydir" 2>&1 || true
if grep -aE -q ' emptydir' "${STAGE_C_LOG}.emptydir"; then
    echo "[test_install_multipkg]   OK : /opt/hamnix/emptydir present on target ext4 (nested empty dir)"
else
    echo "[test_install_multipkg]   MISS: /opt/hamnix/emptydir absent — empty-dir package dropped (BUG #132)" >&2
    head -5 "${STAGE_C_LOG}.emptydir" >&2 || true
    stage_c_fail=1
fi

rm -f "$TARGET_RAW"

if [ "$stage_c_fail" -ne 0 ]; then
    echo "[test_install_multipkg] Stage C FAILED — both files must be present AND carry their payload" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG" "$STAGE_C_LOG" "${STAGE_C_LOG}.from_a" "${STAGE_C_LOG}.from_b" "${STAGE_C_LOG}.emptydir"
    fi
    exit 1
fi
echo "[test_install_multipkg] Stage C: PASS"

if [ "${KEEP_LOGS:-0}" != "1" ]; then
    rm -f "$STAGE_B_LOG" "$STAGE_C_LOG" "${STAGE_C_LOG}.from_a" "${STAGE_C_LOG}.from_b" "${STAGE_C_LOG}.emptydir"
    rm -f "$TARGET_IMG"
fi

echo "[test_install_multipkg] ALL STAGES PASS"
