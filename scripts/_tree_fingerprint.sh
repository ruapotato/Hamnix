#!/usr/bin/env bash
# scripts/_tree_fingerprint.sh — one SHA-256 that changes whenever ANY
# buildable input in the tree changes.
#
# Shared by the two build caches the CI battery leans on
# (scripts/_kernel_image.sh, scripts/_adder_bin.sh). Both are content-
# addressed rather than mtime-addressed precisely so that a stale artifact
# is unreachable by construction — the failure mode
# scripts/test_artifact_freshness.sh exists to catch. That guarantee is only
# as good as this fingerprint, so it is deliberately GENEROUS: every tracked
# file plus every untracked-but-not-ignored file, hashed by CONTENT. It
# costs ~0.4 s against compiles that cost 30-200 s.
#
# fs/initramfs_blob.S is excluded because it is a generated file whose
# content is a pure function of the cpio payload; _kernel_image.sh keys on
# that payload (fs/initramfs_blob.S.bin) explicitly.
#
# Prints the empty string if git is unavailable, which every caller treats
# as "no cache — compile for real".

_TF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

hamnix_tree_fingerprint() {
    (
        cd "$_TF_ROOT" || return 1
        {
            git ls-files
            git ls-files --others --exclude-standard
        } 2>/dev/null \
            | grep -v '^fs/initramfs_blob\.S$' \
            | LC_ALL=C sort -u \
            | tr '\n' '\0' \
            | xargs -0 -r sha256sum 2>/dev/null \
            | sha256sum | cut -d' ' -f1
    )
}

# hamnix_build_env_fingerprint — the build-affecting environment.
#
# The Adder compiler reads ADDER_* (ADDER_CC picks seed-vs-native, ADDER_OPT/
# ADDER_OPT2 pick an optimizer, ADDER_CHECK_BOUNDS instruments) and the build
# scripts read HAMNIX_*. Two gates with identical sources but a different
# ADDER_OPT must NOT share a cache entry, so every such variable is folded
# into the key by name and value.
hamnix_build_env_fingerprint() {
    { env | grep -E '^(ADDER|HAMNIX)_' || true; } | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}
