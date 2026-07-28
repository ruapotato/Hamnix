#!/usr/bin/env bash
# scripts/test_de_visual_gate.sh — THE VISUAL REGRESSION GATE.
#
# Boots the installer image under OVMF/KVM and produces, for every
# graphical boot:
#
#   1. A real cursor-FPS number, emitted by the compositor once per second
#      ([de_perf] cursor_fps=N) while the rc.5 hook drives the cursor via
#      /dev/mouse absolute moves (A.1 consolidation — no injection ctl verb).
#   2. A pre-spawn and post-spawn framebuffer PNG for each genuinely-
#      windowed hamui app the rc.5 hook launches THROUGH THE DE LAUNCH
#      QUEUE (hamcalscene hamcalcscene hammonscene — each self-allocates an
#      owned wsys window via hamui_window()), captured live via the QEMU
#      monitor `screendump` HMP command on `[visual_gate]
#      launching/launched` markers in the serial log.
#   3. A whole-DE composite PNG snapped just after the gate finishes
#      sequencing apps.
#
# THIS IS THE #99 REGRESSION GATE: a launch-queue write
# (`echo /bin/<app> > /dev/wsys/run/launch`) must produce a rendered
# window. The panel (hampanelscene) drains the queue and spawns the app
# as a scene client; the kernel emits `[devwsys] window <wid> mapped
# pid=<pid>` per self-served window.
#
# FAILS if any launched app's window region shows no new pixels
# (WINDOW_DIFF_MIN) OR if fewer than WINDOW_MAP_MIN distinct windows were
# mapped (so a launch-queue app's fresh window is proven allocated).
# cursor_fps is reported for info only (the legacy hamUId present that
# emitted it is retired in the scene DE). All PNGs land under
# build/de_visual_gate/<timestamp>/.
#
# This is the build-time visual-gate — there is no -kernel multiboot
# fast-path: that route hits project_qemu_multiboot_vbe_limit on this
# host so cannot produce real-framebuffer PNGs. The UEFI/OVMF live boot
# is the only authoritative path, matching scripts/
# test_installer_de_runlevel5.sh.
#
# Env overrides:
#   INSTALLER_IMG      image path        (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware     (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for the handoff marker (default: 240)
#   GATE_WAIT          seconds to wait for `[visual_gate] start` (default: 60)
#   APP_WAIT           seconds to wait between markers (default: 20)
#   FPS_MIN            minimum cursor_fps to PASS (default: 5)
#   OUT_DIR            output dir        (default: build/de_visual_gate/<ts>)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# This gate PROVES the #99 DE launch path: it needs rc.5's boot-time DE
# self-test (the demo-app launches through /dev/wsys/run/launch + the
# [visual_gate] launching/launched markers), which lives in the
# /etc/rc.d/rc.5.selftest fragment. That fragment is packaged into the image
# ONLY when built with HAMNIX_DE_SELFTEST=1 — a NORMAL user boot omits it so
# the desktop comes up clean. So build a DEDICATED self-test image here, at
# a DISTINCT path, so this gate never boots (or clobbers) the clean shipped
# build/hamnix-installer.img.
export HAMNIX_DE_SELFTEST=1
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer-selftest.img}"
export HAMNIX_INSTALLER_IMG_OUT="$INSTALLER_IMG"
BOOT_WAIT="${BOOT_WAIT:-240}"
GATE_WAIT="${GATE_WAIT:-60}"
APP_WAIT="${APP_WAIT:-20}"
FPS_MIN="${FPS_MIN:-5}"
# Minimum changed pixels inside the central window region for an app to
# count as "rendered". A real toolkit window paints thousands of pixels;
# cursor/wallpaper jitter is a few dozen at most. 1500 is a safe floor.
WINDOW_DIFF_MIN="${WINDOW_DIFF_MIN:-1500}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_visual_gate/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

# The Calendar/clock is unified on hamcalscene (rc.5 autostarts it, not the
# legacy stopwatch-only hamclock) — match what rc.5 actually launches.
APPS=(hamcalscene hamcalcscene hammonscene)

# --- environment gates -----------------------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[visual_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[visual_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

CONVERTER=""
if command -v convert >/dev/null 2>&1; then
    CONVERTER="convert"
elif command -v ffmpeg >/dev/null 2>&1; then
    CONVERTER="ffmpeg"
elif command -v pnmtopng >/dev/null 2>&1; then
    CONVERTER="pnmtopng"
else
    echo "[visual_gate] SKIP: no PPM->PNG converter" >&2
    exit 0
fi

MON_DRIVER=""
if command -v socat >/dev/null 2>&1; then
    MON_DRIVER="socat"
elif command -v nc >/dev/null 2>&1; then
    MON_DRIVER="nc"
else
    echo "[visual_gate] SKIP: no socat/nc to drive QEMU monitor" >&2
    exit 0
fi

# --- ensure installer image (missing OR STALE -> rebuild) --------------
# This gate's image path is DEDICATED (hamnix-installer-selftest.img), so the
# old "rebuild only when absent" rule re-booted it forever. On 2026-07-24 that
# made the gate report the office suite missing from a tree where it was
# already shipping — the image it booted predated the launchers by two days.
# See scripts/_installer_img.sh.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "[visual_gate]"

mkdir -p "$OUT_DIR"
echo "[visual_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-vg.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-vg.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-vg-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON"
}
trap cleanup EXIT

mon_cmd() {
    if [ "$MON_DRIVER" = "socat" ]; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    else
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    fi
}

ppm_to_png() {
    local ppm="$1" png="$2"
    case "$CONVERTER" in
        convert) convert "$ppm" "$png" 2>/dev/null ;;
        ffmpeg)  ffmpeg -y -loglevel error -i "$ppm" "$png" </dev/null 2>/dev/null ;;
        pnmtopng) pnmtopng "$ppm" > "$png" 2>/dev/null ;;
    esac
}

# Capture one screendump PPM, convert to PNG. Returns 0 on success.
snapshot() {
    local label="$1"
    local ppm=$(mktemp --tmpdir hamnix-vg.XXXXXX.ppm)
    local png="$OUT_DIR/$label.png"
    if ! mon_cmd "screendump $ppm"; then
        rm -f "$ppm"; return 1
    fi
    # screendump is async; poll for the file to be non-empty + stable.
    local i=0
    while [ "$i" -lt 30 ]; do
        if [ -s "$ppm" ]; then
            break
        fi
        sleep 0.1
        i=$((i + 1))
    done
    if [ ! -s "$ppm" ]; then
        rm -f "$ppm"; return 1
    fi
    # Small extra delay for file write to finish.
    sleep 0.3
    ppm_to_png "$ppm" "$png"
    # Keep the raw PPM next to the PNG: the render check decodes the
    # PPM directly (no PIL dependency) to count changed pixels in the
    # expected window region — a byte-diff of the whole PNG false-passes
    # when only the cursor/wallpaper moved and no app window appeared.
    cp "$ppm" "$OUT_DIR/$label.ppm" 2>/dev/null || true
    rm -f "$ppm"
    if [ -s "$png" ]; then
        echo "[visual_gate]   wrote $png ($(wc -c < "$png") bytes)"
        return 0
    fi
    return 1
}

# region_window_diff PRE.ppm POST.ppm
#   Decodes two binary P6 PPMs and counts pixels that differ by more
#   than a small per-channel threshold inside the CENTRAL window region
#   (the middle 70% of the frame, excluding the top panel and the screen
#   edges where the cursor and wallpaper jitter live). Prints the changed
#   pixel count on stdout. A real app window paints a large contiguous
#   block of new pixels there; a cursor-only move changes a few dozen.
region_window_diff() {
    local pre="$1" post="$2"
    python3 - "$pre" "$post" <<'PYEOF'
import sys
def load_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        return None
    # Parse the P6 header: magic, width, height, maxval — each token is
    # whitespace-separated; comments (#...) may appear.
    idx = 2
    toks = []
    while len(toks) < 3:
        while idx < len(data) and data[idx:idx+1].isspace():
            idx += 1
        if idx < len(data) and data[idx:idx+1] == b'#':
            while idx < len(data) and data[idx:idx+1] != b'\n':
                idx += 1
            continue
        start = idx
        while idx < len(data) and not data[idx:idx+1].isspace():
            idx += 1
        toks.append(int(data[start:idx]))
    idx += 1  # single whitespace after maxval
    w, h, mx = toks
    return w, h, data[idx:idx + w*h*3]
a = load_ppm(sys.argv[1])
b = load_ppm(sys.argv[2])
if a is None or b is None or a[0] != b[0] or a[1] != b[1]:
    print(-1); sys.exit(0)
w, h, pa = a; _, _, pb = b
# Central window region: middle 70% horizontally, 15%..85% vertically
# (skip the top panel band and the bottom edge).
x0, x1 = int(w*0.15), int(w*0.85)
y0, y1 = int(h*0.15), int(h*0.85)
THRESH = 24  # per-channel delta to count as "changed"
changed = 0
n = min(len(pa), len(pb))
for y in range(y0, y1):
    base = y*w*3
    for x in range(x0, x1):
        i = base + x*3
        if i+2 >= n:
            continue
        if (abs(pa[i]-pb[i]) > THRESH or abs(pa[i+1]-pb[i+1]) > THRESH
                or abs(pa[i+2]-pb[i+2]) > THRESH):
            changed += 1
print(changed)
PYEOF
}

# Mirror the user's exact ship command, headlessly + monitor socket.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    > "$LOG" 2>&1 < /dev/null &
QEMU_PID=$!

echo "[visual_gate] waiting up to ${BOOT_WAIT}s for handoff marker..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$HANDOFF_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[visual_gate] FAIL: qemu exited before handoff marker" >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[visual_gate] FAIL: handoff marker not seen in ${BOOT_WAIT}s" >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[visual_gate] handoff reached; waiting up to ${GATE_WAIT}s for [visual_gate] start..."

wait_marker() {
    local pat="$1" timeout="$2"
    local deadline=$(( SECONDS + timeout ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

if ! wait_marker '\[visual_gate\] start' "$GATE_WAIT"; then
    echo "[visual_gate] FAIL: rc.5 visual_gate did not start in ${GATE_WAIT}s" >&2
    tail -120 "$LOG" >&2
    exit 1
fi

# Composite "bare desktop" shot before any app launches.
echo "[visual_gate] gate started; snapping desktop baseline..."
snapshot "00-desktop-baseline" || true

# Wait for the nudge phase to complete so cursor_fps lands.
wait_marker '\[visual_gate\] nudge_done' "$APP_WAIT" || true

# --- per-app capture loop --------------------------------------------
declare -A PRE_HASH
declare -A POST_HASH
declare -A APP_STATUS
declare -A APP_DIFFPX

idx=0
for app in "${APPS[@]}"; do
    idx=$((idx + 1))
    label_pre=$(printf "%02d-%s-pre" "$idx" "$app")
    label_post=$(printf "%02d-%s-post" "$idx" "$app")

    if ! wait_marker "\[visual_gate\] launching $app" "$APP_WAIT"; then
        echo "[visual_gate] WARN: launching-$app marker missed; continuing" >&2
        APP_STATUS[$app]="no-launching-marker"
        continue
    fi
    # The rc.5 hook sleeps 1s AFTER the launching marker, so we have a
    # window to snap the pre-spawn frame.
    snapshot "$label_pre" || true
    if [ -s "$OUT_DIR/$label_pre.png" ]; then
        PRE_HASH[$app]=$(sha256sum "$OUT_DIR/$label_pre.png" | awk '{print $1}')
    fi

    if ! wait_marker "\[visual_gate\] launched $app" "$APP_WAIT"; then
        echo "[visual_gate] WARN: launched-$app marker missed; continuing" >&2
        APP_STATUS[$app]="no-launched-marker"
        continue
    fi
    snapshot "$label_post" || true
    if [ -s "$OUT_DIR/$label_post.png" ]; then
        POST_HASH[$app]=$(sha256sum "$OUT_DIR/$label_post.png" | awk '{print $1}')
    fi

    # Meaningful render proof: count changed pixels in the central window
    # region between the pre- and post-spawn frames. A byte-diff of the
    # whole PNG false-passes (cursor/wallpaper jitter alone flips it), so
    # require a substantial contiguous change where the window appears.
    pre_ppm="$OUT_DIR/$label_pre.ppm"
    post_ppm="$OUT_DIR/$label_post.ppm"
    if [ -s "$pre_ppm" ] && [ -s "$post_ppm" ]; then
        diffpx=$(region_window_diff "$pre_ppm" "$post_ppm" 2>/dev/null || echo -1)
        diffpx=${diffpx:--1}
        APP_DIFFPX[$app]="$diffpx"
        if [ "$diffpx" -lt 0 ]; then
            APP_STATUS[$app]="no-render (ppm decode failed)"
        elif [ "$diffpx" -ge "$WINDOW_DIFF_MIN" ]; then
            APP_STATUS[$app]="rendered ($diffpx px)"
        else
            APP_STATUS[$app]="no-render (only $diffpx px changed in window region)"
        fi
    elif [ -n "${PRE_HASH[$app]:-}" ] && [ -n "${POST_HASH[$app]:-}" ]; then
        # PPM unavailable (converter kept none) — fall back to byte-diff
        # but flag it as weak so a reviewer knows the strong check was
        # skipped.
        if [ "${PRE_HASH[$app]}" = "${POST_HASH[$app]}" ]; then
            APP_STATUS[$app]="no-render (identical pre/post; weak check)"
        else
            APP_STATUS[$app]="rendered (weak byte-diff only)"
        fi
    else
        APP_STATUS[$app]="no-shot"
    fi
done

# Final composite shot after all apps spawned.
wait_marker '\[visual_gate\] done' "$APP_WAIT" || true
snapshot "99-composite-final" || true

# Tear down QEMU.
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

# --- parse cursor_fps from the serial log ----------------------------
# A.1: the compositor emits "[de_perf] cursor_fps=N presents=X window_cs=Z"
# once per second (decoupled from any injection verb). The line is stamped
# at EMERG level so it survives console_set_interactive() suppression; EMERG
# printk still carries the "[NNNNNN] " sequence prefix, so match the tag
# ANYWHERE on the line (not anchored at ^). Pick the BUSIEST line (highest
# cursor_fps over the boot), which reflects the rc.5 cursor-drive window.
FPS_LINE=$(grep -aE '\[de_perf\] cursor_fps=' "$LOG" \
    | sed -nE 's/.*(cursor_fps=[0-9]+ presents=[0-9]+ window_cs=[0-9]+).*/\1/p' \
    | sort -t= -k2 -n | tail -1 || true)
CURSOR_FPS=$(printf '%s' "$FPS_LINE" | sed -nE 's/.*cursor_fps=([0-9]+).*/\1/p')
CURSOR_FPS=${CURSOR_FPS:-0}
PRESENTS=$(printf '%s' "$FPS_LINE" | sed -nE 's/.*presents=([0-9]+).*/\1/p')
PRESENTS=${PRESENTS:-0}

# --- DE-marker grep --------------------------------------------------
DE_MARKERS=$(grep -aE '\[de_ws\] active=|\[de_kbd\]|\[de_notify\] render|hamUI stack started|\[de_perf\] cursor_fps=' "$LOG" \
                | sort -u | head -20 || true)

# #99: kernel window-mapped markers. Each `newwindow` (self-served window)
# emits "[devwsys] window <wid> mapped pid=<pid>" (at WARN so it survives the
# post-boot console gate). The rc.5 scene apps map their windows at BOOT; the
# launch-queue apps map AFTER the "[visual_gate] start" marker. So counting
# the markers that appear PAST that line is a direct count of launch-queue
# windows — independent of how many windows booted.
GATE_START_LINE=$(grep -an '\[visual_gate\] start' "$LOG" | head -1 | cut -d: -f1)
GATE_START_LINE=${GATE_START_LINE:-0}
WINDOW_MAP_MARKERS=$(grep -aoE '\[devwsys\] window [0-9]+ mapped pid=[0-9]+' "$LOG" | sort -u || true)
if [ "$GATE_START_LINE" -gt 0 ]; then
    LAUNCH_MAP_COUNT=$(tail -n "+$GATE_START_LINE" "$LOG" \
        | grep -acE '\[devwsys\] window [0-9]+ mapped pid=[0-9]+' || true)
else
    LAUNCH_MAP_COUNT=0
fi
LAUNCH_MAP_COUNT=${LAUNCH_MAP_COUNT:-0}
WINDOW_MAP_COUNT=$(printf '%s\n' "$WINDOW_MAP_MARKERS" | grep -c 'mapped' || true)
WINDOW_MAP_COUNT=${WINDOW_MAP_COUNT:-0}

# --- write summary ---------------------------------------------------
SUMMARY="$OUT_DIR/SUMMARY.txt"
{
    echo "test_de_visual_gate summary ($TS)"
    echo "================================"
    echo "cursor_fps      = $CURSOR_FPS"
    echo "presents        = $PRESENTS"
    echo "fps_baseline    = $FPS_MIN"
    echo
    echo "per-app render status"
    echo "----------------------"
    for app in "${APPS[@]}"; do
        printf "  %-12s %s\n" "$app" "${APP_STATUS[$app]:-missing}"
    done
    echo
    echo "DE markers seen"
    echo "----------------"
    printf '%s\n' "$DE_MARKERS"
    echo
    echo "kernel window-mapped markers (#99)"
    echo "----------------------------------"
    printf '%s\n' "$WINDOW_MAP_MARKERS"
    echo "distinct mapped wids (whole boot) = $WINDOW_MAP_COUNT"
    echo "windows mapped AFTER gate start   = $LAUNCH_MAP_COUNT (launch-queue)"
} > "$SUMMARY"
cat "$SUMMARY"

# --- pass/fail decision ----------------------------------------------
fail=0
# cursor_fps is emitted ONLY by the LEGACY hamUId present loop, which the
# scene-file DE retires (hamUId exits right after the rl5 desktop flip). So
# in the production scene compositor it is expected to read 0 — it is NOT a
# launch-render signal and must not fail this gate. Report it as info only.
if [ "$CURSOR_FPS" -lt "$FPS_MIN" ]; then
    echo "[visual_gate] INFO: cursor_fps=$CURSOR_FPS (legacy hamUId present retired; not gated)" >&2
fi
# #99: each launched windowed app must map a FRESH window AFTER the gate
# starts. Require at least one launch-phase window-mapped marker per app in
# APPS (they map their own top-level via `newwindow` in the kernel). This is
# independent, kernel-side corroboration of the per-app pixel-render check.
LAUNCH_MAP_MIN="${LAUNCH_MAP_MIN:-${#APPS[@]}}"
if [ "$LAUNCH_MAP_COUNT" -lt "$LAUNCH_MAP_MIN" ]; then
    echo "[visual_gate] FAIL: only $LAUNCH_MAP_COUNT launch-phase window-mapped markers (< $LAUNCH_MAP_MIN); launch-queue apps did not allocate windows" >&2
    fail=1
fi
no_render_apps=()
for app in "${APPS[@]}"; do
    case "${APP_STATUS[$app]:-missing}" in
        rendered*) ;;          # "rendered (NNNN px)" / "rendered (weak ...)"
        *)
            no_render_apps+=("$app(${APP_STATUS[$app]:-missing})")
            ;;
    esac
done
if [ "${#no_render_apps[@]}" -gt 0 ]; then
    echo "[visual_gate] FAIL: apps did not render: ${no_render_apps[*]}" >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[visual_gate] PASS: ${#APPS[@]}/${#APPS[@]} launch-queue apps rendered, $LAUNCH_MAP_COUNT launch-phase windows mapped (cursor_fps=$CURSOR_FPS info-only)"
    exit 0
else
    echo "[visual_gate] FAIL (artifacts: $OUT_DIR)" >&2
    exit 1
fi
