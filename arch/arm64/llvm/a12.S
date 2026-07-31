/*
 * arch/arm64/llvm/a12.S — PER-TASK ADDRESS SPACES (per-task TTBR0 + ASID) for
 * the aarch64 LLVM whole-kernel lane. First increment of A12.
 *
 * WHAT A11 COULD NOT DO
 * ---------------------
 * scripts/build_kernel_llvm_arm64.sh says it plainly: "All members link at the
 * SAME VA and are loaded one at a time, which is the honest scope of A11:
 * several programs, selected by name, not several concurrently resident address
 * spaces (that needs the per-task TTBR0 work)." Every EL0 program so far shared
 * ONE 2 MiB window (head.S's l3_user_pgtable), so loading the second program
 * necessarily destroyed the first.
 *
 * This file builds a real TTBR0 address space PER TASK: each gets its own L1,
 * its own L2 (a copy of the kernel's, so the kernel identity map stays resident
 * in every address space exactly as on x86 — the syscall path runs on the
 * task's TTBR0 and must still reach kernel memory), and its own L3 whose 512
 * leaves map the SAME user VA range 0x4800_0000-0x481F_FFFF to a DIFFERENT
 * physical 2 MiB region. Switching tasks is one TTBR0_EL1 write carrying the
 * task's ASID.
 *
 * THE nG=0 TLB TRAP, HANDLED WHILE BUILDING RATHER THAN RETROFITTED
 * ----------------------------------------------------------------
 * docs/arm64_phase50.md root-caused the trap waiting at the end of exactly this
 * port: the standalone kernel mapped the user window with a GLOBAL (nG=0)
 * translation, so a stale global entry shadowed the per-ASID mapping and
 * `tlbi aside1is` — which only evicts per-ASID NON-global entries — could not
 * dislodge it. Producers and consumer then agreed with each other through the
 * stale alias while never touching the real page.
 *
 * Its Option A ("remove the competing global translation") applies verbatim
 * here, and this lane can take it at its cheapest possible moment: head.S's
 * l3_user_pgtable leaves are now built with nG=1 (descriptor 0x0F47, bit 11
 * set) instead of nG=0 (0x0747), and the per-task leaves below match. After
 * that change there is NO global translation anywhere for the user VA range.
 * A8..A11 keep running exactly as before, on ASID 0; the A12 spaces use ASID 1
 * and ASID 2.
 *
 * WHAT IS PROVEN AND WHAT IS NOT — read this before trusting the green gate.
 * Under qemu-system-aarch64 TCG:
 *   - the ASID tagging IS load-bearing and IS tested: forcing every space to
 *     ASID 0 makes space 0 run space 1's program and reds the gate;
 *   - the nG bit is NOT testable here. Reverting both descriptors to nG=0
 *     leaves the gate green, because TCG flushes the whole TLB (globals
 *     included) when the ASID in TTBR0_EL1 changes. Real silicon does not, and
 *     that difference IS the phase-50 bug. So nG=1 is correct-by-architecture
 *     and asserted by INSPECTION in the gate, not by execution. Do not "simplify
 *     it away" because a boot stayed green.
 * The kernel's identity RAM/device blocks stay global: they are EL1-only, they
 * are identical in every address space, and nothing ever re-maps those VAs.
 *
 * Backing store for the per-task windows is reserved in .bss below, so it can
 * never collide with whatever the buddy allocator hands out.
 *
 * Gate: scripts/test_arm64_a12_addrspace.sh.
 */

    .equ USER_L2_IDX,  64           /* (0x4800_0000 - 0x4000_0000) / 2MiB */
    .equ A12_SPACES,   2
    .equ A12_WIN_SIZE, 0x200000     /* 2 MiB per task window */
    /* Page descriptor: VALID(11) | AttrIndx1 | AP=01 | SH_inner | AF | nG.
     * Same as head.S's 0x747 EL0-RW leaf plus nG (bit 11) — see above. */
    .equ A12_PTE_FLAGS, 0x0F47

    .section .text

/* ------------------------------------------------------------------------ *
 * arm64_a12_build_spaces — build A12_SPACES independent TTBR0 address spaces.
 * Clobbers x0-x9. No arguments.
 * ------------------------------------------------------------------------ */
    .globl arm64_a12_build_spaces
    .type arm64_a12_build_spaces, %function
arm64_a12_build_spaces:
    stp     x19, x30, [sp, #-16]!
    stp     x20, x21, [sp, #-16]!
    mov     x19, #0                     /* space index */
.Lspace_loop:
    mov     x0, x19
    bl      .Lbuild_one
    add     x19, x19, #1
    cmp     x19, #A12_SPACES
    b.lt    .Lspace_loop
    /* Publish the tables before any TTBR0 switch can walk them. */
    dsb     ish
    isb
    ldp     x20, x21, [sp], #16
    ldp     x19, x30, [sp], #16
    ret
    .size arm64_a12_build_spaces, .-arm64_a12_build_spaces

/* Build one space. x0 = index. Clobbers x0-x9. */
    .type .Lbuild_one, %function
.Lbuild_one:
    lsl     x9, x0, #12                 /* index * 4096 (one table each) */

    ldr     x1, =arm64_a12_l1
    add     x1, x1, x9                  /* x1 = this space's L1 */
    ldr     x2, =arm64_a12_l2
    add     x2, x2, x9                  /* x2 = this space's L2 */
    ldr     x3, =arm64_a12_l3
    add     x3, x3, x9                  /* x3 = this space's L3 */

    /* Copy the kernel L1 (device block + the RAM table pointer) so the kernel
     * identity map is resident in this address space too — the syscall/IRQ
     * path runs on the task's TTBR0 and must still reach kernel memory. */
    ldr     x4, =l1_pgtable
    mov     x5, #0
1:  ldr     x6, [x4, x5, lsl #3]
    str     x6, [x1, x5, lsl #3]
    add     x5, x5, #1
    cmp     x5, #512
    b.lt    1b

    /* Copy the kernel L2 (512 identity 2 MiB EL1-only blocks). */
    ldr     x4, =l2_pgtable
    mov     x5, #0
2:  ldr     x6, [x4, x5, lsl #3]
    str     x6, [x2, x5, lsl #3]
    add     x5, x5, #1
    cmp     x5, #512
    b.lt    2b

    /* Point this space's L1[1] at its OWN L2, and that L2's user slot at its
     * OWN L3 — otherwise every space would share the kernel's single window,
     * which is the whole thing A12 exists to stop. */
    orr     x6, x2, #0x3
    str     x6, [x1, #8]
    orr     x6, x3, #0x3
    mov     x5, #USER_L2_IDX
    str     x6, [x2, x5, lsl #3]

    /* Fill the L3: 512 x 4 KiB leaves mapping the SAME VA window to THIS
     * space's private backing region. nG=1 (see the header). */
    ldr     x4, =arm64_a12_backing
    mov     x7, #A12_WIN_SIZE
    madd    x4, x0, x7, x4              /* backing PA = base + idx * 2MiB */
    mov     x5, #0
    movz    x8, #A12_PTE_FLAGS
3:  add     x6, x4, x5, lsl #12
    orr     x6, x6, x8
    str     x6, [x3, x5, lsl #3]
    add     x5, x5, #1
    cmp     x5, #512
    b.lt    3b
    ret
    .size .Lbuild_one, .-.Lbuild_one

/* ------------------------------------------------------------------------ *
 * arm64_a12_switch — install space x0's TTBR0 with ASID (x0 + 1).
 *
 * NO TLB maintenance here, deliberately. Every user-VA translation in the
 * system is non-global and ASID-tagged, so ASID 1 and ASID 2 cannot see each
 * other's entries and neither can see ASID 0's (A8..A11). If this switch needed
 * a flush to be correct, some global alias would still exist and
 * docs/arm64_phase50.md's failure would be back. Caveat for whoever takes this
 * to hardware: TCG flushes on ASID change anyway, so "it booted" does not yet
 * prove the no-flush path on silicon. It is the ASID recycling case (more tasks
 * than ASIDs) that will need real invalidation, and there is none of that yet.
 * ------------------------------------------------------------------------ */
    .globl arm64_a12_switch
    .type arm64_a12_switch, %function
arm64_a12_switch:
    lsl     x9, x0, #12
    ldr     x1, =arm64_a12_l1
    add     x1, x1, x9                  /* table PA (identity-mapped) */
    add     x2, x0, #1                  /* ASID = index + 1 */
    lsl     x2, x2, #48
    orr     x1, x1, x2
    dsb     ish
    msr     ttbr0_el1, x1
    isb
    ret
    .size arm64_a12_switch, .-arm64_a12_switch

/* ------------------------------------------------------------------------ *
 * arm64_a12_switch_kernel — back to the boot address space (ASID 0).
 * ------------------------------------------------------------------------ */
    .globl arm64_a12_switch_kernel
    .type arm64_a12_switch_kernel, %function
arm64_a12_switch_kernel:
    ldr     x1, =l1_pgtable
    dsb     ish
    msr     ttbr0_el1, x1               /* ASID 0 */
    isb
    ret
    .size arm64_a12_switch_kernel, .-arm64_a12_switch_kernel

/* ------------------------------------------------------------------------ *
 * arm64_a12_window_differs — INDEPENDENT check, run from EL1 with the kernel
 * TTBR0 installed, that the two spaces are backed by DIFFERENT physical pages.
 *
 * This reads the BACKING REGIONS by their identity PAs, so it does not go
 * through either task's mapping and cannot be fooled by a TLB alias. Returns
 * in x0 the first differing byte offset + 1, or 0 if the two 4 KiB pages at
 * offset 0x10000 (where the loader puts the program image) are identical.
 * Two different programs were loaded there, so identical pages == one shared
 * window == A12 did nothing.
 * ------------------------------------------------------------------------ */
    .globl arm64_a12_window_differs
    .type arm64_a12_window_differs, %function
arm64_a12_window_differs:
    ldr     x1, =arm64_a12_backing
    add     x1, x1, #0x10000            /* space 0 image page */
    mov     x3, #A12_WIN_SIZE
    add     x2, x1, x3                  /* space 1 image page */
    mov     x4, #0
1:  ldrb    w5, [x1, x4]
    ldrb    w6, [x2, x4]
    cmp     w5, w6
    b.ne    2f
    add     x4, x4, #1
    cmp     x4, #4096
    b.lt    1b
    mov     x0, #0                      /* identical -> spaces are NOT distinct */
    ret
2:  add     x0, x4, #1
    ret
    .size arm64_a12_window_differs, .-arm64_a12_window_differs

/* ------------------------------------------------------------------------ *
 * Page tables + private backing store. The backing store lives in .bss so it
 * can never collide with buddy-allocator pages.
 * ------------------------------------------------------------------------ */
    .section .bss
    .balign 4096
    .globl arm64_a12_l1
arm64_a12_l1:
    .space  4096 * A12_SPACES
    .balign 4096
    .globl arm64_a12_l2
arm64_a12_l2:
    .space  4096 * A12_SPACES
    .balign 4096
    .globl arm64_a12_l3
arm64_a12_l3:
    .space  4096 * A12_SPACES
    .balign 0x200000
    .globl arm64_a12_backing
arm64_a12_backing:
    .space  A12_WIN_SIZE * A12_SPACES
    /* Explicit .size so the gate can pin the reservation from the ELF: a
     * refactor that collapsed the two spaces onto one region would otherwise
     * pass the runtime check vacuously. */
    .size   arm64_a12_backing, A12_WIN_SIZE * A12_SPACES

    .section .note.GNU-stack,"",%progbits
