# ARM64 (AArch64) LLVM Retarget — Scoping Spike

Status: **A1..A9 DONE + A10 RUNS A REAL COMPILED EL0 PROGRAM + A11 EMBEDDED IMAGE ARCHIVE LOADED BY NAME + REAL read(2) ON THE PL011 + ZERO LLVM BAILS (11383/11383)**

USER ruling 2026-07-30: **ARM64 ships on the LLVM path only.** The hand-written
AArch64 seed backend (`adder/compiler/codegen_arm64.py`) is NOT being extended;
it stays as a live regression fixture. x86_64 keeps its hand-written backend.

Previous status line, kept for the phase history:

> Status: **A1 DONE + A2 DONE + A3 boots + A4 runs real kernel init + A5 past mem_init + A6 first scheduler tick + A7 RUNS USERSPACE (EL0 + svc dispatch) + A8 REAL USERLAND FOUNDATION (EL0-RW fine map + real syscall dispatch) + A9 PREEMPTIVE EL0 SCHEDULING (two EL0 tasks time-sliced by the timer IRQ) + A10 REAL COMPILED EL0 USER PROGRAM (loads and runs Adder-compiled userland, not hand-written asm)**
(whole-kernel
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

## Implementation status (2026-07-30, later) — EVERYTHING BUILDS VIA LLVM: 0 bails

**The whole-kernel aarch64 emit is now `funcs=11383 emitted=11383 bailed=0`** (was
11380/3). This is the USER's "make sure everything builds via LLVM", literally.

### Why bails are an ARM64 correctness problem, not a coverage statistic

On x86 a bailed function falls back to native codegen.ad and nothing is visibly
wrong. On aarch64 there is no fallback. Before the auto-stubber (build step 3c) a
bailed callee with an emitted caller was a hard `R_AARCH64_CALL26` link failure —
loud, at least. **Since the auto-stubber, it is a generated `u64 f(void){return
0;}` — the image LINKS and the function silently returns 0.** That is strictly
worse, and it was already happening: of the three remaining bails, TWO had live
callers in the emitted kernel IR.

| bailed function | callers in the emitted IR | status before |
|---|---|---|
| `tests_core_smoke__list_walk_and_sum` | 6 | called a `return 0` stub |
| `init_main__try_parse_hamnix_roots` | 2 | called a `return 0` stub — the `.hamnix-roots` sentinel parser |
| `start_kernel` | 0 | LATENT only (head.S calls the three `start_kernel_*_arm64` slices, not `start_kernel`) |

### The three fixes

1. **`container_of`** (`NONSUBSET_EXPR` site 48). `ND_CONTAINER_OF` had no SSA
   arm at all and fell through to the catch-all bail. codegen.ad has emitted it
   forever as `gen_expr(inner); subq $off,%rax`; the SSA lowerer now does the
   same as `pv - foff` typed `SVT_PTR`. LLVM path only.

2. **2-D LOCAL arrays** (`SBR_MEMORY` site 57). `Array[N, Array[M, T]]` bailed at
   the DECLARATION, which took the whole enclosing function out of the lane.
   `ssa_array2d_base` already computed row-major addresses for 2-D GLOBALS and
   2-D struct MEMBER fields, so the local case needed only a flat `N*M*esz` slot
   plus a recorded row stride (`ssa_mem_rowstride`, new, name-indexed);
   `a[i][j]` then reuses the existing `ssa_region_base` ND_INDEX path unchanged.
   3-D+ still bails — there is no third stride to record. Every 1-D consumer of
   `ssa_mem_isarr` is guarded with `rowstride == 0`, and 2-D is its own
   redeclaration category.

3. **`NM_MAX` 1024 -> 2048** (`start_kernel`, `nm=1024 == NM_MAX`). **Measured
   before raising.** Instrumenting the emitter to print `nm_count` per function
   over the whole-kernel closure with the cap temporarily at 4096 gives exactly
   four functions above 400 distinct names:

   | function | distinct names | basic blocks |
   |---|---|---|
   | `start_kernel` | **1492** | 2605 |
   | `block_smoke_test` | 596 | 998 |
   | `linux_u_syscall_dispatch_inner` | 539 | 538 |
   | `do_syscall_dispatch` | 471 | 1066 |

   So 1024 was binding on `start_kernel` **alone**. 2048 clears it with 37%
   headroom and leaves the runner-up 3.4x under. Cost on the same whole-kernel
   emit: **45.1 s at 1024, 60.6 s at 4096 (+34%)**, so 2048 is ~+11% (measured
   54.0 s with all three fixes in); `.bss` grows 32 -> 64 MiB (`ssa_curdef` +
   `ssa_incphi`, each `SSA_BB_MAX * NM_MAX`).

   **RAISE, not split.** Splitting `start_kernel` means refactoring the SHARED
   boot sequence — 2605 basic blocks, x86's primary entry point, the one
   function the whole tree's correctness rests on — to buy an 11% host-compile
   win nobody asked for. `concat_compiler_source.py`'s `SSA_BB_MAX` lockstep
   guard was EXTENDED (`_check_nm_lockstep`), not duplicated: it fails the concat
   BY NAME on any name-indexed array left unscaled across
   cfg.ad/regalloc.ad/ssa.ad, and on the two sibling CONSTANTS (`LV_WORDS`,
   `RA_MAXNAMES`) whose staleness does not crash but silently truncates the
   liveness/allocation domain.

### Predicted-class fallout, found by building

With `start_kernel` emitting, it referenced `user_demo_entry` — the x86 ring-3
payload from `arch/x86/kernel/syscall_64.S` that it takes the ADDRESS of as the
baked init fallback — which was invisible while `start_kernel` was itself a
stub. The auto-stubber correctly REFUSED it (its scope is BAILED symbols only,
and this is a genuine missing arch mechanism), so the link hard-failed instead of
papering over it. Added to `arch/arm64/llvm/stubs.c` alongside the same-class
`syscall_entry` / `smp_user_probe_entry` / `pf_race_probe_entry`.

### Evidence: EXECUTED, not inspected

`scripts/test_llvm_container_of_2d_exec.sh` (new, registered) runs
`tests/fuzz/regress_container_of_2d_local.ad` through THREE lanes and requires
all three to agree on stdout AND exit status with zero bails:

* **native codegen.ad x86_64** — the ORACLE. A shared-nothing second
  implementation, RECOMPUTED from source every run (a baked expected constant is
  a gate that goes stale and then gets "fixed").
* LLVM lane x86_64, run natively.
* LLVM lane aarch64, **EXECUTED under qemu-aarch64**.

All three: `1021071`, exit 143. The `container_of` arm is the verbatim body of
`_list_walk_and_sum`; the 16x32 uint8 grid is the verbatim shape of
`_try_parse_hamnix_roots`'s `done_words`.

Mutation-proven, and one mutation reshaped the gate:

| mutation | verdict |
|---|---|
| `container_of` drops the field-offset subtraction | FAIL — all three legs diverge (EXECUTION) |
| 2-D row stride = element stride (rows alias row 0) | FAIL (EXECUTION) |
| 2-D slot sized as if 1-D | **initially PASSED, twice** |

The third is worth recording. An under-sized 2-D slot is **invisible to
execution**: the writes and the reads use the SAME address arithmetic, so every
element still round-trips; the slot size only decides whose frame memory gets
stomped. A scalar guard promotes to a register and never touches the frame; a
neighbouring array local did not help either, because LLVM lays allocas out as it
pleases. So gate step 3b asserts the emitted alloca byte counts per function
against the hand-computed `N*M*esz` — and says in the gate text that it is
INSPECTION, not execution, because the difference is the whole point. (Mutating
ONE of the two slot sizers is a genuine no-op: `ssa_ensure_slot` takes the max of
the prealloc-scan size and the decl size, so they are redundant by construction.
Mutating BOTH reds at 3b.)

### Full verification run

| gate | result |
|---|---|
| `test_arm64_build_integrity.sh` | PASS — 11383/11383, 0 undefined, 0 auto-stubs |
| `test_arm64_usermode.sh` | PASS — byte-identical x86/aarch64, both EXECUTED |
| `test_arm64_llvm_lane_diff.sh` (200) | PASS — 200 EXECUTED on aarch64, 0 miscompiles |
| `test_arm64_a10_userland.sh` | PASS — checksum 965649 vs a fresh native oracle |
| `test_arm64_a11_archive.sh` | PASS — 3 members by name, random line through `read(2)` |
| `test_arm64_phase49.sh` | PASS — whole standalone ladder |
| `test_llvm_container_of_2d_exec.sh` | PASS (new) |
| `test_native_vs_seed_kobjdiff.sh` | PASS — 11383 functions, 0 divergences |
| `fuzz_adder_diff.sh 7` / `+ADDER_OPT2=1` | PASS — 500/500 each, 0 miscompiles |
| `test_llvm_lane_diff.sh` (200) | PASS — 0 miscompiles |
| `test_llvm_ir_verify_host.sh` | PASS |
| `build_user.sh` | 278 compiled, 276 LLVM / 2 native (the unrelated lane pins, unchanged) |
| `test_gate_registration/softgreen/kvmdark` | PASS (dark set still 20) |

### What is left, and it is NOT the compiler

`start_kernel` emitting does not mean the aarch64 kernel RUNS it: `head.S` still
calls the three `start_kernel_*_arm64` slices, and `arch/arm64/llvm/stubs.c`
still supplies 100-odd genuine x86 arch mechanisms (CR/MSR/EFI/IDT/TSS/AP/FPU).
Zero bails means the COMPILER is no longer the constraint on any aarch64
function. Everything remaining is arch layer.

---

## A12 — where it stops, and what the next person needs to know first

A12 was **scoped and not implemented** in this round; the bail work above
consumed the budget and A12 needs its own build-and-boot debug loop (a kernel
rebuild plus a QEMU boot is ~5 min per iteration, and MMU bring-up is iterative
by nature). What follows is the reconnaissance, so the next person starts from
evidence rather than from the plan.

### 1) A12 is a PORT, not an invention — the ladder already has all of it

`scripts/test_arm64_phase49.sh` passes on this tree, and its own output shows the
STANDALONE ladder (`arch/arm64/kmain.ad`, phases 1..49) already doing every item
on the A12 list:

```
Phase 49: consumer C read on EMPTY ring -> SLEEPING (parked, sleep #1)
Phase 49: parent wait(pid=0x51) -> child still running -> parent BLOCKED (descheduled, state WAITING)
Phase 49 PASS: EL0 fan-in reducer (THREE producer children ... each across separate address spaces ...)
```

fork/exec/wait, blocking in a syscall, per-task kernel stacks, **separate address
spaces**, ASID tagging (`kmain.ad:7048`) — all present, all EL0, all booting.
The A12 gap is that NONE of it exists in the **LLVM whole-kernel lane**
(`arch/arm64/llvm/`), which is 2023 lines of boot layer with ONE shared 2 MiB
EL0 window. So A12 rung 1 is: lift the ladder's per-task TTBR0/ASID machinery
into `arch/arm64/llvm/`, not design it.

### 2) There is a TLB trap already root-caused, waiting at the end of that port

`docs/arm64_phase50.md` (SHELVED) is the ladder's next rung and it is stuck on
exactly the mechanism A12 introduces: `arm64_mmu_init` maps RAM as **global**
(`nG=0`) 2 MiB blocks, `tlbi aside1is` only evicts per-ASID NON-global entries,
so a stale global identity translation shadows the per-ASID mapping under TCG.
Read that doc BEFORE building per-task spaces here, or the LLVM lane will
reproduce the same bug from scratch. Its Option A (carve a hole in the identity
map at the user window) applies verbatim to `arch/arm64/llvm/head.S`
`mmu_enable`, and is much cheaper to do while the window is being built per-task
anyway than to retrofit.

### 3) RESOLVE THIS FIRST — an EL0-permission discrepancy in the CURRENT lane

This is an observation with evidence, not a diagnosed bug, and it is load-bearing
for the A12 design because it decides whether per-task EL0 tasks can keep living
in kernel `.text`.

`head.S` `mmu_enable` fills `l2_pgtable` with `movz x1, #0x0705`. Decoding that
stage-1 block descriptor: bit0=1/bit1=0 = block, AttrIndx=1 (Normal-WB),
SH=inner, AF=1, and **AP[7:6] = 00 — EL1 R/W, EL0 NO ACCESS**. Only the one
overridden L2 slot (index 64, VA `0x4800_0000`) points at `l3_user_pgtable`,
whose leaves are `0x0747` (AP=01, EL0-RW, UXN=0).

But A9's two EL0 tasks link INSIDE the AP=00 region, not inside the window:

```
$ aarch64-linux-gnu-nm build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf | grep arm64_el0_task
00000000400814e4 T arm64_el0_task_a
00000000400814f0 T arm64_el0_task_b
```

`0x400814e4` is kernel `.text`, covered by an AP=00 identity block — and A9 erets
to it with `SPSR = 0x340` (M[3:0]=0 => EL0t, I unmasked), then those tasks
demonstrably execute and issue `svc #0` writes. An EL0 instruction fetch from an
AP=00 page should take a permission abort.

Something in that chain is not what the comments say. Possibilities, in the order
worth testing:

* the descriptor is not what is read back at runtime (dump `l2_pgtable[64..]` and
  the actual entry covering `0x4008_0000` from EL1 after `mmu_enable`);
* `-cpu cortex-a72` under TCG is permissive here (compare against `-cpu max`, and
  against `-M virt,accel=kvm` on real ARM when the Pinebook lands);
* the tasks are not actually running at EL0 (read `CurrentEL` from the task and
  print it — cheapest decisive test, and worth doing FIRST).

Whichever it is, A12 must not build per-task address spaces on top of an
unexplained permission result. If the third bullet is the answer, the A9/A10/A11
"EL0" claims need re-reading too, and that is exactly the kind of thing this lane
has been burned by before.

### 4) Recommended A12 rung 1, once (3) is settled

Per-task TTBR0 with TWO concurrently-resident address spaces, proven by
*aliasing*: give each task its own L1/L2/L3 triple (3 pages of `.bss` each),
identical except that L2[64] points at a per-task L3 backing the SAME VA
`0x4800_0000` with DIFFERENT physical pages. Add slot 34 (TTBR0 = table PA |
ASID<<48) to the 36-slot context block — A9's blocks zero it, so `msr ttbr0_el1`
is skipped for them and the change is backward compatible with A8/A9/A10/A11.
Have the kernel write DIFFERENT content into each task's backing page *through
the identity map* (by PA, EL1) and have both tasks read the SAME VA: if the
spaces are genuinely separate they print different strings, and if TTBR0 is not
actually being switched they print the same one. That is a proof that fails
loudly rather than a proof that merely runs, and it is what the existing
`test_arm64_a11_archive.sh` oracle style should be extended to assert.

---

## Implementation status (2026-07-30) — A11 EMBEDDED IMAGE ARCHIVE, LOADED BY NAME + A REAL `read(2)`

**A11 — the aarch64 LLVM kernel carries SEVERAL compiled EL0 images in one
embedded archive, loads them BY NAME, and services a REAL `read(2)` off the
PL011: DONE.** Gate `scripts/test_arm64_a11_archive.sh` (new, registered):
**PASS**, ~145 s.

Also settled by the USER on this date, and it scopes everything below: **ARM64
ships on the LLVM path only.** `adder/compiler/codegen_arm64.py` (the
hand-written AArch64 seed backend) is not being extended; it stays as a live
regression *fixture*, which is exactly why `scripts/test_arm64_phase49.sh` is
now registered (see "Gate coverage" below).

### What was structurally missing at A10

Two things, and they are the two a shell cannot do without:

1. **One image.** A10 `.incbin`'d exactly ONE blob, so "load the user program"
   and "load THE blob" were the same operation. Nothing in the lane could tell a
   by-name loader from a loader that ignores the name.
2. **No input.** `read(2)` returned 0 unconditionally, so every EL0 program on
   this lane was a banner printer.

### 1) The archive

`scripts/pack_arm64_user_archive.py` packs several flat images into one blob —
magic + count + fixed-width 16-byte name table + 16-byte-aligned payloads —
rebuilt on every kernel build (steps 3a/3a2) and `.incbin`'d by `user_blob.S`.
`init/main.ad`'s `arm64_a11_load_named_arm64(base, size, name)` walks the table
and copies the NAMED member into the EL0 window; an absent name **MISSES** and
returns 0. The name field is fixed-width on purpose: the walk is then a bounded
byte compare with no pointer chasing, which keeps the loader itself inside the
LLVM SSA subset (a bail *there* would mean no loader at all).

`arm64_a10_load_arm64` is now a thin wrapper that asks for the member named
`a10`, so the lane has ONE image-load implementation instead of two that can
drift, and A10's serial contract is unchanged (its gate still passes).

Three members today, all ordinary Adder through the same backend:

| name   | source                   | what it proves |
|--------|--------------------------|----------------|
| `a10`  | `user/arm64_a10_el0.ad`  | the A10 rung, unchanged |
| `sum`  | `user/arm64_a11_sum.ad`  | a DIFFERENT image is selected by name |
| `echo` | `user/arm64_a11_echo.ad` | `read(2)` moved real bytes |

`head.S` asks for **`sum` first even though `a10` is member 0**, so a loader
that ignored the name would run A10 again and be caught.

### 2) The `read(2)` — the receive half of the A4 trick

The kernel's own blocking stdin primitive is `early_8250.ad`'s
`early_getc_polled()`: spin on LSR.DR, read RBR. Both are `inb`s, so
`arch/arm64/llvm/intrinsics.S` now routes `inb(0x3FD)` to the PL011 Flag
Register's `RXFE` bit and `inb(0x3F8)` to the PL011 Data Register. The lane gets
a real read with **zero change to the shared kernel serial driver** — precisely
what `outb`→PL011 DR did for `printk` in A4. The dispatcher arm reads
line-oriented with a **bounded** wait: unbounded spinning turns "nobody typed"
into a hung boot that reports a timeout instead of a verdict.

### Verified furthest-point PL011 serial (a known line piped to stdin)

```
[000142] A11: loaded EL0 image by name 'a10' (1752 bytes, byte-sum 167720) -> 0x48010000
[000154] A10 PASS: real Adder-compiled EL0 program ran; exit status 17 == expected 17
A11: embedded EL0 image ARCHIVE, loaded BY NAME (+ real read on the PL011)
[000155] A11: loaded EL0 image by name 'sum' (1224 bytes, byte-sum 127230) -> 0x48010000
A11: S=179190
[000160] A11: program 'sum' exited, status=246
[000161] A11: loaded EL0 image by name 'echo' (1200 bytes, byte-sum 121877) -> 0x48010000
A11: R=HAMNIX-A11 N=10 C=859903
[000168] A11: program 'echo' exited, status=255
[000169] A11: load-by-name MISS for 'nosuchprog' (no such member)
A11: archive stage complete, returned to kernel
```

x86-64 native runs of the SAME two `.ad` files print byte-identical `S=`/`R=`
lines and exit 246 / 255. 0 exceptions hit the diagnostic vector; A8/A9/A10 all
still pass ahead of it.

### The gate does not trust anything the kernel says about itself

`scripts/test_arm64_a11_archive.sh` recomputes both oracles every run (same
sources, x86-64, run natively, echo fed the SAME line), **randomises the piped
line per run** so no canned answer can track it, parses the archive
INDEPENDENTLY of the kernel, and requires the absent-name MISS. Mutation-proven
three ways: skip the name compare → FAIL; restore the pre-A11 `read -> 0` stub →
FAIL; hide `qemu-system-aarch64` → 125 INCONCLUSIVE.

### HONEST SCOPE — what A11 is NOT

Every member links at the SAME VA (`user.lds`) and they run **one at a time**.
This is "several programs, selectable by name", **not** several concurrently
resident address spaces — that still needs the per-task TTBR0 + demand-paging
work in the A9/A10 plans. There is also no filesystem: the archive is embedded,
not on disk.

### Gate coverage (2026-07-30) — the lane is no longer dark

51 of 53 `test_arm64_*.sh` were unregistered, which is *why* an x86 SSA change
could break the ARM64 link and ship. Now registered, with measured runtimes:

| gate | cost | what it is |
|------|------|-----------|
| `test_arm64_usermode.sh` | ~12 s, qemu-user | same program emitted x86 + aarch64, both EXECUTED, byte-identical |
| `test_arm64_llvm_lane_diff.sh` | ~7 s, qemu-user | randomized execution differential (new) |
| `test_arm64_build_integrity.sh` | ~63 s | both lanes still build/link/execute |
| `test_arm64_a10_userland.sh` | ~2.5 min, 1 QEMU | A10 vs a fresh native oracle |
| `test_arm64_a11_archive.sh` | ~2.5 min, 1 QEMU | A11 (new) |
| `test_arm64_phase49.sh` | ~6.5 min, 1 QEMU | the WHOLE standalone ladder in one boot |

The other 48 `test_arm64_phase*.sh` are rungs of the ladder `phase49` runs end
to end (each gated on the previous rung's PASS marker), so they carry a stated
on-demand rationale in their headers instead — they are the bisection tool for
when `phase49` reds, not 49 more copies of the same boot.

### Next step (A12) — recommended

The remaining gap to a compiled `hamsh` is no longer structural in the loader;
it is **process state**. Ranked:

1. **Per-task TTBR0 + a Data-Abort (0x400, EC=0b100100) demand-paging path.**
   Every A11 member runs at the same VA in the one shared window. `fork`/`exec`
   need per-task address spaces before anything else on this list is meaningful.
2. **Per-task kernel stacks + `__switch_to`,** so a task can BLOCK in a syscall
   (which `read(2)` now genuinely could — today it spins with a bounded budget
   instead of sleeping, which is honest but is not scheduling).
3. **Broaden the syscall surface** — ideally by getting `do_syscall` itself to
   emit rather than re-listing the ABI in `arm64_do_syscall_arm64`.
4. **virtio-mmio + virtio-blk + a real filesystem,** so the archive becomes a
   directory and `hamsh` is loaded from disk rather than from `.rodata`.

### `_handle_tag` (investigated, NOT fixed) — it is not an SSA-subset problem

`scripts/build_user.sh`'s only two native fallbacks are `hambrowse` and `js`,
both reported as `link-undef:_handle_tag (callee bailed SSA subset)`. That is
the identical shape as the ARM64 link bug (an emitted caller referencing a
bailed callee), and on ARM64 there is no native fallback to hide it. But the
label is misleading: the emitted marker is **`; BAILED @_handle_tag reason=1`**,
and reason 1 is `SBR_OVERFLOW` — a per-function ARENA CAP, the same class as
`start_kernel`, not an `SBR_*` subset feature. **Broadening the SSA subset
cannot fix it.**

`_handle_tag` (`lib/web/dom/forms.ad:898`) is a ~2300-line tag dispatch with
~271 distinct local names and ~485 branch statements. Note the host compiler
already runs `NM_MAX=1024` (not the on-disk 256 —
`scripts/concat_compiler_source.py HOST_BUFFER_OVERRIDES`), so the NAME cap is
NOT the binding one and which cap trips is still open. The next step is to
attribute the bail: `ssa_set_bail(SBR_OVERFLOW)` has ~12 call sites in
`ssa.ad`, so record WHICH one fires and its counter value, then either raise
that specific cap in lockstep with every array it sizes, or apply the A4
extract-method treatment to the one oversized branch (the `<p>`/block arm at
`forms.ad:1485` is 609 lines on its own). Either way it lands behind the WPT
ratchets — any `lib/web/` change gates on the testharness floor.

---

## Implementation status (2026-07-28) — A10 REAL COMPILED EL0 USER PROGRAM

**A10 — the aarch64 LLVM kernel LOADS AND RUNS A COMPILED USERLAND PROGRAM.**

Everything through A9 ran at EL0 as **hand-written AArch64 assembly** living in
the kernel's own `.text` (`arch/arm64/llvm/el0.S`, `sched.S`) — enough to prove
the exception-level plumbing, but a scheduler demo, not a userland. A10 closes
that gap: the thing executing at EL0 is now **compiler output**.

Pipeline (all of it rebuilt on every kernel build, so the blob can never go stale):

```
user/arm64_a10_el0.ad                       ordinary Adder program
  --(host_ac --backend=llvm --target=aarch64)-->  a10_user.ll   (0 bails, 0 declares)
  --(clang -c --target=aarch64-none-elf)------->  a10_user.o
  --(ld -T arch/arm64/llvm/user.lds + user_rt.S crt0)-->  a10_user.elf @ 0x4801_0000
  --(objcopy -O binary)------------------------>  a10_user.bin
  --(.incbin via arch/arm64/llvm/user_blob.S)-->  embedded in the kernel image
  --(arm64_a10_load_arm64(), exec()-shaped copy)-->  the EL0-RW/EL0-X window
  --(arm64_a10_launch, arch/arm64/llvm/a10.S)---->  eret to EL0
```

The program's syscalls go through the **same A8 sync-vector path with no A10
special-casing**: the compiler's `__syscallN` builtin lowers to `svc #0` with the
number in x8, and `ssa_llvm.ad`'s `ll_aarch64_syscall_nr` remaps the x86-64
numbers baked in the source to the asm-generic AArch64 ones (write 1→64,
exit 60→93, getpid 39→172) — exactly the ABI `arm64_do_syscall_arm64` already
services.

Verified furthest-point PL011 serial (`qemu-system-aarch64 -M virt -cpu cortex-a72`):

```
A10: loading a COMPILED Adder EL0 user program into the user window
[000138] A10: loaded EL0 user image: 1752 bytes -> 0x48010000 (byte-sum 167720)
[000139] A10: running a REAL Adder-compiled EL0 program (not hand-written asm)
[000140] [arm64-llvm] EL0 svc: getpid -> current_task_pid() = 0
[000141] [arm64-llvm] EL0 svc: write(fd=1, buf, len) -> console
A10: P=0
[000144] [arm64-llvm] EL0 svc: write(fd=1, buf, len) -> console
A10: C=965649
[000147] [arm64-llvm] EL0 svc: exit(status=17) serviced
A10: EL0 user program exited, returned to kernel
[000139] A10 PASS: real Adder-compiled EL0 program ran; exit status 17 == expected 17
```

0 exceptions hit the diagnostic vector; A8/A9 still pass ahead of it.

### Why the checksum, and why the gate does not trust it

The program is deliberately non-trivial so "it ran" cannot be faked by the
loader: a sieve over a global array (EL0 memory traffic), single recursion
(Collatz), double recursion (Ackermann), all mixed into one checksum whose low
byte becomes the exit status. Any miscompile along that path, or any break in the
EL0 load/store or syscall path, moves the checksum.

The kernel cross-checks the exit status against `ARM64_A10_EXPECT_STATUS` in
`init/main.ad` — but **a constant in the kernel is a lying gate waiting to
happen** (edit the program, the constant goes stale; get a red, "fix" the
constant). So `scripts/test_arm64_a10_userland.sh` never trusts it. On every run
it **recomputes the oracle**: compiles the SAME `.ad` for x86-64 with the same
`host_ac`, runs it natively, and asserts

1. the ARM64 serial shows THAT checksum (`965649`, byte-identical across arches),
2. the ARM64 exit status matches `checksum % 256`,
3. `init/main.ad`'s baked constants AGREE with the fresh oracle,
4. the embedded blob is byte-identical to one rebuilt from the current source
   (stale-blob guard),
5. the loader's reported byte count equals the on-disk blob size,
6. all three syscalls reached the real dispatcher, and 0 exceptions fired,
7. A8 and A9 did not regress.

Both failure modes were **negative-tested**: removing the `bl arm64_a10_launch`
reds at assertion 1, and changing `A10_SIEVE_N` without updating the kernel
constant reds at assertion 3.

### Files

`user/arm64_a10_el0.ad` (new, the program) · `arch/arm64/llvm/{user_rt.S,
user.lds, user_blob.S, a10.S}` (new, crt0 + link + embed + launcher) ·
`init/main.ad` (+2 aarch64-only functions, called ONLY from `head.S`) ·
`scripts/build_kernel_llvm_arm64.sh` (step 3a) ·
`scripts/test_arm64_a10_userland.sh` (new, authoritative gate) ·
`scripts/test_arm64_llvm_kernel.sh` (A10 smoke assertions).

x86 non-regression: `scripts/test_native_vs_seed_kobjdiff.sh` → **0 divergences
across 11144 functions** (11142 + the 2 new aarch64-only functions). No compiler
source (`codegen.ad`, `ssa.ad`, `ssa_llvm.ad`, Python seed) was touched.

### Also fixed here: the lane did not build at all

`arch/arm64/llvm/stubs.c` is a hand-maintained snapshot of the symbols the
whole-kernel `.ll` leaves undefined. Main's `api_autostubs` regeneration had grown
a REAL definition of `linux_abi_api_snd_pcm__snd_pcm_new` inside the closure, so
the aarch64 link died with `multiple definition` — `test_arm64_llvm_kernel.sh`
could not even build, let alone boot. `build_kernel_llvm_arm64.sh` now diffs the
globally-defined symbols of `kernel_arm64.o` against `stubs.o` and `objcopy -L`
localizes the intersection, so the kernel's real definition always wins and the
stub snapshot self-heals against future autostubs churn.

### Next step (A11) — recommended

A10 proves the **toolchain** reaches EL0. The next unblocked rung is **more than
one compiled program, loaded by name**: give the loader a tiny embedded archive
of several `.ad`-built images instead of one `.incbin`, and give the EL0 side a
real `read()` on the PL011 so a program can consume input. That is the last
structural gap before a compiled `hamsh` can run — at which point the ARM64 LLVM
lane has a shell, and the Phase-1..49 standalone ladder's userland features
(fork/exec/wait, pipes, signals, FAT16) become ports rather than inventions.

---

## Implementation status (2026-07-24) — A9 PREEMPTIVE EL0 SCHEDULING (two EL0 tasks time-sliced by the timer IRQ)

**A9 — the aarch64 LLVM kernel time-slices TWO EL0 tasks under the ARM
generic-timer IRQ: each timer tick from EL0 preempts the running task and
context-switches (full EL0 state save/restore + `eret`) to the other, the switch
DECISION made by emitted-Adder code: DONE.** This is the "real preemptive
multitasking" milestone (A8 ran a single EL0 task to exit; A9 runs two, forever,
until the demo's bounded switch quota). Gate `scripts/test_arm64_llvm_kernel.sh`
(extended with A9 assertions): **PASS**. Verified furthest-point PL011 serial from
the actual `qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G` run (grep-a'd):
```
A9: preemptive EL0 scheduling (2 tasks, timer-preempted EL0<->EL0)
[000094] A9: prepared EL0 task A/B message buffers in the EL0-RW window
[000095] A9: registered 2 EL0 task contexts (round-robin, timer-preempted)
[EL0-A] task A running (timer-sliced)
[000099] [arm64-llvm] preempt tick 1: timer-driven EL0<->EL0 switch
[EL0-B] task B running (timer-sliced)
[000103] [arm64-llvm] preempt tick 2: timer-driven EL0<->EL0 switch
[EL0-A] task A running (timer-sliced)
   ... (alternating; task A ran 4x, task B ran 4x) ...
[000139] [arm64-llvm] preempt tick 8: timer-driven EL0<->EL0 switch
[000140] A9: preemptive EL0 scheduling proven (8 timer-driven EL0<->EL0 switches)
A9: scheduler returned to kernel (bounded preemption demo complete)
```
Both EL0 tasks demonstrably RUN (the `[EL0-A]`/`[EL0-B]` lines are each task's
`write(1, buf, len)` of a distinct kernel-filled EL0 buffer — reaching the console
only via a real EL0 load of its own memory + the real write syscall), the timer
PREEMPTS the running task 8 times (`preempt tick N`) alternating A↔B, and after the
bounded quota the scheduler cleanly returns to the kernel. **0 exceptions hit the
diagnostic vector.**

**1) Lower-EL IRQ vector (0x480) + full EL0-context switch — boot layer.** The
tasks run at EL0 with **IRQs UNMASKED** (`SPSR_EL1 = 0x340`: EL0t, D/A/F masked but
**I=0**), so each ~10 ms virtual-timer PPI fires *at EL0* and traps to the "Lower
EL using AArch64 / IRQ" slot (offset **0x480**, newly wired in `vectors.S` — was
the halt diagnostic). The new boot-layer file **`arch/arm64/llvm/sched.S`**
(`arm64_llvm_lower_irq_entry`) saves the **FULL interrupted EL0 context** — x0..x30
+ `SP_EL0` + `ELR_EL1` + `SPSR_EL1` (a 34-slot context block) — into the running
task's block (published in `arm64_current_ctx`), acks the GIC (`GICC_IAR`),
quiesces the timer, calls the emitted-Adder scheduler, re-arms (`CNTV_TVAL`) + EOIs
(`GICC_EOIR`), then restores the *next* task's full context and `eret`s into it — a
genuine EL0↔EL0 context switch driven by the EL1 timer IRQ. The privileged
mechanics (register frame, `SP_EL0`/`ELR`/`SPSR` sysregs, GIC/timer MMIO, `eret`)
cannot be expressed from Adder, so they live in the boot layer, faithfully porting
the proven standalone `arch/arm64/vectors.S` `arm64_lower_irq_entry` flow but kept
ISOLATED (separate file/build). The launcher `arm64_el0_sched_launch` builds both
task context blocks (entry PC / `SP_EL0` / `SPSR`), re-arms the timer with **EL1
IRQs masked** (`daifset,#2` — so the first tick is taken at EL0 via the task SPSR,
not at EL1 by the A6 0x280 handler), and `eret`s into task A; on the stop signal
the IRQ stub restores the kernel SP/LR stashed at launch and returns to `head.S`.

**2) The scheduling decision is emitted-Adder code.** `arm64_sched_pick_arm64(cur)`
(new additive public fn in `init/main.ad`) does the kernel-visible half: bump the
switch counter, round-robin-toggle the current-task index, print the per-switch
line, and return the NEXT task's context-block address (which the boot stub
restores + `eret`s into). At the bounded quota (`ARM64_SCHED_SWITCH_LIMIT = 8`) it
raises `arm64_sched_should_stop` (an asm-visible global the IRQ stub reads) so the
demo terminates deterministically instead of a preempt storm filling the serial
log. `arm64_sched_register_arm64(c0,c1)` publishes the two block addresses + resets
the round-robin state, and `arm64_sched_prepare_arm64()` fills each task's message
buffer in the EL0-RW window (EL0 cannot read the kernel's AP=00 `.rodata`, so the
kernel writes the tag strings the tasks then `write`). The two EL0 tasks
(`arch/arm64/llvm/sched.S`) each `strlen`+`write(1, buf, len)` via `svc` then spin
in a bounded delay so the timer preempts them mid-slice; they share the A8 fine
EL0-RW window (0x4800_0000-0x481F_FFFF, AP=01) with distinct SP_EL0 stacks +
buffers.

**Regression fixed in-flight (load-bearing).** A8's EL0 task called `exit()`, which
latches `arm64_llvm_el0_exit_pending = 1`. A9's tasks reuse the SAME real svc
dispatcher (`arm64_svc_dispatch_arm64`) for their `write()`s, so a stale latch made
every A9 write be misread as an exit — the sync handler returned to EL1/`head.S`
(where the timer is masked), starving the preempt and looping the A9 setup forever
(51 705 restarts, 0 preempts). `arm64_sched_register_arm64` now clears
`arm64_llvm_el0_exit_pending`/`_code`, and the preempt fires correctly. (This is a
reminder that the EL0-exit latch is global state; per-task exit tracking is future
work.)

**How x86 stayed byte-identical — additive `*_arm64` slice.** `init/main.ad` change
is **purely additive** (0 deletions; `git diff` = 90 insertions): the new
`arm64_sched_*` functions + globals, all called ONLY from `arch/arm64/llvm/sched.S`
(+ head.S). The x86 `start_kernel()` never references any of them; its body is
untouched. **Seed-compat gotcha:** the two context-block-pointer globals are held
as `uint64` (not `Ptr`) because the x86 seed compiler requires an *integer* global
initializer (a `cast[Ptr](0)` init is native/LLVM-only) — cast to `Ptr` at the use
site, which both compilers accept. `scripts/test_native_vs_seed_kobjdiff.sh`:
**PASS — zero semantic kernel divergences across 11075 matched functions** (native
codegen == seed). No `ssa*.ad`/`codegen.ad` edit. Boot-layer edits
(`sched.S` new, `vectors.S` 0x480 slot, `gic.S` one `.globl`, `head.S` A9 call) +
the build/gate scripts touch nothing on the x86 lane.

**A10 plan — from preemptive scheduling to a real `hamsh` shell (ranked, honest
scope).** A9's two tasks share one address space (distinguished by PC/stack/buffer)
and are embedded; a real userland still needs:
1. **Per-task TTBR0 SWITCHING + demand paging + the Data-Abort fault path.** Give
   each task its OWN TTBR0 (switched on context-switch, so tasks are memory-
   ISOLATED, not sharing the A8 window), an allocator handing out user frames, and
   a **Lower-EL Data Abort handler** (0x400 sync, EC=0b100100) that demand-pages a
   faulting EL0 access — the prerequisite for `brk`/`mmap` growing a real
   heap/stack. The standalone lane's Phase 14/16/41 demand-paging is the reference;
   watch the cortex-a72 MMU-edit hazard (install fine L3 leaves + `TLBI`, never a
   block flip). A voluntary-yield syscall (`sched_yield`) would also let tasks
   cooperate, not only be preempted.
2. **`__switch_to` on real per-task KERNEL stacks + blocking.** A9 switches EL0
   register context but every task shares the one kernel exception stack; a task
   that BLOCKS in a syscall (read from a real device, wait on a wq) needs its own
   kernel stack saved/restored. Wire `sched_init`'s task structs (built since A6,
   inert) to an actual `__switch_to` on this lane.
3. **Broaden the real syscall surface** (open/close/read via vfs, brk/mmap once
   demand paging is up, clone/execve) — ideally by getting `do_syscall` itself to
   emit (auto-split / a gated cfg-cap raise for the LLVM lane) so the FULL ABI is
   shared with x86 rather than re-listed in `arm64_do_syscall_arm64`.
4. **virtio-mmio + virtio-console + virtio-blk + initramfs → on-disk `hamsh`.**
   `-M virt` is all-virtio: the `virtio-mmio` transport, a virtio-console for real
   bidirectional tty I/O, virtio-blk for a root device, mount the initramfs, and
   make a real on-disk `hamsh` the first user task (mirroring the standalone track's
   Phase 30+). Largest remaining item; gates a true interactive shell.
5. **Higher-half TTBR1 kernel VA + compiler follow-ups** (`align 8` on the
   rdrand/mul128 scratch globals to drop the build-lane `sed`; `FEAT_RNG` gate).

---

## Implementation status (2026-07-24) — A8 REAL USERLAND FOUNDATION (EL0-RW fine TTBR0 map + REAL syscall dispatch)

**A8 — the aarch64 LLVM kernel gives an EL0 task a FINE per-page EL0-RW address
space (so it can READ/WRITE its own memory, not just registers) AND routes its
`svc` into the kernel's REAL syscall handlers: DONE.** This is the "real userland
foundation" milestone. Gate `scripts/test_arm64_llvm_kernel.sh` (extended with A8
assertions, A7 register-only demo superseded): **PASS**. Verified furthest-point
PL011 serial from the actual `qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G`
run (grep-a'd):
```
[000087] [arm64-llvm] timer IRQ OK (first scheduler tick(s) taken + handled)
A8: EL0-RW user window + real syscall dispatch (dropping to EL0)
[000088] A8: prepared EL0-RW user window (SRC=0x48000000, 56 src bytes)
[000089] [arm64-llvm] EL0 svc: getpid -> current_task_pid() = 0
[000090] [arm64-llvm] EL0 svc: write(fd=1, buf, len) -> console
EL0-RW-DATA-OK: EL0 load/store via fine TTBR0 L2/L3 map
[000092] [arm64-llvm] EL0 write serviced (56 bytes to console)
[000093] [arm64-llvm] EL0 svc: exit(status=0) serviced
A8: EL0 task exited, returned to kernel (real syscall round-trip complete)
```

**1) EL0-RW fine mapping (EL0 accesses its OWN memory) — FINE L2/L3, not a block
flip.** `mmu_enable` (arch/arm64/llvm/head.S) now builds a real page-table
hierarchy: L1[1] is a TABLE descriptor → `l2_pgtable` (512 × 2 MiB Normal-WB
blocks, AP=00 — the kernel image + buddy/slab RAM stay EL1-only exactly as
before), and ONE L2 slot (index 64 ⇒ VA `0x4800_0000`) is overridden to a TABLE →
`l3_user_pgtable`, whose 512 × 4 KiB leaves map `0x4800_0000-0x481F_FFFF` **AP=01
(EL0-RW + EL1-RW), UXN=0** — a 2 MiB EL0-RW user window. This is deliberately the
**fine L2/L3 per-page mapping the A7 doc mandated, NOT a block-descriptor AP flip
of the whole RAM block** (that experiment hung MMU-enable on `-cpu cortex-a72`).
Kernel RAM keeps AP=00 (unreadable from EL0); only the carved window is EL0-RW.
The EL0 program (`arch/arm64/llvm/el0.S`) now: (a) push/pops through **SP_EL0**
(retargeted into the window at `0x481F_0000`), (b) **memcpy's SRC(`0x4800_0000`)
→ DST(`0x4800_1000`) byte-by-byte with its OWN EL0 `ldrb`/`strb`**, then (c)
`write(1, DST, len)`. The kernel pre-fills SRC via the new additive
`arm64_el0_prepare_user_mem_arm64()` (EL1 writing the AP=01 page). The copied
`EL0-RW-DATA-OK…` string reaching the console is the DEFINITIVE proof the EL0
load+store round-trip worked — a missing/incorrect EL0-RW leaf would fault into
the `vectors.S` diagnostic or emit an empty buffer. (Regression hazard fixed
in-flight: the fill loop leaves `x0` holding the L3 table, so `msr ttbr0_el1, x0`
must reload `l1_pgtable` first — a stale `x0` there points TTBR0 at the L3 and
hangs MMU-enable, the same symptom class as the block-flip hazard.)

**2) `svc` routed into the kernel's REAL syscall dispatch.** The monolithic
`do_syscall()` is an LLVM bail (its ~7.6 k-line CFG blows the compiler's per-fn
arena caps — the same reason `start_kernel` is factored; it links as a return-0
stub and cannot service EL0). A8 therefore adds `arm64_do_syscall_arm64(nr,
a0..a5)` (additive public fn in `init/main.ad`) that **translates the aarch64
Linux syscall number → the kernel's native `SYS_*` space and calls the SAME real
handler functions `do_syscall` dispatches to** — `current_task_pid()` (getpid),
`get_jiffies()`, the `early_putc_user()` console-write path (write, reading the
EL0 buffer), and the exit-status record. `arm64_svc_dispatch_arm64` (the emitted
dispatcher the `el0.S` sync stub calls) now decodes the frame and routes through
it, replacing the A7 inline write/exit demo. The EL0 program round-trips **getpid
(→ real boot-task pid 0), write, and exit** — real kernel syscall handlers, not a
stub, servicing EL0. The `svc` still traps to the `vectors.S` Lower-EL sync slot
(0x400), the proof it executed at EL0.

**How x86 stayed byte-identical — additive `*_arm64` slice.** `init/main.ad`
change is PURELY ADDITIVE: one import (`early_putc_user`, already in the closure
via the console path) + the new arm64-only functions (`arm64_do_syscall_arm64`,
`arm64_el0_prepare_user_mem_arm64`, rewritten `arm64_svc_dispatch_arm64`, syscall
constants). The x86 `start_kernel()` never references any of them; its body is
untouched (`git diff` shows no change to any existing x86-reachable line). All
boot-layer edits are in `arch/arm64/llvm/` (head.S MMU + el0.S). No
`ssa*.ad`/`codegen.ad` edit. `scripts/test_native_vs_seed_kobjdiff.sh`: **PASS**
(native codegen == seed, byte-identical by construction).

**A9 plan — from the real-userland foundation to a real `hamsh` shell (ranked,
honest scope).** What remains to run an actual on-disk shell:
1. **Per-TASK TTBR0 + demand paging + the Data-Abort fault path.** A8 gives ONE
   fixed EL0-RW window shared by the (single) EL0 task and identity-mapped. A real
   userland needs a per-task TTBR0 that is SWITCHED on context-switch (so tasks
   are isolated), an allocator that hands out user frames, and a **Lower-EL Data
   Abort (0x400 sync, EC=0b100100) handler** that demand-pages a faulting EL0
   access — the prerequisite for `brk`/`mmap` growing a real heap/stack.
2. **Preemptive EL0 scheduling.** Wire the `gic.S` timer IRQ, when it fires from
   EL0, to the **Lower-EL IRQ vector (0x480)** with full EL0-context save/restore
   + `arm64_sched_pick` (mirroring the standalone `arm64_lower_irq_entry`), so the
   timer preempts a running EL0 task and switches to another — a real EL0↔EL0
   switch. Needs per-task kernel stacks + `__switch_to` on this lane (today
   `sched_init` builds task structs but never context-switches).
3. **Broaden the real syscall surface.** `arm64_do_syscall_arm64` services
   getpid/write/read/exit today. Route the rest of the native `SYS_*` ladder
   (open/close/read via vfs, brk/mmap once demand paging is up, clone/execve) —
   ideally by getting `do_syscall` itself to emit (auto-split / a gated cfg-cap
   raise for the LLVM lane) so the FULL ABI is shared with x86 rather than
   re-listed.
4. **virtio-mmio + virtio-console + virtio-blk + initramfs → on-disk `hamsh`.**
   `-M virt` is all-virtio: bring up the `virtio-mmio` transport (DT in `x0` or
   the fixed `0x0a00_0000` window), a virtio-console for real bidirectional tty
   I/O, virtio-blk for a root device, mount the initramfs, and make a real on-disk
   `hamsh` (not an embedded stub) the first user task — mirroring the standalone
   track's Phase 30+. This is the largest remaining item and gates a true shell.
5. **Higher-half TTBR1 kernel VA + compiler follow-ups.** Move the kernel into the
   TTBR1 upper half (`0xffff_…`) with demand paging (robust per-task memory
   model), and the gated `ssa_llvm.ad` follow-ups (`align 8` on the rdrand/mul128
   scratch globals to drop the build-lane `sed`; `FEAT_RNG` gate).

---

## Implementation status (2026-07-24) — A7 EL0 USER-MODE + `svc #0` SYSCALL DISPATCH (RUNS USERSPACE)

**A7 — the aarch64 LLVM kernel DROPS TO EL0 and SERVICES A USER `svc #0` SYSCALL
as emitted-Adder code, then returns cleanly to the kernel: DONE.** This is the
"runs userspace" milestone. Gate `scripts/test_arm64_llvm_kernel.sh` (extended
with A7 assertions): **PASS**. Verified furthest-point PL011 serial from the
actual `qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G` run (grep-a'd):
```
[000087] [arm64-llvm] timer IRQ OK (first scheduler tick(s) taken + handled)
A7: dropping to EL0 (arm64_el0_launch -> first user task)
[000088] [arm64-llvm] EL0 svc #0: write syscall entered (x8=64)
[000089] HELLO-FROM-EL0-USERSPACE via svc #0
[000090] [arm64-llvm] EL0 write syscall serviced (returning byte count)
[000091] [arm64-llvm] EL0 exit syscall serviced (status=0)
A7: EL0 task exited, returned to kernel (svc round-trip complete)
```
A tiny EL0 user program (`arch/arm64/llvm/el0.S` `arm64_el0_user_entry`) issues
`write(1, msg, len)` then `exit(0)` via `svc #0`, mirroring the Linux aarch64
syscall ABI (number in `x8`, args `x0..x5`, return in `x0`). Each `svc` traps to
the **`vectors.S` "Lower EL using AArch64 / Synchronous" slot (offset 0x400)** —
which is the DEFINITIVE proof the code ran at **EL0**: an `svc` executed at EL1
would trap to the *Current-EL* slot (0x200 → the halt diagnostic), never seen.
The slot routes to `arm64_llvm_lower_sync_entry`, which saves the full `x0..x30`
frame and calls the **emitted-Adder dispatcher `arm64_svc_dispatch_arm64()`**
(new additive public function in `init/main.ad`) — so the user syscall is
genuinely serviced by the kernel's OWN LLVM-emitted code. `write` emits the user
buffer over the PL011-routed console (via `early_putc`, the A4 print path) and
returns the byte count; `exit` records the status and signals the stub to leave
EL0, restore the saved kernel `SP`/`LR`, and `ret` back into `head.S` — a full
**EL0 ↔ EL1 ↔ kernel round-trip**. The A6 timer proof is preserved (head.S waits,
via `wfi`, for `arm64_llvm_tick_count` to reach the quota before dropping to EL0,
so the masked-IRQ EL0 window doesn't starve the tick).

**How EL0 was brought up — boot-layer assembly, isolated lane.** The privileged
exception-return mechanics (`SPSR_EL1`=EL0t+DAIF-masked / `ELR_EL1` / `SP_EL0`,
`eret` to EL0, and the register-frame save/restore around the syscall) cannot be
expressed from Adder, so they live in a **new boot-layer file
`arch/arm64/llvm/el0.S`** (`arm64_el0_launch` + `arm64_el0_user_entry` +
`arm64_llvm_lower_sync_entry`), porting the flow of the proven standalone kernel
(`arch/arm64/vectors.S` `arm64_lower_sync_entry` + `arch/arm64/kmain.ad` EL0
launcher) but kept ISOLATED from that lane (separate files, separate build). The
`vectors.S` 0x400 slot was re-pointed from the halt diagnostic to
`arm64_llvm_lower_sync_entry`. The kernel-visible syscall service is the emitted
Adder dispatcher, so the syscall is handled by the kernel's own compiled code.

**How x86 stayed byte-identical — additive `*_arm64` slice.** Mirroring A4–A6:
`arm64_svc_dispatch_arm64()` is a **new additive public function** (plus two
syscall-number constants + one exit-code global) called ONLY from `el0.S`; the
x86 `start_kernel()` never references it, and `start_kernel()`'s body is
untouched. The one import line gained `early_putc` (already in the closure via
`printk`; no new x86-reachable code). `scripts/test_native_vs_seed_kobjdiff.sh`:
**PASS — 0 semantic divergences across 11070 matched kernel functions** (native
codegen == seed, byte-identical by construction). No `ssa*.ad`/`codegen.ad` edit.

**Isolation / A8 gap (honest scope).** This proof runs EL0 on the shared
`head.S` identity map, whose RAM L1 block is **AP=00** (EL1 RW, EL0 **no DATA**
access). EL0 *instruction fetch* is allowed (UXN=0), and the demo user program
is **register-only** (`mov`/`adr`/`svc` — no EL0 load/store, never touches
`SP_EL0`), so it needs no EL0-RW data page and kernel RAM stays unreadable from
EL0. This is a legitimate EL0 + syscall round-trip, but it is NOT yet a general
userland: a real task needs an EL0 data stack + heap.

**A8 plan — from the svc round-trip to a real `hamsh` shell (ranked).** What
remains to run an actual userland:
1. **Per-task TTBR0 address space + EL0-RW data mapping.** Build a real page-table
   hierarchy (L1→L2→L3) so each task gets an EL0-RW (AP=01) code+stack+heap window
   isolated from the kernel and from other tasks — replacing the shared AP=00
   identity block. (NOTE: an experiment flipping the *whole* RAM L1 block to AP=01
   hung the MMU-enable path on this `-cpu cortex-a72` model; the correct fix is a
   fine L2/L3 EL0-only mapping, not a blanket block-AP change — resolve that here.)
   This unblocks a task that actually uses its stack/heap, and per-task isolation.
2. **Route `svc` into the kernel's REAL syscall dispatch.** Today
   `arm64_svc_dispatch_arm64` services `write`/`exit` inline. Wire it (or the
   `do_syscall` bail, which is currently a link stub) to the kernel's genuine
   syscall table so the full ABI surface (open/read/close/mmap/brk/…) is available
   to EL0 — the aarch64 syscall-number ABI from A1/A2 already maps the numbers.
3. **Preemptive EL0 scheduling.** Wire the `gic.S` timer IRQ to the scheduler's
   tick/preempt hook and add the **Lower-EL (EL0) IRQ vector** + full EL0-context
   save/restore (mirroring the standalone `arm64_lower_irq_entry`/`arm64_sched_pick`)
   so the timer preempts a running EL0 task — a real EL0↔EL0 switch. Needs per-task
   kernel stacks + the demand-paging fault path (Data Abort from a lower EL).
4. **virtio-mmio console + blk + initramfs → `hamsh`.** `-M virt` is all-virtio:
   bring up the `virtio-mmio` transport, a virtio-console for real bidirectional
   tty I/O, virtio-blk for a root device, and mount the initramfs so a real
   on-disk `hamsh` (not an embedded stub) is the first user task — mirroring the
   standalone track's Phase 30+. This is the largest remaining item.
5. **Higher-half TTBR1 kernel VA + demand paging.** Move the kernel into the TTBR1
   upper half (`0xffff_...`) with demand paging (prerequisite for a robust
   per-task memory model), and the compiler follow-ups (`align 8` on the
   rdrand/mul128 scratch globals to drop the build-lane `sed`; `FEAT_RNG` gate).

---

## Implementation status (2026-07-24) — A6 GICv2 + generic-timer FIRST SCHEDULER TICK + init past MM

**A6 — the aarch64 LLVM kernel takes its FIRST SCHEDULER TICK (GICv2 + ARM
generic timer, IRQ handled by emitted-Adder code) AND continues real init past
the MM boundary (rcu/sched/softirq/workqueue): DONE.** Gate
`scripts/test_arm64_llvm_kernel.sh` (extended with A6 assertions): **PASS**.
Verified furthest-point PL011 serial from the actual
`qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G` run (grep-a'd):
```
A5: start_kernel_mem_arm64 returned
A6: entering start_kernel_post_mm_arm64 (rcu/sched/softirq/workqueue)
[000073] A6: entering start_kernel_post_mm_arm64 (post-MM init slices)
[000074] [rcu] grace-period engine initialised
[000075] A6: rcu_init done
[000076] A6: sched_init done
[000077] [softirq] core up: vectors HI..RCU, ksoftirqd spawned
[000078] A6: softirq_init done
[000079] [workqueue] up: 4 shared-pool workers spawned
[000080] A6: workqueue_init done
[000081] A6: start_kernel_post_mm_arm64 complete
A6: start_kernel_post_mm_arm64 returned
A6: gic_timer_init (GICv2 + generic timer, unmasking IRQs)
[000082] [arm64-llvm] scheduler timer tick 1
[000083] [arm64-llvm] scheduler timer tick 2
[000084] [arm64-llvm] scheduler timer tick 3
[000085] [arm64-llvm] scheduler timer tick 4
[000086] [arm64-llvm] scheduler timer tick 5
[000087] [arm64-llvm] timer IRQ OK (first scheduler tick(s) taken + handled)
```
This is a **real IRQ taken by the GIC and handled by the kernel's OWN LLVM-
emitted Adder code**: the GICv2 distributor + CPU interface are enabled, the ARM
virtual generic timer (`CNTV_*`, PPI INTID 27) fires a periodic ~10 ms tick, the
`vectors.S` Current-EL-SPx IRQ slot vectors to the `gic.S` entry stub, which acks
the GIC (`GICC_IAR`), calls the emitted-Adder handler `arm64_do_timer_tick()`
(bumps the tick counter + prints the per-tick line), re-arms `CNTV_TVAL_EL0`, and
EOIs (`GICC_EOIR`). After the proof quota the handler returns "stop" and the stub
leaves the timer disabled so the boot parks quietly (masking DAIF would be undone
by the `eret` restoring `SPSR_EL1`, so quiescing the SOURCE is the correct stop).
Init also walks meaningfully past the MM block: `rcu_init` (grace-period engine),
`sched_init` (O(1) run-lists + pid hash + boot task published RUNNING),
`softirq_init` (vectors + ksoftirqd kthread spawned), `workqueue_init` (4-worker
shared pool spawned) — all emitted LLVM Adder code over the PL011 console.

**How GICv2 + timer were brought up — boot-layer assembly, isolated lane.** The
privileged interrupt-controller / timer HW mechanics (GICv2 MMIO at the `-M virt`
addresses `GICD @0x0800_0000` / `GICC @0x0801_0000`, the `CNTV_*` generic-timer
sysregs, the IRQ register-frame save/restore, DAIF unmask) cannot be expressed
from Adder in this lane, so they live in a **new boot-layer file
`arch/arm64/llvm/gic.S`** (`gic_timer_init` + `arm64_llvm_irq_entry`), porting
the constants + flow of the proven standalone kernel (`arch/arm64/kmain.ad`
`arm64_gic_init`/`arm64_timer_init`/`arm64_irq_handler` +
`arch/arm64/vectors.S`) but kept ISOLATED from that lane (separate files,
separate build — `scripts/build_kernel_llvm_arm64.sh` assembles `gic.S`). The
GICD/GICC/PL011 MMIO all fall in the device 0-1GiB block the `head.S` MMU already
maps Device-nGnRE. The KERNEL-VISIBLE tick bookkeeping is done by the emitted
Adder handler `arm64_do_timer_tick()`, so the tick is genuinely handled by the
kernel's own compiled code, not a hand-written stub.

**How init continued past MM — additive `*_arm64` slice, x86 byte-identical.**
Mirroring the A4/A5 extract pattern: a **new additive public function**
`start_kernel_post_mm_arm64()` in `init/main.ad` calls the ARCH-NEUTRAL init
slices `rcu_init` → `sched_init` → `softirq_init` → `workqueue_init`, called
ONLY from `arch/arm64/llvm/head.S` (the x86 `start_kernel()` never references it,
so the x86 kernel is behaviourally unchanged). The x86-specific post-`mem_init`
steps (`setup_smap_late`/`setup_spectre_v2`/`setup_kpti` = CR/MSR page-table
work, `fpu_init_bsp` = CR4.OSXSAVE, `uaccess_smoke_test` = STAC/CLAC) are SKIPPED
— they are x86 mechanisms. `get_bsp_cr3()` inside `sched_init()` is a nop-stub on
aarch64 (task cr3=0), harmless because this lane never context-switches yet;
`kthread_create` (ksoftirqd, workqueue workers) builds task structs but never
`__switch_to`'s (no `schedule()` on this lane), so the structures are inert until
a future EL0/preemption phase.

**HARD-RULE compliance.** `init/main.ad` change is PURELY ADDITIVE (one new
public function + one tick handler + two module globals; zero deletions,
`start_kernel()` body untouched — `git diff` shows no change to any existing
x86-reachable line). `scripts/test_native_vs_seed_kobjdiff.sh` was run (must
PASS). No `ssa*.ad`/`codegen.ad`/`cfg.ad`/`regalloc.ad` edit, so the compiler
native path is byte-identical by construction. New boot-layer files
(`arch/arm64/llvm/gic.S`) + the arm64 build/gate scripts touch nothing on the
x86 lane.

**A7+ next phases (ranked).** Reaching a shell needs a real console device the
kernel's own tty path can drive + a root fs:
1. **virtio-mmio transport + virtio-console + virtio-blk + initramfs.** `-M virt`
   is all-virtio: bring up the `virtio-mmio` transport (the device tree QEMU
   hands in `x0`, or the fixed `0x0a00_0000` MMIO window), a virtio-console for
   real bidirectional tty I/O (replacing the PL011-routed 8250 shim), virtio-blk
   for a root device, and mount the initramfs — mirroring the standalone track's
   Phase 30+ — to reach `hamsh`. This is the largest remaining item.
2. **Preemptive EL0 scheduling.** The A6 tick is handled but does NOT yet drive a
   context switch. Wire the `gic.S` IRQ path to the scheduler's tick/preempt hook
   (`scheduler_tick`/`preempt_tick`) and add the Lower-EL (EL0) IRQ vector +
   full-context save/restore (mirroring the standalone `arm64_lower_irq_entry` /
   `arm64_sched_pick`) so the timer IRQ preempts a running EL0 task — a real
   EL0↔EL0 switch. Needs per-task kernel stacks + the EL0 `svc` sync path.
3. **EL0 user-mode + `svc` syscall dispatch.** Add the Lower-EL AArch64
   synchronous vector (`svc #0` → `do_syscall`), drop to EL0 with a user page
   table, and run a first user task — mirroring the standalone Phase 4.
4. **Higher-half TTBR1 kernel VA + real page tables.** Today the kernel runs on
   the `head.S` flat identity map (TTBR0). A real aarch64 memory model puts the
   kernel in the TTBR1 upper half (`0xffff_...`) with demand paging; needed
   before per-task address spaces.
5. **Compiler follow-ups (gated, `ssa_llvm.ad`):** `align 8` on the
   rdrand/mul128 scratch globals (removes the build-lane sed); `FEAT_RNG` gate +
   software fallback for `arch_get_random_u64`.

---

## Implementation status (2026-07-24) — A5 mem_init port + past mem_init

**A5 — the aarch64 LLVM kernel goes PAST `mem_init` into full MM/slab bring-up:
DONE.** Gate `scripts/test_arm64_llvm_kernel.sh` (extended with A5 assertions):
**PASS**. Verified furthest-point PL011 serial from the actual
`qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G` run (grep-a'd):
```
A4: start_kernel_early returned
A5: entering start_kernel_mem_arm64 (aarch64 mem_init port)
[000010] [arm64-mm] memblock region base=0x0000000050000000 top=0x0000000080000000
[000011] [cow] refcount table: 524288 frames, 1048576 bytes
[000013] [swap] 4096 slots, region @ 0x0000000050100000
[000016] [arm64-mm] mem_init_arm64 done (buddy + slab up)
[000033] [buddy-coalesce] PASS
[000036] [pa-stress] PASS (churn net-neutral, free=0)
[000038]   kmalloc(  48) = 0x0000000052400020        <- slab alloc in the aarch64 RAM window
[000048]   large3[99999] roundtrip = 0x5a  (expect 0x5a)
[000059] A5: mm/slab smoke tests done (buddy allocator + slab verified)
[000072] A5: start_kernel_mem_arm64 complete
A5: start_kernel_mem_arm64 returned
```
The buddy allocator and slab are fully up and exercised: `memblock_smoke_test`,
`page_alloc_smoke_test`, `page_alloc_coalesce_test` (PASS), `page_alloc_stress_test`
(256-iter churn, 0 OOM, PASS), and `slab_smoke_test` (kmalloc/kfree across
32..100000 B, order-0..5, roundtrip verified) all run as emitted LLVM Adder code
over the PL011-routed console — the "meaningfully past `mem_init`" A5 goal.

**How mem_init was ported — arch-conditional continuation, x86 byte-identical.**
The x86 `mem_init()` (`arch/x86/mm/init.ad`) builds x86 page tables
(`pgtable_extend_from_e820` / `pgtable_build_page_offset_map` /
`pgtable_build_cpu_entry_area` = CR3/PML4/PDPT/CEA work) that do not exist on
aarch64 and would fault. Rather than pollute the shared x86 `mem_init` with
runtime arch branches, A5 mirrors the A4 extract-method pattern: two **new
additive public functions** in `init/main.ad`, `mem_init_arm64()` and
`start_kernel_mem_arm64()`, called ONLY from `arch/arm64/llvm/head.S` (the x86
`start_kernel()` never references them, so the x86 kernel is behaviourally
unchanged). `mem_init_arm64()` runs the ARCH-NEUTRAL allocator bring-up from the
x86 flow — `memblock_init` → `memblock_set_region` → `cow_init` / `swap_init` /
`page_desc_init` (per-PFN metadata reserve) → `page_alloc_init` (buddy) →
`slab_init` → `kswapd_init` — and **skips ALL x86 page-table construction**: the
`head.S` identity map (RAM `0x4000_0000-0x7FFF_FFFF` Normal-WB, vaddr==paddr)
already provides a flat mapping over the whole memblock window, so no aarch64
TTBR page-table build is needed for the buddy/slab allocators to run. The one
arch-specific decision is the memblock window: `e820_init()` is x86/multiboot
(the `mb_*` getters are nops on aarch64), so it is replaced by an explicit
`memblock_set_region(0x5000_0000, 0x8000_0000)` — 1.25–2 GiB, well above the
kernel image (loaded @`0x4008_0000`) and inside the identity-mapped RAM block.
`get_bsp_cr3()` inside `cow_init()` is a nop-stub on aarch64 (no CR3) — harmless.

**HARD-RULE compliance.** This is a SHARED-source change (`init/main.ad`:
two additive functions + additive imports of already-existing `mm.*` init
functions) plus `arch/arm64/llvm/head.S` + the gate script. Per the rule:
`scripts/test_native_vs_seed_kobjdiff.sh` was run (native kernel codegen vs seed
— the additions compile deterministically in both, 0 semantic divergences) AND
the x86 LLVM kernel was rebuilt + booted to prove the additive change does not
regress the x86 boot (the two new functions are dead code on x86: never called
by `start_kernel()`). No `ssa*.ad`/`codegen.ad`/`cfg.ad`/`regalloc.ad` edit, so
the compiler native path is byte-identical by construction.

**A6+ next phases (ranked).** Reaching a shell needs real interrupts + a console
device the kernel's own tty path can drive:
1. **Real exception handling + GICv2 + ARM generic-timer tick.** Port the proven
   standalone `arch/arm64/kmain.ad` GICv2 (`GICD_*`/`GICC_*` @ the `-M virt` MMIO)
   + `CNTV_CVAL_EL0`/`CNTV_CTL_EL0`/`CNTFRQ_EL0` timer bring-up into this lane, and
   route the `vectors.S` IRQ slot to the kernel's `do_irq`. Gives the first
   scheduler tick / preemption — prerequisite for anything that waits on an
   interrupt. (Today `vectors.S` slots all dump ESR/ELR and halt.)
2. **Continue `start_kernel` past the MM block.** The x86-specific post-`mem_init`
   steps (`setup_smap_late`/`setup_spectre_v2`/`setup_kpti` = CR/MSR work;
   `uaccess_smoke_test` = STAC/CLAC + user page tables) are x86 mechanisms — peel
   the arch-neutral remainder (`softirq_init`, `workqueue_init`, `rcu_init`,
   `sched_init`, VFS/`cpio_init`) into further small emittable `*_arm64` slices,
   stubbing/skipping the x86 mitigation calls.
3. **virtio-mmio console + blk + initramfs.** `-M virt` is all-virtio: bring up
   `virtio-mmio` transport (the device tree QEMU hands in `x0`, or the fixed
   `0x0a00_0000` MMIO window), a virtio-console for real tty I/O, virtio-blk for a
   root device, and mount the initramfs — mirroring the standalone track's Phase
   30+ — to reach `hamsh`.
4. **Higher-half TTBR1 kernel VA + real page tables.** Today the kernel runs on the
   `head.S` flat identity map (TTBR0). A real aarch64 memory model puts the kernel
   in the TTBR1 upper half (`0xffff_...`) with demand paging; needed before
   user-mode (EL0) tasks and per-task address spaces.
5. **Compiler follow-ups (gated, `ssa_llvm.ad`):** `align 8` on the
   rdrand/mul128 scratch globals (removes the build-lane sed); `FEAT_RNG` gate +
   software fallback for `arch_get_random_u64`.

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

---

## ELPROBE — settling "does the LLVM lane's userland actually run at EL0?"

Every A9/A10/A11 claim rested on EL0 execution, and nothing in the tree tested
it. The doubt was concrete: `head.S mmu_enable` fills `l2_pgtable` with
descriptor low bits `0x0705`, i.e. **AP[2:1] = 00, "EL1 RW, EL0 no access"**,
and overrides only `L2[64]` (VA `0x4800_0000`-`0x481F_FFFF`) to an AP=01 L3
window. Yet A9's two "EL0" tasks (`sched.S arm64_el0_task_a/_b`) link into the
**kernel's own .text** at ~`0x4008_14e4`, inside the AP=00 region, and they run.

`arch/arm64/llvm/elprobe.S` asks the CPU instead of arguing. It erets a probe
into that same AP=00 block and executes `mrs x0, CurrentEL` — defined at EL1+,
**UNDEFINED at EL0** — then `svc #0`. Its own private vector table has a
different handler in each of the 16 slots, so *which slot the hardware enters*
is a discriminator nothing in software chooses.

**Result (executed, `qemu-system-aarch64 -M virt -cpu cortex-a72`):**

```
ELPROBE: probe text VA = 0x0000000040082608
stage 0: LOWER-EL AArch64 sync slot (0x400)  esr=0x02000000 ec=0x00
         spsr=0x3C0 m=0x0  x0=0x5EED   -> EL0
stage 1: LOWER-EL AArch64 sync slot (0x400)  esr=0x9200000E ec=0x24
         spsr=0x3C0 m=0x0             -> AP=00 enforced for EL0 DATA
```

Stage 0: the MRS never executed (x0 still holds the sentinel), the exception
came through the **lower-EL** slot, and `SPSR.M[3:0] = 0b0000` = EL0t. **The
userland is genuinely at EL0.** Stage 1 demands the opposite outcome from the
same page: an EL0 *data* load from that kernel .text takes a Data Abort from a
lower EL (`EC=0x24`, `DFSC=0x0E` = permission fault level 2), so stage 0 is not
"TCG checks no permissions".

**The resolution of the apparent paradox:** in AArch64 stage-1 translation
`AP[2:1]` gates **data** access only. EL0 **instruction fetch** is gated by
`UXN` (bit 54, = 0 in the `0x0705` block) and `SCTLR_EL1.WXN`. EL0 executing
from an EL0-no-data-access page is therefore architecturally expected, not a TCG
liberty — and A9's tasks keep every data access (stacks `0x481E_0000` /
`0x481C_0000`, buffers `0x4800_4000` / `0x4800_5000`) inside the AP=01 window.
`el0.S`'s header already said this; it had simply never been tested.

**No correction to A9/A10/A11 is required.** Gate:
`scripts/test_arm64_currentel_probe.sh` (mutation-tested: switching the probe's
SPSR to `0x3c5` = EL1h reds it, and both discriminators flip — slot `0x200`,
`EC=0x15`, `SPSR.M=0x5`, `x0=0x4`).

## A12 (first increment) — per-task TTBR0 address spaces

`scripts/build_kernel_llvm_arm64.sh` stated A11's honest scope itself: "All
members link at the SAME VA and are loaded one at a time ... not several
concurrently resident address spaces (that needs the per-task TTBR0 work)."

`arch/arm64/llvm/a12.S` builds two independent TTBR0 spaces. Each has its own
L1, its own L2 (a copy of the kernel's, so the kernel identity map stays
resident in every space — the syscall path runs on the task's TTBR0 and must
still reach kernel memory), its own L3 mapping the **same** user VA window to
its own private `.bss`-reserved 2 MiB region, and its own ASID. A switch is one
`TTBR0_EL1` write.

Proven by executing, in this order (the order *is* the proof — a shared window
would make the first run print sum's line):

```
load 'a10' -> space 0 ; load 'sum' -> space 1, SAME VA 0x48010000
run space 0 -> A10: P=0 / C=965649, exit 17    (after sum was already loaded)
run space 1 -> A11: S=179190,       exit 246
run space 0 -> A10: P=0 / C=965649, exit 17    (after space 1 also RAN)
kernel-side compare of both backing regions by identity PA: they differ
```

Gate: `scripts/test_arm64_a12_addrspace.sh`.

### The `nG=0` trap, and a mutation that survived

`docs/arm64_phase50.md` root-caused the trap waiting at the end of this port: a
**global** (`nG=0`) translation for a user VA is not evicted by `tlbi aside1is`
and shadows every later per-ASID mapping of that VA. Its Option A is applied
here while the window is being built — `head.S`'s EL0-RW leaves are now
`0x0F47` (nG=1), not `0x0747` — rather than retrofitted.

Mutation testing gave a split result that must not be smoothed over:

- Forcing every space to **ASID 0** reds the gate loudly: space 0 runs space 1's
  program and exits 246, and the backing-page comparison fails. **The ASID
  tagging is load-bearing and is tested.**
- Reverting **both** descriptors to `nG=0` leaves the gate **green**. QEMU TCG
  flushes the whole TLB, globals included, when the ASID in `TTBR0_EL1` changes.
  Real silicon does not — and that difference *is* the phase-50 bug. **TCG
  cannot discriminate the nG bit at all.**

So `nG=1` is correct-by-architecture and asserted by **inspection** in the gate,
which says so in its own text. An execution-only gate here would have stayed
green while shipping the phase-50 bug to hardware.

### Where A12 stops

Landed: per-task TTBR0 + ASID + private backing, concurrently resident images.
**Not** landed, in the order the port needs them:

1. A **Data-Abort demand-paging** path (the lower-EL sync vector still routes
   only `svc`; `EC=0x24` from a task is fatal). Spaces are pre-populated.
2. **Per-task kernel stacks + `__switch_to`** — until then a task cannot block
   *inside* a syscall; A12's runs are still run-to-exit on the boot stack, and
   A9's preemption still switches EL0 contexts only.
3. **ASID recycling** (more tasks than ASIDs) — the point at which real TLB
   invalidation becomes necessary, and the point at which the nG bit stops being
   untestable under TCG.
4. A broader syscall surface, then virtio-blk + a filesystem.

`arch/arm64/kmain.ad` (the standalone ladder, `test_arm64_phase49.sh` green)
already has fork/exec/wait, blocking-in-syscall, and ASID-tagged separate
address spaces. Items 1-2 are a port from there, not an invention.

## A13 — DEMAND PAGING (the A12 item 1 above, landed 2026-07-31)

Commits `eec21236` (mechanism) + `ab247f59` (gate). Gate:
`scripts/test_arm64_a13_demand.sh`, registered in the CI battery.

### The bug this closes was worse than "unhandled"

A12 item 1 says `EC=0x24` from a task was *fatal*. It was not fatal — it was
**misread**. `el0.S`'s Lower-EL synchronous stub dispatched **every** synchronous
exception from EL0 into `arm64_svc_dispatch_arm64()` without ever reading
`ESR_EL1.EC`. A data abort was therefore decoded as a syscall numbered by
whatever the faulting program happened to have left in `x8`, was answered with a
value in `x0`, and was `eret`'d back to resume. A fault that returns a plausible
value and keeps running is the same failure shape this lane already hit once (the
A11 exit latch: a run truncated after one syscall "that looked like a working
demo in the log").

Confirmed by mutation, not by reading: reverting the EC compare to always-true
reproduces it exactly — the boot floods with
`EL0 svc: unknown nr=0 (returning -ENOSYS)` forever, because each refused
"syscall" resumes the task onto the same faulting instruction.

### What landed

- `el0.S` decodes `ESR_EL1.EC`: `0x15` (SVC64) → the syscall dispatcher,
  `0x24`/`0x20` (Data/Instruction Abort from a lower EL) → the demand path,
  anything else → the loud diagnostic vector (previously: all of it → syscalls).
- `arch/arm64/llvm/a13.S` builds a TTBR0 space (ASID 3) whose 16-page window at
  `0x4814_0000` is left **invalid**, and does only what Adder cannot express:
  read `FAR_EL1`/`ESR_EL1`/`TTBR0_EL1`, and `tlbi vaae1is`.
- The **policy is emitted Adder** (`init/main.ad`
  `arm64_a13_demand_fault_arm64`): fault-class check (a *permission* fault must
  not be papered over by stamping a fresh leaf), region check, a walk of the
  **live** TTBR0 tables (the base the CPU is actually using, read at fault time —
  not a pointer the kernel remembered), frame allocation, zero-fill, leaf stamp.
  The stub then `eret`s with `ELR_EL1` **untouched**, so the faulting instruction
  retries and the task never learns it faulted.
- **Every refusal kills the task, not the kernel.** Status 139 (128+SIGSEGV) is
  latched and the stub unwinds to `head.S` exactly as `exit()` does.

### What was executed vs. inspected

**Executed** (qemu-system-aarch64 `-M virt -cpu cortex-a72`): the 8 demand leaves
read as invalid descriptors *before* the run; exactly 8 faults, one per page, at
the expected VAs in address order; 8 **distinct** frames; the bytes EL0 stored
read back at each frame's **identity PA** (not through the task's mapping, so no
TLB alias can fake it); `A13: D=12126821464` / status 88, matching a Python
oracle computed independently in the gate; and the negative control — a store to
`0x4900_0000` refused, the task killed with 139, the boot continuing.

**Inspected** (and labelled as such in the gate): the demand leaves are `nG=1`.
The A12 boundary still binds — TCG flushes globals on an ASID change and cannot
discriminate the bit.

Four mutations, each rebuilt and booted, each caught: removing the carve (leaves
pre-valid); removing the region check (the wild store gets mapped); aliasing all
demand pages onto one frame; and reverting the EC decode.

### Where A13 stops

Items 2-4 of the A12 list are unchanged and still in that order. The next one is
**per-task kernel stacks + `__switch_to`**: A13's faults are all serviced to
completion on the boot stack and return to the same task, so a task still cannot
block *inside* a syscall or a fault. That is the hinge — once it holds, the
`arch/arm64/kmain.ad` ladder's fork/exec/pipes/signals become ports rather than
inventions. Note also that A13's frame pool is a bump allocator with no free
path; a real pager needs eviction, and `ASID recycling` (item 3) remains the
point at which `nG` stops being untestable.

---

## A14 — PER-TASK KERNEL STACKS + `__switch_to` (landed 2026-07-31)

**A task can now block inside a syscall.** This was the hinge A13's section names
as the next step, and it is now demonstrated end-to-end on
`qemu-system-aarch64 -M virt -cpu cortex-a72`.

Gate: `scripts/test_arm64_a14_kstack.sh` (registered).
Commits: `89f17c5d` (mechanism + policy), `a0621fae` (gate).

### It was NOT a port — check before you believe the brief

The premise going in was that `arch/arm64/kmain.ad` "already does all of it" and
A14 would be a port. That is true of fork/exec/pipes/signals; **it is not true of
kernel stacks.** Every `arm64_pNN_switch_to` in the 25k-line standalone kernel is
a TTBR0+ASID swap and nothing else, and the standalone lane's "blocking" is done
by **parking the blocked task's EL0 PC on a self-loop** and having the timer-IRQ
scheduler skip it (`arm64_p21_park_blocked_el0`). There is no `SP_EL1` write, no
per-task kernel stack, and no callee-saved context switch anywhere in
`arch/arm64/`. A task in the standalone lane cannot block inside a syscall
either. A14 is an invention, and the phases below it inherit from A14, not from
`kmain.ad`.

### What landed

* `arch/arm64/llvm/a14.S` — a 16 KiB kernel stack per task, a context block
  (x19..x28, FP, LR, SP, kstack_top), `arm64_a14_switch_to(prev, next)` over
  exactly the AAPCS64 callee-saved set, a first-entry trampoline, and
  `arm64_a14_switch_entry` (called from the middle of el0.S's syscall path, so a
  task that stops there stops **mid-syscall**, with its EL0 register frame live
  below it on its own stack).
* **`SP_EL1` selection needs no stub change and no scratch register.** `SP_EL1`
  is unused while at EL0, so the stack is chosen by ERETing to EL0 with SP
  already at that task's stack top; el0.S's frame pop leaves SP exactly there
  before every `eret`, so the invariant maintains itself. This avoids the
  chicken-and-egg of wanting a free GPR before the frame is saved.
* `head.S`'s own execution is one of the switchable contexts, so the last task
  hands the CPU back through the same `__switch_to` rather than a special unwind.
* Policy in emitted Adder (`init/main.ad`): `arm64_a14_pick_arm64` (who runs
  next), `arm64_a14_syscall_arm64` (block/wake/exit, and the third dispatch
  outcome `2 == switch`), `arm64_a14_resumed_arm64`, `arm64_a14_report_arm64`.
  Same split as A8/A9/A13.

### The correctness fix A14 forced out: el0.S's frame was not a `pt_regs`

`ELR_EL1`, `SPSR_EL1` and `SP_EL0` are **single hardware registers, not per-task
state.** Through A13 that was invisible — exactly one task was ever in flight, so
the live HW values at `eret` were still that task's. The moment a task blocks and
a peer runs, the peer's entry overwrites all three.

The first A14 boot proved it: the woken task eret'd on task B's values and landed
in B's post-exit `b .` loop, and the kernel hung. It **hung** rather than printing
a plausible log, which is the good version of this failure — the same defect one
syscall earlier would have looked entirely fine, exactly like A11's exit latch and
A12's misdecoded abort.

The frame is now a real 34-slot `pt_regs` (x0..x30, SP_EL0, ELR_EL1, SPSR_EL1) —
the same layout `sched.S`'s A9 context blocks use — restored before every `eret`.
`arm64_svc_dispatch_arm64`'s contract (`frame_ptr[n] == xN`) is unchanged, and for
a task that was not descheduled the three writes are exact no-ops, so A8..A13 are
untouched (A13's abort path still erets on the ELR it faulted on, so the faulting
instruction still retries).

### What was executed vs. inspected

**Executed**: the five events in the only order a genuine deschedule can produce
(`order=0x12345`: A blocked, B stored `0x2222` into A's *parked* x0 slot, B
exited, A resumed mid-syscall, A exited); the two tasks' kernel SPs
(`0x41403ec0` and `0x41407ec0`) landing in different reservations, with A's
parked EL0 frame on A's stack and A resuming on the *same* SP it blocked on; and
the sentinels A left in x21..x28 surviving B's entire syscall (checksum
`0x62246`, recomputed in Python from `a14.S`'s `.equ` constants and cross-checked
against `init/main.ad`'s constant, so neither side is its own oracle). The whole
A8..A13 ladder passes in the same boot.

**Inspected**: that the two kernel-stack reservations are disjoint and ≥16 KiB
(from the ELF symbol table — every runtime range check is *relative* to those
symbols, so aliasing them would satisfy all of them), and that el0.S still
restores the three sysregs from the frame.

**`nG` is not at issue here, and the gate says so.** A14 adds no page-table entry,
no `TTBR0` write and no `tlbi`; both tasks run in the kernel L1 on ASID 0 over
head.S's existing `nG=1` EL0-RW window. So A14 is neither exposed to nor evidence
about the TCG `nG` blindness of `docs/arm64_phase50.md`. Per-task *address spaces*
(A12) and per-task *kernel stacks* (A14) are deliberately still separate
increments; combining them introduces ASID recycling, which is the first point at
which `nG` stops being untestable and needs KVM or real silicon.

### Mutations

* **Both tasks share one kernel stack** (B's ctx SP pointed at A's stack top):
  caught — `A14 FAIL: kernel-stack canary reads 0x819edb14, expected 0x819eda94`.
* **Shared stack *and* the canary comparison neutered**: still caught, by the
  event-order check — the boot dies after the resume and A never exits. Note the
  honest limit this exposes: in that run the *sentinel-checksum* assertion is
  never reached, so the gate has canary + order as its detectors of a shared
  stack, and no direct evidence that the checksum alone would catch it.
* **The wake hands off immediately** (`return 2` instead of `0`, making a block
  indistinguishable from a hand-off): caught **only** by the order check —
  `order=0x1245`. The canary was intact, the checksum was right, the stacks were
  distinct, and the log read perfectly. This is precisely why the order is
  accumulated as digits rather than counted; a counter round-trips under any
  reordering.
* Reverting the `ELR/SPSR/SP_EL0` restore is caught twice: by the boot hang and by
  a source-level assertion in the gate.

### Where A14 stops — be precise

* **Two tasks and exactly one block/wake edge.** There is no run queue, no
  priority, and no preemption *while* a task is blocked (the A14 tasks run with
  DAIF masked; A9's timer preemption is a separate stage and the two have not
  been combined).
* **No task struct.** A "task" is a context block plus a stack. There is no pid,
  no state enum, no parent/child, no fd table — so the block/wake edge is
  hand-wired between two known contexts rather than driven by a wait queue.
* **The kernel stacks are plain `.bss` reservations with no guard page.** A deep
  kernel call chain would silently run off the bottom into the neighbouring
  symbol. A guard mapping is the obvious next hardening and A13's pager machinery
  can supply it.
* **The blocked task's own kernel stack is where its EL0 frame lives, and nothing
  bounds how many tasks exist.** Both stacks are statically reserved; there is no
  allocator, and A13's frame pool is still a bump allocator with no free path.
* **A14 does not combine with A12.** Both tasks share one address space. Doing
  per-task stacks *and* per-task TTBR0 at once is the next increment, and it is
  the one that finally requires a KVM or real-silicon run for `nG`.

With the hinge in place, the `arch/arm64/kmain.ad` ladder's fork/exec/pipes/wait
now *are* ports for the parts that are policy — but each still needs the task
struct and wait queues that A14 deliberately did not invent.
