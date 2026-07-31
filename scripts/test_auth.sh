#!/usr/bin/env bash
# scripts/test_auth.sh — END-TO-END MULTI-USER AUTH GATE.
#
# Proves Hamnix is a real multi-user system: a freshly-created user can
# have a password SET (passwd), and that password then actually
# AUTHENTICATES them (su) — right password succeeds and changes
# identity; wrong password is denied.
#
# This exercises the full credential stack landed in this work:
#   * useradd alice            — creates alice (uid >= 1000) with a
#                                LOCKED shadow stub (`alice:!:0`).
#   * passwd alice             — hostowner drives the /dev/auth `setpass`
#                                verb; the KERNEL generates a fresh
#                                $6$<salt>$<sha512-crypt> and rewrites the
#                                LIVE /etc/shadow on the ext4 sysroot
#                                (replacing the `!` lock). Userland never
#                                touches the shadow secret directly.
#   * su alice  (wrong pw)     — /dev/auth returns "denied"; su prints
#                                "su: Authentication failure" and returns
#                                control to the hostowner shell.
#   * su alice  (right pw)     — /dev/auth verifies the password against
#                                that SAME live /etc/shadow, returns "ok",
#                                su calls SYS_SETUID_AUTH on the verified
#                                fd, then prints
#                                "su: switched to uid <N> (alice)" via
#                                sys_getuid() — the deterministic identity
#                                proof — before execing alice's login
#                                shell.
#
# THE SHADOW-LOCATION CRUX this test guards: /dev/auth reads AND writes
# the LIVE authoritative /etc/shadow through the VFS (resolve_path +
# kernel-mediator perm bypass), NOT the frozen initramfs copy. If passwd
# wrote one shadow and su read another, the right-password su would be
# DENIED and su's "switched to uid <N> (alice)" line would never print —
# assertion C below would fail. So C passing is the crux proof.
#
# Because passwd/su take over the console and read passwords with echo
# SUPPRESSED (raw byte reads), this test uses GENEROUS settle sleeps
# before feeding each password line — the interactive program must be
# fully up and blocked in its read() before the keystrokes arrive.
#
# Boots the INSTALLED ext4-on-NVMe system (the golden disk produced by the
# real installer, scripts/build_installed_nvme.sh) — the baked hamnix.img
# was retired; a real system is installed onto a disk, never shipped as a
# pre-baked root image. The boot harness lives in scripts/_installed_boot.sh.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or the golden disk is
# unavailable (the shared helper gates this).
#
# Env overrides:
#   GOLDEN_NVME        installed disk path       (default: build/hamnix-installed.qcow2)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   SHELL_BOOT_WAIT    seconds to wait for the   (default: 200)
#                      interactive-prompt marker
#   HAMNIX_SKIP_BUILD  1 = require an existing golden disk (no rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERNEL_BANNER="Hamnix kernel booting"
PROMPT_MARKER="handing off to interactive shell"

# The seed account + the new user we create and authenticate.
ALICE="alice"
ALICE_PW="s3cr3t-alice"
WRONG_PW="totally-wrong"

# Fence markers driven into the serial stream so each assertion can be
# attributed to a specific command in the interleaved log.
M_ADD="HAMNIX_AUTH_USERADD"
M_PASSWD="HAMNIX_AUTH_PASSWD"
M_SU_OK="HAMNIX_AUTH_SU_OK"
M_WHOAMI="HAMNIX_AUTH_WHOAMI"
M_SU_BAD="HAMNIX_AUTH_SU_BAD"
M_DONE="HAMNIX_AUTH_DONE_99"

# --- boot the installed system (gates KVM/OVMF/golden disk; SKIPs clean) -
# shellcheck source=_installed_boot.sh
source "$PROJ_ROOT/scripts/_installed_boot.sh"

# ====================================================================
# BOOT — create alice, set her password, authenticate (right + wrong).
# ====================================================================
installed_boot_start

echo "[test_auth] waiting up to ${SHELL_BOOT_WAIT}s for the interactive prompt..."
if ! installed_boot_wait; then
    echo "[test_auth] FAIL: prompt marker not seen." >&2
    exit 1
fi
echo "[test_auth] prompt reached; driving the auth flow."

# Send a shell command line + settle.
type_cmd() { installed_type "$1" "${2:-4}"; }
# Send a RAW line (e.g. a password fed to an interactive program that reads
# with echo suppressed). Identical mechanics, named separately for clarity.
type_line() { installed_type "$1" "${2:-3}"; }

# GENEROUS settle before the very first keystroke after boot.
sleep 6

# 1. Create alice (hostowner is the live boot identity, uid 1).
type_cmd "echo $M_ADD" 2
type_cmd "useradd $ALICE" 6

# 2. Set alice's password as the hostowner. passwd reads two lines with
#    echo SUPPRESSED — give it a long settle to come fully up and block
#    in its first read() before we feed the password, then again before
#    the confirmation line.
type_cmd "echo $M_PASSWD" 2
type_cmd "passwd $ALICE" 6
type_line "$ALICE_PW" 4
type_line "$ALICE_PW" 5

# 3. su alice with the WRONG password FIRST — must be denied. su returns
#    control cleanly to the hostowner shell, so we can run the success
#    case afterwards from the same shell.
type_cmd "echo $M_SU_BAD" 3
type_cmd "su $ALICE" 8
type_line "$WRONG_PW" 6

# 4. su alice with the RIGHT password — identity must change to alice.
#    On a successful auth su prints "su: switched to uid <N> (alice)"
#    using sys_getuid() and THEN execs alice's login shell. The printed
#    line is the deterministic identity proof — it does not depend on the
#    nested login shell's interactive stdin (which is unreliable under
#    sys_spawn/execve). su's Password: prompt reads with echo suppressed.
type_cmd "echo $M_SU_OK" 2
type_cmd "su $ALICE" 8
type_line "$ALICE_PW" 6
# Give su time to authenticate, run SYS_SETUID_AUTH, and print the
# identity line before we fence the slice closed.
sleep 8
type_cmd "echo $M_WHOAMI" 4

type_cmd "echo $M_DONE" 3
sleep 3

installed_boot_stop

LOG="$INSTALLED_LOG"
echo "[test_auth] --- serial log ---"
cat "$LOG"
echo "[test_auth] --- end serial log ---"

# Sanitize (strip CRs + CSI/SGR escapes).
CLEAN=$(mktemp --tmpdir hamnix-auth.clean.XXXXXX.log)
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" > "$CLEAN"

slice() {
    awk -v a="$1" -v b="$2" '
        $0 ~ a { grab=1; next }
        $0 ~ b { grab=0 }
        grab   { print }
    ' "$CLEAN"
}

ADD=$(slice "$M_ADD" "$M_PASSWD")
PASSWD=$(slice "$M_PASSWD" "$M_SU_BAD")
SU_BAD=$(slice "$M_SU_BAD" "$M_SU_OK")
SU_OK=$(slice "$M_SU_OK" "$M_WHOAMI")

fail=0
ALICE_UID=""

# Sanity: the box booted to an interactive prompt.
grep -a -q "$KERNEL_BANNER" "$LOG" || { echo "[test_auth] FAIL: kernel banner absent." >&2; fail=1; }
grep -a -q "$PROMPT_MARKER" "$LOG" || { echo "[test_auth] FAIL: shell-ready marker absent." >&2; fail=1; }

# A. useradd alice reported success, and we LEARN the uid it allocated.
#
# 2026-07-31: assertion C used to demand the literal "switched to uid 1000".
# useradd allocates the lowest free uid >= 1000 by scanning /etc/passwd, and
# etc/passwd has since gained TWO shipped accounts in that range -- `dave` at
# 1000 (ef449d6e) and `live` at 1001 (10db26d2, the live->hostowner rename).
# alice is therefore 1002, and the gate had been asserting a roster that no
# longer exists. This file's own header always said "uid >= 1000"; only the
# assertion was pinned. Gate rot, not an auth defect.
#
# Rather than loosen C to "any uid >= 1000" (which would no longer prove su
# reached the RIGHT account), take the uid straight out of useradd's own report
# -- "useradd: created alice (uid 1002) with home server #alice ..." -- and
# require su to land on exactly that. That is STRICTER than the old check: it
# cross-checks the allocator against the authenticator, and it survives the next
# account added to etc/passwd.
if printf '%s\n' "$ADD" | grep -a -q -E "useradd: created $ALICE"; then
    ALICE_UID=$(printf '%s\n' "$ADD" \
        | sed -n "s/.*useradd: created $ALICE (uid \([0-9]\{1,\}\)).*/\1/p" \
        | head -1)
    if [ -z "$ALICE_UID" ]; then
        echo "[test_auth] FAIL (A): useradd reported success but did not print" \
             "the allocated uid; cannot cross-check C." >&2
        printf '%s\n' "$ADD" | sed 's/^/      /' >&2
        fail=1
    elif [ "$ALICE_UID" -lt 1000 ]; then
        echo "[test_auth] FAIL (A): useradd allocated uid $ALICE_UID for $ALICE;" \
             "regular accounts must be >= 1000 (1=hostowner, 2..999 system)." >&2
        fail=1
    fi
    echo "[test_auth] PASS (A): useradd $ALICE created the account (uid ${ALICE_UID:-?})."
else
    echo "[test_auth] FAIL (A): 'useradd: created $ALICE' not seen." >&2
    printf '%s\n' "$ADD" | sed 's/^/      /' >&2
    fail=1
fi

# B. passwd alice reported the password was updated.
if printf '%s\n' "$PASSWD" | grep -a -q -E "password updated successfully"; then
    echo "[test_auth] PASS (B): passwd $ALICE set the password (kernel rewrote live /etc/shadow)."
else
    echo "[test_auth] FAIL (B): 'password updated successfully' not seen." >&2
    printf '%s\n' "$PASSWD" | sed 's/^/      /' >&2
    fail=1
fi

# C. su alice with the right password changed identity. THE crux assertion:
#    passwd's write and su's verify hit the SAME live /etc/shadow, or this
#    fails. After a verified /dev/auth "ok" + SYS_SETUID_AUTH, su prints
#    "su: switched to uid <N> (alice)" using sys_getuid() — proving its
#    OWN process identity actually became alice's uid (the one useradd
#    reported in assertion A -- 1002 today, since dave=1000 and live=1001
#    are shipped in etc/passwd), independent
#    of any nested-shell interactive read. If passwd and su had hit
#    different shadows the auth would have been DENIED and this line would
#    never print.
if [ -z "$ALICE_UID" ]; then
    echo "[test_auth] FAIL (C): no uid from useradd to cross-check against." >&2
    fail=1
elif printf '%s\n' "$SU_OK" | grep -a -q -E "su: switched to uid $ALICE_UID \($ALICE\)"; then
    echo "[test_auth] PASS (C): su $ALICE (right password) -> 'su: switched to uid $ALICE_UID ($ALICE)' — identity changed to the uid useradd allocated, live shadow consulted."
else
    echo "[test_auth] FAIL (C): su did NOT confirm the identity change to '$ALICE' at uid $ALICE_UID (auth or SYS_SETUID_AUTH failed)." >&2
    printf '%s\n' "$SU_OK" | sed 's/^/      /' >&2
    fail=1
fi

# D. su alice with the WRONG password is denied.
if printf '%s\n' "$SU_BAD" | grep -a -q -E "Authentication failure"; then
    echo "[test_auth] PASS (D): su $ALICE (wrong password) -> 'Authentication failure' — bad password denied."
else
    echo "[test_auth] FAIL (D): wrong-password su was NOT denied (no 'Authentication failure' line)." >&2
    printf '%s\n' "$SU_BAD" | sed 's/^/      /' >&2
    fail=1
fi

# No CPU trap during the run.
if grep -a -q -E "TRAP: vector|page fault" "$LOG"; then
    echo "[test_auth] FAIL: CPU exception observed during the run:" >&2
    grep -a -E "TRAP: vector|page fault" "$LOG" | head -5 >&2
    fail=1
fi

rm -f "$CLEAN"
if [ "$fail" -eq 0 ]; then
    echo "[test_auth] PASS — Hamnix is a real multi-user system: useradd -> passwd -> su authenticates (right ok, wrong denied)."
    rm -f "$LOG"
    exit 0
else
    echo "[test_auth] FAIL (serial log: $LOG)" >&2
    exit 1
fi
