#!/usr/bin/env bash
# scripts/test_iso_cdrom_commands.sh — boot build/hamnix.iso as a
# CD-ROM ONLY (no rootfs partition attached) and prove the live shell
# has a working native toolset.
#
# WHY THIS EXISTS (regression guard for the 4c8c10b lean-cpio bug):
#   GNOME Boxes (and a real-HW USB/CD boot) presents the ISO over
#   ATAPI/USB. Hamnix's block layer cannot read the appended ext4
#   rootfs partition off that medium, so EVERYTHING the live shell
#   needs must come from the cpio baked into the kernel ELF. Commit
#   4c8c10b forced HAMNIX_CPIO_LEAN=1 in build_iso.sh, which stripped
#   the ~110 native Adder tools onto that unreadable partition — so a
#   GNOME Boxes boot had ZERO commands ("command not found" for ls,
#   cat, everything). build_initramfs.py now keeps the full native
#   toolset in the cpio regardless of lean (only the heavy busybox +
#   Debian apt/dpkg closure is lean-stripped). This test locks that in.
#
#   The pre-existing test_iso_shell.sh ALWAYS attaches the rootfs
#   partition as a virtio disk, so it exercises the disk-boot path and
#   never caught the CD-only regression. test_iso_qemu.sh only checks
#   boot banners, not whether a command resolves. This test closes both
#   gaps: cdrom-only, asserts commands actually run.
#
# Env overrides:
#   HAMNIX_ISO         iso path                 (default: build/hamnix.iso)
#   SHELL_BOOT_WAIT    seconds to wait for the  (default: 60)
#                      interactive-prompt marker
#   HAMNIX_SKIP_BUILD  1 = reuse existing ISO   (default: rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
SHELL_BOOT_WAIT="${SHELL_BOOT_WAIT:-60}"
# rc.boot.full's final line before the REPL. The cpio copy of
# rc.boot.full prints this too (it is the same source file), so it
# marks "interactive shell reached" on the CD-only path as well.
PROMPT_MARKER="handing off to interactive shell"

if [ ! -e /dev/kvm ]; then
    echo "[test_iso_cdrom] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_iso_cdrom] rebuilding userland + ISO"
    rm -f "$HAMNIX_ISO"
    bash "$PROJ_ROOT/scripts/build_iso.sh"
fi
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_iso_cdrom] FAIL: $HAMNIX_ISO missing after build_iso.sh." >&2
    exit 1
fi
# Stale-artifact guard: HAMNIX_SKIP_BUILD=1 reuses whatever ISO/rootfs is
# already on disk. Say so LOUDLY when it predates the tree under test.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
installer_img_warn_if_stale "$HAMNIX_ISO" "[iso_cdrom_commands]"

LOG=$(mktemp --tmpdir hamnix-iso-cdrom.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-iso-cdrom-in.XXXXXX)
mkfifo "$INFIFO"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$INFIFO"
}
trap cleanup EXIT

exec 4<>"$INFIFO"
exec 3>"$INFIFO"

# -cdrom ONLY: no -drive for the rootfs partition. This is exactly the
# medium GNOME Boxes presents by default, and the partition is
# deliberately absent so the toolset can ONLY come from the cpio.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -cdrom "$HAMNIX_ISO" \
    -m 512M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[test_iso_cdrom] waiting up to ${SHELL_BOOT_WAIT}s for prompt marker..."
booted=0
for _ in $(seq 1 "$SHELL_BOOT_WAIT"); do
    if grep -a -q "$PROMPT_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_iso_cdrom] FAIL: qemu exited before reaching the prompt." >&2
        echo "----- serial log tail -----" >&2
        tail -60 "$LOG" >&2
        exit 1
    fi
    sleep 1
done

if [ "$booted" -ne 1 ]; then
    echo "[test_iso_cdrom] FAIL: prompt marker '$PROMPT_MARKER' not seen in ${SHELL_BOOT_WAIT}s." >&2
    echo "----- serial log tail -----" >&2
    tail -60 "$LOG" >&2
    exit 1
fi
echo "[test_iso_cdrom] prompt reached; typing commands at the shell."

type_cmd() {
    printf '%s\n' "$1" >&3
    sleep 4
}

type_cmd "echo HAMNIX_CDROM_REPL_OK"   # proves echo + the REPL live
type_cmd "ls /bin"                     # native toolset must list from cpio
type_cmd "cat /version"                # a stripped-by-lean tool, run from cpio
type_cmd "echo HAMNIX_CDROM_DONE_99"

sleep 3
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&-
exec 4>&-

# --- assertions -----------------------------------------------------
fail=0

# 1. REPL alive.
if grep -a -q -E '^HAMNIX_CDROM_REPL_OK' "$LOG"; then
    echo "[test_iso_cdrom] PASS: echo marker round-tripped (REPL alive)."
else
    echo "[test_iso_cdrom] FAIL: echo marker not echoed back." >&2
    fail=1
fi

# 2. THE KEYSTONE: zero 'command not found'. This is the exact 4c8c10b
#    regression signature — with the toolset stripped to the unreadable
#    partition, every typed command faulted with 'command not found'.
if grep -a -q "command not found" "$LOG"; then
    echo "[test_iso_cdrom] FAIL: 'command not found' present — native toolset is NOT in the cpio (lean-cpio regression):" >&2
    grep -a "command not found" "$LOG" >&2
    fail=1
else
    echo "[test_iso_cdrom] PASS (KEYSTONE): zero 'command not found' on a cdrom-only boot."
fi

# 3. `ls /bin` actually listed native tools. Require several distinct
#    tool names to appear AFTER the prompt — a real listing, not noise.
hits=0
for tool in whoami xargs uname uptime wget which; do
    if grep -a -q -E "(^|[[:space:]])${tool}([[:space:]]|\$)" "$LOG"; then
        hits=$((hits + 1))
    fi
done
if [ "$hits" -ge 4 ]; then
    echo "[test_iso_cdrom] PASS: ls /bin listed the native toolset ($hits/6 probe tools present)."
else
    echo "[test_iso_cdrom] FAIL: ls /bin did not list the native toolset ($hits/6 probe tools) — tools missing from cpio." >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_iso_cdrom] PASS"
    rm -f "$LOG"
    exit 0
else
    echo "[test_iso_cdrom] FAIL (serial log: $LOG)" >&2
    exit 1
fi
