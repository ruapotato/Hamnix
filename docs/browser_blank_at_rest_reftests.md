# Blank-at-rest reftest passes — 13 named pairs that will flip to FAIL

**If a CSS/rendering fix of yours turned the reftest ratchet red on a test in
the list below, this note is why, and the red is expected.** It is not a
regression you introduced by being wrong. It is a pass that was resting on the
engine painting *nothing*, and your fix made one side paint something.

Measured 2026-07-30 against `d5ffbc88` on the full vendored lane
(`scripts/wpt_reftest_run.py --all`, 1442 pairs: PASS 47, WEAK-PASS 208,
NONDISCRIMINATING 110, FAIL 1077).

## The shape

`scripts/test_wpt_reftest_ratchet_host.sh` scores a pair PASS when the
relationship **holds** and is **load-bearing on a subject declaration**: the
lane neutralizes each of the test's declarations in turn (mutant *k*) and asks
whether the holding breaks. Separately, mutant *0* re-renders both sides with
all CSS and scripts stripped; a pair that still holds there is
NONDISCRIMINATING and leaves the denominator.

Those two controls are an **and**, not an **or**, and that is deliberate — the
docstring records that global-strip alone discarded 57 of 67 real fixes whose
reference is a plain green square. The consequence is a legitimate but fragile
class:

> A pair can hold **blank == blank** at rest, still fail mutant 0 to
> discriminate it, and *still* be a genuine PASS because neutralizing one
> declaration makes the test paint something the reference does not have.

The evidence lives entirely in the mutation. Nothing in the resting pixels
carries it. So the pass survives exactly as long as the engine keeps painting
nothing on that page — and it converts to **FAIL** the moment a capability
lands that makes one side non-blank.

## The worked example (2026-07-30)

`css/css-position/position-fixed-dynamic-transformed-sibling.html` — a
`<div id=target style="display:none">` holding a `position:fixed` bar, revealed
by `target.style.display = ""`.

At `d5ffbc88` the classifier recorded:

```json
{"verdict": "PASS", "load_bearing": "display", "null_holds": true,
 "subject_props": ["display", "height", "position", "transform"]}
```

| | test | ref | holds |
|---|---|---|---|
| unmutated | 800×600 all `#ffffff` | 800×600 all `#ffffff` | **True** |
| mutant 0 (null-CSS) | all `#ffffff` | all `#ffffff` | **True** |
| mutant *k*: `display` neutralized | `#ffffff`:440800, **`#0000ff`:39200** | all `#ffffff` | **False → load-bearing** |

Ten other declarations held under mutant *k*; `display` alone broke it, and the
reference declares no `display`, so it counted as subject evidence. The pass was
real: it proved the engine applied `display:none`.

Then a fix made `setAttribute("style","")` / `style.display=""` actually reveal
a markup-hidden element. **The 39,200 blue pixels the mutation used to produce
moved into the resting render**, the reference still could not paint its
`position:fixed` box (the engine drops a fill whose last row is past the last
in-flow row, and an out-of-flow box contributes no rows), and PASS 47 → 46
against `#!PASS_FLOOR 47`.

That is a genuine regression under the lane's own model, not a misclassification
— which is why the floor was **not** lowered and the fix was **held** instead,
on branch `hold/style-reveal`.

## The 13

Every baseline PASS whose *unmutated* render is a single uniform colour. All 13
have `null_holds: true`, i.e. all 13 are banked on mutant *k* alone.

| load-bearing | test |
|---|---|
| `display` | `css/css-backgrounds/background-color-body-propagation-004.html` |
| `display` | `css/css-backgrounds/background-color-body-propagation-005.html` |
| `display` | `css/css-backgrounds/background-color-root-propagation-001.html` |
| `display` | `css/css-position/position-fixed-dynamic-transformed-sibling.html` |
| `background-image` | `css/css-backgrounds/background-clip/clip-border-area-multiple-backgrounds.html` |
| `background-image` | `css/css-backgrounds/background-position-three-four-values.html` |
| `background-image` | `css/css-backgrounds/background-position-xy-three-four-values-passthru.html` |
| `background-image` | `css/css-backgrounds/background-size/background-size-cover-svg.html` |
| `height` | `css/css-backgrounds/border-image-repeat-space-1.html` |
| `height` | `css/css-backgrounds/border-image-repeat-space-2.html` |
| `height` | `css/css-backgrounds/border-image-repeat-space-3.html` |
| `height` | `css/css-backgrounds/border-image-repeat-space-7.html` |
| `position` | `css/css-position/hypothetical-dynamic-change-002.html` |

7 of the 208 WEAK-PASSes are blank at rest on the same basis.

Nine of the thirteen wait on capabilities we intend to land —
`position:fixed`/`absolute` painting, `background-image`, `border-image` — so
**this collision will recur.** Corroboration that it is a mechanism and not a
one-off: `hypothetical-dynamic-change-002` is in the list, and it broke
independently under an experimental canvas change on the same day, for the same
reason.

## What to do when you hit one

1. **Check the list.** If your red is one of these 13, you have almost certainly
   made the engine *more* correct, not less.
2. **Do not lower `#!PASS_FLOOR`, and do not reach for `--regen --allow-loosen`.**
   The pass set is guarded separately from the count for exactly this reason,
   and `--allow-loosen` is reserved for when the *lane* changed (a re-import),
   not when the *engine* changed. A rule you can talk your way around is not a
   rule.
3. **Earn the pair back.** The honest resolution is to make the other side paint
   too — i.e. land the capability the reference needs. For the `position:fixed`
   four that means real out-of-flow painting: an out-of-flow box contributes no
   flow rows, so `htmlpage_render` drops its fill and the canvas is too short to
   hold it. Four narrower variants of "let an out-of-flow fill extend the
   canvas" were measured and all scored *worse* (PASS 45), because each one
   converts several other blank-at-rest agreements into honest failures at the
   same time. It needs the real feature — fixed-child static position and
   border-radius background clipping — not a canvas tweak.
4. **If you cannot, hold the fix on a branch and say what lands it.** That is
   what `hold/style-reveal` is.

## MEASURED 2026-07-31 — out-of-flow painting landed, and what it cost

Real `position:absolute`/`fixed` painting is now in (bfill_oof pixel geometry;
the box is given the rect CSS specified instead of being resolved through a row
grid that does not contain it). Measured on the full vendored lane against
`7e6edc7c`, with the `hold/style-reveal` fix cherry-picked on top:

    PASS 47 -> 45     WEAK-PASS 208 -> 207     ND 110 (unchanged)   ERROR 0

The ledger, every pair that changed class, both directions:

| was | now | test | why |
|---|---|---|---|
| FAIL | **PASS** | `css-backgrounds/background-origin-007` | the abspos box now paints |
| FAIL | **WEAK-PASS** | `CSS2/abspos/static-inside-inline-block` | ditto |
| PASS | WEAK-PASS | `css-position/position-fixed-dynamic-transformed-sibling` | **the target pair**. Both sides now render the SAME 784x50 blue bar at y 0..49 — the exact 39,200 px the mutation used to produce. It drops to WEAK because the reveal fix removes the evidence that made it a PASS: with reveal working, neutralizing `display` no longer changes the render, and every remaining declaration is repeated verbatim by the reference. |
| PASS | FAIL | `css-position/hypothetical-dynamic-change-002` | one of the 13. Needs CSSOM `style.left =` writes to re-lay-out (they do not, today) AND fixed-child static position. |
| WEAK | FAIL | `css-position/hypothetical-dynamic-change-001` | same two causes |
| PASS | FAIL | `css-backgrounds/background-rounded-image-clip-001` | NOT one of the 13, same mechanism. Blocked on something else entirely: `html{background-color:green}` must cover the VIEWPORT, and hambrowse's canvas is sized to content, so the test (canvas 212px, it has a 300x200 abspos box) and the reference (canvas 62px) disagree about how much of the frame is green. Border-radius clipping alone cannot recover it — measured. |
| WEAK | FAIL | `css-backgrounds/background-clip-content-box-001` | needs `background-clip: content-box`, which is not parsed at all |
| WEAK | FAIL | `css-backgrounds/border-image-space-001` | needs `border-image` |

Two experiments that scored WORSE and were reverted, recorded so they are not
repeated:

* **Out-of-flow BORDER painting** (the exact analogue of the fill fix, for the
  bbox registry): **PASS 40, WEAK-PASS 204, ND 110 -> 105.** It converts the
  four `height`-load-bearing `border-image-repeat-space-*` entries in the 13
  above, plus `border-image-repeat-round-1/2`, `-space-4/5/6`, and three
  `box-shadow/slice-block-fragmentation-*` (out of ND, straight into FAIL). The
  capability is right; it needs `border-image` beside it.
* Growing the ROW GRID rather than the canvas — this is the fifth variant of
  the four already recorded above, and it is the same answer.

So the pattern in the doc holds and is now quantified twice over: on this
corpus each new painting capability costs more than it earns until its
companion capabilities land. The three named blockers, in the order they would
pay: **`background-clip`/`background-origin` box insets**, **`border-image`**,
and **the page background covering the viewport rather than the content
canvas**.

## Open question, owned by the orchestrator

A pass whose resting render carries no information is arguably a different kind
of pass, and the lane already models one such distinction (WEAK-PASS: "real
work, banked under its own floor, kept out of the headline number"). Whether
blank-at-rest deserves a third class is a ratchet-design decision, to be taken
deliberately rather than discovered again by the next regression. Recorded here
so it is not lost.

## MEASURED 2026-07-31 (second pass) — background-clip and the viewport canvas

Continuing the bundle. Measured on `hold/oof-painting` (`eb415bc8`, itself
PASS 45 / WEAK 207 / ND 110 against the `#!PASS_FLOOR 47` / `#!WEAK_PASS_FLOOR
208` baseline), landing two of the three named blockers:

    PASS 45 -> 48     WEAK-PASS 207 -> 205     ND 110 (unchanged)   ERROR 0

The ledger against `hold/oof-painting`, every pair that changed class, both
directions:

| was | now | test | why |
|---|---|---|---|
| FAIL | **PASS** | `css-backgrounds/background-rounded-image-clip-001` | the pass out-of-flow painting cost, EARNED BACK. It needed both the viewport canvas background and `background-clip: content-box`; the box geometry was never the blocker, the size of the green field was. |
| WEAK | **PASS** | `css-backgrounds/background-color-clip` | promoted. Honouring the property is what makes the pair discriminating. |
| FAIL | **PASS** | `css-backgrounds/border-width-pixel-snapping-001-a` | fallout of routing wide `border` shorthands to the real per-side painter |
| WEAK | FAIL | `css-backgrounds/background-clip/clip-rounded-corner` | both sides now paint an IDENTICAL 5,920px blue ring where before each had a hairline; the residual 512px is the fill rect and the border rect not being the same rectangle. Box-model geometry. |

### What landed

1. **The canvas background covers the VIEWPORT** (css-backgrounds-3 §2.11.2).
   The canvas is never smaller than the viewport; this engine sized it to
   CONTENT, so `html{background-color:green}` painted a band as tall as the text.
   Chromium fills all 800x600; we filled 800x62. Alone it moves NOTHING on the
   lane (the harness composites onto a white 800x600 anyway) — it is only
   load-bearing in combination, which is the whole thesis of this document.
2. **`background-clip` / `background-origin` are parsed**, and the clip is a
   per-side pixel inset of the fill rect. On `background-clip-content-box-001`
   the test side now paints orange 32,400 px and blue 7,600 px — *identical to
   Chromium*.
3. **`background-clip` is a LAYER LIST.** The colour is painted in the
   bottom-most layer, so it takes the LAST entry after truncation to the layer
   count. `background-color-clip` turns on exactly that: three clip entries, two
   layers, so the colour clips to the MIDDLE one — reachable neither as "the
   first" nor as "the last".
4. **`border: 20px solid` painted a HAIRLINE.** The shorthand left the per-side
   packed widths at 0, so every uniform solid border at any width fell to the
   legacy 1px stroke, while the per-side spelling of the same border drew a real
   ring. Chromium 8,800 blue px; we painted 384. 1px solid borders deliberately
   stay on the legacy path — the two agree there, and it keeps every 1px-bordered
   card byte-identical.

### A third experiment that scored WORSE and was reverted

**`transparent` border colours, and `border: solid 15px transparent`.** Both are
real bugs: `_color_value` does not know `transparent`, so the painter fell back
to BLACK and drew a hard frame where the author asked for an invisible one; and
`_style_len` reads only the LEADING token, so a style-first value lost its width
entirely. Fixing them removed a 332px black frame that was the ENTIRE pixel
difference between `css3-background-clip-{border,padding,content}-box` and their
references — all three sat at exactly 332 diff px, and all three then held.

It still scored worse: **PASS 45, WEAK 199, ND 110 -> 122**, over the ceiling.

The cost is the `border-image` cluster, and it is the same mechanism this
document describes. Nine pairs — `border-image-repeat-space-1/2/3` (three of
the thirteen), `-space-4/5`, `-repeat-round-1/2`, and
`clip-border-area-{background-geometry,border-image}` — were resting on the
engine painting that WRONG black frame. Remove it and their renders stop
depending on CSS at all, so they leave the denominator as NONDISCRIMINATING.
The three tests it fixes land as NONDISCRIMINATING too, because this engine does
not size an absolutely positioned box from opposite insets (`top/left/right/
bottom: 0`), so neither side paints the box.

So this is now the third measurement agreeing on the same finding: **on this
corpus a new painting capability costs more than it earns until its companion
capability lands.** `transparent` borders land with **`border-image`**, exactly
as out-of-flow border painting does.

### Where the bundle stands

PASS 48 clears `#!PASS_FLOOR 47`. **WEAK-PASS 205 does not clear 208.** The four
WEAK-PASSes still owed, and what each waits on:

| test | blocked on |
|---|---|
| `css-backgrounds/background-clip-content-box-001` | out-of-flow BORDER painting — its reference is a `position:absolute` box with `border:10px solid blue`, and an abspos box registers no border at all. Its own test side is already pixel-identical to Chromium. |
| `css-backgrounds/background-clip/clip-rounded-corner` | the fill rect and the border rect being the same rectangle (512px) |
| `css-backgrounds/border-image-space-001` | `border-image` |
| `css-position/hypothetical-dynamic-change-001` | CSSOM `style.left =` triggering re-layout |

and one PASS, `css-position/hypothetical-dynamic-change-002`, on that same
CSSOM re-layout.

The bordered-box fill rect is worth naming precisely, because two of those four
run through it. Measured on `div{position:absolute;border:5px solid;padding:25px;
width:100px;height:100px}`: the border box should be 160x160 at the static
position x=8; we paint the fill at x=33 (border-box left PLUS the padding) and
116x150 in size. That is the box-model keystone this document's predecessor
already names — it is not something `background-origin` can be calibrated
around, which is why the five `background-origin-002/003/004/005/008` near-misses
(all pure X-offset errors, green already exactly 60x60) were left alone rather
than fitted to broken geometry.

## MEASURED 2026-07-31 (third pass) — two of this document's own blockers were
## MISATTRIBUTED, and one of the remaining PASSes is anti-evidence

Continuing the bundle from `hold/bg-clip-viewport` (`29f9c963` — PASS 48 /
WEAK-PASS 205 / ND 110 / ERROR 0 against `#!PASS_FLOOR 47` /
`#!WEAK_PASS_FLOOR 208` / `#!ND_CEILING 110`):

    PASS 48 -> 49     WEAK-PASS 205 -> 206     ND 110 (unchanged)   ERROR 0

The ledger, every pair that changed class, both directions — only two moved:

| was | now | test | why |
|---|---|---|---|
| FAIL | **WEAK-PASS** | `css-backgrounds/border-image-space-001` | `bottom:` anchoring, below |
| FAIL | **PASS** | `css-values/ex-calc-expression-001` | the `ex` unit, below |

### 1. `border-image-space-001` is NOT blocked on `border-image`

The bundle's ledger named it as the pair that `border-image` would recover.
Measured against Chromium, it is not: **`support/border.png` is not vendored**,
so neither side loads an image and Chromium renders BOTH sides as a plain
108x108 green box (11,664 green px, byte-identical screenshots).

Our test side already matched that. The whole difference was on the REFERENCE
side, whose sixteen `position:absolute` children include five spelled
`bottom: 0px` — and those five landed in a band flush BELOW the container,
contributing exactly the 2,000 px that were the pair's entire diff.

The cause is that an out-of-flow box contributes no flow rows, so its fill's row
span is DEGENERATE (`bfill_top == bfill_bot`). `_apply_positioned` resolves
`bottom:` on the row grid as `trow = minrow + (cb_bot - bottom/LINE_H -
box_bot)`, and with `box_bot == minrow` the height it subtracts is ZERO: the
box's TOP is pinned where its BOTTOM belongs. It cannot be repaired in rows —
the grid is 12px-quantised and the box's height lives in a pixel pin — and
layout cannot finish it in pixels either, because row pixel heights are not
resolved until the paint pass. So the sum is now split (`bfill_pxbrow` /
`bfill_pxboff`; see layout/box.ad). Test and reference are now byte-identical.

### 2. The `ex` unit was absent from the length table entirely

Not wrong — ABSENT. `_len_apply_unit` has no `ex` case, so the unit fell through
to the px/unitless return WITHOUT advancing the cursor past it, leaving the two
letters in the buffer to derail any enclosing calc(). `calc(1ex + 1ex)` did not
evaluate at all while its reference's `2ex` did. Exactly 8 vendored documents in
the lane use an `ex` length, all checked individually.

### 3. Out-of-flow BORDER painting cannot land — and `border-image` is not what
### unblocks it either

This document records the experiment as costing `PASS 45 -> 40`, and predicts
that `border-image` beside it would repay that. **Both halves are wrong, and the
correction matters more than the experiment.**

The companion is not `border-image`, it is the `transparent`-border fix: the
four `border-image-repeat-space-*` PASSes are `border: 27px solid transparent`
boxes, and what breaks them is the engine painting that transparent border
BLACK. So the two reverted patches were re-landed TOGETHER (out-of-flow border
geometry mirroring `bfill_oof/pxy/pxh` onto the bbox registry, plus
`53d46a26`). The abspos reference of `background-clip-content-box-001` did start
painting its border — 7,040 blue px where it had painted none.

It still does not land, and now there is a reason rather than a number:

    border-image-repeat-space-1/2/3   PASS -> NONDISCRIMINATING
    border-image-repeat-space-7       PASS -> FAIL

**Chromium renders `border-image-repeat-space-1` and its reference as 480,000
white pixels — both sides, completely blank.** With `support/border.png`
unvendored there is no image to draw and the transparent border is invisible, so
the pair is genuinely nondiscriminating on this corpus. Its PASS was banked
entirely on our black frame. And Chromium's `border-image-repeat-space-7` paints
11,340 BLACK px against a blank reference — **Chromium itself fails that pair**
here.

So those four PASSes are ANTI-EVIDENCE: the lane is rewarding the engine for a
bug, and any correct engine loses them. No capability recovers them, because the
asset the tests need is not in the tree. `border-image` would not have helped;
it cannot raster an image that does not exist. Both patches were reverted again
and the tree left at the two clean fixes above — because the alternative is
lowering a floor, and a floor that moves when the engine is right is not a
floor.

### Where the bundle stands

PASS 49 clears 47. **WEAK-PASS 206 does not clear 208 — short by exactly 2.**
The owed set is down from four to three:

| test | blocked on |
|---|---|
| `css-backgrounds/background-clip-content-box-001` | out-of-flow BORDER painting, which costs 4 PASS to the anti-evidence above (49 -> 45, under the floor). Blocked on the LANE, not the engine. |
| `css-backgrounds/background-clip/clip-rounded-corner` | the box-model keystone: the fill rect and the border rect are not the same rectangle (512 px). Measured here: fill x 8..124 y 12..86, border x 10..121 y 12..88, where the box is 140x120. |
| `css-position/hypothetical-dynamic-change-001` | CSSOM `style.left =` triggering re-layout (lib/web/dom, not this scope) |

### The next capability, measured rather than guessed

A near-miss scan (every FAIL pair rendered and ranked by pixel diff) puts the
answer beyond argument. The largest tractable cluster by far is **CSS counters +
generated content**: ~25 pairs in `css/css-lists` sitting at 38-250 diff px,
whose references are as simple as `counter-7-ref.html` printing the number 7.
`_pseudo_is_element` currently reports `::before`/`::after` and returns inert —
"generated content we do not synthesise" — and `counter-reset` /
`counter-increment` / `counter()` appear nowhere in `lib/web/`. That single
capability is worth an order of magnitude more than either remaining blocker,
and unlike them it is not gated on an unvendored asset or on a box-model
rewrite.

Second is `display: contents` (~8 pairs, 220-235 px). The
`background-size/vector` cluster (12 pairs at 248 px) is NOT a candidate: its
SVGs are unvendored too, the same trap as `border.png`.
