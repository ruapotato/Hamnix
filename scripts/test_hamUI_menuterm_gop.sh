#!/usr/bin/env bash
# scripts/test_hamUI_menuterm_gop.sh — AUTHORITATIVE GATE for Increment-3a of
# the MATE-mirror DE rewrite: the Applications-menu (and panel/desktop)
# "Terminal" LAUNCHER is wired to the SEPARATE-PROCESS hamterm path, NOT the
# old dormant in-daemon APP_TERM hand-drawn grid. Proven on a REAL EFI GOP
# framebuffer (OVMF/UEFI) via the installer LIVE image.
#
# Increment-2 (scripts/test_hamUI_termspine_gop.sh) proved daemon_spawn_terminal()
# spawns /bin/hamterm as a separate process. THIS gate proves the user-facing
# MENU entry actually reaches that path: it drives the exact dispatch the menu
# uses — menu_launch(0, ...), where flat index 0 is "Terminal" — and asserts the
# resulting window is a separate-process hamterm (compositor-allocated wid >= 2,
# a child stdout pipe, hamui markup auto-detected), and explicitly NOT an
# in-daemon APP_TERM grid (DWIN_APP != APP_TERM). A regression that reverts the
# menu wiring back to daemon_spawn_app(APP_TERM) FAILS this gate.
#
# WHY THE INSTALLER IMAGE / OVMF. Identical rationale to the termspine gate: on
# this host QEMU's multiboot1 + 64-bit ELF path provides no usable VBE
# framebuffer, so a `-vga std` multiboot self-test cannot bring the daemon up.
# The installer live image boots under OVMF/UEFI, brings up a REAL EFI GOP
# framebuffer, and reaches runlevel 5 where the supervisor autostarts hamUId.
#
# DETERMINISTIC PROOF — NO serial injection / NO typing. We build the installer
# image with ENABLE_MENUTERM_SELFTEST=1, which makes build_initramfs.py plant
# /etc/hamui-menuterm-test (and drop hamde.svc so hamUId autostarts
# deterministically). The PROVEN 2-token `hamUId daemon` autostart finds that
# marker and routes into autoflag 49 -> daemon_menu_term_selftest, which runs
# inline right after it grabs /dev/fb, then exits cleanly.
#
# Markers asserted (emitted by daemon_menu_term_selftest, prefix "[menuterm]"):
#     [menuterm] menu Terminal spawned /bin/hamterm as a separate process with wid
#     [menuterm] OK menu Terminal damaged only its own window rect
#     [menuterm] OK hamui markup auto-detected + body rasterised
#     [menuterm] OK menu Terminal body composited on screen (windowed)
#     [menuterm] PASS
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or mksquashfs is unavailable.
#
# Env overrides:
#   INSTALLER_IMG      installer image path (default: build/hamnix-installer.img)
#   HAMNIX_SKIP_BUILD  1 = reuse existing installer image (default: rebuild
#                        WITH the menu-terminal svc marker)
#   OVMF_FD            OVMF firmware path   (default: auto-resolved)
#   BOOT_WAIT          boot+selftest wait   (default: 240)
#   MENUTERM_KEEP_LOG  1 = keep serial log on success

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
KERNEL_BANNER="Hamnix kernel booting"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_menuterm_gop] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
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
    echo "[test_menuterm_gop] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_menuterm_gop] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- build the installer image WITH the menu-terminal svc marker ------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_menuterm_gop] building installer image with ENABLE_MENUTERM_SELFTEST=1 (autostart menu-Terminal self-test)"
    ENABLE_MENUTERM_SELFTEST=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[hamUI_menuterm_gop]"
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_menuterm_gop] SKIP: installer image $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-menuterm.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-menuterm.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-menuterm.XXXXXX.log)
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
# autostarts hamUId, which finds the menuterm marker and runs the proof.
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

# --- wait for the self-test's marker (or boot failure) ----------------
echo "[test_menuterm_gop] waiting up to ${BOOT_WAIT}s for the autostart menu-Terminal self-test..."
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E "\[menuterm\] (PASS|FAIL|ABORT)" "$LOG"; then
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
echo "[test_menuterm_gop] --- captured serial output (menuterm markers) ---"
grep -a -E 'EFI GOP framebuffer console ready|DAEMON up screen=|DAEMON keyboard ownership|\[menuterm\]|HAMTERM' "$LOG" | head -40
echo "[test_menuterm_gop] --- end ---"

# --- assertions -------------------------------------------------------
fail=0

if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_menuterm_gop] FAIL: kernel panic / trap" >&2
    grep -a -E "PANIC|panic:|TRAP:|BUG:" "$LOG" | head >&2
    fail=1
fi

assert_marker() {
    if grep -a -q -E "$1" "$LOG"; then
        echo "[test_menuterm_gop] OK: $2"
    else
        echo "[test_menuterm_gop] MISS: $2 (expected marker: '$1')" >&2
        fail=1
    fi
}

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_menuterm_gop] OK: kernel banner present (EFI stub -> kernel)."
else
    echo "[test_menuterm_gop] MISS: kernel banner NOT present." >&2
    fail=1
fi

assert_marker 'EFI GOP framebuffer console ready'                  'EFI GOP framebuffer came up the UEFI way (not multiboot/VBE)'
assert_marker 'DAEMON up screen=[0-9]+x[0-9]+'                     'hamUId daemon up at the real GOP geometry'
assert_marker 'DAEMON keyboard ownership grabbed'                  'compositor took EXCLUSIVE physical keyboard ownership (real input grab)'
assert_marker '\[menuterm\] menu Terminal spawned /bin/hamterm as a separate process' 'the MENU Terminal entry spawns hamterm as its OWN process with a wid (not the APP_TERM grid)'
assert_marker '\[menuterm\] OK menu Terminal damaged only its own window' 'opening the menu Terminal did NOT trigger a full-screen recomposite (lag bug)'
assert_marker '\[menuterm\] OK hamui markup auto-detected'         'the separate-process terminal hamui markup was auto-detected + rasterised'
assert_marker '\[menuterm\] OK menu Terminal body composited on screen' 'the separate-process terminal pixels are on the GOP frame (windowed)'
assert_marker '\[menuterm\] PASS'                                  'the full Increment-3a menu-Terminal spine ran to completion'

# A regression that re-wired the menu to the dormant grid would emit this:
if grep -a -q -E '\[menuterm\] FAIL .*APP_TERM grid' "$LOG"; then
    echo "[test_menuterm_gop] FAIL: menu Terminal opened the in-daemon APP_TERM grid (regression)" >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_menuterm_gop] capture method: builds the installer live image with the autostart menu-Terminal svc marker, boots it under a REAL EFI GOP framebuffer (OVMF/-vga std); at runlevel 5 the supervisor autostarts hamUId in autoflag-49 menu-Terminal self-test mode, which drives menu_launch(0) (the Applications-menu Terminal entry) and asserts the resulting window is a separate-process /bin/hamterm (wid + stdout pipe + auto-detected hamui markup composited on the GOP frame), NOT the dormant in-daemon APP_TERM grid"
    echo "[test_menuterm_gop] PASS"
    [ "${MENUTERM_KEEP_LOG:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_menuterm_gop] FAIL (serial log: $LOG)" >&2
    exit 1
fi
