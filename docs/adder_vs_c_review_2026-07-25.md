# Adder vs C — an honest capability review (2026-07-25)

**Base:** `438fca0a` · **Scope:** Adder as a *systems* language and as an *application* language, compared to C.
**Method:** repo evidence (file:line), empirical compiler probes run at this SHA, and a re-run of
`scripts/bench_llvm.sh` plus a new clang/rustc control. This is a review, not marketing —
the value here is the gap list. Where I could not confirm something I say so.

> **Reading note.** Three things in this repo disagree with each other about what Adder is:
> `adder/LANGUAGE.md` (the reference), `docs/adder_language_roadmap.md` (the roadmap, which
> narrates features as "landed"), and the compiler itself. Wherever they conflict, this document
> reports **what the compiler actually did when I fed it a program**. Those probes are in §1.1.

---

## 0. Executive verdict

| Question | Verdict |
|---|---|
| Is Adder a viable systems language? | **Yes, demonstrably** — ~905k lines of Adder run a self-hosting OS with only ~13.5k lines of asm. But it does this by *outsourcing* the hard parts (packed layouts, ISRs, locks, barriers) to `.S` files and raw pointer arithmetic. |
| Is Adder a viable application language? | **Yes, but it is currently harder than C**, not easier. The shipping app dialect is a strict subset of C89 with Python punctuation, and the missing stdlib imposes visible *product* limits. |
| Is Adder fast? | **Yes, via LLVM — at parity with C.** Measured 1.13× clang-O2 and 1.04× rustc-O. The widely-quoted "0.89× gcc-O2 / beats gcc" is a **clang-vs-gcc artifact**, not an Adder win. |
| Is Adder safe? | **No — as shipped it has C's safety posture with *less* static checking than C.** See §1. |
| Biggest single weakness | **There is no type checker.** Not "a weak one" — none. See §1.1. |

---

## 1. Type system & safety

### 1.1 Empirical probes (run at 438fca0a, `python3 -m compiler.adder compile --target=x86_64-linux`)

I compiled minimal programs to find out what the compiler *does*, rather than what the docs claim.

| Program | Result |
|---|---|
| `def f(p: Ptr[uint8])` called as `f(x)` where `x: int32` | **ACCEPTED**, no diagnostic |
| `y: uint8 = 300` | **ACCEPTED**, silent truncation |
| `p: Ptr[uint64] = g()` where `g() -> Ptr[uint8]` | **ACCEPTED**, no cast needed |
| `n: int32 = d` where `d: float64` | **ACCEPTED** |
| **`f(1)` for `def f(a: int32, b: int32)`** | **ACCEPTED — wrong arity compiles** |
| `s.nosuchfield` on a struct | REJECTED (`x86: struct 'S' has no field 'nosuchfield'`) |

The arity case is the sharpest. This program compiles clean and returns a **different answer on every
run** (observed exits 89, 169, 121 — `%esi` is whatever the caller left there):

```python
def f(a: int32, b: int32) -> int32:
    return a + b
def main() -> int32:
    return f(1)          # compiles; b = garbage
```

C rejects this outright. So does every other statically-typed language. The cause is structural:
the whole pipeline is `adder/compiler/adder.py:594-604` —

```python
program = parse(source, filename)
_run_affine_check(program)
return generate(program)
```

parse → affine-move check → codegen. There is **no `sema.py`, no `typecheck.py`, no type-checking
pass at all**. Type annotations are *codegen hints* that select instruction widths, not contracts.
What exists is partial type *recovery* inside the backend (`codegen.ad:1999 expr_signedness`,
`codegen.ad:9386 expr_array_type`), with an explicit `0 = unknown` state documented at
`codegen.ad:1996`: "*everything else (binop, literal, call, index) -> 0 (unknown)*".

That unknown state is not academic — it is the direct cause of shipped miscompiles (§7e).

### 1.2 What Adder genuinely has

| Feature | Status | Note |
|---|---|---|
| Fixed-width primitives | ✅ **better than C** | `int8..uint64`, `float32/64`, `bool`, `char`. Bare `int` **is** `int32` (`parser.ad:710`), `char` is unsigned (`codegen.ad:1984`) — both implementation-defined in C. No `<stdint.h>` layer, no integer-promotion lattice. |
| No implicit conversions | ✅ *in syntax* | `cast[T](x)` is the only conversion form (`LANGUAGE.md:906`). But since nothing checks annotations (§1.1), this is convention, not enforcement. |
| Structs (`class`) | ✅ partial | C-ABI layout, declaration order, natural align capped at 8 (`codegen.ad:11436`). Nesting works. Inheritance = field flattening, **no vtables**. |
| Struct by-value pass/return | ⚠️ **partial** | Only ≤16 bytes and float-free (SysV 2×INTEGER). Larger → loud reject. C has no such limit. |
| Struct literals / designated init | ❌ | `Point{x=10}` rejected (`LANGUAGE.md:1436`). Declare then field-assign. |
| `Array[N,T]` | ✅ **better than C** | `N` lives in the type and is what the bounds check tests. No decay-to-pointer amnesia. But `N` must be a **numeric literal** — you cannot write `Array[NCELLS, uint8]`, so sizes are duplicated as magic numbers. |
| `Slice[T]` fat pointer | ✅ exists / ❌ unused | Real 16-byte `{ptr,len}` (`codegen.ad:13235`), runtime-checked indexing, sub-slicing `s[a:b]`. **Zero non-test users in the entire tree** (verified: every `Slice[` hit outside `adder/compiler/` is under `tests/`). |
| `Ptr[T]` | ✅ = C | Element-scaled arithmetic, **except** `Ptr[T] - Ptr[T]` yields a *byte* difference, not an element count (`LANGUAGE.md:855`) — the opposite of C's `ptrdiff_t`. A real porting footgun. |
| `cast[T]` | ⚠️ **weaker than C** | "Integer↔integer casts are a no-op at the assembly level … the compiler trusts the programmer to mask when narrowing matters" (`LANGUAGE.md:900`). C *guarantees* defined truncation. |
| Tagged `enum` + `Option`/`Result` + `?`/`!` | ✅ exists / ❌ unused | Confirmed working by probe. But: single 64-bit word, 8-bit tag, so **56 bits for all payloads combined**; anything wider is rejected ("multi-word enum deferred", `codegen.ad:1446`). `Result[Ptr[T], E]` is therefore **not expressible** — which is exactly why nobody uses it. **Zero non-test users.** |
| `match` | ✅ exists / ❌ unused | Probe: accepted. Native pattern grammar (`parser.ad:2105-2142`) is bare binders only — **no literal patterns, no guards, no OR-patterns, no nesting**; the seed parser has guards, so seed and native accept *different languages*. Non-exhaustive match is a **warning**, then falls through (`codegen.ad:17348`). **Zero production `match` statements** in `user/ lib/ kernel/ drivers/ fs/ sys/`. |
| `union` | ❌ | Parsed, codegen-rejected. Probe confirms: `x86: top-level UnionDef not yet supported`. Type-pun via `cast[Ptr[T]]`. |
| Bitfields | ❌ | None. |
| Generics / traits / interfaces | ❌ | Generic args are **parsed and discarded** (`parser.ad:1866-1871`). No trait/interface token exists. Roadmap Tier C = "deliberately skip". Roughly C-parity, except C has `_Generic` and macros. |
| Function/operator overloading | ❌ | None. |
| `const` / immutability | ❌ **worse than C** | No `const`, `let`, `mut`, or `final` — zero matches in either lexer. No `const char *` equivalent; "constants" are mutable globals in `.data`. |
| Type inference | ❌ by design | Every binding annotated; no `let`. |

### 1.3 The memory-safety story, honestly

`--check-bounds` **works** — I verified it:

```
$ adder compile t_bounds.ad                    # a[9] on Array[4,int32]
$ ./tb.elf ; echo $?                           → 0        (silent OOB write)

$ adder compile --check-bounds t_bounds.ad
$ ./tb.elf
bounds: index out of range (len 4) at .../t_bounds.ad:4
Illegal instruction                            → 132      (clean trap)
```

That is a genuinely nice design: unsigned compare catches `i<0` and `i>=N` in one `cmp`, `ud2`→SIGILL,
descriptive message on host targets, byte-inert when off. **But:**

1. **It is in no production build script.** `grep -rl check-bounds scripts/` returns only
   `test_adder_*.sh` and the CI manifest. Neither `build_user.sh` nor any kernel build passes it.
2. **It cannot cover the code that exists.** `expr_array_type` (`codegen.ad:9386`) returns non-zero
   only for an `Array[N,T]`-typed local/global/field. **Any `Ptr[T]` base — the entire production
   idiom — silently skips the check with no diagnostic.**
3. **The kernel is structurally exempt** by design (`adder.py:148`: `do_bounds = check_bounds and
   userspace_bounds`). That's a defensible choice, but it means the 265k-line kernel gets nothing.

`unsafe:` is a **soft keyword** (no `TOK_UNSAFE`; matched textually at `parser.ad:1640`) and is purely
a codegen instrumentation toggle (`cg_unsafe_depth`). Since the checks it suppresses are off by
default, `unsafe:` is a no-op in the shipped configuration. Note the inversion vs Rust: **in Adder
unsafe is the default and safety is the annotation.** `unsafe:` says nothing about raw `Ptr` deref,
arbitrary `cast`, or `asm` — all legal in ordinary "safe" code.

`Own[T]` affine move-checking (use-after-move, double-`drop`) is real — but it lives in
`adder/compiler/affine_check.py`, i.e. **the Python seed only**. The native parser strips the
qualifier and does nothing (`parser.ad:609-621`), and `roadmap:305-308` confirms enforcement is
"seed-authoritative". Since `ADDER_CC=adder` (native) is the default, **`Own[T]` use-after-move
compiles silently in the shipping toolchain.** `docs/adder_language_guide.md`'s safety table, which
lists `Own[T]` as "always / all targets", is wrong. Zero non-test users either way.

**Not present at all:** borrow checking, lifetimes, regions, RAII/destructors, use-after-free or
double-free detection for `kmalloc`/`kfree`, integer-overflow checks, uninitialised-read checks,
any sanitizer (ASan/UBSan/TSan), null-pointer typing (`Ptr[T]` is nullable by explicit design
decision, `roadmap:145-150`).

**Bug classes Adder prevents vs C:** array OOB *on `Array`-typed bases, in userspace, if you opt in*;
implicit conversion surprises *in syntax*; `char`-signedness and `int`-width portability bugs;
duplicate-symbol link-order lottery (merge-time hard error, `adder.py:504`); unknown struct fields.

**Bug classes it does not prevent, that C also does not:** UAF, double-free, leaks, null deref,
data races, overflow, uninitialised reads, type-punning hazards.

**Bug classes C prevents that Adder does not:** wrong argument types, **wrong argument counts**,
incompatible pointer assignment, missing prototypes, narrowing-cast semantics, `const` violations.

---

## 2. Systems programming

The headline number is real and should be said plainly: **~905k lines of Adder vs ~13.5k lines of
asm** across the whole OS, and `kernel/` (23.8k), `mm/` (12.2k) and `sys/src/9/` (40.7k) contain
**zero** assembly. Nearly all remaining asm is in `arch/` (8.7k) plus blobs (`fs/diskimg_blob.S`,
`fb_font_8x16.S`). That ratio is Linux-class. Adder is unambiguously capable of real kernel work.

The honest question is *how* it gets there.

| Facility | Adder | Note |
|---|---|---|
| Port I/O | ✅ **better than C** | `inb/outb/inw/outw/inl/outl` are real intrinsics lowering to bare instructions (`codegen_x86.py:6240`), 130 call sites. Portable C needs a builtin or inline asm. |
| Per-CPU / `%gs` | ✅ **better than C** | `Percpu[T]` is a *language type* emitting `%gs:`-prefixed access with no helper call, plus a `.data..percpu` section. C needs `__seg_gs` or macro machinery. Limits: no `&percpu_var`, no sub-aggregate fields, scalars must be 1/2/4/8 B. |
| Freestanding / no runtime | ✅ | No GC, no hidden allocator, no hidden init. Every heap-implying Python-ism is codegen-rejected *precisely because* it implies hidden heap. Only emitted runtime hooks are the stack protector and `.modinfo` (skipped on bare metal). Correct design. |
| Compile-time builtins | ✅ | `sizeof`, `min`/`max` (→`cmov`), `abs`, `clamp`, `strlen` (→`repne scasb`), `container_of` — all folded inline, no call. |
| Function pointers | ✅ | `Fn[R,A...]` is a real type, 407 occurrences. Real vtable-pattern users: `kernel/softirq.ad:80 Array[10, Fn[None]]`, `kernel/time/clocksource.ad:178`, `kernel/rcu/rcu.ad:439`, `fs/btrfs.ad:645`. |
| Bit manipulation | ✅ | `& \| ^ << >>` + augmented forms. No rotate builtin (C has none either). |
| Linker scripts | ✅ | `arch/x86/kernel/kernel.lds` does the higher-half `0xffffffff80000000` VMA/LMA split properly. |
| **Inline asm** | ⚠️ **much weaker than C** | See below. |
| **`volatile` / MMIO** | ❌ **the worst gap** | See below. |
| **Packing / alignment / unions / bitfields** | ❌ | See below. |
| Interrupt handlers | ❌ | No `naked`, no `__attribute__((interrupt))`. All 256 vectors are hand-written stubs (`arch/x86/kernel/idt_asm.S:31-124`, `irq_asm.S` 367 lines, `trap_asm.S` 553, `syscall_64.S` 622). Adder only twiddles descriptor bits. |
| Section attributes | ❌ | Codegen hardcodes exactly five sections (`.data`, `.bss`, `.data..percpu`, `.rodata`, `.modinfo`). `.text.boot`/`.head.text`/`.pgtables` are populated purely from `.S`. |
| Varargs | ❌ **worse than C** | No `...`, no `va_list`. `kernel/printk/printk.ad` is an *arity family*: `printk0/1/2/3`, and **every argument must be hand-`cast[uint64]`'d at every call site**. Hard ceiling of 3 args. |
| Atomics / memory model | ⚠️ minimal | Four intrinsics (`atomic_cas32/64`, `atomic_add32/64`) lowering to real `LOCK CMPXCHG`/`XADD`. **No acquire/release, no atomic load/store, no compiler barrier.** Barriers are raw `asm_volatile("mfence")` — 2 sites in the whole tree. Locks are entirely `extern def` into `arch/x86/kernel/spinlock_asm.S`, whose `SFENCE`-before-unlock ordering *cannot be written in Adder*. |
| Preprocessor / macros | ❌ | None. No conditional compilation, no `#include`, no `_Generic`. |

### 2.1 Inline asm is a string splice

`asm_volatile` is the only form (the `asm(...)` *expression* form is codegen-rejected). Its
implementation is literally text emission (`codegen_x86.py:6303-6311`):

```python
elif name == "asm_volatile":
    for line in args[0].value.splitlines():
        if line.strip(): self.emit(f"    {line.strip()}")
```

**No operand constraints, no clobber list, no register-allocator interaction, no `"=r"`/`"m"`
templating.** This is weaker than GCC extended asm *and* weaker than MSVC `__asm`. The consequence
is mechanical: any asm that must take a value in or hand one back cannot be inline, so it becomes a
`.S` file with a hand-written SysV contract. Hence **115 `extern def` declarations in `arch/x86`
alone**, and hence `cpuid`, `rdmsr`/`wrmsr`, `lgdt`/`lidt`/`ltr`, `cr3`, `invlpg` and every lock
primitive living in assembly. `arch/x86/kernel/idt_asm.S:184` says it out loud: *"lidt operand from
Hamnix would be awkward"*.

The only two multi-line users hand-roll RIP-relative addressing to dodge registers the compiler owns
(`arch/x86/kernel/power.ad:269`) — i.e. they work around the missing clobber list by hand.

There is also **no `swapgs` path anywhere** (`arch/x86/kernel/kpti_asm.S:19`: "Hamnix sets
IA32_GS_BASE directly and never swapgs"), flagged in-tree as needing revisiting. A swapgs syscall
entry needs interleaved asm and compiler-managed state — which `asm_volatile` cannot express.

### 2.2 No `volatile`, no MMIO builtins — driver correctness rests on a promise

`volatile` is lexed and parsed and **ignored by codegen** (`LANGUAGE.md:1429`). Grepping `.ad` under
`kernel mm fs drivers arch` for the qualifier (excluding `asm_volatile`) finds **zero uses**. There
are no `readl`/`writel`/`mmio_read32` builtins. Every driver open-codes casts:

```python
# drivers/audio/hda.ad:280 — under a comment that says "volatile MMIO helpers"
def _hda_r32(off: uint64) -> uint32:
    return cast[Ptr[uint32]](hda_mmio + off)[0]
```

`drivers/usb/xhci.ad:798` states the accepted risk explicitly: *"no volatile keyword (the compiler
doesn't reorder past extern calls and we don't hoist these into a tight loop)"*. That is an
**unenforced whole-program invariant standing in for a type qualifier**, and it has already leaked —
`drivers/audio/hda.ad:349` has a delay loop that reads an MMIO register into a dead local *"so the
loop isn't optimized away"*. That is a hand-applied `volatile` the compiler cannot verify. Now that
clang -O2 is the default backend, this class of bug gets strictly more likely.

### 2.3 No layout control — hardware structs are magic numbers

No `packed`, no `aligned(N)`, no `union`, no bitfields. `packed` is a lexer token with **zero
consumers**. So hardware descriptors are not described by types at all:

- **xHCI TRBs**: the 16-byte descriptor exists only as a *comment* (`drivers/usb/xhci.ad:239-243`);
  the code manipulates `Ptr[uint32]` with manual index math at `:1666, 1679, 1728, 1775, 1900, 1949`.
- **ACPI MADT**: raw offsets — `etype: uint8 = cast[Ptr[uint8]](ent)[0]`,
  `flags: uint32 = cast[Ptr[uint32]](ent + 4)[0]` (`drivers/acpi/acpi.ad:309-333`).
- **IDT gates**: `Array[512, uint64]` with hand-shifted bit fields (`arch/x86/kernel/idt.ad:47-64`).

In C these are `struct __attribute__((packed))` with named fields and compiler-checked offsets.
Every hardware-descriptor bug in this kernel is one arithmetic typo away with no type-system backstop.
For an OS whose value proposition is native drivers, **this is the single most expensive gap.**

**Systems-language verdict:** Adder *can* do essentially everything C can at the metal, but for
inline asm, ISRs, layout control, barriers and locks it does so **by delegating to `.S`**, and for
MMIO it does so **by convention rather than by type**. It is a capable kernel language with a
Plan-9-ish taste and two genuinely better-than-C features (`Percpu[T]`, port I/O intrinsics), sitting
on top of a notably thin metal-facing feature set.

---

## 3. Application programming

### 3.1 The shipping app dialect

Counted across `user/` + `lib/` at this SHA:

| Construct | Occurrences |
|---|---|
| `while` loops | **9,033** |
| `for x in ...` | **0** |
| `x += ...` | **0** |
| `match` / `case` | **0** |
| `cast[Ptr[uint8]]("` | **10,017** |
| `Slice` / `String` / `Result` / `Option` / `enum` | **0** |

The compiler supports `for i in range(a,b,step)`, `for x in arr`, all ten compound assignments,
chained comparisons, walrus, ternary, `do:/while`, `match`. **Almost none of it is used.** The real
application dialect of Adder is `while` + `if` + free functions + module globals + fixed arrays —
a strict subset of C89 with Python punctuation.

Two structural causes are worth naming, because they are self-inflicted and fixable:

1. **The byte-lockstep invariant creates a disincentive to adopt features.** Roadmap invariants #2/#3
   require seed and native to emit byte-identical code and require new features to be byte-inert when
   unused. Using a new feature perturbs the objdiff oracle — so the safest thing an author can do is
   never use one.
2. **Stale guidance.** `memory/feedback_compiler_quirks.md` still lists `for..in range()`, `+=`,
   class methods and `match` as unsupported, and still claims adjacent string-literal concat is
   broken. All are wrong at HEAD (both parsers implement concat: `parser.py:569`, `parser.ad:1178`).
   The corpus is written to the pessimistic doc.

### 3.2 What's actually missing (and what it costs)

**Strings.** No usable string type in production. A literal is `Ptr[char]`, so passing it anywhere
needs `cast[Ptr[uint8]](...)` — **10,017 times**. No concatenation, no formatting, no printf, no
f-strings. Every app re-implements `u64_to_dec` and a buffer-append helper (`user/hambrowse.ad:135`,
copy-pasted into `user/aplay.ad:46`, `user/hamUI.ad:104`, `user/playtone.ad:41`, `user/hamUId.ad:189`).
Formatting one status line, `user/hambrowse.ad:992-1011`:

```python
    sb: Array[64, uint8]
    sp: uint64 = _sapp(&sb[0], 0, cast[Ptr[uint8]]("HTTP "))
    sp = sp + _u64_to_dec(cast[uint64](st[0]), &sb[sp])
    sp = _sapp(&sb[0], sp, cast[Ptr[uint8]]("  bytes "))
    sp = sp + _u64_to_dec(bl[0], &sb[sp])
    sb[sp] = 0
    _set_status(&sb[0])
```

Six lines for `sprintf("HTTP %d  bytes %d", ...)`. Here Adder is **strictly worse than C**, because
C at least has printf. `lib/hamstr.ad` (261 LOC) and `lib/strview.ad` (76 LOC) exist and are decent —
**and have zero users in `user/`**.

**Collections.** None. `List`/`Dict`/`Tuple`/`Optional` are codegen-rejected because they imply hidden
heap; `LANGUAGE.md:1408` prescribes *"a flat `Array[N, KV]` … plus a linear scan"*. There is no
`lib/vec.ad`, no `lib/map.ad`, no hash table anywhere in `lib/` or `user/`. This is not a stylistic
consequence — it is a **product** consequence:

```python
# lib/hamsheetcore.ad:45-49 — the spreadsheet
MAXROWS:  uint64 = 32
MAXCOLS:  uint64 = 8
CELLTEXT: uint64 = 64
cell_raw: Array[16384, uint8]

# lib/hamwritecore.ad:121-122 — the word processor
CAP:  uint64 = 4096
text: Array[4096, uint8]
```

A 32×8 spreadsheet and a **4 KB maximum document**, shipped. `lib/hamalloc.ad` (308 LOC, a real
segregated-freelist allocator) exists and **no app uses it** — `user/hambrowse.ad:34` states the
policy: *"every sizable buffer is a top-level BSS Array, NEVER a stack local … No malloc"*, because
the user stack is one 4 KiB page. hambrowse consequently reserves 8+ MB of BSS unconditionally.

**Error handling.** Bare `return -1` (`user/hambrowse.ad:353, 365, 395, 406, 1390, …` — not even
distinguishable codes). `Result`/`Option`/`?` exist and work, but the 56-bit single-word payload
means `Result[Ptr[T], E]` cannot be expressed, which is precisely why adoption is zero. No panic, no
abort, no assert in userland; the only trap is the opt-in `ud2`, which shipped builds don't enable.
`docs/js_perf.md:37` records the predictable outcome: *"out of bounds into adjacent BSS"*.

**Closures.** None. `LambdaExpr` parses in both frontends and has no codegen case in either
(confirmed by probe: `x86: expression LambdaExpr not yet supported`). No nested functions. `Fn[...]`
is used at only 8 sites in `user/`+`lib/`, five of them double-casts through `uint64`.

**Modules & build model.** Import is a **flat merge into one global namespace** (`adder.py:504`);
`import lib.X as Y` loses the alias silently. Worse for ergonomics: **whole-program fused compile,
every time.** No separate compilation, no object files, no incremental rebuild. `user/hambrowse.ad`
transitively pulls the whole `lib/web/` tree — **~58k LOC re-parsed and re-codegen'd on every
one-character edit**. C's `make` does not have this problem.

**Stdlib shape.** The libraries are an *inverted* libc: excellent application-specific verticals
(graphics ~22k LOC incl. TTF rasterizer and a 2D Vulkan-ish stack; `lib/web/` ~58k HTML/CSS/DOM/JS;
crypto ~8.9k incl. ed25519/RSA/P-256/X.509/PGP/SSH; zlib+xz ~3.2k; mp3/wav; 9P) on an **essentially
empty general-purpose foundation**: no stdio, no printf, no libm, no JSON, no collections. Every app
copy-pastes a 40-line `extern def sys_open/sys_read/sys_write/...` preamble.

### 3.3 Two real apps

**HamWrite** — `user/hamwrite.ad` (468) + `lib/hamwritecore.ad` (3,317). Real features: menus,
bold/italic/underline, H1–H3, alignment, lists, colours, ruler, multi-level undo, find & replace,
word wrap, clipboard. The code is C with `:` instead of `{}` — flat module globals, no structs, no
methods, `while` with manual index math. `hamwrite_find_next()` (`lib/hamwritecore.ad:1224-1259`)
mutates five module-level globals (`find_msg`, `find_cur`, `anchor`, `caret`, `sel_on`) because
returning a struct by value is awkward; C would pass a `struct FindState *`.
**Verdict: a wash, marginally in Adder's favour** — no headers, no prototypes, no forward
declarations, no build system, readable casts.

**hambrowse** — `user/hambrowse.ad` (2,496) + ~58k LOC of engine. Note the one-element-array
out-parameter idiom (`st: Array[1, int64]`, `bo: Array[1, uint64]`, `bl: Array[1, uint64]` at
`:344, :386, :865`) — Adder has no tuple returns, so multiple returns go through pointer-to-array.
**Verdict: harder than C.** The string surgery quoted in §3.2 is two `snprintf`s in C, and there is
no header-tax saving to offset it because the browser is one fused TU anyway.

**App-language verdict:** Adder is currently **net harder than C for applications**, and the reasons
are *all* stdlib and ergonomics, not syntax. The syntax is fine — pleasant, even. What's missing is
strings, formatting, collections, and incremental builds. The impressive graphics/web/crypto
libraries were written *despite* the language layer, in the C-subset dialect, not in Adder-as-designed.

---

## 4. Performance — the honest numbers

### 4.1 Re-run of `scripts/bench_llvm.sh` (this SHA, i7-8086K @4.0GHz, best-of-7, checksum-gated)

```
kernel      nat-SSA      LLVM    gcc-O0    gcc-O2   LLVM/O2  natSSA/O2
matmul      0.1525s   0.0135s   0.0783s   0.0188s     0.72x      8.11x
sieve       0.3303s   0.0443s   0.1943s   0.0426s     1.04x      7.75x
licm        0.2756s   0.0296s   0.1405s   0.0329s     0.90x      8.37x
dcecopy     0.3179s   0.0500s   0.3302s   0.0605s     0.83x      5.26x
tak         0.7641s   0.3786s   0.4695s   0.3169s     1.19x      2.41x
collatz     1.3500s   0.1028s   0.3909s   0.1409s     0.73x      9.58x
mandel      0.1036s   0.0212s   0.0365s   0.0212s     1.00x      4.90x
saxpy       0.2342s   0.0600s   0.1280s   0.0595s     1.01x      3.93x
geomean                                               0.91x      5.77x
```

8/8 kernels compiled, 0 bails, 0 wrong checksums. Reproduces the recorded 0.87–0.90× within noise.

### 4.2 The clang/Rust control — *this is the number that matters*

`docs/llvm_elf64_apps_measurement.md:147` reads: *"the LLVM backend is … 0.87x gcc-O2 — **i.e. it
beats gcc -O2**"*. That framing is misleading, and the repo contains no data to check it against,
because it compares Adder-through-**clang** against C-through-**gcc**. I built the same eight C
kernels with clang-19 -O2, wrote straightforward safe-Rust ports of all eight, checksum-verified all
four toolchains produce identical output, and timed them identically:

| kernel | Adder-LLVM | gcc-O2 | clang-O2 | rustc-O | AD/gcc | **AD/clang** | **AD/rust** |
|---|---:|---:|---:|---:|---:|---:|---:|
| matmul  | 0.0134 | 0.0186 | 0.0121 | 0.0123 | 0.72 | 1.10 | 1.09 |
| sieve   | 0.0441 | 0.0411 | 0.0426 | 0.0663 | 1.07 | 1.04 | 0.67 |
| licm    | 0.0288 | 0.0321 | 0.0206 | 0.0211 | 0.90 | 1.40 | 1.37 |
| dcecopy | 0.0468 | 0.0569 | 0.0370 | 0.0374 | 0.82 | 1.27 | 1.25 |
| tak     | 0.2904 | 0.3007 | 0.3560 | 0.3615 | 0.97 | 0.82 | 0.80 |
| collatz | 0.1022 | 0.1407 | 0.0762 | 0.0863 | 0.73 | 1.34 | 1.18 |
| mandel  | 0.0207 | 0.0208 | 0.0206 | 0.0212 | 1.00 | 1.00 | 0.98 |
| saxpy   | 0.0613 | 0.0599 | 0.0516 | 0.0521 | 1.02 | 1.19 | 1.18 |
| **geomean** | | | | | **0.89** | **1.13** | **1.04** |

**The correct claim is: Adder-via-LLVM is at parity with C — 1.13× clang-O2 and 1.04× rustc-O.**
The "0.89× gcc-O2" is a clang-vs-gcc artifact and should be retired from the project's messaging.
1.13× is still an excellent result and needs no inflation; the residual gap (worst on `licm` 1.40×
and `collatz` 1.34×) is where Adder's IR loses information clang would otherwise exploit.

**Native SSA backend: 5.77× gcc-O2** — i.e. roughly **6.5× slower than the LLVM path**. Since native
is the non-droppable bootstrap and the byte-identity oracle, that is the performance of Adder's *own*
codegen, and it is not close to C.

(Rust ports are mine, written for this review from the C twins; they are safe Rust with `Vec`
indexing, not `unsafe`/`static mut`. Sources and the timing harness are outside the repo tree; the
`bench_llvm.sh` run is reproducible in-tree.)

**Caveat on both tables:** eight small integer/float loop kernels are not a proof about a 905k-line
OS. `docs/llvm_elf64_apps_measurement.md:160-190` is admirably honest that an app-level A/B timing
was *attempted and failed* because the LLVM backend still bails on `lib/vk/vk_2d`'s raster inner
loops. **There is no end-to-end application or kernel performance comparison in this repo.**

---

## 5. Tooling & ergonomics — where new languages actually lose

| | Adder | C |
|---|---|---|
| Error messages (host/seed) | line + column, filename, **one error then abort** | line + column + caret + snippet + fix-its + notes, all errors |
| Error messages (**shipping native compiler**) | `[adder_cc] FAIL: parse error at line N` / `codegen error reason=7` — **no column, no filename, no token, no "expected X"**; the reason-code legend lives in a source comment (`codegen.ad:815`) | — |
| Warnings | **none** — no `-Wall`, no `-Wconversion`, no `-Werror` | extensive |
| Debug info | **none** — zero DWARF (`grep -rni "dwarf\|debug_line\|DW_TAG" adder/compiler/` → nothing). You cannot source-level debug an Adder binary. | full |
| Debugging practice | printk checkpoints on serial; QEMU gdbstub at raw addresses; **A/B native-vs-LLVM substitution** (`KLLVM_DEFAULT_FORCE_NATIVE`) as a bisection tool; hand-written static `.ll` scanners | gdb, perf, ASan/UBSan/TSan |
| Sanitizers / coverage / profiler | **none** | all |
| Build model | **whole-program fused, no incremental, no separate compilation.** ~2 min whole-kernel `-O2` compile for a one-line change (`docs/kernel_llvm_phase5b.md:1299`) | separate compilation + make |
| Editor / IDE | **nothing.** No syntax file, no LSP, no tree-sitter, no formatter, no linter. `parse_with_errors()` exists "for tooling support" with no consumer. ~905k lines edited without highlighting. | mature everywhere |
| Formal grammar | **none.** No EBNF anywhere. The grammar is "whatever `parser.py` and `parser.ad` both happen to accept" — two independent recursive-descent parsers that agree by convention, and demonstrably **don't** (match guards) | ISO standard |
| Docs | voluminous but **self-contradicting** (see below) | standard + decades of material |
| Testing | ✅ **genuinely strong** — 1,462 `test_*.sh` gates, 132 `tests/*.ad`, differential fuzzer with a by-construction oracle (`fuzz_adder_diff.sh`, 0 miscompiles/500), and a **byte-identity kobjdiff oracle across 11,064 kernel functions**. Weaknesses: no unit-test framework, no assertions API, no coverage; gates are bash grepping serial logs, which the project itself documents as producing false greens and reds. | mature |

Here is a direct comparison I ran on the same three-error program:

```
Adder:  Error: x86: unknown identifier 'undefined_thing'          ← 1 error, no line, no column

gcc:    t_err.c:2:13: error: initialization of 'int' from 'char *' ... [-Wint-conversion]
        t_err.c:3:13: error: implicit declaration of function 'undefined_thing' ...
        t_err.c:4:12: error: 'z' undeclared (first use in this function)   ← all 3, with carets
```

Adder reported one of three problems and **never noticed the type error at all**.

**Doc currency is itself a maturity signal, and it's bad.** `adder/LANGUAGE.md:3-4` still says Adder compiles
"via a hand-written backend (**no LLVM**)" — falsified by `docs/llvm_default_build.md`.
`LANGUAGE.md:20` says "there are no exceptions, no try/except" while `LANGUAGE.md:160` lists them as
keywords and `adder_language_guide.md:105` says they work (my probe: **rejected**, so LANGUAGE.md's
prose is right and the guide is wrong). `LANGUAGE.md:573-634` documents literal/guard/OR patterns in
detail while `LANGUAGE.md:1424` in the *same file* says match codegen is unimplemented (my probe:
match works, guards don't on native). `roadmap:36-38` lists `try/except/finally`, `lambda`,
comprehensions, f-strings and `List`/`Dict` as shipped — my probes reject **all five**. An agent or
human reading any one of these documents will be wrong about the language.

---

## 6. Maturity gaps a C programmer will hit on day one

Verified present/absent, not guessed:

| C feature | Adder | Impact |
|---|---|---|
| Function prototypes / arg checking | ❌ | wrong arity silently compiles (§1.1) |
| `const` | ❌ | no read-only contracts, no `.rodata` by type |
| `union` | ❌ | punning via `cast[Ptr[T]]` |
| Bitfields | ❌ | hardware registers as shift/mask soup |
| `__attribute__((packed/aligned))` | ❌ | hardware descriptors as magic offsets |
| `volatile` | ❌ (parsed, ignored) | MMIO correctness by convention |
| Varargs | ❌ | `printk0..3` + mandatory casts |
| Preprocessor / macros / conditional compilation | ❌ | no portability shims, no `_Generic` |
| Designated / struct initialisers | ❌ | declare-then-assign |
| `switch` on integers | ❌ | `match` is enum-only on native; chained `if/elif` |
| Separate compilation / headers | ❌ | 58k-LOC rebuild per edit (also removes header tax — genuinely two-sided) |
| stdio / printf | ❌ | hand-rolled `u64_to_dec` in every app |
| libm | ❌ | no `sin`/`sqrt`/`pow` anywhere; the spreadsheet uses fixed-point int64 |
| Collections (even hand-rolled convention) | ❌ | fixed-size BSS arrays as product limits |
| Threading primitives in-language | ❌ | `lib/thread.ad` (351 LOC) + `extern def` into asm spinlocks |
| Third-party ecosystem | ❌ | zero. Everything is written in-tree. |
| Function pointers | ✅ | `Fn[R,A...]`, real |
| `sizeof` / `container_of` | ✅ | compile-time folded |

The last line of that table is important context: **C's biggest advantage over Adder is not a language
feature, it's fifty years of libraries and tools.** Nothing in this review changes that.

---

## 7. Compiler bugs — what the last week says about maturity

Every one of these was a **silent miscompile found by booting an OS and watching it crash**, not by
any test. All were fixed in the ~5 days before this SHA.

**a) Red zone × interrupts — `48faa96a`.** Every LLVM-emitted function stored locals in the 128-byte
SysV red zone; the kernel takes IRQs on the same stack, so a timer tick inside `ip_csum16` clobbered
the `buf` pointer → intermittent `#GP` during DNS lookups. `-mno-red-zone` was *already on the clang
command line* and did nothing, because command-line codegen flags don't seed per-function attributes
when clang consumes pre-existing textual IR. Fix: emit `noredzone` on all 11,067 defs. **Implication:
the emitter shipped for weeks emitting functions with no LLVM attributes at all.**

**b) Struct-local alloca sized 8 bytes — `5245bf45`.** Struct-typed locals fell through
`ssa_intern_local`'s scalar path where `prim_type_size` returns 8, so a 32-byte `P9Cursor` got an
8-byte alloca; member stores at +8/+16/+24 overran the frame and at -O2 zeroed the low dword of the
saved return address → `ret` to `0xffffffff00000000`. **Every struct local was 8 bytes.**

**c) Global alignment over-promise — same commit.** The emitter declared every module global
`align 16` while the hybrid link let byte-packed `native_main.o` define them at any address; clang -O2
vectorised a zeroing loop to `movaps` → `#GP`. The doc calls it what it is: the emitter *"LIES to
clang"*.

**d) Struct-value globals sized `[8 x i8]` — `b5a7a97c`.** ~50 globals 8 bytes too small; every store
past offset 8 spilled into the **adjacent** `.bss` global (`@v9p_dev` at offset 112 of 120;
`@xhci` at 836 of 840). A static scanner found **1,776 constant-offset accesses past a global's
declared size**.

**e) Signed-vs-unsigned member compare — `4d6406b1`.** `ssa_expr_sgn` had **no `ND_MEMBER` arm**, so
*any* comparison of an unsigned struct field emitted `icmp slt` instead of `icmp ult`. Caught only
because a high-half kernel pointer has bit 63 set. This is §1.1's missing type checker cashing out
as a miscompile: signedness is *recovered* in the backend, and a whole AST node class was missing.

**f) Fixed-size table overflow → wrong symbol, silently — `077cc1dd`.** Exceeding
`MAX_GLOBALS=16384` made `llvm_glob_for`'s reverse scan fall back to the **wrong global**, so
**41% (3,146/7,660) of all printk format-string pointers in the emitted IR pointed at garbage.**

That last one names the deepest structural issue: **the compiler is built entirely on fixed-size
arrays, and overflow does not error — it produces a wrong answer.** A partial inventory:
`codegen.ad`: `CODE_CAP=2097152`, `MAX_LOCALS=256`, `MAX_FUNCS=1024`, `MAX_GLOBALS=1024`,
`MAX_STRINGS=2048`, `MAX_STRUCTS=256`, `MAX_ENUMS=64`. `cfg.ad`: `NM_MAX=256` (max distinct names
per function), `CI_MAX=16384`, `BB_MAX=8192`, `LOOP_MAX=256`. `regalloc.ad`: `RA_MAXNAMES=256
# == cfg NM_MAX`. `ssa.ad`: `SSA_VAL_MAX=65536`, `SSA_BB_MAX=1024`.

Worse, these caps **differ between the host and on-device compilers via textual source rewriting** —
`scripts/concat_compiler_source.py:242` literally does
`("NM_MAX: uint32 = 256", "NM_MAX: uint32 = 1024")` plus ~60 more sed-style pairs that must be kept
in manual lockstep, with an in-file warning that *"EVERY array/constant sized by NM_MAX MUST scale in
lockstep or the liveness/SSA passes write out of bounds."* **The host compiler is a different
compiler from the device compiler, produced by find-and-replace.**

The caps leak into production. `init/main.ad:4321`: *"start_kernel itself is a ~7.6k-line function
whose CFG exceeds the compiler's per-function NM_MAX / CI_MAX arena caps, so the LLVM backend BAILS
on it"* — **the kernel's entry point is not compilable by the default backend.** Commit `4e2712d0`
records apps still falling back "**4 NM_MAX**". And `scripts/build_user.sh:77-116` institutionalises
it: `_classify_bail()` maps LLVM failures to reason strings and silently falls back to the native
backend per app, reporting "native fallback: N/M apps" as a normal build line. **Backend-bailing is a
routine, expected build outcome.**

**What this says about maturity:** the *process* around the compiler is unusually rigorous for a
project this age — a differential fuzzer with a construction oracle, and byte-identity objdiff across
11k kernel functions, are better than most hobby compilers ever get. But those oracles check
*native == seed*; the LLVM emitter sits outside them, which is exactly why five silent miscompiles
shipped and were found by crashing. And the debugging record is candid about how hard that is:
`f10a1e9a` "DISPROVEN", `a3fd3467` "DISPROVEN", `72f805c0` "OVERTURN", `e1b20ac2` "REFRAME",
`7a1bf7bf` "NOT reproduced" — five reversals in ten days on one bug class.

---

## 8. Capability matrix (summary)

| Feature | Adder | C | Note |
|---|---|---|---|
| Fixed-width primitive types | ✅ | ⚠️ | `int`≡`int32`, `char` unsigned — pinned, not impl-defined |
| Static type checking | ❌ | ✅ | **no type checker exists**; wrong arity compiles |
| Implicit conversions | ✅ none | ❌ | but unenforced |
| `const` / immutability | ❌ | ✅ | |
| Structs / C-ABI layout | ✅ | ✅ | |
| Struct by-value pass/return | ⚠️ ≤16 B | ✅ | |
| Struct literal init | ❌ | ✅ | |
| Packed / aligned / bitfields | ❌ | ✅ | **worst systems gap** |
| Unions | ❌ | ✅ | pun via `cast[Ptr[T]]` |
| Arrays with size in the type | ✅ | ⚠️ | but `N` must be a literal |
| Fat-pointer slices | ✅ | ❌ | 0 production users |
| Tagged enums / `Option`/`Result`/`?` | ⚠️ | ❌ | 56-bit payload cap → `Result[Ptr[T],E]` impossible; 0 users |
| Pattern matching | ⚠️ | ❌ | enum-only on native, no literals/guards; 0 users |
| Generics / traits | ❌ | ❌ | C has `_Generic`+macros |
| Preprocessor / macros | ❌ | ✅ | |
| Varargs | ❌ | ✅ | `printk0..3` |
| Function pointers | ✅ | ✅ | |
| Closures / lambdas | ❌ | ❌ | |
| Exceptions | ❌ | ❌ | by design |
| Bounds checking (opt-in) | ⚠️ | ❌ | works, but `Array`-bases only, in no build script |
| Ownership / affine types | ⚠️ | ❌ | `Own[T]`, seed-only, 0 users |
| Borrow check / lifetimes | ❌ | ❌ | deliberately skipped |
| RAII / destructors | ❌ | ❌ | |
| GC-free / freestanding | ✅ | ✅ | |
| Inline asm | ⚠️ | ✅ | no operands/clobbers |
| `volatile` / MMIO | ❌ | ✅ | parsed, ignored |
| Port I/O intrinsics | ✅ | ⚠️ | better than portable C |
| Per-CPU (`%gs`) as a type | ✅ | ⚠️ | better than C |
| Interrupt/naked functions | ❌ | ✅ | all ISRs in `.S` |
| Section attributes | ❌ | ✅ | linker script only |
| Atomics | ⚠️ 4 intrinsics | ✅ | no memory model, no barriers builtin |
| Threading primitives | ❌ | ✅ | `extern def` to asm |
| stdio / printf / libm | ❌ | ✅ | |
| Collections in stdlib | ❌ | ⚠️ | C also lacks them, but has printf/qsort/bsearch |
| Strings / formatting | ❌ | ⚠️ | worse than C |
| Separate / incremental compilation | ❌ | ✅ | 58k-LOC rebuild per edit |
| Debug info (DWARF) | ❌ | ✅ | |
| Sanitizers / profiler / coverage | ❌ | ✅ | |
| Editor / LSP / formatter | ❌ | ✅ | none at all |
| Warnings | ❌ | ✅ | |
| Multi-error diagnostics | ❌ | ✅ | |
| Formal grammar / spec | ❌ | ✅ | two parsers that disagree |
| Differential fuzzing + byte-identity oracle | ✅ | ⚠️ | better than typical |
| Codegen quality (via LLVM) | ✅ | ✅ | 1.13× clang-O2, 1.04× rustc |
| Codegen quality (native backend) | ❌ | ✅ | 5.77× gcc-O2 |
| Third-party ecosystem | ❌ | ✅ | |

---

## 9. Ranked gaps to close

Ordered by (damage caused) × (cost to fix), using this repo's own evidence.

1. **A real type checker.** Argument count and type, assignment compatibility, pointer-type
   compatibility, return type. This is the root of §1.1, of the `icmp slt` miscompile (§7e), and of
   why the language cannot get non-null `Ref[T]` (`roadmap:145-150` defers it explicitly *because* it
   "is a genuine type-checker addition, not a desugar"). Everything else on this list gets easier
   after it.
2. **Kill the fixed-size-table failure mode.** Overflow must *error*, never fall back to a wrong
   symbol (§7f). Then grow or dynamise `NM_MAX`/`CI_MAX` so `start_kernel` and the 4 remaining
   NM_MAX-bailing apps compile, and retire the `concat_compiler_source.py` string-substitution
   divergence between host and device compilers.
3. **Layout control: `packed`, `align(N)`, and bitfields.** Turns xHCI/ACPI/IDT magic offsets into
   compiler-checked field names. Highest-value systems feature by a distance.
4. **Working `volatile` (or MMIO intrinsics).** The `xhci.ad:798` promise is not enforceable and
   becomes more dangerous now that clang -O2 is default.
5. **Strings + formatting.** A usable `String`/`Slice[uint8]` with concat and a `format`/`printf`
   equivalent. Deletes 10,017 casts and the `u64_to_dec` copy-paste, and makes app code readable.
6. **A minimal collections library** (growable vector, hash map). Directly lifts the 4 KB document
   and 32×8 spreadsheet product ceilings.
7. **Incremental / separate compilation.** 58k-LOC rebuild per browser edit is the biggest daily
   productivity tax in the project.
8. **DWARF line tables.** Even `.debug_line` alone would convert "bisect backends and stare at
   serial" into "gdb backtrace with line numbers".
9. **Inline asm with operands and clobbers.** Unlocks swapgs, barriers, and locks written in Adder
   rather than `.S`.
10. **Multi-error diagnostics with columns on the native compiler.** `codegen error reason=7` is
    unacceptable for a shipping compiler.
11. **Multi-word enums** (sret / `rax:rdx`). Without them `Result[Ptr[T], E]` is inexpressible and the
    whole error-handling story stays unused.
12. **Doc reconciliation.** Three documents currently give three different answers about `match`,
    `try`, `lambda`, and LLVM. Generate the feature table from probes; delete the rest.
13. **Editor support** (a tree-sitter grammar would give highlighting to every editor at once).

---

## 10. Should you write X in Adder or C today?

| If you're writing… | Use | Why |
|---|---|---|
| **HamnixOS kernel, drivers, filesystems, servers** | **Adder** | It already works at 265k lines with essentially no asm, self-hosts, and is the project's whole point. Discipline required: hardware descriptors need hand-checked offsets, MMIO needs hand-audited access, and you must keep functions under the NM_MAX cap. |
| **A hardware descriptor / wire-format struct** | **C-shaped care in Adder**, and push for `packed` | Adder cannot express it as a type today. Write the offsets once, in one place, with `sizeof` assertions. |
| **An interrupt entry, lock, or barrier** | **`.S`** | Not expressible in Adder. This is already the tree's practice. |
| **A HamnixOS GUI/office/desktop app** | **Adder** | Consistency, no FFI seam, the `lib/hamui`+`lib/web` stack is Adder-native. Accept that you will hand-roll formatting and live with fixed-size buffers. |
| **A text/string/data-processing tool** | **C, if you had the choice** | No printf, no collections, no libm. In-tree you don't have the choice — so budget for the boilerplate. |
| **Anything performance-critical** | **Adder via LLVM** | 1.13× clang-O2 is genuinely competitive. Avoid the native SSA backend (5.8× gcc-O2) for anything hot. Verify your function doesn't bail (`build_user.sh` will tell you). |
| **Anything that must be memory-safe** | **Neither** | Adder ships with C's safety posture and less static checking. If safety is the requirement, that's a Rust conversation, and the project has explicitly decided against it (`roadmap:46-63`). |
| **A new language feature or compiler pass** | **Adder** | The self-hosted compiler + differential fuzzer + byte-identity oracle make this genuinely pleasant, and it's where the leverage is. |

**One-line summary.** Adder is a real, working systems language that has earned its keep — a
self-hosting OS in ~905k lines with 1.5% assembly, at C-level performance through LLVM. Its
weaknesses are not exotic: it has **no type checker**, **no layout control**, **no working
`volatile`**, **no strings or collections**, **no debug info**, **no editor support**, and a compiler
whose fixed-size internal tables **silently emit wrong code on overflow**. None of those are hard
research problems — they are unglamorous engineering, and closing the first three would change what
it feels like to write this OS more than any other work available.

---

## Appendix — reproduction

- `bash scripts/bench_llvm.sh` (§4.1). Log from this run: `build/bench_llvm/run.log`.
- §4.2 control: C twins from `tests/bench/opt/*.c` built with `clang-19 -O2`; Rust ports written for
  this review from those twins (safe Rust, `Vec` indexing), built `rustc -O -C panic=abort`; all four
  toolchains checksum-verified identical before timing; best-of-7, same harness as `bench_llvm`.
  Machine: Intel i7-8086K @ 4.00GHz, gcc 14.2.0, clang 19.1.7, rustc 1.79.0.
- §1.1 / §1.3 / §5 probes: single-file `.ad` programs compiled with
  `python3 -m compiler.adder compile --target=x86_64-linux [--check-bounds]` under the repo root.
  Confirmed accepted: default args, keyword args, `match`, `enum`, `Option`/`Some`/`None`/`!`,
  `Slice[T]`, `String`, sub-slicing, `--check-bounds` trap.
  Confirmed rejected: `lambda`, f-strings, list comprehensions, `try`/`except`, `union`, `defer`,
  `@packed`, varargs `...`.
- Counts in §3.1 from `grep -rhoE ... --include=*.ad user lib` at this SHA.
