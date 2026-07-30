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

# HAMNIX_CVO_SKIP_BUILD=1 reuses the already-built image. Only for iterating
# on the harness during a hunt — the kernel edit under test MUST be in the
# image, and pass 13 lost a whole measurement to a stale one. The unset
# default always rebuilds.
if [ "${HAMNIX_CVO_SKIP_BUILD:-0}" = "1" ] && [ -f "$ELF" ]; then
    echo "[cow_vma_origin] (1-3/4) SKIPPED (HAMNIX_CVO_SKIP_BUILD=1)"
    echo "[cow_vma_origin] image age: $(( $(date +%s) - $(stat -c %Y "$ELF") ))s"
    trap 'rm -f "$LOG"' EXIT
else
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
fi

echo "[cow_vma_origin] (4/4) Boot + counted run"
LOG=$(mktemp)
if [ "${HAMNIX_CVO_SKIP_BUILD:-0}" = "1" ]; then
    trap 'rm -f "$LOG"' EXIT
else
    trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT
fi

# THREE identical workload runs, one origin dump after each.
#
# Two dumps would be enough if the first run's cohort were the only one-time
# population, and it is not: hamsh's own frames take their first reference on
# the first fork and legitimately never die while hamsh lives. Three runs give
# TWO inter-run deltas, so a per-run leak (constant positive net) is
# distinguishable from a one-time resident set (net 0 after the first run)
# without any appeal to a slope or a mean. The LAST delta is the assertion;
# the first is printed for contrast.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 420 \
    -- "echo track full > /proc/meminfo" 3 \
       "u_mmap_fork" 25 \
       "echo track origin > /proc/meminfo" 6 \
       "u_mmap_fork" 25 \
       "echo track origin > /proc/meminfo" 6 \
       "u_mmap_fork" 25 \
       "echo track origin > /proc/meminfo" 6 \
       "echo track org 23 > /proc/meminfo" 10 \
       "echo track org 24 > /proc/meminfo" 20 \
       "echo track org 5 > /proc/meminfo" 20 \
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
if [ "$mfp" -ge 3 ]; then
    echo "[cow_vma_origin] OK: u_mmap_fork PASS x$mfp (COW semantics intact)"
else
    echo "[cow_vma_origin] MISS: expected 3 u_mmap_fork PASS banners, got $mfp"
    fail=1
fi

# The instrument must be ARMED. A disarmed or table-less ledger prints a
# banner instead of numbers, and a gate that passed on an absent dump would be
# exactly the false-exoneration the census's controls exist to prevent.
if grep -F -q "[origin] DISARMED" "$LOG" || grep -F -q "[origin] NO TABLE" "$LOG"; then
    echo "[cow_vma_origin] FAIL: origin ledger not armed — the dump is VOID"
    fail=1
fi

# Three `track origin` dumps -> two inter-run deltas. Each dump ends with the
# "tagged live frames" summary line, which is what delimits the blocks.
python3 - "$LOG" <<'PY' > /tmp/.cvo_deltas.$$ || fail=1
import re, sys
log = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
blocks, cur = [], {}
for line in log.splitlines():
    m = re.search(r'\[origin\] org=(\d+) born=(\d+) died=(\d+)', line)
    if m:
        cur[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
    elif 'tagged live frames' in line:
        blocks.append(cur); cur = {}
if len(blocks) < 3:
    sys.stderr.write("ERR blocks=%d\n" % len(blocks)); sys.exit(1)
b1, b2, b3 = blocks[0], blocks[1], blocks[2]
for arm in sorted(set(b1) | set(b2) | set(b3)):
    (n1, d1) = b1.get(arm, (0, 0))
    (n2, d2) = b2.get(arm, (0, 0))
    (n3, d3) = b3.get(arm, (0, 0))
    # arm, born/died delta over run 2, then over run 3
    print("%d %d %d %d %d" % (arm, n2 - n1, d2 - d1, n3 - n2, d3 - d2))
PY
if [ "$fail" -ne 0 ] || [ ! -s /tmp/.cvo_deltas.$$ ]; then
    echo "[cow_vma_origin] FAIL: could not read three origin dumps from the log"
    rm -f /tmp/.cvo_deltas.$$
    exit 1
fi

echo "[cow_vma_origin] --- per-arm deltas, run2 and run3 (identical workloads) ---"
while read -r arm b2 d2 b3 d3; do
    printf '[cow_vma_origin] arm=%-3s run2 born=%-5s died=%-5s net=%-5s | run3 born=%-5s died=%-5s net=%s\n' \
        "$arm" "$b2" "$d2" "$((b2 - d2))" "$b3" "$d3" "$((b3 - d3))"
done < /tmp/.cvo_deltas.$$

# POSITIVE CONTROL for the arms themselves: the second run MUST have
# exercised the mmap-VMA owner share, or "arm 23 is balanced" is a statement
# about an empty set — the same blind-instrument failure `track plant` exists
# to rule out for the census.
db23=$(awk '$1==23{print $4}' /tmp/.cvo_deltas.$$)
if [ -z "${db23:-}" ] || [ "$db23" -eq 0 ]; then
    echo "[cow_vma_origin] FAIL: arm 23 took no births in the final window"
    echo "                 — the workload never reached vma_fork_copy's"
    echo "                 owner-mmap share, so a zero net proves nothing."
    fail=1
else
    echo "[cow_vma_origin] control OK: arm 23 run3 born=$db23"
fi

# THE ASSERTION, on the LAST inter-run delta only. By run 3 every one-time
# population is already born, so a non-zero net is a frame this run's share
# created and this run's teardown did not destroy — per run, counted.
for arm in 23 24; do
    line=$(awk -v a="$arm" '$1==a{print}' /tmp/.cvo_deltas.$$)
    [ -z "$line" ] && continue
    b3=$(echo "$line" | awk '{print $4}')
    d3=$(echo "$line" | awk '{print $5}')
    net=$((b3 - d3))
    if [ "$net" -ne 0 ]; then
        echo "[cow_vma_origin] UNMATCHED: arm=$arm run3 born=$b3 died=$d3 net=$net"
        echo "                 — vma_fork_copy created $net frame(s) this run"
        echo "                 that its teardown never destroyed."
        fail=1
    else
        echo "[cow_vma_origin] closed: arm=$arm run3 born=$b3 died=$d3 net=0"
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
