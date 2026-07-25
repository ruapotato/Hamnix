#!/usr/bin/env bash
# scripts/test_installer_oom_reclaim.sh — #106 native app-spawn memory-reclaim
# + graceful-OOM regression gate.
#
# WHAT THIS GUARDS
# ----------------
# During DE bring-up the desktop launches ~28 native ELF apps. Two coupled
# bugs (found by the KVM real-HW-fidelity QA sweep) turned a MEMORY-pressured
# boot into a hard CPU wedge:
#
#   1. LEAK. Each native ELF load carves one large CONTIGUOUS physical region
#      (fs/elf.ad region_alloc, ~16-19 MiB). The reclaim pool keyed those
#      regions by EXACT byte size, but every app's image span differs by a few
#      KiB, so a freed 16.79 MiB region could never back the next 16.97 MiB
#      request. region_alloc cold-missed into the ONE-WAY memblock bump cursor
#      every time — physical use climbed monotonically toward the RAM ceiling
#      until memblock_alloc returned 0. (mm/page_alloc.ad now uses an
#      address-sorted, coalescing, first-fit-with-split free list: ANY freed
#      region backs ANY later request <= its size, so spawn->exit->reap is
#      net-neutral and the climb plateaus.)
#
#   2. GRACELESS OOM. When region_alloc failed, fs/elf.ad printed a truncated
#      `elf: OOM` and execve's failure print dereferenced the RAW USER path
#      pointer via %s — but execve had already torn the caller's address space
#      down (vma_clear), so that pointer was unmapped and printk's %s walk
#      KERNEL-#PF'd, wedging the CPU mid-print (`execve: ELF load of '` with no
#      newline, no heartbeat ever). Fixed to log the kernel path copy and
#      return -ENOMEM cleanly, so one app's OOM no longer takes the boot down.
#
# Pre-fix this gate FAILS (no `[hamsh-alive]`, and/or a truncated
# `ELF load of` print, and/or a fatal trap). Post-fix it PASSES: the boot
# reaches the shell heartbeat under memory pressure, and any OOM that does
# occur is a COMPLETE, graceful `-ENOMEM` — never a truncated wedge.
#
# CONSTRAINED MEMORY. Default -m 768M: the task's canonical regression size —
# ~650 MiB free at boot, yet the exact-size-bucket leak still OOM-wedged it.
# Override with MEM=<MiB>. At 768M the leak fix frees enough that no app OOMs;
# a smaller MEM (e.g. 640) additionally exercises the graceful-OOM path (some
# apps legitimately can't fit) while still reaching the heartbeat.
#
# ENV
#   IMG          installer image path      (default: build/hamnix-installer.img)
#   MEM          guest RAM in MiB           (default: 768)
#   BOOT_TIMEOUT per-boot deadline seconds  (default: 180)
#   QEMU_CPU     cpu model                  (default: max — carries SMAP for TCG)
#   QEMU_ACCEL   set to "kvm" for KVM        (default: TCG, the CI default)
#   OVMF_FD      OVMF firmware path         (default: /usr/share/ovmf/OVMF.fd)
#   SERIAL_LOG   evaluate a pre-captured log instead of booting (logic-only)
#   SKIP_BUILD=1 refuse the ~14-min rebuild if IMG is missing
#   KEEP_LOG=1   keep the temp serial log on exit
#
# Pass marker:  [test_installer_oom_reclaim] PASS
# Fail marker:  [test_installer_oom_reclaim] FAIL

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${IMG:-build/hamnix-installer.img}"
MEM="${MEM:-768}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
OVMF_FD="${OVMF_FD:-/usr/share/ovmf/OVMF.fd}"
QEMU_CPU="${QEMU_CPU:-max}"
QEMU_ACCEL="${QEMU_ACCEL:-}"

HEARTBEAT_RE='\[hamsh-alive\]'
# Fatal wedge markers: a triple/double-fault reset, or the one-shot
# unrecoverable trap-diag halt (cli;hlt — the CPU is dead, no heartbeat can
# follow). The #106 graceless-OOM wedge surfaced as a trap-diag halt after a
# truncated OOM print.
FATAL_RE='TRAP: vector|triple fault|double fault|cpu_reset|#DF|\[trap-diag\] halting'
# Truncated-OOM signature: `execve: ELF load of '<path>` that KERNEL-#PF'd
# mid-%s so the line never reached its `failed` word (the #106 wedge). Post-fix
# every ELF-load-failure print is complete and contains `failed`. modload's
# `modload: ELF load of '%s' failed` also matches `ELF load of` but always
# carries `failed`, so requiring `failed` on every such line is exact.
ELFLOAD_RE='ELF load of'

say() { echo "[test_installer_oom_reclaim] $*"; }

# --- evaluate(): PASS/FAIL verdict over a serial log -------------------
evaluate() {
    local log="$1"
    local hb fatal trunc
    hb=$(grep -aE -c "$HEARTBEAT_RE" "$log" || true)
    say "observed $hb heartbeat line(s); $(grep -aEc "$ELFLOAD_RE" "$log" || true) ELF-load-failure line(s)"

    # (a) A truncated / incomplete ELF-load-failure print = the graceless-OOM
    #     kernel #PF wedge. Every `ELF load of` line MUST contain `failed`.
    trunc=$(grep -aE "$ELFLOAD_RE" "$log" | grep -avc "failed" || true)
    if [ "$trunc" -ne 0 ]; then
        say "FAIL: $trunc truncated 'ELF load of' print(s) with no 'failed' —"
        say "      the #106 graceless-OOM wedge (printk %s kernel-#PF'd on the"
        say "      torn-down user path pointer). Offending lines:"
        grep -aEn "$ELFLOAD_RE" "$log" | grep -av "failed" | head -5 | sed 's/^/    /' >&2
        return 1
    fi

    # (b) No fatal CPU wedge.
    if grep -aE -q "$FATAL_RE" "$log"; then
        say "FAIL: fatal-trap / wedge indication present (matched '$FATAL_RE'):"
        grep -aEn "$FATAL_RE" "$log" | head -6 | sed 's/^/    /' >&2
        return 1
    fi

    # (c) The heartbeat must be reached — the boot survived the app storm
    #     under memory pressure (pre-fix the leak OOM-wedged it here).
    if [ "$hb" -lt 1 ]; then
        say "FAIL: no '[hamsh-alive]' heartbeat — boot wedged/starved during the"
        say "      native app-spawn storm (the #106 monotonic memblock leak)."
        say "--- last 40 serial lines ---"
        tail -40 "$log" | strings | sed 's/^/    /' >&2
        return 1
    fi

    # Informational: report graceful OOMs that were survived (not required —
    # whether any app OOMs depends on MEM vs the DE working set).
    local goom
    goom=$(grep -aEc "failed: out of memory \(-ENOMEM\)" "$log" || true)
    if [ "$goom" -gt 0 ]; then
        say "note: $goom app(s) hit a GRACEFUL -ENOMEM OOM and the boot survived."
    fi
    say "heartbeat reached under -m ${MEM}M pressure; no truncated OOM, no wedge."
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
# On a battery shard with no prebuilt image, SKIP cleanly (the full image
# build + OVMF boot runs in the installer CI job / locally) — exactly the
# HAMNIX_SKIP_BUILD=1 / SKIP_BUILD=1 pattern the sibling installer gates use.
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$IMG" "[installer_oom_reclaim]"; then
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

LOG=$(mktemp --tmpdir hamnix-oom-reclaim.XXXXXX.log)
OVMF_RW=$(mktemp --tmpdir hamnix-oom-reclaim.ovmf.XXXXXX.fd)
QEMU_PID=""
cleanup() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_LOG:-0}" = "1" ]; then
        echo "[test_installer_oom_reclaim] KEEP_LOG: serial log at $LOG" >&2
    else
        rm -f "$LOG"
    fi
    rm -f "$OVMF_RW"
}
trap cleanup EXIT INT TERM
cp "$OVMF_FD" "$OVMF_RW"

say "=== #106 OOM-reclaim / graceful-degrade gate ==="
say "  image      = $IMG"
say "  memory     = ${MEM}M   (constrained: pre-fix the leak OOM-wedged here)"
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
        # Fast-fail on a wedge (truncated OOM print or trap-diag halt).
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
