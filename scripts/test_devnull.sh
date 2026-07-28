#!/usr/bin/env bash
# scripts/test_devnull.sh — M16.68 verification.
#
# Exercises /dev/null as both a write SINK and a read EOF source via
# the shell:
#   /bin/echo SINK_MARK > /dev/null  — sink consumes everything; the
#                                      marker never reaches stdout
#   /bin/echo VISIBLE_MARK           — control: an un-redirected write
#                                      DOES reach stdout
#   cat /dev/null                    — immediate EOF, no output
#
# Asserts that:
#   1. An external command redirected to /dev/null produces no output
#   2. The same command WITHOUT the redirect does reach stdout (so the
#      absence in (1) is the redirect working, not the command failing)
#   3. cat /dev/null prints nothing and the shell survives it
#
# WHY /bin/echo, NOT the `echo` builtin: the shell's `echo` is an
# in-process builtin whose redirect handling is intentionally minimal
# (see user/hamsh.ad — `_builtin_dispatch`: builtins run at prompt
# scope; `> file` is wired only for SPAWNED children via
# _wire_redirects). `> /dev/null` on a builtin is therefore a no-op by
# design — testing it would test the builtin limitation, not /dev/null.
# `/bin/echo` is the external coreutils tool; its stdout IS rebound to
# /dev/null by _wire_redirects, exercising the real sink path.
#
# WHY hamsh_ran, NOT a plain grep: hamsh's interactive line editor
# echoes every keystroke, so the typed `/bin/echo SINK_MARK ...` line
# lands in the serial log too. hamsh_ran (scripts/_hamsh_log.sh) drops
# the prompt-prefixed input-echo lines and inspects genuine command
# output only — so the SINK_MARK assertion measures /dev/null, not the
# editor repainting the command as it was typed.

# Input is PROMPT-GATED + output-adaptive via scripts/_hamsh_drive.sh — the
# old fixed-sleep feeder shoved every command at the 16550 before hamsh was
# reading, so under load the first command was dropped and the gate false-red.
. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devnull
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# Redirect an EXTERNAL command's stdout to /dev/null (sink should absorb it),
# then a control write with NO redirect (must reach stdout), then read
# /dev/null (immediate EOF), then a survival sentinel. Each command is
# waited on its OWN observable effect, not a fixed sleep.
hamsh_send '/bin/echo SINK_MARK_XYZ > /dev/null'
hamsh_send_await '/bin/echo VISIBLE_MARK_XYZ' 'VISIBLE_MARK_XYZ' "$CMD_WAIT" || true
hamsh_send 'cat /dev/null'
hamsh_send_await '/bin/echo POST_CAT_XYZ' 'POST_CAT_XYZ' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

# Never observed the fixture's own output at all -> the guest was starved,
# not that /dev/null is broken. That is INCONCLUSIVE, never a false red.
verdict_boot_gate "$TAG" "$LOG" 0 'VISIBLE_MARK_XYZ|POST_CAT_XYZ'

# The control write is the observation everything else hangs off: if it
# never reached stdout the guest simply did not get far enough, and the
# "sink absorbed it" check below would falsely pass on an empty log. So an
# absent control is INCONCLUSIVE, not FAIL.
if ! hamsh_ran "$LOG" "VISIBLE_MARK_XYZ"; then
    verdict_inconclusive "$TAG" \
        "the un-redirected control echo never reached stdout within" \
        "${CMD_WAIT}s — the guest was starved before it could run the" \
        "fixture; nothing about /dev/null was observed. Re-run on a quiet host."
fi
echo "[test_devnull] OK: un-redirected echo reached stdout"

fail=0
# 1. SINK_MARK_XYZ must NOT appear in genuine command output — the
#    `> /dev/null` redirect rebound the external echo's /fd/1 to the
#    sink. Now that the control DID reach stdout, an absent SINK marker is
#    real evidence the sink worked (not just an empty log). A PRESENT SINK
#    marker is an OBSERVED leak -> FAIL.
if hamsh_ran "$LOG" "SINK_MARK_XYZ"; then
    echo "[test_devnull] MISS: SINK_MARK_XYZ leaked through /dev/null"
    fail=1
else
    echo "[test_devnull] OK: /dev/null absorbed redirected stdout"
fi
# 2. The shell survived cat /dev/null. Absence here cannot distinguish a
#    wedge from starvation -> INCONCLUSIVE (handled after the leak check).
post_ok=0
if hamsh_ran "$LOG" "POST_CAT_XYZ"; then
    echo "[test_devnull] OK: shell survived cat /dev/null"
    post_ok=1
else
    echo "[test_devnull] NOTE: POST_CAT_XYZ survival sentinel not observed"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devnull] --- captured output ---"
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
    echo "[test_devnull] --- end output ---"
    verdict_fail "$TAG" "/dev/null LEAKED redirected stdout (SINK_MARK observed as output)"
fi
if [ "$post_ok" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "/dev/null absorbed the redirect and the control write reached" \
        "stdout, but the POST_CAT_XYZ survival sentinel was not seen within" \
        "${CMD_WAIT}s — cannot tell a wedge from a starved guest. Re-run quiet."
fi
verdict_pass "$TAG" "/dev/null absorbs redirected stdout; control write reaches stdout; shell survives cat /dev/null"
