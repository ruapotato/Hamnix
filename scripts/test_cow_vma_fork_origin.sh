#!/usr/bin/env bash
# scripts/test_cow_vma_fork_origin.sh — the mmap-VMA fork share, COUNTED.
#
# Leak pass 15. Pass 14 closed the user-stack span by giving it a per-span
# origin and comparing born vs died; the residue it left named the LAST share
# path without one — mm/vma.ad::vma_fork_copy's own vm_cow_share_range calls.
# Pass 15 gives that path two origins (23 = the owner-mmap arm, 24 = the
# demand-resident arm) and closes them the same way.
#
# WHY THIS IS NOT A SOAK. The brief forbids validating on a before/after
# soak-mean pair: the leak is bursty and bimodal, and two byte-identical
# builds differ by 6.4 pg/cycle. The quantity here is COUNTED and the workload
# is DETERMINISTIC — /bin/u_mmap_fork does exactly 8 x (mmap 2 pages, write,
# fork, child writes, parent wait4 + munmap), then exits. It runs in one boot
# instead of twelve minutes.
#
# WHY REPEAT-INVARIANCE AND NOT `born == died`. An absolute balance is the
# WRONG assertion here and asserting it would produce a permanent false red.
# cow_share_page takes a frame 0 -> 2 (parent + child); when the child dies
# the count falls to 1, and the frame is NOT dead while the parent still maps
# it. hamsh is alive for the whole run, so every frame IT shared into the
# fork legitimately reads born-without-died. Absolute balance is only
# meaningful for a span whose whole cohort has exited, which is exactly what
# made pass 14's 768/768 readable and is not the situation here.
#
# What IS closed-form: run the identical workload TWICE and compare the
# DELTAS. hamsh's own frames are born on the first launch and merely
# re-shared (1 -> 2, not a birth) on the second, so the second launch's
# cohort is created and destroyed entirely within the measured window.
#
#     delta_born(arm) - delta_died(arm) == 0     for arms 23 and 24
#
# A non-zero delta is a frame the mmap-VMA fork share created and the
# teardown did not destroy — a leak, counted, with no slope and no mean.
#
# The `track full` arming and the `track origin` / `track org N` dumps are the
# same ctl verbs the soak uses (sys/src/9/port/devmeminfo.ad); nothing here is
# test-only kernel code.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ensure_ubin_or_skip test_cow_vma_fork_origin u_mmap_fork mmap_fork

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[cow_vma_origin] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[cow_vma_origin] (2/4) /init = hamsh + embed u_mmap_fork"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[cow_vma_origin] (3/4) Rebuild kernel"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[cow_vma_origin] (4/4) Boot + counted run"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 240 \
    -- "echo track full > /proc/meminfo" 3 \
       "u_mmap_fork" 30 \
       "echo MARK_BASE > /proc/meminfo" 2 \
       "echo track origin > /proc/meminfo" 5 \
       "u_mmap_fork" 30 \
       "echo MARK_FINAL > /proc/meminfo" 2 \
       "echo track origin > /proc/meminfo" 5 \
       "echo track org 23 > /proc/meminfo" 8 \
       "echo track org 24 > /proc/meminfo" 8 \
       "echo track org 5 > /proc/meminfo" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[cow_vma_origin] --- origin ledger ---"
grep -F "[origin]" "$LOG" || true
echo "[cow_vma_origin] --- live-frame owners ---"
grep -F "[orgl]" "$LOG" || true
echo "[cow_vma_origin] --- end ---"

fail=0

mfp=$(grep -F -c "MF: PASS" "$LOG" || true)
if [ "$mfp" -ge 2 ]; then
    echo "[cow_vma_origin] OK: u_mmap_fork PASS x$mfp (COW semantics intact)"
else
    echo "[cow_vma_origin] MISS: expected 2 u_mmap_fork PASS banners, got $mfp"
    fail=1
fi

# The instrument must be ARMED. A disarmed or table-less ledger prints a
# banner instead of numbers, and a gate that passed on an absent dump would be
# exactly the false-exoneration the census's controls exist to prevent.
if grep -F -q "[origin] DISARMED" "$LOG" || grep -F -q "[origin] NO TABLE" "$LOG"; then
    echo "[cow_vma_origin] FAIL: origin ledger not armed — the dump is VOID"
    fail=1
fi

# Split the log at the two dumps. Each `track origin` emits one block; take
# block 1 as the baseline and block 2 as the final.
awk '/\[origin\] totals|\[origin\] org=/{print}' "$LOG" >/dev/null 2>&1 || true
python3 - "$LOG" <<'PY' > /tmp/.cvo_deltas.$$ || fail=1
import re, sys
log = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
# Each dump ends with the "tagged live frames" summary line.
blocks, cur = [], {}
for line in log.splitlines():
    m = re.search(r'\[origin\] org=(\d+) born=(\d+) died=(\d+)', line)
    if m:
        cur[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
    elif 'tagged live frames' in line:
        blocks.append(cur); cur = {}
if len(blocks) < 2:
    print("ERR blocks=%d" % len(blocks)); sys.exit(1)
base, fin = blocks[0], blocks[1]
for arm in sorted(set(base) | set(fin)):
    b0, d0 = base.get(arm, (0, 0))
    b1, d1 = fin.get(arm, (0, 0))
    print("%d %d %d" % (arm, b1 - b0, d1 - d0))
PY
if [ "$fail" -ne 0 ] || [ ! -s /tmp/.cvo_deltas.$$ ]; then
    echo "[cow_vma_origin] FAIL: could not read two origin dumps from the log"
    rm -f /tmp/.cvo_deltas.$$
    exit 1
fi

echo "[cow_vma_origin] --- per-arm deltas across the second identical run ---"
cat /tmp/.cvo_deltas.$$ | while read -r arm db dd; do
    printf '[cow_vma_origin] arm=%-3s delta_born=%-6s delta_died=%-6s net=%s\n' \
        "$arm" "$db" "$dd" "$((db - dd))"
done

# POSITIVE CONTROL for the arms themselves: the second run MUST have
# exercised the mmap-VMA owner share, or "arm 23 is balanced" is a statement
# about an empty set — the same blind-instrument failure `track plant` exists
# to rule out for the census.
db23=$(awk '$1==23{print $2}' /tmp/.cvo_deltas.$$)
if [ -z "${db23:-}" ] || [ "$db23" -eq 0 ]; then
    echo "[cow_vma_origin] FAIL: arm 23 took no births in the measured window"
    echo "                 — the workload never reached vma_fork_copy's"
    echo "                 owner-mmap share, so a zero net proves nothing."
    fail=1
else
    echo "[cow_vma_origin] control OK: arm 23 delta_born=$db23"
fi

for arm in 23 24; do
    line=$(awk -v a="$arm" '$1==a{print}' /tmp/.cvo_deltas.$$)
    [ -z "$line" ] && continue
    db=$(echo "$line" | awk '{print $2}')
    dd=$(echo "$line" | awk '{print $3}')
    net=$((db - dd))
    if [ "$net" -ne 0 ]; then
        echo "[cow_vma_origin] UNMATCHED: arm=$arm born=$db died=$dd net=$net"
        fail=1
    else
        echo "[cow_vma_origin] closed: arm=$arm born=$db died=$dd net=0"
    fi
done
rm -f /tmp/.cvo_deltas.$$

if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[cow_vma_origin] DIAG: CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[cow_vma_origin] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[cow_vma_origin] PASS -- the mmap-VMA fork share closes born == died"
