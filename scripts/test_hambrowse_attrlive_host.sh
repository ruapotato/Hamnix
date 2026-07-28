#!/usr/bin/env bash
# scripts/test_hambrowse_attrlive_host.sh — FAST, QEMU-free gate for LIVE
# CONTENT ATTRIBUTES: getAttribute/hasAttribute must report what script last
# wrote, not what the start tag said at parse time.
#
# WHY THIS EXISTS
# ===============
# getAttribute() read the START TAG out of the source — right for an untouched
# element and wrong the moment script writes one. MEASURED against chromium
# --headless on this fixture: after `a.setAttribute('href','b.html')` chromium's
# getAttribute answers "b.html"; ours answered the source's "a.html". The JS
# property could not serve as the store, because href/src/alt/title are
# REFLECTED onto every element at registration (and href/src absolutised), so
# "the object has an own href" says nothing about whether script wrote it.
#
# ORACLE (chromium --headless --dump-dom on this fixture, 2026-07-28):
#   get.before a.html | get.after b.html | has.after true | get.new v
#   get.removed null  | has.removed false | img.get q.png
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_attrlive.html"
mkdir -p "$OUT"

echo "[hb-attrlive] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/attrlive_compile.log"; then
    echo "[hb-attrlive] FAIL: host harness did not compile"
    cat "$OUT/attrlive_compile.log"; exit 1
fi
echo "[hb-attrlive] PASS host harness compiled -> $BIN"

echo "[hb-attrlive] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/attrlive_native.elf" 2>"$OUT/attrlive_native.log"; then
    echo "[hb-attrlive] FAIL: native hambrowse did not compile"
    cat "$OUT/attrlive_native.log"; exit 1
fi
echo "[hb-attrlive] PASS native hambrowse still compiles"

fail=0
D0="$OUT/attrlive_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-attrlive] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG AT|JSERR' "$D0" || true

assert_line() {
    if grep -Fxq -- "JSLOG $1" "$D0"; then
        echo "[hb-attrlive] PASS $2"
    else
        echo "[hb-attrlive] FAIL $2 (missing exact line: JSLOG $1)"; fail=1
    fi
}

assert_line 'AT get.before :: a.html'  "getAttribute reads the source attribute before any write"
assert_line 'AT get.after :: b.html'   "setAttribute is VISIBLE to getAttribute (was the stale source value)"
assert_line 'AT has.after :: true'     "hasAttribute agrees after the write"
assert_line 'AT get.new :: v'          "an attribute the source never declared round-trips"
assert_line 'AT get.removed :: null'   "removeAttribute makes getAttribute answer null, not the source value"
assert_line 'AT has.removed :: false'  "hasAttribute agrees after the removal"
assert_line 'AT img.get :: q.png'      "a URL-valued attribute round-trips unabsolutised through getAttribute"

if grep -q '^JSERR' "$D0"; then
    echo "[hb-attrlive] FAIL uncaught JS error"; grep '^JSERR' "$D0"; fail=1
else
    echo "[hb-attrlive] PASS no uncaught JS error"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-attrlive] RESULT: FAIL"; exit 1
fi
echo "[hb-attrlive] RESULT: PASS — content attributes track script writes, matching chromium"
