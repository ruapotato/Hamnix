# Proposed `.github/workflows/ci.yml` changes — 2026-07-25

Agents do not edit `.github/`. This file is the **exact** diff for the
orchestrator to apply. Companion analysis: `docs/ci_status_2026-07-25.md`.
Base: `438fca0a`.

Everything in `scripts/` needed to make the optimizer battery honest has
already landed, so **no workflow change is required to turn CI green** — these
two changes are about not throwing away signal.

---

## Change 1 — the scheduled/nightly run must not be cancelled by pushes

**Problem (measured).** Of the last 60 `Hamnix CI` runs: **45 cancelled, 15
failure, 0 success.** The workflow's own comment already admits push runs never
survive long enough to finish the 16-shard bare-metal battery, and designates
the nightly `cron: '0 7 * * *'` run as "the reliable on-device green signal".
But the nightly shares a concurrency group with pushes and
`cancel-in-progress: true`, so the first push after 07:00 UTC kills it. The
designated reliable signal is exactly the one being destroyed.

**Fix.** Give scheduled (and `workflow_dispatch`) runs their own group and turn
cancellation off for them.

```diff
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -53,4 +53,17 @@
+# EVENT-AWARE (2026-07-25, docs/ci_status_2026-07-25.md): the nightly run is
+# documented above as "the reliable on-device green signal", but it shared this
+# group with pushes, so the first push after 07:00 UTC cancelled it — 45 of the
+# last 60 runs ended CANCELLED and 0 ended in success. Scheduled and manually
+# dispatched runs now get their OWN group and are never cancelled in progress,
+# so the full ~50-minute battery actually completes at least once a day. Push
+# runs keep collapsing exactly as before.
 concurrency:
-  group: ${{ github.workflow }}-${{ github.ref }}
-  cancel-in-progress: true
+  group: >-
+    ${{ github.workflow }}-${{ github.ref }}-${{
+      (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch')
+      && 'full' || 'fast' }}
+  cancel-in-progress: >-
+    ${{ github.event_name != 'schedule'
+        && github.event_name != 'workflow_dispatch' }}
```

Notes:
* `cancel-in-progress` accepts an expression; it is evaluated as a boolean, and
  the `>-` folded scalar keeps it a single line for the parser.
* Two concurrent nightlies cannot happen (cron fires once a day), and a manual
  dispatch during a nightly queues rather than cancels — which is the intent.

---

## Change 2 — one red Tier-1 step must not skip the other twenty

**Problem (measured).** Tier 1 runs ~21 sequential steps. Step 5, "Optimizer
battery (test_opt_\*)" (line 97), has been failing since ~2026-07-21, and
GitHub skips every later step in the job. So **none** of these ever ran:
codegen/invariant static checks, and all 13 browser gates, the 2 hamUI gates
and the 2 DE-menu gates. Every red CI run reported one failure and hid the
state of twenty other gates.

**Fix.** Add `if: ${{ !cancelled() }}` to each Tier-1 step from "Compiler
feature tests" (line 88) onward. The job still fails if any step fails; you just
learn everything in a single run instead of one bisect-per-push.

```diff
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@
       - name: Compiler feature tests (test_compiler_*)
+        # ALWAYS-RUN (2026-07-25): a failure in any single Tier-1 step used to
+        # SKIP every later step, so one red gate hid the state of ~20 others
+        # (docs/ci_status_2026-07-25.md). `!cancelled()` keeps the step running
+        # after an earlier failure while still letting a cancelled run stop.
+        # The job's overall conclusion is unchanged: any red step reds the job.
+        if: ${{ !cancelled() }}
         run: |
```

…and the same two-line addition (`if: ${{ !cancelled() }}`, placed immediately
above the step's `run:`) on each of these steps in the `host-selftests` job:

| line | step |
| --- | --- |
| 97  | Optimizer battery (test_opt_*) |
| 119 | Codegen + invariant static checks |
| 139 | Native browser engine (host-side dual-target) |
| 146 | Native browser google.com usability |
| 153 | Native browser pixel graphics |
| 159 | Native browser form-control boxes |
| 168 | Native browser image rendering (PNG) |
| 175 | Native browser interlaced PNG decode |
| 181 | Native browser SVG rasterizer |
| 188 | Native browser on-device window |
| 194 | Native browser Back/Forward history |
| 200 | Native browser line reflow |
| 207 | Native browser JPEG decode |
| 214 | Native browser GIF decode |
| 221 | hamUI GUI apps |
| 237 | Data-driven DE app menu |

(Do **not** add it to `Checkout`, `Set up Python 3.11`, or `Adder compiler
functional check` — if the toolchain is not there, the rest is noise.)

---

## Change 3 (optional) — refresh the stale comment on the battery step

Lines 98-111 still describe the 2026-07-09 triage ("the optimizations ARE
implemented and firing… no skip list"). That is no longer true: `ba2e4bcf`
retired the whole opt1 lane on 2026-07-21. Suggested replacement comment:

```yaml
      - name: Optimizer battery (test_opt_*)
        # GLOB-driven so a new optimizer test is gated the moment it lands.
        #
        # 2026-07-25: commit ba2e4bcf (2026-07-21) retired the legacy opt1 lane
        # (opt.ad deleted; `--opt` now arms the SSA pipeline, and the dump
        # driver no longer calls ra_enable() on the emission path). 43 of these
        # guards assert opt1/regalloc counters that can no longer fire — their
        # CORRECTNESS assertions still pass (opt == off == reference). They now
        # source scripts/lib_opt1_lane.sh, which EMPIRICALLY probes the lane
        # (scripts/_opt1_lane_probe.py, with a --dump-regalloc positive control)
        # and prints a loud "SKIPPED: ... lane is RETIRED" banner instead of
        # failing — and starts gating again by itself the moment the lane is
        # re-armed. Grep the log for "SKIPPED:" to see what is not exercised and
        # "KNOWN-BUG:" for open bugs held as XFAIL.
        # See docs/ci_status_2026-07-25.md.
```

---

## Not proposed

* **Splitting the battery across push vs schedule.** Unnecessary: the whole
  Tier-1 optimizer battery is host-only and cheap (the full 52 guards run in a
  few minutes locally). The cancellation problem is entirely about the
  16-shard **bare-metal** battery, which Change 1 fixes.
* **Making the optimizer battery non-blocking.** It is meaningful again after
  the `scripts/` changes; it should keep gating.
