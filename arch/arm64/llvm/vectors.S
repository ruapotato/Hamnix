/*
 * arch/arm64/llvm/vectors.S — minimal VBAR_EL1 exception vector table for the
 * LLVM whole-kernel boot lane (docs/arm64_llvm_scoping.md A3).
 *
 * The AArch64 vector table is 0x800 bytes: 16 slots of 0x80, grouped in 4 sets
 * of 4 (Sync/IRQ/FIQ/SError) for {Current EL SP0, Current EL SPx, Lower AArch64,
 * Lower AArch32}. For A3 every slot routes to one diagnostic handler that dumps
 * ESR_EL1 + ELR_EL1 over PL011 and halts — so if the boot proof faults anywhere
 * (e.g. a bad MMU descriptor or an unstubbed path), we get exact serial evidence
 * of where instead of a silent hang. Real per-vector handlers (IRQ dispatch, EL0
 * sync/svc, timer) are later phases, mirroring arch/arm64/vectors.S.
 */

    .section .text.vectors, "ax"
    .balign 0x800
    .globl arm64_llvm_vectors
arm64_llvm_vectors:
    /* ---- Current EL with SP_EL0 ---- */
    .balign 0x80
    b       arm64_llvm_exc          /* Synchronous */
    .balign 0x80
    b       arm64_llvm_exc          /* IRQ */
    .balign 0x80
    b       arm64_llvm_exc          /* FIQ */
    .balign 0x80
    b       arm64_llvm_exc          /* SError */

    /* ---- Current EL with SP_ELx (the kernel runs here, EL1h) ---- */
    .balign 0x80
    b       arm64_llvm_exc          /* Synchronous */
    .balign 0x80
    b       arm64_llvm_irq_entry    /* IRQ (0x280): GICv2 + generic-timer tick (gic.S) */
    .balign 0x80
    b       arm64_llvm_exc          /* FIQ */
    .balign 0x80
    b       arm64_llvm_exc          /* SError */

    /* ---- Lower EL using AArch64 (EL0 userspace traps here) ---- */
    .balign 0x80
    b       arm64_llvm_lower_sync_entry /* Synchronous (0x400): EL0 `svc #0` (el0.S) */
    .balign 0x80
    b       arm64_llvm_lower_irq_entry  /* IRQ (0x480): preempt running EL0 task (sched.S) */
    .balign 0x80
    b       arm64_llvm_exc          /* FIQ */
    .balign 0x80
    b       arm64_llvm_exc          /* SError */

    /* ---- Lower EL using AArch32 ---- */
    .balign 0x80
    b       arm64_llvm_exc          /* Synchronous */
    .balign 0x80
    b       arm64_llvm_exc          /* IRQ */
    .balign 0x80
    b       arm64_llvm_exc          /* FIQ */
    .balign 0x80
    b       arm64_llvm_exc          /* SError */

/* Diagnostic: print "EXC esr=<16hex> elr=<16hex>" and halt. */
    .balign 0x80
    /* .globl: A13's el0.S branches here for any EL0 synchronous exception that
     * is neither SVC64 nor a lower-EL abort, instead of the pre-A13 behaviour of
     * feeding it to the syscall dispatcher. */
    .globl arm64_llvm_exc
    .type arm64_llvm_exc, %function
arm64_llvm_exc:
    ldr     x0, =msg_exc
    bl      uart_puts
    mrs     x0, esr_el1
    bl      uart_puthex
    ldr     x0, =msg_elr
    bl      uart_puts
    mrs     x0, elr_el1
    bl      uart_puthex
    mov     x0, #10
    bl      uart_putc
1:  wfi
    b       1b
    .size arm64_llvm_exc, .-arm64_llvm_exc

    .section .rodata
    .balign 8
msg_exc:
    .asciz  "\nEXC esr="
msg_elr:
    .asciz  " elr="

    .section .note.GNU-stack,"",%progbits
