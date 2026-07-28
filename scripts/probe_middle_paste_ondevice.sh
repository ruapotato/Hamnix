#!/usr/bin/env bash
# scripts/probe_middle_paste_ondevice.sh — ON-DEVICE REPRODUCER for the
# middle-click PRIMARY paste defect. NOT a CI gate: it currently FAILS,
# because the bug it reproduces is still open. Do not add it to
# scripts/ci_battery_manifest.txt until it passes.
#
# WHY IT EXISTS
# =============
# The user, twice: "Mid mouse does not paste the hilated text still but event
# vewer does see the mid moues." Nine host gates already cover this feature
# (test_snarf_primary_host, test_htb_evt_paste_host, test_primary_paste_chain_host,
# test_hamtextbox_host, test_htermsel_host, test_hamedit_clipboard,
# test_paste_gnu_crosscheck, test_de_snarf_wctl, test_htb) and every one of
# them is green. docs/text_selection_clipboard.md says so explicitly in its
# closing paragraph: automated confirmation of click-to-position, drag-select
# and middle-paste through a REAL MOUSE was deferred. That deferred surface is
# exactly where the defect lives, so the host gates could never see it and a
# tenth host gate would not help.
#
# This harness closes that hole. It drives the whole chain on a real OVMF+KVM
# boot of the shipped image, with no screen scraping and no OCR — every
# assertion reads a file over the serial console:
#
#   SELECT half: type a marker into the DE terminal (QEMU `sendkey`), then
#     left-press / drag / release across it by writing absolute pointer
#     events to /dev/mouse, then `cat /dev/snarf.primary` from the serial
#     shell. Highlighting must PUBLISH the selection.
#
#   PASTE half: plant `echo <marker> > /dev/snarf` in /dev/snarf.primary,
#     middle-click in the terminal, then `cat /dev/snarf` from the serial
#     shell. The paste is asserted by its EFFECT — the terminal executed the
#     pasted line — so there is nothing to misread off a screenshot.
#
# WHAT IT FOUND (2026-07-27, image 7747bfe1, 1280x800)
# ====================================================
# BOTH halves fail on device, which overturns the briefed framing that the
# event arrives and only the "primary-selection -> paste plumbing" is
# missing. The event does arrive — the injected pointer moves the cursor to
# the requested screen pixel, confirmed by screendump — and the compositor
# does route it: haminput, reading the same /dev/wsys/<wid>/event ring, shows
# MIDDLE-down. But in hamtermscene:
#
#   * a left drag across text leaves /dev/snarf.primary EMPTY at every row
#     tried, and the "[hamterm] SEL copied PRIMARY" marker never appears;
#   * a middle click with a known-good PRIMARY payload executes nothing.
#
# So PRIMARY is never SET, and there is therefore nothing for the middle
# click to paste. Chasing the paste half alone cannot fix this. The break is
# between the compositor emitting `m <x> <y> <buttons> <dz>` on the window's
# event ring and hamtermscene's _evt_apply_wheel acting on it — both ends of
# which read correct in the source, so the next step is to instrument the
# ring itself (does the app's non-blocking drain observe the press at all, or
# does it observe it with coordinates that miss the grid?).
#
# USAGE:  bash scripts/probe_middle_paste_ondevice.sh
#         artifacts land in build/middle_paste_probe/

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
OUTDIR="${OUTDIR:-build/middle_paste_probe}"
BOOT_WAIT="${BOOT_WAIT:-400}"

[ -e /dev/kvm ] || { echo "[mid-paste] SKIP: /dev/kvm absent" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[mid-paste] SKIP: socat required" >&2; exit 0; }

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -f "$OVMF_FD" ] || { echo "[mid-paste] SKIP: OVMF firmware not found" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "[mid-paste] SKIP: $INSTALLER_IMG absent" >&2; exit 0; }

mkdir -p "$OUTDIR"
TMPD=$(mktemp -d --tmpdir hamnix-mid-paste.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT
cp "$OVMF_FD" "$TMPD/ovmf.fd"
cp "$INSTALLER_IMG" "$TMPD/img.raw"

python3 - "$TMPD" "$OUTDIR" "$BOOT_WAIT" <<'PYDRV'
import os, re, subprocess, sys, threading, time

tmpd, outdir, boot_wait = sys.argv[1], sys.argv[2], int(sys.argv[3])
mon = os.path.join(tmpd, "mon.sock")
SW, SH = 1280, 800
PASTE_MARK = "HAMPASTEOK"

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

def wait_for(m, t):
    d = time.time() + t
    while time.time() < d:
        with lock:
            if buf.find(m.encode()) >= 0: return True
        if qemu.poll() is not None: return False
        time.sleep(0.05)
    return False

def send(l):
    qemu.stdin.write((l + "\n").encode()); qemu.stdin.flush()

def mon_cmd(c):
    subprocess.run(["socat", "-", "UNIX-CONNECT:%s" % mon],
                   input=(c + "\n").encode(), stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=30)

def mouse(x, y, btn):
    """Absolute pointer event on /dev/mouse: '<ax> <ay> <buttons> <dz> 1'."""
    ax = int(x * 32767 / (SW - 1)); ay = int(y * 32767 / (SH - 1))
    send('echo "%d %d %d 0 1" > /dev/mouse' % (ax, ay, btn))
    time.sleep(1.2)

def cap(cmd, pause=5):
    with lock: since = len(buf)
    send(cmd); time.sleep(pause)
    with lock: return bytes(buf[since:]).decode("utf-8", "replace")

fails = []
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[mid-paste] FAIL: never reached handoff", file=sys.stderr)
        sys.exit(1)
    time.sleep(25)

    send("echo /bin/hamtermscene > /dev/wsys/run/launch")
    if not wait_for("[hamterm] scene window ready", 90):
        print("[mid-paste] FAIL: DE terminal never came up", file=sys.stderr)
        sys.exit(1)
    time.sleep(10)

    # ---- Locate the terminal window DETERMINISTICALLY ------------------
    # Blind screen coordinates are what made the earlier arm of this probe
    # unfalsifiable: a click that misses the window proves nothing. Take the
    # wid the kernel just mapped off the serial log, then read the window's
    # real rect from its own wctl file ("<x> <y> <w> <h> <focus>") and derive
    # every click from the terminal's OWN cell geometry (lib/htermsel.ad:
    # x0=6, cell_w=8, y0=6, line_h=20 in window-content-local pixels).
    with lock: pre = bytes(buf).decode("utf-8", "replace")
    wids = re.findall(r"\[devwsys\] window (\d+) mapped", pre)
    if not wids:
        print("[mid-paste] FAIL: no window ever mapped", file=sys.stderr)
        sys.exit(1)
    wid = wids[-1]
    # NB: read the per-window /ctl file, NOT /wctl. The rio-shape wctl status
    # line is backed by a SEPARATE wsys_wctl_x/y/w/h store that the scene
    # compositor never updates, so it reports "0 0 0 0 click" for every live
    # window; /ctl reports the compositor's real rect
    # ("<x> <y> <w> <h> z=.. decorate=.. gen=..").
    geo = cap("cat /dev/wsys/%s/ctl" % wid, 5)
    gm = re.search(r"(-?\d+) (-?\d+) (\d+) (\d+) z=", geo)
    if not gm:
        print("[mid-paste] FAIL: could not read window %s geometry: %r"
              % (wid, geo), file=sys.stderr)
        sys.exit(1)
    wx, wy, ww, wh = (int(g) for g in gm.groups())
    print("[mid-paste] terminal wid=%s rect=%d,%d %dx%d" % (wid, wx, wy, ww, wh))

    def cell(row, col):
        """Screen pixel at the CENTRE of grid cell (row,col) of this window."""
        return (wx + 6 + col * 8 + 4, wy + 6 + row * 20 + 10)

    # ---- SELECT half: drag across the terminal's own output -------------
    # The grid already holds the startup `echo NS_OK; ls /` output, so no
    # keystroke injection is needed on the critical path. Drag from the first
    # cell to a cell several rows down: whatever the layout, the span covers
    # non-empty text, so a working selection MUST publish a non-empty PRIMARY.
    send("echo -n '' > /dev/snarf.primary"); time.sleep(3)
    with lock: sel_since = len(buf)
    x0, y0 = cell(0, 0)
    x1, y1 = cell(2, 12)
    x2, y2 = cell(4, 24)
    mouse(x0, y0, 0)            # move in, no button
    mouse(x0, y0, 1)            # LEFT press  -> anchor
    mouse(x1, y1, 1)            # drag        -> extend
    mouse(x2, y2, 1)            # drag        -> extend
    mouse(x2, y2, 0)            # release     -> copy to PRIMARY
    time.sleep(2)
    prim = cap("echo PRIMBEG; cat /dev/snarf.primary; echo; echo PRIMEND", 8)
    with lock: sel_tail = bytes(buf[sel_since:]).decode("utf-8", "replace")
    mon_cmd("screendump %s" % os.path.join(outdir, "afterdrag.ppm"))

    # PRIMARY CONTENT is the assertion — the marker alone is only corroborating
    # (a marker can be lost to the console gate; a file read cannot).
    # hamsh echoes every typed character back, so the raw capture is full of
    # cursor-motion escapes; take only what lies between the two markers on
    # their OWN output lines and strip the escape noise.
    pm = re.search(r"PRIMBEG(.*?)PRIMEND", prim, re.S)
    prim_body = pm.group(1) if pm else ""
    prim_body = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", prim_body)
    prim_body = prim_body.replace("\r", "")
    prim_body = "\n".join(l for l in prim_body.split("\n")
                          if "hamsh$" not in l and "echo PRIM" not in l)
    prim_body = prim_body.strip()
    if not prim_body:
        fails.append("a left drag over terminal text left /dev/snarf.primary "
                     "EMPTY (selection never published; marker seen: %s)"
                     % ("yes" if "SEL copied PRIMARY" in sel_tail else "no"))
    else:
        print("[mid-paste] PASS drag published PRIMARY: %r" % prim_body[:60])

    # ---- PASTE half: plant an executable line, middle-click ------------
    send("echo -n '' > /dev/snarf"); time.sleep(3)
    send("echo 'echo %s > /dev/snarf' > /dev/snarf.primary" % PASTE_MARK)
    time.sleep(3)
    px, py = cell(1, 4)
    mouse(px, py, 0)
    mouse(px, py, 4)            # middle down (bit2)
    mouse(px, py, 0)            # middle up
    time.sleep(6)
    mon_cmd("screendump %s" % os.path.join(outdir, "afterpaste.ppm"))
    time.sleep(1)
    out = cap("cat /dev/snarf", 6)
    if PASTE_MARK not in out:
        fails.append("a middle click with a known-good PRIMARY payload "
                     "pasted nothing (the terminal never ran the pasted line)")
    else:
        print("[mid-paste] PASS middle click pasted and the line executed")
finally:
    with lock:
        open(os.path.join(outdir, "serial.log"), "wb").write(bytes(buf))
    try: mon_cmd("quit")
    except Exception: pass
    time.sleep(1); qemu.kill()

if fails:
    for f in fails:
        print("[mid-paste] FAIL: %s" % f, file=sys.stderr)
    sys.exit(1)
print("[mid-paste] PASS")
PYDRV
exit $?
