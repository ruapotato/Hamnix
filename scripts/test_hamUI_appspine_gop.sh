#!/usr/bin/env bash
# scripts/test_hamUI_appspine_gop.sh — AUTHORITATIVE GATE for Increment-1 of
# the MATE-mirror DE rewrite: the FIRST desktop app running as its OWN
# process, spawned by the compositor, with focus-gated keyboard input routed
# to it via the per-window event files — proven on a REAL EFI GOP framebuffer
# (OVMF/UEFI) via the installer LIVE image.
#
# WHY THE INSTALLER IMAGE / OVMF. Identical rationale to
# scripts/test_hamUI_markupclient_gop.sh: on this host QEMU's multiboot1 +
# 64-bit ELF path provides no usable VBE framebuffer, so a `-vga std`
# multiboot self-test cannot bring the daemon up. The installer live image
# boots under OVMF/UEFI, brings up a REAL EFI GOP framebuffer, and reaches
# runlevel 5 where the supervisor autostarts hamUId. That makes it the
# authoritative render/spawn/input gate on this host.
#
# DETERMINISTIC PROOF — NO serial injection / NO typing. We build the
# installer image with ENABLE_SPINE_SELFTEST=1, which makes build_initramfs.py
# plant /etc/hamui-spine-test (and drop hamde.svc so hamUId autostarts
# deterministically). The PROVEN 2-token `hamUId daemon` autostart finds that
# marker and routes into autoflag 47 -> daemon_app_spine_selftest, which runs
# inline right after it grabs /dev/fb, then exits cleanly.
#
# The self-test (user/hamUId.ad::daemon_app_spine_selftest):
#   1. SPAWNS /bin/hamecho as its OWN process (sys_spawn + sys_wsys_alloc),
#      giving it a real kernel wid and a stdout pipe the compositor owns.
#   2. Damages ONLY the new window's rect + presents via the dirty-rect path,
#      asserting DMG_LAST_FULL==0 and the presented area == the window rect —
#      i.e. opening the app does NOT trigger a full-screen recomposite (the
#      historical terminal-open lag bug).
#   3. Composites and asserts hamecho's hamui "ui" markup auto-detected +
#      rasterised, its body composited on screen, and the desktop backdrop
#      still showing OUTSIDE the window (windowed, not full-screen).
#   4. Routes key code 'A' (65) to the FOCUSED window via the focus-gated
#      key path (evt_emit_key -> /dev/wsys/<wid>/keys) and asserts hamecho
#      ECHOed it back ("ECHO 65") on its stdout pipe — proof the routed key
#      crossed into the SEPARATE process.
#   5. Asserts the routed key did NOT appear on /dev/cons — proof it went
#      exclusively to the per-window stream and never to the shared console
#      the boot/serial shell reads (the compositor holds the exclusive
#      console-input grab — drivers/video/fb_cdev.ad "grab" verb).
#
# Markers asserted (emitted by daemon_app_spine_selftest, prefix "[spine]"):
#     [spine] hamecho spawned as separate process with wid
#     [spine] OK spawn damaged only its own window rect
#     [spine] OK app body composited on screen (windowed)
#     [spine] OK routed key reached the separate process
#     [spine] OK routed key did NOT leak to the console shell
#     [spine] PASS
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or mksquashfs is unavailable.
#
# Env overrides:
#   INSTALLER_IMG      installer image path (default: build/hamnix-installer.img)
#   HAMNIX_SKIP_BUILD  1 = reuse existing installer image (default: rebuild
#                        WITH the spine svc marker)
#   OVMF_FD            OVMF firmware path   (default: auto-resolved)
#   BOOT_WAIT          boot+selftest wait   (default: 240)
#   SPINE_KEEP_LOG     1 = keep serial log on success

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
KERNEL_BANNER="Hamnix kernel booting"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_spine_gop] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
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
    echo "[test_spine_gop] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_spine_gop] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- build the installer image WITH the spine svc marker --------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_spine_gop] building installer image with ENABLE_SPINE_SELFTEST=1 (autostart app-spine self-test)"
    ENABLE_SPINE_SELFTEST=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[hamUI_appspine_gop]"
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_spine_gop] SKIP: installer image $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-spine.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-spine.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-spine.XXXXXX.log)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$MEDIA_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$MEDIA_RW"
}
trap cleanup EXIT

# -vga std under OVMF gives a real EFI GOP framebuffer. The installer
# medium is attached as virtio-blk; NO NVMe target is attached, so the
# system boots its in-RAM cpio to runlevel 5, where the supervisor
# autostarts hamUId, which finds the spine marker and runs the proof.
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
echo "[test_spine_gop] waiting up to ${BOOT_WAIT}s for the autostart app-spine self-test..."
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E "\[spine\] (PASS|FAIL|ABORT)" "$LOG"; then
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
echo "[test_spine_gop] --- captured serial output (spine markers) ---"
grep -a -E 'EFI GOP framebuffer console ready|DAEMON up screen=|DAEMON keyboard ownership|\[spine\]' "$LOG" | head -40
echo "[test_spine_gop] --- end ---"

# --- assertions -------------------------------------------------------
fail=0

if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_spine_gop] FAIL: kernel panic / trap" >&2
    grep -a -E "PANIC|panic:|TRAP:|BUG:" "$LOG" | head >&2
    fail=1
fi

assert_marker() {
    if grep -a -q -E "$1" "$LOG"; then
        echo "[test_spine_gop] OK: $2"
    else
        echo "[test_spine_gop] MISS: $2 (expected marker: '$1')" >&2
        fail=1
    fi
}

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_spine_gop] OK: kernel banner present (EFI stub -> kernel)."
else
    echo "[test_spine_gop] MISS: kernel banner NOT present." >&2
    fail=1
fi

assert_marker 'EFI GOP framebuffer console ready'             'EFI GOP framebuffer came up the UEFI way (not multiboot/VBE)'
assert_marker 'DAEMON up screen=[0-9]+x[0-9]+'                'hamUId daemon up at the real GOP geometry'
assert_marker 'DAEMON keyboard ownership grabbed'             'compositor took EXCLUSIVE physical keyboard ownership (real input grab)'
assert_marker '\[spine\] hamecho spawned as separate process' 'the app runs as its OWN process with a compositor-allocated wid'
assert_marker '\[spine\] OK spawn damaged only its own window' 'opening the app did NOT trigger a full-screen recomposite (lag bug)'
assert_marker '\[spine\] OK app body composited on screen'    'the separate-process app pixels (hamui markup) are on the GOP frame'
assert_marker '\[spine\] OK routed key reached the separate'  'a focus-gated keystroke crossed into the separate process'
assert_marker '\[spine\] OK routed key did NOT leak'          'the keystroke did NOT leak to the /dev/cons boot/serial shell'
assert_marker '\[spine\] PASS'                                'the full Increment-1 spine ran to completion'

if [ "$fail" -eq 0 ]; then
    echo "[test_spine_gop] capture method: builds the installer live image with the autostart app-spine svc marker, boots it under a REAL EFI GOP framebuffer (OVMF/-vga std); at runlevel 5 the supervisor autostarts hamUId in autoflag-47 spine self-test mode, which spawns /bin/hamecho as its own process, asserts window-only spawn damage + on-screen markup via daemon_pixel, routes a focus-gated keystroke into the child (echoed back over its pipe), and asserts that keystroke never reached /dev/cons"
    echo "[test_spine_gop] PASS"
    [ "${SPINE_KEEP_LOG:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_spine_gop] FAIL (serial log: $LOG)" >&2
    exit 1
fi
