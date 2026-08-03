# Real-use bug report — 2026-07-21 (USER, default -O0 installer image)

Found by actually using the booted desktop. Triaged by the orchestrator.
NOTE: image was default `-O0` (HAMNIX_KERNEL_OPT=0) — NOT the SSA/--opt path, so
these are pre-existing bugs, not opt-cutover regressions.

## Tier 1 — system stability (CRITICAL)
- [x] **#DF hang in `syscall_entry`** — FIXED (main, cli-before-user-RSP @ syscall_64.S; boot-verified)  
  <details>original:</details> — double-fault (vec=8), CPL0 on USER stack,
  rip=0xffffffff805f26f9 = `syscall_entry`+0xa9 (fn @ 0x805f2650). Kernel faults
  while still on the user rsp → syscall-entry stack-switch bug (per-CPU kstack /
  swapgs / %gs base). Trips under heavy syscall load ("while typing a lot"). = the hang.
  → AGENT (kernel).
- [x] **RAM only ever goes UP** (FIXED main: (B) reporting bug — meminfo now counts buddy free pool, not just order-0 list) — closing apps doesn't free memory (mem_gate log:
  free stuck at 1466512 before/after). Either a real kernel leak (task teardown
  not reclaiming pages) OR System Monitor reads wrong. Confirm which.

## Tier 2 — browser (directive: render like Chrome / run most websites)
- [x] **Google** (FIXED main: top-level `this`→global; JS iterator/Object gaps): main search page renders badly; searching → `JS: uncaught
  TypeError: ze is not a function`. JS-engine gap (minified Google JS).
- [x] **Google desktop full-site BLANK** (FIXED main 92db33ea): the whole rendered body was silently dropped. Root cause was NOT a DOM-wipe — desktop google ships ~1.1MB inline JS *before* `<body>`, and `_strip_comments` in `lib/web/dom/bindings.ad` capped source at 256KiB (`CS_CAP`/`RW_CAP`), truncating everything past byte 262144. Raised caps to 4MiB end-to-end (engine + hambrowse read paths) + >256KiB regression fixture. Live google now renders: color logo, app-grid, About/Store, search prompt, Upload/Tools/Create/Canvas/AI-Mode controls. RESIDUAL (open, real-pattern): (a) layout not centered like real google; (b) decimal numeric char-ref `&#127820;` (astral emoji 🎨) not decoded; (c) one image = broken-placeholder.
  - [x] **(a) centering FIXED main 702e3fe8**: real cause was `MAX_RULES=256` — google's `.LS8OJ{justify-items:center}` is rule #833 in a ~1200-rule sheet, silently dropped. Raised rule/selector/pool caps (256→2048 etc), added grid/flex-column `justify-items/align-items:center`→text-align-center mapping, stopped `max-width:100%` pinning intrinsic img width. Logo now centered ~x=510, searchbox centered. VERIFIED on the actual rendered PNG (not just synthetic gates — prior agent's synthetic-only pass was the trap).
  - [x] **(b) `&#127820;` in button labels FIXED main 702e3fe8**: the `<button>` label scan copied raw source bytes; now decodes numeric/named entities. (Decode already worked in the text-dump harness; the paint path needed it too.)
  - **(c) broken image = EXPECTED** (relative-URL logo the offline host render can't fetch; not a bug).
  - **Google fidelity — big buildout 2026-07-22 (main ffa378b6).** From blank → recognizable homepage: centered color logo + tagline, search input fills the bar w/ AI-Mode pill, google-styled submit buttons (centered labels), About/Store top-left w/ gap, app-grid top-right, footer Build-on-top + Advertising-left/Privacy-right. Landed: calc-height %, MAX_RULES 256→2048, bare-N%→auto, inline-SVG width-decline + unsized-viewBox 24px fallback, display:none depth-skip, chip margins, submit-button CSS, AI-Mode fill, button vcenter, flex `order`+wrap-relocate, flex-child hidden-descendant measurement skip, flex-item blockification, **runtime CSSOM insertRule/adoptedStyleSheets/dynamic-style→re-cascade**. OPEN: (a) Gmail/Images STILL hidden — CSSOM works but google's reveal JS throws **`maft is not a function`** (a minified-JS engine gap, NOT CSSOM) before it runs — next google lever is that JS gap; (b) search input paints as thin bar not full-height field (vertical paint); (c) footer Settings wraps (nested popup divs); (d) app-grid ~40px vertical offset (inline-SVG box height); (e) About/Store "o" sub-pixel baseline (font_ttf, not worth the risk). Further google-specific fidelity = chasing minified-JS errors (diminishing ROI).
  - **Multi-site buildout 2026-07-22 (main 6ef6df72):** google + Hacker News + Wikipedia + MDN + BBC + danluu-blog all render. Landed: explicit-table-width (HN `<center><table width=85%>`), landmark-float+dropdown-collapse (Wikipedia article un-buries; refined to `<aside>`-only so MDN/BBC top-`<nav>` bars don't overlap), broken-`<img>` percentage-decline (BBC 44×1184px→40×32 compact), JS `performance`+`document.fonts` (killed google `maft`), `XMLHttpRequest`, CSSOM insertRule/adoptedStyleSheets. **KEY FINDING: external `<link>` CSS is ALREADY fully implemented + working** (`he_css_scan_links`/`_collect_css` engine + `user/hambrowse.ad` http9 fetch + host sibling-`.css` resolve); the `extcss` gate was a STALE-assertion false-fail (x=158→8 + `s0` field), now PASS. So MDN/BBC host-render limits are just **remote-URL CSS not fetchable on the no-network host gfx path** — on-device hambrowse fetches them. Browser is in strong shape; remaining host-render gaps are network-bound (would render correctly on-device) or minor polish (reddit horiz-nav, BBC card-grid — both need the external CSS that works on-device).
  - **NEW residual (open)**: vertical fidelity — google's `calc(100%-560px)` hero heights push the logo/searchbox low + some button overlap bottom-right. Horizontal centering done; `calc()`-based block heights are the next browser gap.
  - **Google fidelity push 2026-07-22** (user driving real render iteration). FIXED: calc()-height % resolves against viewport-height not width (d5e497c); MAX_RULES 256→2048 dropped centering rule #833 (702e3fe8); bare `N%` height → auto not viewport (03b0cc20); inline-SVG `width:100%` resolved vs page not 24px parent → giant blob (aac6a65); display:none skip now depth-tracks nested divs (03b0cc20); top-nav inline-block chip margins threaded into pixel flow — "AboutStore" gap (4cc0176b); submit-button CSS (`#f8f9fa` pill, 8px radius, `#3c4043` label) via `is_btn` cascade-match (831ebc59). OPEN handoffs: (a) **FOOTER needs CSS `order` parsing** (NOT implemented in cascade.ad — google's `@media(max-width:1200px){.ssOUyb{order:0}}` reorders rows) + **flex-child natural-width measurement must include padding** (`_flex_measure_children` measures text only, ignores `.pHiOh{padding:15px}` → groups pack too tight, stack instead of `space-between` bar) + width:100%-wrap two-tier; (b) **nested-flex + flex-grow spacer + justify-content:flex-end** for top-right cluster (app-grid/Gmail/Images position); (c) **Gmail/Images need JS-injected-stylesheet exec** (google injects `.gb_R{display:block}` via CSSOM insertRule at runtime; static CSS only has display:none — proven via CDP); (d) logo perfect-centering (grid justify-items + symmetric padding subtract); (e) search-box internals (agent in flight).
- [x] **DuckDuckGo** (FIXED main: http9 now inflates Content-Encoding: gzip): fetch OK (HTTP 200, 41976 bytes) but renders BLANK white.
  Parse/layout drops the whole doc. HOST-reproducible (curl + hambrowse_gfx).
- [ ] **Networking flaky**: `fetch FAILED rc=-2` / `rc=-6` intermittent; YouTube
  lags then DNS/connect/TLS error. Some fetches succeed (200). DNS/TLS reliability.
  → AGENT (browser real-sites, HOST repro).

## Tier 3 — apps / UX
- [x] **Panel CPU applet = 0%** (FIXED main: shared lib/cpustat.ad reads /dev/stat) while System Monitor shows real CPU. Applet reads
  wrong source / not sampling.
- [x] **Software app** (FIXED main: strip hamnix- display + detect installed via /bin/<cmd>): apps show redundant `hamnix-` prefix; installed/available
  counts wrong (221 all / 23 installed / 198 available — not detecting installed).
- [x] **hamterm** (FIXED main: waitpid reap + Ctrl-D close): `exit` ends the shell prompt but does NOT close the window;
  Ctrl+D also doesn't. Window should close on shell exit ([hamterm] logs
  "shell exited; closing window" in one case but leaves it in the GUI case).
- [x] **Middle-mouse paste** (FIXED: paste hook was gated behind scrollback view): (X11 primary selection): mouse MIDDLE is seen
  (Input Event Inspector shows it) but paste doesn't happen. Ctrl+C/V works.
  → primary-selection buffer not wired to middle-click.
- [x] **Audio** (FIXED: file buffer 320KiB→4MiB; decoder was fine): `hamnix-music-demo.mp3` = "unreadable audio" but test.mp3 +
  test.wav work. Specific MP3 (bitrate/format variant) the decoder chokes on.
  HOST-checkable (run mp3decode on the file).
- [x] **No boot-up sound** (FIXED: jingle hook was in disabled legacy panel; now fires from live desktop) played.
- [x] **Snake (hamgame)**: after a few rounds slows way down AND leaves green
  cells behind the snake (trail not cleared) — perf degradation + stale-cell paint.

## Dispatch waves
- Wave 1 (now): kernel #DF; browser real-sites (Google/DDG/JS/net).
- Wave 2: apps cluster (panel CPU, software counts/prefix, hamterm close);
  audio (mp3 + boot sound); middle-paste; snake; RAM-leak-vs-sysmon.

## CI hygiene
- [x] Foundational `test_hambrowse_host.sh` 15 FAIL→0 (stale snapshot from landed proportional-column + border-model improvements; gate updated to match real Chrome-close output, no engine change).

## Chrome-parity roadmap (measured 2026-07-23, main 94c9c97f — SSIM/brmse vs chromium)
Ranked hambrowse-vs-Chrome gaps by cross-site impact (agent acdff02e):
1. **Text too wide → early wrap → ~2× inflated page height** (TOP impact; every text page; HN SSIM 0.402, titles wrap to 2 lines). Cause: hambrowse glyph-advance metrics (DejaVu Sans) wider than Chrome's default face. Fixing lifts every real-page score. ← NEXT.
2. flex-direction:column blockification — **FIXED 94c9c97f** (flexbox SSIM 0.663→0.729).
3. `font-family: serif`/`monospace` generic-family selection (serif pages render sans).
4. Header/nav table-cell sizing so single-line headers don't wrap (compounds #1).
5. Default vertical rhythm (line-height, heading/paragraph margins).
6. justify-content spacing nuances; flex/block background-bar FILL emission (dispflex/flexnav fails).
Tooling: `chromium` @ /usr/bin (Chrome ref); `framediff_gfx_*` SSIM harness; self-contained inline-CSS pages give clean comparisons.

## Chrome-parity progress (round 2, main 14b39ad7)
CLOSED so far: flex-column blockification (SSIM 0.663→0.729); #1 text-too-wide (DejaVu→Liberation condensed metric, HN 0.427→0.451); list `<li>` vertical margins (danluu blog 0.558→0.648, zero churn — gated on authored margin). Serif empirically ruled out as a big lever (+0.01). Re-ranked remaining gaps:
1. Header/nav `<table>`-cell sizing → single-line headers don't wrap (HN 0.563).
2. MDN-class two-column sidebar/main (0.709 — nav renders as narrow 284px col, main pushed below; grid/flex two-pane collapse).
3. Article-column max-width (Wikipedia hb content 995px vs Chrome 355px).
4. `font-family: serif`/`monospace` generic-family selection (low cross-site impact).

## Chrome-parity progress (round 3, 2026-07-23)
CLOSED: **nested `<table width="100%">` now STRETCHES to fill its parent cell** (the
Hacker News orange nav-bar pattern `<td bgcolor=#ff6600><table width=100%>…`). Before,
a nested width table shrank to its content and stranded the right-aligned `login`, so
`Hacker News new | past | … | submit` wrapped to a 2nd line; now the nav renders on ONE
line like Chrome. Fix: a nested table honours its width attribute, bounded to the parent
cell's right edge (`_compute_cols` stretch no longer gated to `cell_active==0`;
forms.ad `<table>` open reads the width attr for nested tables too). HN brmse 0.133→0.119
(the harness's PRIMARY structural distance improves); SSIM 0.563→0.562 (neutral — the raw
SSIM is confounded by HN's uncorrected vertical row-inflation, below). Non-table pages
(wiki/mdn/blog) byte-identical; wiki/mdn/google spot-checks unchanged. New host gate
`test_hambrowse_nesthdr_host.sh` (fixtures `hambrowse_nesthdr{,_auto}.html`): asserts the
nested width=100% right-cell reaches the viewport edge (632/640) vs an un-sized control
that stays content-width (188) — fails on base (188 both).

ATTEMPTED-BUT-DEFERRED this round (kept OUT to avoid a headline-metric regression):
**auto-column cap → container width** (so a long story title stays on one line instead
of wrapping at the fixed 480px per-column cap). Correct in isolation (clean full-width
table fixture brmse 0.227→0.184, titles single-line) BUT it interacts badly with HN's
`<center><table width=85%>`: the nested story table's now-uncapped natural width exceeds
the outer table's 85% target, so the OUTER table loses its explicit-width clamp and
overflows FULL-WIDTH (dropping the `<center>` gutter Chrome shows), spiking HN brmse
0.119→0.210. Prerequisite for that fix → **clamp an explicit-width table to its target
(wrap wide content at the target, don't let a wide descendant overflow it)**.

Re-ranked remaining gaps (round 4):
1. **HN vertical row-inflation** (NEW top lever; hb 1988px vs Chrome 1430px = 1.39×).
   Root-caused: table cells share the GLOBAL `cur_row`, so a block element inside one
   cell inflates the whole row — the empty `<div class="votearrow">` in HN's votelinks
   cell alone adds ~18px/story (isolated: story block 35px→53px with the div). Chrome
   gives an empty styleless block 0 height. This vertical mismatch dominates the raw
   SSIM (the metric's vertical-stretch normalization amplifies/inverts it), so it must
   land before horizontal table fixes can move SSIM. Fix = independent cell row-flow OR
   collapse empty in-cell blocks — a row-model change, sized as its own round.
2. Explicit-width table target CLAMP (prereq for the auto-column-cap title fix above).
3. MDN two-column sidebar/main (0.709).
4. Article-column max-width (Wikipedia).

## Chrome-parity round 4 (main after 0d9256a8)
CLOSED: HN vertical row-inflation — empty block (`div.votearrow height:10px`) in a `<td>` was adding 2 rows/story via shared `cur_row` (`g_cell_pending` skips the cell's leading soft-newline; empty sub-LINE_H block collapses to 0 rows; both gated to inside-cell so non-table flow byte-identical). **HN page height 2000→1696px (1.39×→1.18× vs Chrome ~1438px)**, isolated repro 233→119px. NOTE: full-frame SSIM harness reads vertical-fidelity gains as WORSE (resize misregistration) — use page-height + side-by-side, not raw resized SSIM, for vertical changes.
Round-5 lever: cell/row content-line height — a single-line cell occupies ~2 quantized LINE_H(16→18px) rows vs Chrome's ~1 text line (17px); investigate per-row leading/`_bump_row` pitch inside cells.

## Chrome-parity round 5 (main after ad8fb29b)
CLOSED (partial — the safe half): the "~2 rows per single-line cell" was NOT per-row pitch — measured a single-line cell is ONE 19px content row (Chrome ~17–22px), tighter than Chrome. The excess was a spurious TRAILING blank paragraph-gap row the `</table>` handler stranded via `_para_break()` after every top-level in-flow table (a `<table>` is a margin-0 block box → no gap). Replaced with `_soft_newline()` (scoped to the table-close path; non-table flow byte-identical). **Isolated single-line-cell table 119→100px; a single-row single-cell table now == a bare `<div>` (62px==62px). HN 1696→1677px.** New host gate `test_hambrowse_cellrowh_host.sh` (single-line cell == bare block height). No-regression: host/realsite/realarticle/tblwidth/nesttable/cellflow/nesthdr/cellempty/lineheight/valign/google all PASS.
Round-6 lever (GLOBAL — deferred per scope discipline, needs sign-off): the DOMINANT residual HN gap (~239px over Chrome's 1438) is **small-font line-height quantisation** — an 8pt subtext line (HN `.subtext`/`.subline`) renders at a full 19px LINE_H row where Chrome uses ~13px. Measured: 5×8pt lines span ~115px in hb vs ~65px in Chrome. This is a row-height-by-font-size change to the LINE_H grid (variable per-row height driven by the row's max font metric), affecting ALL small-font text (table AND prose), so it churns dozens of pixel gates — do NOT blanket-change global LINE_H. Plan: thread the row's max font-px into the htmlpage row-height pass (forms.ad `row_padt`/`row_padb` already carry per-row px), so a row whose content is entirely < base font gets a proportionally shorter height; gate on a small-font fixture + re-baseline shifted gates as Chrome-correct. Secondary: hb IGNORES `<tr height:5px>` spacer rows entirely (under-counts 5px/story) — a minor opposing error to fold in at the same time.

## Chrome-parity round 6 (worktree — LANDED the primary lever)
CLOSED: the small-font line-height quantisation. Root cause was NOT the LINE_H grid but `lib/htmlpage.ad` seeding **every** text row at a fixed `BODY_H=19` floor (`row_h[r]=BODY_H`), so any row whose glyph box is < 19px (all sub-16px text) stayed at 19 while large fonts already exceeded it (h1=38, 22px=25). Fix (`htmlpage_render` pass 1a, guarded): a row whose LARGEST font is < 16px, carries no explicit CSS line-height, and whose true glyph height (new `row_gh`/`row_ga` trackers) is below the body floor takes that glyph height instead. Rows at/above the 16px base, image rows, margin-gap rows and line-height'd rows are byte-identical.
**Measured vs `/usr/bin/chromium` (self-measuring getBoundingClientRect page):**
| font | Chrome | hb BASE | hb FIX |
|------|--------|---------|--------|
| 8pt  | 12 | 19 (+7) | 11 (−1) |
| 10px | 11 | 19 (+8) | 11 (exact) |
| 13px | 15 | 19 (+4) | 15 (exact) |
| 16px | 18 | 19 (+1) | 19 (unchanged) |

Synthetic HN-subtext page: 5×8pt subtext block **95→55px**; 4-line 8pt/10px/13px/16px page **body 76→56px == Chrome's exact 56**. Real fixtures shrank toward Chrome: website 1068→1033, signup 624→609, filter 727→700, filterlist 423→408, boxmodel 603→598, realarticle 1446→1442, uaelems 705→700.
**Blast radius (measured, all fixtures diffed base-vs-fix):** 27 fixtures shift pixel output (only pages with sub-16px text — `<small>`, UA h5/h6, 8-13px CSS). **Gate churn = 0 newly-failing gates:** every geometry gate over a shifted fixture still PASSES (they assert relational/specific-pixel invariants that survive the height change, not absolute page height) — bordercolor, borderside, button, fieldset, flexrowgap, flexwrap, grid, gridspan, iconbtn, pseudocss, wordwrap, filter, filterlist, gfx, host, realarticle, realsite, cellflow, cellrowh, nesttable, valign, lineheight all green. All RED gates (borderradius, border, boxsizing, fidelity, uaelems, website, accentind, boxshadow, abswidth, flexwrap_qa) were proven RED on base too (byte-identical PPM for no-small-font pages; base-swap reproduced the same failure) — pre-existing, not caused here. New gate `test_hambrowse_smallrowh_host.sh` (small-font row strictly shorter than the 16px base; native hambrowse compiles). Fixture `tests/fixtures/hambrowse_smallfont.html`.
**DEFERRED (scoped follow-up):** the secondary opposing error — hb ignores `<tr height:5px>` spacer rows. This is a distinct **engine table-layout** change (not the htmlpage row-height pass), lower value (5px/story) and higher risk (touches table gates), so it was kept OUT of the clean primary landing. Plan: mirror the existing `row_mgap` sub-row-px mechanism (forms.ad ~L2064) — on an empty `<tr>`/cell carrying an explicit `height` < LINE_H, emit ONE spacer row tagged `row_mgap = height px` so the pixel pass draws it at its true small height instead of dropping it.

## Chrome-parity round 7 (worktree — LANDED the primary lever)
Re-measured 2026-07-23 vs `/usr/bin/chromium` at width 1000 (hb canvas caps at 1000×2000). Ranked gaps: **1. Hacker News story titles WRAP to a 2nd line** (top lever — every story doubled in height; hb page 1658px vs Chrome 1438px = 1.15×, SSIM 0.537). 2. Blog/prose list-row vertical rhythm (danluu `<li>` pitch hb ~38px vs Chrome ~32px — flex-`<li>` margin path, SSIM 0.709). 3. MDN responsive mega-menu (hb renders the whole collapsed nav expanded, pushing the article down — a `display`/media-query/CSSOM concern, SSIM 0.720). 4. Wikipedia article-column max-width (SSIM 0.826, already closest). 5. `<tr height:5px>` spacer honoring (deferred r6, minor & OPPOSING — would make HN *taller*).

CLOSED: **#1 — the story-title wrap.** Root cause was NOT the font metric or the explicit-width stretch; the real HN story list is an **auto-width `<table>` (no width attr)**, and `_compute_cols` clamped every column at a fixed **60-char (480px) cap** ("stop a runaway column"). A ~90-char headline therefore wrapped even though its container was ~850px wide. Chrome sizes an auto column to its content bounded only by the container. Fix (`lib/web/layout/tables.ad` `_compute_cols`): replace the hard `60` cap with `colcap = avail / CELL_W` **floored at the old 60**, so a column NEVER shrinks below its previous width and only a >60-char column in a >480px container grows; the existing `bounded` rule still clamps the grid to the container right edge (no overflow — the round-3 regression prerequisite). The proportional free-space rule already pours most surplus into the now-wider text column, so a separate "flex-only distribution" experiment proved **redundant** and was dropped (byte-identical result, smaller diff).
**Measured (page height vs Chrome 1438):** HN **1658 → 1335px** (1.15× → 0.93×), every title on ONE line, story rows now align ~row-for-row with Chrome (see side-by-side). Synthetic HN fixture (long title in a wide table): page **138 → 119px** (2 rows → 1). Full-frame SSIM reads 0.537 → 0.493 — the **documented vertical-misregistration confound** (a shorter, more-correct page mis-registers against Chrome's taller frame); page-height + side-by-side are the honest signal for this vertical change, per the round-4 note.
**Blast radius (measured, ALL 221 fixtures diffed base-vs-fix at the 640px gate width):** **0 existing fixtures change** — the fix only engages for a table column > 60 chars in a container > 480px, which no committed fixture at 640px hits. **Gate churn = 0.** All required gates PASS: tblcolcap(new), tblwidth, nesthdr, nesttable, cellflow, cellrowh, smallrowh, host, google, realsite, realarticle. Pre-existing RED gates (infobox, website) proven **byte-identical base-vs-fix** (PPM `cmp`) — untouched. New gate `test_hambrowse_tblcolcap_host.sh` (fixture `hambrowse_tblcolcap.html`): a long title fits ONE line in a wide table (page 62px) yet still wraps in a narrow one (480px → 81px, proving the cap tracks the container); native hambrowse compiles.

Re-ranked remaining gaps (round 8):
1. **Blog/prose list-row vertical rhythm** — danluu `<li>{display:flex;margin:0 0 .9em}` pitch hb ~38px vs Chrome ~32px (~6px/row over ~200 rows). Flex-`<li>` content-row + margin path; general prose lever.
2. **HN residual** — narrow rank/vote columns still a touch wider than Chrome (title starts ~150 vs ~100px); and the inline sitebit `(domain)` sits with extra whitespace before it rather than tight after the title.
3. **MDN responsive mega-menu collapse** — the desktop nav is a click-dropdown Chrome hides; hb renders it fully expanded (needs media-query `display:none` / CSSOM). Big MDN-class lever but complex.
4. Wikipedia article-column max-width (SSIM 0.826).
5. `<tr height:5px>` spacer honoring (still deferred; opposing sign to any height fix).

## Chrome-parity round 8 (worktree — LANDED the primary lever)
Re-measured 2026-07-23 vs `/usr/bin/chromium` at width 1000. Ranked gaps confirmed:
**1. Blog/prose list-row vertical rhythm** (top general lever; danluu index, SSIM
0.709, hb item pitch **38px vs Chrome 32px**). 2. HN residual (page confounded by the
round-7 vertical shortening; SSIM 0.493). 3. MDN mega-menu (0.720). 4. Wikipedia
max-width (0.826).

CLOSED: **#1 — list-item sub-row margin PIXEL height.** Root cause was NOT flexbox:
a block `<li>` and a `display:flex` `<li>` measured **identically** (both 38px). The
gap is entirely the **authored bottom margin**. `li{margin:0 0 .9em}` = 14.4px
quantises to exactly ONE blank grid row, and hambrowse drew that lone gap row at the
full `BODY_H` (~19px) body line pitch — so every item ran 19(content)+19(gap)=38px
instead of Chrome's 19+14≈32. The `<li>` inter-item-margin path (`lib/web/dom/forms.ad`)
emitted the gap via `_emit_vgap` but never tagged its px. Fix: tag the lone emitted gap
row with its REAL px via `row_mgap` — the *identical* mechanism the heading
margin-bottom already uses (the `lib/htmlpage.ad` per-row pass then draws `mg` px when
`mg < BODY_H` instead of a full body row). Guarded to fire only when the emit ran with
the previous item's row still dirty (the common single-line item) and the gap rounds to
one row.
**Measured:** danluu index item pitch **38 → 33px** (Chrome 32 — within 3%, was 19%
over); synthetic 6-item `li{margin:.9em}` list pitch 38 → 33. Full-frame blog SSIM reads
0.709 → 0.699 — the **documented vertical-misregistration confound** (a denser, more
Chrome-correct page mis-registers against Chrome's frame); item pitch + side-by-side are
the honest signal, per the round-4 note.
**Blast radius (all 222 fixtures diffed base-vs-fix at the 640px gate width):** **0
fixtures change** — the path fires only for a sub-`BODY_H` `li` margin that rounds to one
row, which no committed 640px fixture hits. **Gate churn = 0.** HN / MDN / Wikipedia real
pages **byte-identical** (HN's story list is a `<table>`, not an `li` list; the others
carry no sub-row li margin). All required gates PASS: host, google, realsite,
realarticle, tblwidth, tblcolcap, nesttable, nesthdr, cellflow, cellrowh, smallrowh,
limargin, navgap. New gate `test_hambrowse_limarginpx_host.sh` (fixture
`hambrowse_limargin_px.html`): the 4 inter-item gap rows of a 5-item `li{margin:.9em}`
list are drawn at 14px while a `margin:0` control adds no short row (base: all 12 rows a
flat 19px → FAIL). Native hambrowse compiles.

Re-ranked remaining gaps (round 9):
1. **HN residual** — narrow rank/vote columns still a touch wider than Chrome (title
   starts ~150 vs ~100px); inline sitebit `(domain)` carries extra leading whitespace
   rather than sitting tight after the title.
2. **MDN responsive mega-menu collapse** — desktop nav is a click-dropdown Chrome hides;
   hb renders it fully expanded (needs media-query `display:none` / CSSOM). Big MDN-class
   lever but complex.
3. Wikipedia article-column max-width (SSIM 0.826, closest).
4. Prose paragraph rhythm / heading margins on long-form articles (next general lever
   after list rhythm).
5. `<tr height:5px>` spacer honoring (still deferred; opposing sign to any height fix).

## Chrome-parity progress (rounds 9–11 + heading colour, main 8cf14fd7)
CLOSED, each measured vs `/usr/bin/chromium`, orchestrator-verified 0-newly-failing:
- **Round 9 (77374a7c): prose paragraph rhythm** — `<p>`/`<figure>` inter-paragraph gap
  was drawn at the full ~19px BODY_H row; now tagged at the real UA 16px via `row_mgap`
  (`g_para_mgap`). p→p gap 19→**16px (exact Chrome)**; paragraph pitch 38→35 (Chrome 34).
  Margin collapse preserved (a `</p><h2>` boundary keeps the taller heading margin).
- **Round 10 (33d54238): grid/flex inter-row gap over-height** — a `display:grid;gap:16px`
  of padded/bordered cards stranded a phantom LINE_H row between grid rows (`_flex_item_close`
  measured the row bottom from `cur_row`, overshooting the item border-box). Now measured
  from the item's own outer box. Inter-card-row gap 37→**18px** (Chrome 16); SSIM 0.745→0.814.
  ALSO: **disproved the ranked-#1 Wikipedia article-max-width lever** — the saved fixture's
  container max-width lives in external CSS the offline harness can't fetch, so offline Chrome
  also renders full-width; narrowing hb would DIVERGE from the reference. Dropped from roadmap.
- **Round 11 (0abcbf41): borderless-box vertical padding baked at real px** — bordered
  cards/cells were already within 0–4px (rounds 4–10 via `bbox_padv`); the residual ~10–15%
  over-height was plain BORDERLESS padded bands (padding quantised to whole LINE_H rows, fill
  only covering the content row). Extended the real-px padding bbox to borderless blocks+floats
  (no-stroke kind-3 bbox; flex/grid items excluded — they inset via `cur_row` rewind). Fill
  height now within **2px of Chrome** across 4/8/10/12/16px padding. 9/225 fixtures shift, all
  improvements.
- **Heading colour (8cf14fd7): UA-default h1–h6 = body black `#101010`, not `#14306e` blue.**
  USER flagged the Wikipedia render's blue headings as the last major visible diff vs Chrome.
  Chrome's UA stylesheet gives headings no colour (inherit black); hambrowse hardcoded a
  "heading dark blue" in the role palette (`_palette`/`_palette_rgb` idx 2). Set to body text.
  Explicit author `color:` still wins via the cascade (impliedtags fixture's `h2{color:#14306e}`
  unchanged). Gates: host (h1/h2/h4/h5/h6 UA-default assertions → #101010), impliedtags,
  headmargin, google, realsite, realarticle all PASS. Wiki render confirmed black headings.

### Ranked roadmap for round 12+ (in flight: round 12 = HN residual, agent aa4cd81c)
1. **HN residual column geometry** — rank/vote column wider than Chrome (title starts ~150 vs
   ~100px); inline sitebit `(domain)` extra leading whitespace. General table-column lever.
2. **MDN responsive mega-menu collapse** — desktop nav is a click-dropdown Chrome hides; hb
   renders it expanded (media-query `display:none` / CSSOM). Big MDN lever, complex.
3. **Global 1px-per-line line-box over-height** (row pitch 19 vs Chrome ~18.4) — now the
   dominant residual on every multi-line box; HIGH reach but HIGH risk (the BODY_H/LINE_H
   quantisation sticky + grid-auto-rows invariants depend on; needs a per-row variable-pitch
   pass, not a global floor change).
4. `font-family: serif`/`monospace` generic-family selection (low cross-site impact).

## Chrome-parity progress (round 12, main 91080d11)
CLOSED: **`cellpadding="0"` / `cellspacing="0"` honoring** (the HN/forum/aggregator
presentational-table pattern). hambrowse ignored the attribute — every column carried a
fixed 16px CELL_PAD + 6px CELL_PADX and empty cells floored to 24px, so HN's rank +
empty-votelinks columns pushed each story title far right. Now `<table>` open parses
`cellpadding` (new `g_tbl_cpad`/`g_tbl_padx` + stack slots), the column model uses it, and
empty cells collapse when cpad=0. Measured vs chromium (no news.css): full HN page
rank→title **72px → 32px** (Chrome 26); isolated row **56px → 16px** (Chrome 12); empty
votelinks column collapses; page height unchanged (horizontal fix). Churn: exactly 9
fixtures shift (the cellpadding=0 ones), 224 byte-identical, 17/17 required gates PASS. New
gate `test_hambrowse_cellpad0_host.sh` (base title x0=66 FAIL / fix x0=26 PASS, cpad=8
control stays 66). Sitebit `(domain)` leading-whitespace gap 2 measured 16 vs Chrome ~9px —
inline flow, the DejaVu space+`(` glyph advance (font-metric lever), NOT a padding bug.

### Ranked roadmap for round 13+ (in flight: round 13 = HN centering gutter)
1. **HN `<center><table width=85%>` centering gutter** — Chrome indents the whole table
   ~75px (85% of 1000, centered); hambrowse gives ~8px (rank@8 vs Chrome@90). General
   `<center>`/`margin:auto` gutter lever for legacy centered-layout sites.
2. **MDN responsive mega-menu collapse** — media-query `display:none` / CSSOM.
3. **Sitebit / inline space-glyph width** (space+`(` 16px vs Chrome ~9px) — the DejaVu-wide
   space advance; ties into the general font-metric lever affecting all prose.
4. Wikipedia article-column max-width (SSIM 0.826, closest).

## Chrome-parity progress (round 13, main 8e92c4ad)
Measure-first FINDING: the assigned target (HN `<center><table width=85%>` gutter) was
ALREADY working on main (commits 7783e76a/5815a119, pre-round-12) — a `<center>`ed 85% table
already centers with ~75px gutters matching Chrome. The round-13 roadmap entry was STALE.
CLOSED instead (adjacent self-centering idioms that were genuinely broken): **`<table style="margin:0 auto">` and `<table align="center">` now center themselves** (previously
hugged left at x0=35). New `g_tbl_center` (tables.ad) set from `m_center`/`d_center`
(margin-auto cascade+inline) or the `align="center"` attr (forms.ad); `_compute_cols`
centers when top-level and `span_w < avail` (so full-width tables never offset; floated
tables exempt). Measured @1000px: margin:auto 85% table x0 35→**109** (Chrome 100);
align=center likewise; plain table x0=35 unchanged; width:100%+margin:auto still fills
10→998. Churn: of 228 fixtures ONLY the new `hambrowse_tblcenter` shifts, 227 byte-identical,
0 newly-failing (tblwidth/tblcolcap full-width fill verified intact). New gate
`test_hambrowse_tblcenter_host.sh`.

### Ranked roadmap for round 14+
1. **MDN responsive mega-menu collapse** — desktop nav is a click-dropdown Chrome hides; hb
   renders it expanded, pushing the article down (media-query `display:none` / CSSOM). Biggest
   remaining MDN-class lever, complex.
2. **Sitebit / inline space-glyph width** (space+`(` ~16px vs Chrome ~9px) — the DejaVu-wide
   space advance; general font-metric lever affecting all prose. Needs a hambrowse-side advance
   override (`lib/font_ttf.ad` is DE-shared / off-limits).
3. **Global 1px-per-line line-box over-height** (row pitch 19 vs Chrome ~18.4) — dominant
   residual on every multi-line box; HIGH reach, HIGH risk (BODY_H/LINE_H quantization +
   grid-auto-rows invariants; needs a per-row variable-pitch pass).
4. `font-family: serif`/`monospace` generic-family selection (low cross-site impact).

## Chrome-parity progress (round 14, main 911815f8)
Measure-first FINDING: the assigned target (`@media` `display:none` collapse) was ALREADY
working — `lib/web/css/cascade.ad` has a full CSS Media Queries L4 subset (`_media_matches`/
`_mq_query`/`_mq_feature`: min/max-width+height, orientation, prefers-color-scheme, and/comma/
not/only) threaded to the LIVE viewport (`bw`×`bh`); `_parse_at_rule` recurses matching `@media`,
skips non-matching. Verified both directions (desktop nav @1000px, mobile @640px). Roadmap
entry was stale. CLOSED instead the genuine narrower gap: **the `media` ATTRIBUTE on a
`<style media="(max-width:799px)">` element was ignored** — `_collect_css` never read `media=`,
so a responsive `<style media>` block cascaded unconditionally (hiding a desktop nav even wide).
Fix (~8 lines): `_collect_css` reads the `media` attr via `_hx_find_attr` and gates the block
through the same `_media_matches` (live viewport); non-matching skipped, matching applies,
no-media/`all` unchanged. Measured (`hambrowse_stylemedia.html`): wide 1000px article-start-y
78→**135px** (desktop nav restored); narrow 640px collapses correctly. Churn: of 229 fixtures
ONLY the new `hambrowse_stylemedia` shifts (228 byte-identical), 0 newly-failing, all required +
media/matchmedia/stylemedia PASS. New gate `test_hambrowse_stylemedia_host.sh`.

### Ranked roadmap for round 15+
1. **Sitebit / inline space-glyph width** (space+`(` ~16px vs Chrome ~9px) — the DejaVu-wide
   space advance; general font-metric lever affecting ALL prose horizontal spacing. Needs a
   hambrowse-side advance override (`lib/font_ttf.ad` is DE-shared / off-limits). Moderate churn
   risk — gate carefully.
2. **`<link media="…">` external-sheet gating** — the external-stylesheet sibling of round 14's
   `<style media>` fix; a fetched `<link media>` sheet is not yet media-gated. Lower host-
   testability (external fetch is on-device); gate via a synthetic `he_css_append`-with-media
   harness.
3. **Global 1px-per-line line-box over-height** (row pitch 19 vs Chrome ~18.4) — dominant
   residual on every multi-line box; HIGH reach, HIGH risk (BODY_H/LINE_H quantization +
   grid-auto-rows invariants; needs a per-row variable-pitch pass).
4. `font-family: serif`/`monospace` generic-family selection (low cross-site impact).

## Chrome-parity progress (round 15, main d73f4593)
Measure-first FINDING: the assigned target ("DejaVu space glyph too wide in all prose") was
STALE — the isolated proportional space is already Chrome-correct (`"a a"−"aa"`=4px hb vs
Chrome 4.5px; hb actually narrower). CLOSED the real gap: **table-cell inline runs fell back
to the 8px CELL_W monospace grid** — `_run_px`/`_space_px` (box.ad) used the monospace grid
whenever `table_active`, while the pixel paint drew the narrower proportional advances, so
layout reserved 8px/char but paint drew fewer → a phantom gap before every following inline
segment (the round-12 HN sitebit `(domain)` over-spacing). Fix: drop the `table_active` guard
so table-cell inline runs route through the same proportional measure hook the paint uses
(matches the already-proportional `tables.ad` `_adv8`/`_measure_table` column model); the
`he_meas_set==0` fallback keeps SEG-dump/text harnesses byte-identical. Measured: in-cell
inter-word space **25px → 5px** (Chrome ~4.5); sitebit `(github.com)` run x 292→268 (Chrome
~260; residual ~8px is the separate non-space 877-hscale glyph metric). Churn: of 229 fixtures
only 3 shift (span, tblcenter, tblcolcap — all multi-word cells wrapping less = Chrome-correct),
0 newly-failing. New gate `test_hambrowse_wordspace_host.sh`. DE-UNCHANGED verified: font_ttf.ad
untouched + no DE binary imports lib/web (grep-confirmed by orchestrator) → cannot reach the DE.

### Ranked roadmap for round 16+
1. **Non-space glyph advance residual** — the ~8px sitebit offset from the accumulated 877-hscale
   DejaVu→Liberation approximation (~0.25px/char, compounds on long lines). A hambrowse-side
   per-glyph advance refinement (NOT font_ttf, DE-shared) would close it.
2. **Global 1px-per-line line-box over-height** (row pitch 19 vs Chrome ~18.4) — dominant
   VERTICAL residual on every multi-line box; HIGH reach, HIGH risk (BODY_H/LINE_H quantization +
   grid-auto-rows invariants; needs a per-row variable-pitch pass).
3. **`<link media="…">` external-sheet gating** — fetched-stylesheet sibling of round-14's
   `<style media>` fix; on-device fetch, synthetic gate needed.
4. `font-family: serif`/`monospace` generic-family selection (low cross-site impact).

## Chrome-parity progress (round 16, main 994c42fb)
CLOSED: **per-glyph Liberation Sans advance override** (new `lib/web/font_adv.ad`, 254 lines:
sans+bold per-glyph advances cp 32-126 in 2048-upm units). font_ttf approximates
DejaVu→Liberation with ONE per-face scale (877/1000), but the true per-GLYPH advances differ
from a uniform 0.877× — caps runs too narrow, thin/punctuation too wide, error compounding
over a line. `lib/htmlpaint.ad` measure AND paint now consult the override (fall back to
font_ttf when it returns -1), so measure==paint (no phantom gaps). Measured long-run end-x vs
chromium: 43-char CAPS 386→**432** (Chrome ~433); narrow i/l/1/. 183→164 (Chrome 160); wide
W/M/G/O 451→480 (Chrome 487). **Mean |error| across 6 diverse strings 19px → 4.5px; worst
47px → ≤9px.** HIGH-churn (advance changes every sans line): 223/230 fixtures shift, but
**0 newly-failing** — 25 red-after gates all proven base-red (identical fail on base), new
`glyphadv` gate base-FAIL/fix-PASS, all required + text/wrap PASS (host, google, realsite,
realarticle, tblwidth, tblcolcap, nesthdr, cellflow, cellrowh, smallrowh, wordspace, wordwrap,
textindent, whitespace, reflow, limargin, lineheight). DE-UNCHANGED verified: font_ttf.ad
untouched + no DE binary imports font_adv/htmlpaint/lib.web (orchestrator grep-confirmed).

### Ranked roadmap for round 17+
1. **Body-text subpixel advance** — the per-glyph INTEGER override leaves ±3-9px residual on
   long runs from per-glyph rounding; lowering `FU_ADV_MIN_PX` (20) so 16px body uses
   fu-accumulation with this table cuts it to ~1px, but re-rounds every body line (broad churn);
   its own gated round.
2. **Global 1px-per-line line-box over-height** (row pitch 19 vs Chrome ~18.4) — dominant
   VERTICAL residual on every multi-line box; HIGH reach/HIGH risk (per-row variable-pitch pass).
3. **`<link media="…">` external-sheet gating** — fetched-stylesheet sibling of round-14's
   `<style media>` fix.
4. `font-family: serif`/`monospace` generic-family selection (would let serif/mono get their own
   advance metrics too).

## Chrome-parity progress (round 17, worktree — LANDED the global vertical lever)
CLOSED: **the global 1px-per-line line-box over-height** (the roadmap's dominant remaining
VERTICAL residual). Root cause: `lib/htmlpage.ad` seeded every 16px body content row from the
font's GLYPH BOUNDING box (`htmlpaint_ttf_height` = ascent+descent = 19px), but Chrome lays a
`line-height:normal` 16px sans line out at ~1.15em = **18px** — so hb added ~1px PER LINE,
compounding down every multi-line block. Measured vs `/usr/bin/chromium`: a 20-line 16px
paragraph is **360px in Chrome (18px/line) vs hb's 380 (19px/line)**.

**Fix (surgical, invariant-preserving):**
- `BODY_H` 19→18 (the blank/gap-row floor) so blank rows match content rows.
- New **pass 1a2** (line-height:normal cap): a row with NO explicit CSS line-height whose height
  came SOLELY from its own text glyphs (`row_h == row_gh`, so no image/taller box) and whose font
  is ≥16px is clamped to `round(px*1.15) = (px*23+10)/20`, but NEVER grown (`min`). This matches
  Chrome's line-height:normal EXACTLY (measured: 16→18, 32→37; 18/21/24 already equal the glyph
  box → byte-identical). Guarded to px≥16 so the sub-16 rows the round-6 small-font pass (1a)
  already Chrome-matches via the glyph box (8→9, 10→11, 13→15) are untouched.

**Why the sticky / grid-auto-rows invariants survive (the #1 risk):** sticky (`lib/web/layout/
flow.ad`) and grid-auto-rows compute integer ENGINE row indices (`pos_t/LINE_H`, LINE_H=16, a
SEPARATE unit htmlpage never changes); htmlpage only maps row-index→pixel FORWARD. The old sticky
bug was NON-UNIFORMITY (a 16px blank row beside 19px content rows). This change keeps blank rows
AND 16px content rows UNIFORM at 18, so the row grid stays consistent. PROVEN: **sticky, grid,
gridautorows, gridrowgap, valign, cellrowh gates all PASS** (they encode exactly those
row-grid/relative invariants).

**Measured (page/block height vs Chrome):** 10-line 16px block **190→180px (Chrome 180, exact)**;
20-line **380→360 (Chrome 360, exact)**; per-size row heights now 16→18 and 32→37 (Chrome-exact),
all other sizes byte-identical.

**Blast radius / gate churn (base vs fix binaries, ALL 231 fixtures diffed @640px):** all 231
fixture PPMs shift (every page has 16px body text → a uniform 1px/row vertical compaction) — but
gate churn is contained because only **5 gates structurally parse the pixel `ROW top h` dump with
absolute-height assertions**: `smallrowh`, `pmargin`, `limarginpx`, `lineheight` (all re-baselined
19→18, a Chrome-PROVEN correction — 16px body IS 18px in Chrome) + the NEW `linebox` gate
(base-FAIL @19px/line, fix-PASS @18). EVERY other gate uses the engine-grid SEG dump (row indices
/ x-positions) or relative geometry, which a pixel-height-only change cannot move — confirmed by
the full battery: **0 newly-failing gates**; all reds (abswidth, accentind, …) proven base-red
(identical fail on the base binary, unrelated pre-existing failures). New gate
`test_hambrowse_linebox_host.sh` + fixture `hambrowse_linebox.html`; native hambrowse compiles.

## Chrome-parity progress (round 18, worktree — LANDED the body-subpixel-advance lever)
CLOSED: **body-text subpixel advance accumulation** (the roadmap's #1 remaining HORIZONTAL
residual). Round 16 gave hb an accurate per-glyph Liberation advance table (`lib/web/font_adv.ad`)
but 16px BODY text still summed those advances as per-glyph INTEGER px (`FU_ADV_MIN_PX=20`, above
body size), so a long line drifted up to N*0.5px from Chrome by accumulating per-glyph rounding.
Fix = lower the crossover to **16** (`lib/htmlpaint.ad`, one constant + comment) so 16px body
accumulates in FONT UNITS and rounds the running pen ONCE — the fu path already used for headings.

**MEASURE-FIRST finding (vs `/usr/bin/chromium` at 16px, getBoundingClientRect):** Chrome's
rendered run width == its subpixel `measureText` (bcr==measureText to ~0.01px) — Chrome does NOT
grid-hint each body glyph advance to an integer. The old round-16 comment claiming "Chrome hints
body to integer" predated the per-glyph table and was measured against the uniform 877 face scale;
with the real per-glyph table (which IS Chrome's measureText), subpixel accumulation is the faithful
body model. **Measured 9 diverse 40-60char 16px lines: mean |advance err| 2.28px → 1.56px** (~32%);
worst 4.5px → 2.98px. Residual is font_adv table precision (~2px on some lines, model-independent —
lines where per-glyph rounding drift is ~0 don't move), NOT the accumulation model. Two example
lines drift in OPPOSITE directions under the integer model (base 435<Chrome 438; base 470>Chrome
468) and BOTH centre on Chrome ±1 with fu accumulation.

**Blast radius / gate churn (base FU=20 vs fix FU=16 binaries, ALL 232 fixtures diffed @640px):**
210/232 fixtures shift (every page with 16px body text re-rounds — broad, as predicted, like round
16). **Gate churn = 0 newly-failing.** Ran the full 166-gate host battery on fix + the 25 required
gates (host, google, realsite, realarticle, tblwidth, tblcolcap, nesthdr, cellflow, cellrowh,
smallrowh, wordspace, wordwrap, glyphadv, textindent, whitespace, reflow, linebox, limargin,
lineheight, sticky, grid, pmargin, limarginpx, valign, navgap) — all PASS. 144 PASS / 22 FAIL on
fix; **all 22 FAILs PROVEN base-red** (identical FAIL rebuilt at FU=20): abswidth, accentind, border,
borderradius, boxr2, boxshadow, boxsizing, calc, checkradio, decimlen, dispflex, fidelity, flexnav,
flexwrap_qa, gencontent, gridr2, http_features (on-device/QEMU — environmental), infobox, landing,
sdl (SDL env), uaelems, website — the documented pre-existing reds + environmental gates, none
caused here. NO wrap/reflow regressions (reflow/wordwrap/wordspace/textindent/whitespace all PASS).
New gate `test_hambrowse_subadv_host.sh` (fixture `hambrowse_subadv.html`): two 16px nowrap lines,
base FU=20 fails both windows on opposite sides, fix FU=16 PASSes; native hambrowse compiles.
**DE-UNCHANGED:** `lib/font_ttf.ad` UNTOUCHED (only `lib/htmlpaint.ad` constant changed; font_adv.ad
untouched); no DE binary (hamde/hamUI/hampanel/hamdesktop/hamterm) imports htmlpaint/htmlpage/
font_adv/lib.web — grep-confirmed — so the change reaches only the browser-family binaries.

### Ranked roadmap for round 19+
1. **font_adv per-glyph table precision** — the residual ~2px on some 16px lines is now the
   accumulation-model-INDEPENDENT floor: the round-16 Liberation advance table (measured via canvas
   `measureText`, run/50) is ~0.03-0.05px/glyph off Chrome on some lowercase/mixed runs, compounding
   to ~2-3px on 50-60char lines. Re-measure the table at higher precision (longer sample runs, or
   direct hmtx from a Liberation .ttf) to push the mean |err| below ~1px. Low risk (data-only,
   same measure==paint path), but broad churn (re-rounds every sans line again).
2. **`<link media="…">` external-sheet gating** — fetched-stylesheet sibling of round-14's
   `<style media>` fix (on-device fetch; synthetic gate needed).
3. **h1/32px line-box + heading vertical rhythm** — round 17 fixed 32px→37 pitch; the residual
   heading margin/leading rhythm (h1/h2 top+bottom margins vs Chrome) is the next vertical lever.
4. `font-family: serif`/`monospace` generic-family selection (would let serif/mono get their own
   advance + line metrics).

## Chrome-parity progress (round 18, main ed3e58c0)
CLOSED: **body-text subpixel advance** — `FU_ADV_MIN_PX` 20→16 (lib/htmlpaint.ad) so 16px body
text accumulates the round-16 per-glyph Liberation table in FONT UNITS (pen rounded once) instead
of summing per-glyph INTEGER advances. Measure-first correction: Chrome's rendered run width ==
its subpixel `measureText` (bcr==measureText) — Chrome does NOT grid-hint body advances, so
subpixel accumulation is the faithful model (the old round-16 "Chrome hints to integer" note
predated the per-glyph table). Measured (9 diverse 40-60char 16px lines): mean |advance err|
**2.28px → 1.56px** (~32%); worst 4.53→2.98. Lines that drifted opposite directions under the
integer model both centre on Chrome ±1. Churn: 210/232 fixtures shift (every 16px line re-rounds),
0 newly-failing (166-gate battery: 144 PASS, 22 FAIL all proven base-red at FU=20; required +
text/wrap/row-grid incl. wordwrap/reflow/wordspace/textindent all PASS). New gate
`test_hambrowse_subadv_host.sh`. DE-unchanged (htmlpaint-only; no DE binary imports it).
Residual ~2px is the font_adv TABLE PRECISION floor (model-independent) → round 19.

### Ranked roadmap for round 19+ (browser PAUSED here at sub-2px accuracy; DE-under-LLVM is the active priority)
1. **font_adv per-glyph table precision** — the ~2px residual is now the accumulation-independent
   floor; re-measure Liberation advances at higher precision (longer sample runs / direct hmtx) to
   push mean |err| below ~1px.
2. **`<link media="…">` external-sheet gating** — fetched-stylesheet sibling of round-14's `<style media>`.
3. **Heading vertical rhythm** — em-based h1-h6 top/bottom margins.
4. `font-family: serif`/`monospace` generic-family metrics.

## Chrome-parity progress (round 19 — DIMINISHING-RETURNS readout, docs-only, no code change)
MEASURE-FIRST re-audit of the assigned #1 lever (**font_adv per-glyph table precision**). Three
independent measurements — all on this host's `/usr/bin/chromium` and the Liberation TTFs —
**disprove the round-18 hypothesis** that the ~1.56px residual is table imprecision. The table is
already at the precision floor; the true residual is **kerning**, a different (and out-of-scope)
lever. **No `font_adv.ad`/htmlpaint change landed** — per the round-15..18 discipline, an honest
diminishing-returns readout is the correct outcome here.

**Measurement 1 — direct hmtx cross-check (fontTools on the actual `LiberationSans-Regular.ttf` /
`-Bold.ttf`, upm 2048):** the committed table matches the font's raw `hmtx` advance for 92/95 sans
and 94/95 bold cells. The 3 that differ are `'1'` (table 990 vs hmtx **1139**), `'f'` (533 vs 569),
bold `'1'` (1028 vs **1139**). **KEY FINDING that forecloses the roadmap's "read hmtx directly"
idea:** Chrome does NOT render Liberation's raw hmtx for these — Chrome's `measureText` for `'1'` at
16px is **7.717px = 988fu**, NOT the tabular hmtx 1139. So the table (measured from Chrome, not the
font) is CORRECT and reading hmtx would REGRESS `'1'` by +9px per glyph. `fc-match sans-serif` here
is DejaVu, `Arial`→Liberation; but `measureText("16px sans-serif")==("16px Arial")==("16px
Liberation Sans")` for every ASCII cp — Chrome resolves all three to the same face, so Chrome's
`measureText` is the sole ground truth (as round 16 already used).

**Measurement 2 — higher-precision table re-measure (run/200 vs round-16's run/50):** re-measured
Chrome `measureText` for cp32..126 at 16px. Vs the committed table the **mean |per-glyph err| is
0.04fu sans / 0.02fu bold ≈ 0.0003px**, **max 2.2fu = 0.017px** (the `'1'` cell). Only 3 cells would
round differently — `'1'` 990→988, `'f'` 533→532, bold `'1'` 1028→1027 — each a **sub-0.02px**
nudge. Applying them re-rounds every sans line containing `'1'`/`'f'` (broad fixture churn) for an
un-measurable ≤0.02px/glyph gain → **not worth the churn** (the directive's explicit STOP condition).

**Measurement 3 — real hb-vs-Chrome line residual, and its TRUE source (15 diverse 40-60char 16px
lines, hb `dumpops` end-x vs Chrome):** the pure advance model (sum the committed table fu, no
kerning) already has **mean |err| = 0.582px** vs Chrome `measureText` — **already below the 1px
target.** The residual is dominated by ONE effect: **hambrowse does not apply kerning.** Proven:
`measureText` (and rendered `getBoundingClientRect`, which equals it) applies kern pairs — AV −1.19px,
To/Te −1.77, Yo −1.47, WATTAGE −2.97 — while hb sums per-glyph advances flat. The table matches
Chrome's per-glyph `measureText` EXACTLY (0 cells >0.6fu off), but the per-glyph SUM exceeds Chrome's
whole-line `measureText` by the kern total: worst line "WWMM…KANGAROO WATTAGE" **+3.26px**,
"Association of Widely Available…" +0.90px, plain prose ≈0 (mean missing-kern over-width −0.023px,
range [−1.44,+3.26]). **A kern-pair subset would cut mean |err| 0.58→~0.26px (pure rounding floor)
and worst-case ~3.3px→~0.**

**Conclusion:** the per-glyph advance table is OPTIMAL at integer-fu resolution (≤0.017px/glyph vs
Chrome; mean line advance err 0.58px < 1px target). Further table precision is un-measurable and
not worth the broad re-round churn. DE-UNCHANGED is trivially satisfied — **no file changed except
this doc** (`font_adv.ad`/`font_ttf.ad`/`htmlpaint.ad` all byte-identical; no engine/gate touched).

### Ranked roadmap for round 20+
1. **Kerning (pair adjustment)** — the now-quantified real #1 horizontal lever. Chrome's rendered
   text applies Liberation/Arial kern pairs (AV, To, WA, Ta, Ya, …); hb sums flat advances, running
   up to ~3px wide on caps/pairs-heavy lines and ~0.9px on mixed prose. A hambrowse-side kern-pair
   subtraction (a small pair→delta table alongside `font_adv.ad`, applied once in the
   `lib/htmlpaint.ad` fu-accumulation path — same measure==paint discipline) would drop mean advance
   |err| 0.58→~0.26px and kill the caps worst-case. Higher churn/wrap-regression risk than a data
   table → gate carefully (fixtures with/without kern pairs; prove wrap changes Chrome-correct).
2. **`<link media="…">` external-sheet gating** — fetched-stylesheet sibling of round-14's `<style media>`.
3. **Heading vertical rhythm** — em-based h1-h6 top/bottom margins.
4. `font-family: serif`/`monospace` generic-family metrics (own advance + kern tables).
