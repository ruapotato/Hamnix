#!/usr/bin/env bash
# scripts/test_de_pointer_irqoff.sh
#
# THE REAL DESKTOP, THE REAL POINTER PATH, UNDER KVM.
#
# USER REPORT: "things that take up a lot of CPU make the mouse studder or
# freze, it would be nice if the mouse would keep working even if a process is
# taking up 100% cpu."
#
# WHY THIS EXISTS SEPARATELY FROM scripts/test_syscall_irqoff.sh
# -------------------------------------------------------------
# That gate measures the same quantity -- how long a syscall holds EFLAGS.IF
# clear, attributed per syscall -- but it does it on a LIGHTWEIGHT hamsh boot
# under TCG, with no DE, and with a synthetic workload. Three gaps, all of
# which matter for the reported symptom:
#
#   * NO DE. The user's mouse is serviced by the kernel compositor once the
#     DE owns the screen (wsys_de_is_live). The DE's own long IRQ-off regions
#     -- wsys_scene_present / _wsys_present_commit_impl wrap the whole
#     rasterize + recompose + flush in local_irq_save() -- only exist on a
#     real DE boot, and they are reached through a syscall, so this
#     instrument is exactly the thing that can see them. On the hamsh boot
#     they are not exercised at all.
#   * TCG, NOT KVM. TCG inflates syscall duration by one to two orders of
#     magnitude, so a TCG number cannot be used to clear a KVM machine (nor
#     to condemn one). The "IA32_FMASK holds IF clear for 10-14 ms" claim was
#     made about KVM specifically.
#   * SYNTHETIC WORKLOAD vs the shipped image. This gate boots the same .img
#     the user boots, under UEFI/OVMF, with the same load the pointer-latency
#     gate uses.
#
# WHAT IS MEASURED. Identical to test_syscall_irqoff.sh: the EXCESS over the
# nominal tick period, i.e. how late a timer IRQ that was already DUE got
# delivered because a syscall was holding IF clear, attributed to that
# syscall by name. See the banner over SYSIRQ_TICK_NS in
# arch/x86/kernel/time.ad. The timer IRQ is the only thing that runs
# mouse_pump_to_compositor(), so a delayed tick is a cursor that did not move.
#
# RELATION TO scripts/test_pointer_latency_under_load.sh: that gate measures
# the OUTCOME (longest interval with no cursor update) on this same image and
# workload. This one measures the CAUSE and NAMES it. Run together they say
# both "the pointer was fine" and "here is why, and here is what would have to
# regress for it not to be".
#
# Not in ci_battery_manifest.txt because it needs /dev/kvm, OVMF and a built
# installer image, none of which a GitHub runner has: registered, it would
# hit the `[ -e /dev/kvm ] || exit 0` bail on every CI run and add one more
# permanently-green gate that never asserts anything (see
# scripts/test_gate_kvmdark.sh — that population is a shrinking ratchet and
# this would enlarge it). It is a HOST-RUN gate, run on a machine with KVM
# alongside scripts/test_pointer_latency_under_load.sh, which has exactly the
# same requirements. The CI-safe half of this measurement is
# scripts/test_syscall_irqoff.sh, which is registered and needs no KVM.
#
# VERDICTS
#   PASS          measured, under bound
#   FAIL          measured, over bound
#   INCONCLUSIVE  nothing measured (no report, no DE, injection dropped, no
#                 KVM/OVMF/socat). An unobserved assertion is never a pass.
#
# Env overrides:
#   INSTALLER_IMG     image path      (default: build/hamnix-installer.img)
#   OVMF_FD           OVMF firmware   (default: auto-resolved)
#   BOOT_WAIT         handoff wait s  (default: 300)
#   HOGS              pure-CPU hogs   (default: 4)
#   SYSIRQ_MAX_US     tick-delay ceiling, us (default: 6000)
#   OUT_DIR           artifacts       (default: build/sysirq-de/<ts>)

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[sysirq-de]"
VTAG="sysirq-de"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
HOGS="${HOGS:-4}"
SYSIRQ_MAX_US="${SYSIRQ_MAX_US:-6000}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/sysirq-de/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

source "$PROJ_ROOT/scripts/_verdict.sh"

# --- STRUCTURAL PRE-CHECK (runs with or without KVM) ------------------
struct_fail=0
need() {
    if ! grep -aFq "$2" "$1"; then
        echo "$TAG FAIL: structural marker missing: $3 ($2 in $1)" >&2
        struct_fail=1
    fi
}
need arch/x86/kernel/time.ad 'def sysirq_report'  'the report this gate parses'
need arch/x86/kernel/time.ad 'def sysirq_name'    'per-syscall NAMES'
need sys/src/9/port/devproc.ad '"sysirq"'         'the control verb'
need sys/src/9/port/devwsys.ad '"sysirq"'         'the /dev/wsys/ctl surface this gate drives'
[ "$struct_fail" -eq 0 ] || { verdict_fail "$VTAG" "structural seams missing"; exit 1; }
echo "$TAG structural markers OK."

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

# STALE-IMAGE GUARD. Boot the tree under test, never an older artifact.
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "$TAG"

mkdir -p "$OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-sysirqde.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-sysirqde.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-sysirqde-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-sysirqde.XXXXXX).in
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
    verdict_inconclusive "$VTAG" "no handoff marker in ${BOOT_WAIT}s -- nothing was measured"
}
# The kernel only composites the cursor once the DE owns the screen. Before
# the rl5 flip there is no DE pointer path to measure, so a measurement taken
# earlier would describe a different machine.
# Wait for the rl5 FLIP itself, not for an init log line: the flip is the
# event that makes the kernel own the cursor, and its marker is stable
# ("[scene_de] kernel scene compositor owns /dev/fb (rl5 flip)"). The init-side
# wording varies between boots — one run printed "[init] entering runlevel 5"
# and the next "rc.boot: entered runlevel 5", which cost a whole boot.
wait_for "rl5 flip|entered runlevel 5|entering runlevel 5" 120 \
    || verdict_inconclusive "$VTAG" "never reached the runlevel-5 flip -- the DE pointer path is not live"
sleep 8

ready=0
for _ in 1 2 3; do
    printf 'echo MARK_SYSIRQ_READY\n' >&3
    sleep 2
    grep -aq MARK_SYSIRQ_READY "$LOG" && { ready=1; break; }
done
[ "$ready" -eq 1 ] || verdict_inconclusive "$VTAG" \
    "shell never echoed the readiness marker -- serial injection dropped, nothing measured"
echo "$TAG shell ready."

# --- load: the user's literal scenario --------------------------------
# Pure-CPU ring-3 spinners that issue ZERO syscalls after startup. Nothing is
# injected during a measurement window: the guest shell echoes typed input
# character by character, so injecting while loaded garbles commands and has
# previously produced a silent zero-load "measurement".
start_hogs() {
    local i=0
    while [ "$i" -lt "$HOGS" ]; do
        printf '/bin/preempt_hog &\n' >&3
        i=$((i+1)); sleep 4
    done
    local d=$(( SECONDS + 60 ))
    while [ "$SECONDS" -lt "$d" ]; do
        [ "$(grep -ac 'hog: running tight CPU loop' "$LOG")" -ge "$HOGS" ] && return 0
        sleep 1
    done
    return 1
}
start_hogs || verdict_inconclusive "$VTAG" \
    "only $(grep -ac 'hog: running tight CPU loop' "$LOG")/$HOGS CPU hogs started -- the box was NOT under load, so any number here would describe an idle machine"
echo "$TAG $HOGS pure-CPU hogs confirmed running."

# ARM the instrument, run the syscall-heavy storm in the FOREGROUND (one
# execve + ELF load + virtio block read per path under /bin), then report.
printf 'echo "sysirq 1" > /dev/wsys/ctl\n' >&3
sleep 3
if ! grep -aq '\[sysirq\] ack armed=1' "$LOG"; then
    verdict_inconclusive "$VTAG" \
        "the kernel never acknowledged 'sysirq 1' -- the instrument was never armed, so nothing was measured"
fi
echo "$TAG instrument armed; running the exec/ELF-load storm."
# Bounded with head -40: the full /bin walk did not finish in 240 s on a KVM
# guest carrying four 100%-CPU hogs, and an unfinished storm means the window
# never closes. 40 execve + ELF load + virtio block reads is plenty of the
# shape we are measuring.
printf '%s\n' "/bin/find /bin | /bin/head -40 | /bin/xargs -n 1 /bin/true ; echo STORM_DONE" >&3
storm_ok=0
d=$(( SECONDS + 420 ))
while [ "$SECONDS" -lt "$d" ]; do
    # TWO occurrences, not one. hamsh echoes typed input character by
    # character, so the command line itself puts the marker in the log before
    # anything has run — the first version of this loop matched its own echo
    # and declared the storm complete about 0.2 s after starting it.
    [ "$(grep -ac 'STORM_DONE' "$LOG")" -ge 2 ] && { storm_ok=1; break; }
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 2
done
[ "$storm_ok" -eq 1 ] || verdict_inconclusive "$VTAG" \
    "the syscall storm never completed -- the measurement window did not close"
sleep 2
printf 'echo "sysirq 2" > /dev/wsys/ctl\n' >&3
sleep 5
printf 'echo "sysirq 0" > /dev/wsys/ctl\n' >&3
sleep 2

kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""

grep -a '\[sysirq\]' "$LOG" | grep -av '\[K' > "$OUT_DIR/report.txt"
echo "$TAG --- measured (real DE, KVM) ---"
cat "$OUT_DIR/report.txt"
echo "$TAG --- end ---"

hdr=$(grep -a '\[sysirq\] n=' "$LOG" | grep -av '\[K' | tail -1)
[ -n "$hdr" ] || verdict_inconclusive "$VTAG" \
    "no sysirq report on the console -- the report verb did not land"
N=$(sed -n 's/.*\[sysirq\] n=\([0-9]*\).*/\1/p' <<<"$hdr")
mx=$(grep -a '\[sysirq\] max_us=' "$LOG" | grep -av '\[K' | tail -1 \
     | sed -n 's/.*max_us=\([0-9]*\).*/\1/p')
dl=$(grep -a '\[sysirq\] delayed=' "$LOG" | grep -av '\[K' | tail -1 \
     | sed -n 's/.*delayed=\([0-9]*\).*/\1/p')
if [ -z "${N:-}" ] || [ "${N:-0}" -lt 1000 ]; then
    verdict_inconclusive "$VTAG" \
        "only ${N:-0} syscalls sampled on the DE boot -- the arm or the storm did not land"
fi

echo "$TAG DE + KVM: n=$N delayed=${dl:-?} max_us=${mx:-?}"
echo "$TAG --- worst offenders by name ---"
grep -aE '\[sysirq\] top\+? ' "$LOG" | grep -av '\[K' || true
echo "$TAG --- end ---"

if [ "${mx:-999999}" -gt "$SYSIRQ_MAX_US" ]; then
    worst=$(grep -a '\[sysirq\] top+ ' "$LOG" | grep -av '\[K' | head -1)
    verdict_fail "$VTAG" "on the real DE under KVM a syscall delayed a due timer IRQ by ${mx}us (> ${SYSIRQ_MAX_US}us) while four processes burned 100% CPU — that is a visible cursor freeze. Worst: $worst"
    exit 1
fi
verdict_pass "$VTAG" "on the real DE under KVM no syscall delays a due timer IRQ past ${SYSIRQ_MAX_US}us under $HOGS x 100%-CPU + an exec/ELF-load storm (worst ${mx}us over $N syscalls)"
exit 0
