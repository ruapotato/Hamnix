#!/usr/bin/env bash
# scripts/test_atkbd_no_keystroke_loss.sh — regression guard for the
# "some keys delayed / some keys lost" DE keyboard bug.
#
# Two distinct structural invariants, both of which silently regress to
# dropped/delayed keystrokes if broken, and neither of which a runtime
# self-test can exercise (they live in the i8042 hardware read path):
#
# INVARIANT A — SINGLE STATUS READ per drained byte (atkbd_poll +
#   atkbd_irq_handler). The i8042 status register's OBF (bit 0) and AUX
#   (bit 5) bits BOTH describe the one byte latched in the output buffer
#   (port 0x60). They must be sampled from ONE status read that also gates
#   the data read. The buggy shape read 0x64 twice — once in the
#   while-condition, once for the AUX `st` — so on a busy controller the
#   AUX bit could belong to the NEXT byte and a real key got mis-classified
#   or dropped. The guard asserts neither drain loop has a
#   `while (inb(KBD_STATUS_PORT) ...` header AND a separate
#   `st = inb(KBD_STATUS_PORT)` inside (the two-read pattern); the fixed
#   shape samples `st` once before the loop and re-samples at the loop tail.
#
# INVARIANT B — the AUX (mouse) IRQ handler must ROUTE, not DROP, any
#   keyboard byte it finds in the shared output buffer. The i8042 has ONE
#   byte-wide output buffer shared by both ports; when IRQ 12 (mouse)
#   services and a keyboard scancode is sitting in OBF, the handler's `inb`
#   ALREADY consumes it, so discarding it loses a real keystroke (worst
#   during a mouse drag, when IRQ 12 fires fast). The fixed handler feeds
#   that byte to atkbd_process_byte(). The guard asserts the AUX-clear arm
#   of auxmouse_irq_handler calls atkbd_process_byte.
#
# Fast, deterministic, grep-only (NO QEMU boot).
#
# Pass marker:  PASS: atkbd no-keystroke-loss invariants intact
# Fail marker:  FAIL: <which invariant broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ATKBD_SRC="drivers/input/atkbd.ad"
AUX_SRC="drivers/input/auxmouse.ad"

for f in "$ATKBD_SRC" "$AUX_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

fail=0
fail_inv() {
    echo "FAIL: $1" >&2
    fail=1
}

# Extract a function body: from `def <name>(` to the next top-level `def`.
fn_body() {
    awk -v name="$1" '
        $0 ~ "^def[[:space:]]+" name "[[:space:]]*\\(" { inside=1; print; next }
        /^def[[:space:]]/ { if (inside) inside=0 }
        inside { print }
    ' "$2"
}

# --- INVARIANT A: single status read in the canonical keyboard drain ----
# BUG 3 (refactor): the port read + decode now lives in the SINGLE serialized
# _atkbd_drain(); atkbd_poll() and atkbd_irq_handler() both route through it.
# Invariant A (single-status-read) is asserted on that one drain body.
drain_body=$(fn_body _atkbd_drain "$ATKBD_SRC")
if [ -z "$drain_body" ]; then
    fail_inv "invariant A: _atkbd_drain() not found in $ATKBD_SRC"
else
    # The BUGGY two-read shape is a `while (inb(KBD_STATUS_PORT)` loop header.
    if grep -qE 'while[[:space:]]*\(inb\(KBD_STATUS_PORT\)' <<<"$drain_body"; then
        fail_inv "invariant A (_atkbd_drain): loop still re-reads inb(KBD_STATUS_PORT) in its while-header (two-read race)"
    fi
    # Positive: the loop must gate on a cached status snapshot named st.
    if ! grep -qE 'while[[:space:]]*\(st[[:space:]]*&[[:space:]]*KBD_STATUS_OBF' <<<"$drain_body"; then
        fail_inv "invariant A (_atkbd_drain): loop does not gate on a cached status snapshot (st & KBD_STATUS_OBF)"
    fi
    # Still classifies AUX (0x20) and still routes KBD bytes.
    if ! grep -qE '&[[:space:]]*0x20' <<<"$drain_body"; then
        fail_inv "invariant A (_atkbd_drain): lost the AUX-bit (0x20) classification"
    fi
    if ! grep -qE 'atkbd_process_byte' <<<"$drain_body"; then
        fail_inv "invariant A (_atkbd_drain): no longer routes keyboard bytes to atkbd_process_byte"
    fi
    # BUG 3 SERIALIZATION invariant: the drain must mask local IRQs AND take
    # the re-entrancy guard so the IRQ-1 / timer-poll / stray-AUX producers
    # cannot interleave the port read + shared decode state.
    if ! grep -qE 'local_irq_save' <<<"$drain_body"; then
        fail_inv "invariant A (_atkbd_drain): drain no longer masks local IRQs (producers can race the port read)"
    fi
    if ! grep -qE 'atkbd_draining' <<<"$drain_body"; then
        fail_inv "invariant A (_atkbd_drain): lost the atkbd_draining re-entrancy guard"
    fi
fi

# Both entry points must route through the single serialized drain (not read
# the port themselves — that would reintroduce the race).
for fn in atkbd_poll atkbd_irq_handler; do
    body=$(fn_body "$fn" "$ATKBD_SRC")
    if [ -z "$body" ]; then
        fail_inv "invariant A: $fn() not found in $ATKBD_SRC"
        continue
    fi
    if ! grep -qE '_atkbd_drain' <<<"$body"; then
        fail_inv "invariant A ($fn): does not route through the serialized _atkbd_drain()"
    fi
done

# --- INVARIANT B: AUX IRQ routes (not drops) keyboard bytes -------------
aux_body=$(fn_body auxmouse_irq_handler "$AUX_SRC")
if [ -z "$aux_body" ]; then
    fail_inv "invariant B: auxmouse_irq_handler() not found in $AUX_SRC"
else
    # The fixed handler feeds the stray keyboard byte to the keyboard state
    # machine instead of discarding it.
    if ! grep -qE 'atkbd_process_byte' <<<"$aux_body"; then
        fail_inv "invariant B: auxmouse_irq_handler drops the keyboard byte instead of routing it to atkbd_process_byte (lost keystroke during mouse activity)"
    fi
fi

if [ "$fail" = "0" ]; then
    echo "PASS: atkbd no-keystroke-loss invariants intact"
    exit 0
fi
echo "FAIL: atkbd no-keystroke-loss invariants regressed" >&2
exit 1
