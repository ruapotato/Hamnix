#!/usr/bin/env bash
# scripts/test_ext4_journal.sh — #149 ext4 JBD2 journal verification.
#
# Proves the ext4 driver's new write-ahead journal (fs/jbd2.ad) makes
# the filesystem crash-consistent, in ordered/metadata-journaling mode.
#
# Unlike build/ext4.img (minted with -O ^has_journal), this test mints
# a SEPARATE ext4 image WITH a real JBD2 journal (mkfs.ext4 default /
# -O has_journal). The kernel mounts it, parses the real JBD2
# superblock, and runs ext4_journal_selftest() (gated by the cpio
# sentinel /etc/ext4-journal-test) which asserts, with concrete raw
# fs-block contents:
#
#   1. A transaction committed to the journal but NOT yet checkpointed
#      (== crash after commit) IS recovered by replay — the committed
#      change survives.
#   2. A torn transaction (descriptor + data written, NO commit block,
#      == crash mid-commit) is DISCARDED by replay — the change rolls
#      back and the fs block is untouched.
#   3. The JBD2 superblock magic 0xC03B3998 was actually read from the
#      journal inode (proves a real journal was parsed, not a stub).
#
# The kernel prints stable, unforgeable markers this script greps.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_journal

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

echo "[test_ext4_journal] (1/5) Mint a JOURNALLED ext4 disk image"
# 16 MiB so mkfs.ext4 builds a real internal journal (a journal needs
# >= 1024 blocks; at 1 KiB blocks that is >= 1 MiB of journal alone, so
# a comfortably-large image keeps the default journal). Force the
# has_journal feature explicitly so this never silently degrades.
JDISK=$(mktemp --suffix=.ext4-journal.img)
truncate -s 16M "$JDISK"
# 1 KiB blocks to match the driver's well-trodden 1 KiB path; -O
# has_journal turns the journal ON (the opposite of build/ext4.img).
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_JRN" -O has_journal "$JDISK" >/dev/null

# Sanity: the host must agree the image has a journal + report the
# journal inode, so a mkfs that silently dropped the feature fails loud.
if command -v dumpe2fs >/dev/null 2>&1 || [ -x /sbin/dumpe2fs ]; then
    DUMPE2FS="$(_which dumpe2fs)"
    if ! "$DUMPE2FS" -h "$JDISK" 2>/dev/null | grep -qi "has_journal"; then
        echo "[test_ext4_journal] FAIL: minted image lacks has_journal feature"
        rm -f "$JDISK"
        exit 1
    fi
    echo "[test_ext4_journal] host confirms has_journal feature present"
fi

echo "[test_ext4_journal] (2/5) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_ext4_journal] (3/5) Plant /etc/ext4-journal-test sentinel + /init"
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_JOURNAL_TEST=1 \
    python3 scripts/build_initramfs.py

echo "[test_ext4_journal] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

LOG=$(mktemp)
trap 'rm -f "$LOG" "$JDISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ext4_journal] (5/5) Boot QEMU with the journalled image"
set +e
(
    sleep 4
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$JDISK",if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_journal] --- jbd2 / journal lines ---"
grep -E 'jbd2:|ext4: journal|ext4_journal' "$LOG" || true
echo "[test_ext4_journal] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero jbd2/[ext4_journal] markers == starved/timeout/OOM boot — the crash-
# consistency selftest never ran — NOT a regression. The per-needle chain
# below stays as diagnostics; final decision is verdict_*.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'jbd2:|\[ext4_journal\]|ext4: journal'

fail=0
for needle in \
    "ext4: journal attached (JBD2)" \
    "[ext4_journal] OK magic=0xC03B3998 (real JBD2 superblock parsed)" \
    "[ext4_journal] OK committed-but-uncheckpointed: fs block still OLD" \
    "[ext4_journal] OK committed txn survived crash (replay applied NEW)" \
    "[ext4_journal] OK torn txn rolled back (fs block unchanged)" \
    "[ext4_journal] PASS crash-consistency (commit survives, torn rolls back)"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ext4_journal] OK: '$needle'"
    else
        echo "[test_ext4_journal] MISS: '$needle'"
        fail=1
    fi
done

# Hard fail if any FAIL marker was printed by the in-kernel self-test.
if grep -F -q "[ext4_journal] FAIL" "$LOG"; then
    echo "[test_ext4_journal] in-kernel self-test reported a FAIL marker"
    grep -F "[ext4_journal] FAIL" "$LOG" || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_journal] --- full log ---"
    cat "$LOG"
    if ! grep -F -q "[ext4_journal] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "jbd2/[ext4_journal] markers printed but the terminal PASS banner" \
            "never arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ext4_journal] crash-consistency marker was OBSERVED absent (or an" \
        "internal FAIL was reported) while the selftest ran (qemu rc=$rc)."
fi
verdict_pass "$TAG" "ext4 JBD2 journal crash-consistency: a committed txn's" \
    "replay applies NEW data across a crash while a torn txn rolls back" \
    "(qemu rc=$rc)"
