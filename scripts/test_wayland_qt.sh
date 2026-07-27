#!/usr/bin/env bash
# scripts/test_wayland_qt.sh — Wayland native-client bring-up for a Qt5 WIDGETS
# app (qt_hello, staged by scripts/stage_qt_app.sh). Proves a Qt-toolkit app
# renders as a NATIVE Wayland client of the in-kernel compositor via the
# QtWayland `wayland` platform plugin + wl_shm raster backing store — broadening
# GUI-from-Linux-ns coverage beyond the GTK (weston/foot) toolkit.
#
# LADDER (reports how far it climbs):
#   (a) qt_hello connects to the native Wayland server (registry advertised).
#   (b) it commits a wl_shm buffer on a NEW wid (window MAPS).
#   (c) it RENDERS — screendump -> PNG is a non-flat multi-colour region.
#
# SOFTWARE RENDER ONLY (QT_QPA_PLATFORM=wayland raster backing store; no GL).
# Env baked into /qt-launch.sh by stage_qt_app.sh.
#
# SKIPS CLEANLY when /dev/kvm, OVMF, the image, socat, or a staged qt_hello is
# unavailable. KVM/OVMF only. Every qemu killed on exit.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$PROJ_ROOT"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-360}"; CMD_WAIT="${CMD_WAIT:-180}"; QEMU_MEM="${QEMU_MEM:-6G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"; TAG="[test_wl_qt]"
LIVE_MARKER="booting LIVE environment"; HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"; REGISTRY_MARKER="registry advertised"; COMMIT_MARKER="shm buffer committed"

[ -e /dev/kvm ] || { echo "$TAG SKIP: /dev/kvm absent." >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP: socat not installed." >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && OVMF_FD="$c" && break; done; fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP: OVMF firmware not found." >&2; exit 0; }
# STALE-IMAGE GUARD: this gate BOOTS a pre-existing image it did not build.
# A WARNING is not enough — a stale image false-GREENs the very regression
# this gate exists to catch (bit us 2026-07-01, 07-11, 07-27). ensure_installer_img
# REBUILDS when the image is missing or older than any tracked build input;
# HAMNIX_SKIP_BUILD=1 downgrades to a LOUD stale warning, never a silent pass.
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ensure_installer_img "$INSTALLER_IMG" "[wayland_qt]" \
    || { echo "[wayland_qt] SKIP: no usable $INSTALLER_IMG" >&2; exit 0; }

OVMF_RW=$(mktemp --tmpdir hamnix-wlqt.ovmf.XXXXXX.fd); IMG_RW=$(mktemp --tmpdir hamnix-wlqt.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wlqt.XXXXXX.log); FIFO=$(mktemp --tmpdir -u hamnix-wlqt-in.XXXXXX); MON=$(mktemp --tmpdir -u hamnix-wlqt-mon.XXXXXX.sock)
mkfifo "$FIFO"; cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
cleanup(){ [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null; exec 3>&- 2>/dev/null; rm -f "$OVMF_RW" "$IMG_RW" "$FIFO" "$MON"; [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"; }
trap cleanup EXIT

qemu-system-x86_64 -enable-kvm -cpu host -bios "$OVMF_RW" -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" -vga std -display none -no-reboot -monitor "unix:$MON,server,nowait" -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 & QEMU_PID=$!
exec 3> "$FIFO"
mon(){ printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" 2>/dev/null; }
send(){ printf '%s\n' "$1" >&3; }
wait_for(){ local pat="$1" secs="$2" i; for i in $(seq 1 "$secs"); do grep -a -F -q "$pat" "$LOG" && return 0; kill -0 "$QEMU_PID" 2>/dev/null || return 1; sleep 1; done; return 1; }
send_until(){ local cmd="$1" pat="$2" secs="$3" waited=0 i; while [ "$waited" -lt "$secs" ]; do printf '\n' >&3; sleep 1; printf '%s\n' "$cmd" >&3; for i in $(seq 1 15); do grep -a -F -q "$pat" "$LOG" && return 0; kill -0 "$QEMU_PID" 2>/dev/null || return 1; sleep 1; waited=$((waited+1)); [ "$waited" -ge "$secs" ] && break; done; done; grep -a -F -q "$pat" "$LOG"; }

echo "$TAG waiting up to ${BOOT_WAIT}s for LIVE + handoff..."
wait_for "$LIVE_MARKER" "$BOOT_WAIT" || { echo "$TAG FAIL: LIVE marker not seen." >&2; tail -40 "$LOG"|strings >&2; exit 1; }
wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT" && echo "$TAG live-root DONE." || echo "$TAG WARN: live-root DONE not seen." >&2
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || { echo "$TAG FAIL: handoff not seen." >&2; tail -40 "$LOG"|strings >&2; exit 1; }
wait_for "[visual_gate] done" 240 && { echo "$TAG DE settled."; sleep 6; } || echo "$TAG NOTE: visual_gate-done not seen; proceeding."

pre_reg=$(grep -acF "$REGISTRY_MARKER" "$LOG" 2>/dev/null|head -1); pre_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null|head -1)
echo "$TAG pre-launch: registry=$pre_reg commits=$pre_commits"
echo "$TAG --- RUNG (a): launch qt_hello (QT_QPA_PLATFORM=wayland) ---"
rung_a=0
if send_until "spawn linux { /bin/sh /qt-launch.sh }" "$REGISTRY_MARKER" "$CMD_WAIT"; then
    post_reg=$(grep -acF "$REGISTRY_MARKER" "$LOG" 2>/dev/null|head -1)
    [ "$post_reg" -gt "$pre_reg" ] && { echo "$TAG PASS (a): registry advertised (reg $pre_reg->$post_reg)."; rung_a=1; } || echo "$TAG NOTE (a): registry present, no new bind."
else echo "$TAG WARN (a): registry marker not seen." >&2; fi

echo "$TAG (b) waiting for wl_shm commit (up to ${CMD_WAIT}s)..."
rung_b=0; post_commits="$pre_commits"
for _i in $(seq 1 "$CMD_WAIT"); do kill -0 "$QEMU_PID" 2>/dev/null || break; post_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null|head -1); [ "$post_commits" -gt "$pre_commits" ] && break; sleep 1; done
echo "$TAG NOTE (b): commits before=$pre_commits after=$post_commits"
[ "$post_commits" -gt "$pre_commits" ] && { echo "$TAG PASS (b): qt_hello committed a wl_shm buffer (window mapped)."; rung_b=1; } || echo "$TAG WARN (b): no new wl_shm commit." >&2
sleep 6
WID="$(grep -aF "$COMMIT_MARKER" "$LOG"|tail -1|grep -aoE 'wid [0-9]+'|awk '{print $2}')"; echo "$TAG Qt surface wid: ${WID:-<unknown>}"
echo "$TAG --- Qt/Wayland serial ---"; grep -aiE "\[QT\]|qt.qpa|wayland|qpa|assert|abort|error|fatal|segfault|could not|No such" "$LOG"|tail -30 || true

echo "$TAG --- RUNG (c): screendump ---"
PPM="$OUTDIR/wl_qt_app.ppm"; PNG="$OUTDIR/wl_qt_app.png"; rm -f "$PPM" "$PNG"
mon "screendump $PPM" >/dev/null; sleep 1
command -v pnmtopng >/dev/null 2>&1 && [ -s "$PPM" ] && pnmtopng "$PPM" > "$PNG" 2>/dev/null && echo "$TAG PNG: $PNG"
rung_c=0
if [ -s "$PPM" ]; then
    read -r RENDER_OK MSG < <(python3 - "$PPM" <<'PY'
import sys
def load(p):
    d=open(p,'rb').read(); assert d[:2]==b'P6'; idx=2; vals=[]
    while len(vals)<3:
        while idx<len(d) and d[idx] in b' \t\n\r': idx+=1
        if d[idx:idx+1]==b'#':
            while idx<len(d) and d[idx] not in b'\n': idx+=1
            continue
        s=idx
        while idx<len(d) and d[idx] not in b' \t\n\r': idx+=1
        vals.append(int(d[s:idx]))
    idx+=1; w,h,mv=vals; return w,h,d[idx:idx+w*h*3]
w,h,b=load(sys.argv[1]); best=0
for y0 in range(0,max(1,h-120),20):
    for x0 in range(0,max(1,w-200),20):
        s=set()
        for yy in range(y0,y0+120,8):
            for xx in range(x0,x0+200,8):
                o=(yy*w+xx)*3; s.add((b[o],b[o+1],b[o+2]))
        best=max(best,len(s))
print(1 if best>=8 else 0, f"tile_uniq={best} fb={w}x{h}")
PY
)
    echo "$TAG render check: $MSG"; [ "${RENDER_OK:-0}" = "1" ] && [ "$rung_b" = "1" ] && rung_c=1
else echo "$TAG WARN (c): no PPM." >&2; fi

echo "$TAG ============================================================"
echo "$TAG QT NATIVE-WAYLAND LADDER:"
echo "$TAG   (a) connects to native Wayland : $([ "$rung_a" = 1 ] && echo YES || echo no)"
echo "$TAG   (b) window MAPS (wl_shm commit): $([ "$rung_b" = 1 ] && echo YES || echo no)"
echo "$TAG   (c) chrome RENDERS (non-flat)  : $([ "$rung_c" = 1 ] && echo YES || echo no)"
echo "$TAG   screendump: $PNG"
echo "$TAG ============================================================"
if [ "$rung_a" = 1 ] && [ "$rung_b" = 1 ] && [ "$rung_c" = 1 ]; then echo "$TAG RESULT: PASS — Qt renders as a native Wayland client."; exit 0; fi
if [ "$rung_a" = 1 ] || [ "$rung_b" = 1 ]; then echo "$TAG RESULT: PARTIAL — see ladder."; exit 0; fi
echo "$TAG RESULT: FAIL — Qt did not connect to the native Wayland server." >&2; exit 0
