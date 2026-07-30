# Leak pass 17 — hamsh does not leak per command, and the last blind allocator is attributable

Base `6af2c007` (after pass 16). Pass 16 retired every kernel COW share path
on counted quantities and handed over one residue and one blind spot:

> Arm 23 grows `+2 +2 +3 +2 +3` per cycle ... **every survivor is mapped by a
> live owner** ... it is memory a userland process is holding, which no kernel
> teardown can reclaim. **The next pass belongs in `hamsh`, not in `mm/`.**

> **Teach `region_alloc` to stamp a per-frame site and owner.** It is the
> single remaining blind spot in the whole instrument.

This pass answers both, and the answer to the first is **not** the one the
brief expected: hamsh strands nothing.

---

## 0. The measurement — a FLOOR, not an occupancy sample

`hamsh` allocates out of module-scope arenas and collects them with a
mark/compact collector (`gc_collect`). Occupancy is therefore a **sawtooth**:
allocate until `_maybe_recycle_arenas` trips, collect, repeat. That is exactly
why the existing gate (`test_hamsh_arena_soak_host.sh`, which asserts the
`arenas` line DROPS at least once) cannot answer this pass's question. A shell
that stranded one node per command would still show the line dropping, on
every collection, forever — while dying a little sooner each time.

The quantity that separates *allocating* from *leaking* is the **floor**:
occupancy **immediately after a collection**. Anything the mark phase cannot
reach is precisely what survives one. So this pass adds `arenas gc` — force a
collection, then print — which makes the floor samplable on demand instead of
only where the sawtooth happens to land.

Everything below is a **count read out of the shell's own tally**, compared by
**exact equality**. No soak mean appears anywhere, for the reason passes 14–16
established: two byte-identical builds of this system differ by 6.4 pg/cycle.

---

## 1. THE ANSWER — hamsh strands nothing per command

Three **identical** sweeps of 16 command classes (`echo`, `assign`, `strcat`,
`list`, `dict`, `ifelse`, `forloop`, `tryexcept`, user-function `call`,
`alias`/`unalias` cycle, `pushd`/`popd`, nested capture, `listappend`,
`slice`, ternary, `$( )` substitution), floor sampled after every class, with
a live `def` and a live list variable held across every collection:

```
after sweep 1:  nodes=8 kids=3 vals=23 elems=11 str=47 scope=11 fns=1 aliases=0
after sweep 2:  nodes=8 kids=3 vals=23 elems=11 str=47 scope=11 fns=1 aliases=0
after sweep 3:  nodes=8 kids=3 vals=23 elems=11 str=47 scope=11 fns=1 aliases=0
```

**Byte-identical, on all eight counters.** The assertion is deliberately NOT
"the floor is zero": sweep 1 legitimately creates the bindings the classes
name (`c`, `LL`, `DD`, `q`, `w`, a `def`, an alias), and a collector that
dropped those would be a bug. Sweep 2 and 3 REBIND the same names, so
everything legitimate cancels and only unreachable residue could show.

Per class, S2 vs S3: **zero classes move the floor**.

### The positive control, because an equality can pass vacuously

Pass 16 nearly published two false exonerations from instruments whose zero
meant "nobody looked". So the gate plants **one genuinely new, genuinely
reachable binding** after sweep 3 and REQUIRES the floor to move:

```
after the plant: nodes=8 kids=3 vals=24 elems=11 str=64 scope=12 ...
```

It moves on three counters. If it did not, the equality above would be
vacuous, and the gate **fails** rather than printing green.

---

## 2. AND THE RESIDENT SET IS FLAT TOO — 361 consecutive identical samples

The floor result covers the arenas. It does not by itself cover what pass 16
actually measured, which was **frames**: hamsh's arenas are BSS, and BSS is
demand-zero, so a shell whose arenas fill grows its resident set even with a
perfect collector.

Measured directly, on the same host seam, sampling `/proc/<pid>/statm` every
5 s while the shell ran ~24,000 commands (echo / assignment / if-else /
try-except / user-function call, with a `def`, a list and an alias live
throughout):

```
RSS samples: 363
  449 pages   x 1     (t = 0 s, still starting up)
  542 pages   x 361   (t = 5 s .. 1805 s)
```

**Exactly two distinct values, ever.** 542 pages = 2.12 MiB, reached inside
the first five seconds and then not moved by a single page for thirty minutes,
across **16 collections** (`gc=16` in the transcript) and full sawtooth
excursions (`nodes` ranged 1075 → 14915 → 3511 → 14915 …).

**This is what arm 23's `+2 +2 +3 +2 +3` is.** It is a **ramp to a bounded
high-water**, not a slope — the shell faulting in its arena pages as it fills
them for the first time, which terminates. Pass 16 could not tell a ramp from
a slope because six cycles is inside the ramp. Thirty minutes and 361
identical samples is outside it.

**hamsh is exonerated on counted quantities.** So is the residue pass 16
attributed to it.

**What this does NOT establish**, stated rather than implied: this is the
x86_64-linux build of the *same source*, driven over a pipe. It shares every
arena, every table and `gc_collect` itself with the device build, which is why
the seam is meaningful — but it is not the device, and it does not speak to
the eight other apps in the DE soak pool. Pass 16's third open question ("point
this gate at the other eight apps") is untouched and is now the leading one.

---

## 3. THE REAL BUG IN hamsh WAS A SILENT CAP, NOT A LEAK

Hunting hamsh's arenas found no leak. Hunting its **caps** found a live one of
exactly the class the zero-leak directive calls out — *"these do not leak, they
silently stop working, which is worse because nothing reports it."*

`FN_NAME_MAX` was 16. `exec_def` truncated the function name at 15 bytes with
**no error and no counter**, while every lookup (`call_user_fn`, `exec_def`'s
own replace scan, completion) compares the stored — truncated — name against
the caller's **full** name with `cstr_eq`. Measured, before:

```
def my_very_long_function_name(k) { return k + 1 }
DEFOK 0                                                  <- reported SUCCESS
r = ${ my_very_long_function_name(1) }
hamsh: runtime error: call to undefined function
       'my_very_long_function_name' — was its `def` ever run?
def my_very_long_function_name(k) { return k + 2 }       <- redefine
arenas ... fns=2                                         <- SECOND slot burned
```

Two failures, and the second is the uptime one:

* The `def` reports success and the failure is delivered later, at the CALL,
  by a diagnostic pointing miles from the cause — **the identical symptom the
  `FN_MAX = 32` fix was written to kill**, resurfacing through a different
  limiter.
* The replace scan can never match either, so **re-defining the same
  long-named function takes a NEW registry slot every time**. An rc file or a
  shell library that re-sources long-named helpers burns slots monotonically
  until it hits the hard `FN_MAX` — a silent cap feeding a hard one. That *is*
  a leak, in the only table where hamsh had one.

Fixed two ways, because refusing a name is worse UX than storing it:
`FN_NAME_MAX` is now 64 (512 × 64 = 32 KiB BSS, up from 8 KiB — a measured
+24,576 bytes, paid once, in a process whose arenas already total ~4 MiB), so
real shell-library names fit; and a name that **still** does not fit now
`rt_raise`s at the `def` instead of mis-registering. After:

```
==LONGDEF   st=0
==LONGCALL  lr=15 st=0        <- 25-char name registers AND calls
==LONGREDEF lr=25             <- redefinition took effect
arenas ... fns=2/512          <- g0 + the long name. NOT three.
==OVERDEF   st=1              <- 70-char name REFUSED, loudly
arenas ... fns=2/512 aliases=1/512   <- the refusal consumed no slot
```

A second, same-shaped one closed alongside it: `builtin_alias` truncated names
at 127 bytes into `_alias_name_scratch` and then **listed the truncated name**,
so even reading the table did not reveal the mis-binding. Now refused with
`status 1` (`==OVERALIAS st=1`), while a normal alias still binds
(`==OKALIAS st=0`, `aliases=1/512`).

And the readouts that would have caught both: `arenas` now prints `fns` **with
its cap** and the alias table at all. A cap you cannot watch approaching is a
silent cap with extra steps.

---

## 4. THE OTHER NAMED SILENT CAPS — audited, and mostly already closed

Four were carried forward as open. Audited against the tree, they are not:

| cap | status | evidence |
|-----|--------|----------|
| `timer_*` "stops at 4096 turns" | **CLOSED** | free list makes 4096 a *simultaneously-pending* ceiling, not a lifetime one; overflow increments `timer_overflow`, latches a `CEILING timer table full ... being DROPPED` note and `set_error`s (`lib/web/js/builtins/timers.ad:23-30`); counters at `js_arena_stat` 20-25 |
| `pr_*` promise reactions | **CLOSED** | `pr_overflow` + latched `CEILING promise reaction pool full` + `set_error` (`lib/web/js/builtins/promise.ad:68-75`); free list; stats 28-33 |
| `mse_*` "caps at 131072" | **CLOSED** | `mse_overflow` + latched `CEILING Map/Set entry pool full` (`lib/web/js/builtins/collections.ad:41-45`); free list fed by `obj_gc_free`; stats 34-39 |
| `sp_buf` "bytes never reclaimed" | **TRUE, BY DESIGN — and now watchable** | the collector is non-moving; it reclaims ID slots and permanently orphans the bytes, because builtins hold raw `&sp_buf[..]` pointers across a collection. Exhaustion is loud (three `CEILING string pool exhausted` sites) but there was **no readable pressure counter**: `js_arena_stat` index 6 reports string IDs, which the collector *does* reclaim, so it sits flat while the lifetime byte budget drains underneath it. **Added indices 47 (`sp_top`) and 48 (`SP_CAP`).** |

A ceiling observable only by hitting it is not meaningfully different from a
silent one, which is why 47/48 are worth the two switch arms.

---

## 5. `region_alloc` IS NOW ATTRIBUTABLE

Pass 16's §8.1. `region_alloc` never went through the buddy allocator — it
first-fits a pooled chunk or cold-misses into memblock — so not one of its
frames carried a per-frame site or owner. That is why the ELF image and
PT_INTERP reported under **site 0**, why the census had to scope itself to
`USER-MAPPED sites only`, and why arms 1 (W^X verbatim share, 101 survivors)
and 19 (ELF image span, 20 survivors) stayed **unadjudicated**.

`PA_SITE_REGION = 21` is **appended** (ids 1..20 keep their frozen values, so
archived pass-6..16 logs still read correctly). Attribution reuses the same
one-shot pending-slot protocol `alloc_pages` uses — `pa_set_site` /
`pa_set_owner` — except that an **unnamed caller falls back to
`PA_SITE_REGION` rather than `PA_SITE_UNKNOWN`**, because UNKNOWN is the one
bucket whose growth cannot be acted on and for a region there is always at
least one true thing to say.

Two things the implementation had to get right, both of which are instrument
bugs of the kind that print a green over a leak:

* The stamp runs **under the region lock and boot CR3** — the guard
  `region_alloc` already takes for its raw-physical free-list header writes.
* `region_free` untallies **BEFORE its coalesce**, under the same lock. The
  coalesce mutates `addr`/`rsize` to describe the **merged** chunk, whose
  neighbours were already untallied when *they* were freed; untallying
  afterwards would credit one free with frames it does not own and clamp the
  site's live count to a false zero.

Disarmed cost is unchanged: `_pa_trk_stamp_region` returns on the same
`_pa_trk_site == 0` load-and-compare every other tracker hook uses. `order` is
parked at 15 ("not a buddy order"), which the buddy allocator cannot emit, so
no consumer can mistake a region for an order-15 run. `_build_meminfo` is
untouched.

**Every allocator in the tree is now attributable.**

---

## 6. PASS 16's OWN GATE WAS REPORTING A FALSE GREEN

`scripts/test_cow_hamterm_origin.sh` guarded on `[ -e /dev/kvm ] || exit 0`.
GitHub runners have no `/dev/kvm`. So on **every CI run since it was
registered** it reported GREEN having asserted nothing whatsoever about COW
origins — the exact false-green class `scripts/test_gate_kvmdark.sh` exists to
ratchet against, and it was that ratchet's only red. It now exits **125
(INCONCLUSIVE)**, so `ci_run_gate.sh` warns instead of counting the run as
proof. `test_gate_kvmdark.sh` is back to PASS with its population still frozen
at 20 — no baseline line was added.

---

## 7. Gates actually run

```
[kobjdiff]      PASS — zero semantic divergences, 11371 matched kernel functions
[percmd-floor]  PASS — every check; driver rc=0
[test_cow_fork]  PASS -- copy-on-write fork keeps parent/child private
[test_mmap_fork] PASS -- COW fork over an mmap VMA keeps parent/child private
[mm-zap]         PASS -- _vma_free_cow_range zaps+flushes before freeing;
                         task_reap returns the user stack COW-safely
[gate_registration] PASS
[gate_softgreen]    PASS
[gate_kvmdark]      PASS (20 dark gates, population frozen) — was FAIL on base
[js-asyncpools]     PASS (10 adversarial retention cases, gc-stress identical)
native x86_64-adder-user hamsh                     compiles
```

### 7a. The new gate is mutation-proven, not merely green

Two mutations, each reverted after its run:

| mutation | what it simulates | result |
|---|---|---|
| `gc_collect` roots **every** node, not just reachable ones | a collector that cannot tell garbage from live | **check1 + check1b RED**, and check1b named **all 16 classes** |
| `FN_NAME_MAX` back to 16, length refusal disabled | the silent cap as it shipped | **check3, check3b, check4, check6 RED** — and check6 read **`fns=4`**, i.e. one `g0` plus **three** separate slots burned by what should have been one function defined and redefined. The registry burn reproduces on demand. |

The gate is therefore sensitive to both things it claims to measure, and the
working tree is clean afterwards (`git status` empty).

### 7b. One host-seam caveat, recorded rather than "fixed"

`hamsh --no-echo < script` **never exits** on the host build (measured: rc=124
without a trailing `exit`, rc=0 with one). On the device the contract is
unambiguous — `sys_read_nb` reports `>0` bytes, `0` = would-block, `-1` = EOF
(`sys/src/9/port/devfd.ad:633`) — and `ed_readline` handles all three. The
x86_64-linux shim cannot make that distinction for a redirected regular file,
whose EOF read returns 0, which the editor loop reads as "stdin idle". So it
is a host-seam artifact, **not** a device uptime bug, and the gate's driver
ends with an explicit `exit` rather than the shell's read loop being changed
on the strength of a host-only symptom.

**NOT run, stated rather than implied:** `scripts/test_de_visual_gate.sh`, and
a DE soak with a SIGTERM audit. The `region_alloc` stamping is verified by
kobjdiff and by construction; it has **not** been exercised on device, so arms
1 and 19 are *now instrumented* but **not yet adjudicated**. That is a new
capability, not a new result, and it is stated that way on purpose.

---

## 8. The next counted questions

1. **Re-run `test_cow_hamterm_origin.sh` on a KVM host and adjudicate arms 1
   and 19**, which now have owners. This is the first pass where their
   `owner-dead = 0` can mean something. One boot, no soak.
2. **Point the origin gate at the other eight DE apps.** hamsh is exonerated
   and the terminal path is retired; if a residual slope survives, it belongs
   to something neither gate launches. This is now the leading question.
3. **Settle the site-20 orphan** (pass 16 §4) by asking whether its PFN lies
   inside a live task's recorded ustack run. One frame, one predicate.
