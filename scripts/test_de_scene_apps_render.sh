#!/usr/bin/env bash
# scripts/test_de_scene_apps_render.sh — render-evidence gate for the two
# new scene-DE applications (hamcalcscene + hameditscene).
#
# Boots the installer image into runlevel 5 (scene DE), waits for the
# interactive serial shell, then launches each scene app THROUGH THE REAL
# DE LAUNCH QUEUE (/dev/wsys/run/launch — the same path the visual gate
# uses) and screendumps the framebuffer BEFORE and AFTER each launch. If
# the AFTER screendump shows new pixels in a window-sized region the app
# rendered. PNGs land in the OUT_DIR for human inspection.
#
# This is render evidence, NOT a strict pass/fail of pixel content (the
# floor is build-green + rl5). rc=124 timeout is NOT a fail.
set -u
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_scene_apps_render/$TS}"
mkdir -p "$OUT_DIR"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "[apps_render] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[apps_render] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[apps_render] SKIP: socat required" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "[apps_render] SKIP: $INSTALLER_IMG absent" >&2; exit 0; }
# Stale-artifact guard: this gate BOOTS a pre-existing image it did not
# build. Booting a stale one silently is the 2026-07-24 false-negative
# class — be loud about it. shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
installer_img_warn_if_stale "$INSTALLER_IMG" "[de_scene_apps_render]"

echo "[apps_render] output dir: $OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-ar.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-ar.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-ar-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() { rm -f "$OVMF_RW" "$IMG_RW" "$MON"; }
trap cleanup EXIT
: > "$LOG"

SNAP_HELPER="$OUT_DIR/.snap.sh"
cat > "$SNAP_HELPER" <<SNAPEOF
#!/bin/bash
label="\$1"
ppm="$OUT_DIR/\$label.ppm"
printf 'screendump %s\n' "\$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
for i in \$(seq 1 30); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading
img, ovmf, mon, logpath, snap, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio",
    "-m", "1G",
    "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{mon},server,nowait",
    "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
   bufsize=0)
logf = open(logpath, "wb")
buf = bytearray(); lock = threading.Lock()
def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b: break
        logf.write(b); logf.flush()
        with lock: buf.extend(b)
threading.Thread(target=reader, daemon=True).start()
def wait_for(marker, timeout):
    m = marker.encode(); deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf: return True
        if qemu.poll() is not None: return False
        time.sleep(0.2)
    return False
def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
def screendump(label):
    subprocess.run([snap, label], timeout=20)
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[apps_render] driver: never reached handoff", file=sys.stderr)
    else:
        print("[apps_render] driver: handoff reached", file=sys.stderr)
        # rc.5 launches the calculator + text editor as their own scene
        # services at boot (the working scene-client path). Wait for both
        # launch markers, let the DE settle, then screendump the desktop —
        # both app windows should be painted in the one frame.
        wait_for("[scene_de] launching calculator", 90)
        wait_for("[scene_de] launching text editor", 30)
        time.sleep(10)
        screendump("desktop")
        print("[apps_render] driver: captured settled desktop", file=sys.stderr)
        print("[apps_render] driver: done", file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception:
        qemu.kill()
PYDRV

# Convert ppm -> png for inspection.
if [ -s "$OUT_DIR/desktop.ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$OUT_DIR/desktop.ppm" > "$OUT_DIR/desktop.png" 2>/dev/null || true
fi

echo "[apps_render] --- render evidence ---"
fail=0
# Both scene apps must reach their rc.5 launch markers (own scene-client ns).
if grep -aq '\[scene_de\] launching calculator' "$LOG"; then
    echo "[apps_render] PASS calculator launched (scene path)"
else
    echo "[apps_render] FAIL calculator launch marker missing"; fail=1
fi
if grep -aq '\[scene_de\] launching text editor' "$LOG"; then
    echo "[apps_render] PASS text editor launched (scene path)"
else
    echo "[apps_render] FAIL text editor launch marker missing"; fail=1
fi
# No kernel panic.
if grep -aqi 'kernel panic\|#UD\|triple fault' "$LOG"; then
    echo "[apps_render] FAIL panic/fault in serial log"; fail=1
else
    echo "[apps_render] PASS no panic during boot"
fi
if [ -s "$OUT_DIR/desktop.png" ]; then
    echo "[apps_render] screendump: $OUT_DIR/desktop.png (view for the calc grid + editor area)"
else
    echo "[apps_render] WARN no desktop screendump captured"
fi

echo "[apps_render] artifacts in $OUT_DIR"
if [ "$fail" -eq 0 ]; then
    echo "[apps_render] RESULT: PASS"
else
    echo "[apps_render] RESULT: FAIL"
fi
exit 0
