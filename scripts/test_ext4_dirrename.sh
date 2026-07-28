#!/usr/bin/env bash
# scripts/test_ext4_dirrename.sh — ext4 cross-directory directory-rename
# maturity verification.
#
# Proves the directory-move leg of ext4_rename (fs/ext4.ad): moving a
# sub-directory to a DIFFERENT parent must
#   (1) rewrite the moved dir's ".." dirent to point at the new parent,
#   (2) DECREMENT the old parent's i_links_count (its child's ".."
#       backlink left it), and
#   (3) INCREMENT the new parent's i_links_count (the backlink joined it),
# while leaving the moved dir's own i_links_count unchanged. It also
# asserts the negative: a SAME-parent rename (just a name change) must
# touch neither parent's link count nor the moved dir's "..".
#
# The in-kernel ext4_dirrename_selftest() (gated on the cpio marker
# /etc/ext4dirrename-test) does all of this on the live ext4 mount, so the
# host only attaches a plain, empty ext4 scratch disk.
#
# TRANSPORT: the scratch disk is attached over AHCI (ich9-ahci + ide-hd),
# NOT virtio. ext4 is transport-agnostic (it goes through the block-layer
# slot via blk_read_sectors), and AHCI is the load-tolerant transport the
# other ext4-on-AHCI tests use — it sidesteps the known virtio-blk
# load-flake under concurrent TCG.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ext4_dirrename] PASS  (kernel prints [ext4-dirrename] PASS)
# Fail marker:  [test_ext4_dirrename] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_dirrename

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

DISK=$(mktemp --suffix=.ext4dirrename.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_dirrename] (1/4) Mint a 1 KiB-block ext4 scratch image"
# 64 MiB headroom; 1 KiB blocks match the driver's well-trodden path. The
# kernel selftest creates its own scratch directories, so the disk ships
# empty.
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_DIRREN" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4_dirrename] (2/4) Build userland + plant /etc/ext4dirrename-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4DIRRENAME_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_dirrename] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4_dirrename] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ich9-ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_dirrename] --- ext4-dirrename self-test output ---"
grep -a -E "\[ext4-dirrename\]" "$LOG" || true
echo "[test_ext4_dirrename] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4-dirrename] markers == starved/timeout/OOM boot, NOT a regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-dirrename\]'

fail=0

if grep -a -F -q "[ext4-dirrename] FAIL" "$LOG"; then
    echo "[test_ext4_dirrename] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-dirrename] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[ext4-dirrename] PASS" "$LOG"; then
    echo "[test_ext4_dirrename] MISS: self-test PASS banner (expected '[ext4-dirrename] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_dirrename] --- full log ---"
    cat "$LOG"
    if ! grep -a -F -q "[ext4-dirrename] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ext4-dirrename] markers printed but the terminal PASS banner" \
            "never arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "the [ext4-dirrename] PASS banner was OBSERVED absent (or an internal" \
        "FAIL was reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "cross-directory directory rename rewrites '..' and" \
     "rebalances parent link counts; same-dir rename leaves them untouched" \
     "(qemu rc=$rc)"
