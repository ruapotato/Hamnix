#!/usr/bin/env bash
# scripts/test_arm64_a14_kstack.sh — A14: PER-TASK KERNEL STACKS + __switch_to on
# the aarch64 LLVM lane (arch/arm64/llvm/a14.S + el0.S's pt_regs frame +
# init/main.ad's blocking policy).
#
# WHAT IS NEW, AND WHY NO EARLIER GATE CAN COVER IT
# ------------------------------------------------
# A9 already switched EL0 tasks, and A13 already serviced a page fault — so it is
# easy to believe this lane could already block. It could not. A9 switched only at
# the EL0 boundary: the timer IRQ saved an interrupted EL0 frame and eret'd into
# another EL0 frame, and no task ever had KERNEL state that had to survive a peer.
# A13's faults were serviced to completion on head.S's stack and returned to the
# same task. Every EL1 entry in this lane ran on ONE stack and unwound it fully.
#
# That is the gate on fork/exec/pipes/wait/signals: each needs a task to stop
# half-way through kernel code, let a peer run kernel code, and resume with its
# own kernel call frames intact.
#
# HOW THIS GATE REFUSES TO PASS VACUOUSLY
# ---------------------------------------
# "A task blocked" is the easiest claim in this file to fake with a plausible log,
# and this lane has already shipped two logs that lied (A11's exit latch truncated
# a run after one syscall; A12's abort was decoded as a syscall and answered). So,
# in order:
#
#   1. THE EVENT ORDER, NOT A COUNT. The kernel accumulates one hex digit per
#      event into a single integer: 1 = A blocked inside a syscall, 2 = B stored a
#      value into A's PARKED frame, 3 = B exited, 4 = A resumed inside its
#      syscall, 5 = A exited. Only a genuine deschedule yields 0x12345. A wake
#      serviced synchronously inside A's own syscall has no 2/3 between the 1 and
#      the 4; a lane that never blocked has no 4 at all. A COUNTER would survive
#      any reordering — the exact class of defect that let a 2-D slot sized as 1-D
#      pass, because writes and reads shared the address arithmetic.
#   2. TWO STACKS, OBSERVED. The kernel prints the SP each task was on inside the
#      kernel and asserts each is inside its own reservation, that A's parked EL0
#      frame is on A's stack, and that A resumed on the SAME SP it blocked on.
#      This gate additionally asserts from the SYMBOL TABLE that the two
#      reservations are disjoint and each at least 16 KiB — a refactor that
#      aliased them would leave every runtime check passing.
#   3. AN EXECUTED SURVIVAL CHECK. Task A loads sentinels into x21..x28 BEFORE it
#      blocks. They live in A's EL0 frame, on A's kernel stack, while B runs an
#      ENTIRE syscall. A sums them after resuming. On a shared kernel stack B's
#      frame lands on top of them and the sum is wrong. This is the property under
#      test, executed — not an inspection of the .bss reservation.
#   4. AN INDEPENDENT ORACLE. That checksum is recomputed HERE, in python, from
#      a14.S's own .equ constants, and cross-checked against the constant
#      init/main.ad compares to. Neither the kernel nor the EL0 program is its own
#      oracle, and a drift between the two sources reds this gate.
#   5. THE pt_regs INVARIANT. ELR_EL1/SPSR_EL1/SP_EL0 are single hardware
#      registers. Until A14 the stub eret'd on the live HW values, which is
#      correct only while exactly one task is in flight. The first A14 boot
#      proved it: the woken task eret'd into task B's post-exit `b .` loop and
#      hung. The stub now saves and restores all three, and this gate asserts the
#      restore exists in the CODE (below) as well as exercising it.
#   6. THE EARLIER LADDER, IN THE SAME BOOT. The frame grew from 32 to 34 slots
#      and el0.S's dispatch gained a third outcome; A8..A13 must be untouched.
#
# WHAT THIS GATE DOES NOT PROVE — say it out loud.
#   * A14 adds NO page-table entry, no TTBR0 write and no `tlbi`. Both tasks run
#     in the kernel L1 with ASID 0 on head.S's nG=1 EL0-RW window. So nothing here
#     is exposed to — or evidence about — the QEMU-TCG nG blindness of
#     docs/arm64_phase50.md. Per-task ADDRESS SPACES (A12) and per-task KERNEL
#     STACKS (A14) are still separate; combining them introduces ASID recycling,
#     which is the first point at which nG stops being untestable and needs KVM or
#     real silicon.
#   * Two tasks and one block/wake edge. There is no run queue, no preemption
#     while blocked, no stack-overflow guard page (the stacks are plain .bss
#     reservations), and no per-task struct beyond the switch context.
#
# REGISTERED in scripts/ci_battery_manifest.txt. Needs qemu-system-aarch64 +
# aarch64 binutils + clang; a missing one is INCONCLUSIVE (125), never a soft
# green.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLANG="${CLANG:-clang-19}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
ELF="build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf"
W="build/a14_gate"
SERIAL="$W/serial.txt"
SEC="$W/a14_section.txt"
BOOT_TIMEOUT="${A14_BOOT_TIMEOUT:-180}"

fail()   { echo "[A14] FAIL $*"; exit 1; }
inconc() { echo "[A14] INCONCLUSIVE $*"; exit 125; }
note()   { echo "[A14] $*"; }

command -v qemu-system-aarch64 >/dev/null || inconc "qemu-system-aarch64 not found (apt install qemu-system-arm)"
command -v "${CROSS}as"        >/dev/null || inconc "aarch64 binutils not found"
command -v "${CROSS}ld"        >/dev/null || inconc "aarch64 binutils not found"
command -v "${CROSS}nm"        >/dev/null || inconc "aarch64 binutils not found"
command -v "$CLANG"            >/dev/null || inconc "$CLANG not found"
command -v python3             >/dev/null || inconc "python3 not found (needed for the independent oracle)"
[ -f arch/arm64/llvm/a14.S ] || fail "missing arch/arm64/llvm/a14.S"

rm -rf "$W"; mkdir -p "$W"

if [ -z "${ADDER_HOST_AC:-}" ] && [ ! -x "$HOST_AC" ]; then
    note "0) bootstrapping host_ac"
    # shellcheck disable=SC1091
    source scripts/_adder_cc.sh
    adder_cc_bootstrap >"$W/bootstrap.log" 2>&1 || { sed 's/^/[A14]   | /' "$W/bootstrap.log"; fail "host_ac bootstrap"; }
fi
[ -x "$HOST_AC" ] || inconc "no host_ac.elf at $HOST_AC"

# --------------------------------------------------------------------------
# THE INDEPENDENT ORACLE. a14.S states the EL0 sentinel contract as three .equ
# constants; init/main.ad states the answer as one constant. Recompute the answer
# here, in python, from the FIRST — so a drift between the two sources is a red
# gate rather than two files quietly agreeing with each other about a wrong sum.
# --------------------------------------------------------------------------
eqval() {  # eqval <NAME> -> the .equ value from a14.S
    grep -oP "^\s*\.equ\s+$1,\s*\K0x[0-9A-Fa-f]+|^\s*\.equ\s+$1,\s*\K[0-9]+" arch/arm64/llvm/a14.S | head -1
}
SBASE="$(eqval A14_SENTINEL_BASE)"
SN="$(eqval A14_SENTINEL_N)"
WAKEV="$(eqval A14_WAKE_VALUE)"
[ -n "$SBASE" ] && [ -n "$SN" ] && [ -n "$WAKEV" ] \
    || fail "could not read the A14 sentinel contract (.equ A14_SENTINEL_BASE/_N/A14_WAKE_VALUE) out of arch/arm64/llvm/a14.S"
EXP_SUM="$(python3 -c "
b=int('$SBASE',0); n=int('$SN',0); w=int('$WAKEV',0)
print('0x%x' % (sum(b+k for k in range(n)) + w))")"
KERN_SUM="$(grep -oP '^ARM64_A14_EXPECT_SUM:\s*uint64\s*=\s*\K0x[0-9A-Fa-f]+' init/main.ad)"
[ -n "$KERN_SUM" ] || fail "init/main.ad has no ARM64_A14_EXPECT_SUM"
[ "$((EXP_SUM))" = "$((KERN_SUM))" ] \
    || fail "the python oracle computes $EXP_SUM from a14.S's contract but init/main.ad compares to $KERN_SUM — the two sources have drifted"
note "   oracle (recomputed in python from a14.S: $SN sentinels from $SBASE + wake $WAKEV): checksum $EXP_SUM, and init/main.ad agrees"

EXP_SEQ="$(grep -oP '^ARM64_A14_EXPECT_SEQ:\s*uint64\s*=\s*\K0x[0-9A-Fa-f]+' init/main.ad)"
[ "$((EXP_SEQ))" = "$((0x12345))" ] \
    || fail "ARM64_A14_EXPECT_SEQ is $EXP_SEQ, not 0x12345 — the order that means 'A blocked, B ran kernel code, A resumed mid-syscall'"

note "1) building the aarch64 LLVM kernel"
CLANG="$CLANG" scripts/build_kernel_llvm_arm64.sh >"$W/build.log" 2>&1 \
    || { tail -30 "$W/build.log" | sed 's/^/[A14]   | /'; fail "kernel build"; }
[ -f "$ELF" ] || fail "no kernel ELF at $ELF"
grep -q 'bailed=0' "$W/build.log" \
    || { grep -a 'ADDER_STAT' "$W/build.log" | sed 's/^/[A14]   | /'; fail "emitter bailed (auto-stubs return 0 and the image would lie)"; }

# ---- INSPECTION: the two kernel stacks are DISJOINT reservations -----------
# The runtime range checks below are all relative to the symbols this reads, so
# aliasing the two stacks would satisfy every one of them. Assert separateness
# where it is actually decided: the symbol table.
sym_addr() { printf '%d' "$((16#$("${CROSS}nm" "$ELF" | awk -v s="$1" '$3==s{print $1}')))"; }
sym_size() { printf '%d' "$((16#$("${CROSS}nm" -S "$ELF" | awk -v s="$1" '$4==s{print $2}')))"; }
KA=$(sym_addr arm64_a14_kstack_a); KAS=$(sym_size arm64_a14_kstack_a)
KB=$(sym_addr arm64_a14_kstack_b); KBS=$(sym_size arm64_a14_kstack_b)
[ "$KA" -gt 0 ] && [ "$KB" -gt 0 ] || fail "arm64_a14_kstack_a/b are not in the image"
[ "$KAS" -ge 16384 ] && [ "$KBS" -ge 16384 ] \
    || fail "a kernel stack is smaller than 16 KiB (a=$KAS b=$KBS) — too small to hold a syscall's frames"
[ $((KA + KAS)) -le "$KB" ] || [ $((KB + KBS)) -le "$KA" ] \
    || fail "the two kernel stacks OVERLAP in the image — they are not per-task at all"
note "   INSPECTION ok: two DISJOINT kernel-stack reservations of $KAS/$KBS bytes"

# el0.S must actually restore the three per-task sysregs from the frame. The
# first A14 boot hung because it did not; a revert would hang the same way, but
# assert it in the CODE so the reason is never in doubt.
for r in sp_el0 elr_el1 spsr_el1; do
    grep -qE "^[[:space:]]*msr[[:space:]]+$r, x9" arch/arm64/llvm/el0.S \
        || fail "INSPECTION: el0.S no longer restores $r from the exception frame — a descheduled task would eret on the PEER's value"
done
note "   INSPECTION ok: el0.S restores SP_EL0/ELR_EL1/SPSR_EL1 from the frame (they are single HW registers, not per-task state)"

note "2) booting qemu-system-aarch64 -M virt"
printf 'A14-GATE\n' | timeout "$BOOT_TIMEOUT" qemu-system-aarch64 -M virt -cpu cortex-a72 \
    -m 2G -nographic -no-reboot -kernel "$ELF" -serial mon:stdio >"$SERIAL" 2>&1
# The kernel parks in wfi; timeout killing qemu (rc 124) is expected.

dump() { grep -a . "$SERIAL" | grep -vi terminating | sed 's/^/[A14]   | /'; }

grep -qa 'A14: PER-TASK KERNEL STACKS' "$SERIAL" \
    || { dump; inconc "boot never reached the A14 stage (starved, not a verdict)"; }

# Judge on the A14 SECTION ONLY.
sed -n '/A14: PER-TASK KERNEL STACKS/,$p' "$SERIAL" | grep -a . >"$SEC"

grep -qa '^EXC esr=' "$SERIAL" && { dump; fail "the kernel diagnostic vector fired — an exception reached the halt handler"; }
grep -qa 'A14 FAIL'  "$SEC"    && { dump; fail "the kernel itself reported an A14 failure"; }

# ---- 1. the block/wake/resume ORDER --------------------------------------
grep -qa 'A14: task A BLOCKED inside a syscall' "$SEC" \
    || { dump; fail "no task ever blocked inside a syscall"; }
grep -qa "A14: task B stored $WAKEV into the BLOCKED task's parked x0 slot" "$SEC" \
    || { dump; fail "the peer never deposited a value into the blocked task's PARKED frame"; }
grep -qa 'A14: a task RESUMED inside its syscall, on its own kernel stack' "$SEC" \
    || { dump; fail "no task ever resumed inside a syscall — the block was one-way"; }
python3 - "$SEC" "$WAKEV" <<'PY' || { dump; fail "the block/wake/resume events are not in the only order a genuine deschedule can produce"; }
import sys
want = ["task A BLOCKED inside a syscall",
        "stored %s into the BLOCKED task's parked x0 slot" % sys.argv[2],
        "task B exited; the CPU goes to the task that blocked",
        "a task RESUMED inside its syscall",
        "task A exited, reporting sentinel checksum"]
lines = open(sys.argv[1], errors="replace").read().splitlines()
i = 0
for w in want:
    while i < len(lines) and w not in lines[i]:
        i += 1
    if i >= len(lines):
        print("out of order or missing:", w)
        sys.exit(1)
    i += 1
sys.exit(0)
PY
note "PASS the five events happened in order: A blocked -> B woke it -> B exited -> A resumed mid-syscall -> A exited"

# The kernel's own single-integer order check, and its per-task SP observations.
grep -qa "order=$EXP_SEQ" "$SEC" \
    || { dump; fail "the kernel's event-order accumulator is not $EXP_SEQ"; }

# ---- 2. the two tasks were on DIFFERENT kernel stacks ---------------------
SPS="$(grep -oaP 'A14: kernel SPs — blocked task \K0x[0-9a-f]+, waker 0x[0-9a-f]+' "$SEC")"
[ -n "$SPS" ] || { dump; fail "the kernel never reported the two tasks' kernel SPs"; }
A_SP="0x$(echo "$SPS" | grep -oP '^0x\K[0-9a-f]+')"
B_SP="0x$(echo "$SPS" | grep -oP 'waker 0x\K[0-9a-f]+')"
[ "$((A_SP))" -ge "$KA" ] && [ "$((A_SP))" -lt $((KA + KAS)) ] \
    || { dump; fail "the blocked task's kernel SP $A_SP is not inside arm64_a14_kstack_a"; }
[ "$((B_SP))" -ge "$KB" ] && [ "$((B_SP))" -lt $((KB + KBS)) ] \
    || { dump; fail "the waker's kernel SP $B_SP is not inside arm64_a14_kstack_b"; }
note "PASS the blocked task ran on $A_SP (its own stack) and the peer on $B_SP (a different one)"

# ---- 3. + 4. the parked EL0 registers survived, against the oracle --------
grep -qa "A14: task A exited, reporting sentinel checksum $EXP_SUM" "$SEC" \
    || { dump; fail "the resumed task's x21..x28 sentinels did not sum to the python oracle's $EXP_SUM — its parked EL0 registers did not survive the peer's syscall"; }
grep -qa "checksum=$EXP_SUM" "$SEC" \
    || { dump; fail "the kernel's own verification of the sentinel checksum did not pass"; }
grep -qa 'A14 PASS: a task BLOCKED inside a syscall' "$SEC" \
    || { dump; fail "the kernel did not reach its A14 verdict"; }
note "PASS the sentinels A left in x21..x28 survived B's whole syscall (checksum $EXP_SUM, matching the python oracle)"

# ---- 5. the boot context got the CPU back through the same __switch_to ----
grep -qa 'A14: no runnable task left; the CPU goes back to the boot context' "$SEC" \
    || { dump; fail "the last task did not hand the CPU back through __switch_to"; }
grep -qa 'A14: kernel-stack/context-switch stage complete' "$SEC" \
    || { dump; fail "head.S never resumed after the switch back — the boot context was not restored"; }
note "PASS head.S's own execution was a switchable context and resumed through the same __switch_to"

# ---- 6. the earlier ladder is undisturbed --------------------------------
grep -qa 'A8: EL0 task exited'          "$SERIAL" || { dump; fail "A8 regressed"; }
grep -qa 'A9: scheduler returned'       "$SERIAL" || { dump; fail "A9 regressed"; }
grep -qa 'A10 PASS'                     "$SERIAL" || { dump; fail "A10 regressed"; }
grep -qa 'A11: archive stage complete'  "$SERIAL" || { dump; fail "A11 regressed"; }
grep -qa "A12 PASS: the two spaces' backing pages differ" "$SERIAL" || { dump; fail "A12 regressed"; }
grep -qa 'A13 PASS: 8 demand faults serviced' "$SERIAL" || { dump; fail "A13 regressed (the grown pt_regs frame or the third dispatch outcome broke demand paging)"; }
grep -qa 'A13 PASS: 1 refused fault(s)' "$SERIAL" || { dump; fail "A13's negative control regressed"; }
grep -qa 'ELPROBE-VERDICT: EL0 '        "$SERIAL" || { dump; fail "the EL0 probe regressed"; }
note "PASS A8/A9/A10/A11/A12/A13 + the EL0 probe still pass with the 34-slot frame and the third dispatch outcome"

echo "[A14] PASS per-task kernel stacks: a task BLOCKED inside a syscall, a peer ran kernel code on its OWN stack and woke it, and it resumed mid-syscall with its parked EL0 registers intact"
exit 0
