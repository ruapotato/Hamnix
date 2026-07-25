#!/usr/bin/env bash
# scripts/test_installer_boot_heartbeat.sh - INSTALLER-IMAGE BOOT GATE.
#
# PURPOSE (the orchestrator's pre-push gate)
# ------------------------------------------
# This is the boot SMOKE TEST the orchestrator runs as a GATE before
# pushing anything to main. The user asked, verbatim, for "a test that
# looks for the heartbeat of the ham shell as a gate on whether or not
# you push something." That is exactly this script.
#
# It boots the production installer image (build/hamnix-installer.img)
# under OVMF+TCG single-CPU and PASSES only if the hamsh idle heartbeat
# line "[hamsh-alive]" reaches the serial console AND no fatal-trap
# indication (TRAP: vector / triple fault / double fault / cpu_reset)
# appears. The heartbeat is emitted ~every 3s from hamsh's ed_readline
# idle poll (user/hamsh.ad _hb_emit_to_stderr, ~line 7270); seeing it
# proves SYSRET into ring-3 worked AND the shell keeps getting scheduled
# across timer IRQs from userspace.
#
# Why an installer-image boot specifically: scripts/test_hamsh_heartbeat.sh
# boots a -kernel ELF directly and never exercises the full OVMF -> EFI
# stub -> kernel -> userspace-IRQ path. Boot regression #402 (per-CPU
# TSS/GDT/MSR) triple-faulted at the FIRST timer IRQ from userspace
# (#UD->#GP->#DF->cpu_reset) so NO heartbeat ever appeared on the
# installer image, yet the direct-kernel heartbeat test could not see it.
# That regression reached main because there was no installer-boot gate.
# This script is that gate.
#
# HOW THE ORCHESTRATOR INVOKES IT AS A PUSH GATE
# ----------------------------------------------
#   # Build once, then gate against the fresh image before pushing:
#   bash scripts/build_installer_img.sh                # ~14 min, Stage 1
#   bash scripts/test_installer_boot_heartbeat.sh && git push   # gate
#
#   # Or point it at an already-built image and skip the 14-min rebuild:
#   SKIP_BUILD=1 IMG=build/hamnix-installer.img \
#       bash scripts/test_installer_boot_heartbeat.sh && git push
#
# Exit code is 0 on PASS, non-zero on FAIL, so `&& git push` is the gate.
#
# Env overrides
# -------------
#   IMG          installer image path     (default: build/hamnix-installer.img)
#   SKIP_BUILD=1 do NOT (re)build the image even if missing/stale; fail
#                instead if IMG is absent. Lets the orchestrator gate a
#                pre-built image without paying the ~14-min Stage-1 cost.
#   BOOT_TIMEOUT deadline seconds for the heartbeat to appear (default 180).
#                The boot is slow under TCG; the script polls and exits as
#                soon as the marker is seen, so this is only an upper bound.
#                Under pure TCG (CI, no KVM) the live-distro squashfs stream
#                pushes the heartbeat to ~830s, so CI sets this to ~1200.
#   QEMU_CPU     QEMU -cpu model (default: max). MUST expose SMAP, because
#                syscall_entry uses stac/clac — the default TCG cpu (qemu64)
#                #UDs on them and the first syscall triple-faults under TCG.
#                `max` carries SMAP under both TCG and KVM.
#   RETRIES      number of boots to attempt before FAIL (default 1). CI
#                sets 3 to ride out the intermittent DE-bringup trap-diag
#                halt under TCG (see the RETRIES comment in-body). A truly
#                non-booting image fails every attempt, so retries never
#                hide the boot-path regression this gate guards.
#   OVMF_FD      OVMF firmware path       (default: /usr/share/ovmf/OVMF.fd)
#   SERIAL_LOG   pre-captured serial log to evaluate INSTEAD of booting
#                (logic-only mode for CI/dev: feed a known-good or
#                known-broken log and assert the PASS/FAIL verdict without
#                spinning QEMU). When set, no QEMU is launched.
#   KEEP_LOG=1   keep the temp serial log on exit (debugging).
#
# Pass marker:  [test_installer_boot_heartbeat] PASS
# Fail marker:  [test_installer_boot_heartbeat] FAIL

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${IMG:-build/hamnix-installer.img}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
OVMF_FD="${OVMF_FD:-/usr/share/ovmf/OVMF.fd}"
# CPU model. The kernel's syscall_entry uses SMAP (stac/clac, opcode
# 0f 01 cb). QEMU's DEFAULT TCG cpu (qemu64) does NOT expose SMAP/SMEP,
# so those instructions raise #UD and the first syscall triple-faults —
# a #UD at syscall_entry that ONLY happens under TCG, never under
# `-cpu host` (KVM). CI runs pure TCG (no /dev/kvm), so we must request a
# cpu model that carries SMAP. `-cpu max` exposes the full feature set and
# is valid under both TCG and KVM, so the same line works locally and in CI.
QEMU_CPU="${QEMU_CPU:-max}"

# Accelerator. DEFAULT is TCG (empty QEMU_ACCEL) so CI — which has no
# /dev/kvm — is unchanged and the same command boots everywhere. Local
# runs on a KVM-capable host can export QEMU_ACCEL=kvm for a ~10x faster,
# deadline-proof boot (the native-compiled kernel executes more insns than
# the seed build, so under pure TCG it crosses [hamsh-alive] only just
# before a 180s poll — a chronic local false-FAIL). NOTE: KVM is far faster
# but can MASK TCG-only timing bugs (e.g. the #413 steal-window race), so it
# is opt-in for liveness checks, never the CI default.
QEMU_ACCEL="${QEMU_ACCEL:-}"
ACCEL_ARGS=()
if [ "$QEMU_ACCEL" = "kvm" ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ACCEL_ARGS=(-enable-kvm)
    else
        echo "[test_installer_boot_heartbeat] QEMU_ACCEL=kvm requested but /dev/kvm not accessible; falling back to TCG." >&2
    fi
fi

# The liveness marker we require, and the fatal-trap markers we reject.
HEARTBEAT_RE='\[hamsh-alive\]'
# A fatal first-IRQ-from-userspace triple-fault (regression #402) surfaces
# as a "TRAP: vector 0xNN" print from the trap handler and/or the firmware
# resetting the CPU. Any of these means the boot died, even if a stale
# heartbeat fragment somehow appeared.
#
# "[trap-diag] halting" is the one-shot fault diagnostic in
# arch/x86/kernel/trap_diag.ad: an unrecoverable fault (e.g. an unresolved
# user #PF whose SIGSEGV could not be delivered) does `cli; hlt` with NO
# recovery — it wedges the WHOLE CPU, so the heartbeat can never follow.
# Treat it as fatal so the poll loop below breaks out the instant it
# appears instead of burning the full BOOT_TIMEOUT waiting for a heartbeat
# that will never come.
FATAL_RE='TRAP: vector|triple fault|double fault|cpu_reset|#DF|\[trap-diag\] halting'

say() { echo "[test_installer_boot_heartbeat] $*"; }

# --- evaluate(): the PASS/FAIL verdict over a serial log --------------
# Shared by both the live-boot path and the SERIAL_LOG logic-only path so
# the gate logic is asserted identically either way. Returns 0=PASS,1=FAIL.
evaluate() {
    local log="$1"
    local hb fatal
    hb=$(grep -aE -c "$HEARTBEAT_RE" "$log" || true)
    say "observed $hb heartbeat line(s) matching '$HEARTBEAT_RE'"

    if grep -aE -q "$FATAL_RE" "$log"; then
        fatal=1
    else
        fatal=0
    fi

    if [ "$fatal" -ne 0 ]; then
        say "FAIL: fatal-trap indication present (matched '$FATAL_RE') --"
        say "      this is the regression #402 signature (first timer IRQ"
        say "      from userspace -> #UD->#GP->#DF->cpu_reset). Offending lines:"
        grep -aEn "$FATAL_RE" "$log" | head -8 | sed 's/^/    /' >&2
        return 1
    fi

    if [ "$hb" -lt 1 ]; then
        say "FAIL: no '[hamsh-alive]' heartbeat reached the serial console"
        say "      within the boot window. The shell never got scheduled"
        say "      after SYSRET into ring-3 (boot wedged or starved)."
        say "--- last 40 serial lines ---"
        tail -40 "$log" | strings | sed 's/^/    /' >&2
        return 1
    fi

    say "heartbeat present and no fatal trap detected."
    return 0
}

# --- logic-only mode: evaluate a pre-captured serial log, no QEMU -----
if [ -n "${SERIAL_LOG:-}" ]; then
    if [ ! -f "$SERIAL_LOG" ]; then
        say "FAIL: SERIAL_LOG=$SERIAL_LOG does not exist"
        say "FAIL"
        exit 1
    fi
    say "logic-only mode: evaluating pre-captured log $SERIAL_LOG (no QEMU boot)"
    if evaluate "$SERIAL_LOG"; then
        say "PASS"
        exit 0
    else
        say "FAIL"
        exit 1
    fi
fi

# --- ensure the installer image exists (build it unless SKIP_BUILD) ---
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$IMG" "[installer_boot_heartbeat]"; then
    if [ "${SKIP_BUILD:-0}" = "1" ]; then
        say "FAIL: $IMG missing and SKIP_BUILD=1 (refusing the ~14-min rebuild)."
        say "FAIL"
        exit 1
    fi
    say "image $IMG absent -- building via scripts/build_installer_img.sh (~14 min)"
    # The [hamsh-alive] heartbeat this gate keys on is OPT-IN — off on a
    # normal shipped boot so the interactive console stays clean. Build the
    # gate image with ENABLE_HAMSH_HEARTBEAT=1 so build_initramfs.py (invoked
    # by build_installer_img.sh) plants the /etc/hamsh-heartbeat marker that
    # arms it. NOTE: a SKIP_BUILD run against a pre-existing image REQUIRES
    # that image to have been built with this flag, otherwise the heartbeat is
    # (correctly) absent and this gate FAILs — rebuild via this script.
    HAMNIX_INSTALLER_IMG_OUT="$IMG" ENABLE_HAMSH_HEARTBEAT=1 \
        bash scripts/build_installer_img.sh
fi
if [ ! -f "$IMG" ]; then
    say "FAIL: $IMG still missing after build_installer_img.sh."
    say "FAIL"
    exit 1
fi

# --- OVMF firmware (writable copy: UEFI persists vars into the image) --
if [ ! -f "$OVMF_FD" ]; then
    if [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ ! -f "$OVMF_FD" ]; then
    say "FAIL: OVMF firmware not found (tried $OVMF_FD; apt install ovmf)."
    say "FAIL"
    exit 1
fi

LOG=$(mktemp --tmpdir hamnix-installer-heartbeat.XXXXXX.log)
OVMF_RW=$(mktemp --tmpdir hamnix-installer-heartbeat.ovmf.XXXXXX.fd)
QEMU_PID=""
cleanup() {
    # Kill QEMU on every exit path (success, failure, signal).
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_LOG:-0}" = "1" ]; then
        echo "[test_installer_boot_heartbeat] KEEP_LOG: serial log at $LOG" >&2
    else
        rm -f "$LOG"
    fi
    rm -f "$OVMF_RW"
}
trap cleanup EXIT INT TERM
cp "$OVMF_FD" "$OVMF_RW"

# --- boot_once(): one OVMF+TCG boot, polled to the first marker --------
# Boots the image once, serial -> $LOG (truncated first), and returns
#   0 = heartbeat seen (PASS)
#   1 = a FATAL_RE marker seen (incl. the unrecoverable trap-diag halt)
#   2 = neither — QEMU died early or the deadline elapsed (no heartbeat)
# It tears its own QEMU down before returning so the caller can retry.
boot_once() {
    : > "$LOG"
    qemu-system-x86_64 \
        "${ACCEL_ARGS[@]}" \
        -cpu "$QEMU_CPU" \
        -bios "$OVMF_RW" \
        -drive "file=$IMG,format=raw,if=virtio" \
        -m 1G \
        -vga std \
        -display none \
        -serial "file:$LOG" \
        -no-reboot \
        -monitor none \
        >/dev/null 2>&1 &
    QEMU_PID=$!

    # Poll the serial log until heartbeat, a fatal marker, QEMU exit, or
    # the boot deadline. Exits early on the first marker.
    local deadline rc
    deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
    rc=2
    while :; do
        if [ -f "$LOG" ]; then
            if grep -aE -q "$HEARTBEAT_RE" "$LOG"; then rc=0; break; fi
            # Fast-fail the instant a fatal marker (e.g. "[trap-diag]
            # halting") appears — the CPU is wedged, the heartbeat will
            # never come, so don't burn the rest of BOOT_TIMEOUT.
            if grep -aE -q "$FATAL_RE" "$LOG"; then rc=1; break; fi
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then QEMU_PID=""; rc=2; break; fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            say "deadline reached (${BOOT_TIMEOUT}s) without a heartbeat."
            rc=2; break
        fi
        sleep 2
    done

    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
    return "$rc"
}

# RETRIES: how many boots to attempt before declaring FAIL (default 1).
#
# WHY RETRIES EXIST. The installer image boots straight to the GRAPHICAL
# runlevel (rc.boot.full `init 5`), so the whole hamUI desktop stack comes
# up alongside hamsh. Under pure TCG that DE bringup INTERMITTENTLY trips
# an unrecoverable fault — a user-mode #PF whose SIGSEGV can't be delivered
# routes into arch/x86/kernel/trap_diag.ad's one-shot "[trap-diag] halting"
# (cli;hlt, no recovery) and wedges the box before hamsh's heartbeat. This
# is a REAL latent kernel/DE bug (orthogonal to the boot path this gate
# guards), reproducing ~1-in-3 boots under TCG, and is NOT something this
# test should mask away by editing the kernel.
#
# A genuinely non-booting image (the regression class this gate exists for,
# e.g. #402's first-timer-IRQ triple-fault BEFORE any userspace) fails
# EVERY attempt, so retries never hide it. The flaky DE fault, being
# ~1/3 and independent per boot, is retried past: RETRIES=3 leaves a
# ~(1/3)^3 ≈ 4% residual flake. Each bad attempt fast-fails at the halt
# (no full-timeout wait), so the retries are bounded.
RETRIES="${RETRIES:-1}"

say "=== installer boot heartbeat gate ==="
say "  image      = $IMG"
say "  firmware   = $OVMF_FD"
say "  heartbeat  = '$HEARTBEAT_RE'   (must appear)"
say "  fatal      = '$FATAL_RE'   (must NOT appear)"
say "  deadline   = ${BOOT_TIMEOUT}s/attempt (polled; exits early on first marker)"
say "  attempts   = up to $RETRIES (retry only the intermittent DE-bringup fault)"

attempt=1
last_rc=2
while [ "$attempt" -le "$RETRIES" ]; do
    say "--- boot attempt $attempt/$RETRIES ---"
    # `set -e` is active: a non-zero return from boot_once (rc 1/2 = a
    # failed attempt we WANT to retry) must not abort the script, so
    # capture it without letting -e fire.
    last_rc=0
    boot_once || last_rc=$?
    if [ "$last_rc" -eq 0 ]; then
        say "boot attempt $attempt: heartbeat observed."
        if evaluate "$LOG"; then
            say "PASS"
            exit 0
        fi
        # evaluate() disagreeing with rc=0 would mean a fatal marker AND a
        # heartbeat in the same log — treat as a failed attempt and retry.
        say "boot attempt $attempt: heartbeat present but evaluate() rejected it; retrying."
    elif [ "$last_rc" -eq 1 ]; then
        say "boot attempt $attempt: FATAL marker (e.g. trap-diag halt) — intermittent DE-bringup fault; retrying."
        grep -aEn "$FATAL_RE" "$LOG" | head -4 | sed 's/^/    /' >&2
    else
        say "boot attempt $attempt: no heartbeat within the deadline; retrying."
    fi
    attempt=$(( attempt + 1 ))
done

say "all $RETRIES boot attempt(s) failed to reach the heartbeat."
# Surface the verdict over the LAST attempt's log for the post-mortem.
evaluate "$LOG" || true
say "FAIL"
exit 1
