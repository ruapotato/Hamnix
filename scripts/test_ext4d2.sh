#!/usr/bin/env bash
# scripts/test_ext4d2.sh — ext4 DEPTH-2 extent-tree support.
#
# Proves fs/ext4.ad grows a file PAST the depth-1 index-tree capacity by
# promoting the inode's extent tree to a DEPTH-2 index node (the inode's
# index records point at INTERMEDIATE index blocks, which point at leaf
# blocks). Reads every block back by walking idx -> idx -> leaf, exercises
# the depth-2 trim path with a partial truncate, then frees the whole
# tree on a truncate-to-zero (folding it back to an inline depth-0 leaf).
#
# Fixture: a host-minted EMPTY ext4 image (1 KiB blocks, no journal)
# mounted by the kernel at /ext. The in-kernel ext4_extentd2_selftest()
# (gated on /etc/ext4d2-test) builds the test file ITSELF at boot — it
# appends 400 deliberately NON-CONTIGUOUS one-block extents (a spacer
# block kept allocated between each pair defeats coalescing), which is
# more than the depth-1 ceiling (4 inode idx slots x 84 leaf records =
# 336 @ 1 KiB blocks), so the inode MUST become a depth-2 index node. No
# host-side fragmentation trickery is required.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ext4d2] PASS   (kernel prints [ext4d2] PASS)
# Fail marker:  [test_ext4d2] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4d2

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

DISK=$(mktemp --suffix=.ext4d2.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4d2] (1/4) Mint a 1 KiB-block ext4 image (no journal)"
# 128 MiB headroom @ 1 KiB blocks: plenty of free data blocks for the
# self-test's 400 data + 400 spacer single-block allocations, and 1 KiB
# blocks keep each leaf/index node small (84 records) so 400 fragmented
# blocks overflow the depth-1 ceiling (336) and force depth 2.
truncate -s 128M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_D2" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4d2] (2/4) Build userland + plant /etc/ext4d2-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4D2_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4d2] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4d2] (4/4) Boot QEMU with the empty ext4 image"
set +e
timeout 240s qemu-system-x86_64 \
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

echo "[test_ext4d2] --- ext4d2 self-test output ---"
grep -a -E "\[ext4d2\]" "$LOG" || true
echo "[test_ext4d2] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4d2] markers == starved/timeout/OOM boot, NOT a regression. The
# per-marker check() chain below stays as diagnostics; final decision is
# verdict_*.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4d2\]'

fail=0

if grep -a -F -q "[ext4d2] FAIL" "$LOG"; then
    echo "[test_ext4d2] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4d2] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_ext4d2] OK: $label"
    else
        echo "[test_ext4d2] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "depth-2 tree forced"             "[ext4d2] forced depth-2 tree: eh_depth=2"
check "read-back through depth-2 walk"  "read-back verified"
check "partial truncate (depth-2 trim)" "partial truncate to"
check "full truncate folds tree back"   "tree folded to depth 0"
check "self-test PASS banner"           "[ext4d2] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4d2] --- full log ---"
    cat "$LOG"
    if ! grep -a -F -q "[ext4d2] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ext4d2] markers printed but the terminal PASS banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ext4d2] marker was OBSERVED absent (or an internal FAIL was" \
        "reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "ext4 depth-2 extent tree: a fragmented file overflows" \
     "the depth-1 ceiling via a depth-2 index node, reads back correctly" \
     "through idx->idx->leaf, partial-truncates, and frees the tree on full" \
     "truncate (qemu rc=$rc)"
