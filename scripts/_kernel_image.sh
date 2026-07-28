#!/usr/bin/env bash
# scripts/_kernel_image.sh — content-addressed cache for the bare-metal
# kernel ELF, shared by every on-device gate in the CI battery.
#
# WHY THIS EXISTS
# ===============
# 178 of the 185 QEMU gates in scripts/ci_battery_manifest.txt contain the
# same two steps:
#
#     INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py
#     python3 -m compiler.adder compile --target=x86_64-bare-metal \
#         init/main.ad -o "$ELF"
#
# and there are only a handful of distinct images behind them — mostly
# init=build/user/init.elf and init=build/user/hamsh.elf. `compiler.adder
# compile` of init/main.ad (355 modules) is single-threaded and NOT
# incremental: 101 s on this idle 12-core KVM host (measured 2026-07-28),
# and a GitHub runner's slower single core costs ~2-2.5x that. 178 gates x
# 101 s = 5.0 h of pure recompilation per battery run; round-robin-sharded
# 16 ways that is ~11 kernel compiles per shard, i.e. ~46 min of the 50-min
# shard budget spent producing a kernel that is byte-identical across all
# 11 of them. That is why every shard of the 2026-07-27 run was cancelled
# at 50m1x having completed almost no boots.
#
# This helper collapses those N compiles into one per distinct
# (sources, initramfs) pair.
#
# HONESTY — WHY THIS IS NOT A SOFT GREEN
# ======================================
# This is a CACHE, not a skip. The key is a SHA-256 over:
#   * the CONTENT of every tracked file and every untracked-but-not-ignored
#     file in the tree (kernel sources, the Adder compiler, build scripts),
#     excluding only the generated fs/initramfs_blob.S; and
#   * the CONTENT of the generated cpio payload fs/initramfs_blob.S.bin,
#     which is what actually varies between gates (a different /init, an
#     extra /bin/<fixture>).
# Any edit to any input changes the key and forces a real compile, so a hit
# returns an ELF byte-identical to the one a from-scratch compile would have
# produced. It cannot present a stale artifact as fresh — the failure mode
# scripts/test_artifact_freshness.sh exists to catch — because staleness is
# unreachable by construction rather than merely unlikely. Fingerprinting
# costs ~0.4 s against a 101 s compile.
#
# MEASURED HIT RATE — READ THIS BEFORE BUDGETING WITH IT
# ======================================================
# scripts/build_initramfs.py embeds EVERY build/user/*.elf at /bin/<name>,
# and 164 of the 181 kernel-building gates compile a fixture into
# build/user/ before the kernel. Each such gate therefore has a genuinely
# DIFFERENT initramfs and needs a genuinely different kernel: within one
# fresh shard those 164 always MISS, and that ~101 s compile is irreducible
# for them as long as the kernel .incbin-s its initramfs. This cache pays
# off for (a) the 17 gates that do not plant a fixture, (b) any gate re-run
# in the same working tree (local iteration), and (c) a shard where a warm
# build/kernelcache is restored. It is NOT a 178x saving; do not budget as
# if it were. The structural fix for the other 164 would be to hand the
# initramfs to QEMU as a separate module instead of compiling it into the
# image — a kernel boot-path change, deliberately out of scope here.
#
# The cache lives in build/kernelcache/ (gitignored with the rest of
# build/). It is deliberately NOT in the freshness gate's artifact list:
# those entries are addressed by input hash, not by mtime.
#
# USAGE
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
#
#     kernel_image_compile "$ELF"          # blob already generated
#     kernel_image "$HAMSH_ELF" "$ELF"     # generate the blob, then compile
#
# Both return non-zero (leaving <out> untouched) on failure, so a caller
# under `set -e` — or one appending `|| verdict_inconclusive ...` — behaves
# exactly as it did around the inline compile. HAMNIX_KERNEL_CACHE=0 forces
# a real compile every time.

_KI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=_tree_fingerprint.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_tree_fingerprint.sh"

# _kernel_image_key — the shared tree fingerprint plus the cpio payload.
# The payload is gitignored (51 MiB) but IS a kernel input: it is
# .incbin-ed straight into the image, and it is the thing that differs
# between two gates compiling the same sources with a different /init.
_kernel_image_key() {
    (
        cd "$_KI_ROOT" || return 1
        { hamnix_tree_fingerprint
          hamnix_build_env_fingerprint
          sha256sum fs/initramfs_blob.S.bin 2>/dev/null
        } | sha256sum | cut -d' ' -f1
    )
}

# kernel_image_compile <out-elf> — compile init/main.ad for x86_64-bare-metal
# against the CURRENT fs/initramfs_blob.S.bin, serving from cache on a hit.
kernel_image_compile() {
    local out="$1"
    local tag="[kernel_image]"

    if [ "${HAMNIX_KERNEL_CACHE:-1}" = "0" ]; then
        echo "$tag HAMNIX_KERNEL_CACHE=0 — compiling (cache bypassed)"
        ( cd "$_KI_ROOT" && python3 -m compiler.adder compile \
            --target=x86_64-bare-metal init/main.ad -o "$out" )
        return $?
    fi

    local key cache
    key="$(_kernel_image_key)"
    cache="$_KI_ROOT/build/kernelcache/$key.elf"

    if [ -n "$key" ] && [ -s "$cache" ]; then
        echo "$tag cache HIT $key -> $out"
        cp -f "$cache" "$out"
        return 0
    fi

    echo "$tag cache MISS $key — compiling init/main.ad"
    if ! ( cd "$_KI_ROOT" && python3 -m compiler.adder compile \
            --target=x86_64-bare-metal init/main.ad -o "$out" ); then
        return 1
    fi
    if [ -n "$key" ]; then
        mkdir -p "$_KI_ROOT/build/kernelcache"
        cp -f "$out" "$cache.tmp.$$" && mv -f "$cache.tmp.$$" "$cache"
    fi
    return 0
}

# kernel_image <init-elf> <out-elf> — regenerate the initramfs with <init-elf>
# as /init, then kernel_image_compile.
kernel_image() {
    local init="$1" out="$2"
    if [ ! -f "$init" ]; then
        echo "[kernel_image] init ELF not found: $init" >&2
        return 1
    fi
    if ! INIT_ELF="$init" python3 "$_KI_ROOT/scripts/build_initramfs.py" >/dev/null; then
        echo "[kernel_image] build_initramfs.py failed for INIT_ELF=$init" >&2
        return 1
    fi
    kernel_image_compile "$out"
}
