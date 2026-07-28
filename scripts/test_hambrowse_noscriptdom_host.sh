#!/usr/bin/env bash
# scripts/test_hambrowse_noscriptdom_host.sh — <noscript> is RAWTEXT, and that
# has to be true in the DOM as well as on screen.
#
# WHAT IT CATCHES
# ===============
# hambrowse always runs scripts, so per the HTML standard a <noscript> element's
# content is CHARACTER DATA, not markup: nothing inside it enters the document
# tree. The RENDERER already knew that (it is what stops the ubiquitous "Please
# enable JavaScript" block from painting — see test_hambrowse_google_host.sh),
# but the DOM TREE INDEXER did not, so every element inside a <noscript> still
# got a record and script could count it, query it, and getElementById it.
#
# MEASURED against `chromium --headless --dump-dom`,
# document.getElementsByTagName("*").length on unmodified real-site snapshots:
#     tests/fixtures/realsites/google_search.html    20 vs chromium 16
#     tests/fixtures/realsites/wikipedia_plan9.html 4576 vs chromium 4575
# and the excess was EXACTLY each page's <noscript> contents — google_search's
# one block holds A+DIV+META+STYLE, wikipedia's holds a single <img>. Both pages
# now match chromium exactly.
#
# ORACLE: chromium on the SAME fixture, line for line — the gate diffs the two
# engines' console output rather than checking a hard-coded census, so a
# disagreement names itself. Chromium absent => that comparison is SKIPped
# (never failed) and the explicit assertions below still run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_host_nsdom"
FIX="tests/fixtures/hambrowse_noscriptdom.html"
fail=0

echo "[hb-nsdom] compiling host driver (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/nsdom_compile.log"; then
    echo "[hb-nsdom] FAIL: host driver did not compile"; cat "$OUT/nsdom_compile.log"; exit 1
fi
echo "[hb-nsdom] PASS host driver compiled"

HAM="$OUT/nsdom_ham.txt"
"$BIN" "$FIX" 880 2>&1 | tr '|' '\n' | sed -n 's/^.*\(NSDOM .*[^ ]\) *$/\1/p' | sed 's/ *$//' | sort -u > "$HAM"
if [ ! -s "$HAM" ]; then
    echo "[hb-nsdom] FAIL: the engine reported no NSDOM lines at all"; exit 1
fi

want() {   # want <exact line> <description>
    if grep -qxF -- "$1" "$HAM"; then
        echo "[hb-nsdom] PASS $2"
    else
        echo "[hb-nsdom] FAIL $2 (expected line: $1)"
        fail=1
    fi
}

want 'NSDOM all=8' \
     'the element census counts only the LIVE tree (html/head/body/2 noscript/2 div/script)'
want 'NSDOM tags=BODY:1,DIV:2,HEAD:1,HTML:1,NOSCRIPT:2,SCRIPT:1' \
     'no A / IMG / SPAN / META / STYLE from inside the <noscript> blocks'
want 'NSDOM dead1=null' \
     'getElementById cannot reach an element inside <noscript>'
want 'NSDOM dead4=null' \
     'nor one inside a NESTED <noscript>'
want 'NSDOM qsa-dead=0' \
     'querySelectorAll cannot reach them either'
want 'NSDOM live1=FOUND' \
     'the element BEFORE the block is still reachable'
want 'NSDOM live2=FOUND' \
     'and so is the one AFTER it (the skip stops at the right close tag)'
want 'NSDOM trap=x</noscript>y' \
     'a literal "</noscript>" inside a JS string closes nothing'

CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
if [ -n "$CHROMIUM" ]; then
    CHR="$OUT/nsdom_chr.txt"
    "$CHROMIUM" --headless --no-sandbox --disable-gpu --enable-logging=stderr \
        --dump-dom "file://$(readlink -f "$FIX")" 2>&1 >/dev/null \
        | sed -n 's/^.*\(NSDOM .*\)$/\1/p' | sed 's/", source:.*$//' \
        | sed 's/ *$//' | sort -u > "$CHR"
    if [ ! -s "$CHR" ]; then
        echo "[hb-nsdom] SKIP chromium comparison (chromium logged nothing)"
    elif diff -u "$CHR" "$HAM" > "$OUT/nsdom_diff.txt"; then
        echo "[hb-nsdom] PASS all $(wc -l < "$CHR") reported values match chromium exactly"
    else
        echo "[hb-nsdom] FAIL engine and chromium disagree —"
        sed -n '3,40p' "$OUT/nsdom_diff.txt"
        fail=1
    fi
else
    echo "[hb-nsdom] SKIP chromium comparison (no chromium installed)"
fi

# ---------------------------------------------------------------------------
# The REAL-SITE case this came from: google_search.html's element census. The
# page ships one <noscript>; its four elements are the entire difference from
# chromium's answer.
# ---------------------------------------------------------------------------
REAL="tests/fixtures/realsites/google_search.html"
if [ -f "$REAL" ]; then
    W="$(mktemp -d)"
    cp "$REAL" "$W/p.html"
    cat >> "$W/p.html" <<'EOF'
<script>console.log('NSREAL all=' + document.getElementsByTagName('*').length);</script>
EOF
    gh="$(timeout 600 "$BIN" "$W/p.html" 1024 2>&1 | tr '|' '\n' \
           | sed -n 's/^.*NSREAL all=\([0-9]*\).*$/\1/p' | tail -1)"
    if [ -n "$CHROMIUM" ]; then
        gc="$(timeout 120 "$CHROMIUM" --headless --no-sandbox --disable-gpu \
                --enable-logging=stderr --virtual-time-budget=10000 \
                --dump-dom "file://$W/p.html" 2>&1 >/dev/null \
              | sed -n 's/^.*NSREAL all=\([0-9]*\).*$/\1/p' | tail -1)"
    else
        gc=""
    fi
    rm -rf "$W"
    if [ -z "$gh" ]; then
        echo "[hb-nsdom] FAIL google_search census produced no number"; fail=1
    elif [ -z "$gc" ]; then
        echo "[hb-nsdom] SKIP google_search chromium census (no chromium)"
        # Still pin the absolute number chromium gave when this was measured.
        if [ "$gh" = "16" ]; then
            echo "[hb-nsdom] PASS google_search census is 16 (chromium's recorded answer)"
        else
            echo "[hb-nsdom] FAIL google_search census $gh, chromium measured 16"; fail=1
        fi
    elif [ "$gh" = "$gc" ]; then
        echo "[hb-nsdom] PASS google_search element census matches chromium exactly ($gh)"
    else
        echo "[hb-nsdom] FAIL google_search element census $gh vs chromium $gc"; fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-nsdom] RESULT: FAIL"; exit 1
fi
echo "[hb-nsdom] RESULT: PASS"
