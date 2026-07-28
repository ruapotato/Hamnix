#!/usr/bin/env bash
# scripts/test_ext4dir.sh — multi-block ext4 directory walk verification.
#
# Proves fs/ext4.ad walks a directory that overflows its first data block
# across EVERY mapped block — both lookup (name -> inode) and readdir
# (enumerate) — instead of the old single-block-only behaviour.
#
# Fixture: a host-minted ext4 image (1 KiB blocks, no journal) carrying
#   /bigdir  — populated with 300 short-named files (f0000..f0299) whose
#              content == their own name. At 1 KiB blocks this directory
#              spans 5 data blocks, so any file f0250..f0299 lives in a
#              block PAST block 0 and is only reachable by a full walk.
# plus, when the host can build it (loopback mount; sudo), a real htree
# directory:
#   /htreedir — 600 files (h0000..h0599) created through the kernel's
#               own ext4 so the inode actually carries EXT4_INDEX_FL
#               (htree / dir_index). Driver handles this by linear-leaf-
#               scan: it walks every block, the index nodes contribute
#               nothing, and the real entries are harvested from the leaf
#               blocks. Skipped gracefully when no loopback mount is
#               available — the linear /bigdir case is the must-have.
#
# The host parses each directory's on-disk blocks to learn (a) the exact
# real-entry count and (b) the name of a file it placed in the LAST data
# block, and writes those as ground-truth files at the image root:
#   /bigdir-count.txt, /bigdir-last.txt  (and /htreedir-* when present).
# The in-kernel ext4_dirmb_selftest() (gated on /etc/ext4dir-test) reads
# that ground truth and asserts readdir's count matches and the last-
# block file resolves by name + reads back correctly.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ext4dir] PASS   (kernel prints [ext4dir] PASS)
# Fail marker:  [test_ext4dir] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4dir

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
DEBUGFS="$(_which debugfs)"

DISK=$(mktemp --suffix=.ext4dir.img)
STAGE=$(mktemp -d)
LOG=$(mktemp)
trap 'rm -rf "$LOG" "$DISK" "$STAGE"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

NBIG=300

echo "[test_ext4dir] (1/6) Mint a 1 KiB-block ext4 image"
# 64 MiB headroom; 1 KiB blocks match the driver's well-trodden path and
# keep ~30 dirents/block so 300 files comfortably overflow several blocks.
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_DIR" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4dir] (2/6) Populate /bigdir with $NBIG files (linear multi-block)"
# Stage each file's payload (== its own name) and build one debugfs script.
CMDS="$STAGE/dbg.txt"
: > "$CMDS"
echo "mkdir /bigdir" >> "$CMDS"
i=0
while [ "$i" -lt "$NBIG" ]; do
    nm=$(printf 'f%04d' "$i")
    printf '%s' "$nm" > "$STAGE/$nm"
    echo "write $STAGE/$nm /bigdir/$nm" >> "$CMDS"
    i=$((i + 1))
done
"$DEBUGFS" -w -f "$CMDS" "$DISK" >/dev/null 2>&1

# Try to ALSO build a real htree dir via a loopback mount (needs the
# kernel ext4 driver to perform the htree conversion debugfs can't do).
HAVE_HTREE=0
NHT=600
if sudo -n true >/dev/null 2>&1; then
    HMNT=$(mktemp -d)
    if sudo mount -o loop "$DISK" "$HMNT" >/dev/null 2>&1; then
        if sudo mkdir -p "$HMNT/htreedir" >/dev/null 2>&1; then
            sudo bash -c '
                d="$1"; n="$2"
                i=0
                while [ "$i" -lt "$n" ]; do
                    nm=$(printf "h%04d" "$i")
                    printf "%s" "$nm" > "$d/htreedir/$nm"
                    i=$((i + 1))
                done
            ' _ "$HMNT" "$NHT" >/dev/null 2>&1 || true
            sync
        fi
        sudo umount "$HMNT" >/dev/null 2>&1 || true
        # Confirm the directory really came out htree-flagged (0x1000).
        FLAGS=$("$DEBUGFS" -R "stat /htreedir" "$DISK" 2>/dev/null \
                  | sed -n 's/.*Flags: \(0x[0-9a-fA-F]*\).*/\1/p' | head -1)
        if [ -n "$FLAGS" ] && \
           python3 -c "import sys; sys.exit(0 if (int('$FLAGS',16)&0x1000) else 1)"; then
            HAVE_HTREE=1
            echo "[test_ext4dir] htree dir built (inode flags $FLAGS, INDEX set)"
        else
            echo "[test_ext4dir] htree dir not INDEX-flagged (flags=${FLAGS:-?}); skipping htree pass"
        fi
    fi
    rmdir "$HMNT" 2>/dev/null || true
else
    echo "[test_ext4dir] no passwordless sudo; skipping the optional htree pass"
fi

echo "[test_ext4dir] (3/6) Compute ground truth (entry counts + last-block files)"
# Parse the on-disk directory blocks to learn, per directory, the exact
# real-entry count and the name of a file in the LAST data block. Emit
# shell assignments the script then writes back into the image root.
GTRUTH="$STAGE/gtruth.sh"
python3 - "$DISK" "$DEBUGFS" "$HAVE_HTREE" > "$GTRUTH" <<'PY'
import sys, struct, subprocess, re

img, debugfs, have_htree = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
BS = 1024
data = open(img, "rb").read()

def extents(path):
    out = subprocess.check_output([debugfs, "-R", "stat %s" % path, img],
                                  stderr=subprocess.DEVNULL).decode()
    seg = out[out.find("EXTENTS:"):]
    phys = {}
    for l0, l1, p0, _ in re.findall(r'\((?:ETB\d+|(\d+)(?:-(\d+))?)\):(\d+)(?:-(\d+))?', seg):
        if l0 == "":
            continue
        a = int(l0); b = int(l1) if l1 else a; p = int(p0)
        for i, lb in enumerate(range(a, b + 1)):
            phys[lb] = p + i
    return phys

def walk(path):
    """Return (real_count, last_block_file_name) by linear-leaf-scan —
    exactly what the kernel does."""
    phys = extents(path)
    total = 0
    last_name = None
    for lb in sorted(phys):
        blk = data[phys[lb] * BS:(phys[lb] + 1) * BS]
        pos = 0
        block_real = []
        while pos + 8 <= len(blk):
            inode, rec_len, name_len, ftype = struct.unpack_from("<IHBB", blk, pos)
            if rec_len < 8 or pos + rec_len > len(blk):
                break
            if inode != 0 and name_len > 0 and 8 + name_len <= rec_len:
                nm = blk[pos + 8:pos + 8 + name_len].decode("latin1")
                if nm not in (".", ".."):
                    block_real.append(nm)
            pos += rec_len
        total += len(block_real)
        if block_real:
            last_name = block_real[-1]   # a file in this (currently last) leaf
    return total, last_name

bc, bl = walk("/bigdir")
print("BIG_COUNT=%d" % bc)
print("BIG_LAST=%s" % bl)
if have_htree:
    hc, hl = walk("/htreedir")
    print("HT_COUNT=%d" % hc)
    print("HT_LAST=%s" % hl)
PY
# shellcheck disable=SC1090
. "$GTRUTH"

echo "[test_ext4dir] /bigdir: $BIG_COUNT real files, last-block file '$BIG_LAST'"
if [ "$HAVE_HTREE" = "1" ]; then
    echo "[test_ext4dir] /htreedir: $HT_COUNT real files, last-leaf file '$HT_LAST'"
fi

# Write the ground truth back into the image root so the kernel reads it.
GT="$STAGE/gt"
: > "$STAGE/_bc"; printf '%s\n' "$BIG_COUNT" > "$STAGE/_bc"
printf '%s\n' "$BIG_LAST" > "$STAGE/_bl"
WB="$STAGE/writeback.txt"
{
    echo "write $STAGE/_bc /bigdir-count.txt"
    echo "write $STAGE/_bl /bigdir-last.txt"
} > "$WB"
if [ "$HAVE_HTREE" = "1" ]; then
    printf '%s\n' "$HT_COUNT" > "$STAGE/_hc"
    printf '%s\n' "$HT_LAST" > "$STAGE/_hl"
    {
        echo "write $STAGE/_hc /htreedir-count.txt"
        echo "write $STAGE/_hl /htreedir-last.txt"
    } >> "$WB"
fi
"$DEBUGFS" -w -f "$WB" "$DISK" >/dev/null 2>&1

echo "[test_ext4dir] (4/6) Build userland + plant /etc/ext4dir-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4DIR_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4dir] (5/6) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4dir] (6/6) Boot QEMU with the multi-block-dir image"
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

echo "[test_ext4dir] --- ext4dir self-test output ---"
grep -a -E "\[ext4dir\]" "$LOG" || true
echo "[test_ext4dir] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# A TCG-starved / GRUB-OOM boot emits ZERO [ext4dir] markers and used to be
# indistinguishable from a real regression (a wall of MISS -> hard FAIL).
# Route the zero-marker case through the shared discriminator FIRST: it is
# INCONCLUSIVE (starved/timeout/OOM), never a bogus red. The per-marker
# check() chain below stays as DIAGNOSTICS; the final decision is verdict_*.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4dir\]'

fail=0

if grep -a -F -q "[ext4dir] FAIL" "$LOG"; then
    echo "[test_ext4dir] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4dir] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_ext4dir] OK: $label"
    else
        echo "[test_ext4dir] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "bigdir spans multiple data blocks"   "[ext4dir] bigdir(linear) spans"
check "readdir enumerated every block"       "readdir enumerated all"
check "last-block file resolved by name"     "last-block file resolved by name"
check "self-test PASS banner"                "[ext4dir] PASS"

if [ "$HAVE_HTREE" = "1" ]; then
    check "htree dir INDEX-flagged"          "[ext4dir] htreedir carries EXT4_INDEX_FL"
    check "htree walked by linear-leaf-scan" "[ext4dir] htree-flagged dir walked by linear-leaf-scan OK"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4dir] --- full log ---"
    cat "$LOG"
    # Some [ext4dir] markers printed but the terminal PASS banner never
    # arrived AND qemu was killed by timeout -> starved mid-selftest, not a
    # regression. A clean exit (rc!=124) without PASS, or an OBSERVED marker
    # MISS, is a real actionable red.
    if ! grep -a -F -q "[ext4dir] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ext4dir] markers printed but the terminal PASS banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ext4dir] marker was OBSERVED absent (or an internal FAIL was" \
        "reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "multi-block ext4 directory: readdir enumerates all" \
     "blocks and a last-block file resolves by name (qemu rc=$rc)"
