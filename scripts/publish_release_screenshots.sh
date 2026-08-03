#!/usr/bin/env bash
# scripts/publish_release_screenshots.sh <capture-dir> [dest]
#
# Takes a capture produced by scripts/capture_release_screenshots.sh and
# publishes the repo-facing subset into docs/screenshots/: the idle desktop,
# the Applications menu, and the "running" frame of every app, plus an
# index.md carrying the honest per-app verdict table and the image
# provenance.  PPMs and the pre/typed/closed working frames stay behind in
# the capture dir — only the shots a reader should look at get committed.
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: publish_release_screenshots.sh <capture-dir> [dest]}"
DEST="${2:-$PROJ_ROOT/docs/screenshots}"
[ -f "$SRC/verdicts.tsv" ] || { echo "no verdicts.tsv in $SRC" >&2; exit 1; }
mkdir -p "$DEST"

for f in "$SRC"/00-desktop.png "$SRC"/01-appmenu.png "$SRC"/99-desktop-final.png; do
    [ -f "$f" ] && cp "$f" "$DEST/$(basename "$f")"
done
for f in "$SRC"/*-b-running.png; do
    [ -f "$f" ] || continue
    b=$(basename "$f"); cp "$f" "$DEST/${b%-b-running.png}.png"
done
cp "$SRC/provenance.txt" "$DEST/provenance.txt"
cp "$SRC/verdicts.tsv"   "$DEST/verdicts.tsv"
echo "published $(ls "$DEST"/*.png | wc -l) PNGs to $DEST"
