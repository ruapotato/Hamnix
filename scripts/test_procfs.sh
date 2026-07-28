#!/usr/bin/env bash
# scripts/test_procfs.sh - M16.36 verification.
#
# Boots hamsh as /init, drives it through `ps` + `exit`, and greps the
# captured serial log for:
#
#   1. the /proc/version banner            → procfs renderer ran
#   2. the /proc/uptime line               → uptime helper formatted
#   3. the "__init__" comm                 → /proc/tasks walked the
#                                            task table and rendered
#                                            the live shell process
#
# MIGRATED (test-trustworthiness sweep) off the old fixed-`sleep 3` +
# resend feeder onto the load-adaptive scripts/_hamsh_drive.sh:
# boot-ready marker + FEEDER_SYNC handshake, then `ps` is sent exactly
# ONCE and waited on its own observable /proc/tasks output. The
# assertions read genuine `ps` OUTPUT (the /proc renderers' bytes), NOT
# the typed `ps` input-echo. Three-valued verdict (scripts/_verdict.sh):
# a guest that never reaches `ps` proves nothing about the renderers
# (this host starves TCG guests) → INCONCLUSIVE, not a false red.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"
. "$PROJ_ROOT/scripts/_hamsh_log.sh"

TAG=test_procfs
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_procfs] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_procfs] (2/3) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_procfs] (3/3) Rebuild kernel image + boot"
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
hamsh_send_await 'ps' '/proc/tasks ---' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_procfs] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_procfs] --- end output ---"

# Zero /proc/tasks output -> the guest was starved, not the renderer broken.
verdict_boot_gate "$TAG" "$LOG" 0 '/proc/tasks ---'

fail=0
# Assert on genuine command OUTPUT (drop prompt/input-echo lines).
for needle in \
    "hamnix/" \
    "/proc/uptime ---" \
    "PID	STATE	COMM" \
    "__init__"
do
    if hamsh_ran "$LOG" "$needle"; then
        echo "[$TAG] OK: '$needle'"
    else
        echo "[$TAG] MISS: '$needle'"
        fail=1
    fi
done

# /proc/uptime must render two decimal seconds fields, not a raw counter.
if ! sed -n '/--- \/proc\/uptime ---/,+1p' "$LOG" | grep -aqE '[0-9]+\.[0-9]+ [0-9]+\.[0-9]+'; then
    echo "[$TAG] MISS: /proc/uptime '<up> <idle>' decimal-seconds shape"
    fail=1
else
    echo "[$TAG] OK: /proc/uptime decimal-seconds shape"
fi

# No task row may render an empty COMM column (see test_proc_tasks_comm.sh).
EMPTY=$(sed -e 's/\r$//' "$LOG" | grep -aE '^[0-9]+	' | awk -F'\t' 'NF < 3 || $3 == "" { print $1 }')
if [ -n "$EMPTY" ]; then
    echo "[$TAG] MISS: empty COMM for pid(s): $(echo $EMPTY | tr '\n' ' ')"
    fail=1
fi

[ "$fail" -eq 0 ] || verdict_fail "$TAG" "one or more /proc renderers MISSed."
verdict_pass "$TAG" "/proc/version, /proc/uptime and /proc/tasks all rendered."
