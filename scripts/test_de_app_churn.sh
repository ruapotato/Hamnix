#!/usr/bin/env bash
# scripts/test_de_app_churn.sh — open/close a SERIES of desktop apps and prove
# the session neither wedges nor kills its clients.
#
# USER-REPORTED FAILURE (2026-07-17): after booting the desktop and opening a
# few apps (Applications menu, System Monitor, Audio Player) the box HUNG —
# the serial went silent right after several apps mapped a window and then
# exited with code=143 (SIGTERM) they never asked for.
#
# What this gate does, on the SHIPPED installer image under OVMF:
#   1. boot to the DE handoff;
#   2. launch N apps through the real DE launch queue (/dev/wsys/run/launch,
#      the same path the Applications menu uses), interleaving the app menu,
#      System Monitor and the Audio Player, closing each one via its own
#      per-window /ctl `close` verb (the compositor's close path);
#   3. after EVERY launch, prove the box is still alive by round-tripping an
#      echo marker over the serial console (a wedged scheduler/compositor
#      never answers) and by screendumping the framebuffer;
#   4. FAIL on any unexpected exit code=143, on a missed liveness marker, or
#      on a launch that never maps a window.
#
# Env overrides: INSTALLER_IMG, OVMF_FD, BOOT_WAIT, OUT_DIR, ROUNDS.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
ROUNDS="${ROUNDS:-3}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_app_churn/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

if [ ! -e /dev/kvm ]; then echo "[churn] SKIP-RUNTIME: /dev/kvm absent" >&2; exit 0; fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "[churn] SKIP-RUNTIME: no OVMF" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[churn] SKIP-RUNTIME: no socat" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "[churn] SKIP-RUNTIME: $INSTALLER_IMG absent" >&2; exit 0; }

mkdir -p "$OUT_DIR"
echo "[churn] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-churn.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-churn.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-churn-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-churn.XXXXXX).in
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

mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1; }

snapshot() {
    local label="$1" ppm="$OUT_DIR/$1.ppm"
    rm -f "$ppm"
    mon_cmd "screendump $ppm" || return 1
    local i=0
    while [ "$i" -lt 40 ]; do [ -s "$ppm" ] && break; sleep 0.1; i=$((i+1)); done
    [ -s "$ppm" ] || return 1
    sleep 0.3
    command -v convert >/dev/null 2>&1 && convert "$ppm" "$OUT_DIR/$1.png" 2>/dev/null
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

echo "[churn] waiting up to ${BOOT_WAIT}s for the DE handoff..."
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "[churn] FAIL: handoff marker not seen" >&2; tail -60 "$LOG" >&2; exit 1
fi
sleep 6
printf 'echo MARK_CHURN_READY\n' >&3
sleep 1
wait_for MARK_CHURN_READY 12 || { printf 'echo MARK_CHURN_READY\n' >&3; sleep 2; }

fail=0
say_fail() { echo "[churn] FAIL $*" >&2; fail=1; }

alive_n=0
# Round-trip a marker through the interactive shell: a wedged box never answers.
assert_alive() {                    # assert_alive <label>
    alive_n=$((alive_n+1))
    local m="MARK_ALIVE_${alive_n}"
    printf 'echo %s\n' "$m" >&3
    local d=$(( SECONDS + 20 ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "$m" "$LOG" && { echo "[churn] alive after $1"; return 0; }
        sleep 1
    done
    say_fail "SYSTEM WEDGED after $1 (no serial response in 20s)"
    return 1
}

sig143_base=0
check_sigterm() {                   # check_sigterm <label>
    local n
    n=$(grep -ac "exited (code=143)" "$LOG")
    if [ "$n" -gt "$sig143_base" ]; then
        say_fail "unexpected SIGTERM exit after $1: $(grep -a 'exited (code=143)' "$LOG" | tail -1)"
        sig143_base=$n
    fi
}

launch_app() {                      # launch_app <prog> <label>
    local prog="$1" label="$2" before after
    before=$(grep -ac "\[devwsys\] window .* mapped" "$LOG")
    printf 'echo %s > /dev/wsys/run/launch\n' "$prog" >&3
    local d=$(( SECONDS + 30 ))
    while [ "$SECONDS" -lt "$d" ]; do
        after=$(grep -ac "\[devwsys\] window .* mapped" "$LOG")
        [ "$after" -gt "$before" ] && break
        sleep 1
    done
    if [ "${after:-0}" -gt "$before" ]; then
        echo "[churn] $label mapped: $(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)"
    else
        say_fail "$label ($prog) mapped NO window in 30s"
    fi
    sleep 3
    snapshot "$label"
    check_sigterm "$label"
    assert_alive "$label" || return 1
    return 0
}

# Close the newest decorated window through the compositor's own close path.
close_top() {                       # close_top <wid> <label>
    printf 'echo close > /dev/wsys/%s/ctl\n' "$1" >&3
    sleep 3
    check_sigterm "close $2"
    assert_alive "close $2" || return 1
    return 0
}

snapshot 000_idle_desktop

APPS="/bin/hammonscene /bin/hamaudioscene /bin/hamappmenu /bin/hamfmscene /bin/hamnotesscene /bin/hamcalcscene"

i=0
r=1
while [ "$r" -le "$ROUNDS" ]; do
    for a in $APPS; do
        i=$((i+1))
        n=$(printf '%03d' "$i")
        base="$(basename "$a")"
        launch_app "$a" "${n}_r${r}_${base}" || break 2
        # ask the just-mapped window to close itself (compositor close path)
        wid=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1 \
              | sed -n 's/.*window \([0-9]*\) mapped.*/\1/p')
        [ -n "$wid" ] && close_top "$wid" "${n}_${base}"
    done
    r=$((r+1))
done

snapshot 999_final_desktop
assert_alive "final"

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

echo "[churn] launches: $i, windows mapped: $(grep -ac '\[devwsys\] window .* mapped' "$LOG")"
echo "[churn] code=143 exits: $(grep -ac 'exited (code=143)' "$LOG")"
echo "[churn] PNGs + serial.log: $OUT_DIR"
[ "$fail" -ne 0 ] && { echo "[churn] OVERALL FAIL"; exit 1; }
echo "[churn] OVERALL PASS"
