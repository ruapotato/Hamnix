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

## Open question, owned by the orchestrator

A pass whose resting render carries no information is arguably a different kind
of pass, and the lane already models one such distinction (WEAK-PASS: "real
work, banked under its own floor, kept out of the headline number"). Whether
blank-at-rest deserves a third class is a ratchet-design decision, to be taken
deliberately rather than discovered again by the next regression. Recorded here
so it is not lost.
