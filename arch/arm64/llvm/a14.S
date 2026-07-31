/*
 * arch/arm64/llvm/a14.S — PER-TASK KERNEL STACKS + __switch_to for the aarch64
 * LLVM whole-kernel lane. A14.
 *
 * WHAT EVERY PHASE UP TO A13 COULD NOT DO
 * ---------------------------------------
 * A13 made a page fault SERVICEABLE, but it was serviced to completion on the
 * boot stack and returned to the SAME task. A9 time-sliced two EL0 tasks, but
 * only ever at the EL0 boundary: the timer IRQ saved the interrupted EL0 frame
 * and eret'd into another EL0 frame, so no task ever had kernel state that had to
 * survive. Every EL1 entry in this lane so far runs on ONE stack — head.S's — and
 * unwinds fully before the next task runs.
 *
 * The consequence is the gate on everything downstream: A TASK CANNOT BLOCK
 * INSIDE A SYSCALL. fork/exec/pipes/wait/signals all need a task to stop
 * half-way through kernel code, let a PEER run kernel code, and then resume with
 * its own kernel call frames intact. That needs two things this file adds:
 *
 *   1. PER-TASK KERNEL STACKS. Each task owns a 16 KiB stack. Because SP_EL1 is
 *      not used while at EL0, the stack is selected simply by ERETing to EL0 with
 *      SP already pointing at that task's stack top — the next EL1 entry (svc or
 *      abort) lands on the right stack with no stub change and no scratch
 *      register juggling. el0.S's `add sp, sp, #(16*16)` before its `eret`
 *      restores SP to exactly the task's stack top, so the invariant maintains
 *      itself.
 *
 *   2. arm64_a14_switch_to(prev, next) — a real __switch_to. AAPCS64 callee-saved
 *      state (x19..x28, FP, LR) plus SP are saved into `prev` and loaded from
 *      `next`, and the `ret` lands wherever `next` last stopped. A task that
 *      stops inside `arm64_a14_switch_entry` (which is itself called from the
 *      middle of el0.S's syscall path, with the interrupted EL0 register frame
 *      still live BELOW it on that task's kernel stack) resumes there later, with
 *      its frames and its saved EL0 registers untouched.
 *
 * THE POLICY IS EMITTED ADDER, NOT ASSEMBLY — same split as A9's scheduler, A8's
 * dispatcher and A13's pager. This file does only what Adder cannot express:
 * register save/restore, SP, SPSR_EL1/ELR_EL1/SP_EL0, `eret`. WHO runs next, when
 * a task is blocked, and every verdict are init/main.ad's
 * arm64_a14_pick_arm64 / arm64_a14_syscall_arm64 / arm64_a14_report_arm64.
 *
 * WHAT THE DEMO EXECUTES (the sequence IS the assertion)
 * -----------------------------------------------------
 *   boot ctx --switch--> task A (EL0)
 *   A loads sentinels into x21..x28, then `svc A14_BLOCK`.
 *       The kernel latches A as blocked and switches away MID-SYSCALL. A's EL0
 *       register frame and its kernel call frames stay parked on A's stack.
 *   task B (EL0, first entry through the trampoline)
 *   B `svc A14_WAKE(0x2222)` — the kernel writes 0x2222 into the x0 slot of A's
 *       PARKED EL0 frame (on A's kernel stack) and marks A runnable. B RESUMES at
 *       EL0 (this syscall does not switch) and then `svc A14_EXIT_B`, which
 *       switches to A.
 *   A resumes INSIDE arm64_a14_switch_entry, below which its EL0 frame still sits.
 *       It returns into el0.S, which reloads that frame and erets. A therefore
 *       comes back to EL0 from its `svc` with x21..x28 intact and x0 = 0x2222.
 *   A sums x21..x28 + x0 and reports it via `svc A14_EXIT_A`; the kernel switches
 *       back to the BOOT context, which resumes inside arm64_a14_run in head.S.
 *
 * The checksum can only be right if A's saved EL0 registers survived B running an
 * entire syscall — which is exactly what a SHARED kernel stack would destroy, and
 * is the reason the sentinels are carried in callee-saved-at-EL0 registers rather
 * than recomputed. The event order (A blocks, B wakes, B exits, A resumes, A
 * exits) is accumulated as hex digits of one integer, so a wake serviced
 * synchronously inside A's own syscall could not produce it.
 *
 * nG / TLB: A14 adds NO page-table entries. Both tasks run in the kernel L1 with
 * ASID 0 on the A8 EL0-RW window (head.S's nG=1 leaves), and no TTBR0 write and
 * no `tlbi` occurs anywhere in this file — so nothing here is exposed to the
 * QEMU-TCG nG blindness documented in docs/arm64_phase50.md and in
 * scripts/test_arm64_a12_addrspace.sh. Per-task ADDRESS SPACES (A12) and per-task
 * KERNEL STACKS (A14) are deliberately kept as separate increments; combining
 * them is the point at which ASID recycling — and therefore nG — starts to matter
 * and needs a KVM or real-silicon run.
 *
 * Gate: scripts/test_arm64_a14_kstack.sh.
 */

    .equ SPSR_EL0T_DAIF,  0x3c0         /* M[3:0]=EL0t, DAIF (bits 9:6) masked */

    /* Kernel context block, 8-byte slots:
     *   0..9  : x19..x28      (AAPCS64 callee-saved)
     *   10    : x29 (FP)
     *   11    : x30 (LR)      — where this context resumes
     *   12    : SP            — this context's kernel stack pointer
     *   13    : kstack_top    — for the range assertions
     * 14 slots, padded to 128 bytes. */
    .equ A14_CTX_SIZE,    128
    .equ A14_O_X29,       80
    .equ A14_O_X30,       88
    .equ A14_O_SP,        96
    .equ A14_O_KTOP,      104

    .equ A14_KSTACK_SIZE, 16384         /* 16 KiB per task, as on real ports */

    /* EL0 stacks inside the A8 EL0-RW window (0x4800_0000-0x481F_FFFF, AP=01,
     * nG=1). Distinct from A9's 0x481E/0x481C tops so a stale A9 value cannot
     * make an A14 stack look live. */
    .equ A14_A_SP_EL0,    0x48180000
    .equ A14_B_SP_EL0,    0x48160000

    /* A14 syscall numbers. Deliberately outside the aarch64 Linux range so they
     * can never collide with the real numbers arm64_do_syscall_arm64 handles. */
    .equ A14_NR_BLOCK,    0xA140
    .equ A14_NR_WAKE,     0xA141
    .equ A14_NR_EXIT_B,   0xA142
    .equ A14_NR_EXIT_A,   0xA143

    /* The EL0 sentinel contract. The gate recomputes the expected checksum from
     * THESE three numbers, in python, and cross-checks it against the constant
     * the kernel compares to — so neither side is its own oracle. */
    .equ A14_SENTINEL_BASE, 0xC001      /* x21 = BASE, x22 = BASE+1, ... */
    .equ A14_SENTINEL_N,    8           /* x21..x28 */
    .equ A14_WAKE_VALUE,    0x2222      /* what B hands to the blocked A */

    /* Canary written onto a task's OWN kernel stack immediately before it
     * switches away, and read back after it resumes. Mixed with the context
     * address so the two tasks' canaries differ: a switch that resumed the WRONG
     * context, or a stack that another task had reused, shows up here. */
    .equ A14_CANARY_LO,   0x5A14
    .equ A14_CANARY_HI,   0xC0DE

    .section .text

/* ------------------------------------------------------------------------ *
 * arm64_a14_switch_to(x0 = prev ctx, x1 = next ctx) — THE CONTEXT SWITCH.
 *
 * Saves AAPCS64 callee-saved state + SP into `prev`, loads `next`'s, publishes
 * `next` as current, and `ret`s — landing at next's saved x30. For a task that
 * has never run, x30 was seeded to arm64_a14_task_start and SP to its stack top,
 * so the same `ret` performs a first entry; for a task that stopped inside
 * arm64_a14_switch_entry, it lands after that call, mid-syscall.
 *
 * Caller-saved registers are NOT saved: by AAPCS64 the caller has already dealt
 * with them, and every path into here is an ordinary `bl`. The interrupted EL0
 * registers are not this function's business either — they are on the task's own
 * kernel stack, saved by el0.S's vector stub, and stay there.
 * ------------------------------------------------------------------------ */
    .globl arm64_a14_switch_to
    .type arm64_a14_switch_to, %function
arm64_a14_switch_to:
    stp     x19, x20, [x0, #0]
    stp     x21, x22, [x0, #16]
    stp     x23, x24, [x0, #32]
    stp     x25, x26, [x0, #48]
    stp     x27, x28, [x0, #64]
    stp     x29, x30, [x0, #A14_O_X29]
    mov     x2, sp
    str     x2, [x0, #A14_O_SP]

    /* current = next, BEFORE the stack swap: after `mov sp, x2` this function is
     * running on the incoming task's stack and must already be "it". */
    ldr     x3, =arm64_a14_current
    str     x1, [x3]

    ldp     x19, x20, [x1, #0]
    ldp     x21, x22, [x1, #16]
    ldp     x23, x24, [x1, #32]
    ldp     x25, x26, [x1, #48]
    ldp     x27, x28, [x1, #64]
    ldp     x29, x30, [x1, #A14_O_X29]
    ldr     x2, [x1, #A14_O_SP]
    mov     sp, x2
    ret
    .size arm64_a14_switch_to, .-arm64_a14_switch_to

/* ------------------------------------------------------------------------ *
 * arm64_a14_task_start — first-entry trampoline. Reached by the `ret` at the end
 * of arm64_a14_switch_to for a context that has never run, with x19 = the EL0
 * entry PC and x20 = the EL0 SP that arm64_a14_init seeded.
 *
 * SP is already this task's kernel stack top and NOTHING is pushed here, so the
 * `eret` leaves SP_EL1 at the top of the right stack — which is precisely how the
 * next EL1 entry from this task lands on its own kernel stack.
 * ------------------------------------------------------------------------ */
    .globl arm64_a14_task_start
    .type arm64_a14_task_start, %function
arm64_a14_task_start:
    msr     elr_el1, x19
    msr     sp_el0, x20
    mov     x0, #SPSR_EL0T_DAIF
    msr     spsr_el1, x0
    isb
    eret
    .size arm64_a14_task_start, .-arm64_a14_task_start

/* ------------------------------------------------------------------------ *
 * arm64_a14_switch_entry — called from el0.S's sync stub when the emitted-Adder
 * dispatcher answers 2 ("this syscall switches tasks"). Runs ON THE CURRENT
 * TASK'S KERNEL STACK, with that task's full EL0 register frame live below SP.
 *
 * It pushes a canary, asks the Adder policy who runs next, and switches. When (if)
 * this task is switched back to, execution resumes at the instruction after the
 * `bl`, the canary is read back and handed to Adder to verify, and the function
 * returns into el0.S — which reloads the EL0 frame that has been sitting on this
 * stack the whole time and erets. That return path is the entire claim of A14.
 * ------------------------------------------------------------------------ */
    .globl arm64_a14_switch_entry
    .type arm64_a14_switch_entry, %function
arm64_a14_switch_entry:
    stp     x29, x30, [sp, #-16]!
    stp     x19, x20, [sp, #-16]!

    ldr     x2, =arm64_a14_current
    ldr     x19, [x2]                   /* x19 = prev (this) ctx */

    movz    x20, #A14_CANARY_LO
    movk    x20, #A14_CANARY_HI, lsl #16
    eor     x20, x20, x19               /* per-task canary */
    stp     x20, xzr, [sp, #-16]!

    mov     x0, x19                     /* arg0 = this ctx  */
    mov     x1, sp                      /* arg1 = this task's kernel SP */
    bl      arm64_a14_pick_arm64        /* emitted Adder: -> next ctx */
    mov     x1, x0
    mov     x0, x19
    bl      arm64_a14_switch_to

    /* ==== resumes HERE, after one or more OTHER tasks ran kernel code ==== */
    ldr     x0, [sp]                    /* canary as it reads back now */
    movz    x1, #A14_CANARY_LO
    movk    x1, #A14_CANARY_HI, lsl #16
    eor     x1, x1, x19                 /* x19 was restored by switch_to */
    mov     x2, sp
    bl      arm64_a14_resumed_arm64     /* emitted Adder: verify + log */

    add     sp, sp, #16
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret
    .size arm64_a14_switch_entry, .-arm64_a14_switch_entry

/* ------------------------------------------------------------------------ *
 * arm64_a14_init — build the two task contexts and publish them to the Adder
 * policy. Nothing runs yet.
 * ------------------------------------------------------------------------ */
    .globl arm64_a14_init
    .type arm64_a14_init, %function
arm64_a14_init:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =arm64_a14_ctx_boot
    bl      .Lzero_ctx14
    ldr     x0, =arm64_a14_ctx_a
    bl      .Lzero_ctx14
    ldr     x0, =arm64_a14_ctx_b
    bl      .Lzero_ctx14

    /* task A */
    ldr     x0, =arm64_a14_ctx_a
    ldr     x1, =arm64_a14_el0_task_a
    str     x1, [x0, #0]                        /* x19 = EL0 entry PC */
    movz    x1, #(A14_A_SP_EL0 >> 16), lsl #16
    str     x1, [x0, #8]                        /* x20 = EL0 SP */
    ldr     x1, =arm64_a14_task_start
    str     x1, [x0, #A14_O_X30]                /* resume at the trampoline */
    ldr     x1, =arm64_a14_kstack_a_top
    str     x1, [x0, #A14_O_SP]
    str     x1, [x0, #A14_O_KTOP]

    /* task B */
    ldr     x0, =arm64_a14_ctx_b
    ldr     x1, =arm64_a14_el0_task_b
    str     x1, [x0, #0]
    movz    x1, #(A14_B_SP_EL0 >> 16), lsl #16
    str     x1, [x0, #8]
    ldr     x1, =arm64_a14_task_start
    str     x1, [x0, #A14_O_X30]
    ldr     x1, =arm64_a14_kstack_b_top
    str     x1, [x0, #A14_O_SP]
    str     x1, [x0, #A14_O_KTOP]

    ldr     x0, =arm64_a14_ctx_boot
    ldr     x1, =arm64_a14_ctx_a
    ldr     x2, =arm64_a14_ctx_b
    bl      arm64_a14_register_arm64

    ldp     x29, x30, [sp], #16
    ret
    .size arm64_a14_init, .-arm64_a14_init

/* Zero a context block. x0 = base (preserved). Clobbers x2. */
    .type .Lzero_ctx14, %function
.Lzero_ctx14:
    mov     x2, #0
1:  str     xzr, [x0, x2, lsl #3]
    add     x2, x2, #1
    cmp     x2, #(A14_CTX_SIZE / 8)
    b.lt    1b
    ret
    .size .Lzero_ctx14, .-.Lzero_ctx14

/* ------------------------------------------------------------------------ *
 * arm64_a14_run — hand the CPU to task A and get it back.
 *
 * head.S's own execution becomes a switchable context (arm64_a14_ctx_boot), so
 * the return path is the same __switch_to, not a special "unwind to the kernel"
 * case as in A8..A13. When the last A14 task exits, the policy picks the boot
 * context and this function resumes after its `bl`.
 * ------------------------------------------------------------------------ */
    .globl arm64_a14_run
    .type arm64_a14_run, %function
arm64_a14_run:
    stp     x29, x30, [sp, #-16]!
    ldr     x2, =arm64_a14_current
    ldr     x0, =arm64_a14_ctx_boot
    str     x0, [x2]                    /* current = the boot context */
    ldr     x1, =arm64_a14_ctx_a
    bl      arm64_a14_switch_to
    /* ==== resumes here when a task switches back to the boot context ==== */
    ldp     x29, x30, [sp], #16
    ret
    .size arm64_a14_run, .-arm64_a14_run

/* ------------------------------------------------------------------------ *
 * The two EL0 tasks. Hand-written like A9's (an EL0 program that must hold
 * sentinels in specific registers across a blocking syscall is not something a
 * compiler can be asked to guarantee), and they live in the kernel's own .text —
 * EL0-executable identity RAM, UXN=0, exactly as A9's tasks do. They touch NO
 * memory except their own EL0 stack, so no new mapping is needed.
 * ------------------------------------------------------------------------ */
    .globl arm64_a14_el0_task_a
    .type arm64_a14_el0_task_a, %function
arm64_a14_el0_task_a:
    /* Sentinels in x21..x28. These must survive: (a) being saved into A's EL0
     * frame on A's kernel stack, (b) task B running an entire syscall, (c) being
     * reloaded by el0.S. On a SHARED kernel stack, B's frame lands on top of
     * them and the checksum below is wrong. */
    movz    x21, #(A14_SENTINEL_BASE + 0)
    movz    x22, #(A14_SENTINEL_BASE + 1)
    movz    x23, #(A14_SENTINEL_BASE + 2)
    movz    x24, #(A14_SENTINEL_BASE + 3)
    movz    x25, #(A14_SENTINEL_BASE + 4)
    movz    x26, #(A14_SENTINEL_BASE + 5)
    movz    x27, #(A14_SENTINEL_BASE + 6)
    movz    x28, #(A14_SENTINEL_BASE + 7)

    mov     x0, #0
    movz    x8, #A14_NR_BLOCK
    svc     #0                          /* BLOCKS INSIDE THE KERNEL */

    /* x0 is whatever the kernel stored into this task's PARKED frame while it
     * was descheduled — B's wake value. */
    mov     x9, x0
    add     x10, x21, x22
    add     x10, x10, x23
    add     x10, x10, x24
    add     x10, x10, x25
    add     x10, x10, x26
    add     x10, x10, x27
    add     x10, x10, x28
    add     x10, x10, x9
    mov     x0, x10
    movz    x8, #A14_NR_EXIT_A
    svc     #0
1:  b       1b                          /* the exit never resumes EL0 */
    .size arm64_a14_el0_task_a, .-arm64_a14_el0_task_a

    .globl arm64_a14_el0_task_b
    .type arm64_a14_el0_task_b, %function
arm64_a14_el0_task_b:
    movz    x0, #A14_WAKE_VALUE
    movz    x8, #A14_NR_WAKE
    svc     #0                          /* wakes A but does NOT switch */
    mov     x0, #0
    movz    x8, #A14_NR_EXIT_B
    svc     #0                          /* exits and switches to the woken A */
1:  b       1b
    .size arm64_a14_el0_task_b, .-arm64_a14_el0_task_b

/* ------------------------------------------------------------------------ *
 * Kernel stacks (one per task) + context blocks + the running-context pointer.
 *
 * The two stacks are SEPARATE reservations with a guard-sized gap symbol between
 * them, so the gate can assert from the symbol table that they cannot overlap —
 * a refactor that aliased them would make every runtime check pass while
 * destroying the property A14 exists to provide.
 * ------------------------------------------------------------------------ */
    .section .bss
    .balign 16
    .globl arm64_a14_kstack_a
arm64_a14_kstack_a:
    .space  A14_KSTACK_SIZE
    .size   arm64_a14_kstack_a, A14_KSTACK_SIZE
    .globl arm64_a14_kstack_a_top
arm64_a14_kstack_a_top = arm64_a14_kstack_a + A14_KSTACK_SIZE

    .balign 16
    .globl arm64_a14_kstack_b
arm64_a14_kstack_b:
    .space  A14_KSTACK_SIZE
    .size   arm64_a14_kstack_b, A14_KSTACK_SIZE
    .globl arm64_a14_kstack_b_top
arm64_a14_kstack_b_top = arm64_a14_kstack_b + A14_KSTACK_SIZE

    .balign 16
    .globl arm64_a14_ctx_boot
arm64_a14_ctx_boot:
    .space  A14_CTX_SIZE
    .balign 16
    .globl arm64_a14_ctx_a
arm64_a14_ctx_a:
    .space  A14_CTX_SIZE
    .balign 16
    .globl arm64_a14_ctx_b
arm64_a14_ctx_b:
    .space  A14_CTX_SIZE
    .balign 8
    .globl arm64_a14_current
arm64_a14_current:
    .space  8

    .section .note.GNU-stack,"",%progbits
