#!/usr/bin/env bash
# scripts/bench_de_ondevice.sh — ON-DEVICE desktop responsiveness benchmark.
#
# WHY: the user reports the whole desktop got laggy ("2048 used to be quick but
# is very laggy now — only like 2 or 3 fps when blocks are moving", "the mouse on
# startup seems low fps", "terminal input seems to have like .2 sec lag"). Every
# one of those pixels is pushed by the KERNEL scene compositor
# (sys/src/9/port/devwsys.ad rasterizes each window and z-blits to /dev/fb), so
# desktop responsiveness is a direct read-out of KERNEL code speed. This harness
# turns that feel into numbers that can be A/B'd across kernel builds.
#
# It measures, on a real OVMF+KVM boot of build/hamnix-installer.img:
#
#   1. boot_to_handoff_s   — power-on -> "handing off to interactive shell".
#                            A whole-kernel speed proxy (no DE involved).
#   2. term_echo_ms        — median round-trip of a typed shell line to its
#                            echoed output (the "terminal input lag" number).
#   3. win_paint_s         — `echo /bin/ham2048scene > /dev/wsys/run/launch`
#                            -> first frame in which the window is painted.
#   4. game_fps            — N arrow keys are injected into 2048 through the
#                            emulated PS/2 keyboard (QEMU monitor `sendkey`);
#                            we time how long the compositor takes to settle
#                            (two identical consecutive screendumps). Every key
#                            is one animated move, so fps = N / settle_seconds.
#                            This is the "2 or 3 fps" number.
#
# USAGE
#   bash scripts/bench_de_ondevice.sh                 # bench build/hamnix-installer.img
#   INSTALLER_IMG=/path/img.raw OUT_REPORT=x.txt bash scripts/bench_de_ondevice.sh
#   LABEL=native bash scripts/bench_de_ondevice.sh    # tag the report
#   NO_KVM=1 bash scripts/bench_de_ondevice.sh        # TCG (slow-CPU proxy)
#
# NO_KVM=1 runs the guest under TCG instead of KVM. Use it to A/B a change
# whose cost is CPU-side: on a fast KVM host every reading below pins to the
# harness noise floor (a screendump round-trip), because the desktop is
# already faster than the harness can sample. TCG scales the guest CPU down
# by ~an order of magnitude, which is also the closer model of the real
# hardware Hamnix targets, and makes compositor CPU the actual bottleneck.
#
# This is a MANUAL A/B bench, not a CI pass/fail gate: absolute numbers are
# host-CPU dependent, so only compare runs on the SAME quiet host. It never
# writes to the tree under test and needs no kernel instrumentation.
set -u
cd "$(dirname "$0")/.." || exit 1

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LABEL="${LABEL:-default}"
BOOT_WAIT="${BOOT_WAIT:-300}"
KEYS="${KEYS:-24}"
OUT_REPORT="${OUT_REPORT:-build/bench_de_ondevice_$LABEL.txt}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "[bench_de] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[bench_de] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[bench_de] SKIP: socat required" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "[bench_de] SKIP: $INSTALLER_IMG absent" >&2; exit 0; }

TMPD=$(mktemp -d --tmpdir hamnix-bench-de.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT
cp "$OVMF_FD" "$TMPD/ovmf.fd"
cp "$INSTALLER_IMG" "$TMPD/img.raw"

echo "[bench_de] label=$LABEL img=$INSTALLER_IMG"
echo "[bench_de] host: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
echo "[bench_de] load: $(uptime | sed 's/.*load average/load average/')"

python3 - "$TMPD" "$BOOT_WAIT" "$KEYS" "$LABEL" "$OUT_REPORT" "${NO_KVM:-0}" <<'PYDRV'
import hashlib, os, statistics, subprocess, sys, threading, time

tmpd, boot_wait, keys, label, report, no_kvm = sys.argv[1:7]
boot_wait, keys = int(boot_wait), int(keys)
accel = ["-cpu", "qemu64"] if no_kvm == "1" else ["-enable-kvm", "-cpu", "host"]
mon = os.path.join(tmpd, "mon.sock")
log = open(os.path.join(tmpd, "serial.log"), "wb")

t_start = time.time()
qemu = subprocess.Popen([
    "qemu-system-x86_64",
] + accel + [
    "-bios", os.path.join(tmpd, "ovmf.fd"),
    "-drive", "file=%s,format=raw,if=virtio" % os.path.join(tmpd, "img.raw"),
    "-m", "1G", "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", "unix:%s,server,nowait" % mon,
    "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)

buf = bytearray()
lock = threading.Lock()

def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b:
            break
        log.write(b); log.flush()
        with lock:
            buf.extend(b)

threading.Thread(target=reader, daemon=True).start()

def wait_for(marker, timeout, since=0):
    m = marker.encode()
    deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if buf.find(m, since) >= 0:
                return time.time()
        if qemu.poll() is not None:
            return None
        time.sleep(0.02)
    return None

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

def mon_cmd(cmd):
    subprocess.run(["socat", "-", "UNIX-CONNECT:%s" % mon],
                   input=(cmd + "\n").encode(),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)

def screenhash():
    """Hash the current framebuffer. Returns (hash, nonblack_pixel_count)."""
    ppm = os.path.join(tmpd, "shot.ppm")
    try:
        os.unlink(ppm)
    except OSError:
        pass
    mon_cmd("screendump %s" % ppm)
    for _ in range(60):
        if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
            time.sleep(0.05)
            try:
                data = open(ppm, "rb").read()
            except OSError:
                continue
            if len(data) > 1000:
                return hashlib.sha1(data).hexdigest(), len(data)
        time.sleep(0.05)
    return None, 0

res = {"label": label, "keys_injected": keys}
try:
    t_handoff = wait_for("handing off to interactive shell", boot_wait)
    if t_handoff is None:
        print("[bench_de] FAIL: never reached handoff", file=sys.stderr)
        sys.exit(1)
    res["boot_to_handoff_s"] = round(t_handoff - t_start, 2)
    print("[bench_de] boot_to_handoff_s=%.2f" % res["boot_to_handoff_s"], file=sys.stderr)

    # Let rc.5 finish bringing the desktop up before timing anything.
    time.sleep(20)

    # ---- 2. terminal input latency ------------------------------------
    # Round-trip of a typed shell line to its echoed output. This is the
    # kernel tty/uaccess/schedule path the DE terminal also rides.
    lat = []
    for i in range(7):
        tag = "PERFMARK%02d" % i
        with lock:
            since = len(buf)
        t0 = time.time()
        send("echo %s" % tag)
        t1 = wait_for(tag, 15, since)
        if t1:
            lat.append((t1 - t0) * 1000.0)
        time.sleep(0.4)
    if lat:
        # Drop the first sample (first serial cmd is historically swallowed).
        useful = lat[1:] or lat
        res["term_echo_ms_median"] = round(statistics.median(useful), 1)
        res["term_echo_ms_min"] = round(min(useful), 1)
        res["term_echo_ms_all"] = [round(x, 1) for x in lat]
        print("[bench_de] term_echo_ms_median=%.1f" % res["term_echo_ms_median"], file=sys.stderr)

    # ---- 3. window paint latency --------------------------------------
    base_h, _ = screenhash()
    t0 = time.time()
    send("echo /bin/ham2048scene > /dev/wsys/run/launch")
    painted = None
    while time.time() - t0 < 90:
        h, _ = screenhash()
        if h and h != base_h:
            painted = time.time()
            break
    if painted:
        res["win_paint_s"] = round(painted - t0, 2)
        print("[bench_de] win_paint_s=%.2f" % res["win_paint_s"], file=sys.stderr)
    else:
        res["win_paint_s"] = "none"

    # Let the window settle fully before driving the game.
    time.sleep(8)

    # ---- 4. 2048 frame rate -------------------------------------------
    # The freshly launched window already owns keyboard focus, so we do NOT
    # click (a click anywhere outside the board hands focus to the panel and
    # the arrow keys go nowhere — the first version of this harness measured
    # exactly that and reported a bogus "instant settle"). Inject `keys`
    # arrow keys back to back; each one is a board move that forces the
    # kernel compositor to re-rasterize + re-blit the window. Time how long
    # the desktop takes to settle (two identical consecutive screendumps)
    # and report keys / settle_seconds as the moves-per-second rate.
    # HARNESS NOISE FLOOR: a screendump is a monitor round-trip plus a
    # socat fork, so per-move latencies can never resolve finer than this.
    # Measure it on a static screen and report it alongside the results.
    rtt = []
    for _ in range(10):
        t_a = time.time(); screenhash(); rtt.append((time.time() - t_a) * 1000.0)
    res["screendump_rtt_ms_median"] = round(statistics.median(rtt), 1)

    # PER-MOVE LATENCY. Injecting the whole burst back to back just loses
    # keys in the PS/2 controller (an earlier version of this harness did
    # exactly that and read a bogus instant settle with zero observed frame
    # changes). Instead send ONE arrow key and poll the framebuffer until
    # the board actually changes — that delta IS the user-visible "how long
    # until the blocks move" number. Repeat and take the median.
    seq = ["left", "up", "right", "down"]
    moves = []
    prev, _ = screenhash()
    for i in range(keys):
        t_a = time.time()
        mon_cmd("sendkey %s" % seq[i % 4])
        got = None
        while time.time() - t_a < 10:
            h, _ = screenhash()
            if h and h != prev:
                got = time.time(); prev = h
                break
        if got:
            moves.append((got - t_a) * 1000.0)
        time.sleep(0.3)
    res["moves_observed"] = len(moves)
    if moves:
        res["move_latency_ms_median"] = round(statistics.median(moves), 1)
        res["move_latency_ms_min"] = round(min(moves), 1)
        res["move_latency_ms_max"] = round(max(moves), 1)
        res["game_moves_per_s"] = round(1000.0 / statistics.median(moves), 2)
        print("[bench_de] move_latency_ms_median=%.1f (n=%d, floor=%.1f)"
              % (res["move_latency_ms_median"], len(moves),
                 res["screendump_rtt_ms_median"]), file=sys.stderr)
    else:
        res["move_latency_ms_median"] = "none"
        res["game_moves_per_s"] = 0

    # ---- 5. cursor tracking rate --------------------------------------
    # "The mouse on startup seems low fps": each pointer move repaints the
    # cursor through the same kernel compositor. Inject a stream of relative
    # moves and time the settle the same way.
    cur = []
    prev, _ = screenhash()
    for i in range(16):
        t_a = time.time()
        mon_cmd("mouse_move %d %d" % (17 if i % 2 == 0 else -17, 13 if i % 3 else -13))
        got = None
        while time.time() - t_a < 10:
            h, _ = screenhash()
            if h and h != prev:
                got = time.time(); prev = h
                break
        if got:
            cur.append((got - t_a) * 1000.0)
        time.sleep(0.2)
    if cur:
        res["cursor_latency_ms_median"] = round(statistics.median(cur), 1)
        res["cursor_moves_observed"] = len(cur)
        print("[bench_de] cursor_latency_ms_median=%.1f"
              % res["cursor_latency_ms_median"], file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass

os.makedirs(os.path.dirname(report) or ".", exist_ok=True)
with open(report, "w") as f:
    for k, v in res.items():
        f.write("%s=%s\n" % (k, v))
print("[bench_de] report: %s" % report, file=sys.stderr)
for k, v in res.items():
    print("[bench_de]   %s=%s" % (k, v))
PYDRV
rc=$?
echo "[bench_de] driver rc=$rc"
exit 0
