# Leak pass 13 — the census is validated, and the unmatched reference is named

Base `79360ab3`. Two results, in the order they matter.

---

## 1. THE NEGATIVE CONTROL — PASS

Pass 12's census had a positive control (`track plant`: an unmapped frame it
must find) and no negative one. Every conclusion pass 12 drew — the three span
kinds, the live owner, the two disproofs — rests on the census not
manufacturing orphans out of live frames, and nothing had ever tested that.

`track mplant` now allocates one order-0 frame at a user-mapped site and MAPS
it into a long-lived address space at a scratch VA (11 GiB, above RAM top so
`phys != VA` and the leaf survives the walk's identity filter, reached only
through tables the walk CRACKED). Both controls were outstanding in the same
census of an 18-cycle soak:

```
[census] planted control orphan phys=0x15be7000 tag=0xc0ffee00
[census] planted MAPPED control phys=0x1733c000 va=0x2c0000000
[census] mapped control installed in task slot 6
[census] walked 20 address spaces
[census] orphaned frames: 33 (of 6395 live)
[census] control OK: planted orphan detected
[census] negctl phys=0x1733c000 site=6 reachable=1
[census] negative control OK: mapped frame at va=0x2c0000000
[census] site 6: 1 orphans, live 118
[census] site 6 orphan[0] tag_va=0xc0ffee00        <- the plant, and ONLY the plant
[census] site 11: 32 orphans, live 42
```

Both controls sit at **site 6**, so this is a paired test on one site: of 118
live VMA_ANON frames the census reported exactly one orphan, it was the
deliberately-unmapped plant, and the deliberately-MAPPED frame next to it was
marked reachable and not counted.

**The census neither under- nor over-reports.** Pass 12's numbers stand.

Reproduced on a second, independent 21-cycle soak (different image build,
different orphan population -- 113 orphans of 6323 live, 112 of them at site
11): `negctl phys=0x16fa5000 site=6 reachable=1`, `site 6: 1 orphans, live 59`,
that one orphan again being the plant. Two runs, both controls, both green.

## 2. THE UNMATCHED ARM — it is NOT cow_resolve_pte

The ledger is now per call site (16 arms; `track ledger`, O(arms), sampled
every cycle). 18 cycle-deltas, `HAMNIX_TRACK_ALLOCS=full`:

| arm | site | add/cyc | drop/cyc | net |
|-----|------|--------:|---------:|----:|
| 1 | `_cow_share_one_page` W^X read-only verbatim | 1445.67 | — | +1445.67 |
| 2 | `_cow_share_one_page` general COW | 2931.61 | — | +2931.61 |
| 5 | `cow_resolve_pte` fresh copy | **55.44** | — | +55.44 |
| 9 | `_vma_free_cow_range` | — | 1674.78 | −1674.78 |
| 10 | `_cow_release_forked_range` | — | 2588.22 | −2588.22 |
| 11 | `vma_free_cow_strays` | — | 1.78 | −1.78 |
| 13 | `cow_resolve_pte` displaced page | — | **55.44** | −55.44 |
| 14 | `region_free_cow_safe` | — | 64.56 | −64.56 |
| | **SUM** | 4432.72 | 4384.78 | **+47.94** |

`UNATTRIBUTED arm=0: add=0 drop=0` — the instrumentation is complete, so the
residue is not hiding in an untagged call site.

* **`cow_resolve_pte` balances EXACTLY: 55.44 in, 55.44 out, to two decimals
  over 18 cycles.** Pass 12 ended on "the remaining explanation is an unmatched
  `cow_share_page`… a reference handed out for a mapping that never became a
  durable mapper", and named `cow_resolve_pte`'s `cow_ref_inc` among the
  suspects. It is not it. **Disproved at 0.00.**
* The **entire +47.94 refs/cycle imbalance is in the FORK-SHARE pair**: arms
  1+2 add 4377.28/cyc, arms 9+10+11+14 drop 4329.34/cyc.
* Eight arms are **dead** under the DE workload — `_share_one_page`
  (`vm_share_range`), `vm_cow_ref_range`, all three shared-mmap page-cache
  refs, the file-backed teardown, the unmap range and the pgc-fail undo all
  read zero. They cannot be the leak and need not be investigated.

## 3. THE LEAK IS BURSTY, AND THAT IS WHY TWO IDENTICAL BUILDS DIFFER BY 6.4

Per-cycle net (adds − drops), in order:

```
7, 133, 2, 128, 7, 28, 0, 128, 4, 0, 126, 0, -22, 0, 71, 1, 250, 0
```

Twelve of eighteen cycles are ≤ 7. Five are 71–250. The mean of 47.94 is
**dominated by a handful of bursts**, and six cycles leak essentially nothing.

The brief predicted this shape: *"a bimodal outcome usually means an event that
either happens or does not."* It does. A 30-minute soak that catches four
bursts and one that catches eight differ by exactly the kind of margin the two
byte-identical pass-12 soaks showed (9.21 vs 15.61 pg/cycle). **The run-to-run
spread is not measurement noise and not host load — it is the burst count.**
This also means a mean-based comparison of two soaks is the wrong statistic
even in principle; the right one is the per-arm counted balance, which is what
this ledger provides.

(This run: `PagesInUse +4.85/cycle`, 18 cycles / 483 s / 72 apps. Note refs are
not pages — a burst of shared references strands fewer frames than it counts.)

## 4. Soak B — the arm 1 / arm 2 split, and what it did NOT settle

Arms 17/18 split the two teardown walks by the dropped PTE's COW bit (a W^X
verbatim share leaves it CLEAR, a general COW share force-SETS it). Second
soak, 21 cycle-deltas, freshly built image, `arm=0` again exactly zero:

| arm | site | add/cyc | drop/cyc |
|-----|------|--------:|---------:|
| 1 | share, W^X read-only verbatim | 1452.95 | — |
| 2 | share, general COW | 2989.05 | — |
| 5 | `cow_resolve_pte` copy | **59.52** | — |
| 9 | `_vma_free_cow_range`, COW-set | — | 1718.33 |
| 10 | `_cow_release_forked_range`, COW-set | — | 1190.29 |
| 11 | `vma_free_cow_strays` | — | 1.57 |
| 13 | `cow_resolve_pte` displaced | — | **59.52** |
| 14 | `region_free_cow_safe` | — | 68.76 |
| 17 | `_vma_free_cow_range`, COW-clear | — | 3.90 |
| 18 | `_cow_release_forked_range`, COW-clear | — | 1414.00 |

Outstanding slope **+45.14 refs/cycle** (soak A: +47.94 — reproducible), and
**arm 5 balances arm 13 EXACTLY a second time, 59.52/59.52.** Two independent
runs, two different absolute rates, identical to the hundredth. `cow_resolve_pte`
is not the leak, and that is now established rather than suggested.

The split did **not** cleanly isolate one share arm, and the reason is worth
recording because it is the next obstacle:

* pairing arm 1 with 17+18 and arm 2 with 9+10 leaves residue in BOTH
  (+35.05 and +80.43);
* `region_free_cow_safe` (arm 14, 68.76/cyc) works from a PHYSICAL base and
  has no PTE, so the COW-bit classifier cannot bucket it. Where those 68.76
  land decides the answer. Region frames are the ELF image, i.e. exactly what
  the W^X verbatim share (arm 1) shares — assigning them there gives

  ```
  arm 1 bucket: 1452.95 add vs 1486.66 drop   net  -33.71
  arm 2 bucket: 2989.05 add vs 2910.19 drop   net  +78.86
  ```

  which puts the whole leak on the **general COW share**. That is the most
  likely reading, but it rests on an assignment the instrument did not
  measure, so it is stated here as a lead and NOT as a result.

## 5. Next counted question

**Tag the frame, not the call.** The COW-bit classifier reads the PTE at drop
time, which is a proxy for origin and breaks down exactly where it matters
(`region_free_cow_safe` has no PTE at all). Record the ARM that first took a
frame's reference — one byte per PFN alongside the refcount table, written on
the 0->N transition — and every drop then reports its true origin with no
inference. That closes arm 1 and arm 2 against their real drops and needs one
soak.

Second: the bursts. Soak B repeats the pattern with wider swings (one cycle at
-183, one at +314). Five or six cycles out of twenty carry the whole leak. The
ledger is per cycle; sampling it per APP LAUNCH would name the event, and a
named event is a reproducible test case rather than a slope.

## 5. Gates

```
[kobjdiff] kernel FUNCs compared: 11281
[kobjdiff] PASS — zero semantic kernel divergences across 11281 matched functions
[test_cow_fork]  PASS -- copy-on-write fork keeps parent/child private
[test_mmap_fork] PASS -- copy-on-write fork over an mmap VMA keeps parent/child private
[soak A] 18 cycles / 483 s / 72 apps launched, 72 closed; SIGTERM audit CLEAN
[soak B] 21 cycles / 605 s / 84 apps launched, 84 closed; SIGTERM audit CLEAN
```

Both soaks still end `OVERALL FAIL` on `PagesInUse` — no fix was attempted
this pass, deliberately. Pass 12 established that a fix under ~6 pg/cycle
cannot be validated by a soak pair, and pass 13 has now shown why (the leak is
bursty, so the soak MEAN is the wrong statistic even in principle). Shipping a
speculative fix before the origin tag exists would have produced exactly the
unfalsifiable claim the brief forbids.

## 8. A build hole found in passing, and it would have poisoned this pass

`scripts/_installer_img.sh`'s `_HAMNIX_IMG_INPUT_DIRS` — the list that decides
whether the shipped image is stale — did not contain **`mm`**. The entire
memory manager (page_alloc.ad, vma.ad, cow.ad, slab.ad, reclaim.ad), all
inside `init/main.ad`'s compile closure, could be edited without marking the
image stale. Soak B was launched immediately after committing the arms-17/18
change to mm/cow.ad and mm/vma.ad and reported `image (0d00h11m old)`: it was
about to measure the PREVIOUS build and report the numbers under the new one.
Caught only because the timestamp was implausible.

This is worse for a leak gate than for a feature gate — a leak measurement
from the wrong build looks entirely plausible, so nothing downstream would
have flagged it. `linux_abi` (the whole Linux syscall shim) had the same hole,
and `adder` is compiled into shipped user binaries. All three added. It is the
third time this list has been found short (`sys` 2026-07-25, `tests`
2026-07-28), which is the argument for the producer-side always-overwrite
contract that file's own comment already makes.

## 6. Cost

The per-arm ledger is **gated** (`cow_ledger_enable`, armed by the same
`track on`/`track full`/`track off` verbs as the page tracker), so the only
unconditional additions in this whole effort remain pass 12's four declared
totals. Disarmed, `cow_set_arm` is one global load and one not-taken branch.
`_build_meminfo` is untouched, so `/proc/meminfo` is byte-identical armed or
disarmed. The negative control is `track`-ctl-only and ZAPs its PTE before
freeing.
