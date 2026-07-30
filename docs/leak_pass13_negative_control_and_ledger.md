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

## 4. Next counted question

Arms 1 and 2 both drain into arms 9 and 10, so the imbalance names a *pair*,
not a site. The PTE carries the answer — a W^X verbatim share leaves the COW
bit CLEAR, a general COW share force-SETS it — so arms 17/18 now split the two
teardown walks by the dropped PTE's COW bit. One soak then closes arm 1
against 17+18 and arm 2 against 9+10 independently, and the residue lands on
one of them.

Second: the bursts. Five cycles out of eighteen carry the leak. Which app
launch, or which reap, coincides with them? The ledger is per cycle; making it
per *app launch* would name the event.

## 5. Gates

```
[kobjdiff] kernel FUNCs compared: 11281
[kobjdiff] PASS — zero semantic kernel divergences across 11281 matched functions
[test_cow_fork]  PASS -- copy-on-write fork keeps parent/child private
[test_mmap_fork] PASS -- copy-on-write fork over an mmap VMA keeps parent/child private
[soak] 18 cycles / 483 s / 72 apps launched, 72 closed; SIGTERM audit CLEAN
```

## 6. Cost

The per-arm ledger is **gated** (`cow_ledger_enable`, armed by the same
`track on`/`track full`/`track off` verbs as the page tracker), so the only
unconditional additions in this whole effort remain pass 12's four declared
totals. Disarmed, `cow_set_arm` is one global load and one not-taken branch.
`_build_meminfo` is untouched, so `/proc/meminfo` is byte-identical armed or
disarmed. The negative control is `track`-ctl-only and ZAPs its PTE before
freeing.
