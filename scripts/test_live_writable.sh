#!/usr/bin/env bash
# scripts/test_live_writable.sh
#
# REGRESSION GATE (#67): the LIVE installer image boots with a WRITABLE
# in-RAM root. The live native session's `/` is the read-only cpio
# embedded in the kernel ELF; etc/rc.boot's LIVE branch unions a writable
# tmpfs server (`#t`) MBEFORE the cpio at `/` with MCREATE (`bind -bc`),
# so a file created / written ANYWHERE in the live session lands in RAM
# and reads back, while reads of unmodified files fall through to the
# read-only cpio. Writes are RAM-only and volatile (lost on reboot) —
# exactly the live-session contract.
#
# What this proves, end to end, on the REAL shipped artifact
# (build/hamnix-installer.img under OVMF — the real boot path):
#
#   1. rc.boot took the LIVE branch and printed the writable-root marker
#      ("live root is WRITABLE in RAM").
#   2. A NEW file the cpio does NOT contain — /root/livetest — is created,
#      written, and reads back its content. Impossible against a
#      read-only cpio root without the tmpfs overlay.
#   3. COPY-UP: a truncating write to a path that read-through-EXISTS in
#      the cpio — /etc/debian_version — succeeds and reads back the NEW
#      content (the tmpfs shadow, MBEFORE the cpio copy).
#
# FALSE-GREEN GUARD (feedback_false_green console leak / typed-echo): the
# hamsh line editor echoes every typed command back on the serial console,
# so a marker that appears in the typed write command cannot prove the
# write happened. Each proof writes the REVERSED marker and reads it back
# through `rev` (`cat FILE | rev`), so the forward marker
# ("LIVEWROK" / "COPYUPOK") materialises ONLY in `rev`'s OUTPUT — the typed
# write line carries the reversed form ("KORWEVIL" / "KOPUYPOC") and the
# read line carries no marker at all. The forward string therefore appears
# in the log if and only if the file was really written to RAM and read
# back. (hamsh's interactive parser lexes '%' as an operator, so printf
# %-formats are unusable here; echo + rev is the portable route.)
#
# Judged ONLY by serial-log markers (never wrapper exit codes; a qemu
# timeout after the markers appeared is benign). The first serial command
# after boot is historically dropped, so every command is RE-SENT until
# its own output appears (feedback_serial_test_first_cmd_dropped) and
# keystrokes are gated on boot markers, not fixed sleeps.
#
# SKIPS CLEANLY (exit 0) when OVMF or the installer image is unavailable
# and cannot be built. Uses KVM (-cpu host) when /dev/kvm is present, else
# falls back to pure TCG (-cpu max, SMAP-capable) like the heartbeat gate.
#
# Env overrides:
#   INSTALLER_IMG      image path     (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware  (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for boot markers   (default: 900)
#   CMD_WAIT           seconds to wait for command output (default: 240)
#   QEMU_MEM           guest RAM      (default: 2G)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild; SKIP if absent)
#   KEEP_LOGS          1 = keep the serial log on PASS
#
# Pass marker:  [test_live_writable] PASS
# Fail marker:  [test_live_writable] FAIL

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-900}"
CMD_WAIT="${CMD_WAIT:-240}"
QEMU_MEM="${QEMU_MEM:-2G}"
TAG="[test_live_writable]"

LIVE_MARKER="booting LIVE environment"
WRITABLE_MARKER="live root is WRITABLE in RAM"
HANDOFF_MARKER="handing off to interactive shell"

# Reversed-marker proofs: write the reversed form, read back through `rev`
# so the forward marker appears ONLY in rev's output.
NEWFILE_OUT="LIVEWROK"                # rev of the written "KORWEVIL"
COPYUP_OUT="COPYUPOK"                 # rev of the written "KOPUYPOC"

# --- resolve OVMF (skip cleanly if absent) ----------------------------
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && { OVMF_FD="$cand"; break; }
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "$TAG SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- ensure the installer image exists (rebuild by default) -----------
# shellcheck source=_installer_img.sh
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
    if [ ! -f "$INSTALLER_IMG" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    # Reusing a pre-existing image: say so LOUDLY when it predates the tree.
    installer_img_warn_if_stale "$INSTALLER_IMG" "[live_writable]"
else
    echo "$TAG rebuilding installer image via build_installer_img.sh (~6 min; HAMNIX_SKIP_BUILD=1 to reuse)"
    if ! bash "$PROJ_ROOT/scripts/build_installer_img.sh"; then
        echo "$TAG SKIP: installer image build failed (toolchain/host gap)." >&2
        exit 0
    fi
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "$TAG SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

# --- KVM vs TCG ------------------------------------------------------
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL=(-enable-kvm -cpu host)
    echo "$TAG using KVM (-cpu host)."
else
    # -cpu max exposes SMAP so syscall_entry's stac/clac don't #UD under TCG.
    ACCEL=(-cpu max)
    echo "$TAG /dev/kvm unavailable — pure TCG (-cpu max)."
    BOOT_WAIT=$((BOOT_WAIT > 1200 ? BOOT_WAIT : 1200))
fi

OVMF_RW=$(mktemp --tmpdir hamnix-live-w.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-live-w.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-live-w.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-live-w-in.XXXXXX)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
# Fresh writable COPY of the image (never mutate the shipped artifact).
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    if [ "${KEEP_LOGS:-0}" = "1" ]; then
        echo "$TAG serial log kept: $LOG" >&2
    else
        rm -f "$LOG"
    fi
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"
}
trap cleanup EXIT

qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot \
    -monitor none \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

wait_for() {
    local pat="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        grep -a -F -q "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

send_until() {
    # send_until <line1> <line2> <output-pattern> <total-seconds>
    # hamsh's interactive parser is ONE command per line (a ';' on a
    # single line is a parse error), so a write+read proof is two SEPARATE
    # lines. Both are RE-SENT each iteration (freshly-booted hamsh drops
    # the first serial line; a later cat re-reads once the write lands).
    local l1="$1" l2="$2" pat="$3" secs="$4" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        printf '%s\n' "$l1" >&3
        sleep 1; waited=$((waited + 1))
        printf '%s\n' "$l2" >&3
        for i in $(seq 1 20); do
            grep -a -F -q "$pat" "$LOG" && return 0
            kill -0 "$QEMU_PID" 2>/dev/null || return 1
            sleep 1
            waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -F -q "$pat" "$LOG"
}

fail=0
markers_seen=0

echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch..."
if wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    markers_seen=$((markers_seen + 1))
    echo "$TAG PASS: rc.boot took the LIVE branch."
else
    echo "$TAG INCONCLUSIVE: LIVE-branch marker not seen (did the guest boot?)." >&2
    tail -60 "$LOG" | strings >&2
    exit 0
fi

if wait_for "$WRITABLE_MARKER" "$BOOT_WAIT"; then
    markers_seen=$((markers_seen + 1))
    echo "$TAG PASS: writable-root overlay applied ('$WRITABLE_MARKER')."
else
    echo "$TAG FAIL: writable-root marker not seen — 'bind -bc #t /' did not apply." >&2
    grep -a "rc.boot: WARNING could not make live root writable" "$LOG" >&2 || true
    fail=1
fi

if wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: interactive handoff reached."
else
    echo "$TAG INCONCLUSIVE: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -80 "$LOG" | strings >&2
    exit 0
fi

# --- Proof 1: create + write + read a NEW file the cpio lacks ---------
if [ "$fail" -eq 0 ]; then
    if send_until \
        "echo KORWEVIL > /root/livetest" \
        "cat /root/livetest | rev" \
        "$NEWFILE_OUT" "$CMD_WAIT"; then
        echo "$TAG PASS: new file /root/livetest written to RAM and read back ('$NEWFILE_OUT')."
    else
        echo "$TAG FAIL: could not create+read /root/livetest — live root not writable." >&2
        fail=1
    fi
fi

# --- Proof 2: COPY-UP — truncating write over an existing cpio file ---
if [ "$fail" -eq 0 ]; then
    if send_until \
        "echo KOPUYPOC > /etc/debian_version" \
        "cat /etc/debian_version | rev" \
        "$COPYUP_OUT" "$CMD_WAIT"; then
        echo "$TAG PASS: copy-up write over cpio /etc/debian_version read back new content ('$COPYUP_OUT')."
    else
        echo "$TAG FAIL: copy-up write to /etc/debian_version did not read back — overlay create-routing broken." >&2
        fail=1
    fi
fi

if [ "$markers_seen" -eq 0 ]; then
    echo "$TAG INCONCLUSIVE: zero guest markers observed." >&2
    exit 0
fi
if [ "$fail" -eq 0 ]; then
    echo "$TAG PASS"
    exit 0
else
    echo "$TAG FAIL"
    exit 1
fi
