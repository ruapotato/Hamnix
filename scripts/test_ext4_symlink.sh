#!/usr/bin/env bash
# scripts/test_ext4_symlink.sh — ext4 slow-symlink create/read verification.
#
# Proves ext4_create_symlink (fs/ext4.ad) supports BOTH symlink encodings:
#   * fast (inline) link: target <= 60 bytes, stored in the inode's i_block;
#   * slow link: target > 60 bytes, stored in a freshly-allocated data block
#     recorded as a depth-0 extent — exactly like a regular file's block 0.
# The in-kernel ext4_symlink_selftest() (gated on the cpio marker
# /etc/ext4-symlink-test) creates one of each on the live ext4 mount and reads
# each target back via _ext4_read_symlink_target, comparing byte-for-byte
# against what was written. The selftest does all the work, so the host only
# attaches a plain, empty ext4 scratch disk on virtio.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ext4_symlink] PASS   (kernel prints [ext4-symlink] PASS)
# Fail marker:  [test_ext4_symlink] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_symlink

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

_which() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for prefix in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$prefix/$name" ]; then echo "$prefix/$name"; return 0; fi
    done
    echo "$0: required tool '$name' not found" >&2
    return 1
}
MKFS="$(_which mkfs.ext4)"

DISK=$(mktemp --suffix=.ext4symlink.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_symlink] (1/4) Mint a 1 KiB-block ext4 scratch image"
# 64 MiB headroom; 1 KiB blocks match the driver's well-trodden path. The
# kernel selftest creates the symlinks itself, so the disk ships empty.
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_SYMLINK" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4_symlink] (2/4) Build userland + plant /etc/ext4-symlink-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_SYMLINK_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_symlink] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4_symlink] (4/4) Boot QEMU with the ext4 scratch image"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_symlink] --- ext4-symlink self-test output ---"
grep -a -E "\[ext4-symlink\]" "$LOG" || true
echo "[test_ext4_symlink] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4-symlink] markers == starved/timeout/OOM boot, NOT a regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-symlink\]'

fail=0

if grep -a -F -q "[ext4-symlink] FAIL" "$LOG"; then
    echo "[test_ext4_symlink] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-symlink] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[ext4-symlink] PASS" "$LOG"; then
    echo "[test_ext4_symlink] MISS: self-test PASS banner (expected '[ext4-symlink] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_symlink] --- full log ---"
    cat "$LOG"
    if ! grep -a -F -q "[ext4-symlink] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ext4-symlink] markers printed but the terminal PASS banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "the [ext4-symlink] PASS banner was OBSERVED absent (or an internal" \
        "FAIL was reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "slow (data-block) and fast (inline) symlinks create and" \
     "read back byte-for-byte on the live ext4 mount (qemu rc=$rc)"
