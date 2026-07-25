#!/usr/bin/env bash
# scripts/test_ls_overlay_dirs.sh — regression gate for the silently-empty
# shadow-overlay directory listing.
#
# THE BUG (fixed by the commit that added this gate)
#
# fs/vfs_mount.ad registers /usr /etc /bin /sbin /lib /lib64 /opt /run /srv
# /var as SHADOW tmpfs overlay mounts, so `apt`/`dpkg` inside the Linux
# namespace have a writable layer over the read-only cpio initramfs.
# fs/tmpfs.ad materialises each of those overlay roots as a synthetic
# tmpfs DIRECTORY. vfs_open's tmpfs arm then matched the shadow mount and
# handed `open("/bin")` back to _open_tmpfs_read() — which opened that
# synthetic directory as a readable, ZERO-BYTE FILE.
#
# Result: `ls /bin` printed NOTHING and exited 0. Not an error — an empty
# directory. Meanwhile every one of the 228 binaries under /bin exec'd
# fine (exec goes through _lookup_name, a different path), so the whole
# desktop launched from a directory userspace could not enumerate. The
# same silent emptiness hit /etc, /lib, /usr, /var, /sbin, /srv...
#
# The fix routes a directory under a shadow overlay mount to a UNION
# listing (tmpfs entries, then the cpio-baked entries appended with
# dedup) instead of to the file-read arm.
#
# WHAT THIS GATE ASSERTS — on the SHIPPED IMAGE under UEFI/OVMF, because
# `-kernel` multiboot cannot boot on this host (QEMU: "multiboot knows
# VBE. we don't") and is not the acceptance path anyway:
#
#   1. `ls /bin`            lists real binaries (hamsh, ls, cat, echo)
#                           and is NON-EMPTY by a wide margin (>= 100).
#   2. `ls /etc`            lists motd, passwd, fstab.
#   3. `ls /lib`            lists `modules` (a cpio-IMPLICIT directory:
#                           no cpio entry named /lib/modules exists, only
#                           /lib/modules/<x>.ko files).
#   4. `ls /lib/modules`    lists e1000e.ko and the nested `6.12` dir —
#                           proves nesting under an overlay root works.
#   5. `ls /usr/share/man`  lists ls.1.md — proves a path nested two deep
#                           under a *different* overlay root works.
#   6. `ls -l /lib`         renders `modules` with a leading 'd' (P9_QTDIR)
#                           so hamfm draws a folder icon, not a file icon.
#   7. `ls /tmp`            still works (authoritative tmpfs, no cpio
#                           union) — guards against the fix regressing the
#                           non-shadow tmpfs arm.
#
# NO PIPES: hamsh's pipelines are broken at time of writing and wedge the
# shell, so every count is done host-side on the captured serial log.
#
# Verdicts (docs/TEST_VERDICTS.md): PASS=0 FAIL=1 INCONCLUSIVE=125.
# A starved guest / missing OVMF / missing KVM / absent image is
# INCONCLUSIVE, never a false green.

set -u

TAG=test_ls_overlay_dirs
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$(dirname "$0")/_verdict.sh"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
QEMU_MEM="${QEMU_MEM:-2G}"

# ---- environment gates: every one of these is INCONCLUSIVE, not FAIL ----
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

# The .img is NOT rebuilt when present (see the stale-installer-img QA
# trap). Callers that changed kernel code must rebuild it themselves.
[ -f "$INSTALLER_IMG" ] \
    || verdict_inconclusive "$TAG" \
         "$INSTALLER_IMG absent — run: bash scripts/build_installer_img.sh"
# This gate deliberately boots whatever image is already there. That is only
# safe if the reader is TOLD when that image predates the tree under test —
# a silent stale boot is how the 2026-07-24 office-suite false negative
# happened. shellcheck source=_installer_img.sh
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
installer_img_warn_if_stale "$INSTALLER_IMG" "[ls_overlay_dirs]"

OVMF_RW=$(mktemp --tmpdir hamnix-lsov.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-lsov.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-lsov.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-lsov-in.XXXXXX)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill -9 "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

echo "[$TAG] booting $INSTALLER_IMG under OVMF + KVM"
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

# Wait for hamsh to exist at all.
booted=0
for _ in $(seq 1 120); do
    grep -aqF 'hamsh' "$LOG" && { booted=1; break; }
    alive || break
    sleep 1
done
[ "$booted" = "1" ] || verdict_inconclusive "$TAG" \
    "hamsh prompt never appeared within 120s (qemu alive=$(alive && echo yes || echo no)) — host starved or boot broke."

# Let rc.boot / the DE settle so their own output does not interleave
# with the listings we are about to capture.
sleep 6

# A freshly-booted hamsh DROPS THE FIRST serial command (it never echoes).
# Re-send until the marker actually appears. Gate on the marker, never on
# a fixed sleep.
send_until() {
    local cmd="$1" pat="$2" secs="${3:-40}" waited=0 i
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

send_until 'echo LSOV_READY' 'LSOV_READY' 45 \
    || verdict_inconclusive "$TAG" \
         "shell never echoed LSOV_READY — guest starved or hamsh wedged."

# run <marker-before> <command> <marker-after> <settle-seconds>
# Emits BEGIN/END markers around each listing so the host-side parser can
# slice the serial stream deterministically. No pipes (hamsh pipelines
# wedge the shell right now).
run() {
    printf 'echo %s\n' "$1" >&3; sleep 2
    printf '%s\n' "$2" >&3;      sleep "$4"
    printf 'echo %s\n' "$3" >&3; sleep 2
}

run BEG_BIN    'ls /bin'             END_BIN    6
run BEG_ETC    'ls /etc'             END_ETC    4
run BEG_LIB    'ls /lib'             END_LIB    4
run BEG_LIBMOD 'ls /lib/modules'     END_LIBMOD 4
run BEG_MAN    'ls /usr/share/man'   END_MAN    4
run BEG_LSL    'ls -l /lib'          END_LSL    4
run BEG_TMP    'ls /tmp'             END_TMP    4

alive || verdict_inconclusive "$TAG" "qemu died before the listings completed."

# Every END marker must have landed, or we never observed the assertion.
for m in END_BIN END_ETC END_LIB END_LIBMOD END_MAN END_LSL END_TMP; do
    grep -aqF "$m" "$LOG" || verdict_inconclusive "$TAG" \
        "marker $m never appeared — guest starved mid-run; nothing observed."
done

# ---------------- host-side parse of the captured serial stream ----------
# hamsh echoes each keystroke with ANSI cursor moves, so the raw log is
# full of `hamsh$ l`, `hamsh$ ls`, ... partial-echo lines. Strip ANSI, drop
# prompt-echo lines and async kernel/DE chatter, then slice between markers.
export LSOV_LOG="$LOG"
python3 - <<'PY'
import os, re, sys

raw = open(os.environ["LSOV_LOG"], "rb").read().decode("utf8", "replace")

def slice_between(a, b):
    i = raw.find("\n", raw.find(a))
    j = raw.find(b, i + 1)
    if i < 0 or j < 0 or j <= i:
        return None
    return raw[i:j]

NOISE = ("task: pid", "hamsh-alive", "visual_gate", "mem_gate",
         "hamsh$", "Mem:", "total", "[")

# The `echo BEG_x` that opens each slice echoes its own marker onto the
# serial line. Drop it so the counts below are entries, not entries+1.
MARKER = re.compile(r"^(BEG|END)_[A-Z]+$")

def entries(seg):
    if seg is None:
        return None
    seg = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", seg)
    out = []
    for line in seg.split("\n"):
        s = line.strip()
        if not s:
            continue
        if any(n in s for n in NOISE):
            continue
        if MARKER.match(s):
            continue
        out.append(s)
    return out

def names(seg):
    """For `ls -l`, the name is after the tab; for plain ls, the whole line."""
    e = entries(seg)
    if e is None:
        return None
    return [x.split("\t")[-1] for x in e]

failures = []
notes = []

def check(label, a, b, must_have, min_count=1, pred=None):
    seg = slice_between(a, b)
    got = names(seg)
    if got is None:
        failures.append(f"{label}: could not slice {a}..{b} out of the log")
        return
    notes.append(f"{label}: {len(got)} entries (first: {got[:5]})")
    if len(got) < min_count:
        failures.append(
            f"{label}: only {len(got)} entries, expected >= {min_count} "
            f"(silently-empty regression?) got={got[:20]}")
    for m in must_have:
        if m not in got:
            failures.append(f"{label}: missing expected entry {m!r}; got={got[:20]}")
    if pred:
        pred(label, entries(seg))

# 1. /bin — the headline bug. 228 binaries are staged; demand >= 100 and
#    specific well-known names. "some output appeared" is not an assertion.
check("ls /bin", "BEG_BIN", "END_BIN",
      ["hamsh", "ls", "cat", "echo", "lsblk"], min_count=100)

# 2. /etc — a different shadow overlay root.
check("ls /etc", "BEG_ETC", "END_ETC",
      ["motd", "passwd", "fstab"], min_count=10)

# 3. /lib — `modules` is a cpio-IMPLICIT dir (no cpio entry of that name).
check("ls /lib", "BEG_LIB", "END_LIB", ["modules"], min_count=1)

# 4. nesting under an overlay root, incl. a nested implicit dir `6.12`.
check("ls /lib/modules", "BEG_LIBMOD", "END_LIBMOD",
      ["e1000e.ko", "modules.dep", "6.12"], min_count=5)

# 5. two levels deep under a different overlay root.
check("ls /usr/share/man", "BEG_MAN", "END_MAN",
      ["ls.1.md", "hamsh.1.md"], min_count=5)

# 6. `ls -l /lib` must mark `modules` as a DIRECTORY (leading 'd' from
#    P9_QTDIR) or hamfm renders a file icon for every folder.
def dir_flag(label, ents):
    for line in ents or []:
        if line.endswith("modules"):
            if not line.startswith("d"):
                failures.append(
                    f"{label}: 'modules' not marked as a directory: {line!r}")
            return
    failures.append(f"{label}: no 'modules' row found in ls -l output")

check("ls -l /lib", "BEG_LSL", "END_LSL", [], min_count=1, pred=dir_flag)

# 7. authoritative tmpfs (/tmp) must still list — the fix must not have
#    regressed the non-shadow arm. The DE drops .hamfm_wid etc. there.
seg = slice_between("BEG_TMP", "END_TMP")
tmp = names(seg)
if tmp is None:
    failures.append("ls /tmp: could not slice BEG_TMP..END_TMP")
else:
    notes.append(f"ls /tmp: {len(tmp)} entries ({tmp[:5]})")
    if len(tmp) < 1:
        failures.append("ls /tmp: empty — the authoritative tmpfs arm regressed")

for n in notes:
    print(f"[test_ls_overlay_dirs]   {n}")

if failures:
    print("[test_ls_overlay_dirs] observed violations:", file=sys.stderr)
    for f in failures:
        print(f"  - {f}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
parse_rc=$?

if [ "$parse_rc" -eq 0 ]; then
    verdict_pass "$TAG" \
        "shadow-overlay dirs enumerate: /bin >=100 entries incl hamsh/ls/cat," \
        "/etc incl motd/passwd, /lib incl implicit dir 'modules' (QTDIR in ls -l)," \
        "/lib/modules nested incl 6.12, /usr/share/man incl ls.1.md, /tmp intact."
else
    verdict_fail "$TAG" \
        "one or more shadow-overlay directories did not enumerate correctly" \
        "(see the observed violations above)."
fi
