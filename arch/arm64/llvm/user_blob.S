/*
 * arch/arm64/llvm/user_blob.S — embeds the A10 EL0 user image into the kernel
 * (docs/arm64_llvm_scoping.md A10).
 *
 * This lane boots with `-kernel` and has no disk, so the user program travels
 * INSIDE the kernel image, exactly like an initramfs-embedded init. The blob is
 * the flat binary produced by scripts/build_kernel_llvm_arm64.sh step 3a:
 *
 *   user/arm64_a10_el0.ad
 *     --(host_ac --backend=llvm --target=aarch64)--> a10_user.ll
 *     --(clang -c --target=aarch64-none-elf)-------> a10_user.o
 *     --(ld -T user.lds, with user_rt.S crt0)------> a10_user.elf @ 0x4801_0000
 *     --(objcopy -O binary)------------------------> a10_user.bin   <- .incbin'd here
 *
 * The assembler is invoked with `-I <build dir>` so `a10_user.bin` resolves to
 * the freshly built artifact — the blob can never be stale relative to the .ad
 * source, because the build script regenerates it on every kernel build.
 *
 * The bounds are exposed to Adder as two accessor FUNCTIONS rather than as data
 * symbols, because init/main.ad declares foreign symbols with `extern def`.
 * init/main.ad's arm64_a10_load_arm64() calls them to copy the image to its link
 * VA before the kernel erets to it.
 */

    .section .rodata
    .balign 16
arm64_a10_blob_start:
    .incbin "a10_user.bin"
arm64_a10_blob_end:

    .section .text
    .globl arm64_a10_blob_base
    .type arm64_a10_blob_base, %function
arm64_a10_blob_base:
    ldr     x0, =arm64_a10_blob_start
    ret
    .size arm64_a10_blob_base, .-arm64_a10_blob_base

    .globl arm64_a10_blob_size
    .type arm64_a10_blob_size, %function
arm64_a10_blob_size:
    ldr     x0, =arm64_a10_blob_end
    ldr     x1, =arm64_a10_blob_start
    sub     x0, x0, x1
    ret
    .size arm64_a10_blob_size, .-arm64_a10_blob_size

    .section .note.GNU-stack,"",%progbits
