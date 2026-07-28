/*
 * arch/arm64/llvm/user.lds — link script for the A10 EL0 user image
 * (docs/arm64_llvm_scoping.md A10).
 *
 * The image is a FLAT, position-DEPENDENT binary linked at the fixed VA
 * 0x4801_0000, which sits inside the fine EL0-RW/EL0-X window head.S carves out
 * of the identity map (0x4800_0000-0x481F_FFFF, AP=01, UXN=0). Because that
 * window is identity-mapped (VA == PA), the kernel can simply memcpy the blob to
 * 0x4801_0000 and `eret` to it: every absolute relocation clang emitted under
 * -mcmodel=small already points at the right place.
 *
 * Window budget (must not collide with the A8/A9 users of the same window):
 *   0x4800_0000  A8 SRC buffer
 *   0x4800_1000  A8 DST buffer
 *   0x4800_4000  A9 task-A message buffer
 *   0x4800_5000  A9 task-B message buffer
 *   0x4801_0000  >>> A10 user image (text/rodata/data/bss) <<<
 *   0x481A_0000  A10 EL0 stack top
 *   0x481C_0000  A9 task-B EL0 stack top
 *   0x481E_0000  A9 task-A EL0 stack top
 *   0x481F_0000  A8 EL0 stack top
 * The build script asserts the emitted image stays below 0x4810_0000.
 *
 * _start must come first so the load address IS the entry point — the kernel
 * erets straight to 0x4801_0000 without parsing any header.
 */
ENTRY(_start)

SECTIONS
{
    . = 0x48010000;

    .text : {
        *(.text.start)              /* user_rt.S _start — MUST be first */
        *(.text .text.*)
    }

    .rodata : ALIGN(8) { *(.rodata .rodata.*) }
    .data   : ALIGN(8) { *(.data .data.*) }

    . = ALIGN(8);
    __bss_start = .;
    .bss    : ALIGN(8) { *(.bss .bss.*) *(COMMON) }
    . = ALIGN(8);
    __bss_end = .;

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
