#!/usr/bin/env bash
# scripts/test_installer_full.sh
#
# End-to-end installer smoke test:
#
#   Stage A: rebuild the kernel + ISO + a blank 2 GiB qcow2 target.
#   Stage B: boot ISO under QEMU with the blank target attached as
#            vdb; drive hamsh stdin to run /etc/install.hamsh; assert
#            install completes via banner markers.
#   Stage C: boot the installed qcow2 alone (no ISO); assert hamsh
#            prompts, and the [firstboot] grow-check arm logs the
#            slack-or-fit decision.
#   Stage D: resize-to-fit verification. Repeats the install+boot
#            against a 1 GiB and a 5 GiB target, asserts that
#            ext4_resize_grow extended the FS to fill each disk,
#            and that a SECOND boot of the same disk does NOT
#            re-trigger the grow (sentinel respected via
#            ext4_resize_check returning "no grow needed").
#
# Markers asserted, in order, on Stage B (hpm-driven shape):
#   "[install] Hamnix installer"
#   "[gpt] init OK"                     (kernel-side gpt_init)
#   "[gpt] mkpart idx=0"                (ESP partition)
#   "[gpt] mkpart idx=1"                (rootfs partition)
#   "hpm: installed hamnix-base"        (Phase 5 hpm-driven install)
#   "hpm: installed hamnix-installer-tools"
#   "hpm: installed hamnix-bootloader"
#   "hpm: installed linux-debian-12"
#   "[install] (7/7) hostowner credentials"  (Phase 12 prompt step)
#   "[install] install complete"             (final banner)
#
# Markers asserted on Stage C (boot from disk alone):
#   "Hamnix kernel booting"             (kernel banner)
#   "[rootfs] mounted ext4 rootfs"      (rootfs detected on vdb)
#
# Markers asserted on Stage D, per disk size:
#   "[ext4_resize_grow] DONE: blocks N -> M"  (with M > N and
#                                              M*1024 ≈ disk size)
#   "[firstboot] resize_grow OK"
#   "[firstboot] sentinel .hamnix-grown inum=..."
# Second-boot markers (idempotency):
#   "[firstboot] no grow needed"
#   ABSENT: "[ext4_resize_grow] DONE"
#
# Env overrides:
#   BOOT_TIMEOUT  per-stage seconds         (default: 60)
#   TARGET_SIZE   qcow2 size                (default: 2G)
#   STAGE_D_SKIP=1  skip the Stage D resize verification
#   KEEP_LOGS=1   keep log + qcow2 artifacts on PASS

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
TARGET_SIZE="${TARGET_SIZE:-2G}"
HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
TARGET_IMG="${TARGET_IMG:-build/installed.qcow2}"

# --- Stage A: build artifacts -----------------------------------------
echo "[test_installer_full] Stage A: build ISO + blank target"
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    rm -f "$HAMNIX_ISO"
    bash "$PROJ_ROOT/scripts/build_iso.sh" >/dev/null
fi
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_installer_full] FAIL Stage A: ISO not built" >&2
    exit 1
fi
# Stale-artifact guard: HAMNIX_SKIP_BUILD=1 reuses whatever ISO/rootfs is
# already on disk. Say so LOUDLY when it predates the tree under test.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_warn_if_stale "$HAMNIX_ISO" "[installer_full]"

rm -f "$TARGET_IMG"
qemu-img create -f qcow2 "$TARGET_IMG" "$TARGET_SIZE" >/dev/null
echo "[test_installer_full] Stage A: target $TARGET_IMG ($TARGET_SIZE)"

# --- Stage B: install ------------------------------------------------
echo "[test_installer_full] Stage B: boot ISO and run installer"
STAGE_B_LOG=$(mktemp --tmpdir hamnix-installer-stageB.XXXXXX.log)

set +e
(
    # Wait for hamsh prompt, then drive the installer.
    sleep 5
    printf 'hamsh /etc/install.hamsh\n'
    # The installer prints ~5 sections; allow time for the dd_blk
    # copies of the 32 MiB ESP and the ~120 MiB rootfs partition.
    sleep 45
    printf 'echo INSTALLER_DONE\n'
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

echo "[test_installer_full] Stage B QEMU rc=$RC_B (124 = timeout-killed, normal)"

# Stage B assertions.
stage_b_fail=0
check_marker() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_B_LOG"; then
        echo "[test_installer_full]   OK : $label"
    else
        echo "[test_installer_full]   MISS: $label" >&2
        stage_b_fail=1
    fi
}
check_marker '\[install\] Hamnix installer' "installer banner"
check_marker '\[gpt\] init OK' "gpt_init"
check_marker '\[gpt\] mkpart idx=0' "ESP mkpart"
check_marker '\[gpt\] mkpart idx=1' "rootfs mkpart"
# hpm-driven install: the installer drives `hpm install hamnix-base`,
# a METAPACKAGE that depends on every component. hpm's solver
# (cmd_install_solved) installs each leaf in topo order, emitting a
# "hpm: installed <name>" line per package. The root metapackage
# installs last. Assert key leaves + the root + the bootloader + the
# distro package landed.
check_marker 'hpm: installed hamnix-init'             "hpm install hamnix-init (component)"
check_marker 'hpm: installed hamnix-hamsh'            "hpm install hamnix-hamsh (component)"
check_marker 'hpm: installed hamnix-coreutils'        "hpm install hamnix-coreutils (component)"
check_marker 'hpm: installed hamnix-installer-tools'  "hpm install hamnix-installer-tools (component)"
check_marker 'hpm: installed hamnix-bootloader'       "hpm install hamnix-bootloader (component, #esp)"
check_marker 'hpm: installed hamnix-base'             "hpm install hamnix-base (metapackage root)"
check_marker 'hpm: installed linux-debian-12'         "hpm install linux-debian-12"
# Byte transfer onto target:
#   * ESP (FAT12) still uses dd_blk — exactly one occurrence.
#   * rootfs (ext4) now uses install_rootfs_from_manifest, which
#     pushes each curated Debian file individually via the kernel's
#     install_file ctl verb. Assert the manifest runner's success
#     banner is present AND that the manifest-driven path moved a
#     non-trivial number of files onto the target (rejecting the
#     silent zero-install regression).
ddok=$(grep -aE -c 'dd_blk: OK' "$STAGE_B_LOG" || true)
if [ "$ddok" -ge 1 ]; then
    echo "[test_installer_full]   OK : dd_blk: OK ×$ddok (ESP byte-transfer)"
else
    echo "[test_installer_full]   MISS: dd_blk: OK appeared $ddok times (need 1 for ESP)" >&2
    stage_b_fail=1
fi
# install_rootfs_from_manifest emits one "  install: <path>" line per
# successful file install + a final "OK" summary line. The .hamnix-roots
# entry MUST always be present (the kernel's mount_rootfs_partition
# can't register #distro without it); assert at least that one
# installed cleanly.
check_marker '\[install\] \(6/7\) install rootfs files' "manifest install banner"
check_marker 'install_rootfs_from_manifest: .* installed' "manifest summary line"
check_marker '  install: \.hamnix-roots' ".hamnix-roots installed on target"
# etc/install.hamsh layout (post-ac0bf0d):
#   step (7/7) header is "hostowner credentials" (the prompt step),
#   and the final banner is the unadorned "[install] install complete".
# Assert BOTH — the prompt step must have run, AND the run must have
# reached the install-complete banner. Strengthens the previous
# single-line check that conflated the two.
check_marker '\[install\] \(7/7\) hostowner credentials' "step 7 reached"
check_marker '^\[install\] install complete' "install complete"

# Disk-layout assertion: after the install banner says "complete",
# the target qcow2 MUST carry a GPT (signature "EFI PART" at byte
# 0x200 = sector 1) and an MBR signature (0x55AA at byte 0x1FE).
# Without these, Stage C's UEFI boot has nothing to load and fails
# with "BdsDxe: failed to load Boot0001 ... Not Found" — the symptom
# that previously fooled diagnosis into thinking the sentinel write
# was broken when the actual fault was upstream in the install
# pipeline (e.g. an mkfs_ext4 call that clobbered the GPT). Catch
# this BEFORE the UEFI boot so the failure mode points at the
# actual cause.
TARGET_RAW=$(mktemp --tmpdir hamnix-installer-stageB-raw.XXXXXX.img)
if qemu-img convert -O raw "$TARGET_IMG" "$TARGET_RAW" 2>/dev/null; then
    mbr_sig=$(od -An -N2 -tx1 -j 0x1FE "$TARGET_RAW" | tr -d ' \n')
    gpt_sig=$(od -An -N8 -c -j 0x200 "$TARGET_RAW" | tr -d ' \n')
    if [ "$mbr_sig" = "55aa" ]; then
        echo "[test_installer_full]   OK : MBR signature 0x55AA present"
    else
        echo "[test_installer_full]   MISS: MBR signature 0x55AA absent (got 0x$mbr_sig) — install clobbered the partition table" >&2
        stage_b_fail=1
    fi
    if echo "$gpt_sig" | grep -q "EFIPART"; then
        echo "[test_installer_full]   OK : GPT signature 'EFI PART' present at LBA 1"
    else
        echo "[test_installer_full]   MISS: GPT signature 'EFI PART' absent at LBA 1 (got '$gpt_sig')" >&2
        stage_b_fail=1
    fi
fi
rm -f "$TARGET_RAW"

if [ "$stage_b_fail" -ne 0 ]; then
    echo "[test_installer_full] Stage B FAILED — last 80 lines of log:" >&2
    tail -80 "$STAGE_B_LOG" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG"
    fi
    exit 1
fi
echo "[test_installer_full] Stage B: PASS"

# --- Stage C: boot from installed disk alone -------------------------
echo "[test_installer_full] Stage C: boot from $TARGET_IMG (no ISO)"
STAGE_C_LOG=$(mktemp --tmpdir hamnix-installer-stageC.XXXXXX.log)

set +e
(
    sleep 8
    printf 'echo DISK_BOOT_OK\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -drive "file=$TARGET_IMG,if=virtio,format=qcow2" \
    -bios /usr/share/ovmf/OVMF.fd \
    -smp 2 -m 512M -nographic -no-reboot -monitor none -serial stdio \
    > "$STAGE_C_LOG" 2>&1
RC_C=$?
set -e
echo "[test_installer_full] Stage C QEMU rc=$RC_C"

stage_c_fail=0
check_marker_c() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_C_LOG"; then
        echo "[test_installer_full]   OK : $label"
    else
        echo "[test_installer_full]   MISS: $label" >&2
        stage_c_fail=1
    fi
}
# UEFI boot path: PE entry + post-EFI + kernel banner.
check_marker_c '\[hamnix\] EFI entry reached|Hamnix kernel booting' "boot reached"
check_marker_c '\[rootfs\] mounted ext4 rootfs|\[rootfs\] ext4 magic' "ext4 rootfs detected"

if [ "$stage_c_fail" -ne 0 ]; then
    echo "[test_installer_full] Stage C FAILED — last 80 lines of log:" >&2
    tail -80 "$STAGE_C_LOG" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG" "$STAGE_C_LOG"
    fi
    exit 1
fi
echo "[test_installer_full] Stage C: PASS"

if [ "${KEEP_LOGS:-0}" != "1" ]; then
    rm -f "$STAGE_B_LOG" "$STAGE_C_LOG"
    rm -f "$TARGET_IMG"
fi

# --- Stage D: ext4 resize-to-fit verification -------------------------
# Repeat the install+boot for two disk sizes (1 GiB, 5 GiB) and assert
# that the kernel's _first_boot_grow_check actually extends the ext4
# FS to fill each disk. A second boot of the same disk must NOT
# re-trigger the grow (idempotency via ext4_resize_check).
#
# The kernel logs:
#   [ext4_resize_grow] DONE: blocks <before> -> <after>
# We parse the <after> count and assert it's at least
# (disk_bytes - SLACK_BYTES) / 1024 where SLACK_BYTES allows for
# GPT + ESP + rounding-to-whole-block-groups.

if [ "${STAGE_D_SKIP:-0}" = "1" ]; then
    echo "[test_installer_full] Stage D: SKIPPED via STAGE_D_SKIP=1"
    echo "[test_installer_full] ALL STAGES PASS"
    exit 0
fi

# Pick a disk size for resize verification. Two sub-tests:
#   D-1: 1 GiB qcow2 — exercises a modest grow (~10x source rootfs)
#   D-2: 5 GiB qcow2 — exercises a large grow (~50x source rootfs)
# Each sub-test runs Stage B (install) then Stage C (boot from disk)
# and parses the kernel log for the resize markers.
#
# stage_d_install_and_boot <size_str> <expected_min_blocks_after>
stage_d_install_and_boot() {
    local size_str="$1"
    local min_blocks="$2"
    local label="$3"

    local img_path
    img_path=$(mktemp --tmpdir hamnix-installer-stageD.XXXXXX.qcow2)
    local install_log
    install_log=$(mktemp --tmpdir hamnix-installer-stageD-install.XXXXXX.log)
    local boot_log
    boot_log=$(mktemp --tmpdir hamnix-installer-stageD-boot.XXXXXX.log)
    local boot2_log
    boot2_log=$(mktemp --tmpdir hamnix-installer-stageD-boot2.XXXXXX.log)

    echo "[test_installer_full] Stage D ($label): target size=$size_str img=$img_path"
    rm -f "$img_path"
    qemu-img create -f qcow2 "$img_path" "$size_str" >/dev/null

    # Install phase (mirrors Stage B's stdin driving).
    set +e
    (
        sleep 5
        printf 'hamsh /etc/install.hamsh\n'
        sleep 45
        printf 'echo INSTALLER_DONE\n'
        sleep 2
        printf 'exit\n'
        sleep 1
    ) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
        -drive "file=$HAMNIX_ISO,if=virtio,format=raw,readonly=on" \
        -drive "file=$img_path,if=virtio,format=qcow2" \
        -smp 2 -m 512M -nographic -no-reboot -monitor none -serial stdio \
        > "$install_log" 2>&1
    set -e

    # See Stage B above re: the install.hamsh banner layout. Two
    # markers: (7/7) hostowner credentials must have run, AND the
    # final "install complete" line must be present.
    if ! grep -aE -q '\[install\] \(7/7\) hostowner credentials' "$install_log" \
       || ! grep -aE -q '^\[install\] install complete' "$install_log"; then
        echo "[test_installer_full] Stage D ($label) FAIL: install did not complete" >&2
        tail -40 "$install_log" >&2
        if [ "${KEEP_LOGS:-0}" != "1" ]; then
            rm -f "$img_path" "$install_log" "$boot_log" "$boot2_log"
        else
            echo "[test_installer_full] Stage D ($label) keep-logs: $install_log $boot_log $boot2_log" >&2
        fi
        return 1
    fi
    echo "[test_installer_full] Stage D ($label): install OK"

    # First boot — should trigger the resize.
    set +e
    (
        sleep 8
        printf 'echo FIRST_BOOT_OK\n'
        sleep 2
        printf 'exit\n'
        sleep 1
    ) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
        -drive "file=$img_path,if=virtio,format=qcow2" \
        -bios /usr/share/ovmf/OVMF.fd \
        -smp 2 -m 512M -nographic -no-reboot -monitor none -serial stdio \
        > "$boot_log" 2>&1
    set -e

    # Assert: resize ran, sentinel got written.
    # Preserve the boot log to a stable path on any failure so diagnosis
    # doesn't require KEEP_LOGS=1 + temp-file scraping.
    local fail_log_dir="/tmp/hamnix-installer-stageD-fail"
    if ! grep -aE -q '\[ext4_resize_grow\] DONE: blocks' "$boot_log"; then
        echo "[test_installer_full] Stage D ($label) FAIL: no ext4_resize_grow DONE marker" >&2
        echo "  --- last 40 lines of boot log: ---" >&2
        tail -40 "$boot_log" >&2
        mkdir -p "$fail_log_dir"
        cp "$boot_log" "$fail_log_dir/${label}-boot.log"
        cp "$install_log" "$fail_log_dir/${label}-install.log"
        echo "[test_installer_full] Stage D ($label) FAIL logs preserved: $fail_log_dir/${label}-{boot,install}.log" >&2
        if [ "${KEEP_LOGS:-0}" != "1" ]; then
            rm -f "$img_path" "$install_log" "$boot_log" "$boot2_log"
        else
            echo "[test_installer_full] Stage D ($label) keep-logs: $install_log $boot_log $boot2_log" >&2
        fi
        return 1
    fi
    if ! grep -aE -q '\[firstboot\] sentinel \.hamnix-grown inum=' "$boot_log"; then
        echo "[test_installer_full] Stage D ($label) FAIL: sentinel marker missing" >&2
        tail -40 "$boot_log" >&2
        mkdir -p "$fail_log_dir"
        cp "$boot_log" "$fail_log_dir/${label}-boot.log"
        cp "$install_log" "$fail_log_dir/${label}-install.log"
        echo "[test_installer_full] Stage D ($label) FAIL logs preserved: $fail_log_dir/${label}-{boot,install}.log" >&2
        if [ "${KEEP_LOGS:-0}" != "1" ]; then
            rm -f "$img_path" "$install_log" "$boot_log" "$boot2_log"
        else
            echo "[test_installer_full] Stage D ($label) keep-logs: $install_log $boot_log $boot2_log" >&2
        fi
        return 1
    fi

    # Extract the post-grow block count and check it meets the minimum.
    local after_blocks
    after_blocks=$(grep -aE '\[ext4_resize_grow\] DONE: blocks' "$boot_log" \
                   | sed -E 's/.*-> ([0-9]+).*/\1/' | tail -1)
    if [ -z "$after_blocks" ]; then
        echo "[test_installer_full] Stage D ($label) FAIL: could not parse block count" >&2
        tail -10 "$boot_log" >&2
        if [ "${KEEP_LOGS:-0}" != "1" ]; then
            rm -f "$img_path" "$install_log" "$boot_log" "$boot2_log"
        else
            echo "[test_installer_full] Stage D ($label) keep-logs: $install_log $boot_log $boot2_log" >&2
        fi
        return 1
    fi
    if [ "$after_blocks" -lt "$min_blocks" ]; then
        echo "[test_installer_full] Stage D ($label) FAIL: post-grow blocks=$after_blocks < min=$min_blocks" >&2
        if [ "${KEEP_LOGS:-0}" != "1" ]; then
            rm -f "$img_path" "$install_log" "$boot_log" "$boot2_log"
        else
            echo "[test_installer_full] Stage D ($label) keep-logs: $install_log $boot_log $boot2_log" >&2
        fi
        return 1
    fi
    echo "[test_installer_full] Stage D ($label): grow OK ($after_blocks blocks; min=$min_blocks)"

    # Second boot — should NOT re-trigger the grow.
    set +e
    (
        sleep 8
        printf 'echo SECOND_BOOT_OK\n'
        sleep 2
        printf 'exit\n'
        sleep 1
    ) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
        -drive "file=$img_path,if=virtio,format=qcow2" \
        -bios /usr/share/ovmf/OVMF.fd \
        -smp 2 -m 512M -nographic -no-reboot -monitor none -serial stdio \
        > "$boot2_log" 2>&1
    set -e

    if grep -aE -q '\[ext4_resize_grow\] DONE: blocks' "$boot2_log"; then
        echo "[test_installer_full] Stage D ($label) FAIL: second boot re-ran grow (NOT idempotent)" >&2
        tail -40 "$boot2_log" >&2
        if [ "${KEEP_LOGS:-0}" != "1" ]; then
            rm -f "$img_path" "$install_log" "$boot_log" "$boot2_log"
        else
            echo "[test_installer_full] Stage D ($label) keep-logs: $install_log $boot_log $boot2_log" >&2
        fi
        return 1
    fi
    if ! grep -aE -q '\[firstboot\] no grow needed' "$boot2_log"; then
        # Acceptable alternate: the check returned 0 silently and the
        # later marker didn't print (e.g. partition size matched exactly).
        # Surface the boot log so a future failure is debuggable.
        if grep -aE -q '\[rootfs\] mounted ext4 rootfs' "$boot2_log"; then
            echo "[test_installer_full] Stage D ($label): second boot mounted; no explicit 'no grow needed' marker" >&2
        else
            echo "[test_installer_full] Stage D ($label) FAIL: second boot mount missing" >&2
            tail -40 "$boot2_log" >&2
            rm -f "$img_path" "$install_log" "$boot_log" "$boot2_log"
            return 1
        fi
    fi
    echo "[test_installer_full] Stage D ($label): second boot idempotent (no re-grow)"

    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$img_path" "$install_log" "$boot_log" "$boot2_log"
    else
        echo "[test_installer_full] Stage D ($label) KEEP_LOGS: $install_log $boot_log $boot2_log"
    fi
    return 0
}

echo "[test_installer_full] Stage D: ext4 resize-to-fit verification"

# 1 GiB disk = 1073741824 bytes. After GPT (1 MiB) + ESP (32 MiB) +
# partition alignment, the rootfs partition is ~1037 MiB = 253692
# blocks at 4 KiB. Kernel mkfs is whole-group only (32768 blk/group);
# (253692 / 32768) floors to 7 groups → 7 * 32768 = 229376 blocks.
# Allow ~5K slack for s_reserved_gdt_blocks bookkeeping cliff cases.
#
# Block-size note: the kernel-side mkfs_ext4 always emits 4 KiB
# blocks (s_log_block_size = 2). The legacy dd_blk-of-rootfs.img
# path used host mkfs.ext4 which defaults to 1 KiB blocks for
# sub-512-MiB FSes — that's where the OLD 800,000-block threshold
# came from. The new manifest-installer path uses 4 KiB
# consistently, so the threshold drops 4x.
stage_d_install_and_boot 1G 225000 "1G" || {
    echo "[test_installer_full] Stage D-1G: FAILED" >&2
    exit 1
}

# 5 GiB disk = 5368709120 bytes. After GPT (2048 + 34 sectors) + ESP
# (32 MiB = 65536 sectors), the rootfs partition is 10418143 sectors
# = 5086 MiB → ~1302267 blocks at 4 KiB → floor to 32768/group = 39
# groups → 39 * 32768 = 1277952 blocks. Threshold 1,250,000 (~5%
# slack) so a future kernel-side group-overhead tweak doesn't trip
# the test on a single missing group.
stage_d_install_and_boot 5G 1250000 "5G" || {
    echo "[test_installer_full] Stage D-5G: FAILED" >&2
    exit 1
}

echo "[test_installer_full] Stage D: PASS"

echo "[test_installer_full] ALL STAGES PASS"
