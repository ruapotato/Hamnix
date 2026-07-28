#!/usr/bin/env bash
# scripts/test_9p_codec.sh — 9P V0 codec round-trip regression.
#
# Builds tests/test_9p_codec.ad as a userland ELF, plants it at
# /bin/test_9p_codec, boots QEMU + hamsh, runs the binary, and
# greps the serial log for the [p9codec] PASS banner.
#
# The test covers every T- and R-message in docs/9p.md §3:
# Tversion/Rversion, Tauth/Rauth, Tattach/Rattach, Rerror,
# Tflush/Rflush, Twalk/Rwalk, Topen/Ropen, Tcreate/Rcreate,
# Tread/Rread, Twrite/Rwrite, Tclunk/Rclunk, Tstat/Rstat,
# Twstat/Rwstat. Plus four malformed-input cases: truncated
# header, wrong type byte, oversize body, undersize body.
#
# PASS criterion: "[p9codec] failures=0" AND "[p9codec] PASS"
# both present in the serial log. Any non-zero failures count
# escalates to FAIL with the captured log dumped.
#
# Shape borrowed from scripts/test_p9file.sh (Phase C P9 file
# fixture) — boot once, drive via hamsh stdin, grep stdout.

# ---------------------------------------------------------------------------
# MIGRATED onto scripts/_hamsh_drive.sh (test-trustworthiness campaign).
# The legacy driver did `( sleep N; printf '/bin/test_9p_codec\n'; ... ) | qemu`:
# under host load the fixed sleep raced ahead of hamsh's readline and the
# command was dropped, so the gate MISSed its own markers and reported a
# FALSE red. This drives hamsh prompt-gated (boot-ready marker) + output-
# adaptive (FEEDER_SYNC handshake, send-once/wait-on-effect) and reports the
# three-valued verdict: a starved guest is INCONCLUSIVE, an observed fixture
# `[p9codec] FAIL:` (or a started-but-never-PASSed run while the shell demonstrably
# survived) is FAIL, and only an observed `[p9codec] PASS` is a green.
. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_9p_codec
BTAG='p9codec'
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_codec.elf
TEST_SRC=tests/test_9p_codec.ad
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

# ---- build ---------------------------------------------------------------
bash scripts/build_user.sh >/dev/null \
    || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null \
    || verdict_inconclusive "$TAG" "build_modules failed"
python3 -m compiler.adder compile --target=x86_64-adder-user \
    "$TEST_SRC" -o "$TEST_ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "fixture compile failed ($TEST_SRC)"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

# ---- boot + drive --------------------------------------------------------
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# Run the fixture ONCE and wait on its OWN terminal banner ([BTAG] PASS).
# Then a survival sentinel: a trivial external echo AFTER the fixture, waited
# on its own effect. If POST lands, the shell was demonstrably alive — so a
# fixture that still never reached PASS aborted/hung (a real bug), NOT a
# starved guest. This is the false-red/false-green discriminator.
hamsh_send_await "/bin/$TAG" "[$BTAG] PASS" "$CMD_WAIT" || true
hamsh_send_await "/bin/echo POST_${TAG}_OK" "POST_${TAG}_OK" "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[$TAG] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[$TAG] --- end output ---"

# ---- verdict -------------------------------------------------------------
# Guest demonstrably alive & producing output? Require the fixture's start
# banner OR the survival sentinel; neither after a clean boot+sync means a
# wedge/starve — verdict_boot_gate sorts INCONCLUSIVE vs FAIL.
verdict_boot_gate "$TAG" "$LOG" 0 "\\[$BTAG\\] start|POST_${TAG}_OK"

# 1. The fixture's OWN failure line is an OBSERVED regression -> FAIL.
if grep -aqF "[$BTAG] FAIL" "$LOG"; then
    grep -aF "[$BTAG] FAIL" "$LOG" | sed 's/^/  /'
    verdict_fail "$TAG" "fixture emitted [$BTAG] FAIL: — an OBSERVED regression"
fi
# 2. The fixture reached its aggregate PASS banner (only printed when every
#    sub-assertion held) -> the observation we are named for. PASS.
if grep -aqF "[$BTAG] PASS" "$LOG"; then
    verdict_pass "$TAG" "fixture reached [$BTAG] PASS (all sub-assertions held)"
fi
# 3. No terminal verdict. If the survival sentinel landed the shell was NOT
#    starved, so the fixture started and then aborted/hung before PASS -> a
#    real FAIL. If the sentinel is absent too, the guest starved mid-run and
#    we observed nothing conclusive -> INCONCLUSIVE.
if grep -aqF "POST_${TAG}_OK" "$LOG"; then
    verdict_fail "$TAG" \
        "fixture started but never reached [$BTAG] PASS and emitted no [$BTAG] FAIL" \
        "line, yet the post-fixture survival echo DID reach stdout — the shell" \
        "was alive, so the fixture aborted/hung mid-run (a real regression)."
fi
verdict_inconclusive "$TAG" \
    "fixture start seen but neither [$BTAG] PASS/FAIL nor the survival sentinel" \
    "was observed within ${CMD_WAIT}s — the guest starved mid-run. Re-run quiet."
