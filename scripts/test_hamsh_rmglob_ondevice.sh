#!/usr/bin/env bash
# scripts/test_hamsh_rmglob_ondevice.sh — THE reproducer for the silent
# partial-action bug, run end to end on the SHIPPED installer image under
# UEFI/OVMF.
#
# THE BUG (2026-07-28). hamsh's _argv_push_cstr dropped argument 64 onward
# with no error and no status, and the kernel's exec argv snapshot then
# truncated again at MAX_ARGV=32. So:
#
#     $ rm *          # in a 200-file directory
#     $                <- exit 0, no output, 169 files still there
#
# and the user believed the directory was empty.
#
# WHY THIS GATE IS SHAPED THE WAY IT IS
# The reason the bug survived is that `rm` EXITED 0. A gate that asserted on
# exit status would have passed on the broken build — that is precisely the
# mistake to avoid. So this gate asserts on the ONLY thing that matters:
#
#     make a directory with N > 200 files, run `rm *`, then COUNT what is
#     left, and require the count to be ZERO.
#
# It also counts BEFORE the rm, so "the directory was empty all along" (a
# gate that cannot fail) is ruled out rather than assumed.
#
# Host-gate-green is not device-working (docs/TEST_VERDICTS.md). The fast
# QEMU-free companion is scripts/test_hamsh_argvcap_host.sh; this one is the
# acceptance.
#
# SERIAL SEAM. The measured throughput of this seam is ~120 input chars/s;
# faster DROPS BYTES, including newlines, which fuses lines. Everything here
# is therefore driven as a handful of SHORT lines — the file creation is one
# guest-side `for` loop, so the host only has to push ~60 characters for it —
# and every step is confirmed by WAITING for the guest's own marker.
#
# Verdicts (docs/TEST_VERDICTS.md): PASS=0 FAIL=1 INCONCLUSIVE=125.

set -u

TAG=test_hamsh_rmglob_ondevice
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$(dirname "$0")/_verdict.sh"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
QEMU_MEM="${QEMU_MEM:-2G}"
# N must be comfortably past BOTH pre-fix walls (hamsh's 64-slot argv arena
# and the kernel's MAX_ARGV=32) so a regression to either is unmistakable.
NFILES="${NFILES:-230}"
RMDIR="${RMDIR:-/tmp/rmglob}"

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

OVMF_RW=$(mktemp --tmpdir hamnix-rmglob.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-rmglob.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-rmglob.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-rmglob-in.XXXXXX)
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
for _ in $(seq 1 180); do
    grep -aqF 'hamsh' "$LOG" && { booted=1; break; }
    alive || break
    sleep 1
done
[ "$booted" = "1" ] || verdict_inconclusive "$TAG" \
    "hamsh never appeared within 180s — host starved or boot broke."
sleep 6

# A freshly-booted hamsh DROPS THE FIRST serial command; gate on a marker,
# and re-send until the guest answers rather than trusting a fixed sleep.
send_until() {
    local cmd="$1" pat="$2" secs="${3:-60}" waited=0 i
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

send_until 'echo RMGLOB_READY' 'RMGLOB_READY' 90 \
    || verdict_inconclusive "$TAG" \
         "shell never echoed RMGLOB_READY — guest starved or hamsh wedged."

# --- 1. build the directory ----------------------------------------------
send_until "mkdir $RMDIR ; echo RMGLOB_MKDIR" 'RMGLOB_MKDIR' 60 \
    || verdict_inconclusive "$TAG" "guest never acknowledged mkdir."

# One guest-side loop: ~60 chars over the wire creates all N files. `touch`
# is a real spawned binary (user/touch.ad), so this exercises the ordinary
# path, not a shell shortcut.
CREATE="for i in range(1, $((NFILES + 1))) { touch $RMDIR/f\$i }"
printf '\n%s\n' "$CREATE" >&3
# N spawns take a while; wait for the guest to come back to a prompt by
# asking it a question and requiring the answer.
send_until 'echo RMGLOB_CREATED' 'RMGLOB_CREATED' 600 \
    || verdict_inconclusive "$TAG" \
         "guest never finished creating $NFILES files (spawn storm too slow?)."

# --- 2. count BEFORE (so an empty-directory false green is impossible) ----
send_until "cd $RMDIR ; echo RMGLOB_CD" 'RMGLOB_CD' 60 \
    || verdict_inconclusive "$TAG" "guest never acknowledged cd."
printf '\nfor f in * { echo BEFORE $f }\n' >&3
send_until 'echo RMGLOB_BEFORE_DONE' 'RMGLOB_BEFORE_DONE' 300 \
    || verdict_inconclusive "$TAG" "guest never finished the BEFORE listing."

# --- 3. THE REPRODUCER ---------------------------------------------------
printf '\nrm *\n' >&3
send_until 'echo RMGLOB_RM_DONE' 'RMGLOB_RM_DONE' 300 \
    || verdict_inconclusive "$TAG" 'guest never came back from rm-glob.'

# --- 4. count AFTER ------------------------------------------------------
printf '\nfor f in * { echo AFTER $f }\n' >&3
send_until 'echo RMGLOB_AFTER_DONE' 'RMGLOB_AFTER_DONE' 300 \
    || verdict_inconclusive "$TAG" "guest never finished the AFTER listing."

sleep 3
alive || verdict_inconclusive "$TAG" "qemu died before the run completed."

# ---------------- host-side parse of the captured serial stream ----------
export RMGLOB_LOG="$LOG" RMGLOB_N="$NFILES"
python3 - <<'PY'
import os, re, sys

raw = open(os.environ["RMGLOB_LOG"], "rb").read().decode("utf8", "replace")
raw = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
raw = raw.replace("\r", "\n")
want_n = int(os.environ["RMGLOB_N"])

fail = []
def ok(m):  print("[ondevice] ok: %s" % m)
def bad(m): fail.append(m); print("[ondevice] WRONG: %s" % m)

def listed(tag):
    # The guest's own result lines look like "<tag> f17". The line editor
    # echoes the TYPED loop too, so drop anything carrying the loop syntax.
    names = set()
    for line in raw.split("\n"):
        line = line.strip()
        if "{" in line or "}" in line or "for " in line:
            continue
        m = re.search(r"\b%s\s+(f\d+)\s*$" % tag, line)
        if m:
            names.add(m.group(1))
    return names

before = listed("BEFORE")
after = listed("AFTER")

# --- 0. the run must actually have observed the directory FULL first.
# Without this the gate could "pass" on a guest that never created a file.
if len(before) < want_n:
    print("[ondevice] INCONCLUSIVE: only %d of %d files were observed BEFORE "
          "the rm (serial drops or the create loop never finished) — nothing "
          "can be concluded about the delete." % (len(before), want_n))
    sys.exit(125)
ok("the directory really held %d files before `rm *`" % len(before))

# --- 1. THE ASSERTION. Not the exit status: the CONTENTS.
if after:
    bad("`rm *` left %d of %d files behind — a PARTIAL delete reported as "
        "success. Survivors (first 10): %s"
        % (len(after), len(before), sorted(after)[:10]))
else:
    ok("`rm *` emptied the directory: 0 of %d files survived" % len(before))

# --- 2. and it must not have been loud-but-broken either: no E2BIG, no
# argv raise, no "cannot remove" — the vector should simply have fit.
for pat in ("argv: too many arguments",
            "argument list too long",
            "rm: cannot remove"):
    if pat in raw:
        bad("'%s' appeared — the delete did not complete cleanly" % pat)

sys.exit(1 if fail else 0)
PY
rc=$?

case "$rc" in
  0)   verdict_pass "$TAG" \
         "on the shipped image: \`rm *\` in a ${NFILES}-file directory removed EVERY file (asserted on the surviving file count, not on exit status)" ;;
  125) verdict_inconclusive "$TAG" "not enough was observed on the device to decide" ;;
  *)   echo "[$TAG] --- tail of serial log ---" >&2
       tail -80 "$LOG" | strings >&2
       verdict_fail "$TAG" "\`rm *\` did NOT empty the directory — silent partial delete" ;;
esac
