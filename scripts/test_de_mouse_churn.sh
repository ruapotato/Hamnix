#!/usr/bin/env bash
# scripts/test_de_mouse_churn.sh — drive the desktop WITH THE MOUSE the way a
# user does: click desktop launcher icons, click the Applications menu, and
# CLOSE each window with its titlebar close box — repeatedly.
#
# USER-REPORTED FAILURE (2026-07-17): after opening a few apps (app menu,
# System Monitor, Audio Player) the box HUNG; the serial ends right after
# apps mapped a window and exited code=143 (SIGTERM).
#
# Unlike test_de_app_churn.sh (which only exercises the launch QUEUE), this
# gate exercises the compositor's POINTER router: hit-test, raise/focus,
# close-box teardown (which SIGTERMs the client) and slot recycling. After
# every gesture it round-trips a marker over the serial console: a wedged
# scheduler/compositor never answers.
#
# Env: INSTALLER_IMG, OVMF_FD, BOOT_WAIT, OUT_DIR, ROUNDS.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
ROUNDS="${ROUNDS:-3}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_mouse_churn/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

[ -e /dev/kvm ] || { echo "[mchurn] SKIP-RUNTIME: /dev/kvm absent" >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "[mchurn] SKIP-RUNTIME: no OVMF" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[mchurn] SKIP-RUNTIME: no socat" >&2; exit 0; }
# STALE-IMAGE GUARD: this gate BOOTS a pre-existing image it did not build.
# A WARNING is not enough — a stale image false-GREENs the very regression
# this gate exists to catch (bit us 2026-07-01, 07-11, 07-27). ensure_installer_img
# REBUILDS when the image is missing or older than any tracked build input;
# HAMNIX_SKIP_BUILD=1 downgrades to a LOUD stale warning, never a silent pass.
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ensure_installer_img "$INSTALLER_IMG" "[de_mouse_churn]" \
    || { echo "[mchurn] SKIP: no usable $INSTALLER_IMG" >&2; exit 0; }

mkdir -p "$OUT_DIR"
echo "[mchurn] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-mchurn.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-mchurn.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-mchurn-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-mchurn.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() { [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null; rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"; }
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1; }

snapshot() {
    local label="$1" ppm="$OUT_DIR/$1.ppm"
    rm -f "$ppm"; mon_cmd "screendump $ppm" || return 1
    local i=0; while [ "$i" -lt 40 ]; do [ -s "$ppm" ] && break; sleep 0.1; i=$((i+1)); done
    [ -s "$ppm" ] || return 1
    sleep 0.3
    command -v convert >/dev/null 2>&1 && convert "$ppm" "$OUT_DIR/$1.png" 2>/dev/null
    return 0
}

wait_for() {
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

# --- pointer helpers: QEMU PS/2 relative motion ------------------------
CUR_X=640; CUR_Y=400            # compositor seeds the cursor at screen centre
mouse_step() {                  # mouse_step <dx> <dy> (|d| <= 100 per packet)
    mon_cmd "mouse_move $1 $2"
    sleep 0.05
}
mouse_to() {                    # mouse_to <x> <y> absolute screen coords
    local tx="$1" ty="$2" dx dy sx sy
    while [ "$CUR_X" -ne "$tx" ] || [ "$CUR_Y" -ne "$ty" ]; do
        dx=$(( tx - CUR_X )); dy=$(( ty - CUR_Y ))
        sx=$dx; sy=$dy
        [ "$sx" -gt 100 ] && sx=100; [ "$sx" -lt -100 ] && sx=-100
        [ "$sy" -gt 100 ] && sy=100; [ "$sy" -lt -100 ] && sy=-100
        mouse_step "$sx" "$sy"
        CUR_X=$(( CUR_X + sx )); CUR_Y=$(( CUR_Y + sy ))
    done
}
click_at() {                    # click_at <x> <y>
    mouse_to "$1" "$2"
    sleep 0.3
    mon_cmd "mouse_button 1"
    sleep 0.3
    mon_cmd "mouse_button 0"
    sleep 0.6
}
dblclick_at() {                 # dblclick_at <x> <y> (desktop icons launch on
    mouse_to "$1" "$2"          #  the second click / already-selected click)
    sleep 0.3
    mon_cmd "mouse_button 1"; sleep 0.2; mon_cmd "mouse_button 0"
    sleep 0.4
    mon_cmd "mouse_button 1"; sleep 0.2; mon_cmd "mouse_button 0"
    sleep 0.6
}

fail=0
say_fail() { echo "[mchurn] FAIL $*" >&2; fail=1; }

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

echo "[mchurn] waiting up to ${BOOT_WAIT}s for the DE handoff..."
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || {
    echo "[mchurn] FAIL: no handoff marker" >&2; tail -40 "$LOG" >&2; exit 1; }
sleep 8
printf 'echo MARK_MCHURN_READY\n' >&3
sleep 1
wait_for MARK_MCHURN_READY 12 || { printf 'echo MARK_MCHURN_READY\n' >&3; sleep 2; }

alive_n=0
assert_alive() {                # assert_alive <label>
    alive_n=$((alive_n+1))
    local m="MARK_ALIVE_${alive_n}"
    printf 'echo %s\n' "$m" >&3
    local d=$(( SECONDS + 20 ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "$m" "$LOG" && { echo "[mchurn] alive after $1"; return 0; }
        sleep 1
    done
    say_fail "SYSTEM WEDGED after $1 (no serial response in 20s)"
    snapshot "WEDGED_$1"
    return 1
}

snapshot 000_idle
# Desktop icon column (see build/de_app_churn PNGs): x~53 col 1, x~135 col 2.
# Rows: Audio Player (53,50) / Log Viewer (135,50) / Calculator (53,120) /
#       Notes (135,120) / Calendar (53,195) / Software (135,195) /
#       Control Center (53,265) / System Monitor (135,265).
mapped_count() { grep -ac "\[devwsys\] window .* mapped" "$LOG"; }
expect_map() {                  # expect_map <before-count> <label>
    local d=$(( SECONDS + 25 ))
    while [ "$SECONDS" -lt "$d" ]; do
        [ "$(mapped_count)" -gt "$1" ] && {
            echo "[mchurn] $2 mapped: $(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)"
            return 0; }
        sleep 1
    done
    say_fail "$2 mapped NO window"
    return 1
}

# app  -> close-box screen coords, derived from each app's `geometry` ctl write
#   hammonscene   geometry 300 140 364 ...  -> close box (654,131)
#   hamaudioscene geometry 480 160 360 360  -> (830,151)
#   hamnotesscene geometry 220 150 480 300  -> (690,141)
#   hamcalcscene  geometry 610 110 188 300  -> (788,101)
#   hamfmscene    geometry 760 430 320 280  -> (1070,421)
APPS="hammonscene:654:131 hamaudioscene:830:151 hamnotesscene:690:141 hamcalcscene:788:101 hamfmscene:1070:421"

i=0
r=1
while [ "$r" -le "$ROUNDS" ]; do
    # The Applications menu, opened and dismissed with the mouse, exactly as
    # the user does before picking an app.
    i=$((i+1)); n=$(printf '%03d' $i)
    click_at 45 11
    sleep 2
    snapshot "${n}_r${r}_appmenu_open"
    assert_alive "appmenu open r$r" || break 2
    click_at 45 11                     # toggle it shut again
    sleep 1.5
    assert_alive "appmenu toggle-shut r$r" || break 2

    for spec in $APPS; do
        app="${spec%%:*}"; rest="${spec#*:}"; cx="${rest%%:*}"; cy="${rest##*:}"
        i=$((i+1)); n=$(printf '%03d' $i)
        before=$(mapped_count)
        printf 'echo /bin/%s > /dev/wsys/run/launch\n' "$app" >&3
        expect_map "$before" "$app r$r"
        sleep 3
        [ "$app" = hammonscene ] && snapshot "${n}_r${r}_${app}"
        assert_alive "$app launch r$r" || break 2
        # close it from its own titlebar close box (compositor teardown path)
        click_at "$cx" "$cy"
        sleep 2
        assert_alive "$app close r$r" || break 2
    done
    # Per-round memory probe: a per-launch kernel leak shows up here as a
    # monotonically falling free-page count long before the box wedges.
    printf 'echo MEMMARK_%s; free\n' "$r" >&3
    sleep 2
    r=$((r+1))
done

snapshot 999_final
assert_alive "final"
sleep 2
snapshot 999_final_b

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

echo "[mchurn] windows mapped: $(grep -ac '\[devwsys\] window .* mapped' "$LOG")"
echo "[mchurn] code=143 exits: $(grep -ac 'exited (code=143)' "$LOG")"
echo "[mchurn] artifacts: $OUT_DIR"
[ "$fail" -ne 0 ] && { echo "[mchurn] OVERALL FAIL"; exit 1; }
echo "[mchurn] OVERALL PASS"
