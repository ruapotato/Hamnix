# Leak pass 18 — every orphan in the machine is now accounted for, and all nine DE apps are adjudicated

Base `28110946`. Pass 17 closed with three counted questions. This pass
answers all three.

The headline is a **counted** one, not a soak mean: after 32 app open/closes
across the eight DE apps no earlier gate had ever launched, a whole-machine
reachability census with both controls green reports **one** orphaned frame
in the entire system — **the control this gate plants on purpose**. Every
other frame the census could not reach through a page table was shown, by a
predicate rather than an argument, to lie inside a live task's
wholesale-return run.

---

## 1. THE SITE-20 ORPHAN IS ACCOUNTED FOR — one predicate, one boot

Passes 16 and 17 saw orphan counts of 2, 1, 2 over three runs: the planted
control plus **at most one** further frame, always `PA_SITE_EXECVE`,
intermittent and never growing. Neither pass could say what it was, because a
count cannot separate the two stories that fit that shape — and they have
opposite consequences.

`_mm_phys_live_run()` (`kernel/sched/core.ad`) asks the question that can:
**does this frame lie inside a run that some LIVE task will hand back
WHOLESALE, by physical base** — `image_phys`, `interp_phys`, `ustack_phys`,
`ustack_base`? It is the same rule `_mm_leaf_unreclaimed` already applies at
reap time, asked of a physical frame instead of a leaf, so the two
instruments cannot disagree about what "accounted for" means.
`_mm_census_runcheck()` applies it to every orphan at every user-mapped site
and prints, per site, collected / in-run / UNACCOUNTED.

Measured on KVM, `test_cow_hamterm_origin.sh`, four `hamtermscene`
open/closes (`build/cow_hamterm_origin/20260730-153452`):

```
[cens3] site 6  orphan[0] phys=0x1514a000  inrun-slot=0   run-span=0
[cens3] site 6:  1 orphan(s) collected, 0 inside a live run, 1 UNACCOUNTED
[cens3] site 20 orphan[0] phys=0x159b1000  inrun-slot=23  run-span=3
[cens3] site 20: 1 orphan(s) collected, 1 inside a live run, 0 UNACCOUNTED
```

The site-20 frame lies inside **task slot 23's execve eager user-stack run**
(span 3 = `ustack_phys`). That prefix is allocated as ONE contiguous run and
only the pages the process has actually touched carry a user PTE, so a census
whose only oracle is a page-table walk honestly reports the untouched
remainder as unreachable — while `free_pages(ustack_phys)` at reap returns
it. Which is why it was intermittent (it depends on how far that process had
walked its stack when the census ran) and why it never grew (it is bounded by
the run).

**Not a leak. No teardown change could or should reach it.**

### The predicate proved sensitive in BOTH directions, in the SAME sweep

An instrument that answered "in a run" for everything would print the same
reassuring zero. It did not: in one sweep it returned **in-run** for the
execve frame and **UNACCOUNTED** for the planted control, which is mapped
nowhere and therefore lies in no run by construction. So the plant is the run
predicate's own positive control for free, and both gates now **FAIL** a
run-check that reports zero UNACCOUNTED while a plant is outstanding —
"every orphan explained" includes one that cannot be, and that is
over-claiming, not cleanliness.

Truncation is refused rather than swallowed: `page_alloc_orphan_collect`
stops at `PA_ORPH_CAP` (64), so a site whose collected count falls short of
its tallied count is declared `TRUNCATED` and treated as INCONCLUSIVE.

### The terminal gate had been condemning its own blind spot

`test_cow_hamterm_origin.sh` FAILED this run under its old rule ("orphans > 1
= a leak"). That rule turned an instrument limitation into a bug report. It
now judges UNACCOUNTED, and **re-adjudicating the same captured serial log
with the new rule turns the run from FAIL to PASS with no measurement
changed.**

---

## 2. ALL EIGHT NON-TERMINAL DE APPS, ADJUDICATED SEPARATELY

`scripts/test_cow_deapps_origin.sh` launches the eight apps neither existing
origin gate ever touched — `hamwrite`, `hamsheet`, `hamslides`, `hamfmscene`,
`hammonscene`, `hamaudioscene`, `hamcalcscene`, `hambrowse --demo` — one app
at a time, four identical open/close cycles each (three inter-cycle deltas
per app), closing each window the way the DE's own close box does. One boot,
32 launches (`build/cow_deapps_origin/20260730-155517`).

| app | arm 23 nets | verdict |
|---|---|---|
| hamwrite | +1 +3 +2 | RESIDENCY (owner-dead 0, owner-stray 0 of 44) |
| hamsheet | +2 +3 +2 | RESIDENCY |
| hamslides | +1 +0 +0 | closed |
| hamfmscene | +0 +3 +6 | RESIDENCY |
| hammonscene | +0 +0 +0 | closed |
| hamaudioscene | +1 +0 +0 | closed |
| hamcalcscene | +0 +0 +2 | RESIDENCY |
| hambrowse | +0 +3 +0 | closed |

Arms 0 and 5 are `+0 +0 +0` for **all eight**. Arms 1, 2, 19, 21 and 24 had
**no live survivors at all** in this run (`TOTAL=0`), which is exactly right
and is stated rather than glossed: **none of these eight apps forks**, so
none of them reaches the image-share or fork-copy paths. Their zeros are
about a path that never ran, and that is not an exoneration of the path —
`hamtermscene` is the app that exercises it and it has its own gate.

Every positive net was adjudicated by the owner discriminator, not by its
sign: `owner-dead = 0` and `owner-stray = 0` over 44 survivors, i.e. every
surviving frame is still mapped by the live task that allocated it.

**The whole table reproduced exactly on a second, independent boot**
(`build/cow_deapps_origin/20260730-162048`, a different machine instance —
its planted control landed at a different physical frame, `0x14c97000` vs
`0x14e13000`): the same eight apps, the same three nets each, the same
verdicts, and the same single planted orphan. Two identical readings of a
per-frame count are worth more than any number of soak means, because passes
14-16 established that two byte-identical builds differ by 6.4 pg/cycle on
the aggregate.

### The census, whole-machine, after all 32 launches

```
positive control (track plant)  : OK
negative control (track mplant) : OK
orphaned frames                 : 1
[census] planted control orphan phys=0x14e13000 tag=0xc0ffee00
[cens3]  site 6 orphan[0] phys=0x14e13000 → in no run, UNACCOUNTED
```

**The only unreachable frame in the machine is the one the gate planted.**
Both controls green in the same sweep, and the run predicate accounted for
everything else.

### A false red the gate caught on itself

Its first run accused `hamwrite` and `hamsheet` of a named slope at site 6
(`vma_anon`), which grew on every delta for both. They are innocent and the
accusation was the gate's own: `track plant` allocates its control frame **at
`PA_SITE_VMA_ANON`**, so the deliberately-unreachable positive control sits
in the very per-site bucket the growth rule reads. The plant is now
identified by **physical address** and discounted from its own site; the
total rule got stricter at the same time (sum of UNACCOUNTED after the
discount must be **zero**, and a run where the plant's phys was never printed
is INCONCLUSIVE, because a plant you cannot identify cannot be discounted).

Site 6 does grow across the run — 11 → 39 live frames over 32 launches — and
that growth is *reported*, never waved away. But every one of those frames is
reachable from a live task's page tables, which is the resident-set ramp
pass 17 characterised over 361 identical RSS samples, not a leak. Pass 17's
lesson is written into the rule: a monotone site is **flagged**, then
adjudicated against the census, and condemned only if the census finds
unexplained frames there.

---

## 3. ARMS 1 AND 19 — CLEARED, and the half that was still vacuous is fixed

Pass 17 called them "instrumented, not adjudicated". Booted:

```
arm  d2 born/died/net   d3               d4
1     124/124/+0        124/124/+0       124/124/+0
19     38/ 39/-1         38/ 37/+1        38/ 39/-1
```

Arm 1 is **exactly balanced on all three inter-cycle deltas**; arm 19
oscillates about zero. That is the quantity that clears them, and it is the
one this campaign trusts: a per-cycle leak is a constant positive net on
every later cycle.

The owner half, however, was still blind:

```
arm 1   TOTAL=101 owner-dead=0 owner-unrecorded=101 stray=0
arm 19  TOTAL=20  owner-dead=0 owner-unrecorded=20  stray=0
```

`owner-dead = 0` over a population whose owner was **never recorded** means
"nobody wrote an owner down". Pass 17 gave `region_alloc` a per-frame SITE
but nothing ever named an OWNER — so for the two arms that work was done for,
the discriminator still could not speak. The pending-slot protocol was
already wired through `_pa_trk_stamp_region`; it needed the ELF loader to
name itself, which is one `pa_set_owner(current_idx_get())` at each of the
two `region_alloc` sites in `fs/elf.ad`.

**And the second run needed it.** A repeat of the same gate on the fixed
build (`build/cow_hamterm_origin/20260730-160632`) did NOT come out balanced
— arm 1's last net was `+23`, arm 19's `+16`, arm 21's `+62` — so the delta
alone would have left all three UNADJUDICATED. With the owner recorded they
adjudicate cleanly:

```
arm 1   TOTAL=101 owner-dead=0 owner-unrecorded=0 stray=0 untagged=101
arm 19  TOTAL=20  owner-dead=0 owner-unrecorded=0 stray=0 untagged=20
arm 21  TOTAL=63  owner-dead=0 owner-unrecorded=0 stray=0 untagged=63
```

`owner-unrecorded` went 101 → 0 and 20 → 0: every survivor is owned by a task
that is still alive. `untagged` is high because a region allocation stamps at
most one VA for a whole run, which is structural and is reported as its own
number rather than swept into `stray` — the false red pass 16 walked into.
The verdict is RESIDENCY on both arms, from the discriminator rather than
from an argument.

---

## 4. A SILENT CAP, of exactly the named class: the per-pid wid table

`devwsys`'s `_wsys_pending_put` / `_wsys_pending_take` deliver a freshly
allocated wid to the allocating process by pid. An entry was only ever
removed by the OWNING pid's readback — so a process that allocated a window
and died before reading it back (a crash, a close box during startup, a
`kill` mid-launch: things the DE soak does dozens of times an hour) left its
entry behind **forever**. Thirty-two of those and the table is permanently
full, at which point every concurrent launch silently falls back to the
single global `wsys_last_alloc_wid` — i.e. back to the exact cross-delivery
bug this table was added to fix ("taskbar shows only ONE of N open windows"),
with nothing anywhere reporting that it happened.

It does not leak memory. It silently stops working, days later, as a UI bug
with no diagnostic — the shape of pass 17's `FN_NAME_MAX`.

* a full table now PRUNES entries whose pid is no longer a live task, so 32
  is a ceiling on SIMULTANEOUSLY-PENDING allocations rather than on lifetime
  ones (the `timer_*` / `pr_*` / `mse_*` fix shape);
* overflow is COUNTED and latches one loud `CEILING` note;
* occupancy carries a high-water mark and `wsys_pending_stat()` exposes
  occupancy / hi / evicted / overflow / stale / capacity — a ceiling you
  cannot watch approaching is a silent cap with extra steps;
* and **a pid is not an identity over months of uptime**. The allocating
  task's SLOT is recorded too, so a pid match with a slot mismatch is a
  tombstone from a recycled pid: cleared, counted, refused. Serving a dead
  task's wid to a live task that inherited its number is worse than the cap —
  that task then drives somebody else's window.

The existing boot selftest (`wsys_multiwin_taskbar_selftest`, run by
`scripts/test_de_multiwin_taskbar.sh`) grows two legs: **Part C** fills the
table with dead pids and requires one more put to land WITHOUT incrementing
the overflow counter; **Part D** pokes a slot mismatch onto a live pid's
entry and requires the take to be refused AND counted.

### The other named caps, audited

`hamsh` alias-65 and def-33 were carried forward as open. They are not:
`ALIAS_MAX` and `FN_MAX` are both **512**, both overflow paths `rt_raise`
loudly (`alias: too many aliases (ALIAS_MAX=512) — alias NOT defined`, `def:
too many functions (FN_MAX=512) — function NOT defined`), and `arenas` prints
both tables **with their caps**, so the pressure is watchable. Pass 17's own
transcript already read `fns=2/512 aliases=1/512`. Closed.

---

## 5. THE INSTRUMENT WAS TRUNCATING ITSELF — 35 diagnostics, 14 of them ours

Read in this pass's own serial log:

```
[census] scope: USER-MAPPED sites only. kernel sites[census] control OK: ...
[cens3] site 6 orphan[0] run-span=0[cens3] site 6: 1 orphan(s) collected...
```

Adder silently drops adjacent string-literal concatenation, so a
multi-fragment `printk` emits its FIRST fragment and nothing else —
**including the trailing newline**, which merges the next message onto the
same line. The census had been documenting its own scope in a sentence that
stopped at "kernel sites"; half of every multi-line diagnostic in `mm/` has
been missing for as long as it existed.

35 call sites tree-wide, **14 of them in this campaign's own instruments**
(`mm/page_alloc.ad` ×8, `kernel/sched/core.ad` ×6). Every gate here greps
that log and several match anchored patterns, so a swallowed newline is not
cosmetic — it is one merged line away from a gate that greps for a marker and
does not find it. All 35 are mechanically joined into single literals:
semantically identical if the concatenation had worked, a fix where it did
not. Verified in band afterwards — the run-span legend and the full
`orphan(s) collected` sentence now print, on their own lines.

The language-layer fix (make the parser concatenate, or REJECT the construct
loudly) is named below rather than attempted here.

> **CLOSED 2026-07-30 by `d3a04b6e`** (annotated 2026-08-03). The native
> parser now CONCATENATES, matching the Python seed, which had concatenated
> all along — so this was a seed/native semantic divergence, i.e. a
> miscompile, not merely a missing feature. Gate
> `scripts/test_compiler_adjacent_strings.sh`, registered in
> `ci_battery_manifest.txt`. The item below is therefore DONE; do not
> re-dispatch it.

---

## 6. Gates run

```
[cowapps]   PASS  — 8 of 8 apps adjudicated, 32 open/closes, census reports
                    ONE orphan (the plant), both controls green, run
                    predicate clean. Run TWICE end to end: the first run
                    FAILED on the gate's own plant-in-the-growth-bucket bug
                    (§2); after the fix a fresh boot passes end to end
                    (20260730-162048) AND re-adjudicating the first run's
                    UNCHANGED serial log also passes, with identical nets.
[cowterm]   PASS  — 4 cycles, arms 1/19/21 adjudicated by the newly recorded
                    owner, site-20 orphan accounted for, census 1 orphan
[kobjdiff]  PASS  — zero semantic divergences across 11380 matched kernel
                    functions
[multiwin]  PASS  — and the new legs ran:
                    [MULTITASK_BAR] pending table: cap=32 hi=3 evicted=32
                                    stale-refused=1 overflow=0
                    i.e. a table full of DEAD pids was reclaimed rather than
                    overflowing (evicted=32, overflow=0) and a pid-reuse
                    tombstone was refused and counted (stale-refused=1)
[test_cow_fork]  PASS — COW fork keeps parent/child private
[test_mmap_fork] PASS — COW fork over an mmap VMA keeps parent/child private
[mm-zap]         PASS — _vma_free_cow_range zaps+flushes before freeing;
                        task_reap returns the user stack COW-safely
[gate_registration] PASS
[gate_softgreen]    PASS
[gate_kvmdark]      PASS (20 dark gates, population still frozen — the new
                    gate exits 125 INCONCLUSIVE without /dev/kvm, so it is
                    not a dark green)
```

**NOT run, stated rather than implied:** `scripts/test_de_visual_gate.sh` and
a full DE soak with a SIGTERM audit.

### The new gate is mutation-proven, not merely green

Twelve mutations in total, each reverted after its run. Eight against a
synthetic log before the first boot (a collector that roots everything; a
leaking arm; an arm whose owners were never recorded; a missing negative
control; a stale kernel with no `[cens3]`; a truncated site; an over-claiming
predicate; an app with too few cycles) and four against the **real**
`20260730-155517` serial log afterwards:

| mutation | result |
|---|---|
| a second UNACCOUNTED frame planted at site 20 | **FAIL**, named the site |
| the plant explained away (`0 UNACCOUNTED`) | **FAIL**, "predicate OVER-CLAIMS" |
| the plant's `phys=` line removed | **FAIL**, INCONCLUSIVE |
| a `TRUNCATED` site added | **FAIL**, INCONCLUSIVE |

---

## 7. So is the leak closed?

**On counted quantities, with both census controls green in the same sweep:
there is no unexplained frame in the machine.** That is the strongest form
this campaign has ever been able to state, and it now rests on:

* every COW share arm balanced or adjudicated as residency by the owner
  discriminator, across **nine** DE apps rather than one;
* a whole-machine reachability census whose only orphan is the control it
  planted, with the negative control proving it does not over-report;
* a run predicate that accounts for the one class of frame the census cannot
  see — and that demonstrably answers differently for a frame in a run and a
  frame in none;
* a kernel heap reporting `+0` live objects on every site;
* `hamsh` exonerated in pass 17 on a post-GC floor and 361 identical RSS
  samples.

What this does **not** establish, stated rather than implied: these are
minutes-long runs, not months. A leak of one frame per hour is invisible at
this timescale and would still cost 8 MiB a year. The instrument to catch
*that* is not a longer soak of the same kind — pass 15 established that a
soak mean is not an estimator — it is this census run twice, hours apart, on
one boot, differencing the per-site live counts with the plant discounted.
That is the next question, and it is cheap.

---

## 8. The next counted questions

1. **Run the census TWICE on one long-lived boot, hours apart**, and
   difference the per-site live counts with the plant discounted. Everything
   above is a minutes-scale measurement; the user's bar is months. This is
   the smallest experiment that speaks to it, and both controls make the
   difference meaningful.
2. ~~**Fix adjacent string-literal concatenation in the Adder front end**~~ —
   **DONE, `d3a04b6e` (2026-07-30).** 35 diagnostics were silently losing
   everything after their first fragment. The native parser concatenates now;
   the seed already did. Gated by
   `scripts/test_compiler_adjacent_strings.sh` (registered).
3. **Point the origin instrument at the DE's own long-lived processes** —
   `hamUId`, the panel, the compositor. Every gate so far measures apps that
   OPEN AND CLOSE; nothing measures the processes that never exit, which are
   precisely the ones that have to survive months.
