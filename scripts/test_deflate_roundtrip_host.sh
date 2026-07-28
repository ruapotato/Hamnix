#!/usr/bin/env bash
# scripts/test_deflate_roundtrip_host.sh — FAST, QEMU-free host gate for the
# native DEFLATE *encoder* (lib/zlib/deflate.ad) and its gzip framing.
#
# It compiles user/deflate_host.ad (the host driver for the SAME fixed-Huffman
# + LZ77 encoder shipped by native `gzip` and `tar -czf`) for the x86_64-linux
# Adder target, gzip-compresses several fixtures, then decompresses each with
# the REAL system `gunzip` AND python's `gzip` module and byte-compares against
# the original. That proves Hamnix-produced gzip is INTEROPERABLE with Linux —
# the whole point of the feature — in milliseconds, no QEMU. It also confirms
# the NATIVE gzip/gunzip/tar binaries still compile from the same lib, and that
# a repetitive fixture actually SHRINKS (real compression, not a stored wrapper).
#
# Built with the frozen Python seed compiler (compiles 100% of the tree).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/deflate_host"
mkdir -p "$OUT"
fail=0

echo "[deflate-host] compiling encoder host driver for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/deflate_host.ad "$BIN" 2>"$OUT/deflate_compile.log"; then
    echo "[deflate-host] FAIL: host driver did not compile"; cat "$OUT/deflate_compile.log"; exit 1
fi
echo "[deflate-host] PASS host driver compiled -> $BIN"

# The native binaries must still compile from the shared lib (compile-clean).
for tgt in gzip gunzip tar; do
    if python3 -m compiler.adder compile --target=x86_64-adder-user \
            "user/$tgt.ad" -o "$OUT/${tgt}_native.elf" 2>"$OUT/${tgt}_native.log"; then
        echo "[deflate-host] PASS native $tgt compiles"
    else
        echo "[deflate-host] FAIL native $tgt did not compile"; cat "$OUT/${tgt}_native.log"; fail=1
    fi
done

# --- fixtures ------------------------------------------------------------
python3 - "$OUT" <<'PY'
import os, sys, random
out = sys.argv[1]
random.seed(1)
# repetitive (LZ77-friendly)
open(f"{out}/rt_repeat.bin","wb").write(b"The quick brown fox jumps over the lazy dog.\n"*200)
# real source file (mixed content)
open(f"{out}/rt_source.bin","wb").write(open("lib/zlib/deflate.ad","rb").read())
# empty
open(f"{out}/rt_empty.bin","wb").write(b"")
# tiny
open(f"{out}/rt_tiny.bin","wb").write(b"abcdefghij")
# multi-block (>64 KiB, crosses the 32 KiB block boundary twice)
lines=[("line %d: the quick brown fox %d\n"%(i,random.randint(0,50))).encode() for i in range(3000)]
open(f"{out}/rt_multi.bin","wb").write(b"".join(lines))
PY

roundtrip() {
    local name="$1" f="$OUT/$1.bin" gz="$OUT/$1.gz" o="$OUT/$1.out"
    if ! "$BIN" "$f" "$gz"; then
        echo "[deflate-host] FAIL $name: encoder returned non-zero"; fail=1; return
    fi
    # (1) system gunzip must accept our stream and reproduce the input.
    if gunzip -c "$gz" > "$o" 2>/dev/null && cmp -s "$f" "$o"; then
        local orig comp; orig=$(wc -c < "$f"); comp=$(wc -c < "$gz")
        echo "[deflate-host] PASS $name: system gunzip round-trip ($orig -> $comp bytes)"
    else
        echo "[deflate-host] FAIL $name: system gunzip mismatch"; fail=1; return
    fi
    # (2) python gzip module cross-check (independent inflater).
    if python3 -c "import gzip,sys; sys.exit(0 if gzip.open('$gz','rb').read()==open('$f','rb').read() else 1)"; then
        echo "[deflate-host] PASS $name: python gzip cross-check"
    else
        echo "[deflate-host] FAIL $name: python gzip mismatch"; fail=1
    fi
}

for fx in rt_repeat rt_source rt_empty rt_tiny rt_multi; do
    roundtrip "$fx"
done

# --- real-compression assertion (not just a stored wrapper) --------------
orig=$(wc -c < "$OUT/rt_repeat.bin"); comp=$(wc -c < "$OUT/rt_repeat.gz")
if [ "$comp" -lt $(( orig / 10 )) ]; then
    echo "[deflate-host] PASS real compression: repetitive $orig -> $comp bytes (>10x)"
else
    echo "[deflate-host] FAIL weak compression: $orig -> $comp (LZ77 not engaging?)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[deflate-host] FAIL"; exit 1
fi
echo "[deflate-host] PASS"
exit 0
