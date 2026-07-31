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

    /* A8 (docs/arm64_llvm_scoping.md): REAL userland foundation. First the kernel
     * (EL1) writes a source string into the fine EL0-RW user window at 0x4800_0000
     * (proving the AP=01 L3 leaves are live), then drops to EL0. The EL0 program
     * (el0.S) getpid()s, exercises its SP_EL0 stack, memcpy's SRC->DST with its OWN
     * EL0 loads/stores, then write(1, DST, len) + exit(0). Each svc traps to the
     * vectors.S Lower-EL sync slot (0x400) -> arm64_llvm_lower_sync_entry -> the
     * emitted-Adder dispatcher arm64_svc_dispatch_arm64() -> arm64_do_syscall_arm64,
     * which routes into the kernel's REAL syscall handlers (current_task_pid,
     * early_putc_user, ...). On exit() the sync stub restores this kernel context
     * and returns here. Proves EL0 accesses its OWN mapped memory AND real kernel
     * syscalls are serviced from EL0. A fault dumps ESR/ELR via vectors.S. */
    /* ELPROBE (elprobe.S): before claiming ANYTHING about "EL0 userland", ask
     * the CPU. The probe erets to a program in the kernel's own .text — the
     * same AP=00 2 MiB block that carries A9's tasks — and executes
     * `mrs x0, CurrentEL`, which is UNDEFINED at EL0 and defined at EL1. The
     * vector SLOT the hardware picks, ESR.EC, SPSR.M and x0 all report the
     * answer. It installs and restores its own VBAR_EL1, so nothing below is
     * perturbed. */
    bl      arm64_elprobe_run

    ldr     x0, =msg_a8
    bl      uart_puts
    bl      arm64_el0_prepare_user_mem_arm64
    bl      arm64_el0_launch
    ldr     x0, =msg_a8_ret
    bl      uart_puts

    /* A9 (docs/arm64_llvm_scoping.md): PREEMPTIVE EL0 scheduling. Build TWO EL0
     * tasks and time-slice them under the ARM generic-timer IRQ. The kernel first
     * fills each task's message buffer in the EL0-RW window, then sched.S's
     * launcher re-arms the timer (EL1 IRQs masked), erets into task A (SPSR.I=0,
     * IRQs on at EL0), and each timer IRQ traps to the Lower-EL IRQ vector (0x480)
     * -> arm64_llvm_lower_irq_entry, which saves the running task's full EL0
     * context and calls the emitted-Adder scheduler arm64_sched_pick_arm64() to
     * round-robin to the other task — a real timer-driven EL0<->EL0 switch. After
     * a fixed switch quota the scheduler stops and the stub returns here. A fault
     * dumps ESR/ELR via vectors.S. */
    ldr     x0, =msg_a9
    bl      uart_puts
    bl      arm64_sched_prepare_arm64
    bl      arm64_el0_sched_launch
    ldr     x0, =msg_a9_ret
    bl      uart_puts

    /* A10 (docs/arm64_llvm_scoping.md): the FIRST REAL EL0 USER PROGRAM. A8/A9
     * ran hand-written assembly at EL0. A10 loads a COMPILED program — the Adder
     * source user/arm64_a10_el0.ad, built by the same Adder LLVM backend that
     * built this kernel, linked flat at 0x4801_0000 and embedded via user_blob.S
     * — into the EL0-RW/EL0-X window (arm64_a10_load_arm64, an exec()-shaped
     * image copy), erets to it (a10.S), lets it issue REAL write/getpid/exit
     * syscalls through the SAME A8 sync-vector path, and then cross-checks the
     * exit status it computed against the independently-known expected value
     * (arm64_a10_verify_arm64). A fault dumps ESR/ELR via vectors.S. */
    ldr     x0, =msg_a10
    bl      uart_puts
    /* The blob bounds are AARCH64-ONLY symbols (user_blob.S). They are passed
     * in as ordinary AAPCS64 arguments rather than declared `extern def` in the
     * SHARED init/main.ad: an extern in shared Adder source becomes an
     * undefined reference in the x86_64 link too, which is exactly the
     * arch-foreign-undef regression scripts/test_napi.sh caught. Arch symbols
     * are resolved HERE, in the arch layer. */
    ldr     x0, =arm64_a11_archive_start   /* x0 = archive base */
    ldr     x1, =arm64_a11_archive_end
    sub     x1, x1, x0                     /* x1 = archive size */
    bl      arm64_a10_load_arm64           /* loads the member named "a10" */
    cbz     x0, park                    /* image missing/oversized -> no eret */
    bl      arm64_a10_launch
    ldr     x0, =msg_a10_ret
    bl      uart_puts
    bl      arm64_a10_verify_arm64

    /* A11 (docs/arm64_llvm_scoping.md): SEVERAL compiled images in ONE embedded
     * archive, selected BY NAME, plus a real read() on the PL011.
     *
     * The order below is deliberate and is the whole point. "sum" is asked for
     * FIRST even though "a10" is the archive's first member, so a loader that
     * ignored the name and copied member 0 would run the A10 program again and
     * print A10's line, not "A11: S=...". Then "echo" — a THIRD, different
     * image — consumes real bytes off the PL011 through the kernel's syscall
     * dispatcher. Finally a name that is NOT in the archive must MISS: a loader
     * that falls back to "whatever was there" is worse than one that fails,
     * because it would make every by-name assertion above vacuous. */
    ldr     x0, =msg_a11
    bl      uart_puts

    ldr     x0, =arm64_a11_archive_start
    ldr     x1, =arm64_a11_archive_end
    sub     x1, x1, x0
    ldr     x2, =name_sum
    bl      arm64_a11_load_named_arm64
    cbz     x0, a11_echo_stage          /* miss -> skip the eret, keep booting */
    bl      arm64_a10_launch            /* same eret path; same link VA */
    ldr     x0, =name_sum
    bl      arm64_a11_report_arm64

a11_echo_stage:
    ldr     x0, =arm64_a11_archive_start
    ldr     x1, =arm64_a11_archive_end
    sub     x1, x1, x0
    ldr     x2, =name_echo
    bl      arm64_a11_load_named_arm64
    cbz     x0, a11_miss_stage
    ldr     x0, =msg_a11_stdin
    bl      uart_puts
    bl      arm64_a10_launch
    ldr     x0, =name_echo
    bl      arm64_a11_report_arm64

a11_miss_stage:
    /* NEGATIVE control: a name the archive does not carry must MISS. */
    ldr     x0, =arm64_a11_archive_start
    ldr     x1, =arm64_a11_archive_end
    sub     x1, x1, x0
    ldr     x2, =name_absent
    bl      arm64_a11_load_named_arm64
    cbz     x0, a11_done                /* 0 == correctly refused */
    ldr     x0, =msg_a11_badhit
    bl      uart_puts
a11_done:
    ldr     x0, =msg_a11_ret
    bl      uart_puts

park:
    wfi
    b       park
    .size _start, .-_start

/* ------------------------------------------------------------------------ *
 * MMU: identity map with a FINE per-page EL0-RW user window (A8).
 *
 * L1[0] = device block (0-1GiB: PL011/GIC), Device-nGnRE, EL1-only.
 * L1[1] = TABLE -> l2_pgtable, covering RAM 0x4000_0000-0x7FFF_FFFF as 512 x 2MiB
 *         Normal-WB blocks, AP=00 (EL1 RW, EL0 no access) — the kernel image +
 *         buddy/slab RAM stay EL1-only exactly as before.
 * ONE L2 slot (index 64 => VA 0x4800_0000) is overridden to a TABLE ->
 *         l3_user_pgtable, whose 512 x 4KiB leaves map 0x4800_0000-0x481F_FFFF
 *         AP=01 (EL0-RW, EL1-RW) + UXN=0 (EL0 exec ok) — the A8 user window.
 *
 * This is the fine L2/L3 EL0-RW mapping the A7 doc called for. It is NOT a
 * block-descriptor AP flip of the whole RAM block: that experiment HUNG MMU-
 * enable on -cpu cortex-a72 (see docs/arm64_llvm_scoping.md). Kernel RAM stays
 * AP=00 (unreadable from EL0); only the carved 2MiB window is EL0-RW.
 * MAIR/TCR/SCTLR constants match the proven standalone kernel (kmain.ad).
 * ------------------------------------------------------------------------ */
    .equ USER_L2_IDX, 64            /* (0x4800_0000 - 0x4000_0000) / 2MiB = 64 */
    .type mmu_enable, %function
mmu_enable:
    ldr     x0, =l1_pgtable
    mov     x1, #0x401              /* device block: VALID|AF|AttrIndx0 */
    str     x1, [x0, #0]
    /* L1[1] = table descriptor -> l2_pgtable (VALID|TABLE). */
    ldr     x2, =l2_pgtable
    orr     x1, x2, #0x3
    str     x1, [x0, #8]

    /* Fill l2_pgtable: 512 identity 2MiB blocks, Normal-WB, AP=00 (EL1-only). */
    ldr     x0, =l2_pgtable
    movz    x3, #0x4000, lsl #16    /* PA base 0x4000_0000 */
    mov     x5, #0                  /* index */
1:  movz    x1, #0x0705             /* block: VALID|AF|SH_inner|AttrIndx1, AP=00 */
    orr     x1, x1, x3              /* | PA */
    str     x1, [x0, x5, lsl #3]
    add     x3, x3, #0x200000       /* +2MiB */
    add     x5, x5, #1
    cmp     x5, #512
    b.lt    1b

    /* Override L2[USER_L2_IDX] with a TABLE descriptor -> l3_user_pgtable. */
    ldr     x0, =l2_pgtable
    ldr     x2, =l3_user_pgtable
    orr     x1, x2, #0x3
    mov     x5, #USER_L2_IDX
    str     x1, [x0, x5, lsl #3]

    /* Fill l3_user_pgtable: 512 identity 4KiB pages over 0x4800_0000-0x481F_FFFF,
     * AP=01 (EL0-RW + EL1-RW), Normal-WB, UXN=0 (EL0 exec allowed) — the A8
     * EL0-RW user window. Page descriptor low bits 0x747 = VALID(11)|AttrIndx1|
     * AP01(bit6)|SH_inner(bits9:8)|AF(bit10). */
    ldr     x0, =l3_user_pgtable
    movz    x3, #0x4800, lsl #16    /* PA base 0x4800_0000 */
    mov     x5, #0
2:  movz    x1, #0x0747             /* page: VALID|AF|SH_inner|AttrIndx1|AP=01 */
    orr     x1, x1, x3
    str     x1, [x0, x5, lsl #3]
    add     x3, x3, #0x1000         /* +4KiB */
    add     x5, x5, #1
    cmp     x5, #512
    b.lt    2b

    movz    x2, #0xff04             /* MAIR: attr0=Device-nGnRE, attr1=Normal-WB */
    msr     mair_el1, x2
    movz    x2, #0x3519             /* TCR: T0SZ=25, WB/WA, inner-shareable, 4K */
    movk    x2, #0x0001, lsl #32    /*      | IPS=1 (bit32) => 0x1_0000_3519 */
    msr     tcr_el1, x2
    ldr     x0, =l1_pgtable         /* TTBR0 = the L1 (top-level) table, NOT the
                                     * L3 that x0 was left holding by the fill loop */
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
msg_a8:
    .asciz  "A8: EL0-RW user window + real syscall dispatch (dropping to EL0)\n"
msg_a8_ret:
    .asciz  "A8: EL0 task exited, returned to kernel (real syscall round-trip complete)\n"
msg_a9:
    .asciz  "A9: preemptive EL0 scheduling (2 tasks, timer-preempted EL0<->EL0)\n"
msg_a9_ret:
    .asciz  "A9: scheduler returned to kernel (bounded preemption demo complete)\n"
msg_a10:
    .asciz  "A10: loading a COMPILED Adder EL0 user program into the user window\n"
msg_a10_ret:
    .asciz  "A10: EL0 user program exited, returned to kernel\n"
msg_a11:
    .asciz  "A11: embedded EL0 image ARCHIVE, loaded BY NAME (+ real read on the PL011)\n"
msg_a11_stdin:
    .asciz  "A11: running 'echo' — it will read(2) a line off the PL011\n"
msg_a11_badhit:
    .asciz  "A11: FAIL load-by-name returned an image for a name NOT in the archive\n"
msg_a11_ret:
    .asciz  "A11: archive stage complete, returned to kernel\n"
/* Member names asked for at runtime. Fixed 16-byte fields in the archive, but
 * these are ordinary NUL-terminated strings — the walk compares up to the NUL
 * and requires the stored name to end there too, so "sum" cannot match a
 * hypothetical "summer". */
name_sum:
    .asciz  "sum"
name_echo:
    .asciz  "echo"
name_absent:
    .asciz  "nosuchprog"
    .balign 8
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
    .globl l2_pgtable               /* A8: L2 for the RAM 1GiB region (512 x 2MiB) */
l2_pgtable:
    .space  4096
    .balign 4096
    .globl l3_user_pgtable          /* A8: L3 for the 2MiB EL0-RW user window */
l3_user_pgtable:
    .space  4096
    .balign 4096
    .globl __percpu_scratch
__percpu_scratch:
    .space  4096
