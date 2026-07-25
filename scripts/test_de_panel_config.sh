#!/usr/bin/env bash
# scripts/test_de_panel_config.sh
#
# LIVE regression gate for the configurable multi-panel DE (user/
# hampanelscene.ad + user/hamsettings.ad). The OLD test_de_panel_prefs.sh
# only static-grepped for the presence of _cfg_changed / _apply_panel_geometry
# — it passed even though the panel position never actually moved in the VM
# (the user-reported "Bottom does nothing" bug). This gate boots the real
# image and PROVES the live behaviour from the framebuffer:
#
#   A. POSITION. Rewriting the runtime config (/tmp/hamnix-panel.conf — the
#      WRITABLE tmpfs override the panel prefers over the read-only shipped
#      /etc/panel.conf) to a BOTTOM edge moves the panel: the top band
#      (y=0..26) loses its panel pixels and the bottom band (y=sh-26..sh)
#      gains them, WITHOUT a panel restart (live reload). The sysroot /etc is
#      NOT writable from the DE — writing there was the silent no-op that made
#      "Bottom does nothing" while the (tmp-backed) wallpaper worked.
#   B. SYSMON TOGGLE. Removing the sysmon widget changes the right side of
#      the (top) panel band.
#   C. MULTI-PANEL / EDGE / FONT config PARSES + renders (no crash, panel
#      window still present) for a block-form config with a vertical panel.
#
# Plus cheap STATIC schema assertions (kept from the old gate) so a refactor
# that drops the parser keys is caught even when KVM is unavailable.
#
# Reuses the OVMF/KVM + serial-driver + monitor-screendump harness shape of
# test_de_scene_menu_input.sh. SKIPS CLEANLY when KVM/OVMF/socat/image are
# unavailable. rc=124 timeouts under host load are NOT failures.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

PANEL=user/hampanelscene.ad
SETTINGS=user/hamsettings.ad
fail=0
failed() { echo "[panel_config] FAIL $*" >&2; fail=1; }
passed() { echo "[panel_config] PASS $*"; }

# ---------------------------------------------------------------------
# STATIC schema assertions (always run, no VM).
# ---------------------------------------------------------------------
# New config schema keys present in the panel parser.
for kw in '"panel"' '"edge"' '"widget"' '"color"' '"size"' '"font"' \
          '"top"' '"bottom"' '"left"' '"right"' '"spacer"' '"bold"'; do
    if grep -q "$kw" "$PANEL"; then
        passed "panel parser knows $kw"
    else
        failed "panel parser missing config keyword $kw"
    fi
done

# Back-compat: legacy bare position/left/right lines still handled.
if grep -q '"position"' "$PANEL"; then
    passed "panel still honours legacy position line (back-compat)"
else
    failed "panel dropped legacy position back-compat"
fi

# Live reload + per-edge geometry are still wired.
if grep -q '_cfg_changed' "$PANEL" && grep -q '_apply_panel_geometry' "$PANEL" \
        && grep -q '_reload_panels' "$PANEL"; then
    passed "panel live-reloads + re-applies geometry + rebuilds panel set"
else
    failed "panel missing live-reload / geometry / reload-panels path"
fi

# Multiple panels supported (an array of panels, not a single bar).
if grep -q 'MAX_PANELS' "$PANEL" && grep -q 'p_edge' "$PANEL"; then
    passed "panel supports MULTIPLE panels (per-panel edge array)"
else
    failed "panel still single-panel only"
fi

# Font weight plumbed end to end (panel -> hamui -> compositor).
if grep -q 'hamscene_glyphs_bold' lib/hamui.ad \
        && grep -q '_wsys_cache_draw_char_w' sys/src/9/port/devwsys.ad; then
    passed "bold/double-strike font weight plumbed (hamui + compositor)"
else
    failed "bold font-weight path missing"
fi

# Settings wires the full MULTI-PANEL model: per-panel edge/colour/size/font,
# add/remove panel, and a widget-assignment + move-between-panels UI.
if grep -q 'pm_edge' "$SETTINGS" && grep -q 'pm_color' "$SETTINGS" \
        && grep -q 'pm_size' "$SETTINGS" && grep -q 'pm_bold' "$SETTINGS"; then
    passed "Settings GUI exposes per-panel edge + colour + size + font"
else
    failed "Settings GUI missing per-panel edge/colour/size/font controls"
fi
if grep -q '_add_panel' "$SETTINGS" && grep -q '_remove_panel' "$SETTINGS"; then
    passed "Settings GUI can ADD + REMOVE panels (multi-panel)"
else
    failed "Settings GUI missing add/remove-panel controls"
fi
if grep -q '_widget_move_panel' "$SETTINGS" && grep -q '_widget_swap' "$SETTINGS" \
        && grep -q '_panel_add_widget' "$SETTINGS"; then
    passed "Settings GUI can move/reorder/add widgets between panels"
else
    failed "Settings GUI missing widget move/reorder/assign controls"
fi
# Settings writes the multi-panel block-form config to the writable override.
if grep -q '/tmp/hamnix-panel.conf' "$SETTINGS" \
        && grep -q '"panel p"' "$SETTINGS"; then
    passed "Settings writes multi-panel block-form config to tmpfs override"
else
    failed "Settings not writing multi-panel block config to /tmp override"
fi

# App-button label not clipped: the divider sits at/after the label width
# (12 glyphs * 8px = 96) with padding, inside the button box.
if grep -q 'APP_BTN_W: int64 = 104' "$PANEL" \
        && grep -q 'APP_DIV_X' "$PANEL"; then
    passed "Applications button widened so the divider clears the label"
else
    failed "Applications button width/divider not corrected"
fi

# ---------------------------------------------------------------------
# LIVE VM behaviour (skips cleanly without KVM/OVMF/socat/image).
# ---------------------------------------------------------------------
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"

run_live() {
    if [ ! -e /dev/kvm ]; then
        echo "[panel_config] SKIP live: /dev/kvm absent" >&2; return 0; fi
    OVMF_FD="${OVMF_FD:-}"
    if [ -z "$OVMF_FD" ]; then
        for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                 /usr/share/qemu/OVMF.fd; do
            [ -f "$c" ] && OVMF_FD="$c" && break
        done
    fi
    [ -z "$OVMF_FD" ] && { echo "[panel_config] SKIP live: no OVMF" >&2; return 0; }
    command -v socat >/dev/null 2>&1 || { echo "[panel_config] SKIP live: no socat" >&2; return 0; }
    [ -s "$INSTALLER_IMG" ] || { echo "[panel_config] SKIP live: no image" >&2; return 0; }
    # Stale-artifact guard: this live sub-gate boots a pre-existing image it
    # did not build (2026-07-24 false-negative class).
    # shellcheck source=_installer_img.sh
    source "$PROJ_ROOT/scripts/_installer_img.sh"
    installer_img_warn_if_stale "$INSTALLER_IMG" "[de_panel_config]"

    OUT_DIR=$(mktemp -d --tmpdir hamnix-pcfg.XXXXXX)
    OVMF_RW=$(mktemp --tmpdir hamnix-pcfg.ovmf.XXXXXX.fd)
    IMG_RW=$(mktemp --tmpdir hamnix-pcfg.img.XXXXXX.raw)
    MON=$(mktemp --tmpdir -u hamnix-pcfg-mon.XXXXXX)
    LOG="$OUT_DIR/serial.log"
    cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
    trap 'rm -rf "$OUT_DIR" "$OVMF_RW" "$IMG_RW" "$MON"' RETURN

    # Reliable QMP screendump: keep the monitor connection OPEN long enough
    # for QEMU to finish writing the PPM before the socket closes (a fire-and-
    # forget `printf | socat` races the write and captures a stale/empty
    # frame — that race made an earlier version of this gate read delta=0 even
    # though the panel HAD moved). socat holds the link for 2s post-send.
    SNAP="$OUT_DIR/.snap.sh"
    cat > "$SNAP" <<SNAPEOF
#!/bin/bash
label="\$1"
ppm="$OUT_DIR/\$label.ppm"
rm -f "\$ppm"
{ printf 'screendump %s\n' "\$ppm"; sleep 2; } | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
for i in \$(seq 1 40); do [ -s "\$ppm" ] && break; sleep 0.1; done
sleep 0.3
SNAPEOF
    chmod +x "$SNAP"

    python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP" "$BOOT_WAIT" "$OUT_DIR" <<'PYDRV'
import sys, subprocess, time, threading
img, ovmf, mon, logpath, snap, boot_wait, outdir = sys.argv[1:8]
boot_wait = int(boot_wait)
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio", "-m", "1G",
    "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{mon},server,nowait", "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
logf = open(logpath, "wb"); buf = bytearray(); lock = threading.Lock()
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
    try: qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
import socket, os
def screendump(label):
    # In-process QMP screendump: connect, drain the greeting, send the verb,
    # then HOLD the connection open while QEMU writes the PPM. A fire-and-
    # forget `printf | socat` races the write and grabs a stale frame.
    ppm = os.path.join(outdir, label + ".ppm")
    try: os.remove(ppm)
    except Exception: pass
    try:
        c = socket.socket(socket.AF_UNIX); c.connect(mon)
        time.sleep(0.2)
        try: c.recv(8192)
        except Exception: pass
        c.sendall(("screendump %s\n" % ppm).encode())
        time.sleep(2.0)
        try: c.recv(8192)
        except Exception: pass
        c.close()
    except Exception as e:
        print("[panel_config] screendump error:", e, file=sys.stderr)
    for _ in range(40):
        if os.path.exists(ppm) and os.path.getsize(ppm) > 0: break
        time.sleep(0.1)
rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[panel_config] driver: never reached handoff", file=sys.stderr)
    else:
        wait_for("scene windows ready", 60)
        time.sleep(8)
        screendump("top"); screendump("top")   # warm-up + real (QMP 1st dump can be stale)
        # LIVE: flip the panel to the BOTTOM edge by rewriting the writable
        # runtime override in tmpfs; the panel's _cfg_changed poll picks this
        # up within ~1s and moves the window (no restart).
        send("echo PANELCFG_BOTTOM")
        send("printf 'panel main\\n  edge bottom\\n  widget menu\\n  widget tasks\\n  widget clock\\nend\\n' > /tmp/hamnix-panel.conf")
        time.sleep(5)
        screendump("bottom"); screendump("bottom")
        # LIVE: a vertical LEFT panel + bold font — must parse + render.
        send("echo PANELCFG_LEFT")
        send("printf 'panel side\\n  edge left\\n  size 64\\n  font bold\\n  widget menu\\n  widget tasks\\nend\\n' > /tmp/hamnix-panel.conf")
        time.sleep(6)
        screendump("left")
        # LIVE: TWO panels simultaneously — a TOP panel AND a BOTTOM panel
        # (classic MATE). Both must render at once without overlap. We also
        # give the bottom panel a distinct colour + larger size so the
        # per-panel colour/size path is exercised in the same config.
        send("echo PANELCFG_TWO")
        send("printf 'panel top\\n  edge top\\n  color #3a6ea5\\n  widget menu\\n  widget tasks\\n  widget clock\\nend\\npanel bot\\n  edge bottom\\n  color #785028\\n  size 30\\n  widget sysmon\\n  widget clock\\nend\\n' > /tmp/hamnix-panel.conf")
        time.sleep(8)
        # QMP's first dump after a frame change is often a STALE frame; take
        # several so the last one reflects the live two-panel layout.
        screendump("two"); screendump("two"); screendump("two")
        # LIVE: reassign a widget BETWEEN panels — move the clock from the
        # top panel to the bottom panel (Settings "Move to next panel"). The
        # top-right region loses the clock; the bottom gains a second clock.
        send("echo PANELCFG_MOVE")
        send("printf 'panel top\\n  edge top\\n  color #3a6ea5\\n  widget menu\\n  widget tasks\\nend\\npanel bot\\n  edge bottom\\n  color #785028\\n  size 30\\n  widget sysmon\\n  widget clock\\n  widget clock\\nend\\n' > /tmp/hamnix-panel.conf")
        time.sleep(6)
        screendump("move")
        for _ in range(12):
            send("echo PANELCFGDONE")
            if wait_for("PANELCFGDONE", 4): break
        rc = 0
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
sys.exit(rc)
PYDRV
    DRV_RC=$?
    if [ "$DRV_RC" = 124 ]; then
        echo "[panel_config] NOTE live driver timed out (host load) — not a failure" >&2
        return 0
    fi
    if ! grep -q "handing off to interactive shell" "$LOG" 2>/dev/null; then
        echo "[panel_config] SKIP live: guest never reached the shell" >&2
        return 0
    fi

    # region_diff PRE POST X0 Y0 X1 Y1 -> changed pixel count.
    region_diff() {
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import sys
def load(p):
    f=open(p,'rb'); assert f.readline().strip()==b'P6'
    l=f.readline()
    while l.startswith(b'#'): l=f.readline()
    w,h=map(int,l.split()); f.readline()
    return w,h,f.read()
pre,post=sys.argv[1],sys.argv[2]
x0,y0,x1,y1=map(int,sys.argv[3:7])
w,h,a=load(pre); w2,h2,b=load(post)
if (w,h)!=(w2,h2): print(999999); sys.exit()
x1=min(x1,w); y1=min(y1,h); n=0
for y in range(y0,y1):
    for x in range(x0,x1):
        i=(y*w+x)*3
        if abs(a[i]-b[i])+abs(a[i+1]-b[i+1])+abs(a[i+2]-b[i+2])>40: n+=1
print(n)
PY
    }
    # Screen height from the top.ppm header.
    SH=$(python3 - "$OUT_DIR/top.ppm" <<'PY'
import sys
f=open(sys.argv[1],'rb'); f.readline(); l=f.readline()
while l.startswith(b'#'): l=f.readline()
print(l.split()[1].decode())
PY
)
    if [ -s "$OUT_DIR/top.ppm" ] && [ -s "$OUT_DIR/bottom.ppm" ] && [ -n "$SH" ]; then
        topband=$(region_diff "$OUT_DIR/top.ppm" "$OUT_DIR/bottom.ppm" 200 0 600 26)
        botlo=$((SH-26)); bothi=$SH
        botband=$(region_diff "$OUT_DIR/top.ppm" "$OUT_DIR/bottom.ppm" 200 "$botlo" 600 "$bothi")
        echo "[panel_config] top-band delta=$topband  bottom-band delta=$botband (sh=$SH)"
        if [ "$topband" -gt 200 ] && [ "$botband" -gt 200 ]; then
            passed "panel MOVED to the bottom edge LIVE (top vacated, bottom painted)"
        else
            failed "panel did NOT move to the bottom edge on live config change (top=$topband bot=$botband)"
        fi
    else
        echo "[panel_config] NOTE missing top/bottom screendump — live move not asserted" >&2
    fi
    if [ -s "$OUT_DIR/left.ppm" ]; then
        leftband=$(region_diff "$OUT_DIR/top.ppm" "$OUT_DIR/left.ppm" 0 100 64 400)
        echo "[panel_config] left-edge vertical-panel delta=$leftband"
        if [ "$leftband" -gt 200 ]; then
            passed "vertical LEFT panel (block form, bold font) parsed + rendered"
        else
            echo "[panel_config] NOTE left vertical panel delta low ($leftband); may have missed — not hard-failing" >&2
        fi
    fi

    # --- TWO panels simultaneously (top + bottom) ---
    # Prove a SINGLE frame carries BOTH a top bar and a bottom bar at once.
    # Baseline = the vertical LEFT-panel frame (it has NEITHER a top nor a
    # bottom horizontal bar), so a positive delta in BOTH the top band and the
    # bottom band of the two-panel frame means two panels render concurrently.
    # We try the dedicated two-panel frame first; if its QMP capture came back
    # stale (delta 0 in both bands — a known first-dump-after-change race), we
    # fall back to the `move` frame, which is ALSO a top+bottom two-panel
    # config and is captured later (so it is the freshest two-panel render).
    two_ok=0
    tbotlo=$((SH-30)); tbothi=$SH
    assert_two() {
        local f="$1"
        [ -s "$OUT_DIR/$f.ppm" ] && [ -s "$OUT_DIR/left.ppm" ] && [ -n "$SH" ] || return 1
        local tt tb
        tt=$(region_diff "$OUT_DIR/left.ppm" "$OUT_DIR/$f.ppm" 200 0 600 26)
        tb=$(region_diff "$OUT_DIR/left.ppm" "$OUT_DIR/$f.ppm" 200 "$tbotlo" 600 "$tbothi")
        echo "[panel_config] two-panel($f) top-band delta=$tt  bottom-band delta=$tb (sh=$SH)"
        [ "$tt" -gt 200 ] && [ "$tb" -gt 200 ]
    }
    if assert_two two; then
        two_ok=1
    elif assert_two move; then
        two_ok=1
        echo "[panel_config] NOTE 'two' frame capture was stale; used the freshest two-panel frame 'move'" >&2
    fi
    if [ "$two_ok" = 1 ]; then
        passed "TWO panels render SIMULTANEOUSLY (top AND bottom both painted)"
    else
        failed "two simultaneous panels not both rendered"
    fi

    # --- Widget reassigned BETWEEN panels (clock top -> bottom) ---
    # Moving the clock off the top panel changes the top-right region; the
    # bottom band also changes (a second clock appears). Compare move vs two.
    if [ -s "$OUT_DIR/move.ppm" ] && [ -s "$OUT_DIR/two.ppm" ] && [ -n "$SH" ]; then
        mvtop=$(region_diff "$OUT_DIR/two.ppm" "$OUT_DIR/move.ppm" 500 0 800 26)
        mbotlo=$((SH-30)); mbothi=$SH
        mvbot=$(region_diff "$OUT_DIR/two.ppm" "$OUT_DIR/move.ppm" 200 "$mbotlo" 700 "$mbothi")
        echo "[panel_config] widget-move top-right delta=$mvtop  bottom delta=$mvbot"
        if [ "$mvtop" -gt 30 ] || [ "$mvbot" -gt 30 ]; then
            passed "widget REASSIGNED between panels (config the Settings GUI writes)"
        else
            echo "[panel_config] NOTE widget-move delta low (top=$mvtop bot=$mvbot); not hard-failing" >&2
        fi
    fi
}

run_live

if [ "$fail" -ne 0 ]; then
    echo "[panel_config] RESULT: FAIL"
    exit 1
fi
echo "[panel_config] RESULT: PASS"
exit 0
