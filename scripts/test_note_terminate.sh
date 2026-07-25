#!/usr/bin/env bash
# scripts/test_note_terminate.sh — `kill <pid>` (Plan 9 note) must actually
# terminate a handler-less process.
#
# Boots the shipped image, launches a DE app through the launch queue, finds
# its pid in /proc/tasks, writes the Plan 9 "terminate" note to
# /proc/<pid>/note (what user/kill.ad, hamUI/hamUId close and the panel's
# menu toggles all do), and asserts the task actually exits (code=143) and
# its window slot is reclaimed.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$PROJ_ROOT"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
OUT_DIR="${OUT_DIR:-build/note_terminate/$(date +%Y%m%d-%H%M%S)}"
[ -e /dev/kvm ] || { echo "[note] SKIP-RUNTIME: no kvm" >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
  for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    [ -f "$c" ] && OVMF_FD="$c" && break; done
fi
[ -f "$OVMF_FD" ] || { echo "[note] SKIP-RUNTIME: no OVMF" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "[note] SKIP-RUNTIME: no image" >&2; exit 0; }
mkdir -p "$OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-note.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-note.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
FIFO=$(mktemp -u --tmpdir hamnix-note.XXXXXX).in; mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
QEMU_PID=""
cleanup(){ [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null; rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"; }
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"
wait_for(){ local d=$(( SECONDS + $2 )); while [ "$SECONDS" -lt "$d" ]; do
    grep -aqE "$1" "$LOG" && return 0; sleep 1; done; return 1; }
qemu-system-x86_64 -enable-kvm -cpu host -bios "$OVMF_RW" \
  -drive file="$IMG_RW",format=raw,if=virtio -m 1G \
  -vga std -display none -no-reboot -serial stdio <&4 > "$LOG" 2>&1 &
QEMU_PID=$!
wait_for "handing off to interactive shell" "$BOOT_WAIT" || { echo "[note] FAIL: no handoff" >&2; exit 1; }
sleep 6
printf 'echo MARK_READY\n' >&3; sleep 2
fail=0
# 1) launch an app and grab its pid off the map line
# Launch the app AS A CHILD OF THIS SHELL so the note write passes
# devproc's caller-uid == target-uid gate (the DE's own close paths are
# always same-uid: the panel notes its own children).
printf '/bin/hammonscene &\n' >&3
wait_for "\[devwsys\] window .* mapped" 30 || { echo "[note] FAIL: app never mapped" >&2; exit 1; }
sleep 3
line=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)
pid=$(echo "$line" | sed -n 's/.*mapped pid=\([0-9]*\).*/\1/p')
wid=$(echo "$line" | sed -n 's/.*window \([0-9]*\) mapped.*/\1/p')
echo "[note] app pid=$pid wid=$wid"
# 2) Plan 9 note -> must terminate it. Probe BOTH userland spellings:
#    /bin/kill (lib/p9.ad p9_note, what the DE uses) and a shell redirect.
printf 'echo PROBE_LS; ls /proc/%s\n' "$pid" >&3
sleep 3
printf '/bin/kill %s\n' "$pid" >&3
sleep 3
printf 'echo terminate > /proc/%s/note\n' "$pid" >&3
if wait_for "task: pid $pid exited" 20; then
    echo "[note] PASS terminate note killed pid $pid: $(grep -a "task: pid $pid exited" "$LOG" | tail -1)"
else
    echo "[note] FAIL: pid $pid survived the terminate note" >&2; fail=1
fi
# 3) the wid slot must come back (reaped on the next windows read)
sleep 3
printf 'echo WINS; cat /dev/wsys/windows\n' >&3
sleep 3
if sed -n '/WINS/,$p' "$LOG" | grep -aqE "^$wid "; then
    echo "[note] FAIL: wid $wid still listed after the client died" >&2; fail=1
else
    echo "[note] PASS wid $wid reclaimed"
fi
exec 3>&-; sleep 0.5; kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""
echo "[note] log: $LOG"
[ "$fail" -eq 0 ] && { echo "[note] OVERALL PASS"; exit 0; }
echo "[note] OVERALL FAIL"; exit 1
