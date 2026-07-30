#!/usr/bin/env bash
# scripts/test_install_short_write.sh — the installer must NOT report
# success for bytes it did not write.  (#464)
#
# WHY THIS GATE EXISTS
# ====================
# write(2) chunks internally. Natively (arch/x86/kernel/syscall.ad::
# _sysarm_write) the chunk is a heap bounce capped at UA_WR_BOUNCE_SZ =
# 4 MiB; in the Linux-ABI shim (linux_abi/u_syscalls.ad::
# _u_vfs_write_user) it is a flat 4 KiB. In BOTH, an errno returned by a
# chunk after the first used to be thrown away in favour of the positive
# byte count accumulated so far:
#
#     if wn < 0:
#         if wr_total == 0:
#             return wn          # first chunk: errno propagates
#         return wr_total        # later chunk: -EIO becomes "N bytes"
#
# Every consumer above it — user/install_rootfs_from_manifest.ad,
# user/hpm.ad, user/install.ad — tested only `wn < 0`. So a kernel -EIO
# arrived as a success-looking short count, the installer counted the
# file as installed, printed "install: <path> (N bytes)", and exited 0.
# That is data loss that ships looking healthy, on the InstalLER — our
# primary ship vehicle. It is the same failure shape as three separate
# bugs found the same week (`sh not found`, the missing package repo, the
# truncated repo mirror): content the medium has that the install
# silently fails to write.
#
# WHAT THIS GATE ASSERTS
# ======================
# It drives the REAL path, not a mock: /bin/install_rootfs_from_manifest,
# the same binary install.ad's install_distro_tree / install_package_repo
# / install_home_skeleton invoke, against a blank virtio disk.
#
# The fixture (scripts/build_initramfs.py, ENABLE_SHORTWRITE_TEST=1) is a
# two-row manifest:
#
#     swblocker         <- 11 bytes        installs OK, as a regular FILE
#     swblocker/victim  <- 4 MiB           MUST fail: its parent is a file
#
# Row 2 fails inside ext4 ("[ext4_mkdir_p] component is not a dir" ->
# ext4_install_file_to_slot -1 -> devblk -EIO). The 4 MiB body is what
# makes it the HINGE reproducer rather than a plain error test: the ctl
# frame is header + 4 MiB, strictly larger than the 4 MiB write bounce,
# so write(2) must loop. Chunk 1 only STAGES the body in kernel memory
# (devblk prints "install_file: streaming") and reports itself fully
# consumed; the -EIO surfaces on the FINAL chunk, with 4 MiB already
# accumulated. A single-chunk write does not reproduce anything — the old
# code propagated a first-chunk errno correctly.
#
# Assertions, all observed on the guest serial log:
#   1. streaming  the kernel really took the multi-chunk staging path
#                 (a fast-path boot proves nothing -> INCONCLUSIVE)
#   2. blocker    row 1 DID install — the harness is wired up and the
#                 manifest was read (guards against a vacuous pass where
#                 nothing ran at all)
#   3. rejected   the tool reports the failure for swblocker/victim
#   4. noclaim    the tool does NOT print "install: swblocker/victim" —
#                 the literal silent-loss symptom
#   5. summary    its own tally says FAILED, not "0 failed — OK"
#   6. toolexit   its EXIT STATUS is nonzero
#
# 3, 4 and 6 are the ones that were red before the fix.
#
# MUTATION TESTING
# ================
# MUTATE=<label>[,...] blinds individual assertions (labels above) to
# prove each is load-bearing. The REAL mutation test is reverting the
# hinge in arch/x86/kernel/syscall.ad::_sysarm_write back to
# `if wr_total == 0: return wn; return wr_total` — this gate then goes
# red on `rejected`, `noclaim`, `summary` and `toolexit` at once.
#
# Pass marker: [test_install_short_write] PASS
# Exit codes:  0 PASS, 1 FAIL, 125 INCONCLUSIVE (build/boot never got
#              far enough — never a soft green)

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_install_short_write

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"

mutated=",${MUTATE:-},"
blinded() {
    [ -n "$1" ] && [ "${mutated#*,${1},}" != "$mutated" ]
}

DISK=$(mktemp --suffix=.shortwrite.img)
LOG=$(mktemp)
cleanup() {
    rm -f "$LOG" "$LOG.build" "$DISK"
    # Restore a DEFAULT initramfs so the next gate on this tree does not
    # inherit the 4 MiB fixture.
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[$TAG] (1/5) Mint a blank 64 MiB target disk"
truncate -s 64M "$DISK"

echo "[$TAG] (2/5) Build userland"
if ! bash scripts/build_user.sh >"$LOG.build" 2>&1; then
    tail -40 "$LOG.build" >&2
    verdict_inconclusive "$TAG" "scripts/build_user.sh failed"
fi
for need in "$HAMSH_ELF" build/user/install_rootfs_from_manifest.elf; do
    [ -f "$need" ] || verdict_inconclusive "$TAG" "$need missing after build"
done

echo "[$TAG] (3/5) Plant the short-write fixture + hamsh rc, rebuild kernel"
INIT_ELF="$HAMSH_ELF" \
HAMNIX_HAMSH_RC=etc/shortwrite.hamsh \
ENABLE_SHORTWRITE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs.py failed"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[$TAG] (4/5) Boot QEMU and run the installer against the blank disk"
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 1G \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?

echo "[$TAG] --- guest output ---"
grep -a -E "\[shortwrite\]|install_rootfs_from_manifest:|\[devblk\] install_file|\[ext4_mkdir_p\]|\[ext4_install_file\]" "$LOG" || true
echo "[$TAG] --- end ---"

verdict_boot_gate "$TAG" "$LOG" "$rc" '\[shortwrite\]'

# --- preconditions: the repro condition must actually have been met ---
if ! grep -a -F -q "[shortwrite] mkfs_ext4 /dev/blk/vdb" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "the driver script never reached mkfs_ext4 — no target filesystem," \
        "so nothing about short writes was observed"
fi
if grep -a -F -q "install_file: staging alloc failed" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "devblk could not kmalloc the 4 MiB staging buffer, so the install" \
        "failed on the FIRST chunk (-ENOMEM). The old code propagated a" \
        "first-chunk errno correctly, so this boot cannot distinguish fixed" \
        "from broken. Re-run on a quieter host or with more guest RAM."
fi
if ! blinded streaming; then
    if ! grep -a -F -q "[devblk] install_file: streaming size=4194304" "$LOG"
    then
        verdict_inconclusive "$TAG" \
            "the kernel never took the multi-chunk STREAMING path for the" \
            "4 MiB victim body (no '[devblk] install_file: streaming" \
            "size=4194304'). Without >=2 chunks the errno lands on the" \
            "first chunk, which even the unfixed code propagated — this" \
            "boot proves nothing."
    fi
    echo "[$TAG] OK: multi-chunk staging path taken (the repro condition)"
else
    echo "[$TAG] MUTATED(blinded): streaming"
fi

fail=0
want() {
    local label="$1" needle="$2" mut="$3"
    if blinded "$mut"; then
        echo "[$TAG] MUTATED(blinded): $label"
        return
    fi
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[$TAG] OK: $label"
    else
        echo "[$TAG] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}
reject() {
    local label="$1" needle="$2" mut="$3"
    if blinded "$mut"; then
        echo "[$TAG] MUTATED(blinded): $label"
        return
    fi
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[$TAG] SILENT LOSS: $label (log contains '$needle')" >&2
        fail=1
    else
        echo "[$TAG] OK: $label"
    fi
}

# 2. the harness really ran: row 1 landed.
want "row 1 (swblocker) installed — the manifest was read" \
     "  install: swblocker (" blocker

# 3. THE assertion: the failure is REPORTED.
want "row 2 failure is reported to the operator" \
     "install_rootfs_from_manifest: kernel rejected install of swblocker/victim" \
     rejected

# 4. THE assertion: the failure is not ALSO claimed as an install.
reject "row 2 is not claimed as installed" \
       "  install: swblocker/victim" noclaim

# 5. the tool's own tally is honest.
want "tool tally reports a failure" \
     "install_rootfs_from_manifest: 1 installed, 0 missing, 1 FAILED" summary

# 6. and its exit status is nonzero.
want "tool exit status is NONZERO" \
     "[shortwrite] tool-exit: NONZERO" toolexit

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "the installer did not report a kernel write failure it suffered." \
        "A 4 MiB file that could not be written was accounted as installed" \
        "(or the failure was never surfaced) — silent data loss on the" \
        "primary ship vehicle. See the MISS/SILENT LOSS lines above."
fi

verdict_pass "$TAG" \
    "a mid-write kernel -EIO on a multi-chunk write(2) reached the" \
    "installer: swblocker/victim was reported rejected, was NOT counted" \
    "as installed, and install_rootfs_from_manifest exited nonzero"
