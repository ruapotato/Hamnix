# Leak pass 15 — the last unnamed share path, and closing arm 5

Base `241402ca` (pass 14). Pass 14 left exactly two named residues and asked
two counted questions about them. This pass answers both, and the answer to
the first one is **not the one the brief expected**.

---

## 0. What pass 14 handed over

> 1. **org=2 after the split = the mmap-VMA fork path** (`vma_fork_copy` ->
>    `vm_cow_share_range`), +56 frames over 12 minutes. Give it its own arm and
>    close it against `_vma_free_cow_range` the same way arm 21 was closed.
> 2. **org=5 = `cow_resolve_pte`, a constant +10 across three independent
>    runs.** Confirm it by dumping the ten frames' owners once.

Both are now instrumented. The instrument is the deliverable; the numbers
below are what it reports.

---

## 1. THE SPLIT — arm 2's residue is TWO paths, not one

`vma_fork_copy` calls `vm_cow_share_range` from two structurally different
places, and pass 14's "+56 on the mmap-VMA fork path" lumped them:

| arm | call site | what it shares | how it drains |
|----:|-----------|----------------|---------------|
| 23 | `vma_fork_copy`, `owns_pages != 0`, not `MAP_SHARED` | an OWNER mmap VMA's whole range | both nodes flagged `is_cow` -> `_vma_node_free` -> `_vma_free_cow_range` |
| 24 | `vma_fork_copy`, `owns_pages == 0`, `is_demand` | only the pages the parent had already FAULTED in a demand VMA | node records no backing run; frames are tracked through rmap |

Arm 2 stays the default, so the split is still total: anything left at arm 2
is a caller nobody has named, which is an answer rather than a gap.

`fs/elf.ad` gained `vm_cow_share_set_arm` so `mm/vma.ad` can name its own
spans the same way `_vm_cow_share_all_locked` names image / brk / ustack. One
store on a debug path, feeding a gated tally.

---

## 2. THE MEASUREMENT — and why it is not `born == died`

**An absolute born/died balance is the WRONG assertion here, and asserting it
would have produced a permanent false red.** `cow_share_page` takes a frame
`0 -> 2` (parent + child); the child's death returns it to **1**, not to 0.
The frame is not dead while the parent still maps it. So every frame a LIVE
parent shared reads born-without-died forever, by design. Pass 14's `768/768`
was readable precisely because that span's entire cohort had exited; here the
parent (`hamsh`) outlives the measurement.

What IS closed-form is a **repeat**. `scripts/test_cow_vma_fork_origin.sh`
runs the deterministic `/bin/u_mmap_fork` fixture (8 x mmap 2 pages, write,
fork, child writes, parent `wait4` + `munmap`) **three times** with a
`track origin` dump after each. Every one-time population is born on the first
run; a per-run leak shows as a constant positive net on the later deltas, and
a fixed resident set shows as zero. No slope, no mean, no soak.

**Second identical run, per-arm delta (2-dump form, boot 1):**

| arm | delta born | delta died | net |
|----:|-----------:|-----------:|----:|
| 1 (W^X verbatim) | 3 | 3 | **0** |
| 5 (`cow_resolve_pte`) | 26 | 26 | **0** |
| 19 (ELF image span) | 0 | 0 | **0** |
| 21 (user stack span) | 64 | 64 | **0** |
| 23 (owner mmap VMA) | 17 | 16 | **+1** |
| 24 (demand VMA resident) | 0 | 0 | **0** |

Read that carefully, because it disagrees with the brief's framing:

* **Arm 24 took 46 births and ZERO deaths for the whole boot — and did not
  grow by a single frame on the repeat.** `add=138 drop=92` leaves exactly 46
  outstanding references, one per frame, every one at refcount 1. That is the
  signature of a FIXED RESIDENT SET, not a leak: `hamsh`'s demand pages took
  their first reference at the first fork and stay at 1 for as long as `hamsh`
  lives. `track org 24` confirms it — 46 frames, **owner-dead = 0**.
* **Arm 23 closed EXACTLY on the first run (16 born / 16 died = 8 iterations
  x 2 pages) and netted +1 on the second.** The single survivor is described
  by `track org 23`: `phys=0xa4e7000`, `site=6` (`PA_SITE_VMA_ANON`),
  `cow_refcount=1`, `owner slot=7 live=1`, and — the discriminator — **the
  owner still maps that VA to that very frame**. A frame a running process
  still maps is not reachable by any teardown fix.
* Arms 1, 19 and 21 each close at net 0 across an identical repeat,
  independently corroborating pass 14's fix on a completely different
  workload.

So the counted answer to question 1 is: **under a deterministic exercise of
`vma_fork_copy`, neither of its two share arms leaks a frame per run.** Pass
14's "+56 on the mmap-VMA fork path" was a LIVE-RESIDENCY residue misread as
a leak, which is exactly the error the `0 -> 2 -> 1` refcount shape invites
and exactly why the repeat form of the measurement was needed to see it.

**What this does NOT establish.** The +56 was measured under the DE soak's
`hamtermscene` workload, and this gate runs `u_mmap_fork`. A leak that needs
a VMA shape `u_mmap_fork` never builds — a split VMA, a `MAP_FIXED` alias, a
re-forked demand node — would not appear here. The honest claim is narrow and
counted: **the plain owner-mmap and demand-resident fork shares are clean per
run**; the DE workload's arm 23/24 deltas are the next measurement, and the
verb to take them (`track org N`) now exists.

---

## 3. ARM 5 — the constant +10, named

(pending the owner dump from the second boot)

---

## 4. The instrument — `track org N`

```
echo track org 5 > /proc/meminfo
```

`cow_origin_next_live(org, from_pfn)` enumerates **exactly** the `born - died`
population of one arm. That equality is by construction, not by approximation:
`_cow_ledger_note_drop` clears the origin byte on the frame's death, so
"origin == N and refcount != 0" is the same set the tally counts. An
enumeration that could disagree with its own tally would be worse than none —
the rule `page_alloc_orphan_collect` already follows against the census sweep.

`mm_origin_live_dump` then names each survivor: phys, recorded site, recorded
fault VA, refcount, owner slot, owner liveness, owner pid and comm, and
whether that owner **still maps the recorded VA to this frame**. That last
line is the discriminator the census introduced and it is what turns a
constant residue from an argument into a measurement.

Cost: `O(frames)` per survivor, the same class as `track census`, hence a ctl
verb and never a `/proc/meminfo` field. Everything is gated behind
`cow_ledger_on()` / `page_alloc_track_mode()`; `_build_meminfo` is untouched,
so `/proc/meminfo` is byte-identical when disarmed. The only new
unconditional cost anywhere in this pass is `_pa_trk_meta` / `_pa_trk_tag`
reads inside two accessors that return 0 when the tracker is disarmed.

---

## 5. Gates

(pending)

---

## 6. The next counted question

1. **Take the arm 23 / arm 24 deltas under the DE soak's `hamtermscene`
   launch**, which is the workload pass 14's +56 came from. The instrument is
   the same; only the driver changes. If they are zero there too, the +56 was
   residency and arm 2's residue is fully retired.
2. Whatever the DE run leaves, describe it with `track org N` rather than
   arguing about it — the verb reports owner liveness and current mapping, and
   a frame whose owner is alive and still maps it is not a teardown bug.
