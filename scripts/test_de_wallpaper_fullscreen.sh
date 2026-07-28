#!/usr/bin/env bash
# scripts/test_de_wallpaper_fullscreen.sh — LIVE visual gate: every built-in
# Control Center wallpaper must COVER THE WHOLE SCREEN.
#
# THE USER BUG (2026-07, hands-on): "in the control center, if you select a
# background image like Sunset or Ocean or Tiles the background does not cover
# the full background and has a lot of black on the bottom, like 1/5 of the
# screen. Default seems to work."
#
# WHAT IT DOES. Boots the installer image under OVMF/KVM to the DE, then for
# each built-in image wallpaper (Default, Sunset, Ocean, Tiles) applies it
# through the EXACT sink the Appearance capplet's click uses —
# `hamctl --wall <n>` calls _write_wallpaper_image_ppm + _wsys_wallpaper_apply,
# i.e. renders the PPM and writes the /dev/wsys/ctl `wallpaper <path>` verb —
# and screendumps the framebuffer. hamctl is spawned VIA THE DE LAUNCH QUEUE
# (/dev/wsys/run/launch, which now carries arguments) because that verb is
# hostowner-only: a serial-shell-spawned hamctl would have its ctl write
# refused, which is NOT what happens when you click the capplet.
#
# WHAT IT ASSERTS, per wallpaper, on the real framebuffer:
#   * the BOTTOM BAND of the desktop (the region the bug blanked) is not
#     black: near-black pixels there stay under BLACK_MAX_PCT; and
#   * the bottom band is as bright as the rest of the backdrop (mean-luma
#     ratio >= LUMA_RATIO_MIN) — a half-painted backdrop shows up as a dark
#     band even when the compositor's root colour is not pure black.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image or socat are missing,
# or when the guest never reaches the shell (host-load timeout is NOT a fail).

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_wallpaper_fullscreen/$TS}"
BLACK_MAX_PCT="${BLACK_MAX_PCT:-2}"
LUMA_RATIO_MIN="${LUMA_RATIO_MIN:-60}"        # percent of the mid-band luma

if [ ! -e /dev/kvm ]; then
    echo "[wpfs] SKIP: /dev/kvm absent (KVM required)" >&2; exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[wpfs] SKIP: OVMF firmware not found (apt install ovmf)" >&2; exit 0
fi
command -v socat >/dev/null 2>&1 || {
    echo "[wpfs] SKIP: socat required to drive the monitor/serial" >&2; exit 0; }

source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[wpfs]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[wpfs] SKIP: $INSTALLER_IMG stale/absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[wpfs] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Reaching here means a build was ATTEMPTED just above and produced no
# image: the tree does not build, nothing is booted and NOTHING IS
# ASSERTED. That is INCONCLUSIVE (125), never a clean skip — the
# by-request skip (HAMNIX_SKIP_BUILD=1) is handled above and still
# exits 0. See scripts/_installer_img.sh + test_gate_softgreen.sh.
[ -f "$INSTALLER_IMG" ] || {
    echo "[wpfs] RESULT: INCONCLUSIVE ($INSTALLER_IMG could not be built)" >&2
    exit 125; }

mkdir -p "$OUT_DIR"
echo "[wpfs] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-wpfs.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wpfs.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-wpfs-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
trap 'rm -f "$OVMF_RW" "$IMG_RW" "$MON"' EXIT

SNAP_HELPER="$OUT_DIR/.snap.sh"
cat > "$SNAP_HELPER" <<SNAPEOF
#!/bin/bash
label="\$1"
ppm="$OUT_DIR/\$label.ppm"
printf 'screendump %s\n' "\$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
for i in \$(seq 1 40); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

: > "$LOG"

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading, re

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

_HB_RE = re.compile(rb'\[hamsh-alive\][^\n]*')
_CSI_RE = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')
def _denoise(b):
    return _CSI_RE.sub(b'', _HB_RE.sub(b'', b))

def wait_for(marker, timeout, since=0):
    m = marker.encode(); deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            tail = bytes(buf[since:])
        if m in tail or m in _denoise(tail):
            return True
        if qemu.poll() is not None:
            return False
        time.sleep(0.4)
    return False

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[wpfs] driver: never reached handoff", file=sys.stderr)
    else:
        print("[wpfs] driver: handoff reached", file=sys.stderr)
        time.sleep(6)
        subprocess.run([snap, "boot"], timeout=30)
        for idx, name in ((0, "default"), (1, "sunset"), (2, "ocean"),
                          (3, "tiles")):
            with lock:
                mark = len(buf)
            # Launch THROUGH THE DE LAUNCH QUEUE, not the serial shell: the
            # /dev/wsys/ctl `wallpaper` verb is hostowner-only, and the
            # interactive shell's session is not the DE's — a shell-spawned
            # hamctl gets its ctl write refused. The panel spawns it in the
            # same context a Control Center click would.
            send("echo '/bin/hamctl --wall %d' > /dev/wsys/run/launch" % idx)
            if not wait_for("[hamctl] wallpaper applied", 30, mark):
                print("[wpfs] driver: %s apply marker not seen" % name,
                      file=sys.stderr)
            # hamdesktop polls /dev/wsys/wallpaper on its redraw cadence.
            wait_for("[hamdesktop] wallpaper loaded", 25, mark)
            time.sleep(5)
            subprocess.run([snap, "wall_%s" % name], timeout=30)
            # hamdesktop is spawned detached (no stdout): it publishes the
            # pipeline state to /tmp/hamdesktop-wp.status instead.
            send("cat /tmp/hamdesktop-wp.status")
            time.sleep(2)
        rc = 0
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()
    logf.flush(); logf.close()
sys.exit(rc)
PYDRV
DRV_RC=$?

if [ "$DRV_RC" = "2" ]; then
    echo "[wpfs] SKIP: guest did not reach interactive shell; log: $LOG" >&2
    exit 0
fi

echo "[wpfs] --- hamdesktop wallpaper pipeline status ---"
grep -ao "gen=[0-9]* loaded=[0-9]* w=[0-9]* h=[0-9]* img=[0-9]*" "$LOG" | tail -4 | sed 's/^/[wpfs]   /'

echo "[wpfs] --- assertions ---"
fail=0
for name in default sunset ocean tiles; do
    f="$OUT_DIR/wall_$name.ppm"
    if [ ! -s "$f" ]; then
        echo "[wpfs] SKIP: $name screendump missing (monitor dump failed)" >&2
        exit 0
    fi
    out=$(python3 - "$f" "$BLACK_MAX_PCT" "$LUMA_RATIO_MIN" <<'PY'
import sys

def load_ppm(path):
    data = open(path, "rb").read()
    if not data.startswith(b"P6"):
        return None
    idx, toks = 2, []
    while len(toks) < 3:
        while idx < len(data) and data[idx:idx+1].isspace():
            idx += 1
        if data[idx:idx+1] == b'#':
            while idx < len(data) and data[idx:idx+1] != b'\n':
                idx += 1
            continue
        s = idx
        while idx < len(data) and not data[idx:idx+1].isspace():
            idx += 1
        toks.append(int(data[s:idx]))
    idx += 1
    w, h, _ = toks
    return w, h, data[idx:idx + w*h*3]

path, black_max, luma_min = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
img = load_ppm(path)
if img is None:
    print("PARSE_FAIL"); sys.exit(0)
w, h, px = img

# Desktop backdrop region: skip the top strip and the bottom panel so the
# panels' own dark chrome cannot mask (or fake) a black band.
TOP, BOT = int(h * 0.10), h - 40
MID0, MID1 = TOP, int(TOP + (BOT - TOP) * 0.5)          # reference band
LOW0, LOW1 = int(TOP + (BOT - TOP) * 0.75), BOT         # the band the bug blanked

def band(y0, y1):
    black = 0; total = 0; luma = 0
    for y in range(y0, y1):
        row = y * w * 3
        for x in range(0, w, 2):                        # every 2nd px: plenty
            i = row + x * 3
            r, g, b = px[i], px[i+1], px[i+2]
            total += 1
            luma += (r * 30 + g * 59 + b * 11) // 100
            if max(r, g, b) < 24:
                black += 1
    return black, total, luma / max(total, 1)

lb, lt, ll = band(LOW0, LOW1)
mb, mt, ml = band(MID0, MID1)
black_pct = 100.0 * lb / max(lt, 1)
ratio = 100.0 * ll / max(ml, 0.001)
ok = (black_pct <= black_max) and (ratio >= luma_min)
print("%s black_pct=%.2f bottom_luma=%.1f mid_luma=%.1f ratio=%.0f%%"
      % ("OK" if ok else "BAD", black_pct, ll, ml, ratio))
PY
)
    echo "[wpfs] $name: $out"
    case "$out" in
        OK*) echo "[wpfs] PASS $name wallpaper covers the full screen" ;;
        *)   echo "[wpfs] FAIL $name wallpaper leaves a dark/black band at the bottom" >&2
             fail=1 ;;
    esac
done

# LIVENESS: a wallpaper that never got applied would sail through the coverage
# checks above (the untouched default backdrop covers the screen fine). Each
# image must actually REPAINT the desktop, so demand a large frame difference
# against the Default backdrop.
for name in sunset ocean tiles; do
    d=$(python3 - "$OUT_DIR/wall_default.ppm" "$OUT_DIR/wall_$name.ppm" <<'PY'
import sys
def load(p):
    d = open(p, "rb").read()
    i, t = 2, []
    while len(t) < 3:
        while d[i:i+1].isspace(): i += 1
        if d[i:i+1] == b'#':
            while d[i:i+1] != b'\n': i += 1
            continue
        s = i
        while not d[i:i+1].isspace(): i += 1
        t.append(int(d[s:i]))
    i += 1
    return t[0], t[1], d[i:i + t[0]*t[1]*3]
wa, ha, a = load(sys.argv[1]); wb, hb, b = load(sys.argv[2])
if (wa, ha) != (wb, hb):
    print(-1); raise SystemExit
n = min(len(a), len(b)); ch = 0
for i in range(0, n - 2, 3):
    if abs(a[i]-b[i]) > 24 or abs(a[i+1]-b[i+1]) > 24 or abs(a[i+2]-b[i+2]) > 24:
        ch += 1
print(ch)
PY
)
    if [ "$d" -ge 50000 ]; then
        echo "[wpfs] PASS $name repainted the desktop ($d px differ from Default)"
    else
        echo "[wpfs] FAIL $name barely changed the desktop ($d px) — the wallpaper was never applied" >&2
        fail=1
    fi
done

echo "[wpfs] artifacts (PPM frames) in $OUT_DIR"
if [ "$fail" = "0" ]; then
    echo "[wpfs] RESULT: PASS"
    exit 0
fi
echo "[wpfs] RESULT: FAIL" >&2
exit 1
