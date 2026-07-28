/*
 * arch/arm64/llvm/user_rt.S — crt0 for the ARM64 LLVM lane's REAL EL0 user
 * program (docs/arm64_llvm_scoping.md A10).
 *
 * This is the ONLY assembly in the A10 user image; everything else is the
 * Adder program user/arm64_a10_el0.ad compiled by the Adder LLVM backend with
 * `--target=aarch64`. Exactly the split a real userland has: a tiny crt0 plus
 * a compiled program.
 *
 * Responsibilities (standard freestanding crt0):
 *   1. Zero .bss between the linker-provided __bss_start/__bss_end. The Adder
 *      globals (a10_sieve, a10_outbuf) are zeroinitializer, so they land in
 *      .bss, which is NOBITS and therefore absent from the flat binary the
 *      kernel loads. Zeroing them here is both correct AND a genuine EL0 store
 *      workout across ~600 bytes before main() ever runs.
 *   2. call main(0, 0).
 *   3. exit(rc) via `svc #0` in case main returns (it shouldn't — the Adder
 *      program calls a10_exit itself).
 *
 * NOTE: this is linked at the FIXED VA 0x4801_0000 (user.lds) inside the fine
 * EL0-RW/EL0-X window head.S maps AP=01/UXN=0, and the image is identity-mapped
 * (VA == PA), so the absolute relocations the -mcmodel=small code emits resolve
 * correctly once the kernel copies the blob to that address.
 */

    .section .text.start, "ax"
    .globl _start
    .type _start, %function
_start:
    /* 1) zero .bss (EL0 stores through the AP=01 window). */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:
    /* 2) main(0, 0) — the Adder entry point. */
    mov     x0, #0
    mov     x1, #0
    bl      main

    /* 3) exit(main's rc) if it ever returns. */
    mov     x8, #93                     /* __NR_exit (aarch64) */
    svc     #0
3:  b       3b                          /* exit never resumes EL0 */
    .size _start, .-_start

    .section .note.GNU-stack,"",%progbits
