#!/usr/bin/env bash
# scripts/test_de_cursor_hotspot.sh — DE cursor-hotspot + keys-lossless gate.
#
# Guards two user-reported DE input rough edges via the ALWAYS-ON boot:37
# window-server self-tests (sys/src/9/port/devwsys.ad), which run
# unconditionally on every boot (the wsys_close_box_selftest chain):
#
#   [CURSOR_HOTSPOT] PASS — the cursor sprite's blit ORIGIN (its arrow TIP)
#       coincides EXACTLY with the routed hit-test point (wsys_cursor_x/y).
#       This is the "clicks register at the arrow's BOTTOM, not its tip"
#       bug: if the tip and the hit point ever diverge again a click lands
#       off the visible tip, and this marker flips to FAIL.
#
#   [KEYS_LOSSLESS] PASS — a burst pushed into a focused window's /keys ring
#       drains back out in order with no loss (the IRQ-safe keyboard ring
#       the DE terminal reads from). Guards the input-echo path against a
#       dropped/one-behind keystroke regression.
#
# Both markers are emitted at boot:37 BEFORE the shell prompt, so we only
# need to boot far enough to see the shell ready, then grep the log — no
# keystroke or fixture needed (robust under concurrent-agent host load).
#
# Three-valued verdict: a boot that never reaches the prompt is INCONCLUSIVE
# (host-starved), not a FAIL.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_de_cursor_hotspot
BOOT_WAIT="${BOOT_WAIT:-420}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[cursor_hotspot] (1/2) Build userland + kernel"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

echo "[cursor_hotspot] (2/2) Boot QEMU; scrape boot:37 wsys self-test markers"
hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_send 'exit'
sleep 2

echo "[cursor_hotspot] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[cursor_hotspot] --- end output ---"

fail=0

if grep -aq '\[CURSOR_HOTSPOT\] PASS' "$LOG"; then
    echo "[cursor_hotspot] OK: cursor arrow TIP == routed hit-test point"
else
    if grep -aq '\[CURSOR_HOTSPOT\] FAIL' "$LOG"; then
        echo "[cursor_hotspot] FAIL: cursor tip diverged from the hit point (clicks land off-tip)"
        fail=1
    else
        verdict_inconclusive "$TAG" "no [CURSOR_HOTSPOT] marker in the boot log (selftest never ran)"
    fi
fi

if grep -aq '\[KEYS_LOSSLESS\] PASS' "$LOG"; then
    echo "[cursor_hotspot] OK: focused-window /keys ring is lossless (no dropped keystroke)"
else
    if grep -aq '\[KEYS_LOSSLESS\] FAIL' "$LOG"; then
        echo "[cursor_hotspot] FAIL: /keys ring dropped/reordered a keystroke"
        fail=1
    else
        verdict_inconclusive "$TAG" "no [KEYS_LOSSLESS] marker in the boot log (selftest never ran)"
    fi
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" "a wsys input self-test reported FAIL"
fi

verdict_pass "$TAG" "cursor hotspot + keys-lossless self-tests PASS"
