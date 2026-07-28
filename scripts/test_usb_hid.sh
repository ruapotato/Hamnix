#!/usr/bin/env bash
# scripts/test_usb_hid.sh — V0 regression for the USB xHCI + HID
# boot-keyboard skeleton (drivers/usb/{xhci,hid,usb}.ad).
#
# Test strategy (two-pronged):
#
#   1. Boot QEMU with `-device qemu-xhci -device usb-kbd` and assert
#      that the kernel:
#        a. PCI-scans + finds the xHCI controller at a sane bdf,
#        b. successfully maps BAR0 + decodes the capability registers
#           (CAPLENGTH non-zero, max_ports populated),
#        c. resets the controller (HCRST clears, CNR clears),
#        d. walks the root-hub PORTSC array and identifies the
#           emulated `usb-kbd` as a boot-keyboard candidate. The
#           specific log line we assert on is:
#                 "[xhci] root hub: keyboard at port N"
#           Without this banner the BAR mapping or the port-scan is
#           regressed and there's no realistic path to a USB
#           keystroke reaching hamsh.
#
#   2. Assert the HID translator self-test passes. The driver runs
#      a deterministic synthetic-report battery at boot:
#        - lowercase 'a'
#        - Shift+'a' -> 'A'
#        - CapsLock latches across a release
#        - Shift+'1' -> '!'
#        - Ctrl+'c' -> 0x03 (SIGINT byte)
#        - Right-Ctrl+Shift+'d' -> 0x04
#        - Arrow Up  -> ESC [ A
#        - F1        -> ESC O P
#        - Diff suppression (held key yields ONE event, not two)
#        - Enter / Space / Backspace round-trip
#      The PASS banner is "[usb_hid] self-test PASS (N cases)" — the
#      N matches the number of _hid_expect calls in hid_self_test.
#      As of V0 there are 17 cases; bump the assertion together with
#      the driver if you add cases.
#
# Why this shape and NOT a `-monitor sendkey` end-to-end fixture:
# pressing a USB key in QEMU and observing it land in hamsh would
# require the V1 xHCI transfer engine (Command Ring, Event Ring, per-
# endpoint Transfer Rings, Address Device flow, GetDescriptor + Set
# Protocol exchange, interrupt-in polling). V0 deliberately stops at
# "device enumerated on the root hub, HID translator path proven via
# self-test bytes through the kbd FIFO". Real-keystroke verification
# is V1+ with an `expect`-style harness.
#
# Regression invariants this script ALSO enforces (negative checks):
#   - The atkbd PS/2 path is NOT disturbed. atkbd self-test still
#     reports PASS in this run, with the same 25-cases count as
#     scripts/test_atkbd_ext.sh; a regression that, say, accidentally
#     drained the kbd FIFO before atkbd's self-test would surface as
#     a missing atkbd PASS banner here.
#   - No kernel panic / TRAP between PCI scan and the user-mode
#     ready banner.
#
# Pass marker:    [usb_hid] PASS
# Fail marker:    [usb_hid] FAIL

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_usb_hid

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

ELF=build/hamnix-kernel.elf

echo "[test_usb_hid] (1/3) Build userland (init.elf must exist for cpio)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_usb_hid] (2/3) Build default initramfs"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_usb_hid] (3/3) Rebuild kernel + boot QEMU with qemu-xhci + usb-kbd"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

# `-device qemu-xhci` instantiates a generic xHCI host controller on
# the PCI bus; `-device usb-kbd` plugs a HID-class boot keyboard into
# the first available xHCI port. The combination is what the V0
# driver is built to handle.
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
    -device usb-mouse \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_usb_hid] --- captured USB-relevant boot output ---"
grep -E "xhci|usb_hid|usb_hid_mouse|atkbd:|hid:" "$LOG" || true
echo "[test_usb_hid] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero USB/xHCI markers == the guest never reached USB init: a starved/
# timed-out TCG boot (this gate's timeout is a tight 15s), an OBSERVED crash
# (verdict_boot_gate FAILs on TRAP/panic), or GRUB OOM — NOT a HID regression.
# rc=124 (timeout) is the EXPECTED normal exit here (kernel HLTs after init),
# so a boot that DID emit markers still passes the gate below.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[xhci\]|\[usb_hid|atkbd:'

fail=0

# --- xHCI controller-detect assertion --------------------------------
# The bdf value will vary depending on PCI bus topology, but the
# "controller found" line is invariant. We don't fuzz-match on the
# exact bdf because qemu-xhci's slot assignment depends on the order
# of `-device` flags + the i440FX chipset's slot allocator.
if grep -F -q "[xhci] controller found" "$LOG"; then
    echo "[test_usb_hid] OK: xHCI controller detected via PCI"
else
    echo "[test_usb_hid] MISS: xHCI controller-found banner absent"
    fail=1
fi

# --- BAR0 + capability decode ----------------------------------------
# CAPLENGTH must decode to non-zero (a healthy QEMU xHCI lands at 64
# = 0x40 op-base offset). max_ports must be > 0 (qemu-xhci default
# is 8: 4 USB2 + 4 USB3 lanes).
if grep -E -q "\[xhci\] max_slots=[0-9]+ max_ports=[0-9]+" "$LOG"; then
    echo "[test_usb_hid] OK: HCSPARAMS1 decoded"
else
    echo "[test_usb_hid] MISS: HCSPARAMS1 decode banner absent"
    fail=1
fi

# --- Controller reset --------------------------------------------------
if grep -F -q "[xhci] controller reset complete" "$LOG"; then
    echo "[test_usb_hid] OK: HCRST cycle complete (CNR cleared)"
else
    echo "[test_usb_hid] MISS: xHCI reset banner absent"
    fail=1
fi

# --- Root-hub keyboard discovery ---------------------------------------
# This is THE load-bearing V0 marker: if the BAR mapping is wrong or
# the PORTSC offset/stride decode is broken, we'll never see this
# line even when usb-kbd is present.
if grep -E -q "\[xhci\] root hub: keyboard at port [0-9]+" "$LOG"; then
    echo "[test_usb_hid] OK: root-hub keyboard candidate discovered"
else
    echo "[test_usb_hid] MISS: no keyboard candidate on the root hub"
    fail=1
fi

# --- HID translator self-test ----------------------------------------
# The "17 cases" matches the count of _hid_expect calls (plus the
# diff-suppression -1 check) in hid_self_test. Bump together with
# the driver if you add cases.
if grep -F -q "[usb_hid] self-test PASS (17 cases)" "$LOG"; then
    echo "[test_usb_hid] OK: HID boot-report translator self-test PASS"
else
    echo "[test_usb_hid] MISS: HID self-test PASS banner absent"
    fail=1
fi

# --- HID MOUSE translator self-test ----------------------------------
# The boot-protocol mouse driver (hid_mouse_report) runs a synthetic
# report battery at boot, packing each into the devmouse FIFO and
# popping it back to assert the encoding. 15 assertions as of #416:
# 7 cursor cases + dz==0 round-trips on the 3-byte (no-wheel) reports,
# plus 4-byte wheel-up / wheel-down round-trips and a length-guard case
# proving a stale byte3 in a 3-byte report injects no phantom scroll.
if grep -F -q "[usb_hid_mouse] self-test PASS (15 cases)" "$LOG"; then
    echo "[test_usb_hid] OK: HID boot-MOUSE translator self-test PASS"
else
    echo "[test_usb_hid] MISS: HID mouse self-test PASS banner absent"
    fail=1
fi

# --- Negative checks --------------------------------------------------
# Whatever order the markers appeared in, the HID self-test must NOT
# have reported a failure line.
if grep -F -q "[usb_hid] self-test FAIL" "$LOG"; then
    echo "[test_usb_hid] MISS: HID self-test FAIL line present"
    fail=1
fi
if grep -F -q "[usb_hid_mouse] self-test FAIL" "$LOG"; then
    echo "[test_usb_hid] MISS: HID mouse self-test FAIL line present"
    fail=1
fi

# Regression invariant: atkbd's PS/2 self-test still passes. A
# refactor that accidentally drains the kbd FIFO during xhci_init
# (e.g. running hid_self_test BEFORE atkbd_self_test) would surface
# as a missing atkbd PASS banner.
if grep -F -q "atkbd: self-test PASS (25 cases)" "$LOG"; then
    echo "[test_usb_hid] OK: atkbd PS/2 self-test still PASS (no regression)"
else
    echo "[test_usb_hid] MISS: atkbd PS/2 self-test regressed"
    fail=1
fi

# A kernel panic / unexpected TRAP between init phases would prevent
# the kernel from reaching xhci_init at all, but also catches the
# case where xhci_init itself triple-faults on a bad MMIO read.
if grep -E -q "PANIC|TRAP: vector" "$LOG"; then
    echo "[test_usb_hid] MISS: kernel panic / unexpected trap in boot log"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "USB/xHCI markers were observed (the guest booted) but a required" \
        "self-test marker was OBSERVED absent or a FAIL/TRAP was printed" \
        "(qemu rc=$rc) — a real xHCI/HID/atkbd regression."
fi

# rc=124 is timeout, which is the expected "kernel HLT'd after init"
# outcome — we never reach a clean qemu shutdown because the kernel
# doesn't power off after running through start_kernel. Any OTHER
# non-zero rc with markers present is an OBSERVED abnormal exit.
if [ "$rc" -ne 124 ] && [ "$rc" -ne 0 ]; then
    verdict_fail "$TAG" \
        "the guest booted and produced USB markers but qemu exited rc=$rc" \
        "(neither 0 nor the expected 124 HLT-timeout) — an OBSERVED abnormal exit."
fi

verdict_pass "$TAG" "xHCI controller detect + HCSPARAMS decode + reset +" \
    "root-hub keyboard discovery, HID keyboard (17) and mouse (15) translator" \
    "self-tests, and the atkbd PS/2 self-test (25) all PASS (qemu rc=$rc)"
