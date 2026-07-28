#!/usr/bin/env bash
# scripts/test_de_resolution_edge_to_edge.sh — THE RESOLUTION GATE.
#
# WHY THIS EXISTS (the bug the whole suite could not see)
# ------------------------------------------------------
# Every other DE gate boots at the QEMU/OVMF default GOP mode, which is
# 1280x800 = 1,024,000 px. The per-window scene cache used to live in a
# FIXED 4 MiB buddy block (MAX_ORDER = 10 is a hard ceiling — alloc_pages
# refuses anything larger), and the cache is a tightly-packed RGBA frame,
# so a window could never be taller than 4 MiB / (w*4) rows:
#
#   1280x800  = 4,096,000 B  -> fits (4,194,304 B block). Every gate green.
#   1280x1024 = 5,242,880 B  -> 205 rows silently dropped.
#   1920x1080 = 8,294,400 B  -> 534 of 1080 rows dropped: HALF THE SCREEN.
#
# The full-screen hamdesktop backdrop therefore stopped painting at row 546
# on a 1080p panel and the compositor's root colour filled the rest — i.e.
# the desktop was only ever correct at the QEMU default, and EVERY real
# laptop panel is 1920x1080 or larger. Confirmed by screendump before the
# fix (build/de_visual/repro-1080p/de_visual.png).
#
# WHAT THIS GATE DOES
# -------------------
# For each requested mode it boots the REAL shipped installer image under
# UEFI/OVMF with `-device VGA,xres=,yres=` (the efi_stub inherits GOP's
# current mode, so this is the true guest framebuffer geometry), lets the
# production runlevel-5 desktop settle, and then asserts, on the real
# framebuffer and the real serial log:
#
#   1. the guest really runs at the requested geometry
#      (`[de_present] fb_w=W fb_h=H`), and the screendump is W x H;
#   2. NO window's cache was clamped below its geometry — the kernel emits
#      a `[wsys] cache-clamp wid=..` line whenever it has to shorten a
#      cache, and this gate requires ZERO of them. This is the invariant
#      the bug violated, and it is resolution-independent;
#   3. the compositor ROOT COLOUR (the backdrop that shows through where
#      no window paints — reported by the kernel as `root_rgb=` so this
#      gate never hard-codes a theme colour) covers < ROOT_MAX_PCT of the
#      frame, and < 5% of the LAST SCANLINE. A cache clamped short shows
#      up as a solid root-coloured slab across the bottom of the screen;
#   4. a PANEL is present at the TRUE screen height: a near-uniform band
#      within 40 px of the top edge AND within 40 px of the bottom edge of
#      the actual H (the bottom panel is placed from the real screen
#      height, so a panel that lands at 800 on a 1080 screen fails);
#   5. windows actually mapped (`[devwsys] window <n> mapped` >= MAP_MIN)
#      and the desktop backdrop window is rendering at the real resolution
#      (that is what (3) proves — it is a full-screen window).
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat/nc, a PPM converter or
# the installer image are unavailable, or when the firmware refuses the
# requested mode (we cannot test a mode the platform will not set).
#
# Env overrides:
#   RESOLUTIONS   space-separated WxH list (default "1920x1080 1280x1024")
#   INSTALLER_IMG image path      (default: build/hamnix-installer.img)
#   OVMF_FD       OVMF firmware   (default: auto-resolved)
#   BOOT_WAIT     seconds for the handoff marker            (default: 240)
#   SETTLE        seconds to let the DE paint after handoff (default: 22)
#   ROOT_MAX_PCT  max % of the frame allowed to be root colour (default: 2)
#   MAP_MIN       minimum mapped-window markers             (default: 3)
#   OUT_DIR       artifact dir    (default: build/de_resolution/<ts>)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

RESOLUTIONS="${RESOLUTIONS:-1920x1080 1280x1024}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
SETTLE="${SETTLE:-22}"
ROOT_MAX_PCT="${ROOT_MAX_PCT:-2}"
MAP_MIN="${MAP_MIN:-3}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_resolution/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[de_res] SKIP: /dev/kvm absent (KVM required)" >&2; exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[de_res] SKIP: OVMF firmware not found (apt install ovmf)" >&2; exit 0
fi
MON_DRIVER=""
if command -v socat >/dev/null 2>&1; then
    MON_DRIVER="socat"
elif command -v nc >/dev/null 2>&1; then
    MON_DRIVER="nc"
else
    echo "[de_res] SKIP: no socat/nc to drive the QEMU monitor" >&2; exit 0
fi
CONVERTER=""
command -v convert >/dev/null 2>&1 && CONVERTER="convert"
[ -z "$CONVERTER" ] && command -v pnmtopng >/dev/null 2>&1 && CONVERTER="pnmtopng"

# --- the image MUST be freshly built from this tree -------------------
# scripts/_installer_img.sh: never boot an image older than the source it
# is supposed to be testing (the stale-image trap).
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
ensure_installer_img "$INSTALLER_IMG" "[de_res]" || exit 0

mkdir -p "$OUT_DIR"
echo "[de_res] output dir: $OUT_DIR"

mon_cmd() {
    local sock="$1" cmd="$2"
    if [ "$MON_DRIVER" = "socat" ]; then
        printf '%s\n' "$cmd" | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
    else
        printf '%s\n' "$cmd" | nc -U -q1 "$sock" >/dev/null 2>&1
    fi
}

ANALYZE_PY="$OUT_DIR/analyze.py"
cat > "$ANALYZE_PY" <<'PYEOF'
# Structural analysis of a P6 PPM desktop screendump at a known geometry.
# Pure stdlib (no PIL): the framebuffer dump is a raw P6.
#   argv: <ppm> <W> <H> <root_r> <root_g> <root_b> <root_max_pct>
# Prints a JSON-ish report and exits 0 (all invariants hold) / 1.
import sys, json

def load_ppm(path):
    data = open(path, 'rb').read()
    if not data.startswith(b'P6'):
        return None
    idx = 2; toks = []
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
    w, h, _mx = toks
    return w, h, data[idx:idx + w*h*3]

ppm, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ROOT = (int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]))
ROOT_MAX_PCT = float(sys.argv[7])

img = load_ppm(ppm)
rep = {"ok": False}
if img is None:
    print(json.dumps({"error": "not a P6 PPM"})); sys.exit(1)
w, h, px = img
rep["dump_w"], rep["dump_h"] = w, h
if (w, h) != (W, H) or len(px) < w*h*3:
    rep["error"] = "screendump geometry %dx%d != requested %dx%d" % (w, h, W, H)
    print(json.dumps(rep)); sys.exit(1)

def pix(x, y):
    i = (y*w + x)*3
    return (px[i], px[i+1], px[i+2])

def near(a, b, t=6):
    return abs(a[0]-b[0]) <= t and abs(a[1]-b[1]) <= t and abs(a[2]-b[2]) <= t

# (3) root-colour coverage over the whole frame, and on the last scanline.
root_n = 0; total = 0
for y in range(0, h, 2):
    for x in range(0, w, 2):
        total += 1
        if near(pix(x, y), ROOT):
            root_n += 1
rep["root_pct"] = round(100.0*root_n/max(total, 1), 3)
last_n = 0; last_t = 0
for x in range(0, w, 2):
    last_t += 1
    if near(pix(x, h-1), ROOT):
        last_n += 1
rep["last_row_root_pct"] = round(100.0*last_n/max(last_t, 1), 3)

# FIRST row that is >=90% root colour, i.e. where the desktop STOPPED
# painting. Reported for diagnosis: the pre-fix 1080p frame cuts at 555
# (the 4 MiB block held 4194304/(1920*4) = 546 rows).
cut = None
for y in range(0, h):
    n = 0; t = 0
    for x in range(0, w, 8):
        t += 1
        if near(pix(x, y), ROOT):
            n += 1
    if n/max(t, 1) >= 0.9:
        cut = y
        break
rep["first_unpainted_row"] = cut

# (4) panel bands: a row is "panel" when >=80% of its pixels share one
# colour that is NOT the root colour and not the mid-screen backdrop.
mid = pix(w//2, h//2)
def panel_row(y):
    from collections import Counter
    c = Counter(pix(x, y) for x in range(0, w, 4))
    col, n = c.most_common(1)[0]
    frac = n/max(sum(c.values()), 1)
    return frac >= 0.80 and not near(col, ROOT) and not near(col, mid)
rep["panel_top"] = any(panel_row(y) for y in range(0, min(40, h)))
rep["panel_bottom"] = any(panel_row(y) for y in range(max(0, h-40), h))

fails = []
if rep["root_pct"] > ROOT_MAX_PCT:
    fails.append("root colour covers %.2f%% of the frame (max %.2f%%) — the "
                 "desktop is not painted edge to edge; painting stops at row "
                 "%s of %d"
                 % (rep["root_pct"], ROOT_MAX_PCT, rep["first_unpainted_row"],
                    h-1))
if rep["last_row_root_pct"] > 5.0:
    fails.append("last scanline is %.1f%% root colour — bottom of the screen "
                 "unpainted" % rep["last_row_root_pct"])
if not rep["panel_top"]:
    fails.append("no panel band within 40px of the top edge")
if not rep["panel_bottom"]:
    fails.append("no panel band within 40px of the bottom edge at the TRUE "
                 "screen height %d" % h)
rep["ok"] = not fails
rep["fails"] = fails
print(json.dumps(rep, indent=2))
sys.exit(0 if rep["ok"] else 1)
PYEOF

overall=0
tested=0

for RES in $RESOLUTIONS; do
    XRES="${RES%x*}"; YRES="${RES#*x}"
    echo ""
    echo "[de_res] ===== ${XRES}x${YRES} ====="
    RDIR="$OUT_DIR/$RES"; mkdir -p "$RDIR"
    LOG="$RDIR/serial.log"
    PPM="$RDIR/desktop.ppm"
    OVMF_RW=$(mktemp --tmpdir hamnix-res.ovmf.XXXXXX.fd)
    IMG_RW=$(mktemp --tmpdir hamnix-res.img.XXXXXX.raw)
    MON=$(mktemp --tmpdir -u hamnix-res-mon.XXXXXX)
    cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

    qemu-system-x86_64 \
        -enable-kvm -cpu host \
        -bios "$OVMF_RW" \
        -drive file="$IMG_RW",format=raw,if=virtio \
        -m "${HAMNIX_VM_MEM:-2G}" \
        -device "VGA,xres=$XRES,yres=$YRES" -display none -no-reboot \
        -monitor "unix:$MON,server,nowait" \
        -serial stdio \
        > "$LOG" 2>&1 < /dev/null &
    QEMU_PID=$!

    booted=0
    for _ in $(seq 1 "$BOOT_WAIT"); do
        grep -a -q "$HANDOFF_MARKER" "$LOG" && { booted=1; break; }
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 1
    done
    if [ "$booted" -ne 1 ]; then
        echo "[de_res] FAIL(${RES}): handoff marker not seen in ${BOOT_WAIT}s" >&2
        tail -60 "$LOG" >&2
        overall=1
        kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null
        rm -f "$OVMF_RW" "$IMG_RW" "$MON"
        continue
    fi
    sleep "$SETTLE"
    mon_cmd "$MON" "screendump $PPM"
    for _ in $(seq 1 40); do [ -s "$PPM" ] && break; sleep 0.25; done
    sleep 0.5
    kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON"

    # provenance: which image did we actually boot?
    grep -a -m1 "\[boot\] image built" "$LOG" || true

    # (1) the guest really got the mode.
    GEO=$(grep -a -m1 -oE "\[de_present\] fb_w=[0-9]+ fb_h=[0-9]+" "$LOG" || true)
    if [ -z "$GEO" ]; then
        echo "[de_res] SKIP(${RES}): no [de_present] geometry line in the serial log" >&2
        rm -f "$PPM"
        continue
    fi
    GW=$(echo "$GEO" | grep -oE "fb_w=[0-9]+" | cut -d= -f2)
    GH=$(echo "$GEO" | grep -oE "fb_h=[0-9]+" | cut -d= -f2)
    if [ "$GW" != "$XRES" ] || [ "$GH" != "$YRES" ]; then
        echo "[de_res] SKIP(${RES}): firmware set ${GW}x${GH}, not ${XRES}x${YRES}" >&2
        rm -f "$PPM"
        continue
    fi
    echo "[de_res] PASS(${RES}): guest framebuffer is ${GW}x${GH}"
    tested=$((tested + 1))
    fail=0

    # (2) NO cache was clamped below its window geometry.
    if grep -a -q "\[wsys\] cache-clamp" "$LOG"; then
        echo "[de_res] FAIL(${RES}): a window cache was clamped below its geometry:" >&2
        grep -a -m5 "\[wsys\] cache-clamp" "$LOG" >&2
        fail=1
    else
        echo "[de_res] PASS(${RES}): no window cache clamped below its geometry"
    fi

    # (5) windows actually mapped.
    MAPPED=$(grep -a -c "\[devwsys\] window .* mapped" "$LOG" || true)
    if [ "${MAPPED:-0}" -lt "$MAP_MIN" ]; then
        echo "[de_res] FAIL(${RES}): only ${MAPPED} mapped windows (want >= $MAP_MIN)" >&2
        fail=1
    else
        echo "[de_res] PASS(${RES}): ${MAPPED} windows mapped"
    fi

    # (3)+(4) the pixels.
    if [ ! -s "$PPM" ]; then
        echo "[de_res] FAIL(${RES}): no screendump captured" >&2
        fail=1
    else
        RGB=$(grep -a -m1 -oE "root_rgb=[0-9]+,[0-9]+,[0-9]+" "$LOG" | cut -d= -f2)
        if [ -z "$RGB" ]; then
            echo "[de_res] FAIL(${RES}): kernel did not report root_rgb= (present diag)" >&2
            fail=1
            RGB="32,80,96"
        fi
        RR=$(echo "$RGB" | cut -d, -f1); RG=$(echo "$RGB" | cut -d, -f2)
        RB=$(echo "$RGB" | cut -d, -f3)
        echo "[de_res] compositor root colour: rgb($RR,$RG,$RB)"
        if python3 "$ANALYZE_PY" "$PPM" "$XRES" "$YRES" "$RR" "$RG" "$RB" \
                   "$ROOT_MAX_PCT"; then
            echo "[de_res] PASS(${RES}): desktop painted edge to edge; panels at the true screen height"
        else
            echo "[de_res] FAIL(${RES}): desktop is NOT painted edge to edge" >&2
            fail=1
        fi
        if [ -n "$CONVERTER" ]; then
            case "$CONVERTER" in
                convert)  convert "$PPM" "$RDIR/desktop.png" 2>/dev/null ;;
                pnmtopng) pnmtopng "$PPM" > "$RDIR/desktop.png" 2>/dev/null ;;
            esac
            echo "[de_res] screendump: $RDIR/desktop.png"
        fi
    fi
    [ "$fail" -ne 0 ] && overall=1
done

echo ""
if [ "$tested" -eq 0 ]; then
    echo "[de_res] SKIP: no requested mode could be set by the firmware" >&2
    exit 0
fi
if [ "$overall" -eq 0 ]; then
    echo "[de_res] PASS ($tested mode(s), artifacts in $OUT_DIR)"
    exit 0
fi
echo "[de_res] FAIL (artifacts in $OUT_DIR)" >&2
exit 1
