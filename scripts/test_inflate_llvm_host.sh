#!/usr/bin/env bash
# scripts/test_inflate_llvm_host.sh — FAST, QEMU-free host gate proving the
# gzip inflater decodes REAL package tarballs correctly under BOTH compiler
# lanes: the native SSA backend AND the LLVM backend (which, since
# scripts/build_user.sh made ADDER_LLVM_DEFAULT=1 the default, is the lane that
# actually builds the shipped /bin/hpm).
#
# THE SHIP-BLOCKER THIS EXISTS TO CATCH
# =====================================
# On 2026-07-27 a fresh install off the shipped hamnix-installer.img died with
#
#     hpm: PKGINFO not found in tarball
#     [install] FAIL: hpm base package install non-zero
#
# The tarball was fine. `inflate_feed` had returned SUCCESS having decoded ZERO
# bytes, so hpm walked an empty buffer. Cause: lib/zlib/inflate.ad's
# `_dyn_header_decode` declares `sym: uint8` in one branch and `sym: uint32` in
# another. Adder names are FUNCTION-scoped, so both interned to one name id and
# SHARED one stack slot — and the SSA memory-local classifier froze that slot at
# the FIRST declaration's size, emitting `alloca [1 x i8]` for a local whose
# address is handed to `_huff_decode(..., &sym)` as a `Ptr[uint32]`. The
# callee's 4-byte store ran off the end of the 1-byte slot and wedged the
# dynamic-Huffman header decode. Fixed in adder/compiler/ssa.ad
# (ssa_widen_mem_local).
#
# EVERY gate that exercised the inflater compiled it with the SEED / native
# backend, so all of them stayed green while the shipped LLVM-built binary was
# broken. That gap is what this gate closes: it runs the SAME source through
# BOTH lanes and byte-compares the output against the system gunzip.
#
# WHY test_tar_gzip.sh DOES NOT COVER THIS (measured, not assumed). That gate
# DOES rebuild userland through the LLVM lane and DOES run the shipped ELF64
# /bin/gunzip against a real dynamic-Huffman host .gz. It was re-run on
# 2026-07-27 against a compiler with the ssa.ad fix REVERTED and still reported
# PASS on all nine of its checks. The same defect, in the same function, in a
# differently-linked binary, was benign: an undersized alloca is a FRAME-LAYOUT
# hazard, so whether the 3-byte overrun lands on padding or on a live neighbour
# depends on the surrounding allocation set and the optimiser. `hpm` lost that
# coin flip; `gunzip` won it. A gate whose verdict depends on a coin flip is
# not a guard.
#
# This gate is built to be layout-INDEPENDENT instead: it byte-compares the
# FULL decompressed output (not a substring of a serial log) against the system
# gunzip, over multi-file tarballs of mixed text+binary content that force the
# full 19-symbol code-length alphabet incl. the 16/17/18 repeat codes, at BOTH
# -O0 and -O2.
#
# Revert adder/compiler/ssa.ad's ssa_widen_mem_local and the LLVM lane goes red
# here in about two seconds.
#
# Env:
#   BENCH_CLANG   clang binary (default: clang-19, then clang)
#   ADDER_HOST_AC LLVM-capable host_ac.elf (default build/cutover/host_ac.elf)

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[inflate_llvm_host]"
fail=0
passed() { echo "$TAG PASS $*"; }
failed() { echo "$TAG FAIL $*" >&2; fail=1; }

OUT="$(mktemp -d --tmpdir hamnix-inflate-llvm.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    for c in clang-19 clang; do command -v "$c" >/dev/null 2>&1 && CLANG="$c" && break; done
fi

# --- fixtures: REAL gzip streams, not synthetic toys ------------------
# Python's tarfile w:gz (what scripts/build_packages.py uses for every
# repo tarball) emits FNAME-flagged gzip with dynamic-Huffman blocks —
# precisely the shape that broke. Prefer the genuine article; fall back
# to generating equivalent ones so the gate runs on a bare checkout.
FIXTURES=()
for f in build/packages/main/packages/hamnix-init-1.0.0.tar.gz \
         build/packages/main/packages/hamnix-coreutils-1.0.0.tar.gz \
         build/packages/main/packages/hamnix-hamsh-1.0.0.tar.gz; do
    [ -f "$f" ] && FIXTURES+=("$f")
done
if [ "${#FIXTURES[@]}" -eq 0 ]; then
    echo "$TAG no built repo tarballs — synthesizing equivalent fixtures"
    python3 - "$OUT" <<'PY' || { echo "$TAG SKIP: cannot synthesize fixture" >&2; exit 0; }
import sys, os, tarfile, random
out = sys.argv[1]
root = os.path.join(out, "fixpkg-1.0.0")
os.makedirs(os.path.join(root, "files/etc"), exist_ok=True)
open(os.path.join(root, "PKGINFO"), "w").write(
    "name: fixpkg\nversion: 1.0.0\narch: any\ntarget: #hamnix-system\n")
random.seed(1234)
# Mixed English-ish text + binary so the deflate stream uses DYNAMIC
# Huffman with a full 19-symbol code-length alphabet (incl. 16/17/18
# repeat codes) — the exact decode path that broke.
words = ["hamnix", "package", "install", "kernel", "namespace", "plan9",
         "inflate", "deflate", "huffman", "window", "symbol", "length"]
for i in range(24):
    body = " ".join(random.choice(words) for _ in range(400)) + "\n"
    body += bytes(random.randrange(256) for _ in range(512)).decode("latin1")
    open(os.path.join(root, "files/etc", "f%02d" % i), "w").write(body)
with tarfile.open(os.path.join(out, "fixture.tar.gz"), "w:gz",
                  format=tarfile.GNU_FORMAT, compresslevel=9) as t:
    t.add(root, arcname="fixpkg-1.0.0")
PY
    FIXTURES+=("$OUT/fixture.tar.gz")
fi
echo "$TAG fixtures: ${FIXTURES[*]}"

# --- lane 1: native SSA backend (the seed's x86_64-linux host target) --
NAT="$OUT/inflate_host.native"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/inflate_host.ad "$NAT" >"$OUT/native.log" 2>&1; then
    failed "native lane did not compile user/inflate_host.ad"
    tail -20 "$OUT/native.log" >&2
    echo "$TAG RESULT: FAIL" >&2
    exit 1
fi
passed "native lane compiled user/inflate_host.ad"

# --- lane 2: LLVM backend -> clang -> host binary ---------------------
# Same .ll the shipped Hamnix binaries are built from
# (scripts/adder_cc_llvm_native64.sh step 1); only the runtime differs — a
# five-function libc shim instead of user/runtime.S — so the code under test
# is byte-for-byte the code that ships.
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
llvm_ok=1
if [ -z "$CLANG" ]; then
    echo "$TAG SKIP LLVM lane: no clang found (set BENCH_CLANG)" >&2
    llvm_ok=0
elif [ ! -x "$HOST_AC" ]; then
    echo "$TAG SKIP LLVM lane: $HOST_AC absent (run scripts/_adder_cc.sh adder_cc_bootstrap)" >&2
    llvm_ok=0
fi

if [ "$llvm_ok" = "1" ]; then
    cat > "$OUT/shim.c" <<'EOF'
#include <fcntl.h>
#include <unistd.h>
long sys_open(const char *p)        { return open(p, O_RDONLY); }
long sys_open_write(const char *p)  { return open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644); }
long sys_read(long fd, void *b, unsigned long n)        { return read((int)fd, b, n); }
long sys_write(long fd, const void *b, unsigned long n) { return write((int)fd, b, n); }
long sys_close(long fd)             { return close((int)fd); }
EOF
    if ! "$HOST_AC" --backend=llvm user/inflate_host.ad "$OUT/inflate_host.ll" \
            >"$OUT/llvm_emit.log" 2>&1; then
        failed "LLVM backend could not emit IR for user/inflate_host.ad"
        tail -20 "$OUT/llvm_emit.log" >&2
        llvm_ok=0
    else
        passed "LLVM backend emitted IR for user/inflate_host.ad"
    fi
fi

# The undersized-slot bug is a frame-layout hazard: it can hide at one -O
# level and corrupt at another. Test BOTH.
LLVM_BINS=()
if [ "$llvm_ok" = "1" ]; then
    for opt in O0 O2; do
        if "$CLANG" "-$opt" -o "$OUT/inflate_host.$opt" \
                "$OUT/inflate_host.ll" "$OUT/shim.c" >"$OUT/clang.$opt.log" 2>&1; then
            LLVM_BINS+=("$opt:$OUT/inflate_host.$opt")
            passed "LLVM lane linked at -$opt"
        else
            failed "LLVM lane did not link at -$opt"
            tail -20 "$OUT/clang.$opt.log" >&2
        fi
    done
fi

# --- the actual proof: byte-compare both lanes against system gunzip ---
check_lane() {
    local label="$1" bin="$2" gz="$3" base
    base="$(basename "$gz")"
    local got="$OUT/$label.$base.out" want="$OUT/want.$base"
    python3 -c "import gzip,sys; open(sys.argv[2],'wb').write(gzip.open(sys.argv[1],'rb').read())" \
        "$gz" "$want" || { failed "$label: reference gunzip failed on $base"; return; }
    if ! "$bin" "$gz" "$got" 2>"$OUT/$label.$base.err"; then
        failed "$label: inflate_host returned non-zero on $base — $(tr -d '\n' < "$OUT/$label.$base.err")"
        return
    fi
    local gsz wsz
    gsz=$(stat -c %s "$got" 2>/dev/null || echo -1)
    wsz=$(stat -c %s "$want")
    if [ "$gsz" != "$wsz" ]; then
        failed "$label: $base inflated to $gsz bytes, expected $wsz"
        return
    fi
    if ! cmp -s "$got" "$want"; then
        failed "$label: $base inflated bytes DIFFER from system gunzip"
        return
    fi
    passed "$label: $base -> $wsz bytes, byte-identical to system gunzip"
}

for gz in "${FIXTURES[@]}"; do
    check_lane "native" "$NAT" "$gz"
    for entry in "${LLVM_BINS[@]}"; do
        check_lane "llvm-${entry%%:*}" "${entry#*:}" "$gz"
    done
done

if [ "$fail" -eq 0 ]; then
    echo "$TAG RESULT: PASS"
    exit 0
fi
echo "$TAG RESULT: FAIL" >&2
exit 1
