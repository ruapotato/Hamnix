# hambrowse Functional Gap Analysis vs Chrome — 2026-07-24

**Scope:** a FUNCTIONAL (not pixel) readout of how far hambrowse (engine `lib/web/`,
JS in `lib/web/js/` + `lib/jsengine.ad`) is from RUNNING THE REAL WEB — can a user
load, execute, and USE real sites, not just have them look right.

**Why this is a different question than the parity rounds.** `docs/found_bugs_realuse_2026-07-21.md`
documents 19 rounds of pixel/SSIM work that took static rendering to **sub-1px** vs
`/usr/bin/chromium`. That is real and impressive. But every one of those rounds measured
*painting a static snapshot*. None measured whether a page's JavaScript can drive the
DOM after load. This analysis does, and finds the picture is very different: **the static
renderer is excellent; the live/interactive layer has one structural wall that makes
JS-driven pages non-interactive.**

**Method (all empirical, oracle-checked — nothing below is speculation):**
- **JS/ECMAScript** — 156 probes run through the host engine (`build/host/hambrowse_host`,
  built from `user/hambrowse_host.ad`, which drives the SAME `lib/htmlengine.ad` the native
  browser uses) and cross-checked against **node (V8 == Chrome's engine)**. Scripts:
  `scripts/probe_js_coverage.sh`, `scripts/probe_js_hard.sh`.
- **DOM / Web APIs** — 61 probes, oracle = **real `chromium --headless --dump-dom`**; each
  probe writes its result into `document.title`, read back from both engines. Script:
  `scripts/probe_dom_api.sh`.
- **CSS / layout-read** — `getComputedStyle` / `getBoundingClientRect` / `offset*` values
  compared hb vs chromium directly.
- **SPA** — hand-built mini-React (createElement tree + state + re-render on click) driven
  through the engine's own click dispatch.
- **Offline honesty:** there is no live network on the host path, so fetch/XHR/CORS/redirects
  cannot be exercised end-to-end. Where I could only test the *API surface* (does `fetch`
  exist and return a Promise) and not a real round-trip, it is called out as such.

---

## Executive summary / distance-to-usable

hambrowse is **NOT a fluke renderer** — its JS engine is genuinely strong (one of the best
parts of the project) and static pages render beautifully. The blocker to "usable for most
websites" is concentrated, not diffuse:

> **One structural gap dominates everything: the live DOM is not wired to interaction.**
> Interaction (click/type/submit) resolves element ids against the **static parsed HTML
> source** (`src_ptr`), so **any element created after load — via `createElement` OR
> `innerHTML` — is unreachable by event dispatch.** Combined with `element.click()` /
> `dispatchEvent()` not driving handlers, and all layout-read APIs (`getBoundingClientRect`,
> `offsetWidth`, `getComputedStyle`) returning stub constants, **no client-rendered SPA
> (React/Vue/Angular/Svelte) can be interactive**, and even server-rendered pages lose any
> dynamic behavior that mutates then re-binds the DOM.

**Grounded estimate:** the static engine is ~90% of the way to Chrome parity; the
**functional/interactive engine is ~35–45%**. Closing it to "usable for most websites" is a
**multi-month effort (est. 3–6 months, 1–2 engineers)**, but it is *front-loaded*: one
foundational rework (a live DOM tree that layout, query, and event dispatch all share) unlocks
the majority of it. The long tail (Web Components, canvas-2D-in-JS, full CSSOM computed values,
real networking) is the remaining months.

### Per-dimension scorecard

| Dimension | State | Evidence |
|---|---|---|
| **1. ECMAScript core** | **Strong (works)** | 86/86 core + 57/70 advanced probes match V8 exactly |
| **2a. DOM mutation/query** | **Partial** | createElement/innerHTML/query*/classList/dataset work; `closest`/`matches`/`append`/`remove`/`insertBefore`/`nextElementSibling` broken |
| **2b. Event dispatch (live)** | **Broken (structural)** | dynamic elements not click-reachable; `element.click()` throws; `dispatchEvent(new Event)` no-ops |
| **2c. Layout-read APIs** | **Broken (stubbed)** | `getBoundingClientRect`/`offsetWidth`/`getComputedStyle` return 8px/16px constants, not real geometry |
| **2d. Timers/storage/observers** | **Works** | setTimeout/clearTimeout/rAF, localStorage/sessionStorage, MutationObserver all correct |
| **3. CSS (static layout)** | **Strong** | sub-1px vs Chrome across 230 fixtures (parity rounds); CSSOM *read* is the gap |
| **4. Networking** | **Partial/untestable offline** | `fetch`/`XMLHttpRequest`/`URL` present & return Promises; `Headers`/`Request`/`Response` undefined; no real round-trip on host |
| **5. SPA / dynamic content** | **Broken** | mini-React re-render stays at initial state; consequence of 2b+2c |

---

## Dimension 1 — JavaScript / ECMAScript coverage

**Verdict: STRONG. This is not the gap.** The interpreter (`lib/web/js/interp.ad`, 111KB) is
comprehensive and modern.

**Works (86/86 core probes byte-match V8):** arrow fns, let/const, template literals, full
destructuring (array/object/defaults/rest), spread (call/array/object), optional chaining,
nullish coalescing + `??=`/`||=`/`&&=`, classes (extends/super/static/**private #fields**/
getters/setters/computed props), generators + `yield*`, closures, try/catch/finally, labeled
break/continue, tagged templates, `Symbol.iterator`, **BigInt**, `**`; Array (sort/filter/reduce/
find/flat/flatMap/includes/from/of/fill/some/every/entries/at), String (pad/includes/replaceAll/
matchAll/codePointAt/raw/localeCompare), Object (keys/values/entries/assign/freeze/fromEntries/
defineProperty/getPrototypeOf/create), Map/Set/WeakMap, JSON (parse/stringify+indent), Math,
Number, **RegExp incl. named groups / lookahead / sticky / unicode flag**, Intl.NumberFormat +
DateTimeFormat, Date + ISO, Promise (then/chain/all/race/catch/finally/allSettled), async/await
(incl. loops + try/catch), `queueMicrotask`, async iterators, `structuredClone`, Proxy (get/set/
has), Reflect (apply/ownKeys/construct/defineProperty), `Object.setPrototypeOf`, `.call`/`.apply`/
`.bind`, `arguments`.

**Genuine gaps found (13/70 advanced probes fail — `scripts/probe_js_hard.sh`):**

| Probe | hb result | V8 | Impact |
|---|---|---|---|
| `closure_loop_let` | `1,2,3` | `0,1,2` | **HIGH** — `for(let i…)` does NOT create a per-iteration binding; every closure captures the final value. This is the canonical "register a handler per item in a loop" bug — silently wrong, not an error. Breaks common real code. |
| `element.click()`/event dispatch (see dim 2) | throws | — | HIGH |
| `gen_send` | `got undefined` | `got 42` | MED — `generator.next(v)` doesn't inject `v` into `yield`. Breaks coroutine/saga libs. |
| `new_target` | **SyntaxError** | `ok` | MED — `new.target` unparseable; appears in transpiled class output. |
| `entries_iter` | `next is not a function` | `a 1` | MED — `Map.prototype.entries()` returns a non-iterator (for-of works, manual `.next()` doesn't). |
| `typedarray_map`/`set`/`subarray` | `map/join is not a function` | works | MED — `TypedArray.prototype` methods missing (map/set/subarray). Canvas/wasm/crypto glue. |
| `DataView` | `not defined` | `258` | MED — no `DataView`. Binary protocols / wasm. |
| `in_operator` | `"length" in [] → false` | `true` | MED — `in` misses builtin intrinsic props (array `length`); finds prototype methods. Array-like detection breaks. |
| `error_stack` | `null.x → not TypeError` | `true` | MED — engine-thrown errors aren't `instanceof TypeError`; user-thrown ones are. `catch(e){if(e instanceof TypeError)…}` misroutes. |
| `Promise.any` | `not a function` | `any ok` | LOW-MED |
| `intl_collator` | `undefined` | `function` | LOW |
| `string_normalize` | wrong length | `4` | LOW |

**Note:** the memory's "`ze`/`maft` is not a function" Google-bundle failures were prior-round
fixes; the residual core-JS gaps above are subtler (mostly *silently wrong*, not thrown), which
is arguably worse for real sites.

---

## Dimension 2 — DOM & Web APIs

**Verdict: the fault line of the whole browser.** 37/61 probes pass (`scripts/probe_dom_api.sh`);
the failures cluster into one structural cause plus a batch of missing methods.

### 2b — THE STRUCTURAL WALL: live DOM not wired to interaction (HIGH, blocks the real web)

Interaction routing (`lib/web/dom/canvas.ad` `he_dom_click` → `_lookup_or_register`) resolves an
element id by scanning the **raw parsed HTML source** (`_dom_find_by_id` over `src_ptr`) and a
registration table that is **not populated for JS-created nodes**. Result — measured:

```
STATIC  <button id=inc> in HTML, engine click  → Count: 1   (works)
DYNAMIC createElement('button');id='inc';appendChild → CLICK-NOHANDLER, Count: 0
innerHTML='<button id=b2>' then click b2        → CLICK-NOHANDLER
delegation: container listener + innerHTML kids  → CLICK-NOHANDLER
```

Any node that wasn't in the original HTML text is invisible to event dispatch. This is why the
mini-React SPA below never updates. It is the single highest-impact item in this document.

Compounding it:
- **`element.click()` throws** `click is not a function` (measured). Sites call `.click()`
  programmatically constantly.
- **`dispatchEvent(new Event("x"))` no-ops** — `Event` constructs, `dispatchEvent` exists
  (`typeof === function`), but a listener for a custom type never fires (`fired=0`);
  `defaultPrevented`/`CustomEvent.detail` don't propagate. Frameworks dispatch synthetic events.

*(The engine's OWN click path — `he_dom_click_index` → `_dispatch_event` — has a real bubbling
core with capture/target/bubble phases, `stopPropagation`, and drains timers afterward. The
machinery exists; it just can't be reached for dynamic nodes or from JS.)*

### 2c — Layout-read APIs return stub constants (HIGH)

Every JS layout measurement returns fixed placeholder numbers, not real geometry (measured):

```
#t{width:200px;height:80px}
  getBoundingClientRect()  hb: w=8  h=16 top=0   chrome: w=200 h=80 top=8
  offsetWidth/Height       hb: 8 / 16            chrome: 150 / 60
  getComputedStyle().width hb: 8px               chrome: 120px
  getComputedStyle().display  hb: block          chrome: flex
  getComputedStyle().padding  hb: 0px            chrome: 10px
```

`getComputedStyle().color` IS correct (returns cascaded color), but width/display/padding/box
metrics are stubs. This breaks: sticky/dropdown positioning, "measure-then-place" menus,
scroll-based lazy loading, chart/carousel/tooltip libraries, responsive JS — anything that reads
the box model. The engine computes true geometry internally (the pixel renderer is sub-1px); it
simply isn't exposed to the CSSOM/JS layer.

### 2a — DOM mutation/query: works with holes (MED)

**Works (measured vs chromium):** `createElement`, `innerHTML` (read+write), `textContent`,
`querySelector`/`All`, `getElementsByTagName`/`ClassName`, `classList.toggle`/`contains`,
`dataset`, `cloneNode`, `insertAdjacentHTML`, `firstElementChild`/`lastElementChild`,
`parentNode`, `removeChild`.

**Broken (measured):**

| API | hb | chrome | Note |
|---|---|---|---|
| `closest(sel)` | `N` | `Y` | used pervasively in event delegation |
| `matches(sel)` | `false` | `true` | ditto |
| `el.append(str)` / `el.remove()` | throws / no-op | works | modern mutation API |
| `insertBefore` / `replaceChild` | throws (null `firstChild`) | works | text-node children return null |
| `nextElementSibling` | throws (null) | `B` | sibling traversal |
| `classList.add("a","b")` | only `a` | `a b` | **not variadic** |
| `getAttribute` after `setAttribute("data-x")` | `null` | `7` | attr round-trip (dataset works though) |
| `new FormData(form)` | `nullnull` | `12` | form serialization |
| `input.checked` read | empty | `true` | |

### 2d — Timers / storage / observers: WORKS (good news)

setTimeout(+args)/clearTimeout/requestAnimationFrame, localStorage/sessionStorage (incl. JSON
round-trip), MutationObserver (fires on childList mutation), IntersectionObserver/ResizeObserver
(present as functions), window/navigator/location/history all present and correct.

### Missing entirely (MED/LOW)

Web Components (`customElements` undefined, `attachShadow` undefined, `<template>.content` null);
canvas **2D context is null in JS** (`getContext("2d")` → null, `measureText` throws) even though
there's a canvas paint path; `document.cookie` write didn't round-trip.

---

## Dimension 3 — CSS feature coverage

**Verdict: STRONG for static layout, per the 19 parity rounds (flexbox, grid, position/sticky,
media queries incl. `@media` + `media=` attribute, calc, custom props, cascade/specificity to
2048 rules, transforms — all landed and sub-1px).** The FUNCTIONAL CSS gap is **CSSOM read-back**
(dim 2c): JS cannot observe the computed style/box it renders. Also unverified functionally:
CSS transitions/animations *observed from JS* (the paint may animate, but `animationend` events /
`getComputedStyle` mid-animation are untested and likely absent given 2b/2c). Real layouts don't
"break" statically; they break when JS tries to read them back.

---

## Dimension 4 — Networking / resource loading

**Honest offline caveat: no live network on the host path, so this is an API-surface audit, not a
round-trip test.** Measured presence: `fetch` (function, returns a thenable), `XMLHttpRequest`
(function), `URL` (function). **Absent:** `Headers`, `Request`, `Response`, `URLSearchParams` all
`undefined` — so `fetch(new Request(...))` and header manipulation fail. Per memory, the native
`user/hambrowse.ad` path does real HTTP/9 fetch (gzip inflate, external `<link>` CSS, redirects)
on-device, and `img`/`link`/`script` resource loading works there; the gaps are (a) the modern
fetch object model (`Response.json()`, `Headers`) and (b) reliability (memory notes intermittent
`fetch FAILED rc=-2/-6`, DNS/TLS flakiness — still open). fetch's `.then(r=>r.json())` chain
cannot be verified offline and the missing `Response` type suggests it is incomplete.

---

## Dimension 5 — Dynamic / SPA content

**Verdict: BROKEN — this is where "renders but unusable" bites hardest.** Measured with a
hand-built mini-React (createElement tree + `count` state + re-render on click):

```
render() → button "Count: 0"       (initial render: CORRECT, paints fine)
click #inc (engine dispatch)  → CLICK-NOHANDLER; stays "Count: 0"
```

The initial render is perfect (proving createElement/appendChild/event-listener *registration*
all work). But the state update never fires because the dynamically-created button is not
interaction-reachable (2b). This generalizes: **React/Vue/Angular/Svelte build their entire DOM
dynamically and rely on synthetic-event dispatch + delegation over dynamic children — every one
of those mechanisms is exactly what's broken.** Client-side routing, virtual-DOM diffing, and
reactive re-render all sit on top of these primitives, so a modern SPA renders its first frame
(if SSR'd) and is then frozen.

---

## Ranked biggest-impact gaps (fix these N → dramatically more real web works)

| # | Gap | Impact | Effort | Why |
|---|---|---|---|---|
| **1** | **Live DOM tree shared by layout + query + event dispatch** (dynamic nodes interaction-reachable; id lookup off the live tree, not `src_ptr`) | **Blocks all SPAs + most dynamic pages** | **Large / multi-month** | The keystone. Everything dynamic depends on it. Requires event dispatch (and query/`closest`/`matches`) to walk the same live node tree the JS DOM mutates, replacing the source-scan id resolution. |
| **2** | **Real CSSOM read-back**: `getBoundingClientRect`/`offset*`/`getComputedStyle` return true geometry & computed values | **HIGH — measure-then-act JS everywhere** | **Medium-Large** | Engine already computes the numbers for paint; wire them to the JS objects. Unblocks positioning, lazy-load, chart/UI libs. |
| **3** | **`element.click()` + `dispatchEvent(Event/CustomEvent)` drive handlers** | **HIGH — programmatic events** | **Small-Medium** (dispatch core exists) | Route `.click()`/`.dispatchEvent()` through the existing `_dispatch_event` bubbling core; propagate `detail`/`defaultPrevented`. |
| **4** | **`for(let)` per-iteration binding** | **HIGH — silently wrong** | **Small-Medium** | Fresh binding per loop iteration in the interpreter's scope handling. Silent data corruption is worse than a throw. |
| **5** | **DOM method holes**: `closest`, `matches`, `append`/`remove`/`insertBefore`/`nextElementSibling`, variadic `classList.add`, `getAttribute` round-trip | **MED — delegation & mutation** | **Small each** | Individually cheap; `closest`/`matches` gate event delegation. |
| **6** | **fetch object model**: `Response`/`Headers`/`Request`/`URLSearchParams` + `.json()` | **MED — data-driven pages** | **Medium** | Plus fix the open DNS/TLS reliability. Needs on-device verification. |
| **7** | **TypedArray methods + `DataView`, generator `.next(v)`, `new.target`, `in`-on-builtins, error `instanceof`, `Promise.any`** | **MED — edge bundles** | **Small each** | Long tail of JS conformance; each unblocks a class of minified bundles. |
| **8** | **Web Components + canvas-2D-in-JS** | **MED-LOW** | **Large** | Many sites polyfill/degrade; deprioritize until 1–6 land. |

---

## Recommended phased roadmap

### Phase-0 STATUS — LANDED 2026-07-24 (this pass)

Phase-0 quick wins are largely DONE. Probe-suite deltas (oracle = node/V8 for JS,
`chromium --headless --dump-dom` for DOM), all on `build/host/hambrowse_host`:

- **JS-hard (`scripts/probe_js_hard.sh`): 57/70 → 63/70.**
- **DOM/Web-API (`scripts/probe_dom_api.sh`): 37/61 → 53/61.**
- **JS-core (`scripts/probe_js_coverage.sh`): 86/86 (unchanged — no regression).**
- Render gates (host, google, realsite, realarticle) + DOM/event gates
  (domapi/domcore/dommut/events/evtcapture/matches/contains/classlistr2/innerhtml/
  qsel_created/domtree/insadj/observers/evttypes) all still PASS — no paint regression.
- New gate `scripts/test_hambrowse_phase0_host.sh` (+ `tests/fixtures/hambrowse_phase0.html`)
  pins every fix below to its V8/Chrome-verified output; registered in `ci_battery_manifest.txt`.

**DONE (each verified base-FAIL → after-PASS vs the oracle):**
- ✅ `for(let …)` per-iteration binding — closure-in-loop was `1,2,3`, now `0,1,2` (V8). *(gap 4)*
- ✅ `element.click()` + `dispatchEvent(new Event/CustomEvent)` drive handlers on
  created/innerHTML nodes: target phase + bubbling over the live `parentNode` chain,
  `e.target`, `detail`, `preventDefault`/`defaultPrevented`, `stopPropagation`,
  `removeEventListener`. *(gap 3)* — via a JS-object-keyed listener store + `_obj_dispatch`
  (distinct from the coordinate-driven source-tree `_dispatch_event`, which is untouched).
- ✅ `closest`/`matches` on created + innerHTML nodes; `append`/`remove`/`insertBefore`/
  `replaceChild` keep `firstChild`/`lastChild`/`nextElementSibling` in sync;
  `nextElementSibling`/`parentNode` now wired for innerHTML children; **variadic**
  `classList.add`/`remove`; `getAttribute` round-trips a runtime `setAttribute`;
  `input.checked` reflects the innerHTML boolean attr. *(gap 5)*
- ✅ JS long tail *(gap 7)*: `Promise.any`, `new.target` (was SyntaxError), engine-thrown
  errors are `instanceof TypeError`/`Error`, `Map.prototype.entries()/keys()/values()`
  return real iterators (`.next()`), `"length" in []`.

**REMAINING (deferred — bigger or lower-ROI, NOT the Phase-0 keystone):**
- `new FormData(formEl)` scraping named controls (cross-layer JS↔DOM form walk).
- `classList` object on *created* elements (keyed by source index today).
- `document.cookie` write round-trip; `Headers`/`Request`/`Response`/`URLSearchParams` fetch model *(gap 6, needs on-device)*.
- JS: generator `.next(v)` value injection (engine runs generators EAGERLY — needs the lazy-generator rework, not a Phase-0 patch), `DataView`, `TypedArray.map/set/subarray`, `Intl.Collator`, `String.prototype.normalize`.
- canvas-2D-in-JS, Web Components (`customElements`/`attachShadow`/`<template>.content`) — Phase-4.
- The **live-DOM interaction keystone (Phase 1)** and **CSSOM read-back (Phase 2)** are unchanged and remain the multi-month heart of the effort. The Phase-0 event work above is the *programmatic* target+bubble path over the JS object tree; it does NOT replace the Phase-1 shared live-tree/hit-test rework.

**Phase 0 — quick, high-ROI wins (days–2 weeks), while Phase 1 is scoped:**
- `element.click()` / `dispatchEvent` → existing dispatch core (gap 3).
- `closest`, `matches`, variadic `classList.add`, `append`/`remove`, `nextElementSibling`,
  `getAttribute` round-trip (gap 5).
- `for(let)` per-iteration binding (gap 4).
- Small JS: `Promise.any`, `DataView`, `TypedArray.map/set/subarray`, `new.target`, `Map.entries`
  iterator, error `instanceof`, `in`-on-builtins (gap 7).
- These are individually small, independently testable via the probe harnesses here, and each
  removes a real failure class **without** the Phase-1 rework.

**Phase 1 — the keystone (1–3 months): live DOM interaction.**
- Make event dispatch resolve targets against the **live node tree** the JS DOM already mutates,
  not `src_ptr`. Register JS-created nodes (createElement/innerHTML) in the id/hit-test index so
  clicks/typing reach them; support delegation over dynamic children.
- Acceptance gate: the mini-React fixture in this doc becomes interactive (click → Count
  increments → re-render). Add it to `scripts/test_js_functional_host.sh`.

**Phase 2 — CSSOM read-back (3–6 weeks): expose real geometry** (gap 2). Unblocks the large class
of "measure then position/animate" scripts. Gate: `getBoundingClientRect`/`offsetWidth`/
`getComputedStyle` match chromium within the pixel tolerance the paint path already achieves.

**Phase 3 — networking object model + reliability (weeks): `Response`/`Headers`/`.json()`,
fix DNS/TLS flakiness** (gap 6). Requires on-device testing (offline host can't verify).

**Phase 4 — long tail (months): Web Components, canvas-2D-in-JS, CSS animation/transition JS
events, remaining Intl/normalize.** Deprioritized; sites degrade rather than break on these.

---

## Quick-wins vs deep structural work

- **Quick wins (Phase 0):** the entire JS long-tail + DOM-method holes + programmatic events +
  `for(let)`. High ROI, low risk, each has a ready probe here. Do these first — they visibly
  improve real bundles immediately and don't touch the render/layout core the parity rounds own.
- **Deep structural work (Phases 1–2):** the live-DOM/interaction rework and CSSOM read-back.
  This is the multi-month heart of the effort. It is architectural (a shared live node tree) and
  should be one focused agent's charter, coordinated to NOT collide with the ongoing
  `lib/web/` parity edits.

**Honest bottom line:** hambrowse can already *load and display* an enormous fraction of the web
correctly, and its JS engine rivals a real one on language features. What it cannot yet do is let
you *use* a page whose content is built or updated by JavaScript after load. That is one big
rework (Phase 1) plus one medium one (Phase 2), realistically **3–6 months** to reach "usable for
most websites" — the good news is the work is concentrated and the render foundation under it is
already excellent.

---

### Reproduce / probes added (additive, no engine changes)
- `scripts/probe_js_coverage.sh` — 86 ECMAScript-core probes vs node.
- `scripts/probe_js_hard.sh` — 70 advanced/metaprogramming probes vs node.
- `scripts/probe_dom_api.sh` — 61 DOM/Web-API probes vs `chromium --headless --dump-dom`.
- Build first: `python3 -m compiler.adder compile --target=x86_64-linux user/hambrowse_host.ad -o build/host/hambrowse_host`
  (or run `scripts/test_js_functional_host.sh` once).
