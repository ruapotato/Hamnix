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
#   * the scene clients actually BROUGHT UP their windows (>= RL5_MIN_WINDOWS
#     `[devwsys] window N mapped` lines), AND
#   * the framebuffer is non-blank (the DE actually painted pixels).
#
# WHY NOT `presented=` (the assertion this gate shipped with, 2026-07-12)
# ---------------------------------------------------------------------
# It asserted `presented >= 5` against the LAST `[de_present] ... presented=N`
# line on the serial console. That assertion has been UNSATISFIABLE — not
# flaky, unsatisfiable — and the gate was 5/5 red when it was finally run on a
# KVM host on 2026-07-28. Two independent reasons, both measured:
#
#   1. `[de_present]` is a REAL-HW BLANK-SCREEN DIAGNOSTIC, throttled by
#      WSYS_PRESENT_DIAG_MAX = 8 presents (sys/src/9/port/devwsys.ad). On a
#      healthy boot it is exhausted BEFORE the scene clients map anything:
#          [000881] [de_present]   live_windows=0 presented=0
#          [001254] [de_present]   live_windows=0 presented=0
#          [001280] [devwsys] window 2 mapped pid=31     <-- first window
#      The last `presented=` the gate can ever read is therefore an
#      early-boot snapshot, structurally 0, no matter how well the DE works.
#   2. Even at steady state the number is out of reach. `>= 5` was calibrated
#      on 2026-07-12, when rc.5 baked a demo-app self-test that opened four
#      app windows. ac81cb23 (2026-07-13) moved that into
#      /etc/rc.d/rc.5.selftest, packaged ONLY under HAMNIX_DE_SELFTEST=1, so a
#      normal boot is the "clean first-boot desktop (no demo apps)" and maps
#      four windows total (desktop, panel x2, toast).
#
# The gate went dark the day after it was written and nobody saw it, because
# it needs /dev/kvm and every GitHub runner is ubuntu-latest — see
# scripts/test_gate_kvmdark.sh and scripts/ci_run_kvm_battery.sh.
#
# The replacement asserts the same PROPERTY (the DE came up whole, not bare)
# on a signal that is not throttled and not tied to the demo apps: the count
# of windows the scene clients mapped. Measured at 4 on healthy boots (this
# image and the installer gate's). This is the STRONGEST reachable form of
# the original intent — the old one asserted nothing at all.
#
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
#   RL5_MIN_WINDOWS    min mapped scene windows (default: 3 — desktop +
#                      the panel's two; the toast is transient)
#   BOOT_WAIT          per-boot handoff timeout seconds (default: 240)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
RL5_BOOTS="${RL5_BOOTS:-5}"
RL5_MIN_WINDOWS="${RL5_MIN_WINDOWS:-3}"
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

    # Windows the scene clients actually mapped. NOT `presented=` — see the
    # header: that diagnostic is throttled to the first 8 presents and is
    # exhausted before the first window maps, so it can only ever read 0.
    windows=$(grep -ac "\[devwsys\] window [0-9]* mapped" "$LOG" 2>/dev/null)
    windows=${windows:-0}
    if [ "$booted" = 1 ] && [ "$windows" -ge "$RL5_MIN_WINDOWS" ] 2>/dev/null && [ "${distinct:-0}" -ge 2 ]; then
        echo "[rl5_det] boot $i: PASS (handoff + windows=$windows>=$RL5_MIN_WINDOWS + fb painted distinct=$distinct)"
    else
        echo "[rl5_det] boot $i: FAIL (booted=$booted windows=$windows distinct=${distinct:-0}) — BARE/HUNG DESKTOP" >&2
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
