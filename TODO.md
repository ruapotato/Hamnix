# Hamnix TODO

What's still open. **For what's shipped, read [`STATUS.md`](STATUS.md)** —
it's append-only, dated, and the source of truth. Completed items live
there, not here; this file stays lean.

Pointers:
- Design: [`docs/architecture.md`](docs/architecture.md),
  [`docs/native-api.md`](docs/native-api.md) (Layer 1 Plan 9 syscalls),
  [`docs/hamUI.md`](docs/hamUI.md), [`docs/security.md`](docs/security.md).
- Snapshot: [`README.md`](README.md). Onboarding: [`CONTRIBUTING.md`](CONTRIBUTING.md).
- Latest audits (2026-06-13): [gap vs Linux](docs/audit_gap_vs_linux_2026-06-13.md),
  [arch shortcuts](docs/audit_arch_shortcuts_2026-06-13.md).

Markers: `[ ]` open · `[~]` in flight.

---

## ⚠ 2026-08-03 — a LIVE `--opt` miscompile on `main` (native codegen.ad lane)

**✔ CLOSED 2026-08-04 by `63131c78` — this whole section is now HISTORY.** Both
[~] items below were fixed by the `ssa_callee_direct_symbol_ok` whitelist (see
the ✔ entry further down) and re-verified RED-on-main first. The text is kept
because it is the clearest statement of the two shapes; do not re-brief from it
as if it were open.

- [x] **Keyword args / omitted defaults are marshalled positionally by the SSA
  builder.** `gen_call` re-shapes such calls via `normalize_call_args`; the SSA
  builder walks the argument chain in *written* order. Repro through the native
  lane (`tests/fuzz/ad_codegen_host.py`: `build_driver` → `run_dump(opt=…)` →
  `wrap_elf` → run):

      def g(a: uint64, b: uint64 = 7) -> uint64: return a * 10 + b
      def main() -> uint64: return g(3)

  `--opt` off → **37** (correct), `--opt` on → **30**. The Python seed is
  unaffected (37 both ways). The shape sits squarely inside the accepted SSA
  subset, so nothing else was stopping it.
- [x] **codegen.ad's by-NAME call interceptions have no linkable symbol.**
  `__syscallN`, `asm_volatile`, the port-I/O + atomic intrinsics and
  `len(slice)` lower to inline bytes, but the SSA lane never enters `gen_call`,
  so a statement-position `__syscall1(60, x)` emits `call rel32` + a fixup
  naming `__syscall1`. Userland hard-fails `cg_fail(7)`; a **kernel** target
  silently records a PLT32 extern reloc against a nonexistent symbol. The
  code comment claiming "the native path never reaches here" stopped being true
  when Phase 3 started emitting.
- [ ] **Invariant to restore: an SSA bail must fall back to -O0, never
  hard-fail.** The in-flight fix branch bails the two cases above but turns
  `tests/fuzz/regress_match_liveness.ad` from `STATUS ok` into
  `STATUS cgfail reason=7`, regressing `scripts/fuzz_adder_diff.sh` to rc 1.
  That fixture pins the register-allocator liveness bug that *blanked the
  desktop* — silently ceasing to compile it is a coverage loss wearing a
  green badge.
- [ ] **Re-brief subset work from the census, not from prose.** The
  "~86.7% subset coverage" figure in the design doc is a *fuzzer-corpus*
  number. Over the real tree it is **16.92%** (3598/21261 functions), over
  kernel sources **26.11%** (2493/9548). The long-briefed gap list is wrong:
  `SBR_SHORTCIRCUIT` bails **zero** functions and `SBR_MANYARGS` is 1.5%. The
  real top three, 71% of all fallbacks, are `SBR_NONPROMOTABLE` 27.0%
  (address-taken scalar local — the native path has no `SVO_ALLOCA` at all),
  `SBR_NONLOCAL` 26.1%, `SBR_CALL` 18.0%. Steer with the per-CALL-SITE
  histogram (`--dump-ssa`, `ssa_bail_site_hist`) and
  `scripts/ssa_subset_census.py`; a per-*reason* histogram is useless, since
  `SBR_MEMORY` alone spans ~40 distinct gates.

- [x] ✔ **The two live `--opt` call-shape miscompiles are FIXED** (`63131c78`).
      The blocked `3269f2b2` is superseded. Verified RED on main first: a
      shape-1/2 reduction printed `on=51` where the answer is `58` (omitted
      trailing default marshalled positionally — silent, no diagnostic), and the
      full fixture `cgfail`ed under `--opt`. Fixed by a **whitelist**
      (`ssa_callee_direct_symbol_ok`), because a blacklist of intercepted
      `gen_expr`/`gen_call` shapes is unmaintainable by construction — the
      previous attempt listed four of six families and missed enum constructors.
      Gates: fuzz 500/500 0 miscompiles, kobjdiff 11398/0, `test_opt_*` 52/52.
- **Census re-run on `63131c78` (whole tree, 2616291 functions): 17.49%
  accepted.** NOT a clean before/after — the census tool shipped with the fix,
  so it cannot be run unchanged against the old compiler — but the subset did
  **not** shrink despite the whitelist's narrowing, because the same change
  relaxed the call-result gate (`ssa_callee_ret_native_ok`; float and by-value
  aggregate returns still bail). Current bail table, and it **re-orders the
  briefed one above**:
  `SBR_NONLOCAL` **31.5%** (site 34 alone = 27.0%, 583092 functions),
  `SBR_NONPROMOTABLE` 28.2% (site 66), `SBR_MEMORY` 18.2% (site 92 = 13.4%),
  `SBR_CALL` 14.1%, `SBR_NONSUBSET_EXPR` 5.8%, `SBR_MANYARGS` 1.5%,
  `SBR_FLOAT` 0.6%.
- [x] ✔ **RETIRED — "next subset target = `SBR_NONLOCAL` site 34" was an
      INSTRUMENT BUG.** The census driver ran `ssa_run_program()` on the bare
      parsed AST, skipping the `collect_externs`/`layout_globals` prologue the
      real `--opt` lane runs, so `glob_count == 0` and **every global read bailed
      in the census and none of them bailed in the real compiler**. Corrected
      whole-tree numbers, same tool build both sides: **accepted 17.46% →
      36.65%**, site 34 27.4% of bails → 4.2%. Per-construct split kills both
      briefed candidates: function-name address decay = 3 functions, aggregate/
      array globals = 0, out of 21276. Guarded by
      `scripts/test_ssa_census_fidelity.sh`, verified RED on main first.
- [x] ✔ **DONE 2026-08-05 (`90f3a590`) — native local-memory model, accepted
      subset 36.65% → 61.15%.** And it carries the campaign's most reusable
      lesson: **a census site's share is an UPPER BOUND, not the win.** Site 66
      was briefed at 36.9% of bails; implementing *exactly* it moved the subset
      **+0.13%**, because a bail histogram is a FIRST-bail histogram and the
      function simply re-bails one statement later. What moved the number was
      landing the whole CLUSTER the site sits in. Size the next target by
      **lift-and-diff** (lift one construct, re-run the census, diff the accepted
      set), not by a histogram row.
- [ ] **UNMERGED, needs verification: `worktree-agent-a2c468f66677acd3e`** carries
      that lift-and-diff harness (`scripts/ssa_lift_diff.sh`,
      `scripts/test_ssa_bailsite_66_split.sh`, census + dump-driver changes) and the
      measurement behind the lesson above — site 66 splits into 104/105 and **both
      halves are worth 0% accepts**. It branched from `0d1c1df1`, BEFORE the memory
      model landed in `90f3a590`, and it touches `ssa.ad`/`ssa_emit.ad` — which that
      commit rewrote. `git merge-tree` reports no textual conflict, which is exactly
      the case [[feedback_worktree_stale_base]] warns about. Verify the MERGED result
      against main's SSA gates, and re-run the census on the merge, not on the branch.
- [ ] **Next: SSA rewrite Phase 4 cutover** (make the native SSA lane the
      default path, not the opt-in one). Re-measure the subset first — do not
      brief it from the 61.15% figure above without re-running the census, and
      confirm the census still runs the SAME pipeline the product does
      (`scripts/test_ssa_census_fidelity.sh` exists precisely because it once
      did not).
- [ ] **The census measures a STANDALONE compile of each `.ad`; a real build
      import-merges the module closure.** A global defined in another module is
      invisible to it and bails at site 34 — the residual 566 is an upper bound,
      not a subset gap. Don't "fix" it by accepting unknown names.

---

## 2026-08-04 — browser: the live-DOM functional lane exists, and it moved the blame

`scripts/test_livedom_functional_host.sh` on `main`: runs each fixture's JS,
dispatches REAL events into the nodes that JS built, drains timers, then diffs
the WHOLE live DOM against `chromium --headless`. Both sides read off the same
channel, so the diff is of two DOMs, not of two serialisers. Fixtures in
`tests/fixtures/livedom/`, banked floor in `.../BASELINE` — **now `pass=18
fail=1` @ `c16fb668`** (was zero), so the gate can finally rot-proof a win.
The one remaining failure is `06_class_style_toggle`, deferred on purpose
(needs CSSOM serialisation, and closing it would move a green render gate).

- **DISPROVED: "events can't reach dynamic elements."** Measured directly, both
  engines agree — a click on a script-created button runs its listener, a click
  inside an `innerHTML`-replaced subtree runs its listener, and a click on a
  5-deep script-built tree bubbles to a delegated ancestor with the correct
  `event.target`. Dispatch is not the keystone it was briefed as.
- [x] ✔ **D1 CLOSED** (`d702f796`) — `el.attributes` omitted attributes set via
      property setters (`el.id=`, `el.className=`, `dataset`): `getAttribute()`
      and `getAttributeNames()` had them, only the `NamedNodeMap` did not,
      because a created element's attributes were enumerated by two different
      code paths. Unified onto one enumerator (`_cre_all_names`). It was the
      biggest single diff producer, and closing it took the lane **0 → 3**
      (`01_create_click`, `11_counter_chain`, `15_innerhtml_rerender` — the
      three fixtures that diverged on attributes and nothing else, so they went
      byte-identical). Also: `getAttributeNames()` must **not** dedupe — two
      namespaces can legitimately share one qualified name.
- [x] ✔ **D2 (text half) CLOSED** (`ecd24fa1`) — `el.textContent = x` on a
      SOURCE-anchored element never ran "replace every child with one Text
      node". Only a CREATED node ran that algorithm; a source-anchored one
      stashed the string as an own property that **only** the render read-back
      (`_dom_readback` → `dom_ov_inner`) ever consulted. The node then carried
      two representations of its content that disagreed — after
      `src.textContent='NEW'`, `.textContent` said `NEW` while
      `childNodes[0].nodeValue` and `.firstChild.data` still said `ORIG`, so
      every reader that WALKS the tree (a framework, a delegated handler
      reading its own output element back) saw the original source text. Same
      shape as D1 (two enumerators): the fix **deletes the second writer**
      rather than teaching the readers about it — both kinds of node now run
      `_node_set_text_content`. Orchestrator re-measured clean-tree both sides:
      **`pass=3 fail=12` @ `7f82b640` → `pass=7 fail=8`**, new passes
      `02_innerhtml_subtree` `03_delegation` `04_settimeout_mutate`
      `05_form_input`, all four banked and all four failing on the pre-fix
      engine. Post-merge the render lane was checked separately (it fails
      disjointly from this one): hambrowse style gate GREEN, WPT testharness
      ratchet PASS at the banked floor 13945/16807, failures 2961 = baseline.
- [x] ✔ **D2b/D3/D4 CLOSED** (`a6ce1da3`) — all three were the SAME shape as D1
      and D2, a **third** time running: one piece of state, two writers, only
      one on the path the readers walk. **D2b** — `classList` wrote only the
      reflected `className`; `_el_get_attribute` consults the `sattr_`
      content-attribute store FIRST, so a source-anchored element reported its
      parse-time class forever. **D3** — `_insert_before_v` gated on
      `_find_cre_by_obj()`, which a DocumentFragment deliberately never
      satisfies, so the insert branch was skipped whole and the staged children
      dropped; `appendChild` had the spec's insert-children-then-empty step,
      `insertBefore` never got it. **D4** — two causes: the created-node branch
      never nulled `parentNode`, and the SOURCE branch nulled it **before** the
      child-list surgery, which reads `parent.children` — a lazy accessor that
      materialises the subtree and rewrites `parentNode` on every child,
      overwriting the null. **Order is load-bearing.** Three neighbours of the
      identical shape came with them: `appendChild()` of a source-anchored
      element was a total no-op; a SECOND `textContent=` on a source element did
      nothing (an own data property shadows the prototype accessor in
      `member_set` as well as `member_get` — the D2 tail); `el.dataset.foo=`
      wrote the dataset object and no attribute. Floor **pass=7 fail=8 →
      pass=12 fail=6**, orchestrator-re-measured; guards proved RED by
      `git archive`ing the pre-fix tree, not by assertion.
- [x] ✔ **D5/D6/D7 CLOSED 2026-08-04** (`3aec4142`) — floor **pass=12 fail=6 →
      pass=16 fail=2**; fixtures `07`, `09`, `10`, `12`. All three were the
      two-writers shape. **D7:** two writers for where a raw-text element's body
      ends — a correct byte scan and a wrong *markup* scan, and the wrong one fed
      `tx_ce`, which every tree reader walks; the `<` in `i < 3` was read as a
      start tag and the skip-to-`>` ate the script's own `</script>`, so the
      whole JS source came out as a sibling text node. Unified onto
      `_rawtext_close`. **D5:** `click()`'s scripted path dispatched and stopped
      while the mouse path was complete; both now run the activation behaviour,
      with `input`/`change` fired only for a **connected** element. **D6:**
      three writers for the selection; `selectedIndex` is now a pure view over
      `.value`. Verified: ratchet PASS 0-newly-failing (floor 13945 → **14077**)
      and the **full 200-gate `test_hambrowse_*_host.sh` sweep 200/200**.
      ⚠ **`17` had been green BY ACCIDENT** — same `i < 3`, but no `>` before the
      close tag, so the bogus span ran past the leak. A green fixture is not
      evidence the code path is right.
- [x] ✔ **D8 RE-LANDED 2026-08-04 (`c16fb668`)** — merged `179eac42`, reverted
      `b15a1588`, now back for good. Orchestrator re-ran both lanes on the branch
      before merging: ratchet **PASS, 0 newly-failing, PASS 15433** (floor was
      13945, since re-banked to 15433 in `7b661ce6`), live-DOM `pass=16 fail=2 →
      **pass=18 fail=1**`. **Neither of the two "loss" clusters was D8, and the
      brief that blamed the accessor was DISPROVED:**
      - The 6 frameset subtests were a **THIRD writer** — a JS prelude shim
        defining `onblur/onerror/onfocus/onload/onscroll/onresize` on the Body
        and FrameSet prototypes out of one object keyed by **handler NAME**: one
        store for every body and every frameset in the document, sitting on a
        more-derived prototype so it won the lookup. The blanket
        `HTMLElement.prototype` accessor was correct; the cache in front of it
        was not. Shim deleted. That is the two-writers shape a **seventh** time,
        and the first instance found outside the DOM store.
      - The 58 `Range-comparePoint` subtests were **not conformance at all** —
        see the arena-wall item below. A correct commit was reverted over a
        memory reading.
- [ ] **★★★ OPEN — the WPT arena wall is `ext_pin`, and 44% of measured subtests
      never run to completion.** Root-caused + instrumented 2026-08-04
      (`a40f0af9`); orchestrator-reverified (ratchet PASS, 15433 = 15433, BSS +0).
      **The framing below THIS line is the corrected one — the previous entry
      blamed `testharness.js` report retention and BOTH of its proposed fixes
      were measured and rejected.**
      - **Cause: `ext_pin` (`lib/web/js/api.ad`) pins FOREVER every object handle
        crossing the `js_*` boundary.** Native *constructors* build their results
        with `js_new_object_v()`, so the immortal set is **linear in what the page
        DOES**, not in what the embedder retains. Clinching experiment: a page
        with **zero DOM interaction** — 4000 trivial
        `test(function(){assert_true(true)})` calls — dies at **2211 subtests**,
        the same wall as the Range files. 20 000 dropped `AbortController`s leave
        **40 600 objects immortal** (41 391 of 48 000 slots); 200 000 closures
        dropped in pure JS leave the live set **flat** (37 004 freed in one
        collection). The collector is healthy; it cannot touch what `ext_pin`
        marked. testharness builds one `AbortController` per `Test` — which is why
        a DOM-free page hits a DOM-shaped wall — and AbortController/AbortSignal
        are built from `js_new_object_v` + `js_set_prop` alone, so **no embedder
        table holds them and the pin protects nothing**.
      - **Both previously-briefed fixes are DEAD.** (a) The streaming report
        **already exists** (`tests/wpt/hamnix_testharnessreport.js` streams via
        `add_result_callback`); neutering its buffer moved 1925→1917 / 2019→2130,
        inside the noise. The residual retainer is inside vendored
        `testharness.js`, which must stay byte-identical. (b) A per-test object
        budget is a **live-free** — the naive version drops the suite from 2211
        subtests to **1**; the safe subset buys only 2211→2652 and stays linear.
      - **`MAX_OBJ` is not the lever and no constant is:** 48000 → 1925/2019,
        40000 → 1590/1612 — pure functions of a constant. (The "1477/1684 at
        40000" previously recorded here was itself stale — same drift.)
      - **The real fix needs BOTH halves, and half of it is a silent live-free:**
        (1) transient handles → the scoped `gc_push`/`gc_popto` temp-root stack
        that already exists, driven by an explicit embedder-scope API (there is
        currently **no** "this embedder call is over" signal to unwind on);
        (2) persistent handles → **trace** the embedder's own tables (`dom_obj`,
        `dom_clsobj`, `dom_on*_fn`, `evl_fn`, `mo_cb`, `cv_sstk_*`, `mrec_attr`,
        `g_cur_event`) as roots — which inverts the `js/` → `dom/` layering and so
        needs a **registered mark callback**, not a direct reference.
        Verify any attempt under `gc_stress` **with the census, not a WPT score**.
      - [ ] **★ 42 of 706 files — 8044 of 18 422 subtests (44%) — do not run to
        completion**, across **FOUR** ceilings, not one: **22** `gc root stack
        overflow` (clustered on `dom/nodes/moveBefore/*` — a stuck-open root and a
        real bug shape, own item), **13** string pool, **10** object pool, plus
        engine wall-clock timeout. **24 produce ZERO subtests** and had been
        sitting unexplained in the "no results" bucket. **So the banked floor
        15433 is substantially a memory reading.** A fifth silent cap surfaced:
        `document.createElement` has a hard per-page **`CRE_MAX=8192`**.
      - **Now instrumented, so this can never silently recur:** the live-object
        census (`js_arena_stat` 49-54, `HAMNIX_JS_ARENA_STATS=1` — `n_objs` is an
        **extent** that never falls, so a retention bug and a genuine working set
        both read as `n_objs == MAX_OBJ`, and nothing was diagnosable until the
        arena could say what held it); truncation detection in `wpt_run.py`,
        hoisted **above** the ratchet's PASS line and hardened so a test's own
        output cannot forge the verdict; `scripts/test_js_ext_pin_leak_host.sh`
        ratcheting the immortal set.
      - **Standing rule:** before treating any baseline delta as conformance,
        check whether the file RAN TO COMPLETION — the ratchet now prints this.
- [x] ~~**D8 CLOSED 2026-08-04** (`179eac42`)~~ — fixture `14`'s inline
      `onclick=` never ran because the content attribute and the IDL attribute
      were **two writers for one piece of state** (the sixth instance of the
      shape): the parse-time inline source lived in `dom_on*_src` (four
      hard-coded types, captured only at element registration) while
      `setAttribute` stashed a raw **string** on the JS object, which no
      dispatch path can call. So the only way to give a `createElement()`'d node
      an inline handler produced a handler that could never run. One accessor
      pair per handler name on `HTMLElement.prototype` is now the single reader.
      Floor **pass=12 fail=6 → pass=14 fail=5**.
- [ ] **`06` is a FOURTH instance of the shape, deliberately deferred.** Its
      class half is now byte-identical; it diverges on the `style=` attribute
      alone. Closing it also needs CSSOM serialisation to match chromium
      (declaration order, `"prop: value;"` spacing, colour normalisation), which
      would move `test_hambrowse_style_host.sh`'s banked `getAttribute('style')`
      expectation — a separate change with its own re-measurement, not a churn
      of a green render gate.
- [x] ✔ **DISPROVED: "the gate is not deterministic."** 15 fixtures × 5 reps ×
      both engines — 150 runs — produced exactly ONE distinct output per fixture
      per engine, and three whole-gate runs were byte-identical. The stale-binary
      suspicion was wrong too: this gate keys its build on a CONTENT fingerprint
      of the tree (`scripts/_adder_bin.sh`), which is the *fix* for the
      `hambrowse_gfx` trap, not an instance of it. The `pass=2` came from an
      **uncommitted 21-line NamedNodeMap patch** in the measuring agent's working
      tree — same commit, different working tree. `git rev-parse HEAD` was a true
      statement about the repository and a false statement about the binary.
      The measurement needed no fix; the REPORT did. Every run now prints HEAD,
      the tree fingerprint, the chromium version, and a loud DIRTY banner naming
      each modified engine input; `HAMNIX_LIVEDOM_REQUIRE_CLEAN=1` refuses to
      measure a dirty tree at all. **Floor is now banked: `pass=0 fail=15`,
      verified clean-tree at `39db2a07`** (chromium 147.0.7727.137).

- [x] ✔ **A RENDER bug this lane is structurally blind to** (`d702f796`, found
      while working D1). `el.style.display` was **write-only for `"none"`**: an
      element a stylesheet rule hid and a script revealed
      (`.stash{display:none}` + `el.style.display='block'` — the show/hide
      primitive behind every modal, dropdown, accordion and tab strip) produced
      no override at all, the rewrite re-emitted a bare tag, the cascade
      re-applied `display:none` on the fresh parse, and the element never
      appeared. Fixed in `_emit_merged_style()`. It moved this lane by **zero**,
      correctly — the DOM already read back `"block"`, so a DOM-diffing harness
      cannot see a painting bug. Coverage lives in
      `test_hambrowse_style_host.sh` (`REVEALWORD` + a `STAYHIDDEN` negative
      control). **Generalises:** a functional lane and a render lane fail
      disjointly, so a green live-DOM diff is not evidence the page PAINTS.

None of D1–D7 is visible to a pixel diff. This is the lane that sees them.

---

## 2026-08-04 — leak census pass 21: the trend arm landed, and it disproved pass 20

Tooling on `main` (`d99b19b5`); writeup `docs/leak_pass21_n_sample_census.md`;
44/44 mutation cases green via `scripts/test_leak_hours_report_mutations.sh`.

**Pass 20's headline is retired.** A 6-minute three-sample run reaches `vma_anon`
**+34** where the 8.02-hour run reached **+37**, and `hamsh` pid 6 reaches **+26**
in both. Eight hours bought three extra pages and zero extra pages. The new SHAPE
classifier calls both **DECAY** without being told what to look for. So the "+41
pages of real growth hidden inside a −149 shrink" is the tracker *attributing* a
fixed population as site 0 drains into the named sites — not growth of the machine.

- [x] ✔ **The 4×2h proof run LANDED — `VERDICT: PASS`, and it retires the residual.**
  One boot, 4 samples over 6.05 h. Both suspects are **DECAY**, not leaks, and the
  trend arm called it without being told what to look for:
  - site 6 `vma_anon` — `1/32/38/48`, rates `+15.36 → +2.97 → +4.96` pg/h
  - long-lived pid 6 `hamsh` — `100/123/127/137`, rates `+11.40 → +1.98 → +4.96` pg/h
  - site 0 `unknown` — `5978/5830/5830/5830`: **FLAT** after one −148 drain, terminal
    rate `+0.00`, so there is no re-attribution credit left to hand out
  - TOTAL live pages **−97** over the gap (−16.02 pg/h). Every other tracked site is
    FLAT at zero. All four sweeps' census control was green: the only unaccounted
    frame in the machine was the planted control.
  **There is no measurable leak at hours scale.** Pass 20's "+41 pages of real growth"
  is fully retired; it was site 0 draining into named sites, exactly as pass 21 argued.
- [x] **Arm the page tracker AT BOOT — DONE 2026-08-05 (`7f4a116f`).** `mem_init()` calls
  `page_alloc_track_boot_arm()` after the counters are zeroed and before one frame
  leaves the buddy allocator, so site 0 starts EMPTY and every per-site number is an
  attribution rather than a difference of attributions. This retires the
  re-attribution credit, the `owner-unrecorded` population, and the per-site
  attribution gap at once. (The old entry was listed twice; both are this item.)
  - Verified by the orchestrator on the shipped image under UEFI/OVMF, RED on main
    first: `scripts/test_track_boot_armed.sh` rc=1 on unmodified main ("no `[trk]
    boot-arm` marker"), PASS on the merge. The load-bearing number is **13063
    cumulative allocs against 6698 live pages** — those 6365 allocated-and-freed
    frames can only have been counted by a tracker already running during bringup.
    Site 0 is **0.1%** of the live population; it was ~100% under late arming.
  - **Boot is not slower** (the red line this work was not allowed to cross):
    boot-to-handoff main 8s/8s/9s vs 7s/7s merged.
  - Permanent cost, read off the device rather than trusted from a formula:
    **3.24 MiB** of tracker arrays, 13.0 bytes/frame for 261632 frames, exposed as
    `PgTrackBytes`. The deep-audit page-table walk does NOT ride along — it gates on
    an explicit `track audit on`, default OFF, because it walks a task's user half
    with IRQs masked on every reap and every execve.
- [ ] **Re-run the leak census now that site 0 is empty.** Every re-attribution argument
  in passes 20 and 21 was an argument about frames the tracker never saw allocated;
  those arguments are now testable directly. Brief from the highest-numbered
  `docs/leak_pass*.md`, not from memory.
- Rule the campaign keeps re-learning: the trend arm thresholds on **resolution**,
  never on a rate tolerance. A sustained positive rate is unbounded by definition,
  so no threshold on it is defensible; a smaller floor is bought by running longer.

---

## 2026-08-05 — open items found while verifying (orchestrator)
- [ ] **The `ADDER_OPT=1` lever assertions are ALL DEAD.** `rm -rf build/fuzz_ad_codegen;
  ADDER_OPT=1 bash scripts/fuzz_adder_diff.sh` exits rc=1 with **20** `never fired`
  corpus failures and every lever counter at zero (const-fold, CSE, LICM, DCE,
  constbr, copyprop). Byte-identical on unmodified `origin/main`, so it is not a
  branch regression. Correctness IS still covered (500/500 accepted, 500 CORRECT,
  0 miscompiles) — what is dead is every "the lever actually fired" assertion. The
  lane also misreports the failure as `found a genuine miscompile`, which sends the
  reader to the wrong place. A permanently-red gate becomes wallpaper.
  [~] Re-dispatched 08-05 (`opt/lever-assertions-r1`) — a SECOND session restart
  killed the previous agent before it committed. Briefed to separate "levers are
  dead" from "assertions are dead": they are different bugs with different fixes,
  and only the first is an optimizer bug.
- [x] ✔ **CLOSED 2026-08-05 (`72b1da5c` + `32a08646`) — `textContent` answered from
  the parse-time source span, not the live tree.** The two-writers shape for the
  SEVENTH time, and it took TWO deletions to close: the stale READER (the getter now
  walks the live tree past the `g_dom_mutated` latch, exactly as the innerHTML getter
  already did) and then the stale WRITER (`_append_sync_text`, which concatenated an
  appended Text node onto an own `textContent` property and, once the getter was on
  the tree, double-counted it — `"mountedmounted"`). Fixed `<template>` inertness on
  the way (chromium: `childNodes.length === 0`, `textContent === ""`). New gate
  `scripts/test_dom_textcontent_livetree_host.sh`, 22 chromium-measured facts, in the
  CI manifest, RED-on-main-verified, and it re-measures live chromium so it cannot go
  dark. Floors: livedom 18/1 held, reactmount PASS, ratchet nothing-regressed with
  PASS 15829 → **15830**. [[feedback_two_writers_defect_shape]]
- [~] **A DOM detach path.** `cre_obj`/`dom_obj` keep every node the DOM ever made —
  8000 dropped detached `<div>`s leave 25439 live objects and zero collections. Banked
  as a ceiling in `test_js_ext_pin_leak_host.sh`, not a target. Dispatched 08-05, and
  briefed to MEASURE FIRST: if few live objects are reachable only from those stores,
  the detach path is not the lever and the finding is the deliverable.
  Re-dispatched 08-05 (`js/dom-detach-measure-r1`) — two agents have now died with
  their sessions without committing. Phase 1 is measurement ONLY; a small number is
  a successful disproof and ends the front.
- [~] **Leak census pass 24 — the first run whose attributions are REAL.** Every
  earlier hours-scale verdict was reached with ~100% of frames unattributed (site 0);
  pass 22 (`7f4a116f`) boot-arms the tracker and pass 23 (`c1ad90db`) stopped the
  adjudicator from excusing boot-armed unattributed survivors. Dispatched 08-05;
  the first agent's 6 h soak was cut off by a session death — its PRE-RUN evidence
  survives as `docs/leak_pass24_boot_armed_census.md` (`42dbd687`, cherry-picked:
  boot-arm mode=2 site0=0 confirmed on that boot's own serial log, 45/45 report
  mutations caught) and the soak is re-dispatched to fill in the RESULTS section.
  **08-05 05:20 — the soak SURVIVED this session's death.** It was `nohup`ed, so it
  outlived the agent that started it: `test_leak_hours_census.sh` pids 934567/979061
  under `.claude/worktrees/agent-a0a5a68db3a2911cf`, `OUT_DIR=build/leak_hours_census/
  pass24-5x90m`, `SAMPLES=5 GAP_S=5400 SETTLE_S=900`, at sample B of 5 (~6 h left).
  Do NOT re-dispatch it and do NOT kill stray QEMU — the orchestrator collects the
  results directly. Generalises: a `nohup`ed measurement is the one thing that
  survives a session death, so long soaks should always be launched that way.
- [ ] **SSA next target = site 92** (call-symbol whitelist, 55.7% of what remains) —
  but read it as a CLUSTER, and mind the standalone-TU caveat that inflates it, same
  as site 34. A census site's share is an UPPER BOUND on the win, never the win.

---

## 2026-07-22 — LLVM = PRIMARY backend: compile EVERYTHING (USER)
USER 07-22: "make LLVM the primary compile pathway"; "build the kernel and all packages with llvm" for the speedup; "get the new LLVM backend to compile EVERYTHING, keeping the kernel LAST but still on the TODO after we get all other apps compiled via llvm."
- ✅ LLVM backend PROVEN: 0.86× gcc-O2; native-link → real ELF64 native binaries; **panel (662/662 fns) compiled via LLVM BOOTS + launches apps (3/3)**; on-device compilation works (host_ac emits .ll on live OS via PIE). Native SSA stays the BOOTSTRAP FLOOR (builds host_ac; can't drop).
- [~] **ALL USER APPS via LLVM** — coverage sweep DONE (17 core DE apps, agent a999cbb2 @ main 326de2b1): **15/17 build native ELF64 via LLVM**; launch-queue trio (hamcal/hamcalc/hammon) boot-verified 3/3. Every remaining bail = `SBR_MEMORY`. Closed so far: structs, 2-D arrays, float, local memory, `gptr[i]` global-Ptr[T] indexing (326de2b1). non-IDENT-base index CLOSED (f7fdeaf7: N-D global arrays + `foo()[i]` pointer-returning bases; hampkgscene 1→0, hamaudioscene 14→11). float-array load/store CLOSED (38512567: `load double`/`store double` through typed ptrs, LLVM-only; mp3decode 10→0 bails, hamaudioscene fully emits). **✅ ALL 17 core DE apps now emit fully via LLVM (0 bails).** ELF64-build sweep DONE (e08defc6, agent a387f904, `docs/llvm_elf64_apps_measurement.md`): **17/18 scene apps build native ELF64** (all real `ELF 64-bit x86-64 SYSV`, no PT_INTERP); **boot-verified under OVMF/KVM** — 3/3 launch-queue apps launch AS ELF64 through the ELF64 panel, 9 windows mapped, no regression vs ELF32 control. **SPEEDUP: LLVM = 0.87× gcc-O2 (beats -O2); native-SSA = 5.57×; LLVM ~6.4× faster than native-SSA** (bench_llvm best-of-7). float-global-scalar load + cast-ptr index CLOSED (98fd2ef2, agent a4a37ad0: `load double` for scalar float globals via `glob_is_float`; `cast[Ptr[T]](x)[i]` index) — **✅✅✅ ALL 18/18 scene apps now BUILD native ELF64 via LLVM (0 bails, 0 build fails), boot-verified.** Orchestrator-reverified: hamaudioscene emitted=495 bailed=0 → real `ELF 64-bit x86-64 SYSV` static, fuzz+OPT2-fuzz 0-miscompile, kobjdiff 11061/0, bench 8/8 @ 0.88× gcc-O2. **THE APPS FRONT OF "LLVM COMPILES EVERYTHING" IS DONE.** App-level host timing not feasible (vk_2d raster still bails, non-app). Residual non-app bail classes (local float arrays, float-pointee `foo()[i]`, float32-narrowing-init globals) deferred until needed.
  - **★ USER 07-22: "every single app compiled with LLVM backend."** DONE (2af6c807, agent ab83b665): `scripts/build_user.sh` now defaults EVERY app to the LLVM→clang→ELF64 lane with automatic per-app native fallback (build never breaks). **Coverage: 254/271 apps via LLVM by default** (orchestrator-reproduced: full build green + DE boot); 17 native fallbacks = roadmap to 100%: ~15 "SSA-subset callee bailed → link-undef" (`word_to_float_bits`, `ta_load`, `eval_call`, `wm_button`, `spawn_worker`, `spawn_shell`, init/getty no-main bodies) + 1 real LLVM float-IR-type bug in `awk` (`'%vN' i64 vs double`). Knobs: `ADDER_LLVM_DEFAULT=0`, `ADDER_FORCE_NATIVE_APPS`. NEXT to reach literally-every-app: broaden the SSA subset for those callees + fix the awk i64/double IR bug (compiler-side).
  - **254→262/271 (bc0c3504, agent aca61c97):** 4 native-safe SSA-subset broadenings (ssa.ad only, kobjdiff 11061/0): awk float-IR type bug (reset `ssa_local_fw` on redeclaration — stale float-width typed an int merge-phi `double`), address-taken float locals (`cast[Ptr[uint64]](&tmp)[0]` reinterpret → lex/parse_selftest), `&"literal"[i]`-as-value (argv marshalling → getty/httpd/init/sshd/ssh), float load/store through cast pointers (`ta_load`). **Remaining 9 fallbacks:** 5 compiler apps bail on raw `__syscallN` (NO linkable symbol — legit-native, arguably "correct native"); 4 (hamsh/hamUId/js/hambrowse) bail on `NM_MAX=256` distinct-names-per-fn cap (a bump like LL_NAME_MAX/MAX_GLOBALS would close them → ~266/271). `&arr[i].field`-as-value proven CORRECT on host (kernel "wrong symbol" was the already-fixed Ph5c/5d global-table interaction). Residual: local struct-array `&loc[i].field` bails safe.
  - **262→~271/271 (b82f5edb, agent afa3c0e8, orchestrator-adopted+verified):** (a) NM_MAX 256→1024 via `concat_compiler_source.py` HOST_BUFFER_OVERRIDES (codegen.ad + cfg.ad untouched; companion LV_WORDS liveness-bitset + lr_hole_* + ra_* allocator arrays mirror-scaled) → closes hamsh/hamUId/js/hambrowse; (b) `SVO_SYSCALL` inline-asm passthrough (`__syscall0..6` → `call asm sideeffect "syscall", "={rax},{rax},{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11},~{memory}"`) → closes the 5 raw-syscall compiler apps. Agent confirmed fuzz+OPT2 0-miscompile before I adopted; orch reverifying kobjdiff + build coverage. NOTE: agent kept pausing before commit → orchestrator committed its worktree diff + verified.
- [~] **KERNEL via LLVM — THE LAST ITEM** (USER: after all apps). Scoped (`docs/kernel_llvm_scoping.md`, 448f9637): kernel ~93% emittable; blockers = 4 bounded gaps incl. TWO SILENT MISCOMPILES (%gs percpu scalar load, asm_volatile) the app sweep never hit. PoC: a leaf kernel module compiles clean via LLVM to kernel ELF. **Phase 0+1 DONE (82fd3a8d, agent afecf0a7):** LL_OUT_CAP 4→32 MiB (whole-kernel .ll emits intact, 26 MiB) + `cast[Ptr[Struct]](p)[i].field` MEMORY class → page.ad/pgtable.ad/setup_percpu.ad all **14→0 bails**, page_* accessors emit; init/main.ad closure 11061 funcs 9759 emit. All native-safety gates green pre-push. **Ph2 asm_volatile passthrough DONE (5059e63e, agent adfa8a0f):** emits `call void asm sideeffect "...", "<clobbers>"()` for all 32 sites (0 bogus `@asm_volatile` left); BEHAVIORALLY proven (executes to 12345, objdump confirms mfence+reload). Caught a critical sub-bug: named module globals now get EXTERNAL linkage (else clang -O2 forwards pre-asm value across the park-to-global pattern — silent miscompile); verified app ELF64 builds + bench 0.87× unaffected. **Ph3 %gs percpu via addrspace(256) DONE (b424fda2, agent ade843fc):** two root causes (LLVM lane never set `cg_target_kernel` so percpu unclassified + SSA scalar path had no percpu case); now `load/store iW addrspace(256)*` → objdump proves `mov %gs:0x0,%rax`; SAME per-CPU offsets (0,8) as native. Address-of `&percpu` + aggregate percpu still BAIL (safe, not miscompile). BOTH silent-miscompile blockers now closed. Orchestrator-reverified incl. **app ELF64 boot-verify 3/3** (cg_target_kernel=1 shared LLVM lane is inert for apps — they still build+boot). **Ph4 residual tail DONE (648ba025, agent aa68de3f):** closed the 2 biggest reason=11 buckets — module-scope struct access `g.field` (305) + `g[i].field` array-of-struct (652), a class apps never hit (`ssa_global_struct_base`/`ssa_global_indexed_struct_base`, LLVM-only). **Kernel bails 1302→486 (−63%), emitted 9759→10575 (+816 funcs).** Differentials proved correct IR. Remaining 486 tail (Phase-5 blockers): reason=11 recursive lvalue-address through non-bare-ident base (365 — needs one broader "recursive lvalue-address lowering" feature), reason=4 non-scalar global read (68), reason=2 fn-pointer/indirect calls (49), reason=0 (4). ALSO flagged for Ph5: whole-kernel `.ll` fails `llvm-as` on a declare/define name collision (`@kmod_linux_load_hook` extern AND defined) — link-unit concern. **Ph4b recursive lvalue-address DONE (f13f0a4c, agent a75332b7):** mutually-recursive lvalue-address walker (`ssa_region_base`/`ssa_struct_base_rec`/`ssa_index_addr_general`) — nested member `a.b.c`, `g[i].stack[d].buf[j]` r/w+`&`, array-of-struct `&g[i]`, ptr-returning-call base. **Kernel bails 486→248 (−49%); reason=11 365→122; emitted 10575→10813.** Found+fixed 2 pre-existing address bugs (struct-element array stride; array-field-as-pointer deref). Remaining 248 tail: **117 = `&function`** (symbol-ref — belongs to Ph5 link lane, NOT lvalue), 73 reason=4 non-scalar global read, 49 reason=2 fn-pointer/indirect call, 5 multi-dim member array, 4 reason=0. **Ph5a close-emit-tail DONE (ff73332c, agent a17959102):** `SVO_FUNCADDR` (`&function`/fn-name-as-value → `ptrtoint ptr @name`), indirect fn-pointer calls (local + global), multi-dim member/array-of-struct arrays, non-scalar global reads. **Kernel bails 248→7 (−97%):** reason=11 122→2, reason=4 73→0, reason=2 49→1, reason=0 4 (pre-existing empty-SSA). **★ THE WHOLE-KERNEL `.ll` (30 MiB) NOW PASSES `llvm-as-19` CLEAN → valid 10 MiB .bc** — the gating deliverable for linking. The real llvm-as blocker was `LL_NAME_MAX`=2048 saturating vs ~11k funcs → 2333 spurious declare/define collisions (masked by the kmod error); fixed 2048→20480. Orchestrator-reverified: fuzz+OPT2 0-miscompile, kobjdiff 11061/0, bench 0.87×, **apps still build ELF64** (name-set change safe). Remaining 7 bails all safe: 4 empty-SSA, 1 container_of (test file), 2 (local 2-D array + int-as-ptr store) — bounded future extensions. **★★★ Ph5b LINK + BOOT — LLVM KERNEL BOOTS TO USERSPACE 2026-07-22 (6990aea9, agent a8fa9041).** `scripts/build_kernel_llvm.sh` (opt-in lane; native path byte-identical — only scripts/docs/.S added): whole-kernel `.ll` → `clang-19 -mcmodel=kernel -O0` → link 22 `.S` stubs + native-hybrid fallback (`ld --allow-multiple-definition`, LLVM first-wins for 11054 emitted funcs, the 7 bailed fall through to native `main.o`) under kernel.lds @ 0xffffffff80000000. **The LLVM-compiled kernel BOOTS: start_kernel → trap_init → full pgtable/e820/COW/swap bringup → page_offset direct-map PASS → execve INTO USERSPACE → hamsh shell "M16.35 shell ready" → sources /etc/rc.boot → rfork child pid=7 → WALLS.** Captured wall (`-d int`): `v=0e cpl=3 CR2=0x0f210fb7` = userspace child COW write-fault; handler ENTERED but never returns (only 2 pfaults in 30s, no storm, no triple-fault). Native ref kernel from identical .S/.lds boots fully → wall is LLVM-codegen, not link. **Prime suspect: Phase-3 `%gs` percpu `current` read returning wrong `current->mm` so COW handler loops; verify via clang -S that percpu `current` emits `mov %gs:<off>`.** `-O0` required (`-O2` collides rdrand/rdseed asm `.L` labels → needs emitter `${:uid}` label-uniquify for an `-O2` lane). **Ph5c garbage-printk COW hang FIXED (077cc1dd, agent ac7ed6f1):** root cause was NOT percpu — the whole-kernel LLVM closure registers ~10075 named + ~6297 interned-string globals, overflowing host-compiler `MAX_GLOBALS`=16384 → `ssa_llvm.ad::llvm_glob_for` reverse-scan returned `@FB_PIXFMT_BGR` for **3146 printks (41% of all kernel printks!)**; `do_page_fault`'s garbage format-string → `printk` `while fmt[i]!=0` spewed `0x01` forever → child's COW fault never returned → hang. Fix: `concat_compiler_source.py` `MAX_GLOBALS` 16384→32768 (host-compiler build buffer ONLY; on-disk codegen.ad unchanged=1024 → native byte-identical by construction). Collisions 3146→0; COW faults now resolve CLEAN (no 0x01 spew). Gates: kobjdiff 11061/0, fuzz+OPT2 0-miscompile, bench 8/8, codegen.ad not in diff. A/B native-substitution method pinpointed it. **Ph5d PARTIAL (de46aa80, agent a7729fdd, ~2.9h):** landed a REAL native-safe fix — `ssa_llvm.ad::llvm_emit_globals` now emits external module globals `dso_local` (was dso_preemptable → GOT-routed `R_X86_64_REX_GOTPCRELX`; the native-hybrid `--allow-multiple-definition` link doesn't uniformly relax duplicated GOTPCRELX → hazard); now direct `R_X86_64_32S`, 0 GOTPCREL. Gates green (kobjdiff 11061/0, fuzz+OPT2 0-miscompile, bench 8/8, codegen.ad untouched). **BUT still walls at `rfork pid=7`** — NOT fully fixed. Pinpoint: the wall = FIRST cross-task schedule (child pid7 created READY, parent yields→scheduler picks a kworker→`_another_task_ready()` returns 0→idle; child never dispatched to userspace). A/B (new `scripts/kllvm_force_native.py` + `KLLVM_FORCE_NATIVE=` hook) PROVED it's NOT sched/core.ad (377 fns forced native → still hangs) NOR do_rfork (forced native → still hangs) → a shared-data/child-post-fork-context issue. **Found a REAL codegen bug: `&arr[i].field` materialized AS A VALUE miscompiles → wrong .data symbol** (corrupted the agent's `&`-address debug probes; a genuine SVO/lvalue-address-as-value bug worth fixing independently). **Ph5e (6fcbf587, agent ae5a88b9, ~1.5h):** (1) BUILD-BLOCKER found+fixed — whole-kernel `.ll` outgrew `LL_OUT_CAP`=32MiB (Ph4b/5a broadening) → silent `ll_putc` truncation mid-fn → clang `expected value token`; **bumped LL_OUT_CAP 32→64MiB** (host LLVM-backend BSS buffer). (2) PINPOINT — **`do_page_fault`'s LLVM codegen mis-resolves `task_table[]` reads during fault handling**: at fault entry, `task_image_lo(6)` w/ LITERAL index returns 0 (vs native 0x400000) → VMA miss → spurious SIGSEGV at hamsh stage-01. task_table is higher-half (mapped every PML4), cr3 identical → NOT a mapping issue; native reads correct → memory not corrupted. **A/B-proven:** `KLLVM_FORCE_NATIVE=do_page_fault` → all demand faults resolve → boots stages 01-05 → hamsh → rc.boot → `rfork pid=7`. Fix: route `do_page_fault` native-hybrid by DEFAULT in build_kernel_llvm.sh (opt-in lane only, appendable via KLLVM_FORCE_NATIVE). Native-safe: kobjdiff 11061/0, fuzz-off 500/500, bench 8/8, codegen.ad untouched. **LLVM kernel lane now builds+boots to the pid=7 wall again.** OPEN residuals: (a) the exact miscompiled construct INSIDE do_page_fault not isolated (large-fn codegen edge or cross-call clobber under -mcmodel=kernel -O0; next probe = `clang -S @do_page_fault` vs a working reader) — a proper ssa_llvm fix stays open; (b) the pid=7 cross-task-schedule wall itself (`_another_task_ready` returns 0, child never dispatched) — the original Ph5d residual, still there. Ph5f/5g/5h (agents a63dc35f/ac66282f/ac3765a4) OVERTURNED the do_page_fault-codegen theory: **do_page_fault is compiled CORRECTLY** (its IR has only 5 stores, none reach task_table; routing it native just SHIFTS BSS +0x1000 so victims dodge a wild write — a LAYOUT ARTIFACT, not a fix). **Ph5h (cd1acfd6) proved force-native bisection is LAYOUT-CONFOUNDED** (forcing `vma_demand_fault` native "boots to pid=7" but its IR has 0 stores → only shifts BSS; can't causally pin). **Reliable gdb watchpoints (Ph5h) overturned the "task_table physical zeroing" narrative:** `task_table[6].image_lo` is written EXACTLY ONCE (the BSS clear), never wild-zeroed via any alias; the fault is `tree-find=0` = the slot's demand-VMA not found. **CORRECTED DIAGNOSIS: layout-sensitive corruption of the VMA INTERVAL-TREE / node-pool (NOT task_table)**, written by `vma_register_bss_demand`/the tree-insert during execve. NEXT Ph5i: NON-confounded probe — data-watchpoint the VMA node-pool region (not task_table) to catch the store that breaks tree-find, OR differential dump of slot-6's VMA tree in a booting (do_page_fault-native) vs failing build. TOOLING (load-bearing): serial logs are binary→`grep -a`; qemu gdbstub exec-breakpoints DON'T fire but data-watchpoints DO; watchpoints deopt TCG (watch a RARELY-written addr, not printk_line_seq); give qemu a shorter timeout than gdb. Separate: `_another_task_ready` pid=7 wall still distinct. **6 agents deep (~10h); bug is exceptionally elusive — diagnosis shifted read-misread→write-corruption→wild-OOB→VMA-tree; the differential-VMA-tree dump is the decisive next probe.**
- **Ph5i (b5a7a97c, agent aa053c8f) FOUND+FIXED A REAL LLVM MISCOMPILE:** static OOB scanner over the whole-kernel `.ll` → **1776 constant-offset accesses past a global's declared size** — ~50 struct-VALUE module globals (`@v9p_dev`, `@xhci`, `@nvme`, `@ahci`, `@gpu_state`, scheduler scratch…) emitted as `[8 x i8]`. Root cause: codegen.ad's struct-global decl reserves full `st_total` in .bss + stamps `glob_struct_idx` but records elem/scalar_size=0; `ssa_llvm.ad::llvm_glob_bytes` never consulted `glob_struct_idx` → 8-byte scalar default → every `g.field` store past off-8 spilled into the ADJACENT .bss global. **Fix: `llvm_glob_bytes` returns `st_total[glob_struct_idx-1]`** → `@v9p_dev [120]`, `@xhci [840]`; OOB scanner=0, llvm-as clean. Native-safe (kobjdiff, fuzz, bench 8/8, codegen.ad not in diff — no native caller). Real correctness win (was corrupting adjacent globals for every struct-value global). **BUT boot wall PERSISTS** — a SEPARATE broad region-zeroing on execve→first-fault: at fault time `task_table[6].{image_lo,vma_list_head}` AND `vma_tree_root[6]` ALL read 0 (3 unrelated slot-keyed higher-half globals) while printk still works → broad slot-keyed BSS zeroing, NOT a single wild store or stride miscompile. Tooling in scratchpad: `scan_oob.py` (catches "global declared too small" regressions), `vtree_iso.ad`. Ph5j (bc6fb4cc doc): TIME-bracketed the zeroing to execve-sysret→first-fault; ruled out write-path/timer/_vma_zero_phys/wrong-slot; paradox = no synchronous LLVM fn in the gap yet multi-global zero. **★ Ph5k (18301c42, agent a4f6dae2) — MAJOR REFRAME: the stage-01 wall was a DEBUG-PROBE LAYOUT ARTIFACT.** A CLEAN (probe-free) do_page_fault-**LLVM** kernel BOOTS PAST stage-01 to `rfork pid=7` under BOTH TCG and KVM — same as the native-hybrid default (emit stat: clean funcs=11064 vs probe-build 11065; each `.bss` probe shifted layout so a latent wild store hit task_table). DMA RULED OUT (`-nic none` no change; CPU store not device DMA); KPTI OFF (rules out trap-entry/CR3). `scan_oob.py=0` (5i const-offset fix holds) → remaining writer = a **VARIABLE-INDEX/STRIDE store miscompile** (`g[i].field`/`g[i].arr[j]` wrong stride — invisible to const-offset scan; why 8 agents' HW-watchpoints missed it: TCG too slow, KVM DR clobbered by kernel DRn writes). Productive tools: qemu-monitor `xp` phys-read, `-nic none` quiesce, clean-vs-probe A/B. **do_page_fault native-hybrid may now be UNNECESSARY** (verify a clean `KLLVM_DEFAULT_FORCE_NATIVE=""` build boots→pid7, then flip default). Ph5l (78b2ba9c) REFUTED variable-stride (scan_oob=0; task_table stride exactly correct). **★★★ Ph5m (cd7ebc35, agent aeaac63a) — ROOT PINNED + BOTH WALLS CLEARED.** The wild store is a bulk `.bss` MEMSET, one CONTIGUOUS region starting EXACTLY at `__bss_start` — from **`memblock_alloc`'s LLVM codegen returning a `__bss_start`-colliding base** → `region_alloc`→`_load_elf64` gets a region aliasing `.bss` → its eager memset/PT_LOAD memcpy zeroes task_table etc. **ONE bug caused BOTH walls:** stage-01 SIGSEGV (task_table[6] VMA zeroed) AND pid=7 (task_table[child].state clobbered → `_another_task_ready()==0` → child never dispatched). Single-variable bisection (force ONLY memblock_alloc native) clears both — layout-INVARIANT (24MiB hole anchored at fixed __bss_start, task_table 24MiB inside → not layout luck). **do_page_fault-LLVM confirmed FINE** (swaps the native-hybrid to the ACTUAL culprit). Fix: `build_kernel_llvm.sh` default force-native `do_page_fault`→`memblock_alloc`. **⚠ ORCHESTRATOR REPRO (cd7ebc35, TCG+KVM): CLEARS the stage-01 SIGSEGV — boots cleanly stage-01→05 (main-enter/arenas/env/fd-ns/rc-open) → `rfork pid=7`. BUT STILL WALLS AT pid=7 (576 lines, log ends there) — the agent's "past pid=7 to kmod-load (~3879 lines)" DID NOT REPRODUCE.** So memblock_alloc-native is a real, correct isolation (root buggy fn pinned; do_page_fault-LLVM works) that removes the stage-01 corruption path, but the pid=7 scheduler wall PERSISTS as a distinct blocker (memblock's task_table[child].state theory is incomplete OR the agent had a favorable/different boot). Native-safe (build-script+doc only, no source; native byte-identical by construction). **★ Ph5n (72f805c0, agent a02ddbb2) — UNIFIES ALL WALLS + overturns Ph5m.** Same-boot A/B + physical `xp` reads prove: the stage-01 SIGSEGV, the pid=7 wall, AND a NEW kmod-load `#GP` (boot:35, `__SCT__might_resched` rip 0xffffffff8c61a956, 3290 skipped relocs, export table `NR_EXPORTS`@phys 0x05109c40 physically 0) are ALL the SAME single deterministic **layout-sensitive bulk-`.bss` wild store** (Ph5g/5k/5m). Native-hybridding functions (`memblock_alloc`, `do_page_fault`, `linux_abi_lookup`) only RELOCATES the victim — the store PERSISTS; **the LLVM lane fully boots in NO config** (my earlier "reaches pid=7" was itself a victim-location artifact). `linux_abi_lookup` codegen is CORRECT (objdump-verified) — it reads 0 because the export table IS physically 0. So the `_another_task_ready`/pid=7 theory is MOOT until the wild store is fixed. **BEST NEXT PROBE (Ph5o): the export-table victim is zeroed EARLY (boot:35, past the early-boot DR-clobber window) at a FIXED phys addr `0x05109c40`** — arm a physical/low-identity HW watchpoint there AFTER boot:34; the tripping RIP names the writer. Candidate writers at boot:35: `kmod_linux_load`'s `memset(base,0,span)` / `_bias_loaded` / `_copy_sections` / `_apply_relocations` in `linux_abi/loader.ad` — check each `sec_loaded_addr[i]` lands in the module window, not low kernel `.bss`. The wild store has resisted 11 agents (5b–5n) unpinned to an instruction; this fixed-early-address watchpoint is the most tractable lead yet. ~~a SEPARATE 2nd bug still stalls the child at `rfork pid=7` (post-fork syscall/exec/exit path, another LLVM-miscompiled fn); same A/B native-substitution will pinpoint it.** Also deferred: `-O2` lane (rdrand/rdseed asm `.L`-label collision needs emitter `${:uid}`).
- **★★★ Ph5p (main 8cf14fd7, agent a069c56f — ORCHESTRATOR-VERIFIED) — the "wild .bss store" (5g–5o, 11 agents) DID NOT EXIST; DISPROVEN.** Full-speed-TCG `hbreak` on the LIVE `kmod_linux_load` (0xffffffff8042eff0; native symbol pointed at the dead duplicate) caught the truth: `NR_EXPORTS`'s LLVM copy (`0x896c2002`) stays **2756/INTACT** the entire boot; a write-watchpoint fired ONCE (the legit `__bss_start..__bss_end` clear, rip 0xffffffff80114018) and NEVER again. 5o's "physical zero via direct-map alias" was reading the NEVER-POPULATED native duplicate. **ROOT CAUSE = hybrid-link DUPLICATE-GLOBAL split:** both `kernel_main_llvm.o` and `native_main.o` strongly define every module global; `ld --allow-multiple-definition` binds each relocation to a duplicate independently → writer `_add_export` → LLVM copy, reader `linux_abi_lookup` → native copy → reader scans an empty table → 3290 skipped relocs → usbcore `init_module` #GP. The `.ll` IR is CORRECT — the defect is purely the hybrid link. **FIX (native byte-identical — scripts+doc only): `scripts/kllvm_externalize_dupglobals.py`** rewrites the LLVM object's DEFINITION of every global native also defines (10076 globals) into an `external` decl → native is sole definer, all refs bind one copy. Wired into `build_kernel_llvm.sh` (steps 1c/1d). **VERIFIED (orchestrator, KVM -cpu host, grep -a): `relocations applied=14183 skipped=0` (usbcore + all 4 modules), #GP GONE; boot now clears boot:35 and reaches `[boot:42] start_first_task` → `exec'ing /bin/hamsh` → `execve: jumping to 0x…` (into userspace) → NEW distinct wall `panic: schedule: dispatch into task with uninitialized sp`.** kobjdiff 11064/0 PASS. **Ph5q (agent aa4cd81c, in flight):** chase the `uninitialized sp` panic — prime suspect per 5p is ANOTHER hybrid-link split, this time FUNCTION-level (the first-task sp-init writer vs the schedule dispatcher reader resolved to different copies by `--allow-multiple-definition` first-wins). Same native-substitution / hbreak method. **NOTE for future sessions: kernel-LLVM blockers have been BOTH hybrid-link duplicate-definition bugs AND real codegen miscompiles — check both.**
- **★★★ Ph5q (main 91080d11, agent aa4cd81c — ORCHESTRATOR-VERIFIED, fresh build+boot) — LLVM-COMPILED KERNEL BOOTS TO THE USERSPACE SHELL = ARM-UNLOCK MILESTONE.** The `uninitialized sp` panic was a REAL codegen miscompile (not a link split): `schedule()`'s `task_table[nxt].sp < 0x100000` guard (`.sp` is `uint64`) false-fired on a valid high-half kstack sp (bit 63 set) because `ssa.ad::ssa_expr_sgn` lacked an ND_MEMBER arm → `.sp` signedness=unknown → emitted `icmp slt` (signed) not `ult`. Native codegen.ad already handles ND_MEMBER via `member_scalar_signedness` (why native boots). FIX = 10-line ssa.ad ND_MEMBER arm delegating to that same helper (LLVM/--opt path; codegen.ad untouched → native byte-identical). **VERIFIED (KVM -cpu host, fresh host_ac + kernel rebuild): `.ll` now `icmp ult`; boots `[hamsh:_start hit]` → shell stages 01-05 → `M16.35 shell ready` → /etc/rc.boot → rfork pids 7-13 + userspace execve → squashfs mount + live-distro stream; ZERO panics.** Gates: kobjdiff 11064/0 PASS, ADDER_OPT2=1 fuzz PASS, bench 8/8. **⚠ BUILD GOTCHA: `build_kernel_llvm.sh` bakes ssa.ad into `ADDER_HOST_AC` (build/cutover/host_ac.elf) via concat — after any ssa*.ad edit REBUILD host_ac (`_adder_cc.sh adder_cc_bootstrap`, or kobjdiff does it) BEFORE the kernel or the `.ll` is stale (still `slt`) — cost one false-fail boot.** ⇒ Whole-kernel LLVM Hamnix reaches the shell; LLVM→ARM64 is free, directly enabling the Pinebook retarget.
- **Ph5r (main a3fd3467, agent afbefe18 — ORCHESTRATOR-VERIFIED) — `-O2` lane now COMPILES+BOOTS (was un-buildable); label blocker root-fixed.** The documented `-O2` blocker (clang inline-asm `.L`-label collisions: `symbol '.Lrdrand_retry' is already defined` ×4 from devrandom.ad `_rdrand64`/`_rdseed64`) is fixed in `ssa_llvm.ad::ll_put_asm_string` — appends LLVM `${:uid}` (per-instantiation-unique) to every GAS `.L<ident>` local label (def+refs share the uid → still matched; distinct inlinings get distinct uids → no collision); globals untouched. General + ARM-relevant. **VERIFIED (orchestrator): `.ll` emits `.Lrdrand_retry${:uid}`; `-O0` STILL boots to `M16.35 shell ready` + rfork pids 7-14 (no regression); kobjdiff 11064/0 PASS (codegen.ad not in native diff).** `-O2` text 54.3MB = **5.4% smaller** than `-O0`. Agent ran fuzz/OPT2/bench 8/8 PASS. **`-O2` lane now builds+links+boots to boot-stage-32 but WALLS at two pinned `-O2`-only codegen blockers (documented Ph5r, NOT fixed):** (1) **9P-handshake INDIRECT CALL to `0xffffffff00000000`** — high 32 bits of the call target dropped, RSI in p9smoke_buf; force-native excludes p9_smoke_test/_smoke_pump_call → miscompile in a deeper 9P codec/attach callee (a real `-mcmodel=kernel -O2` indirect-call address-materialization bug). (2) **rfork/COW page-free wild-addr storm** (`[pa-corrupt] free of wild addr` over COW demand-VMA) — separate latent `-O2` divergence, `-O0` runs the same path clean. NEXT (agent in flight): fix the `-O2` 9P indirect-call high-bits miscompile → then the COW page-free → `-O2` boots to shell = the LLVM perf payoff.
- **★★★ Ph5s (main 5245bf45, agent ae62a5fd — ORCHESTRATOR-VERIFIED, both lanes booted) — `-O2` LLVM KERNEL BOOTS TO THE SHELL = LLVM PERF PAYOFF, full -O0 parity.** Ph5r's "indirect-call miscompile" hypothesis was WRONG (disproved). Two real -O2-only codegen bugs root-fixed: (#1) **struct-local STACK OVERFLOW** — `ssa.ad::ssa_intern_local` lacked a struct branch → a 32B struct local (P9Cursor) got an `[8 x i8]` alloca (scalar path prim_type_size=8), its init overran the frame and zeroed a saved return address' low dword under -O2's tight layout (→ `ret` to `0xffffffff00000000`; -O0 padding hid it). Fix: size struct-local alloca to `st_total`. A BROAD latent LLVM/--opt bug (any struct local under-allocated). (#2) emitter declared every global `align 16` but native-hybrid link makes byte-packed native_main.o sole definer at arbitrary alignment → clang -O2 `movaps` #GP; fix emits `align 1` (`ssa_llvm.ad`+`kllvm_externalize_dupglobals.py`). **VERIFIED (KVM -cpu host, fresh host_ac): -O2 boots `[p9smoke] PASS` → `M16.35 shell ready` → rfork pids 7-14, 0 faults; -O0 still boots to shell (regression clean).** Gates: kobjdiff 11064/0, ADDER_OPT2=1 fuzz PASS (the --opt path the struct fix touches), bench 8/8 @ 0.90× gcc-O2. codegen.ad NOT in native diff. -O2 text ~3MB smaller. Pre-existing non-fatal `[pa-corrupt]` COW-range-free storm remains (cosmetic, both lanes). **NEXT: ARM64 codegen retarget scoping — the LLVM kernel is now correctness+perf complete; LLVM→ARM is the north-star unlock.**
- **★★★ LLVM KERNEL RENDERS THE DESKTOP (USER's #1 priority 2026-07-23) — orchestrator-verified, screenshot delivered.** Both -O0 and -O2 LLVM-compiled kernels boot the shipped DE userland (`build/initramfs_blob.S`) to a full hamUI desktop: panel + 13 icons + hamedit + hamfm, 6-7 `[devwsys] window mapped` markers, real 2572-color framebuffer (reproduced on fresh current-main builds). Harness `scratchpad/boot_de.sh ELF SER PNG` (grub-ISO + `-vga std -m 1536M` + monitor screendump; run ~2min, don't kill during the live-distro stream). Committed on-demand gate `scripts/test_de_visual_gate_llvm.sh` + `docs/de_visual_gate_llvm.md`. **Storm FIXED (main 1abf963a):** the `[pa-corrupt] free of wild addr` storm (5655 lines, Phase-5s dismissed as cosmetic) was a real SHARED native+LLVM MM bug — `_vma_free_cow_range` handed region-backed (non-buddy) fork-child image frames to `free_page`; fix gates `free_page` on `_pa_link_ok` (buddy-only), `cow_drop_page` stays unconditional (refcount exact). Storm 5655→0 BOTH lanes, rl5 7269→1613, desktop still renders (6 windows, no regression), kobjdiff 11064/0 PASS. **REMAINING (separate, SHARED native+LLVM, NOT LLVM-specific):** the BIOS-ISO+in-RAM SELFTEST path (`test_de_visual_gate_llvm.sh`) still maps 0 windows because detached launch-queue scene clients rfork-but-never-execve (Phase-5d "child READY not dispatched" wall) — native fails IDENTICALLY through that harness (OVMF+ext4 works for both). So the gate compares in-RAM vs OVMF = harness-confounded; the real desktop (shipped image) renders. Chasing the in-RAM dispatch gap = a general kernel/boot-path fix (benefits native too), not an LLVM regression.
- [ ] **KERNEL via LLVM — LAST, but ON THE LIST** (USER: after all apps). The hard one: bare-metal (higher-half link), heavy **inline asm** + `%gs` **percpu** the LLVM emitter doesn't handle yet. Needs: inline-asm passthrough to LLVM, percpu modeling, `clang -ffreestanding -target x86_64` + the kernel.lds link. Do after all apps compile via LLVM.

## 2026-07-21 — LLVM optional backend (USER-approved direction)

Decision: the native SSA optimizer is correct but ~5.5× slower than gcc-O2; hand-matching
LLVM is a multi-year grind. So adopt **LLVM as an OPTIONAL "release/fast" backend** (Rust's
MIR→LLVM model), lowering our existing **SSA IR → LLVM IR**. Native SSA/hand-written-x86
backend STAYS as the DEFAULT + self-hosting bootstrap. USER also **rejected forking Linux**
into a Plan 9 shape — keep the native Adder kernel; get its speed by LLVM-compiling it and
its drivers via the existing `.ko` shim.

- [~] LLVM backend spike (agent 2026-07-21): `adder/compiler/ssa_llvm.ad` emits textual
  `.ll` from the SSA IR → clang-19/llc. Gated `--backend=llvm`, native default unchanged.
  Acceptance = correctness (0 wrong answers on bench+fuzzer) + the 4-way perf number
  (native-SSA vs Adder-LLVM vs gcc-O0 vs gcc-O2). The LLVM-vs-gcc-O2 number decides it.
- [~] **Get the LLVM backend functional WITHIN the Linux namespace** (USER) — feasibility mapped
  2026-07-22: the whole `.ad→.ll→clang→binary` pipeline runs INSIDE `enter linux { }` (host_ac.elf
  AND clang are both x86_64-linux binaries; bash runs in the Debian ns) — NO new kernel/ns machinery.
  Phased plan (QEMU-validated):
  - [~] **Phase 0** — stamp `EI_OSABI=LINUX(3)` on the `x86_64-linux` target (`elf_emit.ad:832`,
    thread the target through `ELF_FMT_USER`; keep `x86_64-adder-user`=SYSV/native). Fixes the ONE
    code blocker: host_ac.elf is currently OSABI=SYSV so `fs/elf.ad::elf_is_linux_binary` classifies
    it as NATIVE → wrong syscall routing. Then stage host_ac into a writable `#distro` + QEMU
    `enter linux { host_ac --backend=llvm hello.ad hello.ll }` → .ll appears.
  - [x] **Phase 0a DONE** (main e1d00476): x86_64-linux target stamps EI_OSABI=3 (elf_emit.ad + fused_driver + seed adder.py header stamp). host_ac.elf→OS/ABI Linux; native user→SYSV; kobjdiff+fuzzer PASS.
  - [x] **Phase 0b DONE + KEY FINDING** (main 4452c991): shim CORRECTLY routes host_ac on-device (`elf: Linux-ABI binary detected; route via u_syscalls` — 0a works!) BUT host_ac never reaches main(): the **ELF loader KERNEL-#PFs (vec=0x0e) backing host_ac's ~474 MiB static BSS arena** (fused compiler's huge fixed Array[] globals, e.g. fused_driver_host_main.ad drv_src: Array[25165824]). Non-present PTE (pte=0) in BSS span [0x488000,0x1def5000). NOT RAM-exhaustion (repro @3G/8G), NOT ENOSYS, NOT the ET_EXEC overlay — specifically the loader's large-BSS mapping path. Reproducer: `HAMNIX_STAGE_HOSTAC=1` + `scripts/test_ondevice_hostac_llvm.sh` (opt-in, normal images unaffected).
  - [x] **Phase 0c DONE + DEEP FINDING** (main aba69789, mm/vma.ad boot-CR3-shield the BSS demand-VMA node alloc): fixed the BSS #PF (root cause was NOT missing BSS backing — demand-zero VMA machinery already exists; the bug was `vma_register_bss_demand` slab-allocing the VmaNode AFTER punching the BSS window not-present, so the freelist obj landed in the punched region → #PF. Fix allocs+inserts the node under BOOT CR3 before the punch). RESULT: **host_ac now LOADS + routes via shim + reaches main()** (past the BSS wall). kobjdiff PASS + desktop boot PASS (native-safe). RESIDUAL/FUNDAMENTAL BLOCKER: host_ac is ET_EXEC@0x400000 so its 474MiB LOW-vaddr BSS **ALIASES the kernel's low-identity direct map** (shared PML4[0]); on host_ac's first file I/O the kernel derefs the virtqueue descriptor ring (low phys, inside the punched window) under host_ac's CR3 → wedges. Can't be fixed at the #PF handler (kernel demand-fault at a low VA aliasing in-use kernel RAM is ambiguous). TWO WAYS FORWARD: **(1) KPTI high-half consumer flip** — make slab/driver RAM accesses reach RAM via the existing high-half direct map (PML4[273] @0xffff888000000000, present in every task) so they're immune to any task's low-identity punch = the general/correct fix (the "remaining large mm work" flagged in arch/x86/mm/pgtable.ad); **(2) build host_ac as ET_DYN/PIE at a HIGH base** so its BSS lands above RAM where the punch removes nothing kernel-used = pragmatic unblock, a host_ac BUILD-TARGET change (existing ET_DYN demand-BSS path already handles it). ⏸ PARKED pending USER steer (2026-07-22): the on-device build is now a genuine MULTI-PHASE KERNEL BRING-UP; asked USER whether to keep driving (option 2 next) or bank the (complete, fast) LLVM-backend win + revisit on-device later.
  - [x] **✅ host_ac RUNS ON-DEVICE 2026-07-22 (main d19c7227)** — the ET_EXEC-low-BSS-aliasing wall is GONE via **PIE/ET_DYN host_ac** (USER call). The seed codegen is fully position-independent (`lea g(%rip)`, ZERO relocs) so `-pie` "just works" — no relocator needed; ET_DYN loader rebases BSS to ≥4GiB (aslr_load_bias), clear of low-identity RAM. Gated `ADDER_X86_LINUX_PIE=1` (set for host_ac bootstrap in `_adder_cc.sh`; fuzz driver etc. stay ET_EXEC). Also merged: virtqueue-ring HHDM redirect (f6eadf4f). **Reproducer `test_ondevice_hostac_llvm.sh` = P0B_RESULT rc=0 ll_bytes=610** — host_ac ran under the Linux shim in the Debian namespace + emitted a .ll ON THE LIVE OS. kobjdiff PASS (PIE host_ac → identical kernel codegen). NOTE: high placement needs ASLR on (default); pin a high load-bias if a deterministic boot ever sets aslr_disabled=1.
  - [~] **Phase 1** — the on-device .ad→.ll works; NEXT = clang in the namespace: prove clang survives the shim (big C++ dyn binary + subprocesses + temp); fix `fs/vfs.ad::vfs_mkdir` `/tmp` ENOSYS gap; stage clang DSO closure into writable ext4 `#distro`.
  - [ ] **Phase 2** — on-device `/usr/local/bin/adder-cc-llvm` (port `scripts/adder_cc_llvm.sh`).
  - [ ] **Phase 3** — productionize: clang delivery (bake into debootstrap fixture OR file:// localrepo,
    no network), size a disk-backed `#distro` for the ~1GB toolchain, add a QEMU on-device gate.
  RISKS: clang-under-shim (unproven, moderate) + fitting ~1GB toolchain on a writable disk `#distro`.
  Output binary is a Linux-ABI ELF (runs in the linux ns) — correct per docs/distro-namespaces.md.
- [ ] Once the LLVM number lands: STOP grinding the native register allocator toward
  gcc-parity (it only needs correct + decent for bootstrap); LLVM carries release speed.
- [ ] Robustify the `.ko` driver L-shim (the answer to "mature drivers" that made forking
  Linux tempting) + LLVM-compile the native kernel (the answer to "faster kernel").

---

## ✅ 2026-07-17 session close — ~31 merges, wide 8-agent fan-out (see STATUS.md for the log)

- **GPU track COMPLETE** — DE + all games present via virtio-gpu zero-copy DMA, **0.20 ms/frame (53.9×)**, SW fallback intact. Games are transitively accelerated (compositor owns scanout). NEXT: venus/virgl 3D for real fill/compute accel (#182, foundation agent in flight).
- **Browser W3C** — broad: flexbox family incl. class-resolved + align-content + shrink; box-sizing/overflow/ellipsis/sticky+fixed/box-shadow+opacity/gradients; JS engine ES-modules→BigInt (+ private-fields/for-await/Symbol.for); DOM lifecycle/geometry/body/viewport-rects. OPEN next: `window` object (in flight), conic-gradient, multi-line getClientRects, full-cascade getComputedStyle, interactive scroll.
- **Adder→C parity** — HONEST metric **1.62× of gcc-O2** on the non-gameable tak suite (fib retired). P1-IR foundation + fused indexed load `8f9fd17b` + fused store-immediate `cae0328e` landed (no regression). Fused indexed STORES `e647aa11` = DO-NOT-MERGE alignment-shadowed (parked). NEXT: ALU-visible geomean levers (non-bandwidth-bound), then loop-body alignment normalization to unpark shadowed levers.
- **hamsh** — Python-class: lambda/set/frozenset/comprehensions/f-strings/dict + real compiler-layer fixes (glued-subscript). NEXT: hashable frozenset dict-keys, `*args`.
- **Games/DE** — Tetris + Minesweeper; polish across file-manager/editor(syntax)/notes/sysmon/pkg-mgr/calendar/audio. Audio guest→host chain CONFIRMED working (ALSA default).
- **Compiler-correctness fixes IN FLIGHT:** `not` operator codegen (suspected untested/buggy), JS `[a,b]=[b,a]` destructuring-assignment (broken — decl works, assignment doesn't).

---

## ⚠ On-device QA bug list (2026-07-17, user testing the shipped image)

Daily-driver blockers found by driving the OVMF image. Verified by looking at the
render / running the gate before merge. Most SHIPPED; see STATUS.md for SHAs.

- [x] Browser `<input>` renders as a real bordered box (was `[___]` underscores);
  Google search box added beside the URL bar (default engine Google). `66176e7f`
- [x] Browser Google JS error partly fixed (`new Image()` stub). Remaining Google
  homepage TypeErrors + `eval` parse gap = broad ES/DOM completeness (own the search
  box → results-page path instead; do NOT boil the ocean).
- [x] **Middle-mouse PRIMARY selection made SYSTEM-WIDE** (`87f63a33`): consolidated
  select→PRIMARY + button-2→paste into shared `lib/hamtextbox.ad` (one place), converged
  editor/Notes/terminal/browser-URL onto it, + a LIVE-event-path gate (feeds raw
  `m x y 4` wire line, 17/17). Root cause was verification+architecture (hand-rolled in
  4 places, prior gate only tested the buffer API), NOT a dropped button-2 event — the
  code path is correct end-to-end (hid→devwsys→app all preserve bit2). ⚠ CAVEAT: the
  on-device failure the USER saw in editor/Notes was NOT reproduced (‑smp2 on-device
  skipped, wedges). If it still fails on-device after this, it's an on-device-only
  event-routing/focus issue the host gate can't see → re-test on a healthier host.
  OPEN follow-ups: browser rendered-PAGE text selection (pixel→DOM-run map, larger);
  file-manager rename / calculator / dialog flat-buffer fields (per-app, 1-liner each).
- [x] Audio prefers ALSA host backend. `e07b1fb4` — USER to confirm they hear it.
- [x] Games: Snake + Chess new apps + Coin Dash wired into Games menu. `c143b446`
  (chess v1 lacks castling/en-passant/under-promotion — documented.)
- [x] Screenshot "select area" dims the LIVE desktop, not black. `03173344`
- [x] Control Center relayouts on resize (black gutter gone). `c29297f2`
  Latent same-bug follow-up: `user/hammonscene.ad` (sysmon) discards resize events.
- [D] **`enter linux` ~30s is DIAGNOSIS-ONLY, not a latency bug** — it's `-smp 2`
  DE-bring-up starvation (self-clears), the D3 SMP-fairness problem. Fix lives in
  the scheduler/DE-bring-up, NOT hamsh. See memory `project_enter_linux_slow_is_d3`.
- [x] Small: `test_hambrowse_float.sh` stale SEG regex fixed (`0a0ba1dd`); + decimal
  length regression gate added.

### Queued fronts (USER 2026-07-17) — dispatch on trigger, protect timing-sensitive slots
- [x] **hamsh pygame-style bindings** DONE (`9acecdea`): `builtin_pygame` verb + rgb()/
  pixel()/poll_event()/ev_* expression fns in `user/hamsh.ad` → hamSDL engine; a game is
  writable in hamsh. `examples/pygame_bounce.hsh` runs 90 frames, host PPM verified. Device
  build unaffected. Gaps: on-device `flip`→/dev/wsys commit, sound, file-loaded sprites,
  fps precision, collision helpers.
- **★ Vulkan UNIFICATION campaign (USER: "make DE + SDL use the vulkan backend").**
  Today `lib/vk` is an ISLAND — hamSDL, the DE compositor (`hamui_host`/`devwsys`), and
  `vk_raster` are THREE separate SW rasterizers. Unify everything onto the vk API so a
  future GPU backend behind that API accelerates the whole desktop + all games at once.
  - [x] **Phase A — vk 2D primitive layer** DONE (`d2a333ad`, `lib/vk/vk_2d.ad`:
    fill_rect/alpha/blit/line as recorded vk cmd-buffer ops; host PPM gate 10/10). Delivered
    the hamSDL/DE→vk2d primitive-mapping table. Gaps for B/C: glyph AA coverage-mask op,
    rounded-rect AA op, scissor/clip rect (windowed compositing).
  - [x] **Phase B — route hamSDL through vk** DONE (`de0dbf5f`): `lib/hamsdl_vk.ad` vk2d-backed
    rasterizer; sdlpong/Coin Dash/pygame now vk clients, byte-identical PNGs (cmp-verified).
    Added vk2d `cov_mask` (glyph coverage) + `fill_roundrect`. ham2048/snake/chess left on
    hamui_host (DE-scene apps, never call sdl_* → Phase C). sdl_* API unchanged.
  - [x] **Phase C — route the DE compositor (hamui_host) through vk** DONE (`12fdb90e`):
    byte-identical pixels (cmp-verified), 6 DE gates pass. Bench 24.3→**32.7 ms/frame** = ~35% CPU
    REGRESSION (RGBA 4B vs RGB 3B + per-pixel clip checks; CLEAR doubled), AS ANTICIPATED (vk2d =
    same SW fill math). USER call: merge now + fix CPU path + start GPU. Kernel devwsys = C.2.
  - [x] **CPU-path opt** DONE (`ad371b2d`): clip-hoist to per-primitive + packed-word opaque
    fill + hoisted-const blend in `lib/vk/vk_2d.ad`, byte-identical (cmp), 12 gates green. DE bench
    **32.7→9.1 ms/frame** — not just recovered: **2.7× FASTER than the original 24.3ms** pre-vk
    rasterizer (CLEAR 9.6→1.8). Games share vk2d → same speedup free. Residual (RGBA 4B blend +
    flatten) only the GPU erases. NOTE: `PACKED` is a reserved Adder token — can't be a local name
    (worked around as `pword`); consider un-reserving for identifier use [[feedback_compiler_quirks]].
  - [x] **Phase D — virtio-gpu backend behind the vk API** DONE (`c732f5ba`+`5fa3bc4e`): new
    `lib/vk/vk_gpu.ad` + `vk_core` seam (SW default / GPU opt-in, refuses if no device; SW present
    byte-unchanged). GPU **CLEAR + PRESENT/scanout** on native virtio-gpu, VERIFIED ON-DEVICE
    (OVMF+virtio-gpu-pci): GPU clear == SW reference byte-for-byte + 4-quadrant scanout screendump
    correct, no leaked qemu. Fixed a dead gate (`HAMNIX_FORCE_SELFTESTS=1`, default off). Still SW: 2D/3D ops.
  - [x] **Phase D.2 — GPU present measurement** DONE (`625ec551`): on-device (OVMF, 1280×800):
    SW GOP present 11.77ms vs GPU present 11.28ms (1.04×, convert-limited) vs **GPU present
    BGRA-native = 0.19ms = 61×**. GPU fb == SW pixel-for-pixel. The convert (RGBA→BGRA) eats the
    win; default stays SW (opt-in `vk_try_enable_gpu_present`). CONFIRMED: base virtio-gpu-2d is a
    scanout device — fills stay CPU-bound (real fill accel needs venus/virgl #182).
  - [ ] **Phase D.3 — BGRA-native present** (unlocks the 61× GPU present) — render the vk color
    image / DE composite directly into a BGRA backing, drop the convert, then flip DE to GPU present
    by default. HOLD: needs virtio-gpu QEMU → wait for the parity big-bangs to free the host (bench).
  - [ ] **venus/virgl 3D (#182)** — real GPU fill/compute accel (the only path to offloading fills).
  - [x] **DE-speed baseline (USER)** DONE (`b3b6e710`): BEFORE = **24.3 ms/frame** @1024×768,
    fills **17.3 ms (~87%)**. `bench_de_compositor.sh` + `docs/de_perf_baseline.md`. Re-run after
    CPU-opt + GPU for the comparison. Caveat: host metric = compositing math; on-device frame-timing
    also needed for a true end-to-end claim.
  - [ ] **3D/accel-prep (parallel):** MVP vertex transform + perspective + indexed meshes
    (`vkCmdDrawIndexed`) + rotating-cube demo — extends the same API. vk_raster already
    does depth-buffered triangles.

### New fronts green-lit by USER (2026-07-17)
- [x] **Scheduler fairness (D3 fix)** DONE (`571d7494`): root cause = fresh forks seeded at
  RAW min-vruntime, so sub-tick DE-bringup storm children (exit with 0 vruntime) re-arrive at
  the pinned-low min and starve a foreground task. Fix = monotonic vruntime floor + seed new
  tasks at floor+one-slice penalty (CFS place_entity). On-device -smp2 fairness gate proven
  (revert-proof). CAVEAT: proven at the scheduler DECISION; full enter-linux wall-clock
  before/after not measured (would confirm the 30s→~few-s user-visible win on-device).
- [~] **Adder → C-speed PARITY (target 1.1×/1.0×)** — HONEST metric now **1.64× of gcc-O2**
  (fib RETIRED as degenerate + replaced by tak/Takeuchi, `a6d682fd`; see
  [[feedback_universal_not_benchmark_gaming]]). Peephole frontier exhausted at ~1.69× (fused
  LOADS `8f9fd17b`; fused STORES DO-NOT-MERGE alignment-shadowed, patch parked). USER GREEN-LIT both
  big-bangs: **(A) XL P1-IR statement-machine rewrite** (`codegen.ad`) — foundation increment
  `cf343155` (compare-operand dest-passing, objdiff-clean, universal but perf-neutral on this
  bandwidth-bound suite); NEXT increment IN FLIGHT = immediate-indexed-store + collatz dst-alias/div
  (the ALU-visible residuals where the geomean moves). **(B) fib recursion→iteration** DONE
  `54969cda` (narrow two-term-recurrence matcher — correct, kept, but why fib was retired as a metric).
  All --opt-gated (flag-OFF byte-identical), objdiff+fuzzer+checksum gated; reject alignment-shadowed
  levers even if correct.

---

## ⚠ Direction (2026-06-20)

**Goal sharpened:** Hamnix is a **good desktop _and_ server OS in the
shape of Plan 9** — not a general "Linux competitor." That target makes
several architectural calls for us (below). Plan 9 spine is real and
held; the next push is foundational hardening, not new surface area.

### ⚠ Compiler strategy REDIRECT (2026-06-21) — Python is the SEED; the optimizer lives in Adder

The original plan put the optimizer in the Python compiler (`codegen_x86.py`).
**Reversed.** The Python compiler is a **bootstrap seed: correct, not fast.** Its
only job is to compile the real (Adder-written) compiler once. Pouring a permanent
optimizer into it means (a) writing the whole IR + passes TWICE (Python now, Adder
later), (b) two compilers that silently diverge — the fuzzer already caught **6
miscompiles** in `codegen.ad` from exactly that drift, and (c) an optimizer that
never runs on-device and proves nothing about the self-hosted toolchain (the
credibility demo). Perf is orthogonal to compiler language — the generated-code
quality lives in the *passes*, so there's no perf reason to keep them in Python.

**New ordering / state:**
1. **Adder Linux target (Tier 2)** — ✅ DONE. `x86_64-linux` freestanding target;
   host-run Adder does real syscalls.
2. **Compiler fuzzer** — ✅ DONE. Predicted-output oracle; found+fixed 3 backend
   miscompiles; 0 over 10k programs. The permanent correctness gate + the
   differential oracle (`--diff-target`).
3. **Self-hosting cutover — NOW THE LEAD COMPILER TRACK.** Finish `codegen.ad` to
   FULL parity with `codegen_x86.py`, then build the `.ad` compiler as an
   `x86_64-linux` host binary so it drives the build with Python as a one-time seed.
   This is the prerequisite for the real optimizer AND the credibility milestone.
   - ✅ **Multi-dimensional array globals** (`Array[N, Array[M, T]]`) — DONE.
     `codegen.ad` now lays out the full nested type into `.bss`, carries the
     array type node per global, and indexes level-by-level (outer index scales
     by the nested row stride, inner by the scalar element). Root fix: the
     index-scale helper handled only power-of-2 widths; added an `imulq` fallback
     for arbitrary row strides (e.g. 24). The differential fuzzer now generates
     2-D grid traffic in BOTH modes; `scripts/fuzz_adder_diff.sh` accept-rate is
     100% with 0 miscompiles. The differential gate now exercises EVERY construct
     the default generator emits (subset==default).
   - ✅ **Parity gaps CLOSED (2026-06-21).** Multi-base receiver-offset bump
     LANDED in `codegen.ad` (`class_end_of_fields`/`receiver_offset_for` +
     `emit_add_imm_rax` bump in `gen_method_call`; fuzzer emits a
     `MDerived(MBase0,MBase1)` inherited-from-second-base method every program).
     By-value struct params/returns REJECTED in lockstep in BOTH backends
     (Adder has no by-value aggregate ABI by design; the seed previously
     SILENTLY miscompiled them — now `CodeGenError` / `cg_fail(9)`). SysV XMM
     extern-FP path documented as intentionally GP-uniform/unused (no extern
     float call exists). (`codegen.ad` already covers 1-D/2-D/scalar globals of
     every width, casts, compares, div/mod, while/for/do-while loops,
     if/elif/else, break/continue, helper calls, pointers, syscalls,
     classes/methods + multi-base dispatch, structs + member access, and scalar
     SSE float32/float64.)
   - ✅ **CUTOVER DRY-RUN PROVEN (2026-06-21).** The full self-hosted compiler
     (lexer+parser+codegen+elf_emit + a new Linux-syscall host driver
     `fused_driver_host_main.ad`) builds as a single `x86_64-linux` host ELF via
     the Python seed and runs. Differential self-compile over the fuzz corpus
     (`.ad` host binary vs Python seed) = **300/300 = 100% behavioral match, 0
     mismatch, 0 unsupported**. No self-hosting fixpoint blocker (the `.ad`
     compiler's own source uses only the flat SoA subset both backends compile).
     Gate: `scripts/test_selfhost_cutover_dryrun.sh`. Validation:
     `fuzz_adder_diff.sh` 4 seeds×400 = 1600 progs 100%/0-miscompile,
     `fuzz_adder.sh` 600 progs 0-miscompile, `test_adder_x86_64_linux.sh` +
     `test_arm64_codegen.sh` PASS. NEXT (not done — deliberately): flip the
     default build driver to the `.ad` binary per the runbook in
     `docs/subsystems/adder-compiler.md` (config switch + CI guard via the
     dry-run + on-device fixpoint gates; Python seed retained as bootstrap +
     fallback).
4. **Userland-isolated drivers (UMDF)** — ✅ DONE (first slice: stock `.ko` in a
   restartable userland host, crash-isolated). Follow-ups: respawn supervisor, real
   BAR-backed driver, `exports.ad` parity.
5. **Kernel scaling rework** — ✅ DONE (O(active) scheduler, NTASKS→512, dynamic-CPU
   guard). Deferred perf items (per-wq locks, softirqs, slab, NUMA/RCU) stay deferred.
6. **Adder code optimizer — REFRAMED: build it IN ADDER, post-cutover.** The
   permanent home of the IR + LICM/CSE/strength-reduction/regalloc is the
   self-hosted Adder compiler (track 3), so it runs on-device and isn't written
   twice. **FREEZE the Python optimizer** at the current `-O1` peephole + `-O2`
   regalloc (Adder/-O2 ≈ 3.0× of C). Those stay ONLY as a baseline + differential
   oracle. Do NOT invest more *permanent* optimizer work in Python. The in-flight
   Python from-AST IR is a throwaway DESIGN PROTOTYPE to validate the pass shape
   where iteration is cheap; its real implementation is Adder-native. Perf goal
   (≤ ~2× of C, ideally parity) is met by the Adder-native passes.

Plus: **gate the two real boot paths in CI** — ✅ DONE (installer-image OVMF
heartbeat, non-blocking).

### Decision points (record, don't lose)

- **Python compiler = seed, Adder compiler = product.** (See redirect above.) All
  *permanent* optimization belongs in `codegen.ad` lineage, post-self-hosting-cutover.
- **LLVM — PERMANENTLY REJECTED (2026-06-21, user decision).** Not the path. We do
  NOT adopt LLVM as a second backend at any point. Perf (≤2×/parity), multi-arch
  (ARM64 already has a native backend), and any CPU mitigations are pursued
  natively in the Adder compiler / hand-rolled backends. Rationale: keep the whole
  toolchain native + self-hosted (the ethos and credibility); a giant C++ dependency
  is off the table. Don't reopen this.

---

## ⚠ Namespace law

Hamnix is **Plan 9-shaped. There is NO global filesystem route.** A
process sees a path only because something was *bound or mounted into
its own namespace*. **No work may write to a global `/var`/`/usr`/
`/etc`/`/var/lib/dpkg`/`/var/cache/apt`/`/var/www`.** All Linux-binary-
shim and distro/package state lives inside a distro-shaped namespace
exported by the userland **`distrofs`** 9P daemon; a shim is launched
`rfork(RFNAMEG)` → mount/bind `distrofs` → exec. A TODO is mis-shaped
if it says "write X to `/var/...`" without "...in the shim's distrofs
namespace" — fix the wording.

## ⚠ Boundary-discipline law

**Layer 1 (native) stays pure 9P / namespace.** The non-file modern
mechanisms — `io_uring`, `epoll`, `futex`, signalfd/eventfd/timerfd —
are the antithesis of "everything is a file." Permitted **only inside
Layer 2** as confined kernel objects for Linux guests. The moment one
becomes a native-code dependency, the architecture has been retrofitted
backwards.

---

## Kernel parity (Linux)

Full ranked gap analysis + waves: [`docs/kernel_parity_roadmap.md`](docs/kernel_parity_roadmap.md).
The Linux ABI shim (`linux_abi/`) is strong; the half-assed gaps are all
in the Layer-1 CPU-side core. Four keystones everything leans on: RCU,
the EEVDF scheduler, and the page-cache + rmap + reclaim triad.

**Wave 1 — foundations (parallel; RCU unblocks the rest)**
- [ ] **RCU core** — Tiny/Tree RCU, QS on ctx-switch + tick, `call_rcu`/
  `synchronize_rcu`. Absent today (`kernel/sched/core.ad:627`). `kernel/rcu/`.
- [ ] **EEVDF/CFS scheduler** — replace the O(NTASKS) min-vruntime linear
  scan (`kernel/sched/core.ad:1050`) with an eligibility/deadline tree.
- [ ] **rmap + struct page** — `anon_vma` + `page->mapping` (fully absent);
  prerequisite for real reclaim AND the page cache. `mm/rmap.ad` (new).

**Wave 2 — big subsystems (depend on Wave 1)**
- [ ] **VFS page cache (`address_space`)** — block-only today
  (`kernel/block/blk.ad:370`); file mmap snapshots backing (`fs/vfs.ad:6102`).
  Unified per-inode page tree + dirty tracking. `fs/` + `mm/`.
- [ ] **LRU reclaim + kswapd + watermarks** — replace the per-task O(tasks)
  walk (`mm/reclaim.ad:69`) with active/inactive LRU + background kswapd.
- [x] **softirq + workqueue pool + tasklet + threaded IRQs** — DONE. Real
  Linux-shape bottom-half stack: per-CPU softirq vectors HI..RCU with
  `raise_softirq`/`do_softirq` on IRQ-return (bounded MAX_SOFTIRQ_RESTART
  loop + ksoftirqd fallback) in `kernel/softirq.ad`; real tasklets
  (SCHED/RUN state machine, run-once-coalesced, self-serialized);
  concurrency-managed workqueue with 4 worker kthreads + `queue_work` /
  `flush_work` / `flush_workqueue` / delayed-work-via-timer in
  `kernel/workqueue.ad` (replaces the 4-slot manual-flush table);
  `request_threaded_irq` now spawns the irq thread + the top half wakes it
  on IRQ_WAKE_THREAD (`linux_abi/api_irq.ad`). Net RX migrated onto
  NET_RX_SOFTIRQ (`drivers/net/virtio_net.ad`): hard-IRQ top half ACKs +
  raises, drain runs in softirq. Proven live by `scripts/test_bh.sh`
  (in-kernel `bh_selftest_run`): all 5 assertions PASS.

**Wave 3 — scale & correctness (depend on Wave 2)**
- [x] **dcache + inode cache (+ rcu-walk)** — page/inode/dentry caches landed
  in `fs/fcache.ad`; the dentry-cache hot read path is now Linux RCU-walk:
  `fcache_dcache_lookup` runs lockless under `rcu_read_lock()` with a per-slot
  seqcount + `rcu_dereference` on the publish point, validates the live
  namespace generation + per-Pgrp key inside the stable read, and degrades to
  a locked ref-walk (`_dcache_lookup_refwalk`) on a torn read. Inserts publish
  `dc_valid` last via `rcu_assign_pointer`; evicted slots are RCU-retired and
  their byte-pool reuse is deferred past a grace period via `call_rcu`. Proven
  by the RCU-walk cases in `fcache_selftest` (`scripts/test_fcache.sh`).
- [ ] **dirty writeback throttling + per-bdi flushers** — none; `fsync` is
  a device-cache barrier only (`fs/ext4.ad:7466`). After page cache.
- [x] **per-VMA locking + maple tree** — DONE (Wave-3): VMAs now indexed by
  an augmented AVL interval tree (O(log n) find/overlap/gap; the sorted list
  stays only as the iterator), each VMA has a per-VMA spinlock, and the
  demand-fault path RCU-looks-up + trylocks the VMA with a per-mm seqcount
  fallback to the mm-wide write lock (Linux `lock_vma_under_rcu` model).
  `mm/vma.ad`; gated by `scripts/test_mm_vma_tree_logic.py` + test_mm_pressure PART E.
- [ ] **hrtimers (ns) + NO_HZ + clocksource registry** — hrtimers are
  jiffies-quantized 16-slot (`linux_abi/api_hrtimer.ad:47`), no tickless.

**Backlog (post-parity scaling / niche):** PELT + sched_domains +
SCHED_DEADLINE; RT signals + tgid thread groups; remaining 5 namespaces +
`setns`; cgroup memory/io/pids + nesting; page-allocator pcplists/zones/
migratetypes; THP/NUMA/KSM; io_uring async + net opcodes; eBPF verifier/
program-types/JIT; fair qspinlock + lockdep + kernel mutex/rwsem.

**Plan 9 law:** native control stays ctl-file-shaped; Linux-ABI parity
stays in `linux_abi/`. RCU/sched/MM/page-cache are shared Layer-1 core.

---

## Track 1 — Adder Linux target (Tier 2: compute + file I/O)

**Why:** run freestanding Adder on Linux at native speed (dev + fuzzing
+ host self-hosting). NOT for GUI/namespace apps — those need Plan 9
emulation on Linux (plan9port-scale), explicitly out of scope. This is
the unlock for tracks 2 and 3.

**Grounding:** `aarch64-linux` already exists and already emits Linux
syscall numbers — mirror it for x86. Userland is freestanding (raw
`syscall`, no glibc).

- [ ] **Register `x86_64-linux` target** beside `aarch64-linux` in
  `adder/compiler/adder.py:34` (`{codegen: x86, kbuild: False,
  bare_metal: False}`). Revisit the `bare_metal` flag — it only gates
  `.modinfo`, wrong proxy for "userspace"; consider a `userspace` flag.
- [ ] **`user/linux-runtime.S`** — Linux x86_64 syscall numbers
  (write=1, read=0, open=2, close=3, lseek=8, exit=60, …) + Linux
  `_start` (argc/argv off the stack). Mirror `user/runtime.S`.
- [ ] **`user/linux-init.lds`** — `elf64-x86-64`, `ENTRY(_start)`, drop
  the `elf32-i386`/`.code64` wrapper trick.
- [ ] **Link path** in `adder.py` (mirror `:527-571` aarch64-linux) —
  `as --64`, `ld -m elf_x86_64 -nostdlib -static`.
- [ ] **Centralize syscall numbers** (high-value cleanup) — today
  scattered as `movq $N,%rax` across `user/runtime.S`; a per-target table
  lets x86-adder-user / x86_64-linux / aarch64-* coexist without copy-paste.
- [ ] **Smoke test** — compile a file-I/O Adder program to `x86_64-linux`,
  run on host, verify read/write/exit reach the Linux kernel.

## Track 2 — Compiler fuzzer

**Why:** de-risk the solo single-pass hand backend. The May 2026 sweep
fixed 5 silent miscompiles (signed/unsigned compare, sub-8-byte pointer
writes, 2-D array addresses) — the surface is real.

- [ ] **Host-test compile target** (depends on Track 1's `x86_64-linux`).
  Reuse computational codegen; only the output/exit primitive maps to
  Linux. Generated programs run natively — millions/hr, no QEMU.
- [ ] **Program generator + predicted-output oracle.** Generator emits a
  random valid Adder program AND computes its expected result by
  construction; compiled program prints actual; compare. Catches the
  whole May bug class with no second implementation.
- [ ] **Crash/assert mode** — fuzz for compiler exceptions /
  `CodeGenError` on valid input.
- [ ] **Batched in-VM pass** for the ABI/namespace surface the host
  target can't cover (syscall numbering, `_start`, 9P semantics): boot
  Hamnix once, feed thousands of programs over a channel — don't reboot
  per program.
- [ ] **Report bug density** — this number gates the LLVM decision.
- [ ] (Later, if LLVM lands) **differential oracle** — same generated
  programs through both backends, compare.

## Track 3 — Self-hosting cutover ★ LEAD COMPILER TRACK (2026-06-21 redirect)

**Why:** close the bootstrap AND unlock the real optimizer. The build is still
Python-locked (`python3 -m compiler.adder`); `codegen.ad` is a ~2317-LOC
self-hosting SUBSET that emits raw machine bytes and drives NO build. This is now
the LEAD compiler track: the Adder-native optimizer (track 6) cannot be built until
the Adder compiler reaches parity and can host it. Progress so far: 6 real
`codegen.ad` miscompiles fixed + a host differential fuzzer (`scripts/fuzz_adder_diff.sh`,
`--ad-codegen`) added; 100% correct over 2400+ programs on the supported subset
(STATUS corrected Done→Partial).

- [ ] **Finish `compiler/codegen.ad` to FULL parity** with `codegen_x86.py` — the
  remaining feature surface that's out of the current subset: multi-dimensional
  array globals, classes/methods, for-loops, structs/member access, do-while,
  floats, `.modinfo`. Validate EVERY addition with `scripts/fuzz_adder.sh` (0
  miscompiles) + the differential mode vs the Python backend.
  - [x] **FLOATS — DONE (2026-06-21), scalar SSE float32/float64 in LOCKSTEP.**
    Implemented in BOTH `codegen_x86.py` (seed/oracle) AND `codegen.ad` plus the
    fuzzer's bit-exact oracle. FP values transit `%rax` as their IEEE bit
    pattern; SSE (`addss/subss/mulss/divss`+`sd`, `ucomi`+NaN-unordered setcc,
    `cvtsi2`/`cvtt`/`cvtss2sd`/`cvtsd2ss`, sign-bit-xor negate) runs only at the
    op site. Validated: differential gate 4 seeds × 400 = 1600 programs 100%
    accepted/correct, 0 miscompiles; Python fuzzer 1500 clean; regress pin
    unchanged. The "seed FROZEN" rule covers the OPTIMIZER ONLY (untouched);
    adding the missing FP correctness feature to the seed was required + allowed.
    See docs/subsystems/adder-compiler.md "Floating point — scalar SSE, LOCKSTEP."
  - REMAINING for cutover: by-value struct params/returns, multi-base receiver
    offset. All other constructs (multi-dim array globals, classes/methods,
    loops, structs, do-while, FLOATS) are LANDED + fuzz-proven.
- [ ] **Build the `.ad` compiler as an `x86_64-linux` host binary** (via Track 1) so
  `adder_cc` runs on the host, compiling Adder→Hamnix at native speed — Python
  becomes a one-time SEED (correct, not fast; freeze its optimizer per the redirect).
- [ ] **Cutover:** make the default build use the `.ad` compiler once it's
  fuzz-proven at parity (the Python compiler stays as the bootstrap seed only).
- [ ] **Run the `.ad` compiler in Hamnix too** (`x86_64-adder-user`) for on-device
  source packages (#186).
- [~] STATUS "on-device self-hosting Done" corrected to Partial (Track 3 pass).

## Track 4 — Userland-isolated drivers (.ko out of kernel)

**Why:** stock `.ko` modules load into kernel memory today
(`linux_abi/loader.ad`) and share the kernel fault domain — a buggy
vendor driver panics the box. A Plan 9 _and_ server-correct OS runs
drivers as restartable userland file servers.

**Scope:** ONE build. `.ko` support stays in every image (server and
desktop alike) and loads on demand based on the hardware present — no
`.ko`-free profile, no separate server build. The goal is to change
*where `.ko` executes* (a restartable userland host, not kernel space),
not whether it's available. Native drivers stay first choice where the
hardware is standardized; `.ko` remains the escape hatch for vendor-mess
HW (consumer wifi, GPUs) — now crash-isolated.

- [~] **User-mode driver framework (UMDF-style).** First vertical slice
  landed: `linux_abi/umdf_kernel.ad` exposes the three privileged
  primitives over a narrow syscall channel — MMIO map (`SYS_UMDF_MMIO_MAP`
  321, uncacheable phys→user VA), DMA alloc (`SYS_UMDF_DMA_ALLOC` 322,
  phys-contiguous + phys exposed), IRQ file (`SYS_UMDF_IRQ_OPEN` 323 +
  blocking read on the returned irq fd, per-vector WaitQueue). The driver
  posts a `#X` server (existing namespace law). Remaining: respawn
  supervisor (auto-restart on crash), real BAR-backed driver.
- [~] **Port the `.ko` loader into a userland host process.** Landed:
  `user/umdf_host.ad` runs the ET_REL load + reloc + symbol resolution +
  `init_module` dispatch in a CPL3 process; the `.ko` lands in mmap'd
  USER memory and `_printk`/MMIO/IRQ/DMA shims bottom out into the host's
  userland shim / the new syscalls. Remaining: broaden the userland shim
  table toward `linux_abi/exports.ad` parity for richer `.ko`s, and `%gs`
  per-CPU handling in userland.
- [x] **Restart/crash-isolation test** — `scripts/test_umdf_host.sh`:
  crashes a userland driver host (NULL deref), proves the kernel + hamsh
  survive, and a fresh host re-inits the `.ko` afterward. Per-task UMDF
  cleanup hook (`register_umdf_task_exit_hook`) reclaims IRQ files + DMA
  buffers on both clean exit and crash.

## Track 5 — Kernel scaling rework

**Why:** static-array ceilings calcify the longer they bake. Lift the
*structural* limits now; defer perf tuning until a workload measures it.

**Fix now (structural — gets harder over time):**
- [ ] **Dynamic CPUs** — `MAX_CPUS=16` static arrays → dynamic per-CPU
  allocation indexed by `smp_processor_id()`. Cite: `arch/x86/kernel/smp.ad`.
- [ ] **Dynamic / list-based tasks** — `NTASKS=256` is now a *static
  array of 256*; the scheduler scans all slots O(NTASKS) to pick next
  (`kernel/sched/core.ad`). Convert to intrusive per-CPU run-lists so
  pick-next is O(active), and drop the hard task ceiling.

**Defer until a contended multicore workload exists (well-trodden, not research):**
- [ ] **Per-waitqueue locks** — replace the global `wq_lock` serializing
  every WAIT↔READY transition.
- [~] **SMP work-stealing + CPU affinity** — per-CPU runqueue + load
  balancing landed (#139/#151/#397); work-stealing and affinity open.
- [ ] **Softirq / threaded IRQs** — IRQ handlers run in hard context
  today (`arch/x86/kernel/irq.ad`); add bottom-half deferral.
- [ ] **Per-CPU slab cache** — single global free list contends under
  fork storms (`mm/slab.ad`).
- [x] **Buddy merge-on-free** — DONE: `_free_pages_raw` coalesces XOR-buddies
  up to `MAX_ORDER` (canonical `__free_one_page`) under the IRQ-safe buddy
  spinlock (`mm/page_alloc.ad`). Asserting self-test
  `page_alloc_coalesce_test` + `scripts/test_buddy_coalesce.sh`.

**Deep / punt until measured:** NUMA-node awareness + per-node pools;
RCU read-side for task/VFS traversal.

- [x] **LRU-ordered reclaim + rmap + kswapd + writeback throttling** —
  Linux-shape MM parity landed: per-PFN struct-page array (`mm/page.ad`:
  flags/mapcount/LRU links/rmap word); anon reverse map (`mm/rmap.ad`) so
  reclaim finds a page's mapper without walking every task's page tables;
  active/inactive LRU with second-chance/CLOCK (`mm/lru.ad`); watermark-
  driven kswapd + direct reclaim (`mm/kswapd.ad`, low/min/high over
  memblock-headroom+buddy-free); dirty/writeback accounting +
  balance_dirty_pages throttling (`mm/writeback.ad`); LRU-tail scanner
  `reclaim_shrink_lru` evicts the coldest single-mapper anon pages via
  rmap (`mm/reclaim.ad`). OOM killer kept as the last resort. Proven by
  `scripts/test_mm_pressure.sh` PART C.

## Track 6 — Adder code optimizer (→ rough C territory)

> **★ REDIRECT (2026-06-21): the optimizer's permanent home is the ADDER compiler,
> not Python.** The Python `-O1` peephole + `-O2` regalloc below are LANDED and stay
> ONLY as a baseline + differential oracle — **the Python optimizer is FROZEN; do not
> add more permanent passes to it.** The real IR + LICM/CSE/strength-reduction/regalloc
> is built in `codegen.ad` AFTER the self-hosting cutover (Track 3, the lead track),
> so the optimizer runs on-device and isn't written twice. LLVM is **permanently
> rejected** (not the path) — the native Adder optimizer is THE route to ≤2×/parity.
> An in-flight Python from-AST IR is a THROWAWAY design prototype only.

**Why:** compiled Adder is sound but unoptimized. Baseline
(`docs/bench_adder_host.md`, `scripts/bench_adder_host.sh`): geomean
~1.6× of `gcc -O0`, ~4.3× of `-O2`, ~24× faster than CPython. The `-O2`
gap is concentrated in a few classic passes, not anything LLVM-scale.

**Goal:** rough C ballpark — **target ≤ ~2× of `-O2`** (from ~4.3×).
Non-goal: `-O2` parity / auto-vectorization.

> ### ★★★ TARGET MET (2026-07-07, orchestrator-verified on a quiet host)
> The **native Adder** optimizer (`--opt` / `ADDER_OPT=1`, 6 passes: const-fold,
> CSE, LICM, DCE, branch-fold, copy-prop) is at **geomean 1.83× of `gcc -O2`** —
> inside the ≤2× target, and *faster than* `gcc -O0` (0.56×). Optimizer ON vs OFF
> = 3.52×. Every kernel is now <2× of `-O2` except **fib (2.93×)** — irreducible
> recursive call/prologue overhead, which inlining cannot help; diminishing
> returns, left alone. Numbers: `docs/bench_opt_results.md`
> (`bash scripts/bench_opt.sh`; `rm -rf build/fuzz_ad_codegen` first).
> Measure on a QUIET host — the previously-committed 2.49× was a stale,
> under-load measurement, not a real regression.
>
> **This track is therefore on HOLD**, behind Firefox + interactive-OS QA per the
> user's sequencing. Do not open a new optimizer agent unless the user
> re-prioritizes. Default codegen (flag OFF) stays byte-identical to the seed.

The stale Python-era progression below (4.28× `-O0` → 3.47× `-O1` → 3.03× `-O2`,
geomean of `-O2`) is the **frozen Python seed's** asm-level passes, kept only as a
baseline + differential oracle. It is NOT the product optimizer.

- [x] **Increment 1 — `-O1` peephole optimizer (LANDED 2026-06-20).**
  `adder/compiler/peephole_x86.py`, gated behind `adder compile -O1` (default
  `-O0` single-pass path, used by the Hamnix image build, is unchanged).
  Four local provably-safe transforms over the emitted asm: condition→branch
  fusion, dead store-reload elim, immediate-push folding, push/pop→scratch
  forwarding (unwinds the stack-machine memory traffic via the unused
  `%r8`–`%r11`). **Result: geomean 4.24× → 3.45× of `-O2`** (1.23× speedup;
  fib 1.43×, mmul 1.38×, sieve 1.35×). 0 fuzzer miscompiles at `-O1`
  (`FUZZ_OPT=1 scripts/fuzz_adder.sh`). The IR-based steps below are the next
  increment (the peephole can't express LICM/strength-reduction/regalloc).
- [x] **Increment 2 — `-O2` stack-slot register promotion (LANDED 2026-06-21).**
  `adder/compiler/regalloc_x86.py`, gated behind `adder compile -O2` (runs
  after the `-O1` peephole; default `-O0` image-build path unchanged).
  A register allocator *over the stack slots*: the stack-machine backend keeps
  every local in an `OFF(%rbp)` slot and round-trips it through memory on every
  access; this pass promotes each function's hottest address-never-taken
  full-width scalar locals into the five callee-saved registers `%rbx,%r12–%r15`
  (never emitted by the backend, never scratched by `-O1`). Promotion is
  proven-safe per slot: only when *every* `OFF(%rbp)` appearance is a plain
  8-byte `movq` load/store (any sized/`movz*`/`movs*`/`lea`/indexed/canary use
  disqualifies it). Saves/restores via a fresh enlarged-frame slot at the
  prologue + before every `leave`. **Result: geomean 3.47× → 3.03× of `-O2`**
  (1.14× over `-O1`, 1.41× over `-O0`; sieve 2.69→2.13×, lcg 1.89→1.51×,
  collatz 5.92→5.26×, mmul 5.52→5.09×). **0 fuzzer miscompiles at `-O2`**
  (`FUZZ_OPT=2 scripts/fuzz_adder.sh`; 2000-program CI batch + 8000 soak).
  Implemented at the asm level (operates on emitted text per-function) rather
  than as a from-AST SSA IR — the same proven-safe, incremental shape as the
  `-O1` peephole, and it captures the single biggest win (memory round-trips)
  the IR was wanted for. The from-AST IR + the remaining IR-level passes below
  are still the next increment.
The three steps below were the *Python-track* plan. They were **superseded by the
2026-06-21 redirect and are now DONE natively in Adder** (`adder/compiler/{ir,cfg,opt,regalloc}.ad`,
STATUS T4/T8/T18/T18b) — the IR, LICM, CSE, DCE, copy-prop and linear-scan regalloc all
live in the self-hosted compiler and run on-device. Kept here only so the history reads
straight; do NOT implement them in Python.

- [x] ~~**Step 0 — introduce a minimal IR.**~~ Done in Adder: basic-block + value IR
  (`ir.ad`) + whole-function CFG/liveness (`cfg.ad`).
- [x] ~~**Loop-invariant code motion + strength reduction.**~~ LICM landed (`opt.ad`,
  zero-trip/trap-safe). Strength reduction not separately needed to hit the target.
- [x] ~~**CSE + simple inlining.**~~ Cross-statement CSE on extended basic blocks landed
  (with conservative aliasing-store invalidation). Inlining not needed to hit ≤2×.
- [x] **Validate:** every pass preserves results — gated on the fuzzer's `ADDER_OPT=1`
  correctness lane, flag-off objdiff byte-identity, and `scripts/bench_opt.sh`'s
  per-kernel checksum equality (a miscompiling kernel is excluded from the speed
  table, not timed). Ratio tracked in `docs/bench_opt_results.md`.

**Remaining (only if the user re-prioritizes perf):** a full IR-consuming backend
(IR coverage is ~87% of binary-op roots today; the rest still falls back to the
stack-machine emit path), and instruction-selection IR (#493+).

## Kernel hygiene — the `name0` byte-order trap

- [ ] **Two `name0` fields, opposite byte orders, same name.**
  `TaskStruct.name0` (`kernel/sched/core.ad:248`) packs **MSB = char 0**;
  `KmemCache.name0` (`mm/slab.ad:72`) packs **LSB first**. Each is
  self-consistent, but the collision is what produced the `driftfok` bug:
  `kernel/softirq.ad` spelled its task tag in slab's order, so `ps` rendered
  PID 1 as garbage, and three sibling tags (`kworker`, `irq#thr`, `kthread`)
  were 7 chars so their packed word led with a NUL and rendered an **empty**
  COMM. Fixed in `06b1bf11`, but the trap is structural — it will bite again.
  Give the two fields distinct names (`comm_tag_be` / `cache_tag_le`) or a
  shared `pack_tag()` helper, so the convention travels with the type rather
  than living in comments.

## CI / verification gap

**Overhauled 2026-07-10 (was 14 gates, all green-or-nothing; now 116 gates,
three-valued, sharded).** `ci.yml` is now: a Tier-1 host-selftest job (compiler/
optimizer/codegen, no QEMU), a 12-way round-robin-sharded bare-metal battery
driven by `scripts/ci_battery_manifest.txt` (`scripts/ci_run_battery_shard.sh`,
per-gate `GATE_TIMEOUT`, 50-min ceiling), and the installer OVMF boot-heartbeat
job that **does** build `build/hamnix-installer.img` every push. Docs-only pushes
skip the workflow (`paths-ignore`). Adding a gate = one line in the manifest.

- [ ] **The two `test_distro_*` gates are in NO registry — and one of them is red**
  (found 2026-08-03 while verifying the 1.0 version bump). `grep -c test_distro_namespace
  scripts/ci_battery_manifest.txt scripts/list_host_gates.sh` = **0 and 0**; same for
  `test_distro_debian`. They boot QEMU, so the host sweep excludes them by construction,
  and nobody ever added them to the battery — **CI has never run either one, so there is
  no baseline and they may have been failing for a long time**. `test_distro_debian.sh`
  currently FAILs `qemu rc=124`: the guest never reaches the prompts, so every banner
  MISSes, including `12.4` assertions no recent change touched. The 1.0 bump is
  **not** the cause (version strings + the hand-counted `uname.ad` length literal are
  consistent; the DE visual gate renders 3/3 apps on the same tree).
  Suspect the hardcoded `timeout 60s` at `scripts/test_distro_debian.sh:146` — a fixed
  60 s budget for a whole boot cannot survive a loaded host (observed failing at load
  average ~10). Fix the budget (or make it adaptive), confirm a PASS isolated on a quiet
  host, THEN add both to the manifest. Do not register them while red.
  This is another instance of [[project_unregistered_gate_backlog]] — 1495 gates on
  disk, 528 in the manifest.

- [ ] **`test_installer_nvme_inram.sh` (installed-disk, real OVMF) still un-gated**
  — it hard-requires `/dev/kvm` (SKIPs without it) and runs a 3-stage
  install→reboot→boot flow too slow for TCG. Gate it on a KVM-enabled
  self-hosted runner, or shrink the install payload. (The USB/installer OVMF
  boot-heartbeat path IS gated now.)
- [ ] **Test-migration sweep — continue on a quiet host (the highest-yield bug
  finder this project has).** Migrating dark `MISS→hard-FAIL` gates onto the
  three-valued `verdict_boot_gate`/`_hamsh_drive.sh` and investigating whatever
  doesn't cleanly PASS found **9 real hidden kernel bugs** across the
  syscall / dm / ext4 / block-storage / AHCI families (2026-07-10). Families
  SWEPT (mechanical or bug-yielding, now gated): Linux-ABI syscall selftests,
  /dev+srv, ext4-core, block/storage+AHCI, core net stack (MECHANICAL — stack
  sound). Families NOT yet swept (candidates, may hide bugs): **usb/xhci**,
  **mm/page/slab/vma**, **ext4-stretch** (csum/fast_commit/resize/verity/
  fscrypt/bigalloc/flexbg/eainode/multigroup), the **NIC L-shim** gates
  (e1000e/r8169/net_irq), the **TLS/HTTPS** net gates (need offline TLS
  fixtures), and `test_ahci_ko`/heavy `.ko` L-shim gates. Also: `test_socketpair`
  and `test_net_dns_cache` want a `_hamsh_drive.sh` / offline-fixture follow-up.

---

## Native-capability push (2026-07-10) — reduce Linux-ns reliance

USER DIRECTIVE: make the OS as capable as possible natively; Linux ns is a
fallback, not a primary. Pushed back on "compete with Firefox/Chrome / full
Python" parity framing (unwinnable) → reframed to winnable targets. All
dual-target + host-iterable. See memory `project_native_capability_push`.

Landed + pushed:
- [x] **Native JS engine** `lib/jsengine.ad` — ES5/basic-ES6 tree-walking
  interpreter, dual-target; host gate 10/10 exact-output PASS; `js_eval` +
  host-binding API for the browser's future DOM. Native gate BLOCKED on the
  FPU gap above (kept in-tree, un-wired). `05ebc230`+`9d9d9ae3`+`b6d2977b`.
- [x] **Browser CSS cascade** — `<style>` element/`.class`/`#id`/descendant
  selectors + specificity, `color`/`bg`/`font-weight`/`text-align`/
  `display:none`, `rgb()`+named colors, inline-style override; `TODO(js)`
  hook left for `js_eval`. Host gate 48 assertions PASS. `c3dc99dd`.
- [x] **Browser PROPER GRAPHICS (2026-07-11)** — the host pixel engine
  (`lib/htmlpaint.ad`/`htmlpage.ad`) replaced the monospace char grid with a
  real pixel canvas: (1) a from-scratch pure-Adder TrueType rasterizer
  (`lib/font_ttf.ad`) with 4×4-supersampled grayscale anti-aliasing and
  continuous CSS `font-size` (h1..h6 hierarchy, bold/serif/mono faces); (2) a
  from-scratch pure-Adder PNG decoder (`lib/png.ad`: DEFLATE inflate + all 5
  unfilters, RGB/RGBA/gray/palette) wired to `<img>` decode+alpha-blit
  (`lib/htmlimg.ad`). Host gates `test_hambrowse_gfx.sh` (17) +
  `test_hambrowse_img.sh` PASS. Gaps: PNG-only, nearest-neighbour scale, no
  float text-wrap. Presenting this on the NATIVE on-device browser via the v2
  blit protocol is in flight (task #79).
- [x] **ext4 fast-commit + largedir corruption fixes** — page-cache
  invalidation on FC replay (`f2972fad`); leaked-inode multiply-claim
  (multi-group `ext4_free_inode` + `_ext4_drop_inode_link`, `6acd2d36`).
- [~] **hamsh dual-syntax** — Python-indentation ⟷ curly, fully
  interchangeable (context = default only). Agent in flight (task #44).

## Kernel hardening & correctness

- [~] **CPU-mitigations.** SMEP + SMAP page-stamp landed; **Spectre-v2
  landed** (2026-07-10, `c2a56419`): IBRS/STIBP/SSBD via `IA32_SPEC_CTRL`
  (CPUID-gated) + IBPB on cross-address-space context switch; `-smp 2`
  heartbeat verified clean. Still **open: SMAP CR4-flip, KPTI, MDS
  VERW-on-return.** KPTI deferred with a concrete plan — this kernel's
  swapgs-less `%gs`-offset entry + high-half entry pages make a live CR3
  switch triple-fault-prone (see task #48). SMAP flip is gated OFF because
  high-half kernel pages are US=1. Cite: `arch/x86/kernel/trap_diag.ad:382`.
- [ ] **FPU/SSE/AVX context-switch save/restore (FOUNDATIONAL).** The
  context switch (`__switch_to_asm`, `arch/x86/kernel/sched_asm.S:50`)
  swaps only callee-saved GPRs — NO `fxsave`/`xsave` of the FPU/vector
  file. So any native float64/SIMD corrupts under preemption (found via
  the native JS engine: `2.0*3.0+1.0`→`1`), and likely corrupts SSE/AVX
  Debian-ns binaries too. Secondary: APs enable XCR0/OSXSAVE but never
  `CR4.OSFXSR`/`OSXMMEXCPT`. Fix dispatched (task #49); acceptance = the
  BLOCKED `test_jsengine_native.sh` goes green. See memory
  `project_fpu_ctxswitch_gap`.
- [ ] **Intermittent EFI-stub #PF during kernel load (OVMF).** A #PF in
  the EFI stub right after "kernel ELF read OK" ("Can't find image
  information"), intermittent — a shipped/installer boot-reliability risk
  (task #50). Not introduced by userspace work.
- [ ] **Suspend/resume.** S3 path real; HW wake-vector trampoline in
  `entry.S` pending. S0ix later.
- [ ] **F2 thin-shim conversion.** `SYS_NICE`/`SVC_CTL`/`NETCFG`/
  `RESOLVE`/`WSYS_*` syscall arm BODIES still duplicate the ctl-file
  implementation in `arch/x86/kernel/syscall.ad`; replace with thin
  delegations.
- [~] **#439 post-exit wedge.** Boot-CR3 guard landed
  (`mm/page_alloc.ad:40-65`); a probabilistic reclaim-path
  double-free/cycle in `_try_remove_buddy` may remain — needs runtime
  verification. WIP snapshots on `worktree-agent-ae2373654138b1014`
  (`9944f32b`), `worktree-agent-a9c57d837298c09e7` (`a22bd04f`).
- [~] `stat`/`fstat` per-backend hooks — `do_stat` migrated to hook
  table (`47ab21c5`); `do_fstat` per-server migration deferred.
- [~] Delete the global `/var` tmpfs — per-Pgrp bind `/var → #t/var` in
  place; backend `vfs_mount` router entry removal needs FS-routing
  migration.
- [~] Plan 9 `note_group` + cross-task `/proc/<pid>/note` landed
  (`660978bb`); runtime verification pending.

## P9-shape hammer — long tail

- [~] **F7 #390** — FD-mark fold continuation. Pipes next (highest
  leverage).
- [ ] **F10-4 … F10-12** — remaining F10-audit findings (afd Tauth,
  `init/main.ad` split, full Dir-record atime/mtime + per-task uid, etc.).

## Interactive-QA sweep 2026-07-08 (orchestrator, shipped image over serial)

Every item below was found by DRIVING the shipped `hamnix-installer.img` under
UEFI/OVMF, or by disbelieving a green/red gate — none by the suite behaving as
designed. Seven gates were found lying (five false-red, two false-green).

Landed + pushed:
- [x] Installer image build restored (pinned 512 MiB rootfs → auto-size w/ floor).
- [x] `/proc/{mounts,stat,diskstats}` honour the read offset — `df` no longer
  spins forever and wedges the console.
- [x] `uptime` reports seconds not seconds/100 (two `/proc/uptime` renderers).
- [x] `ps` no longer prints uninitialized memory for PID 1 (`name0` byte-order);
  `/proc/tasks` renders full `comm`; closed a latent `/proc` buffer overrun.
- [x] `ls /bin` enumerates — shadow tmpfs overlay roots opened as 0-byte FILES.
- [x] **#471** apt-NX VMA straddling-alias fix, gated by a differential run.
- [x] **hamsh pipelines actually carry bytes** — were 100% broken behind a
  false-green `test_pipe.sh` (builtin LHS never bound a pipe; external stages
  raced the post-spawn parent bind, invisible under TCG).
- [x] **ext4**: the 9th concurrently-open file no longer reported as ENOENT
  (global 8-entry table → 512; EMFILE no longer laundered into ENOENT).
- [x] **Infinite `FUTEX_WAIT` park** for large thread groups — the "bounded"
  park had no timer to fire its self-heal; killed every heavily-threaded Linux
  app. Fixed with `_futex_sweep_expired()` on the arch tick + locked slots.
- [x] `test_mm_pressure.sh` resurrected (was unbootable: 337 MiB kernel into
  256 MiB); heartbeat canary given an `-smp 1` control arm.

Systemic test-infra finding (HIGH — up to ~600 gates affected):
- [ ] **The `-kernel` `-m 256M` gates are GREEN on CI and RED on any dev host
  that has run debootstrap.** `build_initramfs.py` defaults
  `HAMNIX_DEFAULT_REAL_DEBIAN=1`, which stages the whole debootstrap closure
  (`tests/distros/debian-minbase/rootfs/`, 351 MiB) into the initramfs blob
  linked *into* the kernel ELF → ~337 MiB. GRUB then fails to load it at
  `-m 256M` (`error: out of memory. / you need to load the kernel first.`),
  before the kernel runs a single instruction, so EVERY assertion "fails". The
  fixture is **gitignored**, so a fresh CI checkout has only busybox → a small
  kernel → the same gates pass. Confirmed on `test_devtime`/`test_devpid`
  (identical GRUB OOM to `test_mm_pressure`, which was fixed with
  `HAMNIX_DEFAULT_REAL_DEBIAN=0`). ~600 scripts match `-m 256M` + `-kernel` +
  `build_initramfs` without that flag. These are kernel/unit tests that need no
  Debian userland. **Fix at the source, not 600 files** — e.g. the `-kernel`
  test path defaults to a busybox initramfs (real-Debian tests opt IN), or the
  `_kernel_iso.sh` shim bumps `-m` when the kernel ELF is large. Architectural
  call — one sweeping agent, on a quiet host. NOT a product regression (the
  shipped installer image boots + the DE renders; only the dev-host `-kernel`
  unit lane is affected).

Open blockers (agent-owned):
- [ ] **`-smp 2` guest wedge** — an idle shell (and any pipeline) halts in
  `kernel/sched/core.ad::yield_to_others`; `-smp 1` fine. Repro is 70 s / one
  command; suspect #413 steal-window. See [[project_smp2_idle_wedge]] in memory.
- [x] **Firefox — DEEP-TRACK, verdict final (2026-07-11).** NOT a Hamnix bug we
  can fix. Software GL/EGL (Mesa llvmpipe over `wl_shm`) now WORKS on the
  compositor (weston-simple-egl renders — merged). With EGL present, Firefox's
  wall MOVED UPSTREAM of gfx: the main thread parks in libc `sem_wait` (never
  reaches `gfxPlatform`/EGL). A kernel-futex investigation (task #78) DISPROVED a
  lost-wakeup: `clone(CLONE_VM)` shares the creator's cr3 so every pthread sibling
  computes an identical private `_futex_key` (WAIT/WAKE match), the blocking-park
  arm is race-free under `_futex_lock`, and a 9-thread/3200-directed-wake
  `sem_pingpong` gate PASSES — the `matched 0 waiters` storm is benign counting-
  semaphore behavior. So it's a Gecko-internal circular wait, confirmed. Firefox
  stays behind the native browser per the user's fallback framing; the EGL config
  flip is preserved dark on `worktree-agent-a10dac83395dbcb75`. See
  [[project_firefox_startup_deadlock]].
- [x] `ls /dev` named `blk` unconditionally → a stripped (non-hostowner) ns named a
  path it couldn't open (`lsblk` failed). FIXED (`50d7d9ec`, #9): the /dev listing
  now hides `blk` in any ns that can't open it (same hostowner rule as the open
  gate) across all 3 emitters; also closed an info-leak where `sys_listdir` /
  `vfs_listdir` bypassed the permission check and enumerated device names for any
  uid; `lsblk` degrades a denied open to "no accessible block devices". Boundary
  NOT weakened (not a re-bind). Gate `test_dev_blk_ns_visibility.sh`.
- [ ] Flip `test_pipe.sh` / `test_multipipe.sh` back to `-smp 2` once the wedge
  lands — they default to `-smp 1` to dodge it, which hides it.

## Interactive-QA sweep 2026-07-13 (orchestrator, hands-on install QA — CLOSED)

The user returned from testing the installed image with a ~18-item hands-on list;
driven as one agent wave (worktree-isolated), each fix render-/gate-verified
before merge. All shipped through `1a9b333e`. See STATUS.md "QA-by-using wave 7"
for the full narrative. Tasks #199–#217. Every item below is DONE + pushed:

- [x] Startup calc = the broken legacy `/bin/hamcalc` → autostart repointed to `/bin/hamcalcscene` (#199).
- [x] Calendar inert → real stopwatch + date-select relative-time + month/arrow nav; panel-clock unified on `/bin/hamcalscene` (#201).
- [x] Notes: no save/new → Save (Ctrl-S)/New (Ctrl-N)/multi-note + persistence to `/home/live/Notes` (#202).
- [x] Menu crowded → MATE menu (search + Recent + category headers all visible) (#206).
- [x] Linux Process Viewer wouldn't open → CLI (`Terminal=true`) entries now hosted in `/bin/hamtermscene` (real window), not the surface-less Wayland-client path (#207).
- [x] Panel right-click "giant widget list" → MATE **Add to Panel…** searchable categorized applet chooser (#210).
- [x] Legacy Settings duplicate → delisted `/bin/hamsettings` everywhere; Control Center is the sole surface (#211).
- [x] File-manager right-click → added **New File** beside New Folder (#212).
- [x] 2048 slows down → growth DISPROVED; real cause was the ~1.8s/move blocking animation, cut to ~0.9s (10→5 commits, 200→50ms) (#209/#214).
- [x] Mouse wheel inverted in EVERY app → raw hardware wheel sign normalized to the `/dev/mouse` contract at the driver layer (PS/2 + USB HID + Wayland); upstream of the correct #123/#141 fixes (#200).
- [x] Ctrl+Alt+Left/Right (workspace) + Ctrl+Alt+T (terminal) → compositor already dispatched them (#124); PS/2 driver now emits the `ESC[1;7D/C` / CSI-46 sequences (#213).
- [x] `ifconfig`/Control-Center IP "error" → a #163 uaccess regression: `do_netcfg` ran `access_ok()` on the KERNEL staging buffer; stale checks removed (FIB on-device gate PASS-ALL) (#203).
- [x] Installer still on the INSTALLED system → launcher gated on the live-only `/etc/installer-medium` via a new `X-Hamnix-LiveOnly` desktop key; completion message moved above the footer buttons (#204).
- [x] Freshly-provisioned home empty → `/etc/skel` (Desktop/Documents/Downloads/Pictures + welcome), copied by the installer and chowned to the user via a new ext4 `chown` ctl verb (#205).
- [x] Screenshot claimed `/root/screenshot` (no such home) → routed to `/home/live/Pictures` with a runtime mkdir (#208).
- [x] google.com "loads but isn't usable" → `_serialize_form` never prepended the form `action` (submit reloaded the homepage); fixed → `NAV /search?q=…` (#215). Then the on-device follow-up: wired the browser front-end so a click focuses a field, typed chars edit the DOM value, and Enter/submit navigates (#216).
- [x] Systemic: DE scene-client search boxes (app-menu, panel chooser) rendered but weren't typable — the clients now read the per-window `/dev/wsys/<wid>/keys` stream and feed the existing filters; the compositor already delivered keys to the focused window (#217).

Merge-bar lesson banked: an agent's `install.ad` used a `Ptr[uint8]` string global
the frozen seed accepts but the native x86 backend rejects — caught before push;
always native-verify (`--target=x86_64-adder-user`), never trust a seed-only
"compiles clean". See [[feedback-compiler-quirks]].

## hamUI / DE track

- [~] **`lib/hamui.ad` MATE-class widget set** — menu/menubar,
  scrolledwindow, dialog/modal, notebook/tabs, radio, slider, spinbutton,
  combobox, progressbar, separator, image, toolbar, statusbar,
  treeview/grid, multi-line textview; grid layout + per-widget
  align/expand/fill, dynamic editing, destruction, damage tracking.
  v1 + Inc 1/2/3 landed.
- [~] **Rio-faithful reshape** — `#w` per-process bind landed; image+
  dirty-rect wire format being implemented across devwsys+hamUId+hamui.
- [ ] **DE pivot finish — substitution not addition.** Physically remove
  the dead `daemon_pixel` render fallbacks (~20K dead LOC in
  `user/hamUId.ad`); replace with a thin router. Target: `user/hamUId.ad`
  below ~10 KLOC.
- [ ] **hamsh `use hamui`** — bindings; may need hamsh closures + event
  loop + persistent state.
- [ ] X11/Xvfb bridge in a `kind=fb` layer (path to Firefox/Chromium).
- [~] BDF font store landed; runtime font-file loading deferred.
- [x] **Cursor hotspot + terminal input lag FIXED** (2026-07-10,
  `5bed1f72`+`f6878b17`). Cursor hotspot was already correct in the kernel
  (`cb202157`) but ungated — added `test_de_cursor_hotspot.sh`. The ~0.5s
  terminal echo lag was hamterm busy-polling (`sys_read_nb`+`sys_yield`
  kept it READY; `yield_to_others` naps a full 10ms tick, compounding
  across every always-ready poller); fixed by making hamterm event-driven
  via `sys_waitfds` (parks on `/keys`,`/pointer`,`shell-stdout`).

## GPU / graphics (#181–185, native-first)

Target: glxgears + vkcube spinning in a hamUI window, accelerated where
present. **Laws:** (1) DE never requires the Linux *namespace* — baseline
is native Vulkan + native software rasterizer (NOT lavapipe). (2) `.ko`
modules via the L-shim ARE used (`i915.ko`); `.ko` ≠ namespace.

- [~] **#181 Phase 0** — native Vulkan spine + software rasterizer + WSI.
- [~] **#182 Phase 1** — native virtio-gpu + native venus in a VM.
- [~] **#183 Phase 2** — DE composites via native spine; Linux X11 apps
  bridge in via venus-shaped ICD + Zink (optional).
- [ ] **#184 Phase 3 (METAL)** — Intel i915 silicon via `i915.ko`.
- [ ] **#185 Phase 4 (optional)** — native ANV-equivalent.

## Driver / storage / input maturity

- [ ] AHCI NCQ (serialises on slot 0); hot-plug / COMRESET retry;
  multi-port naming (`sd1`…).
- [ ] NVMe multi-queue + multi-namespace.
- [ ] Partition: extended-CHS, BSD disklabel, APM; GPT UTF-16 names;
  `mount /dev/sd0p1 /mnt` path-to-slot resolver.
- [ ] ext4 mkfs multi-block-group layout + journal at mkfs time; ext4
  truncate on index-node files; growing a full dir block (prior attempt
  `bc1cb9c8` reverted `bb7ba653` — broke heartbeat boot).
- [~] Networking forwarding-path auto-wiring (gated behind
  `ip_forwarding_enabled`, default 0).
- [ ] Input: dead-key / compose / IME; blocking read on `/dev/mouse`;
  MADT IRQ-override consumption.
- [ ] stock-Linux `.ko` coverage: `MAX_EXPORTS` bumps; `usbcore`+
  `xhci_hcd`, `libphy`, `8021q`, `nf_conntrack` core. (Reconcile with
  Track 4 — `.ko` work should target the userland host, not the kernel.)

## Userspace polish

- [ ] `enter linux { /bin/sh }` interactive stdin doesn't reach the Linux
  process (sshd sessions have their own pty).
- [ ] Nested `` `{ } `` command substitution clobbers (hamsh).
- [ ] busybox `ls` enumeration XFAIL (musl DIR-fd round-trip); busybox
  `sh -c "a|b"` internal-pipeline `#GP`.
- [ ] `/bin` tool audit for cwd-relative defaults.
- [ ] CPython: trim frozen stdlib; PGO/LTO; C extensions once a U-track
  `ld.so` exists.
- [ ] TEMP_DEBUG cleanup pass when bring-up stabilises.

## Metal bring-up (human-in-the-loop)

- [ ] **xHCI v1 metal** — HCH-clear MMIO poll wedges on real Intel NUC;
  USB mouse dead on metal.
- [ ] Asus i5-4210U boot crash; built-in keyboard never responded under
  Legacy/BIOS (hypothesis EHCI-routed).
- [ ] MMIO-stall class audit: ehci, ahci, nvme.
- [ ] Real NIC silicon: e1000e EEPROM on Intel; r8169 RX on RTL8168;
  Broadcom tg3; Intel igb; NUC I219 silent.
- [ ] Drop the FAT12 32 MiB ESP cap via GPT-ESP path.
- [ ] **#117/#118** — verify >4GB fix kills real-HW #UD + persisted logs
  (USB boot at `-m 8G`).

## Bigger lifts — no immediate plan

- [ ] iwlwifi / ath11k / mt76 — real radios. Firmware via the planned
  `non-free-firmware` channel.
- [ ] Browser in a hamUI window — gated on hamUI Phase 5 (X11 bridge).
- [~] Multi-arch ARM64 (#175) — aarch64 backend landed; full bare-metal
  kernel port (Phase 3+) open. **Note:** an LLVM second backend (see
  Decision points) would subsume much of this.
- [ ] **Arch convergence** — factor an arch-interface; link a shared
  portable core into ARM64. Do once ARM64 bring-up is stable.
- [ ] Signed package indexes (sha256 covers tarballs; index unsigned).

## 2026-08-04 — host/CI tooling: Pillow was never installed

- [x] ✔ **FIXED (`7d41bb3f`)** — `test_hambrowse_{flexwrap_qa,gridareas,gridpng}_host.sh`
      were DARK, not failing: `ModuleNotFoundError: No module named 'PIL'`, and
      all three PASS on unmodified main once it is installed. Ten scripts import
      PIL, including `render_hambrowse_png.py` and `framediff_*` — the whole
      visual-QA path. Installed on the dev host; added to the CI host-selftest
      job with `pip` (not apt's `python3-pil`: that job runs `actions/setup-python`,
      so the apt package installs into a different interpreter).
- [ ] **Sweep the rest of the gate corpus for the same class.** Three of 200
      hambrowse gates were dark on ONE missing dependency, and they were only
      found because a merge forced a full sweep. `list_host_gates.sh` counts
      ~583 gates; nobody knows how many of the other ~383 have never executed.
      A cheap first pass: run every gate once on a quiet host and classify
      non-PASS into {real red, missing dependency, dead gate}.
