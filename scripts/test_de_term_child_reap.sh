#!/usr/bin/env bash
# scripts/test_de_term_child_reap.sh — the DE terminal must not strand its
# child shell when its window is closed.
#
# THE BUG THIS PINS (found by the 30-minute soak, docs/de_stress_soak.md)
# ======================================================================
# user/hamtermscene.ad spawns `/bin/hamsh --no-echo /etc/rc.de-user` as the
# window's interactive shell. Closing the window posts the Plan 9 "terminate"
# note to hamtermscene, and a note to a handler-less process TERMINATES it
# outright (sys/src/9/port/sysnote.ad) — it never runs another instruction, so
# it cannot reap anything. The child shell was left RUNNING FOREVER.
#
# The soak measured the cost by running the same 36 cycles with and without
# the terminal in the app mix:
#
#   metric            with hamtermscene     control (no terminal)
#   MemFree slope     -4525 kB/cycle        -1443 kB/cycle
#   PagesInUse        +148.8 pg/cycle       +24.4 pg/cycle
#   VmaNodesLive      28 -> 58              28 -> 28   (flat)
#   TasksLive         20 -> 35              20 -> 20   (flat)
#
# i.e. ~1 task, 2 VMA nodes and ~300 pages stranded per terminal close.
#
# WHAT THIS GATE ASSERTS
# ======================
# Open and close /bin/hamtermscene CYCLES times (default 12) and require that
# after every close the kernel's own accounting comes BACK TO BASELINE:
#
#   * TasksLive      — no accumulating task (the orphaned shell)
#   * VmaNodesLive   — no accumulating address-space node
#   * live `hamsh` rows in /proc/tasks — the direct, unambiguous witness:
#     one extra hamsh per cycle is exactly the leak, and zero growth is
#     exactly the fix
#
# Small transient drift is tolerated (a zombie awaiting the next allocation's
# reap sweep is normal), so the gate compares the LAST cycle against the
# BASELINE with a tolerance and additionally requires the hamsh census never
# to exceed baseline + 1 at any settled sample. A per-cycle leak of 1 blows
# through both at CYCLES=12.
#
# Runs in ~4 minutes, so unlike the soak it is cheap enough for the normal
# battery.
#
# Env: INSTALLER_IMG, OVMF_FD, BOOT_WAIT, OUT_DIR, CYCLES, TASK_TOL, VMA_TOL.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[termreap]"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
CYCLES="${CYCLES:-12}"
TASK_TOL="${TASK_TOL:-2}"
VMA_TOL="${VMA_TOL:-4}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_term_child_reap/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

[ -e /dev/kvm ] || { echo "$TAG SKIP-RUNTIME: /dev/kvm absent" >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP-RUNTIME: no OVMF" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP-RUNTIME: no socat" >&2; exit 0; }

# Fresh image, always: a leak gate that boots a stale image measures the old
# kernel's leak. ensure_installer_img builds when needed (always-overwrite
# contract, scripts/_fresh_artifact.sh).
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if declare -F installer_img_or_verdict >/dev/null 2>&1; then
    installer_img_or_verdict "$INSTALLER_IMG" "$TAG"
else
    installer_img_warn_if_stale "$INSTALLER_IMG" "$TAG"
fi
# Reaching here without an image means the build was attempted and produced
# nothing: INCONCLUSIVE, never a clean skip (2026-07-28 soft-green sweep).
[ -f "$INSTALLER_IMG" ] || {
    echo "$TAG RESULT: INCONCLUSIVE ($INSTALLER_IMG absent — nothing booted)" >&2
    exit 125; }
# A build in flight leaves a SHORT image behind. Booting it costs the full
# BOOT_WAIT and then reports "no handoff", which reads like a kernel
# regression; catch the real cause up front.
IMG_SZ=$(stat -c %s "$INSTALLER_IMG" 2>/dev/null || echo 0)
if [ "$IMG_SZ" -lt 33554432 ]; then
    echo "$TAG SKIP-RUNTIME: $INSTALLER_IMG is only ${IMG_SZ}B — a build is" >&2
    echo "$TAG   probably still writing it. Re-run once the build finishes." >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "$TAG output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-tr.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-tr.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-tr-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-tr.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own QEMU (never a global pkill — a concurrent gate's
    # boot is not ours to end).
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
}
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1; }
snapshot() {
    local ppm="$OUT_DIR/$1.ppm"
    rm -f "$ppm"; mon_cmd "screendump $ppm" || return 1
    local i=0; while [ "$i" -lt 40 ]; do [ -s "$ppm" ] && break; sleep 0.1; i=$((i+1)); done
    [ -s "$ppm" ] || return 1
    command -v convert >/dev/null 2>&1 && convert "$ppm" "$OUT_DIR/$1.png" 2>/dev/null
    return 0
}
# grep -a everywhere: the serial log carries NUL bytes.
wait_for() {
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
mapped_count() { grep -ac "\[devwsys\] window .* mapped" "$LOG"; }

qemu-system-x86_64 \
    -enable-kvm -cpu host -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "$TAG waiting up to ${BOOT_WAIT}s for the DE handoff..."
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || {
    echo "$TAG FAIL: no handoff marker in ${BOOT_WAIT}s" >&2
    tail -40 "$LOG" >&2; exit 1; }
sleep 8
# hamsh drops the FIRST serial command; burn one on a ready marker.
printf 'echo MARK_TR_READY\n' >&3
sleep 1
wait_for MARK_TR_READY 12 || { printf 'echo MARK_TR_READY\n' >&3; sleep 2; }

fail=0
say_fail() { echo "$TAG FAIL $*" >&2; fail=1; }

# sample <label> — meminfo + the live task table, between anchored markers.
# Markers MUST be matched anchored host-side: hamsh echoes the whole command
# line back before running it, so an unanchored match finds the echo first.
sample() {
    local lbl="$1"
    printf 'echo TRSMP_%s_B; cat /proc/meminfo; echo TRTASK_%s; cat /proc/tasks; echo TRSMP_%s_E\n' \
        "$lbl" "$lbl" "$lbl" >&3
    local d=$(( SECONDS + 25 ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "TRSMP_${lbl}_E" "$LOG" && { sleep 1; return 0; }
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

# wait_exit <pid> <base-count> <timeout>: a NEW exit line for this pid.
# Presence alone is wrong — pids recycle and the previous holder's exit line
# would match instantly.
wait_exit() {
    local pid="$1" base="$2" deadline=$(( SECONDS + $3 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ "$(grep -ac "task: pid $pid exited" "$LOG")" -gt "$base" ] && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

snapshot 000_idle
sample base || say_fail "baseline sample timed out"

c=0
while [ "$c" -lt "$CYCLES" ]; do
    c=$((c+1))
    before=$(mapped_count)
    # Launch as a CHILD OF THIS SHELL: devproc's note gate is
    # caller-uid == target-uid, so this closes it exactly the way the DE's
    # own close box does (hamUId daemon_close_slot -> p9_note_tree).
    printf '/bin/hamtermscene &\n' >&3
    d=$(( SECONDS + 30 ))
    while [ "$SECONDS" -lt "$d" ]; do
        [ "$(mapped_count)" -gt "$before" ] && break
        sleep 1
    done
    if [ "$(mapped_count)" -le "$before" ]; then
        say_fail "cycle $c: hamtermscene mapped NO window in 30s"
        snapshot "STUCK_c$c"; break
    fi
    line=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)
    pid=$(echo "$line" | sed -n 's/.*mapped pid=\([0-9]*\).*/\1/p')
    if [ -z "$pid" ]; then say_fail "cycle $c: no pid in the mapped line"; break; fi
    # Let the shell actually start and print its prompt, otherwise we would
    # be closing the window before the child even exists — which passes for
    # the wrong reason.
    sleep 3
    exit_base=$(grep -ac "task: pid $pid exited" "$LOG")
    printf '/bin/kill %s\n' "$pid" >&3
    if ! wait_exit "$pid" "$exit_base" 20; then
        say_fail "cycle $c: pid $pid survived the terminate note for 20s"; break
    fi
    # Give the kernel a beat: an orphaned zombie is reclaimed by
    # reap_orphan_zombies at the next task allocation, so sample after some
    # settling rather than in the middle of teardown.
    sleep 3
    sample "c$c" || { say_fail "cycle $c: sample timed out"; break; }
    echo "$TAG cycle $c done (pid $pid)"
done
CYCLES_RUN=$c

snapshot 999_final
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null

SUMMARY="$OUT_DIR/summary.txt"
python3 - "$LOG" "$CYCLES_RUN" "$TASK_TOL" "$VMA_TOL" > "$SUMMARY" 2>&1 <<'PY'
import re, sys
log, ncyc, task_tol, vma_tol = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
txt = open(log, 'rb').read().decode('utf-8', 'replace').replace('\r', '')

def region(lbl):
    # ANCHORED: hamsh echoes the command line (containing BOTH markers) back
    # before running it, so an unanchored non-greedy match captures nothing.
    m = re.search(r'^TRSMP_%s_B$(.*?)^TRSMP_%s_E$' % (lbl, lbl), txt, re.M | re.S)
    return m.group(1) if m else None

def parse(lbl):
    r = region(lbl)
    if r is None:
        return None
    out = {}
    for key in ('MemFree', 'PagesInUse', 'VmaNodesLive', 'TasksLive'):
        m = re.search(r'^%s:\s+(\d+)' % key, r, re.M)
        if m:
            out[key] = int(m.group(1))
    tm = re.search(r'^TRTASK_%s$(.*)' % lbl, r, re.M | re.S)
    out['hamsh'] = len(re.findall(r'\bhamsh\b', tm.group(1))) if tm else -1
    return out

labels = ['base'] + ['c%d' % i for i in range(1, ncyc + 1)]
rows = [(l, parse(l)) for l in labels]
rows = [(l, d) for l, d in rows if d]
print('label   MemFree  PagesInUse  VmaNodesLive  TasksLive  hamsh')
for l, d in rows:
    print('%-6s %8s %11s %13s %10s %6s' % (
        l, d.get('MemFree', '?'), d.get('PagesInUse', '?'),
        d.get('VmaNodesLive', '?'), d.get('TasksLive', '?'), d.get('hamsh', '?')))
if len(rows) < 3:
    print('VERDICT: FAIL (only %d parsed samples)' % len(rows)); sys.exit(1)
base = rows[0][1]
cyc = [d for _, d in rows[1:]]
# THE SETTLED FLOOR is the load-bearing statistic, not the last sample.
# A close leaves a zombie behind for a beat — reap_orphan_zombies collects an
# orphan at the next task ALLOCATION, i.e. when the next app launches — so an
# individual sample legitimately reads baseline+1 task / +2 VMA nodes if it
# lands mid-teardown. What CANNOT happen without a leak is the floor rising:
# take the minimum over the back third of the run and require it to be at
# baseline. With the leak that floor climbs by one task and two VMA nodes per
# cycle and misses by ~10; without it, it is exactly baseline.
tail_n = max(3, len(cyc) // 3)
tail = cyc[-tail_n:]
floor_t = min(d['TasksLive'] for d in tail) - base['TasksLive']
floor_v = min(d['VmaNodesLive'] for d in tail) - base['VmaNodesLive']
peak_t = max(d['TasksLive'] for d in cyc) - base['TasksLive']
peak_v = max(d['VmaNodesLive'] for d in cyc) - base['VmaNodesLive']
dh = max(d['hamsh'] for d in cyc) - base['hamsh']
bad = []
print()
print('TasksLive    base %d | settled floor over last %d cycles %+d (tol 1) | peak %+d (tol %d)'
      % (base['TasksLive'], tail_n, floor_t, peak_t, task_tol))
print('VmaNodesLive base %d | settled floor over last %d cycles %+d (tol 2) | peak %+d (tol %d)'
      % (base['VmaNodesLive'], tail_n, floor_v, peak_v, vma_tol))
print('hamsh rows   base %d | peak %+d (tol 1)' % (base['hamsh'], dh))
if floor_t > 1:
    bad.append('TasksLive never came back to baseline (settled floor %+d over the '
               'last %d of %d cycles) — orphaned child shells' % (floor_t, tail_n, ncyc))
if floor_v > 2:
    bad.append('VmaNodesLive never came back to baseline (settled floor %+d)' % floor_v)
if peak_t > task_tol:
    bad.append('TasksLive peaked %+d above baseline over %d cycles' % (peak_t, ncyc))
if peak_v > vma_tol:
    bad.append('VmaNodesLive peaked %+d above baseline over %d cycles' % (peak_v, ncyc))
if dh > 1:
    bad.append('live hamsh count grew %+d — the terminal is stranding its shell' % dh)
if bad:
    for b in bad:
        print('LEAK: ' + b)
    print('VERDICT: FAIL')
    sys.exit(1)
print('VERDICT: PASS (counters returned to baseline across %d cycles)' % ncyc)
PY
rc=$?
cat "$SUMMARY"
[ "$rc" -ne 0 ] && fail=1

if [ "$fail" -ne 0 ]; then
    echo "$TAG FAIL — see $OUT_DIR" >&2
    exit 1
fi
echo "$TAG PASS ($CYCLES_RUN cycles) — artifacts in $OUT_DIR"
exit 0
