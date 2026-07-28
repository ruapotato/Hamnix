#!/usr/bin/env bash
# scripts/test_hambrowse_elbudget_host.sh — the PER-ELEMENT RESOURCE BUDGET gate.
#
# WHY THIS GATE EXISTS. Every other DOM gate in this tree works on a handful of
# elements, so it can never see the failure that actually kills real pages:
# registering a DOM element used to allocate ~46 JS objects (32 of them fresh
# native-function objects for methods that only ever read `this`), plus a fresh
# 3-method CSSStyleDeclaration and a fresh 6-method DOMTokenList. With
# MAX_OBJ = 40000 that meant ONE `document.getElementsByTagName("*")` on a page
# of roughly 870+ elements exhausted the whole object pool — "object pool
# exhausted", JSERR, and every remaining script on the page dead. And with the
# element registry capped at 1024, a bigger page silently handed back UNDEFINED
# entries from getElementsByTagName, so the page's own
# `for (...) a[i].getAttribute(...)` loop threw.
#
# Both were MEASURED on unmodified snapshots of real sites:
#   en.wikipedia.org/wiki/Web_browser   4018 elements
#   wiki.archlinux.org/title/Systemd    2151 elements
# — neither could complete a single "*" query.
#
# THE FIXTURE is 1505 elements: comfortably past the old pool ceiling and past
# the old 1024-element registry cap, so a regression on EITHER axis turns this
# gate red. It asserts the FULL element census, that no entry is undefined, that
# the methods are shared (`a.appendChild === b.appendChild` — Chromium's answer,
# because they live on the prototype) and that ~5000 more objects can still be
# allocated afterwards.
#
# ORACLE: `chromium --headless --dump-dom` on the SAME fixture, byte for byte.
# Re-derived live when chromium is present, otherwise the recorded run below.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FX="tests/fixtures/hambrowse_elbudget.html"
mkdir -p "$OUT"
fail=0

echo "[hb-eb] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/eb_compile.log"; then
    echo "[hb-eb] FAIL: host harness did not compile"; cat "$OUT/eb_compile.log"; exit 1
fi
echo "[hb-eb] PASS host harness compiled -> $BIN"

echo "[hb-eb] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/eb_native.log"; then
    echo "[hb-eb] FAIL: native hambrowse did not compile"; cat "$OUT/eb_native.log"; exit 1
fi
echo "[hb-eb] PASS native hambrowse still compiles"

RAW="$OUT/eb_raw.txt"
"$BIN" "$FX" 880 >"$RAW" 2>&1 || { echo "[hb-eb] FAIL: render exited non-zero"; exit 1; }
GOT="$OUT/eb_got.txt"
sed -n 's/^JSLOG //p' "$RAW" > "$GOT"
cat "$GOT"

# The failure mode itself, asserted directly: no pool may run dry on this page.
if grep -qE 'object pool exhausted|string pool exhausted|value pool exhausted|property pool exhausted' "$RAW"; then
    echo "[hb-eb] FAIL a JS pool was exhausted on a 1505-element page:"
    grep -E 'pool exhausted' "$RAW" | sort -u; fail=1
else
    echo "[hb-eb] PASS no JS pool exhausted registering 1505 elements + 5000 objects"
fi
if grep -q '^JSERR' "$RAW"; then
    echo "[hb-eb] FAIL the page reported a fatal JS error:"; grep '^JSERR' "$RAW"; fail=1
else
    echo "[hb-eb] PASS no fatal JS error"
fi

EXP="$OUT/eb_exp.txt"
cat > "$EXP" <<'EOF'
ALL=1505
UNDEF=0
DIV=500
A=500
SPAN=500
QSA=500
SHARED=true
OWNKEYS=true
CALLABLE=true r0
ALLOC=5000 4999
EOF

CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
if [ -n "$CHROMIUM" ]; then
    LIVE="$OUT/eb_live.txt"
    timeout 60 "$CHROMIUM" --headless --no-sandbox --disable-gpu \
        --enable-logging=stderr --dump-dom "file://$PWD/$FX" 2>&1 >/dev/null \
        | sed -n 's/.*CONSOLE:[0-9]*\] "\(.*\)", source.*/\1/p' > "$LIVE" || true
    if [ -s "$LIVE" ]; then
        if diff -u "$EXP" "$LIVE" >"$OUT/eb_oracle.diff"; then
            echo "[hb-eb] PASS live chromium oracle matches the recorded expectations"
        else
            echo "[hb-eb] FAIL chromium DRIFTED from the recorded oracle:"
            cat "$OUT/eb_oracle.diff"; fail=1
        fi
        cp "$LIVE" "$EXP"
    else
        echo "[hb-eb] NOTE chromium produced no console output; using the recording"
    fi
else
    echo "[hb-eb] NOTE no chromium on this host; using the recorded oracle"
fi

if diff -u "$EXP" "$GOT" >"$OUT/eb.diff"; then
    echo "[hb-eb] PASS 1505-element census matches chromium byte-for-byte (10 lines)"
else
    echo "[hb-eb] FAIL census differs from chromium:"; cat "$OUT/eb.diff"; fail=1
fi

if [ "$fail" = 0 ]; then echo "[hb-eb] RESULT: PASS"; else echo "[hb-eb] RESULT: FAIL"; fi
exit "$fail"
