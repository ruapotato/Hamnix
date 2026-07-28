#!/usr/bin/env bash
# scripts/test_de_office_suite.sh — the OFFICE SUITE ships on the desktop.
#
# HamWrite / HamSheet / HamSlides used to be repo-ONLY: their .desktop
# launchers lived in etc/hamde/apps-optional/ and their packages were excluded
# from the hamnix-base closure, so a fresh install carried neither the binaries
# nor the Applications-menu entries — the user could never see them. They are
# now first-class pre-installed DE apps (hamnix-hamwrite/-hamsheet/-hamslides
# under hamnix-desktop-apps, launchers in etc/hamde/apps/).
#
# This gate boots the SHIPPED installer image under OVMF and proves, on the
# real desktop:
#
#   1. /etc/hamde/apps carries all three launchers (what the panel scans, see
#      hamappmenu.ad's _dd_scan) and /bin carries all three binaries.
#   2. Launching each app THROUGH THE DE LAUNCH QUEUE
#      (`echo /bin/<app> > /dev/wsys/run/launch`) maps a real window
#      (`[devwsys] window <wid> mapped`) and paints it — verified by a QEMU
#      monitor screendump before/after, counting changed pixels.
#   3. Each app RESPONDS TO REAL KEYSTROKES: characters are pushed through the
#      emulated PS/2 keyboard with the QEMU monitor `sendkey` verb, i.e. the
#      genuine atkbd -> compositor -> focused-window path, and the window must
#      repaint as a result (typed text in HamWrite, a cell value in HamSheet,
#      a new slide/advance in HamSlides).
#
# All PNGs land under build/de_office_suite/<timestamp>/.
#
# Env overrides:
#   INSTALLER_IMG  image path (default: build/hamnix-installer.img)
#   OVMF_FD        OVMF firmware (default: auto-resolved)
#   BOOT_WAIT      seconds to wait for the handoff marker (default: 240)
#   OUT_DIR        output dir (default: build/de_office_suite/<ts>)
#   DIFF_MIN       min changed pixels for "the window painted" (default: 1500)
#   TYPE_DIFF_MIN  min changed pixels for "the app reacted to keys" (default: 40)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
DIFF_MIN="${DIFF_MIN:-1500}"
TYPE_DIFF_MIN="${TYPE_DIFF_MIN:-40}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_office_suite/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

APPS="hamwrite hamsheet hamslides"

# --- structural guard: the launchers are SHIPPED, not optional ----------
struct_fail=0
for a in $APPS; do
    if [ ! -f "etc/hamde/apps/$a.desktop" ]; then
        echo "[office] FAIL: etc/hamde/apps/$a.desktop missing (still optional?)" >&2
        struct_fail=1
    fi
    if [ -f "etc/hamde/apps-optional/$a.desktop" ]; then
        echo "[office] FAIL: etc/hamde/apps-optional/$a.desktop still present" >&2
        struct_fail=1
    fi
done
grep -q "^Word Processor|file|/bin/hamwrite$" etc/desktop.icons || {
    echo "[office] FAIL: desktop.icons lacks the Word Processor launcher" >&2
    struct_fail=1; }
grep -q "^Spreadsheet|file|/bin/hamsheet$" etc/desktop.icons || {
    echo "[office] FAIL: desktop.icons lacks the Spreadsheet launcher" >&2
    struct_fail=1; }
grep -q "^Presentation|file|/bin/hamslides$" etc/desktop.icons || {
    echo "[office] FAIL: desktop.icons lacks the Presentation launcher" >&2
    struct_fail=1; }
[ "$struct_fail" -eq 0 ] || exit 1
echo "[office] structural markers OK (3 shipped launchers + desktop icons)"

# --- environment gates ---------------------------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[office] SKIP-RUNTIME: /dev/kvm absent (structural PASS)" >&2; exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || {
    echo "[office] SKIP-RUNTIME: OVMF firmware not found" >&2; exit 0; }
MON_DRIVER=""
command -v socat >/dev/null 2>&1 && MON_DRIVER=socat
[ -z "$MON_DRIVER" ] && command -v nc >/dev/null 2>&1 && MON_DRIVER=nc
[ -n "$MON_DRIVER" ] || {
    echo "[office] SKIP-RUNTIME: no socat/nc to drive the QEMU monitor" >&2; exit 0; }
CONVERTER=""
command -v convert >/dev/null 2>&1 && CONVERTER=convert
[ -z "$CONVERTER" ] && command -v pnmtopng >/dev/null 2>&1 && CONVERTER=pnmtopng
# The image must be BOTH present and CURRENT: "is the office suite on the
# desktop?" answered from a pre-office image is exactly the false red that
# cost two agent cycles on 2026-07-24 (scripts/_installer_img.sh).
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "[office]"

mkdir -p "$OUT_DIR"
echo "[office] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-office.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-office.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-office-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-office.XXXXXX).in
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

snapshot() {                       # snapshot <label> -> $OUT_DIR/<label>.ppm/.png
    local label="$1"
    local ppm="$OUT_DIR/$label.ppm"
    rm -f "$ppm"
    mon_cmd "screendump $ppm" || return 1
    local i=0
    while [ "$i" -lt 40 ]; do [ -s "$ppm" ] && break; sleep 0.1; i=$((i+1)); done
    [ -s "$ppm" ] || return 1
    sleep 0.4
    case "$CONVERTER" in
        convert)  convert "$ppm" "$OUT_DIR/$label.png" 2>/dev/null ;;
        pnmtopng) pnmtopng "$ppm" > "$OUT_DIR/$label.png" 2>/dev/null ;;
    esac
    return 0
}

# Count pixels differing by >THRESH inside the central window region.
region_diff() {
    python3 - "$1" "$2" <<'PYEOF'
import sys
def load(path):
    data = open(path, "rb").read()
    if not data.startswith(b"P6"):
        return None
    idx, toks = 2, []
    while len(toks) < 3:
        while idx < len(data) and data[idx:idx+1].isspace():
            idx += 1
        if data[idx:idx+1] == b'#':
            while idx < len(data) and data[idx:idx+1] != b'\n':
                idx += 1
            continue
        s = idx
        while idx < len(data) and not data[idx:idx+1].isspace():
            idx += 1
        toks.append(int(data[s:idx]))
    idx += 1
    w, h, _ = toks
    return w, h, data[idx:idx+w*h*3]
a, b = load(sys.argv[1]), load(sys.argv[2])
if a is None or b is None or a[0] != b[0] or a[1] != b[1]:
    print(-1); sys.exit(0)
w, h, pa = a
_, _, pb = b
x0, x1 = int(w*0.15), int(w*0.85)
y0, y1 = int(h*0.15), int(h*0.85)
T, changed, n = 24, 0, min(len(pa), len(pb))
for y in range(y0, y1):
    base = y*w*3
    for x in range(x0, x1):
        i = base + x*3
        if i+2 >= n:
            continue
        if (abs(pa[i]-pb[i]) > T or abs(pa[i+1]-pb[i+1]) > T
                or abs(pa[i+2]-pb[i+2]) > T):
            changed += 1
print(changed)
PYEOF
}

wait_for() {
    local pat="$1" timeout="$2"
    local deadline=$(( SECONDS + timeout ))
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

echo "[office] waiting up to ${BOOT_WAIT}s for the DE handoff..."
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "[office] FAIL: handoff marker not seen in ${BOOT_WAIT}s" >&2
    tail -60 "$LOG" >&2; exit 1
fi
sleep 6
# hamsh drops the FIRST serial command; burn one on a ready marker.
printf 'echo MARK_OFFICE_READY\n' >&3
sleep 1
wait_for MARK_OFFICE_READY 12 || { printf 'echo MARK_OFFICE_READY\n' >&3; sleep 2; }

fail=0
say_fail() { echo "[office] FAIL $*" >&2; fail=1; }

# --- 1: the catalogue the panel scans carries the three launchers -------
# Section the serial log so each listing is greppable in isolation.
section() {                        # section <tag> <command>
    printf 'echo BEGIN_%s; %s; echo END_%s\n' "$1" "$2" "$1" >&3
    local d=$(( SECONDS + 25 ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "END_$1" "$LOG" && break
        sleep 1
    done
    sed -n "/BEGIN_$1/,/END_$1/p" "$LOG"
}

section APPSDIR 'ls /etc/hamde/apps' > "$OUT_DIR/apps_dir.txt"
section DESKDIR 'ls /home/live/Desktop' > "$OUT_DIR/desk_dir.txt"
section BINDIR  'ls /bin' > "$OUT_DIR/bin_dir.txt"

for a in $APPS; do
    grep -aq "$a.desktop" "$OUT_DIR/apps_dir.txt" \
        && echo "[office] PASS /etc/hamde/apps/$a.desktop present (panel Applications menu)" \
        || say_fail "/etc/hamde/apps/$a.desktop absent from the booted /etc/hamde/apps"
    grep -aqw "$a" "$OUT_DIR/bin_dir.txt" \
        && echo "[office] PASS /bin/$a shipped in the base image" \
        || say_fail "/bin/$a absent from the booted image"
    grep -aq "$a.desktop" "$OUT_DIR/desk_dir.txt" \
        && echo "[office] PASS ~/Desktop/$a.desktop planted (desktop icon)" \
        || say_fail "~/Desktop/$a.desktop absent (no desktop icon)"
done
appmenu_n=$(grep -ao '[A-Za-z0-9_-]*\.desktop' "$OUT_DIR/apps_dir.txt" | sort -u | wc -l)
echo "[office] Applications-menu catalogue: $appmenu_n .desktop entries"
[ "$appmenu_n" -ge 26 ] || say_fail "expected >=26 .desktop entries, saw $appmenu_n"

# --- 1a: the PANEL's menu MODEL actually absorbed them ------------------
# The launcher dir being right is NOT enough: hampanelscene's _am_add()
# silently drops every entry past AM_MAX, so the office apps once vanished
# from the dropdown while `ls /etc/hamde/apps` looked perfect (the exact
# bug this check exists to catch). The panel self-reports its model size on
# serial; it must have absorbed at least the whole shipped catalogue.
panel_line=$(grep -a '\[panel\] appmenu entries:' "$LOG" | tail -1)
panel_n=$(printf '%s' "$panel_line" | sed -n 's/.*appmenu entries: \([0-9]*\).*/\1/p')
panel_lx=$(printf '%s' "$panel_line" | sed -n 's/.*linux section: \([0-9]*\).*/\1/p')
echo "[office] panel menu model: ${panel_n:-?} entries (linux section ${panel_lx:-?})"
if [ -z "$panel_n" ]; then
    say_fail "panel never reported '[panel] appmenu entries:' on serial"
elif [ "$panel_n" -ge $(( appmenu_n + ${panel_lx:-0} )) ]; then
    echo "[office] PASS panel absorbed all $appmenu_n launchers (+${panel_lx:-0} linux) into its menu model"
else
    say_fail "panel menu model holds only $panel_n entries for $appmenu_n launchers +${panel_lx:-0} linux — AM_MAX overflow is DROPPING apps"
fi

snapshot desktop_00_idle || say_fail "could not screendump the idle desktop"

# --- 1b: the Applications MENU itself lists the office apps -------------
# /bin/hamappmenu IS the panel's Applications dropdown (the panel spawns this
# very binary on a click); it scans /etc/hamde/apps at startup. Spawn it
# through the launch queue and type a filter: hamappmenu's search box filters
# the catalogue live, so filtering on a substring of an office app's Name
# renders that row — visual proof the MENU carries the entry, not just the dir.
mapped_before=$(grep -ac "\[devwsys\] window .* mapped" "$LOG")
printf 'echo /bin/hamappmenu > /dev/wsys/run/launch\n' >&3
d=$(( SECONDS + 30 ))
while [ "$SECONDS" -lt "$d" ]; do
    [ "$(grep -ac "\[devwsys\] window .* mapped" "$LOG")" -gt "$mapped_before" ] && break
    sleep 1
done
sleep 4
snapshot appmenu_01_open || say_fail "could not screendump the Applications menu"
for k in s p r e a d; do mon_cmd "sendkey $k"; sleep 0.3; done
sleep 3
snapshot appmenu_02_filter_spread \
    || say_fail "could not screendump the filtered Applications menu"
px=$(region_diff "$OUT_DIR/appmenu_01_open.ppm" \
                 "$OUT_DIR/appmenu_02_filter_spread.ppm")
if [ "${px:-0}" -ge "$TYPE_DIFF_MIN" ]; then
    echo "[office] PASS Applications menu filtered on 'spread' ($px changed px)"
else
    say_fail "Applications menu did not react to the 'spread' filter ($px px)"
fi
mon_cmd "sendkey esc"
sleep 3

# --- 2 + 3: launch each app + type into it ------------------------------
type_keys() {                      # type_keys <qemu sendkey names...>
    for k in "$@"; do
        mon_cmd "sendkey $k"
        sleep 0.35
    done
}

launch_and_drive() {
    local app="$1" idx="$2"; shift 2
    local before after
    before=$(grep -ac "\[devwsys\] window .* mapped" "$LOG")
    snapshot "${idx}_${app}_pre" || say_fail "$app: pre-screendump failed"
    printf 'echo /bin/%s > /dev/wsys/run/launch\n' "$app" >&3
    local d=$(( SECONDS + 30 ))
    while [ "$SECONDS" -lt "$d" ]; do
        after=$(grep -ac "\[devwsys\] window .* mapped" "$LOG")
        [ "$after" -gt "$before" ] && break
        sleep 1
    done
    if [ "$after" -gt "$before" ]; then
        echo "[office] PASS $app mapped a window ($(grep -a "\[devwsys\] window .* mapped" "$LOG" | tail -1))"
    else
        say_fail "$app mapped NO window within 30s"
    fi
    sleep 4
    snapshot "${idx}_${app}_running" || say_fail "$app: post-screendump failed"
    local px
    px=$(region_diff "$OUT_DIR/${idx}_${app}_pre.ppm" "$OUT_DIR/${idx}_${app}_running.ppm")
    if [ "${px:-0}" -ge "$DIFF_MIN" ]; then
        echo "[office] PASS $app painted its window ($px changed px)"
    else
        say_fail "$app window did not paint ($px changed px < $DIFF_MIN)"
    fi
    # keystrokes through the REAL PS/2 -> atkbd -> compositor -> window path
    type_keys "$@"
    sleep 3
    snapshot "${idx}_${app}_typed" || say_fail "$app: typed-screendump failed"
    px=$(region_diff "$OUT_DIR/${idx}_${app}_running.ppm" "$OUT_DIR/${idx}_${app}_typed.ppm")
    if [ "${px:-0}" -ge "$TYPE_DIFF_MIN" ]; then
        echo "[office] PASS $app reacted to keyboard input ($px changed px)"
    else
        say_fail "$app did NOT react to keyboard input ($px changed px < $TYPE_DIFF_MIN)"
    fi
}

# HamWrite: type a word.  HamSheet: type a number + Enter (commits a cell).
# HamSlides: Ctrl-N adds a slide, then type a title.
launch_and_drive hamwrite  10 h a m n i x
launch_and_drive hamsheet  20 4 2 ret
launch_and_drive hamslides 30 ctrl-n d e m o

snapshot desktop_99_all || say_fail "could not screendump the final desktop"

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

echo "[office] windows mapped total: $(grep -ac '\[devwsys\] window .* mapped' "$LOG")"
echo "[office] PNGs: $OUT_DIR"
if [ "$fail" -ne 0 ]; then echo "[office] OVERALL FAIL"; exit 1; fi
echo "[office] OVERALL PASS"
