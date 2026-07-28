#!/usr/bin/env bash
# scripts/test_jsengine_typedarray_host.sh — FAST, QEMU-free gate for byte-backed
# typed arrays + ArrayBuffer in the native JS engine (lib/web/js/*), via the
# x86_64-linux host driver.
#
# MODEL: an ArrayBuffer owns a [off,off+len) slice of a shared byte pool; a typed
# array is a typed window (element kind + byte offset + element count) over an
# ArrayBuffer. Element reads/writes go through raw little-endian pointer loads/
# stores (host arch order). Integer stores apply ToInt32 + width masking;
# Uint8ClampedArray clamps to [0,255].
#
# Covered (round 7):
#   ArrayBuffer(len) + .byteLength;
#   Int8/Uint8/Uint8Clamped/Int16/Uint16/Int32/Uint32/Float32/Float64 arrays;
#   construction from length, from an array/iterable (copy), and from an
#     ArrayBuffer (shared view, with byteOffset/length);
#   indexed get/set; .length/.byteLength/.byteOffset/.buffer/.BYTES_PER_ELEMENT;
#   .set(src[,offset]); .subarray() (shared) / .slice() (copy); .fill();
#   iteration (for-of, spread, Array.from); static .of()/.from().
#
# Limits (documented): typed arrays do NOT carry the full Array method suite
#   (no join/map/filter/reduce/indexOf) — wrap with Array.from(ta) for those;
#   .values()/[Symbol.iterator]() return a plain-array snapshot (consumable by
#   for-of/spread/Array.from) rather than a spec ArrayIterator; no DataView, no
#   BigInt64/BigUint64 arrays, no endianness control.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-ta] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_ta_compile.log"; then
    echo "[js-ta] FAIL: host driver did not compile"; cat "$OUT/js_ta_compile.log"; exit 1
fi
echo "[js-ta] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_ta_case.js"
    local got
    got="$("$BIN" "$OUT/js_ta_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-ta] PASS $name"
    else
        echo "[js-ta] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- ArrayBuffer ----
assert ab_bytelen   'var b=new ArrayBuffer(16);console.log(b.byteLength)'                              '16'

# ---- construction from length ----
assert ta_len       'var a=new Uint8Array(4);console.log(a.length,a.byteLength,a.BYTES_PER_ELEMENT,a[0])' '4 4 1 0'
assert ta_i32_len   'var a=new Int32Array(3);console.log(a.length,a.byteLength)'                       '3 12'
assert ta_f64_len   'var a=new Float64Array(2);console.log(a.length,a.byteLength)'                     '2 16'

# ---- construction from an array (copy) + indexed get/set ----
assert ta_from_arr  'var a=new Int32Array([10,20,30]);console.log(a[0],a[1],a[2],a.length)'            '10 20 30 3'
assert ta_set_idx   'var a=new Uint8Array(3);a[0]=5;a[1]=9;console.log(a[0],a[1],a[2])'                '5 9 0'

# ---- integer wraparound + clamp coercion ----
assert ta_u8_wrap   'var a=new Uint8Array(1);a[0]=300;console.log(a[0])'                               '44'
assert ta_i8_wrap   'var a=new Int8Array(1);a[0]=200;console.log(a[0])'                                '-56'
assert ta_u16_wrap  'var a=new Uint16Array(1);a[0]=70000;console.log(a[0])'                            '4464'
assert ta_clamp_hi  'var a=new Uint8ClampedArray(1);a[0]=300;console.log(a[0])'                        '255'
assert ta_clamp_lo  'var a=new Uint8ClampedArray(1);a[0]=-10;console.log(a[0])'                        '0'

# ---- signed reads + floats ----
assert ta_i16_neg   'var a=new Int16Array([-5,-1000]);console.log(a[0],a[1])'                          '-5 -1000'
assert ta_u32_big   'var a=new Uint32Array([4000000000]);console.log(a[0])'                            '4000000000'
assert ta_f64_val   'var a=new Float64Array([1.5,2.25]);console.log(a[0]+a[1])'                        '3.75'
assert ta_f32_val   'var a=new Float32Array([0.5,0.25]);console.log(a[0]+a[1])'                        '0.75'

# ---- shared view over an ArrayBuffer ----
assert ta_shared    'var b=new ArrayBuffer(8);var v=new Int32Array(b);v[0]=1000;v[1]=2000;console.log(v.length,v[0],v[1])' '2 1000 2000'
assert ta_alias     'var b=new ArrayBuffer(4);var i=new Int32Array(b);var u=new Uint8Array(b);i[0]=1;console.log(u[0],u[1])' '1 0'
assert ta_view_off  'var b=new ArrayBuffer(8);var v=new Uint8Array(b,4);console.log(v.length,v.byteOffset)' '4 4'
assert ta_buffer    'var a=new Int32Array(3);console.log(a.buffer.byteLength)'                         '12'

# ---- set / subarray / slice / fill ----
assert ta_set_meth  'var a=new Int16Array(5);a.set([7,8,9],1);console.log(Array.from(a).join(","))'    '0,7,8,9,0'
assert ta_subarray  'var a=new Int16Array([1,2,3,4,5]);var s=a.subarray(1,4);console.log(Array.from(s).join(","))' '2,3,4'
assert ta_sub_share 'var a=new Int16Array([1,2,3,4,5]);var s=a.subarray(1,4);s[0]=99;console.log(a[1])' '99'
assert ta_slice     'var a=new Int16Array([1,2,3,4,5]);var s=a.slice(1,3);s[0]=-1;console.log(a[1],s[0])' '2 -1'
assert ta_fill      'var a=new Uint8Array(4);a.fill(7);console.log(Array.from(a).join(","))'           '7,7,7,7'
assert ta_fill_rng  'var a=new Uint8Array(5);a.fill(3,1,3);console.log(Array.from(a).join(","))'       '0,3,3,0,0'

# ---- iteration ----
assert ta_forof     'var s=0;for(const x of new Int32Array([1,2,3,4]))s+=x;console.log(s)'             '10'
assert ta_spread    'console.log([...new Uint8Array([1,2,3])].join("-"))'                              '1-2-3'
assert ta_arrfrom   'console.log(Array.from(new Int32Array([4,5,6])).join(","))'                       '4,5,6'
assert ta_values    'var r=[];for(const x of new Uint8Array([9,8]).values())r.push(x);console.log(r.join(","))' '9,8'

# ---- static of / from ----
assert ta_of        'console.log(Array.from(Uint8Array.of(1,2,3)).join(","),Uint8Array.of(1,2,3).length)' '1,2,3 3'
assert ta_static_from 'console.log(Array.from(Int32Array.from([9,8,7])).join(","))'                    '9,8,7'
assert ta_from_map  'console.log(Array.from(Int32Array.from([1,2,3],x=>x*10)).join(","))'              '10,20,30'
assert ta_from_iter 'function* g(){yield 2;yield 4}console.log(Array.from(Int32Array.from(g())).join(","))' '2,4'

if [ "$fail" -eq 0 ]; then
    echo "[js-ta] ALL PASS"
else
    echo "[js-ta] SOME FAILED"
fi
exit "$fail"
