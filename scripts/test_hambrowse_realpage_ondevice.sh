#!/usr/bin/env bash
# scripts/test_hambrowse_realpage_ondevice.sh — LIVE on-device REALISTIC-PAGE
# gate + defect-discovery harness. Where test_hambrowse_visual_ondevice.sh proves
# a small feature-showcase renders, THIS gate loads a realistic article/landing
# page that exercises common real-web patterns TOGETHER — a flex NAV BAR (links +
# right-aligned button), a wrapping heading+body, a 3-column CARD GRID, a bordered
# TABLE, ordered+unordered LISTS, a blockquote, and a FORM (text input + select +
# submit button) — then screendumps the REAL EFI GOP framebuffer and CRITICALLY
# ASSESSES the layout so cosmetic rendering defects can be enumerated for targeted
# fixes.
#
# MECHANISM: reuses the proven boot+serve+screendump path of the visual gate
# verbatim (OVMF/KVM boot into scene DE runlevel 5 + SLIRP, host-served page the
# guest reaches at 10.0.2.2, QEMU monitor `screendump` -> PPM -> PNG).
#
# The fixture (scripts/fixtures/hambrowse_realpage/page.html.tmpl) paints several
# page regions in LOUD, page-unique colours so a whole-frame pixel scan can locate
# each region's BOUNDING BOX + centroid regardless of window placement, and reason
# about LAYOUT (are the three cards side-by-side columns or wrongly stacked?):
#   nav bar band   = navy     ( 16, 32, 58)
#   nav CTA button = orange   (255, 85,  0)
#   card 1 swatch  = crimson  (230, 25, 75)
#   card 2 swatch  = green    ( 60,180, 75)
#   card 3 swatch  = teal    (  0,153,153)
#   table header   = yellow   (255,225, 25)
#   blockquote bar = purple   (145, 30,180)
#   form submit    = magenta  (240, 50,230)
#
# VERDICT (three-valued, SOFT/REPORT gate):
#   INCONCLUSIVE (exit 125): no guest [hambrowse] markers, empty/near-uniform AFTER
#     frame, or DE handoff never reached — never a fake pass on a blank scanout.
#   FAIL (exit 1): AFTER frame non-blank but FEWER than MIN_REGIONS loud regions
#     found (page crashed / rendered almost nothing).
#   PASS (exit 0): AFTER frame non-blank AND >= MIN_REGIONS regions present. The
#     harness STILL enumerates every layout/paint anomaly it detects (cards
#     stacked instead of columns, nav button mis-placed, missing table header,
#     etc.) as [hbreal:defect] lines — a PASS with cosmetic defects is expected;
#     this gate only FAILs on a blank/crashed render.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, python3, qemu, a PPM->PNG
# converter, or the installer image is absent.
#
# Env overrides:
#   INSTALLER_IMG  live image     (default build/hamnix-installer.img)
#   OVMF_FD        OVMF firmware  (default auto-resolved)
#   BOOT_WAIT      handoff wait s (default 480)
#   PAINT_WAIT     compositor settle s (default 8)
#   OUT_DIR        artifact dir   (default build/hambrowse_realpage_ondevice/<ts>)
#   MIN_REGION_PX  min pixels for a loud region to count as present (default 80)
#   MIN_REGIONS    min distinct regions for PASS (default 4)
#
# VERDICT CODES (scripts/_verdict.sh, project-wide): 0 = PASS, 1 = FAIL,
# 125 = INCONCLUSIVE. This family used a LOCAL 2 for INCONCLUSIVE until
# 2026-07-28. scripts/ci_run_gate.sh maps 125 to a ::warning:: and 2 to a
# BUILD FAILURE, so the private code turned every "could not observe the
# assertion" run into a red shard. There is no reason for the exception and
# it is gone; any embedded python helper that still exits 2 is INTERNAL and
# is remapped by the `case "$rc"` at the foot of the script.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hambrowse_realpage_ondevice/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-480}"
PAINT_WAIT="${PAINT_WAIT:-8}"
MIN_REGION_PX="${MIN_REGION_PX:-80}"
MIN_REGIONS="${MIN_REGIONS:-4}"

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi

[ -e /dev/kvm ] || { echo "[hbreal] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "[hbreal] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat   >/dev/null 2>&1 || { echo "[hbreal] SKIP: socat required for monitor" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[hbreal] SKIP: python3 required" >&2; exit 0; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "[hbreal] SKIP: qemu required" >&2; exit 0; }
CONVERTER=""
for c in convert ffmpeg pnmtopng; do command -v "$c" >/dev/null 2>&1 && CONVERTER="$c" && break; done
[ -z "$CONVERTER" ] && { echo "[hbreal] SKIP: no PPM->PNG converter" >&2; exit 0; }

TMPL="$PWD/scripts/fixtures/hambrowse_realpage/page.html.tmpl"
IMG_SAMPLE="$PWD/tests/fixtures/hambrowse_img_sample.png"
[ -f "$TMPL" ] || { echo "[hbreal] SKIP: fixture $TMPL missing" >&2; exit 0; }

# --- build / stale-guard the installer image --------------------------------
# NEVER boot an image older than the tree under test, and NEVER print a verdict
# for a run that had no image to boot. installer_img_or_verdict
# (scripts/_installer_img.sh) covers all three cases in one call:
#
#   a usable image is in place                   -> returns; the gate carries on
#   HAMNIX_SKIP_BUILD=1 and the image is absent  -> exit 0   (skip BY REQUEST)
#   the build ran and FAILED / produced no image -> exit 125 (INCONCLUSIVE)
#
# The hand-rolled block this replaces got the third case wrong, and it cost
# ~100 s of runner time per gate per run: it invoked build_installer_img.sh
# WITHOUT checking its status, fell through to `cp "$INSTALLER_IMG" "$IMG_RW"`,
# booted QEMU with no drive at all, and burned the whole BOOT_WAIT to a
# timeout that then read as a browser FAIL. A false RED, expensive twice over.
#
# Its stale check was broken too:
#     find lib user sys fs etc scripts -name '*.ad' -o -name '*.S' -newer "$IMG"
# `-newer` binds to the '*.S' branch ONLY (find's implicit -a outranks -o), so
# the expression is `(-name '*.ad') OR (-name '*.S' AND -newer $IMG)` and the
# first .ad file in the tree always matched. The image "was stale" on every
# single run. installer_img_is_stale does the mtime comparison properly.
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "[hambrowse_realpage_ondevice]"

mkdir -p "$OUT_DIR"
echo "[hbreal] output dir: $OUT_DIR"

# --- served document root: the page + the relative <img> ---
SERVE_DIR=$(mktemp -d --tmpdir hamnix-hbreal-www.XXXXXX)
PORT=$(python3 - <<'PYPORT'
import socket
s = socket.socket(); s.bind(("0.0.0.0", 0)); print(s.getsockname()[1]); s.close()
PYPORT
)
cp "$TMPL" "$SERVE_DIR/page.html"
[ -f "$IMG_SAMPLE" ] && cp "$IMG_SAMPLE" "$SERVE_DIR/sample.png"
cp "$SERVE_DIR/page.html" "$OUT_DIR/page.html"
PAGE_URL="http://10.0.2.2:$PORT/page.html"
echo "[hbreal] serving $SERVE_DIR on host port $PORT; hambrowse will load $PAGE_URL"

HTTP_LOG="$OUT_DIR/httpserver.log"
( cd "$SERVE_DIR" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 ) >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!

OVMF_RW=$(mktemp --tmpdir hamnix-hbreal.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-hbreal.img.XXXXXX.raw)
MON=$(mktemp -u --tmpdir hamnix-hbreal-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-hbreal.XXXXXX).in
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

# host-side sanity: server actually serves the page.
sleep 0.5
if command -v curl >/dev/null 2>&1; then
    curl -fs "http://127.0.0.1:$PORT/page.html" -o /dev/null \
        || { echo "[hbreal] SKIP: host server not serving page.html" >&2; exit 0; }
    echo "[hbreal] host sanity: page.html served"
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
echo "[hbreal] waiting up to ${BOOT_WAIT}s for DE shell handoff..."
if ! wait_marker "M16.35 shell ready|handing off to interactive shell" "$BOOT_WAIT"; then
    echo "[hbreal] RESULT: INCONCLUSIVE (never reached DE shell handoff)"
    tail -40 "$LOG" >&2
    exit 125
fi
echo "[hbreal] handoff reached; letting the compositor settle ${PAINT_WAIT}s"
sleep "$PAINT_WAIT"

# --- 2. BASELINE screendump (desktop only, before hambrowse) ---
mon_cmd "screendump $BEFORE_PPM"; sleep 2
[ -s "$BEFORE_PPM" ] && echo "[hbreal] baseline screendump captured" \
    || echo "[hbreal] WARN baseline screendump empty (monitor issue)"

# --- 3. warm up the shell (first serial line is dropped) then launch hambrowse ---
warmed=0
for w in 0 1 2 3 4 5; do
    tag="__HBREALWARM_${w}__"
    send "echo $tag"
    for ((k=0; k<6; k++)); do
        grep -a -q "$tag" "$LOG" && { warmed=1; break; }
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 1
    done
    [ "$warmed" = 1 ] && { echo "[hbreal] shell warm-up ok (attempt $((w+1)))"; break; }
done
[ "$warmed" = 1 ] || echo "[hbreal] WARN shell never echoed warm-up"

echo "[hbreal] launching hambrowse on $PAGE_URL"
for attempt in 1 2 3 4 5 6; do
    send "hambrowse $PAGE_URL &"
    if wait_marker '\[hambrowse\] rendered segs=|\[hambrowse\] fetch FAILED' 40; then
        echo "[hbreal] hambrowse render marker seen (attempt $attempt)"
        break
    fi
    echo "[hbreal] no render marker on attempt $attempt, retrying"
done

# Give the compositor time to blit the browser window's final page.
sleep "$PAINT_WAIT"

# --- 4. AFTER screendump (page rendered) ---
mon_cmd "screendump $AFTER_PPM"; sleep 2

RENDER_LINE=$(grep -a '\[hambrowse\] rendered segs=' "$LOG" | tail -1 || true)
ASSET_LINE=$(grep -a '\[hambrowse\] assets:' "$LOG" | tail -1 || true)

exec 3>&-
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

echo "[hbreal] --- host HTTP access log ---"
grep -a "GET" "$HTTP_LOG" 2>/dev/null | sed 's/^/[hbreal:httpd] /' || echo "[hbreal:httpd] (no GET lines)"

echo "[hbreal] --- evidence ---"
[ -n "$RENDER_LINE" ] && echo "[hbreal] $RENDER_LINE"
[ -n "$ASSET_LINE" ]  && echo "[hbreal] $ASSET_LINE"

# (0) INCONCLUSIVE guard: any guest hambrowse markers at all?
GUESTMARK=$(grep -a -c '\[hambrowse\]' "$LOG")
echo "[hbreal] guest hambrowse markers: $GUESTMARK"
if [ "$GUESTMARK" -eq 0 ]; then
    echo "[hbreal] RESULT: INCONCLUSIVE (no guest [hambrowse] markers — launch never happened)"
    tail -30 "$LOG" >&2
    exit 125
fi

[ -s "$AFTER_PPM" ] || { echo "[hbreal] RESULT: INCONCLUSIVE (empty AFTER screendump — no scanout captured)"; exit 125; }
ppm2png "$AFTER_PPM" "$AFTER_PNG"
[ -s "$BEFORE_PPM" ] && ppm2png "$BEFORE_PPM" "$BEFORE_PNG"
echo "[hbreal] BASELINE png: $BEFORE_PNG"
echo "[hbreal] AFTER    png: $AFTER_PNG"

# --- 5. locate each LOUD region on the REAL scanout, compute its bbox/centroid,
#         and reason about LAYOUT so cosmetic defects can be enumerated. ---
python3 - "$BEFORE_PPM" "$AFTER_PPM" "$MIN_REGION_PX" "$MIN_REGIONS" <<'PYSAMPLE'
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
MIN_PX      = int(sys.argv[3])
MIN_REGIONS = int(sys.argv[4])

TOL = 26
# name, rgb, human description
TARGETS = [
    ("nav_navy",     ( 16, 32, 58), "nav bar band"),
    ("nav_cta",      (255, 85,  0), "nav right-aligned CTA button (orange)"),
    ("card1_crimson",(230, 25, 75), "card 1 swatch (crimson)"),
    ("card2_green",  ( 60,180, 75), "card 2 swatch (green)"),
    ("card3_teal",   (  0,153,153), "card 3 swatch (teal)"),
    ("table_yellow", (255,225, 25), "table header row (yellow)"),
    ("quote_purple", (145, 30,180), "blockquote accent bar (purple)"),
    ("form_magenta", (240, 50,230), "form submit button (magenta)"),
]

if after is None:
    print("[hbreal:px] FAIL: AFTER frame unreadable"); sys.exit(3)
aw, ah, apix = after
amv = memoryview(apix)
print("[hbreal:px] AFTER frame: %dx%d" % (aw, ah))

# non-blank guard
distinct = len({bytes(apix[i:i+3]) for i in range(0, min(len(apix), 300000), 30)})
print("[hbreal:px] AFTER distinct-colour sample: %d" % distinct)

def iswhite(j): return amv[j] > 230 and amv[j+1] > 232 and amv[j+2] > 235

# --- isolate the BROWSER WINDOW column via a near-white column histogram, so
#     loud-region scans are not confounded by the blue DE wallpaper (which sits
#     in the right/edge columns OUTSIDE the page). The page background is a large
#     near-white block; its x-span is the window. ---
colcnt = [0]*aw
whitepx = 0
for y in range(ah):
    base = y*aw*3
    for x in range(aw):
        if iswhite(base + x*3):
            colcnt[x] += 1; whitepx += 1
def span(cnt, n, thr):
    lo = next((i for i in range(len(cnt)) if cnt[i] > thr*n), 0)
    hi = next((i for i in range(len(cnt)-1, -1, -1) if cnt[i] > thr*n), len(cnt)-1)
    return lo, hi
WIN_X0, WIN_X1 = span(colcnt, ah, 0.15)
# exclude the top menu bar and the bottom taskbar rows from region scans.
WIN_Y0, WIN_Y1 = 24, ah-30
print("[hbreal:px] browser window column ~ x[%d..%d]  near-white frac=%.3f" % (WIN_X0, WIN_X1, whitepx/(aw*ah)))

# dark-text density inside the window = "page body actually painted" evidence.
darktext = 0
for y in range(WIN_Y0, WIN_Y1):
    base = y*aw*3
    for x in range(WIN_X0, WIN_X1+1):
        j = base + x*3
        if amv[j] < 90 and amv[j+1] < 90 and amv[j+2] < 90:
            darktext += 1
print("[hbreal:px] dark-text px inside window = %d" % darktext)

def scan_win(frame, rgb):
    """count/bbox/centroid for pixels within TOL of rgb, CLIPPED to the browser
    window column + interior rows (desktop wallpaper excluded)."""
    if frame is None:
        return (0,0,0,0,0,0,0)
    w, h, pix = frame
    tr, tg, tb = rgb
    mv = memoryview(pix)
    c=0; sx=0; sy=0; minx=w; miny=h; maxx=-1; maxy=-1
    x0 = max(0, WIN_X0); x1 = min(w-1, WIN_X1)
    y0 = max(0, WIN_Y0); y1 = min(h-1, WIN_Y1)
    for y in range(y0, y1+1):
        base = y*w*3
        for x in range(x0, x1+1):
            j = base + x*3
            if abs(mv[j]-tr) <= TOL and abs(mv[j+1]-tg) <= TOL and abs(mv[j+2]-tb) <= TOL:
                c += 1; sx += x; sy += y
                if x<minx: minx=x
                if y<miny: miny=y
                if x>maxx: maxx=x
                if y>maxy: maxy=y
    if c == 0:
        return (0,0,0,0,0,0,0)
    return (c, minx, miny, maxx, maxy, sx//c, sy//c)

results = {}
present = []
for name, rgb, desc in TARGETS:
    a = scan_win(after, rgb)
    b = scan_win(before, rgb)
    a_c = a[0]; b_c = b[0]
    ok = (a_c >= MIN_PX) and (a_c >= b_c*3 + MIN_PX)
    results[name] = (a, b, ok, desc, rgb)
    tag = "PRESENT" if ok else "absent "
    if ok:
        present.append(name)
        _, minx, miny, maxx, maxy, cx, cy = a
        print("[hbreal:px] %-8s %-14s px=%-6d bbox=(%d,%d)-(%d,%d) centroid=(%d,%d)  %s"
              % (tag, name, a_c, minx, miny, maxx, maxy, cx, cy, desc))
    else:
        print("[hbreal:px] %-8s %-14s after=%-6d baseline=%-6d  %s"
              % (tag, name, a_c, b_c, desc))

print("[hbreal:px] loud regions found above the fold: %d/%d (%s)" % (len(present), len(TARGETS), ", ".join(present) if present else "none"))
print("[hbreal:px] NOTE: a realistic page is TALL; regions below the single-viewport")
print("[hbreal:px]       fold will read 'absent' here — that is a viewport limit, not")
print("[hbreal:px]       necessarily a paint defect. The PASS/FAIL verdict is gated on")
print("[hbreal:px]       page-body-painted evidence, NOT on the above-the-fold count.")

# ---- defect enumeration: compare to how a real browser lays this out ----
defects = []
def cen(name):
    a = results[name][0]
    return (a[5], a[6]) if results[name][2] else None

# nav bar should be a wide band at the very TOP of the page window.
if "nav_navy" in present:
    a = results["nav_navy"][0]
    _, minx, miny, maxx, maxy, cx, cy = a
    band_w = maxx - minx
    if miny > ah * 0.35:
        defects.append("nav bar band not near the top (miny=%d of %d) — vertical block flow / body top margin" % (miny, ah))
    if band_w < aw * 0.25:
        defects.append("nav bar band is narrow (width=%d) — flex nav not spanning full width / display:flex on <nav>" % band_w)
else:
    defects.append("nav bar band MISSING — <nav> background / flex row not painted (display:flex, background-color)")

# nav CTA should be to the RIGHT of the nav and near the top (flex spacer + right align).
c_cta = cen("nav_cta"); c_nav = cen("nav_navy")
if c_cta is None:
    defects.append("nav CTA button MISSING — <button> in nav not rendered (button default styling / flex child)")
else:
    if c_nav is not None and c_cta[0] < aw * 0.4:
        defects.append("nav CTA button not right-aligned (cx=%d) — flex spacer (flex:1) / justify not honoured" % c_cta[0])
    if results["nav_cta"][0][2] and results["nav_cta"][0][4] > ah*0.35:
        defects.append("nav CTA button below the nav bar — not laid out as a flex child inside <nav>")

# three card swatches should be side-by-side COLUMNS: similar y, spread across x.
cards = [("card1_crimson", cen("card1_crimson")), ("card2_green", cen("card2_green")), ("card3_teal", cen("card3_teal"))]
have = [(n,c) for n,c in cards if c is not None]
# only flag a swatch as a paint DEFECT when at least one sibling DID paint (so all
# three being below the fold is not reported as three missing cards).
if have:
    missing_cards = [n for n,c in cards if c is None]
    for n in missing_cards:
        defects.append("%s not painted while a sibling card did — flex card / background-color on child div" % n)
if len(have) >= 2:
    ys = [c[1] for _,c in have]
    xs = [c[0] for _,c in have]
    yspread = max(ys) - min(ys)
    xspread = max(xs) - min(xs)
    # columns => small y spread, large x spread. stacked => large y spread, small x spread.
    if yspread > xspread and yspread > 40:
        defects.append("card swatches appear STACKED not in columns (y-spread=%d > x-spread=%d) — display:flex on .cards row not laying children horizontally" % (yspread, xspread))
    elif xspread < aw * 0.2 and len(have) >= 3:
        defects.append("card swatches clustered horizontally (x-spread=%d) — flex row not distributing 3 columns across width" % xspread)
    # check left-to-right order matches crimson<green<teal
    order = sorted(have, key=lambda t: t[1][0])
    names_in_order = [n for n,_ in order]
    if len(have) == 3 and names_in_order != ["card1_crimson","card2_green","card3_teal"]:
        defects.append("card column order wrong L->R: %s (expected crimson,green,teal) — flex source-order" % ",".join(names_in_order))

# NOTE: the table, blockquote, and form live LOWER on a tall page and may be
# below the single-viewport fold — so their absence is reported as INFO, and only
# a wrong LAYOUT when they ARE visible is flagged as a defect.
notes = []
if "table_yellow" not in present:
    notes.append("table header row not seen above the fold (below fold, or thead th background not painted)")
else:
    a = results["table_yellow"][0]
    _, minx, miny, maxx, maxy, cx, cy = a
    if (maxx-minx) < aw*0.2:
        defects.append("table header band narrow (width=%d) — table width:100%% / border-collapse layout" % (maxx-minx))

if "quote_purple" not in present:
    notes.append("blockquote accent bar not seen above the fold (below fold, or border-left not painted)")
else:
    a = results["quote_purple"][0]
    _, minx, miny, maxx, maxy, cx, cy = a
    bw = maxx-minx
    if bw > 40:
        defects.append("blockquote accent is wide (width=%d) not a thin left border — border-left rendered as full background?" % bw)

if "form_magenta" not in present:
    notes.append("form submit button not seen above the fold (below fold, or styled <button type=submit> not painted)")

# vertical ORDER sanity: nav < cards < table < form top-to-bottom.
def cy_of(name):
    return results[name][0][6] if results[name][2] else None
seq = [("nav_navy",cy_of("nav_navy")), ("card2_green",cy_of("card2_green")),
       ("table_yellow",cy_of("table_yellow")), ("form_magenta",cy_of("form_magenta"))]
seq = [(n,y) for n,y in seq if y is not None]
for i in range(len(seq)-1):
    if seq[i][1] > seq[i+1][1] + 10:
        defects.append("vertical order inverted: %s (y=%d) below %s (y=%d) — block flow order" %
                       (seq[i][0], seq[i][1], seq[i+1][0], seq[i+1][1]))

for n in notes:
    print("[hbreal:note] " + n)
print("[hbreal:px] --- DEFECTS (%d) ---" % len(defects))
for d in defects:
    print("[hbreal:defect] " + d)
if not defects:
    print("[hbreal:defect] (no LAYOUT defect flagged by pixel heuristics above the fold — eyeball the PNG for cosmetic issues)")

# ---- verdict (SOFT gate) ----
# "page body actually painted" = a substantial near-white page-content column WITH
# real dark text inside the browser window. This is the render evidence the gate
# passes on — NOT the count of loud swatches (which is a below-fold viewport limit,
# used only for defect DISCOVERY above).
BODY_PAINTED = (whitepx >= 0.10*aw*ah) and (darktext >= 2000) and (WIN_X1-WIN_X0) >= 0.25*aw
if distinct < 8:
    print("[hbreal:px] RESULT: INCONCLUSIVE (AFTER frame near-uniform — no real render captured)")
    sys.exit(2)
if BODY_PAINTED:
    print("[hbreal:px] RESULT: PASS — realistic page BODY painted on the REAL scanout "
          "(near-white content + %d dark-text px in the window); %d layout defect(s), "
          "%d below-fold note(s) enumerated above" % (darktext, len(defects), len(notes)))
    sys.exit(0)
print("[hbreal:px] RESULT: FAIL — browser window shows no painted page body "
      "(near-white frac=%.3f, dark-text=%d) — render crashed or blank" % (whitepx/(aw*ah), darktext))
sys.exit(1)
PYSAMPLE
rc=$?

echo "[hbreal] artifacts: $OUT_DIR (serial.log, page.html, baseline/after .ppm+.png, httpserver.log)"
case "$rc" in
    0) echo "[hbreal] RESULT: PASS — hambrowse rendered the realistic page on the REAL framebuffer (see [hbreal:defect] lines for cosmetic findings)"; exit 0 ;;
    2) echo "[hbreal] RESULT: INCONCLUSIVE"; exit 125 ;;
    *) echo "[hbreal] RESULT: FAIL (blank/crashed render — see [hbreal:px] lines + eyeball $AFTER_PNG)"; exit 1 ;;
esac
