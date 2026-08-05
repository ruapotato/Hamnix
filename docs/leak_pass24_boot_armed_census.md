# Leak pass 24 — the first hours-scale census whose site numbers mean anything

Base `32a08646` (main, carrying leak pass 22 `7f4a116f` and pass 23 `c1ad90db`).

Every hours-scale census verdict this campaign has produced — passes 19, 20, 21
— was reached with roughly **100% of live frames unattributed**. Pass 22 armed
the page tracker in `mem_init`; pass 23 removed the excuse that pass 22's own
fix had turned into a false green. This pass is the first run of the instrument
in the world those two commits created.

---

## 1. THE TWO CLAIMS THIS PASS RESTS ON, VERIFIED FIRST

Neither was taken from the brief. Both were checked against the tree and against
this run's own serial log.

### Pass 22 — the tracker really is armed at boot

`mm/page_alloc.ad:674 page_alloc_track_boot_arm()` is called from the arch
`mem_init()` flow. It is a kernel-internal boot-path call, not a poll and not
userland-driven — which matters, because
[[feedback_kernel_reclaim_not_userland_conditional]] forbids reclamation that
depends on a userland poll, and this change deliberately does not create one:
`free_pages` still unstamps under the same buddy lock that frees.

The load-bearing second half is at `mm/page_alloc.ad:646-660`, and it is the
part that makes boot-arming worth anything. `page_alloc_track_enable` used to
call `page_alloc_track_reset()` unconditionally, which parks the entire live
population under `PA_SITE_UNKNOWN`. The census arms with `track full` after its
settle window, so an unconditional re-baseline would have **thrown away every
attribution bringup recorded and re-parked it all in site 0** — boot-arming
would have been a no-op for exactly this gate. The re-baseline is now
conditional on `fresh || _pa_trk_stale`.

Confirmed on this run's own log, printed during bringup:

```
[000196] [trk] boot-arm mode=2 frames=261632
[000197] [trk] boot-arm bytes=3401216 site0=0
```

Mode 2 (per-frame tag words, the mode `track org`'s owner/tag fields need),
261632 frames, **3401216 bytes = 3.24 MiB**, and **`site0=0` at the arm** —
site 0 is empty before the first buddy allocation. The pass-22 numbers are
reproduced exactly.

### Pass 23 — the adjudicator refuses the excuse on a boot-armed log

`scripts/leak_hours_census_report.py:244 parse_boot_armed()` keys on
`[trk] boot-arm mode=N frames=N`, and `check_unrecorded_owners` branches on it:
a `site=0 / va=0 / owner-unrecorded` survivor is a PASSING note on a
userland-armed log (it is the pre-arming population, and `pa_set_owner` is a
no-op while disarmed) and an **INCONCLUSIVE** on a boot-armed one (there is no
pre-arming population left to belong to, so the same evidence now means an
allocation path that called neither `pa_set_site` nor `pa_set_owner`).

`scripts/test_leak_hours_report_mutations.sh` run on this branch:
`PASS — all 45 mutations were caught`, including the new
`arm_unrec_prearming_boot_armed -> INCONCLUSIVE`. Note the failure mode this
guards is a **false green bought BY a fix** — the fix landing is what flipped
the reading's sign, which is the hardest kind to notice.

One further detail that had to be checked before trusting any `[orgl]` line:
the **COW ledger** (`cow_ledger_enable`, `mm/cow.ad`) is *not* boot-armed — it
is still armed by `track full` from userland. But `pa_set_owner`'s no-op guard
is on `_pa_trk_mode`, which *is* boot-armed, so a frame that entered a COW
origin arm and has no recorded owner genuinely had no `pa_set_owner` call. The
pass-23 reading is sound on this log. (The COW ledger's own pre-arming
population lands in arm 0, which is not in the sampled arm list.)

---

## 2. THE RUN

```
OUT_DIR=build/leak_hours_census/pass24-5x90m \
SAMPLES=5 GAP_S=5400 SETTLE_S=900 MIN_GAP_S=5200 TREND_MIN_PAGES=16 \
    bash scripts/test_leak_hours_census.sh
```

One boot, KVM + OVMF on the freshly built shipped installer image, **five**
sample batteries **90 minutes apart**: a **6.00-hour span** with **four**
consecutive rates. Arms `1 2 5 19 21 23 24`. Nothing launched, nothing closed,
between any two samples.

Five points at 90 minutes rather than pass 21's four at two hours is the same
wall clock buying one more rate. The trend arm classifies on the *shape* of the
rate sequence, so a fourth rate is a real gain and the per-interval resolution
cost (1 page over 1.5 h = 0.67 pg/h) is far below anything the arm thresholds
on.

### The resolution floor, stated before the numbers

The instrument is limited by its span, not by a tolerance, and the span is
6.00 hours. `TREND_MIN_PAGES=16` pages of whole-span growth is the floor, so:

* **trend floor ≈ 16 pages / 6.00 h = 2.7 pages/hour ≈ 91 MiB/year.**
* absolute bar `GROWTH_FAIL_PAGES=256` over the span = 42.7 pg/h ≈ 1.5 GiB/yr.

**A leak slower than ~2.7 pages/hour is invisible to this run and no result
below should be read as excluding one.** Buying a smaller floor costs a longer
run and nothing else — that is pass 21's `n4_leak_below_resolution_floor`,
which is a *passing* mutation on purpose.

<!-- VERDICT SECTION FILLED IN WHEN THE RUN RETURNS -->
