# Leak pass 15 — the last unnamed share path, and arm 5 closed

Base `241402ca` (pass 14). Pass 14 left exactly two named residues and asked
two counted questions about them. Both are answered here, and the answer to
the first is **not the one the brief expected**: the mmap-VMA fork path does
not strand frames. Its residue is live, mapped, owner-alive resident pages,
and the instrument says so by naming owners rather than by arguing.

---

## 0. What pass 14 handed over

> 1. **org=2 after the split = the mmap-VMA fork path** (`vma_fork_copy` ->
>    `vm_cow_share_range`), +56 frames over 12 minutes. Give it its own arm and
>    close it against `_vma_free_cow_range` the same way arm 21 was closed.
> 2. **org=5 = `cow_resolve_pte`, a constant +10 across three independent
>    runs.** Confirm it by dumping the ten frames' owners once.

---

## 1. THE SPLIT — arm 2's residue is TWO paths, not one

`vma_fork_copy` calls `vm_cow_share_range` from two structurally different
places, and "+56 on the mmap-VMA fork path" lumped them:

| arm | call site | what it shares | how it drains |
|----:|-----------|----------------|---------------|
| 23 | `vma_fork_copy`, `owns_pages != 0`, not `MAP_SHARED` | an OWNER mmap VMA's whole range | both nodes flagged `is_cow` -> `_vma_node_free` -> `_vma_free_cow_range` |
| 24 | `vma_fork_copy`, `owns_pages == 0`, `is_demand` | only the pages the parent had already FAULTED in a demand VMA | node records no backing run; frames tracked through rmap |

Arm 2 stays the default, so the split is still total: anything left at arm 2
is a caller nobody has named, which is an answer rather than a gap.

`fs/elf.ad` gained `vm_cow_share_set_arm` so `mm/vma.ad` can name its own
spans the way `_vm_cow_share_all_locked` names image / brk / ustack. One store
on a debug path, feeding a gated tally.

---

## 2. WHY THE MEASUREMENT IS A REPEAT, NOT `born == died`

**An absolute born/died balance is the WRONG assertion for a span whose parent
outlives the measurement, and asserting it would have produced a permanent
false red.** `cow_share_page` takes a frame `0 -> 2` (parent + child); the
child's death returns it to **1**, not 0. The frame is not dead while the
parent still maps it. Every frame a LIVE parent shared therefore reads
born-without-died forever, by design. Pass 14's `768/768` was readable
precisely because that span's whole cohort had exited.

What is closed-form is a **repeat**. `scripts/test_cow_vma_fork_origin.sh`
runs the deterministic `/bin/u_mmap_fork` fixture (8 x mmap 2 pages, write,
fork, child writes, parent `wait4` + `munmap`) **three times**, with a
`track origin` dump after each. Every one-time population is born on run 1; a
per-run leak shows as a constant positive net on the later deltas, a fixed
resident set shows as zero. No slope, no mean, no soak, one boot.

### The three dumps (identical workload each time)

| arm | dump 1 | dump 2 | dump 3 | net run 2 | net run 3 |
|----:|-------:|-------:|-------:|----------:|----------:|
| 5 `cow_resolve_pte` | 26/24 | 52/50 | 78/76 | **0** | **0** |
| 19 ELF image span | 21/1 | 21/1 | 21/1 | **0** | **0** |
| 21 user stack span | 65/65 | 129/129 | 193/193 | **0** | **0** |
| 23 owner mmap VMA | 16/16 | 33/32 | 50/48 | **+1** | **+1** |
| 24 demand VMA resident | 46/0 | 46/0 | 46/0 | **0** | **0** |

* **Arm 21 closes exactly on every dump** — 65/65, 129/129, 193/193.
  Pass 14's user-stack fix is independently corroborated here on a completely
  different workload from the one that found it.
* **Arm 23 closed EXACTLY on run 1** (16 born / 16 died = 8 iterations x 2
  pages) and then nets **+1 per run, reproducibly** — the same +1 on two
  independent boots of two separately-built images.
* **Arm 24 took 46 births and ZERO deaths for the whole boot, and did not grow
  by a single frame across two repeats.** `add=184 drop=138` leaves exactly 46
  outstanding references, one per frame, each at refcount 1.

---

## 3. THE ADJUDICATION — `track org N`, and the answer to question 1

A net of +1 per run looks like a leak and is not one. The discriminator is the
census's: a genuinely stranded frame has either a **dead owner** or a live
owner that **no longer maps it**. `track org N` reports exactly that, per
survivor.

**`track org 23`, both survivors:**

```
[orgl] org=23 live[0] phys=0x0a4e7000  va=0x012901e8  site=6 (PA_SITE_VMA_ANON)
[orgl] live[0] cow_refcount=1  owner slot=7 live=1  pid=7
[orgl] live[0] owner maps here phys=0x0a4e7000        <-- SAME FRAME
[orgl] org=23 live[1] phys=0x0a50d000  va=0x012911e6  site=6
[orgl] live[1] cow_refcount=1  owner slot=7 live=1  pid=7
[orgl] live[1] owner maps here phys=0x0a50d000        <-- SAME FRAME
[orgl] org=23 TOTAL=2 owner-live=2
[orgl] org=23 owner-dead=0 owner-unrecorded=0
```

Both survivors are **anonymous demand-fault pages of a LIVE process (pid 7)
which still maps them**, at the consecutive VAs `0x1290000` and `0x1291000`.
That is `hamsh`'s arena growing by one page per command. The page was
untracked (refcount 0) when it was faulted; the NEXT fork COW-shares it
`0 -> 2`, which is its birth on arm 23; the child exits, it falls to 1, and
`hamsh` keeps it because `hamsh` is still using it. **The +1 per run is the
parent's own resident-set growth entering the refcount table, not a teardown
that missed a frame.**

`track org 24` says the same in bulk: **owner-dead = 0** over all 46, and the
population does not grow. 44 of them read `owner: NOT RECORDED` because they
were allocated before `track full` armed the site table — stated rather than
swept, since their owner genuinely is not known.

**So the counted answer to question 1 is a disproof, not a fix.** Under a
deterministic exercise of both `vma_fork_copy` share arms, neither strands a
frame: every survivor is mapped by a live owner. The change this pass makes
to the kernel is instrumentation only — there was nothing to fix on this path,
and a "fix" would have freed frames a running process is using, which is
precisely the failure mode that wedged the desktop twice in earlier passes.

**What this does NOT establish.** The +56 was measured under the DE soak's
`hamtermscene` workload; this gate runs `u_mmap_fork`. A leak needing a VMA
shape `u_mmap_fork` never builds — a split VMA, a `MAP_FIXED` alias, a
re-forked demand node — would not appear here. The narrow, counted claim is:
**the plain owner-mmap and demand-resident fork shares are clean per run, and
their apparent residue on this workload is provably residency.** Taking the
same two arms under the DE soak is the next measurement, and the verb to take
it now exists.

---

## 4. ARM 5 — CLOSED

Pass 14 saw arm 5 at a constant +10 across three independent runs and asked
for the owners once, so that it stops being re-litigated every pass.

On this workload arm 5's population is a constant **2** (26/24, 52/50, 78/76 —
net 0 on both repeats, so it never grows). `track org 5`:

```
[orgl] org=5 live[0] phys=0x0a4e8000  va=0x00476028  site=11 (PA_SITE_COW_RESOLVE)
[orgl] live[0] cow_refcount=1  owner slot=7 live=1  pid=7
[orgl] live[0] owner maps here phys=0x0a4e8000        <-- SAME FRAME
[orgl] org=5 TOTAL=2 owner-live=2
[orgl] org=5 owner-dead=0 owner-unrecorded=0
```

**owner-dead = 0; every survivor is still mapped by its live owner at the VA
the copy was made for.** These are private COW copies made for a long-lived
process, which is what a resident set looks like. Pass 13 exonerated
`cow_resolve_pte` on references, pass 14 exonerated it on frames, and this
names the frames' owners.

**Arm 5 is closed. It should not be re-opened without a run showing
`owner-dead > 0` or a survivor its owner no longer maps** — those are the two
observations that would make it a leak, and both are now one ctl verb away.

---

## 5. The instrument

```
echo track org 5 > /proc/meminfo
```

`cow_origin_next_live(org, from_pfn)` enumerates **exactly** the `born - died`
population of one arm. That equality is by construction, not approximation:
`_cow_ledger_note_drop` clears the origin byte on a frame's death, so
"origin == N and refcount != 0" is the same set the tally counts. An
enumeration that could disagree with its own tally would be worse than none —
the rule `page_alloc_orphan_collect` already follows against the census sweep.

`mm_origin_live_dump` names each survivor: phys, recorded site, recorded fault
VA, refcount, owner slot, owner liveness, owner pid and comm, and whether that
owner **still maps the recorded VA to this frame**.

Cost: `O(frames)` per survivor — the same class as `track census`, hence a ctl
verb and never a `/proc/meminfo` field. Two new accessors
(`page_alloc_frame_owner` / `page_alloc_frame_tag`) read the tracker's
existing per-frame arrays and return 0 when it is disarmed; nothing else is
added to any hot path. Everything is gated behind `cow_ledger_on()` /
`page_alloc_track_mode()`. `_build_meminfo` is untouched, so `/proc/meminfo`
is byte-identical armed or disarmed.

`COW_ARM_MAX` went 24 -> 26 (four `uint64` arrays, +64 bytes of BSS).

---

## 6. What was ruled out

* **The mmap-VMA owner-fork share (arm 23) strands frames** — disproved:
  16/16 on the first run, and every later survivor is mapped by its live
  owner (`owner-dead = 0`).
* **The demand-resident fork share (arm 24) leaks** — disproved: 46 frames,
  zero growth across two identical repeats, `owner-dead = 0`.
* **`cow_resolve_pte` (arm 5) leaks** — disproved on owners, after pass 13
  disproved it on references and pass 14 on frames.
* **Pass 14's user-stack fix regressed** — arm 21 closes exactly on all three
  dumps of a workload unrelated to the one that found the bug.

---

## 7. The next counted question

1. **Take the arm 23 / 24 deltas and their `track org` dumps under the DE
   soak's `hamtermscene` launch**, the workload pass 14's +56 came from. Same
   instrument, different driver. If `owner-dead` is 0 there too, arm 2's
   residue is fully retired and the remaining `PagesInUse` slope is not on any
   COW share path at all — which would redirect the hunt to the non-COW
   allocators (`kmalloc`/slab, `wsys`) that the zero-leak directive already
   names.
2. If `owner-dead > 0` appears for either arm, the dump names the slot and the
   VA, and the fix is at whichever teardown that owner's exit runs — the same
   shape as pass 14's user stack.
3. Arm 24's 44 `owner: NOT RECORDED` frames are a real blind spot of the
   *tracker*, not of the origin tag: they predate the arming. Arming
   `track full` from the boot cmdline rather than from a shell would close it
   and costs nothing that is not already gated.
