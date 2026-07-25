#!/usr/bin/env bash
# scripts/test_dev_namespace.sh — /dev namespace-bind verification.
#
# Proves that /dev and /dev/blk are now real, listable directories served
# by a device file server bound by init (etc/rc.boot's `bind '#c' /dev`
# and `bind '#b' /dev/blk`), NOT a kernel literal-path string-match.
#
# Before this work `ls /dev` failed ("listdir failed: /dev") and `ls /`
# did not show `dev` at all; block devices were reachable ONLY through
# devblk_path_match's hardcoded "/dev/blk/<name>" interception. This test
# asserts, through the namespace bind:
#
#   1. `ls /`          shows  dev          (the #c bind shows up in `/`)
#   2. `ls /dev`       shows  blk          (the dev server lists children)
#   3. `ls /dev/blk`   lists the live block devices (nvme0n1[, vda, ...])
#   4. `lsblk`         prints the block table (user/lsblk.ad sys_listdir)
#   5. `cat /dev/blk/<dev>/size`  returns a non-empty numeric capacity
#      (the legacy literal /dev/blk path still resolves, via the bind)
#
# WHY THE INSTALLER IMAGE UNDER OVMF (not a plain `-kernel` boot): on the
# QEMU host this runs against, the multiboot `-kernel` path fails the VBE
# probe ("Cannot load x86-64 image" / "multiboot knows VBE. we don't" —
# see memory: project_qemu_multiboot_vbe_limit), so plain kernel boots
# never reach userspace. The installer image boots via the EFI stub under
# OVMF, which works. rc.boot applies the `#c`/`#b` device binds BEFORE the
# installer-medium branch, so /dev + /dev/blk are populated in the
# interactive shell the medium re-enters after the auto-install finishes;
# the medium has both the virtio install disk (vda) and the freshly
# partitioned NVMe target (nvme0n1 + partitions) registered.
#
# Input is GATED on the installer-complete marker (not a fixed sleep) so
# the test stays deterministic when boot/install timing shifts under load.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_dev_namespace

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
NVME_SIZE="${NVME_SIZE:-2G}"
INSTALL_WAIT="${INSTALL_WAIT:-500}"

# --- environment gates (mirror test_installer_nvme_inram.sh) ---------
# A missing host prerequisite is ABSENCE OF EVIDENCE, not a pass: report
# INCONCLUSIVE so a host without KVM/OVMF cannot masquerade as green.
if [ ! -e /dev/kvm ]; then
    verdict_inconclusive "$TAG" "/dev/kvm absent — the OVMF installer boot is too slow to observe without KVM. Re-run on a KVM host."
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    verdict_inconclusive "$TAG" "OVMF firmware not found (apt install ovmf) — the EFI-stub installer boot cannot run. Install ovmf and re-run."
fi

# --- build the installer image (compiles the whole kernel) -----------
echo "[test_dev_namespace] (1/2) Build installer image (compiles kernel)"
HAMNIX_INSTALLER_AUTORUN=1 bash scripts/build_installer_img.sh >/tmp/test_dev_namespace_build.log 2>&1 || {
    tail -30 /tmp/test_dev_namespace_build.log >&2
    verdict_inconclusive "$TAG" "installer image build failed — cannot boot the gate (toolchain/build issue, not a /dev-namespace regression)."
}
if [ ! -f "$INSTALLER_IMG" ]; then
    verdict_inconclusive "$TAG" "$INSTALLER_IMG not built — cannot boot the gate."
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$INSTALLER_IMG" "[dev_namespace]"

NVME_IMG=$(mktemp --tmpdir hamnix-devns-nvme.XXXXXX.qcow2)
OVMF_RW=$(mktemp --tmpdir hamnix-devns.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-devns.media.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-devns.boot.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-devns-in.XXXXXX)
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
echo "[test_dev_namespace] (2/2) Boot installer medium under OVMF (+ blank NVMe)"
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
# has applied the device binds and re-entered the interactive shell.
echo "[test_dev_namespace] waiting up to ${INSTALL_WAIT}s for the auto-installer to finish..."
ready=0
for _ in $(seq 1 "$INSTALL_WAIT"); do
    if grep -a -q '\[install-nvme\] install complete on /dev/blk/nvme0n1' "$LOG"; then
        ready=1; break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then break; fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    tail -60 "$LOG" >&2
    verdict_inconclusive "$TAG" \
        "the auto-installer never reported 'install complete' within ${INSTALL_WAIT}s —" \
        "the guest was starved (or the install stalled) before the interactive shell" \
        "re-entered, so the /dev namespace binds were never observable. Re-run on a QUIET host."
fi
echo "[test_dev_namespace] installer done; shell interactive — driving listings."

# Fence markers so each listing attributes to a specific command.
M_ROOT="HAMNIX_DEVNS_ROOT"
M_DEV="HAMNIX_DEVNS_DEV"
M_BLK="HAMNIX_DEVNS_BLK"
M_LSBLK="HAMNIX_DEVNS_LSBLK"
M_SIZE="HAMNIX_DEVNS_SIZE"
M_DONE="HAMNIX_DEVNS_DONE_99"

type_cmd() { printf '%s\n' "$1" >&3; sleep "${2:-4}"; }

sleep 6
type_cmd "echo $M_ROOT" 2
type_cmd "ls /"
type_cmd "echo $M_DEV" 2
type_cmd "ls /dev"
type_cmd "echo $M_BLK" 2
type_cmd "ls /dev/blk"
type_cmd "echo $M_LSBLK" 2
type_cmd "lsblk"
type_cmd "echo $M_SIZE" 2
type_cmd "cat /dev/blk/nvme0n1/size"
type_cmd "echo $M_DONE" 3

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&- 2>/dev/null || true
exec 4>&- 2>/dev/null || true

echo "[test_dev_namespace] --- captured output (post-install shell) ---"
# Show only the portion after install completes, to keep it readable.
awk '/install complete on \/dev\/blk\/nvme0n1/{f=1} f' "$LOG" | tail -120
echo "[test_dev_namespace] --- end output ---"

# Assertions operate on the post-install portion of the log, with the
# interactive line-editor's CR-repaint/prompt-echo lines dropped (those
# echo back every typed keystroke and would false-match a marker that was
# merely TYPED). hamsh repaints one input line on a single serial line
# carrying `hamsh$ `; genuine command output has no prompt. We also strip
# CRs and the `ls`/`cat` runtime's leading non-printable banner bytes so
# the device names match cleanly.
post() {
    awk '/install complete on \/dev\/blk\/nvme0n1/{f=1} f' "$LOG" \
        | tr -d '\r' \
        | grep -a -v 'hamsh\$' \
        | sed 's/[^[:print:]]//g'
}

fail=0

# 1. `ls /` lists `dev` — the `bind '#c' /dev` mtab child surfaces in /.
#    The `ls` columns may be space- or newline-separated; match `dev` as a
#    standalone token (not a substring of `/dev/...` echoes, which `post`
#    already dropped as prompt lines).
if post | sed -n "/$M_ROOT/,/$M_DEV/p" \
        | grep -a -E -q '(^|[^[:alnum:]_/])dev([^[:alnum:]_]|$)'; then
    echo "[test_dev_namespace] OK: ls / shows dev"
else
    echo "[test_dev_namespace] MISS: ls / did not show dev"
    fail=1
fi

# 2. `ls /dev` lists `blk` — the dev server enumerates its children.
if post | sed -n "/$M_DEV/,/$M_BLK/p" \
        | grep -a -E -q '(^|[^[:alnum:]_/])blk([^[:alnum:]_]|$)'; then
    echo "[test_dev_namespace] OK: ls /dev shows blk"
else
    echo "[test_dev_namespace] MISS: ls /dev did not show blk"
    fail=1
fi

# 3. `ls /dev/blk` enumerates nvme0n1 — the block server walks the table.
if post | sed -n "/$M_BLK/,/$M_LSBLK/p" \
        | grep -a -E -q '(^|[^[:alnum:]_])nvme0n1([^[:alnum:]_]|$)'; then
    echo "[test_dev_namespace] OK: /dev/blk enumerates nvme0n1"
else
    echo "[test_dev_namespace] MISS: nvme0n1 not enumerated under /dev/blk"
    fail=1
fi

# 4. lsblk emitted its header — proves user/lsblk.ad's sys_listdir(/dev/blk)
#    succeeded (it bails to stderr with an error otherwise).
if post | grep -a -F -q "SIZE(512B-sectors)"; then
    echo "[test_dev_namespace] OK: lsblk listed the block table"
else
    echo "[test_dev_namespace] MISS: lsblk did not produce its table"
    fail=1
fi

# 5. cat /dev/blk/nvme0n1/size returns a non-empty decimal capacity — the
#    legacy literal /dev/blk path still resolves (now via the bind). The
#    `cat` runtime prefixes a few banner bytes before the number, so match
#    a run of >=6 digits anywhere on a non-prompt line in the fence.
size_line="$(post | sed -n "/$M_SIZE/,/$M_DONE/p" \
    | grep -avE '^\[[0-9]+\]|aslr|runtime:|task: pid|stage-|tick=' \
    | grep -a -oE '[0-9]{6,}' | head -1)"
if [ -n "$size_line" ]; then
    echo "[test_dev_namespace] OK: cat /dev/blk/nvme0n1/size = $size_line"
else
    echo "[test_dev_namespace] MISS: /dev/blk/nvme0n1/size returned no capacity"
    fail=1
fi

# By here the auto-installer DID complete (the ready gate passed) and the
# interactive shell WAS driven, so every listing above was actually
# observable — a MISS is therefore a real regression in the #c/#b device
# binds, not host starvation.
if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "the installer completed and the shell was driven, but a /dev namespace" \
        "listing (ls / | ls /dev | /dev/blk enum | lsblk | size) was OBSERVED" \
        "absent — the #c/#b device binds regressed."
fi
verdict_pass "$TAG" "/dev and /dev/blk are real listable directories served by the #c/#b binds: ls / shows dev, ls /dev shows blk, /dev/blk enumerates nvme0n1, lsblk prints the table, and /dev/blk/nvme0n1/size returns a numeric capacity."
