#!/usr/bin/env bash
# scripts/test_auxmouse_wheel_dz.sh — structural regression guard for the
# "mouse wheel does nothing" bug (DE input BUG 2).
#
# Fast, deterministic, grep-only (NO QEMU boot).
#
# ROOT CAUSE the guard locks in:
#   The PS/2 mouse driver only ever spoke the 3-byte protocol, so the wheel
#   delta (dz) was always 0 and the scroll wheel was dead. The fix negotiates
#   the Microsoft IntelliMouse protocol — the sample-rate "knock" 200, 100, 80
#   followed by GET_DEVID (0xF2); a 0x03 reply switches the device to 4-byte
#   packets whose 4th byte is the signed Z wheel delta. The decode state
#   machine must grow a 4th phase that reads that Z byte and thread it
#   through _mouse_ring_push -> the ring -> mouse_rx_pop_dz.
#
# Pass marker:  PASS: auxmouse wheel dz decode intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

AUX_SRC="drivers/input/auxmouse.ad"

if [ ! -f "$AUX_SRC" ]; then
    echo "FAIL: $AUX_SRC missing" >&2
    exit 1
fi

fail=0
fail_link() { echo "FAIL: $1" >&2; fail=1; }

fn_body() {
    awk -v name="$1" '
        $0 ~ "^def[[:space:]]+" name "[[:space:]]*\\(" { inside=1; print; next }
        /^def[[:space:]]/ { if (inside) inside=0 }
        inside { print }
    ' "$AUX_SRC"
}

# --- LINK 1: init issues the IntelliMouse sample-rate knock 200,100,80 ----
init_body=$(fn_body auxmouse_init)
if [ -z "$init_body" ]; then
    fail_link "link 1: auxmouse_init() not found"
else
    for rate in 200 100 80; do
        if ! grep -qE "_aux_send_expect_ack\(${rate}\)" <<<"$init_body"; then
            fail_link "link 1: auxmouse_init missing the sample-rate knock value ${rate} (IntelliMouse negotiation incomplete)"
        fi
    done
    # GET_DEVID must be issued and the 0x03 reply checked.
    if ! grep -qE 'MOUSE_CMD_GET_DEVID' <<<"$init_body"; then
        fail_link "link 1: auxmouse_init does not GET_DEVID after the knock"
    fi
    if ! grep -qE 'MOUSE_DEVID_INTELLI' <<<"$init_body"; then
        fail_link "link 1: auxmouse_init does not check for the 0x03 IntelliMouse device id"
    fi
    # On a 0x03 reply it must switch to 4-byte packets.
    if ! grep -qE 'mouse_pkt_len[[:space:]]*=[[:space:]]*4' <<<"$init_body"; then
        fail_link "link 1: auxmouse_init does not switch to 4-byte packets on IntelliMouse"
    fi
fi

# --- LINK 2: decode state machine handles a 4th (Z) byte -----------------
dec_body=$(fn_body auxmouse_process_byte)
if [ -z "$dec_body" ]; then
    fail_link "link 2: auxmouse_process_byte() not found"
else
    # A phase-3 (4th byte) branch must exist, gated on mouse_pkt_len >= 4.
    if ! grep -qE 'mouse_pkt_len[[:space:]]*>=[[:space:]]*4' <<<"$dec_body"; then
        fail_link "link 2: decoder does not branch on the negotiated 4-byte length (no wheel path)"
    fi
    if ! grep -qE 'mouse_phase[[:space:]]*=[[:space:]]*3' <<<"$dec_body"; then
        fail_link "link 2: decoder has no phase-3 (Z wheel byte) state"
    fi
fi

# --- LINK 3: the wheel delta is pushed into the ring's dz field ----------
# _mouse_ring_push must take + store a dz argument (not hard-zero it).
push_body=$(fn_body _mouse_ring_push)
if [ -z "$push_body" ]; then
    fail_link "link 3: _mouse_ring_push() not found"
else
    if ! grep -qE '\.dz[[:space:]]*=[[:space:]]*dz' <<<"$push_body"; then
        fail_link "link 3: _mouse_ring_push hard-zeros dz instead of storing the wheel delta"
    fi
fi

# --- LINK 4: the boot self-test covers wheel decode ----------------------
st_body=$(fn_body auxmouse_self_test)
if [ -z "$st_body" ]; then
    fail_link "link 4: auxmouse_self_test() not found"
else
    if ! grep -qE '_st_expect_dz' <<<"$st_body"; then
        fail_link "link 4: self-test has no wheel (dz) assertion case"
    fi
fi

if [ "$fail" = "0" ]; then
    echo "PASS: auxmouse wheel dz decode intact"
    exit 0
fi
echo "FAIL: auxmouse wheel dz decode regressed" >&2
exit 1
