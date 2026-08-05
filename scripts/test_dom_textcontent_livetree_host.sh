#!/usr/bin/env bash
# scripts/test_dom_textcontent_livetree_host.sh — the textContent READ-BACK gate.
#
# WHY THIS EXISTS
# ===============
# A SOURCE-anchored element had TWO representations of its content:
#
#   (1) the parse-time source span [dom_cstart, dom_cend)   — what the
#       textContent getter read (_inner_accessor NID_TC_GET -> _text_into_tw)
#   (2) the LIVE child list                                  — what appendChild,
#       removeChild, insertBefore and every other mutation write, and what
#       childNodes / innerHTML / the renderer read
#
# Script mutations only ever reach (2), so a page that did
#
#     el.appendChild(document.createElement("span"))
#
# read back childNodes.length == 2 and innerHTML == "start<span>MADE</span>"
# — and el.textContent == "start". The tree was RIGHT; only the getter answered
# from the wrong store. That is the D-series READ-BACK shape for the seventh
# time (see feedback_two_writers_defect_shape): two writers for one piece of
# state, one reader on the stale one. The fix deletes the second reader — once
# the page has mutated the source tree, textContent walks the live tree, exactly
# as the innerHTML getter already did via the same g_dom_mutated latch.
#
# It was found by scripts/test_jsengine_gc_obj_host.sh PART E, whose failure
# message blamed GC survival for it and sent the reader to the collector. That
# message now diagnoses; this gate is the direct, cheap, no-GC-involved one.
#
# WHAT IT ASSERTS
# ===============
# One page, no churn, no collection. Every expectation below is a CHROMIUM-
# MEASURED constant (chromium 141 headless on this host, same file). When
# chromium is present the gate ALSO re-measures live and diffs, so the constants
# can never quietly rot; when it is absent the baked constants are still fully
# asserted, so this is never a dark gate (project_dark_gate_dependency_class).
#
# The cases exist because the obvious fix ("just walk the live tree") had ONE
# measured regression: the tx tree does not register elements inside a
# <template> (its contents are an inert fragment), so the whole body came back
# as a single text run and "AHIDDENB" appeared where chromium says "AB". The
# spec-correct fix is that a <template> has NO child nodes at all; T7/T8 pin it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_host_tc"

echo "[dom-tc] compiling hambrowse host harness ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/dom_tc_compile.log"; then
    echo "[dom-tc] FAIL: harness did not compile"; cat "$OUT/dom_tc_compile.log"; exit 1
fi

page="$OUT/dom_tc_livetree.html"
cat > "$page" <<'EOF'
<!doctype html><html><body>
<div id="a">start</div>
<div id="b">A<template><p>HIDDEN</p></template>B</div>
<div id="c">x&amp;y<b>deep<i>er</i></b>z</div>
<div id="d">d1<!--comment-->d2</div>
<div id="e">e1<script>var zz=1;</script>e2</div>
<div id="p">P<b id="k">K</b>Q</div>
<div id="x">pre</div>
<template id="t"><p>HID</p></template>
<script>
function g(i){ return document.getElementById(i); }
function say(k, v){ console.log("TC " + k + "=[" + v + "]"); }

// ---- T1: the bug. An appended CREATED element child must be descended into.
var el = g("a");
var made = document.createElement("span");
made.textContent = "MADE";
el.appendChild(made);
say("T1_kids", el.childNodes.length);
say("T1_ih", el.innerHTML);
say("T1_tc", el.textContent);

// ---- T2: a nested created subtree, and a created text node sibling.
var o = document.createElement("div");
var inn = document.createElement("em"); inn.textContent = "IN";
o.appendChild(document.createTextNode("out"));
o.appendChild(inn);
el.appendChild(o);
say("T2_tc", el.textContent);

// ---- T3: removeChild / insertBefore on SOURCE children.
var p = g("p");
p.removeChild(g("k"));
say("T3_removed", p.textContent);
var s = document.createElement("span"); s.textContent = "S";
p.insertBefore(s, p.firstChild);
say("T3_inserted", p.textContent);

// ---- T4: mutating a source Text node's data through the node interface.
var tn = p.childNodes[p.childNodes.length - 1];
say("T4_nodeType", tn.nodeType);
tn.data = "Z";
say("T4_data", p.textContent);
say("T4_nodeValue", tn.nodeValue);

// ---- T5: entity decoding + a DESCENDANT (not direct) text child survive the
// switch to the live tree.
say("T5_tc", g("c").textContent);

// ---- T6: comments contribute nothing; <script> text DOES (chromium does not
// hide it from textContent).
say("T6_comment", g("d").textContent);
say("T6_script", g("e").textContent);

// ---- T7/T8: <template> contents are an inert fragment: not children, not
// textContent — but reachable through .content.
say("T7_tmpl_kids", g("t").childNodes.length);
say("T7_tmpl_tc", g("t").textContent);
say("T7_content_tc", g("t").content.textContent);
say("T8_inline_tmpl", g("b").textContent);

// ---- T10: an appended created TEXT node counts ONCE. _append_sync_text used
// to concatenate it onto an own textContent property as well, and once the
// getter walked the live tree that second writer double-counted it
// ("mountedmounted" in test_hambrowse_reactmount_host.sh).
var x = g("x");
x.appendChild(document.createTextNode("X"));
say("T10_kids", x.childNodes.length);
say("T10_tc", x.textContent);

// ---- T9: the sibling getters over the same state.
say("T9_el_nodeValue", g("c").nodeValue);
var f = document.createDocumentFragment();
var fe = document.createElement("i"); fe.textContent = "F";
f.appendChild(document.createTextNode("frag-"));
f.appendChild(fe);
say("T9_fragment_tc", f.textContent);
say("T9_comment_tc", document.createComment("CC").textContent);
say("T9_text_tc", document.createTextNode("TT").textContent);
</script>
</body></html>
EOF

# CHROMIUM-MEASURED expectations (chromium --headless, same file).
read -r -d '' WANT <<'EOF'
TC T1_kids=[2]
TC T1_ih=[start<span>MADE</span>]
TC T1_tc=[startMADE]
TC T2_tc=[startMADEoutIN]
TC T3_removed=[PQ]
TC T3_inserted=[SPQ]
TC T4_nodeType=[3]
TC T4_data=[SPZ]
TC T4_nodeValue=[Z]
TC T5_tc=[x&ydeeperz]
TC T6_comment=[d1d2]
TC T6_script=[e1var zz=1;e2]
TC T7_tmpl_kids=[0]
TC T7_tmpl_tc=[]
TC T7_content_tc=[HID]
TC T8_inline_tmpl=[AB]
TC T10_kids=[2]
TC T10_tc=[preX]
TC T9_el_nodeValue=[null]
TC T9_fragment_tc=[frag-F]
TC T9_comment_tc=[CC]
TC T9_text_tc=[TT]
EOF

got="$OUT/dom_tc_got.txt"
timeout 300 "$BIN" "$page" > "$OUT/dom_tc_raw.txt" 2>&1; rc=$?
sed -n 's/^JSLOG \(TC .*\)$/\1/p' "$OUT/dom_tc_raw.txt" > "$got"
if [ "$rc" -ne 0 ]; then
    echo "[dom-tc] FAIL: hambrowse exited $rc"; tail -5 "$OUT/dom_tc_raw.txt"; exit 1
fi
if [ ! -s "$got" ]; then
    echo "[dom-tc] FAIL: the engine logged no TC lines (it died before the script ran)"
    tail -10 "$OUT/dom_tc_raw.txt"; exit 1
fi

fail=0
printf '%s\n' "$WANT" > "$OUT/dom_tc_want.txt"
if diff -u "$OUT/dom_tc_want.txt" "$got" > "$OUT/dom_tc_diff.txt"; then
    echo "[dom-tc] PASS: all 22 textContent read-back facts match chromium"
else
    echo "[dom-tc] FAIL: textContent read-back differs from chromium"
    sed -n '3,60p' "$OUT/dom_tc_diff.txt" | sed 's/^/[dom-tc]     /'
    echo "[dom-tc]   A '-...MADE' / '+start' shaped diff on T1/T2 means the"
    echo "[dom-tc]   textContent getter is answering from the parse-time source"
    echo "[dom-tc]   span again instead of the live tree (lib/web/dom/canvas.ad,"
    echo "[dom-tc]   _inner_accessor NID_TC_GET). It is NOT a GC/lifetime bug:"
    echo "[dom-tc]   T1_kids and T1_ih prove the node is still in the tree."
    fail=1
fi

# Re-measure the constants against real chromium when it is here. This can only
# ever ADD a failure, never hide one — the baked comparison above already ran.
CHROMIUM="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
if [ -n "$CHROMIUM" ]; then
    orc="$OUT/dom_tc_chromium.txt"
    timeout 120 "$CHROMIUM" --headless --no-sandbox --disable-gpu \
        --user-data-dir="$OUT/dom_tc_profile" --virtual-time-budget=5000 \
        --enable-logging=stderr --dump-dom "file://$PWD/$page" 2>&1 >/dev/null \
        | sed -n 's/^.*:CONSOLE[^]]*\] "\(TC .*\)", source: .*$/\1/p' > "$orc"
    if [ ! -s "$orc" ]; then
        echo "[dom-tc] NOTE: chromium logged no TC lines — oracle re-measure skipped"
    elif diff -u "$OUT/dom_tc_want.txt" "$orc" > "$OUT/dom_tc_oracle_diff.txt"; then
        echo "[dom-tc] PASS: the baked constants still match live chromium"
    else
        echo "[dom-tc] FAIL: the baked constants no longer match live chromium"
        sed -n '3,60p' "$OUT/dom_tc_oracle_diff.txt" | sed 's/^/[dom-tc]     /'
        fail=1
    fi
else
    echo "[dom-tc] NOTE: no chromium on this host — baked constants asserted only"
fi

if [ "$fail" -eq 0 ]; then
    echo "[dom-tc] RESULT: PASS"; exit 0
fi
echo "[dom-tc] RESULT: FAIL"; exit 1
