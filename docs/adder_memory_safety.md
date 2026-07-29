# Memory safety in Adder

Status: **increment 1 + 1b + 2 landed** (opt-in runtime array-bounds checking for
userspace, with an `unsafe:` opt-out). Increment 1 landed the checks in the
frozen Python seed (the oracle); **increment 1b mirrors them into the native
`.ad` backend** (`adder/compiler/codegen.ad` + `parser.ad` + the host driver),
so the DEFAULT shipping compiler emits the identical bytes; **increment 2 extends
the native check to the `--opt` isel index paths** (direct-SIB register +
index-into-`%rcx`), which previously routed the index out of `%rax` and silently
dropped the check (see roadmap item 2b). This document is both the design and the
roadmap.

## Motivation & constraints

Adder is Hamnix's self-hosted systems language. It compiles **both** the
kernel (`--target=x86_64-bare-metal`) and userland (`--target=x86_64-linux`,
`--target=x86_64-adder-user`). Today the language is C-like/unsafe: raw
`Ptr[T]`, unchecked `arr[i]`, unchecked casts.

We want the *usability* win of memory safety — an out-of-bounds index in an
app faults cleanly instead of silently corrupting memory — **without** taxing
the kernel, where raw pointer and MMIO work is the whole point and every cycle
counts. So memory safety in Adder is built around a **clean, explicit
opt-out**, and it is layered in incrementally rather than as a big-bang
Rust-style ownership system.

Two hard invariants shaped the design:

1. **Kernel code must be able to bypass all checks** and stay byte-for-byte as
   fast as today. Checks are *never* emitted for a bare-metal target.
2. **The change must be byte-inert when off.** Adder's native `.ad` backend
   (`adder/compiler/codegen.ad`) is the default compiler; the frozen Python
   seed (`adder/compiler/codegen_x86.py`) is its oracle, kept in lockstep and
   guarded by objdiff + the differential fuzzer. Anything that perturbed the
   emitted bytes of existing kernel/userland code would break that lockstep
   and the whole boot. So instrumentation is **opt-in** and every emission
   site is guarded — with the feature off, codegen output is identical to the
   pre-feature compiler.

## What is checked (increment 1)

**Runtime array-bounds checks on `Array[N, T]` indexing**, where `N` is a
compile-time constant. For `a[i]` (load *or* store) the compiler emits, right
after evaluating the index:

```asm
    cmpq $N, %rax        # %rax = index (evaluated once)
    jb   .bcheck_ok_…    # unsigned: 0 <= index < N  -> in range
    ud2                  # out of range -> trap
.bcheck_ok_…:
```

Design points:

* **One unsigned compare covers both ends.** A negative index reinterpreted as
  unsigned is a huge value `>= N`, so `jb` (unsigned "below") rejects both
  `index < 0` and `index >= N` with a single branch — no separate low-bound
  test.
* **The index is evaluated exactly once.** The check reuses the value already
  in `%rax`; it does not re-evaluate the index expression, so a side-effecting
  index (e.g. `a[i := i + 1]`) stays correct.
* **In-range path adds one `cmp` + one not-taken `jb`.** No register is
  clobbered on the fast path, so the surrounding address computation is
  unchanged.
* **Scope: fixed-size arrays only.** `Ptr[T]` carries no length and is left
  unchecked in this increment (see roadmap). Multi-dimensional arrays are
  checked per level: each `[…]` in `grid[r][c]` bounds-checks against that
  level's constant extent, because each level flows through the same
  `gen_index_address` chokepoint.

### Trap behavior

* **Userland:** `ud2` raises `#UD`, delivered as **SIGILL** — a clean,
  deterministic, non-recoverable fault. The process dies (wait-status 132 =
  128 + SIGILL) instead of scribbling on memory. Increment 1 keeps this
  message-free for byte-economy and simplicity; a descriptive
  `__bounds_fail(file, line, idx, len)` panic helper is a small follow-up
  (see roadmap).
* **Kernel:** checks are **never emitted** — bounds violations behave exactly
  as they do today (undefined; the kernel is trusted). This is enforced at the
  driver, not just by convention (below).

## The opt-out

Two mechanisms; increment 1 ships the first, the design covers both.

### `unsafe:` block (shipped)

```python
unsafe:
    dst[i] = raw_read(mmio_base)   # no bounds check inside this block
```

`unsafe` is a **soft keyword** — recognized only in statement position when
immediately followed by `:` and a newline, so it remains usable as an ordinary
identifier and is unambiguous against a `unsafe: Type = …` variable
declaration. The block is *semantically transparent*: it introduces no scope,
no frame, only a codegen instrumentation toggle (a depth counter, so nesting
composes). Bodies inside an `unsafe:` block emit no bounds checks even when
`--check-bounds` is on.

### `@unsafe` / `unsafe def` (designed, next increment)

A per-function attribute that suppresses checks for a whole function — the
natural annotation for hot paths and driver code. The seed already carries a
decorator channel on `FunctionDef`; wiring `@unsafe` through is a small change
(the current top-level-decorator rejection would need to whitelist it). A
per-file pragma (`# adder: unsafe`) is the coarsest form and is deferred.

### Target-level opt-out (automatic)

Kernel/bare-metal targets are **always** unchecked. The driver only turns
instrumentation on for a *userspace* target:

```python
do_bounds = check_bounds and spec.get("userspace", False)
```

`x86_64-bare-metal` has `userspace = False`, so `--check-bounds` is a no-op
for it and kernel bytes never change.

**`x86_64-adder-user` is now bounds-eligible (increment 1b).** It shares the
bare-metal *codegen* path (`bare_metal = True`, RIP-relative, no `.modinfo`)
but is genuine CPL-3 userspace whose `#UD` faults the Adder kernel delivers as
a clean signal — so the gate treats it as eligible:

```python
userspace_bounds = spec.get("userspace", False) or target == "x86_64-adder-user"
do_bounds = check_bounds and userspace_bounds
```

This matters because the native backend's ONLY userspace target *is*
`x86_64-adder-user` (the on-device user ELF, `ELF_FMT_USER`). Promoting it in
the seed keeps seed and native in **lockstep on the flag** — the differential
objdiff (`scripts/test_native_vs_seed_objdiff.sh`) compares them on this exact
target, so an on-flag divergence (native emits a check, seed does not) would
break the gate. The native driver mirrors the gate: it sets `cg_check_bounds`
only for `ELF_FMT_USER`, never `ELF_FMT_KERNEL`.

## How it is gated (default OFF, opt-in)

Increment 1 is **opt-in via `--check-bounds`, default off.** Justification:

* **Stability / byte-inertness.** Default-off means the entire existing corpus
  (kernel + userland) compiles to identical bytes, so the seed↔native lockstep,
  objdiff, and the differential fuzzer stay green with zero risk. Turning
  checks on by default would be a codegen-wide byte change gated on getting
  every index path perfectly right first — exactly the big-bang we want to
  avoid.
* **Kernel safety is structural, not a flag default.** Even with the flag on,
  the target gate keeps the kernel unchecked.

The flag threads: `adder compile … --check-bounds` → `get_generator(…,
check_bounds)` → `generate(program, bare_metal, check_bounds)` →
`X86CodeGen(check_bounds=…)`. When `check_bounds` is `False`,
`_maybe_emit_bounds_check` returns immediately and emits nothing.

## Implementation map (increment 1)

Native-testable, seed-implemented; native codegen.ad left untouched (and thus
byte-inert + lockstep-safe). All in the seed / driver:

| File | Change |
|------|--------|
| `adder/compiler/ast_nodes.py` | `UnsafeStmt(body)` node; added to `Stmt`. |
| `adder/compiler/parser.py` | parse `unsafe:` soft-keyword block. |
| `adder/compiler/codegen_x86.py` | `check_bounds`/`unsafe_depth` state; `UnsafeStmt` codegen; `_maybe_emit_bounds_check`; call site in `gen_index_address`; `generate(..., check_bounds)`. |
| `adder/compiler/adder.py` | `--check-bounds` flag; userspace-only gating in `get_generator`; thread through `compile_source`/`compile_with_imports`. |
| `tests/membounds/*.ad`, `scripts/test_adder_bounds_check.sh` | regression test. |

Increment 1b (native mirror):

| File | Change |
|------|--------|
| `adder/compiler/codegen.ad` | `cg_check_bounds`/`cg_unsafe_depth` state; `maybe_emit_bounds_check` + call sites in `gen_index_addr`; `ND_UNSAFE` in `gen_stmt` + `prescan_block`. |
| `adder/compiler/parser.ad` | `ND_UNSAFE` node; `unsafe:` soft-keyword parse; `tok_text_is` helper. |
| `adder/compiler/fused_driver_host_main.ad` | `--check-bounds` flag; userspace-only `cg_check_bounds` gate (never kernel). |
| `adder/compiler/adder.py` (seed gate) | `x86_64-adder-user` promoted to bounds-eligible so seed↔native stay in lockstep on the flag. |

### Why seed-first, native next

The bounds check lives in the frozen Python seed (the oracle) because it is
fully host-runnable: the regression test compiles real ELFs to
`--target=x86_64-linux`, runs them, and observes the SIGILL directly — a true
end-to-end proof. Because the feature is default-off, the native `.ad` backend
(`codegen.ad`) is completely untouched, so kernel links, objdiff, and the
fuzzer are unaffected. **Increment 1b** mirrors the same guarded block into
`codegen.ad` (the chokepoint is `gen_index_addr` there, which already mirrors
`codegen_x86.gen_index_address` line-for-line) so the *default shipping*
compiler emits checks too. Until then, `--check-bounds` is honored by the seed
path (host userspace builds, the fuzzer, the compiler test battery).

## Verification (increment 1)

* `scripts/test_adder_bounds_check.sh` — OOB checked index traps (SIGILL /
  status 132); in-range checked index runs (exit 10); `unsafe:` suppresses the
  trap (exit 0); bare-metal + `--check-bounds` emits no `ud2`; userspace
  without the flag emits no `ud2`.
* `scripts/test_native_kernel_links.sh` — **PASS**; the native compiler still
  links the kernel with no seed fallback (kernel unaffected).
* **Byte-inert-off:** the default (no-flag) asm output of dozens of real
  self-contained `.ad` fixtures (incl. array-heavy `sieve`, `mmul`,
  `nested_frame_array`, `cast_arr_u32`, `bigmmap`) is md5-identical between the
  new compiler and committed `HEAD`, on both `x86_64-bare-metal` and
  `x86_64-linux`.
* `scripts/run_compiler_tests.sh` — **ALL PASS** (seed + native codegen.ad
  round-trips), confirming no parse/codegen regression.

## Roadmap beyond increment 1

Ordered by value/effort; each stays opt-in + kernel-bypassable.

1. **Descriptive trap.** Replace bare `ud2` with a `__bounds_fail` userspace
   helper that writes `"bounds: idx N of len M at file:line\n"` to fd 2 and
   `exit_group(134)`. Pass idx/len/site via a tiny out-of-line slow path so the
   fast path stays one `cmp`.
2. **Mirror into `codegen.ad` (increment 1b) — DONE.** The same guarded block
   is emitted by the native backend so the default compiler instruments
   userspace. Chokepoint: `gen_index_addr` calls `maybe_emit_bounds_check` right
   after the index lands in `%rax` in every `Array[N,T]`-base branch (local /
   global / multi-dim / nested / `Array[N,Struct]` global / array member);
   `Ptr[T]`/cast/call/string/scalar bases carry no length and self-gate to a
   no-op via `expr_array_type == 0`. Bytes match GNU `as`
   (`48 83 F8 ib | 48 81 F8 id` / `72 02` / `0F 0B`). `unsafe:` is a native
   soft-keyword (`parser.ad`, `ND_UNSAFE`) and suppresses via `cg_unsafe_depth`.
2b. **`--opt` co-instrumentation (increment 2) — DONE.** Under `--opt` the native
   isel lowers a flat-array index straight into a register (never `%rax`) via one
   of two paths, both of which previously SKIPPED the `%rax`-only check:
   * the **direct-SIB coalesce** — a bare full-width register-promoted index goes
     straight into the SIB index register `idxreg` (`index_reg_direct`), and
   * **`try_sel_index_into_rcx`** — a binary index computed straight into `%rcx`.

   `gen_index_addr` now calls `maybe_emit_bounds_check_reg(node, reg)` (a
   register-parametrized form of `maybe_emit_bounds_check`, `reg` = the encoding
   holding the index: `idxreg`, or `%rcx`=1) right before the address `lea` reads
   that register: `cmp $N,%reg; jb +2; ud2` (`emit_cmp_imm_reg` adds REX.B for
   `reg>=8`). `cmp/jb/ud2` do not clobber the index register, so the SIB address
   is unaffected. Still guarded by `cg_check_bounds`/`cg_unsafe_depth`, so it is
   byte-inert when off and honors `unsafe:`. The SEED needs no change: its `--opt`
   is a text peephole/regalloc post-pass over asm the opt-0 codegen already
   emitted with the check, so the `cmpq $N,%rax; jb; ud2` survives (verified: the
   OOB fixtures trap at `-O0/-O1/-O2`). Lockstep here is BEHAVIORAL — the
   byte-exact objdiff runs at opt-0 (unchanged), and both backends now trap a
   `--opt`-compiled OOB index (wait-status 132) and run in-range code unaffected.
   Verified by `scripts/test_adder_bounds_check_opt.sh` (both isel shapes, both
   backends) + the `ADDER_OPT=1 ADDER_CHECK_BOUNDS=1` differential-fuzzer lane.
3. **`@unsafe` / `unsafe def` + `# adder: unsafe` file pragma.**
4. **Sized slices / length-carrying pointers.** A `Slice[T] = {ptr, len}` fat
   pointer so dynamically-sized buffers get the same check; `Ptr[T]` stays the
   raw escape hatch.
5. **Null-pointer deref checks.** Optional check on `p[0]`/`p.field` for a
   `Ptr[T]` known-nullable, same opt-out story.
6. **Use-after-free / lifetimes.** Region/arena tagging first (cheap, fits the
   kernel's slab model), then opt-in ownership/borrow analysis at the type
   level — the long-horizon goal, deliberately last so the cheap runtime wins
   land first.

Everything above preserves the two invariants: **kernel opt-out** and
**byte-inert when off.**

---

# Increment 4 — checked integer arithmetic (`--check-arith`)

**Status: SHIPPED (2026-07-28), opt-in, default OFF.**
Gate: `scripts/test_adder_check_arith.sh` (host-only, no QEMU).

## The defect that motivated it

`cyc_to_ns()` computed `(cycles * mult) >> shift` in `uint64`. On this TSC
(`freq=4009555700 Hz mult=4184308 shift=24`) the product passes 2^64 at
`2^64/mult = 4.409e12` cycles = **1099.5 seconds** of uptime, after which the
monotonic clock jumped **backwards** by 1099 s. `hrtimer_start_rel` arms against
that clock, so past the wrap **every bounded wait in the kernel became
unbounded** — 13 kernel sites on `wq_wait_commit_timeout` (pipe, 9p, AHCI, HDA,
TCP, devfd) and 16 userland programs parked on `sys_waitfds`. The DE panel
wedged after 18 minutes and leaked a 16 MiB framebuffer while it was at it.

One silent multiply, four days invisible. Bounds checking would not have found
it: nothing was out of bounds. Arithmetic checking finds it the first time the
kernel runs past 18 minutes.

## Where it lives — NOT in the code generator

`codegen.ad` and the frozen Python seed are **untouched** by this feature.
`--check-arith` is a pure **AST → AST rewrite** (`adder/compiler/checkarith.ad`)
that runs in the host driver between `parse_program()` and
`gen_program_with_globals()`. For each checked operation it inserts an ordinary
Adder guard statement immediately before the statement containing it:

```
if <overflow predicate over a, b>:
    __ck_arith_trap(<code>, cast[uint64](a), cast[uint64](b), <line>)
<the original statement>
```

The instrumented program is ordinary Adder, so the existing backend compiles it
with no new emitters. Consequences:

* with the flag off, `ck_instrument_program` is never called and the emitted
  bytes are **identical** to the pre-feature compiler (41 units — the whole
  bare-metal kernel plus 40 userland programs — verified byte-for-byte against a
  pre-feature `host_ac.elf`);
* `test_native_vs_seed_kobjdiff.sh` is unaffected because neither backend
  changed;
* the mode works on the native x86-64 backend **and** the optional LLVM backend
  for free, because it is upstream of both.

The runtime (`__ck_arith_trap` and its formatter) is appended as **source text**
to the merged import closure by `drv_emit_ck_runtime` in
`fused_driver_host_main.ad`, again only when the flag is on.

## What is checked

| operation | unsigned predicate | signed predicate |
|---|---|---|
| `a + b` | `(a+b) < a` | `((a^(a+b)) & (b^(a+b))) < 0` |
| `a - b` | `a < b` | `((a^b) & (a^(a-b))) < 0` |
| `a * b` | `b != 0 and (a*b)//b != a` | `(b == -1 and a == MIN)` or `(b != 0 and b != -1 and (a*b)//b != a)` |
| `a << b` | `b >= W or ((a<<b)>>b) != a` | `b < 0 or b >= W or ((a<<b)>>b) != a` |
| `a / b`, `a // b`, `a % b` | `b == 0` | `b == 0 or (b == -1 and a == MIN)` |

Augmented assignment (`x += y`, `x *= y`, …) is checked with the same
predicates. `a == MIN` is expressed width-independently as
`a != 0 and (0 - a) == a` (the minimum is the only non-zero value that is its
own negation), so no width-specific literal is needed. Adder's `and`/`or`
short-circuit, so the division inside the multiply predicate is never reached
with a zero (or, when signed, a `-1`) divisor: **the check itself can never
fault.**

## What a detected overflow does

A **loud, non-optional stop**, naming the operation, both operands, the type and
the source line — the opposite of the four-day silence that motivated the mode:

```
[check-arith] mul overflow lhs=5000000000001 rhs=4184308 ty=uint64 line=9
```

* **Userspace:** the message goes to fd 2, then `exit_group(134)`.
  134 is deliberately distinct from `--check-bounds`' 132 (`SIGILL`) so a run
  with both modes on tells the two apart.
* **Kernel:** there is no `write(2)`. The operands and line are latched into the
  globals `ck_arith_code / ck_arith_lhs / ck_arith_rhs / ck_arith_line` (readable
  from a crash dump) and the kernel's own `panic()` is called with the formatted
  message. A kernel **cannot** quietly continue past a detected overflow — that
  is precisely the failure mode being fixed. `--check-arith-warn` (below) is the
  escape hatch when continuing is what you want.

**The kernel is NOT exempt.** This is the one deliberate departure from the
`--check-bounds` shape, and it is the whole point: the defect is kernel code.
Exempting the kernel would exempt exactly the arithmetic that hurt most.

### `--check-arith-warn` — survey mode

Reports each **site** (source line) once and continues, capped at 512 distinct
sites. A fatal first hit tells you about exactly one site per run, which makes
surveying a tree for intentional-wrap sites impossibly slow. Kernel builds route
the report to `printk0()` instead of `panic()`.

## The opt-out — `unsafe:`

Intentional wrapping is legitimate: hashes, checksums, PRNGs, ring arithmetic
and alignment masks all rely on it. The opt-out is the **existing `unsafe:`
block** — everything lexically inside one is left completely uninstrumented,
exactly as with `--check-bounds`. The whole-file `# adder: unsafe` pragma
suppresses the pass entirely.

**Why not a dedicated wrapping operator** (`a &+ b`, `wrapping_mul(a, b)`)? Any
new *syntax* would have to be understood by the **frozen Python seed**, which
compiles the same tree and is the bootstrap trust root. Adding a token to the
seed is exactly the change this increment is forbidden to make. `unsafe:` needs
no new syntax on either side and is already the project's established
"I meant that" marker.

## Coverage limits (deliberate, conservative, documented)

These cost recall, never soundness — an instrumented site **never** traps on a
program that did not actually overflow.

1. **Operands must be pure.** Literals, identifiers, casts and unary/binary
   combinations of those. A guard *re-evaluates* its operands, so calls, pointer
   and array dereferences (which may be **volatile MMIO**), member reads and
   `?`/`!` disqualify a site. Re-reading an MMIO register to check arithmetic
   would be a bug far worse than the one being caught.
2. **Both operand types must be known and equal** (a bare integer literal adapts
   to the other side). `checkarith.ad` carries a small local type classifier
   over declarations, params and function return types; mixed-width /
   mixed-signedness arithmetic, pointers, floats, enums and struct fields are
   skipped rather than guessed at.
3. **Loop and `elif` conditions are not instrumented**, nor is the RHS of
   `and`/`or`, nor the arms of a conditional expression. Hoisting a guard out of
   a loop condition would check it once instead of per iteration; hoisting it
   out of a short-circuit or an `elif` would evaluate arithmetic on a path the
   program deliberately avoids (the classic `x != 0 and y // x` false positive).
4. **Sub-64-bit types are under-sensitive by construction.** Both Adder backends
   evaluate narrow integer arithmetic in 64-bit registers and truncate on
   *assignment*, so a `uint32 + uint32` intermediate does not wrap at 32 bits at
   run time and the (correct) predicate stays quiet. For narrow types only the
   shift-count check and the divide/modulo-by-zero check are load-bearing.
   Detecting **truncation on store** (`c: uint32 = <expr wider than 2^32>`) is a
   separate, valuable increment, deliberately not attempted here: the tree is
   full of *intentional* narrowing and the compiler already warns about the
   undeclared cases.

The compiler reports its own coverage on every instrumented build:

```
[check-arith] instrumented 24677 site(s), skipped 2868 (impure or untyped operands)
```

## Turning it on across the tree

```
HAMNIX_CHECK_ARITH=1     bash scripts/build_installer_img.sh   # trap
HAMNIX_CHECK_ARITH=warn  bash scripts/build_installer_img.sh   # survey
```

`scripts/_adder_cc.sh` forwards the flag to every unit it builds, kernel object
included. Unset (the default) it is never passed and the build is byte-identical
to an unchecked one.

## Triage of the sites found so far

Two runs, both with `--check-arith-warn` (report each site once, continue):

**A. The compiler itself**, built through the LLVM lane with 1813 guards, then
run over a full bare-metal kernel compile (~1.7 M tokens of input). **2 sites**:

| site | verdict |
|---|---|
| `codegen.ad layout_emit_field`: `cg_layout_offset & cast[uint32](0 - align)` | intentional wrap — two's-complement alignment mask |
| `elf_emit.ad`: `eb64(cast[uint64](0) - cast[uint64](4))  # r_addend = -4` | intentional wrap — building `-4` as a `uint64` |

The instrumented compiler produced a kernel object **byte-identical** to the
unchecked one — independent evidence that the instrumentation is
semantics-preserving.

**B. The kernel**, 24,677 guards, booted under OVMF/QEMU all the way to the
desktop (`[visual_gate] done`). **10 sites, 8 distinct functions, ZERO real
bugs** — every one is a hash/PRNG/diffusion mixer where wrapping IS the
algorithm:

| file / function | site | verdict |
|---|---|---|
| `kernel/stack_protect.ad` | `seed * 0x9E3779B97F4A7C15` | intentional — golden-ratio diffusion |
| `sys/src/9/port/devrandom.ad` `_tsc_jitter64` | `(acc<<7)|(acc>>57)`, `acc + 0x9E37...` | intentional — rotate-mix |
| `sys/src/9/port/devrandom.ad` `_hw_entropy64` | two rotates | intentional |
| `fs/fcache.ad` `dc_strhash` | `h * 1099511628211` | intentional — FNV-1a 64 |
| `arch/x86/kernel/syscall.ad` splitmix64 | `* 0xBF58476D1CE4E5B9`, `* 0x94D049BB133111EB` | intentional |
| `arch/x86/kernel/syscall.ad` `_aslr_stream` | `+ 0x9E3779B97F4A7C15` | intentional — Weyl sequence |
| `kernel/block/blk.ad` `_bcache_hash` | `k * 11400714819323198485` | intentional — Fibonacci hashing |
| `drivers/block/partition.ad` | `idx * 0xBF58476D1CE4E5B9` | intentional — splitmix constant |

The first six are now annotated with `unsafe:` blocks (24,677 → 24,665 guards).
The default, unflagged kernel object is **byte-identical** after the
annotations — verified with `cmp` against a pre-annotation object.

The last two are deliberately **left unannotated**: at those sites an `unsafe:`
block would have to hoist a variable declaration out of the wrapped statement
(`k: uint64 = ...` becomes `k: uint64 = 0` plus an assignment inside the block),
and that restructuring **does** change default codegen. Annotating them is not
worth perturbing the byte-identical baseline; a future `unsafe:` *expression*
form, or declaration-in-`unsafe:` scoping, would close the gap.

Note what the boot run did **not** find: the clock wrap itself. It manifests
only past 1099 s of uptime and a boot-to-desktop run is ~25 s. Catching it needs
`HAMNIX_CHECK_ARITH=1` plus a >18-minute soak — which is exactly the
`test_de_panel_taskbar_soak` shape that surfaced the original wedge.

## Cost

Measured on the bare-metal kernel (`init/main.ad`, 13.9 MB merged closure) with
the native backend:

| | unchecked | `--check-arith` |
|---|---|---|
| guards emitted | 0 | 24,677 (2,868 sites skipped) |
| compile time (user) | 71 s | 90 s (+27 %) |
| kernel object | 8.61 MB | 11.69 MB (+36 %) |

This is a **debug/soak mode**, not a shipping configuration — the same posture
as `--check-bounds`.
