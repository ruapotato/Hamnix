#!/usr/bin/env bash
# scripts/test_hamUI_mouse_gop.sh — AUTHORITATIVE GATE for LIVE pointer
# delivery into the hamUId compositor: injected pointer motion must actually
# move CUR_X/CUR_Y. Proven on a REAL EFI GOP framebuffer (OVMF/UEFI) via the
# installer LIVE image, with REAL headless injection over QMP.
#
# WHAT THIS PROVES (the gap every prior mouse test left open):
#   - scripts/test_mouse.sh proves the PS/2 auxmouse INIT + synthetic decoder
#     only — it explicitly documents that live packet delivery was never
#     driven (no monitor socket in the -nographic suite).
#   - The user-visible bug was "the mouse doesn't move at all, even in the
#     VM": the standard QEMU/Boxes pointer is `usb-tablet` (HID subclass 0,
#     protocol 0, ABSOLUTE coordinates). The xhci driver only enumerated
#     boot-protocol keyboards/mice, so the tablet never came up — and with a
#     tablet present QEMU routes all host pointer motion to it, starving the
#     PS/2 mouse. Result: /dev/mouse never fed, cursor frozen at centre.
#
# THIS gate boots the installer image under OVMF with BOTH pointer flavours
# attached (`-device qemu-xhci -device usb-tablet` plus the machine's builtin
# PS/2 mouse) and injects motion headlessly through QMP input-send-event:
#   - "rel" dx/dy events  -> QEMU routes to the PS/2 mouse -> IRQ12 ->
#     auxmouse -> relative /dev/mouse lines  -> CUR_X += dx.
#   - "abs" x/y events    -> QEMU routes to the usb-tablet -> xHCI
#     interrupt-IN -> hid_tablet_report -> absolute "<x> <y> <b> <dz> 1"
#     lines -> CUR_X = x*scr_w/32768.
#
# DETERMINISTIC PROOF — the image is built with ENABLE_MOUSETEST_SELFTEST=1,
# which plants /etc/hamui-mouse-test (and drops hamde.svc); the PROVEN
# 2-token `hamUId daemon` autostart finds the marker and routes into
# autoflag 50 -> daemon_mouse_selftest, which prints:
#     [mousetest] READY for pointer injection
#     [mousetest] CUR moved CUR_X=... CUR_Y=...
#     [mousetest] REL motion observed
#     [mousetest] ABS motion observed
#     [mousetest] PASS
# We grep the serial LOG for these markers — wrapper exit codes are never
# trusted.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or mksquashfs is unavailable.
#
# Env overrides:
#   INSTALLER_IMG      installer image path (default: build/hamnix-installer.img)
#   HAMNIX_SKIP_BUILD  1 = reuse existing installer image (default: rebuild
#                        WITH the mousetest svc marker)
#   OVMF_FD            OVMF firmware path   (default: auto-resolved)
#   BOOT_WAIT          boot wait for READY  (default: 240)
#   INJECT_WAIT        post-READY wait for PASS/FAIL (default: 90)
#   MOUSETEST_KEEP_LOG 1 = keep serial log on success

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
INJECT_WAIT="${INJECT_WAIT:-90}"
KERNEL_BANNER="Hamnix kernel booting"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_mouse_gop] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
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
    echo "[test_mouse_gop] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_mouse_gop] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- build the installer image WITH the mousetest svc marker ----------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_mouse_gop] building installer image with ENABLE_MOUSETEST_SELFTEST=1 (autostart live-mouse self-test)"
    ENABLE_MOUSETEST_SELFTEST=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[hamUI_mouse_gop]"
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_mouse_gop] SKIP: installer image $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-mousetest.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-mousetest.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-mousetest.XXXXXX.log)
QMP_SOCK=$(mktemp --tmpdir -u hamnix-mousetest.qmp.XXXXXX.sock)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$MEDIA_RW"

cleanup() {
    [ -n "${INJ_PID:-}" ] && kill "$INJ_PID" 2>/dev/null
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$MEDIA_RW" "$QMP_SOCK"
}
trap cleanup EXIT

# -vga std under OVMF gives a real EFI GOP framebuffer. The installer
# medium is virtio-blk; no NVMe target, so the system boots its in-RAM
# cpio to runlevel 5 where the supervisor autostarts hamUId, which finds
# the mousetest marker and runs the autoflag-50 proof. qemu-xhci +
# usb-tablet attach the standard VM absolute pointer (the device GNOME
# Boxes/libvirt provide); the i440fx machine's PS/2 mouse covers the
# relative path. The QMP socket is the headless injection channel.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$MEDIA_RW",format=raw,if=none,id=media \
    -device virtio-blk-pci,drive=media,bootindex=0 \
    -device qemu-xhci -device usb-tablet \
    -m 1280M \
    -vga std -display none -no-reboot -monitor none \
    -qmp unix:"$QMP_SOCK",server,nowait \
    -serial stdio \
    < /dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for the daemon's READY banner -------------------------------
echo "[test_mouse_gop] waiting up to ${BOOT_WAIT}s for '[mousetest] READY'..."
ready=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "\[mousetest\] READY for pointer injection" "$LOG"; then
        ready=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    echo "[test_mouse_gop] FAIL: '[mousetest] READY' never appeared (boot/autostart problem)" >&2
    echo "[test_mouse_gop] --- last serial lines ---" >&2
    tail -n 40 "$LOG" >&2
    echo "[test_mouse_gop] FAIL (serial log: $LOG)" >&2
    exit 1
fi
echo "[test_mouse_gop] READY observed — injecting pointer motion over QMP."

# --- QMP injector: alternate REL (PS/2) and ABS (usb-tablet) motion ----
# Re-injects every ~1.5s until killed; each round sends a relative step
# (routed to the PS/2 mouse) and an absolute position that alternates
# between two screen quadrants (routed to the usb-tablet), so the cursor
# provably MOVES on every round regardless of which path lands first.
python3 - "$QMP_SOCK" <<'PYEOF' &
import json, socket, sys, time

sock_path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
deadline = time.time() + 30
while True:
    try:
        s.connect(sock_path)
        break
    except OSError:
        if time.time() > deadline:
            sys.exit(1)
        time.sleep(0.5)
f = s.makefile("rw")

def cmd(obj):
    f.write(json.dumps(obj) + "\n")
    f.flush()
    while True:
        line = f.readline()
        if not line:
            sys.exit(0)
        msg = json.loads(line)
        if "return" in msg or "error" in msg:
            return msg

f.readline()                       # QMP greeting
cmd({"execute": "qmp_capabilities"})

flip = 0
for _ in range(120):               # ~3 min of injection, harness kills us early
    # Relative motion -> PS/2 mouse (tablet rejects rel events).
    cmd({"execute": "input-send-event", "arguments": {"events": [
        {"type": "rel", "data": {"axis": "x", "value": 25}},
        {"type": "rel", "data": {"axis": "y", "value": 17}}]}})
    time.sleep(0.3)
    # Absolute position -> usb-tablet (0..32767 device range), alternating
    # quadrants so consecutive rounds always change the coordinate.
    ax = 8000 if flip == 0 else 24000
    ay = 6000 if flip == 0 else 20000
    flip ^= 1
    cmd({"execute": "input-send-event", "arguments": {"events": [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}}]}})
    time.sleep(1.2)
PYEOF
INJ_PID=$!

# --- wait for PASS/FAIL ------------------------------------------------
for _ in $(seq 1 "$INJECT_WAIT"); do
    if grep -a -q -E "\[mousetest\] (PASS|FAIL)" "$LOG"; then
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

sleep 1
kill "$INJ_PID" 2>/dev/null
wait "$INJ_PID" 2>/dev/null
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

# --- captured markers ---------------------------------------------------
echo "[test_mouse_gop] --- captured serial output (mousetest/xhci/auxmouse markers) ---"
grep -a -E 'EFI GOP framebuffer console ready|DAEMON up screen=|\[mousetest\]|USB tablet enabled|USB mouse enabled|auxmouse: streaming enabled' "$LOG" | head -40
echo "[test_mouse_gop] --- end ---"

# --- assertions (grep the LOG; never trust wrapper exit codes) ----------
fail=0

if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_mouse_gop] FAIL: kernel panic / trap" >&2
    grep -a -E "PANIC|panic:|TRAP:|BUG:" "$LOG" | head >&2
    fail=1
fi

assert_marker() {
    if grep -a -q -E "$1" "$LOG"; then
        echo "[test_mouse_gop] OK: $2"
    else
        echo "[test_mouse_gop] MISS: $2 (expected marker: '$1')" >&2
        fail=1
    fi
}

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_mouse_gop] OK: kernel banner present (EFI stub -> kernel)."
else
    echo "[test_mouse_gop] MISS: kernel banner NOT present." >&2
    fail=1
fi

assert_marker 'EFI GOP framebuffer console ready'        'EFI GOP framebuffer came up the UEFI way'
assert_marker 'DAEMON up screen=[0-9]+x[0-9]+'           'hamUId daemon up at the real GOP geometry'
assert_marker 'USB tablet enabled'                       'xhci enumerated the usb-tablet (absolute pointer)'
assert_marker '\[mousetest\] READY for pointer injection' 'autoflag-50 live-mouse self-test reached READY'
assert_marker '\[mousetest\] CUR moved CUR_X='           'injected motion MOVED the compositor cursor'
assert_marker '\[mousetest\] REL motion observed'        'PS/2 relative path delivered live packets (IRQ12 -> /dev/mouse -> CUR)'
assert_marker '\[mousetest\] ABS motion observed'        'usb-tablet absolute path delivered live packets (xHCI -> /dev/mouse -> CUR)'
assert_marker '\[mousetest\] PASS'                       'BOTH pointer paths moved the cursor end to end'

if grep -a -q "\[mousetest\] FAIL" "$LOG"; then
    echo "[test_mouse_gop] FAIL: self-test reported a timeout FAIL line" >&2
    grep -a "\[mousetest\] FAIL" "$LOG" >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_mouse_gop] capture method: builds the installer live image with the autostart mousetest svc marker, boots it under a REAL EFI GOP framebuffer (OVMF/-vga std) with qemu-xhci+usb-tablet AND the builtin PS/2 mouse attached; at runlevel 5 hamUId autostarts in autoflag-50 mode, prints READY, the harness injects rel (PS/2) + abs (usb-tablet) motion over QMP input-send-event, and the daemon prints CUR-moved/REL/ABS/PASS markers only when the injected events actually move CUR_X/CUR_Y through the full live path"
    echo "[test_mouse_gop] PASS"
    [ "${MOUSETEST_KEEP_LOG:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "[test_mouse_gop] FAIL (serial log: $LOG)" >&2
    exit 1
fi
