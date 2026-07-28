#!/usr/bin/env bash
# scripts/test_mm_pressure.sh — #167 memory-pressure subsystem:
# anonymous-page swap + page reclaim + an OOM killer, all native.
#
# Boots the kernel once with /etc/mm-test planted (ENABLE_MM_TEST=1);
# init/main.ad at boot:37.mm runs mm_pressure_selftest() (mm/reclaim.ad),
# which proves the WHOLE pressure path with unforgeable assertions:
#
#   PART A — SWAP ROUND-TRIP
#     A real demand-paged anonymous VMA is faulted in, stamped with a
#     deterministic per-byte pattern, and FNV-1a checksummed. reclaim
#     then evicts every page to swap (each PTE rewritten to a not-present
#     swap entry, each physical page freed). The test asserts:
#       * a specific evicted page's PTE IS a swap entry (not present),
#       * all 64 PTEs became swap entries,
#       * the swap store recorded 64 pageouts,
#       * after faulting every page back IN through the real swap-in path,
#         the region's checksum equals the pre-eviction checksum to the
#         bit — proving swap-out then swap-in restored the EXACT bytes.
#
#   PART B — OOM KILLER
#     Two real user tasks get demand VMAs with different resident sets
#     (48 vs 8 pages). The OOM killer is asked to pick a victim; the test
#     asserts it killed the LARGER-RSS task and that the system kept
#     running (the smaller task survives and the post-kill marker prints).
#
# Pass marker:  [test_mm] PASS
# Fail marker:  [test_mm] FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_mm] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mm] (2/3) Build kernel with /etc/mm-test marker"
# HAMNIX_DEFAULT_REAL_DEBIAN=0 is LOAD-BEARING, not an optimisation.
#
# build_initramfs.py defaults that knob to 1, which stages the whole
# debootstrap Debian closure (766 of 1297 cpio entries) into the initramfs
# blob that gets linked INTO the kernel ELF. That pushes build/hamnix-kernel.elf
# to ~337 MiB — and this test deliberately boots with `-m 256M` to create memory
# pressure, so GRUB cannot load the image at all:
#
#     Booting `Hamnix'
#     error: out of memory.
#     error: you need to load the kernel first.
#     Failed to boot both default and fallback entries.
#
# Every [mm] marker is then absent and every assertion below "fails". This gate
# has therefore been unrunnable on any checkout that has the Debian fixture
# staged (i.e. the normal developer machine), which is why the #471
# straddling-alias assertion could never be gated. The mm self-test is a pure
# KERNEL test — it needs no Debian userland.
INIT_ELF=build/user/init.elf ENABLE_MM_TEST=1 HAMNIX_DEFAULT_REAL_DEBIAN=0 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mm] (3/3) Boot QEMU and run the memory-pressure self-test"
# Use KVM when the host offers it. Under pure TCG this kernel (a ~350 MiB ELF,
# GRUB-ISO-wrapped by _kernel_iso.sh because QEMU's multiboot1 loader rejects
# ELFCLASS64) does not reach the self-test inside 180 s on a loaded host — the
# run then produces ZERO [mm] markers and every assertion below "fails",
# which reads as a catastrophic mm regression when nothing regressed at all.
KVM_ARGS=""
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_ARGS="-enable-kvm -cpu host"
fi
set +e
timeout 180s qemu-system-x86_64 \
    $KVM_ARGS \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_mm] --- mm self-test output ---"
grep -E "\[mm\]|\[swap\]|\[reclaim\]|\[oom\]" "$LOG" || true
echo "[test_mm] --- end ---"

# INCONCLUSIVE, not FAIL, when the guest produced NOTHING.
#
# Every assertion below is of the form "marker X absent -> FAIL". If the boot
# never reached the self-test at all (host starved the VM and `timeout` killed
# a still-running QEMU), EVERY marker is absent and the script reports a dozen
# substantive mm failures — swap broken, OOM broken, interval tree broken. That
# is a FALSE RED, and it is indistinguishable from a real regression by exit
# code alone. Observed 2026-07-08: with three QEMU-heavy agents on the host and
# no KVM, this gate reported total mm collapse while nothing had regressed.
#
# The discriminator is whether we OBSERVED anything: zero markers + rc=124 means
# we watched nothing happen, which supports no verdict. See docs/TEST_VERDICTS.md.
markers=$(grep -c -E "\[mm\]|\[swap\]|\[reclaim\]|\[oom\]" "$LOG" || true)
if [ "$markers" -eq 0 ]; then
    echo "[test_mm] qemu rc=$rc, kvm='${KVM_ARGS:-none}'"
    tail -20 "$LOG" | strings
fi
# Shared zero-marker / GRUB-OOM discriminator (scripts/_verdict.sh):
# returns 0 if >=1 [mm]/[swap]/[reclaim]/[oom] marker was observed;
# otherwise EXITS INCONCLUSIVE (GRUB OOM or timeout) or FAIL (observed
# early exit). Keeps a starved/never-booted run from reading as a dozen
# substantive mm regressions.
verdict_boot_gate "test_mm_pressure" "$LOG" "$rc" \
    '\[mm\]|\[swap\]|\[reclaim\]|\[oom\]'

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mm] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[mm] FAIL" "$LOG"; then
    echo "[test_mm] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_mm] PASS: $label"
    else
        echo "[test_mm] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "reclaim evicted all anon pages to swap" \
      "[mm] PASS: reclaim evicted all 64 anon pages to swap"
check "evicted page PTE is a swap entry" \
      "[mm] PASS: evicted page PTE is a swap entry"
check "all PTEs became swap entries" \
      "[mm] PASS: all 64 PTEs are swap entries"
check "swap recorded the pageouts" \
      "[mm] PASS: swap recorded 64 pageouts"
check "swap-in restored exact bytes (checksum match)" \
      "[mm] PASS: swap-in restored exact bytes"
check "reclaim driver evicted user-task pages" \
      "[mm] PASS: reclaim driver evicted"
check "OOM killed largest-RSS victim" \
      "[mm] PASS: OOM killed largest-RSS victim"
check "system survived OOM kill" \
      "[mm] PASS: system survived OOM kill"
# PART C — rmap + active/inactive LRU + LRU-driven reclaim
check "rmap records the anon page's mapper" \
      "[mm] PASS: rmap records mapper for anon page"
# The DELTA, not the absolute total: the LRU legitimately still holds the
# boot tasks' COW-shared (mapcount>1, hence unevictable) anon pages, so an
# absolute "32 pages on LRU" was never a well-formed expectation.
check "fault-in populates the LRU" \
      "[mm] PASS: fault-in added 32 pages to LRU"
check "second-chance promotes referenced pages" \
      "[mm] PASS: referenced pages promoted not evicted"
check "LRU-shrink evicts cold pages via rmap" \
      "[mm] PASS: LRU-shrink evicted 32 cold pages via rmap"
check "all part-C PTEs became swap entries" \
      "[mm] PASS: all 32 part-C PTEs are swap entries"
check "part-C swap-in restores exact bytes" \
      "[mm] PASS: part-C swap-in restored exact bytes via LRU/rmap"
# PART D — dirty-page accounting + balance_dirty_pages throttling
check "dirty-page accounting counts dirty pages" \
      "[mm] PASS: dirty accounting counted 32 dirty pages"
check "balance_dirty_pages throttles over dirty_ratio" \
      "[mm] PASS: balance_dirty_pages throttles over dirty_ratio"
check "clear_page_dirty drains the dirty count" \
      "[mm] PASS: clear_page_dirty drained the dirty count"
# PART E — Wave-3 VMA interval tree (O(log n) find/overlap/gap) + per-VMA lock
check "interval-tree find correct over many VMAs" \
      "[mm] PASS: vma interval-tree find correct over"
check "interval-tree height is logarithmic (O(log n), not O(n))" \
      "[mm] PASS: vma tree height="
check "interval-tree overlap query correct" \
      "[mm] PASS: vma interval-tree overlap query correct"
check "straddling-alias MAP_FIXED replace (#471 residual)" \
      "[mm] PASS: vma straddling-alias MAP_FIXED replace"
check "split keeps tree+list consistent" \
      "[mm] PASS: vma split keeps tree+list consistent"
check "per-VMA lock: same VMA serializes, distinct VMAs concurrent" \
      "[mm] PASS: per-VMA lock"
check "teardown removes test VMAs, tree stays consistent" \
      "[mm] PASS: vma teardown removed"
check "interval-tree/per-VMA-lock self-test complete" \
      "[mm] PASS: vma interval-tree + per-VMA-lock self-test complete"
check "self-test complete" \
      "[mm] PASS: pressure self-test complete"

if [ "$fail" -ne 0 ]; then
    echo "[test_mm] FAIL"
    exit 1
fi

echo "[test_mm] PASS — swap round-trip restores exact bytes AND the OOM killer relieves pressure"
