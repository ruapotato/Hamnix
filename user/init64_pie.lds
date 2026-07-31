/*
 * user/init64_pie.lds - ELF64 *PIE* (ET_DYN) linker script for NATIVE Hamnix
 * user programs. Sibling of user/init64.lds, which links ET_EXEC at a fixed
 * low 0x400000.
 *
 * WHY THIS EXISTS — the low-BSS / direct-map collision.
 * ----------------------------------------------------
 * An ET_EXEC image linked at 0x400000 has user virtual addresses that are
 * NUMERICALLY IDENTICAL to low physical RAM, i.e. the kernel's own identity
 * direct map. For a small image that is merely untidy; for a large one it is a
 * kernel memory-corruption hazard. hambrowse carries ~174 MiB of static BSS, so
 * its ELF64 image spans user vaddrs [0x400000, 0xB35E000) and aliases physical
 * RAM 4-188 MiB — most of MEMBLOCK's [0x200000, 0x0F000000) pool. Under a
 * shared PML4[0] BOTH loader strategies lose:
 *
 *   * demand-BSS punches all 44,501 leaves not-present, so the demand
 *     resolver's own low-RAM touches fault recursively and the box wedges
 *     with interrupts off;
 *   * eager full-span installs user PTEs across the window, so the kernel
 *     reaches a direct-map VA and lands on the app's BSS (reproduced 5/5 as
 *     `[pf] kernel write to RO user page va=0x0a890d98` in page_set_rmap).
 *
 * It is only luck that it faults rather than silently scribbling on a
 * *writable* user page, which would corrupt with no fault and no diagnostic.
 *
 * ET_DYN removes the aliasing BY CONSTRUCTION. fs/elf.ad's _load_elf64 ET_DYN
 * arm rebases the image to a load base of its own choosing — either the ASLR
 * vbase (high, above the 4 GiB direct map) or, on a deterministic boot,
 * identity at the image's OWN memblock `region`. In both cases the image's user
 * vaddrs only ever cover its own pages, which is exactly the property the
 * native ELF32 lane has always had and is why the native lane never hit this.
 *
 * ET_DYN AND RELOCATIONS. The loader applies R_X86_64_RELATIVE from
 * PT_DYNAMIC's DT_RELA/DT_RELASZ (fs/elf.ad::_elf64_apply_relative_relocs), so
 * .rela.dyn MUST be inside a PT_LOAD and PT_DYNAMIC must be present. Both fall
 * out of a plain `ld -pie` as long as the script does not discard them —
 * hence the explicit .dynamic / .rela.dyn / .got placements below. Anything
 * needing a SYMBOLIC reloc (R_X86_64_64 against an undefined symbol, a PLT, a
 * GOT slot that is not link-time-resolvable) is NOT supported; the build is
 * -static -nostdlib with every symbol defined in-image, so the only dynamic
 * relocation kind that survives is R_X86_64_RELATIVE. scripts/build_user.sh's
 * PIE gate asserts that, so a future toolchain change cannot silently
 * introduce a kind the loader would ignore.
 */

OUTPUT_FORMAT("elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS {
    text    PT_LOAD    FLAGS(5);   /* R+X */
    data    PT_LOAD    FLAGS(6);   /* R+W */
    dynamic PT_DYNAMIC FLAGS(4);   /* R   */
}

SECTIONS
{
    /* Base 0: a PIE is rebased wholesale by the loader, so the link-time base
     * is arbitrary. Keep the ELF + program headers INSIDE the first PT_LOAD
     * (p_offset=0, p_vaddr=0) — the same layout the ET_EXEC script uses and the
     * one _load_elf64's page-granular user mapping assumes (page-aligned
     * lowest_v == the copy anchor). Do NOT offset by SIZEOF_HEADERS. */
    . = 0;

    .text : ALIGN(16) {
        *(.text)
        *(.text.*)
    } : text

    .rodata : ALIGN(16) {
        *(.rodata)
        *(.rodata.*)
    } : text

    /* Dynamic-linking metadata. The loader needs PT_DYNAMIC (for DT_RELA /
     * DT_RELASZ / DT_RELAENT) and the .rela.dyn payload itself to be
     * file-backed and inside a PT_LOAD. They are read-only, so they ride the
     * text segment. */
    .dynamic : ALIGN(8) { *(.dynamic) } : text : dynamic
    .rela.dyn : ALIGN(8) {
        *(.rela.init) *(.rela.text) *(.rela.text.*)
        *(.rela.rodata) *(.rela.rodata.*)
        *(.rela.data) *(.rela.data.*)
        *(.rela.got) *(.rela.bss) *(.rela.dyn)
    } : text
    .dynsym  : ALIGN(8) { *(.dynsym) }  : text
    .dynstr  : ALIGN(8) { *(.dynstr) }  : text
    .hash    : ALIGN(8) { *(.hash) }    : text
    .gnu.hash : ALIGN(8) { *(.gnu.hash) } : text

    . = ALIGN(0x1000);

    /* .data.rel.ro / .got hold the pointers the RELATIVE relocations patch.
     * They must be WRITABLE at load time (the loader writes them through the
     * image's identity `region` mapping before the W^X read-only flip, but
     * keeping them in the RW segment is what makes that correct rather than
     * incidental). */
    .data.rel.ro : ALIGN(16) { *(.data.rel.ro) *(.data.rel.ro.*) } : data
    .got : ALIGN(8) { *(.got) *(.got.plt) } : data

    .data : ALIGN(16) {
        *(.data)
        *(.data.*)
    } : data

    .bss : ALIGN(16) {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } : data

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.eh_frame.*)
        *(.interp)
        *(.gnu.version*)
    }
}
