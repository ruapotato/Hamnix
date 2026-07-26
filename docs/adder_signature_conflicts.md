# One symbol, one signature

*Status: 2026-07-17. Tooling landed; the conflict list below is the current
inventory. Regenerate with `python3 scripts/sema_scan.py --mode conflicts`.*

## The bug that made this necessary

`sys_open` had two declarations:

| where | signature |
|---|---|
| device runtime (`runtime.S` externs) | `sys_open(path: Ptr[char]) -> int32` |
| host runtime (`linux-runtime.S` externs) | `sys_open(path, flags, mode) -> int32` |

Every `*_host.ad` harness declared the 3-arg extern; the `lib/` modules those
harnesses import declared the 1-arg one. `merge_programs` keeps the FIRST
declaration of a public name and silently ignores the rest, so in a host build
one of the two spellings simply vanished. Consequences were real:

* `lib/hamtextbox`'s clipboard read called the 3-arg host thunk with only
  `%rdi` set — `open(2)` received whatever garbage was in `%rsi`/`%rdx` as
  flags and mode;
* 3-arg write-opens lost their flags and opened read-only.

36 call sites across 13 host harnesses. Fixed in `ad33523f`.

## Why the type checker did not catch it

`scripts/sema_scan.py` — the tool used to decide which diagnostic classes can
be promoted to hard errors — merged **the whole tree into one program**. In one
merged program, `sys_open` is one name with two declarations, which is not a
question the checker can answer, so the scan **dropped every public name that
two modules declared incompatibly** (299 of them) to avoid inventing false
positives in modules that are never linked together.

That is precisely backwards: *"same symbol, two incompatible signatures"* IS
the bug. Measured, on the pre-fix tree (`73c3932e`):

```
### OLD scan (73c3932e, as shipped) ###
files parsed: 860 (3 parse failures)
ambiguous public names dropped: 300
arity                 0   error          <-- the 36 sys_open errors are in here
```

## What the rework does

`scripts/sema_scan.py` now has three modes.

### `--mode entry` (default) — the sound scan

For every module with a `def main`, resolve its **real import closure** through
`collect_all_imports` → `merge_programs` (the exact path `adder compile` takes)
and type-check that link unit on its own. A symbol is therefore checked with
the signature its own program actually sees. ~570 link units, ~3 min at 12-way
parallelism. Diagnostics are de-duplicated by *site*, so a bad call reached
from ten entry points is one finding, not ten.

On the pre-fix tree it reports what the old scan could not:

```
### NEW scan, per-entry mode ###  (tree at 73c3932e)
link units checked: 558 (0 unresolvable, 3 parse failures, 12 negative fixtures excluded)
arity                  36   error
ERROR-severity sites: 36 in 13 file(s)
  user/hamnotesscene_host.ad:95:17: error: too many arguments to 'sys_open': 3 given, 1 expected [arity]
  user/hamsheet_host.ad:94:17:      error: too many arguments to 'sys_open': 3 given, 1 expected [arity]
  ... (36 total, all sys_open)
```

On current main the same sweep is clean: 570 link units, **0 error-severity
sites** outside `tests/sema/*` and `tests/app_sugar/err_*.ad`, which are the
deliberately-ill-typed fixtures of `scripts/test_adder_sema.sh` and are
excluded by path.

### `--mode conflicts` — the dedicated detector

A cheap whole-tree pass (~35 s at 12-way; one parse per file, extracting only
declaration shapes) that reports **every public name whose declarations
disagree**, arity or types, with all sites — and classifies each:

* **LIVE** — the disagreeing declarations already co-occur in a real link unit.
  One is silently dropped at merge time, so some caller is compiled against the
  wrong ABI *right now*. This is the `sys_open` bug.
* **LANDMINE** — no link unit sees both spellings today. Nothing prevents one
  from doing so tomorrow, and the compiler would not say a word.

Classification is per-link-unit and honours Adder's real visibility rules: a
`_`-prefixed name is module-private *unless* some module in the same program
does `from M import _name` or declares it `extern`, so a name can be private in
one program and public in another (`_slen` is exactly this — 67 definitions,
promoted only inside the game-scene programs, hence a landmine and not live).

On the pre-fix tree, this 35-second pass names the bug directly:

```
conflicting public names: 355  (LIVE 4, LANDMINE 351)
  LIVE arity conflicts:     1

sys_open  [arity [1, 3], extern/ABI]  304 decls, 3 distinct signatures
    (Ptr[char], int32, int32) -> int32   72 site(s)
    (Ptr[char]) -> int32                228 site(s)
```

### `--mode merged` — the legacy pass

Kept only for the corpus-wide per-class site counts that inform
`sema.DEFAULT_SEVERITY`. It is documented in-file as **unsound for finding
bugs**, and now prints its dropped-name count as `<-- BLIND SPOT`.

## The gate

`scripts/test_sema_signature_conflicts.sh`, registered in
`scripts/ci_battery_manifest.txt` twice:

| line | cost | what it does |
|---|---|---|
| `bash scripts/test_sema_signature_conflicts.sh` | ~40 s | conflict detector vs `scripts/sema_conflicts_baseline.txt` + three teeth tests |
| `bash scripts/test_sema_signature_conflicts.sh --full` | ~3 min | the whole per-entry-point sweep |

**Why split.** The battery is round-robin sharded under a 50-minute cap, and a
gate that costs 3 minutes competes with QEMU boots for a shard. The cheap
detector is the one that names the bug class directly, so it gates every push
unconditionally; the full sweep is a separate line that can be shard-balanced
without disarming the conflict check. Both are host-only, no QEMU.

The gate has teeth, asserted every run:

1. the `sys_open` shape reconstructed — a synthetic module declaring a 3-arg
   `sys_open` next to `lib/`'s 1-arg extern must be reported **LIVE** with
   `arity [1, 3]`;
2. a brand-new conflicting extern in a throwaway subtree must fail against an
   empty baseline with `NEW CONFLICT [LIVE]`;
3. per-entry resolution must still report a known arity error in a real link
   unit.

The baseline is **shrink-only**: a conflicting name that is not in it fails the
build, and a baselined LANDMINE that becomes LIVE fails the build.

## The current inventory: 344 conflicting names

`LIVE 0, LANDMINE 344. Arity conflicts 67 (0 of them live). extern/ABI 0.`
Full list with every site: `python3 scripts/sema_scan.py --mode conflicts`.
Names only (the baseline format): add `--names-only`.

### Tiers 1 and 2 — RESOLVED

Every extern/ABI conflict (the `sys_open` tier) and every LIVE conflict is gone.
The tree went from `LIVE 3 / extern-ABI 12` to `LIVE 0 / extern-ABI 0`. What was
done, and why each spelling won:

| name | resolution |
|---|---|
| `sys_execve` | **Real landmine removed.** `user/runtime.S` defines TWO thunks: `sys_execve(path, argv)` — which *deliberately* `xorq %rdx, %rdx` so the kernel's SYS_EXECVE never snapshots a stale caller register as `envp` — and `sys_execve_env(path, argv, envp)`, the genuine 3-arg form. `user/nsrun.ad` declared `sys_execve` as 3-arg, so its third argument was written into `%rdx` and then unconditionally *discarded by the thunk*. nsrun passed 0, so behaviour was correct by luck; any future caller passing a real env array would have silently lost it. nsrun now uses the 2-arg form (the true ABI of that symbol), matching `getty.ad`, `init.ad` and `hamsession.ad`. Callers that need an env array must use `sys_execve_env`. |
| `sys_exit` | Unified on `(code: uint64)` with **no return type**. The thunk `jmp`s to itself if the syscall ever returns, so `-> int32` (2 host harnesses) was a lie about a noreturn function; `uint64` is both the majority (125 sites) and matches the kernel reading `a0` as a 64-bit word. 21 minority decls rewritten. |
| `sys_yield` | Unified on `() -> int32`. The thunk `ret`s with the syscall's `%rax`, and the kernel documents "returns 0", so a value genuinely comes back; `-> None` (20 sites) discarded a real return. Majority spelling (63 sites) also wins on count. |
| `p9_note` | `tests/test_errstr_coverage.ad` declared `extern def p9_note(pid: uint64, sig: uint64)` *and* did `from lib.p9 import p9_note` in the same file. The extern was deleted; the real `def (int32, Ptr[uint8]) -> int32` in `lib/p9.ad:581` is authoritative, and the call site already passed a `Ptr[uint8]`. |
| `sys_nanosleep` | Unified on `(Ptr[uint64], Ptr[uint64]) -> int64`. Both `req` and `rem` are user pointers to `struct timespec` per `user/runtime.S` and the SYS_NANOSLEEP kernel entry; the `rem: uint64` spelling was a pointer typed as an integer. |
| `kmalloc` / `kfree` | `lib/font_bdf.ad` carried `extern` decls for both that **nothing in the file calls**, spelled with the userland `Ptr[uint8]` shape rather than `mm/slab.ad`'s `uint64` handle ABI. Dead declarations deleted; `mm/` untouched. |
| `sys_open` / `sys_open_write` | Unified on `Ptr[char]` (300 / 176 sites). The 3+2 `Ptr[uint8]` decls in host test harnesses now cast at the call site. |
| `sys_waitpid` | Unified on `(pid: int32) -> int64`. A pid is a signed 32-bit value everywhere else in the tree and the thunk zeroes `%esi` (flags) around a 32-bit pid; 12 `uint64` decls and their `cast[uint64]` call sites rewritten. |
| `sys_getcwd` | Unified on `-> int64` (13 sites); the single `-> int32` truncated a 64-bit return. |
| `print_u64` | Unified on `-> int32` (11 sites); the single `-> int64` was a bench-harness typo. |

What remains is Tier 3 and Tier 4 — same-named *local helpers* in unrelated
applications. Those are not ABI bugs and are not unifiable; see below.

### Tier 3 — arity landmines among plain `def`s (67)

Two applications that each grew a local helper with the same obvious name.
Harmless while they never link, and they are *not* trivially unifiable — the
two functions genuinely do different things. The real fix for this tier is to
rename one side or make it `_`-private, not to unify signatures. The worst
offenders, by disagreement:

```
emit           [1, 2, 3, 4]   17 decls,  7 distinct signatures
check          [0, 1, 2, 3]    6 decls,  5 distinct signatures
load_file      [0, 1, 2]       7 decls,  4 distinct signatures
put_dec        [1, 2, 3]       8 decls,  4 distinct signatures
_bytes_eq      [3, 4]          8 decls,  4 distinct signatures
str_eq         [2, 4]         10 decls,  4 distinct signatures
emit_line      [0, 1, 4]       4 decls,  3 distinct signatures
parse_pointer  [3, 5, 6]      18 decls,  3 distinct signatures
split_lines    [0, 4, 5]       4 decls,  3 distinct signatures
write_str      [1, 2]        214 decls,  3 distinct signatures
write_dec      [1, 2]         47 decls,  3 distinct signatures
resolve_path   [1, 3]          3 decls,  3 distinct signatures
parse_u64      [1, 3]         11 decls,  3 distinct signatures
parse_int      [1, 2]         11 decls,  3 distinct signatures
http_get       [4, 6]          2 decls,  2 distinct signatures
emit_scene     [1, 2]         27 decls,  2 distinct signatures
```

`main [0, 2]` also appears (`main()` vs `main(argc, argv)`); it can never go
live, since a link unit has exactly one `main`, but it is left in the list
rather than special-cased so the detector has no exceptions to be wrong about.

### Tier 4 — type-only landmines among plain `def`s (~280)

`_slen`, `cstr_len`, `parse_uint`, `hex_digit`, `name_len`, the `parse_*`
recursive-descent family, … Same story as tier 3, without the arity hazard.
Listed in `scripts/sema_conflicts_baseline.txt`; details on demand from the
detector.

## How to use it

```sh
# is anything conflicting that was not already known?      (~40 s, CI gate)
bash scripts/test_sema_signature_conflicts.sh

# full picture, ranked, with every declaration site         (~35 s)
python3 scripts/sema_scan.py --mode conflicts

# does the tree type-check, program by program?             (~3 min)
python3 scripts/sema_scan.py --mode entry \
    --exclude 'tests/sema/*' --exclude 'tests/app_sugar/err_*.ad'

# after unifying a signature, drop its line from the baseline —
# the gate prints "RESOLVED (drop from the baseline): <name>".
python3 scripts/sema_scan.py --mode conflicts --names-only
```
