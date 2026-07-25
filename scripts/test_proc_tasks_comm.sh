#!/usr/bin/env bash
# scripts/test_proc_tasks_comm.sh — /proc/tasks renders honest task names.
#
# WHAT THIS GUARDS
#
# Two real defects found by driving the shipped image and typing `ps`:
#
#   1. PID 1 (ksoftirqd) rendered as "driftfok". task_struct.name0 is an
#      8-byte ASCII tag packed MOST-significant-byte = character 0 (the
#      contract _buf_put_name0() in fs/procfs.ad decodes, and the one
#      set_task_name0_from_path() writes). kernel/softirq.ad spelled its
#      literal in the OPPOSITE byte order, so "ksoftird" came back
#      reversed: "driftfok". kernel/workqueue.ad, linux_abi/api_irq.ad
#      and linux_abi/api_kthread.ad had the same inversion, and theirs
#      began with a NUL byte, so their kthreads rendered an EMPTY COMM.
#      A reversed tag is indistinguishable, to a reader, from the kernel
#      printing uninitialized memory. It must never come back.
#
#   2. Every COMM was truncated to 8 characters ("hamdeskt") because the
#      renderer printed the name0 tag rather than task_struct.comm, which
#      already holds the full basename.
#
# THE ASSERTIONS (all observed on a real boot of the SHIPPED image):
#   a. the `PID\tSTATE\tCOMM` header and tab-separated shape survive
#      (user/ps.ad and awk consumers depend on it),
#   b. no line renders "driftfok" (nor any other reversed tag),
#   c. NO line has an empty COMM column — a ragged table is the symptom
#      of a NUL-first tag,
#   d. PID 1 has a sensible, non-empty name,
#   e. if a >8-char program is running (the DE spawns hamdesktop /
#      hamfmscene / hamterminal), at least one COMM exceeds 8 chars —
#      i.e. we are printing comm, not the truncated name0 tag.
#
# Boots the SHIPPED installer image under OVMF+KVM (not `-kernel`
# multiboot). Three-valued verdict per scripts/_verdict.sh: a QEMU that
# never reaches the shell is INCONCLUSIVE (125), not a pass and not a
# regression — this host has chronic D-state ACPI kworkers that starve
# TCG/KVM guests. Every qemu started here is killed on exit.
set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"

TAG="test_proc_tasks_comm"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
CMD_WAIT="${CMD_WAIT:-120}"
QEMU_MEM="${QEMU_MEM:-4G}"

HANDOFF_MARKER="handing off to interactive shell"
# `ps` prints this banner immediately before the task table.
PS_MARKER="--- /proc/tasks ---"
# Our own end-of-capture sentinel: hamsh echoes it once ps has finished.
DONE_MARKER="PSTASKS_DONE"

# --- environment gates (INCONCLUSIVE, never a false green) -------------
[ -e /dev/kvm ] || verdict_inconclusive "$TAG" "/dev/kvm absent (KVM required)."
command -v socat >/dev/null 2>&1 \
    || verdict_inconclusive "$TAG" "socat not installed."
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] \
    || verdict_inconclusive "$TAG" "OVMF firmware not found."
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[proc_tasks_comm]"; then
    [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ] && verdict_inconclusive "$TAG" \
        "$INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1."
    echo "[$TAG] building $INSTALLER_IMG"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh" >/dev/null 2>&1
fi
[ -f "$INSTALLER_IMG" ] \
    || verdict_inconclusive "$TAG" "$INSTALLER_IMG could not be built."

OVMF_RW=$(mktemp --tmpdir hamnix-pst.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-pst.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-pst.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-pst-in.XXXXXX)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "${QEMU_PID:-}" ] && { sleep 0.3; kill -9 "$QEMU_PID" 2>/dev/null; }
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

wait_for() {
    local pat="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        grep -a -F -q -e "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
# A freshly-booted hamsh DROPS the first serial command (see
# scripts/_qemu_drive.sh): re-send until the marker proves it landed.
send_until() {
    local cmd="$1" pat="$2" secs="$3" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        printf '\n' >&3; sleep 1
        printf '%s\n' "$cmd" >&3
        for i in $(seq 1 15); do
            grep -a -F -q -e "$pat" "$LOG" && return 0
            kill -0 "$QEMU_PID" 2>/dev/null || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -F -q -e "$pat" "$LOG"
}

echo "[$TAG] waiting up to ${BOOT_WAIT}s for the interactive-shell handoff..."
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" \
        "handoff marker never printed in ${BOOT_WAIT}s (guest never reached hamsh; suspect host load)."
# Let the DE / late kthreads settle so the table is representative.
sleep 5

echo "[$TAG] running \`ps\` on the guest..."
send_until "ps ; echo $DONE_MARKER" "$DONE_MARKER" "$CMD_WAIT" \
    || verdict_inconclusive "$TAG" \
        "\`ps\` never completed in ${CMD_WAIT}s (no $DONE_MARKER echo)."
grep -a -F -q -e "$PS_MARKER" "$LOG" \
    || verdict_inconclusive "$TAG" "\`ps\` ran but printed no '$PS_MARKER' banner."

# --- extract the /proc/tasks section from the serial log ---------------
# Everything between the ps banner and our sentinel, minus the header,
# CR-stripped (the 16550 console emits CRLF).
TABLE=$(sed -e 's/\r$//' "$LOG" \
        | sed -n "/$(printf '%s' "$PS_MARKER" | sed 's/[][\.*^$/]/\\&/g')/,/$DONE_MARKER/p" \
        | grep -aE '^[0-9]+	')

[ -n "$TABLE" ] \
    || verdict_inconclusive "$TAG" "no PID rows parsed out of the /proc/tasks section."

echo "[$TAG] --- /proc/tasks as rendered ---"
printf '%s\n' "$TABLE"
echo "[$TAG] -------------------------------"

fail=""

# (a) the header shape survives — user/ps.ad and awk consumers need it.
grep -a -F -q "PID	STATE	COMM" "$LOG" \
    || fail="${fail}missing tab-separated 'PID<TAB>STATE<TAB>COMM' header; "

# (b) the reversed-tag bytes must never come back.
if printf '%s\n' "$TABLE" | grep -a -q "driftfok"; then
    fail="${fail}'driftfok' (byte-reversed 'ksoftirq' tag) rendered again; "
fi

# (c) no empty COMM column: a NUL-first tag renders a ragged table.
EMPTY=$(printf '%s\n' "$TABLE" | awk -F'\t' 'NF < 3 || $3 == "" { print $1 }')
if [ -n "$EMPTY" ]; then
    fail="${fail}empty COMM for pid(s): $(echo $EMPTY | tr '\n' ' '); "
fi

# (d) PID 1 has a real name.
PID1=$(printf '%s\n' "$TABLE" | awk -F'\t' '$1 == 1 { print $3; exit }')
if [ -z "$PID1" ]; then
    fail="${fail}PID 1 absent or unnamed; "
else
    echo "[$TAG] PID 1 COMM = '$PID1'"
fi

# (e) we print comm (full basename), not the 8-byte name0 tag. Only
#     assertable when a >8-char program is actually running; the DE
#     spawns hamdesktop/hamfmscene/hamterminal, so it normally is.
LONGEST=$(printf '%s\n' "$TABLE" | awk -F'\t' '{ if (length($3) > m) { m = length($3); n = $3 } } END { print n }')
LONGLEN=${#LONGEST}
echo "[$TAG] longest COMM = '$LONGEST' (${LONGLEN} chars)"
if [ "$LONGLEN" -le 8 ]; then
    # Nothing long enough was running to prove or disprove truncation.
    # Do not claim a pass we did not observe.
    verdict_inconclusive "$TAG" \
        "no process with a >8-char name was live, so the 8-char-truncation assertion was never exercised (longest COMM '$LONGEST'). Other assertions held."
fi

[ -z "$fail" ] || verdict_fail "$TAG" "$fail"

verdict_pass "$TAG" \
    "/proc/tasks: header intact, no reversed tag, no empty COMM, pid1='$PID1', longest COMM '$LONGEST' (${LONGLEN} chars > 8 => comm not name0)."
