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
 * The bounds are plain GLOBAL DATA SYMBOLS consumed by head.S, which computes
 * base/size and passes them to init/main.ad's arm64_a10_load_arm64() as ordinary
 * AAPCS64 arguments.
 *
 * They are deliberately NOT surfaced to Adder as `extern def` accessor functions.
 * init/main.ad is the SHARED kernel root, compiled for BOTH x86_64 and aarch64;
 * an `extern def` there emits an undefined reference in the x86_64 link as well,
 * where nothing defines these aarch64-only symbols. That is precisely the
 * arch-foreign-undef regression scripts/test_napi.sh's link check found
 * (`undefined reference to arm64_a10_blob_base/_size`). Arch-specific foreign
 * symbols get resolved in the ARCH LAYER (head.S), never declared in shared
 * Adder source.
 *
 * A11 UPDATE — ONE ARCHIVE INSTEAD OF ONE BLOB
 * --------------------------------------------
 * Through A10 the kernel carried exactly one image, so "load the user program"
 * and "load THE blob" were the same operation and nothing in the lane could
 * tell a by-NAME loader from a loader that ignores the name entirely. A11
 * embeds `user_archive.bin` (built by scripts/pack_arm64_user_archive.py in
 * build step 3a2): a magic + count + fixed-width name table + payloads, walked
 * by init/main.ad's arm64_a11_load_named_arm64().
 *
 * The A10 rung keeps working unchanged because its member is still in there
 * under the name "a10"; head.S now asks for it by name like everything else.
 */

    .section .rodata
    .balign 16
    .globl arm64_a11_archive_start
arm64_a11_archive_start:
    .incbin "user_archive.bin"
    .globl arm64_a11_archive_end
arm64_a11_archive_end:

    .section .note.GNU-stack,"",%progbits
