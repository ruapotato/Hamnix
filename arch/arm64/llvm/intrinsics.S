/*
 * arch/arm64/llvm/intrinsics.S — AArch64 implementations of the low-level
 * intrinsics the Adder LLVM backend emits as real calls (the native backend
 * inlines them). Mirror of scripts/kllvm_io_intrinsics.S for x86, but with
 * genuine aarch64 sequences. Part of the A3 boot layer
 * (docs/arm64_llvm_scoping.md; scripts/build_kernel_llvm_arm64.sh).
 *
 * ABI (AAPCS64, matches the emitted call sites 1:1 with the x86 SysV forms):
 *   memcpy(dst x0, src x1, n x2)               -> dst (x0)
 *   memmove(dst x0, src x1, n x2)              -> dst (x0)
 *   memset(dst x0, c x1, n x2)                 -> dst (x0)
 *   atomic_cas32(addr x0, exp x1, des x2)      -> old (x0, 32-bit zero-ext)
 *   atomic_cas64(addr x0, exp x1, des x2)      -> old (x0)
 *   atomic_add32(addr x0, delta x1)            -> old (x0, 32-bit zero-ext)
 *   atomic_add64(addr x0, delta x1)            -> old (x0)
 *   spinlock_lock(ptr x0)                      -> void   (uint32 lock word)
 *   spinlock_trylock(ptr x0)                   -> 1/0 (x0)
 *   spinlock_unlock(ptr x0)                    -> void
 *   local_irq_save() -> flags(x0) ; local_irq_restore(flags x0)
 *   local_irq_disable()/enable(); cpu_relax(); safe_halt()
 *   inb/inw/inl(port) -> 0 ; outb/outw/outl(val,port) -> void   (no port I/O on ARM)
 *   read_tsc() -> CNTVCT_EL0 ; arch_get_random_u64() -> a cycle-derived word
 *   invlpg_one(va x0) -> void (TLBI VAE1) ; read_rbp() -> x29
 */
    .text

/* ---------------- mem* (byte-wise; correctness over speed) --------------- */
    .globl memcpy
    .type memcpy, %function
memcpy:
    mov     x3, x0                  /* save dst for return */
    cbz     x2, 2f
1:  ldrb    w4, [x1], #1
    strb    w4, [x3], #1
    subs    x2, x2, #1
    b.ne    1b
2:  ret
    .size memcpy, .-memcpy

    .globl memmove
    .type memmove, %function
memmove:
    mov     x3, x0
    cbz     x2, 4f
    cmp     x0, x1                  /* if dst <= src, forward copy is safe */
    b.ls    1f
    /* dst > src: copy backwards to handle overlap */
    add     x3, x0, x2
    add     x1, x1, x2
3:  ldrb    w4, [x1, #-1]!
    strb    w4, [x3, #-1]!
    subs    x2, x2, #1
    b.ne    3b
    ret
1:  ldrb    w4, [x1], #1
    strb    w4, [x3], #1
    subs    x2, x2, #1
    b.ne    1b
4:  ret
    .size memmove, .-memmove

    .globl memset
    .type memset, %function
memset:
    mov     x3, x0
    cbz     x2, 2f
1:  strb    w1, [x3], #1
    subs    x2, x2, #1
    b.ne    1b
2:  ret
    .size memset, .-memset

/* ---------------- atomics (LL/SC) --------------------------------------- */
    .globl atomic_cas32
    .type atomic_cas32, %function
atomic_cas32:
1:  ldaxr   w3, [x0]                /* old */
    cmp     w3, w1                  /* == expected? */
    b.ne    2f
    stlxr   w4, w2, [x0]            /* try store desired */
    cbnz    w4, 1b                  /* retry on lost reservation */
2:  mov     w0, w3                  /* return old (zero-extended) */
    ret
    .size atomic_cas32, .-atomic_cas32

    .globl atomic_cas64
    .type atomic_cas64, %function
atomic_cas64:
1:  ldaxr   x3, [x0]
    cmp     x3, x1
    b.ne    2f
    stlxr   w4, x2, [x0]
    cbnz    w4, 1b
2:  mov     x0, x3
    ret
    .size atomic_cas64, .-atomic_cas64

    .globl atomic_add32
    .type atomic_add32, %function
atomic_add32:
1:  ldaxr   w2, [x0]                /* old */
    add     w3, w2, w1
    stlxr   w4, w3, [x0]
    cbnz    w4, 1b
    mov     w0, w2                  /* return old */
    ret
    .size atomic_add32, .-atomic_add32

    .globl atomic_add64
    .type atomic_add64, %function
atomic_add64:
1:  ldaxr   x2, [x0]
    add     x3, x2, x1
    stlxr   w4, x3, [x0]
    cbnz    w4, 1b
    mov     x0, x2
    ret
    .size atomic_add64, .-atomic_add64

/* ---------------- spinlocks (uint32 word: 0=free,1=held) ---------------- */
    .globl spinlock_lock
    .type spinlock_lock, %function
spinlock_lock:
    mov     w1, #1
1:  ldaxr   w2, [x0]
    cbnz    w2, 2f                  /* held -> spin without hammering */
    stlxr   w3, w1, [x0]
    cbnz    w3, 1b                  /* lost reservation -> retry */
    dmb     ish
    ret
2:  yield
    ldr     w2, [x0]
    cbnz    w2, 2b                  /* wait until it looks free */
    b       1b
    .size spinlock_lock, .-spinlock_lock

    .globl spinlock_trylock
    .type spinlock_trylock, %function
spinlock_trylock:
    mov     w1, #1
1:  ldaxr   w2, [x0]
    cbnz    w2, 2f                  /* already held -> return 0 */
    stlxr   w3, w1, [x0]
    cbnz    w3, 1b
    dmb     ish
    mov     w0, #1
    ret
2:  clrex
    mov     w0, #0
    ret
    .size spinlock_trylock, .-spinlock_trylock

    .globl spinlock_unlock
    .type spinlock_unlock, %function
spinlock_unlock:
    dmb     ish                     /* release: prior stores visible first */
    str     wzr, [x0]
    ret
    .size spinlock_unlock, .-spinlock_unlock

/* ---------------- interrupt masking (DAIF.I) ---------------------------- */
    .globl local_irq_save
    .type local_irq_save, %function
local_irq_save:
    mrs     x0, daif                /* return current DAIF */
    msr     daifset, #2             /* mask IRQ */
    ret
    .size local_irq_save, .-local_irq_save

    .globl local_irq_restore
    .type local_irq_restore, %function
local_irq_restore:
    msr     daif, x0
    ret
    .size local_irq_restore, .-local_irq_restore

    .globl local_irq_disable
    .type local_irq_disable, %function
local_irq_disable:
    msr     daifset, #2
    ret
    .size local_irq_disable, .-local_irq_disable

    .globl local_irq_enable
    .type local_irq_enable, %function
local_irq_enable:
    msr     daifclr, #2
    ret
    .size local_irq_enable, .-local_irq_enable

    .globl cpu_relax
    .type cpu_relax, %function
cpu_relax:
    yield
    ret
    .size cpu_relax, .-cpu_relax

    .globl safe_halt
    .type safe_halt, %function
safe_halt:
    msr     daifclr, #2             /* enable IRQ then wait (like x86 sti;hlt) */
    wfi
    ret
    .size safe_halt, .-safe_halt

    .globl invlpg_one
    .type invlpg_one, %function
invlpg_one:                         /* x0 = VA to invalidate */
    lsr     x0, x0, #12             /* TLBI operand takes VA>>12 */
    dsb     ishst
    tlbi    vaae1, x0
    dsb     ish
    isb
    ret
    .size invlpg_one, .-invlpg_one

    .globl read_rbp
    .type read_rbp, %function
read_rbp:
    mov     x0, x29                 /* aarch64 frame pointer */
    ret
    .size read_rbp, .-read_rbp

/* ---------------- port I/O -> PL011 console routing (A4) ----------------
 * ARM has no port-I/O space, but the kernel's OWN early console
 * (drivers/tty/serial/early_8250.ad) drives an 8250 UART at port 0x3F8 via
 * these inb/outb intrinsics. To make start_kernel_early()'s printk0 reach the
 * aarch64 serial we route that one port at the intrinsic boundary — no kernel-
 * source or compiler change (docs/arm64_llvm_scoping.md A4, item 2):
 *
 *   inb(port x0):  LSR (0x3FD) -> 0x60 (THRE|TEMT, "transmitter ready" so the
 *                  `while (inb(LSR)&0x20)==0` poll in _emit_raw exits at once);
 *                  every other port -> 0 (as before).
 *   outb(val x0, port x1):  THR (0x3F8, DLAB=0) -> store the byte to the PL011
 *                  Data Register (0x0900_0000); every other port -> nop. The
 *                  PL011 is already init'd + its FIFO drained by head.S, so a
 *                  bare DR store transmits. (setup_early_printk's DLL write also
 *                  lands on 0x3F8 => one stray 0x01 byte before the banner;
 *                  harmless control char.)
 * inw/inl/outw/outl keep the old no-port-space behaviour.
 */
    .equ A4_UART_THR,   0x3F8           /* 8250 THR (write) / RBR (read) */
    .equ A4_UART_LSR,   0x3FD           /* 8250 Line Status Register */
    .equ A4_PL011_DR,   0x09000000      /* qemu virt PL011 Data Register */
    .equ A4_PL011_FR,   0x18            /* PL011 Flag Register offset */
    .equ A4_PL011_RXFE, 0x10            /* FR.RXFE: receive FIFO empty */

/*
 * A11 addition — the RECEIVE half of exactly the same trick.
 *
 * The kernel's OWN blocking stdin primitive is early_8250.ad's
 * early_getc_polled(): spin on LSR.DR, then read RBR. Both are `inb`s, so
 * routing them HERE gives the aarch64 lane a real read() with ZERO change to
 * the shared kernel serial driver — the mirror of what outb->PL011 DR did for
 * printk in A4.
 *
 *   inb(0x3FD) (LSR) -> 0x60 (THRE|TEMT) OR'd with 0x01 (DR) when FR.RXFE is
 *                       CLEAR, i.e. a byte is genuinely waiting in the PL011
 *                       receive FIFO.
 *   inb(0x3F8) (RBR) -> the PL011 DR, which POPS one byte off that FIFO.
 *
 * The DR bit MUST reflect real hardware state: a constant "data ready" would
 * feed the kernel garbage forever, and a constant "empty" would hang
 * early_getc_polled(). Note the DR read is DESTRUCTIVE (it pops the FIFO),
 * which is why only the RBR port reaches it — the LSR path reads FR and must
 * never touch DR.
 */
    .globl inb
    .type inb, %function
inb:
    cmp     x0, #A4_UART_LSR
    b.ne    1f
    movz    x9, #0x0900, lsl #16        /* PL011_BASE = 0x0900_0000 */
    ldr     w10, [x9, #A4_PL011_FR]
    mov     x0, #0x60                   /* THRE|TEMT: transmitter ready */
    tst     w10, #A4_PL011_RXFE
    b.ne    9f                          /* RX FIFO empty -> leave DR clear */
    orr     x0, x0, #0x01               /* LSR.DR: a byte is waiting */
9:  ret
1:  cmp     x0, #A4_UART_THR
    b.ne    2f
    movz    x9, #0x0900, lsl #16
    ldr     w0, [x9, #0]                /* PL011 DR: POPS the receive FIFO */
    and     x0, x0, #0xFF
    ret
2:  mov     x0, #0
    ret
    .size inb, .-inb

    .globl inw
inw:
    .globl inl
inl:
    mov     x0, #0
    ret

    .globl outb
    .type outb, %function
outb:                                   /* x0=value, x1=port */
    cmp     x1, #A4_UART_THR
    b.ne    2f
    movz    x9, #0x0900, lsl #16        /* PL011_BASE = 0x0900_0000 */
    strb    w0, [x9, #0]               /* PL011 DR (offset 0) */
2:  ret
    .size outb, .-outb

    .globl outw
outw:
    .globl outl
outl:
    ret

/* ---------------- timing / entropy ------------------------------------- */
    .globl read_tsc
    .type read_tsc, %function
read_tsc:
    isb
    mrs     x0, cntvct_el0          /* virtual counter as a cycle stand-in */
    ret
    .size read_tsc, .-read_tsc

    .globl arch_get_random_u64
    .type arch_get_random_u64, %function
arch_get_random_u64:
    /* No FEAT_RNG gate yet (QEMU virt cortex-a72 lacks RNDR); derive a word
     * from the virtual counter. A real CSPRNG/RNDR path is an A4+ item. */
    isb
    mrs     x0, cntvct_el0
    mrs     x1, cntpct_el0
    eor     x0, x0, x1, lsl #13
    ret
    .size arch_get_random_u64, .-arch_get_random_u64

    .section .note.GNU-stack,"",%progbits
