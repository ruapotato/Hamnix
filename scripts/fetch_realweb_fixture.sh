#!/usr/bin/env bash
# scripts/fetch_realweb_fixture.sh — snapshot a REAL website as a SELF-CONTAINED
# single HTML file suitable for engine-vs-Chrome comparison.
#
# WHY INLINE: the host harnesses (build/host/hambrowse_host, hambrowse_gfx) read
# ONE local file and do not fetch external <link rel=stylesheet> / <script src>
# subresources (the on-device user/hambrowse.ad path DOES). Comparing a raw
# `curl` dump would therefore measure the HARNESS's missing fetcher, not the
# engine. So we fetch the document, then fetch and INLINE every same-origin-ish
# stylesheet and script, producing a file that BOTH hambrowse and
# `chromium --headless` see identically. Fair apples-to-apples.
#
# USAGE: scripts/fetch_realweb_fixture.sh <url> <out.html>
set -uo pipefail
URL="${1:?usage: fetch_realweb_fixture.sh <url> <out.html>}"
OUT="${2:?usage: fetch_realweb_fixture.sh <url> <out.html>}"
mkdir -p "$(dirname "$OUT")"
python3 "$(dirname "$0")/fetch_realweb_fixture.py" "$URL" "$OUT"
