/*
 * arch/arm64/llvm/gic.S — GICv2 + ARM generic (virtual) timer bring-up and the
 * IRQ entry stub for the LLVM whole-kernel aarch64 boot lane
 * (docs/arm64_llvm_scoping.md A6).
 *
 * This file owns the PRIVILEGED interrupt-controller / timer HW mechanics that
 * cannot be expressed from Adder in the LLVM lane: the GICv2 distributor + CPU
 * interface MMIO poking (at the qemu `-M virt` addresses), the CNTV_* generic-
 * timer sysreg programming, the register-frame save/restore around the IRQ, and
 * the DAIF unmask/mask. The KERNEL-VISIBLE tick bookkeeping (counter + per-tick
 * printk) is done by the emitted-Adder handler arm64_do_timer_tick() which this
 * stub calls each tick — so the FIRST SCHEDULER TICK is taken by the GIC and
 * handled by the kernel's own LLVM-emitted code.
 *
 * Constants + flow mirror the proven standalone kernel (arch/arm64/kmain.ad
 * arm64_gic_init / arm64_timer_init / arm64_irq_handler + arch/arm64/vectors.S
 * arm64_irq_entry), ported into this lane but kept ISOLATED from it.
 *
 * QEMU virt GICv2:  GICD @ 0x0800_0000, GICC @ 0x0801_0000  (identity-mapped
 * device region 0-1GiB by head.S's MMU). Virtual-timer PPI = INTID 27.
 */

    .equ GICD_BASE,       0x08000000
    .equ GICC_BASE,       0x08010000
    .equ GICD_CTLR,       0x000
    .equ GICD_ISENABLER,  0x100        /* set-enable, 1 bit / INTID, 32 / reg */
    .equ GICD_IPRIORITYR, 0x400        /* 8 bits / INTID (byte addressed)     */
    .equ GICC_CTLR,       0x000
    .equ GICC_PMR,        0x004        /* priority mask                       */
    .equ GICC_BPR,        0x008
    .equ GICC_IAR,        0x00C        /* interrupt acknowledge               */
    .equ GICC_EOIR,       0x010        /* end of interrupt                    */
    .equ VTIMER_INTID,    27           /* EL1 virtual timer PPI               */

    .section .text
/* ------------------------------------------------------------------------ *
 * gic_timer_init — enable the GICv2 distributor + CPU interface, route the
 * virtual-timer PPI (INTID 27), program a periodic CNTV tick (~10 ms), and
 * unmask IRQs (DAIF.I). Clobbers x0..x4, x9. No stack frame (leaf-ish; only
 * calls nothing).
 * ------------------------------------------------------------------------ */
    .globl gic_timer_init
    .type gic_timer_init, %function
gic_timer_init:
    /* --- GIC Distributor --- */
    movz    x0, #0x0800, lsl #16        /* GICD_BASE = 0x0800_0000 */
    str     wzr, [x0, #GICD_CTLR]       /* disable while configuring */
    mov     w1, #(1 << VTIMER_INTID)    /* enable INTID 27 (ISENABLER[0]) */
    str     w1, [x0, #GICD_ISENABLER]
    /* priority 0 (highest) for INTID 27; IPRIORITYR byte-addressed */
    add     x2, x0, #GICD_IPRIORITYR
    strb    wzr, [x2, #VTIMER_INTID]
    mov     w1, #1
    str     w1, [x0, #GICD_CTLR]        /* enable distributor */

    /* --- GIC CPU interface --- */
    movz    x0, #0x0801, lsl #16        /* GICC_BASE = 0x0801_0000 */
    mov     w1, #0xF0
    str     w1, [x0, #GICC_PMR]         /* allow all priorities */
    str     wzr, [x0, #GICC_BPR]        /* no preemption grouping */
    mov     w1, #1
    str     w1, [x0, #GICC_CTLR]        /* enable signalling */

    /* --- Virtual generic timer: program a ~10 ms periodic tick --- */
    mrs     x9, cntfrq_el0              /* timer rate (Hz) */
    mov     x1, #100
    udiv    x9, x9, x1                  /* period = freq / 100 (~10 ms) */
    ldr     x2, =gic_timer_period
    str     x9, [x2]                    /* stash for the IRQ stub re-arm */
    msr     cntv_tval_el0, x9           /* CVAL = now + period */
    mov     x1, #1
    msr     cntv_ctl_el0, x1            /* ENABLE=1, IMASK=0 */
    isb

    msr     daifclr, #2                 /* clear DAIF.I -> IRQs on */
    ret
    .size gic_timer_init, .-gic_timer_init

/* ------------------------------------------------------------------------ *
 * arm64_llvm_irq_entry — the Current-EL-SPx IRQ vector slot lands here (wired
 * in vectors.S). Save the caller-saved GPR frame, ack the GIC, and for the
 * virtual-timer PPI call the emitted-Adder tick handler, re-arm the timer, and
 * EOI. A spurious/other INTID is EOI'd and ignored. On the Nth tick the Adder
 * handler returns 1 -> mask IRQs so the boot parks quietly instead of a tick
 * storm filling the serial log.
 * ------------------------------------------------------------------------ */
    .globl arm64_llvm_irq_entry
    .type arm64_llvm_irq_entry, %function
arm64_llvm_irq_entry:
    sub     sp, sp, #(16 * 12)
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
    str     x30,      [sp, #(16 * 11)]

    /* Ack: read GICC_IAR. x19 = raw IAR, x20 = INTID. */
    movz    x0, #0x0801, lsl #16        /* GICC_BASE */
    ldr     w19, [x0, #GICC_IAR]
    and     x20, x19, #0x3FF
    mov     x21, #0                     /* default: do not mask (set by handler) */

    cmp     x20, #VTIMER_INTID
    b.ne    2f                          /* not our timer: just EOI */

    /* Quiesce the firing condition while we service it (CNTV_CTL disabled). */
    msr     cntv_ctl_el0, xzr

    /* Kernel-visible tick bookkeeping in emitted Adder. Returns 1 to request
     * "stop ticking" (enough ticks proven), else 0. */
    bl      arm64_do_timer_tick
    mov     x21, x0                     /* stash "stop?" request */

    /* If the handler asked to stop, leave the timer DISABLED (already 0 from
     * the quiesce above) — do NOT re-arm. Masking DAIF here would be undone by
     * the eret restoring SPSR_EL1, so stopping the SOURCE (the CNTV timer) is
     * the correct way to quiesce the periodic tick. */
    cbnz    x21, 2f

    /* Re-arm the next compare and re-enable the timer. */
    ldr     x9, =gic_timer_period
    ldr     x9, [x9]
    msr     cntv_tval_el0, x9
    mov     x1, #1
    msr     cntv_ctl_el0, x1

2:  /* EOI the verbatim IAR value. */
    movz    x0, #0x0801, lsl #16        /* GICC_BASE */
    str     w19, [x0, #GICC_EOIR]

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
    ldr     x30,      [sp, #(16 * 11)]
    add     sp, sp, #(16 * 12)
    eret
    .size arm64_llvm_irq_entry, .-arm64_llvm_irq_entry

    .section .bss
    .balign 8
gic_timer_period:
    .space  8

    .section .note.GNU-stack,"",%progbits
