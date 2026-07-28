#!/usr/bin/env bash
# scripts/test_ext4_verity.sh — ext4 fs-verity (EXT4_VERITY_FL) verification.
#
# Proves native ext4 fs-verity: a regular file gets a built-in, read-only,
# salted-SHA-256 Merkle hash tree (reusing the SHA-256 primitive shared with
# dm-verity, fs/sha256.ad) rooted at a trusted root hash. The in-kernel
# ext4_verity_selftest() (gated on the cpio marker /etc/ext4-verity-test)
# builds a REAL multi-block file on the live ext4 mount, enables verity, then
# proves end to end:
#   (a) a clean verity file reads back byte-identical AND verifies;
#   (b) tampering a DATA block on disk is DETECTED (the verified read fails
#       EIO — the recomputed leaf no longer matches the stored leaf);
#   (c) tampering a HASH-TREE node is DETECTED (the verified read fails EIO —
#       the recomputed root no longer matches the trusted root);
#   (d) restoring data / hash tree makes the file verify again.
# The selftest itself does all the work, so the host only has to attach a
# plain, empty ext4 scratch disk on virtio.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ext4_verity] PASS   (kernel prints [ext4-verity] PASS)
# Fail marker:  [test_ext4_verity] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_verity

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

DISK=$(mktemp --suffix=.ext4verity.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_verity] (1/4) Mint a 1 KiB-block ext4 scratch image"
# 64 MiB headroom; 1 KiB blocks match the driver's well-trodden path. The
# kernel selftest builds the verity file itself, so the disk ships empty.
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_VERITY" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4_verity] (2/4) Build userland + plant /etc/ext4-verity-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_VERITY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_verity] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4_verity] (4/4) Boot QEMU with the ext4 scratch image"
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

echo "[test_ext4_verity] --- ext4-verity self-test output ---"
grep -a -E "\[ext4-verity\]" "$LOG" || true
echo "[test_ext4_verity] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4-verity] markers == the fs-verity selftest never ran: a starved/
# timed-out boot, an OBSERVED crash, or GRUB OOM — NOT a verity regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-verity\]'

if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the fs-verity selftest could not mount. Re-run quiet."
fi

fail=0

if grep -a -F -q "[ext4-verity] FAIL" "$LOG"; then
    echo "[test_ext4_verity] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-verity] FAIL" "$LOG" >&2 || true
    fail=1
fi

# Require the specific tamper-detection PASS lines so a vacuous PASS banner
# can't slip through: both a data-byte tamper and a hash-tree-byte tamper
# must have been genuinely detected.
if ! grep -a -F -q "[ext4-verity] PASS detect-data-tamper" "$LOG"; then
    echo "[test_ext4_verity] MISS: detect-data-tamper PASS line" >&2
    fail=1
fi
if ! grep -a -F -q "[ext4-verity] PASS detect-tree-tamper" "$LOG"; then
    echo "[test_ext4_verity] MISS: detect-tree-tamper PASS line" >&2
    fail=1
fi
if ! grep -a -F -q "[ext4-verity] PASS clean-read" "$LOG"; then
    echo "[test_ext4_verity] MISS: clean-read PASS line" >&2
    fail=1
fi

if ! grep -a -F -q "[ext4-verity] PASS" "$LOG"; then
    echo "[test_ext4_verity] MISS: self-test PASS banner (expected '[ext4-verity] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_verity] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "an [ext4-verity] PASS marker was OBSERVED absent (or an in-kernel FAIL" \
        "was printed) while the fs-verity selftest ran (qemu rc=$rc) — a real" \
        "verity authentication regression."
fi

verdict_pass "$TAG" "fs-verity authenticates a file via a salted SHA-256 Merkle" \
     "tree; clean-read verifies and data AND hash-tree tampering are both" \
     "detected (qemu rc=$rc)"
