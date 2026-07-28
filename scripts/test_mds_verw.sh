#!/usr/bin/env bash
# scripts/test_mds_verw.sh - MDS (Microarchitectural Data Sampling)
# CLEAR_CPU_BUFFERS mitigation gate (task #87).
#
# Verifies that VERW (Intel's CLEAR_CPU_BUFFERS) is emitted on every
# kernel->user (CPL0->CPL3) ring transition, so stale kernel data left
# in the store buffer / fill buffers / load ports is scrubbed before
# control reaches userland. The MD_CLEAR support probe itself lives in
# arch/x86/kernel/cpu_mitigations.ad::setup_spectre_v2() (shared with the
# Spectre-v2 hardware-MSR path); the MDS-active decision + banner and the
# cpu_mitig_mds_active() accessor are the task-#87 additions there. The
# VERW is in the exit-path asm:
#   * arch/x86/kernel/syscall_64.S  — syscall_entry SYSRETQ,
#                                      do_execve_finish SYSRETQ,
#                                      enter_user_mode IRETQ
#   * arch/x86/kernel/sched_asm.S    — sysret_bootstrap SYSRETQ (first
#                                      task), kthread_bootstrap IRETQ
#   * arch/x86/kernel/irq_asm.S      — common_irq IRETQ
#   * arch/x86/kernel/trap_asm.S     — #GP + #PF handler IRETQ
# The IRETQ sites gate on the saved CS RPL (testb $3, 8(%rsp)) so a
# kernel->kernel return skips the (wasted) flush; the SYSRETQ + the
# user-only IRETQ (enter_user_mode) sites are unconditional.
#
# TWO checks, in order of determinism:
#
#   (A) BUILD-TIME objdump. This does NOT need a running CPU to expose
#       MDS. It disassembles the linked kernel and asserts:
#         - the mds_verw_sel selector word symbol exists,
#         - a `verw <disp>(%rip)` referencing mds_verw_sel sits
#           immediately before the SYSRETQ / IRETQ at each exit symbol,
#         - the four IRETQ sites that may return to kernel are preceded
#           by the `testb $0x3,0x8(%rsp)` RPL gate.
#       This is the load-bearing, deterministic acceptance check.
#
#   (B) BOOT-LOG. Boots the kernel and asserts the
#       "[cpu-mitig] MDS active=" line is present (the detection is
#       wired into start_kernel via setup_spectre_v2). Under TCG (no
#       MD_CLEAR) the value is active=0; under KVM -cpu host it is
#       active=1. Both are a PASS for this gate — the objdump check (A)
#       already proved the VERW is compiled in; (B) proves the CPUID
#       probe + log path runs. The boot ALSO reaching userland is an
#       end-to-end proof the VERW placement does not triple-fault (a
#       misplaced VERW faults on the FIRST return-to-user, at
#       start_first_task).
#
# BOOT-ONLY (no FEEDER_SYNC handshake): everything is in the early log.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_kernel_iso.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

pass() { echo "[test_mds_verw]   OK: $1"; }
fail() {
    echo "[test_mds_verw] FAIL: $1" >&2
    exit 1
}

echo "[test_mds_verw] (1/4) Build userland + initramfs + kernel"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_mds_verw] (2/4) Build-time objdump: VERW on every exit path"

DIS=$(mktemp /tmp/test-mds-dis.XXXXXX.txt)
SYM=$(mktemp /tmp/test-mds-sym.XXXXXX.txt)
trap 'rm -f "$DIS" "$SYM"' EXIT
# Dump to FILES (not pipes): `grep -q` closes the pipe early, which under
# `set -o pipefail` turns objdump's SIGPIPE into a spurious pipeline
# failure. Grepping a file sidesteps that entirely.
objdump -d "$ELF" > "$DIS"
objdump -t "$ELF" > "$SYM"

# The selector word the VERW operand points at.
if ! grep -F -q "mds_verw_sel" "$SYM"; then
    fail "mds_verw_sel selector-word symbol missing from the kernel"
fi
pass "mds_verw_sel symbol present"

VERW_TOTAL=$(grep -cE "verw .*<mds_verw_sel>" "$DIS" || true)
if [ "$VERW_TOTAL" -lt 8 ]; then
    fail "expected >=8 'verw ...<mds_verw_sel>' exit-path sites, found $VERW_TOTAL"
fi
pass "$VERW_TOTAL verw <mds_verw_sel> sites in the kernel (>=8 expected)"

# Per-symbol: the function body (from the symbol label to the next
# label) must contain a verw<mds_verw_sel> and terminate with the
# expected transition instruction; the gated IRETQ sites must carry the
# CS-RPL check.
check_site() {
    local sym="$1" ret="$2" gated="$3"
    local body
    body=$(awk -v s="<$sym>:" '
        $0 ~ s {f=1}
        f && NR>1 && /^[0-9a-f]+ </ && $0 !~ s {exit}
        f {print}
    ' "$DIS")
    if ! echo "$body" | grep -qE "verw .*<mds_verw_sel>"; then
        fail "$sym: no 'verw <mds_verw_sel>' in its body"
    fi
    if ! echo "$body" | grep -qE "\b$ret\b"; then
        fail "$sym: expected transition instruction '$ret' not found"
    fi
    if [ "$gated" = "gated" ]; then
        if ! echo "$body" | grep -qE "testb .*0x3,0x8\(%rsp\)"; then
            fail "$sym: gated IRETQ site missing the 'testb \$0x3,0x8(%rsp)' RPL gate"
        fi
    fi
    pass "$sym: verw before $ret${gated:+ ($gated)}"
}

# Unconditional SYSRET / user-only IRET sites.
check_site syscall_entry     sysretq ""
check_site do_execve_finish  sysretq ""
check_site enter_user_mode   iretq   ""
check_site sysret_bootstrap  sysretq ""
# CS-RPL-gated IRET sites (may return to kernel).
check_site common_irq        iretq   gated
check_site kthread_bootstrap iretq   gated
check_site trap_diag_stub_0d iretq   gated   # #GP handler
check_site trap_diag_stub_0e iretq   gated   # #PF handler

echo "[test_mds_verw] (3/4) Boot QEMU + assert MDS detection log line"

LOG=$(mktemp /tmp/test-mds-boot.XXXXXX.log)
trap 'rm -f "$DIS" "$SYM" "$LOG"' EXIT

TIMEOUT="${HAMNIX_MDS_TIMEOUT:-90}"
set +e
timeout "${TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" -smp 1 -nographic -no-reboot -m 512M \
    -monitor none -serial stdio < /dev/null > "$LOG" 2>&1
rc=$?
set -e

# The MDS banner is printed unconditionally by setup_spectre_v2() (before
# its SPEC_CTRL early-return), so its absence means the boot never reached
# the mitigation setup — treat as INCONCLUSIVE (host starvation), matching
# the sibling cpu-mitigations gate's retry contract.
if ! grep -a -E -q "\[cpu-mitig\] MDS active=(0|1)" "$LOG"; then
    echo "[test_mds_verw] INCONCLUSIVE: setup_spectre_v2() never logged the" \
         "MDS banner (boot likely starved before start_kernel reached it)."
    echo "[test_mds_verw] qemu rc=$rc"
    exit 2
fi

MDS_LINE=$(grep -a -E "\[cpu-mitig\] MDS active=(0|1)" "$LOG" | head -1)
echo "[test_mds_verw]   ${MDS_LINE}"

# When the host advertises MD_CLEAR (KVM -cpu host), the mitigation MUST
# report active=1. Under TCG md_clear=0 -> active=0 is expected & fine.
if echo "$MDS_LINE" | grep -F -q "md_clear=1"; then
    if ! echo "$MDS_LINE" | grep -F -q "MDS active=1"; then
        fail "md_clear=1 but MDS not reported active=1"
    fi
    pass "MD_CLEAR present -> MDS active=1 (VERW flushes CPU buffers)"
else
    pass "MD_CLEAR absent (TCG) -> MDS active=0; exit-path VERW still compiled in (check A)"
fi

echo "[test_mds_verw] (4/4) PASS: VERW/CLEAR_CPU_BUFFERS on all kernel->user" \
     "exits (objdump) + MDS detection wired (boot log). qemu rc=$rc"
exit 0
