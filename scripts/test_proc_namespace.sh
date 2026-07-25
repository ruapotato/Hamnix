#!/usr/bin/env bash
# scripts/test_proc_namespace.sh — /proc namespace-bind verification.
#
# Proves that the Plan 9 process surface /proc is a real, bindable `#p`
# proc device server (etc/rc.boot's `bind '#p' /proc`), NOT a kernel
# literal-path string-match in vfs_open/vfs_open_write/vfs_listdir.
#
# Before this work, fs/vfs.ad literal-matched "/proc/<pid>/<file>"
# (devproc_path_match) and the static "/proc/<name>" set (is_proc_path ->
# _open_proc) BEFORE the namespace machinery, and bare `#p` / `#p/<pid>`
# could not be listed at all (`ls /proc` returned ENOENT). Now the kernel
# exposes the proc tree under the `#p` device letter, init binds it to
# /proc, chan_resolve_prefix rewrites a /proc/<...> open to `#p/<...>`, and
# devproc_listdir makes the server a real listable directory tree.
#
# This test asserts, through the namespace bind:
#
#   1. `ls /proc`        lists a static well-known file (cpuinfo) AND a
#                        numeric pid — devproc_listdir enumerated both the
#                        proc_render static set and the live task table.
#   2. `ls /proc/1`      lists the per-task files (status, stat) — the
#                        `#p/<pid>` directory walk.
#   3. `cat /proc/cpuinfo`   renders the static file through the bind
#                        (/proc/cpuinfo -> #p/cpuinfo -> _open_proc).
#   4. `cat /proc/1/status`  renders pid 1's status through the bind
#                        (/proc/1/status -> #p/1/status -> devproc_open).
#
# WHY THE INSTALLER IMAGE UNDER OVMF (not a plain `-kernel` boot): on the
# QEMU host this runs against, the multiboot `-kernel` path fails the VBE
# probe (see memory: project_qemu_multiboot_vbe_limit), so plain kernel
# boots never reach userspace. The installer image boots via the EFI stub
# under OVMF, which works. rc.boot applies the `#p` device bind BEFORE the
# installer-medium branch, so /proc is namespace-resolved in the
# interactive shell the medium re-enters after the auto-install finishes.
#
# Input is GATED on the installer-complete marker (not a fixed sleep) so
# the test stays deterministic when boot/install timing shifts under load.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
NVME_SIZE="${NVME_SIZE:-2G}"
INSTALL_WAIT="${INSTALL_WAIT:-500}"

# --- environment gates (mirror test_net_namespace.sh) ----------------
if [ ! -e /dev/kvm ]; then
    echo "[test_proc_namespace] SKIP: /dev/kvm absent (OVMF boot too slow without KVM)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_proc_namespace] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- build the installer image (compiles the whole kernel) -----------
echo "[test_proc_namespace] (1/2) Build installer image (compiles kernel)"
HAMNIX_INSTALLER_AUTORUN=1 bash scripts/build_installer_img.sh >/tmp/test_proc_namespace_build.log 2>&1 || {
    echo "[test_proc_namespace] FAIL: installer image build failed"
    tail -30 /tmp/test_proc_namespace_build.log
    exit 1
}
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_proc_namespace] FAIL: $INSTALLER_IMG not built"
    exit 1
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[proc_namespace]"

NVME_IMG=$(mktemp --tmpdir hamnix-procns-nvme.XXXXXX.qcow2)
OVMF_RW=$(mktemp --tmpdir hamnix-procns.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-procns.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-procns.boot.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-procns-in.XXXXXX)
mkfifo "$INFIFO"
qemu-img create -f qcow2 "$NVME_IMG" "$NVME_SIZE" >/dev/null
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$MEDIA_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$NVME_IMG" "$OVMF_RW" "$MEDIA_RW" "$INFIFO"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

# --- boot installer medium + blank NVMe; auto-install runs ------------
echo "[test_proc_namespace] (2/2) Boot installer medium under OVMF (+ blank NVMe)"
exec 4<>"$INFIFO"
exec 3>"$INFIFO"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$MEDIA_RW",format=raw,if=none,id=media \
    -device virtio-blk-pci,drive=media,bootindex=0 \
    -drive file="$NVME_IMG",format=qcow2,if=none,id=nvmetgt \
    -device nvme,drive=nvmetgt,serial=hamnvme01,bootindex=1 \
    -m 1280M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

# Gate on the auto-installer's completion marker — at that point rc.boot
# has applied the device binds (incl. `bind '#p' /proc`) and re-entered
# the interactive shell.
echo "[test_proc_namespace] waiting up to ${INSTALL_WAIT}s for the auto-installer to finish..."
ready=0
for _ in $(seq 1 "$INSTALL_WAIT"); do
    if grep -a -q '\[install-nvme\] install complete on /dev/blk/nvme0n1' "$LOG"; then
        ready=1; break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then break; fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "[test_proc_namespace] FAIL: auto-installer never reported complete"
    tail -60 "$LOG"
    exit 1
fi
echo "[test_proc_namespace] installer done; shell interactive — driving /proc listings."

# Fence markers so each listing attributes to a specific command.
M_PROC="HAMNIX_PROCNS_PROC"
M_PID1="HAMNIX_PROCNS_PID1"
M_CPUINFO="HAMNIX_PROCNS_CPUINFO"
M_STATUS="HAMNIX_PROCNS_STATUS"
M_DONE="HAMNIX_PROCNS_DONE_99"

type_cmd() { printf '%s\n' "$1" >&3; sleep "${2:-4}"; }

sleep 6
type_cmd "echo $M_PROC" 2
type_cmd "ls /proc"
type_cmd "echo $M_PID1" 2
type_cmd "ls /proc/1"
type_cmd "echo $M_CPUINFO" 2
type_cmd "cat /proc/cpuinfo"
type_cmd "echo $M_STATUS" 2
type_cmd "cat /proc/1/status"
type_cmd "echo $M_DONE" 3

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&- 2>/dev/null || true
exec 4>&- 2>/dev/null || true

echo "[test_proc_namespace] --- captured output (post-install shell) ---"
awk '/install complete on \/dev\/blk\/nvme0n1/{f=1} f' "$LOG" | tail -160
echo "[test_proc_namespace] --- end output ---"

# Assertions operate on the post-install portion of the log, with the
# interactive line-editor's CR-repaint/prompt-echo lines dropped (those
# echo back every typed keystroke and would false-match a marker that was
# merely TYPED). We strip CRs and the runtime's leading non-printable
# banner bytes so the names match cleanly.
post() {
    awk '/install complete on \/dev\/blk\/nvme0n1/{f=1} f' "$LOG" \
        | tr -d '\r' \
        | grep -a -v 'hamsh\$' \
        | sed 's/[^[:print:]]//g'
}

fail=0

# 1. `ls /proc` lists a static well-known file (cpuinfo) AND a numeric
#    pid — devproc_listdir enumerated the proc_render static set plus the
#    live task table through the `#p` bind.
seg_proc="$(post | sed -n "/$M_PROC/,/$M_PID1/p")"
if echo "$seg_proc" | grep -a -E -q '(^|[^[:alnum:]_/])cpuinfo([^[:alnum:]_]|$)'; then
    echo "[test_proc_namespace] OK: ls /proc shows cpuinfo (static file)"
else
    echo "[test_proc_namespace] MISS: ls /proc did not show cpuinfo"
    fail=1
fi
# A bare numeric line (the pid entry). Exclude the marker echoes and any
# kernel-log noise lines.
if echo "$seg_proc" \
        | grep -avE 'PROCNS|^\[[0-9]+\]|aslr|runtime:|task: pid|stage-|tick=|uptime=' \
        | grep -a -E -q '^[[:space:]]*[0-9]+[[:space:]]*$'; then
    echo "[test_proc_namespace] OK: ls /proc shows a numeric pid"
else
    echo "[test_proc_namespace] MISS: ls /proc did not show a numeric pid"
    fail=1
fi

# 2. `ls /proc/1` lists the per-task files (status + stat) — the
#    `#p/<pid>` directory walk via devproc_listdir.
seg_pid1="$(post | sed -n "/$M_PID1/,/$M_CPUINFO/p")"
if echo "$seg_pid1" | grep -a -E -q '(^|[^[:alnum:]_/])status([^[:alnum:]_]|$)' \
   && echo "$seg_pid1" | grep -a -E -q '(^|[^[:alnum:]_/])stat([^[:alnum:]_]|$)'; then
    echo "[test_proc_namespace] OK: ls /proc/1 shows status + stat"
else
    echo "[test_proc_namespace] MISS: ls /proc/1 did not show status + stat"
    fail=1
fi

# 3. `cat /proc/cpuinfo` renders — the static file opens through the bind
#    (/proc/cpuinfo -> #p/cpuinfo -> _open_proc -> proc_render). cpuinfo
#    always emits a "processor" line.
if post | sed -n "/$M_CPUINFO/,/$M_STATUS/p" \
        | grep -a -i -q 'processor'; then
    echo "[test_proc_namespace] OK: cat /proc/cpuinfo rendered"
else
    echo "[test_proc_namespace] MISS: cat /proc/cpuinfo did not render"
    fail=1
fi

# 4. `cat /proc/1/status` renders — pid 1's per-task status opens through
#    the bind (/proc/1/status -> #p/1/status -> devproc_open). The Plan 9
#    status file is a single line "<pid> <name> <state> <pml4_hex>", so a
#    successful render shows the pid 1 prefix, a single-letter state
#    (R/S/Z) and a long hex pml4 token on one line.
if post | sed -n "/$M_STATUS/,/$M_DONE/p" \
        | grep -a -E -q '(^|[^0-9])1[[:space:]]+[A-Za-z_].*[[:space:]][RSZ?][[:space:]]+(0x)?[0-9a-fA-F]{5,}'; then
    echo "[test_proc_namespace] OK: cat /proc/1/status rendered"
else
    echo "[test_proc_namespace] MISS: cat /proc/1/status did not render"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_proc_namespace] FAIL"
    exit 1
fi
echo "[test_proc_namespace] PASS"
