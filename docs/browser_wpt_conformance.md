# Web Platform Tests: the external browser score

**Current, 2026-07-29: 632 / 4112 subtests = 15.37 %** across 706 vendored WPT
tests (first baseline the same day: 395 / 3760 = 10.51 %). Chromium, through the
same reporter on the same tests, scores 91.4 % overall and 99.4 % with the
file://-origin outliers set aside — so the number below is ours, not the
harness's (see [Cross-check](#cross-check-the-control)).

This is the first browser number here that we did not grade ourselves.

### Movement so far

| | PASS | subtests | score | files reporting | harness `OK` |
|---|---:|---:|---:|---:|---:|
| first baseline | 395 | 3760 | 10.51 % | 484 | 6 |
| after the four fixes below | **632** | 4112 | **15.37 %** | 532 | **499** |

Note the *denominator* grew too: 3760 → 4112 observable subtests. Both effects
are real progress — a subtest that never reported was not passing either.

Four engine fixes, each verified value-by-value against `chromium --headless`
or `node`, and all ten render-corpus pages byte-identical before and after on
both the layout and the pixel backend:

1. **`getComputedStyle()` no longer runs the event loop.** The CSSOM
   `getPropertyValue` thunk was compiled through `js_eval`, which is the
   engine's *turn boundary* and ends by draining the timer queue — so a
   synchronous CSSOM getter pumped the event loop, testharness's watchdog fired
   inside the first `test()`, and every later `test()` in the file was dropped.
   Split into `js_eval_nested` (same pipeline, no drain, caller's control-flow
   latches preserved). `_compile_inline_handler` had the same bug.
2. **The timer queue now runs after the parse, not between `<script>`s.** A
   script element ending is a *microtask checkpoint*; timers must wait for
   `DOMContentLoaded` and `load`. This is why 613 of 706 files reported
   `TIMEOUT` — testharness's own 10-second watchdog fired at the end of the
   first script, before `load` could set its `all_loaded` flag. Harness `OK`
   went 6 → 499. This also retires structural gap #2 below.
3. **`document.createEvent` + a real `DOMException`**, with `js_throw_value` so
   a host native can raise a spec error at all. +207 subtests in one change.
4. **Regex `\uXXXX` is a code point, not its low byte** — `[\ud800-\udbff]`
   compiled to `[\x00-\xff]` and matched everything, which is why 738 assertion
   messages arrived unreadable as `U+61U+73…`.

---

## Why this exists

We have 275 hand-written host gates for the browser engine. Every one of them
was written by us, which means every one encodes *our* belief about what correct
is. On 2026-07-28 a single sweep found **16 of 19 gates in one family asserting
behaviour Chromium does not have** — the gates were green and the engine was
wrong, in the same direction, because the same author wrote both. Self-graded
coverage cannot find that class of error, no matter how much of it there is.

[Web Platform Tests](https://github.com/web-platform-tests/wpt) is the
conformance suite Chromium, WebKit and Gecko are all scored against. It was not
written by us, it cannot be quietly bent to match what the engine already does,
and its number means the same thing to a third party as it does to us.

**On translating WebKit instead.** Reading WebKit/Blink/Gecko for architecture
and algorithms is fine and encouraged. Copying or mechanically translating their
source is not: WebCore and JavaScriptCore are LGPL, so a translated derivative
carries LGPL obligations into a project that ships as a distro. WPT is the
higher-value external asset anyway — it tells us *where we are wrong*, which is
the part we cannot generate for ourselves.

## What is imported, and what is not

`tests/wpt/` holds a **pinned, vendored subset**: 706 testharness.js tests plus
the 39 support files they reference, 4.4 MB, at WPT
`8ab228c702a6cfeacb3c986b06a16a744b493a8d`.

Vendored rather than fetched at gate time, for three reasons:

* CI has no network guarantee. A fetching gate would have to soft-green or go
  INCONCLUSIVE on every hiccup; the ratchet needs to be deterministic.
* The score is only comparable over time if the tests do not move underneath it.
  Pinned, a score change is *our* change, never upstream's.
* A reviewer can see in the diff exactly which external tests we claim to pass.

The cost is repo bytes, and `scripts/wpt_import.py` keeps that honest by copying
only the selected tests and their transitively-referenced support files rather
than whole directories.

Areas: `dom/`, `url/`, `css/css-cascade/`, `encoding/`, and eleven
`html/semantics/` subdirectories that need neither media, plugins, nor a
compositor.

**Skipped, and why** — the full list with per-file detail is generated into
`tests/wpt/EXCLUSIONS.md`. The categories:

| Excluded | Reason |
|---|---|
| `*.sub.html` | `{{host}}`/`{{ports}}` placeholders are expanded by the wptserve HTTP server. The file on disk is not a valid test. |
| `*.tentative.html` | Tests an unstabilised spec proposal; the number would move for reasons unrelated to us. |
| `*.worker.html` | Needs Web Workers — a second JS realm on its own thread. |
| `*-ref.html`, `*-manual.html` | Reftest references, and tests needing a human. |
| references `testdriver.js` | Injects trusted input via the browser automation protocol. With no driver back-end these *hang* rather than fail — an unobservable result, not a failing one. |
| references `idlharness.js` | Fetches spec `.idl` files over HTTP from `/interfaces/`. |
| references `/common/` | Shared fixtures that assume the wptserve origin (cross-origin frames, redirects, headers). |
| `encoding/legacy-mb-*` | ~10,000 machine-generated single-codepoint tests for legacy CJK encodings. `gb18030-encoder.html` **alone** was 254 subtests — 6 % of the whole suite from one table. Excluded for **score hygiene**, so one unimplemented feature cannot swamp the total and hide movement everywhere else. Re-import when we have legacy decoders and want to measure them. |
| `css/CSS2/` | 12,901 files, overwhelmingly reftests requiring pixel comparison against a reference rendering. That is `scripts/framediff_gfx_all.sh`'s job, not this one. |
| all reftests | Same reason: no per-assertion result to scrape. |

**A vendored test is never edited.** That is the entire value of an external
suite. If a test is genuinely inapplicable it goes in the exclusion list above
with a reason — never by touching the file. An exclusion states what our
*runner* cannot observe; "we fail it" is never a valid reason.

## How it runs

```
python3 scripts/wpt_run.py --all --jsonl out.jsonl     # run the suite
python3 scripts/wpt_score.py out.jsonl --vs chrome.jsonl   # score + cross-check
bash scripts/test_wpt_ratchet_host.sh                  # the gate
bash scripts/test_wpt_ratchet_host.sh --regen          # bank fixes
```

Results are **per subtest**, not per page. WPT tests self-report each
`test()`/`async_test()` block through `testharness.js`;
`tests/wpt/hamnix_testharnessreport.js` — our implementation of WPT's
deliberately-empty, vendor-owned reporter stub — streams them over `console.log`
where the host driver's `JSLOG` lines carry them out.

That distinction is the whole point. A "did the page load" check would have
reported 706/706. The subtest scrape reports which of 4,112 assertions fail and
what each one says.

### Preprocessing, and why it is not test editing

Vendored files are read-only. Everything below happens in a temp file,
uniformly, for every test:

1. **Resource loading.** `build/host/hambrowse_host` executes inline `<script>`
   bodies only; it has no resource loader, so `<script src=…>` is a no-op. We
   inline the referenced bytes — what a loader would do.
2. **The vendor hook.** `/resources/testharnessreport.js` is WPT's empty
   integration point. We substitute our implementation of it.
3. **Script coalescing.** All classic script bodies are concatenated into one
   block, in document order, to work around engine bug **#2** below. `--mode
   separate` keeps them apart; that is what chromium gets.

Nothing changes an assertion, an expectation, or a test's logic.

## Cross-check: the control

A harness that reports everything as failing is worse than no harness: it
produces a confident number that is pure noise. So all 706 tests were also run
under `chromium --headless` through the **same reporter**.

Chromium gets the **unmodified** vendored document — URL rebasing and the
vendor-hook swap only, no inlining and no coalescing. It has a real resource
loader and correct task ordering, so it needs neither. Feeding it the untouched
file is what makes it a control rather than a mirror.

```
chromium: 57,747 subtests, 52,757 PASS  ->  91.36 %
          540 of 706 files score exactly 100 %
          99.38 % once the 10 worst files are set aside (53,037 subtests)

comparable subtests (reported by both engines):  3,200
WE FAIL / CHROMIUM PASSES:  2,634    <- the real gap
WE PASS / CHROMIUM FAILS :      1    <- inspected, and it is correct:
    dom/historical.html :: "Historical DOM features must be removed: DOMError"
    We pass by not having implemented DOMError. Chromium still ships it.
files with results in chromium but none for us:  188
files dead in BOTH:                               34   <- harness artifact, not
                                                          an engine gap
```

**Why chromium is at 91 % and not 100 %,** verified by reading the messages:

* `file://` origin. Tests that pull a fixture through an iframe or XHR get
  `Cannot read properties of null (reading 'firstChild')`. Two Range files
  contribute 3,680 subtests of this on their own. It hits both engines equally
  and is a property of running without wptserve, not of either engine.
* Suite newer than the browser. `:heading` selector tests fail with
  "`:heading` is not a valid selector" — the pinned WPT snapshot tests a feature
  the installed chromium has not shipped. **We fail these too, and the
  cross-check is what tells us they are not our bug** — 56 of our failures are
  in this class and are correctly absent from the ranked gap list below.

The gap list is therefore built from the **we-fail-chromium-passes** set, not
from our raw failure list. 2,634 of our 3,365 failures are confirmed real; the
remainder are file://-origin artifacts or things chromium fails too.

## The harness is proved honest before its number is read

`scripts/wpt_run.py --selftest` pushes two synthetic testharness pages through
the real pipeline: one whose assertions hold (must report 2 PASS / 0 FAIL) and
one whose assertions do not (must report 0 PASS / 2 FAIL). The gate runs this
*first* and exits **125 INCONCLUSIVE** if it fails — never PASS.

This is load-bearing. A scraper that silently stopped matching its own result
lines would report zero failures, and zero failures against a baseline of 3,365
reads as a spectacular improvement rather than a broken instrument. Proved by
mutation: stubbing the reporter's `console.log` turns the gate red-125, not
green.

## The ratchet

`scripts/wpt_baseline.txt` records every subtest the engine does not pass, plus
a `#!PASS_FLOOR`. The gate fails if a subtest **not** in the baseline starts
failing, or if the PASS count drops. Lines *leaving* the baseline is the point;
the gate says so and asks you to regenerate.

One subtlety: when a file that previously produced *no* output starts reporting,
its individual failures are not counted as regressions. They were always there,
merely unobservable.

---

## Ranked conformance gaps — the browser roadmap

Ordered by subtests recovered per unit of work. Each row is measured, not
guessed; the repro column is a minimal page that reproduces it.

### FIXED since the first baseline

Gaps 1 (`getComputedStyle` re-entrancy), 2 (timers draining between `<script>`
elements), 9 (regex `\uXXXX` ranges) and 10 (`document.readyState`) are done —
see [Movement so far](#movement-so-far). `document.createEvent` and
`DOMException` are done too. The list below is re-measured against the current
run, not edited down.

### 1. `document.implementation` does not exist — **~296 subtests**

Still the largest single symbol. `hasFeature` 136 failures,
`createHTMLDocument` 117, plus `createDocument` / `createDocumentType` /
`doctype` silencing whole files. Much of `dom/nodes` (2,236 subtests, still the
largest area) is gated behind building a second document to compare against.

### 2. Namespace-aware DOM — **~280 subtests**

`setAttributeNS` 106 + 89, `element.prefix` 53, `getElementsByTagNameNS` 32,
`localName` undefined. `createElementNS` exists but its result carries no
namespace identity.

### 3. `cannot read property 'length' of null or undefined` — **246 subtests**

Now the single biggest *message*, and it is not yet attributed to one cause.
Worth an hour of triage before any of the feature work below: it is likely two
or three distinct getters returning null where a collection is expected, and it
also accounts for 12 of the fully-silent files.

### 4. Range and traversal APIs — **~256 subtests**

`document.createRange`, `window.Range`, `createTreeWalker`,
`createNodeIterator`, `NodeFilter` all undefined. `dom/ranges` 1/206,
`dom/traversal` 0/50, and **26 of the 54 range files are still fully silent**,
so the true figure is much larger — chromium reports 34,000+ subtests there.
Self-contained and well-specified, but note the range files also need
`createCDATASection` (10 silent files) and `createProcessingInstruction` (101),
so budget those with it rather than separately.

### 5. Event subclass constructors — **~55 subtests**

`new UIEvent(...)` gives "value is not a constructor". `document.createEvent`
now covers the legacy factory path, so this is the remaining half.

### 6. `previousElementSibling` — **57 subtests**

Sibling traversal on the live tree. Small and self-contained.

### 7. ChildNode / ParentNode mutation methods — **~150 subtests**

`before`, `after`, `replaceWith`, `prepend` undefined; `append` and `closest`
exist.

### 8. `DOMParser` / `XMLSerializer` — **~60 subtests**

Both undefined. Also the natural implementation route for #1.

### 9. Long tail, each silencing whole files

`createCDATASection` (10 files), the `Function` constructor / dynamic code (6),
`Array.prototype.forEach` on host collections (4), `unshift` (2),
`CSSStyleSheet.insertRule`, `customElements`, `moveBefore`, `TextEncoder` /
`TextDecoder` (`encoding` still 0.0 %), `window.CSS`, `WeakRef`.

### 10. The 99 files that complete with ZERO subtests

Up from 71, because more files now reach completion at all. These no longer
fail on a missing symbol — the harness runs and reports done having registered
nothing. That is a different shape of bug from the rest of this list and is
probably one or two causes; it is the largest single silent bucket left.

### Confirmed gap by area (we fail, chromium passes — 2,634 subtests)

*From the FIRST baseline run; not yet re-measured against chromium since the
fixes above. The per-area table that follows it IS current.*

```
1679  dom/nodes                 44  dom/traversal          23  html/links
 214  dom/events                40  html/grouping-content  15  html/text-level-semantics
 166  css/css-cascade           38  dom/collections        12  dom/lists
 122  html/tabular-data         35  dom/ranges             10  html/disabled-elements
  73  html/the-button-element   32  html/document-metadata  2  dom/abort
  55  html/selectors            26  encoding
  48  dom/misc
```

`dom/ranges` looks small here (35) only because 26 of its 54 files produce no
output for us at all, so their assertions are not comparable. Chromium reports
34,000+ subtests in that directory; it is the largest *hidden* gap in the table
and moves the moment `document.createRange` exists.

### Where the subtests are

Current run. `silent` = files producing no subtest results at all.

| area | files | pass | total | score | silent files |
|---|---:|---:|---:|---:|---:|
| dom/nodes | 264 | 304 | 2236 | 13.6 % | 66 |
| dom/events | 73 | 76 | 344 | 22.1 % | 17 |
| css/css-cascade | 77 | 4 | 290 | 1.4 % | 15 |
| dom/ranges | 54 | 1 | 206 | 0.5 % | 26 |
| dom/lists | 5 | 140 | 189 | **74.1 %** | 0 |
| html/semantics/tabular-data | 29 | 8 | 153 | 5.2 % | 0 |
| dom (misc) | 8 | 50 | 123 | 40.7 % | 0 |
| html/semantics/document-metadata | 81 | 7 | 87 | 8.0 % | 28 |
| html/semantics/selectors | 26 | 18 | 78 | 23.1 % | 6 |
| html/semantics/the-button-element | 15 | 0 | 76 | 0.0 % | 1 |
| html/semantics/sections | 2 | 0 | 63 | 0.0 % | 0 |
| html/semantics/links | 7 | 2 | 55 | 3.6 % | 2 |
| dom/traversal | 17 | 0 | 50 | 0.0 % | 5 |
| dom/collections | 9 | 9 | 48 | 18.8 % | 0 |
| html/semantics/grouping-content | 14 | 5 | 47 | 10.6 % | 0 |
| encoding | 8 | 0 | 28 | 0.0 % | 3 |

**174 of 706 files still produce no subtest results at all** (was 222). These
remain the cheapest wins: one missing API silences an entire file.

## Reading the number honestly

15.37 % is a floor, not a verdict. What still depresses it:

* **174 files are silenced by a single missing symbol each** (was 222), and 99
  of those now run to completion registering zero subtests — a different and
  currently un-diagnosed shape of bug.
* `dom/ranges` and `dom/traversal` are near-zero because Range and the
  traversal APIs do not exist at all, and half the range files cannot report.
* `css/css-cascade` moved off 0.0 % but only to 1.4 %: the re-entrancy that
  made it *unscoreable* is fixed, so what is left is now honest cascade
  failures rather than a measurement artifact. That is the point of the
  exercise — the number went from meaningless to merely low.

Equally, it is not deflated by cherry-picking: the areas were chosen before the
first run, the exclusions are published per-file, and nothing that fails was
excluded for failing. No vendored test was edited and no exclusion was added to
move the score.

**On the growing denominator.** 3,760 → 4,112 observable subtests. A fix that
un-silences a file can *lower* the percentage while strictly improving the
engine, so the ratchet tracks the absolute PASS count (`#!PASS_FLOOR`), not the
ratio. Read both columns.

The corresponding claim in the other direction — that our 275 hand-written gates
are all green — was compatible with 10.51 % external conformance, and is still
compatible with 15.37 %. That is the number to move.
