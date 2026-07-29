#!/usr/bin/env python3
# scripts/_de_desktop_live_view_drv.py — QEMU driver for
# scripts/test_de_desktop_live_view.sh. Boots the installer image under
# UEFI/OVMF, drives REAL pointer gestures through /dev/mouse, and prints
# one "RESULT <name> <value>" line per observation for the shell gate to
# assert on. It makes NO judgements itself.
import os, sys, subprocess, time, threading, re, shutil, tempfile

IMG_SRC, OVMF_SRC, OUT, BOOT_WAIT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
os.makedirs(OUT, exist_ok=True)

tmpd = tempfile.mkdtemp(prefix="hamdlv.")
img = os.path.join(tmpd, "img.raw")
ovmf = os.path.join(tmpd, "ovmf.fd")
mon = os.path.join(tmpd, "mon.sock")
shutil.copy(IMG_SRC, img)
shutil.copy(OVMF_SRC, ovmf)
logpath = os.path.join(OUT, "serial.log")

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio", "-m", "1G",
    "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{mon},server,nowait", "-serial", "stdio",
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
        logf.write(b)
        logf.flush()
        with lock:
            buf.extend(b)


threading.Thread(target=reader, daemon=True).start()

_HB = re.compile(rb'\[hamsh-alive\][^\n]*')
_CSI = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')


def _dn(b):
    return _CSI.sub(b'', _HB.sub(b'', b))


def wait_for(marker, timeout):
    m = marker.encode()
    dl = time.time() + timeout
    while time.time() < dl:
        with lock:
            if m in buf or m in _dn(buf):
                return True
        if qemu.poll() is not None:
            return False
        time.sleep(0.5)
    return False


def send(line):
    try:
        qemu.stdin.write((line + "\n").encode())
        qemu.stdin.flush()
    except Exception:
        pass


def shot(label):
    p = os.path.join(OUT, label + ".ppm")
    subprocess.run(["socat", "-", f"UNIX-CONNECT:{mon}"],
                   input=f"screendump {p}\n".encode(),
                   capture_output=True, timeout=25)
    for _ in range(40):
        if os.path.exists(p) and os.path.getsize(p) > 0:
            break
        time.sleep(0.1)


FB_W, FB_H = 1280, 800


def ab(px, py):
    return (max(0, min(32767, int(px * 32767 / FB_W))),
            max(0, min(32767, int(py * 32767 / FB_H))))


def mv(px, py, btn):
    ax, ay = ab(px, py)
    send(f"echo '{ax} {ay} {btn} 0 1' > /dev/mouse")


TAG = [0]


def run_cmd(cmd, settle=0.5, tries=4):
    TAG[0] += 1
    tag = "DLVX%d" % TAG[0]
    for _ in range(tries):
        with lock:
            start = len(buf)
        send(f"echo {tag}B; {cmd}; echo; echo {tag}E")
        dl = time.time() + 8
        while time.time() < dl:
            with lock:
                ch = bytes(buf[start:])
            if (tag + "E").encode() in ch:
                break
            time.sleep(0.1)
        time.sleep(settle)
        with lock:
            ch = bytes(buf[start:])
        txt = _dn(ch).decode("latin-1")
        a = txt.rfind(tag + "B")
        b = txt.find(tag + "E", a + 1) if a >= 0 else -1
        if a >= 0 and b > a:
            body = txt[a + len(tag) + 1:b]
            if body.strip():
                return body
    return ""


def icon_count():
    """The icon count hamdesktop publishes for the grid it is RENDERING."""
    t = run_cmd("cat /tmp/.hamdesktop.src")
    m = re.findall(r"src=(\S+)\s+n=(\d+)", t)
    if not m:
        return (None, None)
    return (m[-1][0], int(m[-1][1]))


def emit(name, value):
    print(f"RESULT {name} {value}", flush=True)


# ---- the drag gesture ----------------------------------------------------
# Open Applications, hover the first category to open its fly-out, press its
# first app row, then drag to (tx,ty) through several HELD-button motion
# events and release there. This is the user's gesture, driven through the
# real compositor pointer path — no synthesised sidecar anywhere.
MENU_BTN = (40, 10)
CAT_ROW = (78, 58)          # "Accessories" row in the menu box
APP_ROW = (300, 58)         # "Calculator" row in the open fly-out


def menu_window_open():
    """True when a DECORATED window (the Applications menu) is mapped."""
    for n in range(1, 9):
        t = run_cmd(f"cat /dev/wsys/{n}/ctl", settle=0.15, tries=1)
        m = re.search(r"^\s*(-?\d+) (-?\d+) (\d+) (\d+).*dec=(\d+)", t, re.M)
        if m and m.group(5) != "0" and int(m.group(4)) > 100:
            return True
    return False


def open_app_menu(label):
    """Click Applications until its window is actually mapped. The FIRST
    spawn is cold and can take several seconds; a single click + fixed sleep
    silently drives the rest of the gesture onto the bare desktop."""
    for attempt in range(4):
        mv(*MENU_BTN, 0); time.sleep(0.3)
        mv(*MENU_BTN, 1); time.sleep(0.3)
        mv(*MENU_BTN, 0)
        for _ in range(6):
            time.sleep(1.0)
            if menu_window_open():
                shot(label + "_menu")
                return True
    shot(label + "_menu")
    return False


def drag_from_menu(tx, ty, label):
    opened = open_app_menu(label)
    emit("MENU_OPENED_" + label.split("_")[-1].upper(), "1" if opened else "0")
    mv(*CAT_ROW, 0); time.sleep(1.2)          # hover -> fly-out opens
    shot(label + "_flyout")
    mv(*APP_ROW, 0); time.sleep(0.4)
    mv(*APP_ROW, 1); time.sleep(0.4)          # PRESS on the app row
    sx, sy = APP_ROW
    steps = 6
    for k in range(1, steps + 1):
        cx = sx + (tx - sx) * k // steps
        cy = sy + (ty - sy) * k // steps
        mv(cx, cy, 1)                          # held-button motion
        time.sleep(0.35)
    shot(label + "_middrag")
    mv(tx, ty, 1); time.sleep(0.4)
    mv(tx, ty, 0); time.sleep(1.5)             # RELEASE at the drop point
    shot(label + "_dropped")


rc = 2
try:
    if not wait_for("handing off to interactive shell", BOOT_WAIT):
        emit("BOOT", "NO_HANDOFF")
        raise SystemExit(2)
    emit("BOOT", "OK")
    wait_for("[visual_gate] done", 120)
    time.sleep(5)
    shot("00_settled")

    # ============ ITEM 3: the GUI desktop is a LIVE VIEW of ~/Desktop =====
    src, n0 = icon_count()
    emit("SRC", src)
    emit("N0", n0)
    if not src or not src.startswith("/"):
        emit("SRC_BAD", "1")
        raise SystemExit(2)
    emit("SHIPPED_LAUNCHERS", len(re.findall(r"\.desktop", run_cmd(f"ls {src}"))))
    run_cmd(f"echo probe > {src}/GateLiveProbe.txt")
    emit("PROBE_WRITTEN", "1" if "GateLiveProbe" in
         run_cmd(f"ls {src}") else "0")
    time.sleep(5)                               # ~1s re-scan cadence + slack
    src1, n1 = icon_count()
    emit("N1", n1)
    shot("01_probe_added")
    run_cmd(f"rm {src}/GateLiveProbe.txt")
    time.sleep(5)
    src2, n2 = icon_count()
    emit("N2", n2)
    shot("02_probe_removed")

    # ============ ITEM 1: drag an app from the menu ONTO THE PANEL ========
    run_cmd("echo -n '' > /tmp/hamnix-panel-drop")
    before = run_cmd("cat /tmp/hamnix-panel.conf")
    emit("PANELCONF_BEFORE_LAUNCHERS",
         len(re.findall(r"widget launcher ", before)))
    drag_from_menu(700, 12, "03_panel")
    after = run_cmd("cat /tmp/hamnix-panel.conf")
    with open(os.path.join(OUT, "panel_conf_after.txt"), "w") as f:
        f.write(after)
    emit("PANELCONF_AFTER_LAUNCHERS",
         len(re.findall(r"widget launcher ", after)))
    emit("PANEL_DROPPED_CALC",
         "1" if re.search(r"widget launcher \S*hamcalc", after) else "0")
    # The sidecar must be EMPTY afterwards (consumed exactly once). Read it
    # with a marker that only appears when the file has bytes, so the kernel's
    # own console chatter cannot be mistaken for content.
    sc = run_cmd("cat /tmp/hamnix-panel-drop | wc -c")
    m = re.search(r"^\s*(\d+)\s*$", sc, re.M)
    emit("SIDECAR_BYTES_AFTER_PANEL", m.group(1) if m else "UNREADABLE")

    # ============ ITEM 2: drag an app from the menu ONTO THE DESKTOP ======
    src3, n3 = icon_count()
    emit("N3", n3)
    drag_from_menu(760, 620, "04_desktop")
    listing = run_cmd(f"ls {src}")
    with open(os.path.join(OUT, "desktop_listing_after.txt"), "w") as f:
        f.write(listing)
    emit("DESKTOP_DROPPED_CALC",
         "1" if re.search(r"Calculator\.desktop", listing) else "0")
    time.sleep(4)
    src4, n4 = icon_count()
    emit("N4", n4)
    body = run_cmd(f"cat {src}/Calculator.desktop")
    with open(os.path.join(OUT, "dropped_desktop_entry.txt"), "w") as f:
        f.write(body)
    emit("DESKTOP_ENTRY_HAS_EXEC",
         "1" if re.search(r"Exec=\S*hamcalc", body) else "0")
    shot("05_final")
    send("echo DLV_ALIVE_PROBE_ZZ")
    emit("ALIVE", "1" if wait_for("DLV_ALIVE_PROBE_ZZ", 15) else "0")
    rc = 0
except SystemExit as e:
    rc = e.code
except Exception as exc:                                    # noqa: BLE001
    print(f"RESULT DRIVER_EXCEPTION {exc}", flush=True)
    rc = 2
finally:
    try:
        qemu.terminate()
        qemu.wait(timeout=5)
    except Exception:
        try:
            qemu.kill()
        except Exception:
            pass
    logf.flush()
    logf.close()
    shutil.rmtree(tmpd, ignore_errors=True)
sys.exit(rc)
