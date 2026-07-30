# Web Platform Tests: the external browser score

**Current, 2026-07-29: 1964 / 4800 subtests = 40.9 %** across 706 vendored WPT
tests (first baseline the same day: 395 / 3760 = 10.51 %). Chromium, through the
same reporter on the same tests, scores 91.4 % overall and 99.4 % with the
file://-origin outliers set aside — so the number below is ours, not the
harness's (see [Cross-check](#cross-check-the-control)).

This is the first browser number here that we did not grade ourselves.

### Movement so far

| | PASS | subtests | score | files reporting | harness `OK` |
|---|---:|---:|---:|---:|---:|
| first baseline | 395 | 3760 | 10.51 % | 484 | 6 |
| after the four fixes below | 632 | 4112 | 15.37 % | 532 | 499 |
| + event loop / DOM round | 885 | 4118 | 21.49 % | 534 | 504 |
| + `DOMImplementation`, `attributes` | 1123 | 4613 | 24.34 % | 538 | 503 |
| + `createDocument`, namespaced `createElementNS` | 1660 | 4766 | 34.83 % | 540 | 504 |
| + namespaced attributes, `CRE_MAX` | 1952 | 4753 | 41.07 % | 535 | 502 |
| + per-tag interface prototypes | **1964** | 4800 | **40.92 %** | 535 | **502** |

Note the *denominator* grew too: 3760 → 4800 observable subtests. Both effects
are real progress — a subtest that never reported was not passing either, and
the score can fall while the engine strictly improves (1952 → 1964 PASS reads
as 41.07 % → 40.92 % because 47 more subtests became observable).

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
`DOMException` are done too.

Done on 2026-07-29, in the order the score said they paid:

* **`document.implementation`** — `hasFeature` (spec'd true for every argument
  list; 136 subtests in one file), `createHTMLDocument`, `createDocument`
  (a real `XMLDocument`: 432 of 434 subtests), `createDocumentType` (80 of 82).
* **`Element.attributes`** as a live `NamedNodeMap` of `Attr` nodes. This was
  not only a missing API. testharness.js's `format_value()` reads
  `val.attributes.length` for *every element it prints*, so its absence
  replaced **188 real failure messages** with
  `cannot read property 'length' of null or undefined` — which is what old
  gap #3 below actually was. It hid the messages; it did not cause the failures.
* **Namespace-aware DOM** — `localName`, `prefix`, `setAttributeNS`,
  `getAttributeNS`, `hasAttributeNS`, `removeAttributeNS`,
  `getElementsByTagNameNS`, and a `createElementNS` that validates and extracts
  the qualified name (throwing `InvalidCharacterError` / `NamespaceError`),
  preserves case, and answers `namespaceURI` `null` for `""`.
  `dom/nodes/case.html` went 39 → 283 of 285.
* **Per-tag interface prototypes** — 68 of them, so `div instanceof
  HTMLDivElement` and `"HTMLDivElement" in window` are both true.

Three engine bugs found by this work, each of which would bite a real page:

1. `document.createElement(...).classList` silently did nothing. The
   `DOMTokenList` family resolved its owner only through the source-element
   table, so `add`/`remove`/`toggle`/`replace`/`item` no-oped on any created
   element.
2. A created element's `setAttribute()` only wrote a JS property, so it was
   invisible to `element.attributes` and `getAttribute` was case-sensitive on
   it.
3. `CRE_MAX` was **256** created nodes per page — a few seconds of any
   framework render — and `document.createElement` returned `null` past it
   *silently*, so the page died on `.appendChild of null` with no diagnosis.
   Raised to 8192 with a loud ceiling note.

### 1. `document.createProcessingInstruction` — **139 subtests**

`processing-instruction-attributes.html` (140) and
`Document-createProcessingInstruction.html` alone, plus it silences part of
`Node-textContent` (75). Half the file also wants `DOMParser`, so budget the
two together.

### 2. Range and traversal APIs — **~250 subtests**

`document.createRange` (47), `createTreeWalker` (44), `createValueRange` (79),
`NodeFilter`. `dom/ranges` 1/206, `dom/traversal` 0/50, and **26 of the 54
range files are still fully silent**, so the true figure is much larger —
chromium reports 34,000+ subtests there.

### 3. `Node.cloneNode` on created nodes — **135 subtests**

`cloneNode is not a function` on several node kinds, and the clone does not
carry nodeType/attributes. One file, well specified.

### 4. `Node.lookupNamespaceURI` / `lookupPrefix` / `isDefaultNamespace` — **70**

Now that elements carry real namespace identity, this is the remaining half of
the namespace story.

### 5. ChildNode / ParentNode mutation methods — **~150 subtests**

`before` (45), `after` (45), `replaceWith` (33), `prepend` (22). Still
undefined; `append` and `closest` exist.

### 6. `document.createAttribute` / `setAttributeNode` — **~85 subtests**

`createAttribute` 49 plus `Document-createAttribute.html` 36. The `Attr` node
now exists (it backs `element.attributes`), so this is wiring, not modelling.

### 7. `assert_throws_dom ... is not a DOMException` — **94 subtests**

Spread across files. Our host natives throw an object that carries `name`,
`code` and `constructor`, but testharness's DOMException identity check still
rejects it somewhere. One fix, wide reach.

### 8. Event subclass constructors — **~55 subtests**

`new UIEvent(...)` gives "value is not a constructor". `document.createEvent`
covers the legacy factory path; this is the remaining half.

### 9. `previousElementSibling` — **57 subtests**

All 57 are in `css/css-cascade/scope-*`, and the message is
`cannot read property 'previousElementSibling' of null` — the RECEIVER is null,
so the real gap is the `@scope` selector support that returns it, not the
sibling getter (which exists and works).

### 10. `:heading` pseudo-class — **56 subtests**

`html/semantics/sections/headingoffset-and-headingreset.html`, one selector.

### 11. `DOMParser` / `XMLSerializer` — **~47 subtests**

Both undefined.

### 12. The 171 files that produce no subtest results

Each is usually one missing symbol. Still the cheapest bucket per unit of work.

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
| dom/nodes | 264 | 1470 | 2893 | 50.8 % | 62 |
| dom/events | 73 | 172 | 387 | 44.4 % | 16 |
| css/css-cascade | 77 | 4 | 290 | 1.4 % | 15 |
| dom/ranges | 54 | 1 | 206 | 0.5 % | 26 |
| dom/lists | 5 | 168 | 189 | **88.9 %** | 0 |
| html/semantics/tabular-data | 29 | 8 | 152 | 5.3 % | 0 |
| dom (misc) | 8 | 83 | 114 | 72.8 % | 0 |
| html/semantics/document-metadata | 81 | 7 | 85 | 8.2 % | 30 |
| html/semantics/selectors | 26 | 18 | 78 | 23.1 % | 6 |
| html/semantics/the-button-element | 15 | 0 | 76 | 0.0 % | 1 |
| html/semantics/sections | 2 | 0 | 63 | 0.0 % | 0 |
| html/semantics/links | 7 | 2 | 55 | 3.6 % | 2 |
| dom/traversal | 17 | 0 | 50 | 0.0 % | 5 |
| dom/collections | 9 | 9 | 48 | 18.8 % | 0 |
| html/semantics/grouping-content | 14 | 12 | 47 | 25.5 % | 0 |
| html/semantics/text-level-semantics | 9 | 10 | 23 | 43.5 % | 4 |

**171 of 706 files still produce no subtest results at all** (was 222). These
remain the cheapest wins: one missing API silences an entire file.

## Reading the number honestly

40.9 % is a floor, not a verdict. What still depresses it:

* **171 files are silenced by a single missing symbol each** (was 222), and
  most of those run to completion registering zero subtests — a different and
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

**On the growing denominator.** 3,760 → 4,800 observable subtests. A fix that
un-silences a file can *lower* the percentage while strictly improving the
engine, so the ratchet tracks the absolute PASS count (`#!PASS_FLOOR`), not the
ratio. Read both columns.

The corresponding claim in the other direction — that our 281 hand-written gates
are all green — was compatible with 10.51 % external conformance, and is still
compatible with 40.9 %. That is the number to move.
