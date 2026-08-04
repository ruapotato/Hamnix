#!/usr/bin/env bash
# scripts/test_livedom_functional_host.sh — LIVE-DOM FUNCTIONAL harness.
#
# WHY THIS EXISTS
# ===============
# Every browser harness we had compares one of two things:
#   * PIXELS  — scripts/framediff_gfx_all.sh (SSIM against a chromium screenshot)
#   * ONE FACT — the ~200 scripts/test_hambrowse_*_host.sh gates, each of which
#     publishes a single hand-written string (console.log / document.title) and
#     compares it to a chromium-measured constant.
# Neither can see the class of bug that keeps real sites from WORKING: a page
# renders, but the elements its JavaScript created or replaced are not reachable
# by events, so the second click does nothing. A pixel diff of a correct-looking
# first paint is green for exactly that page.
#
# This harness compares the WHOLE LIVE DOM after scripts have run AND after real
# events have been dispatched, against real `chromium --headless` on the same
# file. It is the "dump-dom diff" lane: per fixture, one canonical serialisation
# from each engine, diffed line by line.
#
# METHOD
# ======
# One IDENTICAL driver script (SERIALIZER below) is appended to a copy of each
# fixture and run in BOTH engines. It:
#   1. waits a macrotask for the page's own load-time script,
#   2. calls the fixture's window.__act() — the fixture's interaction script,
#      which dispatches REAL events (el.click(), el.dispatchEvent(...)) into
#      whatever the page built dynamically,
#   3. drains timers (nested setTimeout, then a 50 ms one — the same drain
#      scripts/probe_realweb_dom.sh uses),
#   4. walks the resulting LIVE DOM in document order and console.log()s one
#      line per node.
# Both engines' console output is read off the same channel: hambrowse prints it
# as `JSLOG ...`, chromium as `--enable-logging=stderr` CONSOLE lines. The
# producer is the same JS in both, so the comparison is of the two engines' DOMs
# and event machinery, not of two different serialisers.
#
# The evidence for "the new node is reachable by events" is structural: the
# fixture's handlers only mutate the DOM, so a handler that did not fire shows up
# as a MISSING node in the diff, not as a soft assertion.
#
# WHAT IS NORMALISED, AND WHY  (read this before trusting a green)
# ================================================================
# The failure mode of a harness like this is an over-eager normaliser that hides
# real divergence. The complete list of what we throw away:
#   N1 whitespace-only text nodes are DROPPED and runs of whitespace inside a
#      text node are collapsed to one space. HTML source indentation produces
#      text nodes whose exact splitting is a parser detail, not a functional
#      one. This canNOT hide a missing element, a missing attribute, or missing
#      text — only the shape of inter-element whitespace.
#   N2 text-node content is truncated to 100 chars (with a "…" marker). Keeps a
#      console line inside chromium's logging path. Divergence beyond char 100
#      of a single text node is invisible; fixtures are written short so this
#      never bites.
#   N3 attributes are emitted SORTED BY NAME. Attribute order is not part of the
#      DOM. Names and values are compared verbatim — nothing about a value is
#      normalised.
#   N4 the contents (not the presence) of <script> and <style> elements are
#      skipped. That text is source, not live state, and the injected driver
#      would otherwise dominate every diff.
#   N5 the injected driver <script id="__ldh"> element itself is skipped on both
#      sides — it exists only because we put it there.
#   N6 tag names are lowercased (chromium reports HTML tagName uppercase).
#   N7 the doctype node is not serialised.
# NOT normalised, on purpose: element presence, order, depth, tag, attribute
# names and values, text content, comment nodes (frameworks use them as
# markers), input .value / .checked / select .selectedIndex live state, and the
# node count. A fixture that renders identically but whose click did nothing
# fails here.
#
# WHAT THE FIRST RUN FOUND (2026-08-04, main a5e53862) — pass 0 / fail 15
# ======================================================================
# The brief this harness was built for said "dynamically-created/updated
# elements are unreachable by events". THAT IS NOT WHAT IS BROKEN. Directly
# measured, both engines agree exactly:
#   * a click on a script-created <button> runs its listener,
#   * a click on a node inside an innerHTML-replaced subtree runs its listener,
#   * a click on a 5-deep script-built tree bubbles to a delegated ancestor with
#     the right event.target and event.currentTarget,
#   * three clicks in a row accumulate state on the same created node.
# Events REACH dynamic nodes. What diverges is DOM READ-BACK after mutation, and
# a short list of specific API gaps. In fixture order, the causes are:
#   D1 el.attributes omits attributes set through PROPERTY setters (el.id = x,
#      el.className = x). getAttribute('id') and getAttributeNames() both have
#      them; only the NamedNodeMap is missing them. Single biggest diff producer
#      — it is why nearly every created node prints "[]" here.
#   D2 stale text read-back on a SOURCE-parsed element: after
#      src.textContent = 'NEW', src.textContent returns 'NEW' but
#      src.childNodes[0].nodeValue and src.innerHTML still return the ORIGINAL
#      source text. Same story for classList.add(): className shows 'c1 c2',
#      getAttribute('class') still says 'c1'. Created nodes are fine; the
#      source-anchored lazy-text/attribute path is what is stale. This makes
#      every "handler wrote into a static output div" fixture fail on a
#      read-back, not on a dispatch.
#   D3 insertBefore(documentFragment, ref) inserts NOTHING; the fragment's
#      children are lost (host.childNodes stays 1, the ids go MISSING).
#   D4 node.parentNode still points at the old parent after removeChild().
#   D5 checkbox.click() performs no activation behaviour: .checked does not flip
#      and no change event fires. Radio-group exclusivity likewise never runs.
#   D6 select.value = 'c' moves .value but not .selectedIndex.
#   D7 in two fixtures the <script> element's own source text also shows up as a
#      TEXT NODE sibling of the script in body.
# None of these are visible to a pixel diff, and none of them are the bug the
# brief predicted.
#
# USAGE
#   bash scripts/test_livedom_functional_host.sh            # all fixtures
#   bash scripts/test_livedom_functional_host.sh create     # name filter
#   KEEP=1 bash scripts/...                                 # keep the workdir
#
# EXIT STATUS is a FLOOR, not perfection: tests/fixtures/livedom/BASELINE lists
# the fixtures that were byte-identical to chromium when the floor was banked.
# A fixture in BASELINE that stops matching is a REGRESSION and exits 1; a
# fixture that starts matching is printed as NEW PASS — bank it by adding its
# name to BASELINE. STRICT=1 demands all 15.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIXDIR="tests/fixtures/livedom"
FILTER="${1:-}"
mkdir -p "$OUT"

CHROMIUM="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
if [ -z "$CHROMIUM" ]; then
    # The oracle IS chromium; without it this gate asserts nothing, and a fake
    # "expected" table baked from memory is exactly the trap this lane exists to
    # avoid. Skip loudly rather than lie.
    echo "[livedom] SKIP: no chromium on PATH — this harness has no oracle without it"
    exit 0
fi

echo "[livedom] compiling host engine (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/livedom_compile.log"; then
    echo "[livedom] FAIL: host engine did not compile"; cat "$OUT/livedom_compile.log"; exit 1
fi

WORK="$(mktemp -d)"
if [ "${KEEP:-0}" = "1" ]; then
    echo "[livedom] workdir $WORK (KEEP=1)"
else
    trap 'rm -rf "$WORK"' EXIT
fi

# ---------------------------------------------------------------------------
# The driver. Injected byte-identically into both engines.
# ---------------------------------------------------------------------------
cat > "$WORK/driver.html" <<'DRIVER'
<script id="__ldh">
(function(){
  var LINES = 0;
  function say(s){ LINES++; console.log("LD " + s); }
  function txt(s){
    s = String(s).replace(/[\s ]+/g, " ");          /* N1 collapse */
    if (s.length > 100) s = s.slice(0, 100) + "…";  /* N2 truncate */
    return s;
  }
  function attrs(el){
    var out = [], i, a = el.attributes;
    if (a) for (i = 0; i < a.length; i++) out.push(a[i].name + "=" + a[i].value);
    out.sort();                                          /* N3 sort */
    return out.join(" ");
  }
  /* Live state that has NO attribute mirror. A form control whose .value the
     page changed still serialises with its ORIGINAL value= attribute in every
     browser, so an attribute-only dump is blind to the whole form lane. */
  function live(el){
    var t = el.tagName.toLowerCase(), s = "";
    if (t === "input" || t === "textarea") {
      s += " #value=" + txt(el.value === undefined ? "" : el.value);
      s += " #checked=" + (el.checked ? 1 : 0);
    } else if (t === "select") {
      s += " #value=" + txt(el.value === undefined ? "" : el.value);
      s += " #sel=" + el.selectedIndex;
    }
    return s;
  }
  function walk(n, d){
    var t = n.nodeType, i, c;
    if (t === 1) {
      var tag = n.tagName.toLowerCase();                 /* N6 lowercase */
      if (n.id === "__ldh") return;                      /* N5 self */
      say(d + " E " + tag + " [" + attrs(n) + "]" + live(n));
      if (tag === "script" || tag === "style") return;   /* N4 opaque bodies */
      c = n.childNodes;
      for (i = 0; i < c.length; i++) walk(c[i], d + 1);
      return;
    }
    if (t === 3) {
      var s = txt(n.nodeValue);
      if (s.replace(/ /g, "") === "") return;            /* N1 ws-only */
      say(d + " T " + s);
      return;
    }
    if (t === 8) { say(d + " C " + txt(n.nodeValue)); return; }
    /* other node types (doctype=10, N7) are not serialised */
  }
  function dump(){
    try {
      walk(document.documentElement, 0);
      say("#END nodes=" + LINES);
    } catch (e) { say("#THREW " + e); }
  }
  function act(){
    try { if (typeof window.__act === "function") window.__act(); }
    catch (e) { say("#ACT-THREW " + e); }
  }
  /* macrotask for the page's own load script -> act -> drain -> dump */
  setTimeout(function(){
    act();
    setTimeout(function(){ setTimeout(function(){ setTimeout(dump, 50); }, 0); }, 0);
  }, 0);
})();
</script>
DRIVER

hb_dump() {   # <prepared page> -> canonical lines on stdout
    timeout 300 "$BIN" "$1" 880 2>&1 \
        | sed -n 's/^JSLOG LD //p'
}
ch_dump() {   # <prepared page> -> canonical lines on stdout
    # Greedy \(.*\) so a text node that itself contains '", source: ' cannot
    # truncate the line.
    timeout 120 "$CHROMIUM" --headless --no-sandbox --disable-gpu \
        --virtual-time-budget=8000 --enable-logging=stderr \
        --dump-dom "file://$1" 2>&1 >/dev/null \
        | sed -n 's/^.*:CONSOLE[^]]*\] "LD \(.*\)", source: .*$/\1/p' \
        | tr -d '\r'
}

BASELINE="$FIXDIR/BASELINE"
banked() {   # is $1 in the banked-pass list?
    [ -f "$BASELINE" ] || return 1
    grep -qx "$1" "$BASELINE"
}

pass=0; fail=0; FAILED=""; REGRESSED=""; NEWPASS=""
for fx in "$FIXDIR"/*.html; do
    [ -e "$fx" ] || { echo "[livedom] FAIL: no fixtures in $FIXDIR"; exit 1; }
    name="$(basename "$fx" .html)"
    [ -n "$FILTER" ] && case "$name" in *"$FILTER"*) ;; *) continue ;; esac

    page="$WORK/$name.html"
    cat "$fx" "$WORK/driver.html" > "$page"
    abs="$(readlink -f "$page")"

    hb_dump "$abs" > "$WORK/$name.hb"
    ch_dump "$abs" > "$WORK/$name.ch"

    why=""
    if [ ! -s "$WORK/$name.ch" ]; then
        why="ORACLE PRODUCED NOTHING (chromium logged no LD lines)"
    elif [ ! -s "$WORK/$name.hb" ]; then
        why="hambrowse produced no LD lines (engine died or JSERR)"
    elif ! diff -q "$WORK/$name.hb" "$WORK/$name.ch" >/dev/null; then
        why="live DOM differs from chromium"
    fi

    if [ -z "$why" ]; then
        echo "[livedom] PASS $name ($(wc -l < "$WORK/$name.ch" | tr -d ' ') nodes, live DOM identical to chromium)"
        pass=$((pass+1))
        banked "$name" || NEWPASS="$NEWPASS $name"
    else
        echo "[livedom] FAIL $name — $why"
        [ -s "$WORK/$name.ch" ] && [ -s "$WORK/$name.hb" ] && \
            diff -u "$WORK/$name.ch" "$WORK/$name.hb" \
                | sed -e '1,2d' -e 's/^/[livedom]     /' | head -24
        fail=$((fail+1)); FAILED="$FAILED $name"
        banked "$name" && REGRESSED="$REGRESSED $name"
    fi
done

echo "[livedom] ---------------------------------------------"
echo "[livedom] RESULT pass=$pass fail=$fail"
[ -n "$FAILED" ] && echo "[livedom] failing:$FAILED"
if [ -n "$NEWPASS" ]; then
    echo "[livedom] NEW PASS (not yet banked):$NEWPASS"
    echo "[livedom]   bank it: add the name(s) to $BASELINE"
fi
if [ -n "$REGRESSED" ]; then
    echo "[livedom] REGRESSION — these were banked as matching chromium:$REGRESSED"
    exit 1
fi
if [ "${STRICT:-0}" = "1" ] && [ "$fail" -ne 0 ]; then
    echo "[livedom] STRICT=1: $fail fixture(s) still diverge"
    exit 1
fi
echo "[livedom] floor held (banked passes: $(grep -cvE '^\s*(#|$)' "$BASELINE" 2>/dev/null || echo 0))"
exit 0
