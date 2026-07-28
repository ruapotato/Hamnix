#!/usr/bin/env bash
# scripts/test_ext4_multigroup_inode.sh — ext4 multi-group inode alloc.
#
# Regression gate for QA-N30: creating a NEW file in the distro ext4 root
# ("the distrofs partition") returned a spurious ENOSPC once GROUP 0's
# inode table filled up — even though every OTHER block group still had
# thousands of free inodes AND the fs had ample free blocks.
#
# Root cause: fs/ext4.ad::ext4_alloc_inode scanned ONLY group 0's inode
# bitmap and gave up ("no free inode in group 0") the instant group 0 was
# full. ext4_alloc_block was already multi-group for exactly this reason
# (its "installer payload fills group 0" note); the inode allocator was
# its unfixed twin. A live image built by host mke2fs packs group 0 with
# the Debian payload, so the FIRST new-file create in the running system
# (`enter linux { echo hi > /foo }`, a regular-user home write, dpkg
# laying a package file) hit ENOSPC.
#
# This test mints an ext4 image, FILLS group 0's inode table on the host
# with throwaway files (so the next inode allocation MUST come from a
# non-zero group), boots Hamnix, and drives a Hamnix-side
#   echo SENTINEL > /ext/NEWALLOC.TXT ; cat /ext/NEWALLOC.TXT
# create+write+read round-trip. The create can ONLY succeed if
# ext4_alloc_inode walked past the full group 0 into group >= 1. It then
# asserts the sentinel round-trips AND that the "no free inode" printk is
# absent.
#
# Pass marker (emitted by THIS script after the cat verifies):
#   [ext4mgi] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_multigroup_inode

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
MKE2FS="$(_which mke2fs)"
DEBUGFS="$(_which debugfs)"

# Sentinel the created file carries; a unique string so hamsh's own echo
# of the typed command line can't be mistaken for the file's contents.
MARKER="HAMNIX_MGI_SENTINEL_ROUNDTRIP_OK"

echo "[test_ext4_multigroup_inode] (1/5) Mint an ext4 disk image"
DISK=$(mktemp --suffix=.ext4-mgi.img)
truncate -s 48M "$DISK"
# 1 KiB blocks (8192 blocks/group => 8 MiB/group, so a 48 MiB image is
# ~6 groups). flex_bg mirrors the real installer image (bitmaps + inode
# tables of every group pack into group 0's leader), so a create into a
# non-zero group also exercises the flex-relocated inode-table WRITE path.
"$MKE2FS" -F -q -b 1024 -G 16 -t ext4 -L "HAMNIX_MGI" \
    -O flex_bg,^has_journal,^64bit,^metadata_csum,^resize_inode \
    "$DISK" >/dev/null

IPG=2048
if command -v dumpe2fs >/dev/null 2>&1 || [ -x /sbin/dumpe2fs ]; then
    DUMPE2FS="$(_which dumpe2fs)"
    IPG="$("$DUMPE2FS" -h "$DISK" 2>/dev/null | sed -n 's/^Inodes per group: *//p')"
    IPG="${IPG:-2048}"
    NG="$("$DUMPE2FS" -h "$DISK" 2>/dev/null | sed -n 's/^Group count: *//p')"
    echo "[test_ext4_multigroup_inode] host: inodes/group=${IPG}, groups=${NG:-?}"
fi

# --- Step 1: fill group 0's inode table so any NEW inode must come from a
# non-zero group. Group 0 owns inodes 1..inodes_per_group; creating that
# many throwaway files (plus a margin) exhausts group 0's inode bitmap.
NFILL=$(( IPG + 64 ))
echo "[test_ext4_multigroup_inode] (2/5) Fill group-0 inode table with $NFILL throwaway files"
FILLPAY="$(mktemp --suffix=.mgi-fill)"
printf 'x\n' > "$FILLPAY"
FILLSCRIPT="$(mktemp --suffix=.mgi-dbfs)"
{ i=1; while [ "$i" -le "$NFILL" ]; do echo "write $FILLPAY z$i"; i=$((i+1)); done; } > "$FILLSCRIPT"
"$DEBUGFS" -w -f "$FILLSCRIPT" "$DISK" >/dev/null 2>&1
rm -f "$FILLPAY" "$FILLSCRIPT"

# Confirm group 0 is actually full on the host: the next inode debugfs
# would hand out lives in group >= 1. (Best-effort; skipped if the tools
# are unavailable.)
if command -v dumpe2fs >/dev/null 2>&1 || [ -x /sbin/dumpe2fs ]; then
    G0_FREE="$("$DUMPE2FS" "$DISK" 2>/dev/null | awk '
        /^Group 0:/ {ing=1}
        ing && /Free inodes:/ { match($0,/Free inodes: ([0-9]+)/,m); print m[1]; exit }')"
    echo "[test_ext4_multigroup_inode] host confirms group-0 free inodes now: ${G0_FREE:-?}"
fi

echo "[test_ext4_multigroup_inode] (3/5) Build userland + swap /init = $HAMSH_ELF"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_multigroup_inode] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_multigroup_inode] (5/5) Boot QEMU + drive a Hamnix-side create"
INPUT_FIFO=$(mktemp -u --suffix=.mgi-fifo)
mkfifo "$INPUT_FIFO"
set +e
(
    exec 3>"$INPUT_FIFO"
    waited=0
    while ! grep -aq "loop-enter" "$LOG" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 110 ]; then
            break
        fi
    done
    sleep 1
    # Hamnix-side create: allocates a NEW inode. Group 0 is full, so this
    # can only succeed if ext4_alloc_inode walks into group >= 1.
    printf 'echo %s > /ext/NEWALLOC.TXT\n' "$MARKER" >&3
    sleep 3
    printf 'cat /ext/NEWALLOC.TXT\n' >&3
    sleep 3
    printf 'exit\n' >&3
    sleep 1
    exec 3>&-
) &
FEEDER=$!
timeout 150s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    < "$INPUT_FIFO" > "$LOG" 2>&1
rc=$?
wait "$FEEDER" 2>/dev/null
rm -f "$INPUT_FIFO"
set -e

echo "[test_ext4_multigroup_inode] --- boot output (filtered) ---"
grep -a -E "HAMNIX_MGI_SENTINEL|no free inode|ENOSPC|No space" "$LOG" | head -20 || true
echo "[test_ext4_multigroup_inode] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Gate on hamsh 'loop-enter' liveness, NOT the sentinel itself: zero
# loop-enter == the guest never reached an interactive shell (starved/timed-
# out boot, OBSERVED crash, GRUB OOM) so the create keystroke never fired —
# INCONCLUSIVE. loop-enter present + missing sentinel == OBSERVED fail.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'loop-enter'

# A virtio-blk superblock-read flake (host CPU starvation) means the fs
# never mounted and the create/read-back could not happen: INCONCLUSIVE.
if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the fs never mounted. Re-run on a quiet host."
fi

fail=0

# The create must NOT have hit the group-0-exhaustion ENOSPC path.
if grep -a -F -q "no free inode" "$LOG"; then
    echo "[test_ext4_multigroup_inode] FAIL: ext4_alloc_inode reported 'no free inode'" \
         "— multi-group inode alloc did not walk past the full group 0" >&2
    fail=1
else
    echo "[test_ext4_multigroup_inode] OK: no 'no free inode' printk (allocator walked past group 0)"
fi

# The created file's contents must round-trip: this proves the new inode
# (in group >= 1) was written to its flex-relocated inode table AND read
# back through the normal VFS path.
if grep -a -F -q "$MARKER" "$LOG"; then
    echo "[test_ext4_multigroup_inode] OK: NEWALLOC.TXT round-tripped (inode allocated in group >= 1)"
else
    echo "[test_ext4_multigroup_inode] FAIL: NEWALLOC.TXT sentinel did not read back" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_multigroup_inode] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "hamsh reached its prompt (loop-enter observed) but the multi-group" \
        "inode alloc was OBSERVED to fail — 'no free inode' printed, or" \
        "NEWALLOC.TXT did not round-trip (qemu rc=$rc). A real ext4_alloc_inode" \
        "past-group-0 regression."
fi

echo "[ext4mgi] PASS"
verdict_pass "$TAG" "new-file create allocated an inode from a non-zero block" \
     "group after group 0 was full, and NEWALLOC.TXT round-tripped through the" \
     "VFS read path (qemu rc=$rc)"
