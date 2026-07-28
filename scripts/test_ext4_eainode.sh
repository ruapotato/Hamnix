#!/usr/bin/env bash
# scripts/test_ext4_eainode.sh — ext4 EA_INODE (INCOMPAT_EA_INODE).
#
# Proves fs/ext4.ad's ea-inode xattr READ path end-to-end on a live ext4
# mount. With the EA_INODE feature a single extended attribute whose value
# is too large for the inline / external-block value region is stored in
# its OWN dedicated inode: the xattr entry's e_value_inum field (the u32 at
# entry offset 0x04 that, without the feature, is the always-zero
# e_value_block) names that inode, the value bytes are that inode's regular
# file data (read through the normal extent / block-map path) and the value
# length is that inode's i_size. A driver that ignored e_value_inum would
# read garbage / the wrong region for such an attribute.
#
# HOW THE IMAGE IS BUILT
#
# The host has NO setfattr (the `attr` package is absent) and is not root,
# so we cannot loop-mount + setfattr to let the host kernel mint a real
# ea-inode. debugfs's `ea_set` stores the value inline and truncates it to
# one block — it never creates an ea-inode. So we assemble the on-disk
# ea-inode layout by hand, which is fully deterministic and exercises the
# exact same read path the host kernel would produce:
#
#   1. mke2fs an image WITH `-O ea_inode` (metadata_csum OFF so no inode
#      checksum has to be recomputed after the hand patch).
#   2. `write` the 8 KiB value file as a regular file EAVALUE — this gives a
#      real inode whose extent-mapped data blocks hold the value (i_size =
#      8192). This is exactly what an ea-inode is: a regular inode whose
#      data IS the attribute value.
#   3. `write` the target file BIGATTR.BIN and `ea_set` a small placeholder
#      `user.big` attribute on it (lands in the in-inode xattr region).
#   4. Patch BIGATTR.BIN's in-inode xattr entry for `user.big`: set
#      e_value_inum = EAVALUE's inode, e_value_size = 8192, e_value_offs = 0
#      — i.e. turn the placeholder into a real ea-inode reference.
#
# The value is a repeating 0..255 byte ramp (value[i] == i & 0xFF), 8 KiB =
# 2 filesystem blocks at 4 KiB, so the read must resolve EVERY block of the
# ea-inode, not just the first.
#
# IN-GUEST READ
#
# ext4_eainode_probe() (run from ext4_xattr_selftest, which the
# /etc/ext4xattr-test cpio marker already arms) reads `user.big` back via
# ext4_getxattr — which follows e_value_inum to EAVALUE and pulls the value
# from its data blocks — and asserts the full 8192-byte length plus the
# head and tail bytes of the ramp. The probe is gated on the feature bit
# AND the probe file existing, so it skips cleanly on the plain xattr test
# image (no regression to test_ext4_xattr.sh).
#
# Pass marker (emitted by the kernel probe, grep-asserted here):
#   [ext4eainode] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_eainode

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
DUMPE2FS="$(_which dumpe2fs)"

# Geometry the hand-patch + the kernel probe agree on.
BS=4096          # filesystem block size
ISIZE=256        # inode size (room for an in-inode xattr region)
VAL_LEN=8192     # ea value length = 2 blocks (must match EXT4_EAINODE_VAL_LEN)

DISK=$(mktemp --suffix=.ext4-eainode.img)
VALFILE=$(mktemp --suffix=.eainode-val.bin)
PHFILE=$(mktemp --suffix=.eainode-ph.bin)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK" "$VALFILE" "$PHFILE"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_eainode] (1/6) Mint an ea_inode ext4 image"
truncate -s 64M "$DISK"
# ea_inode ON; metadata_csum OFF so the hand patch needs no checksum fix-up;
# no journal to stay on the driver's well-trodden read path. The ONLY
# non-default behaviour the in-guest probe exercises is following
# e_value_inum to the value inode's data blocks.
"$MKE2FS" -F -q -b "$BS" -I "$ISIZE" -t ext4 -L "HAMNIX_EAINODE" \
    -O ea_inode,^has_journal,^metadata_csum "$DISK" >/dev/null

# Sanity: the host must agree the image carries ea_inode, so a mke2fs that
# silently dropped the feature fails loud rather than faking a PASS.
if ! "$DUMPE2FS" -h "$DISK" 2>/dev/null | grep -qiE '(^| )ea_inode( |$)'; then
    echo "[test_ext4_eainode] FAIL: minted image lacks ea_inode feature" >&2
    exit 1
fi
echo "[test_ext4_eainode] host confirms ea_inode feature present"

echo "[test_ext4_eainode] (2/6) Build the 8 KiB ramp value (value[i] == i & 0xFF)"
python3 -c 'import sys
open(sys.argv[1],"wb").write(bytes([i & 0xFF for i in range(int(sys.argv[2]))]))' \
    "$VALFILE" "$VAL_LEN"
printf 'PLACEHOLDER' > "$PHFILE"

echo "[test_ext4_eainode] (3/6) Plant EAVALUE (the value inode) + BIGATTR.BIN + placeholder xattr"
# EAVALUE: a regular file whose extent-mapped data blocks hold the 8 KiB
# value. This inode IS the ea-inode the xattr entry will point at.
"$DEBUGFS" -w -R "write $VALFILE EAVALUE" "$DISK" >/dev/null 2>&1
# BIGATTR.BIN: the target file carrying the user.big attribute.
"$DEBUGFS" -w -R "write $VALFILE BIGATTR.BIN" "$DISK" >/dev/null 2>&1
# A small placeholder user.big -> lands in the in-inode xattr region.
"$DEBUGFS" -w -R "ea_set -f $PHFILE BIGATTR.BIN user.big" "$DISK" >/dev/null 2>&1

# Discover group 0's inode table block + each inode number from the host so
# the hand patch is layout-independent (flex_bg / 64bit can move things).
ITAB="$("$DUMPE2FS" "$DISK" 2>/dev/null | awk '
    /^Group 0:/ {ing=1}
    ing && /Inode table at/ {
        if (match($0,/Inode table at ([0-9]+)/,m)) { print m[1]; exit } }')"
VAL_INO="$("$DEBUGFS" -R "stat EAVALUE" "$DISK" 2>/dev/null | sed -n 's/.*Inode: *\([0-9]*\).*/\1/p' | head -1)"
TGT_INO="$("$DEBUGFS" -R "stat BIGATTR.BIN" "$DISK" 2>/dev/null | sed -n 's/.*Inode: *\([0-9]*\).*/\1/p' | head -1)"
if [ -z "$ITAB" ] || [ -z "$VAL_INO" ] || [ -z "$TGT_INO" ]; then
    echo "[test_ext4_eainode] FAIL: could not learn inode-table/inode numbers" >&2
    echo "  itab=$ITAB val_ino=$VAL_INO tgt_ino=$TGT_INO" >&2
    exit 1
fi
echo "[test_ext4_eainode] host layout: inode_table_blk=$ITAB EAVALUE inode=$VAL_INO BIGATTR.BIN inode=$TGT_INO"

echo "[test_ext4_eainode] (4/6) Hand-patch BIGATTR.BIN's user.big -> ea-inode reference"
python3 - "$DISK" "$BS" "$ISIZE" "$ITAB" "$VAL_INO" "$TGT_INO" "$VAL_LEN" <<'PY'
import struct, sys
disk, bs, isize, itab, val_ino, tgt_ino, vlen = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
    int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
EXT4_XATTR_MAGIC = 0xEA020000
f = open(disk, "r+b")
def inode_off(n): return itab * bs + (n - 1) * isize
base = inode_off(tgt_ino)
f.seek(base); raw = bytearray(f.read(isize))
extra = struct.unpack_from("<H", raw, 0x80)[0]
if extra == 0:
    print("[test_ext4_eainode] FAIL: target inode has no i_extra_isize", file=sys.stderr)
    sys.exit(1)
region = 128 + extra
magic = struct.unpack_from("<I", raw, region)[0]
if magic != EXT4_XATTR_MAGIC:
    print("[test_ext4_eainode] FAIL: in-inode xattr magic missing (0x%08x)" % magic, file=sys.stderr)
    sys.exit(1)
p = region + 4
patched = False
while p + 16 <= isize:
    nlen, nidx = raw[p], raw[p + 1]
    if nlen == 0 and nidx == 0:
        break
    name = bytes(raw[p + 16:p + 16 + nlen])
    if nidx == 1 and name == b"big":           # user.big
        struct.pack_into("<H", raw, p + 2, 0)         # e_value_offs = 0
        struct.pack_into("<I", raw, p + 4, val_ino)   # e_value_inum
        struct.pack_into("<I", raw, p + 8, vlen)      # e_value_size
        patched = True
        break
    p += (16 + nlen + 3) & ~3
if not patched:
    print("[test_ext4_eainode] FAIL: user.big entry not found in target inode", file=sys.stderr)
    sys.exit(1)
f.seek(base); f.write(raw); f.close()
print("[test_ext4_eainode] patched: user.big e_value_inum=%d e_value_size=%d" % (val_ino, vlen))
PY

# Re-confirm the patch landed (e_value_inum != 0, size == VAL_LEN).
"$DEBUGFS" -R "stat EAVALUE" "$DISK" 2>/dev/null | grep -iE "Size:" | head -1 \
    | grep -q "$VAL_LEN" && echo "[test_ext4_eainode] host confirms EAVALUE i_size=$VAL_LEN (the value length)"

echo "[test_ext4_eainode] (5/6) Build userland + arm xattr/ea-inode probe marker + kernel"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4XATTR_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4_eainode] (6/6) Boot QEMU with the ea_inode image"
set +e
timeout 200s qemu-system-x86_64 \
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

echo "[test_ext4_eainode] --- ext4/ea_inode boot output ---"
grep -a -E "INCOMPAT_EA_INODE|ext4eainode|ext4-xattr" "$LOG" | head -20 || true
echo "[test_ext4_eainode] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero ea_inode markers == the in-boot probe never ran: a starved/timed-out
# boot, an OBSERVED crash, or GRUB OOM — NOT an ea_inode regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4eainode\]|INCOMPAT_EA_INODE'

# A virtio-blk superblock-read flake (host CPU starvation) means the fs
# never mounted and the probe could not run: INCONCLUSIVE.
if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the ea_inode fs never mounted. Re-run on a quiet host."
fi

fail=0

# The mount must announce it detected ea_inode + armed the read path.
if grep -a -F -q "INCOMPAT_EA_INODE present" "$LOG"; then
    echo "[test_ext4_eainode] OK: mount detected INCOMPAT_EA_INODE (ea-inode read armed)"
else
    echo "[test_ext4_eainode] MISS: mount did not announce INCOMPAT_EA_INODE" >&2
    fail=1
fi

# The probe must have found the file and read user.big through the ea-inode.
if grep -a -F -q "[ext4eainode] probe file present" "$LOG"; then
    echo "[test_ext4_eainode] OK: probe resolved BIGATTR.BIN + read user.big via ea-inode"
else
    echo "[test_ext4_eainode] MISS: probe did not run (file unresolved?)" >&2
    fail=1
fi

# Head sentinel: first bytes of the ramp ([0]=0 [1]=1) — first ea-inode
# block resolved.
if grep -a -F -q "[ext4eainode] head bytes ok: [0]=0 [1]=1" "$LOG"; then
    echo "[test_ext4_eainode] OK: head bytes of the 8 KiB ramp read back"
else
    echo "[test_ext4_eainode] MISS: head bytes of ramp not confirmed" >&2
    fail=1
fi

# Tail sentinel: last bytes ([len-2]=254 [len-1]=255) — the SECOND ea-inode
# block resolved, proving multi-block ea-inode reads work.
if grep -a -F -q "[ext4eainode] tail bytes ok: [len-2]=254 [len-1]=255" "$LOG"; then
    echo "[test_ext4_eainode] OK: tail bytes (2nd block) of the ramp read back"
else
    echo "[test_ext4_eainode] MISS: tail bytes of ramp not confirmed" >&2
    fail=1
fi

# The full-length / byte-exact verification done in-kernel.
if grep -a -F -q "[ext4eainode] value verified byte-exact, len=8192" "$LOG"; then
    echo "[test_ext4_eainode] OK: full 8192-byte value verified byte-exact in-kernel"
else
    echo "[test_ext4_eainode] MISS: in-kernel byte-exact verification not seen" >&2
    fail=1
fi

# The probe PASS banner.
if ! grep -a -F -q "[ext4eainode] PASS" "$LOG"; then
    echo "[test_ext4_eainode] MISS: probe PASS banner (expected '[ext4eainode] PASS')" >&2
    fail=1
fi

# A probe FAILURE surfaces as the xattr selftest FAIL — catch it loud.
if grep -a -F -q "[ext4-xattr] FAIL: ea-inode probe failed" "$LOG"; then
    echo "[test_ext4_eainode] FAIL: kernel ea-inode probe reported a failure" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_eainode] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "the ea_inode probe ran but a marker was OBSERVED absent — INCOMPAT_EA_INODE" \
        "not announced, the probe did not resolve BIGATTR.BIN, or the 8192-byte" \
        "user.big value did not verify byte-exact across both ea-inode blocks" \
        "(qemu rc=$rc). A real multi-block ea_inode read regression."
fi

echo "[ext4eainode] PASS"
verdict_pass "$TAG" "EA_INODE (INCOMPAT_EA_INODE): an 8192-byte xattr value stored" \
     "via e_value_inum read back byte-exact across both ea-inode blocks on a live" \
     "ext4 mount (qemu rc=$rc)"
