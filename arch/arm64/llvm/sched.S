/*
 * arch/arm64/llvm/sched.S — PREEMPTIVE EL0 scheduling for the LLVM whole-kernel
 * aarch64 boot lane (docs/arm64_llvm_scoping.md A9).
 *
 * A8 dropped to ONE EL0 task that ran to exit(). A9 builds TWO EL0 tasks and
 * time-slices them: each task runs at EL0 with IRQs UNMASKED (SPSR.I=0), so when
 * the ARM generic timer fires it traps to the "Lower EL using AArch64 / IRQ"
 * vector (0x480, wired in vectors.S) at EL1h. arm64_llvm_lower_irq_entry saves
 * the FULL interrupted EL0 context (x0..x30 + SP_EL0 + ELR_EL1 + SPSR_EL1) into
 * the running task's context block, acks the GIC, calls the emitted-Adder
 * scheduler arm64_sched_pick_arm64(cur_ctx) which does the tick bookkeeping and
 * returns the NEXT task's context block, re-arms the timer, EOIs, restores that
 * task's full context, and ERETs into it — a real EL0<->EL0 context switch driven
 * by the EL1 timer IRQ. After a fixed number of switches the scheduler sets
 * arm64_sched_should_stop; the stub then leaves the timer disabled and returns to
 * head.S (restoring the kernel SP/LR stashed at launch), mirroring the A8 exit.
 *
 * This owns the PRIVILEGED mechanics that cannot be expressed from Adder in this
 * lane: full EL0-context save/restore, SP_EL0/ELR_EL1/SPSR_EL1 sysreg access,
 * the GIC ack/EOI + CNTV re-arm MMIO, and `eret`. The KERNEL-VISIBLE scheduling
 * decision (which task next, tick accounting, the stop signal) is emitted-Adder
 * code — so the context switch is genuinely driven by the kernel's own code.
 *
 * Constants + flow mirror the proven standalone kernel (arch/arm64/vectors.S
 * arm64_lower_irq_entry + arch/arm64/kmain.ad arm64_sched_pick), ported into this
 * lane but kept ISOLATED from it (separate files, separate build).
 *
 * Context block layout (8-byte slots, from base):
 *   0..30 : x0..x30
 *   31    : SP_EL0
 *   32    : ELR_EL1  (resume PC)
 *   33    : SPSR_EL1 (resume PSTATE)
 */

    .equ GICC_BASE,   0x08010000
    .equ GICC_IAR,    0x00C
    .equ GICC_EOIR,   0x010
    .equ VTIMER_INTID, 27

    /* Two EL0 tasks share the A8 fine EL0-RW window 0x4800_0000-0x481F_FFFF
     * (AP=01, built by head.S mmu_enable). Distinct stacks + message buffers
     * inside it distinguish the tasks; the kernel pre-fills the buffers (EL0
     * cannot read kernel .rodata — AP=00). Stacks are 16-byte aligned tops. */
    .equ TASK_A_SP,   0x481E0000        /* EL0 SP for task A */
    .equ TASK_B_SP,   0x481C0000        /* EL0 SP for task B */
    .equ TASK_A_BUF,  0x48004000        /* "[EL0-A] ..." (kernel-filled) */
    .equ TASK_B_BUF,  0x48005000        /* "[EL0-B] ..." (kernel-filled) */
    .equ SPSR_EL0T_IRQON, 0x340         /* M=EL0t, D/A/F masked, I ENABLED */

/* ------------------------------------------------------------------------ *
 * arm64_el0_sched_launch — build the two task context blocks, publish them to
 * the Adder scheduler, re-arm the timer with EL1 IRQs MASKED (so the first tick
 * is taken at EL0, not EL1), and `eret` into task A. Called once from head.S
 * after the A8 round-trip. Saves the kernel SP/LR so the stop path returns here.
 * ------------------------------------------------------------------------ */
    .section .text
    .globl arm64_el0_sched_launch
    .type arm64_el0_sched_launch, %function
arm64_el0_sched_launch:
    /* Stash kernel SP + LR at entry (before any push) for the stop path. */
    ldr     x1, =arm64_sched_saved_sp
    mov     x0, sp
    str     x0, [x1]
    ldr     x1, =arm64_sched_saved_lr
    str     x30, [x1]

    /* Mask EL1 IRQs: the re-armed timer must NOT fire at EL1 (that would hit the
     * A6 0x280 handler); it fires at EL0 via the task SPSR.I=0. */
    msr     daifset, #2

    /* Build task A context block. */
    ldr     x0, =arm64_ctx_a
    bl      .Lzero_ctx
    ldr     x1, =arm64_el0_task_a
    str     x1, [x0, #(8 * 32)]         /* ELR = entry PC */
    movz    x1, #0x481e, lsl #16        /* SP_EL0 = TASK_A_SP */
    str     x1, [x0, #(8 * 31)]
    mov     x1, #SPSR_EL0T_IRQON
    str     x1, [x0, #(8 * 33)]         /* SPSR = EL0t, IRQs on */

    /* Build task B context block. */
    ldr     x0, =arm64_ctx_b
    bl      .Lzero_ctx
    ldr     x1, =arm64_el0_task_b
    str     x1, [x0, #(8 * 32)]
    movz    x1, #0x481c, lsl #16        /* SP_EL0 = TASK_B_SP */
    str     x1, [x0, #(8 * 31)]
    mov     x1, #SPSR_EL0T_IRQON
    str     x1, [x0, #(8 * 33)]

    /* Publish both blocks to the Adder scheduler (resets its round-robin idx). */
    ldr     x0, =arm64_ctx_a
    ldr     x1, =arm64_ctx_b
    bl      arm64_sched_register_arm64

    /* current = task A. */
    ldr     x1, =arm64_current_ctx
    ldr     x0, =arm64_ctx_a
    str     x0, [x1]

    /* Re-arm the generic timer (EL1 IRQs still masked; SPSR.I=0 lets it fire at
     * EL0). Period was stashed by the A6 gic_timer_init in gic_timer_period. */
    ldr     x9, =gic_timer_period
    ldr     x9, [x9]
    msr     cntv_tval_el0, x9
    mov     x1, #1
    msr     cntv_ctl_el0, x1            /* ENABLE=1, IMASK=0 */
    isb

    /* eret into task A: load its full context (x0 = block base). */
    ldr     x0, =arm64_ctx_a
    ldr     x1, [x0, #(8 * 33)]
    msr     spsr_el1, x1
    ldr     x1, [x0, #(8 * 32)]
    msr     elr_el1, x1
    ldr     x1, [x0, #(8 * 31)]
    msr     sp_el0, x1
    ldp     x2,  x3,  [x0, #(8 * 2)]
    ldp     x4,  x5,  [x0, #(8 * 4)]
    ldp     x6,  x7,  [x0, #(8 * 6)]
    ldp     x8,  x9,  [x0, #(8 * 8)]
    ldp     x10, x11, [x0, #(8 * 10)]
    ldp     x12, x13, [x0, #(8 * 12)]
    ldp     x14, x15, [x0, #(8 * 14)]
    ldp     x16, x17, [x0, #(8 * 16)]
    ldp     x18, x19, [x0, #(8 * 18)]
    ldp     x20, x21, [x0, #(8 * 20)]
    ldp     x22, x23, [x0, #(8 * 22)]
    ldp     x24, x25, [x0, #(8 * 24)]
    ldp     x26, x27, [x0, #(8 * 26)]
    ldp     x28, x29, [x0, #(8 * 28)]
    ldr     x30,      [x0, #(8 * 30)]
    ldp     x0,  x1,  [x0, #(8 * 0)]
    eret
    .size arm64_el0_sched_launch, .-arm64_el0_sched_launch

/* Zero a 34-slot context block. x0 = base (preserved). Clobbers x2. */
    .type .Lzero_ctx, %function
.Lzero_ctx:
    mov     x2, #0
1:  str     xzr, [x0, x2, lsl #3]
    add     x2, x2, #1
    cmp     x2, #34
    b.lt    1b
    ret
    .size .Lzero_ctx, .-.Lzero_ctx

/* ------------------------------------------------------------------------ *
 * arm64_llvm_lower_irq_entry — the "Lower EL using AArch64 / IRQ" vector slot
 * (0x480, wired in vectors.S). An EL0 task's timer IRQ traps here at EL1h. Save
 * the running task's full EL0 context into [arm64_current_ctx], hand it to the
 * Adder scheduler, then either switch to the returned next task or (on stop)
 * return to head.S.
 * ------------------------------------------------------------------------ */
    .globl arm64_llvm_lower_irq_entry
    .type arm64_llvm_lower_irq_entry, %function
arm64_llvm_lower_irq_entry:
    /* Stash the task's x0,x1 on the kernel stack; we need two scratch regs. */
    sub     sp, sp, #16
    stp     x0, x1, [sp]

    ldr     x0, =arm64_current_ctx
    ldr     x0, [x0]                    /* x0 = &cur_ctx */

    /* x2..x30 are still live: store directly. */
    stp     x2,  x3,  [x0, #(8 * 2)]
    stp     x4,  x5,  [x0, #(8 * 4)]
    stp     x6,  x7,  [x0, #(8 * 6)]
    stp     x8,  x9,  [x0, #(8 * 8)]
    stp     x10, x11, [x0, #(8 * 10)]
    stp     x12, x13, [x0, #(8 * 12)]
    stp     x14, x15, [x0, #(8 * 14)]
    stp     x16, x17, [x0, #(8 * 16)]
    stp     x18, x19, [x0, #(8 * 18)]
    stp     x20, x21, [x0, #(8 * 20)]
    stp     x22, x23, [x0, #(8 * 22)]
    stp     x24, x25, [x0, #(8 * 24)]
    stp     x26, x27, [x0, #(8 * 26)]
    stp     x28, x29, [x0, #(8 * 28)]
    str     x30,      [x0, #(8 * 30)]

    /* Recover + store the task's real x0,x1. */
    ldp     x2, x3, [sp]
    add     sp, sp, #16
    stp     x2, x3, [x0, #(8 * 0)]

    /* Save SP_EL0, ELR_EL1, SPSR_EL1. */
    mrs     x1, sp_el0
    str     x1, [x0, #(8 * 31)]
    mrs     x1, elr_el1
    str     x1, [x0, #(8 * 32)]
    mrs     x1, spsr_el1
    str     x1, [x0, #(8 * 33)]

    /* Ack the GIC (x19 = raw IAR for the EOI later). */
    movz    x1, #0x0801, lsl #16        /* GICC_BASE */
    ldr     w19, [x1, #GICC_IAR]

    /* Quiesce the timer while servicing. */
    msr     cntv_ctl_el0, xzr

    /* Scheduler: x0 already = &cur_ctx (arg0). Returns &next_ctx in x0. */
    bl      arm64_sched_pick_arm64
    mov     x22, x0                     /* x22 = &next_ctx */

    /* EOI the interrupt. */
    movz    x1, #0x0801, lsl #16        /* GICC_BASE */
    str     w19, [x1, #GICC_EOIR]

    /* Stop requested? Leave the timer disabled and return to head.S. */
    ldr     x0, =arm64_sched_should_stop
    ldr     x0, [x0]
    cbnz    x0, .Lsched_stop

    /* Re-arm the timer for the next slice. */
    ldr     x9, =gic_timer_period
    ldr     x9, [x9]
    msr     cntv_tval_el0, x9
    mov     x1, #1
    msr     cntv_ctl_el0, x1

    /* Publish the new current context. */
    ldr     x0, =arm64_current_ctx
    str     x22, [x0]

    /* Restore next task's context (x0 = block base) and eret into it. */
    mov     x0, x22
    ldr     x1, [x0, #(8 * 33)]
    msr     spsr_el1, x1
    ldr     x1, [x0, #(8 * 32)]
    msr     elr_el1, x1
    ldr     x1, [x0, #(8 * 31)]
    msr     sp_el0, x1
    ldp     x2,  x3,  [x0, #(8 * 2)]
    ldp     x4,  x5,  [x0, #(8 * 4)]
    ldp     x6,  x7,  [x0, #(8 * 6)]
    ldp     x8,  x9,  [x0, #(8 * 8)]
    ldp     x10, x11, [x0, #(8 * 10)]
    ldp     x12, x13, [x0, #(8 * 12)]
    ldp     x14, x15, [x0, #(8 * 14)]
    ldp     x16, x17, [x0, #(8 * 16)]
    ldp     x18, x19, [x0, #(8 * 18)]
    ldp     x20, x21, [x0, #(8 * 20)]
    ldp     x22, x23, [x0, #(8 * 22)]
    ldp     x24, x25, [x0, #(8 * 24)]
    ldp     x26, x27, [x0, #(8 * 26)]
    ldp     x28, x29, [x0, #(8 * 28)]
    ldr     x30,      [x0, #(8 * 30)]
    ldp     x0,  x1,  [x0, #(8 * 0)]
    eret

.Lsched_stop:
    /* Timer already quiesced (cntv_ctl=0). Restore the kernel SP/LR and return
     * to head.S past the `bl arm64_el0_sched_launch`. */
    ldr     x1, =arm64_sched_saved_sp
    ldr     x0, [x1]
    mov     sp, x0
    ldr     x1, =arm64_sched_saved_lr
    ldr     x30, [x1]
    ret
    .size arm64_llvm_lower_irq_entry, .-arm64_llvm_lower_irq_entry

/* ------------------------------------------------------------------------ *
 * The two EL0 tasks. Each: strlen its kernel-filled message buffer, write(1,
 * buf, len) via `svc #0` (serviced by the A8 real dispatcher through the 0x400
 * sync vector), then spin in a bounded delay loop so the ~10ms timer preempts it
 * mid-slice. Runs forever; the scheduler stops the demo after N switches. IRQs
 * are enabled at EL0 (SPSR.I=0) so the preempt actually fires here.
 * ------------------------------------------------------------------------ */
    .globl arm64_el0_task_a
    .type arm64_el0_task_a, %function
arm64_el0_task_a:
    movz    x20, #0x4800, lsl #16
    add     x20, x20, #0x4000           /* buf = TASK_A_BUF */
    b       .Ltask_body
    .size arm64_el0_task_a, .-arm64_el0_task_a

    .globl arm64_el0_task_b
    .type arm64_el0_task_b, %function
arm64_el0_task_b:
    movz    x20, #0x4800, lsl #16
    add     x20, x20, #0x5000           /* buf = TASK_B_BUF */
    b       .Ltask_body
    .size arm64_el0_task_b, .-arm64_el0_task_b

    .type .Ltask_body, %function
.Ltask_body:
    /* strlen(buf) -> x2 (EL0 loads from the EL0-RW window). */
    mov     x2, #0
1:  ldrb    w3, [x20, x2]
    cbz     w3, 2f
    add     x2, x2, #1
    b       1b
2:  mov     x8, #64                     /* __NR_write */
    mov     x0, #1                      /* fd = 1 */
    mov     x1, x20                     /* buf */
    /* x2 = len */
    svc     #0
    /* Bounded busy delay so the timer preempts during the slice. */
    movz    x4, #0x0040, lsl #16        /* ~4M iterations */
3:  subs    x4, x4, #1
    b.ne    3b
    b       .Ltask_body
    .size .Ltask_body, .-.Ltask_body

/* ------------------------------------------------------------------------ *
 * Per-task context blocks + the running-task pointer + saved kernel context.
 * ------------------------------------------------------------------------ */
    .section .bss
    .balign 16
    .globl arm64_ctx_a
arm64_ctx_a:
    .space  288                         /* 34 slots used, padded to 16 */
    .balign 16
    .globl arm64_ctx_b
arm64_ctx_b:
    .space  288
    .balign 8
    .globl arm64_current_ctx
arm64_current_ctx:
    .space  8
arm64_sched_saved_sp:
    .space  8
arm64_sched_saved_lr:
    .space  8

    .section .note.GNU-stack,"",%progbits
