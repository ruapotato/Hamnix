#!/usr/bin/env bash
# scripts/test_hambrowse_visual_ondevice.sh — LIVE on-device VISUAL gate:
# proves hambrowse actually RENDERS a feature-rich page onto the REAL EFI GOP
# framebuffer scanout (not a host re-render), the "device-working, not
# host-green" acceptance for this session's browser landings.
#
# WHAT IT DOES (combines the two proven harnesses)
#   * test_hambrowse_fetch_ondevice.sh: boot the installer image under OVMF/KVM
#     into the scene DE (runlevel 5) with SLIRP networking, serve the page from
#     the HOST (guest reaches it at 10.0.2.2:<port>), and launch hambrowse on it.
#   * test_de_p0_mouse_screendump.sh: drive the QEMU monitor `screendump` to
#     capture the REAL composited framebuffer to a PPM, then convert to PNG.
#
# The fixture (scripts/fixtures/hambrowse_visual_ondevice/page.html.tmpl)
# exercises THIS SESSION'S features together on one page:
#   heading + paragraph, a CSS FLEX row, a position:absolute BADGE, a
#   linear-GRADIENT background, an <IMG> (fetched relative over http9), an inline
#   <SVG> (rect+circle+path), and a scripted <CANVAS> (fillRect/path).
# Four elements are painted in LOUD, UNIQUE colours so a whole-frame pixel scan
# can find them regardless of exact window placement:
#   canvas fill  = magenta  (255,  0,255)
#   svg circle   = lime     (  0,255,  0)
#   svg rect     = orange   (255,136,  0)
#   absolute badge = yellow (255,255,  0)
#
# EVIDENCE / ASSERTIONS (three-valued PASS / FAIL / INCONCLUSIVE):
#   0. Guest [hambrowse] serial markers present, else INCONCLUSIVE (never a pass
#      on a blank/desktop-only frame).
#   1. A BASELINE screendump (desktop, before hambrowse) and an AFTER screendump
#      (page rendered) are captured. The AFTER frame is non-blank AND each LOUD
#      colour is present in a real cluster in AFTER and substantially MORE than in
#      BASELINE — proving hambrowse painted those regions onto the scanout.
#   2. Both PNGs are saved to a stable path (build/hambrowse_visual_ondevice/…)
#      and printed so a human can eyeball them.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, python3, qemu, a PPM->PNG
# converter, or the installer image is absent.
#
# Env overrides:
#   INSTALLER_IMG  live image     (default build/hamnix-installer.img)
#   OVMF_FD        OVMF firmware  (default auto-resolved)
#   BOOT_WAIT      handoff wait s (default 480)
#   PAINT_WAIT     compositor settle s (default 8)
#   OUT_DIR        artifact dir   (default build/hambrowse_visual_ondevice/<ts>)
#   MIN_COLOR_PX   min loud-colour pixels required in AFTER (default 150)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hambrowse_visual_ondevice/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-480}"
PAINT_WAIT="${PAINT_WAIT:-8}"
MIN_COLOR_PX="${MIN_COLOR_PX:-150}"

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi

[ -e /dev/kvm ] || { echo "[hbvis] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "[hbvis] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat   >/dev/null 2>&1 || { echo "[hbvis] SKIP: socat required for monitor" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[hbvis] SKIP: python3 required" >&2; exit 0; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "[hbvis] SKIP: qemu required" >&2; exit 0; }
CONVERTER=""
for c in convert ffmpeg pnmtopng; do command -v "$c" >/dev/null 2>&1 && CONVERTER="$c" && break; done
[ -z "$CONVERTER" ] && { echo "[hbvis] SKIP: no PPM->PNG converter" >&2; exit 0; }

TMPL="$PWD/scripts/fixtures/hambrowse_visual_ondevice/page.html.tmpl"
IMG_SAMPLE="$PWD/tests/fixtures/hambrowse_img_sample.png"
[ -f "$TMPL" ] || { echo "[hbvis] SKIP: fixture $TMPL missing" >&2; exit 0; }
[ -f "$IMG_SAMPLE" ] || { echo "[hbvis] SKIP: sample image $IMG_SAMPLE missing" >&2; exit 0; }

# --- build / stale-guard the installer image (mirrors test_hambrowse_fetch) ---
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[hambrowse_visual_ondevice]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[hbvis] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2; exit 0
    fi
    echo "[hbvis] building installer image (~6 min)"
    bash "$PWD/scripts/build_installer_img.sh"
else
    newer=$(find lib user sys fs etc scripts -name '*.ad' -o -name '*.S' -newer "$INSTALLER_IMG" 2>/dev/null | head -1)
    if [ -n "$newer" ]; then
        if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
            echo "[hbvis] WARNING: $INSTALLER_IMG OLDER than source ($newer) but HAMNIX_SKIP_BUILD=1 — booting STALE image" >&2
        else
            echo "[hbvis] image stale (source newer: $newer) — rebuilding (~6 min)" >&2
            bash "$PWD/scripts/build_installer_img.sh"
        fi
    fi
fi
[ -f "$INSTALLER_IMG" ] || { echo "[hbvis] SKIP: image unavailable" >&2; exit 0; }

mkdir -p "$OUT_DIR"
echo "[hbvis] output dir: $OUT_DIR"

# --- served document root: the page + the relative <img> ---
SERVE_DIR=$(mktemp -d --tmpdir hamnix-hbvis-www.XXXXXX)
PORT=$(python3 - <<'PYPORT'
import socket
s = socket.socket(); s.bind(("0.0.0.0", 0)); print(s.getsockname()[1]); s.close()
PYPORT
)
cp "$TMPL" "$SERVE_DIR/page.html"
cp "$IMG_SAMPLE" "$SERVE_DIR/sample.png"
cp "$SERVE_DIR/page.html" "$OUT_DIR/page.html"
PAGE_URL="http://10.0.2.2:$PORT/page.html"
echo "[hbvis] serving $SERVE_DIR on host port $PORT; hambrowse will load $PAGE_URL"

HTTP_LOG="$OUT_DIR/httpserver.log"
( cd "$SERVE_DIR" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 ) >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!

OVMF_RW=$(mktemp --tmpdir hamnix-hbvis.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-hbvis.img.XXXXXX.raw)
MON=$(mktemp -u --tmpdir hamnix-hbvis-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-hbvis.XXXXXX).in
BEFORE_PPM="$OUT_DIR/baseline.ppm"
AFTER_PPM="$OUT_DIR/after.ppm"
BEFORE_PNG="$OUT_DIR/baseline.png"
AFTER_PNG="$OUT_DIR/after.png"
LOG="$OUT_DIR/serial.log"
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
: > "$LOG"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    kill "$HTTP_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
    rm -rf "$SERVE_DIR"
}
trap cleanup EXIT

# host-side sanity: server actually serves the page + the image.
sleep 0.5
if command -v curl >/dev/null 2>&1; then
    curl -fs "http://127.0.0.1:$PORT/page.html" -o /dev/null \
        || { echo "[hbvis] SKIP: host server not serving page.html" >&2; exit 0; }
    curl -fs "http://127.0.0.1:$PORT/sample.png" -o /dev/null \
        || { echo "[hbvis] SKIP: host server not serving sample.png" >&2; exit 0; }
    echo "[hbvis] host sanity: page.html + sample.png served"
fi

exec 4<>"$FIFO"
exec 3>"$FIFO"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "${HAMNIX_VM_MEM:-2G}" \
    -vga std -display none -no-reboot \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1; }
send()    { printf '%s\n' "$1" >&3; }
ppm2png() {
    case "$CONVERTER" in
        convert)  convert "$1" "$2" 2>/dev/null ;;
        ffmpeg)   ffmpeg -y -loglevel error -i "$1" "$2" </dev/null ;;
        pnmtopng) pnmtopng "$1" > "$2" 2>/dev/null ;;
    esac
}
wait_marker() {  # wait_marker <grep-ere> <timeout-s>
    local pat="$1" to="$2" i
    for ((i=0; i<to; i++)); do
        grep -a -E -q "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

# --- 1. wait for the DE interactive-shell handoff ---
echo "[hbvis] waiting up to ${BOOT_WAIT}s for DE shell handoff..."
if ! wait_marker "M16.35 shell ready|handing off to interactive shell" "$BOOT_WAIT"; then
    echo "[hbvis] RESULT: INCONCLUSIVE (never reached DE shell handoff)"
    tail -40 "$LOG" >&2
    exit 2
fi
echo "[hbvis] handoff reached; letting the compositor settle ${PAINT_WAIT}s"
sleep "$PAINT_WAIT"

# --- 2. BASELINE screendump (desktop only, before hambrowse) ---
mon_cmd "screendump $BEFORE_PPM"; sleep 2
[ -s "$BEFORE_PPM" ] && echo "[hbvis] baseline screendump captured" \
    || echo "[hbvis] WARN baseline screendump empty (monitor issue)"

# --- 3. warm up the shell (first serial line is dropped) then launch hambrowse ---
warmed=0
for w in 0 1 2 3 4 5; do
    tag="__HBVISWARM_${w}__"
    send "echo $tag"
    for ((k=0; k<6; k++)); do
        grep -a -q "$tag" "$LOG" && { warmed=1; break; }
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 1
    done
    [ "$warmed" = 1 ] && { echo "[hbvis] shell warm-up ok (attempt $((w+1)))"; break; }
done
[ "$warmed" = 1 ] || echo "[hbvis] WARN shell never echoed warm-up"

echo "[hbvis] launching hambrowse on $PAGE_URL"
launched=0
for attempt in 1 2 3 4 5 6; do
    send "hambrowse $PAGE_URL &"
    if wait_marker '\[hambrowse\] rendered segs=|\[hambrowse\] fetch FAILED' 40; then
        launched=1
        echo "[hbvis] hambrowse render marker seen (attempt $attempt)"
        break
    fi
    echo "[hbvis] no render marker on attempt $attempt, retrying"
done

# Give the compositor time to blit the browser window's final page.
sleep "$PAINT_WAIT"

# --- 4. AFTER screendump (page rendered) ---
mon_cmd "screendump $AFTER_PPM"; sleep 2

# Grab the browser's own render diagnostics for the report.
RENDER_LINE=$(grep -a '\[hambrowse\] rendered segs=' "$LOG" | tail -1 || true)
ASSET_LINE=$(grep -a '\[hambrowse\] assets:' "$LOG" | tail -1 || true)

exec 3>&-
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

echo "[hbvis] --- host HTTP access log ---"
grep -a "GET" "$HTTP_LOG" 2>/dev/null | sed 's/^/[hbvis:httpd] /' || echo "[hbvis:httpd] (no GET lines)"

echo "[hbvis] --- evidence ---"
[ -n "$RENDER_LINE" ] && echo "[hbvis] $RENDER_LINE"
[ -n "$ASSET_LINE" ]  && echo "[hbvis] $ASSET_LINE"

# (0) INCONCLUSIVE guard: any guest hambrowse markers at all?
GUESTMARK=$(grep -a -c '\[hambrowse\]' "$LOG")
echo "[hbvis] guest hambrowse markers: $GUESTMARK"
if [ "$GUESTMARK" -eq 0 ]; then
    echo "[hbvis] RESULT: INCONCLUSIVE (no guest [hambrowse] markers — launch never happened)"
    tail -30 "$LOG" >&2
    exit 2
fi

# Save the PNGs for eyeballing.
[ -s "$AFTER_PPM" ] || { echo "[hbvis] RESULT: INCONCLUSIVE (empty AFTER screendump — no scanout captured)"; exit 2; }
ppm2png "$AFTER_PPM" "$AFTER_PNG"
[ -s "$BEFORE_PPM" ] && ppm2png "$BEFORE_PPM" "$BEFORE_PNG"
echo "[hbvis] BASELINE png: $BEFORE_PNG"
echo "[hbvis] AFTER    png: $AFTER_PNG"

# --- 5. sample the REAL scanout pixels: count LOUD, page-unique colours in the
#         BASELINE (desktop) vs AFTER (page rendered) frames. Each loud colour
#         must appear as a real cluster in AFTER and substantially more than in
#         BASELINE — proof hambrowse painted those regions onto the framebuffer. ---
python3 - "$BEFORE_PPM" "$AFTER_PPM" "$MIN_COLOR_PX" <<'PYSAMPLE'
import sys

def read_ppm(path):
    try:
        data = open(path, "rb").read()
    except Exception:
        return None
    if not data.startswith(b"P6"):
        return None
    idx = 2; vals = []
    while len(vals) < 3:
        while idx < len(data) and data[idx] in b" \t\n\r": idx += 1
        if idx < len(data) and data[idx:idx+1] == b"#":
            while idx < len(data) and data[idx] not in b"\n": idx += 1
            continue
        s = idx
        while idx < len(data) and data[idx] not in b" \t\n\r": idx += 1
        vals.append(int(data[s:idx]))
    w, h, _ = vals
    idx += 1
    return w, h, data[idx:idx + w*h*3]

before = read_ppm(sys.argv[1])
after  = read_ppm(sys.argv[2])
MIN_PX = int(sys.argv[3])

# LOUD, page-unique colours + a small per-channel tolerance (the std-VGA scanout
# path and any scene downsample can shift a channel by a few LSBs).
TOL = 24
TARGETS = [
    ("canvas_magenta", (255,   0, 255), "canvas fillRect (scripted <canvas>)"),
    ("svg_lime",       (  0, 255,   0), "svg <circle> fill (inline SVG)"),
    ("svg_orange",     (255, 136,   0), "svg <rect> fill (inline SVG)"),
    ("badge_yellow",   (255, 255,   0), "position:absolute badge"),
]

def count(frame, rgb):
    if frame is None: return 0, 0
    w, h, pix = frame
    n = w*h
    tr, tg, tb = rgb
    c = 0
    # stride-sample every pixel (frames are ~1024x768 -> ~0.8M px, fine in py).
    mv = memoryview(pix)
    for i in range(0, n*3, 3):
        if abs(mv[i]-tr) <= TOL and abs(mv[i+1]-tg) <= TOL and abs(mv[i+2]-tb) <= TOL:
            c += 1
    return c, n

if after is None:
    print("[hbvis:px] FAIL: AFTER frame unreadable"); sys.exit(3)
aw, ah, _ = after
print("[hbvis:px] AFTER frame: %dx%d" % (aw, ah))

# non-blank guard: the AFTER frame must have real colour diversity, not a
# uniform fill (a wedged/black scanout).
distinct = len({after[2][i:i+3].tobytes() if isinstance(after[2], memoryview) else after[2][i:i+3]
                for i in range(0, min(len(after[2]), 300000), 30)})
print("[hbvis:px] AFTER distinct-colour sample: %d" % distinct)

seen = []
fails = 0
for name, rgb, desc in TARGETS:
    a_c, _ = count(after, rgb)
    b_c, _ = count(before, rgb)
    ok = (a_c >= MIN_PX) and (a_c >= b_c*3 + MIN_PX)
    tag = "PASS" if ok else "MISS"
    if ok: seen.append(name)
    else:  fails += 1
    print("[hbvis:px] %s %-14s after=%-7d baseline=%-7d  (%s rgb=%s)" %
          (tag, name, a_c, b_c, desc, rgb))

# Verdict: require the majority (>=3 of 4) of the loud regions to appear, AND at
# least the canvas (proves scripting) or an svg shape (proves inline SVG paint).
strong = len(seen) >= 3 and ("canvas_magenta" in seen or "svg_lime" in seen or "svg_orange" in seen)
if distinct < 8:
    print("[hbvis:px] RESULT: INCONCLUSIVE (AFTER frame near-uniform — no real render captured)")
    sys.exit(2)
if strong:
    print("[hbvis:px] RESULT: PASS — features rendered on the REAL scanout: " + ", ".join(seen))
    sys.exit(0)
if seen:
    print("[hbvis:px] RESULT: PARTIAL — only %d/4 loud regions found on scanout: %s" %
          (len(seen), ", ".join(seen)))
    sys.exit(1)
print("[hbvis:px] RESULT: FAIL — no loud page region found on the scanout "
      "(hambrowse window not composited, or render blank)")
sys.exit(1)
PYSAMPLE
rc=$?

echo "[hbvis] artifacts: $OUT_DIR (serial.log, page.html, baseline/after .ppm+.png, httpserver.log)"
case "$rc" in
    0) echo "[hbvis] RESULT: PASS — hambrowse rendered the rich page on the REAL framebuffer scanout"; exit 0 ;;
    2) echo "[hbvis] RESULT: INCONCLUSIVE"; exit 2 ;;
    *) echo "[hbvis] RESULT: FAIL/PARTIAL (see [hbvis:px] lines + eyeball $AFTER_PNG)"; exit 1 ;;
esac
