#!/usr/bin/env bash
# scripts/test_9p_v35_userinit.sh — 9P V3.5 regression.
#
# Verifies the V3.5 Plan 9 layering:
#
#   - Kernel exposes `#X` device aliases directly (`#s`, `#p`,
#     `#c`, `#/`); they open without any namespace binding.
#   - Userspace `init` (user/init.ad) does the canonical `bind`
#     calls at boot before exec'ing hamsh.
#   - After init runs, `/srv`, `/proc/<pid>/ns`, `/n` resolve to
#     the same devices via chan_resolve_prefix rewrite.
#   - The init recipe is rendered in /proc/1/ns (three bind lines).
#
# Unlike test_9p_v3_defaults.sh, this script boots with init.elf as
# `/init` (NOT hamsh directly), proving the recipe-driven path works
# end to end. init exec's hamsh after applying binds.
#
# Markers (greppable):
#   [v35-userinit] start
#   [v35-hash-s] OK
#   [v35-hash-p] OK
#   [v35-hash-c] OK
#   [v35-hash-slot] OK
#   [v35-recipe-srv] OK
#   [v35-recipe-proc] OK
#   [v35-recipe-n] OK
#   [v35-recipe-text] OK
#   [v35-userinit] PASS

# ---------------------------------------------------------------------------
# MIGRATED onto scripts/_hamsh_drive.sh (test-trustworthiness campaign).
# The legacy driver did `( sleep N; printf '/bin/test_9p_v35_userinit\n'; ... ) | qemu`:
# under host load the fixed sleep raced ahead of hamsh's readline and the
# command was dropped, so the gate MISSed its own markers and reported a
# FALSE red. This drives hamsh prompt-gated (boot-ready marker) + output-
# adaptive (FEEDER_SYNC handshake, send-once/wait-on-effect) and reports the
# three-valued verdict: a starved guest is INCONCLUSIVE, an observed fixture
# `[v35-userinit] FAIL:` (or a started-but-never-PASSed run while the shell demonstrably
# survived) is FAIL, and only an observed `[v35-userinit] PASS` is a green.
. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_9p_v35_userinit
BTAG='v35-userinit'
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_v35_userinit.elf
TEST_SRC=tests/test_9p_v35_userinit.ad
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
 python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

# ---- boot + drive --------------------------------------------------------
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
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
