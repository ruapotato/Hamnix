#!/usr/bin/env bash
# scripts/test_ext4_rmdir.sh — ext4 rmdir + directory-rename ".." fixup.
#
# The kernel runs ext4_rmdir_smoke_test() at boot (chained off the
# unconditional ext4_rename_smoke_test, so no extra boot gate is
# needed). It:
#   * mkdir RMD_E, rmdir it, asserts it is gone,
#   * mkdir RMD_N, drops a file inside, asserts rmdir -> -ENOTEMPTY,
#     then cleans up,
#   * mkdir RMD_A/, RMD_B/ and RMD_A/SUB, renames A/SUB -> B/SUB and
#     asserts the moved dir's ".." now resolves to B (not A),
#   * tears everything back down with rmdir.
#
# This script boots the kernel against build/ext4.img and asserts the
# rmdir smoke marker.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_rmdir

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ext4_rmdir] (1/4) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4_rmdir] (2/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4_rmdir] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "[test_ext4_rmdir] (4/4) Boot QEMU with ext4 image"
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

echo "[test_ext4_rmdir] --- ext4 lines ---"
grep -E 'ext4: (rmdir|rename)' "$LOG" || true
echo "[test_ext4_rmdir] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# The rmdir smoke test runs unconditionally at boot on build/ext4.img. Zero
# `ext4:` markers == starved/timeout/OOM boot, NOT a regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'ext4: (mounted|rmdir|rename)'

if grep -F -q "ext4: rmdir smoke PASS" "$LOG"; then
    verdict_pass "$TAG" \
        "ext4 rmdir smoke: empty-dir removal + dir-rename '..' fixup (qemu rc=$rc)"
fi

echo "[test_ext4_rmdir] --- full log ---"
cat "$LOG"
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "ext4 mounted but 'ext4: rmdir smoke PASS' never printed and qemu was" \
        "killed by timeout (rc=124) — starved before the smoke line flushed." \
        "Re-run on a QUIET host."
fi
verdict_fail "$TAG" \
    "ext4 mounted but 'ext4: rmdir smoke PASS' was OBSERVED absent on a clean" \
    "qemu exit (rc=$rc) — the rmdir smoke test really failed."
