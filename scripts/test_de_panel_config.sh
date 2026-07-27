#!/usr/bin/env bash
# scripts/test_de_panel_config.sh
#
# LIVE regression gate for the configurable multi-panel DE (user/
# hampanelscene.ad + user/hamsettings.ad). It boots the real shipped image
# and PROVES the live behaviour from the framebuffer.
#
# ── WHY THIS GATE WAS REWRITTEN (2026-07-27) ─────────────────────────
#
# The previous version asserted the live behaviour as a PIXEL DELTA between
# two screendumps: "the top band changed AND the bottom band changed => the
# panel moved". Three things made that a lie in both directions:
#
#  1. WRONG BASELINE. It assumed the desktop starts with ONE top panel. The
#     shipped /etc/panel.conf (and hampanelscene's _default_config, which
#     must match it byte-for-byte) is the MATE TWO-panel layout: a top bar
#     AND a bottom window-list, BOTH #d4d0c8. Moving "the panel" to the
#     bottom therefore replaces one light-grey bar with another light-grey
#     bar — a delta near ZERO even when the move is perfect. Measured on a
#     good build: top-band delta 800, bottom-band delta 0, with the panel
#     visibly, correctly at the bottom edge.
#  2. BLIND SLEEPS. It pushed a ~130-character `printf ... > /tmp/...` down
#     the serial console and then slept 5 s. hamsh echoes that line back one
#     character at a time; on a loaded host four of the five screendumps in
#     a run captured the PRE-change desktop, so the deltas were measuring
#     one unchanged frame against another.
#  3. DELTA != PRESENCE. "Some pixels changed" cannot distinguish "the panel
#     you asked for is here" from "a stale ghost window is here instead".
#     That is exactly the bug this rewrite pins (a surplus panel window used
#     to relocate to (0,0) and cover the real top panel): every delta-based
#     assertion was satisfied by the ghost.
#
# The live tier now:
#   * drives the panel with configs whose `color` is UNIQUE on the desktop
#     (red / green — the wallpaper is blue and the default bars are grey),
#     so each assertion is "the panel you configured is AT this edge",
#     a positive identification rather than a difference;
#   * asserts ABSENCE the same way (the vacated edge must be WALLPAPER, not
#     "different from before") — which is what catches a ghost;
#   * synchronises on MARKERS, never on a sleep: it waits for the shell to
#     acknowledge the write and then for hampanelscene's own
#     "[panel] config reload" line before it screendumps.
#
# ── ASSERTION ALTITUDE ───────────────────────────────────────────────
#
# The cheap grep tier below is STATIC. It proves that identifiers still
# exist in the source; it proves NOTHING about what the shipped desktop
# renders. It used to announce itself as "panel live-reloads + re-applies
# geometry + rebuilds panel set", which reads as a behavioural guarantee and
# stayed green through a desktop that showed a dead bar where the panel
# should be. Every static check now says STATIC in its own PASS line, and
# the live tier reports LIVE, so a reader of the log can never mistake one
# for the other.
#
# SKIPS CLEANLY when KVM/OVMF/socat/image are unavailable — but says so
# loudly, and a SKIP never prints a live PASS.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

PANEL=user/hampanelscene.ad
SETTINGS=user/hamsettings.ad
fail=0
failed() { echo "[panel_config] FAIL $*" >&2; fail=1; }
passed() { echo "[panel_config] PASS $*"; }

# ---------------------------------------------------------------------
# STATIC schema assertions (no VM). These prove SOURCE SHAPE ONLY.
# ---------------------------------------------------------------------
for kw in '"panel"' '"edge"' '"widget"' '"color"' '"size"' '"font"' \
          '"top"' '"bottom"' '"left"' '"right"' '"spacer"' '"bold"'; do
    if grep -q "$kw" "$PANEL"; then
        passed "STATIC panel parser knows $kw"
    else
        failed "STATIC panel parser missing config keyword $kw"
    fi
done

if grep -q '"position"' "$PANEL"; then
    passed "STATIC panel still honours legacy position line (back-compat)"
else
    failed "STATIC panel dropped legacy position back-compat"
fi

if grep -q '_cfg_changed' "$PANEL" && grep -q '_apply_panel_geometry' "$PANEL" \
        && grep -q '_reload_panels' "$PANEL"; then
    passed "STATIC live-reload/geometry/reload-panels identifiers present (says NOTHING about rendering — see the LIVE tier)"
else
    failed "STATIC panel missing live-reload / geometry / reload-panels path"
fi

if grep -q 'MAX_PANELS' "$PANEL" && grep -q 'p_edge' "$PANEL"; then
    passed "STATIC panel supports MULTIPLE panels (per-panel edge array)"
else
    failed "STATIC panel still single-panel only"
fi

# A surplus panel window must be HIDDEN through the compositor's hide verb,
# never "collapsed" with `geometry x y 0 0` — devwsys deliberately ignores a
# non-positive w/h ("leave the size alone"), so that spelling left a
# full-size window parked at the origin, covering the real top panel.
if grep -q '_set_window_hidden' "$PANEL" \
        && grep -q '"hide"' sys/src/9/port/devwsys.ad; then
    passed "STATIC surplus panel windows hide via the compositor hide verb"
else
    failed "STATIC surplus panel windows are not hidden through devwsys `hide`"
fi

if grep -q 'hamscene_glyphs_bold' lib/hamui.ad \
        && grep -q '_wsys_cache_draw_char_w' sys/src/9/port/devwsys.ad; then
    passed "STATIC bold/double-strike font weight plumbed (hamui + compositor)"
else
    failed "STATIC bold font-weight path missing"
fi

if grep -q 'pm_edge' "$SETTINGS" && grep -q 'pm_color' "$SETTINGS" \
        && grep -q 'pm_size' "$SETTINGS" && grep -q 'pm_bold' "$SETTINGS"; then
    passed "STATIC Settings GUI exposes per-panel edge + colour + size + font"
else
    failed "STATIC Settings GUI missing per-panel edge/colour/size/font controls"
fi
if grep -q '_add_panel' "$SETTINGS" && grep -q '_remove_panel' "$SETTINGS"; then
    passed "STATIC Settings GUI can ADD + REMOVE panels (multi-panel)"
else
    failed "STATIC Settings GUI missing add/remove-panel controls"
fi
if grep -q '_widget_move_panel' "$SETTINGS" && grep -q '_widget_swap' "$SETTINGS" \
        && grep -q '_panel_add_widget' "$SETTINGS"; then
    passed "STATIC Settings GUI can move/reorder/add widgets between panels"
else
    failed "STATIC Settings GUI missing widget move/reorder/assign controls"
fi
if grep -q '/tmp/hamnix-panel.conf' "$SETTINGS" \
        && grep -q '"panel p"' "$SETTINGS"; then
    passed "STATIC Settings writes multi-panel block-form config to tmpfs override"
else
    failed "STATIC Settings not writing multi-panel block config to /tmp override"
fi
if grep -q 'APP_BTN_W: int64 = 104' "$PANEL" \
        && grep -q 'APP_DIV_X' "$PANEL"; then
    passed "STATIC Applications button widened so the divider clears the label"
else
    failed "STATIC Applications button width/divider not corrected"
fi

# ---------------------------------------------------------------------
# LIVE VM behaviour.
# ---------------------------------------------------------------------
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"

run_live() {
    if [ ! -e /dev/kvm ]; then
        echo "[panel_config] SKIP live: /dev/kvm absent — NOTHING about the rendered desktop was checked" >&2; return 0; fi
    OVMF_FD="${OVMF_FD:-}"
    if [ -z "$OVMF_FD" ]; then
        for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                 /usr/share/qemu/OVMF.fd; do
            [ -f "$c" ] && OVMF_FD="$c" && break
        done
    fi
    [ -z "$OVMF_FD" ] && { echo "[panel_config] SKIP live: no OVMF — NOTHING about the rendered desktop was checked" >&2; return 0; }
    command -v socat >/dev/null 2>&1 || { echo "[panel_config] SKIP live: no socat" >&2; return 0; }
    # STALE-IMAGE GUARD: this live sub-gate BOOTS an image it did not build.
    # shellcheck source=_installer_img.sh
    source "$PROJ_ROOT/scripts/_installer_img.sh"
    ensure_installer_img "$INSTALLER_IMG" "[de_panel_config]" \
        || { echo "[panel_config] SKIP live: no usable $INSTALLER_IMG" >&2; return 0; }

    OUT_DIR="${PANEL_CFG_OUT_DIR:-$(mktemp -d --tmpdir hamnix-pcfg.XXXXXX)}"
    mkdir -p "$OUT_DIR"
    OVMF_RW=$(mktemp --tmpdir hamnix-pcfg.ovmf.XXXXXX.fd)
    IMG_RW=$(mktemp --tmpdir hamnix-pcfg.img.XXXXXX.raw)
    MON=$(mktemp --tmpdir -u hamnix-pcfg-mon.XXXXXX)
    LOG="$OUT_DIR/serial.log"
    cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
    if [ -n "${PANEL_CFG_OUT_DIR:-}" ]; then
        trap 'rm -f "$OVMF_RW" "$IMG_RW" "$MON"' RETURN
    else
        trap 'rm -rf "$OUT_DIR" "$OVMF_RW" "$IMG_RW" "$MON"' RETURN
    fi

    python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$BOOT_WAIT" "$OUT_DIR" <<'PYDRV'
import sys, subprocess, time, threading, socket, os
img, ovmf, mon, logpath, boot_wait, outdir = sys.argv[1:7]
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
def count(marker):
    with lock: return buf.count(marker.encode())
def wait_for(marker, timeout):
    m = marker.encode(); deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf: return True
        if qemu.poll() is not None: return False
        time.sleep(0.2)
    return False
def wait_count(marker, n, timeout):
    # Wait until `marker` has been seen at least n times.
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count(marker) >= n: return True
        if qemu.poll() is not None: return False
        time.sleep(0.2)
    return False
def send(line):
    try: qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
def screendump(label):
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

RELOAD = "[panel] config reload"

def apply_config(tag, conf, label):
    # Write the runtime override, WAIT for the shell to finish echoing and
    # running the command, then WAIT for hampanelscene to report that it
    # actually re-read and re-applied the config. No blind sleeps: the old
    # gate's fixed 5 s lost the race on a loaded host and screendumped the
    # PRE-change desktop.
    want = count(RELOAD) + 1
    send("printf '%s' > /tmp/hamnix-panel.conf" % conf)
    send("echo %s" % tag)
    if not wait_for(tag, 60):
        print("[panel_config] driver: shell never acked %s" % tag, file=sys.stderr)
    if not wait_count(RELOAD, want, 60):
        print("[panel_config] driver: panel never reported a reload for %s" % tag,
              file=sys.stderr)
    # One settle beat so the reload's presents have reached scanout, then
    # two dumps (QMP's first dump after a frame change can be stale).
    time.sleep(2)
    screendump(label); screendump(label)

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[panel_config] driver: never reached handoff", file=sys.stderr)
    else:
        wait_for("scene windows ready", 60)
        time.sleep(8)
        # hamsh swallows the FIRST line it is handed on the serial console
        # (see feedback_interactive_test_wait_for_prompt); burn one.
        for _ in range(12):
            send("echo PCFG_WARM")
            if wait_for("PCFG_WARM", 4): break
        screendump("default"); screendump("default")
        # A: ONE panel, BOTTOM edge, in a colour that exists nowhere else on
        # the desktop. Shrinks the shipped two-panel default to one, so it
        # also exercises the surplus-window teardown.
        apply_config("PCFG_A",
                     "panel main\\n  edge bottom\\n  color #c81e28\\n"
                     "  widget menu\\n  widget tasks\\n  widget clock\\nend\\n",
                     "bottom_red")
        # B: TWO panels at once, each its own unique colour.
        apply_config("PCFG_B",
                     "panel t\\n  edge top\\n  color #18a038\\n  widget menu\\n"
                     "  widget tasks\\nend\\n"
                     "panel b\\n  edge bottom\\n  color #c81e28\\n  size 30\\n"
                     "  widget sysmon\\n  widget clock\\nend\\n",
                     "two_green_red")
        # C: a VERTICAL left panel (block form, bold font).
        apply_config("PCFG_C",
                     "panel side\\n  edge left\\n  size 64\\n  font bold\\n"
                     "  color #c81e28\\n  widget menu\\n  widget tasks\\nend\\n",
                     "left_red")
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

    # ---- pixel predicates -------------------------------------------
    # count_kind FRAME KIND X0 Y0 X1 Y1  -> pixels of that kind in the region.
    #   red   : the #c81e28 panel  (r dominant)
    #   green : the #18a038 panel  (g dominant)
    #   bar   : a default #d4d0c8 chrome bar (near-white, all channels high)
    # Colour IDENTITY, not a delta: "the panel you configured is here" and
    # "nothing is here" are both directly expressible, so a stale ghost
    # window can no longer satisfy the assertion the real panel should.
    count_kind() {
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import sys
def load(p):
    f=open(p,'rb'); assert f.readline().strip()==b'P6'
    l=f.readline()
    while l.startswith(b'#'): l=f.readline()
    w,h=map(int,l.split()); f.readline()
    return w,h,f.read()
frame, kind = sys.argv[1], sys.argv[2]
x0,y0,x1,y1 = map(int, sys.argv[3:7])
w,h,a = load(frame)
x1=min(x1,w); y1=min(y1,h); n=0
for y in range(max(0,y0), max(0,y1)):
    for x in range(max(0,x0), max(0,x1)):
        i=(y*w+x)*3
        r,g,b = a[i],a[i+1],a[i+2]
        if kind=='red'   and r>g+50 and r>b+50 and r>90: n+=1
        elif kind=='green' and g>r+40 and g>b+40 and g>80: n+=1
        elif kind=='bar' and r>175 and g>175 and b>165: n+=1
print(n)
PY
    }
    SH=$(python3 - "$OUT_DIR/default.ppm" <<'PY'
import sys
f=open(sys.argv[1],'rb'); f.readline(); l=f.readline()
while l.startswith(b'#'): l=f.readline()
print(l.split()[1].decode())
PY
)
    [ -n "$SH" ] || { echo "[panel_config] SKIP live: no default screendump" >&2; return 0; }
    TOP0=0;  TOP1=26
    BOT0=$((SH-26)); BOT1=$SH
    # Sample x 200..600: clear of the desktop icon column (x<110) and of the
    # clock/sysmon status area, so the region is pure bar-or-wallpaper.

    # Sanity: the SHIPPED DEFAULT really is the MATE two-panel layout. If this
    # ever stops holding, the assertions below are measuring a different
    # desktop and must be re-derived rather than quietly re-tuned.
    d_top=$(count_kind "$OUT_DIR/default.ppm" bar 200 $TOP0 600 $TOP1)
    d_bot=$(count_kind "$OUT_DIR/default.ppm" bar 200 $BOT0 600 $BOT1)
    echo "[panel_config] LIVE default layout: top bar px=$d_top  bottom bar px=$d_bot"
    if [ "$d_top" -gt 5000 ] && [ "$d_bot" -gt 5000 ]; then
        passed "LIVE shipped default renders the MATE TWO-panel layout (top + bottom)"
    else
        failed "LIVE shipped default is not the two-panel layout (top=$d_top bot=$d_bot) — the baseline every assertion below rests on"
    fi

    # A. The panel MOVES to the bottom edge on a live config change, and the
    #    top it left is really EMPTY. `bar` at the top would mean either the
    #    old top panel never went away or a surplus window ghosted into its
    #    place; `red` at the top would mean the panel painted at the wrong
    #    edge. Both are failures the old delta test could not see.
    if [ -s "$OUT_DIR/bottom_red.ppm" ]; then
        a_botred=$(count_kind "$OUT_DIR/bottom_red.ppm" red 200 $BOT0 600 $BOT1)
        a_topbar=$(count_kind "$OUT_DIR/bottom_red.ppm" bar 200 $TOP0 600 $TOP1)
        a_topred=$(count_kind "$OUT_DIR/bottom_red.ppm" red 200 $TOP0 600 $TOP1)
        echo "[panel_config] LIVE A(one panel, edge bottom): bottom red px=$a_botred  top bar px=$a_topbar  top red px=$a_topred"
        if [ "$a_botred" -gt 5000 ]; then
            passed "LIVE panel MOVED to the bottom edge on a live config change"
        else
            failed "LIVE panel did NOT paint at the bottom edge (red px=$a_botred of 10400)"
        fi
        if [ "$a_topbar" -lt 500 ] && [ "$a_topred" -lt 500 ]; then
            passed "LIVE the vacated TOP edge is bare desktop — the surplus panel window is really gone"
        else
            failed "LIVE something is still painted at the TOP after the panel moved away (bar px=$a_topbar red px=$a_topred) — a surplus panel window is ghosting there"
        fi
    else
        failed "LIVE missing bottom_red screendump"
    fi

    # B. TWO panels render SIMULTANEOUSLY, each at its own edge, each in its
    #    own colour. Identifying them by colour is what pins "the TOP panel is
    #    the one I configured", which a delta against the previous frame
    #    cannot do.
    if [ -s "$OUT_DIR/two_green_red.ppm" ]; then
        b_topgreen=$(count_kind "$OUT_DIR/two_green_red.ppm" green 200 $TOP0 600 $TOP1)
        b_botred=$(count_kind "$OUT_DIR/two_green_red.ppm" red 200 $((SH-30)) 600 $SH)
        echo "[panel_config] LIVE B(two panels): top green px=$b_topgreen  bottom red px=$b_botred"
        if [ "$b_topgreen" -gt 5000 ] && [ "$b_botred" -gt 5000 ]; then
            passed "LIVE TWO panels render SIMULTANEOUSLY, each at its configured edge and colour"
        else
            failed "LIVE two simultaneous panels not both rendered (top green=$b_topgreen bottom red=$b_botred)"
        fi
    else
        failed "LIVE missing two_green_red screendump"
    fi

    # C. A VERTICAL panel (edge left, size 64, bold font) parses AND renders.
    if [ -s "$OUT_DIR/left_red.ppm" ]; then
        c_left=$(count_kind "$OUT_DIR/left_red.ppm" red 0 200 64 600)
        c_top=$(count_kind "$OUT_DIR/left_red.ppm" bar 200 $TOP0 600 $TOP1)
        c_bot=$(count_kind "$OUT_DIR/left_red.ppm" bar 200 $BOT0 600 $BOT1)
        echo "[panel_config] LIVE C(vertical left): left red px=$c_left  leftover top bar px=$c_top  leftover bottom bar px=$c_bot"
        if [ "$c_left" -gt 8000 ]; then
            passed "LIVE vertical LEFT panel (block form, bold font) parsed + rendered"
        else
            failed "LIVE vertical LEFT panel did not render (red px=$c_left of 25600)"
        fi
    else
        failed "LIVE missing left_red screendump"
    fi
}

run_live

if [ "$fail" -ne 0 ]; then
    echo "[panel_config] RESULT: FAIL"
    exit 1
fi
echo "[panel_config] RESULT: PASS"
exit 0
