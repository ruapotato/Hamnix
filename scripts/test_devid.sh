#!/usr/bin/env bash
# scripts/test_devid.sh — regression for /dev/version + /dev/hostname.
#
# Runs BOTH fixtures (test_devversion + test_devhostname) inside the same
# QEMU boot so we only pay the build-and-boot cost once:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixtures tests/test_devversion.ad and
#      tests/test_devhostname.ad. build_initramfs.py auto-globs
#      build/user/*.elf so they land at /bin/test_devversion and
#      /bin/test_devhostname in the cpio.
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devversion.ad + devhostname.ad +
#      FD_VERSION_MARK / FD_HOSTNAME_MARK arms are compiled in.
#   5. Boot in QEMU, drive both fixtures over the serial stdio, grep
#      the captured log for the contract markers.
#
# PASS markers:
#   - "[test_devversion] contains_hamnix=1" (the fixture confirmed the
#     /dev/version blob contains the "hamnix" substring).
#   - "[test_devhostname] roundtrip_ok=1" (the fixture read the initial
#     hostname "hamnix", wrote "test-host", and read it back).
# We also assert each fixture's "done" banner and that hamsh remains
# responsive after both round-trips.
#
# INPUT TIMING: prompt-gated + output-adaptive via scripts/_hamsh_drive.sh.
# The old ( sleep 3; printf ... ) | qemu feeder shoved every command at the
# 16550 RX FIFO before hamsh was reading, so under host load the first
# command was dropped and the gate reported a FALSE RED. Each command is now
# sent once after a FEEDER_SYNC handshake and waited on its OWN effect; a run
# that never gets far enough is INCONCLUSIVE (scripts/_verdict.sh), never a
# false green or false red.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devid
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
VER_ELF=build/user/test_devversion.elf
HN_ELF=build/user/test_devhostname.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_devid] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_devid] (2/5) Build tests/test_devversion.ad + test_devhostname.ad"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devversion.ad "$VER_ELF" >/dev/null || verdict_inconclusive "$TAG" "test_devversion.ad compile failed"
adder_bin x86_64-adder-user tests/test_devhostname.ad "$HN_ELF" >/dev/null || verdict_inconclusive "$TAG" "test_devhostname.ad compile failed"

echo "[test_devid] (3/5) Plant /init = hamsh + /bin/test_dev{version,hostname} in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_devid] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_devid] (5/5) Boot QEMU per fixture + drive hamsh"
LOG=$(mktemp)      # devversion boot
LOG2=$(mktemp)     # devhostname boot
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG" "$LOG2"
}
trap cleanup EXIT

# ONE real command per boot. hamsh reliably executes exactly one command
# after the FEEDER_SYNC handshake; a SECOND command sent while it is still
# finishing the first can overflow the 16-byte 16550 RX FIFO (no software
# buffer) and be lost — observed here as the second fixture never echoing.
# Interactive `;`-chaining is not a workaround either (only the first
# statement of a submitted line runs). So each independent fixture gets its
# own boot; each is the single, reliable first command. We assert on genuine
# fixture OUTPUT markers only (never an `echo POST_X` whose input-echo the
# serial log would spuriously match).
drive_one() {  # $1=log  $2=cmd  $3=done-marker  $4=label
    hamsh_boot "$1" "$ELF"
    hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
        || verdict_inconclusive "$TAG" "$4: hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
    hamsh_sync 120 \
        || verdict_inconclusive "$TAG" "$4: readline never echoed FEEDER_SYNC — stdin not consumed"
    hamsh_send_await "$2" "$3" "$CMD_WAIT" || true
    hamsh_send 'exit'
    sleep 2
    hamsh_shutdown
}

drive_one "$LOG"  '/bin/test_devversion'  '[test_devversion] done'  "devversion"
drive_one "$LOG2" '/bin/test_devhostname' '[test_devhostname] done' "devhostname"

echo "[test_devid] --- captured output (devversion) ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG"  | tr -d '\000'
echo "[test_devid] --- captured output (devhostname) ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG2" | tr -d '\000'
echo "[test_devid] --- end output ---"

# If a fixture never even started in its boot, the guest never got far
# enough — that is starvation, not a /dev bug. INCONCLUSIVE, never a false
# red. (Checked per-fixture below; boot_gate here is a fast global guard.)
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devversion\] start'

fail=0
# ---- /dev/version (from its own boot log) ----
if grep -a -F -q "[test_devversion] start" "$LOG"; then
    for m in "[test_devversion] opened /dev/version OK" \
             "[test_devversion] contains_hamnix=1" \
             "[test_devversion] done"; do
        if grep -a -F -q "$m" "$LOG"; then
            echo "[test_devid] OK: '$m'"
        else
            echo "[test_devid] MISS: '$m'"; fail=1
        fi
    done
else
    verdict_inconclusive "$TAG" \
        "the test_devversion fixture never printed its start banner — the" \
        "guest was starved before it ran; nothing about /dev/version was" \
        "observed. Re-run on a quiet host."
fi

# ---- /dev/hostname (from its own boot log) ----
if grep -a -F -q "[test_devhostname] start" "$LOG2"; then
    for m in "[test_devhostname] initial_ok=1" \
             "[test_devhostname] roundtrip_ok=1" \
             "[test_devhostname] done"; do
        if grep -a -F -q "$m" "$LOG2"; then
            echo "[test_devid] OK: '$m'"
        else
            echo "[test_devid] MISS: '$m'"; fail=1
        fi
    done
else
    verdict_inconclusive "$TAG" \
        "the test_devhostname fixture never printed its start banner — the" \
        "guest was starved before it ran; nothing about /dev/hostname was" \
        "observed. Re-run on a quiet host."
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "a /dev/version or /dev/hostname contract marker was OBSERVED absent" \
        "while the fixture DID run (start banner present) — real regression."
fi

verdict_pass "$TAG" "/dev/version contains hamnix; /dev/hostname round-trips; both fixtures ran to clean done"
