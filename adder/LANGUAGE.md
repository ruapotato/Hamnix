# Adder Language Reference

Adder is a Python-syntax **systems** programming language that compiles
directly to x86_64 assembly via a hand-written backend (no LLVM). It's
the language Hamnix is written in — the bare-metal kernel
(`init/main.ad` and everything under `arch/`, `mm/`, `kernel/`,
`drivers/`, `fs/`, `sys/`), the Linux ABI shims (`linux_abi/`), and
userland binaries (`user/*.ad` and `tests/test_*.ad`). See
`docs/architecture.md` for how those pieces fit together.

## Design principles

Adder uses Python's surface syntax to keep code readable, but is a
**systems language** at heart. That means:

- **No hidden allocation.** Heap memory comes from explicit
  `kmalloc(size) -> uint64` calls into `mm/slab.ad`. The language has
  no garbage collector and no implicit `new`.
- **No hidden control flow.** Functions return error codes (Linux's
  `-EINVAL` / `-ENOMEM` convention) — there are no exceptions, no
  `try`/`except`, no unwinding.
- **No runtime-typed values.** Every variable has a declared type. The
  compiler does not synthesise `Any` / `Object` / a `repr()` machinery.
  Comparisons, prints, and conversions are all explicit.
- **Every cycle should be inspectable in the generated assembly.**
  Each Adder construct maps to a handful of x86_64 instructions you can
  reasonably predict, which is why dispatch tables use `Fn[R, A...]`
  (one `call *%r11`) rather than virtual methods or duck typing.

This document is a **reference for what the compiler actually
implements**, not a wishlist. If a section is here, you can rely on
it; if a Python feature you'd expect is missing, it's deliberate (see
*Features deliberately not in Adder* at the bottom).

## Table of Contents
- [Lexical Grammar](#lexical-grammar)
- [Types](#types)
- [Static Type Checking](#static-type-checking)
- [Variables](#variables)
- [Functions](#functions)
- [Function Pointers](#function-pointers)
- [Control Flow](#control-flow)
- [Classes (structs with optional static methods)](#classes-structs-with-optional-static-methods)
- [Pointers and Memory](#pointers-and-memory)
- [Type Casting](#type-casting)
- [Heap Allocation](#heap-allocation)
- [Per-CPU Storage](#per-cpu-storage)
- [Hardware Intrinsics](#hardware-intrinsics)
- [Inline Assembly](#inline-assembly)
- [External Functions](#external-functions)
- [Import System](#import-system)
- [`container_of`](#container_of)
- [Target Selection](#target-selection)
- [Features deliberately not in Adder](#features-deliberately-not-in-adder)

---

## Lexical Grammar

### Identifiers

An identifier is a maximal run of `[A-Za-z0-9_]` that is NOT a valid
numeric literal under the rule below. Identifiers MAY start with a
digit — `9P2000`, `9foo`, `100abc` are all legal identifier names.
The classic Python rule "identifiers can't start with a digit" was
relaxed so Plan 9 / 9P names (`9P2000`, `lib/9p/...`, `sys/src/9/...`)
can be expressed verbatim, matching the spelling in the Plan 9 source
tree and the underlying 9P2000 protocol RFC.

### Numeric literals

When the lexer encounters a token starting with a digit, it greedily
reads `[A-Za-z0-9_]+` and then checks whether the assembled word
matches one of the numeric forms below. If yes, the token is a
`NUMBER`; otherwise it is an `IDENT`. After the greedy alnum read, the
lexer also extends the word through a `.digits` fractional part (only
if the next char is `.` followed by a digit — `9.foo` still tokenizes
as `9` `.` `foo`) and through a signed `[eE][+-]?digits` exponent tail
(the `+`/`-` isn't alnum, so the greedy first pass would otherwise
stop short of `1.5e-3`).

| Form                              | Example     | Token       |
|-----------------------------------|-------------|-------------|
| `0x[0-9A-Fa-f_]+`                 | `0x1F`      | `NUMBER`    |
| `0b[01_]+`                        | `0b1010`    | `NUMBER`    |
| `0o[0-7_]+`                       | `0o755`     | `NUMBER`    |
| `[0-9_]+`                         | `1_000_000` | `NUMBER`    |
| `[0-9_]+\.[0-9_]+([eE][+-]?[0-9_]+)?` | `1.5e-3`    | `NUMBER`    |
| `[0-9_]+[eE][+-]?[0-9_]+`         | `9e5`       | `NUMBER`    |
| anything else with a digit prefix | `9P2000`    | `IDENT`     |
| `0x` followed by non-hex          | `0xZZ`      | `IDENT`     |

Underscores act as digit separators inside numeric literals and are
stripped before value parsing — `1_000_000` evaluates to `1000000`.

Examples:

```python
9P2000: int32 = 100        # IDENT: 9P2000 is a digit-leading identifier
mode: uint32 = 0o755       # NUMBER: octal literal
x = 9.foo                  # NUMBER(9), DOT, IDENT(foo) — three tokens
```

### Strings

Adder accepts `"..."` and `'...'` strings. They lower to a
NUL-terminated byte sequence in `.rodata` and are referenced through
RIP-relative `leaq`. Triple-quoted strings are supported. Escapes:
`\n`, `\t`, `\r`, `\b`, `\\`, `\'`, `\"`, `\0`, `\xNN`.

**That list is exhaustive.** Anything else after a backslash is NOT an
escape: the backslash is dropped and the next character is kept
verbatim, with no warning, in BOTH front ends. So `"\v"` is the letter
`v`, `"\a"` is the letter `a`, and the C octal escape `"\101"` is the
three characters `101` — not `A`. To get a byte by value, spell it
`\xNN`. (`\x` followed by a non-hex digit is a hard error in the seed
but currently yields byte 0 in the native lexer, which NUL-terminates
the literal early. Don't write one — the divergence is a known defect.)

Adjacent string-literal concatenation works: `"foo " "bar"` is exactly
the same as `"foo bar"`. Any number of adjacent `STRING` tokens are
joined into one literal at parse time, just like C and Python — in BOTH
the seed (`parser.py` `parse_primary`) and the native front end
(`parser.ad` `parse_primary`, which copies the fragments into one fresh
`strbuf` entry).

Outside brackets a newline ends the statement, so a multi-line join has
to be parenthesised — exactly as in Python:

```python
printk("some long message "          # inside the call's parens: joined
       "continued here\n")

s: Ptr[uint8] = ("abc"               # parenthesised: joined
                 "def")
```

> Until 2026-07-30 the NATIVE front end consumed the trailing fragments
> and threw their text away — silently, no warning, no error. 35 kernel
> `printk` sites emitted only their opening fragment INCLUDING the
> trailing newline, so log lines merged; 14 of those were a leak
> campaign's own instrumentation. The seed had always concatenated, so
> this was a seed/native semantic divergence as well as a silent drop.
> Pinned by `scripts/test_compiler_adjacent_strings.sh`.

### Reserved words

The lexer in `compiler/lexer.py` claims the following names as
keywords / built-in tokens. Using one of these as a variable,
parameter, field, or function name is a **parse error** (or in a
few cases produces a confusing downstream codegen error, because
the parser still produces a typed token that the codegen can't
demote back to an identifier). When porting C/Linux code that uses
one of these as a parameter name, rename it (the canonical rename
is `match` → `m_match`, `case` → `cse`, `int` → `n`).

Source of truth: `compiler/lexer.py`'s `KEYWORDS` dict — every name
below is a key there. If the lexer's `KEYWORDS` grows, this list
must grow with it.

#### Full reserved-words list (alphabetical)

Every entry below is a key in `compiler/lexer.py::KEYWORDS` and
becomes a typed token rather than an `IDENT`.

```
Array       Dict        Enum        False       Fn          List
None        Optional    Ptr         Ref         True        Tuple
and         as          asm         assert      async       auto
await       bool        break       case        cast        char
class       classmethod continue    dataclass   def         defer
del         do          elif        else        except      extern
finally     float       float32     float64     for         from
global      if          import      in          int         int16
int32       int64       int8        interrupt   is          isinstance
lambda      match       nonlocal    not         or          packed
pass        property    raise       return      self        staticmethod
str         try         uint16      uint32      uint64      uint8
union       volatile    while       with        yield
```

One *additional* name — `Percpu` — is not in the lexer's
`KEYWORDS` dict (the lexer emits it as a plain `IDENT`), but the
**parser** recognises `Percpu[T]` specifically as the per-CPU
storage type. Using `Percpu` as an ordinary name confuses
downstream codegen. Treat it as effectively reserved.

#### Reserved words by category

| Category | Names |
|---|---|
| Control flow | `if`, `elif`, `else`, `while`, `do`, `for`, `in`, `break`, `continue`, `pass`, `return`, `with`, `raise`, `try`, `except`, `finally`, `match`, `case`, `assert`, `defer`, `yield`, `lambda`, `async`, `await` |
| Boolean / null | `True`, `False`, `None`, `and`, `or`, `not`, `is` |
| Definition | `def`, `class`, `from`, `import`, `as`, `extern`, `union`, `interrupt`, `global`, `nonlocal`, `del` |
| Scalar types | `int8`, `int16`, `int32`, `int64`, `uint8`, `uint16`, `uint32`, `uint64`, `float32`, `float64`, `bool`, `char`, `int`, `float`, `str` |
| Compound type heads | `Ptr`, `Fn`, `Array`, `Ref`, `List`, `Dict`, `Tuple`, `Optional`, `Enum` |
| Magic identifier | `Percpu` — an ordinary `IDENT` to the lexer, but the parser recognises `Percpu[T]` specifically as the per-CPU storage type. Don't use `Percpu` as a name. |
| Casts / type-ish | `cast`, `auto` |
| Python noise | `dataclass`, `isinstance`, `property`, `staticmethod`, `classmethod`, `self`, `volatile`, `packed`, `asm` |

Names like `match`, `case`, `int`, `str`, `self`, and `asm` come up
especially often when porting code — rename them on the way in.

(`bytes` and `field` were on this list until 2026-06-15 — both were
dead reservations with no parser / codegen consumer and got
un-reserved per [[feedback-fix-the-language-layer]].)

---

## Types

### Scalar Types

| Type | Size | Description |
|------|------|-------------|
| `int8` | 1 byte | Signed 8-bit integer |
| `int16` | 2 bytes | Signed 16-bit integer |
| `int32` | 4 bytes | Signed 32-bit integer |
| `int64` | 8 bytes | Signed 64-bit integer |
| `uint8` | 1 byte | Unsigned 8-bit integer |
| `uint16` | 2 bytes | Unsigned 16-bit integer |
| `uint32` | 4 bytes | Unsigned 32-bit integer |
| `uint64` | 8 bytes | Unsigned 64-bit integer |
| `bool` | 1 byte | Boolean (`True`/`False`) |
| `char` | 1 byte | 8-bit character; idiomatic for `Ptr[char]` (C-style strings) |

All integers occupy a 64-bit slot in the SysV AMD64 ABI: `%rax` for
return values, the 6 argument registers for parameters. Sub-8-byte
loads/stores use the sized form (`movb`/`movw`/`movl`); reads
zero-extend or sign-extend per the type's signedness.

Signedness drives the codegen for `<`, `<=`, `>`, `>=`, `>>`, `/`,
`//`, and `%`. If either operand is `uint*`, the codegen emits the
unsigned variant (`setb`/`setbe`/`seta`/`setae`, `shrq`, `divq`); if
both are signed, the signed variant (`setl`/`setle`/`setg`/`setge`,
`sarq`, `idivq`). Equality (`==` / `!=`) is sign-agnostic.

### Compound Types

```python
# Pointer to T
p: Ptr[uint32]

# Fixed-size array. N must be a numeric literal. Stored inline:
# in a local frame, on the stack; as a global, in .bss (zero-init)
# or .data (string-initialised). NO heap involvement.
buf: Array[16, uint8]
matrix: Array[8, Array[6, uint8]]    # 2-D works; indexes nest

# Function pointer (see "Function Pointers" below).
handler: Fn[int32, Ptr[uint8], uint64]

# Per-CPU storage (see "Per-CPU Storage" below).
ticks: Percpu[uint64]
```

Production .ad files use `Ptr[T]`, `Array[N, T]`, `Fn[R, A...]`, and
`Percpu[T]`. These are the only compound types the codegen
implements.

---

## Static Type Checking

Type annotations are **contracts, checked before codegen**, not codegen
hints. The pipeline is

```
parse  ->  affine-check (Own[T])  ->  SEMA (type check)  ->  codegen
```

and the sema pass lives in `adder/compiler/sema.py`. It reports **every**
problem it finds in one compile — with `file:line:col`, the source line and
a caret — rather than aborting on the first:

```
$ adder compile t.ad
t.ad:12:18: error: integer literal 300 is not representable in 'uint8' (initialising 'lim') [lit-range]
   12 |     lim: uint8 = 300
      |                  ^~~
      note: value must lie in [-128, 255]
t.ad:14:12: error: too few arguments to 'add3': 2 given, 3 expected (missing 'c') [arity]
   14 |     return add3(1, 2) + take_ptr(n)
      |            ^~~~
      note: declared as add3(a: int32, b: int32, c: int32) -> int32
t.ad:14:34: error: 'int32' used where 'Ptr[uint8]' is required (argument 1 ('p') of 'take_ptr') [ptr-int]
   14 |     return add3(1, 2) + take_ptr(n)
      |                                  ^
      note: add an explicit cast[Ptr[uint8]](...)
Error: 3 type errors (set ADDER_SEMA=0 to bypass the type checker)
```

Every diagnostic belongs to a named **class** (printed in brackets) with a
severity, so a class can be tightened or loosened without a code change.

| Class | Default | What it catches |
|---|---|---|
| `arity` | **error** | wrong number of arguments at a direct call |
| `kwarg` | **error** | unknown / duplicated keyword argument |
| `lit-range` | **error** | integer literal with no representation in the target type (`uint8 = 300`). `-1` into an unsigned type is legal — it names a valid bit pattern |
| `ptr-int` | **error** | an integer used where a `Ptr[T]` is declared — the callee will dereference it |
| `ptr-ptr` | **error** | `Ptr[A]` assigned from `Ptr[B]`. The 8-bit types (`uint8`/`int8`/`char`) are one type for this purpose |
| `int-from-ptr` | **error** | a pointer used where an integer is declared |
| `int-float` | **error** | integer/float mixed without a `cast` |
| `narrowing-arg` | **error** | a call ARGUMENT narrows an integer without a cast (`uint64` into a `uint32` parameter). The callee only ever sees the low bits and cannot detect the truncation |
| `cmp-sign` | warning | `<`/`<=`/`>`/`>=` between a signed and an unsigned operand of the same width. The backend picks ONE comparison for the whole expression — this is the shape behind the `icmp slt`/`ult` kernel miscompile |
| `ret-value` | warning | bare `return` from a value-returning function, or a value returned from `-> None` |
| `deref` | warning | indexing something that is neither a pointer, an array nor a slice |
| `narrowing-assign` | warning | a non-argument narrowing (assignment, initialiser, `return`) without a cast |
| `not-callable` | off | call to a name with no visible declaration |

Environment knobs:

* `ADDER_SEMA=0` — skip the pass entirely.
* `ADDER_SEMA_STRICT=1` — promote every warning class to an error.
* `ADDER_SEMA_ALL=1` — additionally enable the `off` classes.
* `ADDER_SEMA_<CLASS>=error|warning|off` — per class, `-` spelled `_`
  (`ADDER_SEMA_PTR_PTR=error`).

`python3 scripts/sema_scan.py` runs the checker over the whole tree and
prints per-class site counts; that measurement is what sets the defaults
above.

The pass is **pure analysis** — it never mutates the AST, so codegen output
is byte-identical with it on or off.

**Native compiler.** The self-hosted compiler
(`adder/compiler/codegen.ad`), which is the default toolchain, carries the
arity check natively (`arity_check_direct_call`, failure reason 12) because
a wrong-arity call is not a style problem: the callee reads an argument
register the caller never wrote, so the program returns a different answer
on every run. The remaining classes are seed-side today.

---

## Variables

### Declaration and Assignment

Every variable has a declared type:

```python
x: int32 = 42
flags: uint64 = 0xCAFEBABE
buf: Array[8, uint8]                 # zero-init for arrays / structs

# Re-assignment
x = x + 1
```

### One assignment per statement

Each assignment statement has a single target. Tuple-unpacking
assignment (`a, b = b, a`) is **not** supported — the parser accepts
the syntax but the codegen rejects `TupleUnpackAssign`. For a swap,
use a temporary:

```python
a: int32 = 1
b: int32 = 2
tmp: int32 = a
a = b
b = tmp
```

### Compound / augmented assignment operators

All ten compound-assignment operators are supported and desugar to a
read-modify-write at codegen time:

| Operator | Meaning          |
|----------|------------------|
| `+=`     | add              |
| `-=`     | subtract         |
| `*=`     | multiply         |
| `/=`     | divide (signed)  |
| `%=`     | modulo (signed)  |
| `&=`     | bitwise AND      |
| `\|=`    | bitwise OR       |
| `^=`     | bitwise XOR      |
| `<<=`    | left shift       |
| `>>=`    | arithmetic right shift |

They work on `Identifier`, `MemberExpr` (struct-field), and `IndexExpr`
(array/pointer-index) targets. For non-identifier targets the address is
computed once (avoiding double-evaluation of the index expression).

```python
x: int32 = 0
x += 5              # x = x + 5 = 5
flags: uint32 = 0
flags |= 0xFF       # flags = 0xFF
flags &= 0x0F       # flags = 0x0F
flags ^= 0x05       # flags = 0x0A
n: int32 = 8
n >>= 1             # n = 4
n <<= 2             # n = 16

# Struct field compound assignment
p: Point
p.x = 10
p.x += 5            # p.x = 15

# Array index compound assignment
arr: Array[4, int32]
arr[2] = 3
arr[2] *= 7         # arr[2] = 21
```

Note: `/=`, `%=`, and `>>=` honour the operand / target's signedness:
signed types get `idivq` / `sarq`, unsigned types get `divq` / `shrq`.
Works uniformly on simple-identifier targets and on complex
(`arr[i]`, `obj.field`) targets.

Regression fixture: `tests/test_compiler_augmented_assign.ad` +
`scripts/test_compiler_augmented_assign.sh`.

### Walrus / assignment expression `(name := value)`

Adder supports Python's PEP 572 walrus operator for assigning a value
inside an expression. Adder is statically typed, so `name` MUST be an
already-declared local — `:=` does not introduce a new binding.

Only the parenthesised form is accepted. A bare `:=` outside parens
would shadow the statement-level `x = expr` recogniser, so the parser
only looks for it after `(` IDENT WALRUS.

```python
def drain_stream() -> int64:
    n: int64 = 0
    total: int64 = 0
    while (n := next_chunk()) > 0:
        total = total + n
    return total

def split_on_match(x: int64) -> int64:
    q: int64 = 0
    if (q := x * x) > 100:
        return q + 1
    return q - 1
```

Caveat: binary operators in Adder evaluate the RIGHT operand first
(stack-machine style). So `(n := f()) + n` reads `n` BEFORE the walrus
runs — the left side's assignment is not visible to the right side.
This differs from Python. Use the walrus on its own, or as the loop /
guard condition, where the surrounding context evaluates it just
once.

Regression fixture: `tests/test_compiler_walrus.ad` +
`scripts/test_compiler_walrus.sh`.

### Globals

A top-level `name: type = value` declares a global. With an initialiser
that's a literal, it lands in `.data`; without one (or with `0`), it
lands in `.bss`. String-literal initialisers populate
`Array[N, uint8]` globals via `.ascii` + `.zero` padding.

```python
counter: int64 = 0                   # .bss
prompt:  Array[8, uint8] = "hamsh$ " # .data, NUL-padded to length 8

def bump() -> int64:
    counter = counter + 1            # ordinary store to counter(%rip)
    return counter
```

Adder does not use Python's `global` keyword inside functions — any
unqualified name that wasn't declared as a local resolves to the
matching top-level declaration. A `global x` statement is parsed but
**rejected by the codegen** (`x86: statement GlobalStmt not yet
supported`) — just don't write one.

---

## Functions

```python
def add(a: int32, b: int32) -> int32:
    return a + b

# Void return: omit the arrow entirely
def panic_print(msg: Ptr[char]):
    printk0(msg)
```

The codegen uses SysV AMD64: integer/pointer args in
`%rdi`, `%rsi`, `%rdx`, `%rcx`, `%r8`, `%r9` for the first six; result
in `%rax`. Functions emit `endbr64` at entry (IBT-ready), frame with
`%rbp`, and never use the red zone (invalid in kernel context).

There are no default-argument values, no keyword-only parameters, no
`*args`/`**kwargs`, and no nested/closure-capturing function
definitions. Every parameter and return type must be declared. The
parser also accepts keyword arguments AT CALL SITES (`foo(a=1, b=2)`)
but the codegen rejects them with
`x86: keyword arguments not supported (<fname>)` — call positionally.

---

## Function Pointers

Adder has **first-class function pointers** as a real type. The syntax
is `Fn[R, A...]` where `R` is the return type and `A...` are the
argument types. Function pointers are typed, can be stored in globals,
passed as parameters, returned, and called indirectly. SysV AMD64
indirect-call codegen lands the call through `call *%r11`.

```python
# Declare a function-pointer type. This signature says:
# "takes (Ptr[uint8], uint64), returns int32".
on_packet: Fn[int32, Ptr[uint8], uint64]

# Assign a function with a matching signature.
def my_handler(buf: Ptr[uint8], n: uint64) -> int32:
    return cast[int32](n)

on_packet = my_handler

# Indirect-call through the function-pointer variable.
rc: int32 = on_packet(some_buf, some_len)
```

Pass them as parameters too:

```python
def register_handler(fn: Fn[int32, Ptr[uint8], uint64]):
    on_packet = fn
```

And null-check before invoking (cast `0` to the matching `Fn[…]` type):

```python
if on_packet != cast[Fn[int32, Ptr[uint8], uint64]](0):
    on_packet(buf, len)
```

Production uses include: `drivers/net/eth.ad`'s `eth_register_tx_hook`
(every NIC driver registers its TX path this way),
`kernel/sched/core.ad`'s `cleartid_wake_hook`, the IRQ handler table,
the block-device vtable, netfilter hooks, and timer callbacks. Reach
for `Fn[R, A...]` whenever you want a callback — do NOT introduce a
global mode-flag enum to dispatch on.

Regression fixture: `tests/test_compiler_fnptr.ad` +
`scripts/test_compiler_fnptr.sh`.

---

## Control Flow

### Conditionals

```python
if x > 0:
    printk0("positive\n")
elif x < 0:
    printk0("negative\n")
else:
    printk0("zero\n")

# Ternary expression
sign: int32 = 1 if x > 0 else -1
```

### Chained comparisons

Adder implements Python's chained-comparison semantics. An expression like
`a OP1 b OP2 c` means `(a OP1 b) and (b OP2 c)` — **not** `(a OP1 b) OP2 c`
(which would compare the boolean 0/1 result of the first comparison against
`c`). All six relational operators may be chained: `<`, `<=`, `>`, `>=`,
`==`, `!=`.

```python
lo: int32 = 10
x:  int32 = 15
hi: int32 = 20

if lo <= x < hi:          # True: 10 <= 15 and 15 < 20
    do_work()

# 3-way chain:
if 0 < idx < arr_len:     # idx strictly inside [1, arr_len-1]
    arr[idx] = val

# Middle operand is evaluated ONCE, even if it is a function call:
if lo <= f() < hi:        # f() is called exactly once
    ...
```

The codegen lowers an N-link chain to an AND of adjacent pairs with
short-circuit evaluation: the first false pair immediately produces 0,
skipping the remaining comparisons. Middle operands are saved in a
register across the short-circuit test so they are evaluated exactly once.

Regression fixture: `tests/test_compiler_chained_compare.ad` +
`scripts/test_compiler_chained_compare.sh`.

### Loops

```python
# While loop — test condition, then run body
while x > 0:
    x = x - 1

# Do-while loop — run body at least once, then test condition.
# Unique to Adder among Python-syntax languages; ships in the
# `do:`/`while` form (no trailing colon on the `while` line).
# Used by 9+ production sites — e.g. fs/elf.ad's PHDR walker.
do:
    x = x - 1
while x > 0
```

`break` and `continue` are supported inside `while` and `do`/`while`
bodies:

```python
i: int32 = 0
n: int32 = 0
while i < 100:
    if i == 50:
        break
    if i % 2 == 0:
        i = i + 1
        continue
    n = n + 1
    i = i + 1
```

Adder also has a **`for ... in` statement**. Two forms are lowered by
the x86_64 codegen (both compile to the same counter/index scaffold the
`while` idiom uses — no iterator-protocol or heap allocation):

```python
# Counter loop over range(). 1, 2 or 3 args, matching Python:
#   range(stop)              -> 0, 1, ..., stop-1
#   range(start, stop)       -> start, ..., stop-1
#   range(start, stop, step) -> start, start+step, ... (excl. stop)
for i in range(10):
    process(i)

for i in range(0, 100, 2):
    flags = flags | (1 << i)

# A constant negative step counts down (the compare flips to `i > stop`);
# a zero step is rejected at compile time.
for i in range(10, 0, -1):
    process(i)
```

```python
# Iterate a fixed-size array `Array[N, T]`. A hidden index walks 0..N-1
# and the loop variable is rebound to a by-value copy of each element:
xs: Array[4, int32] = [10, 20, 30, 40]
total: int32 = 0
for x in xs:
    total = total + x
```

`break` and `continue` work inside `for` bodies with Python semantics:
`continue` jumps to the induction step (so the counter/index still
advances) and `break` exits the loop. The counter variable's type
follows the surrounding annotation; `range()` is only valid as the
iterable of a `for` (there is no first-class `range` value).

The equivalent `while`-with-an-explicit-counter form remains valid and
is still used throughout the tree:

```python
i: int32 = 0
while i < n:
    process(arr[i])
    i = i + 1
```

### Match / case

Adder has a Python-style `match` statement. It evaluates the scrutinee
exactly once and dispatches to the **first matching arm** (no implicit
fallthrough).

```python
match x:
    case 0:
        printk0("zero\n")
    case 1 | 2 | 3:
        printk0("small\n")
    case n if n > 100:
        printk0("big\n")
    case [1, 2]:
        printk0("the pair 1,2\n")
    case [head, *rest]:
        printk0("non-empty\n")
    case _:
        printk0("other\n")
```

Supported patterns:

| Pattern              | Example                | Semantics                                              |
|----------------------|------------------------|--------------------------------------------------------|
| Literal              | `case 0:`, `case "x":` | matches when `scrutinee == literal` (also `True` / `False` / `None`, and a leading `-` for negative ints) |
| Wildcard             | `case _:`              | always matches; binds nothing                          |
| Name binding         | `case x:`              | always matches; binds `x` to the scrutinee in the body |
| OR                   | `case a \| b \| c:`    | matches if any alternative matches (left-to-right)     |
| Sequence             | `case [a, b]:`         | elementwise match against a `Ptr[T]` / `Array[N, T]` scrutinee; sub-patterns may be literals or name bindings |
| Sequence with rest   | `case [a, *rest]:`     | leading sub-patterns match positionally; `*rest` is permitted at any position (at most one per pattern) |
| Guard                | `case p if cond:`      | arm fires only when both pattern AND guard hold; on guard-fail, dispatch falls through to the next arm |

Each `case` body is an indented block, identical to `if`/`elif`/`else`
bodies. The match arms are required (at least one `case` per `match`);
a final `case _:` is the conventional catch-all.

**Lowering**: at codegen, `match` desugars to a chain of `if`/`elif`
tests over a single materialised scrutinee local. Literal patterns
become equality comparisons, OR patterns become short-circuit `or`s,
sequence patterns become positional `scrut[i]` comparisons, and name
patterns prepend a `VarDecl` binding at the top of the arm body.
Guards lower as a nested `if guard: <body> else: <next-arm>` inside
the arm so the bound names are visible to the guard expression.

Limitations:
* Sequence patterns rely on the caller to provide an
  appropriately-long buffer — there is no `len()` primitive, so no
  runtime length check is synthesised. The pattern's prefix length
  effectively dictates the minimum index the codegen will read.
* `*rest` is accepted but binds to the **scrutinee base pointer**, not
  a slice (Adder has no slice type yet); use it for "match the prefix
  and ignore the tail" idioms rather than for capturing the tail.
* Nested OR / sequence sub-patterns inside a sequence pattern are
  rejected by codegen with a clear error; flatten the cases instead.

Regression fixture: `tests/test_compiler_match.ad` +
`scripts/test_compiler_match.sh`.

---

## Classes (structs with optional static methods)

A `class` in Adder is a **C-ABI-compatible struct**. Fields are laid
out in declaration order, each aligned to its natural alignment
(capped at 8), and the total size is rounded up to 8 bytes. Classes
also carry **optional static methods** (no vtable, no virtual
dispatch, no RAII, no destructors — see *Static methods, auto-self,
name mangling* below) and **optional `__init__` sugar** for
stack-allocated constructors.

Single and multi-base **inheritance is supported purely as field
flattening**: `class Dog(Animal):` prepends each base class's fields
(recursively) before the child's, in declaration order. No vtable,
no virtual dispatch — `d.legs` on a `Dog(Animal)` resolves to the
same byte offset as `a.legs` on a bare `Animal`. A child that
redeclares an inherited field name is a compile error (the codegen
has no override slot to redirect to).

```python
class VmaNode:
    start:       uint64
    end:         uint64
    file_offset: uint64
    backing:     uint64
    next:        uint64
    chunks:      uint64
    prot:        int32
    flags:       int32
    file_fd:     int32
    order:       int32
    nchunks:     int32
    is_cow:      int32
```

You typically allocate a struct on the heap and operate on it through
a `Ptr[VmaNode]`. Field access through a pointer uses **`ptr[0].field`**
— the `[0]` does the explicit dereference, and `.field` then names the
field. (This is the production idiom; `kernel/list.ad`'s linked-list
operations are the canonical example.)

```python
node: Ptr[VmaNode] = cast[Ptr[VmaNode]](kmalloc(SIZEOF_VMA_NODE))
node[0].start = base
node[0].end   = base + len
node[0].flags = 0
```

To take a field's address, use `&ptr[0].field` (or compute the offset
manually).

A struct can also be embedded in an `Array[N, T]` (intrusive freelist
pools) or be a local variable (stored directly on the stack). The
compiler picks the storage based on how the variable is declared.

`container_of(ptr, Type, field)` is the inverse — see
[*`container_of`*](#container_of).

### Inheritance (flat field flattening)

```python
class Animal:
    legs: int32
    age:  int32

class Dog(Animal):
    breed: int32
```

`Dog` lays out as `legs` (offset 0), `age` (offset 4), `breed`
(offset 8) — the parent fields come first in declaration order, then
the child's own. Multiple bases (`class C(A, B):`) and multi-level
chains (`Dog(Animal)` where `Animal(Mammal)`) are flattened
recursively in left-to-right, depth-first order. There is **no
vtable, no virtual dispatch, no upcast pointer** — the inheritance is
purely a layout convenience so common headers stay in one place.
Redeclaring an inherited field name in the child is a compile error.

### Static methods, auto-self, name mangling

A class body may contain `def` methods. They MUST take `self` as
their first parameter; the parser synthesises `self: Ptr[<ClassName>]`
automatically. The compiler emits each method as a free function
named `<ClassName>__<methodName>` (double-underscore joiner), and
rewrites the call site `obj.method(args)` to a direct call against
that mangled symbol with `&obj` (or `obj`, if it's already
`Ptr[<ClassName>]`) prepended as the first argument.

```python
class Foo:
    x: int32
    y: int32

    def sum(self) -> int32:
        return self.x + self.y

# Compiles to (logically):
def Foo__sum(self: Ptr[Foo]) -> int32:
    return self[0].x + self[0].y

# Caller:
def main() -> int32:
    f: Foo
    f.x = 3
    f.y = 4
    return f.sum()    # lowered: Foo__sum(&f)
```

Inside the method body, `self.field` reads/writes through the
pointer (the codegen recognises `MemberExpr` whose base is `Ptr[T]`
and loads the pointer value before adding the field offset). This
is the same effect as the production `ptr[0].field` idiom, but
spelled with auto-deref so methods read naturally.

**Inheritance + methods.** Methods are inherited by the same
field-flattening rule, with **first-match-wins** lookup at compile
time: a child class's own methods shadow inherited ones; otherwise
the leftmost base providing a method wins. The call site lowers to
`<OwnerClass>__<method>`, where `OwnerClass` is the class that
literally declared the method. For multi-base inheritance the
receiver `&obj` is bumped by the owner-base's offset within the
derived class (Adder's pointer arithmetic is un-scaled, so this is
just `&obj + <byte offset>`).

```python
class Animal:
    legs: int32

    def kind(self) -> int32:
        return 1

    def num_legs(self) -> int32:
        return self.legs

class Dog(Animal):
    breed: int32

    def kind(self) -> int32:    # overrides Animal.kind
        return 2

def main() -> int32:
    d: Dog
    d.legs  = 4
    d.breed = 7
    return d.kind() * 10 + d.num_legs()    # 2*10 + 4 = 24
```

**`__init__` sugar.** If a class defines `def __init__(self, ...)`,
the call shape `Foo(args...)` at the right-hand side of a `VarDecl`
init OR a plain assignment is intercepted at codegen time and
lowered to `Foo__init__(&target, args...)` against a
stack-allocated local. Without `__init__`, `Foo(args)` is a compile
error (the existing `f: Foo` declaration form continues to
stack-allocate with zero-init).

```python
class Point:
    x: int32
    y: int32

    def __init__(self, a: int32, b: int32) -> None:
        self.x = a
        self.y = b

def main() -> int32:
    p: Point = Point(3, 4)        # Point__init__(&p, 3, 4)
    return p.x + p.y
```

**What's deliberately NOT here.** There is no vtable, no virtual /
overridable dispatch, no destructors, no RAII, no mixins / multiple
methods of the same name from different bases requiring MRO
disambiguation (first-match-wins is the only rule), no decorators
on methods (`@staticmethod`, `@classmethod`, `@property` all
rejected at codegen time). For polymorphism use a `Fn[R, A...]`
field — the existing `struct file_operations`-style dispatch table
pattern, e.g. in `kernel/vfs/`.

---

## Pointers and Memory

### Address-of and Dereference

```python
x: int32 = 42
ptr: Ptr[int32] = &x         # Address of local x
val: int32 = *ptr            # Dereference (returns int32)
```

### Pointer arithmetic is element-scaled (C semantics)

`Ptr[T] + N` scales by `sizeof(T)`, matching C and Rust: `ptr + 1`
advances by **`sizeof(T)` bytes**, not by 1 byte. `Ptr[T] - N` scales
the same way. The integer side is the side that gets multiplied;
codegen emits a `shlq` (or `imulq` for odd struct sizes) followed by
the `addq` / `subq`.

```python
ptr: Ptr[int32] = &x
ptr_next_elem: Ptr[int32] = ptr + 1           # +4 bytes (sizeof(int32))

q: Ptr[uint64] = ...
q_back_2:      Ptr[uint64] = q - 2            # -16 bytes (2 * sizeof(uint64))
```

**Exception — 1-byte pointees stay byte-wise.** `Ptr[uint8]`,
`Ptr[int8]`, and `Ptr[char]` use plain byte arithmetic (no scale).
This is what makes the kernel's `cast[Ptr[uint8]]` byte-offset idiom
keep working:

```python
head_p: Ptr[uint64] = cast[Ptr[uint64]](skb + 0xc8)
ts_p:   Ptr[uint32] = cast[Ptr[uint32]](skb + 0xd8)
buf:    Ptr[uint8]  = cast[Ptr[uint8]](raw)
buf_x:  Ptr[uint8]  = buf + 16                 # +16 bytes (1-byte pointee)
```

The `skb + 0xc8` form above is plain `uint64 + uint64` (NOT pointer
arithmetic — `skb` is a `uint64`), so it stays byte-wise regardless.
The scaling only applies when the static type of an operand is `Ptr[T]`
with `sizeof(T) > 1`.

`Ptr[T] - Ptr[T]` is the raw byte difference (not the element count) —
the natural lowering, and what existing kernel callers want.

### Indexing through a pointer

`ptr[i]` IS scaled by the pointee size — `gen_index_address` multiplies
the index by `element_size_of(obj)` before adding. So unlike `ptr + i`,
`ptr[i]` behaves like C:

```python
buf: Ptr[uint8] = cast[Ptr[uint8]](kmalloc(N))
buf[0] = 0xAA                # writes one byte at offset 0
buf[1] = 0xBB                # writes one byte at offset 1

words: Ptr[uint32] = cast[Ptr[uint32]](kmalloc(N))
words[1] = 0xCAFEBABE        # writes 4 bytes at byte offset 4
```

### Pointer NULL / numeric pointer

`Ptr[T]` and `uint64` are freely castable in both directions (the
production heap allocator returns a `uint64` precisely so the caller
chooses the pointee type explicitly):

```python
raw: uint64 = kmalloc(64)
buf: Ptr[uint32] = cast[Ptr[uint32]](raw)
if buf == cast[Ptr[uint32]](0):
    return -1                # -ENOMEM
```

---

## Type Casting

Adder requires casts to be explicit. The generic form is `cast[T](x)`:

```python
raw: uint32 = 0x40004000
uart: Ptr[uint32] = cast[Ptr[uint32]](raw)
n8:   uint8  = cast[uint8](n32 & 0xFF)
```

Integer ↔ integer casts are a no-op at the assembly level (everything
occupies a 64-bit slot; the compiler trusts the programmer to mask
when narrowing matters). Integer ↔ pointer casts are also a no-op
— `Ptr[T]` is just a 64-bit value.

`cast[T](x)` is the **only** form that performs a conversion. There
is no implicit promotion / coercion path.

---

## Heap Allocation

There is no `new` keyword. Heap memory comes from `mm/slab.ad`:

```python
from mm.slab import kmalloc, kfree, kzalloc

def make_pgrp() -> Ptr[Pgrp]:
    raw: uint64 = kzalloc(sizeof_Pgrp)
    if raw == 0:
        return cast[Ptr[Pgrp]](0)    # caller checks for NULL
    return cast[Ptr[Pgrp]](raw)

def drop_pgrp(p: Ptr[Pgrp]):
    if p == cast[Ptr[Pgrp]](0):
        return
    kfree(cast[uint64](p))
```

The slab allocator dispatches small (≤2 KiB) requests to per-size
slab caches and large requests through `alloc_pages`. It returns
**`uint64`** rather than `Ptr[T]` so the caller is forced to declare
which type they're allocating — there is no "void pointer" in Adder
and no implicit conversion from `uint64` to `Ptr[T]`. Use `cast[]`.

This is the idiomatic Hamnix pattern. Prefer real heap allocation;
use a fixed `Array[N, T]` pool only when you have a concrete reason
(interrupt-context alloc, OOM-must-succeed guarantee, very tight
count bound that makes the simpler pool code win).

---

## Per-CPU Storage

`Percpu[T]` declares a global whose storage is replicated per CPU.
Reads and writes go through the `%gs:offset` segment override; the
codegen handles the relocations and the `.data..percpu` section
layout.

```python
# arch/x86/kernel/setup_percpu.ad
cpu_id_pcpu: Percpu[uint64]

# arch/x86/kernel/time.ad
local_timer_ticks: Percpu[uint64]

def on_timer_tick():
    local_timer_ticks = local_timer_ticks + 1   # %gs:offset read+write
```

Each per-CPU global gets one slot per CPU in `.data..percpu`; the
`%gs` base is set up per CPU at boot in `setup_percpu_asm.S`. Reading
or writing a `Percpu[T]` global from inside an Adder function emits
the `%gs:`-prefixed `movq`/`movl`/etc. directly — no helper call,
no relocation surprises.

Both scalar `Percpu[T]` and aggregate Percpu globals
(`Percpu[Array[N, T]]`, `Percpu[SomeStruct]`) lower to `%gs:`-prefixed
loads/stores:

```python
# Scalar — direct load/store.
cpu_id_pcpu: Percpu[uint64]
def whoami() -> uint64:
    return cpu_id_pcpu               # movq %gs:offset, %rax

# Aggregate array — indexed load/store. The element size sets the
# scale and the load/store mnemonic.
hist: Percpu[Array[8, uint32]]
def bump(slot: uint64):
    v: uint32 = hist[slot]           # movl %gs:disp(%rcx), %eax
    hist[slot] = v + 1               # movl %eax, %gs:disp(%rcx)

# Aggregate struct — member load/store, literal disp.
class Counters:
    hits:   uint64
    misses: uint32
    flag:   uint8

stats: Percpu[Counters]
def on_hit():
    stats.hits = stats.hits + 1      # movq %gs:disp, %rax / movq %rax, %gs:disp
```

`T` (or each scalar field) must be a 1/2/4/8-byte type — there is no
multi-register Percpu transfer. Sub-aggregate fields of struct type
(`Percpu[Outer]` where `Outer.inner: SomeStruct`) and array-typed
struct fields are intentionally not supported; flatten the layout or
use a separate Percpu global.

**Taking the address of a Percpu global is rejected at codegen.**
`&percpu_x`, `&percpu_arr[i]`, and `&percpu_struct.field` would need a
`%gs`-relative `leaq` which x86 cannot express in a single
instruction; the codegen raises an explicit error rather than emitting
a flat `leaq buf(%rip)` that would silently drop the per-CPU base.
Read/write the value (or the indexed/member-accessed slot) directly
instead.

---

## Hardware Intrinsics

The x86_64 backend recognises a small set of names as **inline
intrinsics** — calls that lower to bare machine instructions instead
of a `call`. Anything not on this list is an ordinary function call.

### Port I/O

The x86 `in`/`out` instructions, for talking to legacy ISA-style
hardware (PIC, PIT, serial UART, CMOS, ...). Each is emitted inline —
there is no exported symbol behind them.

```python
outb(value, port)             # 8-bit  write   (out  %al,  %dx)
v8:  uint8  = inb(port)       # 8-bit  read    (in   %dx,  %al)
outw(value, port)             # 16-bit write   (out  %ax,  %dx)
v16: uint16 = inw(port)       # 16-bit read    (in   %dx,  %ax)
outl(value, port)             # 32-bit write   (out  %eax, %dx)
v32: uint32 = inl(port)       # 32-bit read    (in   %dx,  %eax)
```

Example (from `arch/x86/kernel/time.ad`, programming the PIT):

```python
outb(PIT_CMD_CH0_LOHI_MODE3, PIT_CMD)
outb(div_lo, PIT_CHANNEL0_DATA)
outb(div_hi, PIT_CHANNEL0_DATA)
```

### `asm_volatile` — single inline instruction

For everything else — `cli`/`sti`, `hlt`, `pause`, `mfence`,
control-register pokes — use `asm_volatile`, which emits the string
literal verbatim into `.text`. It takes exactly one **string-literal**
argument and has no operand-substitution: it is for zero-operand (or
fully self-contained) instructions only.

```python
asm_volatile("cli")           # disable interrupts
asm_volatile("hlt")           # halt the CPU until the next interrupt
asm_volatile("pause")         # spin-loop hint
asm_volatile("mfence")        # full memory fence
```

A memory **barrier** on x86_64 is just the matching fence instruction
via `asm_volatile` (`mfence` / `lfence` / `sfence`); there are no
`dmb`/`dsb`/`isb` builtins (those were ARM mnemonics). There are no
`atomic_*` builtins and no `LDREX`/`STREX` — x86 atomicity is
achieved with `lock`-prefixed instructions emitted through
`asm_volatile`, or by calling into the kernel's own helpers.

A multi-line string passed to `asm_volatile` is emitted line by line
(each non-blank line is one instruction), but for any non-trivial
assembly the kernel keeps a hand-written `.S` file and reaches it via
`extern def` — see *Inline Assembly* below — that is the preferred
pattern.

---

## Inline Assembly

There is no `asm("...")` expression form on the x86_64 backend: the
parser accepts `asm("nop")` as an expression but the codegen rejects
it with `x86: expression AsmExpr not yet supported`. Two mechanisms
cover assembly-level code:

### 1. `asm_volatile` for a single instruction

See *Hardware Intrinsics* above — best for one self-contained
instruction (`cli`, `hlt`, `mfence`, ...).

### 2. A `.S` file reached via `extern def`

Anything that needs multiple instructions, labels, register operands,
or a defined calling convention lives in a hand-written `.S` file
assembled alongside the Adder output, and is declared in Adder as an
`extern def`. This is how the kernel does context switches, trap
stubs, and EFI-handoff glue.

```python
# kernel/sched/core.ad — the routine is defined in a .S file
extern def __switch_to_asm(prev: Ptr[uint8], next: Ptr[uint8])

def context_switch(prev: int32, next: int32):
    __switch_to_asm(cast[Ptr[uint8]](&task_table[prev]),
                    cast[Ptr[uint8]](&task_table[next]))
```

The assembler routine (`arch/x86/kernel/*.S`) follows the System V
AMD64 calling convention — arguments arrive in `%rdi`, `%rsi`, `%rdx`,
`%rcx`, `%r8`, `%r9` and the result is returned in `%rax`.

---

## External Functions

Declare functions implemented in another `.ad` file, in a hand-written
`.S` file, or in C (kernel-module targets) with `extern def`:

```python
extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64
extern def sys_exit(code: int32)
extern def memset(dst: Ptr[uint8], val: int32, n: uint64) -> Ptr[uint8]
```

`extern def` emits `.extern <name>` in the generated assembly; the
caller's `call <name>` is resolved by the linker.

---

## Import System

```python
from lib.io import print_str, print_int
from mm.slab import kmalloc, kfree, kzalloc
from kernel.list import ListHead, list_add, list_del
```

Imports are a **flat module merge**: the named symbols are looked up
in the imported module's compile output and resolved as if they had
been declared locally. There is no module-qualified access (no
`lib.io.print_str(...)` after `from lib.io import print_str` — and no
`import lib.io` form that would create such a qualified name).

`from M import X as Y` (rename-on-import) is parsed but **the alias
is lost** — the codegen still expects the original name `X` at use
sites, so writing `Y(...)` fails with `x86: unknown identifier 'Y'`.
Just import `X` under its real name.

### Module-private symbols (leading underscore)

Top-level visibility is by **convention on the symbol name**:

- A top-level name **without** a leading underscore (`kmalloc`,
  `eth_register_tx_hook`, ...) is PUBLIC — it lives in the single
  global symbol namespace. Two modules defining the same PUBLIC name
  is a **hard error** at merge time: `compiler/adder.py`'s
  `merge_programs` prints `Error: duplicate top-level definition '<name>'`
  and exits with status 1. (The exception is `extern def` of the same
  name in multiple modules — those are forward references, so silent
  dedup is harmless.) Rename one of them.
- A top-level name **with** a leading underscore (`_helper`,
  `_emit_str`, ...) is MODULE-PRIVATE — the merger mangles it to
  `<module_slug>__<name>` so each module's `_helper` is a distinct
  symbol. Intra-module references are rewritten to the mangled
  spelling.
- An `import` is itself the export marker. If any other module does
  `from M import _name`, then `_name` is promoted to PUBLIC and
  left un-mangled. Today's cross-module underscore symbols include
  `_add_export`, `__stack_chk_fail/guard/init`, and `_u_errstr`.
  A name promoted to public this way is again subject to the
  duplicate-definition rule above — only one module may define it.
- `extern def` names are never mangled — they refer to real external
  symbols.

Regression fixture: `scripts/test_compiler_module_private.sh`.

---

## `container_of`

`container_of(ptr, Type, field)` is a compile-time expression: given
a pointer to a struct field, it returns a pointer to the enclosing
struct. The codegen resolves the field's byte offset within `Type` at
compile time and emits a single `subq $offset, %rax`.

```python
# Generic intrusive-list pattern.
class Task:
    pid:  int32
    pad:  int32
    link: ListHead              # embedded list node

def task_from_link(p: Ptr[ListHead]) -> Ptr[Task]:
    return container_of(p, Task, link)
```

`Type` and `field` must be plain identifiers (not expressions); the
expression has to be syntactically recognisable as the
`container_of(ptr, T, f)` shape.

---

## Target Selection

Three sub-targets via `python3 -m compiler.adder compile --target=<X>`:

- **`x86_64-bare-metal`** — links into the multiboot1 kernel image at
  `build/hamnix-kernel.elf`. Used for everything under `arch/`, `mm/`,
  `kernel/`, `drivers/`, `fs/`, `sys/`, `init/main.ad`. No red zone,
  ENDBR64 for IBT, RIP-relative `.rodata`, 16-byte stack alignment.
- **`x86_64-adder-user`** — CPL-3 userland ELFs (`user/*.ad`,
  `tests/test_*.ad`). Calls into the native syscall ABI documented in
  `docs/native-api.md`. SysV AMD64 ABI, static binaries, runtime in
  `user/runtime.S`.
- **`x86_64-linux-kernel-module`** — emits a `.S` file the stock Linux
  kbuild system compiles into a regulation `.ko` (M1..M15 regression
  baseline; the `kernel-modules/` tree).

Common to all three: SysV AMD64 calling convention
(`rdi/rsi/rdx/rcx/r8/r9` for first six args, `rax` for return).

---

## Example: complete program (production-style)

```python
# Heap-allocated growable byte buffer, in the production style:
# kmalloc returns uint64, every cast is explicit, no methods, error
# codes flow back as int32 returns, no exceptions.

from mm.slab import kmalloc, kzalloc, kfree

class ByteBuf:
    data:     uint64             # cast to Ptr[uint8] at use site
    capacity: uint64
    length:   uint64

SIZEOF_BYTEBUF: uint64 = 24

def bytebuf_alloc(cap: uint64) -> Ptr[ByteBuf]:
    bb_raw: uint64 = kzalloc(SIZEOF_BYTEBUF)
    if bb_raw == 0:
        return cast[Ptr[ByteBuf]](0)
    data_raw: uint64 = kmalloc(cap)
    if data_raw == 0:
        kfree(bb_raw)
        return cast[Ptr[ByteBuf]](0)
    bb: Ptr[ByteBuf] = cast[Ptr[ByteBuf]](bb_raw)
    bb[0].data     = data_raw
    bb[0].capacity = cap
    bb[0].length   = 0
    return bb

def bytebuf_push(bb: Ptr[ByteBuf], b: uint8) -> int32:
    if bb[0].length >= bb[0].capacity:
        return -28               # -ENOSPC
    p: Ptr[uint8] = cast[Ptr[uint8]](bb[0].data)
    p[bb[0].length] = b
    bb[0].length = bb[0].length + 1
    return 0

def bytebuf_free(bb: Ptr[ByteBuf]):
    if bb == cast[Ptr[ByteBuf]](0):
        return
    kfree(bb[0].data)
    kfree(cast[uint64](bb))
```

---

## Compile-time builtins

These are **pure compile-time** operations: they expand to an immediate
constant or a short inline sequence with no hidden heap allocation and no
hidden control flow. They are intercepted by the codegen before the normal
call path, so no user-visible `def` is needed in any library.

### `sizeof(T)` — type size constant

```python
n: uint64 = sizeof(int32)           # 4
m: uint64 = sizeof(Array[8, uint8]) # 8
s: uint64 = sizeof(MyStruct)        # ABI layout size of the struct

# Use in pointer arithmetic / allocation sizing
buf_raw: uint64 = kmalloc(sizeof(Entry) * count)
```

`sizeof(T)` folds to `movq $N, %rax` — a compile-time constant. Supported
for all scalar types, `Ptr[T]` (always 8), `Array[N, T]` (N × sizeof(T)),
and struct/class types (ABI layout size). Previously you had to hand-roll
`SIZEOF_FOO: uint64 = N` module constants; `sizeof` replaces them.

Regression fixture: `tests/test_compiler_sizeof.ad` +
`scripts/test_compiler_sizeof.sh`.

### `min(a, b)` / `max(a, b)` — inline integer extremum

```python
lo: int32 = min(x, y)   # smaller of x, y
hi: int32 = max(x, y)   # larger of x, y
```

Lowered to `cmpq %rcx, %rax` + `cmovg/cmovl %rcx, %rax` — one compare
and one conditional move. No branch, no call, no heap. Works for any
integer type; uses signed comparison (same default as `<`/`>`).

These are only intercepted when `min`/`max` are NOT shadowed by a
user-defined function or local variable — existing code that defines its
own `imin`, `imax`, etc. is unaffected.

### `abs(x)` — inline absolute value

```python
distance: int64 = abs(delta)
```

Lowered to `negq %rax` + `testq + cmovns` — no branch, no call, no heap.
Works for signed integer types. For unsigned integers `abs` is a no-op
(the value is already non-negative), but the codegen still emits the
branchless form harmlessly.

Regression fixture: `tests/test_compiler_minmax_abs.ad` +
`scripts/test_compiler_minmax_abs.sh`.

### `strlen(s)` — inline NUL-terminated string length

```python
n: uint64 = strlen(s)    # s is Ptr[uint8] or Ptr[char]
```

Returns the number of bytes before the first NUL terminator — the same
semantics as C's `strlen`. Lowered inline via `repne scasb` (x86's
"scan string" instruction), which is approximately:

```asm
movq %rax, %rdi    ; rdi = pointer
xorq %rcx, %rcx
notq %rcx          ; rcx = max scan count (0xffffffff...)
xorb %al, %al      ; al = NUL byte to search for
cld
repne scasb        ; scan forward, decrement rcx each byte
notq %rcx
decq %rcx          ; rcx = bytes before NUL = length
movq %rcx, %rax
```

No call, no heap, no loop labels. Registers clobbered: `%rdi`, `%rcx`,
`%al` (all caller-saved in SysV AMD64).

**Why it matters.** Before this builtin, every file that needed a string
length had to copy-paste an identical 3-line `while s[n] != 0: n += 1`
loop under a private name (`strlen_u8`, `cstr_len`, `_slen`, …). More
than 30 production `.ad` files carry that duplicate. Now they can call
the builtin directly and delete the copy.

As with `min`/`max`/`abs`: if you define your own `def strlen(...)` in
the same compilation unit, the user-defined version takes precedence and
the builtin is not intercepted. This lets existing code that already
defines a private `strlen` keep working unmodified — the upgrade path
is to delete the local definition and rely on the builtin.

Regression fixture: `tests/test_compiler_strlen_clamp.ad` +
`scripts/test_compiler_strlen_clamp.sh`.

### `clamp(x, lo, hi)` — inline range clamp

```python
safe: int32 = clamp(raw_val, 0, 255)   # ensure 0 ≤ safe ≤ 255
```

Returns `lo` if `x < lo`, `hi` if `x > hi`, otherwise `x`. Equivalent
to `min(max(x, lo), hi)` but computed in a single 6-instruction inline
sequence using signed comparisons:

```asm
<eval hi> → push
<eval lo> → push
<eval x>  → rax
popq %rcx          ; rcx = lo
cmpq %rcx, %rax    ; x vs lo
cmovl %rcx, %rax   ; if x < lo: rax = lo
popq %rcx          ; rcx = hi
cmpq %rcx, %rax    ; result vs hi
cmovg %rcx, %rax   ; if result > hi: rax = hi
```

No call, no branch, no heap. Works for any integer type; uses signed
comparison (same convention as `<`/`>`).

Same shadowing rule as all other builtins: a user-defined `def clamp`
takes precedence if it appears in the same compilation unit.

Regression fixture: `tests/test_compiler_strlen_clamp.ad` +
`scripts/test_compiler_strlen_clamp.sh`.

---

## Features deliberately not in Adder

These show up in Python and are intentionally absent from Adder. If
an agent tries to write code using one of them, the parser may accept
it (the AST node exists) but the **codegen will reject it with a
`CodeGenError` citing the source location** — that's by design.
`scripts/test_compiler_unsupported_rejected.sh` guards each one.

A subset is guarded by `scripts/test_compiler_unsupported_rejected.sh`,
which compiles a one-liner per feature and verifies the codegen
rejects it.

| Feature | Status | Use instead |
|---|---|---|
| Tuple-unpacking assignment (`a, b = b, a`) | Codegen rejects `TupleUnpackAssign`. | Use a temporary: `tmp = a; a = b; b = tmp`. |
| `global x` / `nonlocal x` statements | Codegen rejects `GlobalStmt`. Not needed anyway — bare names that aren't locals resolve to globals automatically. | Write `counter = counter + 1` without a `global` declaration. |
| `is` / `is not` operators | Codegen rejects with `binary op BinOp.IS not yet supported` / `BinOp.IS_NOT not yet supported`. | `==` / `!=`. |
| `in` / `not in` operators (membership test) | Parser accepts inside `for ... in`; the binary-op form rejects (codegen errors with `binary op BinOp.IN not yet supported` / `BinOp.NOT_IN not yet supported`). | Walk the container by index and compare. |
| `List[T]`, `Dict[K, V]`, `Tuple[A, B]`, `Optional[T]` types | Imply hidden heap. Adder has no general-purpose dynamic container. Each is rejected explicitly at the source location citing the offending var/param/field (commit 25e6657). | `Array[N, T]` for fixed pools; `Ptr[T]` + `kmalloc` for growable storage. |
| Dict literals `{1: 10}` and dict indexing | No `Dict` type. | A flat `Array[N, KV]` of `class KV { key, value }` plus a linear scan; or a slab-backed hash table built in `.ad`. |
| List literals / list comprehensions (`[x*2 for x in r]`) | Codegen rejects `ListLiteral` / `ListComprehension`. | Write the `while` loop explicitly into an `Array[N, T]`. |
| Lambdas / closures | Closures would need a captured environment (a hidden heap object). Codegen rejects `LambdaExpr`. | A named `def` plus a `Fn[R, A...]` typed callback. |
| F-strings `f"x={x}"` | Each `f"..."` would need a per-call format buffer. Codegen rejects `FStringExpr`. | `printk1(fmt, x)` / `printk2(fmt, x, y)` family in `kernel/printk/printk.ad` (kernel-side), or `snprintf`-style formatting helpers in `linux_abi/api_strings.ad` (userland). |
| String slicing `s[2:5]` | Either it returns a new string (hidden alloc) or a (ptr, len) slice value (a new type with no production users). | Walk the bytes by index; pass `(Ptr[char], length)` pairs. |
| `try`/`except`/`raise`/`finally` | Exceptions break flow control, hide failure modes, don't compose with interrupt context. The hamsh shell language has them — Adder does not. | Return `int32` error codes (`-EINVAL`, `-ENOMEM`, `-ENOENT`, ...) — the Linux/Plan-9 convention. |
| `with X as y:` context managers | RAII-ish but adds non-obvious cleanup paths. | Explicit cleanup before each return; or a single `defer`-style "goto fail" tail. |
| `match`/`case` statements | The parser accepts the syntax, but codegen does not implement it. No production site uses it. | A chained `if`/`elif`. For wide dispatch on enum/syscall numbers, an `Array[N, Fn[...]]` jump table indexed by the value. |
| Virtual / overridable method dispatch (vtables) | Class methods exist (see *Static methods, auto-self, name mangling*) but they are STATIC — resolved at compile time to a `<Class>__<method>` symbol with first-match-wins shadowing. There is no vtable, no per-instance dispatch pointer, no runtime overrides. | Use a `Fn[R, A...]`-typed field on the class as a manual dispatch slot (the `struct file_operations` pattern). Fill it in at construction; call as `obj.handler(...)` lowered through the function-pointer indirect-call path. |
| Destructors / RAII | No automatic cleanup at scope exit; no `def __del__`. Resource lifetime is explicit. | Match every `kmalloc` with an explicit `kfree`; structure error paths around a single trailing cleanup block (the `goto fail;` C idiom — Adder spells it as a flat list of releases before each return). |
| Decorators on `def` / `class` (`@inline`, `@packed`, ...) | The codegen does not implement any decorator semantics. Rejected at codegen time with an actionable error (commit 25e6657: used to be silently dropped). | Define the class fields in the order and size you want; the codegen lays them out C-ABI style. For `@inline`-style hints there's no replacement — the compiler decides. |
| `union` declarations | Parser accepts; codegen rejects at the source location with `x86: top-level UnionDef not yet supported`. Zero production usage. | Type-pun through a `Ptr[T]` cast: `cast[Ptr[uint32]](&u8_array[0])[0]`. |
| Tuple literals / tuple types as values | `Tuple[A, B]` is not a real codegen type. | Return values by writing through caller-supplied `Ptr[T]` out-parameters, or pack into a struct. |
| `print()`, `len()`, `input()`, `ord()`, `chr()` | Not wired up as builtins. | `printk0`/`printk1`/... family for printing. For NUL-terminated string lengths use `strlen(s)` (see *Compile-time builtins*). |
| `sizeof(T)` | **IMPLEMENTED** — folds to a compile-time constant (`movq $N, %rax`). No runtime call, no heap. | `sizeof(int32)` → 4, `sizeof(Array[8, uint8])` → 8, `sizeof(MyStruct)` → ABI layout size. See *Compile-time builtins* below. |
| `min(a, b)` / `max(a, b)` | **IMPLEMENTED** — lowered inline to `cmpq` + `cmovg/cmovl`. No branch, no call, no heap. | Returns the smaller / larger of two integer values. See *Compile-time builtins* below. |
| `abs(x)` | **IMPLEMENTED** — lowered inline to `negq` + `cmovns`. No branch, no call, no heap. | Returns the absolute value of an integer. See *Compile-time builtins* below. |
| `strlen(s)` | **IMPLEMENTED** — lowered inline to `repne scasb`. No call, no heap, no loop labels. | Returns the length of a NUL-terminated `Ptr[uint8]` / `Ptr[char]` string. See *Compile-time builtins* below. |
| `clamp(x, lo, hi)` | **IMPLEMENTED** — lowered inline to two `cmpq` + `cmovl`/`cmovg` pairs. No call, no branch, no heap. | Constrains `x` to the range `[lo, hi]`. See *Compile-time builtins* below. |
| Default-valued parameters `def f(x=0)` | Rejected at codegen time with an actionable error (commit 25e6657: parser used to accept the default but the call site emitted with %esi holding garbage). | Pass the default explicitly at each call site, or use overload-by-name (`alloc_default()` vs `alloc_sized(n)`). |
| `assert`, `defer`, `yield` | Reserved keywords in the lexer; no production usage; codegen does not implement them. | Manual checks; explicit cleanup; iterative state machines. |
| `volatile T` type modifier | Parsed but unused in codegen. | Read MMIO through `Ptr[T]` with barriers via `asm_volatile`. |
| `from M import X as Y` (rename-on-import) | Parser accepts; alias silently lost and only `X` resolves. | Import under the real name: `from M import X`. |
| `import lib.X as Y` and `lib.X.symbol` qualified access | Adder's import is a flat merge — see *Import System*. | `from lib.X import symbol`; rename on collision. |
| Struct-init brace syntax `Point{x=10, y=20}` | Parser accepts; codegen rejects with `x86: expression StructInitExpr not yet supported`. | Allocate on stack/heap, then field-assign each member: `p: Point` then `p.x = 10; p.y = 20`. |
| `asm("instr")` expression form | Parser accepts; codegen rejects with `x86: expression AsmExpr not yet supported`. | Use `asm_volatile("instr")` as a statement — see *Hardware Intrinsics*. |
| `None` as an expression value | Parser produces `NoneLiteral`; codegen rejects with `x86: expression NoneLiteral not yet supported`. Note that `None` IS legal as the void return type in a `Fn[None, ...]` signature. | Use a typed null pointer: `cast[Ptr[T]](0)`. |
| Keyword arguments at call sites `foo(a=1, b=2)` | Parser accepts; codegen rejects with `x86: keyword arguments not supported (<fname>)`. | Call positionally: `foo(1, 2)`. |

If you find yourself reaching for any of these, the answer is almost
always to (a) write the loop / cleanup / error-code path explicitly,
or (b) extend the language at the compiler layer (after talking to
the rest of the team — `feedback_compiler_quirks.md` is the trail of
how those calls have gone historically).
