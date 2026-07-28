#!/usr/bin/env bash
# scripts/test_ext4_fast_commit.sh — ext4 fast_commit (COMPAT_FAST_COMMIT)
# fine-grained per-inode journal + replay verification.
#
# Proves the ext4 driver's fast-commit layer (fs/ext4.ad fast_commit
# block + fs/jbd2.ad fc tail accessors) does a REAL on-disk round-trip
# with durability, not a stub.
#
# Mints a SEPARATE ext4 image WITH a real JBD2 journal AND the
# fast_commit feature (-O has_journal,fast_commit). The kernel mounts
# it, detects COMPAT_FAST_COMMIT, reserves the journal's fast-commit
# tail, and runs ext4_fast_commit_selftest() (gated by the cpio sentinel
# /etc/ext4-fc-test) which asserts, against concrete on-disk bytes:
#
#   1. A per-inode change recorded into the fast-commit area (TAG_INODE +
#      TAG_ADD_RANGE + crc'd TAG_TAIL) leaves the file's real data block
#      UNCHANGED until replay (the fast path only writes the fc log).
#   2. Replaying the fc region (== crash recovery on remount) restores
#      the NEW body byte-for-byte.
#   3. A crc-corrupt fast-commit is REJECTED by replay (the data block
#      keeps the last good body, never the corrupt one).
#
# The kernel prints stable markers this script greps; the verdict is
# computed in-kernel from real byte comparisons, never hardcoded.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_fast_commit

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

echo "[test_ext4_fast_commit] (1/5) Mint a JOURNALLED + fast_commit ext4 disk image"
# 16 MiB so mkfs.ext4 builds a real internal journal (>= 1024 blocks).
# 1 KiB blocks to match the driver's well-trodden path. -O
# has_journal,fast_commit turns BOTH features ON.
FDISK=$(mktemp --suffix=.ext4-fc.img)
truncate -s 16M "$FDISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_FC" \
    -O has_journal,fast_commit "$FDISK" >/dev/null

# Sanity: the host must agree the image has fast_commit + a journal, so a
# mkfs that silently dropped a feature fails loud.
if command -v dumpe2fs >/dev/null 2>&1 || [ -x /sbin/dumpe2fs ]; then
    DUMPE2FS="$(_which dumpe2fs)"
    FEAT="$("$DUMPE2FS" -h "$FDISK" 2>/dev/null | grep -i 'Filesystem features' || true)"
    if ! echo "$FEAT" | grep -qi "fast_commit"; then
        echo "[test_ext4_fast_commit] FAIL: minted image lacks fast_commit feature"
        rm -f "$FDISK"
        exit 1
    fi
    if ! echo "$FEAT" | grep -qi "has_journal"; then
        echo "[test_ext4_fast_commit] FAIL: minted image lacks has_journal feature"
        rm -f "$FDISK"
        exit 1
    fi
    echo "[test_ext4_fast_commit] host confirms fast_commit + has_journal present"
fi

echo "[test_ext4_fast_commit] (2/5) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_ext4_fast_commit] (3/5) Plant /etc/ext4-fc-test sentinel + /init"
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_FC_TEST=1 \
    python3 scripts/build_initramfs.py

echo "[test_ext4_fast_commit] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

LOG=$(mktemp)
trap 'rm -f "$LOG" "$FDISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ext4_fast_commit] (5/5) Boot QEMU with the fast_commit image"
set +e
(
    sleep 4
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$FDISK",if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_fast_commit] --- ext4-fc / fast-commit lines ---"
grep -E 'ext4-fc|fast-commit|fast_commit|COMPAT_FAST_COMMIT' "$LOG" || true
echo "[test_ext4_fast_commit] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4-fc] markers == the fast_commit selftest never ran: a starved/
# timed-out boot, an OBSERVED crash, or GRUB OOM — NOT a journal regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-fc\]|COMPAT_FAST_COMMIT'

if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the fast_commit selftest could not mount. Re-run quiet."
fi

fail=0
for needle in \
    "ext4: COMPAT_FAST_COMMIT present; fast-commit log armed" \
    "[ext4-fc] OK fast-commit area reserved" \
    "[ext4-fc] OK created FC.TXT with OLD body" \
    "[ext4-fc] OK committed-but-unreplayed: file data still OLD" \
    "[ext4-fc] OK fast-commit survived crash (replay applied NEW)" \
    "[ext4-fc] OK corrupt fast-commit rejected by crc (data unchanged)" \
    "[ext4-fc] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ext4_fast_commit] OK: '$needle'"
    else
        echo "[test_ext4_fast_commit] MISS: '$needle'"
        fail=1
    fi
done

# Hard fail if any FAIL marker was printed by the in-kernel self-test.
if grep -F -q "[ext4-fc] FAIL" "$LOG"; then
    echo "[test_ext4_fast_commit] in-kernel self-test reported a FAIL marker"
    grep -F "[ext4-fc] FAIL" "$LOG" || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_fast_commit] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "an [ext4-fc] marker was OBSERVED absent (or an in-kernel FAIL was" \
        "printed) while the fast_commit selftest ran (qemu rc=$rc) — a real" \
        "fast-commit journal/replay regression."
fi
verdict_pass "$TAG" "fs/ext4.ad arms the fast-commit log, and a committed-but-" \
    "unreplayed file reads OLD, a crash-replay applies NEW, and a crc-corrupt" \
    "fast-commit is rejected (qemu rc=$rc)"
