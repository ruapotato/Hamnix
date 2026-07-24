/*
 * arch/arm64/llvm/head.S — AArch64 boot entry for the LLVM whole-kernel lane
 * (docs/arm64_llvm_scoping.md Phase A3; scripts/build_kernel_llvm_arm64.sh).
 *
 * QEMU's `-M virt -kernel <img>` loads the image at physical 0x4008_0000 and
 * enters at its first byte on the primary CPU with the MMU off. This stub is the
 * reset entry: it parks secondary CPUs, drops EL2->EL1 if the model started at
 * EL2, installs the boot stack, zeroes .bss, sets TPIDR_EL1 (the A2 per-CPU base
 * the LLVM emitter reads), installs VBAR_EL1, and prints a banner over the PL011
 * UART with the MMU still off. It then builds a minimal identity page table
 * (device 0-1GiB, RAM 1-2GiB Normal-WB) and enables the MMU + caches.
 *
 * PROOF OF LLVM ADDER EXECUTION: it then calls a PURE emitted Adder leaf from the
 * LLVM kernel object — kernel_printk_printk__fmt_is_flag(c), which returns 1 iff
 * c is a printf flag char ('-','+',' ','#','0') — over a fixed input vector and
 * prints the result bits. Matching the expected "101110" proves the Adder LLVM
 * backend's output runs correctly on aarch64. (start_kernel itself is an LLVM
 * bail — not in the object — so full kernel init is a later phase; see the doc.)
 *
 * Mirrors arch/x86/kernel/head_64.S (bss-zero + stack + jump-to-Adder) and
 * arch/arm64/boot.S (the standalone-kernel EL1 entry), unified for this lane.
 */

    .equ PL011_BASE,    0x09000000
    .equ PL011_DR,      0x00
    .equ PL011_FR,      0x18
    .equ PL011_FR_TXFF, 0x20        /* FR bit5: transmit FIFO full */

    .section .boot.text, "ax"
    .globl _start
    .type _start, %function
_start:
    /* Park secondary CPUs (only affinity-0 runs the kernel). */
    mrs     x0, mpidr_el1
    and     x0, x0, #0xff
    cbnz    x0, park

    /* Drop to EL1 if we entered at EL2 (QEMU virt default without EL3 fw). */
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    at_el1
    mov     x0, #(1 << 31)          /* HCR_EL2.RW=1: EL1 is AArch64 */
    msr     hcr_el2, x0
    mov     x0, #0x3c5              /* SPSR_EL2: M=EL1h, DAIF all masked */
    msr     spsr_el2, x0
    adr     x0, at_el1
    msr     elr_el2, x0
    eret

at_el1:
    /* Boot stack (16-byte aligned, from the linker script). */
    ldr     x0, =__stack_top
    mov     sp, x0

    /* Zero .bss (includes the L1 page table + per-CPU scratch). */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:

    /* TPIDR_EL1 = per-CPU base (the A2 percpu emission reads this register). */
    ldr     x0, =__percpu_scratch
    msr     tpidr_el1, x0

    /* Install exception vectors. */
    ldr     x0, =arm64_llvm_vectors
    msr     vbar_el1, x0
    isb

    /* Banner over PL011 with the MMU still off. */
    ldr     x0, =banner
    bl      uart_puts

    /* Bring up the MMU + caches, then confirm. */
    bl      mmu_enable
    ldr     x0, =msg_mmu
    bl      uart_puts

    /* Run the LLVM-Adder execution proof. */
    bl      llvm_proof

    ldr     x0, =msg_ok
    bl      uart_puts

    /* A4 (docs/arm64_llvm_scoping.md): enter REAL kernel early-init. Unlike the
     * A3 leaf proof, start_kernel_early() is a genuine slice of start_kernel
     * (setup_early_printk, __stack_chk_init, fb_init_early, trap_init + its
     * printk0 banners), emitted by the LLVM backend and run over the PL011-
     * routed 8250 console (see intrinsics.S). Its "Hamnix ..." lines are the
     * furthest-point checkpoints; a fault dumps ESR_EL1/ELR_EL1 via vectors.S. */
    ldr     x0, =msg_a4
    bl      uart_puts
    bl      start_kernel_early
    ldr     x0, =msg_a4_ret
    bl      uart_puts

    /* A5 (docs/arm64_llvm_scoping.md): go PAST mem_init. start_kernel_mem_arm64()
     * runs the aarch64 memory-init port (memblock -> buddy -> slab, skipping the
     * x86 CR3/PML4 page-table work) then the arch-neutral MM/slab smoke proofs,
     * all emitted by the LLVM backend over the PL011-routed console. A fault
     * dumps ESR_EL1/ELR_EL1 via vectors.S. */
    ldr     x0, =msg_a5
    bl      uart_puts
    bl      start_kernel_mem_arm64
    ldr     x0, =msg_a5_ret
    bl      uart_puts

    /* A6 (docs/arm64_llvm_scoping.md): peel the next arch-neutral init slices
     * (rcu/sched/softirq/workqueue) past the MM boundary, emitted by the LLVM
     * backend, then bring up GICv2 + the ARM generic timer and take the FIRST
     * SCHEDULER TICK — the gic.S IRQ stub acks the GIC and calls the emitted-
     * Adder tick handler arm64_do_timer_tick(). A fault dumps ESR/ELR (vectors.S). */
    ldr     x0, =msg_a6
    bl      uart_puts
    bl      start_kernel_post_mm_arm64
    ldr     x0, =msg_a6_ret
    bl      uart_puts

    /* GICv2 + generic-timer: enable the controller + timer and unmask IRQs.
     * From here IRQs are on; each virtual-timer PPI vectors to gic.S's
     * arm64_llvm_irq_entry -> arm64_do_timer_tick(). After a few ticks the
     * handler masks IRQs and we fall through to the wfi park loop. */
    ldr     x0, =msg_tmr
    bl      uart_puts
    bl      gic_timer_init

    /* Let the A6 timer proof finish BEFORE dropping to EL0: wait (wfi) until the
     * emitted-Adder handler has taken its full tick quota (arm64_llvm_tick_count
     * reaches ARM64_LLVM_TICK_LIMIT == 5), at which point gic.S leaves the timer
     * disabled so no further IRQs arrive. Without this, the immediate EL0 eret
     * (IRQs masked in SPSR) would starve the ~10ms tick and regress A6. */
1:  ldr     x0, =arm64_llvm_tick_count
    ldr     x0, [x0]
    cmp     x0, #5
    b.ge    2f
    wfi
    b       1b
2:

    /* A7 (docs/arm64_llvm_scoping.md): drop to EL0 and service a user `svc #0`.
     * arm64_el0_launch erets into a tiny EL0 program that does write(1,...) +
     * exit(0); each svc traps to the vectors.S Lower-EL sync slot (0x400) ->
     * arm64_llvm_lower_sync_entry -> the emitted-Adder dispatcher
     * arm64_svc_dispatch_arm64(). On exit() the sync stub restores this kernel
     * context and returns here — a full EL0<->EL1 round-trip. The "RUNS
     * USERSPACE" milestone. A fault dumps ESR/ELR via vectors.S. */
    ldr     x0, =msg_a7
    bl      uart_puts
    bl      arm64_el0_launch
    ldr     x0, =msg_a7_ret
    bl      uart_puts

park:
    wfi
    b       park
    .size _start, .-_start

/* ------------------------------------------------------------------------ *
 * MMU: identity map, 1 GiB L1 blocks. entry0 = device (0-1GiB: PL011/GIC),
 * entry1 = RAM (0x4000_0000-0x7FFF_FFFF) Normal-WB, EL1-only. MAIR/TCR/SCTLR
 * constants match the proven standalone kernel (arch/arm64/kmain.ad).
 * ------------------------------------------------------------------------ */
    .type mmu_enable, %function
mmu_enable:
    ldr     x0, =l1_pgtable
    mov     x1, #0x401              /* device block: VALID|AF|AttrIndx0 */
    str     x1, [x0, #0]
    movz    x1, #0x0705             /* RAM block: VALID|AF|SH_inner|AttrIndx1, AP=00
                                     * (EL1 RW, EL0 no DATA access). A7 runs the EL0
                                     * user task from this identity-mapped block: EL0
                                     * instruction fetch is allowed (UXN=0), and the
                                     * register-only demo does no EL0 load/store, so
                                     * AP=00 suffices AND keeps kernel RAM unreadable
                                     * from EL0. A real task needing an EL0 data stack
                                     * needs a per-task EL0-RW (AP=01) L2/L3 mapping —
                                     * that is A8 (see docs/arm64_llvm_scoping.md). */
    movk    x1, #0x4000, lsl #16    /* | PA 0x4000_0000 */
    str     x1, [x0, #8]

    movz    x2, #0xff04             /* MAIR: attr0=Device-nGnRE, attr1=Normal-WB */
    msr     mair_el1, x2
    movz    x2, #0x3519             /* TCR: T0SZ=25, WB/WA, inner-shareable, 4K */
    movk    x2, #0x0001, lsl #32    /*      | IPS=1 (bit32) => 0x1_0000_3519 */
    msr     tcr_el1, x2
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, xzr

    dsb     ish
    tlbi    vmalle1is
    dsb     ish
    isb

    mrs     x2, sctlr_el1
    orr     x2, x2, #0x1            /* M: MMU enable */
    orr     x2, x2, #0x4           /* C: data cache */
    orr     x2, x2, #0x1000        /* I: instruction cache */
    msr     sctlr_el1, x2
    isb
    ret
    .size mmu_enable, .-mmu_enable

/* ------------------------------------------------------------------------ *
 * LLVM-Adder execution proof: call the pure emitted leaf fmt_is_flag over a
 * fixed char vector and print each 0/1 result. Expected: 101110.
 * ------------------------------------------------------------------------ */
    .type llvm_proof, %function
llvm_proof:
    stp     x19, x30, [sp, #-16]!
    stp     x20, x21, [sp, #-16]!
    ldr     x0, =msg_fmt
    bl      uart_puts
    ldr     x19, =test_chars        /* '+','A','0','#',' ','z' */
    mov     x20, #6
1:  ldrb    w0, [x19], #1
    bl      kernel_printk_printk__fmt_is_flag
    add     x0, x0, #0x30           /* '0' + result bit */
    bl      uart_putc
    subs    x20, x20, #1
    b.ne    1b
    mov     x0, #10                 /* '\n' */
    bl      uart_putc
    ldp     x20, x21, [sp], #16
    ldp     x19, x30, [sp], #16
    ret
    .size llvm_proof, .-llvm_proof

/* ------------------------------------------------------------------------ *
 * PL011 console primitives (shared with arch/arm64/llvm/vectors.S).
 *   uart_putc:  x0 = byte                 (clobbers x9,x10)
 *   uart_puts:  x0 = ptr to NUL string
 *   uart_puthex:x0 = 64-bit value -> 16 hex digits
 * ------------------------------------------------------------------------ */
    .globl uart_putc
    .type uart_putc, %function
uart_putc:
    movz    x9, #0x0900, lsl #16    /* PL011_BASE = 0x0900_0000 */
1:  ldr     w10, [x9, #PL011_FR]
    tst     w10, #PL011_FR_TXFF
    b.ne    1b
    strb    w0, [x9, #PL011_DR]
    ret
    .size uart_putc, .-uart_putc

    .globl uart_puts
    .type uart_puts, %function
uart_puts:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0
1:  ldrb    w0, [x19], #1
    cbz     w0, 2f
    bl      uart_putc
    b       1b
2:  ldp     x19, x30, [sp], #16
    ret
    .size uart_puts, .-uart_puts

    .globl uart_puthex
    .type uart_puthex, %function
uart_puthex:
    stp     x19, x30, [sp, #-16]!
    stp     x20, x21, [sp, #-16]!
    mov     x19, x0
    mov     x20, #60
1:  lsr     x0, x19, x20
    and     x0, x0, #0xf
    cmp     x0, #10
    b.lt    2f
    add     x0, x0, #('A' - 10)
    b       3f
2:  add     x0, x0, #'0'
3:  bl      uart_putc
    subs    x20, x20, #4
    b.ge    1b
    ldp     x20, x21, [sp], #16
    ldp     x19, x30, [sp], #16
    ret
    .size uart_puthex, .-uart_puthex

/* ------------------------------------------------------------------------ */
    .section .rodata
    .balign 8
banner:
    .asciz  "HAMNIX aarch64 LLVM-kernel: EL1 entry OK (PL011 early console)\n"
msg_mmu:
    .asciz  "MMU: identity map enabled (device 0-1G, RAM 1-2G Normal-WB, caches on)\n"
msg_fmt:
    .asciz  "LLVM-ADDER fmt_is_flag[+,A,0,#,sp,z]="
msg_ok:
    .asciz  "LLVM-ADDER-OK: emitted Adder code executed on aarch64\n"
msg_a4:
    .asciz  "A4: entering start_kernel_early (real kernel init over PL011)\n"
msg_a4_ret:
    .asciz  "A4: start_kernel_early returned\n"
msg_a5:
    .asciz  "A5: entering start_kernel_mem_arm64 (aarch64 mem_init port)\n"
msg_a5_ret:
    .asciz  "A5: start_kernel_mem_arm64 returned\n"
msg_a6:
    .asciz  "A6: entering start_kernel_post_mm_arm64 (rcu/sched/softirq/workqueue)\n"
msg_a6_ret:
    .asciz  "A6: start_kernel_post_mm_arm64 returned\n"
msg_tmr:
    .asciz  "A6: gic_timer_init (GICv2 + generic timer, unmasking IRQs)\n"
msg_a7:
    .asciz  "A7: dropping to EL0 (arm64_el0_launch -> first user task)\n"
msg_a7_ret:
    .asciz  "A7: EL0 task exited, returned to kernel (svc round-trip complete)\n"
test_chars:
    .byte   '+', 'A', '0', '#', ' ', 'z'

/* ------------------------------------------------------------------------ *
 * .bss reservations: L1 page table (4 KiB aligned) + per-CPU scratch page.
 * ------------------------------------------------------------------------ */
    .section .bss
    .balign 4096
    .globl l1_pgtable
l1_pgtable:
    .space  4096
    .balign 4096
    .globl __percpu_scratch
__percpu_scratch:
    .space  4096
