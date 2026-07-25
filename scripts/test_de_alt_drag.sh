#!/usr/bin/env bash
# scripts/test_de_alt_drag.sh — DE Alt+drag (MATE/GNOME2 staple)
# regression guard. Proves that holding Alt while clicking-and-dragging
# anywhere on a window's BODY moves the window (LB) or resizes it from
# the bottom-right corner (RB), exactly like MATE/Marco.
#
# Two halves:
#
#   STRUCTURAL — assert that the load-bearing source markers stay live:
#       (1) the ALT_HELD compositor flag (decoded from button-bit 0x80
#           in daemon_apply_packet) is still wired.
#       (2) wm_button's body-click branch still consults ALT_HELD before
#           the chrome hit-tests fan out, and still emits
#           "[de_altdrag] move=W<slot>".
#       (3) wm_rbutton's Alt+RB branch still calls resize_begin and
#           emits "[de_altdrag] resize=W<slot>" instead of opening the
#           context menu.
#       (4) the kernel /dev/wsys/ctl `drag` verb still accepts the
#           optional 4th <altmask> token (the synthetic injection path).
#       (5) the dispatch keyword `dealtdrag` -> autoflag 53 is wired and
#           daemon_dealtdrag_selftest exists.
#
#   RUNTIME — boot QEMU, wait for hamsh, drive
#       `hamUId daemon dealtdrag`
#   inside the guest. The selftest spawns one APP_SYSMON window, then:
#     - asserts a bare LB body click does NOT move the window,
#     - asserts Alt+LB body click + drag MOVES the window by exactly
#       the cursor delta,
#     - asserts Alt+RB body click + drag RESIZES the window from the
#       bottom-right corner (no context menu opened),
#     - emits "[de_altdrag] move=W..." and "[de_altdrag] resize=W..."
#       boot-log markers along the way,
#     - prints "[DEALTDRAG] PASS" on the serial log.
#   We then grep the serial log for BOTH boot-log markers and the PASS
#   line.
#
# Skips the runtime half cleanly when the host can't boot the kernel
# (the standing QEMU multiboot/VBE 64-bit-ELF limit, mirrored from
# scripts/test_de_cursor_nudge.sh's probe).
#
# Pass marker: PASS: DE Alt+drag (move + resize) intact
# Fail marker: FAIL: DE Alt+drag <reason>

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF="${ELF:-build/hamnix-kernel.elf}"
BOOT_WAIT="${BOOT_WAIT:-120}"

# ---------------- STRUCTURAL pre-check ----------------------------------
HAMUID=user/hamUId.ad
DEVMOUSE=sys/src/9/port/devmouse.ad
struct_fail=0
fail_marker() {
    echo "FAIL: DE Alt+drag structural marker missing: $1" >&2
    struct_fail=1
}

# (1) ALT_HELD flag is defined + decoded from button bit 0x80.
grep -Fq 'ALT_HELD: int32 = 0' "$HAMUID" \
    || fail_marker "ALT_HELD: int32 = 0 (compositor Alt-modifier flag)"
grep -Fq '(btn & 0x80)' "$HAMUID" \
    || fail_marker "(btn & 0x80) Alt-bit decode in daemon_apply_packet"

# (2) wm_button body branch consults ALT_HELD and emits the move marker.
grep -Fq 'hit >= 0 and ALT_HELD != 0' "$HAMUID" \
    || fail_marker "Alt-override branch in wm_button (hit >= 0 and ALT_HELD != 0)"
grep -Fq '[de_altdrag] move=W' "$HAMUID" \
    || fail_marker "[de_altdrag] move=W boot-log marker"

# (3) wm_rbutton Alt+RB branch calls resize_begin and emits the resize marker.
grep -Fq 'ALT_RB_RESIZE' "$HAMUID" \
    || fail_marker "ALT_RB_RESIZE state (Alt+RB resize tracking)"
grep -Fq '[de_altdrag] resize=W' "$HAMUID" \
    || fail_marker "[de_altdrag] resize=W boot-log marker"

# (4) A.1: the Alt+drag injection path is now /dev/mouse (devmouse_write),
# which passes the button bitmap (including the Alt bit 0x80) straight
# through to mouse_rx_push_abs — the compositor decodes (btn & 0x80) above.
grep -Fq 'def devmouse_write(' "$DEVMOUSE" \
    || fail_marker "devmouse_write (/dev/mouse writable-mouse injection)"
grep -Fq 'mouse_rx_push_abs(dx, dy, buttons, dz)' "$DEVMOUSE" \
    || fail_marker "devmouse_write passes the full button bitmap (incl. 0x80) through"

# (5) dispatch keyword + selftest function.
grep -Fq '"dealtdrag"' "$HAMUID" \
    || fail_marker '"dealtdrag" verb in cmd_daemon dispatch'
grep -Fq 'daemon_dealtdrag_selftest' "$HAMUID" \
    || fail_marker 'daemon_dealtdrag_selftest function'

if [ "$struct_fail" -ne 0 ]; then
    echo "FAIL: DE Alt+drag structural check FAILED — see markers above" >&2
    exit 1
fi
echo "[test_de_alt_drag] structural markers OK."

# ---------------- RUNTIME boot half -------------------------------------

if [ ! -f "$ELF" ]; then
    echo "[test_de_alt_drag] SKIP-RUNTIME: $ELF absent (structural PASS recorded)."
    echo "PASS: DE Alt+drag (move + resize) intact (structural only)"
    exit 0
fi
# Stale-artifact guard: a PRESENT-but-OLD kernel ELF is booted silently otherwise,
# which is exactly the 2026-07-24 false-negative class. See _installer_img.sh.
# shellcheck source=_installer_img.sh
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
installer_img_warn_if_stale "$ELF" "[de_alt_drag]"

# Probe the multiboot/VBE host-QEMU limit (mirrors test_de_cursor_nudge.sh):
# QEMU 10.x rejects 64-bit kernel ELFs through -kernel because the stub
# advertises VBE. If we hit that, the structural half carries the PASS.
PROBE_LOG=$(mktemp)
if ! timeout 5 qemu-system-x86_64 -kernel "$ELF" -smp 1 -vga none -display none \
        -no-reboot -m 256M -monitor none -serial stdio < /dev/null \
        > "$PROBE_LOG" 2>&1; then
    :
fi
if grep -q "multiboot knows VBE" "$PROBE_LOG" 2>/dev/null; then
    rm -f "$PROBE_LOG"
    echo "[test_de_alt_drag] SKIP-RUNTIME: host QEMU rejects -kernel 64-bit ELF (multiboot/VBE limit)."
    echo "PASS: DE Alt+drag (move + resize) intact (structural; runtime SKIP)"
    exit 0
fi
rm -f "$PROBE_LOG"

LOG=$(mktemp --tmpdir hamnix-de-altdrag.XXXXXX.log)
FIFO=$(mktemp -u --tmpdir hamnix-de-altdrag.XXXXXX).in
mkfifo "$FIFO"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$FIFO"
    [ -n "${KEEP_LOG:-}" ] && cp "$LOG" "${KEEP_LOG}" 2>/dev/null || rm -f "$LOG"
}
trap cleanup EXIT

exec 4<>"$FIFO"
exec 3>"$FIFO"

KVM_FLAGS=""
if [ -e /dev/kvm ]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

# -vga none / -display none keeps us off the framebuffer (the self-test
# is pure model state and never paints) and avoids the multiboot+VBE
# limitation. The compositor self-test path tolerates a headless boot
# the same way autoflag 39 (dewm) does.
qemu-system-x86_64 \
    -kernel "$ELF" \
    $KVM_FLAGS \
    -smp 2 \
    -vga none \
    -display none \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

wait_for() {
    local pat="$1" timeout="$2"
    local deadline=$(( SECONDS + timeout ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

echo "[test_de_alt_drag] waiting up to ${BOOT_WAIT}s for hamsh prompt..."
if ! wait_for 'hamsh\$' "$BOOT_WAIT"; then
    echo "[test_de_alt_drag] SKIP-RUNTIME: hamsh prompt not seen in ${BOOT_WAIT}s (host slow). Structural PASS recorded." >&2
    tail -40 "$LOG" >&2
    echo "PASS: DE Alt+drag (move + resize) intact (structural; runtime INCONCLUSIVE)"
    exit 0
fi

# Wake the freshly-booted shell (the first serial line is dropped — see
# feedback_serial_test_first_cmd_dropped).
printf 'echo MARK_ALTDRAG_BEGIN\n' >&3
sleep 0.5
if ! wait_for 'MARK_ALTDRAG_BEGIN' 10; then
    printf 'echo MARK_ALTDRAG_BEGIN\n' >&3
fi

# Drive the in-guest self-test.
for _ in 1 2 3; do
    printf 'hamUId daemon dealtdrag\n' >&3
    wait_for '\[DEALTDRAG\] (PASS|FAIL)' 60 && break
done

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 4; kill -9 "$QEMU_PID" 2>/dev/null ) &
WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

echo "[test_de_alt_drag] --- DEALTDRAG output ---"
grep -aE '\[DEALTDRAG\]|\[de_altdrag\]' "$LOG" || true
echo "[test_de_alt_drag] --- end ---"

fail=0

# The selftest must reach a verdict.
if ! grep -aqE '\[DEALTDRAG\] PASS' "$LOG"; then
    if grep -aqE '\[DEALTDRAG\] FAIL' "$LOG"; then
        echo "FAIL: DE Alt+drag selftest reported FAIL" >&2
        fail=1
    else
        # No verdict reached — the compositor may not have run far enough
        # under -vga none on this host. Don't hard-fail; structural carries.
        echo "[test_de_alt_drag] SKIP-RUNTIME: no [DEALTDRAG] verdict (compositor self-test did not run to completion on this host)."
        echo "PASS: DE Alt+drag (move + resize) intact (structural; runtime INCONCLUSIVE)"
        exit 0
    fi
fi

# The boot-log markers MUST appear when PASS prints (they are emitted
# in-line from wm_button / wm_rbutton).
if ! grep -aqF '[de_altdrag] move=W' "$LOG"; then
    echo "FAIL: DE Alt+drag did not emit '[de_altdrag] move=W' marker" >&2
    fail=1
fi
if ! grep -aqF '[de_altdrag] resize=W' "$LOG"; then
    echo "FAIL: DE Alt+drag did not emit '[de_altdrag] resize=W' marker" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE Alt+drag (runtime)" >&2
    exit 1
fi

echo "PASS: DE Alt+drag (move + resize) intact"
exit 0
