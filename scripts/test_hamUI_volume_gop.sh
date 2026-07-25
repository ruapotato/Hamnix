#!/usr/bin/env bash
# scripts/test_hamUI_volume_gop.sh — AUTHORITATIVE GATE for the panel
# volume applet's REAL mixer round-trip, proven on a REAL EFI GOP
# framebuffer (OVMF/UEFI) via the installer LIVE image with QEMU's
# intel-hda codec attached.
#
# What changed (user/hamUId.ad): the status-notifier volume applet no
# longer keeps a private VOL_LEVEL fake — vol_step()/vol_mute_toggle()
# (the exact functions the volume keys + OSD use) write Plan-9 ctl verbs
# ("master <pct>", "mute"/"unmute") to /dev/audioctl and then RE-READ the
# /dev/audio status line, so the displayed level is the kernel mixer's
# answer. On a box with no HDA codec the applet renders truthfully greyed
# (STATNOT_AUDIO == 0).
#
# WHY THE INSTALLER IMAGE / OVMF. Identical rationale to
# scripts/test_hamUI_evloop_gop.sh: on this host QEMU's multiboot1 +
# 64-bit ELF path provides no usable VBE framebuffer, so the daemon can
# only come up under OVMF/UEFI on a real EFI GOP framebuffer.
#
# DETERMINISTIC PROOF — NO serial injection / NO typing. We build the
# installer image with ENABLE_VOLRT_SELFTEST=1, which makes
# build_initramfs.py plant /etc/hamui-volrt-test (and drop hamde.svc so
# hamUId autostarts deterministically). The PROVEN 2-token `hamUId
# daemon` autostart finds that marker and routes into autoflag 52 ->
# daemon_volume_selftest. Each marker below only prints after an
# INDEPENDENT raw re-read of /dev/audio shows the mixer really changed.
#
# Markers asserted (emitted by daemon_volume_selftest, prefix "[volrt]"):
#     [volrt] audio_live=1   /dev/audio answered; mixer state parsed
#     [volrt] vol_set_ok=1   applet vol_step -> kernel master pct == 30
#     [volrt] mute_ok=1      applet mute toggle -> kernel mute latch == 1
#     [volrt] unmute_ok=1    second toggle -> latch 0, level preserved
#     [volrt] PASS
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or mksquashfs is unavailable.
#
# Env overrides:
#   INSTALLER_IMG      installer image path (default: build/hamnix-installer.img)
#   HAMNIX_SKIP_BUILD  1 = reuse existing installer image (default: rebuild
#                        WITH the volrt svc marker)
#   OVMF_FD            OVMF firmware path   (default: auto-resolved)
#   BOOT_WAIT          boot+selftest wait   (default: 240)
#   VOLRT_KEEP_LOG     1 = keep serial log on success

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
KERNEL_BANNER="Hamnix kernel booting"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_volume_gop] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
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
    echo "[test_volume_gop] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_volume_gop] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- build the installer image WITH the volrt svc marker ----------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_volume_gop] building installer image with ENABLE_VOLRT_SELFTEST=1 (autostart volume round-trip self-test)"
    ENABLE_VOLRT_SELFTEST=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[hamUI_volume_gop]"
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_volume_gop] SKIP: installer image $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-volrt.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-volrt.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-volrt.XXXXXX.log)
WAV=$(mktemp --tmpdir hamnix-volrt.XXXXXX.wav)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$MEDIA_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$MEDIA_RW" "$WAV"
}
trap cleanup EXIT

# -vga std under OVMF gives a real EFI GOP framebuffer. The intel-hda +
# hda-output pair (same flags as scripts/test_sound_mixer.sh) gives the
# native HDA driver a codec, so /dev/audio + /dev/audioctl are live and
# the applet's round-trip has a REAL mixer to talk to. The installer
# medium is attached as virtio-blk; NO NVMe target is attached, so the
# system boots its in-RAM cpio to runlevel 5, where the supervisor
# autostarts hamUId, which finds the volrt marker and runs the proof.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$MEDIA_RW",format=raw,if=none,id=media \
    -device virtio-blk-pci,drive=media,bootindex=0 \
    -audiodev "wav,id=snd0,path=$WAV" \
    -device intel-hda \
    -device hda-output,audiodev=snd0 \
    -m 1280M \
    -vga std -display none -no-reboot -monitor none \
    -serial stdio \
    < /dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for the self-test's verdict (or boot failure) ----------------
echo "[test_volume_gop] waiting up to ${BOOT_WAIT}s for the autostart volume round-trip self-test..."
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E "\[volrt\] (PASS|FAIL)" "$LOG"; then
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

sleep 1
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

# --- captured markers -------------------------------------------------
echo "[test_volume_gop] --- captured serial output (volrt markers) ---"
grep -a -E 'EFI GOP framebuffer console ready|DAEMON up screen=|\[volrt\]' "$LOG" | head -40
echo "[test_volume_gop] --- end ---"

# --- assertions -------------------------------------------------------
fail=0

if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_volume_gop] FAIL: kernel panic / trap" >&2
    grep -a -E "PANIC|panic:|TRAP:|BUG:" "$LOG" | head >&2
    fail=1
fi

assert_marker() {
    if grep -a -q -E "$1" "$LOG"; then
        echo "[test_volume_gop] OK: $2"
    else
        echo "[test_volume_gop] MISS: $2 (expected marker: '$1')" >&2
        fail=1
    fi
}

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_volume_gop] OK: kernel banner present (EFI stub -> kernel)."
else
    echo "[test_volume_gop] MISS: kernel banner NOT present." >&2
    fail=1
fi

assert_marker 'EFI GOP framebuffer console ready' 'EFI GOP framebuffer came up the UEFI way (not multiboot/VBE)'
assert_marker 'DAEMON up screen=[0-9]+x[0-9]+'    'hamUId daemon up at the real GOP geometry'
assert_marker '\[volrt\] start'                   'volume round-trip self-test started'
assert_marker '\[volrt\] audio_live=1'            '/dev/audio status line answered (HDA mixer live)'
assert_marker '\[volrt\] vol_set_ok=1'            'applet vol_step round-tripped: kernel master pct == 30 on independent re-read'
assert_marker '\[volrt\] mute_ok=1'               'applet mute toggle latched the kernel mixer mute (status shows mute 1)'
assert_marker '\[volrt\] unmute_ok=1'             'second toggle unlatched mute with the stored level preserved'
assert_marker '\[volrt\] PASS'                    'the full volume round-trip self-test ran to completion'

if [ "$fail" -eq 0 ]; then
    echo "[test_volume_gop] capture method: builds the installer live image with the autostart volrt svc marker, boots it under a REAL EFI GOP framebuffer (OVMF/-vga std) with QEMU intel-hda attached; at runlevel 5 the supervisor autostarts hamUId in autoflag-52 volume self-test mode, which drives vol_step/vol_mute_toggle through /dev/audioctl and proves each change by independently re-reading the /dev/audio status line"
    echo "[test_volume_gop] PASS"
    [ "${VOLRT_KEEP_LOG:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_volume_gop] FAIL (serial log: $LOG)" >&2
    exit 1
fi
