#!/usr/bin/env bash
# scripts/test_react18_host.sh — REAL, UNMODIFIED React 18 on the native engine.
#
# The rest of the functional suite proves hand-written DOM code works. This gate
# proves a production FRAMEWORK works: the upstream react/react-dom UMD bundles
# from npm (tests/jsfunc/vendor/, byte-identical to the registry tarballs) mount
# a component tree, and a click re-renders it. Nothing about React is stubbed or
# shimmed — the reconciler, the concurrent scheduler and the synthetic-event
# system all run as shipped.
#
# THE ORACLE IS CHROMIUM, NOT A HAND-SPEC. The page publishes everything it
# computed into #log as one flat line; the gate reads that line out of THIS
# engine and out of `chromium --headless` and requires them to be EQUAL, on
# load and again after a click. A hand-written expectation could encode our own
# bug; chromium cannot. (Where chromium is missing the xref SKIPs and the
# load/click assertions below still run, so CI stays deterministic.)
#
# React 18's createRoot() is CONCURRENT — render work is deferred to its
# scheduler (MessageChannel, else setTimeout), so both sides read #log from a
# macrotask, and the chromium side runs with a virtual-time budget.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
PAGES="tests/jsfunc/pages"
VENDOR="tests/jsfunc/vendor"
PAGE="$OUT/react18.html"
mkdir -p "$OUT"

echo "[react18] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/react18_compile.log"; then
    echo "[react18] FAIL: host harness did not compile"; cat "$OUT/react18_compile.log"; exit 1
fi
echo "[react18] PASS host harness compiled -> $BIN"

# ---- assemble the self-contained page (vendor bytes spliced VERBATIM) --------
{
    sed '/<!--SCRIPTS-->/,$d' "$PAGES/react18_shell.html"
    printf '<script>\n'; cat "$VENDOR/react.production.min.js";     printf '\n</script>\n'
    printf '<script>\n'; cat "$VENDOR/react-dom.production.min.js"; printf '\n</script>\n'
    printf '<script>\n'; cat "$PAGES/react18_app.js";               printf '\n</script>\n'
    sed -n '/<!--SCRIPTS-->/,$p' "$PAGES/react18_shell.html" | tail -n +2
} > "$PAGE"

fail=0
D0=""
run() {          # run [verb args...] -> capture the dump into $D0
    D0="$OUT/react18_dump.txt"
    "$BIN" "$PAGE" 880 "$@" >"$D0" 2>&1
}
assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then echo "[react18] PASS $2"
    else echo "[react18] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then echo "[react18] FAIL $2 (present: $1)"; fail=1
    else echo "[react18] PASS $2"; fi
}
# The engine's report line, read off its console.
engine_log() { sed -n 's/^JSLOG REACT18 //p' "$D0" | tail -1; }

CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
# Replay the SAME page in chromium, optionally clicking <id> first, and return
# the #log line it produced. The driver waits a macrotask for React's concurrent
# render (and another after the click) before publishing into <title>.
chrome_log() {   # [click-id] -> stdout: the report line chromium computed
    local tmp; tmp="$(mktemp -d)"
    cp "$PAGE" "$tmp/p.html"
    # The click driver waits the same two macrotasks the app does (commit, then
    # passive-effect flush) and then clicks; the app's own document-level click
    # listener re-reports, so BOTH engines report through the identical path.
    if [ -n "${1:-}" ]; then
        printf '<script>setTimeout(function(){setTimeout(function(){document.getElementById("%s").click();},0);},0);</script>\n' "$1" >>"$tmp/p.html"
    fi
    "$CHROMIUM" --headless --no-sandbox --disable-gpu --virtual-time-budget=5000 \
        --enable-logging=stderr --dump-dom "file://$tmp/p.html" 2>&1 >/dev/null \
        | sed -n 's/.*REACT18 \(.*\)", source.*/\1/p' | tail -1
    rm -rf "$tmp"
}
xref() {         # <engine-line> <click-id|""> <message>
    [ -n "$CHROMIUM" ] || { echo "[react18] SKIP chromium xref: $3 (no chromium)"; return; }
    local want; want="$(chrome_log "$2")"
    if [ -z "$want" ]; then
        echo "[react18] FAIL chromium xref: $3 (chromium produced no #log line)"; fail=1; return
    fi
    if [ "$1" = "$want" ]; then
        echo "[react18] PASS chromium xref: $3 (byte-identical to chromium)"
    else
        echo "[react18] FAIL chromium xref: $3"
        echo "[react18]   engine : $1"
        echo "[react18]   chrome : $want"; fail=1
    fi
}

echo "----- (1) load: real React 18 MOUNTS and RENDERS a component tree -----"
run
assert_nogrep '^JSERR'                    "no uncaught JS error while React mounted"
assert_grep   'FLOW.*React 18\.'          "the mounted <h1> carries the real React version"
assert_grep   'FLOW.*Count: 0'            "useState initial render painted the button"
assert_grep   'FLOW.*alpha-0'             "keyed list child (React.memo) painted"
assert_grep   'FLOW.*hits=10'             "useReducer initial state painted"
assert_grep   'FLOW.*CTX-PROVIDED'        "useContext read through the Provider (not the default)"
assert_grep   '^JSLOG REACT18 ver=18\.3\.1 '  "the report line was published"
assert_grep   'cond=ABSENT'               "the conditional subtree is correctly NOT mounted at n=0"
assert_grep   'svg=RECT-OK'               "SVG host instance created (createElementNS path)"
assert_grep   'trace=effect:0'            "useEffect ran after the commit"
LOAD_LINE="$(engine_log)"
[ -n "$LOAD_LINE" ] && echo "[react18] engine load #log: $LOAD_LINE"
xref "$LOAD_LINE" "" "load-time render matches chromium"

echo "----- (2) click: React RE-RENDERS the tree from new state -----"
run click inc
assert_nogrep '^JSERR'                    "no uncaught JS error during the re-render"
assert_grep   'FLOW.*Count: 1'            "useState functional update advanced the counter"
assert_grep   'FLOW.*alpha-1'             "useMemo recomputed and the keyed list re-rendered"
assert_grep   'FLOW.*hits=11'             "useReducer dispatch from the same handler applied"
assert_grep   'FLOW.*CONDITIONAL-SHOWN'   "the conditional subtree MOUNTED on the state change"
assert_grep   'trace=effect:0,cleanup:0,effect:1' "effect cleanup + re-run fired in order"
CLICK_LINE="$(engine_log)"
[ -n "$CLICK_LINE" ] && echo "[react18] engine click #log: $CLICK_LINE"
xref "$CLICK_LINE" "inc" "post-click re-render matches chromium"

if [ "$fail" -ne 0 ]; then
    echo "[react18] RESULT: FAIL"; exit 1
fi
echo "[react18] RESULT: PASS"
