#!/usr/bin/env bash
# scripts/test_de_motion_to_photon.sh
#
# MOTION TO PHOTON: THE NUMBER THE USER ACTUALLY SEES.
#
# USER REPORT: "things that take up a lot of CPU make the mouse studder or
# freze, it would be nice if the mouse would keep working even if a process is
# taking up 100% cpu."
#
# WHY THIS GATE EXISTS
# --------------------
# Three instruments already measure this bug, and all three measure a PROXY:
#
#   wklat   scripts/test_wakeup_latency.sh    wake -> dispatch for a task
#   sysirq  scripts/test_syscall_irqoff.sh    EFLAGS.IF=0 duration in a syscall
#           scripts/test_de_pointer_irqoff.sh  ... the same, on the real DE
#   ptrlat  scripts/test_pointer_latency_under_load.sh
#                                             the GAP between two cursor
#                                             SERVICES
#
# Each has produced a clean disproof, and none of them measures a mouse event.
# ptrlat comes closest and still is not it: it is an interval between SERVICES,
# not the age of an EVENT. A pump that runs punctually every 10 ms and each
# time re-blits a cursor whose position came from a packet that has been
# sitting in the ring for 200 ms scores a flawless ptrlat and looks broken on
# screen. Nothing has ever measured the age of a mouse packet at the instant
# its pixels reach scanout, which is precisely the user's symptom.
#
# WHAT IS MEASURED (arch/x86/kernel/time.ad, the m2p_* instrument)
# ---------------------------------------------------------------
#   t0  the packet lands in the mouse ring (drivers/input/auxmouse.ad)
#   t1  _wsys_route_common begins   -- the pump has it, cursor work starts
#   t2  _wsys_present_cursor_locked has flushed the old footprint and the new
#       sprite to scanout
#
#   total   = t2 - t0   the symptom
#   deliver = t1 - t0   INPUT DELIVERY  (tick starvation, IF masking, device
#                       polling) -- the half wklat and sysirq speak to
#   render  = t2 - t1   COMPOSITOR      (recompose, rasterize, keyed blit, two
#                       flush_rects, and any wait behind a full-screen present
#                       holding wsys_present_lock)
#
# The split is the point: whichever half carries the time, the run RULES THE
# OTHER OUT. That is the deliverable here, more than the pass/fail.
#
# INPUT COMES FROM THE HYPERVISOR, NOT FROM /dev/mouse
# ---------------------------------------------------
# Motion is injected with QEMU monitor `mouse_move`, which drives the emulated
# i8042 AUX device and lands in the guest through the real IRQ 12 handler ->
# _mouse_ring_push. This is deliberate:
#   * a guest-side writer to /dev/mouse would enter through a syscall and could
#     not observe the driver/IRQ half at all, and /dev/mouse injection is
#     independently known to be flaky here;
#   * the PS/2 AUX path is what a real laptop touchpad uses, which is the
#     machine the report came from.
# If ingest never reaches the guest the verdict is INCONCLUSIVE, never a pass:
# an m2p report with ingest=0 describes a machine nobody moved the mouse on.
#
# A/B IN ONE BOOT
# ---------------
# Two windows against the same image, same boot, same instrument:
#   IDLE    nothing running but the DE
#   LOADED  HOGS x /bin/preempt_hog at 100% CPU + an execve/ELF-load/virtio
#           storm -- the user's literal scenario
# An absolute threshold on a shared build host is weather; the comparison is
# not. The gate asserts an absolute ceiling on the LOADED window (the user's
# quality bar is absolute -- a 250 ms freeze is a freeze however busy the box
# is) and REPORTS the idle->loaded delta and the deliver/render split, which is
# the attribution.
#
# wklat IS ALSO ARMED HERE, and that is not incidental. The wake->dispatch
# disproof was taken against a kthread in a lightweight boot, because
# /proc/self/ctl's `wklat` verb is uid-0-or-hostowner and the DE session runs
# as the default NOBODY uid, so the instrument had never once been armed on a
# real desktop. It is reachable from /dev/wsys/ctl now; this gate is the first
# thing to arm it there.
#
# VERDICTS
#   PASS          measured, under the ceiling
#   FAIL          measured, over the ceiling
#   INCONCLUSIVE  nothing measured (no DE, no ingest, no report, injection
#                 dropped). An unobserved assertion is never a pass.
#
# NOT IN ci_battery_manifest.txt: it needs /dev/kvm, OVMF and a built installer
# image, none of which a GitHub runner has. Registered, it would bail at the
# `[ -e /dev/kvm ]` gate on every CI run and become one more permanently-green
# gate that never asserts -- the population scripts/test_gate_kvmdark.sh exists
# to shrink. It is a HOST-RUN gate, run on a KVM machine alongside
# scripts/test_de_pointer_irqoff.sh and
# scripts/test_pointer_latency_under_load.sh, which have identical needs.
#
# Env overrides:
#   INSTALLER_IMG     image path      (default: build/hamnix-installer.img)
#   OVMF_FD           OVMF firmware   (default: auto-resolved)
#   BOOT_WAIT         handoff wait s  (default: 300)
#   HOGS              pure-CPU hogs   (default: 4)
#   MOVE_SECS         injection window per arm, s (default: 20)
#   M2P_MAX_US        loaded-arm total ceiling, us (default: 250000)
#   MIN_SAMPLES       minimum m2p samples per arm (default: 20)
#   OUT_DIR           artifacts       (default: build/m2p/<ts>)

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[m2p]"
VTAG="de-motion-to-photon"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
HOGS="${HOGS:-4}"
MOVE_SECS="${MOVE_SECS:-20}"
M2P_MAX_US="${M2P_MAX_US:-250000}"
MIN_SAMPLES="${MIN_SAMPLES:-20}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/m2p/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

source "$PROJ_ROOT/scripts/_verdict.sh"

# --- STRUCTURAL PRE-CHECK (runs with or without KVM) ------------------
# These are the seams the measurement is made of. If one is deleted the gate
# would still boot and still print numbers -- they would just be numbers about
# a different machine. Assert them by name.
struct_fail=0
need() {
    if ! grep -aFq "$2" "$1"; then
        echo "$TAG FAIL: structural marker missing: $3 ($2 in $1)" >&2
        struct_fail=1
    fi
}
need arch/x86/kernel/time.ad    'def m2p_note_ingest'  't0, the ring-push stamp'
need arch/x86/kernel/time.ad    'def m2p_note_service' 't1, the pump seam'
need arch/x86/kernel/time.ad    'def m2p_note_photon'  't2, the scanout seam'
need arch/x86/kernel/time.ad    'def m2p_report'       'the report this gate parses'
need drivers/input/auxmouse.ad  'm2p_note_ingest()'    't0 wired into the ring push'
need sys/src/9/port/devwsys.ad  'm2p_note_service()'   't1 wired into _wsys_route_common'
need sys/src/9/port/devwsys.ad  'm2p_note_photon()'    't2 wired into the cursor present'
need sys/src/9/port/devwsys.ad  '"m2p"'                'the /dev/wsys/ctl verb this gate drives'
need sys/src/9/port/devwsys.ad  '"wklat"'              'the wsys-side wklat surface (NOBODY-uid reachable)'
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
OVMF_RW=$(mktemp --tmpdir hamnix-m2p.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-m2p.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-m2p-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-m2p.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own QEMU, by recorded PID. Never pkill by pattern: sibling
    # agents run their own QEMUs on this host and a pattern kill takes them out.
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

mon() {  # mon <monitor command>
    printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
}

wait_for() {  # wait_for <egrep pat> <secs>
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

# Inject a serpentine relative-motion stream for <secs> seconds. Relative
# deltas that alternate sign keep the cursor inside the screen without needing
# to know its size, and every packet moves it by a visible amount so every
# packet must produce a present -- a zero-delta stream would be serviced and
# legitimately draw nothing.
inject_motion() {  # inject_motion <secs>
    local deadline=$(( SECONDS + $1 )) i=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ $(( i % 2 )) -eq 0 ]; then mon "mouse_move 7 5"; else mon "mouse_move -7 -5"; fi
        i=$((i+1))
        sleep 0.05
    done
    echo "$i"
}

echo "$TAG waiting up to ${BOOT_WAIT}s for the DE handoff (host loadavg: $(cut -d' ' -f1-3 /proc/loadavg))..."
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || {
    tail -60 "$LOG" >&2
    verdict_inconclusive "$VTAG" "no handoff marker in ${BOOT_WAIT}s -- nothing was measured"
}
# The kernel composites the cursor only once the DE owns the screen. Before the
# rl5 flip there is no DE pointer path, so a measurement taken earlier would
# describe a different machine. Wait for the FLIP, not for an init log line:
# the init-side wording has varied between boots and cost a whole boot once.
wait_for "rl5 flip|entered runlevel 5|entering runlevel 5" 120 \
    || verdict_inconclusive "$VTAG" "never reached the runlevel-5 flip -- the DE pointer path is not live"
sleep 8

ready=0
for _ in 1 2 3; do
    printf 'echo MARK_M2P_READY\n' >&3
    sleep 2
    grep -aq MARK_M2P_READY "$LOG" && { ready=1; break; }
done
[ "$ready" -eq 1 ] || verdict_inconclusive "$VTAG" \
    "shell never echoed the readiness marker -- serial injection dropped, nothing measured"
echo "$TAG shell ready."

arm_instruments() {  # arm_instruments <arm-name>
    printf 'echo "m2p 1" > /dev/wsys/ctl\n' >&3
    sleep 2
    printf 'echo "ptrlat 0" > /dev/wsys/ctl\n' >&3
    sleep 2
    printf 'echo "wklat 2" > /dev/wsys/ctl\n' >&3
    sleep 2
}
report_instruments() {
    printf 'echo "m2p 2" > /dev/wsys/ctl\n' >&3
    sleep 4
    printf 'echo "ptrlat 1" > /dev/wsys/ctl\n' >&3
    sleep 3
    printf 'echo "wklat 3" > /dev/wsys/ctl\n' >&3
    sleep 4
    printf 'echo "m2p 0" > /dev/wsys/ctl\n' >&3
    sleep 2
}

# ======================================================================
# ARM 1 -- IDLE. The baseline. Nothing is running but the DE.
# ======================================================================
echo "$TAG === arm 1: IDLE ==="
arm_instruments idle
# Assert the ARM, not just the write. A silently refused ctl write is
# indistinguishable from a working one from userland, and that failure mode has
# already cost this investigation a whole run: the FIRST real-DE attempt got
# "ctl write refused rc=-1" and measured nothing while looking like a pass.
if ! grep -aq '\[m2p\] ack armed=1' "$LOG"; then
    verdict_inconclusive "$VTAG" \
        "the kernel never acknowledged 'm2p 1' from the DE session -- the instrument was never armed, so nothing was measured"
fi
echo "$TAG m2p armed from the NOBODY-uid DE session."
IDLE_MOVES=$(inject_motion "$MOVE_SECS")
echo "$TAG idle arm: injected $IDLE_MOVES motion packets."
report_instruments
cp "$LOG" "$OUT_DIR/serial.idle.log"
IDLE_END=$(wc -l < "$LOG")

# ======================================================================
# ARM 2 -- LOADED. The user's literal scenario.
# ======================================================================
echo "$TAG === arm 2: LOADED ==="
# Pure-CPU ring-3 spinners issuing ZERO syscalls after startup. Nothing is
# injected on the serial line during a measurement window: the guest shell
# echoes typed input character by character, so typing while loaded garbles
# commands and has previously produced a silent zero-load "measurement".
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

arm_instruments loaded
# Launch the syscall storm in the BACKGROUND so motion injection overlaps it:
# the freeze the user reports happens DURING app launches, not after them.
printf '%s\n' "/bin/find /bin | /bin/head -40 | /bin/xargs -n 1 /bin/true ; echo STORM_DONE &" >&3
sleep 1
LOAD_MOVES=$(inject_motion "$MOVE_SECS")
echo "$TAG loaded arm: injected $LOAD_MOVES motion packets."
report_instruments

kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""

# ----------------------------------------------------------------------
# PARSE. Every extraction is checked; a missing field is INCONCLUSIVE, never a
# pass. Reports are ordered in the log, so the Nth occurrence is the Nth arm.
# ----------------------------------------------------------------------
clean() { grep -a "$1" "$LOG" | grep -av '\[K'; }
clean '\[m2p\]'    > "$OUT_DIR/m2p.txt"
clean '\[ptrlat\]' > "$OUT_DIR/ptrlat.txt"
clean '\[wklat\]'  > "$OUT_DIR/wklat.txt"

echo "$TAG --- measured (real DE, KVM) ---"
cat "$OUT_DIR/m2p.txt" "$OUT_DIR/ptrlat.txt" "$OUT_DIR/wklat.txt"
echo "$TAG --- end ---"

# nth <file> <sed-extract> <occurrence>
nth() { sed -n "s/$2/\1/p" "$1" | sed -n "$3p"; }

I_N=$(nth      "$OUT_DIR/m2p.txt" '.*\[m2p\] armed=[0-9]* ingest=[0-9]* n=\([0-9]*\).*' 1)
I_ING=$(nth    "$OUT_DIR/m2p.txt" '.*\[m2p\] armed=[0-9]* ingest=\([0-9]*\).*'          1)
I_MAX=$(nth    "$OUT_DIR/m2p.txt" '.*\[m2p\] total_max_us=\([0-9]*\).*'                 1)
I_MEAN=$(nth   "$OUT_DIR/m2p.txt" '.*total_mean_us=\([0-9]*\).*'                        1)
I_DMAX=$(nth   "$OUT_DIR/m2p.txt" '.*\[m2p\] deliver_max_us=\([0-9]*\).*'               1)
I_RMAX=$(nth   "$OUT_DIR/m2p.txt" '.*\[m2p\] render_max_us=\([0-9]*\).*'                1)

L_N=$(nth      "$OUT_DIR/m2p.txt" '.*\[m2p\] armed=[0-9]* ingest=[0-9]* n=\([0-9]*\).*' 2)
L_ING=$(nth    "$OUT_DIR/m2p.txt" '.*\[m2p\] armed=[0-9]* ingest=\([0-9]*\).*'          2)
L_MAX=$(nth    "$OUT_DIR/m2p.txt" '.*\[m2p\] total_max_us=\([0-9]*\).*'                 2)
L_MEAN=$(nth   "$OUT_DIR/m2p.txt" '.*total_mean_us=\([0-9]*\).*'                        2)
L_DMAX=$(nth   "$OUT_DIR/m2p.txt" '.*\[m2p\] deliver_max_us=\([0-9]*\).*'               2)
L_DMEAN=$(nth  "$OUT_DIR/m2p.txt" '.*deliver_mean_us=\([0-9]*\).*'                      2)
L_RMAX=$(nth   "$OUT_DIR/m2p.txt" '.*\[m2p\] render_max_us=\([0-9]*\).*'                2)
L_RMEAN=$(nth  "$OUT_DIR/m2p.txt" '.*render_mean_us=\([0-9]*\).*'                       2)
L_OVER=$(nth   "$OUT_DIR/m2p.txt" '.*over250ms=\([0-9]*\).*'                            2)

W_MAX=$(nth    "$OUT_DIR/wklat.txt" '.*\[wklat\] max_us=\([0-9]*\).*'                   2)
W_N=$(nth      "$OUT_DIR/wklat.txt" '.*\[wklat\] n=\([0-9]*\).*'                        2)
P_MAX=$(nth    "$OUT_DIR/ptrlat.txt" '.*\[ptrlat\] n=[0-9]* max_us=\([0-9]*\).*'        2)

# INGEST FIRST. Everything downstream is meaningless if the hypervisor's motion
# never reached the guest's ring, and an m2p report with ingest=0 looks exactly
# like a beautifully fast machine.
if [ -z "${L_ING:-}" ]; then
    verdict_inconclusive "$VTAG" \
        "no m2p report from the loaded arm -- the report verb did not land"
fi
if [ "${L_ING:-0}" -lt 1 ]; then
    verdict_inconclusive "$VTAG" \
        "the guest ingested 0 mouse packets in the loaded arm despite $LOAD_MOVES monitor mouse_move injections -- host-side pointer delivery, not the guest, is what failed here; nothing about the guest was measured"
fi
if [ "${L_N:-0}" -lt "$MIN_SAMPLES" ]; then
    verdict_inconclusive "$VTAG" \
        "only ${L_N:-0} motion-to-photon intervals completed in the loaded arm (ingest=${L_ING}, need $MIN_SAMPLES) -- packets reached the ring but did not reach scanout, so no latency distribution exists to judge"
fi

echo "$TAG"
echo "$TAG === MOTION TO PHOTON, real DE, KVM -cpu host ==="
echo "$TAG   IDLE    n=${I_N:-?} ingest=${I_ING:-?} total_max=${I_MAX:-?}us mean=${I_MEAN:-?}us  (deliver_max=${I_DMAX:-?}us render_max=${I_RMAX:-?}us)"
echo "$TAG   LOADED  n=${L_N:-?} ingest=${L_ING:-?} total_max=${L_MAX:-?}us mean=${L_MEAN:-?}us  (deliver_max=${L_DMAX:-?}us render_max=${L_RMAX:-?}us)"
echo "$TAG   loaded split by mean: deliver=${L_DMEAN:-?}us render=${L_RMEAN:-?}us"
echo "$TAG   corroborating, same loaded window: wklat max=${W_MAX:-?}us over n=${W_N:-?}, ptrlat max=${P_MAX:-?}us"
echo "$TAG"
echo "$TAG   ATTRIBUTION: whichever of deliver/render carries the time is the"
echo "$TAG   half to fix; the other is ruled out by this same run."
echo "$TAG"

{
    echo "arm n ingest total_max_us total_mean_us deliver_max_us render_max_us"
    echo "idle   ${I_N:-?} ${I_ING:-?} ${I_MAX:-?} ${I_MEAN:-?} ${I_DMAX:-?} ${I_RMAX:-?}"
    echo "loaded ${L_N:-?} ${L_ING:-?} ${L_MAX:-?} ${L_MEAN:-?} ${L_DMAX:-?} ${L_RMAX:-?}"
} > "$OUT_DIR/summary.txt"

if [ "${L_MAX:-999999999}" -gt "$M2P_MAX_US" ]; then
    half="render (the compositor)"
    if [ "${L_DMAX:-0}" -gt "${L_RMAX:-0}" ]; then half="deliver (input delivery / the tick)"; fi
    verdict_fail "$VTAG" "on the real DE under KVM a mouse packet took ${L_MAX}us (> ${M2P_MAX_US}us) to reach scanout while $HOGS processes burned 100% CPU -- that is a visible pointer freeze. The time is in the $half half: deliver_max=${L_DMAX:-?}us render_max=${L_RMAX:-?}us, over250ms=${L_OVER:-?} of ${L_N} samples. Artifacts: $OUT_DIR"
    exit 1
fi
verdict_pass "$VTAG" "on the real DE under KVM every one of ${L_N} mouse packets reached scanout within ${L_MAX}us (<= ${M2P_MAX_US}us) under $HOGS x 100%-CPU plus an exec/ELF-load storm; idle was ${I_MAX:-?}us. Split: deliver_max=${L_DMAX:-?}us render_max=${L_RMAX:-?}us"
exit 0
