# hamsh — language and shell reference

**Status:** reference documentation for hamsh as shipped. The shell is built,
matured, and runs as PID 1 init (see `/etc/rc.boot`). Phase D (chan layer,
`namec`, `Mnt`/`mountrpc`, per-Pgrp namespaces, 9P over srvfd) is the
substrate it rides on.

**Thesis:** the shell is the linchpin that gives the whole system gravity toward
Plan 9. The kernel *has* the model; the shell is what makes that model the path
of least resistance. hamsh is the UI for Phase D.

hamsh is a clean-sheet design derived from Hamnix's actual use cases. The
*syntax* is Python-flavored with C-style `{ }` blocks — familiar, not novel —
but the *semantics* are not inherited from bash/sh/rc, and the shell is **not
Adder**: hamsh has its own grammar, its own dynamically-typed value model, and
its own tree-walking evaluator.

---

## 0. The one idea everything reduces to

**A named channel in a scoped namespace.** Stdio, pipes, redirects, dup, binds,
and mounts are all the *same* operation — *bind a `Chan` at a name in a `Pgrp`* —
wearing different syntax. Implementers should feel the VFS surface shrink, not
grow: one primitive, many skins. If a feature in this spec seems to need a new
mechanism, it's probably mis-built — check whether it's "a Chan at a name" first.

---

## 1. Use cases (the design driver — in priority order)

1. Interactive command invocation (the 90% case).
2. Pipelines.
3. Running unmodified Linux ELF binaries with exact argv/env.
4. **Namespace + 9P composition** — bind/mount/import/rfork; assembling a
   process's view of the world. *This is the differentiator no other shell
   serves; it gets the design's novelty budget.*
5. Init/rc scripting and automation.

Every rule below traces to one of these. Ergonomics for #1 and correctness for
#3 are hard constraints.

---

## 2. One language, deterministic statement dispatch

hamsh is **one language** — a clean-sheet shell with a **Python-flavored
syntax** (`def`, `if`/`elif`/`else`, `for … in`, `while`, `try`/`except`,
lists, dicts) using **C-style `{ }` blocks** instead of significant
indentation. It is **not Adder** — it shares no grammar, type system, or
evaluator with Adder. Values are **dynamically typed** and run through hamsh's
own small tree-walking evaluator (§3); there is no compile step and no separate
"expression mode."

A single grammar covers everything. What differs is the **kind of statement**,
decided **deterministically** from a top-level line's first token — never by a
heuristic:

1. a **control construct** if the first token is a statement-starting reserved
   keyword (`if while for def return break continue try ns enter spawn`);
2. else an **assignment** if the line matches
   `IDENT ( = | += | -= | … ) …` at the top level;
3. else a **command** — the first token is the command word, the rest are
   arguments, and **bare words are literal strings**.

This dispatch is the one load-bearing rule: it is what lets `ls -la /dev` run a
command with string arguments while `x = 8080` is an assignment — inside one
language. It must stay boring and predictable: **no xonsh-style auto-detection
of "is this line a subprocess or code."**

In a command statement, computed values reach the argument list only through
explicit **interpolation** — `$name` for a variable, `${ expr }` for an
expression, `` `{ … }`` for command substitution (§8). Everywhere else
(assignment right-hand sides, control-construct conditions, function bodies)
you are simply writing hamsh expressions in the one grammar.

`elif`, `else`, and `except` are reserved continuation keywords.

---

## 3. Values & variables

Variables hold **typed hamsh values**: string, int, bool, list, dict, **set**
(§8d), and **handles** (see §14). Values are **dynamically typed** and evaluated by
hamsh's own small tree-walking evaluator — no compile step, no shared
implementation with Adder. Not "everything is a string."

```
host  = "10.0.2.15"      # string
port  = 8080             # int
args  = ["-la", "/dev"]  # list
```

- Assignment: `name = expr`. Type is inferred. No `var`/`let` required.
- Integer operators: `+ - * / // % **` and the bitwise set `& | ^ ~`
  (`/` is Python-3 true division, so `7 / 2` is `3.5`). Operators must be
  **spaced**: `-` is a legal bare-word character, so `n-1` is one word, not
  a subtraction (§16a explains the error you get).
- Interpolation in command position: `$name`.
- Expression interpolation in command position: `${ expr }`.
- **List interpolation rule (kills word-splitting):** when a list value
  interpolates into command position, **each element becomes exactly one
  argument.** No re-splitting, ever. `ls $args` → `ls` `-la` `/dev`. This makes
  the entire bash word-splitting bug class structurally impossible.

**Environment = the `/env` namespace.** Exported variables are files
under `/env`; children inherit them through the namespace, not
through a separate "environment" concept. `$PATH` reads `/env/PATH`.
Exporting a shell value writes its string form into `/env/NAME`.
(The current implementation mirrors env in hamsh's own value table
and pipes it into a child's argv/envp staging — a dedicated kernel
`#e` env-device is the planned shape but is not in the tree yet.)

> **Scoping across namespace boundaries** (`ns` / `enter` / `spawn`) follows one
> rule: **values cross, resolution is namespace-local.** This is the part most
> likely to surprise — read §13 before implementing those constructs.

---

## 4. Words, quoting, globbing

- A bare unquoted word in command position is a **literal string**.
- Quoting (`"…"`, `'…'`) is needed only for whitespace/metacharacters. Double
  quotes interpolate `$`/`${ }`; single quotes are literal.
- **Globbing is the ONLY implicit expansion.** An unquoted command-position word
  containing glob metacharacters (`* ? [ ]`) is expanded against the *current
  namespace*. Quoted words never glob. There is no implicit splitting, no
  implicit brace/tilde soup — globbing is the single exception, justified by
  interactive ergonomics (#1).

---

## 5. Blocks & control flow

**Two fully-interchangeable block syntaxes; pick per block, mix freely.** Every
block-structured construct (`if`/`elif`/`else`, `while`, `for`, `def`,
`try`/`except`, `ns`, `enter`, `spawn`) accepts EITHER form, chosen from the
token that opens its body:

- **Brace** — `HEADER { statements }`. Paste-robust and REPL-friendly (the parser
  knows a block is incomplete until the closing `}`). This is the preferred form
  for interactive one-liners.
- **Colon / significant-indentation** — `HEADER:` + newline + an indented body,
  Python-style. The preferred form for static script *files*. A single-statement
  inline `HEADER: statement` is also allowed (`if $x > 3: echo big`).

No per-construct terminator zoo (`fi`/`done`/`esac` are banned). The two forms
are decided **per block**, so a script may use indentation for its top-level
structure and braces for inline one-liners (or vice-versa) — the following three
programs are identical:

```
# brace                          # indentation                 # mixed
if $x > 3 {                      if $x > 3:                     if $x > 3:
    echo big                         echo big                      echo big
} else {                         else:                          else { echo small }
    echo small                       echo small
}

for f in $files {                for f in $files:               def deploy(target):
    process $f                       process $f                     stage $target
}                                                                   push $target

def deploy(target) {             def deploy(target):
    ...                              ...
}
```

Functions: `def name(params) { body }` or `def name(params):` + indented body.
Functions run in the ambient namespace (§9) unless wrapped in `ns { }` /
`enter` / `spawn`.

**Lexing.** Indentation is tracked by the lexer: it emits an `INDENT` token when
a logical line's leading column exceeds the enclosing level and one `DEDENT` per
level closed when it falls below. A colon-suite parses its body between a matched
`INDENT`…`DEDENT`; a brace block and the top level treat a stray `INDENT`/`DEDENT`
as an ignorable separator (which is what lets the two forms nest inside each
other). `INDENT`/`DEDENT` are suppressed inside `( )` / `[ ]` so a bracketed
expression may wrap across lines. Blank and comment-only lines carry no
indentation. Interactively, a header ending in `:` switches the read loop into
indentation mode: it keeps reading (continuation prompt) until a blank line,
mirroring the Python REPL.

`{ }` serves both blocks and dict/set literals; the two never collide because
they occur in different positions — a `{` opening a statement body (after a
control header, `def`, or `ns`/`enter`/`spawn`) is a block; a `{` in expression
position is a dict or **set** literal (a first element followed by `:` is a
dict, otherwise a set — see §8d). The parser disambiguates by position, exactly
as every C-family language with map literals does.

**Parse errors carry a line number** — `hamsh: parse error [line N]: …` — so a
syntax error in a sourced multi-line script points at the offending line.

---

## 6. Pipes are channels

A pipe is a `Chan`, not a special kernel byte-buffer. **Two payload modes, chosen
by the ends, not by syntax:**

```
ls | grep ad             # external → external: BYTE channel (mandatory; talks to ELF binaries)
ps | where cpu > 50      # native → native: VALUE channel (structured records flow)
ps | to json | curl …    # value → external: serialize at the boundary
cat f | lines | len      # external → value: bytes become a list of lines
```

- **Bytes are the default** (use case #3 dominates). Structured value streams are
  an opt-in overlay between shell-native producers/consumers and **degrade to
  their text rendering the instant a byte-only program is on either end.**
- Crossing the byte/value boundary is **explicit** via converters: `to json`,
  `from csv`, `lines`, etc. Do not auto-guess.
- **CRITICAL performance rule:** "pipes are 9P" means "pipes are *Chans*." 9P
  messages go on the wire **only across a mount boundary**. A local pipe MUST be
  direct Chan reads (the `devtab`-direct path), never `Tread`/`Rread` per block.
  If `cat big | grep` marshals 9P locally, it is mis-built. Reuse the exact
  `devtab`-vs-`mountrpc` split from Phase D.
- **Do NOT build a full nushell-style table engine.** Bytes-first; structure is a
  light overlay. Data-wrangling is not a top-5 use case.

---

## 7. Stdio as named channels; redirect & dup collapse into bind

A process's standard streams are **names in its namespace**: `/fd/0`, `/fd/1`,
`/fd/2` (the `#d` fd device, mounted at `/fd`). Pipe, redirect, and dup are all
**one operation — bind a Chan at an fd-name:**

```
a | b          # bind a's /fd/1 channel as b's /fd/0
cmd > file     # bind file's channel as cmd's /fd/1
cmd 2>&1       # bind /fd/1's channel also at /fd/2
```

There is no separate pipe mechanism, redirect mechanism, and dup mechanism —
there is one bind over channels.

**Linux-ABI mapping:** the shim must map Linux integer fds 0/1/2/N onto the
`/fd/N` named channels. This is Layer-2 translation work, consistent with the
"route the Linux ABI through the chan layer" item — real shim work, not free.

**`--no-echo` (front-end local echo).** A leading `--no-echo` argv flag turns
off the interactive line editor's per-keystroke echo: the in-line repaint, the
Enter CRLF, and the readline redraw are all suppressed, while the prompt and
command OUTPUT still emit normally. This is for a front-end that does its own
LOCAL line editing + echo over a pipe — the scene DE terminal
(`user/hamtermscene.ad`, spawned as `/bin/hamsh --no-echo /etc/rc.de-user`)
paints typed characters into its glyph grid immediately, so a shell echo
coming back over stdout would double every character. The flag is consumed
before rc dispatch and shifts the remaining argv (rc path, DE-prog) past it.
The serial console and SSH clients never pass it, so they keep the default
echoing editor (a remote terminal relies on the shell to echo). See
`docs/de_scene_file_arch.md` §11a.

---

## 8. Command substitution

```
out   = `{ cat /etc/hostname }       # captures stdout as a string
files = `{ ls *.ad } | lines         # → list of lines via explicit converter
```

`` `{ … }`` runs a command and captures its stdout as a **string** by default;
use `lines` (or another converter) for structured forms. No implicit splitting.

`$(cmd)` is accepted as an **alias** for `` `{cmd} `` — identical token,
identical capture — so bash muscle memory works. Likewise `$?` is an alias for
`$status` (§16). Both were parse errors before; nothing else changes.

### 8a. Built-in expression functions

Call-position builtins usable anywhere an expression is (`${ … }`, assignment
RHS, `if`/`while` conditions):

| function | result |
|---|---|
| `len(x)` | length of a string or list |
| `int(x)` / `str(x)` | type conversion |
| `lines(s)` | split a string on `\n` into a list |
| `upper(s)` / `lower(s)` | ASCII case fold |
| `strip(s)` | drop surrounding whitespace |
| `split(s, sep)` | list of substrings between each `sep` |
| `join(list, sep)` | concatenate a list's elements with `sep` |
| `replace(s, old, new)` | replace every occurrence of `old` |
| `ord(s)` | integer code of the first byte of `s` |
| `chr(n)` | one-byte string whose code is `n` |
| `bool(x)` | `x`'s truthiness as a bool |
| `round(x)` | nearest integer (ties away from zero); an int passes through |

```
name = ${upper("hamnix")}                 # HAMNIX
parts = split("a,b,c", ",")               # ["a", "b", "c"]
echo ${join(parts, " / ")}                # a / b / c
echo ${replace("/usr/bin", "/", ":")}     # :usr:bin
echo ${chr(ord("A") + 1)}                 # B
echo ${round(3.7)} ${bool(0)}             # 4 false
```

### 8b. Sequence arithmetic

`+` and `*` follow Python's sequence semantics, alongside their numeric and
string-concatenation meanings (§eval):

- `list + list` → a new concatenated list (`[1,2] + [3,4]` → `[1,2,3,4]`).
- `str * int` / `int * str` → the string repeated (`"ab" * 3` → `"ababab"`).
- `list * int` / `int * list` → the list repeated (`[0] * 4` → `[0,0,0,0]`).

A non-positive repeat count yields the empty sequence, as in Python.

### 8c. `lambda` & higher-order functions

`lambda P1, P2, …: EXPR` is an anonymous function value (a first-class
callable, printed as `<function>`). Params may take defaults exactly like
`def` (`lambda x, y=10: x + y`). The body is a single expression.

```
double = lambda x: x * 2
echo ${ double(21) }                       # 42
echo ${ (lambda a, b: a + b)(2, 3) }       # 5
```

The higher-order builtins take a callable — an inline `lambda`, a named
builtin (`len`), or a variable holding a lambda:

| function | result |
|---|---|
| `map(fn, seq)` | list of `fn(elem)` for each element |
| `filter(fn, seq)` | elements where `fn(elem)` is truthy (`fn` omitted → element truthiness) |
| `sorted(seq [, key=fn] [, reverse=BOOL])` | new list ordered by `key(elem)` |

```
echo ${ map(lambda x: x * x, [1,2,3]) }              # 1 4 9
echo ${ filter(lambda x: x > 1, [1,2,3]) }           # 2 3
echo ${ sorted([[1,3],[2,1]], key=lambda p: p[1]) }  # [2, 1] [1, 3]
echo ${ map(len, ["a","bb","ccc"]) }                 # 1 2 3
```

**Spacing conventions** (shared with the rest of the expression grammar, not
lambda-specific): binary `+` / `*` are space-flanked (`x * x`, `a + b`) — a
glued `x*x` is a glob/`+arg` word; and `lambda P: BODY` needs a space after
the colon. Comparison (`x > 1`) and subscript (`p[1]`) glue fine — a glued
subscript READ (`p[1]`, `row[0][1]`) is split into an index in expression
position.

### 8d. Sets

A **set** is an unordered collection of unique values, following Python's set
semantics. Membership and uniqueness compare by value (the same string-form
equality dict keys use).

- **Construction:** `set(iterable)` deduplicates any iterable
  (`set([1, 2, 2, 3])` → 3 elements); the `{a, b, c}` **set literal** holds one
  or more comma-separated elements. A brace group is a set when its first
  element is **not** followed by a `:` — a `key: value` first element keeps it a
  dict. Following Python, **empty `{}` is a dict**, and an empty set is written
  `set()` (and renders as `set()`).
- **Set comprehension:** `{EXPR for x in ITER [if COND]}` — like a list
  comprehension, but deduped into a set (`{n * n for n in [1, 2, 3, 2]}` →
  `{1, 4, 9}`).
- **Membership:** `x in s` / `x not in s`.
- **Algebra** (both operands sets): `a | b` union, `a & b` intersection,
  `a - b` difference, `a ^ b` **symmetric difference** (elements in exactly one
  set). `^` binds between `|` and `&` (Python's bitwise precedence). Method
  forms — `union(a, b)`, `intersection(a, b)`, `difference(a, b)`,
  `symmetric_difference(a, b)` — accept **any iterable** as the second argument.
- **Equality:** `a == b` / `a != b` on two sets is **order-independent** (equal
  cardinality plus mutual containment). A `frozenset` compares equal to a plain
  set with the same members.
- **Mutation:** `s.add(x)` (no-op if present), `s.discard(x)` and `s.remove(x)`
  (both tolerant of an absent element — no raise), `s.update(iterable)` (add
  every item in place), `s.clear()` (empty in place), and `s.copy()` (a fresh
  independent **mutable** set).
- **Introspection:** `len(s)`, `issubset(a, b)` / `issuperset(a, b)`.
- **`frozenset`:** `frozenset(iterable)` (or empty `frozenset()`) is an
  **immutable** set. It shares every set operation — membership, `|`/`&`/`-`/`^`
  algebra, equality, iteration, comprehension source — but `add`/`discard`/
  `update`/`clear` are silently refused, and it renders wrapped:
  `frozenset({1, 2, 3})` / `frozenset()`. (A frozenset is **not** currently
  hashable as a dict key — dict keys compare by string form, and a frozenset's
  string form is not stable as a key; document-only limitation.)
- **Iteration:** `for x in s { … }` (in insertion order). Three iterable forms:
  a `{…}` set literal (`for x in {10, 20, 30} { … }` — the literal consumes
  through its own `}`, leaving the body's `{` unambiguous), an expression such
  as `set(v)`, **and a bare set *variable*** — `for x in s { … }` where `s`
  names an in-scope set iterates its **typed** elements (ints stay ints), the
  shell-word analog of the expression form. Every other bare word-list
  (`for f in a b`, globs, `$xs`) keeps the shell word-list soul.

```
s = set([1, 2, 2, 3])
echo ${ len(s) }                       # 3
echo ${ 2 in s }                       # true
echo ${ {1, 2} | {2, 3} }              # {1, 2, 3}
echo ${ {1, 2, 3} & {2, 3, 4} }        # {2, 3}
echo ${ {1, 2, 3} - {2} }              # {1, 3}
echo ${ {1, 2, 3} ^ {2, 3, 4} }        # {1, 4}
echo ${ {1, 2} == {2, 1} }             # true
fs = frozenset([1, 2, 2, 3])
echo "${ fs }"                         # frozenset({1, 2, 3})
s.add(5)
echo ${ join(sorted(s), ",") }         # 1,2,3,5
```

Internally a set reuses the list element layout (single slot per element in the
shared value pool), so iteration/subscript/`len` share the list machinery; the
only added invariants are dedup-on-insert and — for a `frozenset` — an
immutability flag (`val_pay`) that shares the layout and every read path while
refusing mutation.

---

## 9. The ambient namespace & running a command directly

There is no "no namespace" — every process has one. A bare command runs in the
shell's **ambient namespace**: the one the boot recipe assembled (device-letter
binds) plus any binds/mounts done at the prompt since. The prompt *is* the
outermost namespace.

**Share-vs-copy policy (decided):**

- **External commands get a copy-on-write private copy** of the ambient
  namespace. They can read everything the shell sees, but their own
  binds/mounts are private and evaporate on exit. A command can never corrupt
  your view.
- **Composition verbs are builtins that mutate the ambient namespace in-process**
  and persist: `bind`, `mount`, `unmount`, `import`, `cd`. So `import 10.0.2.2
  /net` at the prompt sticks and every later command sees it.
- **Escape hatch:** for the rare tool whose *job* is to set up a namespace, run
  it shared explicitly (`share some-setup-tool`). Safe by default, danger
  opt-in.

This makes the model uniform at every level: **prompt = outermost scope; `ns {}`
= nested scope; a bare command = "run in the current scope."**

---

## 10. Scoped namespaces: `ns { }`

`ns { }` opens a nested scope: snapshot the mount table, run the body, restore at
the closing brace. Desugars to: `rfork(RFNAMEG)` (COW copy of the current Pgrp) →
apply the body's binds/mounts → run the body → tear the scope down.

```
ns {
    bind '#c' /dev
    mount $logsrv /var/log
    /bin/true            # sees only this view
}                        # namespace dissolves here
```

By default `ns { }` **overlays** — it starts from a COW copy of the current
ambient namespace and layers the block's binds on top, so `/env`, `/dev`, and
the device binds survive (see §13). For a hermetic base use `ns clean { }`
(empty base; you bind everything yourself).

The COW snapshot must be cheap (it rides the per-Pgrp mount-table copy from
Phase D, ideally copy-on-write) so entering a scope is not expensive.

`ns` is **exclusively** the scope keyword. To *view* a namespace, read the file
(§14) — there is no `ns`-subcommand for listing.

---

## 11. Namespaces as first-class values: `enter` / `spawn`

A configured namespace is a capturable value (a template — configured but not
entered):

```
sandbox = ns {
    mount $distrofs /
    bind '#c' /dev
}
```

**`enter sandbox { body }` — synchronous.** Forks a child; the child does
`rfork(RFNAMEG)`, applies a fresh COW instance of `sandbox`, runs the body; the
shell **blocks** until the body finishes and **propagates its exit status**.
Subshell-like: in-memory variables defined before the block are *readable* inside
(copied at fork), but variables set inside do NOT leak back out. The view is
discarded at the brace. (Exactly what crosses: §13.)

```
enter sandbox { apt update } && echo done
```

**`spawn sandbox { body }` — asynchronous.** Same fork + rfork + apply, but the
shell does **not** wait — it returns a **handle immediately**. The namespace
instance lives exactly as long as the spawned process.

```
svc = spawn sandbox { httpd }
kill $svc        # signal later
wait $svc        # or block on it now
```

- Default: a backgrounded job that dies if the shell dies.
- `spawn detached sandbox { … }`: uses `rfork(RFNOWAIT)` (the sever-parent path
  on the process-model list) so the service outlives the shell — i.e. a daemon.
- **Your entire init / service-supervisor falls out of `spawn` + handles.** That
  is how rc is written in this shell.

`enter` vs `spawn` differ in exactly one thing: **whether the parent calls
`wait`.** Both are thin wrappers over the namespace-instantiation primitive.

**Base namespace:** both `enter` and `spawn` apply the captured value **onto an
overlay of the current ambient namespace by default** (so the environment, `/dev`,
PATH survive). Use the `clean` form (`enter clean …` / a `sandbox = ns clean {…}`
template) for a hermetic base. See §13.

---

## 12. View vs state (the rule that keeps §11 from being a footgun)

**The namespace is the *view*; durable state lives in the file servers behind
it.** `enter`/`spawn` instantiate a fresh, cheap COW copy of the *view* and
discard it. But `apt update` writes into distrofs's *backing store*, which
persists independently of any view. So: the view is ephemeral, the install is
permanent. Assemble a view once, enter it a hundred times — each entry is a clean
cheap snapshot while accumulated state lives safely in the server. (Persistent
distrofs backing is shipped — RAM cache over ext4, snapshot on dirty
clunk/remove/EOF; `ea22407`.)

---

## 13. What crosses a namespace boundary (variable scoping)

A namespace boundary (`ns {}`, `enter`, `spawn`) is about **files / Chans /
mounts**, not about the shell's in-memory values. The governing principle, stated
once:

> **Values cross the boundary; resolution is namespace-local.**

The value itself always travels (it's data in process memory, copied at the fork
that opens the block). Whether the *thing the value refers to* is reachable
depends on the target namespace. That single rule resolves all three kinds of
"variable":

| value kind | readable inside the block | write propagates back out | usable in a *different* namespace |
|---|---|---|---|
| **data** — string / int / bool / list / dict | yes (fork copy) | no (subshell rule) | yes — needs no resolution |
| **path string** — a value that *names* a resource | yes | no | only if that path is bound in the target namespace |
| **live handle** — mount handle / process handle / open Chan | the value, yes; the resource, no | no | **no — error to use outside its owning namespace** |

So, concretely:

1. **Plain data just works.** `host = "10.0.2.15"; enter s { echo $host }` prints
   the host — `$host` was copied in at fork. The common case you'd worry about
   does not break. Writes don't flow back (it's a subshell), which is the same
   rule as `enter` not leaking variables.

2. **A path string crosses but may not resolve.** `p = "/var/log/out";
   enter s { cat $p }` — the *string* crosses fine, but `cat` only succeeds if
   `/var/log` is bound in `s`. Nothing about the variable broke; the resource may
   simply be absent from that view. That is the entire point of namespaces.

3. **A live handle is namespace-local and must NOT be passed across.** A handle
   from `remote = mount $srv /n/remote` is bound to the namespace that created it.
   `enter s { unmount remote }` is meaningless — `s` never had that mount. Using
   a handle outside its owning namespace **must be a loud error, not undefined
   behavior.** If you need to act on a resource inside another namespace,
   re-resolve it there *by name*, don't carry the live handle in.

**Base-namespace decision (what an entered/captured namespace applies onto):**

- **Default = overlay.** `ns {}` / `enter` / `spawn` start from a COW copy of the
  current ambient namespace and layer the block's (or captured value's) binds on
  top. Therefore `/env` (and so `$PATH` and your exported vars), `/dev`, and the
  device binds **all survive**. This is *why* your environment doesn't vanish
  inside a block, and it's the least-surprising default.
- **`clean` = hermetic.** `ns clean { }` (and the matching `enter clean` /
  `ns clean` template) starts from an empty base — only what the block binds.
  Now `/env`, `/dev`, and PATH are gone unless you bind them yourself. Opt-in
  isolation for a genuine clean room; you accept rebuilding the basics.

**Net:** ordinary variables don't break — in-memory data crosses via the fork
copy, and the environment survives via the overlay default. The one thing that
breaks, and *should* break loudly, is handing a live handle into a foreign
namespace.

---

## 14. Handles, labels, and introspection

**Unifying principle: every resource-creating construct returns a first-class
handle value.** `ns {}` → namespace value; `spawn` → process handle; `mount` →
mount handle.

```
remote = mount $srv /n/remote      # the mount is a value
unmount remote                     # refer by handle, not a fragile path
mount $srv /n/remote as remote     # optional inline-label sugar (no variable)
```

A handle is valid **only in the namespace that created it** (§13). Using one
outside its owning namespace is an error.

Labeling is **not** a separate subsystem — it's the handle pattern applied to
mounts. It becomes *necessary* once union mounts (MBEFORE/MAFTER) land: with
several servers stacked at one path, the path is no longer a unique handle, so a
stable name is required to `unmount` the right one or to ask "where did `/net`
actually come from."

**Introspection is free because everything is a file.** Your namespace is
readable at `/proc/self/ns` (and `/proc/<pid>/ns`), labels and all. There is no
special "list mounts" command — `cat /proc/self/ns`.

---

## 15. Composition verbs (builtins)

`bind`, `mount`, `unmount`, `import`, `cd`. These run **in-process** and mutate
the **ambient** namespace (§9). `import host /net` pulls a remote machine's 9P
tree into the current namespace.

Because a `Chan` does not care whether its server is local or remote, pipelines
and namespaces span machines with no syntax change:

```
ns {
    import 10.0.2.2 /net               # machine A's network stack
    mount $logsrv /var/log             # B's log server
    server </net/tcp/0 >/var/log/out   # input from A, output to B — fully scoped
}
```

That is the CPU-server idiom and the "useful in 2026, not archaic Unix" payoff,
expressed entirely in the shell.

### Authentication / elevation builtins — `newshell`, `read`

Two builtins exist because the Plan-9-shape security model
(`docs/security.md`) needs them and they must NOT live as setuid
binaries.

**`read [-s] VAR`** reads one line from stdin into the shell variable
`VAR`. `-s` mutes echo so passwords don't appear on the terminal. Used
by `etc/install.hamsh` for credential prompts and by `newshell` for the
password prompt. Implementation: `user/hamsh.ad::builtin_read`.

```
hamsh$ read name
alice
hamsh$ echo Hello, $name
Hello, alice
hamsh$ read -s pw
********              # echo muted
```

**`newshell <user> [-c <cmd>]`** is the Plan-9-shape elevation idiom —
factotum-style re-auth into a new shell session AS the target user,
with their full namespace. It is **not** "elevate this command's
authority" (POSIX `sudo`); it is "open a new shell as that user."

```
$ newshell hostowner
password: ********
[hostowner@hamnix ~]$ hpm install linux-debian-12
[hostowner@hamnix ~]$ exit
$ # back to your regular-user shell
```

Implementation (`user/hamsh.ad::builtin_newshell`):

1. Read target uid from `/etc/passwd`.
2. Prompt password.
3. Write to `/dev/auth`: `user <name>\npass <plaintext>\n`. Read `ok`/`denied`.
4. On success: `rfork(RFPROC|RFNAMEG)`, in the child call `SYS_SETUID(target_uid)`,
   stamp `HAMNIX_NEWSHELL_USER=<name>` in env, `exec /bin/hamsh`.
5. The newly spawned hamsh recognises the env var, sources
   `/etc/users/<name>.ns` (or `/etc/users/default.ns`) before the
   interactive prompt — the per-user namespace restriction.

No setuid binary. No environment leak. No setuid path-search game.
Authority is granted by the kernel after password auth, not stolen from
a binary's setuid bit. `newshell hostowner -c '<command>'` runs one
command as hostowner and exits.

---

## 16. Errors via errstr

Wire error handling to the kernel's existing Plan 9 **errstr** mechanism — do not
reinvent `$?` + `set -e`.

- `$errstr` is a native variable holding the last failure string.
- `$status` holds the last command's numeric exit status; **`$?` is an alias**
  for it.
- Every command yields an exit status **and** an errstr.
- Build structured `try { } except { }` on top of errstr.

```
try {
    mount $srv /n/remote
} except {
    echo "mount failed: $errstr"
}
```

### 16a. The never-a-wrong-answer rule

**hamsh never returns a confidently wrong value.** When the evaluator hits a
hard limit or an undefined operation it raises a *runtime fault* instead of
degrading to `0` / `None` / `""`:

- the message is written to **stderr** as `hamsh: runtime error: <what>`,
- `$errstr` carries it and `$status` becomes `1`,
- the fault unwinds at the next statement boundary, so `try { } except { }`
  catches it exactly like a `raise`, and an uncaught one prints
  `hamsh: uncaught exception: <what>` at the top level,
- a fault while evaluating a command's arguments **aborts that command** (it
  never runs with a substituted bogus value), and a fault while evaluating an
  assignment's RHS **does not bind** the variable.

What raises (each of these used to return a plausible wrong number in
silence): division / modulo / `divmod` by zero; bitwise `& | ^ ~` on a
non-integer; recursion past `CALL_DEPTH_MAX`; the value / string / element /
collection / scope arenas filling up; and an undefined name that carries
non-identifier characters — `s(n-1)` lexes `n-1` as ONE bare word (`-` is a
legal word character, §4), so hamsh reports
`undefined name 'n-1' — glued arithmetic? write \`a - b\` with spaces`
rather than substituting nil. A plain undefined identifier (`$HOME`,
`$installer_medium`) keeps the shell's empty-string semantics.

An error raised inside a called `def` propagates out of the *expression* that
called it — the caller cannot mistake the failed call's nil for a result.

### 16b. Fixed limits (there is no garbage collector)

hamsh runs on fixed-size session arenas. Every one of these raises on
overflow; none silently truncates:

| Limit | Value | Applies to |
|---|---|---|
| `LINE_MAX` | 2048 B | one logical input line |
| `TOK_MAX` | 4096 | tokens per logical input |
| `NODE_MAX` | 16384 | AST nodes (session) |
| `STR_ARENA_MAX` | 32768 B | interned strings (session) |
| `VAL_MAX` | 16384 | value cells (session) |
| `LISTELEM_MAX` | 16384 | list/dict element slots |
| `COMP_MAX` | 4096 | elements per list / `range()` / comprehension |
| `SCOPE_MAX` | 128 | live variable bindings |
| `FN_MAX` / `FN_NAME_MAX` | 32 defs / 16 B | user functions |
| args per call | 16 | `def` parameters and call arguments |
| `CALL_DEPTH_MAX` | 12 | nested/recursive `def` frames |
| `ARGV_MAX` / `ENV_MAX` | 64 / 32 | external argv slots / exported vars |
| `source` file | 16 KiB | script read buffer |
| `HIST_MAX` | 48 | history ring |

Value cells are **session-lifetime with no GC** (they are only recycled when
no `def` and no variable is live), so a loop of more than a few thousand
iterations exhausts `VAL_MAX` and raises. Long-running work belongs in Adder,
not hamsh — this is a deliberate small-interpreter trade, and the error names
the arena so the cause is never a mystery.

### 16c. POSIX parameter expansion

`${ … }` is a hamsh **expression**, but the four colon forms every shell user
knows are recognised first, plus `${#NAME}`:

| Form | Meaning |
|---|---|
| `${x:-word}` | value of `x` if set and non-empty, else the literal `word` |
| `${x:+word}` | `word` if `x` is set and non-empty, else empty |
| `${x:=word}` | as `:-`, and assigns `word` to `x` |
| `${x:?msg}` | value of `x`, or raise `msg` when unset/empty |
| `${#x}` | length of `x`'s string form |

`word` is literal (a `$NAME` word is looked up). Bare `${x-1}` / `${x+1}` are
**not** parameter expansion — they are arithmetic, as they have always been.

---

## 17. Non-goals (do NOT build these)

- **No Adder.** hamsh shares no grammar, type system, or evaluator with Adder;
  it is its own small dynamically-typed, Python-flavored language.
- **No separate expression mode / no second language.** One grammar; the
  command-vs-assignment-vs-control distinction is statement dispatch (§2).
- **No heuristic command-vs-code detection** (the xonsh trap). Statement
  dispatch is the deterministic first-token rule of §2, nothing fuzzier.
- **No full structured-table/data-wrangling engine** (not nushell). Bytes-first.
- **No 9P marshalling on local pipes.** Local = direct Chan reads only.
- **No implicit word-splitting / brace / tilde expansion.** Globbing is the sole
  implicit expansion.
- **No per-construct block terminators** (`fi`/`done`/`esac`).
- **No passing a live handle across a namespace boundary.** A handle is valid
  only in its creating namespace (§13); cross-namespace use is an error.

---

## 18. Test coverage

Every section above is backed by an integration test under `scripts/test_hamsh_*.sh`
exercising the behavior end-to-end through a real QEMU boot. The full set
covers: statement dispatch (§2); typed values + list interpolation (§3);
brace blocks + control flow + `def` (§4); stdio-as-`/fd` + pipe/redirect/dup
as `bind` (§7), with a tripwire that a local pipe does zero `mountrpc` calls;
ambient namespace + COW-for-externals (§9); `ns { }` scope + overlay default
(§11); `enter` / `spawn` + handles (§11); boundary scoping (§13); view vs.
state over a posted distrofs daemon (§13); mount handles + `/proc/self/ns`
introspection (§14); errstr / try-catch (§16); interactive line editor with
cursor editing + history + Tab completion (`scripts/test_hamsh_lineedit.sh`);
PID-1 init via `/etc/rc.boot`.
