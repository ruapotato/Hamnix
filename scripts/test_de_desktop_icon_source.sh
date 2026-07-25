#!/usr/bin/env bash
# scripts/test_de_desktop_icon_source.sh — the desktop icon grid must come from
# the USER'S ~/Desktop, never from the filesystem root.
#
# THE BUG THIS GATES (USER report: "The desktop is showing root not ~/Desktop").
# hamdesktop scans a directory and turns every visible entry into a desktop
# icon. It is supposed to scan /home/live/Desktop (16 shipped .desktop
# launchers). On the live image the STARTUP scan was correct, but the ~1s
# periodic re-scan then rebuilt the grid from the filesystem ROOT — icons
# labelled bin / etc / lib / usr. The browse core's current-path global was
# lost between passes, and BOTH layers then degraded silently: an empty path
# defaulted to "/" in fmc_set_cur_path, and the listing code happily listed
# it. The fix re-asserts the desktop dir before every re-scan and makes an
# empty/relative path a NON-listing (never a root listing).
#
# WHAT IT ASSERTS on a REAL UEFI/OVMF boot of the installer image:
#   1. hamdesktop publishes its icon source to /tmp/.hamdesktop.src as
#        src=<dir> n=<count>
#      (re-written on every icon-model rebuild, so it reflects the LIVE grid,
#      not just the startup scan). src MUST be a Desktop dir, never "/".
#   2. n >= 4 — the shipped launchers were actually listed (the built-in
#      fallback set is 3 icons, so >= 4 proves a real ~/Desktop listing).
#   3. `ls /home/live/Desktop` in the guest lists the shipped launchers
#      (structural cross-check that the grid and the shell agree).
#   4. A framebuffer screendump is captured for visual inspection.
#
# SKIPS CLEANLY (exit 0) when KVM/OVMF/socat/the image are unavailable.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
MIN_ICONS="${MIN_ICONS:-4}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_desktop_icon_source/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

# --- structural guard: the launcher templates are shipped ---------------
if [ ! -d etc/skel/Desktop ]; then
    echo "[deskicons] FAIL: etc/skel/Desktop missing (no launcher templates)" >&2
    exit 1
fi
n_skel=$(ls etc/skel/Desktop/*.desktop 2>/dev/null | wc -l)
if [ "$n_skel" -lt 4 ]; then
    echo "[deskicons] FAIL: only $n_skel launcher templates in etc/skel/Desktop" >&2
    exit 1
fi
echo "[deskicons] structural OK: $n_skel launcher templates in etc/skel/Desktop"

# --- environment gates --------------------------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[deskicons] SKIP-RUNTIME: /dev/kvm absent (structural PASS)" >&2; exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || {
    echo "[deskicons] SKIP-RUNTIME: OVMF firmware not found" >&2; exit 0; }
MON_DRIVER=""
command -v socat >/dev/null 2>&1 && MON_DRIVER=socat
[ -z "$MON_DRIVER" ] && command -v nc >/dev/null 2>&1 && MON_DRIVER=nc
[ -n "$MON_DRIVER" ] || {
    echo "[deskicons] SKIP-RUNTIME: no socat/nc for the QEMU monitor" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || {
    echo "[deskicons] SKIP-RUNTIME: $INSTALLER_IMG absent (build it first)" >&2; exit 0; }
# Stale-artifact guard: this gate BOOTS a pre-existing image it did not
# build. Booting a stale one silently is the 2026-07-24 false-negative
# class — be loud about it. shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
installer_img_warn_if_stale "$INSTALLER_IMG" "[de_desktop_icon_source]"

mkdir -p "$OUT_DIR"
echo "[deskicons] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-deskicons.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-deskicons.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-deskicons-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-deskicons.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
}
trap cleanup EXIT
exec 4<>"$FIFO"
exec 3>"$FIFO"

mon_cmd() {
    if [ "$MON_DRIVER" = socat ]; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    else
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    fi
}

snapshot() {
    local label="$1" ppm="$OUT_DIR/$1.ppm"
    rm -f "$ppm"
    mon_cmd "screendump $ppm" || return 1
    local i=0
    while [ "$i" -lt 40 ]; do [ -s "$ppm" ] && break; sleep 0.1; i=$((i+1)); done
    [ -s "$ppm" ] || return 1
    sleep 0.4
    command -v convert >/dev/null 2>&1 && convert "$ppm" "$OUT_DIR/$label.png" 2>/dev/null
    return 0
}

wait_for() {
    local pat="$1" timeout="$2" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[deskicons] waiting up to ${BOOT_WAIT}s for the DE handoff..."
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "[deskicons] FAIL: handoff marker not seen in ${BOOT_WAIT}s" >&2
    tail -60 "$LOG" >&2; exit 1
fi
sleep 8

fail=0
say_fail() { echo "[deskicons] FAIL $*" >&2; fail=1; }

snapshot desktop_icons || say_fail "could not screendump the desktop"

# --- 1-3: the icon-source marker ----------------------------------------
# hamdesktop publishes "src=<dir> n=<count>" to /tmp/.hamdesktop.src every time
# it (re)builds the icon model. stdout of a compositor-spawned DE client does
# NOT reach the serial console, so read the file through the guest shell.
printf 'echo MARK_READY\n' >&3
sleep 1
wait_for MARK_READY 12 || { printf 'echo MARK_READY\n' >&3; sleep 2; }
printf 'echo BEGIN_SRC; cat /tmp/.hamdesktop.src; echo END_SRC\n' >&3
d=$(( SECONDS + 25 ))
while [ "$SECONDS" -lt "$d" ]; do grep -aq END_SRC "$LOG" && break; sleep 1; done
sed -n '/BEGIN_SRC/,/END_SRC/p' "$LOG" > "$OUT_DIR/icon_src.txt"

src_line=$(grep -ao 'src=[^ ]* n=[0-9]*' "$OUT_DIR/icon_src.txt" | tail -1)
if [ -z "$src_line" ]; then
    say_fail "hamdesktop published no icon-source marker (/tmp/.hamdesktop.src)"
else
    echo "[deskicons] marker: $src_line"
    src=$(printf '%s' "$src_line" | sed -n 's/^src=\([^ ]*\).*/\1/p')
    cnt=$(printf '%s' "$src_line" | sed -n 's/.*n=\([0-9]*\).*/\1/p')
    case "$src" in
        */Desktop) echo "[deskicons] PASS icon source is a Desktop dir: $src" ;;
        /)         say_fail "icon source degraded to the filesystem ROOT" ;;
        *)         say_fail "icon source is not a Desktop dir: '$src'" ;;
    esac
    if [ "${cnt:-0}" -ge "$MIN_ICONS" ]; then
        echo "[deskicons] PASS $cnt icons built from ~/Desktop (>= $MIN_ICONS)"
    else
        say_fail "only ${cnt:-0} icons built (< $MIN_ICONS) — fallback set?"
    fi
fi

# --- 4: the guest shell agrees ------------------------------------------
printf 'echo BEGIN_DESKDIR; ls /home/live/Desktop; echo END_DESKDIR\n' >&3
d=$(( SECONDS + 25 ))
while [ "$SECONDS" -lt "$d" ]; do grep -aq END_DESKDIR "$LOG" && break; sleep 1; done
sed -n '/BEGIN_DESKDIR/,/END_DESKDIR/p' "$LOG" > "$OUT_DIR/desk_dir.txt"
n_listed=$(grep -ao '[A-Za-z0-9_-]*\.desktop' "$OUT_DIR/desk_dir.txt" | sort -u | wc -l)
if [ "$n_listed" -ge "$MIN_ICONS" ]; then
    echo "[deskicons] PASS guest ls ~/Desktop lists $n_listed launchers"
else
    say_fail "guest ls /home/live/Desktop listed only $n_listed launchers"
fi

if [ "$fail" -eq 0 ]; then
    echo "[deskicons] PASS — desktop icon grid is sourced from ~/Desktop"
    exit 0
fi
echo "[deskicons] FAIL — see $OUT_DIR" >&2
exit 1
