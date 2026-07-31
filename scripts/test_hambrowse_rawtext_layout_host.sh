#!/usr/bin/env bash
# scripts/test_hambrowse_rawtext_layout_host.sh — FAST, QEMU-free gate for two
# of the three defects found behind the USER-REPORTED "running a Google search
# fails and google.com loads unusable". Both reproduced host-side, with
# `chromium --headless --dump-dom` as the oracle.
#
# SIBLING, NOT DUPLICATE. scripts/test_hambrowse_rawtext_host.sh already pins
# raw-text scope for the SOURCE-TEXT SCANNERS (_dom_collect_selector /
# _dom_find_by_id / _dom_build_tree_index), and it has passed throughout. That
# is precisely how this bug stayed hidden: the DOM side skipped script bodies
# correctly, so getElementById kept finding the element the LAYOUT side had
# just swallowed. Two scanners, two raw-text rules, one of them missing. This
# gate is the LAYOUT half (_layout's skip loop in lib/web/layout/flow.ad).
#
# A. RAWTEXT/RCDATA TOKENIZATION — the serious one, and not a google quirk.
#    <script>/<style>/<title>/<textarea> hold raw text: '<' is an ORDINARY
#    CHARACTER there and only the matching end tag closes them. The layout skip
#    loop walked every '<' as markup, so
#        <script>var b = 1<0;</script><div id=z>ZZZ</div>
#    read "<0;</script><div id=z>" as ONE tag (it ran to the next '>'), ate the
#    div's start tag, and then hunted a </script> that no longer existed —
#    dropping the ENTIRE REST OF THE DOCUMENT. One `a < b` in an inline script
#    blanked the page from that point on. That is most of the web.
#
# C. ToInt32 ON `<<`. The RESULT of a JS left shift is an Int32 (ES2024
#    §13.10.1). Adder evaluates integer expressions in 64-bit registers and
#    truncates only on a store to a 32-bit slot, so the shifted-out bits
#    survived: 45<<29 came out 24159191040 instead of -1610612736. Obfuscated
#    real-world bundles (google's Closure output is a state machine of
#    `<<`/`>>`/`&`/`^` guards) take a DIFFERENT BRANCH on that.
#
# The lettering is deliberately not contiguous: fix B, the inline-style
# "reveal" tri-state, is held OUT of main on branch `hold/style-reveal` behind
# real position:fixed painting (see docs/browser_blank_at_rest_reftests.md), and
# its assertions live with it in scripts/test_hambrowse_style_reveal_host.sh.
# Nothing here asserts behaviour main does not have — google.com's SEARCH page
# still renders blank without B, and this gate does not claim otherwise. Its
# HOME page, which never depended on B, is pinned below so the RAWTEXT change is
# shown not to have moved it.
#
# PART E measures the ENV ARENA over those same real pages, because
# "environment pool exhausted" was the other half of the same user report and
# the ONLY way to tell a capacity limit from a lifetime bug is occupancy over a
# session. The answer is LIFETIME, and already collected on this base: the
# pages peak in the hundreds against a ceiling of 80,000, and a 300,000-scope
# Function.prototype.call loop — the construct the original report died in —
# runs to completion while the arena is swept and REFILLED. This gate fails if
# that ever stops being true.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_rtx"
JSBIN="$OUT/js_rtx"
D="$OUT/rawtext"
mkdir -p "$D"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"

echo "[rtx] compiling hambrowse_host for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$D/compile.log"; then
    echo "[rtx] FAIL: host harness did not compile"; cat "$D/compile.log"; exit 1
fi
echo "[rtx] compiling js_host for x86_64-linux ..."
if ! adder_bin x86_64-linux user/js_host.ad "$JSBIN" 2>"$D/jscompile.log"; then
    echo "[rtx] FAIL: js host did not compile"; cat "$D/jscompile.log"; exit 1
fi

fail=0
pass() { echo "[rtx] PASS $1"; }
bad()  { echo "[rtx] FAIL $1"; fail=1; }

render() {   # file [width]
    timeout 600 "$BIN" "$1" "${2:-1024}" >"$D/out.txt" 2>&1
}
want_seg() { # needle message
    if grep -qF -- "|$1|" "$D/out.txt"; then pass "$2"; else
        bad "$2 (no segment |$1|)"; sed -n '1,12p' "$D/out.txt"; fi
}
no_seg() {   # needle message
    if grep -qF -- "|$1|" "$D/out.txt"; then
        bad "$2 (segment |$1| present)"; else pass "$2"; fi
}

# ---------------------------------------------------------------------------
# PART A — RAWTEXT / RCDATA: '<' inside script/style/title/textarea is TEXT.
# ---------------------------------------------------------------------------
cat > "$D/a1.html" <<'EOF'
<html><body><script>var a=1;var b=a<0?1:2;</script><div id="z">ZZZ</div><p>AFTER</p></body></html>
EOF
render "$D/a1.html" 400
want_seg "ZZZ"   "A1 a bare \`a<0\` in a script does not eat the next element"
want_seg "AFTER" "A1 the rest of the document survives it"

cat > "$D/a2.html" <<'EOF'
<html><body><script>var s="a<b<c<d";var t='<p x';</script><p>KEPT</p></body></html>
EOF
render "$D/a2.html" 400
want_seg "KEPT" "A2 '<' inside a JS string literal is not markup"

cat > "$D/a3.html" <<'EOF'
<html><body><style>/* width < 40em */ p{color:#ff0000}</style><p>STYLED</p></body></html>
EOF
render "$D/a3.html" 400
want_seg "STYLED" "A3 '<' inside a <style> body is not markup"
if grep -qE '^SEG .*#ff0000.*\|STYLED\|' "$D/out.txt"; then
    pass "A3 the stylesheet still applies after the '<'"
else
    bad "A3 the stylesheet was lost"; grep '^SEG' "$D/out.txt" | head -3
fi

cat > "$D/a4.html" <<'EOF'
<html><body><textarea>1 < 2 and 3 > 2</textarea><p>PAST</p></body></html>
EOF
render "$D/a4.html" 400
want_seg "PAST" "A4 '<' inside a <textarea> is not markup"

# A5 — the skip must still END. A </script> really does close it, and markup
# after it is markup again (a mutation-test guard: a skip that never ends and a
# skip that ends immediately both fail PART A).
cat > "$D/a5.html" <<'EOF'
<html><body><script>var q=1<2;</script><p>ONE</p><script>var r=3<4;</script><p>TWO</p></body></html>
EOF
render "$D/a5.html" 400
want_seg "ONE" "A5 first script closes"
want_seg "TWO" "A5 second script closes"
no_seg  "var q=1<2;" "A5 script SOURCE never leaks into the render"

# ---------------------------------------------------------------------------
# PART C — ToInt32 on `<<`. Values pinned against node v20 (and the ES spec).
# ---------------------------------------------------------------------------
cat > "$D/c.js" <<'EOF'
console.log([45<<29, 11<<31, 1<<31, (-1)<<31, '8'<<28, 1<<32, 1<<33,
             3000000000|0, -1>>>1, (1<<31)>>>0, (1<<30)*4|0].join(","));
EOF
WANT_C="-1610612736,-2147483648,-2147483648,-2147483648,-2147483648,1,2,-1294967296,2147483647,2147483648,0"
GOT_C=$(timeout 120 "$JSBIN" "$D/c.js" 2>&1 | tr -d '\r')
if [ "$GOT_C" = "$WANT_C" ]; then
    pass "C left shift truncates to Int32 (11 pinned values match node/ES2024)"
else
    bad "C shift results are not Int32"; echo "  got:  $GOT_C"; echo "  want: $WANT_C"
fi

# ---------------------------------------------------------------------------
# PART D — the REAL captured google.com home page must not move. It renders
# without the held reveal fix, so it is a legitimate neutrality pin here.
# ---------------------------------------------------------------------------
GH="tests/fixtures/realsites/google_home.html"
if [ ! -f "$GH" ]; then
    bad "D fixture missing: $GH"
else
    render "$GH" 1024
    want_seg "[ Google Search ]"     "D google.com home still renders its search button"
    want_seg "[ I'm Feeling Lucky ]" "D ...and its second button"
    want_seg "Advanced search"       "D ...and the link below them"
fi

# ---------------------------------------------------------------------------
# PART E — ENV ARENA: capacity or lifetime? MEASURED, not assumed.
# ---------------------------------------------------------------------------
ENVCEIL=80000
for f in tests/fixtures/realsites/google_search.html "$GH"; do
    [ -f "$f" ] || continue
    line=$(HAMNIX_JS_ARENA_STATS=1 timeout 600 "$BIN" "$f" 1024 2>&1 | grep '^ARENA ' | tail -1)
    if [ -z "$line" ]; then
        bad "E no ARENA readout for $(basename "$f")"; continue
    fi
    envs=$(echo "$line" | grep -o 'envs=[0-9]*' | cut -d= -f2)
    emax=$(echo "$line" | grep -o 'envmax=[0-9]*' | cut -d= -f2)
    if [ "$emax" != "$ENVCEIL" ]; then
        bad "E env ceiling changed ($emax != $ENVCEIL) — re-measure before moving it"
    fi
    # A real page must sit FAR below the ceiling. If one ever creeps past a
    # quarter of it, that is the signal to look again, not to raise the cap.
    if [ "${envs:-0}" -lt $((ENVCEIL / 4)) ]; then
        pass "E $(basename "$f") peaks at $envs/$emax envs (capacity is not the constraint)"
    else
        bad "E $(basename "$f") reached $envs/$emax envs"
    fi
done

# The construct the original report died in: 300,000 call scopes driven through
# Function.prototype.call (which runs its callback with gc_disabled set). This
# is FAR past the 80,000 ceiling, so it can only complete if dead scopes are
# RECLAIMED — the proof that "environment pool exhausted" was a lifetime bug
# and not a sizing one. It must also produce the right answer.
cat > "$D/e.html" <<'EOF'
<html><body><div id="d">x</div><script>
function step(x){ var y = x + 1; return y; }
var s = 0;
for (var i = 0; i < 300000; i++) s = step.call(null, s);
document.getElementById("d").textContent = "SUM" + s;
</script></body></html>
EOF
eline=$(HAMNIX_JS_ARENA_STATS=1 timeout 900 "$BIN" "$D/e.html" 400 2>&1 | tee "$D/out.txt" | grep '^ARENA ' | tail -1)
want_seg "SUM300000" "E 300,000 call/apply scopes complete with the right result"
ecolls=$(echo "$eline" | grep -o 'envcolls=[0-9]*' | cut -d= -f2)
efreed=$(echo "$eline" | grep -o 'envfreed=[0-9]*' | cut -d= -f2)
if [ "${ecolls:-0}" -ge 1 ] && [ "${efreed:-0}" -ge 1 ]; then
    pass "E the env arena was collected and REFILLED (envcolls=$ecolls envfreed=$efreed)"
else
    bad "E no env reclamation observed (envcolls=${ecolls:-?} envfreed=${efreed:-?}) — the arena is leaking again"
fi
if grep -q "environment pool exhausted" "$D/out.txt"; then
    bad "E the env pool was exhausted by a bounded live set"
else
    pass "E no 'environment pool exhausted' on a bounded live set"
fi

if [ "$fail" -ne 0 ]; then
    echo "[rtx] RESULT: FAIL"
    exit 1
fi
echo "[rtx] RESULT: PASS"
exit 0
