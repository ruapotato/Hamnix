#!/usr/bin/env bash
# scripts/capture_release_screenshots.sh — RELEASE EVIDENCE CAPTURE.
#
# Boots the shipped installer image under OVMF/KVM into the scene DE and
# captures, from the REAL framebuffer scanout (QEMU monitor `screendump`,
# never a host-side render — see feedback_host_preview_monospace_lies):
#
#   1. The idle desktop (wallpaper + panel + clock + desktop icons).
#   2. The Applications menu open (/bin/hamappmenu, the very binary the
#      panel spawns on a click).
#   3. Every launcher in /etc/hamde/apps: launched through the REAL DE
#      launch queue (`echo /bin/<app> > /dev/wsys/run/launch`), settled,
#      screendumped, driven with real PS/2 keystrokes, screendumped
#      again, then killed and screendumped a third time.
#
# For each app it records FOUR independent verdicts:
#
#   launched     — the kernel emitted `[devwsys] window <wid> mapped pid=<n>`
#   rendered     — the settled frame differs from the pre-launch desktop by
#                  >= DIFF_MIN pixels in the window region (a blank window
#                  frame is a few hundred px of border; a real UI is tens of
#                  thousands)
#   interactive  — the frame changed by >= TYPE_DIFF_MIN px after keystrokes
#   clean_exit   — after `kill <pid>` the frame returns to within
#                  CLOSE_TOL px of the pre-launch desktop (window torn down,
#                  no ghost, compositor repainted)
#
# Results land as a TSV in $OUT_DIR/verdicts.tsv plus one PNG per phase.
# THIS SCRIPT MAKES NO PASS/FAIL CLAIM ON ITS OWN — a human must look at
# the PNGs. It exits 0 as long as it produced evidence.
#
# Env:
#   INSTALLER_IMG  image path (default build/hamnix-installer.img)
#   OUT_DIR        output dir (default build/release_shots/<ts>)
#   ONLY           space-separated app basenames to capture (default: all)
#   BOOT_WAIT      seconds to wait for DE handoff (default 300)
set -u
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT" || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/release_shots/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
DIFF_MIN="${DIFF_MIN:-1500}"
TYPE_DIFF_MIN="${TYPE_DIFF_MIN:-200}"
CLOSE_TOL="${CLOSE_TOL:-1500}"
SETTLE="${SETTLE:-5}"
HANDOFF_MARKER="handing off to interactive shell"

[ -e /dev/kvm ] || { echo "[shots] SKIP: /dev/kvm absent" >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || {
    echo "[shots] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[shots] SKIP: socat required" >&2; exit 0; }
CONVERTER=""
command -v convert >/dev/null 2>&1 && CONVERTER=convert
[ -z "$CONVERTER" ] && command -v pnmtopng >/dev/null 2>&1 && CONVERTER=pnmtopng
[ -n "$CONVERTER" ] || { echo "[shots] SKIP: no PPM->PNG converter" >&2; exit 0; }

# Stale-image guard: a release screenshot of a week-old image is a lie.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "[shots]"

mkdir -p "$OUT_DIR"
echo "[shots] output dir: $OUT_DIR"
echo "[shots] image: $INSTALLER_IMG ($(date -r "$INSTALLER_IMG" '+%F %T'), $(stat -c %s "$INSTALLER_IMG") bytes)"
{
    echo "image=$INSTALLER_IMG"
    echo "image_mtime=$(date -r "$INSTALLER_IMG" '+%F %T %z')"
    echo "image_bytes=$(stat -c %s "$INSTALLER_IMG")"
    echo "image_sha256=$(sha256sum "$INSTALLER_IMG" | awk '{print $1}')"
    echo "git_head=$(git rev-parse HEAD)"
    echo "git_dirty=$(git status --porcelain | wc -l)"
    echo "captured=$(date '+%F %T %z')"
    echo "host=$(uname -srm)"
    echo "qemu=$(qemu-system-x86_64 --version | head -1)"
} > "$OUT_DIR/provenance.txt"
[ -f "$INSTALLER_IMG.stamp" ] && cp "$INSTALLER_IMG.stamp" "$OUT_DIR/image.stamp"

OVMF_RW=$(mktemp --tmpdir hamnix-shots.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-shots.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-shots-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-shots.XXXXXX).in
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

snapshot() {                        # snapshot <label>
    # NB: separate `local` statements — `local a="$1" b="$a"` expands $a
    # BEFORE the local `a` is assigned, which under `set -u` aborts the
    # whole script with "label: unbound variable".
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

region_diff() {                     # region_diff A.ppm B.ppm -> changed px
    python3 "$PROJ_ROOT/scripts/_ppm_region_diff.py" "$1" "$2"
}

wait_for() {
    local pat="$1"
    local deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

mapped_count() { grep -ac "\[devwsys\] window .* mapped" "$LOG"; }

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

echo "[shots] waiting up to ${BOOT_WAIT}s for the DE handoff..."
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "[shots] FAIL: handoff marker not seen in ${BOOT_WAIT}s" >&2
    tail -60 "$LOG" >&2; exit 1
fi
sleep 8
# hamsh drops the FIRST serial command (feedback_interactive_test_wait_for_prompt).
printf 'echo MARK_SHOTS_READY\n' >&3
sleep 1
wait_for MARK_SHOTS_READY 12 || { printf 'echo MARK_SHOTS_READY\n' >&3; sleep 2; }

# --- text evidence: what the DE thinks it has -------------------------
section() {                         # section <tag> <command>
    printf 'echo BEGIN_%s; %s; echo END_%s\n' "$1" "$2" "$1" >&3
    local d=$(( SECONDS + 30 ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "END_$1" "$LOG" && break
        sleep 1
    done
    sed -n "/BEGIN_$1/,/END_$1/p" "$LOG"
}
if [ -z "${SKIP_TEXT:-}" ]; then
section APPSDIR  'ls /etc/hamde/apps'        > "$OUT_DIR/txt_apps_dir.txt"
# The desktop icon set is PERSISTED to /etc/desktop.icons by hamdesktop;
# /dev/wsys/desktop.icons is not a path (verified 2026-08-03: "dev: no such
# device"). The panel's own count lands in the serial log as
# `[panel] appmenu entries: N`.
section DESKICON 'cat /etc/desktop.icons'    > "$OUT_DIR/txt_desktop_icons.txt"
section APPMENU  'cat /dev/wsys/appmenu'     > "$OUT_DIR/txt_appmenu.txt"
section HPM      'hpm list'                  > "$OUT_DIR/txt_hpm_list.txt"
section FREE     'free'                      > "$OUT_DIR/txt_free.txt"
section UNAME    'uname -a'                  > "$OUT_DIR/txt_uname.txt"
fi

# --- 00: the idle desktop ---------------------------------------------
sleep 3
snapshot 00-desktop || echo "[shots] WARN: idle desktop screendump failed" >&2

# --- 01: the Applications menu ----------------------------------------
before=$(mapped_count)
printf 'echo /bin/hamappmenu > /dev/wsys/run/launch\n' >&3
d=$(( SECONDS + 30 ))
while [ "$SECONDS" -lt "$d" ]; do
    [ "$(mapped_count)" -gt "$before" ] && break
    sleep 1
done
sleep "$SETTLE"
snapshot 01-appmenu || true
# The menu opens with all seven categories COLLAPSED, so the open-menu shot
# alone shows no catalogue. Type into the search box FIRST — that is the
# menu's real discovery path and the only one proven to work. Do NOT send
# esc before typing: esc closes the whole menu (verified 2026-08-03; an
# earlier ordering that pressed esc first captured a bare desktop).
for k in ${MENU_FILTER:-s n a k}; do mon_cmd "sendkey $k"; sleep 0.35; done
sleep 2
snapshot 01b-appmenu-search || true
# Then try keyboard navigation into a submenu. Down/Right does NOT expand a
# category as of 2026-08-03 — the shot is kept so the gap stays visible.
for k in bs bs bs bs; do mon_cmd "sendkey $k"; sleep 0.2; done
mon_cmd "sendkey down"; sleep 0.5
mon_cmd "sendkey right"; sleep 1.5
snapshot 01a-appmenu-submenu || true
menu_pid=$(grep -a "\[devwsys\] window .* mapped" "$LOG" | tail -1 | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
menu_wid=$(grep -a "\[devwsys\] window .* mapped" "$LOG" | tail -1 | sed -n 's/.*window \([0-9]*\) mapped.*/\1/p')
mon_cmd "sendkey esc"; sleep 2
[ -n "$menu_pid" ] && printf 'kill %s\n' "$menu_pid" >&3
[ -n "$menu_wid" ] && printf 'echo free %s > /dev/wsys/ctl\n' "$menu_wid" >&3
sleep 3
snapshot 01c-appmenu-closed || true

# --- 02..: every launcher ---------------------------------------------
# Per-app keystroke script: real keys that SHOULD change the UI.
keys_for() {
    case "$1" in
        hamtermscene)   echo "l s ret" ;;
        hamcalcscene)   echo "7 8 9" ;;
        hameditscene|hamnotesscene|hamwrite) echo "h a m n i x" ;;
        hamsheet)       echo "4 2 ret" ;;
        hamslides)      echo "ctrl-n d e m o" ;;
        ham2048scene|hamsnakescene|hamgamesnake|hamtetrisscene|hamgamedemo)
                        echo "right down left up" ;;
        hamminescene)   echo "right down spc" ;;
        hamchessscene)  echo "right down ret" ;;
        hamfmscene)     echo "down down ret" ;;
        hamcalscene)    echo "right right" ;;
        hammonscene|hamlogscene|hamsoftware|hamctl|haminput|hamshotui|hamaudioscene|hamvideoscene)
                        echo "down down" ;;
        hambrowse)      echo "down down down" ;;
        haminstallui)   echo "down down" ;;
        *)              echo "down" ;;
    esac
}

printf 'app\tbin\tlaunched\twid\tpid\trendered_px\ttyped_px\tclose_resid_px\tfaults\n' \
    > "$OUT_DIR/verdicts.tsv"

idx=1
for desktop in etc/hamde/apps/*.desktop; do
    app=$(basename "$desktop" .desktop)
    bin=$(grep -m1 '^Exec=' "$desktop" | cut -d= -f2 | awk '{print $1}')
    prog=$(basename "$bin")
    # Increment BEFORE the ONLY filter so a given app keeps the SAME tag
    # number whichever batch it is captured in — batches exist so that no
    # more than a handful of undismissable windows pile up per boot.
    idx=$((idx + 1))
    if [ -n "${ONLY:-}" ]; then
        grep -qw "$app" <<<"$ONLY" || continue
    fi
    tag=$(printf "%02d-%s" "$idx" "$app")
    echo "[shots] === $tag  ($bin) ==="

    kill -0 "$QEMU_PID" 2>/dev/null || { echo "[shots] qemu died; stopping" >&2; break; }

    log_mark_start=$(wc -l < "$LOG")
    before=$(mapped_count)
    snapshot "$tag-a-pre" || true
    printf 'echo %s > /dev/wsys/run/launch\n' "$bin" >&3
    d=$(( SECONDS + 30 )); after="$before"
    while [ "$SECONDS" -lt "$d" ]; do
        after=$(mapped_count)
        [ "$after" -gt "$before" ] && break
        sleep 1
    done
    if [ "$after" -gt "$before" ]; then
        launched=yes
        pid=$(grep -a "\[devwsys\] window .* mapped" "$LOG" | tail -1 | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
        wid=$(grep -a "\[devwsys\] window .* mapped" "$LOG" | tail -1 | sed -n 's/.*window \([0-9]*\) mapped.*/\1/p')
    else
        launched=no; pid=""; wid=""
    fi
    sleep "$SETTLE"
    snapshot "$tag-b-running" || true
    rendered_px=$(region_diff "$OUT_DIR/$tag-a-pre.ppm" "$OUT_DIR/$tag-b-running.ppm")

    for k in $(keys_for "$prog"); do mon_cmd "sendkey $k"; sleep 0.35; done
    sleep 3
    snapshot "$tag-c-typed" || true
    typed_px=$(region_diff "$OUT_DIR/$tag-b-running.ppm" "$OUT_DIR/$tag-c-typed.ppm")

    # TEARDOWN. `kill <pid>` alone does NOT remove a scene app's window
    # (verified 2026-08-03: no `task: pid N exited` follows, and the frame
    # after the kill is pixel-identical to the running frame), so every
    # launched app stayed on screen and the desktop accumulated 26 stacked
    # windows. Follow the kill with the hostowner `free <wid>` verb on
    # /dev/wsys/ctl, which routes through wsys_free_wid and recomposes the
    # vacated footprint. close_resid then measures a REAL teardown.
    if [ -n "$pid" ]; then printf 'kill %s\n' "$pid" >&3; sleep 1; fi
    if [ -n "$wid" ]; then printf 'echo free %s > /dev/wsys/ctl\n' "$wid" >&3; fi
    sleep 4
    snapshot "$tag-d-closed" || true
    close_px=$(region_diff "$OUT_DIR/$tag-a-pre.ppm" "$OUT_DIR/$tag-d-closed.ppm")

    faults=$(tail -n +"$log_mark_start" "$LOG" \
        | grep -aciE "panic|page fault|trap [0-9]|oops|GPF|#PF" || true)

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$app" "$prog" "$launched" "${wid:--}" "${pid:--}" "${rendered_px:--1}" \
        "${typed_px:--1}" "${close_px:--1}" "${faults:-0}" \
        >> "$OUT_DIR/verdicts.tsv"
    echo "[shots]     $app wid=${wid:--} pid=${pid:--} launched=$launched rendered=${rendered_px} typed=${typed_px} close_resid=${close_px} faults=${faults:-0}"
done

snapshot 99-desktop-final || true
section FREEEND 'free' > "$OUT_DIR/txt_free_end.txt"

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

rm -f "$OUT_DIR"/*.ppm.tmp
echo "[shots] --- verdicts ---"
column -t -s $'\t' "$OUT_DIR/verdicts.tsv" 2>/dev/null || cat "$OUT_DIR/verdicts.tsv"
echo "[shots] evidence in $OUT_DIR"
exit 0
