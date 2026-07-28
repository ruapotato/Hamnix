#!/usr/bin/env bash
# scripts/test_bind_warn.sh — Phase 9 acceptance for the source-first
# bind flip + inversion warning (docs/rootfs_partition.md "Future
# direction — hamsh `bind` syntax — source first").
#
# WHAT THIS PROVES (all three, unforgeably):
#   1. The source-first `bind SRC DST` order actually LANDS in the
#      namespace — `bind '#s' /n` re-grafts the srv device onto the
#      already-resolving lookup name /n (an MREPL replace of the default
#      /n -> #/ binding). Proven by reading /proc/self/ns back THROUGH
#      `rev`: the reversed line "s# n/ dnib" (i.e. "bind /n #s") can only
#      materialise in `rev`'s OUTPUT — it never appears in the typed
#      command echo, so a serial-echo leak can no longer satisfy it.
#   2. The inversion warning fires for `bind /n '#s'` (arg2 starts with
#      '#' and arg1 does not) — asserted on the program-generated stderr
#      marker text, which is likewise absent from the typed line.
#   3. The warning does NOT refuse the call: hamsh emits NO "bind: …"
#      failure line for the inverted form (run_builtin prints one only
#      when the builtin returns an error), and the shell keeps executing.
#
# WHY THE REWRITE (false-green fix, task #27): the previous revision
# asserted the literal strings "/srv_alt" and "/srv_inv". Those strings
# also appear in the `bind` COMMAND LINES the harness TYPES, so the
# 16550 serial ECHO of the typed input satisfied the grep even though
# the binds never landed — the classic typed-input-echo false-green
# ([[feedback_false_green_console_leak]]). Worse, /srv_alt and /srv_inv
# do not pre-resolve in the namespace, so a source-first bind onto them
# silently no-ops: the gate was green over a bind that DID NOTHING.
# Every assertion now keys on a token that can ONLY be produced by the
# guest's real code path (a reversed /proc/self/ns readback, a program-
# generated stderr marker), never by input echo.
#
# DRIVE STRATEGY: hamsh as /init (INIT_ELF=hamsh.elf) — no rc.boot, so
# no sshd accept-loop to starve the interactive shell — driven through
# the load-adaptive scripts/_hamsh_drive.sh handshake (boot-ready marker
# + FEEDER_SYNC + send-once-wait-effect). A starved guest that never
# reaches its markers is reported INCONCLUSIVE (scripts/_verdict.sh),
# never a starvation-false-FAIL or an echo-false-green.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_bind_warn
# -smp 1: this gate wants a trustworthy verdict, and an -smp 2 boot is
# only false-FAIL-prone under host contention (a PASS stays trustworthy).
export HAMNIX_TEST_SMP="${HAMNIX_TEST_SMP:-1}"
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_bind_warn] (1/3) Build userland (hamsh + rev + helpers)"
bash scripts/build_user.sh >/dev/null

echo "[test_bind_warn] (2/3) Plant hamsh as /init (no rc.boot / no sshd)"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_bind_warn] (3/3) Build kernel"
mkdir -p build
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    # Restore the default initramfs so subsequent gates boot the
    # production /init shim path.
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG" "${CLEAN:-}"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# One command per line; a following unique echo marker is a cheap serial
# barrier (readline is provably live after the sync, and consumes lines in
# order, so the marker echoes only AFTER the preceding command returns).
drive_step() {                      # $1 = command   $2 = barrier marker
    hamsh_send "$1"
    hamsh_send_await "echo $2" "$2" "$CMD_WAIT" || true
}

# 1. Source-first forward bind onto an already-resolving name (/n): it
#    replaces /n -> #/ with /n -> #s. No warning expected (dst=/n).
drive_step "echo BW_FWD_BEGIN"      BW_FWD_MARK
hamsh_send "bind '#s' /n"
drive_step "echo BW_FWD_END"        BW_FWD_END_MARK

# 2. Inverted form: dst '#s' starts with '#', src /n does not -> warns.
drive_step "echo BW_INV_BEGIN"      BW_INV_MARK
hamsh_send "bind /n '#s'"
drive_step "echo BW_INV_END"        BW_INV_END_MARK

# 3. Read the namespace back THROUGH rev so the forward-bind landing shows
#    up only in program OUTPUT (reversed), never in the typed echo.
hamsh_send "echo BW_REV_BEGIN"
hamsh_send "cat /proc/self/ns | rev"
drive_step "echo BW_REV_DONE"       BW_REV_DONE_MARK

hamsh_send 'exit'
sleep 2

echo "[test_bind_warn] --- captured output (tail) ---"
tail -200 "$LOG" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r//g'
echo "[test_bind_warn] --- end ---"

# Normalise: strip ANSI SGR / cursor escapes and CRs so the char-by-char
# line-editor echo can't split a token across rebuilt lines.
CLEAN=$(mktemp)
sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b[()][AB0]//g' -e 's/\r//g' \
    "$LOG" > "$CLEAN"

# Nothing observed at all -> INCONCLUSIVE, not a FAIL.
verdict_boot_gate "$TAG" "$CLEAN" 0 'BW_(FWD|INV|REV)_BEGIN'

fail=0

# (a) UNFORGEABLE: the reversed /proc/self/ns readback proves the
#     source-first forward bind actually landed — /n now resolves to #s.
#     "s# n/ dnib" is "bind /n #s" reversed; it exists ONLY in rev's
#     output. (The default /n binding renders "bind /n #/".) The reversed
#     token appears nowhere in any typed command, so an echo leak cannot
#     forge it.
if grep -a -F -q "s# n/ dnib" "$CLEAN"; then
    echo "[test_bind_warn] OK: source-first 'bind #s /n' LANDED (/n -> #s, reversed readback)"
else
    echo "[test_bind_warn] MISS: forward bind did not land — no reversed '/n -> #s' in the ns readback"
    fail=1
fi

# (b) UNFORGEABLE: the inversion warning fired. This marker text is
#     emitted by hamsh's _hamsh_bind_warn to stderr; it is NOT present in
#     the typed 'bind /n #s' line.
if grep -a -F -q "[hamsh-bind] WARN: argument order looks inverted" "$CLEAN"; then
    echo "[test_bind_warn] OK: inversion warning fired for 'bind /n \"#s\"'"
else
    echo "[test_bind_warn] MISS: no inversion warning observed"
    fail=1
fi

# (c) NEGATIVE CONTROL: the forward (source-first) form must NOT warn.
#     Scan only the window between the forward begin/end barriers.
if awk '/BW_FWD_BEGIN/{a=1;next} /BW_FWD_END/{a=0} a' "$CLEAN" \
        | grep -a -F -q "hamsh-bind"; then
    echo "[test_bind_warn] FAIL: warning fired on the source-first call"
    fail=1
else
    echo "[test_bind_warn] OK: source-first form did NOT trigger the warning"
fi

# (d) The warning does NOT refuse the call: run_builtin prints "bind: …"
#     only when the builtin returns an error, so its ABSENCE proves the
#     inverted call was accepted (not refused) despite the warning.
if grep -a -E -q '(^|[^A-Za-z])bind: ' "$CLEAN"; then
    echo "[test_bind_warn] FAIL: a 'bind: …' error line appeared — the call was refused"
    grep -a -E '(^|[^A-Za-z])bind: ' "$CLEAN" | sed 's/^/    /'
    fail=1
else
    echo "[test_bind_warn] OK: warning did not refuse the call (no 'bind: …' error)"
fi

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a bind source-first / inversion-warning assertion was VIOLATED (see MISS:/FAIL lines)."
verdict_pass "$TAG" "source-first bind lands (rev readback), inversion warns on stderr, warning is non-fatal."
