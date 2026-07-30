# Leak pass 16 — the COW hypothesis, retired under the workload that made it

Base `efa0ddc8` (after pass 15). Pass 15 closed the two `vma_fork_copy` share
arms and published the caveat that made the result incomplete:

> **What this does NOT establish.** The +56 was measured under the DE soak's
> `hamtermscene` workload; this gate runs `u_mmap_fork`. A leak needing a VMA
> shape `u_mmap_fork` never builds ... would not appear here.

That caveat is load-bearing, because `hamtermscene` is not one app among many:
pass 14 counted 212 launches across 53 soak cycles and found it stranded
frames on **23 of 23** of its own launches (~298 frames each) while every
other app in the pool sat within noise of zero. It is the only app that forks.

This pass points the *same* instrument at the *real* driver.

---

## 0. The measurement

`scripts/test_cow_hamterm_origin.sh` boots the shipped installer image under
OVMF, waits for the DE handoff, arms `track full` + `kmtrack`, then opens and
closes `/bin/hamtermscene` N times — as a child of the serial shell, closed
with `/bin/kill`, which is exactly how the DE's own close box closes it
(`daemon_close_slot` -> `p9_note_tree`). After every close it takes a
`track origin`, a `kmtrack dump` and a `track dump`. At the end it runs
`track org N` for every arm a share path can reach, then an orphan census with
**both** controls outstanding.

What is asserted is the **inter-cycle delta** plus the owner discriminator,
never a soak mean and never absolute `born == died` — for the reason pass 15
established: `cow_share_page` takes a frame `0 -> 2` and the child's death
returns it to 1, not 0, so an absolute balance is a permanent false red while
the parent lives.

**Three runs, on three separately-built images**: 4 cycles (image age 344 s),
then 6 cycles twice (image ages 0 s and 0 s) after each of the two instrument
fixes below. Six cycles give five inter-cycle deltas, so "constant positive
net" versus "settles to zero" is a shape rather than a pair of numbers.

---

## 1. THE ANSWER — no COW share arm strands a frame under the terminal

`track org` over every arm, after six terminal open/closes (run 2):

| arm | span | TOTAL live | owner-dead | owner-stray | owner-untagged |
|----:|------|-----------:|-----------:|------------:|---------------:|
| 1  | W^X RO verbatim share | 101 | **0** | **0** | 0 |
| 2  | residual (unnamed caller) | 0 | 0 | 0 | 0 |
| 5  | `cow_resolve_pte` private copy | 12 | **0** | **0** | 0 |
| 19 | ELF image span | 20 | **0** | **0** | 0 |
| 21 | user stack span | 63 | **0** | **0** | 63 |
| 23 | owner mmap VMA fork share | 21 | **0** | **0** | 0 |
| 24 | demand-resident fork share | 64 | **0** | **0** | 0 |

Per-cycle nets over the six-cycle run, for the two arms pass 15 named:

```
arm    d2      d3      d4      d5      d6
23     +2      +2      +3      +2      +3     -> RESIDENCY (see below)
24     -3      +0      +0      +3      -3     -> closed
```

Arm 23 is **the only arm with a persistent positive net**, and it reproduced
identically on both six-cycle runs (`+2 +2 +3 +2 +3`). It adjudicates as
residency — `owner-dead = 0`, `owner-stray = 0` over all 21 survivors, 15 of
which have a recorded owner — and it is the same shape pass 15 named on
`u_mmap_fork`: the long-lived parent shell's own resident set entering the
refcount table at the next fork, not a teardown that missed a frame.

**That is where the residual slope lives.** ~2.4 frames per terminal cycle, on
an arm whose every survivor is mapped by a live owner. Pass 14's residual
`PagesInUse` read +2.02 pg/cycle. The units are not the same (a soak cycle is
not one terminal open/close) so this is a correspondence and not a proof — but
it is the only per-cycle growth left anywhere in this measurement, and it is
memory a **userland process is holding**, which no kernel teardown can or
should reclaim. The next pass belongs in `hamsh`, not in `mm/`.

**`owner-dead = 0` and `owner-stray = 0` on every arm.** Not one survivor of
any COW share path has a dead owner, and not one has a live owner that no
longer maps it. Arm 2 — the catch-all for a caller nobody has named — is
**empty**, so the split is not just total, it is exhaustive.

Pass 15's two conditions for reopening this were "a run showing
`owner-dead > 0`, or a survivor its owner no longer maps". Under the workload
the residue was originally measured on, neither appears.

**The COW share paths are retired.**

### The tallies stopped being a sample

Pass 15's `mm_origin_live_dump` stopped the whole walk at 64 survivors. That
was harmless for a population of two and would have been a **false
exoneration** here: `owner-dead = 0` would have meant "0 among the first 64
frames I happened to reach", over arms holding 101 and 64. The cap is now on
PRINTING only; the walk runs to completion. It costs nothing —
`cow_origin_next_live` resumes from `from_pfn`, so a whole arm is `O(frames)`
once, not `O(frames)` per survivor. `owner-stray` was added and is tallied the
same way, over every survivor.

---

## 2. AND THE HONEST QUALIFIER — three arms were reporting a VACUOUS zero

`owner-dead = 0` over a population **whose owner was never recorded** means
"nobody wrote an owner down", not "no owner is dead". Three arms were in
exactly that state:

| arm | survivors | with a recorded owner (run 1) |
|----:|----------:|------------------------------:|
| 1  | 101 | **0** |
| 19 | 20  | **0** |
| 21 | 63  | **0** |
| 5  | 12  | 12 |
| 24 | 64  | 64 |
| 23 | 16  | 10 |

So the strong claim in §1 rests, as measured, on **arms 5, 23 and 24**. Arms
1, 19 and 21 are *not contradicted* — they are **unadjudicated**, and the gate
now says so and FAILS rather than printing "every survivor is still mapped by
its live owner" over a population where that was never checked. A gate that
overstates its own evidence is how a green run stops meaning anything.

Two fixes, one landed and one named:

* **Arm 21 (user stack) is closed by one line.** `execve`'s eager stack-prefix
  `alloc_pages` set a site but no owner. `pa_set_owner(current_idx_get())`
  next to the existing `pa_set_site(PA_SITE_EXECVE)` fixes it; it is a load, a
  compare and a return while the tracker is disarmed. This matters more than
  the other two: arm 21 is the span pass 14 found the campaign's **main leak**
  in, and it was the one arm whose green was unverifiable.
  Landing it immediately produced the SECOND trap, which is why it is worth
  writing down: with an owner but still no tag, all 64 arm-21 survivors
  reported `owner-stray` — the discriminator was comparing the owner's mapping
  against VA 0. The run only passed because arm 21's net was negative and the
  discriminator was never consulted; on a positive net it would have reported
  a leak that is not there. A frame with an owner but no recorded VA now
  counts as `owner-untagged`, its own number, reported and never swept. Run 3
  reads arm 21 as `owner-unrecorded=0, stray=0, untagged=63` — which is
  exactly the truth: its owners are known and its VAs are not.
* **Arms 1 and 19 are backed by `region_alloc`, not `alloc_pages`,** which
  stamps no per-frame site or owner at all. That is the same reason the census
  reports them under site 0 and its own scope line says
  `USER-MAPPED sites only`. Closing them means teaching `region_alloc` to
  stamp, which is a real change and is left as the next counted question
  rather than smuggled in here.

---

## 3. THEN WHERE? — measured, in the same boot

The point of arming `kmtrack` and the page tracker in the same run is that
"if no COW arm strands a frame, then where?" gets answered from the same
cycles rather than from another boot with another workload.

**Kernel heap, live-object delta per terminal open/close:**

```
site name      d2 live/bytes  d3 live/bytes  d4 live/bytes
0    unknown    +0/+0  +0/+0  +0/+0
1    vfs        +0/+0  +0/+0  +0/+0
2    vma        +0/+0  +0/+0  +0/+0
12   pipe       +0/+0  +0/+0  +0/+0
13   pgrp       +0/+0  +0/+0  +0/+0
```

**Zero, on every site, on every cycle**, with the block pool never exhausted
(so nothing went untracked and silently landed in `unknown`). `pipe` and
`pgrp` are new ids added by this pass precisely because they sit on the
terminal's own fork path — hamtermscene spawns `/bin/hamsh` over pipe Chans
and every fork clones a `Pgrp` — and both had been reporting as
`KM_SITE_UNKNOWN`, the one bucket whose growth cannot be acted on.

**Page sites, live-frame delta per terminal open/close:**

```
site name           live@last   d2  d3  d4
6    vma_anon              76   +3  +3  +1
11   cow_resolve           12   +0  +0  +3
20   execve                64   +0  +0  +0
19   wsys                   0   +0  +0  +0
16   slab                   0   +0  +0  +0
14   pml4                   1   +0  +0  +0
12   kstack                16   +0  +0  +0
9    pgtable               12   +0  +0  +0
```

`wsys`, `slab`, `pgtable`, `kstack`, `pml4` and `execve` are **flat to the
frame** across four identical terminal cycles. The only movement is
`vma_anon` and `cow_resolve` — which are precisely the two populations
`track org` adjudicated as residency (owner-dead 0, owner-stray 0), i.e. the
live DE shell's own resident set.

So on this workload the zero-leak directive's two named suspects — the kernel
heap and `wsys` — are **both disproved on counted quantities**, not argued
about.

---

## 4. THE ONE REAL RESIDUE — a single unreachable frame at `PA_SITE_EXECVE`

The census, with both controls green in the same sweep:

Run 1 (4 cycles):

```
[census] walked 20 address spaces
[census] orphaned frames: 2 (of 6090 live)
[census] control OK: planted orphan detected
[census] negative control OK: mapped frame at va=0x2c0000000
[census] site 6:  1 orphans, live 83      <- the plant (tag_va=0xc0ffee00)
[census] site 11: 0 orphans, live 12 (all reachable)
[census] site 20: 1 orphans, live 64
```

Across the three runs the census read **2, 1, 2** orphans — i.e. the plant
plus *at most one* frame, always at site 20, with site 20's live count pinned
at 64 (one order-6 run) and `+0` on every cycle of every run. Run 2 saw the
plant and nothing else at all.

So the site-20 frame is **intermittent, never more than one, and never
growing**. It is not a slope and it is not on the terminal path; a per-cycle
leak would have produced one per cycle in all three runs.

One of the two is the deliberately planted positive control, identified by its
`0xc0ffee00` tag rather than by its site (the plant allocates at a real
user-mapped site, so a gate that assumed a site would mis-credit it). The
other is genuine: **one frame at site 20, `PA_SITE_EXECVE`, the eager user-
stack prefix.**

What is counted about it:

* Site 20's live count is **64 — exactly one order-6 run — and it did not move
  by a single frame across four cycles, nor across six in the second run**
  (`+0` throughout). Whatever this is, it is **not per-cycle**; a leak on the
  terminal path would have shown one per cycle.
* Arm 21 (the user-stack span) holds **63** survivors. 63 = 64 − 1. The one
  frame the census calls unreachable is the one page of that 64-page run that
  the COW ledger no longer tracks.

That shape is consistent with a page of the prefix having been COW-resolved
into a private copy: the original drops out of the mapping while remaining
part of a run that `task_reap` will return whole. If so it is accounted and
not lost. **That is a hypothesis, not a result** — the discriminator that
would settle it is whether the orphan's PFN lies inside a live task's recorded
ustack run, which the census does not currently ask. It is the next counted
question, and it is one frame, not a slope.

---

## 5. Cost

Everything added stays behind `page_alloc_track_mode()` / `cow_ledger_on()`.
`pa_set_owner` and `km_set_site` are each a global load, a compare and a
return while disarmed. `_build_meminfo` is untouched, so `/proc/meminfo` is
byte-identical armed or disarmed. `KM_SITE_*` ids were appended, never
renumbered. The uncapped origin walk is `O(frames)` once per `track org`, on a
ctl verb that nothing else calls.

---

## 6. Two harness bugs, fixed, because both produce false readings

* **`track census` ends by calling `cow_origin_dump` itself.** The raw log
  therefore carries an origin block that no terminal cycle preceded.
  Attributing it to a workload cycle made the final inter-cycle delta
  all-zero-births — and the gate's own positive control correctly refused to
  call that green, which is the control working. The per-cycle dumps are the
  ones before the first `track org N`.
* **The planted control lands in a real site's tally.** The census verdict now
  discounts it from whichever site it used, by tag.

---

## 7. What was ruled out, and what was not

**Ruled out on counted quantities, under `hamtermscene`:**

* Every COW share arm strands a frame — `owner-dead = 0`, `owner-stray = 0`,
  arm 2 empty. (Firm on arms 5, 23, 24; see §2 for 1, 19, 21.)
* The kernel heap leaks per terminal cycle — `kmtrack` reads `+0` on every
  site, every cycle, pool never exhausted.
* `wsys` leaks per terminal cycle — `+0` frames, four cycles.
* `slab` / `pgtable` / `kstack` / `pml4` / `execve` page footprints grow —
  all `+0`.

## 7b. Gates actually run

```
[kobjdiff] PASS — zero semantic kernel divergences across 11362 matched functions
[kobjdiff] PASS — native kernel codegen matches the seed (semantic).
[test_cow_fork]  PASS -- copy-on-write fork keeps parent/child private
[test_mmap_fork] PASS -- copy-on-write fork over an mmap VMA keeps parent/child private
[cowterm] run 1 (4 cycles) FAIL  — census 2 orphans, 3 arms unadjudicated
[cowterm] run 2 (6 cycles) PASS  — census 1 orphan (the plant), every arm adjudicated
[cowterm] run 3 (6 cycles) FAIL  — census 2 orphans; owner-untagged fix confirmed
```

The pass-16 gate is RED on runs 1 and 3, and that is the honest state: the
census sees one frame it cannot reach, and the gate refuses to call that green.
It was not silenced and its tolerance was not touched.

**NOT run, stated rather than implied:** `scripts/test_de_visual_gate.sh` and a
DE soak with a SIGTERM audit.

**NOT established, stated rather than implied:** this is a four-cycle,
one-boot, terminal-only measurement. It does not speak to the other eight apps
in the soak pool, to a 12-minute slope, or to anything `region_alloc` backs
(arms 1 and 19, and the census's `USER-MAPPED sites only` scope). 

---

## 8. The next counted questions

1. **Teach `region_alloc` to stamp a per-frame site and owner.** It is the
   single remaining blind spot in the whole instrument: it is why arms 1 and
   19 are unadjudicated, why the ELF image reports under site 0, and why the
   census has to scope itself to user-mapped `alloc_pages` sites. Every other
   allocator in the tree is now attributable.
2. **Settle the site-20 orphan** by asking whether its PFN lies inside a live
   task's recorded ustack run. One frame, one predicate, no soak.
3. **Point this gate at the other eight apps.** The terminal was the only one
   that stranded frames when the leak was live; now that it does not, the
   residual slope — if there still is one — belongs to something this gate
   never launches.
