/*
 * arch/arm64/llvm/a10.S — EL0 launcher for the A10 REAL user program
 * (docs/arm64_llvm_scoping.md A10).
 *
 * A8/A9 dropped to EL0 programs that were HAND-WRITTEN AArch64 assembly living
 * in the kernel image's own .text (el0.S / sched.S). A10 instead erets to an
 * image the kernel LOADED into the user window: user/arm64_a10_el0.ad compiled
 * by the Adder LLVM backend for aarch64, linked flat at 0x4801_0000 (user.lds)
 * with the user_rt.S crt0, embedded via user_blob.S and memcpy'd into place by
 * init/main.ad's arm64_a10_load_arm64().
 *
 * Only the eret mechanics live here — this file contains NO user code at all.
 * That is the point of A10: the thing running at EL0 is compiler output, not
 * assembly the kernel author wrote.
 *
 * The `svc #0`s the program issues trap to the SAME Lower-EL synchronous vector
 * (0x400) A8 installed -> arm64_llvm_lower_sync_entry (el0.S) -> the emitted-
 * Adder dispatcher arm64_svc_dispatch_arm64(). On exit() that stub restores the
 * kernel SP/LR stashed below and `ret`s back into head.S. Reusing the A8 stub is
 * deliberate: it proves the real program runs against the SAME syscall path,
 * with no A10-special-cased entry.
 */

    .equ SPSR_EL0T_DAIF, 0x3c0          /* M[3:0]=EL0t, DAIF (bits 9:6) all masked */
    .equ A10_ENTRY_VA,   0x48010000     /* must equal user.lds's `. = 0x48010000` */
    .equ A10_SP_EL0,     0x481A0000     /* EL0 stack top; below A9 task-B's 0x481C0000 */

    .section .text
    .globl arm64_a10_launch
    .type arm64_a10_launch, %function
arm64_a10_launch:
    /* Stash kernel SP + LR into the SAME slots el0.S's sync stub restores on
     * exit(), so the A10 task's exit() returns cleanly here -> head.S. */
    ldr     x1, =arm64_el0_saved_sp
    mov     x0, sp
    str     x0, [x1]
    ldr     x1, =arm64_el0_saved_lr
    str     x30, [x1]

    /* ELR_EL1 = the LOADED image's entry (user.lds puts _start first, so the
     * load address IS the entry point — no header parsing needed). */
    movz    x0, #(A10_ENTRY_VA >> 16), lsl #16
    msr     elr_el1, x0

    /* SP_EL0 inside the EL0-RW window; the crt0 + compiled code use it for real
     * frames (the Adder program recurses, so this stack genuinely gets used). */
    movz    x0, #(A10_SP_EL0 >> 16), lsl #16
    msr     sp_el0, x0

    mov     x0, #SPSR_EL0T_DAIF
    msr     spsr_el1, x0                /* target PSTATE: EL0t, IRQ/FIQ masked */
    isb
    eret                                /* -> EL0 at the LOADED user image */
    .size arm64_a10_launch, .-arm64_a10_launch

    .section .note.GNU-stack,"",%progbits
