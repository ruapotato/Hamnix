# hambrowse real-web compatibility audit — 2026-07-15 (round 11)

**Method.** Characterization round, not a feature round. Pointed the native
browser engine (`lib/htmlengine.ad` parse/CSS/layout, `lib/jsengine.ad` JS,
`lib/htmlpaint.ad`/`lib/htmlpage.ad` paint) at realistic, self-contained pages
via the host render-to-PNG driver `user/hambrowse_host_gfx.ad` (built for
`x86_64-linux`, no QEMU). Every finding below is backed by that driver's
deterministic geometry/paint dump (POSFILL/BORDER/SEGTXT/ULINE/UAELEM/REFLOW…)
or by a code citation. `col`==`pix` in a POSFILL line means the declared colour
actually reached the framebuffer.

**Pages rendered.** Three new fixtures (this round) plus the four pre-existing
realistic fixtures:

| fixture | shape | verdict |
|---|---|---|
| `hambrowse_landing.html` (new) | stylesheet-driven marketing page: fixed flex bar, hero, flex-wrap card grid, main/sidebar flex, footer | layout mostly works; several confirmed CSS gaps |
| `hambrowse_signup.html` (new) | full form: fieldset/legend, label, email/password/text, select/option, radio, checkbox, textarea, buttons | form controls render impressively well; fieldset border missing |
| `hambrowse_todo.html` (new) | JS SPA: array→DOM via createElement/forEach/filter, addEventListener, re-render on click | JS APIs work; **innerHTML='' does not clear created children** |
| `hambrowse_article.html` | unstyled article (UA defaults) | strong — see "worked better than expected" |
| `hambrowse_news.html` | JS gbar/analytics shape | strong — querySelectorAll/dataset/classList all work |
| `hambrowse_google.html` / `hambrowse_interactive.html` | form submit + event handlers | strong |

Two clean, high-value gaps found here were **fixed this round** (see bottom).

---

## Confirmed breaks (observed in a render), ranked by real-site impact

### 1. `border-radius` synthesised a hard 1px border on every card — FIXED
- **Page:** landing (`.card { border-radius: 8px; box-shadow: … }`, no `border`).
- **Symptom:** `BORDER n 3` — each rounded, backgrounded card got a black 1px
  rectangle stroked around it; SEGTXT showed `+------+` / `|` box-art runs.
- **Root cause:** `lib/htmlengine.ad:3471` `_box_decl` matched the generic
  `border` **prefix** against `border-radius`, setting `d_bd=1`. `border-radius`
  is ubiquitous on cards/buttons/inputs that carry no border.
- **Severity:** breaks-the-page (spurious frames all over any modern layout).
- **Status:** FIXED — `border-radius`/`border-image`/`border-collapse`/
  `border-spacing` now excluded; `BORDER n 0` after fix. Gate:
  `scripts/test_hambrowse_landing_host.sh`.

### 2. `rgba(r,g,b,a)` colours/backgrounds were dropped — FIXED
- **Page:** landing (`.btn { background: rgba(255,200,0,0.9) }`).
- **Symptom:** button fill fell back to the inherited hero colour
  (`POSFILL col #12345a`) — the yellow was gone.
- **Root cause:** `lib/htmlengine.ad:_rgb_func` required `rgb(`; on `rgba(` the
  post-`rgb` char was `a`, not `(`, so it returned −1 and the colour was
  discarded. `rgba()` is one of the most common colour spellings on the web.
- **Severity:** degrades (every rgba background/border/text colour lost).
- **Status:** FIXED — `_rgb_func` accepts an optional `a`, ignores alpha; btn
  now `POSFILL col #ffc800`. Gate: `test_hambrowse_landing_host.sh`.

### 3. `innerHTML = ''` does not clear JS-created children
- **Page:** todo. `render()` does `list.innerHTML = ''` then re-appends
  `createElement('li')` items.
- **Symptom:** after a click that re-renders, the list showed the **old** items
  **plus** the new ones (7 lines for 4 tasks) — the `innerHTML=''` clear was a
  no-op against children previously added via `appendChild(createElement(...))`.
- **Root cause (suspected-precise):** the innerHTML-setter fragment path
  (`lib/htmlengine.ad:7708` `_copy_raw_markup` / `dom_ov_inner_html`,
  `lib/jsengine.ad:636`) replaces the node's *original-markup* child range but
  does not detach dynamically-created child nodes from the parent's child list.
- **Severity:** breaks-the-page for ANY re-rendering SPA (React/Vue/vanilla
  "clear then rebuild" is the dominant list-update idiom). Highest-value real
  break still open.

### 4. `text-decoration: line-through` (via a CSS class) is ignored
- **Page:** todo (`.done { text-decoration: line-through }` on a completed item).
- **Symptom:** the completed task "Review the PR" was not struck through
  (`UAELEM strike 0`). Strike only fires for `<s>/<del>/<strike>` tags
  (`g_strike_n`), not CSS.
- **Root cause:** `lib/htmlengine.ad:3943-3949` — `text-decoration` handles only
  `underline` and `none`; `line-through`/`overline` fall through to nothing.
- **Severity:** degrades (common for done/deleted/sale-price states).

### 5. `list-style: none` is ignored — bullets still drawn
- **Page:** todo (`#list { list-style: none }`).
- **Symptom:** `LIST markers 3 discpix #101010` — the "unstyled" nav/todo list
  still got inked disc bullets. Every real navbar/menu built from `<ul>` uses
  `list-style:none`.
- **Root cause:** no `list-style`/`list-style-type` property is parsed
  (grep: only comments mention it); the `<li>` marker path is unconditional.
- **Severity:** degrades (stray bullets on every `<ul>`-based menu/toolbar).

### 6. `position: fixed` is treated as `absolute` (and `right:` does not stretch)
- **Page:** landing (`.bar { position: fixed; top:0; left:0; right:0 }`).
- **Symptom:** `POSFILL 0 … x0 0 x1 568 y0 12` — the bar sat in flow at y≈12
  (not pinned to the top) and was content-width 568px, not the full 900px
  viewport; `right:0` did not stretch it.
- **Root cause:** `lib/htmlengine.ad:3502-3503` folds `fixed` into `absolute`;
  there is no fixed-viewport anchoring, and box width is never resolved from
  `left`+`right` (no right-anchored sizing).
- **Severity:** degrades on a static render (sticky headers are everywhere;
  acceptable-ish without scrolling, but width is wrong).

### 7. `<fieldset>`/`<legend>` border not drawn
- **Page:** signup (`fieldset { border: 1px solid #c3ccd8 }`).
- **Symptom:** `BORDER n 0` — the two account/profile group boxes had no frame;
  `<legend>` rendered as plain inline text, not notched into a border.
- **Root cause (suspected):** the box-border path (`_block_box_open`, bord flag)
  is not engaged for `<fieldset>` styled via a class stylesheet, or the
  fieldset UA box is not wired. Needs confirmation of which selector path drops
  the border (the same `border:1px solid` on a `<table>` DID stroke — see
  article BORDER n 1).
- **Severity:** cosmetic-to-degrades (grouping visually lost).

### 8. Flex items over-shrink, splitting words mid-run
- **Page:** landing flex bar. `SEGTXT Nim` / `SEGTXT bus`, `SEGTXT Log`/`in`.
- **Symptom:** the bold 20px brand "Nimbus" and the "Log in" link wrapped
  mid-token because their flex track was allocated less width than their
  natural content.
- **Root cause (suspected):** flex natural-width measurement / free-space
  distribution (`lib/htmlengine.ad` ~1661 `flex_meas_w`, ~1729-1742 free-space
  step) under-sizes tracks for `justify-content: space-between` with
  variable-width children.
- **Severity:** degrades (nav/brand text visibly broken).

---

## Suspected gaps (from code inspection; not yet isolated in a render)

Confirmed **absent** from the CSS property parser (grep of `lib/htmlengine.ad`),
all common on real sites — degrade silently rather than crash:

- `box-sizing` (0 hits) — width math is content-box only; padded fixed-width
  boxes will be wider than authored.
- `overflow` (no property parse) — no clipping/scroll containers.
- `font-family` (0 hits) — face is chosen from tag semantics only; web fonts /
  font stacks ignored.
- `opacity`, `transform`, `transition`, `box-shadow` (0 hits) — no compositing
  effects (box-shadow silently dropped, which is fine).
- `text-transform`, `letter-spacing`, `background-image`/gradients (0 hits).
- `min-width`/`min-height`, per-side `margin-right`/`padding-*` partially
  present but incomplete (`margin` only routes top/left robustly).
- Selectors: descendant (` `) works and simple specificity is honoured; **child
  (`>`), adjacent (`+`), general-sibling (`~`) tokens are lexed but combinator
  matching is limited**; `:hover`/`:focus`/`::before`/`::after`/`@media`/
  `!important`/`var()`/`calc()`/`hsl()` are all absent.

These are lower priority than the confirmed breaks: they degrade fidelity but do
not garble a page the way #1/#3 do.

---

## Worked better than expected (disproof — with render evidence)

- **JS DOM API is genuinely capable.** news+todo prove `querySelectorAll`,
  `.forEach`, `dataset`, `classList.add/contains`, `getElementsByClassName`,
  `getElementsByTagName`, `getElementById().textContent`, `createElement`,
  `appendChild`, `Array.filter`, template concatenation and
  `addEventListener('click', …)` all run. todo's load-time render produced the
  right 3 items and `Open: 2` (filter). A driven `click add` fired the handler,
  pushed a task and re-rendered (`Open: 3`, "Task 4" appended). Event dispatch
  works.
- **Form controls render with real fidelity.** signup shows placeholders
  (`[you@example.com]`), a `<select>` displaying its `selected` option with a
  dropdown affordance (`[ United Kingdom v]`), radios with checked state
  (`(*) Free ( ) Pro`), a checked checkbox (`[x] …`), and a textarea with its
  value. This is well beyond a monospace stub.
- **UA-default typography is solid.** article (no author CSS) gives a real
  heading hierarchy (`HFACE 2 h38 / 3 h30 / 4 h24`, bold), disc bullets in a
  hanging gutter (`LIST markers 3 itemx 60`), ordered-list numbering,
  `<code>/<pre>` monospace + highlight, a `<blockquote>` indent, a stroked
  `<table border>` (`BORDER n 1`), underlined links, and **no prose overflow**
  at any width (`REFLOW overflow 0`) with proportional TrueType metrics.
- **Backgrounds + z-index paint correctly.** landing's bar/hero/cards/side/
  footer fills all satisfy `col==pix`, and the fixed bar keeps `z 100` over
  content.

---

## Highest-value next round

**Fix `innerHTML = ''` (and by extension `innerHTML = markup`) to detach
dynamically-created children (finding #3).** The "clear the container, rebuild
from data" idiom is how essentially every JS list/table/feed updates. Right now
re-rendering *doubles* content, which silently corrupts any interactive app —
and the rest of the JS DOM stack is already strong enough that this one gap is
what stands between the engine and running real vanilla-JS widgets. Pair it with
`list-style:none` (#5) and `text-decoration:line-through` (#4) — both tiny — to
make JS-built menus/todo/status UIs render cleanly.

Runner-up: a proper `position:fixed`/`right:`-anchored sizing pass (#6/#8) so
flex navbars stop shrinking their brand text.
