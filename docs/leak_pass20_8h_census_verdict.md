# Leak pass 20 — the 8-hour census, and what a PASS at that scale does and does not buy

Base `4b75fc82`. Pass 19 built the instrument — one boot, two identical census
batteries hours apart, nothing launched or closed in between — and ran it at a
gap short enough that its own closing words called the result provisional. This
pass ran that same instrument at **8.02 hours** on one boot, on this host, and
adjudicated the captured log with the strictest report tooling the campaign has.

The run is the one that outlived its owning agent: the agent that launched it
died, the run did not. Its log was captured at
`build/leak_hours_census/pass20-8h/` (sample A `1785785469` = 12:31, sample B
`1785814334` = 20:32, gap 28865 s).

---

## 1. THE VERDICT

Re-adjudicated on `main` after the merge, against the real captured log, with
`min_gap_s=7200` and a `growth_fail_pages=256` bar:

```
python3 scripts/leak_hours_census_report.py \
    build/leak_hours_census/pass20-8h/serial.log \
    build/leak_hours_census/pass20-8h/sample_stamps.txt 7200 256
=> VERDICT: PASS — no measurable leak at hours scale   (rc 0)
```

Both sweeps: **the only unaccounted frame in the whole machine is the planted
control** — `0xb103000` at A, `0x15587000` at B. Zero leaked frames, twice,
eight hours apart, on a machine that had been up the whole time with a desktop
session and processes that never exit.

That is the strongest negative result this campaign has produced. It is not the
same as "there is no leak."

---

## 2. WHAT ACTUALLY MOVED

The TOTAL is **−108 pages**. Taken alone that reads as the machine *shrinking*,
which is exactly the reading pass 20's own tooling was built to refuse: a total
is cancellable.

| site | A | B | delta |
|---|---|---|---|
| 0 `unknown` | 5988 | 5839 | **−149** |
| 6 `vma_anon` | 1 | 38 | **+37** |
| 9 `pgtable` | 0 | 2 | +2 |
| 11 `cow_resolve` | 0 | 2 | +2 |
| **TOTAL** | 5989 | 5881 | −108 |

So **+41 pages of real growth**, hidden inside a −149 shrink of the
unattributed bucket. The per-site growth bar (`site_swap_nets_zero`,
`site_grew_from_unknown`, `site_grew_partial_credit` in
`test_leak_hours_report_mutations.sh`) is the machinery that keeps that from
reading as clean; +41 clears adjudication only because it is under the 256-page
bar, not because it is zero.

Long-lived processes: **17 of 18 are flat to the page** across 8 hours —
including all four kworkers, `hamdesktop`, `hampanelscene`, `sshd`, and every
`__rfork_`. One grew:

```
pid 6  hamsh  resident A=100  B=126  delta +26   <-- GREW
```

COW origin arms: arm 5 churned +40 born / +40 died to a **net of zero** (a
healthy shape — allocation and reclamation both working). Arm 23 is net **+18**
with `owner-dead=0` and `owner-stray=0` of 29 survivors — residency, not
leakage, though 9 of the 29 are `owner-unrecorded`.

---

## 3. THE HONEST RESIDUAL

An 8-hour PASS against a 256-page bar bounds the leak rate at roughly
**32 pages/hour**, i.e. about **1.1 GiB/year**. That bound is far too loose for
the months-and-years target. The measured motion is much smaller — +41 pages in
8.02 h, ~5 pages/hour, ~175 MiB/year if it is linear and unbounded — but this
run **cannot distinguish** that from a one-time settle that has already
finished. Two samples give a delta, not a curve.

Concretely open after this pass:

1. **Is `vma_anon` +37 monotone or a settle?** It went 1 → 38. A site that
   starts at 1 and lands at 38 looks far more like a warm-up reaching steady
   state than like a linear leak — but nothing here proves that. Three or more
   samples on one boot would; two never will.
2. **`hamsh` pid 6, +26 pages / 8 h.** Pass 17 exonerated hamsh on a
   region-attributable basis and the 83-minute AST-arena death was fixed on
   main. This is a different, much slower shape in the *session* shell. ~104 KiB
   per 8 hours.
3. **Arm 23's 9 `owner-unrecorded` survivors.** Not stray, not dead-owned; the
   discriminator simply has no owner recorded for them. An unrecorded owner is
   not an alibi.

The instrument for all three is the same and is already built: **run this census
with N ≥ 3 samples on one boot** and difference consecutive pairs. A settle
flattens; a leak keeps its slope. That is pass 21.

---

## 4. WHAT LANDED

Purely additive, no product code touched:

| file | what it is |
|---|---|
| `scripts/leak_hours_census_report.py` | the adjudicator (per-site growth bar, re-attribution credit) |
| `scripts/leak_kmtrack_diff.py` | kernel-heap (kmtrack) adjudication — pass 19 captured it and never judged it |
| `scripts/test_leak_hours_report_mutations.sh` | **22 mutations**, all caught |
| `scripts/test_leak_kmtrack_diff.sh` | **17 cases** (blindness, contamination, growth, 4 negative controls), all correct |
| `scripts/ci_battery_manifest.txt` | both gates registered |

Both gates verified green on `main` after the merge — seconds each, no boot
required. That separation is deliberate and is why the adjudication is
mutation-testable at all: the gate needs a multi-hour KVM boot to produce a log;
judging the log needs none.

---

## 5. THE CAMPAIGN RULE THIS PASS ADDS

Pass 15: a soak mean is not an estimator.
Pass 18: minutes-long runs cannot see one frame per hour.
Pass 19: build the two-sample one-boot census.
**Pass 20: a TOTAL is cancellable, and two samples give a delta, not a curve.**

Every one of the last six passes disproved the brief it was dispatched with.
This one disproved "the 8-hour run will settle the question."
