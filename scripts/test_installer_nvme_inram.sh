#!/usr/bin/env bash
# scripts/test_installer_nvme_inram.sh — END-TO-END proof of the
# DEBIAN-STYLE in-RAM install flow: the installer sources its payload from
# RAM (inside the firmware-loaded kernel cpio), NEVER from the install
# media's own block device — AND it populates the target ROOT as PACKAGES
# (hpm install hamnix-base), not as a golden-image byte stream. Targets a
# native NVMe disk; demonstrable entirely in a VM under OVMF/qemu (no HW).
#
# WHY THIS IS DISTINCT FROM test_installer_nvme.sh. The original installer
# ended its payload copy with `dd_blk /dev/blk/vdap2 /dev/blk/nvme0n1p2` —
# a RUNTIME read of the install MEDIA's ext4 partition. On the real NUC
# target the media is a USB stick whose native driver is broken, so that
# read defeats the whole in-RAM-installer model. This test proves the fix:
# the install medium is an ESP-ONLY GPT image (NO ext4 partition to read);
# the installer streams ONLY the target ESP out of the in-RAM squashfs and
# installs the target ROOT from the in-RAM package repo via hpm.
#
# TWO in-RAM sources, NEITHER a media read:
#   /rootfs.sqfs (esp.img)  -> ESP byte-copy via sqfs_to_blk (no FAT writer)
#   /iso-packages/main      -> hpm package repo for the ext4 ROOT install
#
# Stages:
#   Stage A: build the ESP-only install medium (build_installer_img.sh ->
#            hamnix-installer.img) + a blank NVMe target qcow2. ASSERT ON
#            THE HOST that the medium has EXACTLY ONE partition (the ESP) —
#            there is physically nothing on the media to read.
#   Stage B: boot the install medium under OVMF (virtio-blk = install
#            media; -device nvme = blank target). rc.boot auto-runs the
#            installer (no keyboard). Assert: the install completed; the
#            log shows the Debian-style package path (`install --auto` ->
#            `hpm install hamnix-base` from file:///iso-packages) and the
#            ESP came from the IN-RAM squashfs ("[sqfs-extract]"); AND a
#            real GPT + ext4 superblock actually landed on the NVMe qcow2
#            (read the raw bytes back on the HOST — REAL verification).
#   Stage C: boot the NVMe qcow2 ALONE under OVMF (NO install media).
#            Assert the kernel mounted ext4-on-NVMe and reached a shell
#            with ZERO 'command not found'.
#
# REAL verification — no hard-coded PASS, no faked install, no
# log-marker-only proof for the bytes-on-disk checks.
#
# Env overrides:
#   BOOT_TIMEOUT      per-stage seconds                 (default: 200)
#   NVME_SIZE         blank NVMe target size            (default: 2G)
#   OVMF_FD           OVMF firmware path                (auto-resolved)
#   HAMNIX_SKIP_BUILD 1 = reuse build/hamnix-installer-autorun.img when FRESH
#                         (default: rebuild)
#   KEEP_LOGS         1 = keep logs + qcow2 on PASS      (default: 0)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-200}"
NVME_SIZE="${NVME_SIZE:-2G}"
# ONE PATH MUST NOT SERVE TWO VARIANTS (2026-07-28).
#
# This gate needs the UNATTENDED medium — built with HAMNIX_INSTALLER_AUTORUN=1,
# which plants the auto-install trigger in the initramfs (scripts/build_
# initramfs.py). Every other consumer of build/hamnix-installer.img needs the
# NORMAL live medium, which boots to the desktop and installs nothing.
#
# It used to write the autorun build to build/hamnix-installer.img, the shared
# path. Freshness is an MTIME COMPARISON — it cannot tell the two variants
# apart — so on any KVM host the manifest's `HAMNIX_SKIP_BUILD=1 bash
# scripts/test_installer_nvme_inram.sh` reused whatever happened to be at that
# path. Whenever a NON-autorun build wrote it last (build_installer_img.sh with
# no env, run_installer.sh's default arm, any of the ~70 DE/browser gates that
# rebuild it when stale), this gate booted a medium that never auto-installs,
# saw no install markers, and reported the end-to-end install BROKEN. A
# reproducible false red on the project's primary ship vehicle. The reverse is
# worse: an autorun image left at the shared path makes an unrelated DE gate
# boot a medium that wipes the "target" disk unattended.
#
# So the autorun variant gets its own path, exactly as the DE visual gate's
# HAMNIX_DE_SELFTEST build already does with hamnix-installer-selftest.img.
# scripts/run_installer.sh had already picked this name for AUTO_INSTALL=1.
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer-autorun.img}"
NVME_IMG="${NVME_IMG:-build/installed-nvme-inram.qcow2}"
KERNEL_BANNER="Hamnix kernel booting"
PROMPT_MARKER="ed-readline-first"

# --- environment gates (skip cleanly) --------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_installer_nvme_inram] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
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
    echo "[test_installer_nvme_inram] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_installer_nvme_inram] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- Stage A: build ESP-only install medium + blank NVMe target -------
echo "[test_installer_nvme_inram] Stage A: build ESP-only install medium + blank NVMe target"
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# MANDATORY REBUILD-WHEN-STALE (not warn-only). This gate is the project's
# only end-to-end proof that an install COMPLETES, so a stale image here is
# strictly worse than no gate: it green-lights the very regression the gate
# exists to catch. That is not hypothetical — the 2026-07-27 ship-blocker
# ("[install] FAIL: hpm base package install non-zero") reached a USER because
# nothing ran an install to completion against a FRESH image.
#
# ensure_installer_img() cannot be used verbatim: this gate needs the
# unattended auto-install path (HAMNIX_INSTALLER_AUTORUN=1), which that helper
# does not set. So invoke build_installer_img.sh directly — rule (b) of
# scripts/test_artifact_freshness.sh PART 2b — and, unlike the old warn-only
# path, honour HAMNIX_SKIP_BUILD ONLY while the image is actually FRESH.
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ] || installer_img_is_stale "$INSTALLER_IMG"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[test_installer_nvme_inram]   $INSTALLER_IMG is STALE (older than a tracked build input) — rebuilding despite HAMNIX_SKIP_BUILD=1 (~6 min)"
    fi
    rm -f "$INSTALLER_IMG"
    # HAMNIX_INSTALLER_IMG_OUT keeps the unattended build in its OWN file —
    # see the INSTALLER_IMG comment above; without it this overwrites the
    # shared live medium with an auto-installing one.
    HAMNIX_INSTALLER_AUTORUN=1 HAMNIX_INSTALLER_IMG_OUT="$INSTALLER_IMG" \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"  # E2E install regression needs the unattended auto-install path
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_installer_nvme_inram] FAIL Stage A: $INSTALLER_IMG not built" >&2
    exit 1
fi

# HOST-SIDE PROOF: the install medium must have EXACTLY ONE partition
# (the ESP). NO ext4 partition 2 = there is physically nothing on the
# media for the installer to read. This is the load-bearing proof the
# USB-read path is gone.
PARTED="/sbin/parted"; [ -x "$PARTED" ] || PARTED="$(command -v parted || true)"
NPARTS=$("$PARTED" -s "$INSTALLER_IMG" unit s print 2>/dev/null \
            | awk '/^[ ]*[0-9]+/ {n++} END {print n+0}')
if [ "$NPARTS" -ne 1 ]; then
    echo "[test_installer_nvme_inram] FAIL Stage A: install medium has $NPARTS partitions; must be 1 (ESP-only)." >&2
    "$PARTED" -s "$INSTALLER_IMG" unit s print >&2
    exit 1
fi
echo "[test_installer_nvme_inram]   OK : install medium is ESP-ONLY (1 partition; no ext4 to read)"
# Also assert there is NO ext4 superblock anywhere a partition-2 would be:
# scan the whole image for the 0xEF53 magic at any 1 MiB boundary +1024.
# (Belt-and-suspenders: the squashfs payload is gzip-compressed so the raw
# ext4 magic does not appear in the medium's bytes.)
INSTALLER_RAW_MAGIC=$(od -An -tx1 "$INSTALLER_IMG" 2>/dev/null | tr -d ' \n' | grep -o "53ef" | head -1 || true)
# (Informational only; not a hard gate — gzip could in theory contain the
# byte pair by chance. The 1-partition GPT check above is the real proof.)

rm -f "$NVME_IMG"
qemu-img create -f qcow2 "$NVME_IMG" "$NVME_SIZE" >/dev/null
echo "[test_installer_nvme_inram] Stage A: NVMe target $NVME_IMG ($NVME_SIZE)"

OVMF_RW=$(mktemp --tmpdir hamnix-inram.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-inram.media.XXXXXX.img)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$MEDIA_RW"

STAGE_B_LOG=$(mktemp --tmpdir hamnix-inram-stageB.XXXXXX.log)
STAGE_C_LOG=$(mktemp --tmpdir hamnix-inram-stageC.XXXXXX.log)
INFIFO_B=$(mktemp --tmpdir -u hamnix-inram-inB.XXXXXX)
INFIFO_C=$(mktemp --tmpdir -u hamnix-inram-inC.XXXXXX)
mkfifo "$INFIFO_B" "$INFIFO_C"

cleanup() {
    [ -n "${QEMU_B_PID:-}" ] && kill "$QEMU_B_PID" 2>/dev/null
    [ -n "${QEMU_C_PID:-}" ] && kill "$QEMU_C_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$MEDIA_RW" "$INFIFO_B" "$INFIFO_C"
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG" "$STAGE_C_LOG" "$NVME_IMG"
    fi
}
trap cleanup EXIT

# --- Stage B: boot installer medium + blank NVMe, run the installer ---
echo "[test_installer_nvme_inram] Stage B: boot ESP-only install medium (OVMF) + blank NVMe; run installer"

exec 4<>"$INFIFO_B"
exec 3>"$INFIFO_B"

# bootindex pins the install media first (same rationale as
# test_installer_nvme.sh: OVMF would otherwise probe the blank NVMe and
# PXE before the virtio media).
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$MEDIA_RW",format=raw,if=none,id=media \
    -device virtio-blk-pci,drive=media,bootindex=0 \
    -drive file="$NVME_IMG",format=qcow2,if=none,id=nvmetgt \
    -device nvme,drive=nvmetgt,serial=hamnvme01,bootindex=1 \
    -m 1280M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$STAGE_B_LOG" 2>&1 &
QEMU_B_PID=$!

# The installer now AUTO-RUNS at boot. /etc/rc.boot detects the
# /etc/installer-medium marker and sources /etc/install_nvme.hamsh ITSELF
# (the real NUC target has no keyboard, so nothing can type the command).
# So there is no "type the installer at a prompt" step anymore, and the
# installer branch of rc.boot never sources rc.boot.full — the
# PROMPT_MARKER ("handing off to interactive shell") is NOT printed on the
# installer medium. We just boot and poll for the installer's own
# completion marker. The boot + a ~512 MiB ext4 stream out of the in-RAM
# squashfs is slow under TCG/KVM, so the budget folds boot into the wait.
INSTALL_WAIT="${INSTALL_WAIT:-400}"
echo "[test_installer_nvme_inram] Stage B: booting installer medium; waiting up to $((BOOT_TIMEOUT + INSTALL_WAIT))s for the auto-run installer to finish..."
installed=0
for _ in $(seq 1 $((BOOT_TIMEOUT + INSTALL_WAIT))); do
    # The package-based installer ends with the install_nvme.hamsh wrapper's
    # own "install complete" line (the inner `install` command also prints
    # "[install] install complete on ...").
    if grep -a -q '\[install-nvme\] install complete' "$STAGE_B_LOG"; then
        installed=1; break
    fi
    if ! kill -0 "$QEMU_B_PID" 2>/dev/null; then
        echo "[test_installer_nvme_inram] FAIL Stage B: qemu exited during install." >&2
        tail -100 "$STAGE_B_LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$installed" -ne 1 ]; then
    echo "[test_installer_nvme_inram] FAIL Stage B: 'install complete' not seen in ${INSTALL_WAIT}s." >&2
    tail -100 "$STAGE_B_LOG" >&2
    exit 1
fi
sleep 2
kill "$QEMU_B_PID" 2>/dev/null
wait "$QEMU_B_PID" 2>/dev/null
exec 3>&-
exec 4>&-

# --- Stage B assertions ----------------------------------------------
stage_b_fail=0
check_b() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_B_LOG"; then
        echo "[test_installer_nvme_inram]   OK : $label"
    else
        echo "[test_installer_nvme_inram]   MISS: $label" >&2
        stage_b_fail=1
    fi
}
check_b "$KERNEL_BANNER" "installer media: kernel banner (EFI stub -> kernel)"
# rc.boot auto-detected the installer medium and started the installer
# itself (no keyboard needed) — this is the keyboard-less auto-run gate.
# rc.boot emits "install target present -- auto-running /etc/install_nvme.hamsh"
# when it auto-runs the installer on the keyboard-less target. (Older builds
# printed "installer medium detected -- ..."; accept either.)
check_b 'auto-running /etc/install_nvme.hamsh|installer medium detected -- auto-running' \
        "rc.boot auto-ran the installer (no keyboard)"
# The installer medium marker made the kernel skip ALL media USB bring-up.
check_b 'installer medium .in-RAM squashfs.: USB root bring-up SKIPPED entirely' \
        "kernel skipped media USB bring-up (in-RAM installer medium)"
# NVMe came up as a real native block device on the installer media.
check_b '\[nvme\] registered as block slot=' "native NVMe driver registered nvme0n1"
# The installer ran its steps.
check_b '\[install-nvme\] Hamnix NVMe installer' "installer banner"
# DEBIAN-STYLE INSTALL: the wrapper handed off to the `install --auto`
# package-based installer (not a golden-image byte stream).
check_b 'running: install --auto' "wrapper invoked the package-based install --auto"
check_b '\[install\] Installing Hamnix .Debian-style package install.' \
        "install command ran in Debian-style package mode"
# The ROOT was populated via hpm packages (the whole point of the rewrite):
# refresh the in-RAM repo, then install the hamnix-base metapackage onto
# the freshly-mkfs'd ext4 via the --target-dev ctl path.
check_b 'hpm.*refresh|\[install\] .4/5. hpm refresh' "hpm refreshed the in-RAM package index"
check_b '\[install\] .5/5. hpm install hamnix-base' "installer installed hamnix-base as packages"
check_b 'hpm: installed hamnix-base' "hpm reported hamnix-base installed onto the target"
# NEGATIVE — the 2026-07-27 ship-blocker's signature. The LLVM-lane /bin/hpm
# (ADDER_LLVM_DEFAULT=1 made that the lane that builds the SHIPPED binary)
# inflated every package tarball to ZERO bytes while reporting success, so the
# very first package of the closure died with "PKGINFO not found in tarball"
# and the user saw only "[install] FAIL: hpm base package install non-zero".
# Root cause was an undersized shared stack slot for a redeclared local in
# lib/zlib/inflate.ad's dynamic-Huffman header decode (fixed in
# adder/compiler/ssa.ad::ssa_widen_mem_local; guarded QEMU-free by
# scripts/test_inflate_llvm_host.sh). Assert the ABSENCE of every
# tarball-decode failure signature so a recurrence names itself here instead of
# surfacing as a bare non-zero exit.
if grep -aE -q 'PKGINFO not found in tarball|gzip inflate failed|gzip inflate did not reach EOS|tar header checksum bad|SHA-256 mismatch' "$STAGE_B_LOG"; then
    echo "[test_installer_nvme_inram]   MISS (KEYSTONE): hpm hit a package-decode failure — the tarball fetch/inflate/tar-walk chain is broken:" >&2
    grep -aE 'PKGINFO not found in tarball|gzip inflate failed|gzip inflate did not reach EOS|tar header checksum bad|SHA-256 mismatch' "$STAGE_B_LOG" >&2
    stage_b_fail=1
else
    echo "[test_installer_nvme_inram]   OK (KEYSTONE): no package fetch/inflate/tar-walk failure in the install."
fi
# The native base install must source bytes ONLY from the local hpm repo —
# NEVER the Debian distro tree (/n/distros). The legacy manifest path emitted
# "skip missing source /n/distros/bin/*" when #distro was unbound; the
# package path must never touch /n/distros. Assert its ABSENCE.
if grep -aE -q 'skip missing source|/n/distros' "$STAGE_B_LOG"; then
    echo "[test_installer_nvme_inram]   MISS (KEYSTONE): base install referenced /n/distros / skipped a missing source — it must source from the local hpm repo only:" >&2
    grep -aE 'skip missing source|/n/distros' "$STAGE_B_LOG" >&2
    stage_b_fail=1
else
    echo "[test_installer_nvme_inram]   OK (KEYSTONE): no '/n/distros' / 'skip missing source' — base populated purely from the local hpm repo."
fi
# KEYSTONE (in-RAM source): the ESP came from the in-RAM squashfs; the
# root package repo is the in-RAM /iso-packages — neither is a media read.
check_b 'file:///iso-packages' "installer used the in-RAM package repo (not a media read)"
# The kernel-side squashfs extractor still runs for the ESP byte-copy.
check_b '\[sqfs-extract\] start' "kernel sqfs-extract streamer ran (ESP byte-copy)"
check_b '\[sqfs-extract\] in-RAM squashfs mounted' "in-RAM squashfs mounted"
check_b '\[sqfs-extract\] DONE: wrote ' "kernel sqfs-extract completed the ESP stream"
# GPT actually landed on NVMe.
check_b '\[gpt\] init OK' "GPT init on NVMe target"
check_b '\[gpt\] mkpart idx=0 ' "ESP mkpart on NVMe"
check_b '\[gpt\] mkpart idx=1 ' "rootfs mkpart on NVMe"
check_b '\[install-nvme\] install complete' "installer reported complete"
check_b 'loop-enter' "shell re-entered interactive loop after install"

# REAL verification: read the NVMe qcow2 back on the HOST and assert a
# protective MBR (0x55AA), a GPT ("EFI PART" at LBA 1), and an ext4
# superblock magic 0xEF53 at the rootfs partition offset.
NVME_RAW=$(mktemp --tmpdir hamnix-inram-raw.XXXXXX.img)
if qemu-img convert -O raw "$NVME_IMG" "$NVME_RAW" 2>/dev/null; then
    mbr_sig=$(od -An -N2 -tx1 -j 0x1FE "$NVME_RAW" | tr -d ' \n')
    gpt_sig=$(od -An -N8 -c -j 0x200 "$NVME_RAW" | tr -d ' \n')
    if [ "$mbr_sig" = "55aa" ]; then
        echo "[test_installer_nvme_inram]   OK : NVMe disk has protective-MBR signature 0x55AA"
    else
        echo "[test_installer_nvme_inram]   MISS: NVMe MBR signature absent (got 0x$mbr_sig)" >&2
        stage_b_fail=1
    fi
    if echo "$gpt_sig" | grep -q "EFIPART"; then
        echo "[test_installer_nvme_inram]   OK : NVMe disk has GPT 'EFI PART' signature at LBA 1"
    else
        echo "[test_installer_nvme_inram]   MISS: NVMe GPT signature absent at LBA 1 (got '$gpt_sig')" >&2
        stage_b_fail=1
    fi
    # ESP starts at LBA 2048 (1 MiB), 64 MiB; rootfs follows at 65 MiB.
    root_off=$(( 65 * 1024 * 1024 + 1024 + 0x38 ))
    ext4_magic=$(od -An -N2 -tx1 -j "$root_off" "$NVME_RAW" | tr -d ' \n')
    if [ "$ext4_magic" = "53ef" ]; then
        echo "[test_installer_nvme_inram]   OK : NVMe rootfs partition carries ext4 magic 0xEF53 (streamed from in-RAM squashfs)"
    else
        echo "[test_installer_nvme_inram]   MISS: ext4 magic not at expected NVMe rootfs offset (got 0x$ext4_magic)" >&2
        stage_b_fail=1
    fi
fi
rm -f "$NVME_RAW"

if [ "$stage_b_fail" -ne 0 ]; then
    echo "[test_installer_nvme_inram] Stage B FAILED — last 120 lines of installer log:" >&2
    tail -120 "$STAGE_B_LOG" >&2
    exit 1
fi
echo "[test_installer_nvme_inram] Stage B: PASS (installer streamed payload from in-RAM squashfs; GPT + ext4 on NVMe)"

# --- Stage C: boot the installed NVMe disk ALONE (no install media) --
echo "[test_installer_nvme_inram] Stage C: boot from NVMe ALONE (install media detached)"

exec 6<>"$INFIFO_C"
exec 5>"$INFIFO_C"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$NVME_IMG",format=qcow2,if=none,id=nvmeroot \
    -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
    -m 1024M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&6 > "$STAGE_C_LOG" 2>&1 &
QEMU_C_PID=$!

echo "[test_installer_nvme_inram] Stage C: waiting up to ${BOOT_TIMEOUT}s for the installed-root shell prompt..."
cbooted=0
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
    if grep -a -q "$PROMPT_MARKER" "$STAGE_C_LOG"; then cbooted=1; break; fi
    if ! kill -0 "$QEMU_C_PID" 2>/dev/null; then
        echo "[test_installer_nvme_inram] FAIL Stage C: qemu exited before the installed-root shell." >&2
        tail -100 "$STAGE_C_LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$cbooted" -ne 1 ]; then
    echo "[test_installer_nvme_inram] FAIL Stage C: installed-root shell prompt not seen in ${BOOT_TIMEOUT}s." >&2
    tail -100 "$STAGE_C_LOG" >&2
    exit 1
fi
echo "[test_installer_nvme_inram] Stage C: installed-root shell ready; typing commands."
sleep 6

type_c() { printf '%s\n' "$1" >&5; sleep "${2:-4}"; }
type_c "echo NVME_ROOT_REPL_OK" 4
type_c "ls /bin" 4
type_c "cat /version" 4
type_c "echo NVME_ROOT_DONE_99" 4
sleep 3
kill "$QEMU_C_PID" 2>/dev/null
wait "$QEMU_C_PID" 2>/dev/null
exec 5>&-
exec 6>&-

# --- Stage C assertions ----------------------------------------------
stage_c_fail=0
check_c() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_C_LOG"; then
        echo "[test_installer_nvme_inram]   OK : $label"
    else
        echo "[test_installer_nvme_inram]   MISS: $label" >&2
        stage_c_fail=1
    fi
}
check_c "$KERNEL_BANNER" "installed NVMe: kernel banner (NVMe-ESP stub -> kernel)"
check_c '\[nvme\] registered as block slot=' "installed NVMe: native driver registered nvme0n1"
check_c '\[rootfs\] ext4 magic on slot .*nvme0n1' "installed NVMe: ext4 root found on nvme0n1pN"
check_c "$PROMPT_MARKER" "installed NVMe: reached interactive shell off ext4-on-NVMe"
check_c '^NVME_ROOT_REPL_OK' "installed NVMe: REPL alive"
if grep -a -q "command not found" "$STAGE_C_LOG"; then
    echo "[test_installer_nvme_inram]   MISS (KEYSTONE): 'command not found' present — commands do NOT resolve off NVMe ext4:" >&2
    grep -a "command not found" "$STAGE_C_LOG" >&2
    stage_c_fail=1
else
    echo "[test_installer_nvme_inram]   OK (KEYSTONE): zero 'command not found' — commands resolve off NVMe ext4."
fi

if [ "$stage_c_fail" -ne 0 ]; then
    echo "[test_installer_nvme_inram] Stage C FAILED — last 100 lines of installed-boot log:" >&2
    tail -100 "$STAGE_C_LOG" >&2
    exit 1
fi
echo "[test_installer_nvme_inram] Stage C: PASS (installed system booted off ext4-on-NVMe)"

echo "[test_installer_nvme_inram] ALL STAGES PASS"
echo "[test_installer_nvme_inram]   ESP-only install medium -> in-RAM ESP squashfs + hpm package repo -> mkfs ext4 root + hpm install hamnix-base + ESP on NVMe -> reboot -> installed-root shell (NO media read, Debian-style package root)"
exit 0
