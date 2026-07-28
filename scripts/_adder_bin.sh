#!/usr/bin/env bash
# scripts/_adder_bin.sh — content-addressed cache for HOST-side Adder
# binaries built by CI gates.
#
# WHY THIS EXISTS
# ===============
# The 410 QEMU-free gates in scripts/ci_battery_manifest.txt are dominated
# by a handful of binaries compiled over and over:
#
#     user/hambrowse.ad           referenced by 210 gates
#     user/hambrowse_host.ad                   140
#     user/hambrowse_host_gfx.ad               120
#     user/js_host.ad                           75
#     user/hamsh.ad                             49
#
# Each `python3 -m compiler.adder compile --target=x86_64-linux
# user/hambrowse_host.ad -o "$BIN"` costs 30-100 s and is not incremental,
# so a single hambrowse gate spends most of its wall clock rebuilding a
# binary its 200 siblings in the same shard also rebuild — byte for byte.
# Together with the kernel recompile (scripts/_kernel_image.sh) that is what
# pushed every shard of the 2026-07-27 battery past its 50-minute cap.
#
# HONESTY — WHY THIS IS NOT A SOFT GREEN
# ======================================
# This is a CACHE, not a skip. The key covers the CONTENT of every tracked
# and every untracked-but-not-ignored file in the tree, plus the target
# triple, the source path and the extra compiler arguments. Any edit to any
# .ad source, to lib/web/, or to the Adder compiler changes the key and
# forces a real compile, so a hit returns a binary byte-identical to the one
# a from-scratch compile would have produced. Gates that assert "X still
# compiles" keep asserting exactly that.
#
# It also RETIRES a real hazard: the ad-hoc "reuse build/host/hambrowse_gfx
# if it exists" shortcuts that made stale-binary false greens possible after
# a lib/web change. Here staleness is unreachable by construction.
#
# A FAILING compile is never cached and always propagates its exit status
# and its stderr, so `... 2>"$LOG" || { cat "$LOG"; exit 1; }` behaves
# unchanged.
#
# USAGE
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
#     adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/c.log"
#
# HAMNIX_ADDER_BIN_CACHE=0 forces a real compile every time.

_AB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=_tree_fingerprint.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_tree_fingerprint.sh"

# adder_bin <target> <src.ad> <out> [extra compiler args...]
adder_bin() {
    local target="$1" src="$2" out="$3"; shift 3
    local tag="[adder_bin]"

    if [ "${HAMNIX_ADDER_BIN_CACHE:-1}" = "0" ]; then
        ( cd "$_AB_ROOT" && python3 -m compiler.adder compile \
            --target="$target" "$src" -o "$out" "$@" )
        return $?
    fi

    local tree key cache
    tree="$(hamnix_tree_fingerprint)"
    if [ -z "$tree" ]; then
        ( cd "$_AB_ROOT" && python3 -m compiler.adder compile \
            --target="$target" "$src" -o "$out" "$@" )
        return $?
    fi
    key="$(printf '%s\n%s\n%s\n%s\n%s\n' "$tree" \
            "$(hamnix_build_env_fingerprint)" "$target" "$src" "$*" \
            | sha256sum | cut -d' ' -f1)"
    cache="$_AB_ROOT/build/adderbincache/$key.bin"

    if [ -s "$cache" ]; then
        echo "$tag cache HIT $target $src -> $out" >&2
        cp -f "$cache" "$out" && chmod +x "$out"
        return 0
    fi

    echo "$tag cache MISS $target $src — compiling" >&2
    if ! ( cd "$_AB_ROOT" && python3 -m compiler.adder compile \
            --target="$target" "$src" -o "$out" "$@" ); then
        return 1
    fi
    [ -s "$out" ] || return 0
    mkdir -p "$_AB_ROOT/build/adderbincache"
    cp -f "$out" "$cache.tmp.$$" && mv -f "$cache.tmp.$$" "$cache"
    return 0
}
