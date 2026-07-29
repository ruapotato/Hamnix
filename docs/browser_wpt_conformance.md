# Web Platform Tests: the external browser score

**Baseline, 2026-07-29: 395 / 3760 subtests = 10.51 %** across 706 vendored WPT
tests. Chromium, through the same reporter on the same tests, scores 91.4 %
overall and 99.4 % with the file://-origin outliers set aside — so the number
below is ours, not the harness's (see [Cross-check](#cross-check-the-control)).

This is the first browser number here that we did not grade ourselves.

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
reported 706/706. The subtest scrape reports which of 3,760 assertions fail and
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

### 1. `getComputedStyle()` re-enters the event loop mid-call — **166 confirmed, all of CSS**

`css/css-cascade` scores **0.0 %** (0 / 243, with a further 25 files silent) and
it is one bug. 166 of those are confirmed against chromium; the rest are in
files we cannot get a comparable reading from yet.
Calling `getComputedStyle()` pumps the timer queue from inside the call. In a
testharness page that means `testharness.js`'s own watchdog timer fires *in the
middle of the first `test()`*, the harness declares itself complete with one
test registered, and every subsequent `test()` on the page is silently dropped.

Repro — the second block emits `WPT#STATUS` (harness already finished) *before*
`M1`, while the first block behaves:

```js
console.log("M0"); test(function(){ assert_equals(1,1); }, "t1"); console.log("M1");
// -> M0, RESULT t1, M1                                    (correct)
console.log("M0"); test(function(){ getComputedStyle(document.documentElement).zIndex;
                                    assert_equals(1,1); }, "t1"); console.log("M1");
// -> M0, WPT#STATUS 2, WPT#DONE 1, M1                     (harness killed mid-test)
```

This is the single highest-leverage engine fix in the list: it is one
re-entrancy, and it currently makes every CSS test in the suite unscoreable.

### 2. Timers drain **between `<script>` elements** instead of after the parse — structural

Per HTML, a task scheduled by script #1 cannot run until the parser is done.
Ours runs immediately:

```html
<script>console.log("S1 start"); setTimeout(function(){console.log("S1 TIMER");},1000);
        console.log("S1 end");</script>
<script>console.log("S2 runs");</script>
<!-- ours: S1 start, S1 end, S1 TIMER, S2 runs   correct: ... S2 runs, S1 TIMER -->
```

Real pages hit this constantly (a deferred init scheduled by an early script
running before the page's own later scripts have defined anything). The runner
works around it with script coalescing, so this bug costs **no** WPT points
today — it is here because it is a genuine spec violation the suite exposed, and
because the workaround should eventually be removable.

### 3. `document.implementation` does not exist — **~300 subtests**

`typeof document.implementation === "undefined"`. Consequences measured across
the suite: `hasFeature` 136 failures, `createHTMLDocument` 116,
`createDocument` and `createDocumentType` silence whole files. Much of
`dom/nodes` (5.9 %, 1,991 subtests, the largest single area) is gated behind
building a second document to compare against.

### 4. Namespace-aware DOM is absent — **~250 subtests**

`setAttributeNS` 106 + 89 failures, `getAttributeNS`, `element.prefix` 53,
`element.localName` undefined. `createElementNS` exists but its result carries
no namespace identity. Blocks most of `dom/nodes` attribute and
`getElementsByTagNameNS` coverage.

### 5. `document.createEvent` + Event subclass constructors — **~160 subtests**

`createEvent` missing (108). `Event`, `CustomEvent`, `MouseEvent` exist as
globals but are not constructible as subclasses — `new UIEvent(…)` gives "value
is not a constructor" (54, concentrated in
`dom/events/Event-subclasses-constructors.html`). `dom/events` is at 14.1 %.

### 6. Range and traversal APIs — **~250 subtests**

`document.createRange`, `window.Range`, `document.createTreeWalker`,
`document.createNodeIterator`, `window.NodeFilter` are all undefined.
`dom/ranges` 0.5 % (1 / 206), `dom/traversal` 0.0 % (0 / 45). Self-contained,
well-specified, no layout dependency — the cleanest large win in the list.

### 7. ChildNode / ParentNode mutation methods — **~150 subtests**

`before` (45), `after` (45), `replaceWith`, `prepend` all undefined; `append`
and `closest` exist. Small, ubiquitous, and heavily used by real pages.

### 8. `DOMParser` / `XMLSerializer` — **~60 subtests**

Both undefined (47 direct failures plus whole silent files). Also the natural
implementation route for #3.

### 9. Regex character classes mis-evaluate `\uXXXX` ranges — correctness, and it blinds diagnosis

`testharness.js` runs every assertion message through
`sanitize_unpaired_surrogates`, whose pattern is
`/([\ud800-\udbff]+)(?![\udc00-\udfff])|…/g`. Our engine matches that surrogate
range against **ordinary ASCII**, so every message came back as
`U+61U+73U+73…` — the entire text, code-unit escaped. 738 failures arrived with
no readable cause until `wpt_score.py` learned to decode it. A character-class
range comparison is evidently being done on the wrong unit width.

### 10. `document.readyState` missing → the harness never completes cleanly

`document.readyState` is undefined, so `testharness.js` falls through to its
`window` load path and every file reports harness status **TIMEOUT (2)** even
when all its subtests completed. Per-subtest results are unaffected (the
reporter streams them via `add_result_callback`), but no file can currently
report a clean `OK`.

### 11. Long tail, each silencing whole files

`createCDATASection` (10 files), the `Function` constructor / dynamic code (6),
`CSSStyleSheet.insertRule` (4), `customElements` / `define` (2+2),
`document.createDocument` (2), `moveBefore` (2), `Array.prototype.unshift` (2),
`Array.prototype.forEach` on some host collections (5),
`addEventListener` on some objects (5), `DOMException`, `NodeList` /
`HTMLCollection` as globals, `AbortController`, `TextEncoder` / `TextDecoder`
(`encoding` 0.0 %), `window.CSS`, `WeakRef`.

`Array.prototype.unshift` and `forEach` being missing on 7 files is worth
calling out separately: those are plain-ECMAScript gaps in a JS engine that
already has `Proxy`, `Reflect` and `structuredClone`.

### Confirmed gap by area (we fail, chromium passes — 2,634 subtests)

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

| area | files | pass | total | score | silent files |
|---|---:|---:|---:|---:|---:|
| dom/nodes | 264 | 117 | 1991 | 5.9 % | 69 |
| dom/events | 73 | 49 | 348 | 14.1 % | 23 |
| css/css-cascade | 77 | 0 | 243 | 0.0 % | 25 |
| dom/ranges | 54 | 1 | 206 | 0.5 % | 26 |
| dom/lists | 5 | 140 | 189 | **74.1 %** | 0 |
| html/tabular-data | 29 | 8 | 153 | 5.2 % | 0 |
| dom/misc | 8 | 49 | 122 | 40.2 % | 1 |
| html/the-button-element | 15 | 0 | 76 | 0.0 % | 1 |
| html/sections | 2 | 0 | 63 | 0.0 % | 0 |
| html/selectors | 26 | 2 | 61 | 3.3 % | 7 |
| html/links | 7 | 2 | 55 | 3.6 % | 2 |
| dom/collections | 9 | 9 | 48 | 18.8 % | 0 |
| html/document-metadata | 81 | 5 | 48 | 10.4 % | 52 |
| html/grouping-content | 14 | 5 | 47 | 10.6 % | 0 |
| dom/traversal | 17 | 0 | 45 | 0.0 % | 6 |
| encoding | 8 | 0 | 28 | 0.0 % | 3 |
| html/text-level-semantics | 9 | 8 | 23 | 34.8 % | 4 |
| html/disabled-elements | 1 | 0 | 10 | 0.0 % | 0 |
| url | 3 | 0 | 2 | 0.0 % | 1 |
| dom/abort | 2 | 0 | 2 | 0.0 % | 0 |
| html/edits | 2 | 0 | 0 | — | 2 |

**222 of 706 files produce no subtest results at all.** These are the cheapest
wins on the board: one missing API silences an entire file's assertions, so the
score understates the engine and a single fix can move it by dozens of subtests
at once.

## Reading the number honestly

10.51 % is a floor, not a verdict. Three things depress it below what the engine
can actually do:

* 222 files are silenced by a single missing symbol each.
* Every CSS test is unscoreable because of one re-entrancy bug (#1).
* No file can report harness status `OK` (#10).

Equally, it is not deflated by cherry-picking: the areas were chosen before the
first run, the exclusions are published per-file, and nothing that fails was
excluded for failing.

The corresponding claim in the other direction — that our 275 hand-written gates
are all green — is now known to be compatible with 10.51 % external conformance.
That is the number to move.
