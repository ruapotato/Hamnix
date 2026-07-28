#!/usr/bin/env bash
# scripts/test_hambrowse_cookie_host.sh — FAST, QEMU-free gate for document.cookie.
#
# WHY THIS GATE EXISTS. document.cookie was not implemented at all: reading it
# produced `undefined`. MediaWiki's startup module does
#     document.cookie.match(/.../)
# so BOTH en.wikipedia.org and wiki.archlinux.org died on the very first script
# with "TypeError: cannot read property 'match' of null or undefined" — measured
# by running unmodified snapshots of those pages through the engine. Per the IDL
# `cookie` is a DOMString: the empty string when the jar is empty, NEVER
# undefined. Assigning to it is a Set-Cookie-shaped WRITE, not a plain property
# store (the old behaviour stored the whole "b=2; path=/" string verbatim and
# handed it straight back).
#
# ORACLE. Every expected line below was produced BYTE-IDENTICALLY by
#     chromium --headless --dump-dom http://127.0.0.1:PORT/hambrowse_cookie.html
# served over http:, because chromium refuses cookies on file:// URLs. When a
# chromium binary AND python3 are present this gate re-derives the oracle live
# and diffs against it; otherwise it falls back to the recorded expectations.
# In particular line C ("b=hello; a=2") is Chromium's answer, not an assumption:
# overwriting a cookie moves it to the END of the serialisation.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FX="tests/fixtures/hambrowse_cookie.html"
mkdir -p "$OUT"
fail=0

echo "[hb-ck] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ck_compile.log"; then
    echo "[hb-ck] FAIL: host harness did not compile"; cat "$OUT/ck_compile.log"; exit 1
fi
echo "[hb-ck] PASS host harness compiled -> $BIN"

echo "[hb-ck] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ck_native.log"; then
    echo "[hb-ck] FAIL: native hambrowse did not compile"; cat "$OUT/ck_native.log"; exit 1
fi
echo "[hb-ck] PASS native hambrowse still compiles"

GOT="$OUT/ck_got.txt"
"$BIN" "$FX" 880 2>&1 | sed -n 's/^JSLOG //p' > "$GOT" \
    || { echo "[hb-ck] FAIL: render exited non-zero"; exit 1; }
cat "$GOT"

# ---- recorded chromium oracle (see header) ----------------------------------
EXP="$OUT/ck_exp.txt"
cat > "$EXP" <<'EOF'
A [] string
B [a=1; b=hello]
C [b=hello; a=2]
D [a=2]
E [a=2]
F [a=2; d=4]
G ["a=2","2"]
H [a=2; d=4; e=x y z]
I [a=2; d=4; e=x y z; f=1]
J [a=2; e=x y z; f=1]
EOF

# ---- when chromium is available, RE-DERIVE the oracle instead of trusting the
# recording. A drift here means chromium moved, and the gate says so loudly.
CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
if [ -n "$CHROMIUM" ]; then
    SRV="$(mktemp -d)"; cp "$FX" "$SRV/"
    PORT=$(( 18000 + (RANDOM % 2000) ))
    ( cd "$SRV" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
    SRVPID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        curl -s -o /dev/null "http://127.0.0.1:$PORT/$(basename "$FX")" && break
        sleep 0.5
    done
    LIVE="$OUT/ck_live.txt"
    timeout 60 "$CHROMIUM" --headless --no-sandbox --disable-gpu \
        --user-data-dir="$SRV/prof" --enable-logging=stderr \
        --dump-dom "http://127.0.0.1:$PORT/$(basename "$FX")" 2>&1 >/dev/null \
        | sed -n 's/.*CONSOLE:[0-9]*\] "\(.*\)", source.*/\1/p' > "$LIVE" || true
    kill "$SRVPID" 2>/dev/null || true
    rm -rf "$SRV"
    if [ -s "$LIVE" ]; then
        if diff -u "$EXP" "$LIVE" >"$OUT/ck_oracle.diff"; then
            echo "[hb-ck] PASS live chromium oracle matches the recorded expectations"
        else
            echo "[hb-ck] FAIL chromium DRIFTED from the recorded oracle:"
            cat "$OUT/ck_oracle.diff"; fail=1
        fi
        cp "$LIVE" "$EXP"
    else
        echo "[hb-ck] NOTE chromium produced no console output; using the recording"
    fi
else
    echo "[hb-ck] NOTE no chromium on this host; using the recorded oracle"
fi

if diff -u "$EXP" "$GOT" >"$OUT/ck.diff"; then
    echo "[hb-ck] PASS document.cookie matches chromium byte-for-byte (10 lines)"
else
    echo "[hb-ck] FAIL document.cookie differs from chromium:"
    cat "$OUT/ck.diff"; fail=1
fi

# The specific real-site failure this closes.
if grep -q '^A \[\] string$' "$GOT"; then
    echo "[hb-ck] PASS document.cookie is a STRING on an empty jar (MediaWiki's .match())"
else
    echo "[hb-ck] FAIL document.cookie is not a string on an empty jar"; fail=1
fi

if [ "$fail" = 0 ]; then echo "[hb-ck] RESULT: PASS"; else echo "[hb-ck] RESULT: FAIL"; fi
exit "$fail"
