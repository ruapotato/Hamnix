# scripts/_installed_boot.sh — SOURCEABLE helper: boot the INSTALLED Hamnix
# system (ext4-on-NVMe) the way the retired build/hamnix.img used to be
# booted, so feature tests keep their coverage after the baked image was
# retired.
#
# It boots a fresh COPY of the golden installed disk
# (build/hamnix-installed.qcow2, produced by scripts/build_installed_nvme.sh
# via the REAL installer path) under OVMF/KVM, reaching an interactive shell
# on the ext4-on-NVMe root. A sourcing test then drives commands over the
# serial console and asserts on the captured log — exactly the old
# build/hamnix.img model, just booting the installed disk instead.
#
# CONTRACT — a test sources this file, then calls:
#     source "$PROJ_ROOT/scripts/_installed_boot.sh"   # gates + builds golden + defines fns
#     installed_boot_start            # boots a fresh copy; sets QEMU_PID, INSTALLED_LOG
#     installed_boot_wait [secs]      # blocks until the shell prompt (default 200s); returns 1 on failure
#     installed_type "cmd" [settle]   # feed one line to the guest (default settle 4s)
#     installed_boot_stop             # kill qemu, close fds
#     # ... then grep "$INSTALLED_LOG" for your assertions ...
#
# This file SKIPS THE WHOLE TEST CLEANLY (echo + `exit 0` in the sourcing
# shell) when /dev/kvm, OVMF, mksquashfs, or the golden disk is unavailable —
# `exit` in a sourced script exits the caller, matching how every OVMF-boot
# test gates itself.
#
# Env overrides:
#   GOLDEN_NVME        golden disk path  (default: build/hamnix-installed.qcow2)
#   OVMF_FD            OVMF firmware     (auto-resolved)
#   INSTALLED_BOOT_MEM guest RAM         (default: 1024M)
#   SHELL_BOOT_WAIT    default prompt wait seconds (default: 200)
#   HAMNIX_SKIP_BUILD  1 = do not (re)build the golden disk; require it present

# Resolve the project root from THIS file's location (works regardless of the
# sourcing test's own PROJ_ROOT).
_IB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GOLDEN_NVME="${GOLDEN_NVME:-build/hamnix-installed.qcow2}"
INSTALLED_BOOT_MEM="${INSTALLED_BOOT_MEM:-1024M}"
SHELL_BOOT_WAIT="${SHELL_BOOT_WAIT:-200}"
INSTALLED_KERNEL_BANNER="Hamnix kernel booting"
INSTALLED_PROMPT_MARKER="handing off to interactive shell"

_ib_skip() { echo "[installed_boot] SKIP: $1" >&2; exit 0; }

# --- environment gates ------------------------------------------------
[ -e /dev/kvm ] || _ib_skip "/dev/kvm absent (KVM required; OVMF boot too slow without it)"
if [ -z "${OVMF_FD:-}" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
{ [ -n "${OVMF_FD:-}" ] && [ -f "$OVMF_FD" ]; } || _ib_skip "OVMF firmware not found (apt install ovmf)"
command -v mksquashfs >/dev/null 2>&1 || _ib_skip "mksquashfs not found (apt install squashfs-tools)"

# --- ensure the golden installed disk exists --------------------------
# STALE-ARTIFACT GUARD. The golden disk is installed ONCE and then reused
# forever by every installed-boot gate (test_auth, test_bios_boot,
# test_useradd, test_himem_above_4g, test_img_uefi_*, test_user_home_mount).
# "Rebuild only when ABSENT" is exactly the shape that produced the
# 2026-07-24 office-suite false negative on the installer image: nothing ever
# deletes build/hamnix-installed.qcow2, so these gates would happily validate
# a disk installed days before the code under test.
# shellcheck source=_installer_img.sh
source "$_IB_ROOT/scripts/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$_IB_ROOT}"
_IB_GOLDEN_ABS="$GOLDEN_NVME"
[ -f "$_IB_ROOT/$GOLDEN_NVME" ] && _IB_GOLDEN_ABS="$_IB_ROOT/$GOLDEN_NVME"
if installer_img_needs_build "$_IB_GOLDEN_ABS" "[installed_boot]"; then
    if [ ! -f "$_IB_GOLDEN_ABS" ] && [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        _ib_skip "golden disk $GOLDEN_NVME absent and HAMNIX_SKIP_BUILD=1"
    fi
    echo "[installed_boot] golden disk absent/stale; (re)building via build_installed_nvme.sh (installs once)"
    bash "$_IB_ROOT/scripts/build_installed_nvme.sh"
fi
# Resolve the golden disk to an absolute path.
if [ -f "$_IB_ROOT/$GOLDEN_NVME" ]; then
    GOLDEN_NVME="$_IB_ROOT/$GOLDEN_NVME"
fi
[ -f "$GOLDEN_NVME" ] || _ib_skip "golden installed disk could not be built (see build_installed_nvme.sh output)"

# --- per-test scratch state -------------------------------------------
# The writable disk + OVMF copy are created ONCE per test (on the first
# installed_boot_start) and REUSED across subsequent boots in the same test,
# so a multi-boot test (e.g. useradd: write on boot 1, verify persistence on
# boot 2) sees its own writes survive — exactly like the old single-IMG_RW
# two-boot pattern. The COPY is per-test (never the golden disk itself), so a
# state-mutating test can never poison the golden master. The log + input
# fifo are fresh PER BOOT.
INSTALLED_LOG=""
_IB_OVMF_RW=""
_IB_DISK_RW=""
_IB_INFIFO=""
QEMU_PID=""

_ib_cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$_IB_OVMF_RW" "$_IB_DISK_RW" "$_IB_INFIFO"
}
trap _ib_cleanup EXIT

# installed_boot_start — boot the test's writable installed disk; opens fd 3
# as the guest's serial stdin and captures the console to $INSTALLED_LOG.
# The first call makes a fresh per-test COPY of the golden disk; later calls
# reuse that same copy (writes from earlier boots persist).
installed_boot_start() {
    if [ -z "$_IB_DISK_RW" ]; then
        _IB_OVMF_RW=$(mktemp --tmpdir hamnix-ib.ovmf.XXXXXX.fd)
        _IB_DISK_RW=$(mktemp --tmpdir hamnix-ib.disk.XXXXXX.qcow2)
        cp "$OVMF_FD" "$_IB_OVMF_RW"
        # Per-test writable copy so state-mutating tests never poison golden.
        cp "$GOLDEN_NVME" "$_IB_DISK_RW"
    fi
    INSTALLED_LOG=$(mktemp --tmpdir hamnix-ib.boot.XXXXXX.log)
    _IB_INFIFO=$(mktemp --tmpdir -u hamnix-ib-in.XXXXXX)
    mkfifo "$_IB_INFIFO"

    exec 4<>"$_IB_INFIFO"
    exec 3>"$_IB_INFIFO"

    qemu-system-x86_64 \
        -enable-kvm -cpu host \
        -bios "$_IB_OVMF_RW" \
        -drive file="$_IB_DISK_RW",format=qcow2,if=none,id=nvmeroot \
        -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
        -m "$INSTALLED_BOOT_MEM" \
        -nographic -no-reboot -monitor none \
        -serial stdio \
        <&4 > "$INSTALLED_LOG" 2>&1 &
    QEMU_PID=$!
}

# installed_boot_wait [secs] — block until the interactive-prompt marker.
# Returns 0 on success, 1 if qemu died or the marker never appeared.
installed_boot_wait() {
    local secs="${1:-$SHELL_BOOT_WAIT}"
    local i
    for i in $(seq 1 "$secs"); do
        if grep -a -q "$INSTALLED_PROMPT_MARKER" "$INSTALLED_LOG"; then
            return 0
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            echo "[installed_boot] qemu exited before reaching the prompt." >&2
            tail -80 "$INSTALLED_LOG" >&2
            return 1
        fi
        sleep 1
    done
    echo "[installed_boot] prompt marker not seen in ${secs}s." >&2
    tail -80 "$INSTALLED_LOG" >&2
    return 1
}

# installed_type "cmd" [settle] — feed one line to the guest serial console.
installed_type() {
    printf '%s\n' "$1" >&3
    sleep "${2:-4}"
}

# installed_boot_stop — stop the guest, close the serial fds, and drop the
# per-boot input fifo (the writable disk persists for any subsequent boot).
installed_boot_stop() {
    kill "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true
    rm -f "$_IB_INFIFO"
    _IB_INFIFO=""
    QEMU_PID=""
}
