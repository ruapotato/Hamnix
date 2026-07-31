#!/usr/bin/env bash
# scripts/test_atkbd_poll_aux_filter.sh — structural regression guard for the
# "mouse drag injects random characters into hamedit" leak (DE input BUG 2).
#
# This is a fast, deterministic, grep-only guard (NO QEMU boot).
#
# ROOT CAUSE the guard locks in:
#   The PS/2 keyboard and mouse share the i8042 output buffer (port 0x60).
#   Status-port (0x64) bit 5 (0x20, AUX) tells whether a pending byte came
#   from the MOUSE (set) or the KEYBOARD (clear). On QEMU a mouse DRAG fills
#   the output buffer with AUX movement bytes. The IRQ-1 handler
#   (atkbd_irq_handler) already checks the AUX bit and DROPS mouse bytes —
#   but the timer-tick POLL path (atkbd_poll) did NOT: it drained 0x60 and
#   fed EVERY byte to atkbd_process_byte, translating mouse-motion bytes as
#   bogus scancodes -> ASCII -> the focused window's /keys stream. That is
#   the "mouse event leaking into keyboard events" the user saw while
#   dragging hamedit.
#
# The fix: atkbd_poll() must mirror atkbd_irq_handler()'s AUX check —
# read the status port, and when bit 5 (0x20) is set, consume the data
# byte WITHOUT routing it to atkbd_process_byte().
#
# Pass marker:  PASS: atkbd poll AUX filter intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ATKBD_SRC="drivers/input/atkbd.ad"

if [ ! -f "$ATKBD_SRC" ]; then
    echo "FAIL: $ATKBD_SRC missing" >&2
    exit 1
fi

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

# BUG 3 (refactor): the per-byte AUX filter now lives in the SINGLE serialized
# _atkbd_drain(), which atkbd_poll() and atkbd_irq_handler() both route through.
# Assert the filter on that drain body.
drain_body=$(awk '
    /^def[[:space:]]+_atkbd_drain[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$ATKBD_SRC")

if [ -z "$drain_body" ]; then
    fail_link "link 1: _atkbd_drain() not found in $ATKBD_SRC"
else
    # Link 1: the drain loop reads the STATUS port (0x64) so it can inspect the
    # AUX bit per byte (not just OBF once).
    if ! grep -qE 'inb\(KBD_STATUS_PORT\)' <<<"$drain_body"; then
        fail_link "link 1 (_atkbd_drain): does not read KBD_STATUS_PORT to inspect AUX bit"
    fi
    # Link 2: it tests the AUX bit (0x20) so mouse-sourced bytes are detected.
    if ! grep -qE '&[[:space:]]*0x20' <<<"$drain_body"; then
        fail_link "link 2 (_atkbd_drain): does not test the AUX bit (0x20) — mouse bytes will leak to /keys"
    fi
    # Link 3: it still routes KEYBOARD bytes to atkbd_process_byte (the else arm).
    if ! grep -qE 'atkbd_process_byte' <<<"$drain_body"; then
        fail_link "link 3 (_atkbd_drain): no longer routes keyboard bytes to atkbd_process_byte"
    fi
    # Link 4 (sanity): the AUX-set arm drains the data port WITHOUT processing.
    if ! grep -qE '^[[:space:]]+inb\(KBD_DATA_PORT\)' <<<"$drain_body"; then
        fail_link "link 4 (_atkbd_drain): AUX-set branch does not discard the data byte (drop mouse byte)"
    fi
fi

# Both entry points must route through the single serialized drain.
for fn in atkbd_poll atkbd_irq_handler; do
    body=$(awk -v name="$fn" '
        $0 ~ "^def[[:space:]]+" name "[[:space:]]*\\(" { inside=1; print; next }
        /^def[[:space:]]/ { if (inside) { inside=0 } }
        inside { print }
    ' "$ATKBD_SRC")
    if ! grep -qE '_atkbd_drain' <<<"$body"; then
        fail_link "$fn: does not route through the serialized _atkbd_drain()"
    fi
done

if [ "$fail" = "0" ]; then
    echo "PASS: atkbd poll AUX filter intact"
    exit 0
fi
echo "FAIL: atkbd poll AUX filter regressed" >&2
exit 1
