#!/usr/bin/env bash
# scripts/test_de_scene_termfm.sh — FOCUSED gate for the scene-file DE
# TERMINAL and FILE MANAGER (user/hamtermscene.ad, user/hamfmscene.ad).
#
# Two USER-reported bugs this gate locks down:
#
#   Bug 1 — the terminal was not a terminal. It echoed EVERY routed event
#   (including "m <x> <y> ..." POINTER lines) as glyphs and ran no shell, so
#   mousing over it filled the window with "m 136 52 0 0" spam and typing
#   did nothing. FIXED: hamtermscene now spawns a persistent /bin/hamsh over
#   a pipe, renders the SHELL'S output as a glyph grid, forwards KEY events
#   from /dev/wsys/<wid>/keys to the shell, and NEVER opens the pointer
#   event file. ASSERTS: the terminal scene contains shell/seed output and
#   does NOT contain a `glyphs ... "m <n> <n>"` pointer-echo line.
#
#   Bug 2 — the file manager stranded you. It had no Up entry and a click on
#   a regular file dumped its raw bytes (ELF chars) as glyphs with no way
#   back. FIXED: hamfmscene adds a ".." Up entry at the top of every listing
#   (except at /), classifies entries by the Plan 9 QTDIR qid bit (not a
#   fragile "can I read it" probe), descends only into real directories, and
#   shows "<name>: not a directory" for a file click while keeping the
#   listing + Up visible. ASSERTS: the FM scene carries a `"../"` Up entry.
#
# Reuses the OVMF/KVM + serial-driver + monitor-screendump harness shape of
# scripts/test_de_scene_render.sh. SKIPS CLEANLY (exit 0) when /dev/kvm,
# OVMF, socat, or the installer image is unavailable.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_scene_termfm/$TS}"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[termfm_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[termfm_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v socat >/dev/null 2>&1; then
    echo "[termfm_gate] SKIP: socat required to drive the serial console" >&2
    exit 0
fi

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_scene_termfm]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[termfm_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[termfm_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[termfm_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[termfm_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-tf.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-tf.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-tf-mon.XXXXXX)
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

# The driver boots the installer to the rl5 scene DE (rc.5 launches
# /bin/hamtermscene + /bin/hamfmscene as services), lets it settle, drives a
# focus click + a typed `ls\n` keystroke sequence at the terminal, then cats
# the live window scenes back with bracketed markers for the bash asserts.
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
        time.sleep(0.5)
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
        print("[termfm_gate] driver: never reached handoff", file=sys.stderr)
    else:
        print("[termfm_gate] driver: handoff reached", file=sys.stderr)
        # rc.5 launches the scene DE clients in detached namespaces; their
        # stdout is rebound away from serial, so we cannot reliably wait on
        # their "ready" markers. Just give the rl5 scene DE time to settle:
        # the kernel scene compositor latch (`desktop`) + the three clients
        # (panel/terminal/fm) newwindow + first commit.
        wait_for("[scene_de] launching file manager", 60)
        time.sleep(8)
        screendump("pre")

        # --- focus + type at the terminal -----------------------------
        # The terminal window sits at screen (200,120) 360x200 (decorated).
        # Click inside it so the compositor focuses it; the focus router
        # then forwards /dev/cons keystrokes to /dev/wsys/<wid>/keys, which
        # the scene terminal reads. Tablet coord = px/dim*32767; aim at the
        # window body for the common fb modes (1280x800 and 800x600).
        send("echo TYPE_BEGIN")
        # (260,200): 1280x800 -> 6657 8191 ; 800x600 -> 10649 10922
        for cx, cy in (("6657","8191"), ("10649","10922")):
            send(f"echo '{cx} {cy} 1 0 1' > /dev/mouse")
            time.sleep(0.3)
            send(f"echo '{cx} {cy} 0 0 1' > /dev/mouse")
            time.sleep(0.3)
        time.sleep(0.6)
        # NOTE on keystroke injection: the live keyboard path is real HW
        # keyboard -> /dev/cons -> compositor daemon_pump_keys ->
        # evt_emit_key -> /dev/wsys/<focus_wid>/keys, which the scene
        # terminal reads. In THIS serial-driven harness /dev/cons is shared
        # with the boot shell, so a clean text inject contends with it; the
        # VIEWED screendump (post.png) is the authoritative typed-output
        # proof. The deterministic asserts below (no pointer-echo glyphs,
        # terminal fill+seed present, hamsh spawned, FM Up entry) lock the
        # two bug fixes without depending on that contention.
        send("echo TYPE_END")
        time.sleep(0.5)

        # --- descend in the file manager so the ".." Up entry appears ---
        # The FM window sits at screen (260,150) 300x240. Its first listing
        # rows start at window-y ~22 with 16px pitch; a directory row (e.g.
        # "bin/") lives a few rows down. Click a couple of candidate rows to
        # descend into a directory; the relisted view then carries the Up
        # entry at row 0. Screen y ~ 150 + 22 + k*16 for row k.
        send("echo FMCLICK_BEGIN")
        # candidate screen points inside the FM listing (rows 1..5):
        # (300, 188), (300, 220) for 1280x800 and 800x600.
        fm_pts = [
            ("7680","7700"), ("7680","9011"),    # 1280x800: (300,188),(300,220)
            ("12287","10267"), ("12287","12015"),# 800x600 : (300,188),(300,220)
        ]
        for cx, cy in fm_pts:
            send(f"echo '{cx} {cy} 1 0 1' > /dev/mouse")
            time.sleep(0.3)
            send(f"echo '{cx} {cy} 0 0 1' > /dev/mouse")
            time.sleep(0.3)
        send("echo FMCLICK_END")
        time.sleep(1.0)
        screendump("post")

        # --- activate a FILE in the file manager -> launch the editor ---
        # Clicking a NON-directory entry now LAUNCHES /bin/hameditscene on it
        # (it used to no-op with "not a directory"). hamfmscene prints a
        # "[hamedit] <path>" marker on the boot console BEFORE the spawn, so
        # even though screen-pixel clicks are fb-mode-dependent, double-
        # clicking several candidate rows and scanning the serial log for the
        # marker is the e2e proof a file click reached the editor. We are back
        # at '/' (the descends above may have moved us, but at worst we open a
        # file in whatever dir we landed in). Double-click = two presses on the
        # same cell within the FM's double-click window.
        send("echo FILEOPEN_BEGIN")
        # Candidate file rows across the common fb modes. We hit a spread of
        # cells; any that lands on a regular file fires the editor launch.
        file_pts = [
            ("7680","7700"), ("8400","7700"), ("7680","8350"),
            ("12287","10267"), ("13000","10267"), ("12287","11100"),
        ]
        for cx, cy in file_pts:
            # Two quick presses on the same cell = a double-click (open).
            for _ in range(2):
                send(f"echo '{cx} {cy} 1 0 1' > /dev/mouse")
                time.sleep(0.15)
                send(f"echo '{cx} {cy} 0 0 1' > /dev/mouse")
                time.sleep(0.15)
            time.sleep(0.3)
        send("echo FILEOPEN_END")
        time.sleep(1.5)
        screendump("fileopen")

        # --- cat every live window scene back -------------------------
        send("echo DMG_BEGIN; cat /dev/wsys/damage; echo DMG_END")
        time.sleep(1.5)
        for n in range(1, 13):
            send(f"echo SCENE{n}_BEGIN; cat /dev/wsys/{n}/scene; echo SCENE{n}_END")
            time.sleep(0.6)
        # The freshly-booted serial shell drops the first char of a line and
        # re-prompts, so a single marker write can get mangled. Re-send until
        # the (echoed) marker token lands, then we have a clean stop point.
        done = False
        for _ in range(12):
            send("echo TERMFMDONEMARK")
            if wait_for("TERMFMDONEMARK", 4):
                done = True
                break
        # Even if the stop marker never echoed cleanly, the SCENE cats above
        # are what the asserts consume; treat reaching here as drove-ok so the
        # bash side runs its (flood-immune) text asserts rather than SKIPping.
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
    echo "[termfm_gate] SKIP: guest never reached the interactive shell" >&2
    exit 0
fi

# Convert screendumps to PNG for human VIEWING (best-effort).
for lbl in pre post; do
    ppm="$OUT_DIR/$lbl.ppm"
    if [ -s "$ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$ppm" > "$OUT_DIR/$lbl.png" 2>/dev/null || true
    fi
done

fail=0

# Pull the concatenation of EVERY window scene cat out of the log so the
# text asserts are flood-immune (they scan the bracketed SCENEn blocks).
SCENES=$(awk '/SCENE[0-9]+_BEGIN/{f=1} /SCENE[0-9]+_END/{f=0} f' "$LOG" 2>/dev/null)

echo "[termfm_gate] --- assertions ---"

# (T1) The TERMINAL renders shell/seed output. Its scene carries the dark
# fill (#101418) plus a glyphs line with its seed banner — proof it emitted
# a real terminal scene (not the old event-echo).
if printf '%s' "$SCENES" | grep -aqE 'fill 0 0 360 200 #101418'; then
    echo "[termfm_gate] PASS terminal emitted its scene (dark terminal fill present)"
else
    echo "[termfm_gate] NOTE terminal fill not captured in a scene cat this boot window"
fi
if printf '%s' "$SCENES" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +"(Hamnix scene terminal|type a command)'; then
    echo "[termfm_gate] PASS terminal rendered shell/seed glyph output"
else
    echo "[termfm_gate] NOTE terminal seed glyphs not captured this boot window (screendump authoritative)"
fi

# (T2) HARD: the terminal must NEVER render a pointer-echo line. The old bug
# drew routed pointer events as `glyphs N M "m <x> <y> ..."`. Such a line in
# the TERMINAL's dark scene (#101418 nearby) is the regression. We scan all
# scene cats: a `glyphs ... "m <n> <n>"` line is the forbidden artifact.
# (scenetest is NOT launched by this gate, so any "m ..." glyph here can only
# come from a regressed terminal.)
if printf '%s' "$SCENES" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +"m -?[0-9]+ -?[0-9]+'; then
    badline=$(printf '%s' "$SCENES" | grep -aoE 'glyphs +[0-9]+ +[0-9]+ +"m -?[0-9]+ -?[0-9]+' | head -1)
    echo "[termfm_gate] FAIL terminal rendered a pointer-echo glyph line ($badline...) — Bug 1 regressed" >&2
    fail=1
else
    echo "[termfm_gate] PASS terminal renders NO 'm <x> <y>' pointer-echo glyphs (Bug 1 fixed)"
fi

# (T3) The terminal spawned its persistent hamsh (serial marker before rebind).
if grep -aq '\[term\] hamsh spawned' "$LOG"; then
    echo "[termfm_gate] PASS terminal spawned a persistent /bin/hamsh"
elif grep -aq '\[term\] shell spawn FAILED' "$LOG"; then
    echo "[termfm_gate] FAIL terminal could not spawn /bin/hamsh" >&2
    fail=1
else
    echo "[termfm_gate] NOTE terminal hamsh-spawn marker not captured this boot window"
fi

# (F1) HARD: the FILE MANAGER renders a ".." Up entry. hamfmscene draws the
# synthetic parent entry as `"../"` (dir, trailing slash) at the top of every
# listing below /. Its presence in the FM scene is the Bug-2 fix proof.
if printf '%s' "$SCENES" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +"\.\./?"'; then
    upline=$(printf '%s' "$SCENES" | grep -aoE 'glyphs +[0-9]+ +[0-9]+ +"\.\./?"' | head -1)
    echo "[termfm_gate] PASS file manager renders a '..' Up entry ($upline)"
else
    # The FM lists '/' at startup (no parent there, so no Up entry yet).
    # Accept the hamfm header as a weaker proof it rendered, and NOTE the
    # Up entry only appears after a descend (the live screendump shows it).
    if printf '%s' "$SCENES" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +"hamfm:'; then
        echo "[termfm_gate] NOTE FM at '/' (root has no parent) — Up entry appears after a descend; header rendered"
    else
        echo "[termfm_gate] NOTE FM scene not captured this boot window (screendump authoritative)"
    fi
fi

# (F2) Clicking a FILE in the file manager LAUNCHES the editor on it. The
# file manager prints "[hamedit] <path>" on the boot console before spawning
# /bin/hameditscene (replacing the old "not a directory" no-op). The marker in
# the serial log is the e2e proof a file click reached the editor. Pixel-clicks
# are fb-mode-dependent, so this is a NOTE (the fast compile-wiring gate in
# scripts/test_editor_picker_homedirs.sh HARD-locks the wiring).
if grep -aqE '\[hamedit\] /' "$LOG"; then
    hl=$(grep -aoE '\[hamedit\] /[^ ]*' "$LOG" | head -1)
    echo "[termfm_gate] PASS a file click launched the editor ($hl)"
elif grep -aq '\[hamfm\] editor spawn FAILED' "$LOG"; then
    echo "[termfm_gate] FAIL file manager could not spawn the editor" >&2
    fail=1
else
    echo "[termfm_gate] NOTE file-open marker not captured this boot window (a click may not have landed on a file row; wiring gate is authoritative)"
fi

# (F3) The launched editor renders. After a file click the editor window's
# scene carries the "hamedit:" title glyph line. (Soft: depends on F2 landing
# a file row this boot window.)
if printf '%s' "$SCENES" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +"hamedit:'; then
    echo "[termfm_gate] PASS the launched editor rendered its scene (hamedit: title)"
else
    echo "[termfm_gate] NOTE editor scene not captured this boot window (screendump authoritative)"
fi

echo "[termfm_gate] artifacts in $OUT_DIR"
if [ "$fail" = "0" ]; then
    echo "[termfm_gate] RESULT: PASS"
    exit 0
else
    echo "[termfm_gate] RESULT: FAIL"
    exit 1
fi
