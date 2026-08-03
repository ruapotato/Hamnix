#!/usr/bin/env bash
# scripts/publish_release_screenshots.sh <capture-dir> [dest]
#
# Takes a capture produced by scripts/capture_release_screenshots.sh and
# publishes the repo-facing subset into docs/screenshots/:
#
#   * the idle desktop, the Applications menu (closed / submenu / search)
#     and the final desktop — FULL FRAMES, untouched;
#   * one image per app, CROPPED to the window that appeared.
#
# The crop is necessary, not cosmetic: windows cannot be torn down from the
# driver (see scripts/_crop_new_window.py), so the capture accumulates every
# app in one session.  Cropping to the changed-pixel bounding box isolates
# the app that just launched.  Every published pixel is still real scanout —
# nothing is re-rendered, scaled, or composited on the host.
#
# PPMs and the pre/typed/closed working frames stay behind in the capture dir.
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: publish_release_screenshots.sh <capture-dir> [dest]}"
DEST="${2:-$PROJ_ROOT/docs/screenshots}"
[ -f "$SRC/verdicts.tsv" ] || { echo "no verdicts.tsv in $SRC" >&2; exit 1; }
mkdir -p "$DEST"

# Full frames that are meant to show the WHOLE desktop.
for f in 00-desktop 01-appmenu 01a-appmenu-submenu 01b-appmenu-search \
         99-desktop-final; do
    [ -f "$SRC/$f.png" ] && cp "$SRC/$f.png" "$DEST/$f.png"
done

# One cropped image per app.
n=0
for pre in "$SRC"/*-a-pre.ppm; do
    [ -f "$pre" ] || continue
    base=$(basename "$pre" -a-pre.ppm)
    post="$SRC/$base-b-running.ppm"
    [ -f "$post" ] || continue
    if python3 "$PROJ_ROOT/scripts/_crop_new_window.py" \
            "$pre" "$post" "$DEST/$base.png"; then
        n=$((n + 1))
    else
        # No window-sized change: publish the full frame so the failure is
        # VISIBLE rather than silently absent from the gallery.
        cp "$SRC/$base-b-running.png" "$DEST/$base.png" 2>/dev/null || true
        echo "  !! $base: no window-sized change; published full frame" >&2
    fi
done

cp "$SRC/provenance.txt" "$DEST/provenance.txt"
cp "$SRC/verdicts.tsv"   "$DEST/verdicts.tsv"
echo "published $n cropped app shots + full frames to $DEST"
