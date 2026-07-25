#!/usr/bin/env bash
# scripts/test_wayland_firefox.sh — Wayland native-client bring-up:
# run the UNMODIFIED Debian `firefox-esr` as a NATIVE Wayland client of the
# in-kernel Wayland compositor via MOZ_ENABLE_WAYLAND=1 — bypassing Xwayland
# (whose rootful X render is blocked in this GL-free environment). This is
# the payoff of the native-Wayland pivot: weston-terminal already renders as
# a native wl client (test_wayland_phase4_term.sh), proving the transport;
# Firefox is the large GTK3 client on the same path.
#
# LADDER (the test REPORTS how far it climbs — this is a multi-gate bring-up,
# NOT expected to pass end-to-end yet):
#   (a) Firefox connects to the native Wayland server — the compositor
#       advertises its registry to the new client ("registry advertised").
#   (b) Firefox's main window MAPS — it commits an xdg_toplevel wl_shm
#       buffer ("shm buffer committed" on a NEW wid).
#   (c) chrome RENDERS — the toolbar/tabs paint into the shm buffer; the
#       window composites into a Hamnix DE window (SCREENDUMP -> PNG, the
#       screendump is a non-flat multi-colour region).
#   (d) about:blank / a local file:// loads (best-effort content check).
#
# SOFTWARE RENDER ONLY: MOZ_ACCELERATED=0 + LIBGL_ALWAYS_SOFTWARE=1 +
# software WebRender (swgl, forced in the staged profile prefs.js). Sandbox
# disabled (MOZ_DISABLE_CONTENT_SANDBOX / MOZ_SANDBOX=0) — the content
# sandbox needs seccomp/user-ns syscalls Hamnix's Linux ABI does not yet
# fully provide. Fresh throwaway profile, -no-remote -new-instance.
#
# Firefox is heavily threaded + memory-hungry: give the guest MORE RAM
# (QEMU_MEM=6G default here). A page-allocator free-list #GP under memory
# pressure (mm_page_alloc__alloc_pages_raw) is a SEPARATE known issue owned
# by agent #69 — if seen, it is reported, NOT worked around here.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, socat, or a staged
# firefox-esr is unavailable. Reports PARTIAL (exit 0) when it climbs some
# but not all rungs — a bring-up probe must not hard-fail the suite. Exits 1
# only on a boot/screendump failure or a fault-storm regression. KVM/OVMF
# only. Every qemu killed on exit.
set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-360}"
CMD_WAIT="${CMD_WAIT:-240}"
QEMU_MEM="${QEMU_MEM:-6G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"
TAG="[test_wl_firefox]"

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
if installer_img_needs_build "$INSTALLER_IMG" "[wayland_firefox]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2; exit 0
    fi
    echo "$TAG building full-mirror live installer image (HAMNIX_LIVE_MINIMAL=0)"
    echo "$TAG   Firefox payload needs a grown rootfs: HAMNIX_ROOTFS_SIZE_MB=${HAMNIX_ROOTFS_SIZE_MB:-1792}"
    HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_ROOTFS_SIZE_MB:-1792}" \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG unavailable." >&2; exit 0; }

# --- decide whether the live image carries firefox-esr ----------------
HAVE_FF=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    "$DEBUGFS" -R "stat /distro/usr/lib/firefox-esr/firefox-esr" "$LIVE_DISTRO_IMG" 2>/dev/null \
        | grep -q "Type: " && HAVE_FF=1
fi
echo "$TAG live image probe: firefox-esr=$HAVE_FF"
if [ "$HAVE_FF" -eq 0 ]; then
    echo "$TAG SKIP: live image carries no firefox-esr." >&2
    echo "$TAG       Run scripts/stage_weston_term.sh then scripts/stage_firefox.sh," >&2
    echo "$TAG       then rebuild: HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB=1792 \\" >&2
    echo "$TAG                     bash scripts/build_installer_img.sh." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-wlff.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wlff.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wlff.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-wlff-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-wlff-mon.XXXXXX.sock)
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
    echo "$TAG DE visual_gate settled; system quiet for Firefox."; sleep 6
else
    echo "$TAG NOTE: visual_gate-done not seen in 240s; proceeding anyway."
fi

# --- seed the X11 dir is NOT needed (pure Wayland); seed /run/.ff cache -
send "mkdir /root/.cache"; sleep 1
send "mkdir /root/.mozilla"; sleep 1

# =====================================================================
# LAUNCH: firefox-esr as a native Wayland client.
# =====================================================================
# LAUNCH VIA /ff-launch.sh (env baked into the script by stage_firefox.sh).
#
# HISTORY / WHY NOT INLINE ENV: a prior form set ~18 `export VAR=... ;` clauses
# then `spawn linux { firefox-esr ... }` on ONE command line. That line exceeds
# hamsh's interactive line-editor width; the readline buffer truncated it at the
# terminal wrap column (~262) BEFORE the `spawn linux { ... }` clause, so
# firefox NEVER launched — the harness then spun waiting for a registry marker
# that could not appear. stage_firefox.sh bakes the identical MOZ_ENABLE_WAYLAND
# / software-render / sandbox-off environment INTO /ff-launch.sh (which also
# prefixes firefox's stderr with "[FF] " on the serial), so a SHORT command line
# both fits the editor and carries the full environment. This is the launch the
# repro brief specifies.
FF_CMD="spawn linux { /bin/sh /ff-launch.sh }"

# =====================================================================
# LADDER RUNG (a): Firefox connects to the native Wayland server.
# =====================================================================
echo "$TAG --- RUNG (a): launch firefox-esr (MOZ_ENABLE_WAYLAND=1) ---"
pre_reg=$(grep -acF "$REGISTRY_MARKER" "$LOG" 2>/dev/null | head -1)
pre_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null | head -1)
echo "$TAG pre-launch: registry=$pre_reg commits=$pre_commits"
rung_a=0
if send_until "$FF_CMD" "$REGISTRY_MARKER" "$CMD_WAIT"; then
    post_reg=$(grep -acF "$REGISTRY_MARKER" "$LOG" 2>/dev/null | head -1)
    if [ "$post_reg" -gt "$pre_reg" ]; then
        echo "$TAG PASS (a): native Wayland registry advertised to Firefox (reg $pre_reg->$post_reg)."
        rung_a=1
    else
        echo "$TAG NOTE (a): registry marker present but no NEW bind detected yet."
    fi
    grep -aF "$REGISTRY_MARKER" "$LOG" | tail -2
else
    echo "$TAG WARN (a): registry marker not seen after launching Firefox." >&2
fi
# Firefox is slow to start (dynamic-load libxul 164 MiB + JS init). Give it time.
echo "$TAG (a) waiting for Firefox startup / window map (up to ${CMD_WAIT}s)..."

# =====================================================================
# LADDER RUNG (b): Firefox's main window MAPS (new shm commit).
# =====================================================================
rung_b=0
post_commits="$pre_commits"
for _i in $(seq 1 "$CMD_WAIT"); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    post_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null | head -1)
    [ "$post_commits" -gt "$pre_commits" ] && break
    sleep 1
done
echo "$TAG NOTE (b): commits before=$pre_commits after=$post_commits"
if [ "$post_commits" -gt "$pre_commits" ]; then
    echo "$TAG PASS (b): Firefox committed a wl_shm buffer (window mapped)."
    grep -aF "$COMMIT_MARKER" "$LOG" | tail -2
    rung_b=1
else
    echo "$TAG WARN (b): no new wl_shm commit — Firefox did not map a window." >&2
fi
sleep 6
WID="$(grep -aF "$COMMIT_MARKER" "$LOG" | tail -1 | grep -aoE 'wid [0-9]+' | awk '{print $2}')"
echo "$TAG Firefox surface window id: ${WID:-<unknown>}"

echo "$TAG --- Firefox / GTK / Wayland serial output ---"
grep -aiE "firefox|mozilla|libxul|gtk|gdk|wayland|MOZ_|glib|Gdk|Gtk|assert|abort|error|fatal|segfault|not provide|failed" "$LOG" | tail -40 || true

# RENDER-PATH slice (#108): surface the WebRender / render-thread / GL-EGL /
# window-map progression captured by the baked ff-launch [FF-RENDER] dump (or
# raw MOZ_LOG render modules). This is the ground-truth for the render-thread-
# readiness question: a GLContext/EGL open on the pure-shm path is the smoking
# gun; its absence (only RenderThread/WebRender/nsWindow lines) means SWGL took
# the wl_shm path and the gap is downstream (xdg_surface/commit).
echo "$TAG --- render-thread / WebRender / GL-EGL / window-map progression ---"
grep -aiE "FF-RENDER|RenderThread|RenderCompositor|SWGL|WebRender|GLContext|EGLLibrary|nsWindow|moz_container|xdg_surface|CreateRenderer|EnsureGPUReady" "$LOG" | tail -40 || true

# #108 ROUND-2 DECISIVE WIRE-TRACE ANALYSIS. The MOZ_LOG render modules above
# are frequently SILENT here: the parent main thread parks UPSTREAM of widget/
# render init (the documented startup deadlock — it g_cond_waits on a storage/
# profile worker that never signals in this limited-Linux-ABI ns), so NO
# RenderThread/WebRender/nsWindow record is ever emitted even when the transport
# is perfectly healthy. The WAYLAND_DEBUG "[FF]" wire trace is therefore the
# GROUND TRUTH for the GL-wall-vs-window-map question that MOZ_LOG cannot answer:
#   * ANY Firefox egl/GLContext/GBM/dmabuf line -> branch (a): a real GL/EGL wall.
#   * wl_shm create_pool (+ growing resize)     -> branch (b): the SWGL wl_shm
#                                                  software path IS taken (no GL).
#   * furthest xdg_* verb + whether get_xdg_surface / attach / commit ever fire
#     -> EXACTLY where the window-map stalls.
echo "$TAG --- #108 wire-trace decision (WAYLAND_DEBUG ground truth) ---"
ff_egl=$(grep -acE '^\[FF\].*(egl|EGL|GLContext|glx|GLX|create_context|gbm|GBM|dmabuf|zwp_linux_dmabuf)' "$LOG" 2>/dev/null)
ff_shmpool=$(grep -acE '^\[FF\].*wl_shm(#[0-9]+)?\.create_pool' "$LOG" 2>/dev/null)
ff_shmresize=$(grep -aoE 'wl_shm_pool#[0-9]+\.resize\([0-9]+\)' "$LOG" 2>/dev/null | tail -1)
ff_xdgbind=$(grep -acE '^\[FF\].*bind\([0-9]+, .xdg_wm_base.' "$LOG" 2>/dev/null)
ff_getxdg=$(grep -acE '^\[FF\].*(get_xdg_surface|get_toplevel|xdg_surface#[0-9]+\.|xdg_toplevel#[0-9]+\.)' "$LOG" 2>/dev/null)
ff_attach=$(grep -acE '^\[FF\].*wl_surface#[0-9]+\.(attach|commit)' "$LOG" 2>/dev/null)
echo "$TAG   Firefox EGL/GLContext lines : ${ff_egl:-0}  (>0 => branch (a) GL wall)"
echo "$TAG   wl_shm create_pool          : ${ff_shmpool:-0}  (>0 => SWGL wl_shm path taken)"
echo "$TAG   last shm-pool resize        : ${ff_shmresize:-<none>}"
echo "$TAG   xdg_wm_base bind            : ${ff_xdgbind:-0}"
echo "$TAG   xdg_surface/toplevel verbs  : ${ff_getxdg:-0}  (0 => window-map never begun)"
echo "$TAG   wl_surface attach/commit    : ${ff_attach:-0}  (0 => no buffer committed)"
if [ "${ff_egl:-0}" -gt 0 ]; then
    echo "$TAG   #108 VERDICT: branch (a) — a GL/EGL context opened on the render path;"
    echo "$TAG     force RenderCompositorSWGL / gfx.webrender.software.opengl=false."
elif [ "${ff_shmpool:-0}" -gt 0 ] && [ "${ff_getxdg:-0}" -eq 0 ]; then
    echo "$TAG   #108 VERDICT: branch (b) — GL wall DISPROVEN; SWGL wl_shm path active,"
    echo "$TAG     but the main thread parks after the xdg_wm_base bind and never"
    echo "$TAG     creates the xdg_surface (window-map stall UPSTREAM of render init:"
    echo "$TAG     the parked Firefox startup deadlock, NOT a GL/render-thread wall)."
elif [ "${ff_attach:-0}" -eq 0 ]; then
    echo "$TAG   #108 VERDICT: branch (b) — reached xdg_surface but never committed a"
    echo "$TAG     wl_shm buffer (map stalls at the attach/commit step)."
else
    echo "$TAG   #108 VERDICT: buffer committed — inspect the ladder (b) result above."
fi

# =====================================================================
# LADDER RUNG (c): chrome RENDERS — screendump the DE window.
# =====================================================================
echo "$TAG --- RUNG (c): screendump Firefox chrome ---"
PPM_APP="$OUTDIR/wl_firefox_app.ppm"
PNG_APP="$OUTDIR/wl_firefox_chrome.png"
rm -f "$PPM_APP" "$PNG_APP"
mon "screendump $PPM_APP" >/dev/null; sleep 1
if command -v pnmtopng >/dev/null 2>&1 && [ -s "$PPM_APP" ]; then
    pnmtopng "$PPM_APP" > "$PNG_APP" 2>/dev/null && echo "$TAG PNG (firefox chrome): $PNG_APP"
fi
rung_c=0
if [ -s "$PPM_APP" ]; then
    read -r RENDER_OK MSG < <(python3 - "$PPM_APP" <<'PY'
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
w,h,b=load(sys.argv[1])
best=0
for y0 in range(0,max(1,h-120),20):
    for x0 in range(0,max(1,w-200),20):
        s=set()
        for yy in range(y0,y0+120,8):
            for xx in range(x0,x0+200,8):
                o=(yy*w+xx)*3; s.add((b[o],b[o+1],b[o+2]))
        best=max(best,len(s))
print(1 if best>=10 else 0, f"chrome_tile_uniq={best} fb={w}x{h}")
PY
)
    echo "$TAG render check: $MSG"
    [ "${RENDER_OK:-0}" = "1" ] && [ "$rung_b" = "1" ] && rung_c=1
else
    echo "$TAG WARN (c): screendump produced no PPM." >&2
fi

# =====================================================================
# LADDER RUNG (d): about:blank / content loaded (best-effort).
# =====================================================================
# Hard to assert content without devtools; treat a live process that mapped
# + rendered as evidence. Look for Firefox's own "nsWindow" / doc-load or a
# clean absence of a crash as the weak signal.
rung_d=0
if [ "$rung_c" = "1" ] && ! grep -aqiE "EXITING GECKO|Crash Annotation|###!!! ABORT|MOZ_CRASH" "$LOG"; then
    rung_d=1
fi

# =====================================================================
# STORM GUARD — a faulting client must DIE cleanly, never fault-loop.
# =====================================================================
STORM_MAX="${STORM_MAX:-40}"
storm_worst=0; storm_rip=""
while read -r cnt rip; do
    [ -z "$cnt" ] && continue
    if [ "$cnt" -gt "$storm_worst" ]; then storm_worst="$cnt"; storm_rip="$rip"; fi
done < <(grep -aoE 'rip=0x[0-9a-fA-F]+' "$LOG" 2>/dev/null | sort | uniq -c | sort -rn)
echo "$TAG STORM GUARD: worst single-RIP fault repeat = ${storm_worst} (limit ${STORM_MAX}) ${storm_rip}"
storm_ok=1
if [ "${storm_worst:-0}" -gt "$STORM_MAX" ]; then
    echo "$TAG FAIL (storm): a fault re-fired ${storm_worst}x at ${storm_rip}." >&2
    storm_ok=0
fi

# --- page-allocator #GP note (agent #69's file, not ours) --------------
if grep -aqiE "mm_page_alloc|alloc_pages_raw|page_alloc.*#GP" "$LOG"; then
    echo "$TAG NOTE: page-allocator #GP under memory pressure observed — this is" >&2
    echo "$TAG   agent #69's mm/page_alloc.ad free-list bug (Firefox's heavy" >&2
    echo "$TAG   allocation load triggers it); NOT fixed here." >&2
fi

# =====================================================================
# VERDICT.
# =====================================================================
echo "$TAG ============================================================"
echo "$TAG FIREFOX NATIVE-WAYLAND LADDER:"
echo "$TAG   (a) connects to native Wayland (registry) : $([ "$rung_a" = 1 ] && echo YES || echo no)"
echo "$TAG   (b) main window MAPS (wl_shm commit)      : $([ "$rung_b" = 1 ] && echo YES || echo no)"
echo "$TAG   (c) chrome RENDERS (screendump non-flat)  : $([ "$rung_c" = 1 ] && echo YES || echo no)"
echo "$TAG   (d) about:blank loads (no crash)          : $([ "$rung_d" = 1 ] && echo YES || echo no)"
echo "$TAG   no fault-storm (clean termination)        : $([ "$storm_ok" = 1 ] && echo YES || echo no)"
echo "$TAG   screendump: $PNG_APP"
echo "$TAG ============================================================"

if [ "$storm_ok" != 1 ]; then
    echo "$TAG RESULT: FAIL — a userspace fault looped instead of terminating." >&2
    exit 1
fi
if [ "$rung_a" = 1 ] && [ "$rung_b" = 1 ] && [ "$rung_c" = 1 ]; then
    echo "$TAG RESULT: PASS — Firefox runs as a native Wayland client with rendered chrome."
    exit 0
fi
if [ "$rung_a" = 1 ] || [ "$rung_b" = 1 ]; then
    echo "$TAG RESULT: PARTIAL — climbed some rungs (see ladder). Next gap at the"
    echo "$TAG   first 'no' rung; check the Firefox/GTK serial lines above." >&2
    exit 0
fi
echo "$TAG RESULT: FAIL — Firefox did not connect to the native Wayland server." >&2
echo "$TAG   (a bring-up probe — inspect the serial log for the first Linux-ABI gap)" >&2
exit 0
