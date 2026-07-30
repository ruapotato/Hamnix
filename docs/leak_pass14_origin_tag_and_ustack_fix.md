# Leak pass 14 — the frame is tagged, the burst is named, and the leak is fixed

Base `b899ed1b` (pass 13). Three results, in the order they matter.

---

## 1. THE ORIGIN TAG — every drop now reports its true origin

Pass 13's per-arm ledger keys the ADD side exactly and the DROP side by
whichever call site happens to be executing. It closed on a structural blind
spot it was careful to publish as a **lead, not a result**:
`region_free_cow_safe` drops ~68.76 refs/cycle from a *physical base* with no
PTE in hand, so the COW-bit classifier could not bucket them at all, and where
those 68.76 landed decided whether the leak sat on the W^X verbatim share
(arm 1) or the general COW share (arm 2).

One byte per PFN removes the inference. The byte records the arm that took the
frame's **first** reference (the `0 -> N` transition); every later add and every
drop on that frame is tallied against that arm regardless of which call site
executes it and regardless of whether a PTE exists. Per origin the ledger keeps
`add`/`drop` (references) and `born`/`died` (frames), and `born - died` is the
leaked-frame population **as a count**, which is what a bursty leak needs.

53-cycle soak, `HAMNIX_TRACK_ALLOCS=full`:

| origin | site | add | drop | born | died | live |
|--------|------|----:|-----:|-----:|-----:|-----:|
| 1 | `_cow_share_one_page`, W^X RO verbatim | 5704 | 5704 | 2852 | 2852 | **0** |
| 2 | `_cow_share_one_page`, general COW | 70409 | 68723 | 4182 | 2519 | **+1663** |
| 5 | `cow_resolve_pte`, fresh copy | 9698 | 9688 | 2872 | 2862 | +10 |
| 0 | untagged (predates the arming) | 191661 | 191936 | 0 | 34 | n/a |

* **Arm 1 closes EXACTLY — born == died == 2852.** Pass 13's most likely
  reading is now a measured result, and the W^X verbatim share is disproved at
  0.00 on a frame basis.
* **Arm 2 owns the entire leaked-frame population.**
* **Arm 5 sits at +10 and does not move.** A 12-minute soak on a different
  build read +10 as well (1222/1212), and a third read +10 (818/808). Three
  independent runs, an identical residue of exactly ten frames: that is a fixed
  resident set, not a slope. `cow_resolve_pte` is now exonerated on FRAMES,
  where pass 13 exonerated it on references.

The census agrees without being asked. It prints each orphan's origin straight
out of the tag, and over 64 sampled orphans: **arm 2 count=58, arm 0 count=6,
arm 1 count=0.**

Bucket 0 is "first reference predates the arming"; `cow_ledger_enable` zeroes
the tag table so a stale tag cannot make an arm look like it over-drops, which
makes `died > born` normal there and exact for arms >= 1.

## 2. THE BURST IS A NAMED, DETERMINISTIC EVENT

Pass 13 established the leak is bursty and bimodal, and that the run-to-run
spread IS the burst count — so the soak MEAN is not an estimator of it. A
bimodal outcome means an event that either happens or does not, and the way to
name it is to **sample finer than the thing that varies**. `track net` is one
line and O(arms), so the soak now emits it after every individual app launch
and joins it to a host-side launch-order file.

53 cycles, 212 launches, per-app COW frames stranded per launch:

```
app                n   live frames/launch     max
hamtermscene      23                298.2     365
hammonscene       24                  1.0       7
hamaudioscene     23                  0.3       5
hamcalcscene      23                  0.3       5
hambrowse         23                  0.1       9
hamwrite          24                -46.3      10
hamfmscene        24                -57.1       6
hamslides         24                -57.1      12
hamsheet          24                -57.9      10

hamtermscene: 23/23 launches stranded frames
  c3:+365 c5:+358 c7:+358 c9:+358 c12:+350 c14:+281 c16:+229 c18:+358
  c21:+354 c23:+347 c25:+254 c27:+339 c30:+272 c32:+230 c34:+296 c36:+358
  c39:+333 c41:+192 c43:+233 c45:+350 c48:+222 c50:+214 c52:+208
```

**23 of 23.** Every other app is within noise of zero; the negative entries are
the delayed release of the *previous* terminal's frames. `hamtermscene` is the
only app in the pool that spawns a child (`/bin/hamsh` running
`/etc/rc.de-user`), so it is the only one that runs the COW fork share at all.

The leak stopped being a slope and became a test case. That also made the
measurement three times cheaper: because the event is deterministic per launch,
a 12-minute soak now settles what previously needed thirty.

## 3. THE BUG — the user stack was the last owner span freed raw

Arm 2 still named a *walk* rather than a *span*: `vm_cow_share_all` COW-shares
three owner spans into every fork child, and each drains through a different,
separately-gated teardown. Splitting arm 2 by span (arm 2 kept as the default,
so the split is total and lossless) settled it in one 12-minute soak:

| origin | span | born | died | live |
|--------|------|-----:|-----:|-----:|
| 19 | ELF image | 342 | 342 | **0** |
| 21 | user stack | 964 | 109 | **+855** |
| 2 | residual = mmap-VMA fork (`vma_fork_copy`) | 578 | 507 | +71 |

The image span closes **exactly**. The stack span returns **11%** of what it
creates, and 855 of that run's 936 tagged live frames are the stack.

The cause is one line. Of the three shared owner spans:

* image + PT_INTERP -> `region_free_cow_safe` — drains the per-PFN refcount
  before pooling;
* brk -> `vma_free_reserved_range` — routes every frame through
  `cow_drop_page`;
* **user stack -> `free_pages(ustack_phys, ...)` — RAW.** Never consulted the
  refcount table, in `task_reap` step 2 and in `task_free_owner_regions`.

`region_free_cow_safe`'s own comment asserts it "matches the brk/stack COW-safe
reclaim". For the stack that had never been true.

**Why a stale count costs PAGES and not just tidiness.** `free_pages` pools the
run with non-zero refcount entries. The next allocation of that PFN inherits
the poison, so the next `cow_share_page` sees `cur != 0` and bumps `N -> N+1`
instead of `0 -> 2`; the matching `cow_drop_page` then stops one short of 0 and
the frame is never freed by its last holder. That is precisely the population
the census has been reporting since pass 11 — refcount 1, zero mappers, owner
alive — and it is why every reclaimer refused these frames by rule.

`ustack_free_cow_safe` mirrors `region_free_cow_safe` exactly, including
declining to free a run that any live relative still COW-maps — which the raw
`free_pages` could already commit as a use-after-free today.

## 4. VALIDATION — counted quantities, never a soak-mean pair

The brief forbids validating against a before/after soak mean, because the
distribution is bursty and bimodal and the mean is not the estimator. Both
soaks below are 12 minutes, same workload, same app pool; what is compared is
**counted**.

| counted quantity | before | after |
|------------------|-------:|------:|
| census orphaned frames | **191** | **1** |
| census orphan origins (of 64 sampled) | arm 21: 42, arm 0: 22 | — |
| org=21 user stack, born / died | 964 / 109 | **768 / 768** |
| org=21 add / drop | 2808 / 1946 | **1536 / 1536** |
| org=19 image, born / died | 342 / 342 | 228 / 228 |
| tagged live frames (sum org>=1) | 936 | **66** |
| runs held back by the new guard | n/a | **0** |

* **The census reports ONE orphan after the fix, and that one is the
  deliberately planted positive control.** Both controls stayed green in the
  same census (positive detected; the mapped negative control marked reachable
  and not counted), so this is a validated instrument reporting an empty
  population, not a blind one reporting zero.
* **The stack span closes exactly**, 768/768 and 1536/1536, where it previously
  returned 109 of 964.
* **Zero held runs**: the new "decline to free" guard never fired, so the fix
  did not trade a refcount leak for a page leak.
* The residue is arm 2's mmap-VMA fork path (+56) and `cow_resolve_pte`'s
  constant +10.

Corroborating but explicitly **not** the validation, since it is exactly the
statistic the brief rejects: `PagesInUse` on those two runs read +11.02 and
+2.02 pg/cycle. It is recorded only because it moves the same way; no claim
rests on it.

## 5. Gates

```
[kobjdiff] PASS — zero semantic kernel divergences across 11296 matched functions
[kobjdiff] PASS — native kernel codegen matches the seed (semantic)
[test_cow_fork]  PASS -- copy-on-write fork keeps parent/child private
[test_mmap_fork] PASS -- copy-on-write fork over an mmap VMA keeps parent/child private
[soak C] 22 cycles / 725 s / 88 apps launched, 88 closed; SIGTERM audit CLEAN
[census] control OK: planted orphan detected
[census] negative control OK: mapped frame at va=0x2c0000000
```

The soak still ends `OVERALL FAIL` — its tolerance is 1.0 pg/cycle and the
residue is above that. The tolerance is a gate threshold, not the target, and
it was not touched.

## 6. Cost

The origin tallies are gated with the rest of the ledger. The TABLE is one byte
per 4 KiB frame from memblock at `cow_init`, **measured** from the soak's own
boot log rather than asserted:

```
[cow] origin table: 261632 bytes (1/frame)      (qemu -m 1G)
```

0.0244% of RAM, half what the refcount table beside it already costs. It is
allocated unconditionally because memblock closes long before any ctl write
could arm the ledger; nothing writes it while disarmed. The only unconditional
additions in this whole effort remain pass 12's four declared totals.
`_build_meminfo` is untouched, so `/proc/meminfo` is byte-identical armed or
disarmed.

`ustack_free_cow_safe` is a real, unconditional cost on the reclaim path: two
passes over the run's frames (256 frames for a 1 MiB stack) doing one refcount
table read each, on a path that already does a page-table teardown and several
`free_pages`. Its `[ustack] held run` diagnostic is `page_alloc_track_mode()`-
gated.

## 7. A build-hole note, carried forward

Pass 13 found `_HAMNIX_IMG_INPUT_DIRS` did not list `mm`, so the entire memory
manager could be edited without marking the shipped image stale, and a leak
measurement from the wrong build looks entirely plausible. Fixed in `72f16540`.
Every image built in this pass was checked against the commit it was supposed
to contain: 8, 25 and 7 minutes newer respectively. That check is cheap and it
is the only signal there is.

## 8. The next counted question

Two named residues remain, both small and both now attributable by construction
rather than by argument:

1. **org=2 after the split = the mmap-VMA fork path** (`vma_fork_copy` ->
   `vm_cow_share_range`), +56 frames over 12 minutes. Give it its own arm and
   close it against `_vma_free_cow_range` the same way arm 21 was closed. It is
   the only share path left without a per-span origin.
2. **org=5 = `cow_resolve_pte`, a constant +10 across three independent runs.**
   Ten frames that never die and never grow is a *resident set*, not a leak —
   most likely the copies made for tasks that live for the whole boot. Confirm
   it by dumping the ten frames' owners once; if they are all long-lived system
   tasks, arm 5 can be closed for good rather than re-litigated every pass.

Neither needs a 30-minute soak. That is the durable win of pass 14: with the
frame tagged and the burst named, the instrument answers in twelve minutes what
used to take thirty and still came back ambiguous.
