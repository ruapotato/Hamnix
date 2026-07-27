#!/usr/bin/env bash
# scripts/test_de_wallpaper_themes.sh — PICKING A WALLPAPER MUST CHANGE THE
# DESKTOP.
#
# WHY THIS GATE EXISTS
# ====================
# On 2026-07-27 the user reported: "Other theme background still don't cover
# the BG image like Sunset Ocean and Tiles." Reproduced on the shipped image:
# selecting Sunset, Ocean or Tiles left the backdrop showing the Default
# gradient, unchanged, pixel for pixel. `hamctl --wall N` printed
# "[hamctl] wallpaper applied" every time and `cat /dev/wsys/wallpaper` still
# read generation 0 immediately afterwards.
#
# Root cause: the `wallpaper <path>` verb in devwsys_ctl_write sat BEHIND the
# hostowner gate, so it returned -EPERM to the Control Center (a DE app
# running as the default NOBODY uid) — and hamctl never looked at the write's
# return value, so it reported success regardless. Two failures stacked: a
# permission model that treated "choose my own desktop picture" as a host-
# owner privilege, and a client that lied in the affirmative about it.
#
# Every existing wallpaper gate passed throughout. test_de_desktop_wallpaper
# greps the source for the full-screen `image` op; test_de_wallpaper_coverage_host
# renders the mosaic on the host with no kernel at all; test_de_wallpaper_fullscreen
# checks the live backdrop for a black band — and a backdrop stuck on Default
# has no black band, it is a perfectly good picture. NOTHING asserted the
# picture you PICKED is the picture you GET.
#
# WHAT IS ASSERTED (on a real OVMF+KVM boot of the shipped installer image)
# ========================================================================
#   1. `cat /dev/wsys/wallpaper` reports a NON-ZERO generation after an apply
#      — i.e. the ctl verb was accepted, not silently refused.
#   2. Each of Sunset (1), Ocean (2) and Tiles (3) produces a backdrop that
#      DIFFERS from Default (0) over the wallpaper area. This is the user's
#      actual complaint and the thing no other gate covers.
#   3. The three of them differ from EACH OTHER, so the gate cannot be
#      satisfied by any single "not Default" fallback (a solid black backdrop,
#      say) that would look just as broken.
#
# Sampling deliberately excludes the top panel band and the bottom taskbar
# band, which are windows, not backdrop, and are identical in every theme.
#
# Skips cleanly when /dev/kvm, OVMF, socat or the image is missing.
#
# Env overrides:
#   INSTALLER_IMG   image path   (default: build/hamnix-installer.img)
#   OVMF_FD         firmware     (default: auto-resolved)
#   BOOT_WAIT       handoff wait (default: 400)
#
# Pass marker:  [wall-themes] PASS
# Fail marker:  [wall-themes] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-400}"

[ -e /dev/kvm ] || { echo "[wall-themes] SKIP: /dev/kvm absent" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[wall-themes] SKIP: socat required" >&2; exit 0; }
python3 -c "import PIL" 2>/dev/null || { echo "[wall-themes] SKIP: python3 Pillow required" >&2; exit 0; }

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -f "$OVMF_FD" ] || { echo "[wall-themes] SKIP: OVMF firmware not found" >&2; exit 0; }

# STALE-IMAGE GUARD: this gate BOOTS a pre-existing image it did not build.
# On 2026-07-27 it had NO guard at all and booted a 07:28 image against an
# 11:19 HEAD, reporting FAIL on a wallpaper-theme fix that was present and
# correct; it passed instantly after a rebuild. The mirror-image failure is
# worse: a stale image silently PASSES the regression this gate exists to
# catch. ensure_installer_img REBUILDS when the image is missing or older
# than any tracked build input; HAMNIX_SKIP_BUILD=1 downgrades to a LOUD
# stale warning, never a silent pass. shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
ensure_installer_img "$INSTALLER_IMG" "[wall-themes]" \
    || { echo "[wall-themes] SKIP: no usable $INSTALLER_IMG" >&2; exit 0; }

TMPD=$(mktemp -d --tmpdir hamnix-wall-themes.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT
cp "$OVMF_FD" "$TMPD/ovmf.fd"
cp "$INSTALLER_IMG" "$TMPD/img.raw"

echo "[wall-themes] img=$INSTALLER_IMG"

python3 - "$TMPD" "$BOOT_WAIT" <<'PYDRV'
import os, subprocess, sys, threading, time
from PIL import Image

tmpd, boot_wait = sys.argv[1], int(sys.argv[2])
mon = os.path.join(tmpd, "mon.sock")

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", os.path.join(tmpd, "ovmf.fd"),
    "-drive", "file=%s,format=raw,if=virtio" % os.path.join(tmpd, "img.raw"),
    "-m", "1G", "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", "unix:%s,server,nowait" % mon, "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
   stderr=subprocess.STDOUT, bufsize=0)

buf = bytearray(); lock = threading.Lock()
def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b: break
        with lock: buf.extend(b)
threading.Thread(target=reader, daemon=True).start()

def wait_for(marker, timeout):
    d = time.time() + timeout
    while time.time() < d:
        with lock:
            if buf.find(marker.encode()) >= 0: return True
        if qemu.poll() is not None: return False
        time.sleep(0.05)
    return False

def send(line):
    qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()

def mon_cmd(cmd):
    subprocess.run(["socat", "-", "UNIX-CONNECT:%s" % mon],
                   input=(cmd + "\n").encode(), stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=30)

def shot(name):
    p = os.path.join(tmpd, name)
    try: os.unlink(p)
    except OSError: pass
    mon_cmd("screendump %s" % p)
    for _ in range(100):
        if os.path.exists(p) and os.path.getsize(p) > 1000:
            time.sleep(0.2)
            try: return Image.open(p).convert("RGB")
            except Exception: pass
        time.sleep(0.05)
    return None

# Backdrop-only sample grid: skip the top panel band and the bottom taskbar
# band (those are windows, not wallpaper, and are theme-independent), and
# skip the left icon column.
def samples(im):
    w, h = im.size
    out = []
    for gy in range(6):
        y = int(h * 0.12 + (h * 0.72) * gy / 5.0)
        for gx in range(8):
            x = int(w * 0.25 + (w * 0.70) * gx / 7.0)
            out.append(im.getpixel((x, y)))
    return out

def dist(a, b):
    return sum(abs(p[c] - q[c]) for p, q in zip(a, b) for c in range(3))

fails = []
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[wall-themes] FAIL: never reached handoff", file=sys.stderr)
        sys.exit(1)
    time.sleep(25)

    grabs = {}
    for idx, name in ((0, "Default"), (1, "Sunset"), (2, "Ocean"), (3, "Tiles")):
        send("/bin/hamctl --wall %d" % idx)
        time.sleep(9)
        im = shot("w%d.ppm" % idx)
        if im is None:
            print("[wall-themes] FAIL: no screendump for %s" % name, file=sys.stderr)
            sys.exit(1)
        grabs[name] = samples(im)
        print("[wall-themes] captured %s" % name)

    # 1. The ctl verb must have been ACCEPTED (generation left 0 == refused).
    with lock: since = len(buf)
    send("cat /dev/wsys/wallpaper")
    time.sleep(6)
    with lock: tail = bytes(buf[since:]).decode("utf-8", "replace")
    gen = None
    for line in tail.splitlines():
        s = line.strip()
        tok = s.split()
        if tok and tok[0].isdigit() and len(tok) >= 2 and tok[1].startswith("/"):
            gen = int(tok[0]); break
    if gen is None:
        fails.append("could not read a '<gen> <path>' line from /dev/wsys/wallpaper")
    elif gen == 0:
        fails.append("/dev/wsys/wallpaper generation is still 0 after four "
                     "applies — the ctl verb was refused (hostowner gate?)")
    else:
        print("[wall-themes] PASS wallpaper generation advanced to %d" % gen)

    # 2. Each named theme must differ from Default.
    base = grabs["Default"]
    for name in ("Sunset", "Ocean", "Tiles"):
        d = dist(grabs[name], base)
        if d < 600:
            fails.append("%s backdrop is indistinguishable from Default "
                         "(total channel distance %d over 48 samples)" % (name, d))
        else:
            print("[wall-themes] PASS %s differs from Default (distance %d)" % (name, d))

    # 3. ...and from each other, so a single broken fallback cannot pass.
    for a, b in (("Sunset", "Ocean"), ("Ocean", "Tiles"), ("Sunset", "Tiles")):
        d = dist(grabs[a], grabs[b])
        if d < 600:
            fails.append("%s and %s backdrops are indistinguishable "
                         "(distance %d)" % (a, b, d))
        else:
            print("[wall-themes] PASS %s differs from %s (distance %d)" % (a, b, d))
finally:
    try: mon_cmd("quit")
    except Exception: pass
    time.sleep(1)
    qemu.kill()

if fails:
    for f in fails:
        print("[wall-themes] FAIL: %s" % f, file=sys.stderr)
    sys.exit(1)
print("[wall-themes] PASS")
PYDRV
rc=$?
exit $rc
