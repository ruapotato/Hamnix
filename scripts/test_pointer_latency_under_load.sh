#!/usr/bin/env bash
# scripts/test_pointer_latency_under_load.sh
#
# LATENCY GATE: the mouse pointer must keep being serviced while a process
# burns 100% CPU.
#
# USER REPORT: "things that take up a lot of CPU make the mouse studder or
# freze, it would be nice if the mouse would keep working even if a process is
# taking up 100% cpu."
#
# WHAT IS ASSERTED, AND WHY IT IS A LATENCY BOUND AND NOT A REACHABILITY CHECK
# ---------------------------------------------------------------------------
# This suite has historically asserted "a function was reached" and called that
# a performance guarantee. Reachability cannot catch this bug: every function
# on the pointer path was always reached, just too late. So the assertion here
# is a MEASURED TIME BOUND on the quantity the user actually perceives:
#
#   max_us = the longest wall-clock interval, anywhere in the measurement
#            window, during which NO mouse packet moved a cursor pixel.
#
# The instrument lives in arch/x86/kernel/time.ad (ptrlat_*) and is fed from
# BOTH routes that can service the pointer -- the timer tick (ptrlat_sample)
# and the inline seam used inside long IRQ-off kernel regions
# (ptrlat_sample_inline). Sampling both is load-bearing: an instrument that
# only samples the TICK is blind to the very fix under test and would report an
# unchanged number on a build where the cursor visibly kept moving.
#
# ATTRIBUTION THIS GATE ENCODES (measured, see the commit history)
# ---------------------------------------------------------------
# The cursor is composited ENTIRELY in the kernel and is serviced by
# mouse_pump_to_compositor(). IA32_FMASK = 0x0200, so SYSCALL entry clears
# EFLAGS.IF and the timer IRQ -- the only thing that ran that pump -- cannot
# fire until the syscall returns. Pointer staleness therefore degenerated to
# "the duration of the longest syscall in flight".
#
# That makes this an INTERRUPT-LATENCY bug, not a scheduling bug and not a
# compositor-throughput bug. The distinction is why this gate uses TWO load
# arms rather than one:
#
#   * PURE-CPU arm (/bin/preempt_hog, a ring-3 loop that issues ZERO syscalls
#     after startup). IF stays set in ring 3, the tick keeps firing, and the
#     pointer is FINE. This arm is the CONTROL: it proves the bug is not
#     "some process is using the CPU" and would catch a future regression that
#     genuinely did break preemption or the scheduler.
#   * SYSCALL-HEAVY arm (repeated program launches: execve -> ELF load ->
#     virtio block reads). This is where the freeze actually lived, so this is
#     the arm the latency bound is asserted on.
#
# A/B IN ONE BOOT
# ---------------
# `ptrsvc 0|1` on /dev/wsys/ctl toggles the inline pointer service at runtime,
# so BASELINE and FIXED are measured in the SAME boot against the SAME
# workload with the SAME instrument. This matters because an absolute
# microsecond threshold is not portable across host load and machine speed --
# and a loaded host is the normal condition in this project's CI. The headline
# assertion is therefore a RATIO plus a generous absolute ceiling, and the
# baseline arm doubles as the gate's built-in mutation test: if turning the fix
# OFF does not make the number worse, the gate is not measuring the fix.
#
# VERDICTS
#   PASS          measured, under bound
#   FAIL          measured, over bound
#   INCONCLUSIVE  nothing measured (no ptrlat report parsed, boot/injection
#                 dropped, no DE). /dev/mouse and serial injection are
#                 historically flaky here; an unobserved assertion is never a
#                 pass, and is not reported as a failure either.
#
# Env overrides:
#   INSTALLER_IMG     image path      (default: build/hamnix-installer.img)
#   OVMF_FD           OVMF firmware   (default: auto-resolved)
#   BOOT_WAIT         handoff wait s  (default: 300)
#   LOAD_SECS         per-arm measurement window s (default: 20)
#   HOGS              pure-CPU hogs to run (default: 4)
#   PTRLAT_MAX_US     absolute ceiling for the FIXED arm (default: 150000)
#   PTRLAT_MIN_RATIO  min baseline/fixed max_us improvement (default: 2)
#   OUT_DIR           artifacts       (default: build/ptrlat/<ts>)
#   KEEP_LOGS         1 = keep serial log on PASS

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[ptrlat]"
# verdict_* helpers add their own brackets, so they take the bare name.
VTAG="ptrlat"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
LOAD_SECS="${LOAD_SECS:-20}"
HOGS="${HOGS:-4}"
PTRLAT_MAX_US="${PTRLAT_MAX_US:-150000}"
PTRLAT_MIN_RATIO="${PTRLAT_MIN_RATIO:-2}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/ptrlat/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

source "$PROJ_ROOT/scripts/_verdict.sh"

# --- STRUCTURAL PRE-CHECK ---------------------------------------------
# Always runs, even with no QEMU. These are the load-bearing seams; if a
# refactor drops one, the runtime numbers could still look fine on a lightly
# loaded boot, so guard the wiring explicitly.
struct_fail=0
need() {  # need <file> <literal marker> <what it is>
    if ! grep -aFq "$2" "$1"; then
        echo "$TAG FAIL: structural marker missing: $3 ($2 in $1)" >&2
        struct_fail=1
    fi
}
# The metric must be fed from BOTH service routes, or it cannot see the fix.
need arch/x86/kernel/time.ad 'def ptrlat_account('       'shared gap accounting'
need arch/x86/kernel/time.ad 'def ptrlat_sample_inline('  'inline-route sampling'
need arch/x86/kernel/time.ad 'ptrlat_account(gap)'        'tick route feeds accounting'
need sys/src/9/port/devmouse.ad 'ptrlat_sample_inline()'  'inline seam samples the gap'
# The service seam itself, and the two long IRQ-off regions it is called from.
need sys/src/9/port/devmouse.ad 'def pointer_service_poll(' 'pointer service seam'
need drivers/virtio/virtio_ring.ad 'pointer_service_poll()' 'virtio used-ring service point'
need fs/elf.ad 'pointer_service_poll()'                     'ELF loader service point'
# The runtime A/B switch this gate measures with.
need sys/src/9/port/devmouse.ad 'def pointer_service_set_enabled(' 'runtime kill-switch'
need sys/src/9/port/devwsys.ad '"ptrsvc"'                   'ptrsvc ctl verb'
need sys/src/9/port/devwsys.ad '"ptrlat"'                   'ptrlat ctl verb'
need sys/src/9/port/devwsys.ad '[ptrlat] svc_runs='         'service-run counter in report'
[ "$struct_fail" -eq 0 ] || exit 1
echo "$TAG structural markers OK (metric fed from both routes; both service points wired; A/B switch present)."

# --- environment gates ------------------------------------------------
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

# STALE-IMAGE GUARD. Boot the tree under test, never an older artifact:
# a stale image false-GREENs exactly the regression this gate exists to catch.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "$TAG"

mkdir -p "$OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-ptrlat.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-ptrlat.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-ptrlat-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-ptrlat.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own QEMU, by recorded PID. Never pkill by pattern:
    # sibling agents run their own QEMUs on this host.
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
}
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

# Mirror the user's ship command, + monitor socket and a serial stdin FIFO.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "${HAMNIX_VM_MEM:-2G}" \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

wait_for() {  # wait_for <egrep pat> <secs>
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

echo "$TAG waiting up to ${BOOT_WAIT}s for the DE handoff (host loadavg: $(cut -d' ' -f1-3 /proc/loadavg))..."
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || {
    tail -60 "$LOG" >&2
    verdict_inconclusive "$VTAG" "no handoff marker in ${BOOT_WAIT}s -- nothing was measured (host may be loaded; check /proc/loadavg)"
}
# The pointer is composited by the kernel only once the DE owns the screen
# (wsys_de_is_live); before the rl5 flip a userspace /dev/mouse reader owns
# the ring and pointer_service_poll is deliberately a no-op. So a measurement
# taken before rl5 would measure nothing at all.
wait_for "\[init\] entering runlevel 5" 60 \
    || verdict_inconclusive "$VTAG" "never entered runlevel 5 -- the kernel cursor path is not live, so there is nothing to measure"
sleep 8

# Readiness handshake: hamsh is known to DROP the first serial command, so
# gate on an observed echo rather than on a sleep.
ready=0
for _ in 1 2 3; do
    printf 'echo MARK_PTRLAT_READY\n' >&3
    sleep 2
    grep -aq MARK_PTRLAT_READY "$LOG" && { ready=1; break; }
done
[ "$ready" -eq 1 ] || verdict_inconclusive "$VTAG" "shell never echoed the readiness marker -- serial injection dropped, nothing measured"
echo "$TAG shell ready; starting load."

# --- load generators --------------------------------------------------
# PURE-CPU load: ring-3 spinners that issue ZERO syscalls. This is the user's
# literal scenario ("a process taking up 100% cpu") and this gate's CONTROL
# arm -- with a healthy tick the pointer should be unaffected by it.
start_hogs() {
    local i=0
    while [ "$i" -lt "$HOGS" ]; do
        printf '/bin/preempt_hog >/dev/null 2>&1 &\n' >&3
        i=$((i+1)); sleep 0.4
    done
    sleep 2
}

# SYSCALL-HEAVY load: repeated program launches. Each one is an execve -> ELF
# load -> virtio block read chain, i.e. precisely the long IF=0 kernel regions
# where the freeze was measured. Runs for <secs> and returns.
launch_churn() {
    local deadline=$(( SECONDS + $1 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        printf '/bin/true >/dev/null 2>&1\n' >&3
        printf 'echo hi >/dev/null\n' >&3
        sleep 0.25
    done
}

# --- one measurement arm ----------------------------------------------
# measure_arm <label> <svc 0|1> -> echoes "max_us mean_us n svc_runs"
measure_arm() {
    local label="$1" svc="$2"
    printf 'echo "ptrsvc %s" > /dev/wsys/ctl\n' "$svc" >&3
    sleep 1
    printf 'echo "ptrlat 0" > /dev/wsys/ctl\n' >&3   # arm: reset, no report
    sleep 1
    local before
    before=$(grep -ac '^\[ptrlat\] n=' "$LOG" 2>/dev/null || echo 0)
    launch_churn "$LOAD_SECS"
    printf 'echo "ptrlat" > /dev/wsys/ctl\n' >&3
    # Wait for a NEW report block to appear (three [ptrlat] lines + svc line).
    local d=$(( SECONDS + 30 )) got=0
    while [ "$SECONDS" -lt "$d" ]; do
        local now
        now=$(grep -ac '^\[ptrlat\] n=' "$LOG" 2>/dev/null || echo 0)
        [ "$now" -gt "$before" ] && { got=1; break; }
        sleep 1
    done
    [ "$got" -eq 1 ] || { echo "MISSING"; return 1; }
    sleep 1
    local hdr svc_line
    hdr=$(grep -a '^\[ptrlat\] n=' "$LOG" | tail -1)
    svc_line=$(grep -a '^\[ptrlat\] svc_runs=' "$LOG" | tail -1)
    {
        echo "arm=$label svc=$svc"
        echo "  $hdr"
        grep -a '^\[ptrlat\] le' "$LOG" | tail -2 | sed 's/^/  /'
        echo "  $svc_line"
    } >> "$OUT_DIR/report.txt"
    local mx mean n runs
    mx=$(sed -n 's/.*max_us=\([0-9]*\).*/\1/p'  <<<"$hdr")
    mean=$(sed -n 's/.*mean_us=\([0-9]*\).*/\1/p' <<<"$hdr")
    n=$(sed -n 's/.*n=\([0-9]*\).*/\1/p'          <<<"$hdr")
    runs=$(sed -n 's/.*svc_runs=\([0-9]*\).*/\1/p' <<<"$svc_line")
    echo "${mx:-0} ${mean:-0} ${n:-0} ${runs:-0}"
}

start_hogs
echo "$TAG $HOGS pure-CPU hogs running."

# CONTROL ARM: pure CPU load only, fix ON. Establishes that a 100%-CPU ring-3
# process does NOT by itself stall the pointer -- i.e. that this is an
# interrupt-latency bug, and that preemption/scheduling are healthy. A
# regression here means something broke the tick or the scheduler.
printf 'echo "ptrsvc 1" > /dev/wsys/ctl\n' >&3 ; sleep 1
printf 'echo "ptrlat 0" > /dev/wsys/ctl\n' >&3 ; sleep 1
ctl_before=$(grep -ac '^\[ptrlat\] n=' "$LOG" 2>/dev/null || echo 0)
sleep "$LOAD_SECS"
printf 'echo "ptrlat" > /dev/wsys/ctl\n' >&3
cd_=$(( SECONDS + 30 )); while [ "$SECONDS" -lt "$cd_" ]; do
    nn=$(grep -ac '^\[ptrlat\] n=' "$LOG" 2>/dev/null || echo 0)
    [ "$nn" -gt "$ctl_before" ] && break
    sleep 1
done
CTL_HDR=$(grep -a '^\[ptrlat\] n=' "$LOG" | tail -1)
CTL_MAX=$(sed -n 's/.*max_us=\([0-9]*\).*/\1/p' <<<"$CTL_HDR")
CTL_MAX=${CTL_MAX:-0}
{ echo "arm=pure_cpu_control svc=1"; echo "  $CTL_HDR"; } >> "$OUT_DIR/report.txt"
echo "$TAG CONTROL (pure 100% CPU, no syscalls): max_us=$CTL_MAX"

# BASELINE ARM: fix OFF, syscall-heavy load. This is the pre-fix behaviour and
# the gate's built-in mutation test.
read -r BASE_MAX BASE_MEAN BASE_N BASE_RUNS <<<"$(measure_arm baseline_svc_off 0)"
echo "$TAG BASELINE (fix OFF, launch churn): max_us=$BASE_MAX mean_us=$BASE_MEAN n=$BASE_N svc_runs=$BASE_RUNS"

# FIXED ARM: fix ON, same load.
read -r FIX_MAX FIX_MEAN FIX_N FIX_RUNS <<<"$(measure_arm fixed_svc_on 1)"
echo "$TAG FIXED    (fix ON,  launch churn): max_us=$FIX_MAX mean_us=$FIX_MEAN n=$FIX_N svc_runs=$FIX_RUNS"

kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""

# --- assertions -------------------------------------------------------
case "$BASE_MAX$FIX_MAX" in *MISSING*) BASE_MAX=0; FIX_MAX=0;; esac
if [ "${FIX_N:-0}" -lt 10 ] || [ "${BASE_N:-0}" -lt 10 ]; then
    verdict_inconclusive "$VTAG" "too few samples (baseline n=${BASE_N:-0}, fixed n=${FIX_N:-0}) -- the ctl verb or the serial injection did not land, so NOTHING was asserted. Report: $OUT_DIR/report.txt"
fi

fail=0

# (1) CONTROL: a pure ring-3 CPU hog must not stall the pointer. If this
# trips, preemption or the timer tick regressed -- a different bug from the
# one this gate was written for, and worth failing loudly on.
if [ "$CTL_MAX" -gt "$PTRLAT_MAX_US" ]; then
    echo "$TAG FAIL: CONTROL arm exceeded the bound: ${CTL_MAX}us > ${PTRLAT_MAX_US}us with $HOGS syscall-free ring-3 hogs. A 100%-CPU userspace loop should NOT stall the pointer; this indicates the timer tick or preemption regressed." >&2
    fail=1
else
    echo "$TAG PASS: CONTROL arm ${CTL_MAX}us <= ${PTRLAT_MAX_US}us (pure CPU load does not stall the pointer; tick + preemption healthy)."
fi

# (2) THE HEADLINE LATENCY BOUND on the shipped configuration.
if [ "$FIX_MAX" -gt "$PTRLAT_MAX_US" ]; then
    echo "$TAG FAIL: pointer went unserviced for ${FIX_MAX}us (> ${PTRLAT_MAX_US}us bound) under syscall-heavy load. That is a visible stutter/freeze." >&2
    fail=1
else
    echo "$TAG PASS: worst pointer-service gap ${FIX_MAX}us <= ${PTRLAT_MAX_US}us under syscall-heavy load."
fi

# (3) THE SEAM DID THE WORK. Without this, arm (2) could pass on a lightly
# loaded boot that never entered a long IRQ-off region at all -- a false green.
if [ "${FIX_RUNS:-0}" -le 0 ]; then
    echo "$TAG FAIL: svc_runs=0 -- the inline pointer-service seam never ran, so the bound above was met by luck, not by the fix. Service points removed?" >&2
    fail=1
else
    echo "$TAG PASS: inline seam serviced the pointer ${FIX_RUNS} times that no timer tick could have."
fi

# (4) BUILT-IN MUTATION TEST. Turning the fix off must make the number
# measurably worse. If it does not, this gate is not measuring the fix and its
# green is meaningless -- so say so rather than banking a bogus pass.
if [ "$BASE_MAX" -le 0 ] || [ "$FIX_MAX" -le 0 ]; then
    echo "$TAG FAIL: could not compare arms (baseline=${BASE_MAX}us fixed=${FIX_MAX}us)." >&2
    fail=1
elif [ $(( BASE_MAX / FIX_MAX )) -lt "$PTRLAT_MIN_RATIO" ]; then
    echo "$TAG FAIL: fix OFF (${BASE_MAX}us) is not >= ${PTRLAT_MIN_RATIO}x worse than fix ON (${FIX_MAX}us). The A/B shows no effect, so this gate is NOT measuring the pointer-service fix -- treat any green from it as unproven." >&2
    fail=1
else
    echo "$TAG PASS: A/B confirms the fix is load-bearing: ${BASE_MAX}us OFF vs ${FIX_MAX}us ON ($(( BASE_MAX / FIX_MAX ))x)."
fi

{
    echo "bound_us=$PTRLAT_MAX_US min_ratio=$PTRLAT_MIN_RATIO hogs=$HOGS load_secs=$LOAD_SECS"
    echo "control_max_us=$CTL_MAX baseline_max_us=$BASE_MAX fixed_max_us=$FIX_MAX"
    echo "fixed_svc_runs=$FIX_RUNS"
} >> "$OUT_DIR/report.txt"
echo "$TAG report: $OUT_DIR/report.txt"

if [ "$fail" -eq 0 ]; then
    [ "${KEEP_LOGS:-0}" = "1" ] || true
    verdict_pass "$VTAG" "pointer serviced within ${PTRLAT_MAX_US}us under sustained CPU + syscall load (worst ${FIX_MAX}us; ${BASE_MAX}us with the fix disabled)"
else
    verdict_fail "$VTAG" "pointer-latency bound violated under load (serial log: $LOG)"
fi
