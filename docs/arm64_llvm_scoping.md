# ARM64 (AArch64) LLVM Retarget — Scoping Spike

Status: **A1 DONE + A2 DONE + A3 boots + A4 runs real kernel init** (whole-kernel
`.ll` compiles CLEAN, LINKS to a bootable aarch64 ELF with **0 undefined
symbols**, BOOTS on `qemu-system-aarch64 -M virt` with PL011 early console +
MMU/caches on, and now **runs the kernel's OWN `start_kernel` early-init
sequence** — real Adder `printk0` over the PL011-routed console, through
`trap_init` + CPU-mitigation/KASLR/sched setup, up to the `mem_init` (x86-paging)
A5 boundary; see the A4 box below). The original scoping spike
(main @ 731f39b9, no compiler code changed) is preserved below as the feasibility
evidence; the **phase-status delta from the implementation work is recorded in the
"Implementation status" box immediately below** and inline in §3.

---

## Implementation status (2026-07-24) — A4 real kernel early-init

**A4 — the aarch64 LLVM kernel REACHES REAL KERNEL INIT and runs it over PL011:
DONE for the early-init (pre-`mem_init`) milestone.** Gate
`scripts/test_arm64_llvm_kernel.sh` (extended with A4 assertions): **PASS**.

The A3 layer only proved a *pure leaf* (`fmt_is_flag`) executes. A4 gets the
kernel's OWN `start_kernel` early-init sequence running as emitted LLVM Adder
code, printing over the console. Verified PL011 serial from the actual
`qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G` run (grep-a'd, furthest
point; kernel then returns to head.S and parks in `wfi`):
```
HAMNIX aarch64 LLVM-kernel: EL1 entry OK (PL011 early console)
MMU: identity map enabled (device 0-1G, RAM 1-2G Normal-WB, caches on)
LLVM-ADDER fmt_is_flag[+,A,0,#,sp,z]=101110
LLVM-ADDER-OK: emitted Adder code executed on aarch64
A4: entering start_kernel_early (real kernel init over PL011)
[000000] gop: no GOP capture (BIOS boot or LocateProtocol failed)
[000001] mb_fb: no framebuffer info (flag bit 12 clear)
[000002] fb: no framebuffer info (BIOS without VBE? QEMU -kernel?)
[000003] Hamnix kernel booting...
[000004] Hamnix: hello from start_kernel
[000005] Hamnix: trap_init done
[000006] [mitig] CR4 SMEP=0 (SMAP deferred to setup_smap_late)
[000007] [kaslr] offset=0x0000000009800000 (module-window slide=... 2MiB-slots)
[000008] Hamnix: early cpu/sched init done
A4: start_kernel_early returned
```
Everything from `[000000]` on is the kernel's REAL Adder `printk0` path
(`setup_early_printk`→`early_putc`→`_emit_raw`→`inb`/`outb`), including the live
`[NNNNNN]` printk line-sequence counter — not a hand-written banner. It walks
`setup_early_printk`, `__stack_chk_init`, `fb_init_early` (correctly detects no
framebuffer on `-kernel` boot), `trap_init`, `setup_smep_smap`, `setup_kaslr`,
and `sched_mark_boot_task_running`, all emitted by the LLVM backend, and returns
cleanly to `head.S`.

**How the 5-bails/`start_kernel` problem was solved — OPTION (b), source+boot,
NO compiler change.** `start_kernel` is a ~7.6 k-line function whose CFG blows
the compiler's per-function arena caps (`NM_MAX=256` distinct names, `CI_MAX`,
`BB_MAX`), so the LLVM backend bails on it (`reason=0` == `cfg_build_function`
overflow, NOT an SBR_* subset bail). Raising `NM_MAX` (option a) is a
non-starter for a function this large: the caps are fixed-size arrays woven
through `cfg.ad`/`regalloc.ad` and the per-block SSA rows are sized
`BB_MAX*NM_MAX`, so a cap big enough for `start_kernel` would be hundreds of MB
of static host arrays AND perturb the native `ADDER_OPT2` regalloc — heavy,
risky, and it would demand the full native-safety battery. Instead A4 **factors
the early-init prefix of `start_kernel` into a new small PUBLIC function
`start_kernel_early()`** (`init/main.ad`). It is small enough to EMIT via LLVM
(few names, mostly calls + string literals), and because public names are not
mangled it links as the bare symbol `@start_kernel_early`. On x86 `start_kernel`
simply calls `start_kernel_early()` at its top — a behaviour-preserving
extract-method refactor, identical statement ordering. This is a
`init/main.ad` + boot-layer change only; **no `ssa_llvm.ad`/`ssa.ad`/
`codegen.ad`/`cfg.ad`/`regalloc.ad` edit**, so the compiler native path is
byte-identical by construction and the compiler native-safety gates
(kobjdiff/fuzz/OPT2/bench) do not gate this change (kobjdiff was still run as a
self-host sanity check on the refactored `init/main.ad`: 0 divergences).

**Console routing (A4 item 2), boot-layer only.** The kernel's own early console
drives an 8250 at port `0x3F8` via `inb`/`outb`, which on aarch64 are supplied by
`arch/arm64/llvm/intrinsics.S`. Those were no-op stubs; A4 routes them at the
intrinsic boundary: `inb(0x3FD)` (LSR) returns `0x60` (THRE|TEMT, so the
`_emit_raw` transmit-ready poll exits) and `outb(_, 0x3F8)` (THR) stores the byte
to the PL011 Data Register (`0x0900_0000`); all other ports keep the old
`0`/no-op. No kernel-source or compiler change — the kernel's `printk0` now
emits over the aarch64 PL011 unmodified. (`setup_early_printk`'s DLL write also
lands on `0x3F8` → one stray `0x01` byte before the banner; a harmless control
char.) `arch/arm64/llvm/head.S` calls `start_kernel_early` after the A3 proof.

**A5+ next phases (ranked):**
1. **`mem_init` — the memory-init port (the A4→A5 boundary).** `mem_init()` is
   the first statement left in `start_kernel` (not reached on aarch64): it does
   real x86 page-table / e820 work (CR3, PDPT US bits, `pgtable_extend_from_e820`)
   that faults on aarch64. Port it to the aarch64 MMU/TTBR model (the head.S
   identity map + a real page allocator over the RAM block) so early init walks
   past it. This is the largest remaining early-init item.
2. **Emit the rest of `start_kernel`.** With `mem_init` ported, keep peeling
   contiguous slices of `start_kernel` into further small emittable functions
   (or, longer-term, teach the compiler to auto-split / raise the arena caps
   behind a gate for the LLVM lane only) until the whole init path emits.
3. **Real exception handling + GICv2 + generic-timer tick** (port the proven
   standalone `kmain.ad` GICv2/`CNTV_*` bringup into this lane) → preemptive
   scheduling; needed before anything that waits on an interrupt.
4. **virtio-mmio console/blk + initramfs** (`-M virt` is all-virtio) → boot to a
   shell, mirroring the standalone track's Phase 30+.
5. **Compiler follow-ups (gated, `ssa_llvm.ad`):** `align 8` on the
   rdrand/mul128 scratch globals (removes the build-lane sed); `FEAT_RNG` gate +
   software fallback for `arch_get_random_u64`; higher-half TTBR1 kernel VA.

---

## Implementation status (2026-07-24) — A3 boot layer

**A3 — `arch/arm64/llvm/` boot layer + link + boot: DONE for the entry/console/
MMU/execution-proof milestone.** The whole-kernel aarch64 `.ll` (11064 funcs,
11059 emitted, 5 bails) now LINKS into a bootable `ELF 64-bit LSB executable, ARM
aarch64` with **0 undefined symbols** and boots on `qemu-system-aarch64 -M virt
-cpu cortex-a72 -m 2G`. Gate `scripts/test_arm64_llvm_kernel.sh` (NEW): **PASS**.

Verified PL011 serial (grep-a'd from the actual qemu-system-aarch64 run — the
furthest point; kernel then halts in a `wfi` park loop, qemu killed by timeout):
```
HAMNIX aarch64 LLVM-kernel: EL1 entry OK (PL011 early console)
MMU: identity map enabled (device 0-1G, RAM 1-2G Normal-WB, caches on)
LLVM-ADDER fmt_is_flag[+,A,0,#,sp,z]=101110
LLVM-ADDER-OK: emitted Adder code executed on aarch64
```
The `101110` is the input-dependent, branch-heavy return of the PURE emitted
Adder leaf `kernel_printk_printk__fmt_is_flag` from the LLVM kernel object, called
from `head.S` over the vector `['+','A','0','#',' ','z']` (flag chars →
`1,0,1,1,1,0`). Matching bit-exactly proves the Adder LLVM backend's output
**runs correctly on real aarch64** — the A3 "enters and runs Adder code" goal.

**The 131 undefined symbols, categorized + resolved** (`nm -u` on the aarch64
`.o`; enumerated in the build):
- **(a) 5 LLVM bails** (`start_kernel` reason=0 [7674-line fn > cfg NM_MAX],
  `do_syscall`, `linux_abi_api_snd_pcm__snd_pcm_new`, `tests_core_smoke__list_walk_and_sum`,
  `init_main__try_parse_hamnix_roots`) → **return-0 stubs** in
  `arch/arm64/llvm/stubs.c`. NOTE: `start_kernel` ITSELF is a bail, so full kernel
  init is not yet reachable through the LLVM object — the A3 proof deliberately
  calls a small pure emitted leaf instead. (The x86 lane supplies these 5 from a
  native hybrid `main.o`; an aarch64 native-fallback object is the A4 analogue.)
- **(b) ~100 x86 arch/boot shims** (CR/MSR/EFER `read_cr*/write_msr/set_efer_*`,
  FPU `fpu_fx*/xsave`, IDT/TSS/CEA `idt_load/tss_*/cea_*`, AP/SMP `ap_*`, EFI
  `get_efi_*/efi_ms_call*`, multiboot `get_mb_*`, image bounds `kernel_text_*`,
  per-CPU `get_per_cpu_*`, `cpuid_get`, `syscall_entry`, `__switch_to_asm`, …) →
  **return-0/nop stubs** (`stubs.c`). None are reached by the boot proof; they
  exist to LINK. Real aarch64 mechanisms (PSCI reset/suspend, GICv2 already-proven
  in the standalone `kmain.ad`, `MIDR_EL1` cpuid, EL0 `svc` entry) are A4+.
- **(c) atomics/mem/arch intrinsics** (`atomic_{add,cas}{32,64}`, `spinlock_*`,
  `mem{cpy,move,set}`, `local_irq_*`, `cpu_relax`, `safe_halt`, `invlpg_one`,
  `read_tsc`, `arch_get_random_u64`, port-I/O `in*/out*`) → **real aarch64
  implementations** in `arch/arm64/llvm/intrinsics.S` (LL/SC `ldaxr`/`stlxr`
  atomics + spinlocks, `DAIF` masking, `TLBI VAE1`, `CNTVCT_EL0` timing; port I/O
  is a nop/0 — no port space on ARM). ABI mirrors `scripts/kllvm_io_intrinsics.S`.

**Boot layer authored** (`arch/arm64/llvm/`, mirroring `arch/x86/`; kept SEPARATE
from the standalone hand-written aarch64 kernel in `arch/arm64/{boot,kmain,
vectors,kernel.lds}` that independently reached Phase 49):
- `head.S` — reset entry at QEMU virt's `0x40080000`: secondary-CPU park, **EL2→EL1
  drop** (`HCR_EL2.RW`, `SPSR_EL2`, `eret`), boot stack, **.bss zero**, `TPIDR_EL1`
  per-CPU base (the A2 percpu emission reads it), `VBAR_EL1` install, PL011 early
  console (`uart_putc/puts/puthex`), **MMU bringup** (identity 1 GiB L1 blocks:
  device 0-1G + Normal-WB RAM 1-2G, `MAIR=0xff04`/`TCR=0x1_0000_3519`/`SCTLR.M|C|I`,
  constants shared with the proven `kmain.ad`), and the fmt_is_flag execution proof.
- `vectors.S` — 16-slot `0x800`-aligned `VBAR_EL1` table; every slot → a diagnostic
  that dumps `ESR_EL1`+`ELR_EL1` over PL011 and halts (so any fault yields exact
  serial evidence instead of a silent hang).
- `intrinsics.S`, `stubs.c` — the (c) and (a)+(b) symbol resolutions above.
- `kernel.lds` — `OUTPUT_ARCH(aarch64)`, identity link at `0x40080000` (no VMA/LMA
  split; the aarch64 high-half TTBR1 kernel VA is A4+, and no absolute kernel VA is
  baked in the IR so it is purely a linker/MMU concern per §2c). Keeps `.got*`
  mapped (discarding a non-empty `.got.plt` is a fatal ld error).
- `scripts/build_kernel_llvm_arm64.sh` — the aarch64 build lane (drops
  `-mcmodel=kernel`; uses `--target=aarch64-none-elf -mcmodel=small` + aarch64
  binutils). Includes a **build-lane-only** `.ll` post-process that over-aligns
  globals to `>=8` (the A2 rdrand/rdseed/mul128 inline-asm does 64-bit
  `str x,[..,:lo12:sym]` on `align 1` `[8 x i8]` scratch globals →
  `R_AARCH64_LDST64_ABS_LO12_NC relocation truncated`; over-alignment is always
  safe and rewrites only the GENERATED file — no compiler-source change, x86 lane
  byte-identical).

**HARD-RULE compliance:** A3 is boot-layer (`arch/arm64/llvm/`) + a new script
lane ONLY — **no `ssa_llvm.ad`/`ssa.ad`/`codegen.ad` change**, so the x86 native
path is byte-identical by construction and the compiler native-safety gates
(kobjdiff/fuzz/OPT2/bench) do not apply to this change.

**A4+ next phases (ranked):**
1. **Reach real kernel init.** `start_kernel` is an LLVM bail — either raise the
   cfg `NM_MAX` cap / split the function so it emits, or build an **aarch64 native
   fallback object** (the x86-hybrid analogue) so the 5 bails get real bodies, then
   call `start_kernel` and walk the early-init sequence (printk over a PL011-routed
   `outb`, memory init, scheduler).
2. **PL011-route the kernel's own console.** Point the emitted `early_8250`
   `outb`/`inb` at the PL011 (make `inb` of the LSR return THRE-ready, `outb` of
   the THR write the PL011 DR) so the kernel's OWN Adder `printk`/`early_putc`
   emits over aarch64 serial — a stronger end-to-end proof than the leaf call.
3. **Real exception handling + GICv2 + generic timer tick** (port the proven
   `kmain.ad` GICv2/`CNTV_*` bringup into this lane) → preemptive scheduling.
4. **virtio-mmio console/blk + initramfs** (`-M virt` is all-virtio) → boot to a
   shell, mirroring the standalone track's Phase 30+.
5. **Compiler follow-ups (gated, A4 `ssa_llvm.ad`):** `align 8` on the
   rdrand/mul128 scratch globals (removes the build-lane sed); `FEAT_RNG` gate +
   software fallback for `arch_get_random_u64`; higher-half TTBR1 kernel VA.

---

## Implementation status (2026-07-23)

**A1 — user-mode `--target=aarch64` emitter flag: DONE.** `ssa_llvm.ad` gained a
`cg_llvm_target` selector (0 = x86_64 default → byte-identical to before; 1 =
aarch64), flipped by `--backend=llvm --target=aarch64*` in the host driver. It
emits (a) the aarch64 module triple, (b) `svc #0` with the number in `x8`, result
in `x0`, args in `x0..x5`, `~{memory}` clobber, and (c) an x86→aarch64 Linux
syscall-number remap for a **literal** number operand (write 1→64, read 0→63,
exit 60→93, exit_group 231→94, close 3→57, lseek 8→62, mmap/munmap, openat
257→56, …). The scoping PoC's two `sed` lines are now produced by the compiler
itself. **Gate `scripts/test_arm64_usermode.sh` (NEW): PASS** — `whole_prog`
emitted with `--target=aarch64` (no sed), `clang --target=aarch64` +
`qemu-aarch64`, output byte-identical to the x86_64 native run (`16834`,
sha256[:16] `702b7185d5376ccf`).

**A2 — freestanding kernel `.ll` compiles CLEAN for aarch64: DONE (0 clang
errors).** Update (2026-07-23, second increment): the A2-remainder inline-asm
classes below are now all remapped, driving the uncapped
`clang --target=aarch64-none-elf -ferror-limit=0 -c kernel_arm64.ll` error count
**272 → 0** (clang rc=0; emits a valid `ELF 64-bit LSB relocatable, ARM aarch64`
object, 10.9 MB). All remaps are gated behind `cg_llvm_target` in the SVO_INLINEASM
path (new `ll_emit_aarch64_asm`, replacing `ll_emit_aarch64_barrier`); the x86
lane is byte-identical (x86 `.ll` still 236 `addrspace(256)` / 0 `tpidr` / 17
`hlt` / 0 `br xN`).
- **14 indirect tail-call (retpoline) trampolines → `br xN`.** The Linux x86
  `__x86_indirect_thunk_r*` shims (`popq %rbp; jmpq *%rN`, plus the `%rbp` variant
  `movq %rbp,%r11; popq %rbp; jmpq *%r11` → `mov x9, x29; br x9`) emit the aarch64
  branch-to-register form under an x86-GPR→aarch64-GPR map (rax→x0 … r15→x13).
  These are x86-only `.ko` shims — dead on aarch64 (the caller-side retpoline
  convention that pre-loads the target in rN does not exist on ARM) — so `br xN`
  keeps the branch-to-register shape and assembles cleanly. Disassembly proof:
  `d61f0000 br x0`, `d61f0120 br x9`, … (14 sites).
- **mul128 (`tls_mul128`) → FAITHFUL `mul`+`umulh`.** Reads `tls_mul128_{a,b}`,
  writes `tls_mul128_{lo,hi}` via `adrp`/`:lo12:` addressing — a real working
  128-bit widening multiply. Disassembles to `mul`/`umulh x12, x9, x10`.
- **rdrand/rdseed → ARMv8.5-RNG `mrs RNDR`/`RNDRRS`.** `rdrand`→`mrs x9,
  s3_3_c2_c4_0` (disassembles to `mrs x9, rndr`), `rdseed`→`s3_3_c2_c4_1`
  (`rndrrs`); result stored to `hwrng_scratch`, success flagged in `hwrng_cf`.
  Needs FEAT_RNG — A3 should add an `ID_AA64ISAR0_EL1.RNDR` gate + software
  fallback for pre-8.5 cores (e.g. QEMU `-M virt` default).
- **cpuid (2), s3_save (ACPI S3), lidt/int3 (reset) → documented aarch64 stubs
  (`nop`).** These mechanisms are x86-platform-specific: aarch64 CPU
  identification is `mrs MIDR_EL1`/`ID_AA64*`, suspend is PSCI `CPU_SUSPEND`, and
  reset is PSCI `SYSTEM_RESET` — all wired in the A3 boot layer. The `nop` stubs
  leave the `cpuid_*` output globals at their prior value (no false x86 feature
  claims on paths not reached on aarch64).
- **aarch64 clobber list widened** to `~{x9}..~{x13},~{memory},~{cc}` (covers the
  mul128/rng scratch regs; barriers touch no GPRs so this is harmless for them).
- **aarch64 link probe:** `aarch64-linux-gnu-ld -r` merges the object cleanly. A
  full executable link needs **131** undefined symbols (`atomic_*`, `ap_*`,
  `cea_*`, `cpuid_get`, `arch_get_random_u64`, …) supplied by a not-yet-existing
  `arch/arm64/` boot layer + a native fallback for the 5 LLVM bails — exactly the
  Phase A3 work (EL1 entry, `VBAR_EL1` vectors, atomics, MMU/TTBR, GIC, PSCI).

**A2 (first increment) — kernel percpu crux + barriers: DONE.**
- **`%gs`/`addrspace(256)` percpu → `TPIDR_EL1` (the silent-miscompile crux):
  FIXED.** Each of the 236 addrspace(256) occurrences (= 118 percpu accesses) now
  emits, on aarch64, `%b = call i64 @llvm.read_register.i64(metadata !0)` (a
  named-register read of `tpidr_el1`) + `add` of the slot offset + a plain
  `inttoptr`/load-store; module-level `declare` + `!llvm.named.register.tpidr_el1`
  metadata are emitted once, lazily, only when used. **Disassembly proof** (real
  emitter output, `clang --target=aarch64-none-elf -O2 -S`): the emitted
  `current_idx_get()` lowers to `mrs x8, TPIDR_EL1` + `ldr x0, [x8, #64]` — NOT a
  bare `ldr`. The OLD addrspace(256) emission of the same function lowers to a
  bare `ldr x0, [x8]` on aarch64 (base dropped) — i.e. the retarget converts a
  silent miscompile into a correct per-CPU access. aarch64 `.ll` now emits **0**
  `addrspace(256)` (x86 lane still emits 236 — unchanged).
- **30 trivial barrier asm sites → aarch64: DONE.** `hlt`→`wfi` (17),
  `cli`→`msr daifset, #2` (6), `sti`→`msr daifclr, #2` (1), `pause`→`yield` (4),
  `mfence`→`dmb ish` (2), matched by exact asm-body string in the `SVO_INLINEASM`
  path and paired with an aarch64-valid `~{memory},~{cc}` clobber (the x86
  `~{rax}…~{r15}` GPR clobber list is invalid on aarch64). aarch64 `.ll` now has
  **0** leftover `hlt/cli/sti/pause/mfence` bodies; x86 lane unchanged (17 `hlt`).
- **Kernel `.ll` clang error count: 332 → 272** (uncapped, `-ferror-limit=0`,
  `clang --target=aarch64-none-elf -c`; the doc's original "186" was the default
  `-ferror-limit`-capped count, which is now **156**). The **60**-error drop is
  entirely the barrier remap; the 236 percpu sites were silent (no error) before
  and correct now, so they contribute no error delta.
- **A2 remainder (unchanged from the scoping inventory, now the sole residual
  error classes):** the 14 indirect tail-call trampolines (`popq %rbp`/`popq
  %rbx`/`jmpq *rN`/`movq %rbp,%r11`) dominate the residual, plus the 8 "real ARM
  work" sites — `cpuid` (2), `rdrand`/`rdseed` (2 each), `mul128`
  (`tls_mul128_*`), `s3_save` (ACPI S3), `lidt;int3` (reset). These are
  category-(b)-mechanical / (b)-real-work from §2a and are the next A2 increment
  (trampolines are mechanical; cpuid/rng/suspend/reset are stub-able for a first
  boot).

**HARD-RULE compliance:** the x86_64 path is byte-identical (all aarch64 emission
is gated behind `cg_llvm_target`, default 0; `codegen.ad` and the native ELF lane
are untouched). Native-safety gates + x86 `-O0` boot spot-check were re-run after
the `ssa_llvm.ad`/driver edits — see the commit message / task report.

---

## Original scoping spike (preserved)

This document answers one question for the user: is ARM64 a **near-term
LLVM retarget** (mostly free, ride the existing `.ll` emitter) or a **larger
bringup**? Evidence below.

**Verdict (one line):** ARM64 user-mode Adder-via-LLVM is **proven working
today** (real program runs under `qemu-aarch64`, byte-identical output to
x86_64). The **freestanding kernel** is a **bounded bringup**, not a rewrite:
the structured LLVM IR is already target-independent; the entire delta is
concentrated in **~52 inline-asm sites + 236 `%gs`-percpu accesses + the 22
`arch/x86/*.S` boot stubs + linker script**. All quantified below.

---

## 1. PoC — a real Adder program runs on ARM64 via LLVM

**Toolchain (all present on this host — nothing to install):**

| tool | status |
|------|--------|
| `clang-19` | present, cross-compiles to `aarch64` out of the box |
| `qemu-aarch64` / `qemu-aarch64-static` | present (user-mode) |
| `aarch64-linux-gnu-{as,ld,objdump,...}` (binutils 2.44) | present |
| `/usr/aarch64-linux-gnu` sysroot | **binutils only — NO aarch64 libc/crt** |
| `qemu-efi-aarch64` (AAVMF UEFI firmware) | present (for future system-mode boot) |

The missing aarch64 libc is a **non-issue** for the PoC (and for Hamnix in
general): Hamnix is freestanding / Plan-9-native and does not link glibc. The
PoC builds a **static `-nostdlib` ELF** with a tiny per-arch `_start`.

**Method (`scripts/arm64_llvm_poc.sh`):** emit ONE `.ll` from
`tests/bench/llvm/whole_prog.ad` with the existing `host_ac.elf --backend=llvm`,
then compile that **same `.ll`** for BOTH targets and run both. The `.ll` is
100% the compiler's real output; the only aarch64 edits are the **two lines a
retargeted `ssa_llvm.ad` would itself emit differently**, applied by `sed` over
the generated file (NOT a compiler change):

1. `target triple = "x86_64-pc-linux-gnu"` → `"aarch64-unknown-linux-gnu"`
2. the one `__syscall3` inline-asm line
   `asm "syscall", "={rax},{rax},{rdi},{rsi},{rdx},..."` →
   `asm "svc #0", "={x0},{x8},{x0},{x1},{x2},~{memory}"` with the Linux write
   number remapped (x86 `1` → arm64 `64`).

`whole_prog.ad` runs gcd/lcm/prime-count/fib/collatz/sieve/6-arg-call and prints
the accumulator via `print_u64` (which now compiles fully in-subset —
`funcs=10 emitted=10 bailed=0` — so the emitted `.ll` DID contain the raw
`syscall`, exercising delta #2 for real).

**Result — PASS:**

```
x86_64 (native)          stdout=[16834] rc=194   sha256[:16]=702b7185d5376ccf
aarch64 (qemu-aarch64)   stdout=[16834] rc=194   sha256[:16]=702b7185d5376ccf
RESULT: PASS — identical output across x86_64 and aarch64 from the SAME emitted .ll
```

`16834 = 21+42+168+6765+111+9592+135` (gcd+lcm+π(1000)+fib(20)+collatz(27)+
sieve(1e5)+blend6); rc `194 = 16834 & 255`. The aarch64 ELF is a genuine
`ELF 64-bit LSB executable, ARM aarch64, statically linked` running under
`qemu-aarch64`. **A real Adder program, compiled through the Adder LLVM backend,
runs correctly on AArch64.**

Reproduce: `bash scripts/arm64_llvm_poc.sh`

---

## 2. x86-ism inventory for the KERNEL `.ll`

Built the whole-kernel closure with the existing emitter (inspection only, no
ssa file touched, so the host_ac rebuild gotcha does not apply):

```
host_ac.elf --backend=llvm --target=x86_64-bare-metal init/main.ad kernel_main.ll
; ADDER_STAT funcs=11064 emitted=11059 bailed=5     (33.6 MB of IR)
```

**Empirical breakage test.** Swapped only the triple to `aarch64-unknown-none-elf`
and ran `clang-19 --target=aarch64-none-elf -c` on the 33 MB `.ll`. Result:
**186 errors, ALL inline-asm** (`<inline asm>: error: unrecognized instruction
mnemonic / invalid operand / unknown token` — i.e. x86 mnemonics fed to the
aarch64 assembler). **Zero errors came from the structured IR** — every
`define`, `load`/`store`, `getelementptr`, `inttoptr`, `phi`, `br`, `call`,
arithmetic, and global compiled cleanly for aarch64. This is the core finding:
**the IR body is already target-independent; 100% of the hard failures are the
inline-asm sites.**

### 2a. Inline-asm sites — 52 total, categorized

| category | sites | distinct | class | AArch64 equivalent |
|----------|------:|---------:|-------|--------------------|
| `hlt` | 17 | 1 | **(b) trivial** | `wfi` |
| `cli` | 6 | 1 | **(b) trivial** | `msr daifset, #2` |
| `sti` | 1 | 1 | **(b) trivial** | `msr daifclr, #2` |
| `pause` | 4 | 1 | **(b) trivial** | `yield` |
| `mfence` | 2 | 1 | **(b) trivial** | `dmb ish` |
| indirect tail-call trampolines `popq %rbp; jmpq *rN` (one per GPR + a `%r11` variant) | 14 | 14 | **(b) mechanical** | `ldp`/frame-restore + `br xN` |
| `cpuid` feature probe (2 variants: `cpuid_eax`/`ci_eax`) | 2 | 2 | **(b) real work** | `mrs` on `ID_AA64*` regs — different mechanism |
| `rdrand`/`rdseed` HW RNG retry loops | 2 | 2 | **(b) real work** | `mrs RNDR/RNDRRS` (ARMv8.5) or alt entropy |
| 128-bit `mulq` (tls_mul128) | 1 | 1 | **(b) easy** | `mul` + `umulh` (or lower via i128 in IR) |
| `s3_save` register-save (ACPI S3 suspend) | 1 | 1 | **(c) bringup** | PSCI `CPU_SUSPEND`; stub for MVP |
| `lidt … ; int3` (triple-fault-style reset via null IDT) | 1 | 1 | **(c) bringup** | PSCI `SYSTEM_RESET` |

Rollup: **30 sites are trivial 1:1 barriers/wait** (5 distinct mnemonics),
**14 are mechanical** indirect-branch trampolines, **8 are real ARM work**
(cpuid/rng/mul128/suspend/reset — mostly small and mostly stub-able for a first
boot). **There is no `syscall` inline-asm in the kernel `.ll` (count = 0)** —
the freestanding kernel issues no Linux syscalls (those live only in the
`linux_abi` shim), so the syscall-number ABI mismatch is a **user-mode-only**
concern.

### 2b. `%gs` per-CPU (`addrspace(256)`) — 236 sites — THE load-bearing item

The emitter models x86 per-CPU storage as `addrspace(256)` pointers (clang's
`%gs` model): 236 load/store sites. **Isolated test on aarch64:** clang
compiles `load i64, i64 addrspace(256)* %p` **without error** but emits a
**plain `ldr x0, [x0]`** — the per-CPU semantics are **silently dropped** (no
`TPIDR_EL1` base). This is a **silent miscompile**, the single most important
correctness item of the retarget, and it lives in `ssa_llvm.ad`
(`ll_put_ity_ptr` / `sv_as256`, gated behind `cg_target_kernel`). AArch64 has no
GS-style address space; the retarget must emit an explicit per-CPU base read
(`mrs xN, TPIDR_EL1`) + offset, or an `llvm.read_register` intrinsic. Bounded
and localized (one emitter path), but must be done before any SMP/per-CPU kernel
code is trusted.

### 2c. Target strings, code model, VA layout, linker/boot

| item | finding | class |
|------|---------|-------|
| `target triple` | 1 line, hardcoded `x86_64-pc-linux-gnu` (`ssa_llvm.ad:1546`) | (b) one-line, per-target |
| `target datalayout` | **none emitted** — clang infers from `--target`. x86_64 and aarch64 are both LP64 little-endian, so no datalayout conflict | (a) as-is |
| `-mcmodel=kernel` | **AArch64 has no `kernel` code model.** The x86 kernel lane passes `-mcmodel=kernel` (negative-2GB, for the `0xffffffff8...` higher-half). AArch64 uses `-mcmodel=small`(±4 GB, PIE-friendly) or `-mcmodel=large`; a high kernel VA is achieved via the **linker script + MMU TTBR1** (upper VA half `0xffff_...`), NOT a code model. `build_kernel_llvm.sh` clang flags need an arch branch. | (c) bringup |
| higher-half VA `0xffffffff80000000` | x86 PML4-511 convention. AArch64 kernels live in the **TTBR1 upper half** (e.g. `0xffff_0000_0000_0000+`). No `inttoptr` in the IR bakes this constant — it comes from `kernel.lds` + boot MMU setup — so the IR is unaffected; the constant moves to the new linker script + page-table bringup. | (c) bringup |
| `arch/x86/kernel/kernel.lds` | `OUTPUT_ARCH(i386:x86-64)`, `ENTRY(_start)`, `KERNEL_VBASE=0xffffffff80000000`, AP-trampoline @0x8000, multiboot low stub | (c) full rewrite → `arch/arm64/.../kernel.lds` |
| boot/entry `.S` stubs | **22 files under `arch/x86/` + 4 under `fs/`,`drivers/`** (`header.S` multiboot, `head_64.S` long-mode+bss-zero, IDT/GDT/TSS, syscall entry, IRQ/trap entry, FPU, KPTI, SMP/AP trampoline, spinlock, sched switch, sigret, vDSO, string) | (c) native rewrite → `arch/arm64/` (EL1 entry, exception-vector table `VBAR_EL1`, MMU/TTBR bringup, GIC, PSCI) |

### Category rollup

- **(a) target-independent, works as-is:** the entire structured IR body
  (11,059 functions), all globals, no datalayout conflict. This is the bulk of
  the 33 MB and it compiled for aarch64 with zero IR errors.
- **(b) needs an AArch64 asm/intrinsic equivalent (in `ssa_llvm.ad`):** triple
  string (1 line), the 52 inline-asm sites (30 trivial + 14 mechanical + 8 real),
  and the 236 `%gs`-percpu accesses (one emitter path). This is the **compiler
  retarget** and it is small and localized.
- **(c) native `.S`/linker/boot-shim rewrite (bringup layer):** 22+ `.S` stubs,
  `kernel.lds`, code-model/VA story, MMU + exception vectors + GIC + PSCI. This
  is the **new `arch/arm64/` tree** — the genuine engineering, mirroring what
  `arch/x86/` already provides.

---

## 3. Phased bringup plan (mirrors the x86 kernel-LLVM lane staging)

The x86 LLVM kernel went user-apps → freestanding `.ll` compiles → link with
`.S` stubs → boot → shell (Phases 5b–5s). ARM64 follows the same ladder, and
Phase A1 is **already green** (§1).

### Phase A1 — user-mode Adder apps on ARM64 (✅ DONE — emitter flag landed)
- **Deliverable:** `scripts/arm64_llvm_poc.sh` (sed spike) **superseded by the real
  emitter flag** + `scripts/test_arm64_usermode.sh` (Adder→`--target=aarch64`
  `.ll` with NO sed→`clang --target=aarch64`→`qemu-aarch64`, parity asserted).
- **Acceptance gate (MET):** `whole_prog` output byte-identical to x86_64
  (`16834`, matching sha256) from compiler-emitted aarch64 `.ll`.
- **Was "next within A1", now DONE:** `ssa_llvm.ad` `--target=aarch64-*` flag emits
  (a) the aarch64 triple and (b) `svc #0`/`x8`/`x0..x5` for `__syscallN` with an
  aarch64 Linux syscall-number table (write=64, exit=93, …). Gate additively;
  x86 output must stay byte-identical (`scripts/test_native_vs_seed_kobjdiff.sh`,
  0 divergences — the native path is not on the LLVM emitter, but run it anyway
  after any ssa file edit). Gate: `objdiff` corpus of `user/*.ad` runs identically
  under qemu-aarch64 and native.
- **Risk:** low. Proven. Syscall-number table is bookkeeping.

### Phase A2 — freestanding kernel `.ll` compiles clean for aarch64 (the compiler retarget)
- **Status: percpu crux + barriers ✅ DONE** (332→272 clang errors; `mrs
  TPIDR_EL1` disassembly proven). Remainder = 14 trampolines + cpuid/rng/mul128/
  s3/reset (next increment). See "Implementation status" box at top.
- **Work:** in `ssa_llvm.ad`, behind the aarch64 target flag: (1) emit aarch64
  equivalents for the 5 trivial barrier mnemonics + the 14 trampoline stubs;
  (2) replace `addrspace(256)` percpu with a `TPIDR_EL1`-based emission (the 236
  sites); (3) provide aarch64 forms (or gated stubs) for cpuid/rdrand/mul128/
  s3/reset. Barriers/percpu are the priority; cpuid/rng/suspend can emit a
  `brk`/stub trap first and be filled in.
- **Acceptance gate:** `clang --target=aarch64-none-elf -c kernel_main.ll` → `0`
  errors (today: 186, all inline-asm) AND a per-CPU load disassembles to a
  `mrs …TPIDR_EL1` + offset, NOT a bare `ldr`. Plus x86 byte-identical
  (kobjdiff 0).
- **Risk:** medium. The percpu retarget is the correctness crux (silent
  miscompile if wrong). Well-contained to one emitter path.

### Phase A3 — boot stubs + MMU + exception vectors on `qemu-system-aarch64 -M virt` → shell
- **Work:** new `arch/arm64/` — EL2→EL1 drop + `_start`, `VBAR_EL1` exception
  vector table, MMU/TTBR0+TTBR1 page-table bringup (upper-half kernel VA),
  `kernel.lds` (`OUTPUT_ARCH(aarch64)`, aarch64 VBASE), GIC + timer + PSCI +
  PL011 UART console; arch branch in `build_kernel_llvm.sh` (drop
  `-mcmodel=kernel`, use `-mcmodel=small`/`large`; aarch64 `as`/`ld`). Use the
  present `qemu-efi-aarch64` (AAVMF) or direct `-kernel`.
- **Acceptance gate (staged, mirroring x86 5b→5s):** (i) links a bootable ELF;
  (ii) reaches early `printk`/UART on `qemu-system-aarch64 -M virt`; (iii)
  demand-paging + scheduler up; (iv) `rfork` child dispatched; (v) shell prompt.
- **Risk:** high-effort but low-uncertainty — this is a **standard AArch64
  bringup**, and `arch/x86/` is a complete reference for every stub. `-M virt`
  is fully virtio (no vendor drivers), so it maps onto the existing native-HW
  invariant (virtio/AHCI/xHCI native).

### Biggest risks, ranked
1. **`%gs`→`TPIDR_EL1` percpu retarget (236 sites)** — silent miscompile if the
   emission is wrong; no compiler error to catch it. Gate with a disassembly
   assertion, not just "it compiled."
2. **Boot/MMU/exception-vector bringup (Phase A3)** — the real labor; low
   conceptual risk (well-trodden, `-M virt` is clean) but the largest LOC.
3. **cpuid/rdrand/S3/reset** — different mechanisms on aarch64; stub-able for a
   first boot, real work later.
4. **Syscall-number ABI (user-mode only)** — Adder `__syscallN` uses x86 Linux
   numbers; needs an aarch64 table. Irrelevant to the freestanding kernel.

**Bottom line for the user:** ARM64 is a **near-term retarget for user-mode
today** and a **bounded, well-understood bringup for the kernel** — not a
rewrite. The north-star bet holds: because the backend emits target-independent
LLVM IR, the structured-IR body (11k functions) is free; the entire cost is the
small `ssa_llvm.ad` asm/percpu delta (Phase A2) plus a fresh `arch/arm64/` boot
layer (Phase A3) that mirrors the existing `arch/x86/` one-for-one.

---

## Appendix — artifacts & reproduction
- PoC script: `scripts/arm64_llvm_poc.sh` (run: `bash scripts/arm64_llvm_poc.sh`).
- Emitted IR inspected: `build/arm64poc/{whole_prog.ll, kernel_main.ll}` (gitignored build dir).
- aarch64 clang error log: `build/arm64poc/aarch64_clang_err.txt` (186 errors, all inline-asm).
- No compiler source (`ssa_llvm.ad`/`ssa.ad`/`codegen.ad`) modified in this spike
  → the default x86 native path is byte-identical by construction (no
  `kobjdiff` divergence possible; nothing on the native codegen path changed).
