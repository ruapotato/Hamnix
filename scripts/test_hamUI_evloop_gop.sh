#!/usr/bin/env bash
# scripts/test_hamUI_evloop_gop.sh — AUTHORITATIVE GATE for the EVENT-DRIVEN
# compositor scheduling rewrite, proven on a REAL EFI GOP framebuffer
# (OVMF/UEFI) via the installer LIVE image.
#
# What changed (user/hamUId.ad): the daemon main loop no longer busy-polls
# (sys_yield each iteration) or re-rasterizes every markup-client body on a
# blind every-8-frames tick. It now:
#   * PARKS in SYS_WAITFDS(313) on its input fds (mouse, console, window
#     stdout pipes) with an adaptive timeout — idle CPU is the kernel
#     sleeping the task on the waitfds WaitQueue, not a yield spin;
#   * re-rasterizes a markup body ONLY when the kernel's pure per-layer
#     content generation counter (/dev/wsys/<N>/draw/<layer>/gen) says the
#     client actually repainted (gen-gated markup_sync);
#   * closes a dead child's EOF'd stdout pipe in term_pump so it can never
#     hot-spin the wait (EOF pipes are permanently "ready" to waitfds).
#
# WHY THE INSTALLER IMAGE / OVMF. Identical rationale to
# scripts/test_hamUI_termspine_gop.sh: on this host QEMU's multiboot1 +
# 64-bit ELF path provides no usable VBE framebuffer, so a `-vga std`
# multiboot self-test cannot bring the daemon up. The installer live image
# boots under OVMF/UEFI, brings up a REAL EFI GOP framebuffer, and reaches
# runlevel 5 where the supervisor autostarts hamUId.
#
# DETERMINISTIC PROOF — NO serial injection / NO typing. We build the
# installer image with ENABLE_EVLOOP_SELFTEST=1, which makes
# build_initramfs.py plant /etc/hamui-evloop-test (and drop hamde.svc so
# hamUId autostarts deterministically). The PROVEN 2-token `hamUId daemon`
# autostart finds that marker and routes into autoflag 51 ->
# daemon_evloop_selftest, which runs inline against the SAME
# daemon_frame()/evl_wait() code the live loop uses, then exits cleanly.
#
# Markers asserted (emitted by daemon_evloop_selftest, prefix "[evloop]"):
#     [evloop] park_ok=1            evl_wait really sleeps (jiffy-verified)
#     [evloop] detect_ok=1          gen-driven frames auto-detect + rasterize
#     [evloop] idle_norerender_ok=1 no gen change -> ZERO body re-rasterizes
#     [evloop] idle_nopresent_ok=1  ...and ZERO presents
#     [evloop] gen_rerender_ok=1    one repaint (gen bump) -> body re-read
#     [evloop] gen_bounded_ok=1     ...presenting only the window's rect
#     [evloop] gen_consumed_ok=1    ...and the gen edge is then consumed
#     [evloop] park_live_ok=1       EOF'd child pipe closed; wait still sleeps
#     [evloop] cursor_cheap_ok=1    cursor move: no body read, no present
#     [evloop] PASS
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or mksquashfs is unavailable.
#
# Env overrides:
#   INSTALLER_IMG      installer image path (default: build/hamnix-installer.img)
#   HAMNIX_SKIP_BUILD  1 = reuse existing installer image (default: rebuild
#                        WITH the evloop svc marker)
#   OVMF_FD            OVMF firmware path   (default: auto-resolved)
#   BOOT_WAIT          boot+selftest wait   (default: 240)
#   EVLOOP_KEEP_LOG    1 = keep serial log on success

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
KERNEL_BANNER="Hamnix kernel booting"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_evloop_gop] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
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
    echo "[test_evloop_gop] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_evloop_gop] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- build the installer image WITH the evloop svc marker --------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_evloop_gop] building installer image with ENABLE_EVLOOP_SELFTEST=1 (autostart event-loop self-test)"
    ENABLE_EVLOOP_SELFTEST=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[hamUI_evloop_gop]"
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_evloop_gop] SKIP: installer image $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-evloop.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-evloop.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-evloop.XXXXXX.log)
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
# autostarts hamUId, which finds the evloop marker and runs the proof.
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

# --- wait for the self-test's verdict (or boot failure) ----------------
echo "[test_evloop_gop] waiting up to ${BOOT_WAIT}s for the autostart event-loop self-test..."
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E "\[evloop\] (PASS|FAIL)" "$LOG"; then
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
echo "[test_evloop_gop] --- captured serial output (evloop markers) ---"
grep -a -E 'EFI GOP framebuffer console ready|DAEMON up screen=|\[evloop\]' "$LOG" | head -40
echo "[test_evloop_gop] --- end ---"

# --- assertions -------------------------------------------------------
fail=0

if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_evloop_gop] FAIL: kernel panic / trap" >&2
    grep -a -E "PANIC|panic:|TRAP:|BUG:" "$LOG" | head >&2
    fail=1
fi

assert_marker() {
    if grep -a -q -E "$1" "$LOG"; then
        echo "[test_evloop_gop] OK: $2"
    else
        echo "[test_evloop_gop] MISS: $2 (expected marker: '$1')" >&2
        fail=1
    fi
}

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_evloop_gop] OK: kernel banner present (EFI stub -> kernel)."
else
    echo "[test_evloop_gop] MISS: kernel banner NOT present." >&2
    fail=1
fi

assert_marker 'EFI GOP framebuffer console ready'    'EFI GOP framebuffer came up the UEFI way (not multiboot/VBE)'
assert_marker 'DAEMON up screen=[0-9]+x[0-9]+'       'hamUId daemon up at the real GOP geometry'
assert_marker '\[evloop\] start'                     'event-loop self-test started'
assert_marker '\[evloop\] park_ok=1'                 'evl_wait really SLEEPS in sys_waitfds (jiffy-verified, no yield spin)'
assert_marker '\[evloop\] detect_ok=1'               'gen-driven frames auto-detect a markup client + rasterize its body'
assert_marker '\[evloop\] idle_norerender_ok=1'      'no gen change -> ZERO markup body re-rasterizes across idle frames'
assert_marker '\[evloop\] idle_nopresent_ok=1'       'no change at all -> ZERO presents across idle frames'
assert_marker '\[evloop\] gen_rerender_ok=1'         'one client repaint (per-layer gen bump) -> body re-read within bound'
assert_marker '\[evloop\] gen_bounded_ok=1'          'the gen-triggered present is bounded by the window rect (no full present)'
assert_marker '\[evloop\] gen_consumed_ok=1'         'the gen edge is consumed (counters stable afterwards)'
assert_marker '\[evloop\] park_live_ok=1'            'dead child EOF pipe closed by term_pump; wait still really sleeps'
assert_marker '\[evloop\] cursor_cheap_ok=1'         'a pure cursor move neither re-rasterizes nor flushes a present'
assert_marker '\[evloop\] PASS'                      'the full event-loop self-test ran to completion'

if [ "$fail" -eq 0 ]; then
    echo "[test_evloop_gop] capture method: builds the installer live image with the autostart evloop svc marker, boots it under a REAL EFI GOP framebuffer (OVMF/-vga std); at runlevel 5 the supervisor autostarts hamUId in autoflag-51 event-loop self-test mode, which parks in sys_waitfds (jiffy-verified), injects a hamui markup client, and proves body re-rasterizes happen ONLY on per-layer gen changes with window-rect-bounded presents"
    echo "[test_evloop_gop] PASS"
    [ "${EVLOOP_KEEP_LOG:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_evloop_gop] FAIL (serial log: $LOG)" >&2
    exit 1
fi
