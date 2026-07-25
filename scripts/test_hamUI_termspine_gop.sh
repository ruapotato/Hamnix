#!/usr/bin/env bash
# scripts/test_hamUI_termspine_gop.sh — AUTHORITATIVE GATE for Increment-2 of
# the MATE-mirror DE rewrite: the TERMINAL as a real compositor-spawned
# SEPARATE-PROCESS app on the same spine Increment-1 (hamecho) established,
# proven on a REAL EFI GOP framebuffer (OVMF/UEFI) via the installer LIVE
# image. This kills the historical "multi-second terminal-open lag" root-cause
# bug: opening a terminal no longer hand-draws an in-daemon grid (and no longer
# triggers a full-screen recomposite) — it spawns /bin/hamterm as its own
# process, allocates it a wid, and composites its hamui markup body live,
# damaging only its own window rect.
#
# WHY THE INSTALLER IMAGE / OVMF. Identical rationale to
# scripts/test_hamUI_appspine_gop.sh: on this host QEMU's multiboot1 + 64-bit
# ELF path provides no usable VBE framebuffer, so a `-vga std` multiboot
# self-test cannot bring the daemon up. The installer live image boots under
# OVMF/UEFI, brings up a REAL EFI GOP framebuffer, and reaches runlevel 5 where
# the supervisor autostarts hamUId. That makes it the authoritative
# render/spawn/input gate on this host.
#
# DETERMINISTIC PROOF — NO serial injection / NO typing. We build the installer
# image with ENABLE_TERM_SELFTEST=1, which makes build_initramfs.py plant
# /etc/hamui-term-test (and drop hamde.svc so hamUId autostarts
# deterministically). The PROVEN 2-token `hamUId daemon` autostart finds that
# marker and routes into autoflag 48 -> daemon_app_term_selftest, which runs
# inline right after it grabs /dev/fb, then exits cleanly.
#
# The self-test (user/hamUId.ad::daemon_app_term_selftest):
#   1. SPAWNS /bin/hamterm as its OWN process (daemon_spawn_terminal ->
#      sys_spawn + sys_wsys_alloc), giving it a real kernel wid + stdout pipe.
#   2. Damages ONLY the new window's rect + presents via the dirty-rect path,
#      asserting DMG_LAST_FULL==0 and the presented area == the window rect —
#      i.e. opening the terminal does NOT trigger a full-screen recomposite
#      (the historical terminal-open lag bug).
#   3. Composites and asserts hamterm's hamui "ui" markup auto-detected +
#      rasterised, its body composited on screen, the desktop backdrop still
#      showing OUTSIDE the window (windowed, not full-screen).
#   4. Routes the keystrokes for `echo TERMOK` + Enter to the FOCUSED window
#      via the focus-gated key path (evt_emit_key -> /dev/wsys/<wid>/keys).
#      hamterm's entry fires its activate signal on Enter, runs the line
#      through a REAL /bin/hamsh, captures its stdout into the textview,
#      renders it live, and emits "HAMTERM ran bytes=<N>" on its stdout pipe.
#      We drain that pipe and assert the marker — proof the focus-gated
#      command crossed into the SEPARATE process and produced real shell
#      output, and we re-sample the window body to confirm it rendered live.
#   5. Asserts the routed keystrokes did NOT appear on /dev/cons — proof they
#      went exclusively to the per-window stream and never to the shared
#      console the boot/serial shell reads (the compositor holds the exclusive
#      console-input grab — drivers/video/fb_cdev.ad "grab" verb).
#
# Markers asserted (emitted by daemon_app_term_selftest, prefix "[term]"):
#     [term] hamterm spawned as separate process with wid
#     [term] OK spawn damaged only its own window rect
#     [term] OK app body composited on screen (windowed)
#     [term] OK focus-gated command ran real /bin/hamsh in the app
#     [term] OK real shell output rendered live in the window
#     [term] OK routed command did NOT leak to the console shell
#     [term] PASS
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or mksquashfs is unavailable.
#
# Env overrides:
#   INSTALLER_IMG      installer image path (default: build/hamnix-installer.img)
#   HAMNIX_SKIP_BUILD  1 = reuse existing installer image (default: rebuild
#                        WITH the terminal svc marker)
#   OVMF_FD            OVMF firmware path   (default: auto-resolved)
#   BOOT_WAIT          boot+selftest wait   (default: 240)
#   TERM_KEEP_LOG      1 = keep serial log on success

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
KERNEL_BANNER="Hamnix kernel booting"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_term_gop] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
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
    echo "[test_term_gop] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_term_gop] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- build the installer image WITH the terminal svc marker -----------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_term_gop] building installer image with ENABLE_TERM_SELFTEST=1 (autostart terminal app-spine self-test)"
    ENABLE_TERM_SELFTEST=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[hamUI_termspine_gop]"
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_term_gop] SKIP: installer image $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-term.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-term.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-term.XXXXXX.log)
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
# autostarts hamUId, which finds the term marker and runs the proof.
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
echo "[test_term_gop] waiting up to ${BOOT_WAIT}s for the autostart terminal app-spine self-test..."
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E "\[term\] (PASS|FAIL|ABORT)" "$LOG"; then
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
echo "[test_term_gop] --- captured serial output (term markers) ---"
grep -a -E 'EFI GOP framebuffer console ready|DAEMON up screen=|DAEMON keyboard ownership|\[term\]|HAMTERM' "$LOG" | head -40
echo "[test_term_gop] --- end ---"

# --- assertions -------------------------------------------------------
fail=0

if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_term_gop] FAIL: kernel panic / trap" >&2
    grep -a -E "PANIC|panic:|TRAP:|BUG:" "$LOG" | head >&2
    fail=1
fi

assert_marker() {
    if grep -a -q -E "$1" "$LOG"; then
        echo "[test_term_gop] OK: $2"
    else
        echo "[test_term_gop] MISS: $2 (expected marker: '$1')" >&2
        fail=1
    fi
}

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_term_gop] OK: kernel banner present (EFI stub -> kernel)."
else
    echo "[test_term_gop] MISS: kernel banner NOT present." >&2
    fail=1
fi

assert_marker 'EFI GOP framebuffer console ready'             'EFI GOP framebuffer came up the UEFI way (not multiboot/VBE)'
assert_marker 'DAEMON up screen=[0-9]+x[0-9]+'                'hamUId daemon up at the real GOP geometry'
assert_marker 'DAEMON keyboard ownership grabbed'             'compositor took EXCLUSIVE physical keyboard ownership (real input grab)'
assert_marker '\[term\] hamterm spawned as separate process'  'the terminal runs as its OWN process with a compositor-allocated wid'
assert_marker '\[term\] OK spawn damaged only its own window'  'opening the terminal did NOT trigger a full-screen recomposite (lag bug)'
assert_marker '\[term\] OK app body composited on screen'     'the separate-process terminal pixels (hamui markup) are on the GOP frame'
assert_marker '\[term\] OK focus-gated command ran real'      'a focus-gated command crossed into the separate process + ran real hamsh'
assert_marker '\[term\] OK real shell output rendered live'   'the real /bin/hamsh output rendered live in the window body'
assert_marker '\[term\] OK routed command did NOT leak'       'the keystrokes did NOT leak to the /dev/cons boot/serial shell'
assert_marker '\[term\] PASS'                                 'the full Increment-2 terminal spine ran to completion'

if [ "$fail" -eq 0 ]; then
    echo "[test_term_gop] capture method: builds the installer live image with the autostart terminal app-spine svc marker, boots it under a REAL EFI GOP framebuffer (OVMF/-vga std); at runlevel 5 the supervisor autostarts hamUId in autoflag-48 terminal self-test mode, which spawns /bin/hamterm as its own process, asserts window-only spawn damage + on-screen markup via daemon_pixel, routes a focus-gated 'echo TERMOK' command into the child (which runs real /bin/hamsh, renders its output, and acks over its pipe), and asserts those keystrokes never reached /dev/cons"
    echo "[test_term_gop] PASS"
    [ "${TERM_KEEP_LOG:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_term_gop] FAIL (serial log: $LOG)" >&2
    exit 1
fi
