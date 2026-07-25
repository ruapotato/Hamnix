#!/usr/bin/env bash
# scripts/probe_realweb_dom.sh — compare the POST-JS DOM of a real-site fixture
# between hambrowse and real chromium.
#
# Method: append an identical CENSUS script to a copy of the page. It counts the
# live element tree (total nodes, div/a/input/button counts, body text length)
# AFTER the page's own JS has run, and writes the summary into document.title.
# hambrowse reports the title on its `TITLE` output line; chromium's comes out of
# `--dump-dom`. Same page, same probe, two engines -> a directly comparable
# fingerprint of "did the page's JavaScript actually build the DOM it meant to".
#
# Usage: scripts/probe_realweb_dom.sh [fixture.html ...]   (default: all realweb)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="build/host/hambrowse_probe_host"; [ -x "$BIN" ] || BIN="build/host/hambrowse_host"
CHROMIUM="$(command -v chromium || command -v chromium-browser)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

CENSUS='<script>(function(){function C(){try{var t=document.getElementsByTagName("*").length,
d=document.getElementsByTagName("div").length,a=document.getElementsByTagName("a").length,
i=document.getElementsByTagName("input").length,b=document.getElementsByTagName("button").length,
x=(document.body&&document.body.textContent||"").replace(/[ \t\n\r]+/g," ").trim().length;
document.title="CENSUS all="+t+" div="+d+" a="+a+" input="+i+" button="+b+" text="+x;}
catch(e){document.title="CENSUS THREW "+e;}}C();setTimeout(C,0);setTimeout(C,50);})();</script>'

files=("$@")
[ ${#files[@]} -eq 0 ] && files=(tests/fixtures/realweb/*.html)

printf '%-16s %-58s %s\n' SITE HAMBROWSE CHROMIUM
for f in "${files[@]}"; do
    name="$(basename "$f" .html)"
    cp "$f" "$WORK/p.html"
    printf '%s\n' "$CENSUS" >> "$WORK/p.html"
    hb="$(timeout 600 "$BIN" "$WORK/p.html" 1024 2>&1 | sed -n 's/^TITLE //p' | tail -1)"
    [ -z "$hb" ] && hb="<no TITLE line / timeout>"
    ch="$(timeout 120 "$CHROMIUM" --headless --no-sandbox --disable-gpu \
            --virtual-time-budget=10000 --dump-dom "file://$WORK/p.html" 2>/dev/null \
          | grep -o '<title>[^<]*</title>' | head -1 | sed 's/<[^>]*>//g')"
    [ -z "$ch" ] && ch="<none>"
    printf '%-16s %-58s %s\n' "$name" "$hb" "$ch"
done
