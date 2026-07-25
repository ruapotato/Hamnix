#!/usr/bin/env bash
# scripts/test_hambrowse_bindata_host.sh — FAST, QEMU-free gate for the BINARY
# DATA builtins: the Array-shaped half of TypedArray.prototype, DataView, and
# Intl.Collator (implemented in lib/web/js/builtins/r8_ta.ad).
#
# WHY. lib/web/js/builtins/r7.ad gave every TypedArray a real byte-backed buffer
# plus set/subarray/slice/fill/values — but none of the Array-shaped methods, so
# `a.join(",")`, `a.map(f)`, `a.forEach(f)` etc. all threw "is not a function".
# scripts/probe_js_hard.sh recorded that as FOUR separate failures
# (typedarray_map / typedarray_set / uint8_subarray / arraybuffer); three of them
# were in fact the same missing `.join()`, and the fourth was a missing DataView.
# Binary-data glue is everywhere on the real web — canvas ImageData, wasm,
# WebCrypto, image/audio decoders, and every binary protocol header (which is
# exactly what DataView exists to read, big-endian first).
#
# ORACLE. Every expected value below came from node (V8 == Chrome's engine):
#     node -e '<the same expressions as tests/fixtures/hambrowse_bindata.html>'
# Do NOT re-derive them from hambrowse's own output — that would make this gate
# self-confirming. On the pre-fix engine the TypedArray assertions throw and the
# DataView ones die with "DataView is not defined".
#
# NO QEMU — runs the SAME lib/web engine the native browser uses, through the
# x86_64-linux host harness (user/hambrowse_host.ad).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_bindata.html"
mkdir -p "$OUT"

echo "[hb-bin] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/bindata_compile.log"; then
    echo "[hb-bin] FAIL: host harness did not compile"; cat "$OUT/bindata_compile.log"; exit 1
fi
echo "[hb-bin] PASS host harness compiled -> $BIN"

echo "[hb-bin] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native_bin.elf" 2>"$OUT/bindata_native.log"; then
    echo "[hb-bin] FAIL: native hambrowse did not compile"; cat "$OUT/bindata_native.log"; exit 1
fi
echo "[hb-bin] PASS native hambrowse still compiles"

D0="$OUT/bindata_run.txt"
if ! "$BIN" "$FIX" 880 >"$D0" 2>&1; then
    echo "[hb-bin] FAIL: render exited non-zero"; cat "$D0"; exit 1
fi

fail=0
grep -E 'JSLOG|JSERR' "$D0" || true

if grep -q '^JSERR' "$D0"; then
    echo "[hb-bin] FAIL: uncaught JS error"; grep '^JSERR' "$D0"; fail=1
fi

want() {   # want <JSLOG line body> <description>
    if grep -Fxq "JSLOG $1" "$D0"; then
        echo "[hb-bin] PASS $2 ($1)"
    else
        echo "[hb-bin] FAIL $2 — want 'JSLOG $1', got '$(grep -E "^JSLOG ${1%% *} " "$D0" | head -1)'"
        fail=1
    fi
}

# ---- TypedArray.prototype: the Array-shaped methods (all V8 values) --------
want "JOIN 1,2"          "TypedArray.prototype.join"
want "SET 0,9,8,0"       "set(src, offset) then join (was: join is not a function)"
want "SUB 2,3"           "subarray(1,3) shares the buffer, then join"
want "MAP 2,4,6"         "map(fn) over an Int32Array"
want "MAPTYPE true"      "map returns a TypedArray of the SAME type (species)"
want "FILTER 2,4"        "filter(fn)"
want "FILTERTYPE true"   "filter returns a TypedArray of the same type (species)"
want "REDUCE 6"          "reduce(fn, init)"
want "FOREACH 6"         "forEach(fn) visits every element"
want "INDEXOF 1"         "indexOf(value)"
want "INCLUDES true"     "includes(value)"
want "FIND 6"            "find(predicate)"
want "AT 7"              "at(-1) indexes from the end"
want "REV 3,2,1"         "reverse() mutates in place and returns the receiver"
want "SORT 1,2,3"        "sort() mutates in place and returns the receiver"

# ---- DataView -------------------------------------------------------------
want "I32 258"           "setInt32/getInt32 round-trip"
want "BE 18,52"          "DataView is BIG-endian by default (0x1234 -> 0x12,0x34)"
want "LE 52,18"          "littleEndian=true flips the byte order (0x34,0x12)"
want "F64 1.5"           "setFloat64/getFloat64 round-trip"
want "I8 -5"             "getInt8 sign-extends"
want "DVLEN 8 4 2"       "byteLength, and a sub-range view's byteLength/byteOffset"

# ---- Intl.Collator --------------------------------------------------------
want "COLLTYPE function" "Intl.Collator exists"
want "COLLSORT a,b,c"    "new Intl.Collator().compare works as a sort comparator"

if [ "$fail" -eq 0 ]; then
    echo "[hb-bin] RESULT: PASS"
    exit 0
fi
echo "[hb-bin] RESULT: FAIL"
exit 1
