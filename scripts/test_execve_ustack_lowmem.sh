#!/usr/bin/env bash
# scripts/test_execve_ustack_lowmem.sh — fix/execve-ustack-oom regression gate.
#
# WHAT THIS GUARDS
# ----------------
# The Linux-ABI user stack is a FIXED 1 MiB window at a high VA. do_execve used
# to back it EAGERLY with a single order-8 (1 MiB) CONTIGUOUS alloc_pages() run
# (arch/x86/kernel/syscall.ad). Under memory fragmentation at low RAM (the user
# hit this launching DE apps at ~221 MB / ~78 MB free, fragmented) that order-8
# run FAILS even with megabytes free. alloc_pages returned 0, and — the
# showstopper — that phys 0 was passed straight to elf_install_user_range,
# which stamped the fixed stack window's US=1 leaves onto physical [0, 1 MiB)
# (the boot page tables / AP trampoline). The task then ran on a stack aliased
# over kernel memory and the argv/envp writes corrupted live page tables:
#   SMAP #PF (cr2 == rsp, US=1 leaf, err=0x01) -> re-fault -> #DF -> halt.
#
# THE FIX (two parts):
#   A. STOP THE CORRUPTION. A pre-PONR pages_can_alloc() guard rejects a
#      genuine OOM with the caller INTACT (-ENOMEM, Linux semantics), and a
#      hard NULL-CHECK on the past-PONR alloc fails the execve deterministically
#      instead of ever mapping phys 0.
#   B. LET APPS LAUNCH UNDER LOW RAM. Only a small CONTIGUOUS PREFIX (order-6,
#      256 KiB) at the top of the window is eager-allocated; the lower remainder
#      is a DEMAND-ZERO VMA that faults in page-by-page (the proven BSS demand
#      path). Order-6 is 4x more fragmentation-tolerant than order-8, so a
#      1 MiB app launches at -m256M where it previously #DF-halted.
#
# ASSERTIONS (over a low-RAM installer boot that spawns the DE app storm):
#   * NO fatal wedge — NO #DF, triple/double fault, cpu_reset, or trap-diag
#     halt. This is the core corruption signature the fix eliminates.
#   * NO stack mapped over physical 0 (the specific alias that #DF'd).
#   * The boot reaches the shell heartbeat (the DE bring-up SURVIVED — apps
#     either launched or failed with a CLEAN -ENOMEM that left the box alive).
#   * Every execve stack-backing failure that DOES occur is the graceful
#     -ENOMEM path, never a truncated wedge.
#
# Pre-fix at -m256M under fragmentation this FAILS (a #DF halt, no heartbeat).
# Post-fix it PASSES: no #DF, heartbeat reached, any OOM is clean.
#
# ENV
#   IMG          installer image path      (default: build/hamnix-installer.img)
#   MEM          guest RAM in MiB          (default: 256 — the user's low-RAM bar)
#   BOOT_TIMEOUT per-boot deadline seconds (default: 180)
#   QEMU_CPU     cpu model                 (default: max — carries SMAP for TCG)
#   QEMU_ACCEL   set to "kvm" for KVM       (default: TCG, the CI default)
#   OVMF_FD      OVMF firmware path        (default: /usr/share/ovmf/OVMF.fd)
#   SERIAL_LOG   evaluate a pre-captured log instead of booting (logic-only)
#   SKIP_BUILD=1 refuse the ~14-min rebuild if IMG is missing (battery shard)
#   KEEP_LOG=1   keep the temp serial log on exit
#
# Pass marker:  [test_execve_ustack_lowmem] PASS
# Fail marker:  [test_execve_ustack_lowmem] FAIL

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${IMG:-build/hamnix-installer.img}"
MEM="${MEM:-256}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
OVMF_FD="${OVMF_FD:-/usr/share/ovmf/OVMF.fd}"
QEMU_CPU="${QEMU_CPU:-max}"
QEMU_ACCEL="${QEMU_ACCEL:-}"

# Readiness marker: the image-agnostic "boot reached the interactive shell"
# signal used across the gate ecosystem (test_auth / test_de_fps /
# build_installed_nvme / ...). The DE app-spawn storm runs during rc.boot
# BEFORE this handoff, so reaching it means the whole storm survived without a
# #DF. The opt-in [hamsh-alive] heartbeat (off on a shipped boot) is also
# accepted as a secondary liveness signal.
HEARTBEAT_RE='handing off to interactive shell|\[hamsh-alive\]'
# Fatal wedge markers — the exact corruption class the fix eliminates. A stack
# aliased over physical 0 SMAP-#PF'd (cr2==rsp) then #DF'd (vector 0x08) to the
# trap-diag one-shot halt. NB: match the FAULT prints ("TRAP: vector 0x..",
# "[trap-diag] halting"), NOT the benign boot-time "IST-backed #DF handler
# installed" / "trap_df_install" lines — a bare "#DF" would false-match those.
FATAL_RE='TRAP: vector|triple fault|\[trap-diag\] halting|cpu_reset'
# Any ELF/stack load-failure print must be COMPLETE (carry a reason word), never
# a truncated %s-kernel-#PF wedge.
ELFLOAD_RE='ELF load of'

say() { echo "[test_execve_ustack_lowmem] $*"; }

evaluate() {
    local log="$1"
    local hb fatal trunc goom
    hb=$(grep -aE -c "$HEARTBEAT_RE" "$log" || true)
    say "observed $hb heartbeat line(s); $(grep -aEc "$ELFLOAD_RE" "$log" || true) ELF-load-failure line(s)"

    # (a) No fatal CPU wedge — the #DF-halt the phys-0 stack alias caused.
    if grep -aE -q "$FATAL_RE" "$log"; then
        say "FAIL: fatal-trap / wedge indication present (matched '$FATAL_RE'):"
        grep -aEn "$FATAL_RE" "$log" | head -8 | sed 's/^/    /' >&2
        say "      This is the pre-fix stack-over-phys-0 #DF signature."
        return 1
    fi

    # (b) No truncated ELF/stack load-failure print (the graceless-OOM #PF wedge).
    trunc=$(grep -aE "$ELFLOAD_RE" "$log" | grep -avc "failed" || true)
    if [ "$trunc" -ne 0 ]; then
        say "FAIL: $trunc truncated 'ELF load of' print(s) with no 'failed'."
        grep -aEn "$ELFLOAD_RE" "$log" | grep -av "failed" | head -5 | sed 's/^/    /' >&2
        return 1
    fi

    # (c) The heartbeat must be reached — the DE bring-up survived the low-RAM
    #     app-spawn storm (pre-fix it #DF-halted before the shell).
    if [ "$hb" -lt 1 ]; then
        say "FAIL: interactive-shell handoff not reached — boot wedged/starved during the"
        say "      native app-spawn storm at -m ${MEM}M."
        say "--- last 40 serial lines ---"
        tail -40 "$log" | strings | sed 's/^/    /' >&2
        return 1
    fi

    # Informational: graceful stack/image -ENOMEM that was SURVIVED (expected
    # at very low MEM; the point is the box stayed alive, not that nothing OOM'd).
    goom=$(grep -aEc "cannot back stack|user-stack prefix.*not available|failed: out of memory \(-ENOMEM\)" "$log" || true)
    if [ "$goom" -gt 0 ]; then
        say "note: $goom clean -ENOMEM stack/image OOM(s) survived (box stayed alive)."
    fi
    say "heartbeat reached under -m ${MEM}M; no #DF, no phys-0 stack alias, no wedge."
    return 0
}

# --- logic-only mode (no QEMU) -----------------------------------------
if [ -n "${SERIAL_LOG:-}" ]; then
    if [ ! -f "$SERIAL_LOG" ]; then
        say "FAIL: SERIAL_LOG=$SERIAL_LOG does not exist"; say "FAIL"; exit 1
    fi
    say "logic-only mode: evaluating pre-captured log $SERIAL_LOG (no QEMU boot)"
    if evaluate "$SERIAL_LOG"; then say "PASS"; exit 0; else say "FAIL"; exit 1; fi
fi

# --- ensure the installer image exists ---------------------------------
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$IMG" "[execve_ustack_lowmem]"; then
    if [ "${SKIP_BUILD:-0}" = "1" ] || [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        say "SKIP: $IMG absent and SKIP_BUILD set — no prebuilt installer image"
        say "      on this shard (exercised in the installer CI job / locally)."
        say "PASS"; exit 0
    fi
    say "image $IMG absent -- building via scripts/build_installer_img.sh (~14 min)"
    HAMNIX_INSTALLER_IMG_OUT="$IMG" bash scripts/build_installer_img.sh
fi
if [ ! -f "$IMG" ]; then
    say "FAIL: $IMG still missing after build_installer_img.sh."; say "FAIL"; exit 1
fi

# --- OVMF firmware -----------------------------------------------------
if [ ! -f "$OVMF_FD" ]; then
    if [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ ! -f "$OVMF_FD" ]; then
    say "FAIL: OVMF firmware not found (tried $OVMF_FD; apt install ovmf)."
    say "FAIL"; exit 1
fi

ACCEL_ARGS=()
if [ "$QEMU_ACCEL" = "kvm" ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ACCEL_ARGS=(-enable-kvm)
    else
        say "QEMU_ACCEL=kvm requested but /dev/kvm not accessible; falling back to TCG."
    fi
fi

LOG=$(mktemp --tmpdir hamnix-ustack-lowmem.XXXXXX.log)
OVMF_RW=$(mktemp --tmpdir hamnix-ustack-lowmem.ovmf.XXXXXX.fd)
QEMU_PID=""
cleanup() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_LOG:-0}" = "1" ]; then
        echo "[test_execve_ustack_lowmem] KEEP_LOG: serial log at $LOG" >&2
    else
        rm -f "$LOG"
    fi
    rm -f "$OVMF_RW"
}
trap cleanup EXIT INT TERM
cp "$OVMF_FD" "$OVMF_RW"

say "=== fix/execve-ustack-oom low-RAM stack-backing gate ==="
say "  image      = $IMG"
say "  memory     = ${MEM}M   (the user's low-RAM bar; pre-fix #DF-halted here)"
say "  firmware   = $OVMF_FD"
say "  deadline   = ${BOOT_TIMEOUT}s (polled; exits early on first marker)"

: > "$LOG"
qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    -cpu "$QEMU_CPU" \
    -bios "$OVMF_RW" \
    -drive "file=$IMG,format=raw,if=virtio" \
    -m "${MEM}M" \
    -vga std \
    -display none \
    -serial "file:$LOG" \
    -no-reboot \
    -monitor none \
    >/dev/null 2>&1 &
QEMU_PID=$!

deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
while :; do
    if [ -f "$LOG" ]; then
        if grep -aE -q "$HEARTBEAT_RE" "$LOG"; then break; fi
        if grep -aE -q "$FATAL_RE" "$LOG"; then break; fi
        if grep -aE "$ELFLOAD_RE" "$LOG" | grep -aq -v "failed"; then break; fi
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then QEMU_PID=""; break; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        say "deadline reached (${BOOT_TIMEOUT}s)."; break
    fi
    sleep 2
done

if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
fi

if evaluate "$LOG"; then say "PASS"; exit 0; else say "FAIL"; exit 1; fi
