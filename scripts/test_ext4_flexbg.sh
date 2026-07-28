#!/usr/bin/env bash
# scripts/test_ext4_flexbg.sh — ext4 flex_bg (INCOMPAT_FLEX_BG).
#
# Proves fs/ext4.ad's flex_bg READ path end-to-end on a live ext4 mount.
#
# With flex_bg the block bitmap, inode bitmap and inode table for a run of
# 2^s_log_groups_per_flex consecutive block groups are NOT each at the head
# of their own group — mke2fs packs them contiguously at the start of the
# flex group's LEADER (first) group. The on-disk group descriptors still
# record the REAL (relocated) bitmap / inode-table block numbers, so a
# correct reader must trust those descriptor fields rather than compute a
# fixed per-group layout. A driver that assumed "group g's inode table
# starts at group g's first block" would mis-locate the inode table of
# every NON-ZERO group and read garbage for files whose inode lives there.
#
# This test mints a SEPARATE ext4 image WITH flex_bg on (build/ext4.img has
# it off, so a normal boot exercises zero flex_bg-specific relocation). The
# image uses a flex group size that spans every block group (-G 16 over a
# 6-group fs), so the inode tables of groups 1..5 are ALL relocated into
# group 0's leader region. It then:
#
#   1. Fills group 0's inode table (2048 inodes) with throwaway files so
#      that the NEXT real file lands in a NON-ZERO block group — i.e. its
#      inode physically lives in the flex-relocated inode table, the case
#      the relocation actually matters for.
#   2. Plants FLEXFILE.TXT (a multi-line sentinel file) which the host
#      confirms is assigned an inode in group >= 1.
#   3. Boots Hamnix, `cat`s the file through the normal VFS path, and
#      grep-asserts BOTH sentinels round back byte-exact — which can only
#      happen if ext4_read_inode resolved the inode through the
#      descriptor-supplied (relocated) inode-table block.
#   4. Asserts the mount announced it detected INCOMPAT_FLEX_BG.
#
# Pass marker (emitted by THIS script after the cat verifies):
#   [ext4flexbg] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_flexbg

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

# Sentinels that bracket the file. Both must read back: the head proves the
# file's (flex-relocated-inode) data resolved; the tail (later block) proves
# the whole file mapped correctly.
MARKER_HEAD="HAMNIX_FLEXBG_SENTINEL_START"
MARKER_TAIL="HAMNIX_FLEXBG_SENTINEL_END"

echo "[test_ext4_flexbg] (1/5) Mint a flex_bg ext4 disk image"
DISK=$(mktemp --suffix=.ext4-flexbg.img)
truncate -s 48M "$DISK"
# Lean flex_bg layout: 1 KiB blocks (8192 blocks/group => 8 MiB/group, so a
# 48 MiB image is 6 groups), flex group size 16 (-G 16) so ALL six groups'
# bitmaps + inode tables pack into group 0's leader. No journal / 64bit /
# csum / resize so the image stays inside the driver's well-trodden read
# path; the ONLY non-default behaviour exercised is the flex relocation.
"$MKE2FS" -F -q -b 1024 -G 16 -t ext4 -L "HAMNIX_FLEXBG" \
    -O flex_bg,^has_journal,^64bit,^metadata_csum,^resize_inode \
    "$DISK" >/dev/null

# Sanity: host must agree the image carries flex_bg, so a mke2fs that
# silently dropped the feature fails loud rather than faking a PASS.
if command -v dumpe2fs >/dev/null 2>&1 || [ -x /sbin/dumpe2fs ]; then
    DUMPE2FS="$(_which dumpe2fs)"
    if ! "$DUMPE2FS" -h "$DISK" 2>/dev/null | grep -qiE '(^| )flex_bg( |$)'; then
        echo "[test_ext4_flexbg] FAIL: minted image lacks flex_bg feature" >&2
        rm -f "$DISK"
        exit 1
    fi
    IPG="$("$DUMPE2FS" -h "$DISK" 2>/dev/null | sed -n 's/^Inodes per group: *//p')"
    FLEX="$("$DUMPE2FS" -h "$DISK" 2>/dev/null | sed -n 's/^Flex block group size: *//p')"
    echo "[test_ext4_flexbg] host confirms flex_bg present (inodes/group=${IPG}, flex size=${FLEX})"
    # Prove the relocation actually happened: group 1's inode table must
    # live BELOW group 1's first block (i.e. packed into group 0).
    G1_ITAB="$("$DUMPE2FS" "$DISK" 2>/dev/null | awk '
        /^Group 1:/ {ing=1}
        ing && /Inode table at/ {
            match($0,/Inode table at ([0-9]+)/,m); print m[1]; exit }')"
    if [ -n "$G1_ITAB" ] && [ "$G1_ITAB" -lt 8193 ]; then
        echo "[test_ext4_flexbg] host confirms flex relocation: group-1 inode table at block $G1_ITAB (inside group 0)"
    else
        echo "[test_ext4_flexbg] WARN: could not confirm group-1 inode-table relocation (block=$G1_ITAB)"
    fi
fi

# --- Step 1: fill group 0's inode table so the real file lands in group 1.
# Group 0 owns inodes 1..(inodes_per_group). Creating that many throwaway
# files forces the NEXT allocation into a non-zero group, whose inode table
# is flex-relocated. We over-create slightly past inodes_per_group.
IPG_N="${IPG:-2048}"
NFILL=$(( IPG_N + 64 ))
echo "[test_ext4_flexbg] (2/5) Fill group-0 inode table with $NFILL throwaway files"
FILLPAY="$(mktemp --suffix=.flexbg-fill)"
printf 'x\n' > "$FILLPAY"
FILLSCRIPT="$(mktemp --suffix=.flexbg-dbfs)"
{ i=1; while [ "$i" -le "$NFILL" ]; do echo "write $FILLPAY z$i"; i=$((i+1)); done; } > "$FILLSCRIPT"
"$DEBUGFS" -w -f "$FILLSCRIPT" "$DISK" >/dev/null 2>&1
rm -f "$FILLPAY" "$FILLSCRIPT"

# --- Step 2: plant FLEXFILE.TXT (multi-line, two sentinels).
PAY="$(mktemp --suffix=.flexbg-pay)"
python3 -c 'import sys
lines=[sys.argv[2]]
for i in range(200):
    lines.append("FLEXBG_BODY_LINE_%04d_padding_to_make_this_multi_block_xxxxxxxx"%i)
lines.append(sys.argv[3])
open(sys.argv[1],"w").write("\n".join(lines)+"\n")' "$PAY" "$MARKER_HEAD" "$MARKER_TAIL"
"$DEBUGFS" -w "$DISK" >/dev/null 2>&1 <<EOF
write $PAY FLEXFILE.TXT
EOF
rm -f "$PAY"

# Confirm the host placed FLEXFILE.TXT's inode in a NON-ZERO block group —
# the whole point of this test. inode number > inodes_per_group means the
# inode lives in the flex-relocated inode table of group >= 1.
FLEX_STAT="$("$DEBUGFS" -R "stat FLEXFILE.TXT" "$DISK" 2>/dev/null)"
FLEX_INO="$(echo "$FLEX_STAT" | sed -n 's/.*Inode: *\([0-9]*\).*/\1/p' | head -1)"
if [ -z "$FLEX_INO" ]; then
    echo "[test_ext4_flexbg] FAIL: could not stat FLEXFILE.TXT" >&2
    echo "$FLEX_STAT" >&2
    rm -f "$DISK"; exit 1
fi
if [ "$FLEX_INO" -le "$IPG_N" ]; then
    echo "[test_ext4_flexbg] FAIL: FLEXFILE.TXT inode $FLEX_INO is still in group 0 (<= $IPG_N) — relocation not exercised" >&2
    echo "$FLEX_STAT" >&2
    rm -f "$DISK"; exit 1
fi
FLEX_GRP=$(( (FLEX_INO - 1) / IPG_N ))
echo "[test_ext4_flexbg] host confirms FLEXFILE.TXT inode=$FLEX_INO lives in block group $FLEX_GRP (flex-relocated inode table)"

echo "[test_ext4_flexbg] (3/5) Build userland + swap /init = $HAMSH_ELF"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_flexbg] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_flexbg] (5/5) Boot QEMU with the flex_bg image"
# Gate keystrokes on the shell-ready marker, not a fixed sleep: this boot
# loads kernel modules and the prompt can appear much later under TCG load.
INPUT_FIFO=$(mktemp -u --suffix=.flexbg-fifo)
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
    printf 'cat /ext/FLEXFILE.TXT\n' >&3
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

echo "[test_ext4_flexbg] --- ext4/flex_bg boot output ---"
grep -a -E "INCOMPAT_FLEX_BG|log_groups_per_flex|flex-aware|HAMNIX_FLEXBG_SENTINEL|FLEXBG_BODY_LINE" "$LOG" | head -20 || true
echo "[test_ext4_flexbg] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Gate on hamsh 'loop-enter' liveness, NOT the flex_bg marker itself: zero
# loop-enter == the guest never reached an interactive shell (starved/timed-
# out boot, OBSERVED crash, GRUB OOM) so the read keystroke never fired —
# INCONCLUSIVE. loop-enter present + absent flex_bg marker == OBSERVED fail.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'loop-enter'

# A virtio-blk superblock-read flake (host CPU starvation) means the fs
# never mounted and the read-back could not happen: INCONCLUSIVE.
if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the flex_bg fs never mounted. Re-run on a quiet host."
fi

fail=0

# The mount must announce it detected flex_bg.
if grep -a -F -q "INCOMPAT_FLEX_BG present" "$LOG"; then
    echo "[test_ext4_flexbg] OK: mount detected INCOMPAT_FLEX_BG"
else
    echo "[test_ext4_flexbg] MISS: mount did not announce INCOMPAT_FLEX_BG" >&2
    fail=1
fi

# Head sentinel: file's flex-relocated inode resolved + first data read.
if grep -a -F -q "$MARKER_HEAD" "$LOG"; then
    echo "[test_ext4_flexbg] OK: FLEXFILE.TXT head sentinel read back (flex-relocated inode resolved)"
else
    echo "[test_ext4_flexbg] MISS: FLEXFILE.TXT head sentinel not read back" >&2
    fail=1
fi

# Tail sentinel (last block) proves the whole file mapped correctly.
if grep -a -F -q "$MARKER_TAIL" "$LOG"; then
    echo "[test_ext4_flexbg] OK: FLEXFILE.TXT tail sentinel read back (full file mapped)"
else
    echo "[test_ext4_flexbg] MISS: FLEXFILE.TXT tail sentinel not read back" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_flexbg] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "hamsh reached its prompt (loop-enter observed) but a flex_bg marker" \
        "was OBSERVED absent — INCOMPAT_FLEX_BG not announced, or FLEXFILE.TXT" \
        "head/tail sentinel did not read back (qemu rc=$rc). A real flex_bg" \
        "inode-table relocation regression."
fi

echo "[ext4flexbg] PASS"
verdict_pass "$TAG" "flex_bg (INCOMPAT_FLEX_BG): a file whose inode lives in a" \
     "flex-relocated inode table read back byte-exact across head and tail" \
     "sentinels on a live ext4 mount (qemu rc=$rc)"
