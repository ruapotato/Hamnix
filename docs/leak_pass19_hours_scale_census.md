# Leak pass 19 — the first measurement in this campaign that can see a slow leak

Base `416d1ca2`. Pass 18 closed the leak on counted quantities and named its
own residual in its closing words:

> these are minutes-long runs, not months. A leak of one frame per hour is
> invisible at this timescale and would still cost 8 MiB a year. The instrument
> to catch *that* is not a longer soak of the same kind — pass 15 established
> that a soak mean is not an estimator — it is this census run twice, hours
> apart, on one boot, differencing the per-site live counts with the plant
> discounted.

This pass builds that instrument, answers pass 18's third question with it in
the same boot (**nothing had ever measured the DE processes that never exit**),
and closes the staleness trap that has now been found short four times.

---

## 1. THE INSTRUMENT

`scripts/test_leak_hours_census.sh` — ONE boot, a settle period, then two
identical sample batteries `GAP_S` apart with **nothing launched and nothing
closed in between**. That "nothing" is the point: every gate before this one
measures an app OPENING AND CLOSING, and a process that lives for the whole
session and grows slowly is invisible to that shape by construction.

Each battery, in this order:

| # | verb | what it yields |
|---|---|---|
| 1 | `track dump` | per-site LIVE page counts |
| 2 | `track origin` | per-arm born/died |
| 3 | `track org N` | the owner discriminator, per arm |
| 4 | `cat /proc/tasks`, `cat /proc/<pid>/statm` | **every live process's resident set** |
| 5 | plant / mplant / census / unplant / unmplant | the whole-machine census, both controls in the same sweep |
| 6 | `kmtrack dump` | kernel heap, reported |

The per-site dump is taken **before** either control is planted, so no control
frame is ever inside a counted site — pass 18's gate failed its first run on
exactly that contamination.

Step 4 needs no kernel change: `/proc/tasks` already names every live task and
`/proc/<pid>/statm` already reports its resident page count. Pointing the
existing instruments at the long-lived cohort was a harness question, not a
kernel one.

### Why differences, and not a soak mean

Pass 15 established that two **byte-identical** builds differ by 6.4 pg/cycle on
a soak mean. Both samples here come from ONE boot of ONE build, so the build
term cancels exactly and the difference is a difference in the machine's state
rather than in two estimates of it.

### Why `born == died` is not the assertion

At hours scale on long-lived processes, **every** owner outlives the
measurement, so an absolute balance is a permanent false red. The quantity is
the inter-sample net, and any non-zero net is adjudicated with the owner
discriminator (`owner-dead` / `owner-stray` / `owner-unrecorded`), never on its
sign.

### A ramp is not a slope — found by RUNNING the gate, not by reading it

The first smoke run took sample A about a minute after the DE handoff. A
machine one minute into a boot is still ramping — lazily faulted pages, first
paints, page cache filling — so a two-hour delta from that baseline would have
measured the **boot ramp** and reported it as a slope, which is precisely the
error pass 17 exists to warn about. `SETTLE_S` (default 15 min) now runs before
the tracker is even armed, so both samples come from the same regime.

---

## 2. THE INSTRUMENT'S OWN CONTROLS

Three passes of this campaign caught a **false green inside their own tooling**
— a survivor walk that stopped at 64 over a population of 101, arms whose zero
meant "nobody recorded an owner", a gate carrying `[ -e /dev/kvm ] || exit 0`.
A green from a blind instrument is worse than a red. So the adjudicator refuses
to say PASS when:

* either census control is missing in either sweep — a blind census and an
  empty population print the same zero;
* the run predicate reports **zero** UNACCOUNTED while a plant is outstanding —
  the plant is mapped nowhere, therefore lies in no run, and a predicate that
  explains it away is over-claiming;
* the plant's physical address was never printed — **a plant you cannot
  identify cannot be discounted**;
* a site reports `TRUNCATED` — it covered a prefix of the population;
* an arm's positive net sits over a population none of whose members has a
  recorded owner (`owner-dead = 0` is vacuous there);
* **the measured gap is below `MIN_GAP_S`.** A gate named "hours" that ran for
  four minutes is the purest false green available here, so the two samples'
  host timestamps are differenced and asserted.

All of these exit **125 INCONCLUSIVE**, never 0.

### The growth bar, and where the number comes from

Orphan freedom is necessary and not sufficient: a resident set that grows
forever kills months of uptime even though every frame is reachable from a live
page table and no teardown fix could touch it. So the total live-page delta
over an interval in which nothing was launched or closed is itself an
assertion, at `GROWTH_FAIL_PAGES` (default 256 pages = 1 MiB over the whole
gap). 1 MiB per two idle hours is ~12 MiB/day and ~4.3 GiB/year — fatal to the
user's bar by inspection, which is why it is defensible rather than tuned, and
deliberately far looser than "zero" so a still-settling bounded ramp does not
fail the gate.

The bar is suppressed when a process STARTED during the gap: a new process
legitimately adds resident pages, and condemning that would be a false red of
exactly the shape this campaign keeps catching.

### Mutation-proven, not merely green

The adjudicator is a **separate file** (`scripts/leak_hours_census_report.py`)
on purpose: the gate needs a two-hour KVM boot to produce a log, so nobody
would ever re-run it to check that its verdict logic still catches anything,
and that is how a gate rots into a green that means nothing.
`scripts/test_leak_hours_report_mutations.sh` feeds it **17 synthetic logs** —
one clean, and one per failure mode, each differing in exactly one respect —
and FAILS if any of them still comes out green. It needs no QEMU, no KVM and no
image, so it is registered in the battery. **17 of 17 caught.**

| mutation | verdict |
|---|---|
| clean pair | PASS |
| samples 4 minutes apart | INCONCLUSIVE |
| positive control missing in B | INCONCLUSIVE |
| negative control missing in A | INCONCLUSIVE |
| no `[cens3]` run predicate | INCONCLUSIVE |
| plant's `phys=` never printed | INCONCLUSIVE |
| predicate reports 0 UNACCOUNTED with a plant out | FAIL (over-claims) |
| three real orphans at site 20 in B | FAIL, named |
| unaccounted frames grew A→B | FAIL |
| a `TRUNCATED` site | INCONCLUSIVE |
| an arm grew with `owner-dead=7` | FAIL |
| an arm grew with all owners unrecorded | INCONCLUSIVE |
| 900 pages of growth, task set unchanged | FAIL |
| the same growth, but a process started | PASS (not attributable) |
| no statm reading in either sample | INCONCLUSIVE (blind arm) |
| sample B missing entirely | INCONCLUSIVE |
| the panel grew 70 pages, under the bar | PASS, named in the report |

The `no_plant_phys` case found a real bug in the first draft: the gap
comparison was differencing two `unacc_real` totals when one sweep could not
discount its own plant, i.e. it was reporting the instrument's own scaffolding
as growth. The comparison is now gated on both plants being identifiable.

---

## 3. THE HOURS-APART RESULT

One boot, 15-minute settle, **two samples 7268 s = 2.02 h apart**, nothing
launched and nothing closed in between.

### The census, both sweeps

```
sample A: positive=OK negative=OK orphans=1 plant=0x15923000 UNACCOUNTED=1 (0 after discounting the plant)
sample B: positive=OK negative=OK orphans=1 plant=0x1593d000 UNACCOUNTED=1 (0 after discounting the plant)
```

Both controls green in **both** sweeps. The plant landed at a different
physical frame each time and was identified and discounted by address in each.
**The only unreachable frame in the machine, at both ends of two hours, is the
one the gate planted** — and the count did not move.

### The per-site difference, with the plant discounted

```
  site 0   unknown       A=5964    B=5813    delta -151
  site 6   vma_anon      A=1       B=32      delta  +31
  site 9   pgtable       A=0       B=2       delta   +2
  site 11  cow_resolve   A=0       B=2       delta   +2
  TOTAL live pages       A=5965    B=5849    delta -116     (-57.5 pages/hour)
```

The machine finished two idle hours holding **116 pages FEWER** than it started
them with. Site 0 (`unknown`) is the population that was already live when the
tracker was armed and therefore carries no recorded site; its −151 and the
+31/+2/+2 at the attributed sites are the same frames being returned and
re-allocated with attribution. **Stated as a limitation rather than glossed:**
because the tracker is armed at sample A, most of the live population is
un-attributed for this run, so the per-site table is thin. The *difference* is
unaffected — both samples are read the same way — but a per-site attribution of
the whole resident set would need the tracker armed at boot.

### The long-lived processes — the thing nothing had ever measured

18 processes were alive at both samples. **17 of the 18 are byte-identical
across two hours:**

```
  hamdesktop     18 -> 18      hampanelscene  14 -> 14      sshd    3 -> 3
  __rfork_       68 -> 68      __rfork_       68 -> 68      __rfork_ 68 -> 68
  __rfork_       73 -> 73      __rfork_       79 -> 79      __rfork_ 79 -> 79
  hamsh (x3)     13 -> 13      kworker/ksoftirq  0 -> 0
```

The eighteenth is **pid 6, the interactive `hamsh` on the serial line** — the
one process that was *not* idle, since the gate drives it with a heartbeat
every five minutes. It grew **+23 pages**.

And that number is the interesting one, because the smoke run of the same gate
measured the same process over a **376-second** gap:

| gap | hamsh pid 6 resident, A -> B | growth |
|---|---|---|
| 376 s (0.10 h) | 100 -> 120 | +20 |
| 7268 s (2.02 h) | 100 -> 123 | +23 |

Both runs start at exactly 100 pages after the settle. Nineteen times the
elapsed time bought three extra pages. A per-hour leak would have shown ~400
pages over the long gap. **That is a bounded high-water, not a slope** — pass
17's `hamsh` finding, reproduced independently here by a different instrument
at a nineteen-fold longer timescale.

### The COW origin arms

```
  arm 5   born +40 died +40 net  +0   TOTAL=2  owner-dead=0 owner-unrecorded=0 owner-stray=0
  arm 23  born +18 died  +0 net +18   TOTAL=29 owner-dead=0 owner-unrecorded=9 owner-stray=0
```

Arm 5 is exactly balanced over the gap. Arm 23's `+18` is adjudicated
**RESIDENCY** by the discriminator rather than by its sign: every one of its 29
survivors is still mapped by the live task that allocated it. Arms 1, 2, 19, 21
and 24 took no births at all in an idle interval and are not reported as clean —
their zeros are about a path that never ran.

### The verdict

> **VERDICT: PASS — no measurable leak at hours scale**

Over 2.02 hours of one boot: no site accumulated an unaccounted frame, the
unaccounted count did not move, the total live page count went **down**, and
every process that ran for the whole interval without being driven held exactly
the same resident set at the end as at the beginning.

**What this does NOT establish, stated rather than implied.** Two hours is not
months, and the interval was IDLE by design. It is a real answer to the
question pass 18 could not reach, and it is not the last one — see §6.

---

## 4. THE STALENESS TRAP, CLOSED PROPERLY

`scripts/_installer_img.sh` decided staleness by comparing image mtime against
tracked **source** mtimes. That model answers exactly one question — "did a
tracked file change after this image was written?" — and it has now been found
short **four times, always in the same direction**:

| date | hole | fix at the time |
|---|---|---|
| 2026-07-25 | `sys` missing from the input dirs — the whole Plan 9 device layer | widen the list |
| 2026-07-28 | `tests` missing — boot-path kernel source | widen the list |
| 2026-07-30 | `mm` / `linux_abi` / `adder` missing — leak pass 13 soaked a kernel predating the mm change it was measuring | widen the list |
| 2026-07-30 | **not a directory at all** | this pass |

The fourth is `ADDER_FORCE_NATIVE_APPS`, and its siblings
`HAMNIX_KERNEL_BACKEND`, `HAMNIX_USER_OPT`, `HAMNIX_KERNEL_OPT`, `ADDER_CC`.
They change what the build **emits** with the tree byte-for-byte identical, so
the guard reported "fresh" and an agent took **seven consecutive false passes**
off an image built under the other configuration. An implausible age was the
only signal available, and the age was entirely plausible.

Widening the list a fifth time would have treated the symptom again. The real
question is *what else can change the image without changing a tracked source?*
— and there are four answers, all of them now hashed into `<img>.stamp`:

* **(a) build configuration** — every `ADDER_*` / `HAMNIX_*` / `ENABLE_*`
  variable in the environment, **default-INCLUDE** with a short documented
  exclusion list for the ones that change *where* or *whether* we build rather
  than *what*. The polarity is the whole point: a forgotten new knob then
  causes a spurious rebuild (annoying, safe) instead of a false pass
  (expensive, wrong). An allow-list would reproduce this bug the first time
  somebody adds a knob without thinking of this file.
* **(b) the input model itself** — `_HAMNIX_IMG_INPUT_DIRS` and the glob list
  go into the stamp, so the day somebody adds the NEXT missing directory,
  every existing image is correctly declared stale. Those images *were* built
  under a model that ignored it. This is the meta-fix for the recurrence.
* **(c) deletions and renames** — an mtime **maximum cannot fall**. `rm
  kernel/foo.ad` changes what the image contains and moves no mtime forward,
  so the old model said "fresh" forever. The stamp hashes the tracked-file
  inventory.
* **(d) the toolchain** — `HAMNIX_KERNEL_BACKEND=llvm` compiles the kernel with
  clang, and a clang upgrade rewrites every byte of it with no source change at
  all.

An **absent** stamp counts as stale, so images predating the mechanism are
rebuilt once rather than trusted forever, and the producer
(`scripts/build_installer_img.sh`) writes the stamp itself — otherwise a direct
build would leave an unstamped image that the next gate rebuilds for another 14
minutes, and a guard that costs a rebuild per invocation is a guard that gets
commented out. `installer_img_stale_reason()` now says WHICH model condemned an
image; "stale" alone sent two agents to the wrong place on 07-24. Cost: 117 ms.

### Mutation result: 13 of 13, in BOTH directions

`scripts/test_installer_img_stamp.sh` runs against a **synthetic tree**
(`PROJ_ROOT` pointed at a temp dir), so it can delete a source file and install
a different compiler in milliseconds, with no QEMU and no image.

| case | expected | got |
|---|---|---|
| image with no stamp | STALE | ok |
| **nothing changed** | **FRESH** | ok |
| `ADDER_FORCE_NATIVE_APPS=1` | STALE | ok |
| `HAMNIX_KERNEL_BACKEND=native` | STALE | ok |
| `HAMNIX_USER_OPT=1` | STALE | ok |
| `ENABLE_XHCI_KO=1` | STALE | ok |
| **`HAMNIX_SKIP_BUILD=1`** | **FRESH** | ok |
| a source file DELETED | STALE | ok |
| **the tree restored** | **FRESH** | ok |
| a source file RENAMED | STALE | ok |
| the input-dir list widened | STALE | ok |
| a different compiler | STALE | ok |
| a second image path | STALE | ok |

The three **negative** controls are the ones that matter most, and they are
stated as prominently as the positives: a stamp that always says "stale" would
pass every positive case in this table and be worse than no stamp at all,
because it means a 6-14 minute rebuild on every gate invocation.

---

## 5. Gates run

```
[hourscens-mut]     PASS  — 17 of 17 mutations caught
[imgstamp]          PASS  — 13 of 13, 10 STALE + 3 FRESH controls
[gate_registration] PASS
[gate_softgreen]    PASS
[gate_kvmdark]      PASS (20 dark gates, population still frozen — the new
                    hours gate exits 125 INCONCLUSIVE without /dev/kvm, so it
                    is not a dark green)
[artifact_freshness] rebuilt, then PASS
[kobjdiff]          PASS  — zero semantic divergences across 11383 matched
                    kernel functions
[test_cow_fork]     PASS  — COW fork keeps parent/child private
[test_mmap_fork]    PASS  — COW fork over an mmap VMA keeps parent/child private
[mm-zap]            PASS  — task_free_owner_regions + task_reap return the user
                    stack COW-safely (no raw free_pages)
[installed-pkg-repo] PASS
[hourscens]         PASS  — the 2.02 h run above
```

### A self-inflicted lesson worth recording

The first smoke run died mid-flight with a bash syntax error at a line that is
syntactically fine. The cause: **the script file was edited while a detached
run was executing it.** Bash reads a script incrementally by byte offset, so an
edit that shifts offsets corrupts the interpreter's position in a running
script. Nothing in the tree was wrong; the run was. Never edit a script a
detached run is executing.

---

## 6. The next counted questions

1. ~~**Fix adjacent string-literal concatenation in the Adder front end.**~~
   **ALREADY DONE when this pass was written — `d3a04b6e`, same day (annotated
   2026-08-03).** This pass carried the item forward from pass 18 from memory
   instead of re-checking the tree, and it then generated at least one further
   dispatch. The native parser concatenates (the Python seed always did, so the
   bug was a seed/native divergence — a miscompile). Gate:
   `scripts/test_compiler_adjacent_strings.sh`, registered in
   `ci_battery_manifest.txt`, extended 2026-08-03 with the mixed-prefix seams
   (`b".." b".."` joins; `f".." ".."` is rejected by both front ends). The
   35 diagnostic call sites had already been mechanically joined in pass 18,
   so nothing in the tree was truncated by the time this was written. **Brief
   from the tree, not from the previous pass's open list.**
2. **Run this gate across a REBOOT-free day, not two hours.** Two hours is the
   first honest hours-scale reading; the bar is months. The gate takes `GAP_S`
   and needs no change to answer at 12 or 24 hours, and the counted question is
   whether the per-site difference stays flat as the gap grows or reveals a
   rate too small to see in two hours.
3. **Point the same battery at a machine under LOAD for the gap**, not idle.
   This pass deliberately measured the quiet case, because that is what
   "running for months" means for a desktop that is mostly idle, and because a
   quiet interval is the only one in which a non-zero delta has an unambiguous
   owner. A loaded interval is a different and harder question.
