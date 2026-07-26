#!/usr/bin/env bash
# scripts/test_de_wallpaper_coverage_host.sh — QEMU-free host gate: the DE
# wallpaper backdrop must cover the WHOLE screen. No black band.
#
# THE USER BUG THIS GATES (2026-07, hands-on report): "if you select a
# background image like Sunset or Ocean or Tiles the background does not cover
# the full background and has a lot of black on the bottom, like 1/5 of the
# screen. Default seems to work."
#
# ROOT CAUSE. user/hamdesktop.ad::emit_wallpaper painted the image as a mosaic
# of `fill` rects into the SAME 16384-byte display list as the desktop icons,
# and simply STOPPED once it crossed the icon byte reserve:
#
#     if hamscene_length() >= WP_SCENE_BUDGET:
#         break            # <-- remaining rows never painted -> BLACK BAND
#
# The cost is one fill per RUN of equal-coloured cells per row. "Default" is a
# pure vertical gradient (1 run/row, 18 fills) so it always fit and always
# covered; Sunset/Ocean/Tiles also vary horizontally (24 runs/row, 432 fills,
# ~11 KB against a 7 KB budget) so they were truncated partway down.
#
# THE FIX, and what this asserts against the emitted display list:
#   1. the mosaic MEASURES candidate grids and coarsens to the finest one that
#      FITS, instead of truncating -> every scanline is painted; and
#   2. the shipped path is one compositor-scaled named-image blit
#      (`image 0 0 <scr_w> <scr_h> wallpaper`), asserted structurally by
#      scripts/test_de_desktop_wallpaper.sh (a host scene dump has no window,
#      so it exercises the mosaic FALLBACK, which is the harder case).
#
# It runs the WORST case: --wall fills the source with a different colour per
# cell so run-coalescing never fires, and --stress loads a full MAX_ICONS
# launcher set so the icon layer still demands its reserve.
#
# SKIPS CLEANLY when the Python seed compiler is unavailable.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="build/host/de_wallpaper_coverage"
CAP=16384

python3 -c 'import compiler.adder' >/dev/null 2>&1 || {
    echo "[wpcover] SKIP: Python seed compiler unavailable" >&2; exit 0; }

mkdir -p "$OUT"
echo "[wpcover] compiling hamdesktop for the host ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamdesktop.ad -o "$OUT/hamdesktop" >"$OUT/compile.log" 2>&1; then
    echo "[wpcover] FAIL: hamdesktop did not compile" >&2
    tail -20 "$OUT/compile.log" >&2; exit 1
fi

DUMP="$OUT/wall.scene"
rm -f "$DUMP"
if ! "$OUT/hamdesktop" --scene-dump "$DUMP" --stress --wall > "$OUT/run.log" 2>&1; then
    echo "[wpcover] FAIL: --scene-dump --stress --wall run failed" >&2
    cat "$OUT/run.log" >&2; exit 1
fi
[ -s "$DUMP" ] || { echo "[wpcover] FAIL: empty display list" >&2; exit 1; }

bytes=$(wc -c < "$DUMP")
if [ "$bytes" -gt "$CAP" ]; then
    echo "[wpcover] FAIL display list $bytes bytes EXCEEDS cap $CAP" >&2; exit 1
fi
echo "[wpcover] PASS display list $bytes bytes <= cap $CAP"

# The backdrop layer is the leading run of `fill` ops (icons/labels follow).
# Assert their union covers every pixel of the 800x600 host screen.
python3 - "$DUMP" <<'PY'
import sys

SCR_W, SCR_H = 800, 600          # hamdesktop host defaults (_screen_dims fails)
rects = []
for line in open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').splitlines():
    parts = line.split()
    if not parts:
        continue
    if parts[0] != 'fill':
        if not rects:
            continue              # leading "# scene v1 hamui" header
        break                     # end of the backdrop layer
    x, y, w, h = (int(v) for v in parts[1:5])
    rects.append((x, y, w, h))

if not rects:
    print("[wpcover] FAIL: no backdrop fills emitted")
    sys.exit(1)

# Per-row interval union -> first uncovered pixel, if any.
rows = [[] for _ in range(SCR_H)]
for (x, y, w, h) in rects:
    for yy in range(max(0, y), min(SCR_H, y + h)):
        rows[yy].append((max(0, x), min(SCR_W, x + w)))

bad = None
for yy in range(SCR_H):
    cur = 0
    for (a, b) in sorted(rows[yy]):
        if a > cur:
            break
        cur = max(cur, b)
    if cur < SCR_W:
        bad = (yy, cur)
        break

print("[wpcover] backdrop fills: %d, covering rows 0..%d"
      % (len(rects), max(y + h - 1 for (_, y, _, h) in rects)))
if bad is not None:
    print("[wpcover] FAIL: row %d uncovered from x=%d — BLACK BAND "
          "(the mosaic truncated instead of coarsening)" % bad)
    sys.exit(1)
print("[wpcover] PASS: every one of the %d scanlines is fully covered "
      "0..%d — no black band" % (SCR_H, SCR_W - 1))
PY
rc=$?
[ "$rc" -eq 0 ] || { echo "[wpcover] RESULT: FAIL" >&2; exit 1; }
echo "[wpcover] RESULT: PASS (artifacts in $OUT)"
exit 0
