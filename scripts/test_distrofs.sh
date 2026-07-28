#!/usr/bin/env bash
# scripts/test_distrofs.sh — smoke for user/distrofs.ad, the userland
# 9P file-server daemon that exports a distro-shaped /var tree.
#
# Pipeline:
#   1. Build userland (hamsh + coreutils + distrofs). build_user.sh's
#      auto-list builds distrofs; build_initramfs.py's glob embeds it
#      at /bin/distrofs in the cpio.
#   2. Build the fixture tests/test_distrofs.ad -> /bin/test_distrofs.
#   3. Plant /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image, boot, drive /bin/test_distrofs, exit.
#   5. Grep the serial log for the round-trip markers + PASS.
#
# MIGRATED (test-trustworthiness sweep) off the old fixed-`sleep 3`
# feeder onto the load-adaptive scripts/_hamsh_drive.sh (boot-ready
# marker + FEEDER_SYNC handshake + send-once). Assertions read the
# fixture's OWN `[distrofs] …` OUTPUT markers, never the typed
# `/bin/test_distrofs` input-echo. Three-valued verdict: a starved
# guest is INCONCLUSIVE, an OBSERVED violation is a real FAIL.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_distrofs
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_distrofs.elf

echo "[test_distrofs] (1/4) Build userland (hamsh + coreutils + distrofs)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_distrofs] (2/4) Build tests/test_distrofs.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_distrofs.ad "$TEST_ELF" >/dev/null

echo "[test_distrofs] (3/4) Plant /init = hamsh + /bin/test_distrofs in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_distrofs] (4/4) Rebuild kernel image + boot"
mkdir -p build
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

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
hamsh_send_await '/bin/test_distrofs' '[distrofs] start' "$CMD_WAIT" || true
for _ in $(seq 1 "$CMD_WAIT"); do
    grep -a -Eq '\[distrofs\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
    hamsh_alive || break
    sleep 1
done
hamsh_send 'exit'
sleep 2

echo "[test_distrofs] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_distrofs] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[distrofs\] (start|PASS|FAIL)'

fail=0
check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_distrofs] OK: $label"
    else
        echo "[test_distrofs] MISS: $label ($marker)"
        fail=1
    fi
}

if grep -a -F -q "[distrofs] FAIL:" "$LOG"; then
    echo "[test_distrofs] observed per-assertion FAIL line(s):"
    grep -a -F "[distrofs] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
fi

check "[distrofs] start"            "fixture ran"
check "[distrofs] spawn OK"         "/bin/distrofs spawned"
check "[distrofs] server starting"  "daemon printed banner"
check "[distrofs] Rversion OK"      "Tversion round-trip"
check "[distrofs] Rattach OK"       "Tattach round-trip"
check "[distrofs] Rwalk dpkg OK"    "Twalk var/lib/dpkg round-trip"
check "[distrofs] Rcreate OK"       "Tcreate status file"
check "[distrofs] Rwrite OK"        "Twrite payload bytes"
check "[distrofs] Rwalk status OK"  "re-walk to created file"
check "[distrofs] Ropen OK"         "Topen round-trip"
check "[distrofs] payload match OK" "Tread returned written bytes"
check "[distrofs] Rstat dir OK"     "Tstat of a directory"
check "[distrofs] PASS"             "fixture reached PASS"

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a distrofs 9P round-trip assertion was VIOLATED (see MISS:/FAIL lines)."
verdict_pass "$TAG" "distrofs 9P round-trip verified end-to-end."
