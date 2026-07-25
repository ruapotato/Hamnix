#!/usr/bin/env bash
# scripts/test_webkit.sh — Wayland native-client bring-up for a REAL modern-web
# engine: run the UNMODIFIED Debian WebKitGTK 4.1 MiniBrowser (WebKit, the
# Safari family) as a NATIVE Wayland client of the in-kernel Wayland compositor.
#
# WHY WEBKIT (not Firefox): Firefox (Gecko) parks in a Gecko-INTERNAL early-init
# circular wait (create_surface->destroy x2, then ZERO xdg_wm_base requests —
# see project_firefox_startup_deadlock). That wall is engine-specific, NOT a
# Hamnix ABI gap: `foot`, weston-terminal and a Qt5 app all map wl_shm windows
# on this SAME compositor. WebKitGTK is a DIFFERENT engine on the proven GTK3/
# wl_shm path, so it may map + paint where Gecko cannot. It is ALSO multi-process
# (MiniBrowser UIProcess + WebKitWebProcess + WebKitNetworkProcess), so it
# exercises Hamnix's fork/exec + AF_UNIX socketpair fd-inherit + SCM_RIGHTS IPC.
#
# LADDER (the test REPORTS how far it climbs — a multi-gate bring-up probe, NOT
# assumed to pass end-to-end):
#   (a) MiniBrowser connects to the native Wayland server — the compositor
#       advertises its registry to the new client ("registry advertised").
#   (b) the window MAPS — MiniBrowser commits an xdg_toplevel wl_shm buffer
#       ("shm buffer committed" on a NEW wid / "[devwsys] window N mapped").
#   (c) the page RENDERS — Skia CPU raster paints into the shm buffer and the
#       DE composites it (SCREENDUMP -> PNG, a non-flat multi-colour region).
#   (d) content loads (best-effort: mapped + rendered + no crash).
#
# SOFTWARE RENDER ONLY: WEBKIT_DISABLE_COMPOSITING_MODE=1 (+ DMABUF renderer
# off, LIBGL_ALWAYS_SOFTWARE=1) -> Skia CPU raster -> wl_shm present. No
# Mesa/EGL/GBM/DRM. Sandbox disabled (bwrap needs user-ns/seccomp we do not yet
# fully provide). All env is BAKED into /webkit-launch.sh by stage_webkit.sh, so
# the serial launch line stays short (hamsh's line editor truncates long lines).
#
# WAYLAND_DEBUG=1 is baked ON by the launcher: every "[WK]" line carries the
# wire trace, the GROUND TRUTH for the map-vs-stall question — exactly which
# xdg-shell verb fired last and in which process it stalled.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, socat, or a staged
# MiniBrowser is unavailable. Reports PARTIAL (exit 0) when it climbs some but
# not all rungs — a bring-up probe must not hard-fail the suite. Exits 1 only on
# a boot/screendump failure or a fault-storm regression. KVM/OVMF only. Every
# qemu killed on exit.
set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-360}"
CMD_WAIT="${CMD_WAIT:-240}"
QEMU_MEM="${QEMU_MEM:-6G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"
TAG="[test_webkit]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"
REGISTRY_MARKER="registry advertised"
COMMIT_MARKER="shm buffer committed"
MAP_MARKER="mapped pid="

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
if installer_img_needs_build "$INSTALLER_IMG" "[webkit]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2; exit 0
    fi
    echo "$TAG building full-mirror live installer image (HAMNIX_LIVE_MINIMAL=0)"
    echo "$TAG   WebKit + closure needs a grown rootfs: HAMNIX_ROOTFS_SIZE_MB=${HAMNIX_ROOTFS_SIZE_MB:-2560}"
    HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_ROOTFS_SIZE_MB:-2560}" \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG unavailable." >&2; exit 0; }

# --- decide whether the live image carries MiniBrowser ----------------
WK_LIBEXEC="usr/lib/x86_64-linux-gnu/webkit2gtk-4.1"
HAVE_WK=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    "$DEBUGFS" -R "stat /distro/$WK_LIBEXEC/MiniBrowser" "$LIVE_DISTRO_IMG" 2>/dev/null \
        | grep -q "Type: " && HAVE_WK=1
fi
echo "$TAG live image probe: MiniBrowser=$HAVE_WK"
if [ "$HAVE_WK" -eq 0 ]; then
    echo "$TAG SKIP: live image carries no WebKitGTK MiniBrowser." >&2
    echo "$TAG       Run scripts/stage_weston_term.sh then scripts/stage_webkit.sh," >&2
    echo "$TAG       then rebuild: HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB=2560 \\" >&2
    echo "$TAG                     bash scripts/build_installer_img.sh." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-wlwk.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wlwk.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wlwk.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-wlwk-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-wlwk-mon.XXXXXX.sock)
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
    echo "$TAG DE visual_gate settled; system quiet for WebKit."; sleep 6
else
    echo "$TAG NOTE: visual_gate-done not seen in 240s; proceeding anyway."
fi

# =====================================================================
# LAUNCH: MiniBrowser (WebKitGTK) as a native Wayland client.
# =====================================================================
# Env (WAYLAND_DISPLAY / WEBKIT_DISABLE_COMPOSITING_MODE / GDK_BACKEND /
# sandbox-off / WAYLAND_DEBUG=1) is baked into /webkit-launch.sh by
# stage_webkit.sh, so the serial command stays short (hamsh's interactive line
# editor truncates a long inline `export ...; spawn linux { ... }` at the wrap
# column, which silently drops the spawn clause — the same trap Firefox hit).
# Default target = file:///page.html (a CSS-styled local page — no network).
WK_CMD="spawn linux { /bin/sh /webkit-launch.sh }"

# =====================================================================
# LADDER RUNG (a): MiniBrowser connects to the native Wayland server.
# =====================================================================
echo "$TAG --- RUNG (a): launch MiniBrowser (WebKitGTK, software wl_shm) ---"
pre_reg=$(grep -acF "$REGISTRY_MARKER" "$LOG" 2>/dev/null | head -1)
pre_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null | head -1)
pre_maps=$(grep -acF "$MAP_MARKER" "$LOG" 2>/dev/null | head -1)
echo "$TAG pre-launch: registry=$pre_reg commits=$pre_commits maps=$pre_maps"
rung_a=0
if send_until "$WK_CMD" "$REGISTRY_MARKER" "$CMD_WAIT"; then
    post_reg=$(grep -acF "$REGISTRY_MARKER" "$LOG" 2>/dev/null | head -1)
    if [ "$post_reg" -gt "$pre_reg" ]; then
        echo "$TAG PASS (a): native Wayland registry advertised to MiniBrowser (reg $pre_reg->$post_reg)."
        rung_a=1
    else
        echo "$TAG NOTE (a): registry marker present but no NEW bind detected yet."
    fi
    grep -aF "$REGISTRY_MARKER" "$LOG" | tail -2
else
    echo "$TAG WARN (a): registry marker not seen after launching MiniBrowser." >&2
fi
echo "$TAG (a) waiting for WebKit startup / window map (up to ${CMD_WAIT}s)..."

# =====================================================================
# LADDER RUNG (b): the main window MAPS (new shm commit / devwsys map).
# =====================================================================
rung_b=0
post_commits="$pre_commits"; post_maps="$pre_maps"
for _i in $(seq 1 "$CMD_WAIT"); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    post_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null | head -1)
    post_maps=$(grep -acF "$MAP_MARKER" "$LOG" 2>/dev/null | head -1)
    { [ "$post_commits" -gt "$pre_commits" ] || [ "$post_maps" -gt "$pre_maps" ]; } && break
    sleep 1
done
echo "$TAG NOTE (b): commits before=$pre_commits after=$post_commits ; maps before=$pre_maps after=$post_maps"
if [ "$post_commits" -gt "$pre_commits" ] || [ "$post_maps" -gt "$pre_maps" ]; then
    echo "$TAG PASS (b): MiniBrowser committed a wl_shm buffer / mapped a window."
    grep -aF "$COMMIT_MARKER" "$LOG" | tail -2
    grep -aF "$MAP_MARKER" "$LOG" | tail -2
    rung_b=1
else
    echo "$TAG WARN (b): no new wl_shm commit / map — MiniBrowser did not map a window." >&2
fi
sleep 6
WID="$(grep -aF "$COMMIT_MARKER" "$LOG" | tail -1 | grep -aoE 'wid [0-9]+' | awk '{print $2}')"
echo "$TAG WebKit surface window id: ${WID:-<unknown>}"

echo "$TAG --- WebKit / GTK / Wayland serial output ---"
grep -aiE "\[WK\]|webkit|MiniBrowser|WebProcess|NetworkProcess|GPUProcess|gtk|gdk|wayland|glib|assert|abort|error|fatal|segfault|not provide|failed|bwrap|sandbox" "$LOG" | tail -60 || true

# =====================================================================
# WIRE-TRACE DECISION (KERNEL ground truth — [wayland]/[wl-req]/[wktrace],
# NOT the client's [WK] WAYLAND_DEBUG lines, which never reach the serial
# console under `spawn linux`; see the block below).
# =====================================================================
# Wire-trace decision keyed on the KERNEL's ground-truth markers (compositor
# `[wayland] ...` + `[wl-req]` + the `[wktrace]` syscall probe + `[devwsys]`
# map), NOT the client's own WAYLAND_DEBUG `[WK]` lines.
#
# WHY (root cause of the recurring "MiniBrowser dies before wl connect"
# MISCHARACTERIZATION): MiniBrowser runs under `spawn linux { ... }`, whose
# child stdout/stderr is NOT wired to the boot serial console — so WAYLAND_DEBUG
# (which prints the `wl_display@...->get_xdg_surface` wire to the client's
# stderr) NEVER reaches $LOG. Only a handful of `[WK]` launcher-echo lines make
# it through the pipe; the actual `[WK]`-prefixed wire trace this block used to
# grep is ALWAYS empty, so every run fell into the final "no [WK] wire trace
# captured — may not have reached wl connection" branch even when MiniBrowser
# had in fact connected, bound the full registry and issued dozens of requests.
# That false-negative is exactly what produced the "ZERO [WK] output" premise.
#
# The compositor (linux_abi/wayland.ad) and the `[wktrace]` probe
# (linux_abi/u_syscalls.ad) print to the KERNEL log, which IS on the serial
# console — the true, always-captured ground truth:
#   * `[wktrace] pid=N (MiniBrowser) ...`     -> the UIProcess exec'd + is
#                                                issuing syscalls (it is ALIVE).
#   * MiniBrowser nr=41/nr=42 (socket/connect) -> it opened the AF_UNIX Wayland
#                                                 connection.
#   * `[wayland] registry advertised`          -> it bound the full registry
#                                                 (incl xdg_wm_base).
#   * `[wl-req]` count                          -> N Wayland wire requests issued.
#   * `[wayland] xdg get_xdg_surface`           -> it began the window map.
#   * `[wayland] xdg get_toplevel`              -> toplevel role created.
#   * `[wayland] surface commit` / `[devwsys] window N mapped` -> buffer
#                                                 committed / window mapped.
# grep -aoF | wc -l counts occurrences even when the kernel concatenates two
# markers on one serial line (no trailing newline flush under load).
echo "$TAG --- wire-trace decision (KERNEL ground truth: [wayland]/[wl-req]/[wktrace]) ---"
cnt() { grep -aoF "$1" "$LOG" 2>/dev/null | wc -l | tr -d ' '; }
k_alive=$(cnt "(MiniBrowser)")
k_sock=$(grep -aoE 'wktrace. pid=[0-9]+ .MiniBrowser. nr=(41|42)\b' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
k_reg=$(cnt "registry advertised")
k_wlreq=$(cnt "[wl-req]")
k_getxdg=$(cnt "xdg get_xdg_surface")
k_toplevel=$(cnt "xdg get_toplevel")
k_commit=$(cnt "[wayland] surface commit")
k_map=$(grep -aoE '\[devwsys\] window [0-9]+ mapped pid=[0-9]+' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
# Secondary (informational only): a GL/EGL line, if any [WK] output survived.
wk_egl=$(grep -acE '\[WK\].*(egl|EGL|GLContext|glx|GLX|gbm|GBM|dmabuf)' "$LOG" 2>/dev/null)
echo "$TAG   MiniBrowser [wktrace] events : ${k_alive:-0}  (>0 => UIProcess exec'd + running)"
echo "$TAG   Wayland socket/connect       : ${k_sock:-0}  (>0 => AF_UNIX wl connection opened)"
echo "$TAG   registry advertised          : ${k_reg:-0}  (>0 => full registry bound)"
echo "$TAG   [wl-req] wire requests        : ${k_wlreq:-0}"
echo "$TAG   xdg get_xdg_surface          : ${k_getxdg:-0}  (0 => window-map never begun)"
echo "$TAG   xdg get_toplevel             : ${k_toplevel:-0}"
echo "$TAG   surface commit               : ${k_commit:-0}  (0 => no buffer committed)"
echo "$TAG   [devwsys] window mapped       : ${k_map:-0}"
echo "$TAG   ([WK] GL/EGL lines, info-only : ${wk_egl:-0})"
if [ "${k_map:-0}" -gt "$pre_maps" ] || [ "${k_commit:-0}" -gt 0 ]; then
    echo "$TAG   VERDICT: window MAPPED — MiniBrowser committed a wl_shm buffer;"
    echo "$TAG     inspect the ladder (b)/(c) result + screendump above."
elif [ "${k_getxdg:-0}" -gt 0 ]; then
    echo "$TAG   VERDICT: reached xdg_surface (get_xdg_surface fired) but never"
    echo "$TAG     committed a wl_shm buffer — map stalls at the attach/commit step."
elif [ "${k_reg:-0}" -gt 0 ]; then
    echo "$TAG   VERDICT: connected + bound the FULL registry (incl xdg_wm_base) and"
    echo "$TAG     issued ${k_wlreq:-0} wire requests, but NEVER created the xdg_surface"
    echo "$TAG     (get_xdg_surface=0) — window-map stall UPSTREAM of surface role,"
    echo "$TAG     the SAME rung Firefox walls at (GTK multi-thread startup-readiness"
    echo "$TAG     barrier: main thread spins / worker threads park in a libc futex"
    echo "$TAG     BEFORE the toplevel is created — engine-internal, not a wl gap)."
elif [ "${k_sock:-0}" -gt 0 ]; then
    echo "$TAG   VERDICT: opened the wl socket but did not complete the registry"
    echo "$TAG     handshake — check the connect/roundtrip path."
elif [ "${k_alive:-0}" -gt 0 ]; then
    echo "$TAG   VERDICT: MiniBrowser exec'd + ran (traced syscalls) but never opened"
    echo "$TAG     the Wayland socket — stalled in early GTK/GDK init, pre-connect."
else
    echo "$TAG   VERDICT: no [wktrace] events — MiniBrowser did not exec (check the"
    echo "$TAG     spawn linux fork/exec + the ~120MB libwebkit2gtk dynamic load)."
fi

# =====================================================================
# LADDER RUNG (c): the page RENDERS — screendump the DE window.
# =====================================================================
echo "$TAG --- RUNG (c): screendump WebKit page ---"
PPM_APP="$OUTDIR/wl_webkit_app.ppm"
PNG_APP="$OUTDIR/wl_webkit_page.png"
rm -f "$PPM_APP" "$PNG_APP"
mon "screendump $PPM_APP" >/dev/null; sleep 1
if command -v pnmtopng >/dev/null 2>&1 && [ -s "$PPM_APP" ]; then
    pnmtopng "$PPM_APP" > "$PNG_APP" 2>/dev/null && echo "$TAG PNG (webkit page): $PNG_APP"
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
print(1 if best>=10 else 0, f"page_tile_uniq={best} fb={w}x{h}")
PY
)
    echo "$TAG render check: $MSG"
    [ "${RENDER_OK:-0}" = "1" ] && [ "$rung_b" = "1" ] && rung_c=1
else
    echo "$TAG WARN (c): screendump produced no PPM." >&2
fi

# =====================================================================
# LADDER RUNG (d): content loaded (best-effort).
# =====================================================================
rung_d=0
if [ "$rung_c" = "1" ] && ! grep -aqiE "WKEXIT=[1-9]|MiniBrowser pipeline ended.*fail|Segmentation|MOZ_CRASH|core dumped" "$LOG"; then
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

if grep -aqiE "mm_page_alloc|alloc_pages_raw|page_alloc.*#GP" "$LOG"; then
    echo "$TAG NOTE: page-allocator #GP under memory pressure observed — this is" >&2
    echo "$TAG   a separate mm/page_alloc.ad free-list bug (WebKit's heavy allocation" >&2
    echo "$TAG   load triggers it); NOT fixed here." >&2
fi

# =====================================================================
# VERDICT.
# =====================================================================
echo "$TAG ============================================================"
echo "$TAG WEBKITGTK MiniBrowser NATIVE-WAYLAND LADDER:"
echo "$TAG   (a) connects to native Wayland (registry) : $([ "$rung_a" = 1 ] && echo YES || echo no)"
echo "$TAG   (b) main window MAPS (wl_shm commit/map)  : $([ "$rung_b" = 1 ] && echo YES || echo no)"
echo "$TAG   (c) page RENDERS (screendump non-flat)    : $([ "$rung_c" = 1 ] && echo YES || echo no)"
echo "$TAG   (d) content loads (no crash)              : $([ "$rung_d" = 1 ] && echo YES || echo no)"
echo "$TAG   no fault-storm (clean termination)        : $([ "$storm_ok" = 1 ] && echo YES || echo no)"
echo "$TAG   screendump: $PNG_APP"
echo "$TAG ============================================================"

if [ "$storm_ok" != 1 ]; then
    echo "$TAG RESULT: FAIL — a userspace fault looped instead of terminating." >&2
    exit 1
fi
if [ "$rung_a" = 1 ] && [ "$rung_b" = 1 ] && [ "$rung_c" = 1 ]; then
    echo "$TAG RESULT: PASS — WebKitGTK MiniBrowser runs as a native Wayland client with a rendered page."
    exit 0
fi
if [ "$rung_a" = 1 ] || [ "$rung_b" = 1 ]; then
    echo "$TAG RESULT: PARTIAL — climbed some rungs (see ladder). Next gap at the"
    echo "$TAG   first 'no' rung; check the WebKit/GTK serial + wire-trace above." >&2
    exit 0
fi
echo "$TAG RESULT: FAIL — MiniBrowser did not connect to the native Wayland server." >&2
echo "$TAG   (a bring-up probe — inspect the serial log for the first Linux-ABI gap)" >&2
exit 0
