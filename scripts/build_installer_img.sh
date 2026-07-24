#!/usr/bin/env bash
# scripts/build_installer_img.sh — build the IN-RAM-SQUASHFS install
# medium: build/hamnix-installer.img.
#
# THE "NO MEDIA READ" INSTALLER (design: the install brief). The install
# medium produced here is an ESP-ONLY GPT image:
#
#   GPT disk
#   └── Partition 1: ESP (FAT12)
#         \EFI\BOOT\BOOTX64.EFI   the native PE/COFF stub (efi_stub.S)
#         \hamnix-kernel.elf      the INSTALLER kernel — its cpio embeds
#                                 /rootfs.sqfs (the full rootfs payload)
#                                 + /etc/install_nvme.hamsh + the
#                                 /etc/installer-medium marker.
#
# There is DELIBERATELY NO ext4 partition 2 on this medium. The entire
# installer rootfs payload rides in the firmware-loaded cpio as a single
# squashfs file; the installer reads its payload from the IN-RAM squashfs,
# NEVER from the media block device. On the real NUC target the install
# media is a USB stick whose native driver is broken, so any runtime media
# read would defeat the in-RAM model — the ESP-only layout is itself the
# load-bearing proof the USB path is gone.
#
# THE TWO-KERNEL BREAK (avoids an infinite "kernel embeds an ESP that
# embeds the kernel" recursion):
#   * INSTALLED kernel  = the normal kernel with an EMPTY cpio (boots off
#                         the NVMe ext4 root). This is what lands inside
#                         /esp.img (and thus on the NVMe ESP after install).
#   * INSTALLER kernel  = a kernel whose cpio embeds /rootfs.sqfs. This is
#                         what lands on the install-medium ESP and runs the
#                         installer in RAM. It is a SEPARATE build artifact.
#
# Squashfs payload (built here, gzip-compressed):
#   /rootfs.sqfs
#     ├── /rootfs.ext4   the full ext4 root (build_rootfs_img.py output)
#     └── /esp.img       the NVMe ESP FAT image (installed kernel + stub)
#
# Build artifacts are NOT committed (the kernel/cpio/squashfs are large);
# the git 100 MB push limit does not apply.
#
# Env overrides:
#   HAMNIX_INSTALLER_IMG_OUT   output image      (default: build/hamnix-installer.img)
#   HAMNIX_ROOTFS_SIZE_MB      shipped ext4 MiB  (default: auto-size)
#   HAMNIX_ROOTFS_MIN_MB       shipped ext4 floor MiB (default: 512)
#   HAMNIX_TARGET_ESP_MB       NVMe ESP FAT MiB  (default: 64; must match
#                              install_nvme.hamsh's ESP partition size)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Opt-in build isolation: HAMNIX_BUILD_DIR relocates the per-invocation
# image/kernel outputs, the generated initramfs blob, and the build lock
# into a caller-chosen directory so two builds in ONE checkout don't
# clobber each other. Default (unset) → the historical build/ tree.
# Export it so the kernel compile (compiler.adder) and build_initramfs.py
# sub-invocations agree on the blob location and lock dir.
OUTDIR="${HAMNIX_BUILD_DIR:-$PROJ_ROOT/build}"
mkdir -p "$OUTDIR"
export HAMNIX_BUILD_DIR="$OUTDIR"

# The installer is the PRIMARY ship vehicle and must carry the real
# Debian userland. _build_lock.sh (sourced just below) defaults
# HAMNIX_DEFAULT_REAL_DEBIAN=0 for the bare-kernel unit lane; the shipped
# image OPTS BACK IN so its initramfs/rootfs keep genuine apt/dpkg. This
# MUST run BEFORE sourcing _build_lock.sh (which would otherwise stamp 0
# first, and this `:-` would then see it already set). An explicit caller
# value still wins.
export HAMNIX_DEFAULT_REAL_DEBIAN="${HAMNIX_DEFAULT_REAL_DEBIAN:-1}"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

# Track-3 self-hosting: Adder-compiler backend selector ($ADDER_CC; default
# `python` = the frozen seed). `adder_cc_compile` is a drop-in for
# `python3 -m compiler.adder compile`. See scripts/_adder_cc.sh +
# docs/subsystems/adder-compiler.md.
# shellcheck source=_adder_cc.sh
source "$PROJ_ROOT/scripts/_adder_cc.sh"

# OPTIMIZED-ADDER SHIP DEFAULT (user directive: "being able to compile and run
# the OS should always be the bar for adopting new optimizations").
#
# STATUS 2026-07-19: the full --opt mechanism (kernel + every userland ELF, with
# a per-binary exclusion escape hatch) is wired and both halves COMPILE clean (0
# cg_fail, 0 native->seed fallbacks). But driving the SHIPPED .img under
# OVMF/KVM to the graphical desktop shows that NEITHER --opt path yet MEETS the
# "OS must run" bar, so both default OFF. The mechanism stays so flipping either
# to 1 is a one-line change the moment the underlying codegen bugs land. The
# differential fuzzer + the test_opt_* bench kernels are 0-miscompile, so these
# are codegen patterns exercised by large hand-written kernel/userland code that
# the microbenchmarks do not cover.
#
#   HAMNIX_USER_OPT default 0 — userland --opt has RUNTIME miscompiles:
#       * /bin/hamsh --opt -> an early rc.boot child (pid 6) takes a read-prot
#         #PF (va=0x34d0f099) -> SIGSEGV and wedges PID 1; the box never reaches
#         the desktop. Bisected: reproduces with ONLY hamsh --opt (cat/init
#         excluded) and DISAPPEARS the moment hamsh is built no-opt.
#       * the scene DE apps (hampanelscene/hamdesktop/...) --opt -> the
#         compositor comes up but paints a BLANK backdrop (panel + icons never
#         render), even with hamsh/cat/init excluded.
#     Per-binary rollback is available via HAMNIX_USER_OPT_EXCLUDE="name ...".
#
#   HAMNIX_KERNEL_OPT default 0 — the --opt kernel COMPILES and boots clean to a
#     shell (it passes scripts/test_opt_kernel_boot.sh, which only asserts
#     userspace/getty-alive), but driving the scene DESKTOP exposes a deeper
#     bug: with an IDENTICAL no-opt userland, the --opt kernel boots, starts the
#     hamUI stack, prints "[scene_de] clean first-boot desktop" and then WEDGES
#     during DE bring-up -- it never reaches "handing off to interactive shell"
#     (reproduced 2x under OVMF, -smp 1, no rival qemu, loadavg<3, so not the
#     known -smp2 starvation stall). The no-opt kernel with the same userland
#     reaches the full MATE-style desktop (panel + icons, screendumped). So the
#     kernel --opt has a runtime miscompile in the DE-bring-up path (heavy
#     rfork/scheduling/mm); it must be fixed in adder/compiler before flipping
#     this to 1. Opt in with HAMNIX_KERNEL_OPT=1 (boots to a shell; wedges the
#     graphical desktop).
#
# Exported so build_user.sh + build_initramfs.py + the kernel compile agree.
export HAMNIX_KERNEL_OPT="${HAMNIX_KERNEL_OPT:-0}"
export HAMNIX_USER_OPT="${HAMNIX_USER_OPT:-0}"
export HAMNIX_USER_OPT_EXCLUDE="${HAMNIX_USER_OPT_EXCLUDE:-}"

# ============================================================================
# SHIPPED-KERNEL BACKEND (user directive 2026-07-24: LLVM is the MAIN/DEFAULT
# build path; native stays as bootstrap + oracle + fallback).
#
#   HAMNIX_KERNEL_BACKEND=llvm    (DEFAULT) — the shipped INSTALLED + INSTALLER
#       kernels are compiled through the Adder LLVM backend (Adder SSA IR ->
#       textual LLVM IR -> clang-19 -> ELF64) and linked as the NATIVE-HYBRID
#       kernel (scripts/build_kernel_llvm.sh): the LLVM object supplies the vast
#       majority of the 11k functions; a small set that the LLVM backend still
#       bails (start_kernel/do_syscall/... + the layout-sensitive memblock_alloc
#       route) fall through to a native-compiled main.o via
#       `ld --allow-multiple-definition`. Requires clang-19 in PATH.
#
#   HAMNIX_KERNEL_BACKEND=native  (FALLBACK) — the shipped kernels are compiled
#       by the native Adder SSA backend (adder_cc_compile -> adder_cc_link_kernel
#       in scripts/_adder_cc.sh), exactly the historical default. Use this when
#       clang-19 is unavailable, to A/B a suspected LLVM-codegen bug, or to
#       reproduce the byte-identical native reference image.
#
# WHAT STAYS NATIVE REGARDLESS OF THIS FLAG (do NOT confuse with the ship path):
#   * the BOOTSTRAP — the Python seed compiles host_ac via the native backend
#     (adder_cc_bootstrap); the LLVM backend lives INSIDE that same host_ac.
#   * the kobjdiff ORACLE — scripts/test_native_vs_seed_kobjdiff.sh (native ==
#     seed byte-identity) is unaffected; it never runs the LLVM lane.
# See docs/llvm_default_build.md.
export HAMNIX_KERNEL_BACKEND="${HAMNIX_KERNEL_BACKEND:-llvm}"

# _build_ship_kernel <out-elf>
# Build ONE shipped kernel ELF (init/main.ad closure) with the currently-selected
# backend, consuming whatever initramfs blob build_initramfs.py last emitted into
# $OUTDIR/initramfs_blob.S (empty cpio for the installed kernel; the squashfs
# payload for the installer kernel). Both backends link the SAME hand-written
# boot .S under arch/x86/kernel/kernel.lds, so the resulting ELF boots the
# identical firmware path either way.
_build_ship_kernel() {
    local out="$1"
    rm -f "$out"
    if [ "$HAMNIX_KERNEL_BACKEND" = "native" ]; then
        echo "[build_installer_img]   backend=native (adder_cc_link_kernel)"
        adder_cc_compile compile --target=x86_64-bare-metal init/main.ad -o "$out"
        return $?
    fi
    if [ "$HAMNIX_KERNEL_BACKEND" = "llvm" ]; then
        echo "[build_installer_img]   backend=llvm (build_kernel_llvm.sh native-hybrid)"
        command -v "${CLANG:-clang-19}" >/dev/null 2>&1 || {
            echo "[build_installer_img] ERROR: HAMNIX_KERNEL_BACKEND=llvm needs '${CLANG:-clang-19}' in PATH." >&2
            echo "[build_installer_img]   Install clang-19, or rebuild with HAMNIX_KERNEL_BACKEND=native." >&2
            return 1
        }
        # host_ac (with its LLVM backend) is the SAME compiler the native lane
        # bootstraps; ensure it exists (build_user.sh in Stage 1 already did this,
        # but the LLVM lane invokes host_ac directly, so make it explicit).
        adder_cc_bootstrap || return 1
        HAMNIX_INITRAMFS_BLOB="$OUTDIR/initramfs_blob.S" \
            bash "$PROJ_ROOT/scripts/build_kernel_llvm.sh" "$out"
        return $?
    fi
    echo "[build_installer_img] ERROR: unknown HAMNIX_KERNEL_BACKEND='$HAMNIX_KERNEL_BACKEND' (want llvm|native)" >&2
    return 2
}

OUT="${HAMNIX_INSTALLER_IMG_OUT:-$OUTDIR/hamnix-installer.img}"
INSTALLED_KERNEL="$OUTDIR/hamnix-installed-kernel.elf"
INSTALLER_KERNEL="$OUTDIR/hamnix-installer-kernel.elf"
EFI_STUB="$OUTDIR/hamnix-bootx64.efi"
ROOTFS_IMG="$OUTDIR/hamnix-rootfs.img"
SQFS_IMG="$OUTDIR/hamnix-rootfs.sqfs"
# Auto-size the shipped ext4 (staged bytes + metadata + apt scratch) with a
# 512 MiB FLOOR. Do NOT pin a fixed size here: the Debian fixture grows (real
# debootstrap closure + staged GUI clients), and a pinned 512 MiB made
# mkfs.ext4 fail with "Could not allocate block" once the closure passed it.
# An explicit HAMNIX_ROOTFS_SIZE_MB still overrides both.
export HAMNIX_ROOTFS_MIN_MB="${HAMNIX_ROOTFS_MIN_MB:-512}"
TARGET_ESP_MB="${HAMNIX_TARGET_ESP_MB:-64}"

# --- Host-tool sanity -------------------------------------------------
need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[build_installer_img] ERROR: '$1' not found in PATH." >&2
        echo "[build_installer_img]   apt-get install mtools binutils squashfs-tools parted e2fsprogs" >&2
        exit 1
    fi
}
need_tool mformat
need_tool mcopy
need_tool mmd
need_tool as
need_tool ld
need_tool dd
need_tool file
need_tool mksquashfs
PARTED="/sbin/parted"; [ -x "$PARTED" ] || PARTED="$(command -v parted || true)"
[ -n "$PARTED" ] || { echo "[build_installer_img] ERROR: parted not found" >&2; exit 1; }

mkdir -p build

# --- Stage 1: userland + the ext4 rootfs payload + package repo -------
echo "[build_installer_img] Stage 1: build userland + modules + ext4 rootfs payload."
bash scripts/build_user.sh
bash scripts/build_modules.sh
# Stage the offline file:// apt repo into the Debian fixture so the live
# #distro (which FULL-mirrors the fixture) can `apt-get install hamhello`
# with no network. No-op SKIP when the debootstrap fixture is absent.
bash scripts/build_local_apt_repo.sh || true
HAMNIX_ROOTFS_OUT="$ROOTFS_IMG" python3 scripts/build_rootfs_img.py
[ -f "$ROOTFS_IMG" ] || { echo "[build_installer_img] ERROR: $ROOTFS_IMG not built" >&2; exit 1; }
# DEBIAN-STYLE INSTALL: build the native package repo. The interactive
# `install` command (and the auto installer) populate the target ext4 root
# by `hpm --repo=file:///iso-packages install hamnix-base` — a real
# package install, not a golden-image dd. build_initramfs.py mirrors
# build/packages/main/ into the installer cpio at /iso-packages/main/ so
# the repo is firmware-loaded into RAM (no media read on the NUC).
#
# HAMNIX_BOOTLOADER_SLIM=1: the hamnix-bootloader package is metadata-only
# here. The installer lays the ESP (BOOTX64.EFI + kernel) onto the target
# via sqfs_to_blk from the in-RAM esp.img — NOT from the bootloader
# package's files — so the package needs no kernel ELF payload. This also
# decouples the package build from build_iso.sh (which produces
# build/hamnix-kernel.elf); this installer pipeline builds its own
# kernels in Stages 3/6 and never invokes build_iso.sh.
echo "[build_installer_img] Stage 1: build native package repo (build/packages/main)."
HAMNIX_BOOTLOADER_SLIM=1 python3 scripts/build_packages.py
[ -f "build/packages/main/index.json" ] || {
    echo "[build_installer_img] ERROR: build/packages/main/index.json not built" >&2
    exit 1
}

# --- Stage 2: the native UEFI stub ------------------------------------
echo "[build_installer_img] Stage 2: build native UEFI PE/COFF stub."
EFI_STUB_SRC="arch/x86/boot/efi_stub.S"
STUB_TMP=$(mktemp -d)
trap 'rm -rf "$STUB_TMP"' EXIT
as --64 -o "$STUB_TMP/efi_stub.o" "$EFI_STUB_SRC"
ld -m i386pep --subsystem 10 -e efi_main --image-base 0 \
   --no-dynamic-linker -nostdlib \
   -o "$EFI_STUB" "$STUB_TMP/efi_stub.o"
# Verify the stub is a genuine PE32+ EFI application by inspecting the
# PE header bytes directly — NOT by grepping file(1)'s human string,
# whose wording drifts between versions ("PE32+ executable (EFI
# application)" on file<=5.45 vs "PE32+ executable for EFI (application)"
# on file>=5.46). That drift silently reddened this gate on GitHub's
# runner (older file) while it passed locally. Check the invariant bytes
# instead: MZ magic, PE signature, optional-header magic 0x020b (PE32+),
# and subsystem 10 (EFI application).
python3 - "$EFI_STUB" <<'PY' \
    || { echo "[build_installer_img] ERROR: stub is not PE32+ EFI" >&2; exit 1; }
import sys, struct
d = open(sys.argv[1], 'rb').read()
if d[:2] != b'MZ': sys.exit("no MZ magic")
pe = struct.unpack_from('<I', d, 0x3c)[0]
if d[pe:pe+4] != b'PE\0\0': sys.exit("no PE signature")
magic  = struct.unpack_from('<H', d, pe + 24)[0]          # optional header magic
subsys = struct.unpack_from('<H', d, pe + 24 + 68)[0]     # PE32+ Subsystem field
if magic != 0x020b: sys.exit(f"optional-header magic 0x{magic:04x} != 0x020b (PE32+)")
if subsys != 10:    sys.exit(f"subsystem {subsys} != 10 (EFI application)")
PY

# --- Stage 3: the INSTALLED kernel (empty cpio; boots off NVMe ext4) --
# This is the kernel that lands on the NVMe ESP. It carries no installer
# payload — the installed disk boots off its ext4 root, exactly like
# build_img.sh's shipped image. Native USB stays the default (the install
# writes a real disk; the installed system is what reads it at boot — on a
# NUC that is NVMe, not USB).
echo "[build_installer_img] Stage 3: compile INSTALLED kernel (empty cpio)."
env HAMNIX_CPIO_EMPTY=1 INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
_build_ship_kernel "$INSTALLED_KERNEL"
[ -f "$INSTALLED_KERNEL" ] || { echo "[build_installer_img] ERROR: installed kernel not built" >&2; exit 1; }
echo "[build_installer_img]   installed kernel: $(file -b "$INSTALLED_KERNEL")"
# #410 Item 1 — HARD CPIO-INTENT ASSERT (installed kernel). The compiled
# ELF's ACTUAL embedded cpio must match the manifest build_initramfs.py
# just emitted (stale/raced-blob detector) and must NOT carry the
# installer payload. Snapshot the manifest next to the kernel because
# Stage 6 re-runs build_initramfs.py and overwrites it.
INSTALLED_MANIFEST="$INSTALLED_KERNEL.cpio-manifest"
cp "$OUTDIR/initramfs_blob.S.manifest" "$INSTALLED_MANIFEST"
python3 scripts/verify_kernel_cpio.py \
    --elf "$INSTALLED_KERNEL" --manifest "$INSTALLED_MANIFEST" \
    --forbid /init --forbid /rootfs.sqfs

# --- Stage 4: the NVMe ESP FAT image (esp.img) ------------------------
# A real FAT12 ESP carrying the EFI stub + the INSTALLED kernel. This is
# what install_nvme.hamsh streams onto the NVMe ESP partition. Its size
# MUST be <= the NVMe ESP partition (HAMNIX_TARGET_ESP_MB) the installer
# carves, since the streamer writes it verbatim starting at LBA 0.
echo "[build_installer_img] Stage 4: build NVMe ESP FAT image (esp.img)."
INSTALLED_KERNEL_BYTES=$(stat -c%s "$INSTALLED_KERNEL")
NEED_MB=$(( (INSTALLED_KERNEL_BYTES + (8 * 1024 * 1024)) / (1024 * 1024) ))
if [ "$NEED_MB" -ge "$TARGET_ESP_MB" ]; then
    echo "[build_installer_img] ERROR: installed kernel (${INSTALLED_KERNEL_BYTES} B)" >&2
    echo "[build_installer_img]   does not fit a ${TARGET_ESP_MB} MiB ESP; raise HAMNIX_TARGET_ESP_MB" >&2
    echo "[build_installer_img]   AND the ESP size in etc/install_nvme.hamsh." >&2
    exit 1
fi
# Size the FAT image a hair UNDER the partition so the verbatim stream
# fits: use TARGET_ESP_MB minus 1 MiB of slack, floored at 32.
ESP_IMG_MB=$(( TARGET_ESP_MB - 1 ))
[ "$ESP_IMG_MB" -ge 32 ] || ESP_IMG_MB=32
TARGET_ESP="$STUB_TMP/esp.img"
dd if=/dev/zero of="$TARGET_ESP" bs=1M count="$ESP_IMG_MB" status=none
mformat -i "$TARGET_ESP" -h 64 -s 32 -c 32 -t $(( ESP_IMG_MB * 64 )) -v HAMNIX ::
# Preallocate \LOG.TXT FIRST (before any other file) so its data extent is
# the first contiguous cluster run — the kernel (kernel/printk/esp_log.ad)
# locates this extent at boot and overwrites it in place to persist the
# printk ring. This is the SAME boot-log-persistence preallocation the
# retired build_img.sh did; it now rides on the installed system's NVMe ESP
# so scripts/test_esp_boot_log.sh keeps its coverage on the installed disk.
# HAMNIX_ESP_LOG_SIZE MUST match ESP_LOG_BYTES in esp_log.ad (default
# 262144 = 256 KiB). Fill with newlines so the file is clean text to EOF.
HAMNIX_ESP_LOG_SIZE="${HAMNIX_ESP_LOG_SIZE:-262144}"
ESP_LOG_SRC="$STUB_TMP/log.txt"
head -c "$HAMNIX_ESP_LOG_SIZE" /dev/zero | tr '\0' '\n' > "$ESP_LOG_SRC"
mcopy -o -i "$TARGET_ESP" "$ESP_LOG_SRC" "::/LOG.TXT"
# Preallocate \OOPS.BIN right after LOG.TXT (same contiguity rationale)
# so kernel/printk/esp_log.ad can locate its data extent via the same
# FAT root-dir scan and overwrite byte 0 in place when panic() fires.
# Size MUST match ESP_OOPS_BYTES in esp_log.ad (default 65536 = 64 KiB).
# A zero fill is fine — the kernel writes a fresh structured record.
HAMNIX_ESP_OOPS_SIZE="${HAMNIX_ESP_OOPS_SIZE:-65536}"
ESP_OOPS_SRC="$STUB_TMP/oops.bin"
head -c "$HAMNIX_ESP_OOPS_SIZE" /dev/zero > "$ESP_OOPS_SRC"
mcopy -o -i "$TARGET_ESP" "$ESP_OOPS_SRC" "::/OOPS.BIN"
mmd -i "$TARGET_ESP" "::/EFI"
mmd -i "$TARGET_ESP" "::/EFI/BOOT"
mcopy -o -i "$TARGET_ESP" "$EFI_STUB"          "::/EFI/BOOT/BOOTX64.EFI"
mcopy -o -i "$TARGET_ESP" "$INSTALLED_KERNEL"  "::/hamnix-kernel.elf"
echo "[build_installer_img]   NVMe ESP image: ${ESP_IMG_MB} MiB (LOG.TXT + BOOTX64.EFI + installed kernel)."

# --- Stage 5: the squashfs payload (esp.img + live-distro.ext4) -------
# DEBIAN-STYLE INSTALL: the squashfs carries the NVMe ESP FAT image (the
# target ROOT is a real package install — `hpm install hamnix-base` from
# the in-RAM /iso-packages repo — not a golden-image stream) PLUS the
# LIVE-medium Debian distro image (#410 Item 2): a compact ext4 whose
# .hamnix-roots declares #distro only. On a LIVE boot (no install
# target) rc.boot triggers `sqfs_live_root /rootfs.sqfs
# /live-distro.ext4` which extracts it into a RAM block device and
# posts #distro, so `enter linux { ... }` runs real Debian binaries
# with NOTHING read from the media. The ESP is byte-copied because FAT
# has no per-file kernel writer. The reader (fs/squashfs.ad) supports
# gzip (id=1) + xz (id=4) and a block size up to 1 MiB; mksquashfs'
# 128 KiB default is well within.
echo "[build_installer_img] Stage 5: build in-RAM squashfs payload (esp.img + live-distro.ext4)."
LIVE_DISTRO_IMG="$OUTDIR/hamnix-live-distro.img"
HAMNIX_ROOTFS_LIVE=1 HAMNIX_ROOTFS_OUT="$LIVE_DISTRO_IMG" \
    HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_LIVE_DISTRO_SIZE_MB:-}" \
    python3 scripts/build_rootfs_img.py
[ -f "$LIVE_DISTRO_IMG" ] || { echo "[build_installer_img] ERROR: $LIVE_DISTRO_IMG not built" >&2; exit 1; }
SQFS_STAGE=$(mktemp -d)
cp "$TARGET_ESP"      "$SQFS_STAGE/esp.img"
cp "$LIVE_DISTRO_IMG" "$SQFS_STAGE/live-distro.ext4"
rm -f "$SQFS_IMG"
mksquashfs "$SQFS_STAGE" "$SQFS_IMG" -comp gzip -noappend -no-progress \
    -no-xattrs >/dev/null
rm -rf "$SQFS_STAGE"
SQFS_BYTES=$(stat -c%s "$SQFS_IMG")
echo "[build_installer_img]   squashfs: $SQFS_IMG ($(( SQFS_BYTES / 1024 / 1024 )) MiB; live distro $(stat -c%s "$LIVE_DISTRO_IMG") B raw)."

# --- Stage 6: the INSTALLER kernel (cpio embeds the squashfs) ---------
# LEAN CPIO (daily-driver RAM reclaim): HAMNIX_CPIO_LEAN=1 makes
# build_initramfs.py SKIP embedding the ~1.1 GiB /var/lib/distros/default
# Debian GUI tree into the kernel .rodata cpio. That tree is reserved
# FOREVER below kernel_image_end() (arch/x86/boot/head_64.S; e820.ad
# bumps the memblock floor past it), so at -m 2G it stole ~1.1 GiB of the
# guest's usable RAM. It is DEAD WEIGHT on the live/installer image: the
# live desktop's #distro is served from the compact ~21.5 MiB
# /rootfs.sqfs (drivers/block/loop.ad loop_sqfs_live_root, bound in
# etc/rc.boot.full) — NOT from this cpio tree — and the native DE +
# native /bin Adder apps (hambrowse, calc, video, audio) never touch it.
# Its only real consumers are the `-kernel` apt/dpkg DEV tests
# (test_linux_apt_install.sh, which builds its OWN fat-cpio
# build/hamnix-kernel.elf — unaffected here) and the not-yet-working
# Firefox/WebKit-via-Linux-ns bridge (follow-up: move that substrate to a
# disk-backed root). Everything load-bearing on the live path stays in the
# cpio: /init, /rootfs.sqfs, the native /bin tools + DE, /lib/modules .ko,
# and /iso-packages. HAMNIX_DEFAULT_REAL_DEBIAN=1 still drives Stages 1/5
# (rootfs.img + live-distro sqfs) unchanged; cpio_lean short-circuits the
# in-cpio embed only.
echo "[build_installer_img] Stage 6: compile INSTALLER kernel (cpio embeds /rootfs.sqfs, LEAN — no in-cpio Debian tree)."
env HAMNIX_INSTALLER_BLOB=1 HAMNIX_INSTALLER_SQFS="$SQFS_IMG" \
    HAMNIX_CPIO_LEAN=1 \
    ENABLE_LOG_SLOW="${ENABLE_LOG_SLOW:-0}" \
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
if [ "${ENABLE_LOG_SLOW:-0}" = "1" ]; then
    echo "[build_installer_img]   page-pause log capture ENABLED (/etc/log-slow planted)."
fi
_build_ship_kernel "$INSTALLER_KERNEL"
[ -f "$INSTALLER_KERNEL" ] || { echo "[build_installer_img] ERROR: installer kernel not built" >&2; exit 1; }
echo "[build_installer_img]   installer kernel: $(file -b "$INSTALLER_KERNEL")"
# #410 Item 1 — HARD CPIO-INTENT ASSERT (installer kernel). The compiled
# ELF MUST embed the full live payload: /init + /rootfs.sqfs, and the ELF
# must be at least as big as the squashfs it claims to carry. Also
# re-assert the Stage 3 INSTALLED kernel now that the payload size is
# known: an empty-cpio kernel must be smaller than the installer kernel
# by AT LEAST the squashfs payload (if the blob raced and the installed
# kernel got the installer blob, its size ~= the installer's and this
# bound trips regardless of how small the squashfs is).
INSTALLER_MANIFEST="$INSTALLER_KERNEL.cpio-manifest"
cp "$OUTDIR/initramfs_blob.S.manifest" "$INSTALLER_MANIFEST"
python3 scripts/verify_kernel_cpio.py \
    --elf "$INSTALLER_KERNEL" --manifest "$INSTALLER_MANIFEST" \
    --require /init --require /rootfs.sqfs \
    --min-elf-size "$SQFS_BYTES"
INSTALLER_ELF_BYTES=$(stat -c%s "$INSTALLER_KERNEL")
python3 scripts/verify_kernel_cpio.py \
    --elf "$INSTALLED_KERNEL" --manifest "$INSTALLED_MANIFEST" \
    --forbid /init --forbid /rootfs.sqfs \
    --max-elf-size $(( INSTALLER_ELF_BYTES - SQFS_BYTES ))

# --- Stage 7: the install-medium ESP (BOOTX64.EFI + installer kernel) -
echo "[build_installer_img] Stage 7: build install-medium ESP (FAT)."
INSTALLER_KERNEL_BYTES=$(stat -c%s "$INSTALLER_KERNEL")
MEDIA_ESP_MB=$(( (INSTALLER_KERNEL_BYTES + (16 * 1024 * 1024)) / (1024 * 1024) ))
[ "$MEDIA_ESP_MB" -ge 32 ] || MEDIA_ESP_MB=32
MEDIA_ESP="$STUB_TMP/media_esp.img"
dd if=/dev/zero of="$MEDIA_ESP" bs=1M count="$MEDIA_ESP_MB" status=none
# mformat's -t (cylinders) is a 16-bit field: it REJECTS any value > 65535
# ("Bad number N for -t"). The nominal cylinder count is MEDIA_ESP_MB*64 (64
# heads * 32 sectors = 2048 sectors = 1 MiB per cylinder), which overflows once
# the installer kernel exceeds ~1 GiB — e.g. a full-mirror live image carrying
# the Mesa/LLVM software-GL stack embeds a ~1.5 GiB kernel -> 95872 > 65535 and
# Stage 7 dies. mformat clamps the on-disk geometry to the ACTUAL file size
# regardless (verified: a 63 MiB image passed -t 4032 still yields 63
# cylinders), so capping -t at 65535 lets it size the FS from the file and
# produce a valid FAT32 ESP for large kernels while leaving every small ESP
# byte-for-byte unchanged.
MEDIA_ESP_TRACKS=$(( MEDIA_ESP_MB * 64 ))
[ "$MEDIA_ESP_TRACKS" -le 65535 ] || MEDIA_ESP_TRACKS=65535
mformat -i "$MEDIA_ESP" -h 64 -s 32 -c 32 -t "$MEDIA_ESP_TRACKS" -v HAMNIXINST ::
# Preallocate \LOG.TXT FIRST on the install-medium ESP too (same rationale
# as the NVMe ESP above): the installer medium IS the USB stick the box
# boots on the serial-less NUC, so scripts/test_esp_boot_log_usb.sh boots
# this image as a USB mass-storage device and recovers \LOG.TXT off its
# ESP. Without this preallocation esp_log has no extent to arm on the USB
# ESP — the exact original bug. Reuse the size/fill from Stage 4.
mcopy -o -i "$MEDIA_ESP" "$ESP_LOG_SRC" "::/LOG.TXT"
# OOPS.BIN on the install-medium ESP too — see Stage 4 above.
mcopy -o -i "$MEDIA_ESP" "$ESP_OOPS_SRC" "::/OOPS.BIN"
mmd -i "$MEDIA_ESP" "::/EFI"
mmd -i "$MEDIA_ESP" "::/EFI/BOOT"
mcopy -o -i "$MEDIA_ESP" "$EFI_STUB"          "::/EFI/BOOT/BOOTX64.EFI"
mcopy -o -i "$MEDIA_ESP" "$INSTALLER_KERNEL"  "::/hamnix-kernel.elf"
echo "[build_installer_img]   install-medium ESP: ${MEDIA_ESP_MB} MiB (LOG.TXT + installer kernel embeds ${SQFS_BYTES} B squashfs)."

# --- Stage 8: assemble the ESP-ONLY GPT install medium ----------------
# Layout: [1 MiB GPT] [ESP partition ONLY] [1 MiB GPT backup]. NO ext4
# partition 2 — there is physically NOTHING on the media for the
# installer to read.
echo "[build_installer_img] Stage 8: assemble ESP-ONLY GPT install medium."
ALIGN_MB=1
ESP_START_MB=$ALIGN_MB
ESP_END_MB=$(( ESP_START_MB + MEDIA_ESP_MB ))
TOTAL_MB=$(( ESP_END_MB + ALIGN_MB ))
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count="$TOTAL_MB" status=none
"$PARTED" -s "$OUT" mklabel gpt
"$PARTED" -s "$OUT" mkpart ESP fat32 "${ESP_START_MB}MiB" "${ESP_END_MB}MiB"
"$PARTED" -s "$OUT" set 1 esp on
dd if="$MEDIA_ESP" of="$OUT" bs=1M seek="$ESP_START_MB" conv=notrunc status=none

# --- Verify: GPT has EXACTLY ONE partition (the ESP) ------------------
echo "[build_installer_img] GPT partition table (must be ESP-ONLY):"
"$PARTED" -s "$OUT" unit s print 2>/dev/null | sed 's/^/    /'
NPARTS=$("$PARTED" -s "$OUT" unit s print 2>/dev/null \
            | awk '/^[ ]*[0-9]+/ {n++} END {print n+0}')
if [ "$NPARTS" -ne 1 ]; then
    echo "[build_installer_img] ERROR: install medium has $NPARTS partitions; must be 1 (ESP-only)." >&2
    exit 1
fi
echo "[build_installer_img]   ESP-ONLY layout confirmed (1 partition; no ext4 to read)."

IMG_BYTES=$(stat -c%s "$OUT")
echo "[build_installer_img] DONE: $OUT"
echo "[build_installer_img]   total image  : ${IMG_BYTES} bytes ($(( IMG_BYTES / 1024 / 1024 )) MiB)"
echo "[build_installer_img]   ESP part 1   : ${MEDIA_ESP_MB} MiB (BOOTX64.EFI + installer kernel)"
echo "[build_installer_img]   in-RAM sqfs  : ${SQFS_BYTES} bytes (rootfs.ext4 + esp.img), embedded in the kernel cpio"
echo "[build_installer_img] Boot it: bash scripts/run_installer.sh   (GTK window; sets bootindex + NVMe target + NIC correctly)"
echo "[build_installer_img]          then inside the guest run /etc/install_nvme.hamsh to install to the NVMe."
echo "[build_installer_img] Test:    bash scripts/test_installer_nvme_inram.sh"
