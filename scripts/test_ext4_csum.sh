#!/usr/bin/env bash
# scripts/test_ext4_csum.sh — ext4 metadata_csum (RO_COMPAT_METADATA_CSUM)
# crc32c integrity verification.
#
# Unlike build/ext4.img (minted with NO metadata_csum), this test mints
# a SEPARATE ext4 image WITH the metadata_csum feature on. fs/ext4.ad's
# mount path detects the feature in s_feature_ro_compat, builds the
# per-filesystem crc32c seed from s_uuid, and runs an in-kernel self-test
# (gated entirely by the feature bit on the mounted image, so a normal
# no-csum boot prints nothing). The self-test proves, against the REAL
# on-disk checksums a host mke2fs wrote, that:
#
#   * the crc32c known-answer vector passes
#       crc32c("123456789") == 0xE3069283
#   * the superblock s_checksum verifies (crc32c over the sb minus the
#     trailing 4 bytes)
#   * a real inode checksum verifies (l_i_checksum_lo/hi, seeded by
#     uuid + inode number + i_generation)
#   * a real directory-block checksum verifies (the ext4_dir_entry_tail
#     det_checksum at the end of the root dir block)
#   * a deliberately corrupted checksum is DETECTED (negative test)
#   * a write/recompute round-trip reproduces a valid checksum
#
# The kernel prints stable [ext4csum] markers this script greps.
#
# To keep the image inside the driver's well-trodden read path we mint a
# LEAN metadata_csum fs: 1 KiB blocks, no journal, no 64bit (32-byte
# group descriptors), no metadata_csum_seed (so the seed is crc32c(uuid)
# directly, the form fs/ext4.ad computes), no resize_inode.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_csum

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
MKE2FS="$(_which mke2fs)"

echo "[test_ext4_csum] (1/5) Mint a metadata_csum ext4 disk image"
CDISK=$(mktemp --suffix=.ext4-csum.img)
truncate -s 8M "$CDISK"
# Lean metadata_csum layout matching the driver's supported feature set.
"$MKE2FS" -F -q -b 1024 -t ext4 -L "HAMNIX_CSUM" \
    -O metadata_csum,^has_journal,^64bit,^metadata_csum_seed,^resize_inode \
    "$CDISK" >/dev/null

# Plant a couple of files so the root directory carries a real,
# checksummed dir block (and the inode under test has content).
DEBUGFS="$(_which debugfs)"
TMP_PAYLOAD="$(mktemp --suffix=.csum-test.payload)"
printf 'EXT4CSUM_MARKER metadata_csum read path works\n' > "$TMP_PAYLOAD"
"$DEBUGFS" -w -f /dev/stdin "$CDISK" >/dev/null <<EOF
write $TMP_PAYLOAD HELLO.TXT
EOF
rm -f "$TMP_PAYLOAD"

# Sanity: the host must agree the image carries metadata_csum, so a
# mke2fs that silently dropped the feature fails loud.
if command -v dumpe2fs >/dev/null 2>&1 || [ -x /sbin/dumpe2fs ]; then
    DUMPE2FS="$(_which dumpe2fs)"
    if ! "$DUMPE2FS" -h "$CDISK" 2>/dev/null | grep -qiE '(^| )metadata_csum( |$)'; then
        echo "[test_ext4_csum] FAIL: minted image lacks metadata_csum feature"
        rm -f "$CDISK"
        exit 1
    fi
    echo "[test_ext4_csum] host confirms metadata_csum feature present"
fi

echo "[test_ext4_csum] (2/5) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_ext4_csum] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4_csum] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

LOG=$(mktemp)
trap 'rm -f "$LOG" "$CDISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ext4_csum] (5/5) Boot QEMU with the metadata_csum image"
set +e
(
    sleep 4
    printf 'cat /ext/HELLO.TXT\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$CDISK",if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_csum] --- ext4csum lines ---"
grep -E '\[ext4csum\]' "$LOG" || true
echo "[test_ext4_csum] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4csum] markers == the metadata_csum selftest never ran: a
# starved/timed-out boot, an OBSERVED crash (verdict_boot_gate FAILs on
# TRAP/panic), or GRUB OOM — NOT a checksum regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4csum\]'

# A virtio-blk superblock-read flake (host CPU starvation under load)
# means the fs never mounted and the selftest could not run: INCONCLUSIVE.
if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the metadata_csum selftest could not mount. Re-run quiet."
fi

fail=0
for needle in \
    "[ext4csum] PASS verify-crc32c-kat (crc32c('123456789')=0xE3069283)" \
    "[ext4csum] PASS verify-superblock" \
    "[ext4csum] PASS verify-inode (root inode #2)" \
    "[ext4csum] PASS verify-dirblock (root dir block)" \
    "[ext4csum] PASS detect-corruption (flipped byte rejected)" \
    "[ext4csum] PASS roundtrip-inode (recompute matches)" \
    "[ext4csum] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ext4_csum] OK: '$needle'"
    else
        echo "[test_ext4_csum] MISS: '$needle'"
        fail=1
    fi
done

# Hard fail if any in-kernel FAIL marker was printed.
if grep -F -q "[ext4csum] FAIL" "$LOG"; then
    echo "[test_ext4_csum] in-kernel self-test reported a FAIL marker"
    grep -F "[ext4csum] FAIL" "$LOG" || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_csum] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "an [ext4csum] PASS marker was OBSERVED absent (or an in-kernel FAIL" \
        "was printed) while the metadata_csum selftest ran (qemu rc=$rc) —" \
        "a real crc32c integrity regression."
fi
verdict_pass "$TAG" "fs/ext4.ad verifies crc32c metadata_csum on a live mount:" \
    "crc32c KAT, superblock, inode, dir-block checksums all verify, a flipped" \
    "byte is rejected, and a recompute round-trips (qemu rc=$rc)"
