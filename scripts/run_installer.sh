#!/usr/bin/env bash
# run_installer.sh — boot the Hamnix installer image in QEMU, correctly.
#
# WHY THIS EXISTS
# ---------------
# The installer is EFI-booted under OVMF. OVMF only auto-launches a disk's
# \EFI\BOOT\BOOTX64.EFI when that disk is its chosen boot candidate. The moment
# you also attach a blank NVMe target and/or a NIC (which you MUST, to install
# to and to get networking), OVMF's boot-device selection stops picking the
# installer media — it falls through to the EFI Internal Shell, or, if a NIC is
# present, to PXE network boot. The cure is an EXPLICIT `bootindex=0` on the
# installer media so OVMF always boots it first. A read-only system OVMF also
# can't persist its boot vars, so we boot a WRITABLE copy. This script sets both
# up (plus a blank NVMe install target and a user-mode NIC) so the installer
# "just boots" — then you run `/etc/install_nvme.hamsh` inside it to install to
# the NVMe, power off, and boot the installed disk with scripts/_installed_boot.sh.
#
# USAGE
#   bash scripts/run_installer.sh                 # GTK window, KVM if available
#   HEADLESS=1 bash scripts/run_installer.sh      # no window; serial on stdio
#   DISK=/path/target.qcow2 bash scripts/run_installer.sh   # persist the install
#
# KNOBS (env)
#   IMG        installer image           (default: build/hamnix-installer.img; built if absent)
#   DISK       NVMe install target       (default: /tmp/hamnix-install-target.qcow2, 16G, created if absent)
#   MEM        guest RAM                  (default: 2G)
#   OVMF_FD    OVMF firmware              (auto-resolved)
#   HEADLESS   1 => -display none + -serial stdio (default: GTK window + serial to a log)
#   NO_NET     1 => omit the NIC          (default: user-mode virtio-net attached)
#   NO_KVM     1 => force TCG             (default: KVM when /dev/kvm exists)
set -euo pipefail
cd "$(dirname "$0")/.."

# AUTO_INSTALL=1 => build/use an UNATTENDED medium that auto-wipes the target
# (for testing/CI only). DEFAULT (unset) => the normal LIVE install medium: it
# boots to the desktop and you run the installer YOURSELF ("Install Hamnix" or
# `install`), which prompts for the disk and confirms the erase. Distinct image
# paths so the two never clobber each other.
if [ -n "${AUTO_INSTALL:-}" ]; then
    IMG="${IMG:-build/hamnix-installer-autorun.img}"
    AUTORUN_BUILD_ENV="HAMNIX_INSTALLER_AUTORUN=1"
else
    IMG="${IMG:-build/hamnix-installer.img}"
    AUTORUN_BUILD_ENV=""
fi
DISK="${DISK:-/tmp/hamnix-install-target.qcow2}"
MEM="${MEM:-2G}"

say() { echo "[run_installer] $*"; }

# --- installer image (build on demand) --------------------------------------
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
if installer_img_needs_build "$IMG" "[run_installer]"; then
    say "installer image $IMG absent/stale — building via scripts/build_installer_img.sh (~14 min)"
    env $AUTORUN_BUILD_ENV HAMNIX_INSTALLER_IMG_OUT="$IMG" bash scripts/build_installer_img.sh
fi
[ -f "$IMG" ] || { say "FAIL: $IMG still missing after build."; exit 1; }

# --- OVMF firmware (writable copy so UEFI can persist boot vars) -------------
if [ -z "${OVMF_FD:-}" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && { OVMF_FD="$c"; break; }
    done
fi
{ [ -n "${OVMF_FD:-}" ] && [ -f "$OVMF_FD" ]; } || { say "FAIL: OVMF firmware not found (apt install ovmf)."; exit 1; }
OVMF_RW=$(mktemp --tmpdir hamnix-installer.ovmf.XXXXXX.fd)
cp "$OVMF_FD" "$OVMF_RW"

# --- blank NVMe install target ----------------------------------------------
if [ ! -f "$DISK" ]; then
    say "creating a blank 16G NVMe install target at $DISK"
    qemu-img create -f qcow2 "$DISK" 16G >/dev/null
fi

cleanup() { rm -f "$OVMF_RW"; }
trap cleanup EXIT

# --- accel / display / net --------------------------------------------------
ACCEL=(); if [ -z "${NO_KVM:-}" ] && [ -e /dev/kvm ]; then ACCEL=(-enable-kvm -cpu host); else ACCEL=(-cpu qemu64); say "no /dev/kvm (or NO_KVM set): TCG — boot will be slow"; fi

NET=(); if [ -z "${NO_NET:-}" ]; then NET=(-netdev user,id=hnet0 -device virtio-net-pci,netdev=hnet0); fi

# --- audio: attach an Intel HDA controller + output codec -------------------
# So the native HDA driver enumerates a class-0403 device at boot and the DE's
# volume applet / aplay / playtone find a live /dev/audio. Without this the guest
# has NO sound device at all (hda_init skips) — the "nothing is audible" report.
#
# HDA_AUDIODEV picks the HOST backend. Default = auto-detect a backend that
# ACTUALLY EMITS to the host speakers. We prefer **alsa** first: it is the
# lowest-level, most universally present sink and it works even when a session's
# PipeWire/PulseAudio routing is broken or misconfigured (observed on the dev box
# — pipewire did NOT emit there, ALSA to the default card did). We only need a
# real ALSA playback card present. Then fall back to native `pipewire`, then `pa`
# (works against pipewire-pulse too), and only pick `none` when nothing is usable.
# Set HDA_AUDIODEV=alsa|pipewire|pa|sdl|none to override, or
# HDA_AUDIODEV=wav,path=/tmp/out.wav to capture guest audio to a file. `none`
# still enumerates the device (DE works) but you won't hear it.
_qemu_has_audiodev() {   # $1=backend name -> 0 if this qemu build lists it
    qemu-system-x86_64 -audiodev help 2>/dev/null | grep -qx "$1"
}
if [ -z "${HDA_AUDIODEV:-}" ]; then
    _xrd="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [ -n "${NO_AUDIO:-}" ]; then
        HDA_AUDIODEV="none"
    elif _qemu_has_audiodev alsa && [ -e /proc/asound/cards ] && grep -q '[0-9]' /proc/asound/cards 2>/dev/null; then
        HDA_AUDIODEV="alsa"
        [ -z "${HEADLESS:-}" ] && say "audio backend: alsa (default host card; override with HDA_AUDIODEV=pipewire|pa)"
    elif [ -S "$_xrd/pipewire-0" ] && _qemu_has_audiodev pipewire; then
        HDA_AUDIODEV="pipewire"
        [ -z "${HEADLESS:-}" ] && say "audio backend: pipewire (native socket $_xrd/pipewire-0)"
    elif [ -S "$_xrd/pulse/native" ]; then
        HDA_AUDIODEV="pa"
        [ -z "${HEADLESS:-}" ] && say "audio backend: pa (PulseAudio socket)"
    else
        HDA_AUDIODEV="none"
        [ -z "${HEADLESS:-}" ] && say "no ALSA card / PipeWire / PulseAudio found: audio device enumerated but muted (set HDA_AUDIODEV=alsa|pipewire|pa|sdl to hear it)"
    fi
fi
AUDIO=(-audiodev "${HDA_AUDIODEV},id=snd0" -device intel-hda -device hda-output,audiodev=snd0)

DISPLAY_ARGS=(); LOG=""
if [ -n "${HEADLESS:-}" ]; then
    DISPLAY_ARGS=(-display none -serial stdio)
else
    LOG=$(mktemp --tmpdir hamnix-installer.serial.XXXXXX.log)
    DISPLAY_ARGS=(-vga std -display gtk -serial "file:$LOG")
    say "serial log: $LOG"
fi

say "media=$IMG  target=$DISK  mem=$MEM  accel=${ACCEL[*]}"
if [ -n "${AUTO_INSTALL:-}" ]; then
    say "AUTO_INSTALL: this UNATTENDED medium will auto-wipe $DISK and install — no prompt."
else
    say "LIVE medium: the desktop comes up; to install, run the \"Install Hamnix\" launcher"
    say "(or type  install  at a hamsh prompt) — it prompts for the disk and confirms the erase."
fi

# The installer media carries \EFI\BOOT\BOOTX64.EFI; bootindex=0 forces OVMF to
# boot it even with the NVMe target + NIC present (otherwise -> EFI shell / PXE).
exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -m "$MEM" \
    -bios "$OVMF_RW" \
    -drive "file=$IMG,format=raw,if=none,id=instmedia" \
    -device virtio-blk-pci,drive=instmedia,bootindex=0 \
    -device nvme,drive=nvmetgt,serial=hamtgt01 \
    -drive "file=$DISK,format=qcow2,if=none,id=nvmetgt" \
    "${NET[@]}" \
    "${AUDIO[@]}" \
    "${DISPLAY_ARGS[@]}" \
    -no-reboot \
    -monitor none
