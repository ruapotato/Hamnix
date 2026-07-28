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

# NOTE ON SHELL OPTIONS: callers are gates running under `set -euo pipefail`.
# The pipeline below can legitimately see a file vanish between `git ls-files`
# and `sha256sum` (a sibling gate's build-lock wipe, a generated file being
# rewritten), which makes xargs exit 123. Inheriting the caller's -e/pipefail
# would then abort the GATE with a bare rc=123 and no message — observed
# 2026-07-28 on test_adder_hamalloc. The subshell therefore turns both off for
# itself. This does NOT weaken the key: a file that could not be hashed simply
# contributes no line, so its absence still changes the digest.
hamnix_tree_fingerprint() {
    (
        set +e +o pipefail
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

# hamnix_build_env_fingerprint — the COMPILER-affecting environment.
#
# ADDER_* is the Adder compiler's knob namespace: ADDER_CC picks
# seed-vs-native, ADDER_OPT/ADDER_OPT2 pick an optimizer, ADDER_CHECK_BOUNDS
# instruments, ADDER_ELF64_APPS changes an output format. Two builds with
# identical sources but a different ADDER_OPT must NOT share a cache entry,
# so every such variable is folded in by name and value.
#
# HAMNIX_* is deliberately EXCLUDED. It is the test/runtime knob namespace —
# HAMNIX_TEST_SMP, HAMNIX_VM_MEM, HAMNIX_DE_SELFTEST, KEEP_LOGS-adjacent
# flags — none of which change a single emitted byte, and gates export them
# around their build steps. Folding them in made every key differ between a
# bare build and the same build run from inside a gate, so nothing ever hit
# (observed 2026-07-28: build_user.sh rebuilt on every gate despite an
# unchanged tree). HAMNIX_INITRAMFS_BLOB is the one HAMNIX_ variable that
# does select a build input, so it is named explicitly.
hamnix_build_env_fingerprint() {
    ( set +e +o pipefail
    { env | grep -E '^ADDER_' || true
      printf 'HAMNIX_INITRAMFS_BLOB=%s\n' "${HAMNIX_INITRAMFS_BLOB:-}"
    } | LC_ALL=C sort | sha256sum | cut -d' ' -f1 )
}
