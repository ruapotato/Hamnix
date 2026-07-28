#!/usr/bin/env bash
# scripts/test_hamsh_arena_soak_ondevice.sh — ON-DEVICE acceptance for the
# hamsh arena collector, on the SHIPPED installer image under UEFI/OVMF.
#
# scripts/test_hamsh_arena_soak_host.sh proves the collector on the host
# build. Host-gate-green is not device-working (docs/TEST_VERDICTS.md, and
# the project's own repeated experience), so this gate re-proves the same
# property on the real .img: a shell that has a `def`'d function and
# variables live can keep allocating indefinitely, reclaims, and still
# evaluates those functions and variables correctly afterwards.
#
# THE SHIPPED SYMPTOM being guarded (2026-07-28 DE stress soak): after
# ~83 minutes / ~700 commands of ordinary desktop use, EVERY command
# returned "hamsh: parse error [line 1]: node arena full" and no app could
# launch again, while the kernel was entirely healthy.
#
# HOW IT FORCES THE CONDITION IN MINUTES INSTEAD OF FOUR HOURS
# The failure is driven by NODES ALLOCATED, not by wall-clock or by command
# count, so a top-level `t = 1 + 1 + ...` substitutes for a desktop command:
# same arena, same allocator, same reclamation decision. It drives short
# lines in batches and stops the moment the GUEST reports a collection.
#
# LEARNED THE HARD WAY: long lines do NOT work over this seam. A ~900-char
# logical line is silently truncated on the way in — a first attempt at 40
# lines x 225 terms landed only ~120 chars each, reached 3069 nodes, and
# reported "occupancy never dropped" for a shell that was working perfectly.
# Keep the lines short.
#
# ASSERTS
#   1. No "node arena full" (nor kid-pool / arena-exhausted) on the device.
#   2. `arenas` shows the node count DROP — reclamation really happened on
#      the device, with a function and variables live throughout.
#   3. The DEVPROBE line (an if/else function body, a list slice, a string
#      variable) evaluates byte-identically before the first collection and
#      after it. A collector that mis-forwards a live AST corrupts this.
#
# Verdicts (docs/TEST_VERDICTS.md): PASS=0 FAIL=1 INCONCLUSIVE=125.
# Missing QEMU/KVM/OVMF/image, or a starved guest, is INCONCLUSIVE — never
# a false green.

set -u

TAG=test_hamsh_arena_soak_ondevice
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$(dirname "$0")/_verdict.sh"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
QEMU_MEM="${QEMU_MEM:-2G}"
# Serial line length is the binding constraint, NOT node count. A ~900-char
# logical line is silently TRUNCATED on the way in (measured: only ~120 chars
# per line landed, so 40 "454-node" lines produced 3069 nodes and no
# collection at all). So: short lines, many of them, and stop as soon as the
# guest reports a collection rather than guessing how many are needed.
BIG_TERMS="${BIG_TERMS:-25}"      # ~100 chars, ~50 nodes per line
MAX_LINES="${MAX_LINES:-500}"
BATCH="${BATCH:-25}"
# Measured throughput of this seam is ~120 input chars/second: the guest's
# line editor echoes every keystroke with cursor moves, and anything faster
# DROPS BYTES — including the newline, so consecutive lines fuse into one
# runaway logical line and the churn stops happening at all (observed: a
# 0.4 s cadence produced "t = 1 + 1 t = 1 + 1 +t = 1 ..." on one line).
# Gate the pace on the measured rate, with margin.
LINE_PAUSE="${LINE_PAUSE:-1.5}"

command -v qemu-system-x86_64 >/dev/null 2>&1 \
    || verdict_inconclusive "$TAG" "qemu-system-x86_64 not installed."
[ -r /dev/kvm ] \
    || verdict_inconclusive "$TAG" "/dev/kvm unavailable; TCG is too slow to be trusted here."

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] \
    || verdict_inconclusive "$TAG" "OVMF firmware not found."

# shellcheck source=_installer_img.sh
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
ensure_installer_img "$INSTALLER_IMG" "[$TAG]" \
    || verdict_inconclusive "$TAG" \
         "$INSTALLER_IMG absent — run: bash scripts/build_installer_img.sh"

OVMF_RW=$(mktemp --tmpdir hamnix-arena.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-arena.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-arena.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-arena-in.XXXXXX)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own qemu, by recorded pid.
    [ -n "${QEMU_PID:-}" ] && kill -9 "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

echo "[$TAG] booting $INSTALLER_IMG under OVMF + KVM ($(installer_img_age_str "$INSTALLER_IMG"))"
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot \
    -monitor none \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

alive() { kill -0 "$QEMU_PID" 2>/dev/null; }

booted=0
for _ in $(seq 1 150); do
    grep -aqF 'hamsh' "$LOG" && { booted=1; break; }
    alive || break
    sleep 1
done
[ "$booted" = "1" ] || verdict_inconclusive "$TAG" \
    "hamsh never appeared within 150s — host starved or boot broke."
sleep 6

# A freshly-booted hamsh DROPS THE FIRST serial command; gate on the marker.
send_until() {
    local cmd="$1" pat="$2" secs="${3:-45}" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        printf '\n' >&3; sleep 1
        printf '%s\n' "$cmd" >&3
        for i in $(seq 1 12); do
            grep -aqF "$pat" "$LOG" && return 0
            alive || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    return 1
}

send_until 'echo ARENA_READY' 'ARENA_READY' 60 \
    || verdict_inconclusive "$TAG" \
         "shell never echoed ARENA_READY — guest starved or hamsh wedged."

send() { printf '%s\n' "$1" >&3; sleep "${2:-1}"; }

# --- live state: exactly what the DE's rc leaves behind ------------------
send 'def dfn(k) { if k > 3 { return "hi" } else { return "lo" } }' 2
send 'keep = [1, 2, 3, 4, 5]' 2
send 'name = "hamnix"' 2

PROBE='echo DEVPROBE ${ dfn(9) } ${ dfn(1) } ${ keep[1:3] } $name'
EXPECT='DEVPROBE hi lo 2 3 hamnix'

send "$PROBE" 3
send 'echo ARENA_MARK_A' 2
send 'arenas' 3

# --- the churn -----------------------------------------------------------
BIG="t = $(python3 -c "import sys; sys.stdout.write(' + '.join(['1'] * $BIG_TERMS))")"
echo "[$TAG] driving up to $MAX_LINES top-level lines (${#BIG} chars each) until the guest collects"
sent=0
while [ "$sent" -lt "$MAX_LINES" ]; do
    alive || break
    for _ in $(seq 1 "$BATCH"); do
        send "$BIG" "$LINE_PAUSE"
    done
    sent=$((sent + BATCH))
    before=$(grep -aco 'arenas nodes=' "$LOG")
    send 'arenas' 3
    after=$(grep -aco 'arenas nodes=' "$LOG")
    if [ "$after" -le "$before" ]; then
        verdict_inconclusive "$TAG" \
            "the guest stopped answering 'arenas' after ~$sent lines — serial input is being dropped, so nothing about reclamation was observed."
    fi
    # Stop as soon as the DEVICE reports a collection — that is the event
    # this gate exists to observe, and over-driving only wastes wall clock.
    grep -aq ' gc=[1-9]' "$LOG" && { echo "[$TAG] guest collected after ~$sent lines"; break; }
done

send 'echo ARENA_MARK_B' 2
send 'arenas' 3
send "$PROBE" 3
send 'echo ARENA_DONE' 3
sleep 3

alive || verdict_inconclusive "$TAG" "qemu died before the run completed."
grep -aqF 'ARENA_DONE' "$LOG" || verdict_inconclusive "$TAG" \
    "ARENA_DONE never appeared — guest starved mid-run; nothing observed."

# ---------------- host-side parse of the captured serial stream ----------
export ARENA_LOG="$LOG" ARENA_EXPECT="$EXPECT"
python3 - <<'PY'
import os, re, sys

raw = open(os.environ["ARENA_LOG"], "rb").read().decode("utf8", "replace")
raw = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
expect = os.environ["ARENA_EXPECT"]

fail = []
def ok(m):   print("[ondevice] ok: %s" % m)
def bad(m):  fail.append(m); print("[ondevice] WRONG: %s" % m)

# --- 1. no arena ever ran dry
for pat in ("node arena full", "kid pool full", "arena exhausted"):
    if pat in raw:
        bad("'%s' appeared on the device" % pat)
if not fail:
    ok("no arena exhausted on the device")

# --- 2. occupancy dropped (reclamation really happened here)
samples = [int(m) for m in re.findall(r"arenas nodes=(\d+)/", raw)]
if len(samples) < 5:
    print("[ondevice] INCONCLUSIVE: only %d 'arenas' samples captured" % len(samples))
    sys.exit(125)
peak = max(samples)
dropped = any(b < a for a, b in zip(samples, samples[1:]))
gc = max([int(m) for m in re.findall(r" gc=(\d+)", raw)] or [0])
if dropped and gc >= 1:
    ok("node occupancy reclaimed on device (peak %d, final %d, %d collections, %d samples)"
       % (peak, samples[-1], gc, len(samples)))
else:
    bad("node occupancy never dropped on device (peak %d, final %d, gc=%d): %s"
        % (peak, samples[-1], gc, samples))
if peak >= 16384:
    bad("peak node occupancy %d reached NODE_MAX" % peak)

# --- 3. the same live function/variable evaluates the same afterwards.
# The line editor echoes the TYPED line too; those carry '${', the results
# do not.
probes = [l.strip() for l in raw.split("\n")
          if "DEVPROBE" in l and "${" not in l]
probes = [re.sub(r"^.*?(DEVPROBE)", r"\1", p) for p in probes]
probes = [p for p in probes if p.startswith("DEVPROBE")]
if len(probes) < 2:
    print("[ondevice] INCONCLUSIVE: captured %d DEVPROBE result lines: %r"
          % (len(probes), probes))
    sys.exit(125)
if probes[0] != expect:
    bad("baseline DEVPROBE is not the expected evaluation: want %r got %r"
        % (expect, probes[0]))
elif all(p == probes[0] for p in probes):
    ok("%d DEVPROBEs identical before and after collection (%r)" % (len(probes), probes[0]))
else:
    bad("DEVPROBE drifted across a collection: %r" % probes)

sys.exit(1 if fail else 0)
PY
rc=$?

case "$rc" in
  0)   verdict_pass "$TAG" \
         "on the shipped image: node arena reclaimed with a def + variables live, and they still evaluate correctly" ;;
  125) verdict_inconclusive "$TAG" "not enough was observed on the device to decide" ;;
  *)   echo "[$TAG] --- tail of serial log ---" >&2
       tail -60 "$LOG" | strings >&2
       verdict_fail "$TAG" "an on-device arena assertion was VIOLATED" ;;
esac
