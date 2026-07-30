# Leak pass 12 — the cow_resolve_pte orphans, counted

Status: **no fix shipped.** Three of the brief's premises are disproved and
the question is now much narrower. This note exists so that survives.

Base `19ab77a6`. Instrumentation only; `mm/` behaviour is unchanged.

---

## 1. The span attribution (the question pass 11 left)

Both answers come from the loader's own log plus the census's new span
classifier, and both are **pid 6 = hamsh**, the soak's shell.

```
elf64: ET_EXEC user-map:   [0x400000, 0x47a000)     <- image file extent
elf64: ET_EXEC bss-demand: [0x47a000, 0x12c5000)    <- demand-zero VMA
execve: jumping to 0x400012 with stack 0x1c00f4fd0
```

* **`0x11f0000`–`0x11f2000` is in hamsh's BSS-demand VMA**, `[0x47a000,
  0x12c5000)` — *not* the ELF image. It is a `VmaNode` (census span
  `mask=16`), registered by `vma_register_bss_demand`, and it is disjoint
  from `[image_lo, image_hi)` because `image_hi = lowest_v + file_hi_rel`
  and `bss_lo == image_hi`. Every native binary links at `0x400000`
  (`user/init64.lds`), so the whole DE shares this layout.

* **`0x1c00f3e98` (and `…f4e98`, `…efe98`) is the Linux/native user stack**:
  `LINUX_USTACK_VBASE = 0x1C0000000` (7 GiB). Specifically the **eager
  256 KiB contiguous prefix** `[VBASE+0xC0000, VBASE+0x100000)` —
  `LINUX_USTACK_SIZE 1 MiB` minus `LINUX_USTACK_EAGER_ORDER 6`. Census span
  `mask=4`. The "above 4 GiB" is not an anomaly: the stack window was
  deliberately decoupled to a high VA to stop it aliasing the kernel
  direct map, and every user task carries the same constant `ustack_lo`.

A third cluster (`0x476028`) lands in the image file extent itself,
`mask=1`. So orphans appear in **all three** span kinds a fork COW-shares —
image, BSS VmaNode, and stack prefix — which is why no single-span fix
would have worked.

## 2. The owner — this overturns the brief's framing

The brief assumed a **teardown** missed these frames. It does not.

`cow_resolve_pte` now records the faulting task (`pa_set_owner`), and the
census reports owner liveness. Across every sampled orphan, in four
independent soaks:

```
[cens2] orphan[k] owner slot=6 live=1
[cens2] orphan[k] owner pid=6
[cens2] orphan refcounts: rc0=0 rc1=44 rc2=0
[cens2] orphan refcounts: rc>2=0  (of 44 sampled)
[cens2] orphan[k] owner now maps phys=0x…  here   <- a DIFFERENT frame
```

* **Owner is pid 6 and pid 6 is ALIVE.** No teardown will ever run for
  these frames. "A teardown sweep is missing" cannot be the explanation.
* **`cow_refcount == 1`, uniformly** — `rc0=0`, `rc2=0`, `rc>2=0` over 44,
  40, 25 and 24 sampled orphans in four runs. Not an over-share (that reads
  `>1`) and not a declined free (that reads `0`).
* **The owner maps a *different* frame at each orphan's VA**, so hamsh
  released its own reference correctly when it COW-copied away. The single
  surviving reference belongs to somebody else.
* The same fault VAs recur with different frames (`0x12be520`,
  `0x128d9d0`, `0x476028`, `0x1c00f4e98` each appear twice in one census),
  i.e. hamsh re-copies the same globals every launch and strands the
  previous copy each time.

So the shape is exact: **a private COW copy that hamsh has since displaced,
left at refcount 1 with zero mappers.** Every reclaimer refuses it by rule
(`_cow_release_forked_range` and `vma_free_cow_strays` free only at exactly
1 *and* only while walking a live task's range; nothing walks a frame no
task maps).

## 3. Where the reference does NOT die — two counted negatives

A reference stranded like that must have been discarded by a holder whose
PTE vanished. There are exactly two places an address space is replaced, and
`mm_reap_stale_leaf_audit` was pointed at both. It walks the user half under
the boot CR3 and counts present non-identity leaves that **no wholesale free
covers** (buddy-owned, and outside `image_phys` / `interp_phys` /
`ustack_phys` / `ustack_base`).

* **At reap** — placed after every range walk and *before* the wholesale
  frees, so those fields still name the runs about to be reclaimed.
* **At execve** — immediately before `elf_load_blob` stamps new leaves.

Result, over a full soak with tracking armed:

```
(no [stale] lines at all)
```

**Zero** in both. The first cut of the audit reported a flat 66 per reap
with first VAs `0x400000` — but that is 64 stack-prefix pages plus 2 image
pages, both about to be returned wholesale by physical base, which
deliberately leave their PTEs present. Once filtered to frames nothing
reclaims, the count is zero.

Therefore: **the leak is not a lost leaf at reap and not a lost leaf at
execve.** Both are now disproved at 0.00, alongside the eleven prior
disproofs.

## 4. Is the ~1.6-per-launch escape attributed?

**Partly, and less than the brief assumed.** Orphan accrual, site 11:

| soak | cycles | site-11 orphans | live | orphans/cycle |
|------|--------|-----------------|------|---------------|
| 4 min | 12 | 25 | 35 | ~2.1 |
| 4 min | 13 | 24 | 34 | ~1.8 |
| 5 min | 13 | 44 | 54 | ~3.4 |
| 10 min | 20 | 90 | 100 | ~4.5 |

In the 20-cycle run `PagesInUse` rose **+7.38 pg/cycle** while the census
proved **~4.5 pg/cycle** of orphans — so `cow_resolve_pte` orphans are
about **60%** of that run's leak, not the 86% the brief carried over from a
per-site *slope*. At 30 minutes the leak rate is higher still (below), so a
majority of the 30-minute leak is **not** attributed by the census.

The COW reference ledger (`cow_refs_added` / `cow_refs_dropped`) reads
`added=46289 dropped=43730 outstanding=2559` on a 13-cycle run. Outstanding
is the count of references the table believes exist; sloping it per cycle is
the cheapest next discriminator and it is now available from the first soak.

## 5. Soak numbers — and a measurement-discipline finding

Two 30-minute soaks, `mm/` byte-identical between them (the rebase touched
no file this pass touches). Both `HAMNIX_SOAK=1 SOAK_MINUTES=30`.

**`150d7f3d`, base `45f5c2e1`, 46 cycles / 1828 s / 184 apps**

```
MemFree     steady=-62.72 kB/cycle  (raw least-squares=-73.4, Theil-Sen=-63.84)
MemUsed     steady=+62.45 kB/cycle  (raw least-squares=+66.0, Theil-Sen=+63.18)
PagesInUse  steady=+15.61 pg/cycle  (raw least-squares=+16.4, Theil-Sen=+15.79)  <-- LEAK
VERDICT: LEAK — PagesInUse: +15.61/cycle (tolerance 1.0)
OVERALL FAIL
```

**`fe77d6ba`, base `19ab77a6`, 49 cycles / 1833 s / 196 apps**

```
MemFree     steady=-36.78 kB/cycle  (raw least-squares=-43.3, Theil-Sen=-36.90)
MemUsed     steady=+36.82 kB/cycle  (raw least-squares=+39.4, Theil-Sen=+36.89)
PagesInUse  steady=+9.21 pg/cycle   (raw least-squares=+9.8, Theil-Sen=+9.22)  <-- LEAK
VERDICT: LEAK — PagesInUse: +9.21/cycle (tolerance 1.0)
OVERALL FAIL
```

Estimators agree tightly in both (a clean series), and `MemFree` agrees with
`PagesInUse` exactly in both: −62.72 kB = −15.68 pg, −36.78 kB = −9.20 pg.
`VmaNodesLive`, `KmallocLive`, `TasksLive`, `liveWids` all flat at 0.00.

Horizon: 9.21 pg/cycle over a 37.4 s cycle ≈ **30 GiB/year**; 15.61 pg/cycle
over a 39.7 s cycle ≈ **47 GiB/year**. Brackets the brief's 32.4 GiB/year.

> **The spread between two 30-minute soaks on byte-identical `mm/` is
> 6.4 pg/cycle** (9.21 vs 15.61). The working assumption has been ">= 1.5
> pg/cycle". It is at least four times that at 30 minutes. Both runs had
> host load (a concurrent build / a concurrent `kobjdiff`), which is a real
> confounder — but that is exactly the condition these soaks run under.
> **A fix that claims less than ~6 pg/cycle cannot be validated by a single
> before/after pair.** Pass 13 should slope the census orphan count and the
> reference ledger, which are per-frame and immune to host timing, rather
> than trusting a `PagesInUse` delta.

Census orphan count before/after a fix: **not applicable — no fix shipped.**
The before-baseline is the table in §4.

## 6. Gates

```
[kobjdiff] kernel FUNCs compared: 11261
[kobjdiff] PASS — zero semantic kernel divergences across 11261 matched functions
[test_cow_fork] PASS -- copy-on-write fork keeps parent/child private
[test_mmap_fork] PASS -- copy-on-write fork over an mmap VMA keeps parent/child private
FES: parent reaped child status=0 / PASS          (test_forkexec_static)
[visual_gate] PASS: 3/3 launch-queue apps rendered, 3 launch-phase windows mapped
```

## 7. Cost of the instrumentation

~493 lines. Exactly **four** are unconditional: the reference-ledger
increments in `cow_share_page` / `cow_ref_inc` / `cow_drop_page`, each a
non-atomic add to a global *inside* a critical section that already pays
`local_irq_save` + a lock-prefixed spinlock acquire. Measured: ~6.9 k
increments per soak cycle, ~35 k cycles against a ~1.2e11-cycle budget
(~3e-7). Gating them would cost a global load plus a branch — the same order
as the add — so a gate buys conformance, not speed. Everything else is
`track census`-only or returns on `page_alloc_track_mode() == 0`.
`_build_meminfo` is untouched, so `/proc/meminfo` is byte-identical both
armed and disarmed. The full rationale is in the `mm/cow.ad` header.

## 8. The next counted question

The reference is not lost at reap and not lost at execve, yet it is
outstanding with no mapper. That leaves **an unmatched
`cow_share_page` at fork time** — a reference handed out for a mapping that
never became a durable mapper, or handed out twice for one.

Make the ledger **per call site**: tag each arm of
`_cow_share_one_page` (general / W^X-read-only / not-present-clear),
`_share_one_page`, and `cow_ref_inc`'s two callers on the add side; and
`_vma_free_cow_range`, `_cow_release_forked_range`, `vma_free_cow_strays`,
`cow_resolve_pte`, `region_free_cow_safe` on the drop side. Slope each per
cycle. The arm whose adds exceed the matching drops by ~2–4 per cycle is the
bug, and that is a one-soak measurement.

Second, cheaper, and worth doing first: the census has a **positive** control
(a planted unmapped frame, verified detected) but **no negative** control —
nothing proves the walk never reports a *mapped* frame as an orphan. The
circumstantial evidence is good (`site 6: 1 orphan of 41 live`, the sole
orphan being the planted control; and the owner demonstrably maps a
different frame at each orphan VA). Plant a **mapped** frame and assert it
is NOT reported. Until that exists, "44 orphans" carries the same class of
unproven assumption that cost passes 1–11.
