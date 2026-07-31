/*
 * arch/arm64/llvm/elprobe.S — DECISIVE exception-level probe for the LLVM
 * whole-kernel aarch64 lane.
 *
 * WHY THIS EXISTS
 * ---------------
 * head.S maps all of RAM 0x4000_0000-0x7FFF_FFFF as 2 MiB blocks with
 * descriptor low bits 0x0705, i.e. AP[2:1] = 00 => "EL1 RW, EL0 no access".
 * Only L2[64] (VA 0x4800_0000-0x481F_FFFF) is overridden to an L3 table whose
 * leaves are AP=01 (EL0-RW). Yet A9's two "EL0" tasks (sched.S
 * arm64_el0_task_a/_b) LINK INTO THE KERNEL'S OWN .text at ~0x4008_14e4 —
 * inside the AP=00 region — and demonstrably execute and syscall after an
 * `eret` with SPSR M[3:0] = 0.
 *
 * That is either (a) a descriptor that is not what the source says, (b) a
 * permissive TCG, or (c) tasks that are NOT actually at EL0 — and (c) would
 * invalidate the A9/A10/A11 "EL0 userland" claims. Reasoning cannot settle it;
 * only asking the CPU can.
 *
 * THE TEST
 * --------
 * `MRS <Xt>, CurrentEL` is op0=3 op1=0 CRn=4 CRm=2 op2=2. It is defined at EL1
 * and above and is UNDEFINED at EL0. So we place a probe program in the SAME
 * kernel .text the A9 tasks live in (same AP=00 2 MiB block, same UXN=0), eret
 * to it exactly the way sched.S/a10.S do, and have it execute `mrs x0,
 * CurrentEL` followed by `svc #0`. Two mutually exclusive outcomes:
 *
 *   - Running at EL0: the MRS is UNDEFINED -> a synchronous exception taken to
 *     EL1 through the "Lower EL using AArch64 / Synchronous" slot (0x400) with
 *     ESR_EL1.EC = 0x00 (Unknown reason). x0 still holds the sentinel the probe
 *     loaded before the MRS, because the MRS never wrote it.
 *
 *   - Running at EL1: the MRS SUCCEEDS (x0 = 0x4, i.e. EL1) and the following
 *     `svc #0` is taken through the "Current EL with SP_ELx / Synchronous" slot
 *     (0x200) with ESR_EL1.EC = 0x15 (SVC64).
 *
 * The two outcomes differ in WHICH VECTOR SLOT is entered, in ESR.EC, and in
 * x0 — three independent discriminators, and the slot is decided by hardware,
 * not by anything this file asserts. SPSR_EL1.M[3:0] (the EL the exception came
 * FROM: 0b0000 = EL0t, 0b0101 = EL1h) is printed as a fourth.
 *
 * The probe installs its OWN VBAR_EL1 for the duration and restores the kernel
 * vector table before returning, so it cannot perturb the A8/A9/A10/A11 rungs
 * that run after it. It is pure assembly with no Adder dependency.
 *
 * Gate: scripts/test_arm64_currentel_probe.sh.
 */

    .equ SPSR_EL0T_DAIF, 0x3c0      /* M[3:0]=EL0t, DAIF (bits 9:6) all masked */
    .equ PROBE_SP_EL0,   0x481F0000 /* inside the AP=01 EL0-RW window */
    .equ PROBE_SENTINEL, 0x5EED     /* x0 before the MRS; survives iff MRS undef'd */

/* ------------------------------------------------------------------------ *
 * arm64_elprobe_run — install the probe vectors, eret to the probe at EL0t,
 * print the verdict, restore VBAR_EL1, return to head.S.
 * ------------------------------------------------------------------------ */
    .section .text
    .globl arm64_elprobe_run
    .type arm64_elprobe_run, %function
arm64_elprobe_run:
    ldr     x1, =arm64_elprobe_saved_sp
    mov     x0, sp
    str     x0, [x1]
    ldr     x1, =arm64_elprobe_saved_lr
    str     x30, [x1]
    mrs     x0, vbar_el1
    ldr     x1, =arm64_elprobe_saved_vbar
    str     x0, [x1]

    ldr     x0, =msg_probe_hdr
    bl      uart_puts

    /* Report the probe's own link address so the reader can check for himself
     * that it is inside the AP=00 block (i.e. NOT in the 0x4800_0000 window). */
    ldr     x0, =msg_probe_at
    bl      uart_puts
    ldr     x0, =arm64_elprobe_entry
    bl      uart_puthex
    mov     x0, #10
    bl      uart_putc

    /* Install the probe's own vector table. */
    ldr     x0, =arm64_elprobe_vectors
    msr     vbar_el1, x0
    isb

    /* eret to the probe with M[3:0] = EL0t. */
    ldr     x0, =arm64_elprobe_entry
    msr     elr_el1, x0
    movz    x0, #(PROBE_SP_EL0 >> 16), lsl #16
    msr     sp_el0, x0
    mov     x0, #SPSR_EL0T_DAIF
    msr     spsr_el1, x0
    movz    x0, #PROBE_SENTINEL
    isb
    eret
    .size arm64_elprobe_run, .-arm64_elprobe_run

/* ------------------------------------------------------------------------ *
 * The probe program. Deliberately linked into the kernel's .text — the SAME
 * AP=00 2 MiB block that carries sched.S's A9 tasks.
 * ------------------------------------------------------------------------ */
    .globl arm64_elprobe_entry
    .type arm64_elprobe_entry, %function
arm64_elprobe_entry:
    /* x0 arrives holding PROBE_SENTINEL. If the MRS is UNDEFINED (EL0) it never
     * executes and x0 keeps the sentinel; if it succeeds (EL1) x0 becomes
     * CurrentEL (0x4 at EL1). */
    mrs     x0, CurrentEL
    /* Only reached if the MRS did NOT trap. */
    mov     x8, #0
    svc     #0
1:  b       1b
    .size arm64_elprobe_entry, .-arm64_elprobe_entry

/* ------------------------------------------------------------------------ *
 * Verdict printers. Both restore VBAR/SP/LR and return to head.S.
 *   x0 at entry to .Lverdict = pointer to the verdict string.
 * ------------------------------------------------------------------------ */
    .type arm64_elprobe_lower_sync, %function
arm64_elprobe_lower_sync:
    ldr     x0, =msg_v_lower
    b       .Lverdict
    .size arm64_elprobe_lower_sync, .-arm64_elprobe_lower_sync

    .type arm64_elprobe_cur_sync, %function
arm64_elprobe_cur_sync:
    ldr     x0, =msg_v_current
    b       .Lverdict
    .size arm64_elprobe_cur_sync, .-arm64_elprobe_cur_sync

    .type arm64_elprobe_other, %function
arm64_elprobe_other:
    ldr     x0, =msg_v_other
    b       .Lverdict
    .size arm64_elprobe_other, .-arm64_elprobe_other

    .type .Lverdict, %function
.Lverdict:
    mov     x21, x0                     /* verdict string */
    mrs     x22, esr_el1
    mrs     x23, spsr_el1
    /* The probe's x0 at the moment of the trap, stashed by the vector slot. */
    ldr     x1, =arm64_elprobe_x0
    ldr     x24, [x1]

    mov     x0, x21
    bl      uart_puts

    ldr     x0, =msg_esr
    bl      uart_puts
    mov     x0, x22
    bl      uart_puthex
    ldr     x0, =msg_ec
    bl      uart_puts
    lsr     x0, x22, #26
    and     x0, x0, #0x3f
    bl      uart_puthex
    ldr     x0, =msg_spsr
    bl      uart_puts
    mov     x0, x23
    bl      uart_puthex
    ldr     x0, =msg_spsr_m
    bl      uart_puts
    and     x0, x23, #0xf
    bl      uart_puthex
    ldr     x0, =msg_x0
    bl      uart_puts
    mov     x0, x24
    bl      uart_puthex
    mov     x0, #10
    bl      uart_putc

    /* Machine-readable one-liner for the gate. EC 0x00 from the LOWER-EL slot
     * with x0 == the sentinel is the EL0 verdict; anything else is not. */
    lsr     x0, x22, #26
    and     x0, x0, #0x3f
    cbnz    x0, .Lnot_el0               /* EC != 0 -> not an UNDEF */
    movz    x1, #PROBE_SENTINEL
    cmp     x24, x1
    b.ne    .Lnot_el0
    and     x1, x23, #0xf
    cbnz    x1, .Lnot_el0               /* SPSR.M[3:0] != 0 -> not EL0t */
    ldr     x1, =msg_v_lower            /* and it must be the LOWER-EL slot */
    cmp     x21, x1
    b.ne    .Lnot_el0
    ldr     x0, =msg_final_el0
    b       .Lfinish
.Lnot_el0:
    ldr     x0, =msg_final_notel0
.Lfinish:
    bl      uart_puts

    /* Restore the kernel vector table and return to head.S. */
    ldr     x1, =arm64_elprobe_saved_vbar
    ldr     x0, [x1]
    msr     vbar_el1, x0
    isb
    ldr     x1, =arm64_elprobe_saved_sp
    ldr     x0, [x1]
    mov     sp, x0
    ldr     x1, =arm64_elprobe_saved_lr
    ldr     x30, [x1]
    ret
    .size .Lverdict, .-.Lverdict

/* ------------------------------------------------------------------------ *
 * The probe's private vector table. Each of the three interesting slots
 * stashes the interrupted x0 and branches to its own verdict, so the SLOT the
 * hardware chose is what decides the answer.
 * ------------------------------------------------------------------------ */
    .macro PROBE_SLOT target
    ldr     x1, =arm64_elprobe_x0
    str     x0, [x1]
    b       \target
    .endm

    .section .text.vectors, "ax"
    .balign 0x800
    .globl arm64_elprobe_vectors
arm64_elprobe_vectors:
    /* ---- Current EL with SP_EL0 ---- */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* Synchronous */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* IRQ */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* FIQ */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* SError */

    /* ---- Current EL with SP_ELx (EL1h) ---- */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_cur_sync   /* Synchronous (0x200) */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* IRQ */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* FIQ */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* SError */

    /* ---- Lower EL using AArch64 ---- */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_lower_sync /* Synchronous (0x400) */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* IRQ */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* FIQ */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* SError */

    /* ---- Lower EL using AArch32 ---- */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* Synchronous */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* IRQ */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* FIQ */
    .balign 0x80
    PROBE_SLOT arm64_elprobe_other      /* SError */

/* ------------------------------------------------------------------------ */
    .section .rodata
    .balign 8
msg_probe_hdr:
    .asciz  "ELPROBE: asking the CPU which EL the eret'd program actually runs at\n"
msg_probe_at:
    .asciz  "ELPROBE: probe text VA = 0x"
msg_v_lower:
    .asciz  "ELPROBE: trapped via the LOWER-EL AArch64 sync slot (0x400)"
msg_v_current:
    .asciz  "ELPROBE: trapped via the CURRENT-EL SP_ELx sync slot (0x200)"
msg_v_other:
    .asciz  "ELPROBE: trapped via an UNEXPECTED slot"
msg_esr:
    .asciz  " esr="
msg_ec:
    .asciz  " ec="
msg_spsr:
    .asciz  " spsr="
msg_spsr_m:
    .asciz  " m="
msg_x0:
    .asciz  " x0="
msg_final_el0:
    .asciz  "ELPROBE-VERDICT: EL0 (MRS CurrentEL was UNDEFINED; SPSR.M=EL0t)\n"
msg_final_notel0:
    .asciz  "ELPROBE-VERDICT: NOT-EL0 (MRS CurrentEL executed, or wrong slot/mode)\n"

/* ------------------------------------------------------------------------ */
    .section .bss
    .balign 8
arm64_elprobe_saved_sp:
    .space  8
arm64_elprobe_saved_lr:
    .space  8
arm64_elprobe_saved_vbar:
    .space  8
arm64_elprobe_x0:
    .space  8

    .section .note.GNU-stack,"",%progbits
