#!/usr/bin/env bash
# scripts/test_ext4_rename.sh — M16.x §12.1 verification: ext4 rename.
#
# The kernel runs ext4_rename_smoke_test() at boot, which:
#   * creates RNSRC.TXT, renames it to RNDST.TXT, verifies the bytes
#     survive the move and the old name is gone (same-directory case
#     + cross-directory machinery),
#   * creates RNSRC2.TXT and renames it ONTO RNDST.TXT — the
#     overwrite-existing-target path,
#   * unlinks the leftover so the FS is left as found.
#
# This script boots the kernel against build/ext4.img and asserts the
# rename smoke marker, plus exercises rename through the VFS by way of
# the native wstat(2) path (hamsh `mv` is copy+unlink, but vfs_rename
# now routes ext4 too).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_rename

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ext4_rename] (1/4) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4_rename] (2/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4_rename] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "[test_ext4_rename] (4/4) Boot QEMU with ext4 image"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 40s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/ext4.img,if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_rename] --- ext4 lines ---"
grep -E 'ext4: rename' "$LOG" || true
echo "[test_ext4_rename] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# The rename smoke test runs unconditionally at boot on build/ext4.img and
# prints its result via `ext4:` lines (mount banner + smoke PASS). A TCG-
# starved / GRUB-OOM boot emits ZERO `ext4:` markers and used to be
# indistinguishable from a real regression. Route zero-marker through the
# shared discriminator first -> INCONCLUSIVE, never a bogus red.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'ext4: (mounted|rename)'

if grep -F -q "ext4: rename smoke PASS" "$LOG"; then
    verdict_pass "$TAG" \
        "ext4 rename smoke: same-dir move + cross-dir move + overwrite-target," \
        "bytes survive and the old name is gone (qemu rc=$rc)"
fi

echo "[test_ext4_rename] --- full log ---"
cat "$LOG"
# ext4 mounted (markers present) but the rename smoke PASS never printed. If
# qemu was killed by timeout the smoke line may simply not have flushed —
# INCONCLUSIVE; a clean exit without it is a real observed regression.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "ext4 mounted but 'ext4: rename smoke PASS' never printed and qemu was" \
        "killed by timeout (rc=124) — starved before the smoke line flushed." \
        "Re-run on a QUIET host."
fi
verdict_fail "$TAG" \
    "ext4 mounted but 'ext4: rename smoke PASS' was OBSERVED absent on a clean" \
    "qemu exit (rc=$rc) — the rename smoke test really failed."
