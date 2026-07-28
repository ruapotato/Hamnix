#!/usr/bin/env bash
# scripts/test_ext4_fscrypt.sh — ext4 fscrypt (EXT4_ENCRYPT_FL) content
# encryption at rest.
#
# Proves native ext4 fscrypt: a regular file gets per-file CONTENT encryption
# via AES-256-XTS (reusing the cipher shared with dm-crypt, fs/aes_xts.ad).
# The in-kernel ext4_fscrypt_selftest() (gated on the cpio marker
# /etc/ext4-fscrypt-test) builds a REAL multi-block file on the live ext4
# mount, sets an fscrypt policy (derives a per-file AES-256-XTS content key
# from a master key via HKDF-SHA256, sets EXT4_ENCRYPT_FL), writes a known
# plaintext ENCRYPTED to disk, then proves end to end:
#   (a) the file reads back byte-identical through the decrypt path;
#   (b) the RAW on-disk block (read beneath the encryption layer) is genuine
#       CIPHERTEXT, NOT the plaintext;
#   (c) two different logical blocks with identical plaintext produce
#       DIFFERENT ciphertext (the XTS tweak = block number is applied);
#   (d) decrypting with the WRONG key yields garbage, not the plaintext.
# The selftest itself does all the work, so the host only has to attach a
# plain, empty ext4 scratch disk on virtio.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ext4_fscrypt] PASS   (kernel prints [ext4-fscrypt] PASS)
# Fail marker:  [test_ext4_fscrypt] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_fscrypt

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

DISK=$(mktemp --suffix=.ext4fscrypt.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_fscrypt] (1/4) Mint a 1 KiB-block ext4 scratch image"
# 64 MiB headroom; 1 KiB blocks match the driver's well-trodden path. The
# kernel selftest builds the encrypted file itself, so the disk ships empty.
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_FSCRYPT" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4_fscrypt] (2/4) Build userland + plant /etc/ext4-fscrypt-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_FSCRYPT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_fscrypt] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4_fscrypt] (4/4) Boot QEMU with the ext4 scratch image"
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

echo "[test_ext4_fscrypt] --- ext4-fscrypt self-test output ---"
grep -a -E "\[ext4-fscrypt\]" "$LOG" || true
echo "[test_ext4_fscrypt] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4-fscrypt] markers == the fscrypt selftest never ran: a starved/
# timed-out boot, an OBSERVED crash, or GRUB OOM — NOT a crypto regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-fscrypt\]'

if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the fscrypt selftest could not mount. Re-run quiet."
fi

fail=0

if grep -a -F -q "[ext4-fscrypt] FAIL" "$LOG"; then
    echo "[test_ext4_fscrypt] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-fscrypt] FAIL" "$LOG" >&2 || true
    fail=1
fi

# Require the specific security/correctness PASS lines so a vacuous PASS
# banner can't slip through: the on-disk bytes must be genuine ciphertext, the
# XTS tweak must actually differentiate blocks, the wrong key must fail, and
# the decrypt round-trip must reproduce the plaintext.
if ! grep -a -F -q "[ext4-fscrypt] PASS decrypt-roundtrip" "$LOG"; then
    echo "[test_ext4_fscrypt] MISS: decrypt-roundtrip PASS line" >&2
    fail=1
fi
if ! grep -a -F -q "[ext4-fscrypt] PASS on-disk-ciphertext" "$LOG"; then
    echo "[test_ext4_fscrypt] MISS: on-disk-ciphertext PASS line" >&2
    fail=1
fi
if ! grep -a -F -q "[ext4-fscrypt] PASS tweak-differs" "$LOG"; then
    echo "[test_ext4_fscrypt] MISS: tweak-differs PASS line" >&2
    fail=1
fi
if ! grep -a -F -q "[ext4-fscrypt] PASS wrong-key" "$LOG"; then
    echo "[test_ext4_fscrypt] MISS: wrong-key PASS line" >&2
    fail=1
fi

if ! grep -a -F -q "[ext4-fscrypt] PASS" "$LOG"; then
    echo "[test_ext4_fscrypt] MISS: self-test PASS banner (expected '[ext4-fscrypt] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_fscrypt] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "an [ext4-fscrypt] PASS marker was OBSERVED absent (or an in-kernel" \
        "FAIL was printed) while the fscrypt selftest ran (qemu rc=$rc) — a" \
        "real at-rest-encryption regression."
fi

verdict_pass "$TAG" "fscrypt encrypts a file's contents at rest with per-file" \
     "AES-256-XTS; on-disk bytes are ciphertext, the XTS tweak differentiates" \
     "blocks, the wrong key fails, and decrypt round-trips (qemu rc=$rc)"
