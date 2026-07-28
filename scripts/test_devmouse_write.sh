#!/usr/bin/env bash
# scripts/test_devmouse_write.sh — writable /dev/mouse: synthetic-event
# injection (the Plan 9 writable-/dev/mouse capability + Linux /dev/uinput
# in one).
#
# devmouse_write() in sys/src/9/port/devmouse.ad used to be a stub that
# rejected every writer (return -1). This fixture proves the real
# implementation: a write to /dev/mouse parses an ASCII event line in the
# SAME format devmouse_read emits — "<dx> <dy> <buttons>\n" — packs the
# fields into the int32 ring encoding, and pushes it onto the auxmouse ring
# (drivers/input/auxmouse.ad::mouse_rx_push) so a SUBSEQUENT devmouse_read
# pops it back out. /dev/mouse becomes a loopback injection channel.
#
# Mechanism (pure boot self-test, no userland interaction):
#   1. scripts/build_initramfs.py honours ENABLE_DEVMOUSE_WRITE_TEST=1: it
#      plants /etc/devmouse-write-test (the gate marker).
#   2. init/main.ad at boot:37.dmw detects the marker and runs
#      devmouse_write_selftest() (sys/src/9/port/devmouse.ad): it injects
#      "5 -3 1\n" via devmouse_write, reads it back via devmouse_read,
#      decodes the ASCII line, and asserts dx==5, dy==-3, buttons==1, plus
#      a malformed-input reject path (a non-numeric line must return -1).
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit
#      ELF in a BIOS GRUB ISO automatically — a raw `qemu -kernel` of the
#      higher-half ELF always fails on this host) and grep the serial log
#      for `[DEVMOUSE_WRITE] PASS`.
#
# Default boots ship NO /etc/devmouse-write-test file, so the self-test is
# a no-op skip everywhere else.
#
# Pass marker:  [test_devmouse_write] PASS
# Fail marker:  [test_devmouse_write] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_devmouse_write

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${DEVMOUSE_WRITE_BOOT_TIMEOUT:-120}"

echo "[test_devmouse_write] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_devmouse_write] (2/3) Build kernel with /etc/devmouse-write-test marker"
INIT_ELF=build/user/init.elf ENABLE_DEVMOUSE_WRITE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_devmouse_write] (3/3) Boot QEMU and run the devmouse-write self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_devmouse_write] --- devmouse-write self-test output ---"
grep -a -E "\[DEVMOUSE_WRITE\]|\[MOUSE_PUMP\]|\[MOUSE_FLUSH\]|\[boot:37.dmw\]" "$LOG" || true
echo "[test_devmouse_write] --- end ---"

# --- three-valued verdict (migrated off the hard MISS->FAIL tail) -----
# A zero-marker / rc=124 boot on a TCG-starved host used to look identical
# to a real regression. verdict_boot_gate resolves zero-marker+timeout to
# INCONCLUSIVE; observed FAILs are real reds; the PASS banners are genuine
# kernel-selftest OUTPUT (this gate feeds NO serial input).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[DEVMOUSE_WRITE\]|\[MOUSE_PUMP\]|\[boot:37.dmw\]'

# --- observed internal failures are real reds ---
if grep -a -qF "[DEVMOUSE_WRITE] FAIL" "$LOG"; then
    grep -a -F "[DEVMOUSE_WRITE] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the devmouse-write self-test reported an internal FAIL (observed regression)."
fi
if grep -a -qF "[MOUSE_PUMP] FAIL" "$LOG"; then
    grep -a -F "[MOUSE_PUMP] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the mouse-pump (live cursor path) self-test reported a FAIL (observed regression)."
fi
# STARTUP-TELEPORT guard: the first live pump tick after the rl5 handoff must
# DISCARD the pre-flip ring backlog (else the centred cursor teleports, then
# settles — the long-standing user-reported bug). A FAIL here means the flush
# regressed and the boot-time cursor jump is back.
if grep -a -qF "[MOUSE_FLUSH] FAIL" "$LOG"; then
    grep -a -F "[MOUSE_FLUSH] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the startup-teleport flush self-test reported a FAIL (boot cursor-jump regression)."
fi
if grep -a -qF "[FOCUS_OUT] FAIL" "$LOG"; then
    grep -a -F "[FOCUS_OUT] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the scene-DE focus-out self-test reported a FAIL (Bug 2a regression)."
fi
# The scene-DE input block ran but never emitted its FOCUS_OUT PASS — an
# OBSERVED regression, not starvation (the block reached boot:37.dein).
if grep -a -qF "[boot:37.dein]" "$LOG" && ! grep -a -qF "[FOCUS_OUT] PASS" "$LOG"; then
    verdict_fail "$TAG" "the scene-DE input block ran but '[FOCUS_OUT] PASS' is absent — Bug 2a focus-out delivery regressed."
fi

# --- both required PASS banners observed => real green ---
if grep -a -qF "[DEVMOUSE_WRITE] PASS" "$LOG" && grep -a -qF "[MOUSE_PUMP] PASS" "$LOG"; then
    verdict_pass "$TAG" "writable /dev/mouse injects synthetic events through the auxmouse ring + the HW mouse-ring pump drains to the compositor (+ scene-DE focus-out) (qemu rc=$rc)."
fi

# Markers seen (guest booted) but a required PASS banner is missing.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the selftest emitted markers but a required PASS banner never printed" \
        "and qemu was killed by timeout (rc=124) — starved mid-selftest. Re-run quiet."
fi
verdict_fail "$TAG" \
    "the selftest started and qemu exited on its own (rc=$rc) WITHOUT both" \
    "[DEVMOUSE_WRITE] PASS and [MOUSE_PUMP] PASS — an OBSERVED incomplete run."
