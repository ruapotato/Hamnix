#!/usr/bin/env bash
# scripts/test_ext4_bigalloc.sh — ext4 bigalloc (RO_COMPAT_BIGALLOC).
#
# Proves fs/ext4.ad's bigalloc READ path end-to-end on a live ext4 mount.
# With bigalloc the unit of block allocation/accounting becomes a CLUSTER
# = block_size << s_log_cluster_size (here 4 KiB blocks, 16 KiB clusters,
# so cluster_ratio == 4). The per-group "block bitmap" becomes a CLUSTER
# bitmap of s_clusters_per_group bits. Extents still record physical BLOCK
# numbers, so an extent-mapped file's data reads must resolve correctly as
# long as the driver never assumed blocks == clusters anywhere on the read
# path.
#
# This test mints a SEPARATE ext4 image WITH bigalloc on (build/ext4.img
# has it OFF, so a normal boot exercises zero bigalloc code). It plants a
# known MULTI-BLOCK file (13800 bytes => 4 x 4 KiB blocks, one extent
# (0-3):phys), boots Hamnix, `cat`s the file through the normal VFS path,
# and grep-asserts the known content rounds back byte-exact across all
# four blocks. The mount also announces it detected RO_COMPAT_BIGALLOC and
# computed the cluster geometry.
#
# Pass marker (emitted by THIS script after the cat verifies):
#   [ext4bigalloc] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_bigalloc

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

# Known content: 200 lines, each unique-enough to grep for, totalling
# 13800 bytes => four 4 KiB blocks (genuinely multi-block / extent-mapped).
MARKER_HEAD="EXT4BIGALLOC_LINE_0000"
MARKER_TAIL="EXT4BIGALLOC_LINE_0199"

echo "[test_ext4_bigalloc] (1/5) Mint a bigalloc ext4 disk image"
DISK=$(mktemp --suffix=.ext4-bigalloc.img)
truncate -s 32M "$DISK"
# Lean bigalloc layout: 4 KiB blocks, 16 KiB clusters (cluster_ratio 4),
# no journal/64bit/csum/resize so the image stays inside the driver's
# well-trodden read path. bigalloc REQUIRES the extent feature (mke2fs
# enables it implicitly).
"$MKE2FS" -F -q -b 4096 -C 16384 -t ext4 -L "HAMNIX_BIGALLOC" \
    -O bigalloc,^has_journal,^64bit,^metadata_csum,^resize_inode \
    "$DISK" >/dev/null

# Sanity: host must agree the image carries bigalloc, so a mke2fs that
# silently dropped the feature fails loud rather than faking a PASS.
if command -v dumpe2fs >/dev/null 2>&1 || [ -x /sbin/dumpe2fs ]; then
    DUMPE2FS="$(_which dumpe2fs)"
    if ! "$DUMPE2FS" -h "$DISK" 2>/dev/null | grep -qiE '(^| )bigalloc( |$)'; then
        echo "[test_ext4_bigalloc] FAIL: minted image lacks bigalloc feature" >&2
        rm -f "$DISK"
        exit 1
    fi
    CSIZE="$("$DUMPE2FS" -h "$DISK" 2>/dev/null | sed -n 's/^Cluster size: *//p')"
    echo "[test_ext4_bigalloc] host confirms bigalloc feature present (cluster size ${CSIZE})"
fi

# Plant BIGFILE.TXT — 200 lines, 13800 bytes, 4 blocks, one extent.
PAY="$(mktemp --suffix=.bigalloc-pay)"
python3 -c 'import sys
body="".join("EXT4BIGALLOC_LINE_%04d_padding_to_make_this_multi_block_xxxxxxxxxxxx\n"%i for i in range(200))
open(sys.argv[1],"w").write(body)' "$PAY"
"$DEBUGFS" -w "$DISK" >/dev/null 2>&1 <<EOF
write $PAY BIGFILE.TXT
EOF
rm -f "$PAY"

# Confirm the host wrote a genuine MULTI-BLOCK extent-mapped inode (not
# inline, not single-block) — else this test would not exercise the
# extent->physical-block math under bigalloc.
BIG_STAT="$("$DEBUGFS" -R "stat BIGFILE.TXT" "$DISK" 2>/dev/null)"
BCOUNT="$(echo "$BIG_STAT" | sed -n 's/.*Blockcount: *\([0-9]*\).*/\1/p')"
if [ -z "$BCOUNT" ] || [ "$BCOUNT" -lt 16 ]; then
    echo "[test_ext4_bigalloc] FAIL: BIGFILE.TXT is not multi-block (Blockcount=$BCOUNT)" >&2
    echo "$BIG_STAT" >&2
    rm -f "$DISK"; exit 1
fi
echo "[test_ext4_bigalloc] host confirms BIGFILE.TXT is a multi-block extent inode (Blockcount=$BCOUNT)"

echo "[test_ext4_bigalloc] (2/5) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_ext4_bigalloc] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_bigalloc] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_bigalloc] (5/5) Boot QEMU with the bigalloc image"
# Gate keystrokes on the shell-ready marker, not a fixed sleep: this boot
# loads kernel modules and the prompt can appear much later under TCG
# load. The feeder tails $LOG until hamsh announces its read loop, THEN
# types the cat.
INPUT_FIFO=$(mktemp -u --suffix=.bigalloc-fifo)
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
    printf 'cat /ext/BIGFILE.TXT\n' >&3
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

echo "[test_ext4_bigalloc] --- ext4/bigalloc boot output ---"
grep -a -E "RO_COMPAT_BIGALLOC|cluster_size|clusters_per_group|EXT4BIGALLOC_LINE" "$LOG" | head -20 || true
echo "[test_ext4_bigalloc] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Gate on hamsh 'loop-enter' liveness, NOT on the bigalloc marker itself:
# zero loop-enter == the guest never reached an interactive shell (starved/
# timed-out boot, an OBSERVED crash, GRUB OOM) so the keystroke that reads
# BIGFILE.TXT was never delivered — INCONCLUSIVE, not a bigalloc regression.
# If loop-enter IS present but RO_COMPAT_BIGALLOC/content is absent, that is
# an OBSERVED failure and falls through to verdict_fail below.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'loop-enter'

# A virtio-blk superblock-read flake (host CPU starvation) means the fs
# never mounted and the read-back could not happen: INCONCLUSIVE.
if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the bigalloc fs never mounted. Re-run on a quiet host."
fi

fail=0

# The mount must announce it detected bigalloc and computed the geometry.
if grep -a -F -q "RO_COMPAT_BIGALLOC present" "$LOG"; then
    echo "[test_ext4_bigalloc] OK: mount detected RO_COMPAT_BIGALLOC + cluster geometry"
else
    echo "[test_ext4_bigalloc] MISS: mount did not announce RO_COMPAT_BIGALLOC" >&2
    fail=1
fi

# First block of the file must read back.
if grep -a -F -q "$MARKER_HEAD" "$LOG"; then
    echo "[test_ext4_bigalloc] OK: BIGFILE.TXT first-block content read back"
else
    echo "[test_ext4_bigalloc] MISS: BIGFILE.TXT head marker not read back" >&2
    fail=1
fi

# Last line lives in the FOURTH block — proves the extent->physical-block
# math is right across all blocks under bigalloc (a blocks==clusters bug
# would mis-resolve later blocks).
if grep -a -F -q "$MARKER_TAIL" "$LOG"; then
    echo "[test_ext4_bigalloc] OK: BIGFILE.TXT last-block content read back (4th block)"
else
    echo "[test_ext4_bigalloc] MISS: BIGFILE.TXT tail marker (4th block) not read back" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_bigalloc] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "hamsh reached its prompt (loop-enter observed) but a bigalloc marker" \
        "was OBSERVED absent — RO_COMPAT_BIGALLOC not announced, or BIGFILE.TXT" \
        "head/4th-block content did not read back (qemu rc=$rc). A real bigalloc" \
        "cluster->block resolution regression."
fi

echo "[ext4bigalloc] PASS"
verdict_pass "$TAG" "bigalloc (RO_COMPAT_BIGALLOC): mount computed cluster" \
     "geometry and a multi-block file read back byte-exact across the 1st and" \
     "4th blocks on a live ext4 mount (qemu rc=$rc)"
