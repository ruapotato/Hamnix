#!/usr/bin/env bash
# scripts/test_hamUI_markupclient_gop.sh — AUTHORITATIVE GATE for the
# keystone "live compositor renders external hamui clients' ui markup"
# feature, on a REAL EFI GOP framebuffer (OVMF/UEFI), via the installer
# LIVE image.
#
# WHY THE INSTALLER IMAGE. scripts/test_hamUI_markupclient.sh runs the SAME
# autoflag-46 self-test, but boots the cpio kernel under `-vga std`
# multiboot. On this host QEMU's multiboot1 + 64-bit ELF path provides no
# usable VBE framebuffer, so the hamUId daemon never comes up there and the
# multiboot self-test SKIPs (see memory: project_qemu_multiboot_vbe_limit).
#
# The installer live image (build/hamnix-installer.img) boots under
# OVMF/UEFI and brings up a REAL EFI GOP framebuffer; its in-RAM cpio reaches
# runlevel 5, where the supervisor autostarts etc/services.d/hamuid.svc and
# the hamUId daemon comes up at the real GOP geometry ("DAEMON up
# screen=WxH"). That makes it the authoritative render gate on this host —
# no golden installed disk required.
#
# DETERMINISTIC PROOF — NO serial injection / NO typing. We build the
# installer image with ENABLE_MKC_SELFTEST=1, which makes build_initramfs.py
# OVERRIDE the cpio's etc/services.d/hamuid.svc exec line to
# `hamUId daemon markupclient` (restart: never). So the AUTOSTARTED daemon
# itself runs autoflag 46 -> daemon_markup_client_selftest inline right
# after it grabs /dev/fb, then exits cleanly. This sidesteps the
# console-takeover race that made a serial-injected
# `hamUId daemon markupclient` unreliable (the autostart daemon owns the
# console, so fed serial bytes never reach a shell). Just boot and capture
# the daemon's "[markup-client]" markers.
#
# The self-test:
#   1. opens /dev/fb, reads the real GOP geometry ("DAEMON up screen=WxH").
#   2. spawns a chrome window with a real kernel wid, injects a hamui-style
#      "ui" markup layer (outer #22cc44 fill + 40x30 inner #cc2244 rect +
#      "HAMUI" text) exactly the way lib/hamui.ad's hamui_render does, runs
#      the LIVE daemon_present() path, then SAMPLES the composited screen
#      (the exact bytes daemon_pixel writes to /dev/fb) and asserts the
#      markup colours land at the on-screen window-body coords while the
#      backdrop shows OUTSIDE the window.
# Honest: every assertion reads the composited frame through daemon_pixel,
# so a procedural body or a stub cannot forge it. The markup round-trips
# through the real kernel wsys draw-surface cdev and the live present path,
# under a REAL EFI GOP framebuffer.
#
# Markers asserted (emitted by daemon_markup_client_selftest):
#     [markup-client] ui markup injected
#     [markup-client] client auto-detected + flagged
#     [markup-client] OK outer rect on screen
#     [markup-client] OK inner rect on screen
#     [markup-client] OK windowed (backdrop outside window)
#     [markup-client] PASS
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or mksquashfs is unavailable
# (mirrors test_installer_nvme_inram.sh).
#
# Env overrides:
#   INSTALLER_IMG      installer image path (default: build/hamnix-installer.img)
#   HAMNIX_SKIP_BUILD  1 = reuse existing installer image (default: rebuild
#                        WITH the markupclient svc-override)
#   OVMF_FD            OVMF firmware path   (default: auto-resolved)
#   BOOT_WAIT          boot+selftest wait   (default: 240)
#   MKC_KEEP_LOG       1 = keep serial log on success

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
KERNEL_BANNER="Hamnix kernel booting"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_mkc_gop] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
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
    echo "[test_mkc_gop] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_mkc_gop] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- build the installer image WITH the markupclient svc-override -----
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_mkc_gop] building installer image with ENABLE_MKC_SELFTEST=1 (autostart markupclient self-test)"
    ENABLE_MKC_SELFTEST=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[hamUI_markupclient_gop]"
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_mkc_gop] SKIP: installer image $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-mkc.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-mkc.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-mkc.XXXXXX.log)
cp "$OVMF_FD" "$OVMF_RW"
# Fresh writable COPY of the installer medium (never boot the master).
cp "$INSTALLER_IMG" "$MEDIA_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$MEDIA_RW"
}
trap cleanup EXIT

# -vga std under OVMF gives a real EFI GOP framebuffer. The installer
# medium is attached as virtio-blk; NO NVMe target is attached, so the
# system boots its in-RAM cpio to runlevel 5 (interactive), where the
# supervisor autostarts hamuid.svc in markupclient self-test mode. No
# serial input is fed — the daemon runs the proof itself.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$MEDIA_RW",format=raw,if=none,id=media \
    -device virtio-blk-pci,drive=media,bootindex=0 \
    -m 1280M \
    -vga std -display none -no-reboot -monitor none \
    -serial stdio \
    < /dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for the self-test's terminal marker (or boot failure) -------
echo "[test_mkc_gop] waiting up to ${BOOT_WAIT}s for the autostart markup-client self-test..."
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E "\[markup-client\] (PASS|FAIL|ABORT)" "$LOG"; then
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
echo "[test_mkc_gop] --- captured serial output (markup-client markers) ---"
grep -a -E 'EFI GOP framebuffer console ready|DAEMON up screen=|\[markup-client\]' "$LOG" | head -40
echo "[test_mkc_gop] --- end ---"

# --- assertions -------------------------------------------------------
fail=0

# A kernel panic / CPU trap is ALWAYS a hard failure — check first.
if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_mkc_gop] FAIL: kernel panic / trap" >&2
    grep -a -E "PANIC|panic:|TRAP:|BUG:" "$LOG" | head >&2
    fail=1
fi

assert_marker() {
    if grep -a -q -E "$1" "$LOG"; then
        echo "[test_mkc_gop] OK: $2"
    else
        echo "[test_mkc_gop] MISS: $2 (expected marker: '$1')" >&2
        fail=1
    fi
}

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_mkc_gop] OK: kernel banner present (EFI stub -> kernel)."
else
    echo "[test_mkc_gop] MISS: kernel banner NOT present." >&2
    fail=1
fi

assert_marker 'EFI GOP framebuffer console ready'           'EFI GOP framebuffer came up the UEFI way (not multiboot/VBE)'
assert_marker 'DAEMON up screen=[0-9]+x[0-9]+'              'hamUId daemon up at the real GOP geometry'
assert_marker '\[markup-client\] ui markup injected'        'hamui-style ui markup layer injected onto the wid'
assert_marker '\[markup-client\] client auto-detected'      'live present auto-detected the ui markup client'
assert_marker '\[markup-client\] OK outer rect on screen'   'markup outer-fill colour composited into the live body'
assert_marker '\[markup-client\] OK inner rect on screen'   'markup inner-rect colour composited into the live body'
assert_marker '\[markup-client\] OK windowed'               'backdrop shows outside the window (windowed, not full-screen)'
assert_marker '\[markup-client\] PASS'                      'self-test ran to completion (markup client is on screen)'

if [ "$fail" -eq 0 ]; then
    echo "[test_mkc_gop] capture method: builds the installer live image with the autostart markupclient svc-override, boots it under a REAL EFI GOP framebuffer (OVMF/-vga std); at runlevel 5 the supervisor autostarts hamUId in autoflag-46 self-test mode, which injects a real hamui ui markup layer, runs the LIVE daemon_present path, and asserts composited-pixel colours at the window body via daemon_pixel"
    echo "[test_mkc_gop] PASS"
    [ "${MKC_KEEP_LOG:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_mkc_gop] FAIL (serial log: $LOG)" >&2
    exit 1
fi
