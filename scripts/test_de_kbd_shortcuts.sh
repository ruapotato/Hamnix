#!/usr/bin/env bash
# scripts/test_de_kbd_shortcuts.sh — exercise the MATE-class keyboard
# shortcuts the DE picked up (Alt-Tab / Ctrl-Alt-T / Alt-F4 / Super /
# Super+D). The atkbd driver has no modifier encoding, so the chords
# ride dedicated CSI codes (45..49) injected through the new
# `/dev/wsys/ctl kbd <N>` verb — the keyboard analogue of driving the
# cursor via /dev/mouse. The compositor's key_process_chunk decodes the CSI and
# fires the bound action, emitting a "[de_kbd] <name>=1" boot-log line
# that this harness greps for.
#
# Always runs the STRUCTURAL guards (source greps). Falls back to a
# structural-only PASS when QEMU/KVM/the kernel ELF aren't available.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF="${ELF:-build/hamnix-kernel.elf}"
BOOT_WAIT="${BOOT_WAIT:-120}"
OUT_REPORT="${OUT_REPORT:-build/de_kbd_shortcuts.txt}"

# --- structural pre-check (always runs) ---------------------------------
DEVWSYS=sys/src/9/port/devwsys.ad
HAMUID=user/hamUId.ad
struct_fail=0

for marker in \
    'wsys_ctl_word_eq(buf, vs, ve, "kbd")' \
    'kbd: missing csi param' \
    '_wsys_cmd_push_wid(cast[int32](1)' ; do
    if ! grep -aFq "$marker" "$DEVWSYS"; then
        echo "[test_de_kbd_shortcuts] FAIL: devwsys marker missing: $marker" >&2
        struct_fail=1
    fi
done

for marker in \
    'KEY_CSI_PARAM == 45' \
    'KEY_CSI_PARAM == 46' \
    'KEY_CSI_PARAM == 47' \
    'KEY_CSI_PARAM == 48' \
    'KEY_CSI_PARAM == 49' \
    'KEY_CSI_PARAM == 51' \
    '[de_kbd] alt_tab=1' \
    '[de_kbd] ctrl_alt_t=1' \
    '[de_kbd] alt_f4=1' \
    '[de_kbd] super=1' \
    '[de_kbd] super_d=1' \
    '[de_kbd] prtsc=1' \
    'cycle_step(1)' \
    'daemon_spawn_terminal(cat_x' \
    'daemon_close_slot(kc4)' \
    'appmenu_spawn(scr_w, scr_h)' \
    'show_desktop_toggle()' \
    'daemon_spawn_screenshot()' ; do
    if ! grep -aFq "$marker" "$HAMUID"; then
        echo "[test_de_kbd_shortcuts] FAIL: hamUId marker missing: $marker" >&2
        struct_fail=1
    fi
done

# Every advertised chord must have a non-empty action label (the
# Control Center "Keyboard" pane scans the registry).
for chord in 'Alt+Tab' 'Ctrl+Alt+T' 'Alt+F4' 'Super+D' 'Print Screen' ; do
    if ! grep -aFq "\"$chord\"" "$HAMUID"; then
        echo "[test_de_kbd_shortcuts] FAIL: chord registry missing: $chord" >&2
        struct_fail=1
    fi
done

# The Print Screen key (#266): the atkbd driver maps the PrtSc extended
# scancode (E0 37) to the dedicated CSI 51 (ESC [ 5 1 ~) that the compositor
# turns into a /bin/hamshot capture.
ATKBD=drivers/input/atkbd.ad
if ! grep -aFq "scancode == 0x37" "$ATKBD"; then
    echo "[test_de_kbd_shortcuts] FAIL: atkbd PrtSc (0x37) mapping missing" >&2
    struct_fail=1
fi

if [ "$struct_fail" -ne 0 ]; then
    exit 1
fi
echo "[test_de_kbd_shortcuts] structural markers OK (kbd ctl verb + CSI 45-49 wired)."

# --- gates --------------------------------------------------------------
mkdir -p "$(dirname "$OUT_REPORT")"

if [ ! -f "$ELF" ]; then
    echo "[test_de_kbd_shortcuts] SKIP-RUNTIME: $ELF absent (structural PASS)."
    {
        echo "test_de_kbd_shortcuts"
        echo "status=structural_only"
        echo "reason=kernel_elf_absent"
    } > "$OUT_REPORT"
    exit 0
fi
# Stale-artifact guard: a PRESENT-but-OLD kernel ELF is booted silently otherwise,
# which is exactly the 2026-07-24 false-negative class. See _installer_img.sh.
# shellcheck source=_installer_img.sh
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
installer_img_warn_if_stale "$ELF" "[de_kbd_shortcuts]"

# Multiboot/VBE host limit probe (same shape as test_de_cursor_nudge).
if ! timeout 5 qemu-system-x86_64 -kernel "$ELF" -smp 1 -vga none -display none \
        -no-reboot -m 256M -monitor none -serial stdio < /dev/null \
        > /tmp/.kbd_probe.$$ 2>&1; then
    :
fi
if grep -q "multiboot knows VBE" /tmp/.kbd_probe.$$ 2>/dev/null; then
    rm -f /tmp/.kbd_probe.$$
    echo "[test_de_kbd_shortcuts] SKIP-RUNTIME: host QEMU rejects -kernel 64-bit ELF (multiboot/VBE limit); structural PASS recorded."
    {
        echo "test_de_kbd_shortcuts"
        echo "status=structural_only"
        echo "reason=qemu_multiboot_vbe_limit"
    } > "$OUT_REPORT"
    exit 0
fi
rm -f /tmp/.kbd_probe.$$

LOG=$(mktemp --tmpdir hamnix-de-kbd.XXXXXX.log)
FIFO=$(mktemp -u --tmpdir hamnix-de-kbd.XXXXXX).in
mkfifo "$FIFO"
QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$FIFO"
    [ -n "${KEEP_LOG:-}" ] || rm -f "$LOG"
}
trap cleanup EXIT
exec 4<>"$FIFO"
exec 3>"$FIFO"

KVM_FLAGS=""
if [ -e /dev/kvm ]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

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

echo "[test_de_kbd_shortcuts] waiting up to ${BOOT_WAIT}s for hamsh prompt..."
if ! wait_for 'hamsh\$' "$BOOT_WAIT"; then
    echo "[test_de_kbd_shortcuts] FAIL: hamsh prompt not seen in ${BOOT_WAIT}s" >&2
    tail -40 "$LOG" >&2
    exit 1
fi

printf 'echo MARK_KBD_READY\n' >&3
sleep 0.5
if ! wait_for 'MARK_KBD_READY' 10; then
    printf 'echo MARK_KBD_READY\n' >&3
    sleep 1
fi

# Inject each shortcut. Spaced so the compositor's key drain cycle has
# time to consume the previous CSI before the next one queues.
for code in 48 46 45 49 49 47 51 ; do
    printf 'echo kbd %d > /dev/wsys/ctl\n' "$code" >&3
    sleep 0.4
done
sleep 1

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 4; kill -9 "$QEMU_PID" 2>/dev/null ) &
WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

fail=0
seen=""
for tag in alt_tab ctrl_alt_t alt_f4 super super_d prtsc ; do
    if grep -aqE "^\[de_kbd\] ${tag}=1" "$LOG"; then
        seen="$seen $tag"
    else
        echo "[test_de_kbd_shortcuts] MISS marker [de_kbd] ${tag}=1" >&2
        fail=1
    fi
done

{
    echo "test_de_kbd_shortcuts"
    echo "status=runtime"
    echo "seen=$seen"
} > "$OUT_REPORT"

if [ "$fail" -ne 0 ]; then
    echo "[test_de_kbd_shortcuts] FAIL: one or more shortcut markers missing" >&2
    tail -80 "$LOG" >&2
    exit 1
fi

echo "[test_de_kbd_shortcuts] PASS: routed shortcuts:$seen"
