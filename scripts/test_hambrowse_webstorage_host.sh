#!/usr/bin/env bash
# scripts/test_hambrowse_webstorage_host.sh — FAST, QEMU-free gate for two
# self-contained browser JS globals real sites/SPAs depend on: WEB STORAGE
# (localStorage / sessionStorage as Storage objects) and the HISTORY API
# (history.pushState / replaceState / state / length / back / forward / go +
# the popstate event) together with Location component parsing (protocol / host
# / hostname / port / pathname / search / hash / origin) and location.hash /
# .href reactive setters (+ hashchange).
#
# The page's <script> runs through the SAME parse+DOM+JS engine the native
# browser uses (lib/web/dom/canvas.ad + lib/web/js/*), and its console.log
# lines become JSLOG lines the gate matches with an exact-output oracle.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_webstorage.html"
mkdir -p "$OUT"

echo "[hb-ws] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ws_compile.log"; then
    echo "[hb-ws] FAIL: host harness did not compile"; cat "$OUT/ws_compile.log"; exit 1
fi
echo "[hb-ws] PASS host harness compiled -> $BIN"

echo "[hb-ws] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ws_native.log"; then
    echo "[hb-ws] FAIL: native hambrowse did not compile"; cat "$OUT/ws_native.log"; exit 1
fi
echo "[hb-ws] PASS native hambrowse still compiles"

fail=0
D0="$OUT/ws_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-ws] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ws] PASS $2"
    else
        echo "[hb-ws] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ws] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-ws] PASS $2"
    fi
}

# ---- Web Storage: Storage semantics ----------------------------------------
assert_grep '^JSLOG coerce 5 string$'  "setItem stringifies its value; getItem round-trips a 'string'"
assert_grep '^JSLOG absent true$'      "getItem of an absent key === null"
assert_grep '^JSLOG removed true$'     "removeItem drops a key (getItem back to null)"
assert_grep '^JSLOG len 2 key x$'      "length counts items; key(0) is the first-inserted key"
assert_grep '^JSLOG cleared 0$'        "clear() empties the store (length 0)"
assert_grep '^JSLOG indep LS$'         "localStorage and sessionStorage are independent stores"

# ---- History API + popstate ------------------------------------------------
assert_grep '^JSLOG hist0 1 true$'     "initial history: length 1, state null"
assert_grep '^JSLOG push 2 1$'         "pushState grows length to 2 + sets history.state"
assert_grep '^JSLOG push2 3 2$'        "a second pushState grows length to 3"
assert_grep '^JSLOG repl 3 9$'         "replaceState updates state WITHOUT growing length"
assert_grep '^JSLOG pop 1$'            "back() fires popstate with event.state of the prior entry"
assert_grep '^JSLOG back 3 1$'         "back() restores the prior history.state (length unchanged)"
assert_grep '^JSLOG pop 9$'            "forward() fires popstate with the re-entered state"
assert_grep '^JSLOG fwd 3 9$'          "forward() restores the replaced state"
assert_grep '^JSLOG pop none$'         "go(-2) fires popstate with a null state (initial entry)"
assert_grep '^JSLOG go 3 true$'        "go(-2) walks the index back to the null-state entry"

# ---- Location component parsing --------------------------------------------
assert_grep '^JSLOG loc https: example.com:8080 example.com 8080$' \
    "location protocol/host/hostname/port parsed (userinfo stripped)"
assert_grep '^JSLOG loc2 /path/to \?q=1&x=2 #frag$' \
    "location pathname/search/hash parsed"
assert_grep '^JSLOG loc3 https://example.com:8080$' \
    "location.origin = protocol + // + host"
assert_grep '^JSLOG root / http://a.com$' \
    "a bare authority yields pathname '/' and a real origin"
assert_grep '^JSLOG href /z \?k=v$' \
    "location.href = ... re-parses the components"

# hashchange fires BEFORE the following log line (synchronous member-set hook).
assert_grep '^JSLOG hc$'               "location.hash = ... fires a hashchange window event"
assert_grep '^JSLOG hash #new$'        "location.hash = ... updates the fragment"

# No uncaught error anywhere in the run.
assert_nogrep '^JSERR'                 "no uncaught JS error across the storage/history/location script"
assert_nogrep 'Uncaught'               "no 'Uncaught' TypeError from a missing API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-ws] RESULT: FAIL"; exit 1
fi
echo "[hb-ws] RESULT: PASS"
