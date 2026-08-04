# Leak pass 21 — three points make a curve, and the curve says "settle"

Base `70cfde1d`. Pass 20 ran the hours-scale census for **8.02 hours** on one
boot, PASSed, and then said in its own §3 that the result could not answer the
question it was run for:

> An 8-hour PASS against a 256-page bar bounds the leak rate at roughly 32
> pages/hour … The measured motion is much smaller — +41 pages in 8.02 h — but
> this run **cannot distinguish** that from a one-time settle that has already
> finished. **Two samples give a delta, not a curve.**

This pass builds the instrument that can, closes the third residual pass 20 left
open, and — the part that matters — finds that the evidence for the first two
residuals was **already on disk** and points the other way from the brief.

---

## 1. THE INSTRUMENT

`scripts/test_leak_hours_census.sh` now takes `SAMPLES=N` batteries on ONE boot,
each `GAP_S` apart, with nothing launched and nothing closed between any of
them. `SAMPLES=2` is the default and is byte-for-byte the pass-19/20 shape, so
every captured two-sample log and the registered mutation gate keep their exact
meaning. Every anti-false-green property is preserved, and one is strengthened:

* the `SETTLE_S` pre-arm window still runs before the tracker is armed;
* the planted census control is still taken **after** the per-site dump, in
  every sweep;
* the fence markers the parser splits on are unchanged (`HC_SAMPLE <label>`,
  labels A..H);
* **the elapsed gap is now asserted on EVERY consecutive pair**, not on one.
  Four samples five minutes apart are two samples with extra steps, and a
  single end-to-end span check would have called that "8 hours".

`scripts/leak_hours_census_report.py` keeps every pass-20 endpoint rule on the
first/last pair — the per-site growth bar, the re-attribution credit, the
refusal to let a cancellable TOTAL exonerate anything — and adds the **TREND
arm** at N ≥ 3: consecutive pairs differenced, each converted to pages/hour so
unequal gaps stay honest, then classified by SHAPE.

| class | meaning |
|---|---|
| `FLAT` | whole-span growth under the resolution floor — nothing is said |
| `SETTLE` | the terminal rate is ≤ 0: it stopped |
| `DECAY` | the terminal rate is under half its earlier peak |
| `SUSTAINED` | the rate is still there at the end of the span — **a leak** |

### Why the trend rule has no rate bar

The absolute bar structurally cannot see a slow linear leak: 90 pages in 8 hours
is 96 MiB/year of unbounded accumulation and sails under a 256-page bar. The
obvious repair — a pages/hour bar — reintroduces the same blindness one decimal
place down, because a *sustained* positive rate is unbounded by definition and
no threshold on it is defensible. So the trend rule thresholds only on
**resolution**: a span of T hours cannot resolve a rate below about one page per
T hours, and below `TREND_MIN_PAGES` of whole-span growth the shape of the curve
is noise. The instrument is limited by its span, not by a tolerance. Buying a
smaller floor means running longer, and the doc says so instead of tuning.

### The credit, expressed as a rate

Pass 20's re-attribution credit says a shrinking site 0 (`unknown`, the
pre-arming population) can explain an attributed site's growth, and that the
honest verdict there is INCONCLUSIVE because frames are counted, not
identity-tracked. The trend arm sharpens it: only a bucket **still being
drained at the end of the span** can be feeding anything. A site 0 that has
finished shrinking is not an alibi at all, and that case is a FAIL
(`n4_leak_site0_already_settled`).

### Processes are classified but cannot convict

A SUSTAINED resident slope on a long-lived process is reported at INCONCLUSIVE,
never FAIL. The one process that grows in every real run of this gate is pid 6,
the serial shell — **and it grows because the harness drives it** with a
heartbeat every five minutes. Convicting it would be the instrument condemning
its own scaffolding, which is the exact false-red shape this campaign keeps
catching. The sites arm is the one that convicts.

---

## 2. PASS 20'S THIRD RESIDUAL, CLOSED ON REAL DATA

> **Arm 23's 9 `owner-unrecorded` survivors.** Not stray, not dead-owned; the
> discriminator simply has no owner recorded for them. An unrecorded owner is
> not an alibi.

Correct, and incomplete: an unrecorded owner is also not necessarily a hole.
Until this pass nothing could tell the two apart, because `[orgl] org=23
owner-unrecorded=9` is a **count**. The kernel was already printing what
settles it, per survivor:

```
[orgl] org=23 live[9] phys=0x000000000b164000
[orgl] live[9] va=0x0000000000000000 site=0
[orgl] live[9] cow_refcount=1
[orgl] live[9] owner: NOT RECORDED
```

and `pa_set_owner` in `mm/page_alloc.ad` is a **no-op while the tracker is
disarmed**, exactly as `pa_set_site` is:

```
def pa_set_owner(o: uint64):
    if _pa_trk_mode == 0:
        return
```

So `site=0` **and** `va=0` **and** `owner=0` arrive together, necessarily: that
frame was allocated before `track full` armed anything, and no owner *could*
have been recorded for it. An unrecorded owner on a **named** site is the
opposite finding — that path ran armed, stamped its site, and never called
`pa_set_owner` — and it is a hole in the discriminator with an address.

The adjudicator now separates them, and re-running **pass 20's own captured
8-hour log** gives the answer:

```
OK: arm 23: all 9 owner-unrecorded survivor(s) carry site=0 and va=0, i.e. they
    were allocated BEFORE `track full` armed the tracker — pa_set_owner is a
    no-op while disarmed (mm/page_alloc.ad), so no owner COULD have been
    recorded. This is the pre-arming population, not a hole in the
    discriminator; arming at boot removes it.
```

Not an alibi, and not a hole either: the same pre-arming population that the
re-attribution credit exists for, and the same fix removes both — **arm the
tracker at boot**.

The rule is enforced in four directions, not asserted: pre-arming is PASS, a
named site is INCONCLUSIVE, no per-frame detail at all is INCONCLUSIVE, and a
detail that covers fewer frames than the tally counted is INCONCLUSIVE (a
prefix attribution — the exact shape leak pass 16 caught in a survivor walk).

---

## 3. WHAT THE EVIDENCE ALREADY SAYS — AND IT DISPROVES THE BRIEF

The brief for this pass asked whether `vma_anon` +37 and `hamsh` +26 are
settles or leaks, and treated the 8-hour numbers as the thing to explain. They
are not. Put pass 20's 8.02-hour run beside a **6-minute** three-sample run of
the same gate on the same base, both anchored at the same post-arming baseline:

| quantity | 0.10 h (3 samples) | 8.02 h (2 samples) |
|---|---|---|
| site 6 `vma_anon` | 1 → 32 → 35 (**+34**) | 1 → 38 (**+37**) |
| pid 6 `hamsh` resident | 100 → 120 → 126 (**+26**) | 100 → 126 (**+26**) |

**Eight hours bought three more pages of `vma_anon` than six minutes did, and
zero more pages of `hamsh`.** Both curves are classified by the new arm without
being told what to look for:

```
site 6 vma_anon  1/32/35     rates +600.00 -> +58.38 pg/h   -> DECAY
pid 6  hamsh     100/120/126 rates +387.10 -> +116.76 pg/h  -> DECAY
```

That is the discrimination pass 20 could not make, and it lands on the opposite
side from the framing this pass was dispatched with. The +41 pages pass 20 called
"real growth hidden inside a −149 shrink" is, on this evidence, **not growth of
the machine at all**: it is the tracker *attributing* a fixed population as
site 0 drains into the named sites. In the 6-minute run site 0 goes 5979 → 5927
(−52) while the named sites take +34/+2/+2 — the same shape, at 1/80th of the
elapsed time. A quantity that reaches the same value in six minutes and in eight
hours has no slope to extrapolate.

This is why pass 20's residual was the right question and its magnitude framing
was the wrong emphasis, and it is the fifth consecutive pass whose evidence
contradicted the brief that ordered it.

The 6-minute run is *not* the proof — its intervals are inside the settle by
construction, and a settle that finishes in three minutes and a leak too slow to
see in three minutes also print the same numbers at that scale. It is a strong
prior. The proof is the long run below, whose intervals are two hours each and
whose baseline is fifteen minutes of settle plus two hours before the first
interval that matters.

---

## 4. THE LONG RUN — CAPTURED, AND JUDGABLE WITHOUT ITS AUTHOR

Launched detached on this host, KVM + OVMF on the shipped installer image, one
boot, four samples, two hours apart:

```
OUT_DIR=build/leak_hours_census/pass21-4x2h \
SAMPLES=4 GAP_S=7200 SETTLE_S=900 MIN_GAP_S=7000 \
    bash scripts/test_leak_hours_census.sh
```

Total wall clock ≈ 6.4 h of gap plus a settle, a rebuild and four sample
batteries. **It is expected to outlive the agent that launched it — pass 20's
did, and that run is the one that produced the campaign's strongest negative
result.** So the log is the deliverable and the verdict is a command:

```
python3 scripts/leak_hours_census_report.py \
    build/leak_hours_census/pass21-4x2h/serial.log \
    build/leak_hours_census/pass21-4x2h/sample_stamps.txt \
    7000 256 4 16 0.5
```

Read the `=== TREND across 4 samples ===` block. `SUSTAINED` on site 6 with the
site-0 credit not covering it convicts `vma_anon` as a leak with a rate;
`SETTLE` or `DECAY` retires pass 20's residual #1 for good. The same block
classifies pid 6, residual #2.

If the run died mid-flight, the partial log still adjudicates: a missing sample
is INCONCLUSIVE with the reason named, never a PASS, and a hole in the curve is
reported as a hole rather than as a flat point.

---

## 5. MUTATION-PROVEN, 44 OF 44

The adjudicator is a separate file from the gate precisely so that judging a log
needs no boot, and `scripts/test_leak_hours_report_mutations.sh` grew from 22
cases to 44. The 22 pass-19/20 cases are unchanged and still caught. The new
ones exist only to hold the new logic honest, and each of them keeps the
ENDPOINT verdict at PASS unless stated — if the trend arm regresses, they go
green and no other rule notices.

| new mutation | verdict | what it pins |
|---|---|---|
| `n4_clean` | PASS | four samples, nothing moves — the negative control for the whole arm |
| `n4_linear_leak_under_bar` | **FAIL** | 15 pg/h, span +90, **under** the 256-page bar. Only the shape convicts it |
| `n4_settle_decaying` | PASS | the SAME endpoint growth, rates 12→4→2 |
| `n4_leaks_then_stops` | PASS | leaked for four hours and stopped: not a slope |
| `n4_noise_zero_trend` | PASS | oscillation under the resolution floor |
| `n4_deltas_under_bar_sum_over` | **FAIL** | three deltas of +200 each **under** the bar, +600 over the span — the exact blindness a per-DELTA bar would have |
| `n4_big_settle_still_over_bar` | **FAIL** | a decaying curve that still puts 350 pages on the machine: **shape does not waive the absolute bar** |
| `n4_leak_masked_by_shrinking_site0` | INCONCLUSIVE | site 0 still draining at exactly the leak's rate |
| `n4_leak_site0_already_settled` | **FAIL** | site 0 finished draining: it cannot be feeding a 15 pg/h site |
| `n4_leak_with_harness_cat` | **FAIL** | a harness `cat` must NOT buy a leak the "a process started" amnesty |
| `n4_leak_with_real_app_started` | PASS | a real app starting still does |
| `n3_settle` / `n3_linear_leak` | PASS / **FAIL** | the minimum N that has a curve at all |
| `n4_process_sustained` | INCONCLUSIVE | a still-climbing resident set blocks PASS and cannot redden |
| `n4_process_settles` | PASS | the same +60, decaying |
| `n3_but_four_asked` | INCONCLUSIVE | fewer samples than required is never a PASS |
| `n4_one_gap_too_close` | INCONCLUSIVE | one four-minute interval among three good ones |
| `n4_leak_below_resolution_floor` | PASS | **the documented hole**: 2 pg/h is invisible at a 6-hour span. Fixed by a longer span, not a lower threshold |
| `arm_unrec_prearming` | PASS | unrecorded owners on site=0/va=0 are structural |
| `arm_unrec_named_site` | INCONCLUSIVE | unrecorded owners at a named site = `pa_set_owner` missing on that path |
| `arm_unrec_no_detail` | INCONCLUSIVE | an unattributed unrecorded owner is not even an argument |
| `arm_unrec_detail_prefix` | INCONCLUSIVE | the detail covers 4 of 9: a prefix, not a clean set |

`n4_leak_with_harness_cat` came out of reading pass 20's captured summary rather
than out of a theory, and it is the ugliest of the set: pass 20's real 8-hour
run reported `processes that appeared during the gap: 62/cat` — the battery
spawns one `cat` per `statm` read — and a non-empty `born` set **downgrades every
growth rule from a FAIL to a note**. The instrument was suppressing its own only
page-growth assertion with a process it had spawned itself. Harness comms are
now reported and excluded from the amnesty.

Gate run on this branch: `[hourscens-mut] PASS — all 44 mutations were caught`,
about a second, no QEMU. Registered in `scripts/ci_battery_manifest.txt`. The
multi-hour census gate stays unregistered for the reason it always has: its
whole assertion is that its samples are hours apart, and it cannot live inside a
50-minute shard.

---

## 6. THE HONEST RESIDUAL

1. **The 4×2h run had not returned when this was written.** Its log and the
   command that judges it are in §4. A captured log plus a judgable command is
   a legitimate deliverable and is exactly how pass 20's result was obtained,
   but it is not a verdict, and this document does not claim one.
2. **The resolution floor is real and is set by the span.** At a 6-hour span
   this instrument cannot see 2 pages/hour, which is 68 MiB/year — well inside
   the range that matters for a months-and-years target.
   `n4_leak_below_resolution_floor` documents the hole as a PASSING case on
   purpose. Buying a smaller floor costs a longer run, and nothing else.
3. **Site 0 still exists, so the credit still exists.** Every re-attribution
   argument in passes 20 and 21 — including the pre-arming answer to residual
   #3 — is an argument about frames the tracker never saw allocated. Arming the
   page tracker at BOOT would empty site 0, delete the credit, delete the
   `owner-unrecorded` population, and make every per-site number an attribution
   rather than a difference of attributions. That is one kernel change and it
   retires three separate ambiguities. **It is the highest-value item this
   campaign has left.**
4. **The gap is still idle by design.** `GAP_LOAD=1` exists and has never been
   run at hours scale.

---

## 7. THE CAMPAIGN RULE THIS PASS ADDS

Pass 15: a soak mean is not an estimator.
Pass 18: minutes-long runs cannot see one frame per hour.
Pass 19: build the two-sample one-boot census.
Pass 20: a TOTAL is cancellable, and two samples give a delta, not a curve.
**Pass 21: a delta has no shape. Measure the SLOPE at the END of the span —
and before extrapolating any growth, check what the same quantity reads at a
fraction of the elapsed time, because a number that is already there after six
minutes has no rate to project.**
