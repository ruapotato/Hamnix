#!/usr/bin/env bash
# scripts/test_de_wctl_truth.sh — /dev/wsys/<N>/wctl MUST NOT LIE.
#
# THE BUG. wctl kept a PRIVATE per-window request store (wsys_wctl_x/y/w/h)
# that the compositor never read and never wrote. A read rendered that store,
# so EVERY live window reported "0 0 0 0 click" no matter its real geometry;
# `wctl resize` and `wctl move` wrote to it and changed nothing on screen; and
# the /dev/wsys/session snapshot recorded 0 0 0 0 for every window, so a saved
# session could not restore one. A previous agent had to route around wctl and
# use the per-window /ctl instead. A surface that silently lies is worse than
# one that errors.
#
# WHAT THIS GATE PINS (in-kernel self-test wsys_wctl_truth_selftest, booted
# under QEMU so it is the real device path, not a source grep):
#   (a) the status line reports the LIVE composited rect (origin + content
#       size), not a request store;
#   (b) resize/move either APPLY to that live rect — verified by reading the
#       geometry back — or are REFUSED with an error and change NOTHING.
#       Accepted-and-ignored, the old behaviour, fails either way.
#
# HONEST LIMIT of this gate: the in-kernel battery runs as pid 0, which owns
# no window and is not the hostowner, so on this path the write is legitimately
# refused and it is the refusal branch that gets exercised end to end (refused
# => geometry untouched => status line unchanged). The APPLY branch's wiring —
# that resize/move reach _wsys_apply_geometry, the same sink the ctl `geometry`
# verb uses, rather than a private store — is pinned statically by
# scripts/test_de_snarf_wctl.sh.
#
# Marker: [WCTL_TRUTH] PASS / FAIL. Zero markers = INCONCLUSIVE = FAIL (the
# battery never ran), never a silent pass.

. "$(dirname "$0")/_build_lock.sh"
# _kernel_iso.sh installs build/binshim/qemu-system-x86_64, which turns a
# `-kernel <elf64>` invocation into a BIOS GRUB `-cdrom <iso>` boot (QEMU's
# built-in -kernel multiboot1 loader rejects 64-bit ELFs / "knows VBE").
. "$(dirname "$0")/_kernel_iso.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_de_wctl_truth] (1/3) Build userland (default init)"
bash scripts/build_user.sh >/dev/null

echo "[test_de_wctl_truth] (2/3) Build kernel with the self-test battery armed"
INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_de_wctl_truth] (3/3) Boot QEMU and run the wctl-truthfulness self-test"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 180s qemu-system-x86_64 \
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

echo "[test_de_wctl_truth] --- self-test output ---"
grep -aE "\[WCTL_TRUTH\]" "$LOG" || true
echo "[test_de_wctl_truth] --- end ---"

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_de_wctl_truth] FAIL: qemu exited rc=$rc" >&2
    exit 1
fi

# The self-test must have RUN. Zero markers means the boot never reached
# boot:37 (or the battery is disarmed) — that is INCONCLUSIVE, not a pass.
if ! grep -aqF "[WCTL_TRUTH]" "$LOG"; then
    echo "[test_de_wctl_truth] FAIL: no [WCTL_TRUTH] marker — the self-test never ran" >&2
    echo "[test_de_wctl_truth]   (boot:37 battery disarmed, or the boot did not get that far)" >&2
    exit 1
fi

if grep -aqF "[WCTL_TRUTH] FAIL" "$LOG"; then
    echo "[test_de_wctl_truth] FAIL: wctl reported a rect it does not have, or accepted a resize/move it did not apply" >&2
    grep -aF "[WCTL_TRUTH]" "$LOG" >&2
    exit 1
fi

if ! grep -aqF "[WCTL_TRUTH] PASS" "$LOG"; then
    echo "[test_de_wctl_truth] FAIL: no PASS verdict" >&2
    exit 1
fi

echo "[test_de_wctl_truth] PASS"
