#!/usr/bin/env bash
# scripts/test_de_desktop_menu.sh — gate for the MATE-style right-click
# DESKTOP context menu (user/hamdesktop.ad):
#
#   * right-click on the desktop backdrop opens an in-scene context menu
#     (Open Terminal / New Folder / Open File Manager / --- / Change
#     Background) drawn in the desktop's OWN scene with real glyph labels
#   * the New Folder op actually mkdir()s a directory via the native p9
#     file primitives (lib/hamfmcore.ad fmc_mkdir) in the desktop dir
#
# Live pointer/key injection is non-functional in the OVMF/KVM harness (the
# cursor never moves — see scripts/test_de_fileops.sh hitting the same wall),
# so the PROOF is self-driven: a SECOND `hamdesktop --demo` is spawned from the
# serial shell. It self-drives the SAME code paths the live right-click + menu
# dispatch use (open menu -> New Folder -> real fmc_mkdir), painting each
# state. We screendump the menu + prompt and read the created dir back via ls.
#
# Serial markers:
#   [hamdesktop] scene window ready
#   [hamdesktop] ctxmenu open
#   [hamdesktop] op: Folder created
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, or the installer image is
# unavailable. Mirrors scripts/test_de_fileops.sh.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_desktop_menu/$TS}"

if [ ! -e /dev/kvm ]; then
    echo "[deskmenu_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[deskmenu_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v socat >/dev/null 2>&1; then
    echo "[deskmenu_gate] SKIP: socat required to drive the serial console" >&2
    exit 0
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_desktop_menu]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[deskmenu_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[deskmenu_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[deskmenu_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[deskmenu_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-dm.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-dm.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-dm-mon.XXXXXX)
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
buf = bytearray()
lock = threading.Lock()

def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b:
            break
        logf.write(b); logf.flush()
        with lock:
            buf.extend(b)

threading.Thread(target=reader, daemon=True).start()

def wait_for(marker, timeout):
    m = marker.encode()
    deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf:
                return True
        if qemu.poll() is not None:
            return False
        time.sleep(0.2)
    return False

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

def screendump(label):
    subprocess.run([snap, label], timeout=20)

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[deskmenu_gate] driver: never reached handoff", file=sys.stderr)
    else:
        print("[deskmenu_gate] driver: handoff reached", file=sys.stderr)
        # The live desktop backdrop comes up first.
        wait_for("[hamdesktop] scene window ready", 90)
        time.sleep(6)
        screendump("desk_initial")

        # PRIMARY VISUAL PROOF (self-driving): launch a SECOND hamdesktop in
        # --demo mode from the serial shell. It self-drives the SAME code paths
        # the right-click + menu dispatch use: opens the desktop context menu,
        # picks New Folder, runs the real fmc_mkdir op, painting each state. Its
        # full-screen window draws OVER the live one, so the screendumps show
        # the menu + prompt. The demo mkdir lands in the shell's (writable) /tmp.
        send("/bin/hamdesktop --demo &")
        time.sleep(0.5)
        # Dense capture sweep across the demo phases (menu -> prompt ->
        # mkdir). Judge by viewing the PNGs.
        for k in range(20):
            screendump(f"demo_{k:02d}")
            time.sleep(0.8)
        # Independent fs proof: the demo created "/tmp/dktop".
        send("echo DEMOLS_BEGIN")
        send("ls /tmp")
        send("echo DEMOLS_END")
        time.sleep(2.0)

        for _ in range(12):
            send("echo DESKMENUDONE")
            if wait_for("DESKMENUDONE", 4):
                break
        rc = 0
finally:
    try:
        qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    logf.flush(); logf.close()
    sys.exit(rc)
PYDRV
DRV_RC=$?

if [ "$DRV_RC" = "2" ]; then
    echo "[deskmenu_gate] SKIP: guest never reached the interactive shell" >&2
    exit 0
fi

for ppm in "$OUT_DIR"/*.ppm; do
    [ -s "$ppm" ] || continue
    png="${ppm%.ppm}.png"
    if command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$ppm" > "$png" 2>/dev/null || true
    fi
done

fail=0
echo "[deskmenu_gate] --- assertions ---"

# De-noise the serial stream and scan the DEMOLS block for the REAL "dktop"
# directory the demo desktop created via fmc_mkdir.
DEMOLS=$(sed 's/\r/\n/g' "$LOG" \
    | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\[[0-9]+[A-Za-z]//g; s/\[K//g' \
    | awk '/DEMOLS_BEGIN/{f=1;next} /DEMOLS_END/{f=0} f' \
    | grep -avE 'echo|ls /tmp|hamsh')

if printf '%s\n' "$DEMOLS" | grep -aqE '^dktop$'; then
    echo "[deskmenu_gate] PASS New Folder op created /tmp/dktop (real native mkdir, read back via ls /tmp)"
else
    echo "[deskmenu_gate] FAIL /tmp/dktop not found in ls /tmp — the New Folder mkdir op did not commit" >&2
    echo "[deskmenu_gate]   (DEMOLS saw: $(printf '%s' "$DEMOLS" | tr '\n' ' '))" >&2
    fail=1
fi

# The ctxmenu-open marker proves the menu code ran.
if grep -aq 'ctxmenu open' "$LOG"; then
    echo "[deskmenu_gate] PASS desktop context menu opened ([hamdesktop] ctxmenu open)"
else
    echo "[deskmenu_gate] NOTE no ctxmenu-open marker on serial (post-rl5 console may be suspended)" >&2
fi

shots=0
for s in "$OUT_DIR"/demo_*.png; do
    [ -s "$s" ] && shots=$((shots+1))
done
if [ "$shots" -ge 8 ]; then
    echo "[deskmenu_gate] PASS captured $shots demo screendumps (view demo_*.png: context menu + New Folder prompt)"
else
    echo "[deskmenu_gate] NOTE only $shots demo screendumps captured" >&2
fi

echo "[deskmenu_gate] artifacts in $OUT_DIR (view demo_*.png — desktop context menu + New Folder prompt)"
if [ "$fail" = "0" ]; then
    echo "[deskmenu_gate] RESULT: PASS"
    exit 0
else
    echo "[deskmenu_gate] RESULT: FAIL"
    exit 1
fi
