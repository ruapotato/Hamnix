#!/usr/bin/env bash
# scripts/test_hambrowse_style_reveal_host.sh — FAST, QEMU-free gate for the
# inline-style REVEAL (the dom_ov_hide tri-state).
#
# THIS GATE SHIPS WITH ITS FIX AND NOT BEFORE. It lives on branch
# `hold/style-reveal` together with the change it asserts; main does not have
# that change, and a gate on main asserting behaviour main does not have is
# worse than no gate. See docs/browser_blank_at_rest_reftests.md for why the
# fix is held and what lands it.
#
# WHAT IT ASSERTS. The inline `display` override used to be a FLAG (none /
# hidden), so script had no way to say "shown". `el.setAttribute("style","")`
# over a `<div style="display:none">` cleared the property, the state fell back
# to "no opinion", the markup attribute was copied through into the rewritten
# tag verbatim, and the element stayed invisible forever. That reveal is the
# standard way a server-rendered page un-hides content — and it is how
# google.com's search page shows its ENTIRE visible body, on a setTimeout, which
# is why hambrowse rendered that page as a blank window.
#
# ORACLE for PART G: chromium 147.0.7727.137,
#   --headless --dump-dom --virtual-time-budget=6000
# on the same captured fixture. Chromium ends with the div's style="" and one
# visible line: the sentence and two links this gate pins.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_rev"
D="$OUT/style_reveal"
mkdir -p "$D"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"

echo "[rev] compiling hambrowse_host for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$D/compile.log"; then
    echo "[rev] FAIL: host harness did not compile"; cat "$D/compile.log"; exit 1
fi

fail=0
pass() { echo "[rev] PASS $1"; }
bad()  { echo "[rev] FAIL $1"; fail=1; }

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
want_segs() { # count message
    got=$(sed -n '1p' "$D/out.txt" | grep -o 'segs=[0-9]*' | cut -d= -f2)
    if [ "$got" = "$1" ]; then pass "$2"; else bad "$2 (segs=$got, want $1)"; fi
}

# ---------------------------------------------------------------------------
# PART B — every way script can express "shown", and the one that must not.
# ---------------------------------------------------------------------------
cat > "$D/b1.html" <<'EOF'
<html><body>
<div id="a" style="display:none">AAA</div>
<div id="b" style="display:none">BBB</div>
<div id="c" style="display:none">CCC</div>
<div id="d" style="display:none">DDD</div>
<div id="e" style="display:none;color:#00ff00">EEE</div>
<script>
document.getElementById('a').setAttribute("style","");
document.getElementById('b').style.display = "";
document.getElementById('c').style.display = "block";
document.getElementById('d').style.display = "none";
document.getElementById('e').setAttribute("style","color:#00ff00");
</script>
</body></html>
EOF
render "$D/b1.html" 400
want_seg "AAA" "B1 setAttribute('style','') reveals a markup-hidden element"
want_seg "BBB" "B1 style.display='' reveals it"
want_seg "CCC" "B1 style.display='block' reveals it"
no_seg  "DDD" "B1 style.display='none' still HIDES it"
want_seg "EEE" "B1 replacing the whole declaration reveals it"
if grep -qE '^SEG .*#00ff00.*\|EEE\|' "$D/out.txt"; then
    pass "B1 the surviving colour declaration still applies"
else
    bad "B1 the revealed element lost its colour"; grep '^SEG' "$D/out.txt"
fi

# B2 — a reveal fired from a TIMER, after the element's markup was parsed. This
# is google.com's exact shape (the script precedes the element it reveals).
cat > "$D/b2.html" <<'EOF'
<html><body>
<script>setTimeout(function(){document.getElementById("late").setAttribute("style","")},2000);</script>
<div id="late" style="display:none">REVEALED</div>
</body></html>
EOF
render "$D/b2.html" 400
want_seg "REVEALED" "B2 a setTimeout reveal of a later element renders"

# B3 — NEGATIVE / neutrality: an untouched markup-hidden element stays hidden,
# and a page that never touches .style is unaffected.
cat > "$D/b3.html" <<'EOF'
<html><body><div style="display:none">SECRET</div><p>SHOWN</p></body></html>
EOF
render "$D/b3.html" 400
no_seg  "SECRET" "B3 an untouched display:none element stays hidden"
want_seg "SHOWN" "B3 its sibling still renders"

# ---------------------------------------------------------------------------
# PART G — the REAL captured google.com search page. Chromium renders exactly
# one visible line there (its whole body is the timer-revealed div); before this
# fix hambrowse rendered a BLANK WINDOW.
# ---------------------------------------------------------------------------
G="tests/fixtures/realsites/google_search.html"
if [ ! -f "$G" ]; then
    bad "G fixture missing: $G"
else
    render "$G" 1024
    want_segs 5 "G google.com/search renders Chromium's 5 segments (was 0)"
    want_seg "If you're having trouble accessing Google Search, please " \
             "G the sentence Chromium paints is present"
    want_seg "click here" "G its first link renders"
    want_seg "feedback"   "G its second link renders"
    if grep -q '^LAYOUT .*links=2' "$D/out.txt"; then
        pass "G both links are clickable (links=2)"
    else
        bad "G link count wrong"; sed -n '1p' "$D/out.txt"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[rev] RESULT: FAIL"
    exit 1
fi
echo "[rev] RESULT: PASS"
exit 0
