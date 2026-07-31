/*
 * arch/arm64/llvm/a13.S — DEMAND PAGING (Data/Instruction Abort from EL0) for the
 * aarch64 LLVM whole-kernel lane. A13.
 *
 * WHAT A12 COULD NOT DO
 * ---------------------
 * A12 gave each task its own TTBR0 address space, but every leaf of every space
 * was stamped VALID at build time. An address space therefore had to be FULLY
 * PRE-POPULATED before a task could touch it, and any EC=0x24 arriving from EL0
 * was not merely unhandled — it was MISREAD. el0.S's Lower-EL synchronous stub
 * dispatched EVERY synchronous exception from EL0 into the SYSCALL dispatcher
 * without ever looking at ESR_EL1.EC, so a data abort was decoded as a syscall
 * whose number happened to be whatever the faulting program left in x8. That is
 * worse than a crash: it returns a value in x0 and erets, so the task resumes and
 * the log stays plausible. (A11's exit-latch bug was the same shape and is called
 * out in init/main.ad: a truncated run that "looked like a working demo".)
 *
 * A13 does two things:
 *   1. el0.S now DECODES ESR_EL1.EC. Only EC=0x15 (SVC64) reaches the syscall
 *      dispatcher. EC=0x24/0x20 (Data/Instruction Abort from a lower EL) reach
 *      the fault path below. Everything else goes to the loud diagnostic vector.
 *   2. A page fault is now SERVICEABLE. The A13 address space leaves a 16-page
 *      window (VA 0x4814_0000..0x4814_FFFF) INVALID. The first EL0 touch of each
 *      page traps, the kernel walks the live TTBR0 tables, allocates and zeroes a
 *      frame, stamps the leaf, invalidates that VA, and erets with ELR_EL1
 *      UNCHANGED so the faulting instruction RETRIES. The task never learns it
 *      faulted.
 *
 * WHAT A REFUSAL DOES — and why the negative control is a runtime path.
 * A fault the kernel will not service (VA outside the demand region, a leaf that
 * is already valid, a fault that is not a translation fault, an exhausted frame
 * pool) does NOT halt the kernel: the handler latches an exit status of 139
 * (128+SIGSEGV) and the stub unwinds to head.S exactly like exit() does. That is
 * the correct kernel behaviour (kill the task, keep running) AND it makes the
 * negative control executable rather than inspected: the 'segv' EL0 program
 * touches an EL1-only VA, is killed, and the boot continues.
 *
 * THE POLICY IS EMITTED ADDER, NOT ASSEMBLY.
 * This file does only what Adder cannot express: read FAR_EL1/ESR_EL1/TTBR0_EL1
 * and issue `tlbi`. The decision — range check, fault-class check, page-table
 * walk, frame allocation, leaf stamping — is init/main.ad's
 * arm64_a13_demand_fault_arm64(), compiled by the same LLVM backend as the rest
 * of the kernel. Same split as A9's scheduler and A8's syscall dispatcher.
 *
 * nG, AND WHAT TCG CANNOT SHOW YOU (unchanged from a12.S, and it still binds).
 * The demand leaves are stamped nG=1 (0x0F47) like every other user-VA leaf, and
 * this file's flush uses `tlbi vaae1is` — by-VA, ALL ASIDs — which is the one
 * form that is correct whether or not a stale global alias exists. QEMU TCG
 * flushes the whole TLB on an ASID change and so cannot discriminate nG at all;
 * see scripts/test_arm64_a12_addrspace.sh's header. The nG assertion here is
 * therefore INSPECTION, as it is there. What IS executed here is that a fault
 * arrives, is serviced, and the retry sees the new mapping — which requires the
 * invalidate to have worked for the invalid->valid transition.
 *
 * Gate: scripts/test_arm64_a13_demand.sh.
 */

    .equ USER_L2_IDX,     64            /* (0x4800_0000 - 0x4000_0000) / 2MiB */
    .equ A13_WIN_SIZE,    0x200000      /* 2 MiB user window, as in a12.S */
    .equ A13_PTE_FLAGS,   0x0F47        /* VALID|AttrIndx1|AP=01|SH|AF|nG — nG=1 */
    .equ A13_DEMAND_L3,   320           /* (0x4814_0000 - 0x4800_0000) / 4KiB */
    .equ A13_DEMAND_PAGES, 16           /* 0x4814_0000 .. 0x4814_FFFF */
    .equ A13_POOL_PAGES,  16            /* frames available to the fault handler */
    .equ A13_ASID,        3             /* A8..A11 use 0; A12 uses 1 and 2 */

    .section .text

/* ------------------------------------------------------------------------ *
 * arm64_a13_build_space — build the A13 TTBR0 address space (ASID 3).
 *
 * Identical in shape to a12.S's .Lbuild_one (own L1/L2/L3, kernel identity map
 * copied in so the syscall path still reaches kernel memory, private 2 MiB
 * backing region) with ONE difference that is the entire point: the 16 leaves of
 * the demand window are left ZERO — an INVALID descriptor. Touching them from
 * EL0 is a translation fault, not a mapped page.
 * ------------------------------------------------------------------------ */
    .globl arm64_a13_build_space
    .type arm64_a13_build_space, %function
arm64_a13_build_space:
    ldr     x1, =arm64_a13_l1
    ldr     x2, =arm64_a13_l2
    ldr     x3, =arm64_a13_l3

    /* Copy the kernel L1 (device block + RAM table pointer). */
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

    /* This space's own L2, and that L2's user slot -> this space's own L3. */
    orr     x6, x2, #0x3
    str     x6, [x1, #8]
    orr     x6, x3, #0x3
    mov     x5, #USER_L2_IDX
    str     x6, [x2, x5, lsl #3]

    /* Fill the L3: 512 x 4 KiB leaves -> this space's private backing region. */
    ldr     x4, =arm64_a13_backing
    mov     x5, #0
    movz    x8, #A13_PTE_FLAGS
3:  add     x6, x4, x5, lsl #12
    orr     x6, x6, x8
    str     x6, [x3, x5, lsl #3]
    add     x5, x5, #1
    cmp     x5, #512
    b.lt    3b

    /* CARVE the demand window back OUT: zero (invalid) descriptors. */
    mov     x5, #A13_DEMAND_L3
    add     x7, x5, #A13_DEMAND_PAGES
4:  str     xzr, [x3, x5, lsl #3]
    add     x5, x5, #1
    cmp     x5, x7
    b.lt    4b

    dsb     ish
    isb
    ret
    .size arm64_a13_build_space, .-arm64_a13_build_space

/* ------------------------------------------------------------------------ *
 * arm64_a13_switch — install the A13 space's TTBR0 with ASID 3.
 * ------------------------------------------------------------------------ */
    .globl arm64_a13_switch
    .type arm64_a13_switch, %function
arm64_a13_switch:
    ldr     x1, =arm64_a13_l1
    movz    x2, #A13_ASID
    lsl     x2, x2, #48
    orr     x1, x1, x2
    dsb     ish
    msr     ttbr0_el1, x1
    isb
    ret
    .size arm64_a13_switch, .-arm64_a13_switch

/* ------------------------------------------------------------------------ *
 * arm64_a13_fault_entry — called from el0.S's Lower-EL sync stub when ESR.EC
 * says Data/Instruction Abort from a lower EL. Reads the registers Adder cannot
 * (FAR_EL1 / ESR_EL1 / TTBR0_EL1), hands them to the emitted-Adder policy, and
 * on success invalidates the faulting VA so the EL0 retry walks the new leaf.
 *
 * Returns x0 = 1 (mapped; retry the faulting instruction) or 0 (refused; the
 * stub unwinds to head.S — the Adder side has already latched status 139).
 *
 * The invalidate is `tlbi vaae1is` (by VA, ALL ASIDs). An invalid->valid
 * transition does not architecturally require a break-before-make, but an
 * implementation is permitted to cache the fact of a translation fault, and this
 * is also the only form that would dislodge a stale GLOBAL alias for the VA if
 * one ever crept back in (docs/arm64_phase50.md). It costs one instruction.
 * ------------------------------------------------------------------------ */
    .globl arm64_a13_fault_entry
    .type arm64_a13_fault_entry, %function
arm64_a13_fault_entry:
    stp     x29, x30, [sp, #-16]!
    mrs     x0, far_el1
    mrs     x1, esr_el1
    mrs     x2, ttbr0_el1
    ldr     x3, =arm64_a13_frame_pool
    mov     x4, #A13_POOL_PAGES
    bl      arm64_a13_demand_fault_arm64
    cbz     x0, 1f
    mrs     x1, far_el1
    lsr     x1, x1, #12                 /* tlbi vaae1is takes VA>>12 */
    dsb     ishst
    tlbi    vaae1is, x1
    dsb     ish
    isb
    mov     x0, #1
1:  ldp     x29, x30, [sp], #16
    ret
    .size arm64_a13_fault_entry, .-arm64_a13_fault_entry

/* ------------------------------------------------------------------------ *
 * Page tables, private backing store, and the demand-fault frame pool.
 *
 * The frame pool is DELIBERATELY a separate .bss reservation from the backing
 * region, so a frame the handler hands out can never be a page the space already
 * mapped. The kernel-side verification reads the pool by its IDENTITY PA, i.e.
 * not through the EL0 mapping, so no TLB alias can fake the result — the same
 * discipline arm64_a12_window_differs uses.
 * ------------------------------------------------------------------------ */
    .section .bss
    .balign 4096
    .globl arm64_a13_l1
arm64_a13_l1:
    .space  4096
    .balign 4096
    .globl arm64_a13_l2
arm64_a13_l2:
    .space  4096
    .balign 4096
    .globl arm64_a13_l3
arm64_a13_l3:
    .space  4096
    .balign 4096
    .globl arm64_a13_frame_pool
arm64_a13_frame_pool:
    .space  4096 * A13_POOL_PAGES
    .size   arm64_a13_frame_pool, 4096 * A13_POOL_PAGES
    .balign 0x200000
    .globl arm64_a13_backing
arm64_a13_backing:
    .space  A13_WIN_SIZE
    .size   arm64_a13_backing, A13_WIN_SIZE

    .section .note.GNU-stack,"",%progbits
