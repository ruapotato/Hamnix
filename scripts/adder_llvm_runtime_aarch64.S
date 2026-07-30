/*
 * scripts/adder_llvm_runtime_aarch64.S — freestanding AArch64 runtime for the
 * Adder LLVM backend's `--target=aarch64` output, so a whole Adder program can
 * be BUILT AND RUN for aarch64 on an x86 host (under qemu-aarch64) with no
 * cross libc installed.
 *
 * The x86 lane links scripts/adder_llvm_runtime.c against glibc for _start and
 * the two prelude helpers that fall outside the SSA integer subset. There is no
 * aarch64 libc on this host (only binutils + clang's aarch64 backend), so the
 * aarch64 lane supplies the same two things directly against the kernel ABI:
 *
 *   _start      — call main(0,0), then exit(rc & 0xff) via `svc #0` (__NR_exit
 *                 = 93 on the asm-generic aarch64 ABI). A returning main must
 *                 never fall off the end.
 *   sys_write   — the raw write(2) primitive Adder programs declare `extern`
 *                 and build their own print_u64 on: __NR_write = 64, args
 *                 already in x0/x1/x2 per the AAPCS64 -> Linux syscall mapping.
 *
 * Deliberately NOT a C file: compiling C would need aarch64 system headers.
 * Deliberately NOT reusing arch/arm64/llvm/user_rt.S: that crt0 is linked at a
 * FIXED kernel-window VA for the A10 EL0 blob and zeroes .bss by hand because
 * the kernel loads a flat binary; here the ELF loader zeroes .bss for us and
 * the image is an ordinary static Linux ELF.
 *
 * Used by scripts/test_arm64_llvm_lane_diff.sh.
 */

    .text

    .globl _start
    .type _start, %function
_start:
    mov     x0, #0
    mov     x1, #0
    bl      main
    and     x0, x0, #0xff               /* exit status is the low byte */
    mov     x8, #93                     /* __NR_exit */
    svc     #0
1:  b       1b                          /* exit never returns */
    .size _start, .-_start

    .globl sys_write
    .type sys_write, %function
sys_write:
    mov     x8, #64                     /* __NR_write */
    svc     #0
    ret
    .size sys_write, .-sys_write

    .section .note.GNU-stack,"",%progbits
