#!/usr/bin/env bash
# scripts/test_net_namespace.sh — /net namespace-bind verification.
#
# Proves that the Plan 9 networking surface /net is now a real, bindable
# `#I` IP device server (etc/rc.boot's `bind '#I' /net`), NOT a kernel
# literal-path string-match in vfs_open/vfs_open_write.
#
# Before this work, fs/vfs.ad's _open_net() literal-matched "/net/tcp/
# clone", "/net/udp/clone" and the per-connection /net/<proto>/<N>/*
# files BEFORE the namespace machinery, returning NET_NOT on a miss.
# Now the kernel exposes the IP stack under the `#I` device letter, init
# binds it to /net, and chan_resolve_prefix rewrites a /net/<...> open to
# `#I/<...>` so EVERY /net access arrives through namespace resolution.
#
# This test asserts, through the namespace bind:
#
#   1. `ls /net`       lists the proto dirs (tcp, udp, icmp)
#   2. `ls /net/tcp`   lists `clone`
#   3. `cat /net/tcp/clone`  returns a numeric connection number — i.e.
#      the open resolved `/net/tcp/clone` -> `#I/tcp/clone` through the
#      bind and the devnet backend actually allocated a connection.
#
# WHY THE INSTALLER IMAGE UNDER OVMF (not a plain `-kernel` boot): on the
# QEMU host this runs against, the multiboot `-kernel` path fails the VBE
# probe (see memory: project_qemu_multiboot_vbe_limit), so plain kernel
# boots never reach userspace. The installer image boots via the EFI stub
# under OVMF, which works. rc.boot applies the `#I` device bind BEFORE the
# installer-medium branch, so /net is namespace-resolved in the
# interactive shell the medium re-enters after the auto-install finishes.
#
# Input is GATED on the installer-complete marker (not a fixed sleep) so
# the test stays deterministic when boot/install timing shifts under load.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# The AUTORUN medium lives at its OWN path (2026-07-28). This script builds
# with HAMNIX_INSTALLER_AUTORUN=1, which plants the unattended auto-install
# trigger; every other consumer of build/hamnix-installer.img wants the NORMAL
# live medium. mtime freshness cannot tell the two apart, so sharing one path
# meant whichever variant was built last silently served both — a false red for
# the install gate, and an unrelated gate booting a medium that auto-wipes a
# disk. See the long note in scripts/test_installer_nvme_inram.sh.
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer-autorun.img}"
NVME_SIZE="${NVME_SIZE:-2G}"
INSTALL_WAIT="${INSTALL_WAIT:-500}"

# --- environment gates (mirror test_dev_namespace.sh) ----------------
if [ ! -e /dev/kvm ]; then
    echo "[test_net_namespace] SKIP: /dev/kvm absent (OVMF boot too slow without KVM)" >&2
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
    echo "[test_net_namespace] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- build the installer image (compiles the whole kernel) -----------
echo "[test_net_namespace] (1/2) Build installer image (compiles kernel)"
HAMNIX_INSTALLER_AUTORUN=1 HAMNIX_INSTALLER_IMG_OUT="$INSTALLER_IMG" bash scripts/build_installer_img.sh >/tmp/test_net_namespace_build.log 2>&1 || {
    echo "[test_net_namespace] FAIL: installer image build failed"
    tail -30 /tmp/test_net_namespace_build.log
    exit 1
}
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_net_namespace] FAIL: $INSTALLER_IMG not built"
    exit 1
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[net_namespace]"

NVME_IMG=$(mktemp --tmpdir hamnix-netns-nvme.XXXXXX.qcow2)
OVMF_RW=$(mktemp --tmpdir hamnix-netns.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-netns.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-netns.boot.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-netns-in.XXXXXX)
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
echo "[test_net_namespace] (2/2) Boot installer medium under OVMF (+ blank NVMe)"
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
# has applied the device binds (incl. `bind '#I' /net`) and re-entered
# the interactive shell.
echo "[test_net_namespace] waiting up to ${INSTALL_WAIT}s for the auto-installer to finish..."
ready=0
for _ in $(seq 1 "$INSTALL_WAIT"); do
    if grep -a -q '\[install-nvme\] install complete on /dev/blk/nvme0n1' "$LOG"; then
        ready=1; break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then break; fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "[test_net_namespace] FAIL: auto-installer never reported complete"
    tail -60 "$LOG"
    exit 1
fi
echo "[test_net_namespace] installer done; shell interactive — driving /net listings."

# Fence markers so each listing attributes to a specific command.
M_NET="HAMNIX_NETNS_NET"
M_TCP="HAMNIX_NETNS_TCP"
M_CLONE="HAMNIX_NETNS_CLONE"
M_DONE="HAMNIX_NETNS_DONE_99"

type_cmd() { printf '%s\n' "$1" >&3; sleep "${2:-4}"; }

sleep 6
type_cmd "echo $M_NET" 2
type_cmd "ls /net"
type_cmd "echo $M_TCP" 2
type_cmd "ls /net/tcp"
type_cmd "echo $M_CLONE" 2
type_cmd "cat /net/tcp/clone"
type_cmd "echo $M_DONE" 3

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&- 2>/dev/null || true
exec 4>&- 2>/dev/null || true

echo "[test_net_namespace] --- captured output (post-install shell) ---"
awk '/install complete on \/dev\/blk\/nvme0n1/{f=1} f' "$LOG" | tail -120
echo "[test_net_namespace] --- end output ---"

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

# 1. `ls /net` lists the proto dirs — the `#I` server enumerates them.
seg_net="$(post | sed -n "/$M_NET/,/$M_TCP/p")"
if echo "$seg_net" | grep -a -E -q '(^|[^[:alnum:]_/])tcp([^[:alnum:]_]|$)' \
   && echo "$seg_net" | grep -a -E -q '(^|[^[:alnum:]_/])udp([^[:alnum:]_]|$)' \
   && echo "$seg_net" | grep -a -E -q '(^|[^[:alnum:]_/])icmp([^[:alnum:]_]|$)'; then
    echo "[test_net_namespace] OK: ls /net shows tcp/udp/icmp"
else
    echo "[test_net_namespace] MISS: ls /net did not show tcp/udp/icmp"
    fail=1
fi

# 2. `ls /net/tcp` lists `clone` — the proto dir enumerates its children.
if post | sed -n "/$M_TCP/,/$M_CLONE/p" \
        | grep -a -E -q '(^|[^[:alnum:]_/])clone([^[:alnum:]_]|$)'; then
    echo "[test_net_namespace] OK: ls /net/tcp shows clone"
else
    echo "[test_net_namespace] MISS: ls /net/tcp did not show clone"
    fail=1
fi

# 3. `cat /net/tcp/clone` returns a connection number — the open resolved
#    /net/tcp/clone -> #I/tcp/clone through the bind and devnet allocated
#    a conn (the clone fd's read renders the conn number as decimal). The
#    `cat` runtime prefixes a few banner bytes before the number, so match
#    a run of digits on a non-prompt, non-log line in the fence. A clone
#    failure renders "-1"; require a NON-negative number.
clone_num="$(post | sed -n "/$M_CLONE/,/$M_DONE/p" \
    | grep -avE '^\[[0-9]+\]|aslr|runtime:|task: pid|stage-|tick=|uptime=' \
    | grep -a -oE '(^|[^-0-9])[0-9]+' | grep -a -oE '[0-9]+' | head -1)"
if [ -n "$clone_num" ]; then
    echo "[test_net_namespace] OK: cat /net/tcp/clone = $clone_num (conn allocated via bind)"
else
    echo "[test_net_namespace] MISS: /net/tcp/clone returned no connection number"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_net_namespace] FAIL"
    exit 1
fi
echo "[test_net_namespace] PASS"
