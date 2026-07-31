/*
 * arch/arm64/llvm/el0.S — EL0 (user-mode) drop + `svc #0` syscall round-trip for
 * the LLVM whole-kernel aarch64 boot lane (docs/arm64_llvm_scoping.md A7).
 *
 * This file owns the PRIVILEGED exception-return / register-frame mechanics that
 * cannot be expressed from Adder in the LLVM lane: programming SPSR_EL1 / ELR_EL1
 * / SP_EL0 and `eret`-ing down to EL0, and the Lower-EL synchronous vector stub
 * that saves the full user register frame around the syscall. The KERNEL-VISIBLE
 * syscall service (decode x8/args, emit the write buffer over the console, record
 * the exit status) is done by the emitted-Adder handler arm64_svc_dispatch_arm64()
 * in init/main.ad — so the user `svc #0` is genuinely serviced by the kernel's own
 * LLVM-emitted code, proving the "runs userspace" milestone.
 *
 * Flow (called once from head.S after the A6 timer proof):
 *   arm64_el0_launch: stash the kernel SP/LR (so the exit path can return here),
 *     program SPSR_EL1 = EL0t + DAIF-masked, ELR_EL1 = arm64_el0_user_entry,
 *     SP_EL0 = arm64_el0_stack_top, and `eret` -> EL0.
 *   arm64_el0_user_entry (runs at EL0): write(1, msg, len) then exit(0) via
 *     `svc #0`; each svc traps to the Lower-EL AArch64 synchronous vector.
 *   arm64_llvm_lower_sync_entry (EL1h): save x0..x30, call the Adder dispatcher,
 *     then either reload the frame + `eret` back to EL0 (write) or restore the
 *     saved kernel SP/LR + `ret` back into head.S (exit) — a full EL0<->EL1<->EL0
 *     round-trip that returns cleanly to the kernel.
 *
 * Constants + flow mirror the proven standalone kernel (arch/arm64/vectors.S
 * arm64_lower_sync_entry + arch/arm64/kmain.ad EL0 launcher), ported into this
 * lane but kept ISOLATED from it (separate files, separate build).
 *
 * ISOLATION / A8 gap: this proof runs EL0 on the shared head.S identity map, whose
 * RAM block is AP=00 (EL1 RW, EL0 no DATA access). EL0 instruction fetch is allowed
 * (UXN=0), and the demo user program is register-only (mov/adr/svc — no EL0 load or
 * store, and it never touches SP_EL0), so it needs no EL0-RW data page. A REAL user
 * task with an EL0 data stack + heap needs a per-task TTBR0 address space with an
 * EL0-RW (AP=01) L2/L3 mapping — that is A8 (see docs/arm64_llvm_scoping.md).
 */

    .equ SPSR_EL0T_DAIF, 0x3c0          /* M[3:0]=EL0t, DAIF (bits 9:6) all masked */

/* ------------------------------------------------------------------------ *
 * arm64_el0_launch — drop to EL0 and run the first user task. Saves the kernel
 * return context (SP + LR) so the exit-syscall path can `ret` back to head.S.
 * ------------------------------------------------------------------------ */
    .section .text
    .globl arm64_el0_launch
    .type arm64_el0_launch, %function
arm64_el0_launch:
    /* Stash kernel SP + LR for the exit path to restore (see the sync stub). */
    ldr     x1, =arm64_el0_saved_sp
    mov     x0, sp
    str     x0, [x1]
    ldr     x1, =arm64_el0_saved_lr
    str     x30, [x1]

    /* Program the EL0 return state. */
    ldr     x0, =arm64_el0_user_entry
    msr     elr_el1, x0                 /* EL0 entry PC */
    /* A8: SP_EL0 points into the fine EL0-RW user window (0x4800_0000-0x481F_FFFF,
     * AP=01), so the EL0 program can actually push/pop — the A7 register-only demo
     * used a kernel-.bss stack the EL0 task could never touch (AP=00). Top at
     * 0x481F_0000 (16-byte aligned, well above the SRC/DST buffers). */
    movz    x0, #0x481f, lsl #16        /* SP_EL0 = 0x481F_0000 (in the EL0-RW window) */
    msr     sp_el0, x0                  /* EL0 stack pointer (16-byte aligned) */
    mov     x0, #SPSR_EL0T_DAIF
    msr     spsr_el1, x0                /* target PSTATE: EL0t, IRQ/FIQ masked */
    isb
    eret                                /* -> EL0; svc traps re-enter EL1 */
    .size arm64_el0_launch, .-arm64_el0_launch

/* ------------------------------------------------------------------------ *
 * arm64_el0_user_entry — the A8 EL0 user program. Mirrors the Linux aarch64 ABI:
 * syscall number in x8, args x0..x5, return in x0. Unlike the A7 register-only
 * demo, this program ACCESSES ITS OWN MEMORY through the fine EL0-RW TTBR0 window
 * (0x4800_0000-0x481F_FFFF, AP=01):
 *   1. getpid() via the REAL kernel syscall table (proves real syscall routing).
 *   2. push/pop through SP_EL0 (proves the EL0 stack is writable/readable).
 *   3. memcpy SRC(0x4800_0000) -> DST(0x4800_1000) byte-by-byte until NUL, using
 *      EL0 loads (ldrb) AND stores (strb) — proves EL0 read+write of its memory.
 *      The kernel pre-filled SRC (arm64_el0_prepare_user_mem_arm64); the message
 *      only reaches the console if the EL0 copy actually worked.
 *   4. write(1, DST, len) via the real kernel console syscall, then exit(0).
 * ------------------------------------------------------------------------ */
    .equ USER_SRC, 0x48000000
    .globl arm64_el0_user_entry
    .type arm64_el0_user_entry, %function
arm64_el0_user_entry:
    /* 1) getpid() — routed into the kernel's real current_task_pid(). */
    mov     x8, #172                    /* __NR_getpid (aarch64) */
    svc     #0                          /* x0 <- real boot-task pid */

    /* 2) EL0 stack round-trip via SP_EL0 (in the EL0-RW window). A fault here
     *    would hit the vectors.S diagnostic; success is implicit. */
    movz    x0, #0x55aa
    str     x0, [sp, #-16]!             /* push (EL0 store to SP_EL0 page) */
    ldr     x3, [sp], #16               /* pop  (EL0 load from SP_EL0 page)  */

    /* 3) memcpy SRC -> DST until NUL, using EL0 ldrb/strb; count length in x11. */
    movz    x9,  #0x4800, lsl #16       /* SRC = 0x4800_0000 (EL0-RW) */
    add     x10, x9, #0x1000            /* DST = 0x4800_1000 (EL0-RW) */
    mov     x11, #0                     /* len */
1:  ldrb    w12, [x9, x11]             /* EL0 LOAD from user src */
    strb    w12, [x10, x11]            /* EL0 STORE to user dst */
    cbz     w12, 2f                     /* stop at (and after copying) the NUL */
    add     x11, x11, #1
    b       1b
2:
    /* 4) write(1, DST, len) via the real kernel console syscall. */
    mov     x8, #64                     /* __NR_write (aarch64) */
    mov     x0, #1                      /* fd = 1 */
    mov     x1, x10                     /* buf = DST (bytes came via EL0 copy) */
    mov     x2, x11                     /* len */
    svc     #0
    /* 5) exit(0). */
    mov     x8, #93                     /* __NR_exit (aarch64) */
    mov     x0, #0                      /* status = 0 */
    svc     #0
3:  b       3b                          /* safety: exit never resumes EL0 */
    .size arm64_el0_user_entry, .-arm64_el0_user_entry

/* ------------------------------------------------------------------------ *
 * arm64_llvm_lower_sync_entry — the "Lower EL using AArch64 / Synchronous" vector
 * slot (0x400, wired in vectors.S). An EL0 `svc #0` traps here at EL1h on the
 * kernel SP_ELx. Save the full x0..x30 frame (32 slots, 16-byte aligned), hand
 * the frame base to the Adder dispatcher, then:
 *   dispatcher returns 0 (resume): reload x0..x30 (x0 = syscall return) and eret
 *     back to EL0 (HW ELR_EL1/SPSR_EL1 untouched -> resumes after the svc);
 *   dispatcher returns 1 (exit): restore the saved kernel SP/LR and `ret` back
 *     into head.S past the `bl arm64_el0_launch`.
 * ------------------------------------------------------------------------ */
    .globl arm64_llvm_lower_sync_entry
    .type arm64_llvm_lower_sync_entry, %function
arm64_llvm_lower_sync_entry:
    sub     sp, sp, #(16 * 16)          /* 32 GPR slots */
    stp     x0,  x1,  [sp, #(16 * 0)]
    stp     x2,  x3,  [sp, #(16 * 1)]
    stp     x4,  x5,  [sp, #(16 * 2)]
    stp     x6,  x7,  [sp, #(16 * 3)]
    stp     x8,  x9,  [sp, #(16 * 4)]
    stp     x10, x11, [sp, #(16 * 5)]
    stp     x12, x13, [sp, #(16 * 6)]
    stp     x14, x15, [sp, #(16 * 7)]
    stp     x16, x17, [sp, #(16 * 8)]
    stp     x18, x19, [sp, #(16 * 9)]
    stp     x20, x21, [sp, #(16 * 10)]
    stp     x22, x23, [sp, #(16 * 11)]
    stp     x24, x25, [sp, #(16 * 12)]
    stp     x26, x27, [sp, #(16 * 13)]
    stp     x28, x29, [sp, #(16 * 14)]
    str     x30,      [sp, #(16 * 15)]

    /* A13: DECODE ESR_EL1.EC FIRST. Before A13 this stub called the syscall
     * dispatcher for EVERY synchronous exception from EL0 — so a data abort was
     * serviced as a syscall whose number was whatever the faulting program had
     * left in x8, a value was written into x0, and the task was eret'd back to
     * resume. A fault that returns a plausible value and keeps running is the
     * exact failure mode this lane has already been bitten by (see the A11 exit
     * latch, init/main.ad arm64_a12_take_exit_arm64). Now:
     *   EC=0x15 SVC64                      -> the syscall dispatcher
     *   EC=0x24/0x20 Data/Instr abort, EL0 -> the A13 demand-paging path
     *   anything else                      -> the loud diagnostic vector */
    mrs     x9, esr_el1
    lsr     x10, x9, #26
    and     x10, x10, #0x3f
    cmp     x10, #0x15
    b.eq    .Lel0_svc
    cmp     x10, #0x24                  /* Data Abort from a lower EL */
    b.eq    .Lel0_abort
    cmp     x10, #0x20                  /* Instruction Abort from a lower EL */
    b.eq    .Lel0_abort
    b       arm64_llvm_exc              /* unexpected EC: dump ESR/ELR and halt */

.Lel0_abort:
    bl      arm64_a13_fault_entry       /* 1 = mapped (retry), 0 = task killed */
    cbz     x0, 3f                      /* refused -> unwind to head.S (status 139) */
    b       .Lel0_resume                /* ELR_EL1 untouched: RETRY the fault */

.Lel0_svc:
    mov     x0, sp                      /* frame_ptr -> arg0 */
    bl      arm64_svc_dispatch_arm64
    cbnz    x0, 3f                      /* nonzero -> EL0 task exited */

.Lel0_resume:
    /* Resume EL0: reload the (mutated) frame and eret. */
    ldp     x0,  x1,  [sp, #(16 * 0)]
    ldp     x2,  x3,  [sp, #(16 * 1)]
    ldp     x4,  x5,  [sp, #(16 * 2)]
    ldp     x6,  x7,  [sp, #(16 * 3)]
    ldp     x8,  x9,  [sp, #(16 * 4)]
    ldp     x10, x11, [sp, #(16 * 5)]
    ldp     x12, x13, [sp, #(16 * 6)]
    ldp     x14, x15, [sp, #(16 * 7)]
    ldp     x16, x17, [sp, #(16 * 8)]
    ldp     x18, x19, [sp, #(16 * 9)]
    ldp     x20, x21, [sp, #(16 * 10)]
    ldp     x22, x23, [sp, #(16 * 11)]
    ldp     x24, x25, [sp, #(16 * 12)]
    ldp     x26, x27, [sp, #(16 * 13)]
    ldp     x28, x29, [sp, #(16 * 14)]
    ldr     x30,      [sp, #(16 * 15)]
    add     sp, sp, #(16 * 16)
    eret                                /* -> EL0, after the svc */

3:  /* EL0 exit(): restore the saved kernel SP/LR and return to head.S. */
    ldr     x1, =arm64_el0_saved_sp
    ldr     x0, [x1]
    mov     sp, x0
    ldr     x1, =arm64_el0_saved_lr
    ldr     x30, [x1]
    ret
    .size arm64_llvm_lower_sync_entry, .-arm64_llvm_lower_sync_entry

/* ------------------------------------------------------------------------ *
 * EL0 stack + saved kernel-context slots.
 * ------------------------------------------------------------------------ */
    .section .bss
    .balign 16
    .globl arm64_el0_stack
arm64_el0_stack:
    .space  4096
    .globl arm64_el0_stack_top
arm64_el0_stack_top = arm64_el0_stack + 4096
    .balign 8
    /* A10: also written by a10.S's launcher, so the real Adder EL0 program's
     * exit() unwinds through the SAME sync-stub path back into head.S. */
    .globl arm64_el0_saved_sp
arm64_el0_saved_sp:
    .space  8
    .globl arm64_el0_saved_lr
arm64_el0_saved_lr:
    .space  8

    .section .note.GNU-stack,"",%progbits
