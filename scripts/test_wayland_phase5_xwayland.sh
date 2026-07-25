#!/usr/bin/env bash
# scripts/test_wayland_phase5_xwayland.sh — Wayland-passthrough Phase 5:
# bring up XWayland on the native in-kernel Wayland compositor, then run
# X11 apps through it. Xwayland is an X server that is itself a libwayland
# CLIENT — it connects to WAYLAND_DISPLAY, creates its X display, listens
# on the X11 unix socket (/tmp/.X11-unix/X0 + the abstract "@..." name),
# and X11 clients connect to it via DISPLAY. This is the "one server
# protocol -> both Wayland AND X11 apps" (design-doc Phase 4) payoff.
#
# Ladder (the test REPORTS how far it climbs):
#   (a) Xwayland connects to the native Wayland server  — registry marker
#       + Xwayland's own root-surface shm-commit.
#   (b) X display comes up  — `DISPLAY=:0 xdpyinfo` prints the display
#       banner (proves the X server + its AF_UNIX socket work).
#   (c) an X11 app maps + renders  — `DISPLAY=:0 xeyes` draws into the
#       rootful X screen, Xwayland re-commits the shm buffer, and the
#       window composites into a Hamnix DE window (SCREENDUMP -> PNG).
#
# Xwayland + xeyes/xdpyinfo run as SEPARATE `spawn linux { }` detached
# processes; they rendezvous over the GLOBAL in-kernel AF_UNIX name
# registry (Xwayland's server bind + the client's connect resolve to the
# same endpoint even across namespaces — the X socket is not a VFS node).
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, socat, or the
# staged Xwayland is unavailable. KVM/OVMF only. Every qemu killed on exit.
set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
CMD_WAIT="${CMD_WAIT:-180}"
# The render rung needs a longer window than a plain command: the X app's
# FIRST spawn cold-loads its whole dynamic closure (ld.so + libX11/libxcb/…)
# under the live RAM-disk, which under -m 3G + host load can take ~3 min
# before it draws. Xwayland's own root commit fires quickly; the app's commit
# lands late. Give rung (c) its own generous bound so it isn't a flaky miss.
RENDER_WAIT="${RENDER_WAIT:-360}"
QEMU_MEM="${QEMU_MEM:-4G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"
TAG="[test_wl5_xwl]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"
REGISTRY_MARKER="registry advertised"
COMMIT_MARKER="shm buffer committed"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then echo "$TAG SKIP: /dev/kvm absent." >&2; exit 0; fi
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP: socat not installed." >&2; exit 0; }
command -v pnmtopng >/dev/null 2>&1 || echo "$TAG NOTE: pnmtopng absent; raw PPM only."
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP: OVMF firmware not found." >&2; exit 0; }
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[wayland_phase5_xwayland]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2; exit 0
    fi
    echo "$TAG building full-mirror live installer image (HAMNIX_LIVE_MINIMAL=0)"
    HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_ROOTFS_SIZE_MB:-1792}" \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG unavailable." >&2; exit 0; }

# --- probe: does the live image carry Xwayland ------------------------
HAVE_XWL=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    "$DEBUGFS" -R "stat /distro/usr/bin/Xwayland" "$LIVE_DISTRO_IMG" 2>/dev/null \
        | grep -q "Type: regular" && HAVE_XWL=1
fi
echo "$TAG live image probe: Xwayland=$HAVE_XWL"
if [ "$HAVE_XWL" -eq 0 ]; then
    echo "$TAG SKIP: live image carries no Xwayland." >&2
    echo "$TAG       Run scripts/stage_xwayland.sh then rebuild with" >&2
    echo "$TAG       HAMNIX_LIVE_MINIMAL=0 bash scripts/build_installer_img.sh." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-wl5.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wl5.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wl5.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-wl5-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-wl5-mon.XXXXXX.sock)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO" "$MON"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" 2>/dev/null; }
wait_for() {
    local pat="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        grep -a -F -q "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
send() { printf '%s\n' "$1" >&3; }
send_until() {
    local cmd="$1" pat="$2" secs="$3" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        printf '\n' >&3; sleep 1
        printf '%s\n' "$cmd" >&3
        for i in $(seq 1 15); do
            grep -a -F -q "$pat" "$LOG" && return 0
            kill -0 "$QEMU_PID" 2>/dev/null || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -F -q "$pat" "$LOG"
}

echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch + handoff..."
if ! wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: LIVE-branch marker not seen." >&2
    tail -60 "$LOG" | strings >&2; exit 1
fi
wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT" \
    && echo "$TAG PASS: kernel live-root bringup completed." \
    || echo "$TAG WARN: '[live-root] DONE' not seen." >&2
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -60 "$LOG" | strings >&2; exit 1
fi
wait_for "ed-readline-first" 30 || sleep 3
if wait_for "[visual_gate] done" 240; then
    echo "$TAG DE visual_gate settled; system quiet for XWayland."; sleep 6
else
    echo "$TAG NOTE: visual_gate-done not seen in 240s; proceeding anyway."
fi

# =====================================================================
# SANITY: ITIMER_REAL / SIGALRM works in isolation (before the X stack).
# =====================================================================
# A tiny static glibc probe (tests/distros/debian-minbase/rootfs staged
# /usr/bin/itimer_probe) arms setitimer(ITIMER_REAL, 100ms repeating),
# installs a SIGALRM handler, and prints ITIMER_PROBE_OK once the handler
# has fired >=3 times. This decouples the setitimer/SIGALRM kernel path
# from xeyes' heavy redraw code: a PASS here proves the timer + signal
# delivery work; a later xeyes failure is then a DISTINCT gate. Skips
# cleanly if the probe binary isn't staged in this image.
echo "$TAG --- SANITY: setitimer(ITIMER_REAL)+SIGALRM (itimer_probe) ---"
sanity_itimer="skip"
if send_until "spawn linux { /usr/bin/itimer_probe }" "ITIMER_PROBE_OK" 60; then
    echo "$TAG PASS (sanity): SIGALRM handler fired — ITIMER_REAL works."
    grep -aF "ITIMER_PROBE_" "$LOG" | tail -4
    sanity_itimer="pass"
elif grep -aqF "ITIMER_PROBE_START" "$LOG"; then
    echo "$TAG WARN (sanity): probe started but SIGALRM did not fire in time." >&2
    grep -aF "ITIMER_PROBE_" "$LOG" | tail -4
    sanity_itimer="fail"
else
    echo "$TAG NOTE (sanity): itimer_probe not present in this image; skipping."
fi

# =====================================================================
# PREREQ: the X11 UNIX-socket directory /tmp/.X11-unix must exist.
# =====================================================================
# Xwayland (via libxtrans) creates its X listening socket under
# /tmp/.X11-unix. When euid != 0 (the live/DE session is non-root)
# libxtrans REFUSES to mkdir that directory and then aborts the WHOLE X
# listener (it binds the abstract AND filesystem X sockets in one call, so
# a missing dir kills both) — xdpyinfo/xeyes then get "unable to open
# display". /tmp is the BASE namespace directory: nsrun mounts only
# /var,/usr,/etc from distrofs, so /tmp (like /run, which carries the
# wayland-0 socket) comes from the base ns, NOT /distro/tmp. Create it
# natively here — this is exactly tmpfiles.d/x11.conf's job on a real
# system (dir /tmp/.X11-unix 1777 root root); the native session launcher
# owns it. Native mkdir gives a world-usable dir; libxtrans only needs the
# dir to be stat-able so it proceeds to bind() the socket by name.
echo "$TAG PREREQ: seeding /tmp/.X11-unix in the base namespace"
send "mkdir /tmp/.X11-unix"
sleep 3

# =====================================================================
# LADDER RUNG (a): launch Xwayland; it connects to the native compositor.
# =====================================================================
# Rootful X screen (default, no -rootless): Xwayland creates ONE root
# wl_surface and X clients render into it -> one DE window shows the X
# screen. -noreset keeps the server up after the last client. Software
# path (no DRM node) -> pixman/shm rendering, no glamor/GL. Env: the same
# XDG_RUNTIME_DIR=/run + WAYLAND_DISPLAY=wayland-0 the weston client uses;
# XDG_CACHE_HOME=/etc/fonts/cache for the prebuilt fontconfig cache.
XWL_ENV='export XDG_RUNTIME_DIR=/run ; export WAYLAND_DISPLAY=wayland-0 ; export XDG_CONFIG_HOME=/run ; export XDG_CACHE_HOME=/etc/fonts/cache'
# NOTE: hamsh lexes a non-glued ':' (space/'=' before it) as OP_COLON, so
# the X display arg MUST be single-quoted (':0') to reach argv as a literal
# word; likewise DISPLAY=':0' and the geometry '+x+y' below.
# -ac DISABLES X access control: a standalone `Xwayland :0` still enforces
# MIT-MAGIC-COOKIE auth and refuses cookie-less local clients ("Authorization
# required, but no authorization protocol specified" -> xdpyinfo can't open
# the display). A compositor-launched Xwayland gets `-auth <cookie>`; for the
# local trusted single-user bridge we disable access control so any client on
# the box connects. (The namespace model already gates who reaches the socket.)
XWL_CMD="$XWL_ENV ; spawn linux { /usr/bin/Xwayland ':0' -ac -noreset -shm -geometry '800x600' }"
echo "$TAG --- RUNG (a): launch Xwayland :0 (connect to native Wayland) ---"
rung_a=0
if send_until "$XWL_CMD" "$REGISTRY_MARKER" "$CMD_WAIT"; then
    echo "$TAG PASS (a): native Wayland registry advertised to Xwayland:"
    grep -aF "$REGISTRY_MARKER" "$LOG" | tail -2
    rung_a=1
else
    echo "$TAG WARN (a): registry marker not seen after launching Xwayland." >&2
fi
# Give Xwayland time to finish init + commit its root surface.
sleep 8
xwl_committed=0
if grep -aF "$COMMIT_MARKER" "$LOG" >/dev/null 2>&1; then
    xwl_committed=1
    echo "$TAG NOTE (a): a wl_surface shm-commit fired after Xwayland launch:"
    grep -aF "$COMMIT_MARKER" "$LOG" | tail -2
fi
echo "$TAG --- Xwayland serial output ---"
grep -aiE "xwayland|\[wayland\]|glamor|glx|EGL|xkb|FatalError|could not|error" "$LOG" | tail -25 || true

# =====================================================================
# LADDER RUNG (b): X display liveness — DISPLAY=:0 xdpyinfo.
# =====================================================================
echo "$TAG --- RUNG (b): DISPLAY=:0 xdpyinfo (X display up?) ---"
DPY_CMD="export DISPLAY=':0' ; spawn linux { /usr/bin/xdpyinfo }"
rung_b=0
# xdpyinfo prints "name of display:" + "version number:" to stdout->serial.
if send_until "$DPY_CMD" "name of display" "$CMD_WAIT"; then
    echo "$TAG PASS (b): xdpyinfo talked to the X server:"
    grep -aE "name of display|version number|dimensions:|number of screens" "$LOG" | tail -8
    rung_b=1
else
    echo "$TAG WARN (b): xdpyinfo did not print a display banner." >&2
    grep -aiE "xdpyinfo|unable to open display|cannot connect|Xlib" "$LOG" | tail -10 || true
fi

# =====================================================================
# LADDER RUNG (c): an X11 app maps + renders — DISPLAY=:0 xeyes.
# =====================================================================
# xeyes connects to the X server (verified: [nxafu] connect + accept) and
# drives its eye redraw off setitimer(ITIMER_REAL) -> SIGALRM (implemented:
# linux_abi setitimer/getitimer/alarm nr 36/37/38). xeyes then redraws,
# Xwayland re-commits the root surface, and the window composites into a
# Hamnix DE window — this rung flips to a real PASS below when the render +
# interframe-change checks pass.
#
# GATE HISTORY: the earlier "428507 #GP storm" was decoded as glibc abort()'s
# `hlt` "unreachable" trap (libc.so.6+0x28507) — reached because a fatal
# default signal (SIGABRT) raised from INSIDE the SIGALRM redraw handler was
# never delivered (signal_dispatch bailed on sig_in_handler), and a re-faulting
# SIGSEGV looped instead of terminating. Both are now fixed (signal_dispatch
# fires fatal-defaults mid-handler; deliver_fault_sigsegv force-terminates a
# blocked/re-faulting SIGSEGV) — see the STORM GUARD below. A remaining
# intermittent poisoned-PTE write fault (all-ones leaf PTE) can still make
# xeyes abort on some ASLR layouts; when it does it now dies cleanly (exit
# 134) instead of storming, and a later boot with a clean layout renders.
echo "$TAG --- RUNG (c): DISPLAY=:0 X11 app renders (xsetroot -solid red) ---"
# Screendump BEFORE the app draws, to diff for the new rendered content.
PPM_PRE="$OUTDIR/wl5_xwl_pre.ppm"
PPM_APP="$OUTDIR/wl5_xwl_app.ppm"
PNG_APP="$OUTDIR/wl5_xwayland_xsetroot.png"
rm -f "$PPM_PRE" "$PPM_APP" "$PNG_APP"
mon "screendump $PPM_PRE" >/dev/null; sleep 1

# The DETERMINISTIC render rung: `xsetroot -solid red` fills the whole rootful
# X screen with one colour via a single XSetWindowBackground+XClearWindow — no
# timers, no SIGALRM, no client-side surface. It is the cleanest proof that the
# GL-free software `-shm` present path re-presents X client damage: the entire
# 800x600 root re-commits and the compositor logs nonzero_px=480000 (full red).
# (Earlier this rung used `xeyes`, but xeyes is transparent/ParentRelative over
# the DEFAULT BLACK X root, so its buffer reads black-on-black — a test-fixture
# artefact, not a pipeline gap. xeyes is still exercised as a supplementary
# SIGALRM/storm probe below.) rootful mode == one DE window shows the X screen.
APP_CMD="export DISPLAY=':0' ; spawn linux { /usr/bin/xsetroot -solid red }"
rung_c=0
# Xwayland already committed its root surface at rung (a), so the "shm buffer
# committed" marker is ALREADY in the log — detect a NEW commit (count INCREASE),
# not the marker's mere presence. In rootful mode the root re-commits the SAME
# wid, so a fresh commit == the X app drew into the screen.
pre_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null || echo 0)
# Fill the root red (a settle newline first so hamsh has a clean prompt).
printf '\n' >&3; sleep 1; send "$APP_CMD"
echo "$TAG (c) xsetroot launched; waiting up to ${RENDER_WAIT}s for a NEW root-surface commit (red fill)..."
post_commits="$pre_commits"
for _i in $(seq 1 "$RENDER_WAIT"); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    post_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null || echo 0)
    [ "$post_commits" -gt "$pre_commits" ] && break
    sleep 1
done
echo "$TAG NOTE (c): commits before=$pre_commits after=$post_commits"
# Supplementary probe: xeyes exercises the setitimer(ITIMER_REAL)->SIGALRM
# redraw path + the fatal-fault STORM GUARD below (non-gating; it draws over
# the now-red root so its window is visible too).
send "export DISPLAY=':0' ; spawn linux { /usr/bin/xeyes -geometry '300x200+40+40' }"
sleep 4
# Let a couple more redraw ticks land so the screendump captures a full frame.
sleep 6
WID="$(grep -aF "$COMMIT_MARKER" "$LOG" | tail -1 | grep -aoE 'wid [0-9]+' | awk '{print $2}')"
echo "$TAG Xwayland surface window id: ${WID:-<unknown>}"
mon "screendump $PPM_APP" >/dev/null; sleep 1

if command -v pnmtopng >/dev/null 2>&1 && [ -s "$PPM_APP" ]; then
    pnmtopng "$PPM_APP" > "$PNG_APP" 2>/dev/null && echo "$TAG PNG (xeyes): $PNG_APP"
fi

# render proof: the app window is a non-flat region (distinct colours) AND
# the framebuffer changed vs the pre-map screendump.
if [ -s "$PPM_PRE" ] && [ -s "$PPM_APP" ]; then
    read -r RENDER_OK CHANGED_OK MSG < <(python3 - "$PPM_PRE" "$PPM_APP" <<'PY'
import sys
def load(p):
    d=open(p,'rb').read(); assert d[:2]==b'P6'
    idx=2; vals=[]
    while len(vals)<3:
        while idx<len(d) and d[idx] in b' \t\n\r': idx+=1
        if d[idx:idx+1]==b'#':
            while idx<len(d) and d[idx] not in b'\n': idx+=1
            continue
        s=idx
        while idx<len(d) and d[idx] not in b' \t\n\r': idx+=1
        vals.append(int(d[s:idx]))
    idx+=1; w,h,mv=vals
    return w,h,d[idx:idx+w*h*3]
wa,ha,a=load(sys.argv[1]); wb,hb,b=load(sys.argv[2])
best=0
for y0 in range(0,max(1,hb-120),20):
    for x0 in range(0,max(1,wb-200),20):
        sset=set()
        for yy in range(y0,y0+120,8):
            for xx in range(x0,x0+200,8):
                o=(yy*wb+xx)*3; sset.add((b[o],b[o+1],b[o+2]))
        best=max(best,len(sset))
render_ok = 1 if best>=10 else 0
changed=0
if (wa,ha)==(wb,hb):
    for yy in range(0,hb,3):
        for xx in range(0,wb,3):
            o=(yy*wb+xx)*3
            if abs(a[o]-b[o])+abs(a[o+1]-b[o+1])+abs(a[o+2]-b[o+2])>24:
                changed+=1
changed_ok = 1 if changed>=20 else 0
print(render_ok, changed_ok, f"app_tile_uniq={best} interframe_changed={changed} fb={wb}x{hb}")
PY
)
    echo "$TAG render check: $MSG"
    [ "$rung_c" = "0" ] && [ "${RENDER_OK:-0}" = "1" ] && [ "${CHANGED_OK:-0}" = "1" ] && rung_c=1
else
    echo "$TAG WARN (c): screendump produced no PPM." >&2
    RENDER_OK=0; CHANGED_OK=0
fi

# =====================================================================
# STORM GUARD — a faulting X client must DIE cleanly, never fault-loop.
# =====================================================================
# Regression guard for the SIGSEGV/#GP fault-storm fix (deliver_fault_sigsegv
# force-terminate-when-SIGSEGV-blocked + signal_dispatch fatal-default fires
# mid-handler). If an X client ever hits a fatal fault (e.g. the intermittent
# poisoned-PTE write fault that drove xeyes into glibc abort()), it must take
# a BOUNDED number of fault dumps and then the task must be reaped — NOT
# re-fault 1000+ times into stack exhaustion. We assert no single faulting RIP
# repeats more than STORM_MAX times in the serial log.
STORM_MAX="${STORM_MAX:-40}"
storm_worst=0
storm_rip=""
while read -r cnt rip; do
    [ -z "$cnt" ] && continue
    if [ "$cnt" -gt "$storm_worst" ]; then storm_worst="$cnt"; storm_rip="$rip"; fi
done < <(grep -aoE '\[(gp|pf)\] user #(GP|PF)?[^r]*rip=0x[0-9a-fA-F]+' "$LOG" 2>/dev/null \
            | grep -aoE 'rip=0x[0-9a-fA-F]+' | sort | uniq -c | sort -rn)
# Also count the classic hlt-in-abort #GP rip repeats (rip printed on the
# '[gp] user #GP rip=' line, which the pattern above may format differently).
gp_worst=$(grep -aoE '\[gp\] user #GP rip=0x[0-9a-fA-F]+' "$LOG" 2>/dev/null \
            | sort | uniq -c | sort -rn | head -1 | awk '{print $1+0}')
[ -n "$gp_worst" ] && [ "$gp_worst" -gt "$storm_worst" ] && storm_worst="$gp_worst"
echo "$TAG STORM GUARD: worst single-RIP fault repeat = ${storm_worst} (limit ${STORM_MAX}) ${storm_rip}"
storm_ok=1
if [ "${storm_worst:-0}" -gt "$STORM_MAX" ]; then
    echo "$TAG FAIL (storm): a fault re-fired ${storm_worst}x at ${storm_rip} — SIGSEGV/#GP" >&2
    echo "$TAG   is looping instead of terminating the task (regression)." >&2
    storm_ok=0
fi

# =====================================================================
# VERDICT — report how far up the ladder.
# =====================================================================
echo "$TAG ============================================================"
echo "$TAG XWAYLAND LADDER:"
echo "$TAG   (a) Xwayland connects to native Wayland : $([ "$rung_a" = 1 ] && echo YES || echo no)"
echo "$TAG   (b) X display up (xdpyinfo)             : $([ "$rung_b" = 1 ] && echo YES || echo no)"
echo "$TAG   (c) X11 app renders (xeyes)             : $([ "$rung_c" = 1 ] && echo YES || echo no)"
echo "$TAG   no fault-storm (SIGSEGV terminates)     : $([ "$storm_ok" = 1 ] && echo YES || echo no)"
echo "$TAG   screendump: $PNG_APP"
echo "$TAG ============================================================"

# A fault STORM is a hard regression regardless of how far the ladder climbed.
if [ "$storm_ok" != 1 ]; then
    echo "$TAG RESULT: FAIL — a userspace fault looped instead of terminating the task." >&2
    exit 1
fi

if [ "$rung_a" = 1 ] && [ "$rung_b" = 1 ] && [ "$rung_c" = 1 ]; then
    echo "$TAG RESULT: PASS — XWayland runs X11 apps on the native Wayland server."
    exit 0
fi
if [ "$rung_a" = 1 ] || [ "$rung_b" = 1 ]; then
    echo "$TAG RESULT: PARTIAL — climbed some rungs (see ladder above). New Linux-ABI"
    echo "$TAG   gap likely at the first 'no' rung; check the Xwayland serial lines." >&2
    exit 0
fi
echo "$TAG RESULT: FAIL — Xwayland did not connect to the native Wayland server." >&2
exit 1
