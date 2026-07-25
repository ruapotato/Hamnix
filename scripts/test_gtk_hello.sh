#!/usr/bin/env bash
# scripts/test_gtk_hello.sh — the MINIMAL-GTK repro for the "GTK/GDK apps park
# before get_xdg_surface" hypothesis. Launches a ~20-line GTK3 toplevel
# (usr/bin/gtk-hello, staged from the host libgtk-3) as a native Wayland client
# of the in-kernel compositor, with WAYLAND_DEBUG=1, and reports EXACTLY which
# xdg-shell rung it reaches:
#   (a) connects to the native Wayland server (registry advertised)
#   (b) get_xdg_surface fires (compositor "[wayland] xdg get_xdg_surface")
#   (c) window MAPS (a NEW "[devwsys] window N mapped" / shm commit)
#
# If gtk-hello MAPS, the "common GDK gate" hypothesis is DISPROVEN — Firefox/
# WebKit stall for a heavier (multiprocess) reason. If it stalls at the SAME
# rung (binds xdg_wm_base, never get_xdg_surface), the GDK gate is confirmed +
# cheaply debuggable here. Same skip/partial discipline as test_webkit.sh.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$PROJ_ROOT"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-700}"; CMD_WAIT="${CMD_WAIT:-200}"; QEMU_MEM="${QEMU_MEM:-6G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"; TAG="[test_gtk_hello]"
LIVE_MARKER="booting LIVE environment"; HANDOFF_MARKER="handing off to interactive shell"
REGISTRY_MARKER="registry advertised"
GETXDG_MARKER="xdg get_xdg_surface"
# A native-DE window logs "[devwsys] window N mapped pid="; a WAYLAND client
# instead commits its wl_shm buffer into a Wayland window slot, logged by the
# compositor as "shm buffer committed ... nonzero_px=" — THAT is the map-success
# marker for a wl client (same as test_webkit.sh's COMMIT_MARKER).
MAP_MARKER="shm buffer committed"

[ -e /dev/kvm ] || { echo "$TAG SKIP: /dev/kvm absent." >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP: socat absent." >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && OVMF_FD="$c" && break; done; fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP: OVMF not found." >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG absent." >&2; exit 0; }
# Stale-artifact guard: this gate BOOTS a pre-existing image it did not
# build. Booting a stale one silently is the 2026-07-24 false-negative
# class — be loud about it. shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
installer_img_warn_if_stale "$INSTALLER_IMG" "[gtk_hello]"

OVMF_RW=$(mktemp --tmpdir hamnix-gtkh.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-gtkh.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-gtkh.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-gtkh-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-gtkh-mon.XXXXXX.sock)
mkfifo "$FIFO"; cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() { [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null; exec 3>&- 2>/dev/null; rm -f "$OVMF_RW" "$IMG_RW" "$FIFO" "$MON"; [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"; }
trap cleanup EXIT
qemu-system-x86_64 -enable-kvm -cpu host -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio -m "$QEMU_MEM" \
    -vga std -display none -no-reboot -monitor "unix:$MON,server,nowait" \
    -serial stdio < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!; exec 3> "$FIFO"
mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" 2>/dev/null; }
wait_for() { local pat="$1" secs="$2" i; for i in $(seq 1 "$secs"); do grep -a -F -q "$pat" "$LOG" && return 0; kill -0 "$QEMU_PID" 2>/dev/null || return 1; sleep 1; done; return 1; }
send_until() { local cmd="$1" pat="$2" secs="$3" waited=0 i; while [ "$waited" -lt "$secs" ]; do printf '\n' >&3; sleep 1; printf '%s\n' "$cmd" >&3; for i in $(seq 1 15); do grep -a -F -q "$pat" "$LOG" && return 0; kill -0 "$QEMU_PID" 2>/dev/null || return 1; sleep 1; waited=$((waited+1)); [ "$waited" -ge "$secs" ] && break; done; done; grep -a -F -q "$pat" "$LOG"; }

echo "$TAG waiting up to ${BOOT_WAIT}s for LIVE branch + handoff..."
wait_for "$LIVE_MARKER" "$BOOT_WAIT" || { echo "$TAG FAIL: LIVE marker not seen." >&2; tail -40 "$LOG" | strings >&2; exit 1; }
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || { echo "$TAG FAIL: handoff not seen." >&2; tail -40 "$LOG" | strings >&2; exit 1; }
wait_for "ed-readline-first" 30 || sleep 3
wait_for "[visual_gate] done" 240 && { echo "$TAG DE settled."; sleep 6; } || echo "$TAG NOTE: visual_gate-done not seen; proceeding."

pre_reg=$(grep -acF "$REGISTRY_MARKER" "$LOG" 2>/dev/null | head -1)
pre_xdg=$(grep -acF "$GETXDG_MARKER" "$LOG" 2>/dev/null | head -1)
pre_map=$(grep -acF "$MAP_MARKER" "$LOG" 2>/dev/null | head -1)
echo "$TAG pre-launch: registry=$pre_reg getxdg=$pre_xdg maps=$pre_map"
GTK_CMD="spawn linux { /bin/sh /gtk-launch.sh }"
echo "$TAG --- launch gtk-hello (GTK3, software wl_shm) ---"
rung_a=0
if send_until "$GTK_CMD" "$REGISTRY_MARKER" "$CMD_WAIT"; then
    post_reg=$(grep -acF "$REGISTRY_MARKER" "$LOG" 2>/dev/null | head -1)
    [ "$post_reg" -gt "$pre_reg" ] && { echo "$TAG PASS (a): registry advertised to gtk-hello (reg $pre_reg->$post_reg)."; rung_a=1; }
else echo "$TAG WARN (a): registry marker not seen after launch." >&2; fi

echo "$TAG (a) waiting for get_xdg_surface / map (up to ${CMD_WAIT}s)..."
rung_b=0; rung_c=0; post_xdg="$pre_xdg"; post_map="$pre_map"
for _i in $(seq 1 "$CMD_WAIT"); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    post_xdg=$(grep -acF "$GETXDG_MARKER" "$LOG" 2>/dev/null | head -1)
    post_map=$(grep -acF "$MAP_MARKER" "$LOG" 2>/dev/null | head -1)
    { [ "$post_xdg" -gt "$pre_xdg" ] || [ "$post_map" -gt "$pre_map" ]; } && break
    sleep 1
done
[ "$post_xdg" -gt "$pre_xdg" ] && { echo "$TAG PASS (b): gtk-hello issued get_xdg_surface (xdg $pre_xdg->$post_xdg)."; rung_b=1; } || echo "$TAG WARN (b): NO get_xdg_surface — parked after xdg_wm_base bind." >&2
sleep 4
post_map=$(grep -acF "$MAP_MARKER" "$LOG" 2>/dev/null | head -1)
[ "$post_map" -gt "$pre_map" ] && { echo "$TAG PASS (c): a NEW window mapped (maps $pre_map->$post_map)."; rung_c=1; } || echo "$TAG WARN (c): no new window map." >&2

echo "$TAG --- GTK / GDK / Wayland serial (last 60) ---"
grep -aiE "\[GTKH\]|\[GTKHELLO\]|\[wl-req\]|\[wayland\]|gtk|gdk|wayland|assert|abort|error|fatal|segfault|GTKEXIT" "$LOG" | tail -60 || true

echo "$TAG --- wire-trace decision ---"
gtk_getxdg=$(grep -acE '(get_xdg_surface|xdg_wm_base#[0-9]+\.get_xdg_surface|\[wayland\] xdg get_xdg_surface)' "$LOG" 2>/dev/null)
gtk_commit=$(grep -acE '(wl_surface#[0-9]+\.commit|\[wayland\] surface commit)' "$LOG" 2>/dev/null)
gtk_shmpool=$(grep -acE 'wl_shm(#[0-9]+)?\.create_pool|\[wayland\] create_buffer' "$LOG" 2>/dev/null)
echo "$TAG   get_xdg_surface : ${gtk_getxdg:-0}"
echo "$TAG   surface commit  : ${gtk_commit:-0}"
echo "$TAG   shm pool/buffer : ${gtk_shmpool:-0}"
if [ "${gtk_getxdg:-0}" -gt 0 ]; then
    echo "$TAG   VERDICT: gtk-hello REACHED get_xdg_surface -> the common-GDK-gate hypothesis is DISPROVEN for a minimal app; browsers stall for a heavier reason."
else
    echo "$TAG   VERDICT: gtk-hello PARKED before get_xdg_surface -> the GDK gate is CONFIRMED and reproduced on a minimal app."
fi

echo "$TAG --- screendump ---"
PPM="$OUTDIR/wl_gtkhello.ppm"; PNG="$OUTDIR/wl_gtkhello.png"; rm -f "$PPM" "$PNG"
mon "screendump $PPM" >/dev/null; sleep 1
command -v pnmtopng >/dev/null 2>&1 && [ -s "$PPM" ] && pnmtopng "$PPM" > "$PNG" 2>/dev/null && echo "$TAG PNG: $PNG"

echo "$TAG ============================================================"
echo "$TAG MINIMAL GTK3 NATIVE-WAYLAND LADDER:"
echo "$TAG   (a) connects (registry)        : $([ "$rung_a" = 1 ] && echo YES || echo no)"
echo "$TAG   (b) get_xdg_surface fires      : $([ "$rung_b" = 1 ] && echo YES || echo no)"
echo "$TAG   (c) window MAPS                : $([ "$rung_c" = 1 ] && echo YES || echo no)"
echo "$TAG ============================================================"
exit 0
