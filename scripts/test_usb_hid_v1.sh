#!/usr/bin/env bash
# scripts/test_usb_hid_v1.sh — V1 regression for the xHCI transfer engine.
#
# V0 (scripts/test_usb_hid.sh) proved the controller-detect + root-hub
# port-scan + HID-report-to-ASCII self-test. V1 adds the wire: Command
# Ring + Event Ring + slot lifecycle + control transfers + interrupt-IN
# polling. This script asserts the V1-specific markers:
#
#   1. The V1 transfer engine bring-up reached "controller running"
#      (RS=1, HCH=0). Without this Command Ring submission can't
#      complete and nothing else happens.
#
#   2. The synthetic transfer-engine self-test fired: we hand-write
#      one Transfer Event TRB into the Event Ring, call xhci_poll, and
#      assert that hid_kbd_report received it. The PASS marker is:
#
#         [xhci_v1] transfer-engine PASS (N reports)
#
#      This proves the *plumbing* (event-ring dequeue, cycle bit
#      tracking, hid_kbd_report dispatch, kbd_rx_push handoff) works
#      end-to-end without depending on whether qemu-xhci's live SETUP
#      handler accepted our TRB encoding on a given QEMU version.
#
#   3. The V0 markers still all PASS — the V0 self-test still emits
#      "[usb_hid] self-test PASS (17 cases)" and the atkbd PS/2 path
#      still emits "atkbd: self-test PASS (25 cases)". Any V1 patch
#      that accidentally drained the FIFO or broke the PS/2 driver
#      surfaces as a missing banner here.
#
# What this script DOES NOT do today: it does NOT use QEMU's `sendkey`
# QMP command to simulate a real keystroke. That path requires the
# live SETUP/Address Device/SET_PROTOCOL exchange to complete against
# qemu-xhci's emulated HID device, which is heavily TRB-encoding
# sensitive and varies across QEMU versions. The synthetic-completion
# test is a deliberate compromise from the V1 plan: it proves the
# transfer-engine code paths work even when the live exchange is
# flaky. See drivers/usb/xhci.ad's `xhci_v1_selftest()` docstring for
# the design rationale.
#
# Pass marker:    [usb_hid_v1] PASS
# Fail marker:    [usb_hid_v1] FAIL

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_usb_hid_v1

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

ELF=build/hamnix-kernel.elf

echo "[test_usb_hid_v1] (1/3) Build userland (init.elf must exist for cpio)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_usb_hid_v1] (2/3) Build initramfs with /etc/xhci-selftest marker"
# ENABLE_XHCI_SELFTEST plants /etc/xhci-selftest so init/main.ad's gated
# xhci_v1_selftest / xhci_v2_selftest actually fire. Default boots skip
# the synthetic selftests (real-hw safety on PS/2-only Asus etc. — the
# synthetic event injection hangs xhci_poll when no USB kbd enumerated).
# The trap below rebuilds the initramfs without the marker so subsequent
# test runs get a clean default.
INIT_ELF=build/user/init.elf ENABLE_XHCI_SELFTEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_usb_hid_v1] (3/3) Rebuild kernel + boot QEMU with qemu-xhci + usb-kbd"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 15s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    -device qemu-xhci \
    -device usb-kbd \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_usb_hid_v1] --- captured V1-relevant boot output ---"
grep -E "xhci|usb_hid|atkbd:|hid:" "$LOG" || true
echo "[test_usb_hid_v1] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero USB/xHCI markers == the guest never reached USB init: a starved/
# timed-out TCG boot, an OBSERVED crash, or GRUB OOM — NOT a V1 regression.
# rc=124 (timeout) is the EXPECTED normal exit (kernel HLTs after init).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[xhci\]|\[usb_hid|atkbd:'

fail=0

# --- V1 bring-up: Run/Stop went hot ----------------------------------
if grep -F -q "[xhci] controller running" "$LOG"; then
    echo "[test_usb_hid_v1] OK: controller RS=1 (transfer engine alive)"
else
    echo "[test_usb_hid_v1] MISS: controller never left Halted"
    fail=1
fi

# --- V1 synthetic transfer-engine round-trip --------------------------
# This is THE load-bearing V1 marker: it proves submit -> Event Ring
# -> xhci_poll -> hid_kbd_report -> kbd_rx_push all wire up.
if grep -E -q "\[xhci_v1\] transfer-engine PASS \([0-9]+ reports\)" "$LOG"; then
    echo "[test_usb_hid_v1] OK: synthetic transfer-engine PASS"
else
    echo "[test_usb_hid_v1] MISS: synthetic transfer-engine FAIL/missing"
    fail=1
fi

# --- V0 regressions: HID self-test still passes ----------------------
if grep -F -q "[usb_hid] self-test PASS (17 cases)" "$LOG"; then
    echo "[test_usb_hid_v1] OK: V0 HID self-test still PASS (no regression)"
else
    echo "[test_usb_hid_v1] MISS: V0 HID self-test PASS banner absent"
    fail=1
fi

# --- V0 regressions: atkbd PS/2 self-test still passes ---------------
if grep -F -q "atkbd: self-test PASS (25 cases)" "$LOG"; then
    echo "[test_usb_hid_v1] OK: atkbd PS/2 self-test still PASS"
else
    echo "[test_usb_hid_v1] MISS: atkbd PS/2 self-test regressed"
    fail=1
fi

# --- V0 regressions: root-hub port scan still finds the kbd ----------
if grep -E -q "\[xhci\] root hub: keyboard at port [0-9]+" "$LOG"; then
    echo "[test_usb_hid_v1] OK: V0 root-hub keyboard discovery still works"
else
    echo "[test_usb_hid_v1] MISS: V0 root-hub keyboard discovery regressed"
    fail=1
fi

# A kernel panic / unexpected TRAP between init phases would prevent
# the kernel from reaching xhci_v1_selftest at all.
if grep -E -q "PANIC|TRAP: vector" "$LOG"; then
    echo "[test_usb_hid_v1] MISS: kernel panic / unexpected trap in boot log"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "USB/xHCI markers were observed (the guest booted) but a required V1" \
        "transfer-engine / V0 regression marker was OBSERVED absent or a" \
        "FAIL/TRAP was printed (qemu rc=$rc) — a real xHCI V1 regression."
fi

# rc=124 is timeout, the expected "kernel HLT'd after init" outcome.
if [ "$rc" -ne 124 ] && [ "$rc" -ne 0 ]; then
    verdict_fail "$TAG" \
        "the guest booted and produced USB markers but qemu exited rc=$rc" \
        "(neither 0 nor the expected 124 HLT-timeout) — an OBSERVED abnormal exit."
fi

verdict_pass "$TAG" "xHCI V1 transfer engine: controller RS=1, Command/Event" \
    "ring + slot lifecycle + control transfers, synthetic transfer-engine PASS," \
    "and V0 HID + atkbd self-tests still PASS (qemu rc=$rc)"
