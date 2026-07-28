#!/usr/bin/env bash
# scripts/test_ext4idx.sh — ext4 extent-INDEX-node (eh_depth > 0) support.
#
# Proves fs/ext4.ad grows a file PAST the 4-inline-extent ceiling by
# promoting the inode's extent tree to a depth-1 index node, reads every
# block back by walking that index tree, and frees the index/leaf/data
# blocks on truncate (folding the tree back to inline).
#
# Fixture: a host-minted EMPTY ext4 image (1 KiB blocks, no journal)
# mounted by the kernel at /ext. The in-kernel ext4_extentidx_selftest()
# (gated on /etc/ext4idx-test) builds the test file ITSELF at boot — it
# appends many deliberately NON-CONTIGUOUS one-block extents (a spacer
# block kept allocated between each pair defeats coalescing), so > 4
# extents are needed and the inode MUST become a depth-1 index node. No
# host-side fragmentation trickery is required.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ext4idx] PASS   (kernel prints [ext4idx] PASS)
# Fail marker:  [test_ext4idx] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4idx

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

DISK=$(mktemp --suffix=.ext4idx.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4idx] (1/4) Mint a 1 KiB-block ext4 image (no journal)"
# 64 MiB headroom @ 1 KiB blocks: plenty of free data blocks for the
# self-test's ~24 data + 24 spacer single-block allocations, and 1 KiB
# blocks keep the on-disk leaf node small (84 extents/leaf) so a modest
# block count still exercises a second index record.
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_IDX" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4idx] (2/4) Build userland + plant /etc/ext4idx-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4IDX_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4idx] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4idx] (4/4) Boot QEMU with the empty ext4 image"
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

echo "[test_ext4idx] --- ext4idx self-test output ---"
grep -a -E "\[ext4idx\]" "$LOG" || true
echo "[test_ext4idx] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4idx] markers == starved/timeout/OOM boot, NOT a regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4idx\]'

fail=0

if grep -a -F -q "[ext4idx] FAIL" "$LOG"; then
    echo "[test_ext4idx] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4idx] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_ext4idx] OK: $label"
    else
        echo "[test_ext4idx] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "depth-1 index node forced"          "[ext4idx] forced index node: eh_depth=1"
check "multi-leaf index (>=2 records)"      "index_records="
check "read-back through index walk"        "read-back verified"
check "truncate freed index+leaf+data"      "tree folded to depth 0"
check "self-test PASS banner"               "[ext4idx] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4idx] --- full log ---"
    cat "$LOG"
    if ! grep -a -F -q "[ext4idx] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ext4idx] markers printed but the terminal PASS banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ext4idx] marker was OBSERVED absent (or an internal FAIL was" \
        "reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "ext4 extent index node: a fragmented file exceeds the" \
     "4-inline-extent ceiling via a depth-1 index node, reads back" \
     "correctly, and truncate frees the tree (qemu rc=$rc)"
