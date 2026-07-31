#!/usr/bin/env python3
# scripts/_de_sysmon_mem_live_drv.py — QEMU driver for
# scripts/test_de_sysmon_mem_live.sh.
#
# USER-REPORTED BUG (2026-07): "the System Monitor does not release RAM in its
# display until the app is restarted." The RAM really is returned — the
# monitor's own MEMORY row is what goes stale — so the assertion has to compare
# the number the monitor IS DRAWING against the kernel's live /proc/meminfo at
# the same instant. hammonscene publishes exactly that to
# /tmp/.hammonscene.mem ("total=<kB> used=<kB> n=<sample seq>"), the same
# shape hamdesktop uses for /tmp/.hamdesktop.src, because stdout does not reach
# the serial console for a compositor-spawned DE client.
#
# The driver makes NO judgements. It prints one "RESULT <name> <value>" line
# per observation and lets the shell gate decide.
import os, sys, subprocess, time, threading, re, shutil, tempfile

IMG_SRC, OVMF_SRC, OUT, BOOT_WAIT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
os.makedirs(OUT, exist_ok=True)

tmpd = tempfile.mkdtemp(prefix="hamsmm.")
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


TAG = [0]


def run_cmd(cmd, settle=0.5, tries=4):
    TAG[0] += 1
    tag = "SMMX%d" % TAG[0]
    for _ in range(tries):
        with lock:
            start = len(buf)
        send(f"echo {tag}B; {cmd}; echo; echo {tag}E")
        dl = time.time() + 10
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


def emit(name, value):
    print(f"RESULT {name} {value}", flush=True)


# ---- driving the REAL desktop icon --------------------------------------
# hamdesktop publishes one "icon <cx> <cy> <label>" line per icon in
# /tmp/.hamdesktop.src, at the cell origin it is ACTUALLY drawing. We use that
# rather than re-deriving the column flow here: a re-derivation has to guess
# the directory listing order too, and a guess that misses clicks some OTHER
# app and reports a false failure.
FB_W, FB_H = 1280, 800


def ab(px, py):
    return (max(0, min(32767, int(px * 32767 / FB_W))),
            max(0, min(32767, int(py * 32767 / FB_H))))


def mv(px, py, btn):
    ax, ay = ab(px, py)
    send(f"echo '{ax} {ay} {btn} 0 1' > /dev/mouse")


def double_click(px, py):
    # hamdesktop activates on the RELEASE edge, and launches on the SECOND
    # click over the same cell (the first selects). Never hold the button
    # across motion — that is a drag, which launches nothing.
    for _ in range(2):
        mv(px, py, 0); time.sleep(0.3)
        mv(px, py, 1); time.sleep(0.3)
        mv(px, py, 0); time.sleep(0.5)


def sysmon_icon_cell():
    """Screen point to click for the System Monitor desktop icon, or None."""
    t = run_cmd("cat /tmp/.hamdesktop.src")
    for cx, cy, label in re.findall(r"^icon (\d+) (\d+) (.+)$", t, re.M):
        if "monitor" in label.strip().lower():
            # Centre of the icon box within the cell (ICON_W 44, ICON_H 38 at
            # ICON_INSET_Y 4) — clear of the label row underneath it.
            return (int(cx) + 22, int(cy) + 23)
    return None


def kernel_mem():
    """(MemTotal, MemFree) in kB straight from the kernel device."""
    t = run_cmd("cat /proc/meminfo")
    mt = re.search(r"^MemTotal:\s*(\d+)", t, re.M)
    mf = re.search(r"^MemFree:\s*(\d+)", t, re.M)
    return (int(mt.group(1)) if mt else None,
            int(mf.group(1)) if mf else None)


def monitor_mem():
    """(total, used, seq, peak) as the RUNNING System Monitor is drawing it."""
    t = run_cmd("cat /tmp/.hammonscene.mem")
    m = re.findall(r"total=(\d+) used=(\d+) n=(\d+) peak=(\d+)", t)
    if not m:
        return (None, None, None, None)
    return tuple(int(x) for x in m[-1])


rc = 2
try:
    if not wait_for("handing off to interactive shell", BOOT_WAIT):
        emit("BOOT", "NO_HANDOFF")
        raise SystemExit(2)
    emit("BOOT", "OK")
    wait_for("[visual_gate] done", 120)
    time.sleep(5)

    # FIDELITY. The user's instance is spawned by the COMPOSITOR — they
    # double-click the System Monitor icon on the desktop, and hamdesktop
    # launches it DETACHED with the desktop's namespace. A serial-shell `&`
    # spawn is a different parent, a different namespace and an ATTACHED child,
    # so it is not the configuration the report came from. Drive the real icon
    # first and fall back to the shell only if the click path did not take,
    # recording WHICH path produced the instance under test.
    emit("PRE_EXISTING", "1" if monitor_mem()[2] is not None else "0")

    spawn_path = "none"
    ok = False
    cell = sysmon_icon_cell()
    if cell:
        emit("ICON_CELL", "%d,%d" % cell)
        double_click(*cell)
        for _ in range(12):
            time.sleep(2)
            if monitor_mem()[2] is not None:
                ok = True
                spawn_path = "desktop_icon"
                break
    else:
        emit("ICON_CELL", "UNRESOLVED")
    if not ok:
        run_cmd("/bin/hammonscene &", settle=1.0, tries=1)
        for _ in range(20):
            time.sleep(2)
            if monitor_mem()[2] is not None:
                ok = True
                spawn_path = "serial_shell"
                break
    emit("SPAWN_PATH", spawn_path)
    emit("SYSMON_PUBLISHED", "1" if ok else "0")
    if not ok:
        shot("00_no_publish")
        raise SystemExit(2)
    shot("00_sysmon_up")

    kt0, kf0 = kernel_mem()
    mt0, mu0, mn0, mp0 = monitor_mem()
    emit("K_TOTAL0", kt0)
    emit("K_FREE0", kf0)
    emit("M_TOTAL0", mt0)
    emit("M_USED0", mu0)
    emit("M_SEQ0", mn0)

    # ---- CONSUME, HOLD, then RELEASE -------------------------------------
    # memhog allocates HOG_MB, TOUCHES every page (so the frames are genuinely
    # resident, not a lazy reservation), holds, then munmaps and exits. That is
    # a known-size pressure pulse with a known end, which is what makes both
    # halves of the assertion possible: the monitor must SEE the rise (peak)
    # and must COME BACK DOWN with the kernel afterwards.
    # --batch is MANDATORY: without it memhog's hold loop polls stdin, and on
    # this box stdin is the serial line the driver issues commands on — it
    # would eat them. Backgrounded (`&`) deliberately: run in the foreground
    # the shell blocks until memhog is GONE and every later sample would read
    # the post-release state, i.e. a gate that always sees "no change" and
    # calls it a pass (the lesson scripts/test_memhog.sh paid for).
    HOG_MB = 128
    run_cmd(f"/bin/memhog {HOG_MB}M --hold 30 --batch --no-verify &",
            settle=1.0, tries=1)
    time.sleep(14)                                     # sample mid-HOLD
    kt1, kf1 = kernel_mem()
    mt1, mu1, mn1, mp1 = monitor_mem()
    emit("K_FREE1", kf1)
    emit("M_USED1", mu1)
    emit("M_SEQ1", mn1)
    shot("01_hog_held")

    time.sleep(35)                                     # hold expires, memhog frees + exits
    kt2, kf2 = kernel_mem()
    mt2, mu2, mn2, mp2 = monitor_mem()
    emit("K_FREE2", kf2)
    emit("M_USED2", mu2)
    emit("M_SEQ2", mn2)
    emit("M_PEAK2", mp2)
    shot("02_hog_released")

    # The monitor must still be sampling at all (seq advancing).
    emit("SEQ_ADVANCED", "1" if (mn2 is not None and mn0 is not None
                                 and mn2 > mn0) else "0")
    # It must have OBSERVED the pressure — otherwise "came back down" is
    # trivially true for a monitor that never moved.
    if None not in (mp2, mu0):
        emit("PEAK_RISE_KB", mp2 - mu0)
    else:
        emit("PEAK_RISE_KB", "UNREADABLE")
    # THE BUG: after the release, the DISPLAYED used must track the kernel.
    if None not in (kt2, kf2, mu2):
        emit("AGREE_DELTA_KB", abs((kt2 - kf2) - mu2))
        emit("RELEASE_DROP_KB", mp2 - mu2)
    else:
        emit("AGREE_DELTA_KB", "UNREADABLE")
        emit("RELEASE_DROP_KB", "UNREADABLE")
    send("echo SMM_ALIVE_PROBE_ZZ")
    emit("ALIVE", "1" if wait_for("SMM_ALIVE_PROBE_ZZ", 15) else "0")
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
