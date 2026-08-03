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
#
# Accepts ONE capture dir, or a batch root containing b1/ b2/ ... (see
# scripts/capture_release_screenshots_batched.sh); in the batch case the
# verdict tables are concatenated and the desktop/menu frames come from b1.
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: publish_release_screenshots.sh <capture-dir|batch-root> [dest]}"
DEST="${2:-$PROJ_ROOT/docs/screenshots}"
mkdir -p "$DEST"

DIRS=()
if [ -f "$SRC/verdicts.tsv" ]; then
    DIRS=("$SRC")
else
    for d in "$SRC"/b*/; do
        [ -f "$d/verdicts.tsv" ] && DIRS+=("${d%/}")
    done
fi
[ "${#DIRS[@]}" -gt 0 ] || { echo "no verdicts.tsv under $SRC" >&2; exit 1; }
FIRST="${DIRS[0]}"

# Full frames that are meant to show the WHOLE desktop.
for f in 00-desktop 01-appmenu 01a-appmenu-submenu 01b-appmenu-search \
         99-desktop-final; do
    [ -f "$FIRST/$f.png" ] && cp "$FIRST/$f.png" "$DEST/$f.png"
done

n=0
head -1 "$FIRST/verdicts.tsv" > "$DEST/verdicts.tsv"
for SRCD in "${DIRS[@]}"; do
    tail -n +2 "$SRCD/verdicts.tsv" | grep -v '^[[:space:]]*$' \
        >> "$DEST/verdicts.tsv" || true
    # One cropped image per app.
    for pre in "$SRCD"/*-a-pre.ppm; do
        [ -f "$pre" ] || continue
        base=$(basename "$pre" -a-pre.ppm)
        post="$SRCD/$base-b-running.ppm"
        [ -f "$post" ] || continue
        # Explicit boxes for windows whose chrome is pixel-identical to what
        # they cover, so no threshold can find the frame automatically.
        extra=()
        case "$base" in
            18-hamtetris) extra=(--box 339,100,371,502) ;;
        esac
        if python3 "$PROJ_ROOT/scripts/_crop_new_window.py" \
                "$pre" "$post" "$DEST/$base.png" "${extra[@]}"; then
            n=$((n + 1))
        else
            # No window-sized change: publish the full frame so the failure
            # is VISIBLE rather than silently absent from the gallery.
            cp "$SRCD/$base-b-running.png" "$DEST/$base.png" 2>/dev/null || true
            echo "  !! $base: no window-sized change; published full frame" >&2
        fi
    done
done

cp "$FIRST/provenance.txt" "$DEST/provenance.txt"
echo "published $n cropped app shots + full frames to $DEST"
