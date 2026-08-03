# hamsh — an honest review (2026-07-25)

Subject: `user/hamsh.ad` (16,331 lines) — HamnixOS's native shell: lexer +
parser + tree-walking interpreter in one Adder source file.
Base commit: `438fca0a`. Spec: `docs/HAMSH_SPEC.md` (724 lines).

**Method.** Every runtime claim below was produced by compiling the *real*
shell source for the host (`python3 -m compiler.adder compile
--target=x86_64-linux user/hamsh.ad`) and driving it over a stdin pipe with
`--no-echo` — the same seam `scripts/test_hamsh_lang_host.sh` uses. Output is
quoted verbatim. Structural claims cite `user/hamsh.ad` line numbers.

**One caveat stated up front.** The host build's namespace `open()` is a
fail-closed stub, so *file* sourcing cannot be exercised on the host — both
`hamsh <script>` and the `source` builtin report `cannot open file` there.
File-sourcing is covered on-device by `scripts/test_hamsh_dualsyntax.sh`
(case F). All host results below are therefore from the REPL/stdin path,
which runs the identical lexer, parser and evaluator.

> **STATUS (fixed the same day).** The P0 findings below — §6.1 value/collection
> exhaustion, §6.2 the `SCOPE_MAX` overrun, and every silent-degradation case in
> §6.3 — have been FIXED in `user/hamsh.ad`, together with the §1.5 doc bug and
> P1 #4/#5 (`$?`, `$(…)`). The rule now written into `docs/HAMSH_SPEC.md` §16a is
> *hamsh never returns a confidently wrong value*: each limit and each undefined
> operation raises a diagnosable error (stderr line + `$status=1` + `$errstr`,
> catchable by `try`/`except`). Two further silent-wrong classes were found while
> re-testing these repros and fixed too: `range()`/comprehensions silently
> truncated at `COMP_MAX=4096` (this, not `VAL_MAX`, was the real cause of the
> §6.1 wrong sum), and `s(n-1)` — glued arithmetic lexes as ONE bare word, which
> reached the evaluator as an undefined name and evaluated to 0, so recursion
> returned a plausible wrong number. Regression gate:
> `scripts/test_hamsh_nosilentwrong_host.sh`. Everything below is the review as
> written, left unedited as the before-state record.

---

## 0. Direct answers to the four questions

**Q1 — How does hamsh stack up for games / simple graphical apps / shell use?**
Shell use: **good, and it is the right tool today** — it is the real `/init`,
sources every `rc`, and has pipelines, redirection, jobs, history, completion
and reverse-search. Simple graphical apps: **possible but marginal** — a real
`pygame` builtin drives `/dev/wsys`, but with only 5 draw primitives, no
sprites, no audio and no frame pacing. Games: **no — use Adder.** Not one of
the shipped ham* games is written in hamsh, and the value-cell exhaustion bug
(§6) alone disqualifies any long-running loop.

**Q2 — Are we using hamsh's Python-like syntax for shell scripts?**
**Mostly no.** Of the shipped scripts, **10 are brace-style, 2 are mixed, 1 is
indent-only, 6 are flat**, and there are **zero** inline-colon one-liners.
`/etc/rc.boot` — the most control-flow-dense script in the repo — is 100%
braces. Python-indent appears in exactly three real files
(`etc/rc.de-user`, `etc/rc.de-hostowner`, `etc/install_multipkg.hamsh`).

**Q3 — Where are curly braces used in the shell?**
Braces are the dominant block form in shipped scripts (`if`/`else`,
`try`/`except`, `ns { }`, `spawn detached { }` in `etc/rc.boot`), *and* they
serve two unrelated non-block roles: `${ expr }` expression interpolation and
`` `{ cmd } `` Plan 9-style command substitution.

**Q4 — Can you use either whenever you like? Does hamsh auto-detect indent vs
braces?**
**Yes — unambiguously.** hamsh decides **per block**, from the single token
that opens that block's body. Both forms are legal in every context (REPL and
script file), and they **mix freely inside one file, one function, even one
`if`/`else` chain**. Proven by parser source (§1) and by 8 passing runtime
cases in the new gate `scripts/test_hamsh_dualsyntax_host.sh`.

---

## 1. Q4 in detail: indent vs braces (parser evidence + runnable proof)

### 1.1 The parser decides per block, from one token

`user/hamsh.ad:2416` — every block-structured construct routes through
`parse_suite()`:

```
def parse_suite() -> int32:
    # The universal block entry point. Every block-structured construct
    # (if/elif/else, while, for, def, try/except, ns, enter, spawn) calls
    # this where it expects its body. Two fully interchangeable forms:
    #   * brace   — `{ statements }`   (the interactive one-liner form)
    #   * colon   — `: NEWLINE INDENT statements DEDENT`  (Python-style),
    #               or a single-statement inline `: statement`.
    # The form is chosen per-block from the token that opens it, so a
    # script can mix them and either style works in any context.
    if pk_is_op(OP_LBRACE) != 0:
        return parse_block()
    if pk_is_op(OP_COLON) != 0:
        return parse_colon_suite()
    ps_set_err("expected '{' or ':' to open block")
    return 0
```

That is the whole answer: there is no file-level or REPL-level mode flag. The
lookahead token `{` or `:` selects the form, so the decision is made
independently for every single block.

### 1.2 Why mixing actually works (not just nominally)

Two deliberate mechanisms make the forms composable rather than merely both-present.

**(a) `{ }` does not suppress INDENT/DEDENT** — `user/hamsh.ad:1226`:

```
# Track ( ) / [ ] nesting so INDENT/DEDENT is suppressed while a
# ... `{ }` is deliberately NOT counted: a brace block's indented body
# ... their INDENT/DEDENT, which is what makes the two syntaxes fully
```

So a brace block written across indented lines still emits INDENT/DEDENT.

**(b) Stray INDENT/DEDENT are swallowed as separators** — `_skip_seps()`,
`user/hamsh.ad:2400`:

```
def _skip_seps():
    # Skip statement separators AND stray indentation tokens. Used at
    # every point that is between statements but NOT the structural
    # boundary of a colon-suite (parse_block's body, parse_program's
    # top level). A brace block whose body is indented emits INDENT
    # after `{` and DEDENT before `}`; swallowing them here lets the two
    # syntaxes mix freely — a colon-suite still consumes its OWN matched
    # INDENT/DEDENT explicitly in parse_colon_suite, so it never loses
    # its terminator to this skip.
```

A colon-suite still consumes *its own* matched INDENT/DEDENT explicitly
(`parse_colon_suite`, `user/hamsh.ad:2457`), so it cannot lose its terminator
to that skip. That asymmetry is what makes nesting either-inside-either safe.

`parse_colon_suite` also handles the inline form (`if x: echo hi`) by checking
for a non-newline directly after the `:`, and tolerates blank lines between
header and body.

### 1.3 Runtime proof

New host gate `scripts/test_hamsh_dualsyntax_host.sh` (added by this review;
it only *observes* hamsh, it does not change it):

```
[dualsyntax-host] PASS A-indent (INDENT 5 pos)
[dualsyntax-host] PASS B-brace (BRACE 5 pos)
[dualsyntax-host] PASS C-mixed-brace-outer-indent-inner (MIX_A pos 1)
[dualsyntax-host] PASS C-mixed-indent-outer-brace-inner (MIX_C small big)
[dualsyntax-host] PASS C-mixed-negative-branch (MIX_B doubled -2)
[dualsyntax-host] PASS D-inline-colon (INLINE_TAKEN)
[dualsyntax-host] PASS E-brace-indented-body (E2_B)
[dualsyntax-host] PASS F-no-opener (expected '{' or ':' to open block)
[dualsyntax-host] VERDICT: PASS — indent and brace are interchangeable per block
```

**Style A — pure Python-indent** (works):

```
def classify(n):
    if n < 0:
        return "neg"
    elif n == 0:
        return "zero"
    else:
        return "pos"

for v in [-2, 0, 5]:
    echo INDENT ${v} ${classify(v)}
```
→ `INDENT -2 neg` / `INDENT 0 zero` / `INDENT 5 pos`

**Style B — pure brace** (works):

```
def classify(n) { if n < 0 { return "neg" } elif n == 0 { return "zero" } else { return "pos" } }
for v in [-2, 0, 5] { echo BRACE ${v} ${classify(v)} }
```
→ `BRACE -2 neg` / `BRACE 0 zero` / `BRACE 5 pos`

**Style C — mixed, both directions, in one file** (works):

```
def outer(n) {              # brace body ...
    if n > 0:               # ... containing an indented suite
        echo MIX_A pos ${n}
    else:
        echo MIX_A nonpos ${n}
    return n * 2
}
def inner(x):               # indented body ...
    if x > 10 { return "big" }    # ... containing brace suites
    else { return "small" }

for v in [1, -1] { r = outer(v); echo MIX_B doubled ${r} }
echo MIX_C ${inner(3)} ${inner(30)}
```
→
```
MIX_A pos 1
MIX_B doubled 2
MIX_A nonpos -1
MIX_B doubled -2
MIX_C small big
```

Note the `if`/`else` chain in `inner` uses a brace body for `if` and a brace
body for `else` while the enclosing `def` is a colon-suite — per-block choice
is real, right down to the branch.

**Style D — inline colon one-liner**: `if 1: echo INLINE_TAKEN` → `INLINE_TAKEN`;
`if 0: echo INLINE_NOT` correctly prints nothing.

**Style E — brace body spread across indented lines** (this is the case
mechanism (a)+(b) exist for):

```
if 1 {
    echo E2_A
    echo E2_B
}
```
→ `E2_A` / `E2_B`

**Style F — neither opener** is a clean, line-numbered error, not a hang:

```
$ if 1 echo NOPE
hamsh: parse error [line 1]: expected '{' or ':' to open block
```

### 1.4 The only real constraints

- A block needs **one** of `{` or `:`. Bare `if x` + newline + indent is an error.
- In the **interactive REPL**, a multi-line indentation suite is terminated by a
  **blank line** (Python-REPL rule, `user/hamsh.ad:14461`). Brace blocks need no
  blank line — the parser knows the block is open until `}`. This is the one
  place the two forms genuinely differ in feel, and it is why the shipped
  scripts and the docs both favour braces for one-liners.

### 1.5 Doc bug found (not fixed — out of scope)

`docs/HAMSH_SPEC.md:695` (§17 Non-goals) states:

> - **No significant-whitespace blocks** in the interactive grammar.

This is **stale and wrong**. §5 of the same document (lines 129–177) documents
significant-indentation suites in full, the lexer implements INDENT/DEDENT
(`user/hamsh.ad:396–397`, `IND_STACK_MAX=64` at `:484`), and §1.3 case A above
proves indentation suites work *in the interactive grammar specifically*
(that test drives the REPL, not a file). Recommend deleting that bullet.

---

## 2. Q2/Q3 in detail: what the shipped scripts actually use

| File | Lines | Style |
|---|---|---|
| `etc/rc.boot` | 304 | **Brace** (31 `{}` pairs) |
| `etc/rc.boot.full` | 265 | **Brace** (26) |
| `etc/rc.d/rc.5` | 160 | **Brace** (9) |
| `etc/rc.d/rc.5.selftest` | 185 | **Brace** (6) |
| `etc/rc.ssh` | 81 | **Brace** (2, both `ns clean { }`) |
| `etc/rc.de-wayland` | 128 | **Brace** (4) |
| `etc/install.hamsh` | 238 | **Brace** (3) + flat |
| `etc/rc.de-user` | 226 | **Mixed** — brace `ns { }`, indent `if/else` (L191) |
| `etc/rc.de-hostowner` | 98 | **Mixed** — same shape (L92) |
| `etc/install_multipkg.hamsh` | 87 | **Indent only** (one `for ... :` suite, L68) |
| `etc/install_nvme.hamsh` | 82 | Flat |
| `etc/rc.d/rc.0`, `rc.3`, `rc.6`, `etc/profile`, `etc/users/default.ns` | 7–50 | Flat |
| `etc/svc/sshd.hamsh`, `etc/services.d/*.svc` | 21–55 | **Not code** — `key: value` data despite the extension |
| `examples/gui_hello.hsh`, `gui_dialogs.hsh`, `pygame_bounce.hsh` | 45–80 | **Brace** |

**Tally: brace 10, mixed 2, indent-only 1, flat 6, inline-colon 0.**

`etc/rc.boot` is emphatically *not* a linear command list — it has nested
`try {} except {}` exit-code probes and `if/else` on `$installer_medium`,
`$autorun`, `$have_target`, `$live_writable_ok`, `$sysroot_ok`, `$installed`:

```
installer_medium = 1
try {
    cat /etc/installer-medium
} except {
    installer_medium = 0
}
if $installer_medium > 0 {
```

The one indent-style path that runs on **every graphical boot**
(`etc/rc.de-user:191`):

```
if $HAMNIX_DE_PROG:
    echo 'rc.de-user: invoking $HAMNIX_DE_PROG'
    if $HAMNIX_DE_PROG_ARG1:
        $HAMNIX_DE_PROG $HAMNIX_DE_PROG_ARG1
    else:
        $HAMNIX_DE_PROG
    exit $status
```

**Braces' other two jobs** (Q3): `${ expr }` expression interpolation
(`ND_DOLEXPR`, `user/hamsh.ad:1286`) and `` `{ cmd } `` command substitution
(`TK_BACKEXP`, `:1082`). Both are *expression* syntax, unrelated to blocks —
a reader skimming `etc/rc.boot` sees braces in three different roles.

**Assessment.** The Python-esque syntax is real, tested, and shipped — but
it is a *minority* style in practice. The project's own `rc` files vote for
braces. That is a defensible outcome (braces are paste-robust and need no
blank-line terminator), but it means "hamsh is Python-esque" oversells what
the shipped corpus looks like.

---

## 3. Language capability vs bash and Python

Legend: ✅ full · 🟡 partial · ❌ absent.

| Capability | bash | Python | hamsh | Evidence (`user/hamsh.ad`) |
|---|---|---|---|---|
| int / float / bool / None | 🟡 | ✅ | ✅ | 12 type tags, `:3520–3541`; int64 `:3548`; IEEE-754 `VT_FLOAT` |
| Arithmetic `+ - * / // % **` | 🟡 | ✅ | ✅ | `_arith :4749`; `/` always float (Python 3 semantics, `:5117`) |
| Integer bitwise `& \| ^ ~ << >>` | ✅ | ✅ | ❌ | parsed but **only** dispatched for sets `:5042`; ints silently → 0 |
| Comparison chaining `1<x<3` | ❌ | ✅ | ❌ | left-fold `:1713`, so `(1<x)<3` |
| Strings + ~45 methods | ❌ | ✅ | ✅ | `eval_call :6540–7440` (upper/split/join/replace/strip/find/…) |
| Slicing `s[a:b:c]`, neg. index | ❌ | ✅ | ✅ | `eval_slice :6238` (lists + strings) |
| f-strings | ❌ | ✅ | ✅ | `ND_FSTR :1318`, `eval_fstring :5262` |
| `str.format()` | ❌ | ✅ | 🟡 | `:spec` parsed then **ignored** — no width/precision |
| Lists + methods + comprehensions | 🟡 | ✅ | ✅ | `ND_LIST :1288`; `ND_LISTCOMP :1304` |
| Dicts | 🟡 | ✅ | 🟡 | `_dict_find :3995` — **O(n) linear scan, string-keyed**; `d[1]`≡`d["1"]` |
| Sets | ❌ | ✅ | ✅ | `VT_SET :3539` + `\| & - ^` operators |
| Tuples (distinct type) | ❌ | ✅ | ❌ | `ND_TUPLE :1310` evaluates to a list |
| `range/map/filter/zip/enumerate/sorted` | ❌ | ✅ | ✅ | `:6930–7184` |
| Functions, defaults, kwargs | 🟡 | ✅ | 🟡 | `parse_def :2863`; **max 16 args** `:4533`; **max 32 defs** `:4698` |
| `*args` / `**kwargs` | ✅ | ✅ | ❌ | not parsed |
| Lambdas | ❌ | ✅ | 🟡 | `parse_lambda :2035` — single *expression* body |
| **Closures / lexical capture** | ❌ | ✅ | ❌ | `scope_get :4538` resolves **current frame or global only** |
| Recursion | ✅ | ✅ | 🟡 | **depth cap 12** `:11268` — and it fails *silently* (§6) |
| if/elif/else, while, for-in, break/continue | ✅ | ✅ | ✅ | `:2740–2860` |
| `pass` / `del` / `global` / `yield` / `match` | — | ✅ | ❌ | not keywords |
| try/except/else/finally, raise | ❌ | ✅ | 🟡 | `parse_try :2899` — **no exception classes**; filter is string compare `:2915` |
| Modules / `import` | 🟡 | ✅ | ❌ | `builtin_import :10121` is a 9P mount verb and **always errors** ("no transport configured") |
| `source FILE` | ✅ | — | 🟡 | `:10151` — **16 KiB buffer, silently truncated** `:10148` |
| Classes / objects / attributes | ❌ | ✅ | ❌ | no `class` construct; `.` is only method-call sugar |
| Scoping | 🟡 | ✅ | 🟡 | flat two-level; a function **cannot rebind a global** |

**Honest verdict on "Python-esque expressiveness."** The *surface* is
genuinely impressive and well beyond bash: comprehensions, sets, slices,
f-strings, lambdas, try/except, ~45 string methods. But three absences make it
a Python *dialect*, not Python: **no closures, no classes, no module system.**
Combined with the caps in §6, it is best described as "Python syntax over a
small fixed-size interpreter" — excellent for 50-line rc scripts, unsuitable
for a 500-line program.

---

## 4. Shell-specific capability vs bash

| Feature | Status | Evidence / note |
|---|---|---|
| Pipelines `a \| b` | ✅ | `parse_pipeline :2720`, `run_pipeline :10718` (cap `PIPE_STAGE_MAX`) |
| Redirect `>` `>>` `<` `2>` `2>&1` | ✅ | parsed `:2685–2709`; `_wire_redirects :10217` (+ in-process for builtins `:10374`) |
| Arbitrary fd syntax (`3>`, `>[2=1]`, `&>`) | ❌ | only the 3 fixed streams; the *mechanism* (`sys_fdbind :8018`) exists but is unexposed |
| **Here-docs `<<EOF` / here-strings** | ❌ | no `<<` token at all. Verified: the body lines execute as commands |
| Command substitution | 🟡 | Plan 9 form `` `{ cmd } `` only (`:1082`). **No `$(...)`** — verified parse error |
| — capturing a *pipeline* | ❌ | `_run_and_capture :11175` returns empty for non-`ND_CMD` |
| Globbing `*` `?` | 🟡 | shell-side `_argv_glob_expand :7915`; `_fnmatch :14228` — **no `[...]` classes**; nullglob off |
| Job control `&`, `jobs`/`fg`/`bg`, Ctrl-Z | ✅ | job table `:10823`, `_builtin_fg :11090`, SIGTSTP/SIGCONT `:10836` |
| Subshells `( )` / grouping `{ ; }` | ❌ | replaced by namespace forms `ns { }` / `enter` / `spawn` (`:3324`, `exec_ns :11434`) |
| Env + `export`, passed to children | ✅ | `builtin_export :8582`; `_build_envp :8107`. **Cap: 32 vars, 32-byte names, 192-byte values** `:4572` |
| Exit status | 🟡 | `$status` (rc-style). **`$?` is a parse error** — verified |
| `&&` / `\|\|` | ✅ | `:3451`, short-circuit `:12255` |
| **`trap`** | ❌ | no trap builtin; Ctrl-C is line-discard only `:15087` |
| `kill` | ✅ | `:14138` |
| Quoting: `"…"` interp, `'…'` literal, escapes | ✅ | `:1005–1053`. No `$'…'`, no backslash line-continuation |
| POSIX param expansion `${x:-y}` `${#x}` `${x%…}` | ❌ | `${ }` is a hamsh **expression**, not param expansion. Verified: both silently yield **empty** |
| Line editing / history / reverse-search / completion | ✅ | `:14520`, `:14563`, Ctrl-R `:15288`, Tab `:15098` |
| `PS1` / `PS2` | ❌ | hardcoded `"hamsh$ "` / `"> "` at `:14763` |

**Builtins** (3 dispatch sites, a `cstr_eq` chain rather than a table):
`cd pushd popd dirs pwd bind unmount mount import export echo hamui pygame svc
service init telinit read newshell setuid source` (`_builtin_dispatch :10011`);
`exit true false kill wait jobs fg bg alias unalias` (`exec_statement :12179`).

**What a bash user hits within five minutes**, in order:
`$?` (parse error), `$(...)` (parse error), here-docs (silently runs your
heredoc body as commands), `${VAR:-default}` (silently empty), `[a-z]` globs,
`trap`, `PS1`. The first four are the painful ones because three of them fail
*silently or confusingly* rather than saying "unsupported".

---

## 5. Graphical / app use

**Yes, hamsh can drive the DE.** It imports the hamSDL stack directly
(`user/hamsh.ad:9550–9578`) and `builtin_pygame` (`:9217`) is genuinely wired
to the window system, not stubbed:

- `pygame init W H` → `sdl_dev_init(...)` → writes `newwindow` to `/dev/wsys/ctl`
- `pygame flip` → `hamsdl_vk_rasterize` + `sdl_dev_present()` → commits the
  display list to `/dev/wsys/<wid>/scene`
- `pygame poll` → `sdl_dev_pump()` drains `/dev/wsys/<wid>/keys` and `/event`

Transport is real code in `lib/hamsdl_dev.ad`. A second surface,
`builtin_hamui` (`:8787`), binds a retained-mode widget toolkit
(`label/button/checkbox/entry/list/combo/menubar/notebook/dialog/…`), demoed by
`examples/gui_hello.hsh`.

**But the ceiling is low.** The full script-visible draw API is:
filled rect, rect outline, line, text, full clear — **5 primitives**. Not
imported into hamsh, and therefore unreachable from script: `sdl_blit`,
`sdl_fill_round_rect`, `sdl_draw_text_bold`, `sdl_dev_upload_rgba` (sprites),
the whole `lib/hamsdl_audio*` mixer, and `sdl_dev_delay`/`sdl_frame_delay`
(**no frame pacing** — `examples/pygame_bounce.hsh` just counts to 90 frames
because it has no clock). The window is single, fixed-size, hardcoded title
`"hamsh game"` at position 80,80. Only arrow keys have named constants.

**Verification honesty:** pixel-level proof exists only on the host
(`scripts/test_hamsh_pygame_host.sh` asserts exact PPM pixels). The device gate
`scripts/test_hamsh_pygame_device.sh` is **structural only** — it greps the ELF
for `newwindow` / `/dev/wsys/ctl` and admits in its own comment that "the actual
pixels-on-a-DE-window screendump is an on-device follow-up." So *"hamsh draws
on a real DE window"* is wired and compiled but **not yet visually proven on
device**.

**Games.** Every shipped ham* game is Adder: `hamgamesnake.ad`,
`hamtetrisscene.ad`, `hamchessscene.ad`, `hamminescene.ad`, `ham2048.ad`,
`hamangrybirds.ad`, `sdlpong.ad` (logic in `lib/`, `user/*.ad` = thin wsys
driver). **There are no `.hamsh` games.** The only hamsh graphical programs are
three `examples/*.hsh` demos.

---

## 6. Performance & robustness — the most serious findings

Speed is a non-issue: 3,276 loop iterations of integer arithmetic ran in
**~5 ms**. The problem is not throughput; it is that **hamsh degrades silently
and returns wrong answers instead of erroring.**

### 6.1 CRITICAL — value-cell exhaustion silently corrupts results

`VAL_MAX = 16384` (`:235`) value cells, **session-lifetime, no GC**.
`v_new` returns cell 0 (= `None`) on exhaustion (`:3591`) — no error, no status.
Arenas only recycle when `fn_count == 0 && sc_count == 0` (`_maybe_recycle_arenas
:14354`), so **any script with a single live variable can never recycle.**

Measured, summing `0..N-1`:

```
N=100    expected=4950       -> RES 4950
N=1000   expected=499500     -> RES 499500
N=3000   expected=4498500    -> RES 4498500
N=3276   expected=5364450    -> RES 5364450
N=4000   expected=7998000    -> RES 5364450   <-- WRONG
N=10000  expected=49995000   -> RES 5364450   <-- WRONG
N=20000  expected=199990000  -> RES 5364450   <-- WRONG
```

The loop silently stops accumulating at ~3,276 iterations (≈5 value
allocations/iteration × 3,276 ≈ 16,384 = `VAL_MAX`) and then **reports a
plausible-looking wrong number.** Status and errstr are empty:

```
$ echo RES $s STATUS $status ERRSTR $errstr
RES 5364450 STATUS  ERRSTR
```

This is the single most dangerous property of hamsh today: a script that
processes a few thousand items produces confidently wrong output with no
diagnostic. **Any loop over more than ~3,000 iterations is untrustworthy.**

### 6.2 CRITICAL — `SCOPE_MAX` buffer overrun (confirmed memory corruption)

`SCOPE_MAX: uint64 = 128` (`:236`) but the three backing arrays are **64**:

```
sc_name:  Array[64, uint64]   # :4496
sc_val:   Array[64, int32]    # :4497
sc_frame: Array[64, int32]    # :4498
```

and the only guard is `if sc_count >= SCOPE_MAX: return` (`:4529`). Bindings
64–127 therefore write **past the end of all three arrays**. Reproduced by
defining N variables then reading the first two back:

```
RESULT 60 first=1 second=2
RESULT 64 first=1 second=2
RESULT 65 first= second=       <-- 65th binding destroys v1 and v2
RESULT 66 first= second=
RESULT 70 first= second=
```

The 65th binding's `sc_name[64]` (8 bytes) lands on `sc_val[0]`/`sc_val[1]`
(two int32s), silently wiping the first two variables. A one-word fix
(`SCOPE_MAX = 64`, or grow the arrays to 128) — **deliberately not applied
here**, as this task is forbidden from changing hamsh behaviour.
`user/hamsh.ad:3557` documents a *previously fixed* instance of exactly this
bug class, so it is a known recurring hazard.

### 6.3 More silent-wrong-answer classes

| Input | Correct | hamsh | Note |
|---|---|---|---|
| `f(20)` with `def f(n): return 1 + f(n-1)` | 20 | **12** | `CALL_DEPTH_MAX=12` `:11268` — truncates silently in expression context |
| `1 / 0`, `5 % 0` | error | **0** | `:4757` — no exception |
| `6 & 3`, `6 \| 3`, `6 ^ 3` | 2, 7, 5 | **0** | int bitwise unimplemented, falls through `_arith` |
| `${x:-zz}`, `${#x}` | — | **empty** | unsupported param expansion renders as nothing |

Four independent ways to get a wrong number with no error. This is a systemic
design choice (fail-soft everywhere) that is wrong for a *scripting* language.

### 6.4 Parser robustness — genuinely good

The token-buffer/EOF issue named in the brief is fixed and defended.
`TOK_MAX=4096`; on overflow the lexer explicitly restores the terminator
(`:576–582`): *"TK_EOF leaves tok_kind[TOK_MAX-1] as a non-EOF token"* →
`tok_kind[TOK_MAX - 1] = TK_EOF`. Two `FORWARD-PROGRESS GUARD`s exist —
`parse_block :2448` and `parse_program :3491` ("idle-CPU hang fix") — each
force-advancing on a non-consumable token so a malformed script can never spin.
Parse errors are **line-numbered** and recoverable (`parse error [line 1]: …`,
verified §1.3 case F). Dedicated gates exist:
`scripts/test_hamsh_tok_capacity.sh`, `test_hamsh_rc_token_budget.sh`.
Parser/expression nesting is capped at 12 with clean errors (`:1589`, `:3308`).

**So: the parser is the robust part; the evaluator is the fragile part.**

### 6.5 Other hard caps (none documented in the spec)

`LINE_MAX` 2048 B · `TOK_MAX` 4096 · `NODE_MAX` 16384 (session) · `STR_ARENA_MAX`
32768 B (session) · `VAL_MAX` 16384 (session) · `LISTELEM_MAX` 16384 ·
`FN_MAX` **32 defs** · `FN_NAME_MAX` **16 bytes** · max **16 args**/call ·
`CALL_DEPTH_MAX` **12** · `ARGV_MAX` 64 · `ENV_MAX` **32** · string concat
result **1023 B** · f-string/render result **1024 B** · `source` file **16 KiB
truncated** · `HIST_MAX` 48.

`docs/HAMSH_SPEC.md` documents **none** of these. A reader would not learn that
hamsh cannot recurse past 12 frames or define more than 32 functions.

---

## 7. Verdicts

### Games — ❌ **No. Use Adder.**
Not one shipped game is in hamsh, and that is the correct call. Blockers, in
order: (1) §6.1 value-cell exhaustion makes any game loop produce garbage after
a few thousand frames; (2) no frame pacing, so no controllable frame rate;
(3) no sprites, no audio, 5 draw primitives; (4) 12-deep recursion and 32-def
caps. A rect-and-text Pong is the honest ceiling, and even that will drift wrong
if it runs long enough.

### Simple graphical apps — 🟡 **Marginal; fine for dialogs and tiny tools.**
The `hamui` retained-mode binding is the strong suit — `examples/gui_hello.hsh`
is a real GUI in 45 lines, and a settings dialog or status panel is very
reasonable. Anything animated, image-bearing, multi-window, or long-running
should be Adder. Also note the device-side pixel proof is still missing (§5).

### Shell (interactive + scripting) — ✅ **Yes, this is the right tool.**
This is hamsh's home. It is the real `/init`, it sources every `rc`, and it
does the Plan 9 things bash cannot (`ns { }`, `bind`, `spawn`, `enter`,
`with bind(...)`). Interactive quality is genuinely good: history persistence,
Ctrl-R reverse search, context-aware Tab completion, job control. For the
50–300-line rc scripts it actually runs, it is comfortably better than bash.
The caveats are (a) bash muscle memory breaks on `$?`/`$(…)`/here-docs/`${x:-y}`
and (b) scripts must stay small — which, for rc files, they are.

---

## 8. Ranked gap list

**P0 — correctness (fix before anything else)**
1. **`SCOPE_MAX` 128 vs `Array[64]` overrun** (§6.2). Confirmed memory
   corruption at the 65th variable. One-line fix.
2. **Value-cell exhaustion returns wrong answers silently** (§6.1). At minimum
   *raise* on exhaustion instead of yielding `None`; properly, add reference
   counting or a mark-sweep so loops don't leak. This is the #1 barrier to
   hamsh being trustworthy for anything non-trivial.
3. **Make all silent degradations loud** (§6.3): recursion-cap overflow,
   division by zero, unimplemented int bitwise, unsupported `${…}` forms.
   A wrong number is worse than an error.

**P1 — the bash papercuts a new user hits immediately**
4. `$?` as an alias for `$status` (currently a parse error).
5. `$(...)` as an alias for `` `{ } `` .
6. Here-docs `<<EOF` — currently the body silently executes as commands.
7. `${VAR:-default}` / `${#VAR}` — currently silently empty.
8. `trap`; `PS1`/`PS2`.
9. `[a-z]` glob character classes; capturing a *pipeline* in `` `{ } ``.

**P2 — language reach**
10. **Closures** (lexical capture) — the biggest single gap vs Python; lambdas
    are crippled without it.
11. Raise the caps that bite first: 32 defs, 16 args, depth 12, 32 env vars,
    16 KiB `source`.
12. Real exception values/types instead of string-prefix matching.
13. Hash-based dicts (currently O(n) and string-keyed, so `d[1]` ≡ `d["1"]`).
14. A real module system (`import` is a 9P verb that always errors).

**P3 — graphics**
15. Import the primitives already sitting in `lib/`: `sdl_blit` (sprites),
    `sdl_dev_upload_rgba`, `sdl_fill_round_rect`, and **`sdl_dev_delay`
    (frame pacing)** — all present, none exposed. Cheap, high leverage.
16. Audio builtin (`lib/hamgame` mixer exists, unexposed).
17. Window title/position/resize control; `SDL_WINDOWRESIZE` in the constant table.
18. An on-device screendump gate for `pygame` (§5) — the current device gate is
    structural only.

**P4 — docs**
19. Delete the stale `docs/HAMSH_SPEC.md:695` "No significant-whitespace blocks"
    non-goal (§1.5) — it flatly contradicts §5 and the implementation.
20. Document the numeric caps (§6.5) in the spec; document that `import` is a
    stub; add float/None/function to the §3 value list.
21. Sync `_cmp_init_builtins` (`:15516`) with the real builtin set — completion
    currently omits `pwd`, `jobs`, `fg`, `bg`, `alias`, `read`, `svc`,
    `pygame`, `hamui`, and more.

---

## 9. Artifacts from this review

- `scripts/test_hamsh_dualsyntax_host.sh` — new QEMU-free gate, 8 cases, proves
  indent/brace interchangeability and mixing (§1.3). Not added to the CI
  manifest.
- No change was made to `user/hamsh.ad` or to any shipped script. The two
  confirmed bugs (§6.1, §6.2) are reported, not fixed, per the task's
  no-behaviour-change constraint.
