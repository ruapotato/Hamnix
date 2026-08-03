# hambrowse vs the REAL web — review, 2026-07-25

**Question asked:** *"how close are we to actually running real websites?"*

**Headline verdict:**

> **Reading the web: close. Using it: not close.**
> hambrowse renders real, unmodified pages from Hacker News, Wikipedia, MDN and
> google.com recognisably — in the Google case, near-photographically — and its
> post-JS DOM tree matches Chrome's to within **0.1–4%** of node count on every
> content site tested. But the **live-DOM interaction keystone is STILL OPEN**
> (verified, §4), and a second wall was found that the previous analysis did not
> reach: **real React 18 cannot even mount** (§5), and **a `ReferenceError`
> aborts the entire remaining script and cannot be caught by `try/catch`** (§6.3),
> which detonates real bundles from the first missing global onward.
>
> Revised estimate (§9): **"renders acceptably" for classic server-rendered sites
> is ~1–2 months of polish away. "Actually usable/interactive on most real
> websites" I put at 6–12 months, i.e. I am revising the prior ~3–6 months
> UP**, because the keystone did not move and the framework-mount gap is a
> second item of comparable size sitting *upstream* of it.

Base: `main` @ `438fca0a`. All numbers below were produced in this pass; nothing
is carried over from the prior document except where explicitly labelled "prior".

---

## 1. Method, and what it can and cannot prove

| | |
|---|---|
| **Engine under test** | `build/host/hambrowse_host` / `build/host/hambrowse_gfx`, compiled fresh from `lib/web/` on `438fca0a`. Cache files (`hambrowse_gfx`, `hambrowse_host_gfx`, `hambrowse_host`) deleted before every render. |
| **Oracle** | real `chromium 147.0.7727.137` (`--headless --dump-dom` for DOM, `--screenshot` for pixels) and `node v20.19.2` (V8) for JS. |
| **Sites** | fetched LIVE this session (the host does have network; the *engine* does not use it). `scripts/fetch_realweb_fixture.py` snapshots a URL and **inlines every external stylesheet and script**, because the host harnesses read one local file and do not fetch subresources — comparing a raw `curl` dump would measure the harness's missing fetcher, not the engine. Both engines then see a byte-identical file. Fixtures: `tests/fixtures/realweb/`. |
| **New harnesses added** | `scripts/fetch_realweb_fixture.{sh,py}`, `scripts/probe_realweb_dom.sh`, `scripts/probe_realweb_scripts.py`, `scripts/probe_js_syntax.sh`, `scripts/locate_js_parse_fail.js`, `user/hambrowse_probe_host.ad` (a copy of `hambrowse_host.ad` that prints `js_error_msg()` instead of a bare `JSERR 1` — **no engine code was changed**). |

**Honest caveats — read these before trusting any number below.**

1. **No network inside the engine.** `fetch`/`XHR`/CORS/redirects/HTTP caching are
   *not* exercised. Images referencing remote URLs are broken placeholders in
   hambrowse. This review says nothing about the on-device `user/hambrowse.ad`
   fetch path.
2. **Inlining is a favour to hambrowse.** On a real network the engine would have
   to fetch those 29 stylesheets itself. The renders below are the engine's
   *best case*.
3. **SSIM is a weak signal here.** The synthetic parity corpus that the 19 pixel
   rounds tuned scores a *mean SSIM of 0.615* vs chromium (worst page `flexnav`
   0.477, per `docs/browser_framediff.md`). Several real sites below score
   **higher** than that — which tells you SSIM in this harness is dominated by
   font AA and scale normalisation, not by "does it look right". **The
   side-by-side images I actually looked at are the primary evidence**; SSIM is
   a continuity column only.
4. **TodoMVC-React is inconclusive** and is excluded from the verdict: served
   from `file://`, *chromium also renders nothing* (18 elements, same as
   hambrowse) because the module graph is CORS-blocked. It is replaced by a
   purpose-built real-React fixture (§5).

---

## 2. Probe scoreboard — current vs prior

| Suite | Prior (2026-07-24) | **Now (438fca0a)** | Oracle |
|---|---|---|---|
| `probe_js_coverage.sh` — ECMAScript core | 86/86 | **86 / 86** | node/V8 |
| `probe_js_hard.sh` — advanced/metaprogramming | 63/70 | **68 / 70** | node/V8 |
| `probe_dom_api.sh` — DOM / Web API | 53/61 | **60 / 67** | chromium |
| `probe_js_syntax.sh` — **PARSER-level (new this pass)** | — | **57 / 61** | node/V8 |

`probe_dom_api` gained 6 probes since the prior run (the CSSOM layout-read set),
so the denominator moved; the pass *rate* went 87% → 90%.

**Remaining JS-hard failures (2):** `gen_send` (`generator.next(v)` does not
inject — engine runs generators eagerly), `string_normalize`.

**Remaining DOM failures (7):** `cookie`, `formdata`, `canvas_ctx`,
`canvas_measure`, `customElements`, `shadowdom`, `template_el`.

**New parser suite — the 4 failures matter more than their count suggests**,
because one unparseable token kills a whole bundle:

```
FAIL  async_method_short   node=<2>       hb=<ReferenceError: async is not defined>
FAIL  class_computed       node=<1>       hb=<TypeError: m is not a function>
FAIL  getter_proto_obj     node=<1>       hb=<undefined>
FAIL  new_dot_target       node=<F {}>    hb=<{  }>
```

Verified by hand — hambrowse cannot parse an **async function *expression*** at all:

```
var f=async e=>e*2;                 => JSLOG 6                                    OK
var f=async(e)=>e*2;                => JSLOG 6                                    OK
async function f(){return 4}        => JSLOG 4                                    OK
var f=async function(e){return e};  => ReferenceError: async is not defined       FAIL
var o={async f(){return 2}};        => ReferenceError: async is not defined       FAIL
class C{async f(){return 3}}        => TypeError: then is not a function          FAIL (parses, not actually async)
```

`async function(` is in essentially every modern bundle. This is the confirmed
cause of the TodoMVC/React-bundle `SyntaxError` (§6.1).

---

## 3. Per-site results

Render column = my own visual judgement of the side-by-side
(`build/framediff_gfx/<site>/sxs_chromium.png`), with the SSIM in brackets for
continuity. DOM column = post-JS element census, identical probe script injected
into both engines (`scripts/probe_realweb_dom.sh`).

| Site | Render | Post-JS DOM (hb vs chromium) | JS | Interaction | Worst break |
|---|---|---|---|---|---|
| **Hacker News** (news/aggregator) | **Good** — orange header, ranked story list, titles, domains, subtext, footer, search box all correct and readable [0.573] | `all=811 / 815`, `a=227 / 227`, `div=29 / 29` — **99.5%** | **clean, 0 errors** | links laid out (227 detected) | content column too narrow; beige `#f6f6ef` page background not applied; text denser than Chrome |
| **Wikipedia** (docs/reference) | **Good** — correct `<h1>`, floated infobox table with Developer/Written in/Kernel type rows, body text flowing beside it, blue underlined links, nested TOC [0.750] | `all=4576 / 4575`, `a=1199 / 1199`, `input=12 / 12` — **99.98%** | 1 error, and it is **not Wikipedia's fault**: hambrowse *executes* `<script type="application/ld+json">` (§6.2) | not tested | article text column squeezed very narrow by the infobox float |
| **MDN `<input>`** (docs, JS-heavy) | **Poor first screen** — the entire collapsed mega-menu (HTML/CSS/JS/Web APIs link trees) is painted expanded, pushing the article off-screen [0.781] | `all=3991 / 3831` (hb +4%), `button=20 / 9`, `input=2 / 0` | 1 error | not tested | **`:not()` selector unsupported** → `display:none` rule never matches → menus render open (47 `:not()` uses on this page) |
| **google.com** (search) | **Very good** — multicolour wordmark, rounded shadowed search box, Google Search / I'm Feeling Lucky buttons, top nav, app-grid glyph, full grey footer [0.881] | `all=440 / 442`, `div=167 / 169` — **99.5%** | 4 of 13 inline scripts error | **WORKS — best result in this review** (see below) | stray "What's on your mind?" placeholder painted; Sign-in button and mic/lens icons missing |
| **books.toscrape.com** (e-commerce) | **CATASTROPHIC** — the tagline "We love being scraped!" renders at ~300px, filling the whole viewport; the entire 20-product grid, sidebar and prices never appear [0.768 — SSIM is lying here] | `all=542 / 542` — **exact** | `ReferenceError: $ is not defined` (jQuery, external, not inlined) | n/a | **`font-size: N%` is resolved as ≈ N×12 px** (§6.4). `small{font-size:80%}` ⇒ ~960px text |
| **react.dev** (SSR + hydrate) | **Content present, layout destroyed** — headings and copy are all there but **every paragraph wraps one word per line**; the content column collapses to min-content [0.832] | census never ran: `SyntaxError: script too large (node limit)` | fatal — bundle exceeds the interpreter's AST node cap | n/a | script node-limit + collapsed grid/flex column width |
| **github.com/login** (form-heavy) | **NO RENDER — hangs** | — | — | — | **the page's JS does not terminate.** >50 min wall-clock, no output, no watchdog (§6.7) |
| **Real React 18 SPA** (`react_spa.html`, §5) | blank shell | `all=8 / 15`, `li=0 / 2`, `#inc` button absent vs `Count: 0` | React + ReactDOM **both load and evaluate**; `ReactDOM.createRoot(el)` **throws** | none | missing DOM primitives (§5) |
| **live-DOM keystone** (`livedom_keystone.html`, §4) | renders | `all=15 / 16`, `button=5 / 6` | clean | **static click works, every dynamic click fails** | the keystone (§4) |

### Interaction that WORKS: the real Google search form

This is the strongest functional result in the review — a real, unmodified
google.com homepage, driven end-to-end through the native pointer/field/submit
index chain (`he_dom_id_index` → `he_dom_is_textfield` → `he_dom_set_value_index`
→ `he_dom_field_form` → `he_dom_submit_index`):

```
$ build/host/hambrowse_probe_host tests/fixtures/realweb/google_home.html 1024 fieldnav APjFqb hamnix
FIELDNAV id=APjFqb idx=3 textfield=1
FIELDNAV form=0
FIELDNAV NAV /search?q=hamnix&sca_esv=16379ba4feb393a7&source=hp&ei=4eBkar-ALImQm9cPmMqW0A0&iflsig=ABILxe8AAAAAamTu8dvS7KA-i_af_FE2GaN0vumg9P-8
```

It found the real `<textarea id="APjFqb">`, classified it as a text field, typed
into it, resolved the enclosing `<form action="/search">`, and serialised a
**correct GET navigation including every hidden field**. On a device with
networking that is a working Google search.

### DOM-tree fidelity is genuinely excellent

Worth calling out separately, because it is the best news here. On four of the
biggest real pages tested, hambrowse's post-JS element tree is within a
rounding error of Chrome's:

```
SITE          HAMBROWSE                                          CHROMIUM
hn            all=811  div=29  a=227  input=1  button=0          all=815  div=29  a=227  input=1  button=0
wikipedia     all=4576 div=266 a=1199 input=12 button=15         all=4575 div=266 a=1199 input=12 button=15
books_shop    all=542  div=56  a=94   input=0  button=20         all=542  div=56  a=94   input=0  button=20
google_home   all=440  div=167 a=18   input=10 button=10         all=442  div=169 a=18   input=10 button=10
mdn_input     all=3991 div=172 a=857  input=2  button=20         all=3831 div=166 a=848  input=0  button=9
```

The HTML parser and the DOM it builds are **not** the problem. (One caveat:
`document.body.textContent` returns `""` on every large page in hambrowse while
Chrome returns 60–300 KB — the `text=` column is omitted above because of it.)

---

## 4. THE LIVE-DOM KEYSTONE — verdict: **STILL OPEN**

The prior analysis claimed event dispatch resolves element ids by scanning the
*static parsed HTML*, so JS-created elements are unreachable by click. I built
`tests/fixtures/realweb/livedom_keystone.html` to re-test that after the Phase-0
event work (JS-object-keyed listener store + `_obj_dispatch`). Verbatim output —
`click <id>` is the engine's own dispatch entry point, i.e. what a user click
routes through:

```
--- load-time (no click):
FLOW  [ html ]          <- innerHTML-created button IS laid out and painted
FLOW  [ kid ]           <- delegation child IS laid out and painted
FLOW  [ static ]
FLOW  PROG-FIRED        <- p.click() from JS DID fire  (Phase-0 _obj_dispatch works)
FLOW  [ Count: 0 ]      <- mini-React initial render is correct

--- click statbtn:   CLICK statbtn        -> "PROG-FIRED | STATIC-FIRED"    PASS
--- click dynbtn:    CLICK dynbtn         -> CLICK-NOHANDLER                FAIL  (createElement + appendChild)
--- click htmlbtn:   CLICK htmlbtn        -> CLICK-NOHANDLER                FAIL  (innerHTML)
--- click kid:       CLICK kid            -> CLICK-NOHANDLER                FAIL  (delegation: listener is on a STATIC container)
--- click inc:       CLICK inc            -> CLICK-NOHANDLER, "Count: 0"    FAIL  (mini-React never advances state)
```

**Answer: the keystone is exactly as the prior analysis described, and Phase-0
did not move it.** What Phase-0 *did* fix is the **programmatic** path —
`element.click()` / `dispatchEvent()` from JS now drive handlers on dynamic nodes
(`PROG-FIRED` proves it). But the **user-interaction** path
(`he_dom_click` / the `htmlpage_hit_link` pointer hit-test) still cannot resolve
an id that was not in the original HTML text.

Note the important nuance: **layout already sees dynamic nodes** — `[ html ]`,
`[ kid ]` and `[ Count: 0 ]` are all laid out and painted. So this is *not* a
missing live tree in the renderer. It is specifically the click→element
resolution step that is still keyed off `src_ptr`. That is encouraging for
effort: the tree exists, dispatch must be re-pointed at it.

Also confirmed by the census: hambrowse reports `button=5` where Chrome reports
`button=6` — one dynamically-created button is missing from
`getElementsByTagName('*')` as well, so the divergence is not purely in dispatch.

---

## 5. The SECOND wall the prior analysis did not reach: real React cannot mount

The prior document tested a *hand-built* mini-React. I tested the **real thing**:
React 18.3.1 UMD + ReactDOM 18.3.1 UMD (142 KB of genuine minified React),
client-rendering a hooks component with `useState`, a list, and two buttons.
Fixture: `tests/fixtures/realweb/react_spa.html`.

```
HB     : REACT all=8  li=0 btn=NO-INC
CHROME : REACT all=15 li=2 btn=Count: 0
```

Both React bundles **load and evaluate cleanly** — that is a real achievement:

```
JSLOG typeof React=object typeof ReactDOM=object createRoot=function useState=function
JSLOG MOUNT-THREW: TypeError: cannot read property of null or undefined
```

The failure is `ReactDOM.createRoot(container)` itself, before any rendering.
Probing the DOM primitives React's renderer needs:

```
el.nodeType                = 1          OK
el.tagName / nodeName      = DIV        OK
el.addEventListener        = function   OK
el.__expando = {a:1}       = 1          OK   (arbitrary props stick — React stores fibers this way)
Object.defineProperty(el)  = 5          OK
el.ownerDocument           = undefined  MISSING   <-- almost certainly the createRoot throw
el.namespaceURI            = undefined  MISSING
document.head              = undefined  MISSING
document.defaultView===window = false   MISSING
document.createComment      = undefined MISSING
document.createDocumentFragment = undefined MISSING
document.createElementNS    = undefined MISSING
typeof Element / typeof Node = undefined MISSING   (and `Node.ELEMENT_NODE` throws)
typeof MessageChannel       = undefined MISSING   (React 18's scheduler)
el.style.setProperty        = THREW "setProperty is not a function"
d.appendChild(document.createTextNode("q")); d.textContent  => ""   BROKEN (text nodes don't attach)
```

This matters because it changes the shape of the problem: **even if the live-DOM
keystone (§4) were fixed tomorrow, React/Vue/Angular would still not render a
first frame.** These two items are independent and both are on the critical path
to "SPAs work". The good news is that this list is *short, concrete, and mostly
small* — none of it is architectural the way §4 is.

---

## 6. Ranked blocker list

Ranked by how many real sites the item would block, not by size. "Sites hit" is
out of the 8 real sites in this review plus general prevalence in the fixtures.

| # | Blocker | Sites hit | Effort | Evidence |
|---|---|---|---|---|
| **1** | **Live-DOM interaction keystone** — click/pointer dispatch resolves ids against `src_ptr`, so any JS-created node is unreachable; delegation over dynamic children dead; SPA state never advances | every dynamic page; **all** SPAs | **Large (1–3 mo)** — but layout already has the live tree (§4), so this is re-pointing dispatch + the id index, not building a new tree | §4 |
| **2** | **Framework mount deps** — `ownerDocument`, `namespaceURI`, `document.head`/`defaultView`, `createComment`/`createDocumentFragment`/`createElementNS`, `Element`/`Node` globals, `MessageChannel`, `style.setProperty`, text nodes not attaching by `appendChild` | **all** SPAs; many widget-driven sites | **Medium (3–6 wk)** — a list of concrete bindings, no architecture | §5 |
| **3** | **`ReferenceError` is FATAL and uncatchable** — an undefined identifier aborts the remaining script and `try{}catch{}` does not catch it | **most** real bundles (any feature-detect on a missing global) | **Small–Medium** | §6.3 |
| **4** | **`font-size: N%` resolved as ≈N×12px** | huge — Bootstrap, normalize.css, and every `%`-based type scale. 17–19 uses each in books/wikipedia fixtures | **Small** — `font-size` calls the generic `_style_len()`, which has no percent-of-inherited-size branch; `_lineh_value` already has the `-1500` permille encoding to copy | §6.4 |
| **5** | **`:not()` selector unsupported** → `display:none` rules never match → collapsed menus/accordions/tabs render fully expanded | 5 of 6 content fixtures (14–47 uses each; **0 on HN, which is also the cleanest render**) | **Small–Medium** | §6.5 |
| **6** | **Non-JS `<script type>` is executed** — `application/ld+json`, `text/template`, `application/json` all evaluated as JS | schema.org JSON-LD is on a very large share of the web; it is Wikipedia's *only* JS error | **Trivial** — check the `type` attribute | §6.2 |
| **7** | **`async function` EXPRESSION + `{async f(){}}` unparseable**; `class{async f(){}}` parses but isn't async | modern bundles broadly; confirmed cause of the React app-bundle SyntaxError | **Small** | §2, §6.1 |
| **8** | **No JS watchdog** — github.com/login's JS never terminates; >50 min, browser wedged, unrecoverable | 1 of 8 tested, but the *class* (runaway script) is unbounded and it is a total-loss failure | **Small** (instruction-budget/deadline) + **Medium** (find the actual loop) | §6.7 |
| **9** | **Script AST node cap** — `SyntaxError: script too large (node limit)` on react.dev's bundle | any site with a large single bundle | **Small** (raise/grow the cap) | §3 |
| **10** | **`<template>` content is rendered**; `visibility:hidden` and `opacity:0` content is painted | 24 `<template>`s on MDN alone | **Small each** | §6.6 |
| **11** | **CSSOM `getComputedStyle().fontSize` still stubbed at `16px`** for every value — the layout-read work covered width/padding/display, not font metrics | measure-then-place JS | **Small** | §6.4 |
| **12** | Collapsed content-column width in grid/flex pages (react.dev wraps one word per line); infobox floats squeeze Wikipedia's article column | 2 of 8 | **Medium** | §3 |
| **13** | `document.body.textContent` returns `""` on large pages | scrapers/readers/a11y JS | **Small** | §3 |
| **14** | canvas 2D context `null` in JS; `customElements`/`attachShadow`/`<template>.content`; `FormData`; `document.cookie` | long tail | **Large** (canvas/WC) | §2 |

### 6.1 The React bundle SyntaxError, localised

`scripts/locate_js_parse_fail.js` walks the acorn AST of a minified bundle and
descends to the smallest node hambrowse still fails to parse (prefix-bisection is
invalid on a one-line minified bundle). On the TodoMVC React app bundle it lands
here:

```
CONTEXT: "…return async function(e,t,n){return Xe((" >>> ").flat(1).filter(Ke)…"
```

`async function(` — an async function *expression* (§2). 236 KB of bundle killed
by one construct.

### 6.2 Non-JavaScript `<script>` types are executed

```
<script type="application/ld+json">{"@context":"https://schema.org",…}</script>
<script type="text/template"><div>{{tpl}}</div></script>
<script type="application/json" id="d">{"a":1}</script>
<script>console.log("normal script ran")</script>
```
```
JSLOG SyntaxError: unexpected token in expression      <- ld+json
JSLOG SyntaxError: unexpected token in expression      <- text/template
JSLOG SyntaxError: unexpected token in expression      <- application/json
JSLOG normal script ran
```
Per spec none of the first three may execute. This is Wikipedia's only error.

### 6.3 `ReferenceError` is fatal and uncatchable

```
try{nope}catch(e){console.log("caught "+e)}console.log("after")
  node : caught ReferenceError: nope is not defined
         after
  hb   : JSLOG ReferenceError: nope is not defined
         JSERR ReferenceError: nope is not defined      <- "after" NEVER RUNS

try{null.x}catch(e){…}console.log("after")   -> hb: caught TypeError… | after     OK
typeof nope                                   -> hb: undefined | after            OK
try{JSON.parse("{bad")}catch(e){…}            -> hb: caught | after               OK
```

So thrown errors and `TypeError` are catchable; **only the undefined-identifier
`ReferenceError` is fatal.** This is why 4 of google.com's 13 inline scripts die
at `ReferenceError: google is not defined` — one missing global takes the rest of
the file with it. It is also why the probe battery in §5 stopped dead at
`Node.ELEMENT_NODE` despite being wrapped in `try/catch`.

I rate this the highest-value *small* fix in the document.

### 6.4 Percentage font-size

```
CSS                       hambrowse                    chromium
body{font-size:100%}      16px  h=19                   16px      h=18     OK (100% special-cased)
p{font-size:90%}          16px  h=1077                 14.4px    h=17     BROKEN
p{font-size:120%}         16px  h=1435                 19.2px    h=22     BROKEN
p{font-size:1.2em}        16px  h=22                   19.2px    h=22     box OK
p{font-size:1.2rem}       16px  h=22                   19.2px    h=22     box OK
p{font-size:14pt}         16px  h=21                   18.6667px h=22     box OK
p{font-size:2vw}          16px  h=23                   15.6px    h=18     box OK
```

`90% → 1077px` and `120% → 1435px` is ≈ `N × 12px`: the `%` is dropped and the
number is treated as an em-like multiplier. Anything other than exactly `100%`
explodes. Note also the first column: **`getComputedStyle().fontSize` returns
`16px` for every one of these** — the CSSOM font read is still a stub even though
width/padding/display are now real.

Root cause is one line: `font-size` is parsed with the generic `_style_len()`
(`lib/web/css/cascade.ad:5663` and `:8384`), which has no
percent-of-inherited-font-size branch. `_lineh_value` (same file, ~`:1880–1912`)
already implements exactly the needed encoding for `line-height`.

This single bug is what destroys books.toscrape.com: Bootstrap's
`small{font-size:80%}` becomes ~960px type.

### 6.5–6.6 What hides and what does not

Everything listed here is *painted* by hambrowse (i.e. failed to hide):

```
display:none                      hidden   OK
[hidden] attribute                hidden   OK
height:0;overflow:hidden          hidden   OK
li.x{display:none}                hidden   OK
.parent > *{display:none}         hidden   OK
@media(min-width:1px){display:none} hidden OK
display:none !important           hidden   OK
.b:not(.open){display:none}       PAINTED  <-- :not() unsupported
<template>…</template>            PAINTED  <-- template content must never render
visibility:hidden                 PAINTED
opacity:0                         PAINTED
position:absolute;left:-9999px    PAINTED inline
```

`:not()` usage in the fixtures: MDN 47, google 42, books 35, react.dev 22,
Wikipedia 14, **HN 0** — and HN is far and away the cleanest render. That
correlation is the argument for prioritising it.

### 6.7 github.com/login hangs the engine

```
github_login.html (3.54 MB)                      > 50 min, no output, killed
github_login.html with <script> stripped (2.97 MB)  1.2 s
github_login.html with <style> stripped (0.61 MB)   > 400 s, killed
```

Strip the scripts and it is fast; strip the CSS and it still hangs. **The
non-termination is in JavaScript execution.** For scale: react.dev (1.68 MB)
lays out in 4.2 s, Wikipedia (506 KB) in 1.9 s, HN in <0.1 s — so this is not a
size curve, it is a runaway loop. There is no instruction budget or deadline, so
one bad page wedges the browser permanently with no way back.

---

## 7. What is genuinely strong

To keep the picture honest, these are real and should not be re-litigated:

- **HTML parsing / DOM construction: essentially Chrome-equivalent** on real
  pages (§3 census, 99.5–100% node agreement on four large sites).
- **ECMAScript: 86/86 core, 68/70 advanced, 57/61 parser.** Two 130 KB minified
  React UMD bundles evaluate without error. That is a serious interpreter.
- **Static paint: readable, structured, correctly coloured** real pages —
  google.com in particular is very close.
- **Real form interaction works** end-to-end on the real Google homepage (§3),
  including hidden-field serialisation.
- **Phase-0 delivered what it claimed**: `element.click()`/`dispatchEvent` on
  dynamic nodes now work (§4), and the CSSOM layout-read work is real for
  width/padding/display (`rect_real_size 224x104`, `computed_sheet_width 200px`,
  `computed_sheet_disp flex` all pass vs chromium).

---

## 8. Suggested order of work (highest value per week first)

1. **Quick, cheap, huge blast radius** (days each): uncatchable `ReferenceError`
   (#3), `font-size: %` (#4), non-JS `<script type>` (#6), async function
   expressions (#7), script node cap (#9), `<template>` (#10), a JS watchdog (#8).
   These seven are all small and together they would visibly change every site in
   §3 — books.toscrape goes from unusable to usable on #4 alone.
2. **`:not()` and the hiding set** (#5, #10) — weeks. Turns MDN-class pages from
   "menu vomit" into "the article".
3. **Framework mount deps** (#2) — 3–6 weeks, a concrete checklist. Ends with
   React rendering its first frame.
4. **The keystone** (#1) — 1–3 months. Ends with React being *interactive*.
   Acceptance gate already exists: `tests/fixtures/realweb/livedom_keystone.html`
   must report `DYN-FIRED`, `HTML-FIRED`, `DELEG-FIRED:kid`, and
   `REACT-STATE=1`; and `tests/fixtures/realweb/react_spa.html` must reach
   `REACT all=15 li=2 btn=Count: 0` (chromium's exact answer).

Steps 1–2 are independent of 3–4 and can run in parallel with them.

---

## 9. Revised estimate

Splitting the question, as asked:

**"Renders acceptably" — mostly already true, ~1–2 months from good.**
For classic server-rendered content sites — news, wikis, docs, blogs, forums,
reference — hambrowse already produces a page you can read and navigate. HN,
Wikipedia and google.com are there *today*. The things standing between that and
"looks right" are items #4, #5, #6, #10 and the column-width bug #12 — all small
or medium. I'd expect a month or two of the same kind of focused work that
produced the 19 pixel rounds to make a large slice of the static web look
basically correct.

**"Actually usable / interactive on most real websites" — 6–12 months. I am
revising the prior ~3–6 months UPWARD.** Reasons, in order of weight:

1. **The keystone did not move.** The prior document sized it at 1–3 months and a
   full cycle later it is byte-for-byte the same failure (§4). That is the single
   biggest input to the estimate and it has not been de-risked. It should be
   re-scoped as *large but bounded* — the encouraging discovery is that layout
   already sees dynamic nodes, so this is re-pointing dispatch, not building a
   live tree from scratch.
2. **A second wall of comparable importance was found downstream of the estimate.**
   The prior analysis proved a *hand-written* mini-React doesn't update. I proved
   *real React 18 doesn't mount at all* (§5), for a completely different set of
   reasons. Fixing the keystone alone yields zero working SPAs. That is
   additional serial work the 3–6 month figure did not contain.
3. **The failure modes I found on real sites are mostly not the ones the prior
   doc predicted.** The four things that actually broke real pages here —
   percentage font-size, `:not()`, JSON-LD execution, uncatchable
   `ReferenceError` — appear nowhere in the prior ranked list. That is the normal
   result of testing against real input instead of fixtures, and it is a reason to
   expect *more* such discoveries as the obvious blockers clear. Estimates that
   assume the known list is the whole list have historically been low.
4. **Robustness is unmeasured and at least once catastrophic.** 1 of 8 real sites
   permanently wedged the engine (§6.7). "Runs most websites" implies not hanging
   on a meaningful fraction of them, and nothing currently guarantees that.

Counterweight, stated fairly: the *rate* of progress is high — Phase-0 and the
CSSOM layout-read work each landed inside a day and both delivered exactly what
they promised, and item list §8.1 is seven small fixes with disproportionate
reach. If those land quickly the "renders acceptably" milestone could beat one
month. The 6–12 month figure is about **interactivity on the modern,
framework-built web**, which is gated on two large serial items, not on the many
small ones.

**One-line answer to the user's question:** *we can already read a lot of the
real web, we can search Google, and we cannot yet use anything that a JavaScript
framework built — that last part is two big pieces of work away, not one.*

---

## Reproduce

```bash
rm -f build/host/hambrowse_gfx build/host/hambrowse_host_gfx build/host/hambrowse_host
python3 -m compiler.adder compile --target=x86_64-linux user/hambrowse_host.ad       -o build/host/hambrowse_host
python3 -m compiler.adder compile --target=x86_64-linux user/hambrowse_probe_host.ad -o build/host/hambrowse_probe_host

bash scripts/probe_js_coverage.sh          # 86/86
bash scripts/probe_js_hard.sh              # 68/70
bash scripts/probe_dom_api.sh              # 60/67
bash scripts/probe_js_syntax.sh            # 57/61   (new)

# real sites (fixtures are committed; re-snapshot with fetch_realweb_fixture.sh)
bash scripts/probe_realweb_dom.sh                              # post-JS DOM census vs chromium
python3 scripts/probe_realweb_scripts.py tests/fixtures/realweb/wikipedia.html
node scripts/locate_js_parse_fail.js <bundle.js>               # localize a parse failure
bash scripts/framediff_gfx_run.sh tests/fixtures/realweb/hn.html 1024

# the keystone
build/host/hambrowse_host tests/fixtures/realweb/livedom_keystone.html 1024 click inc
build/host/hambrowse_probe_host tests/fixtures/realweb/react_spa.html 1024
```

Do **not** run `scripts/test_hambrowse_http_features.sh` on the host — it is an
on-device gate and hangs offline.
