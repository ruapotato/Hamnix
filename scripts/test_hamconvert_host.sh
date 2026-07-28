#!/usr/bin/env bash
# scripts/test_hamconvert_host.sh — FAST, QEMU-free host gate for HamConvert,
# the unit-converter desktop utility (lib/hamconvertcore.ad drawn through
# lib/hamscene.ad + rasterized by lib/hamui_host.ad). It drives the SAME core
# the native app ships with KNOWN conversions and asserts each is exact within a
# tight relative epsilon:
#   * 1 inch = 25.4 mm, 1 mile = 1.609344 km, 1 m = 100 cm,
#   * 100 C = 212 F = 373.15 K, 0 C = 32 F = 273.15 K, 212 F = 100 C,
#     and the affine round-trip 37 C -> F -> C == 37 C,
#   * 1 kg = 2.2046226 lb, 1 US gallon = 3.785411784 l, 1 hectare = 10000 m2,
#   * 1 hour = 3600 s, 1 GB = 1e9 bytes (DECIMAL SI, KB=1000), 60 mph = 96.56064
#     km/h.
# It also exercises the keyboard edge (digit entry + category paging) and
# renders the LENGTH, TEMPERATURE and DATA views to PNGs a human/agent can LOOK
# at, and confirms the NATIVE Hamnix build still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamconvert_host"
mkdir -p "$OUT"
fail=0

echo "[hamconvert-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamconvert_host.ad "$BIN" 2>"$OUT/hcv_compile.log"; then
    echo "[hamconvert-host] FAIL: host harness did not compile"; cat "$OUT/hcv_compile.log"; exit 1
fi
echo "[hamconvert-host] PASS host harness compiled -> $BIN"

echo "[hamconvert-host] compiling NATIVE hamconvert for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamconvert.ad "$OUT/hamconvert_native.elf" 2>"$OUT/hcv_native.log"; then
    echo "[hamconvert-host] FAIL: native hamconvert did not compile"; cat "$OUT/hcv_native.log"; exit 1
fi
echo "[hamconvert-host] PASS native hamconvert still compiles"

DUMP="$OUT/hcv_dump.txt"
if ! "$BIN" "$OUT/hcv_length.ppm" "$OUT/hcv_temp.ppm" "$OUT/hcv_data.ppm" >"$DUMP" 2>&1; then
    echo "[hamconvert-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in length temp data; do
    if python3 scripts/ppm_to_png.py "$OUT/hcv_$f.ppm" "$OUT/hcv_$f.png" 2>"$OUT/hcv_png.log"; then
        echo "[hamconvert-host] PASS rendered $OUT/hcv_$f.png"
    else
        echo "[hamconvert-host] FAIL png conversion ($f)"; cat "$OUT/hcv_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamconvert-host] PASS $2";
    else echo "[hamconvert-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- length -----------------------------------------------------------------
assert_grep '^CONV inch_mm OK 25.4$'        "1 inch = 25.4 mm"
assert_grep '^CONV mile_km OK 1.609344$'    "1 mile = 1.609344 km"
assert_grep '^CONV m_cm OK 100$'            "1 m = 100 cm"

# --- temperature (affine) ---------------------------------------------------
assert_grep '^CONV 100C_F OK 212$'          "100 C = 212 F"
assert_grep '^CONV 100C_K OK 373.15$'       "100 C = 373.15 K"
assert_grep '^CONV 0C_F OK 32$'             "0 C = 32 F"
assert_grep '^CONV 0C_K OK 273.15$'         "0 C = 273.15 K"
assert_grep '^CONV 212F_C OK 100$'          "212 F = 100 C"
assert_grep '^CONV 37C_roundtrip OK 37$'    "37 C -> F -> C round-trips to 37 C"

# --- mass / volume / area / time / data / speed -----------------------------
assert_grep '^CONV kg_lb OK 2.204623$'      "1 kg = 2.2046226 lb"
assert_grep '^CONV gal_l OK 3.785412$'      "1 US gallon = 3.785411784 l"
assert_grep '^CONV hectare_m2 OK 10000$'    "1 hectare = 10000 m2"
assert_grep '^CONV hour_s OK 3600$'         "1 hour = 3600 s"
assert_grep '^CONV GB_byte OK 1000000000$'  "1 GB = 1e9 bytes (KB=1000)"
assert_grep '^CONV 60mph_kmh OK 96.56064$'  "60 mph = 96.56064 km/h"

# make sure NOTHING came back BAD
if grep -Eq '^CONV .* BAD ' "$DUMP"; then
    echo "[hamconvert-host] FAIL some conversion was BAD:"; grep -E '^CONV .* BAD ' "$DUMP"; fail=1
else
    echo "[hamconvert-host] PASS no BAD conversions"
fi

# --- keyboard edge ----------------------------------------------------------
assert_grep '^INPUT_AFTER_KEYS 25$'         "typing '2' then '5' yields input 25"
assert_grep '^CAT_BEFORE 0$'                "category is Length before paging"
assert_grep '^CAT_AFTER 1$'                 "']' paged to the next category (Mass)"

# --- renders ----------------------------------------------------------------
assert_grep '^LENGTH_CAT 0$'                "length view active"
assert_grep '^LENGTH_RESULT 1$'             "12 inch = 1 foot in the length render"
assert_grep '^TEMP_RESULT 212$'             "100 C = 212 F in the temp render"
assert_grep '^DATA_RESULT 1000$'            "1 GB = 1000 MB in the data render"
assert_grep '^PIX_TITLEBAR '               "title-bar pixel sampled"

# --- the three PNGs really exist --------------------------------------------
for f in length temp data; do
    if [ -s "$OUT/hcv_$f.png" ]; then echo "[hamconvert-host] PASS $OUT/hcv_$f.png on disk";
    else echo "[hamconvert-host] FAIL $OUT/hcv_$f.png not written"; fail=1; fi
done

if [ "$fail" -ne 0 ]; then echo "[hamconvert-host] OVERALL FAIL"; exit 1; fi
echo "[hamconvert-host] OVERALL PASS"
