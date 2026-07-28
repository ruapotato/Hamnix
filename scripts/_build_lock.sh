# scripts/_build_lock.sh — per-worktree exclusive lock for the build pipeline.
#
# REAL BUG (not a flake, not a retry-worthy thing):
#
# Every test_*.sh script rebuilds the world (userland binaries +
# initramfs + kernel ELF) IN PLACE in build/, with the per-test
# INIT_ELF override mutating fs/initramfs_blob.S. The kernel image
# then EMBEDS that blob via .incbin, so the kernel's identity
# depends on the source file's contents at compile time.
#
# Within ONE checkout, two concurrent test_*.sh invocations would
# race on fs/initramfs_blob.S — the second one's INIT_ELF clobbers
# the first one's, and qemu boots a kernel built from the wrong
# mix of states. The lock prevents that.
#
# Worktree note (2026-05-18): the lock LIVES IN THE WORKTREE
# (build/.build_lock), not at a global /tmp path. `git worktree`-
# created worktrees have their own physical copy of every tracked
# file including fs/initramfs_blob.S, so agents in separate
# worktrees CAN safely build in parallel — they're touching
# disjoint files on disk. Putting the lock at /tmp would serialise
# them artificially and starve agents that should have been
# independent. Each worktree owns its own lock; the main checkout
# (`/home/david/Hamnix/build/.build_lock`) and any worktree
# (`.claude/worktrees/agent-*/build/.build_lock`) lock different
# files.
#
# Usage: each test_*.sh sources this file as its FIRST action
# (before any `set -e`). The flock is held for the lifetime of
# the script (released when the shell exits). Timeout is 120s —
# if you can't acquire in two minutes within ONE worktree, fail
# fast instead of looping (the previous 600s ate agent cycles).
# Override via HAMNIX_BUILD_LOCK_TIMEOUT=<seconds>.

# Resolve the lock path relative to this script's location, so it
# follows the worktree. ${BASH_SOURCE} is scripts/_build_lock.sh
# inside whichever checkout sourced us.
#
# Opt-in build isolation: when HAMNIX_BUILD_DIR is set, the lock (and the
# auto-wiped outputs) live in that caller-chosen directory instead. Two
# builds in ONE checkout with DIFFERENT HAMNIX_BUILD_DIR then take
# DIFFERENT locks and run in parallel. Unset → the historical
# script-relative ../build path.
if [ -n "${HAMNIX_BUILD_DIR:-}" ]; then
    _HAMNIX_BUILD_LOCK_DIR="$HAMNIX_BUILD_DIR"
else
    _HAMNIX_BUILD_LOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build"
fi
mkdir -p "$_HAMNIX_BUILD_LOCK_DIR"
_HAMNIX_BUILD_LOCK="$_HAMNIX_BUILD_LOCK_DIR/.build_lock"
_HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-120}"

# Higher-half kernel boot shim. The Hamnix kernel is now a true elf64
# higher-half image, which QEMU's `-kernel` multiboot1 loader refuses
# to load. _kernel_iso.sh defines a `qemu-system-x86_64` shell function
# that transparently boots an ELFCLASS64 `-kernel` target from a BIOS
# GRUB ISO instead. Sourced here — before the reentrancy return below —
# so every test_*.sh that sources _build_lock.sh (as its first action)
# picks the shim up. Real Linux bzImages and `-cdrom`/`-bios` boots are
# passed through untouched. See scripts/_kernel_iso.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_iso.sh"

# --- bare-kernel unit lane gets a SMALL initramfs by default ---------
#
# build_initramfs.py defaults HAMNIX_DEFAULT_REAL_DEBIAN=1, which stages
# the WHOLE debootstrap closure (~305 MiB) into fs/initramfs_blob.S —
# and that blob is linked INTO the kernel ELF, so build/hamnix-kernel.elf
# balloons from ~46 MiB (busybox) to ~334 MiB (real Debian). The ~600
# `-kernel` UNIT gates boot that ELF with a small `-m` and a SHORT
# `timeout` (15–30 s): a 334 MiB kernel cannot even be loaded by GRUB
# under `-m 256M` (out-of-memory before the first instruction), and even
# with _kernel_iso.sh's memory floor it cannot finish GRUB-load + cpio
# unpack inside a 15 s budget. So every marker is absent and the gate
# emits a wall of false FAILs. The fixture is gitignored, so this is
# INVISIBLE on a fresh CI checkout (busybox → 46 MiB → green) and only
# bites developers who have run debootstrap (which the Firefox/Wayland
# work requires). See scripts/_kernel_iso.sh and commit 2b34b273.
#
# These are KERNEL/unit tests — they need no Debian userland. So the
# test harness defaults the knob OFF (busybox-only, small fast kernel).
# This does NOT change build_initramfs.py's own default (still 1), so the
# product/installer image and any direct `python3 build_initramfs.py`
# caller that does NOT source this harness still ship real Debian. And
# build_rootfs_img.py (the shipped ext4 root) has its OWN independent
# default=1, so the DISTRO the user boots is unaffected.
#
# A test that genuinely exercises the Debian namespace (enter linux
# running real apt/dpkg/dash, the distro-identity tests) OPTS BACK IN
# with `export HAMNIX_DEFAULT_REAL_DEBIAN=1` right after sourcing this
# file (or by prefixing its build_initramfs.py invocation). Those tests
# have long timeouts (60–2400 s) and larger `-m`, so the big kernel boots
# fine there — and _kernel_iso.sh raises `-m` for them automatically.
# `:-` means an explicit pre-set value (from the caller's environment)
# always wins, so the opt-in and CI overrides are honoured.
export HAMNIX_DEFAULT_REAL_DEBIAN="${HAMNIX_DEFAULT_REAL_DEBIAN:-0}"

# Reentrancy guard: many test_*.sh scripts source us AND invoke
# scripts/build_iso.sh which also sources us. The child process
# inherits fd 200 from the parent, but the child's `flock -x 200`
# would deadlock waiting for the lock the parent already holds.
# Detect "we're nested under a parent that already locked" via an
# exported env var that we set after acquiring. Same-worktree only —
# the lock path is part of the sentinel so a child from a different
# worktree (impossible today, but defensible) still acquires its own.
if [ "${HAMNIX_BUILD_LOCK_HELD:-}" = "$_HAMNIX_BUILD_LOCK" ]; then
    # Parent in this same worktree already holds the lock. Skip
    # re-acquisition. No `exec 200>` either — we don't want to clobber
    # the parent's fd 200 (it's inherited and the lock state is
    # attached to the inherited open-file-description).
    return 0 2>/dev/null || true
fi

# fd 200 reserved; matches conventional flock-in-bash pattern.
exec 200>"$_HAMNIX_BUILD_LOCK"
if ! flock -x -w "$_HAMNIX_BUILD_LOCK_TIMEOUT" 200; then
    echo "[$(basename "$0")] build lock timeout (${_HAMNIX_BUILD_LOCK_TIMEOUT}s) —" \
         "another test still holds $_HAMNIX_BUILD_LOCK." \
         "Override timeout: HAMNIX_BUILD_LOCK_TIMEOUT=<seconds>" >&2
    exit 1
fi

# Auto-wipe stale compiled outputs so every test starts from a clean
# build. A build interrupted hard (kill -9 of a compiler.adder compile)
# leaves TRUNCATED .elf / blob artifacts that the incremental rebuild
# won't regenerate — silently poisoning the next test (e.g. a kernel
# that boots to nothing, or a "not found" for an embedded binary).
# We hold the build lock here, so nothing races this wipe.
#   - WIPED: compiled code outputs (the poison surface).
#   - SPARED: build/*.img disk images (some tests persist + reuse them)
#             and build/.build_lock (a dotfile; * doesn't match it, and
#             fd 200 stays valid regardless).
#
# 2026-07-28 — VERIFY INSTEAD OF ASSUME, for build/user only.
#
# This wipe is the single largest cost in the CI battery. 177 of the 621
# gates in scripts/ci_battery_manifest.txt source this file, so 177 times per
# battery run the whole userland is deleted and rebuilt from scratch
# (scripts/build_user.sh: 89 s wall / 7m43 s CPU on this 12-core host,
# measured 2026-07-28) — and it is deleted whether or not anything is
# actually poisoned. That is what made every shard of the 2026-07-27 run hit
# the 50-minute cap, and it is why the build_user.sh / _adder_bin.sh /
# _kernel_image.sh caches could never hit.
#
# The property the wipe defends is real: a hard-killed compile leaves a
# TRUNCATED .elf that an incremental rebuild will not regenerate. But
# truncation is DETECTABLE. build/user/.stamp records a SHA-256 of every
# file build_user.sh produced, keyed by a fingerprint of the whole source
# tree (scripts/_tree_fingerprint.sh). If every recorded output still hashes
# to its recorded value AND the tree is unchanged, the outputs are provably
# intact and current — there is nothing to un-poison, and re-deriving them
# would produce the same bytes. A truncated, missing, or stale file fails the
# check and we wipe exactly as before. This is the same guarantee, verified
# rather than assumed.
#
# Everything else (build/mod, build/iso, build/*.elf, build/*.iso, the
# initramfs blob) is still wiped unconditionally: those are cheap to
# regenerate, or content-addressed elsewhere, so there is no reason to
# take the risk for them.
_hamnix_build_user_intact() {
    local stampd="$_HAMNIX_BUILD_LOCK_DIR/user/.stamp" root fp
    [ -f "$stampd" ] || return 1
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=_tree_fingerprint.sh
    . "$root/scripts/_tree_fingerprint.sh" || return 1
    fp="$(hamnix_tree_fingerprint)|$(hamnix_build_env_fingerprint)"
    [ -n "$fp" ] || return 1
    [ "$(head -n1 "$stampd")" = "$fp" ] || return 1
    ( cd "$root" && tail -n +2 "$stampd" | sha256sum --quiet --check - ) >/dev/null 2>&1
}

if [ "${HAMNIX_BUILD_LOCK_ALWAYS_WIPE:-0}" != "1" ] && _hamnix_build_user_intact; then
    echo "[build_lock] build/user verified intact against its content stamp —" \
         "keeping it (a truncated or stale output would have failed the check)" >&2
    rm -rf "$_HAMNIX_BUILD_LOCK_DIR"/mod \
           "$_HAMNIX_BUILD_LOCK_DIR"/iso "$_HAMNIX_BUILD_LOCK_DIR"/*.elf \
           "$_HAMNIX_BUILD_LOCK_DIR"/*.iso 2>/dev/null || true
else
    rm -rf "$_HAMNIX_BUILD_LOCK_DIR"/user "$_HAMNIX_BUILD_LOCK_DIR"/mod \
           "$_HAMNIX_BUILD_LOCK_DIR"/iso "$_HAMNIX_BUILD_LOCK_DIR"/*.elf \
           "$_HAMNIX_BUILD_LOCK_DIR"/*.iso 2>/dev/null || true
fi
# The in-source blob (default builds) AND an isolated build-dir blob
# (HAMNIX_BUILD_DIR builds) are both poison surfaces — wipe whichever
# applies. For the default case _HAMNIX_BUILD_LOCK_DIR is ../build so the
# first path resolves to ../fs/initramfs_blob.S as before; the second is
# a harmless no-op. For an isolated build dir the second path is the live
# blob and the first is a no-op.
rm -f "$_HAMNIX_BUILD_LOCK_DIR/../fs/initramfs_blob.S" 2>/dev/null || true
rm -f "$_HAMNIX_BUILD_LOCK_DIR/initramfs_blob.S" 2>/dev/null || true

export HAMNIX_BUILD_LOCK_HELD="$_HAMNIX_BUILD_LOCK"
