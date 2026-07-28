#!/usr/bin/env bash
# scripts/test_de_rl5_deterministic.sh
#
# DETERMINISTIC DE-BRINGUP GATE (#120).
#
# The scene-file desktop used to come up NONDETERMINISTICALLY: on ~55-88%
# of cold boots it was a BARE teal wallpaper + cursor with NO panel and NO
# apps.
#
# ROOT CAUSE (traced on repeated 8-boot marker-gated KVM sweeps; 100%
# correlated across ~25 boots): the ELF loader (fs/elf.ad elf_load_blob /
# the ELF64 path) zero-fills + copies segment bytes into its load `region`
# by identity vaddr with a plain memset/memcpy. region_alloc's backing
# intermittently aliases a page whose leaf PTE carries US=1 (the ET_DYN <->
# direct-map aliasing hazard), and a CPL=0 write to a US=1 page #PFs under
# CR4.SMAP unless RFLAGS.AC is set. The unbracketed write faulted
# `[pf] kernel write to RO user page` (pte …027 = P|RW|US, err=0x3, rip in
# memset called from elf_load_blob), SIGSEGV'ing the process being loaded
# (getty/motd) and cascading into a bare DE where the scene clients never
# mapped. THE FIX: bracket the loader's writes with STAC/CLAC
# (_ua_stac/_ua_clac) exactly like the COW-copy + coredump paths.
# Secondary hardening: rc.5's synchronous "pre-warm shell" step is now
# fire-and-forget so a slow/blocked pre-warm can never gate app launch.
#
# This gate boots the live image to runlevel 5 N times and asserts, EVERY
# boot, that:
#   * the boot handed off to the interactive shell (rc.5 did NOT hang), AND
#   * the compositor presented the full window set (presented >= 5 — the
#     desktop backdrop + panel + the four core apps), AND
#   * the framebuffer is non-blank (the DE actually painted pixels).
# ANY bare/hung boot fails the gate — turning the old coin-flip into a hard
# regression guard.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, or the image are
# unavailable and the image cannot be built.
#
# Env overrides:
#   INSTALLER_IMG      image path         (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware      (default: auto-resolved)
#   RL5_BOOTS          number of boots    (default: 5; the ≥8 sweep is manual)
#   RL5_MIN_PRESENTED  min presented wins (default: 5)
#   BOOT_WAIT          per-boot handoff timeout seconds (default: 240)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
RL5_BOOTS="${RL5_BOOTS:-5}"
RL5_MIN_PRESENTED="${RL5_MIN_PRESENTED:-5}"
BOOT_WAIT="${BOOT_WAIT:-240}"
HANDOFF_MARKER="handing off to interactive shell"

if [ ! -e /dev/kvm ]; then
    echo "[rl5_det] SKIP: /dev/kvm absent (KVM required)" >&2; exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[rl5_det] SKIP: OVMF firmware not found (apt install ovmf)" >&2; exit 0
fi
if ! command -v socat >/dev/null 2>&1; then
    echo "[rl5_det] SKIP: socat required for the framebuffer screendump" >&2; exit 0
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_rl5_deterministic]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[rl5_det] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2; exit 0
    fi
    echo "[rl5_det] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Reaching here means a build was ATTEMPTED just above and produced no
# image: the tree does not build, nothing is booted and NOTHING IS
# ASSERTED. That is INCONCLUSIVE (125), never a clean skip — the
# by-request skip (HAMNIX_SKIP_BUILD=1) is handled above and still
# exits 0. See scripts/_installer_img.sh + test_gate_softgreen.sh.
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[rl5_det] RESULT: INCONCLUSIVE ($INSTALLER_IMG could not be built)" >&2
    exit 125
fi

fail=0; bare=0
for i in $(seq 1 "$RL5_BOOTS"); do
    OVMF_RW=$(mktemp --tmpdir hamnix-rl5det.ovmf.XXXX.fd)
    IMG_RW=$(mktemp --tmpdir hamnix-rl5det.img.XXXX.raw)
    LOG=$(mktemp --tmpdir hamnix-rl5det.XXXX.log)
    MON=$(mktemp --tmpdir -u hamnix-rl5det-mon.XXXX)
    SHOT=$(mktemp --tmpdir hamnix-rl5det.XXXX.ppm)
    cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
    qemu-system-x86_64 -enable-kvm -cpu host -bios "$OVMF_RW" \
        -drive file="$IMG_RW",format=raw,if=virtio \
        -m "${HAMNIX_VM_MEM:-2G}" -vga std -display none -no-reboot \
        -monitor "unix:$MON,server,nowait" -serial stdio \
        > "$LOG" 2>&1 < /dev/null &
    QP=$!; booted=0
    for _ in $(seq 1 "$BOOT_WAIT"); do
        grep -a -q "$HANDOFF_MARKER" "$LOG" && { booted=1; break; }
        kill -0 "$QP" 2>/dev/null || break
        sleep 1
    done
    distinct=0
    if [ "$booted" = 1 ]; then
        sleep 8
        printf 'screendump %s\n' "$SHOT" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
        sleep 2
        [ -s "$SHOT" ] && distinct=$(tail -c +16 "$SHOT" 2>/dev/null \
            | od -An -tx1 -w3 | sort -u | head -200 | wc -l)
    fi
    kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null

    presented=$(grep -a "presented=" "$LOG" | tail -1 | grep -oaE "presented=[0-9]+" | cut -d= -f2)
    presented=${presented:-0}
    if [ "$booted" = 1 ] && [ "$presented" -ge "$RL5_MIN_PRESENTED" ] 2>/dev/null && [ "${distinct:-0}" -ge 2 ]; then
        echo "[rl5_det] boot $i: PASS (handoff + presented=$presented>=$RL5_MIN_PRESENTED + fb painted distinct=$distinct)"
    else
        echo "[rl5_det] boot $i: FAIL (booted=$booted presented=$presented distinct=${distinct:-0}) — BARE/HUNG DESKTOP" >&2
        grep -a -n "\[pf\] kernel write to RO user page\|pre-warm\|scene_de" "$LOG" | tail -12 | sed 's/^/[rl5_det]   /' >&2
        fail=1; bare=$((bare + 1))
    fi
    rm -f "$OVMF_RW" "$IMG_RW" "$LOG" "$MON" "$SHOT"
done

if [ "$fail" = 0 ]; then
    echo "[rl5_det] PASS: $RL5_BOOTS/$RL5_BOOTS boots came up with the full scene desktop (0 bare)."
    exit 0
fi
echo "[rl5_det] FAIL: $bare/$RL5_BOOTS boots came up BARE/HUNG — DE bringup is nondeterministic again." >&2
exit 1
