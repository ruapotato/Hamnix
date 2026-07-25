#!/usr/bin/env bash
# scripts/build_installed_nvme.sh — produce the GOLDEN installed-system
# disk: build/hamnix-installed.qcow2.
#
# WHY THIS EXISTS. The baked GPT+ext4 image (build/hamnix.img, built by the
# now-retired build_img.sh) is gone — a real system is never shipped as a
# pre-baked root image; an INSTALLER lays the root onto a real disk. So the
# feature tests that used to boot hamnix.img now boot the *installed* system
# instead. Installing fresh inside every test would be far too slow (each
# install streams a ~512 MiB ext4 payload out of the in-RAM squashfs under
# OVMF), so we install ONCE here into a golden NVMe qcow2 and let each test
# boot a cheap COPY of it (scripts/_installed_boot.sh). The golden disk is
# the genuine output of the real installer path — proving that path on every
# build — not a shortcut around it.
#
# Flow (factored from scripts/test_installer_nvme_inram.sh Stage A + B):
#   1. build the ESP-only installer medium (build_installer_img.sh).
#   2. boot it under OVMF + a blank NVMe target; run /etc/install_nvme.hamsh;
#      the installer streams its payload from the IN-RAM squashfs and writes
#      a real GPT + ext4 root + ESP onto the NVMe qcow2.
#   3. HOST-verify the bytes actually landed (protective MBR, GPT 'EFI PART',
#      ext4 0xEF53) — no log-marker-only proof — then KEEP the qcow2 as the
#      golden installed disk.
#
# SKIPS CLEANLY (exit 0, no disk produced) when /dev/kvm, OVMF, or
# mksquashfs is unavailable — callers detect the missing golden disk and
# skip too (mirrors every other OVMF-boot test).
#
# Env overrides:
#   GOLDEN_NVME        output golden disk   (default: build/hamnix-installed.qcow2)
#   NVME_SIZE          golden disk size     (default: 2G)
#   BOOT_TIMEOUT       installer-shell wait (default: 200)
#   INSTALL_WAIT       install-complete wait(default: 400)
#   OVMF_FD            OVMF firmware path   (auto-resolved)
#   HAMNIX_SKIP_BUILD  1 = reuse build/hamnix-installer.img (default: rebuild)
#   HAMNIX_FORCE_GOLDEN 1 = rebuild golden even if it already exists

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

GOLDEN_NVME="${GOLDEN_NVME:-build/hamnix-installed.qcow2}"
NVME_SIZE="${NVME_SIZE:-2G}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-200}"
INSTALL_WAIT="${INSTALL_WAIT:-400}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
KERNEL_BANNER="Hamnix kernel booting"
PROMPT_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly, no disk produced) ---------------
if [ ! -e /dev/kvm ]; then
    echo "[build_installed_nvme] SKIP: /dev/kvm absent (KVM required; OVMF install too slow without it)" >&2
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
    echo "[build_installed_nvme] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[build_installed_nvme] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# Reuse an existing golden disk unless forced.
if [ -f "$GOLDEN_NVME" ] && [ "${HAMNIX_FORCE_GOLDEN:-0}" != "1" ]; then
    echo "[build_installed_nvme] reusing existing golden disk: $GOLDEN_NVME"
    echo "[build_installed_nvme]   (set HAMNIX_FORCE_GOLDEN=1 to rebuild)"
    exit 0
fi

# --- Stage A: build ESP-only installer medium + blank NVMe target -----
echo "[build_installed_nvme] Stage A: build ESP-only installer medium + blank NVMe target"
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    rm -f "$INSTALLER_IMG"
    HAMNIX_INSTALLER_AUTORUN=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"  # golden-disk build needs the unattended auto-install path
fi
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_warn_if_stale "$INSTALLER_IMG" "[build_installed_nvme]"
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[build_installed_nvme] FAIL Stage A: $INSTALLER_IMG not built" >&2
    exit 1
fi

# Build the golden NVMe into a temp first; only promote to GOLDEN_NVME on
# a fully-verified install, so a partial/failed run never leaves a corrupt
# "golden" disk behind.
mkdir -p build
GOLDEN_TMP=$(mktemp --tmpdir="$PROJ_ROOT/build" hamnix-installed.XXXXXX.qcow2)
rm -f "$GOLDEN_TMP"
qemu-img create -f qcow2 "$GOLDEN_TMP" "$NVME_SIZE" >/dev/null
echo "[build_installed_nvme] Stage A: blank NVMe target $GOLDEN_TMP ($NVME_SIZE)"

OVMF_RW=$(mktemp --tmpdir hamnix-installed.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-installed.media.XXXXXX.img)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$MEDIA_RW"

STAGE_LOG=$(mktemp --tmpdir hamnix-installed-build.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-installed-in.XXXXXX)
mkfifo "$INFIFO"

PROMOTED=0
cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$MEDIA_RW" "$INFIFO" "$STAGE_LOG"
    # If we never promoted the temp to the golden disk, remove it.
    [ "$PROMOTED" -eq 0 ] && rm -f "$GOLDEN_TMP"
}
trap cleanup EXIT

# --- Stage B: boot installer medium + blank NVMe, run the installer ---
echo "[build_installed_nvme] Stage B: boot installer (OVMF) + blank NVMe; run /etc/install_nvme.hamsh"

exec 4<>"$INFIFO"
exec 3>"$INFIFO"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$MEDIA_RW",format=raw,if=none,id=media \
    -device virtio-blk-pci,drive=media,bootindex=0 \
    -drive file="$GOLDEN_TMP",format=qcow2,if=none,id=nvmetgt \
    -device nvme,drive=nvmetgt,serial=hamnvme01,bootindex=1 \
    -m 1280M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$STAGE_LOG" 2>&1 &
QEMU_PID=$!

# Wait for the install to complete. rc.boot AUTO-RUNS /etc/install_nvme.hamsh
# when it probes a real install target distinct from the boot medium and
# prints "auto-running /etc/install_nvme.hamsh" — but that target probe is
# timing-sensitive under KVM and does NOT always fire, in which case the
# installer just sits at a bare interactive "[hamsh] ... shell ready"
# prompt. So: wait for the shell to be READY (either the full-rc handoff
# marker OR the bare hamsh-ready banner), then — unless the auto-run
# already kicked off — drive /etc/install_nvme.hamsh MANUALLY. Both flows
# converge on the same "install complete" marker.
echo "[build_installed_nvme] Stage B: waiting for install to complete (auto-run or driven)..."
type_b() { printf '%s\n' "$1" >&3; sleep "${2:-4}"; }
# Completion is signalled by install.ad ("[install] install complete on
# /dev/blk/nvme0n1") and then install_nvme.hamsh ("[install-nvme] install
# complete"). Match either — neither emits the old combined string the
# harness used to grep for (which never matched, hanging the build).
INSTALL_DONE_MARKER='\[install\] install complete on /dev/blk/nvme0n1|\[install-nvme\] install complete'
READY_RE="$PROMPT_MARKER|\[hamsh\] M16.35 shell ready"
AUTORUN_RE='auto-running /etc/install_nvme.hamsh'
typed=0
installed=0
for _ in $(seq 1 $((BOOT_TIMEOUT + INSTALL_WAIT))); do
    if grep -a -E -q "$INSTALL_DONE_MARKER" "$STAGE_LOG"; then
        installed=1; break
    fi
    # Once the shell is ready, drive the installer manually — but only if
    # rc.boot's auto-run path did NOT already start it (avoid a double run).
    if [ "$typed" -eq 0 ] && grep -a -E -q "$READY_RE" "$STAGE_LOG"; then
        if grep -a -E -q "$AUTORUN_RE" "$STAGE_LOG"; then
            echo "[build_installed_nvme] Stage B: rc.boot auto-run detected; awaiting completion."
        else
            echo "[build_installed_nvme] Stage B: shell ready, no auto-run; driving the NVMe installer manually."
            sleep 6
            type_b "hamsh /etc/install_nvme.hamsh" 2
        fi
        typed=1
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[build_installed_nvme] FAIL Stage B: qemu exited during install." >&2
        tail -100 "$STAGE_LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$installed" -ne 1 ]; then
    echo "[build_installed_nvme] FAIL Stage B: 'install complete' not seen in $((BOOT_TIMEOUT + INSTALL_WAIT))s." >&2
    tail -100 "$STAGE_LOG" >&2
    exit 1
fi
sleep 2
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&-
exec 4>&-

# --- HOST verification: real bytes landed on the NVMe qcow2 ------------
fail=0
NVME_RAW=$(mktemp --tmpdir hamnix-installed-raw.XXXXXX.img)
if qemu-img convert -O raw "$GOLDEN_TMP" "$NVME_RAW" 2>/dev/null; then
    mbr_sig=$(od -An -N2 -tx1 -j 0x1FE "$NVME_RAW" | tr -d ' \n')
    gpt_sig=$(od -An -N8 -c -j 0x200 "$NVME_RAW" | tr -d ' \n')
    [ "$mbr_sig" = "55aa" ] || { echo "[build_installed_nvme] MISS: NVMe MBR signature (got 0x$mbr_sig)" >&2; fail=1; }
    echo "$gpt_sig" | grep -q "EFIPART" || { echo "[build_installed_nvme] MISS: NVMe GPT 'EFI PART' (got '$gpt_sig')" >&2; fail=1; }
    # ESP at LBA 2048 (1 MiB), 64 MiB; rootfs follows at 65 MiB.
    root_off=$(( 65 * 1024 * 1024 + 1024 + 0x38 ))
    ext4_magic=$(od -An -N2 -tx1 -j "$root_off" "$NVME_RAW" | tr -d ' \n')
    [ "$ext4_magic" = "53ef" ] || { echo "[build_installed_nvme] MISS: ext4 magic at rootfs offset (got 0x$ext4_magic)" >&2; fail=1; }
else
    echo "[build_installed_nvme] FAIL: could not convert golden qcow2 for verification" >&2
    fail=1
fi
rm -f "$NVME_RAW"

if [ "$fail" -ne 0 ]; then
    echo "[build_installed_nvme] FAIL: install did not land a valid GPT+ext4 on NVMe." >&2
    exit 1
fi

# Promote the verified temp disk to the golden path atomically.
mv -f "$GOLDEN_TMP" "$GOLDEN_NVME"
PROMOTED=1
echo "[build_installed_nvme] DONE: golden installed disk $GOLDEN_NVME"
echo "[build_installed_nvme]   real installer path verified: GPT + ext4 root + ESP on NVMe (HOST byte-checked)."
echo "[build_installed_nvme]   feature tests boot a fresh COPY of this disk via scripts/_installed_boot.sh."
exit 0
