# System-wide text selection + X11-style dual clipboard (task #315)

Text handling is baked into the shared backend so it populates everywhere,
rather than each app reinventing it. Two layers:

## 1. `lib/hamtextbox.ad` — the selection + clipboard substrate

The one place that owns editable-text cursor math (since #303) now also owns
selection, hit-testing and clipboard access. Byte-inert for apps that don't
use selection (a box never touches the selection API keeps `_htb_selon == 0`
forever, so `htb_render` draws no highlight and `htb_selection` reports empty).

- **Click-to-position** — `htb_hit_test(x0, buf, n, click_x) -> caret_index`
  is the pixel-exact INVERSE of `htb_caret_x`: it walks the SAME proportional
  glyph advances the compositor draws with and returns the caret index nearest
  the click (left half of a glyph → caret before it, right half → after). A
  click sets the caret THERE (fixes "clicking the input doesn't move the caret
  until you type").

- **Selection model** (managed boxes) — an anchor index + the caret index; the
  selection is `[min(anchor,caret), max)`. `htb_sel_click` sets both (collapse),
  `htb_sel_drag` moves the caret keeping the anchor (extend on click-drag),
  `htb_sel_start/end/active/clear`, and `htb_sel_copy(h, prim)`. Any ordinary
  key fed to `htb_feed` collapses the selection (type/navigate clears it).

- **Highlight render** — `htb_render` draws a `#b4d0f8` band behind the selected
  glyph run (measured with the same advances) before the text.

- **File-backed clipboard** (NO new syscall) — `htb_clip_put(prim, buf, n)` and
  `htb_clip_get(prim, out, cap)` WRITE/READ a Plan 9 file: `prim=0` is the
  CLIPBOARD `/dev/snarf` (Ctrl+C/Ctrl+V), `prim=1` is the X11 PRIMARY selection
  `/dev/snarf.primary` (highlight → middle-click paste).

## 2. The compositor-owned clipboard service — `sys/src/9/port/devsnarf.ad`

Plan 9's clipboard is a FILE. Hamnix already served `/dev/snarf` (a single
64 KiB REPLACE-on-write buffer). #315 adds the X11 PRIMARY selection as a
SECOND, independent file `/dev/snarf.primary` (`primary_buf`/`primary_len`),
same read/REPLACE-write surface. A copy WRITES the file; a paste READS it; the
two buffers are independent (a Ctrl+C into the clipboard never clobbers a live
highlight's PRIMARY). Wired through `sys/src/9/port/namec.ad`
(`DEV_SNARF_PRIMARY`, `#c/snarf.primary`). `devwsys.ad` is UNTOUCHED — the
compositor already forwards window-local pointer events (`m x y buttons dz`,
button bit0=L bit1=R bit2=middle) and raw key bytes to the focused window, so
middle-click, drag-motion, and Ctrl+C/Ctrl+V (bytes 3/22 on `/keys`) need no
new input plumbing.

### Terminal ^C safety

Ctrl+C-as-copy is handled per-app (in the editor / any hamtextbox user), NOT
globally in the compositor, so the terminal's job-control `^C` (SIGINT) is
untouched — each app decides what byte 3 means for its own text region.

## 3. Reference app — `user/hameditscene.ad`

The scene-DE editor is migrated to the substrate: click-to-position caret
(`_ed_hit_offset` maps a pointer to a byte offset via `htb_hit_test` per visual
row), click-drag selection with a visible highlight band, Ctrl+A select-all,
Ctrl+C/Ctrl+V/Ctrl+X on `/dev/snarf`, auto-copy-to-PRIMARY on highlight
release, and middle-click paste of PRIMARY at the click.

## Verification

Two gates, both green (and a native kernel-link check — ship blocker — passes):

1. **`scripts/test_hamtextbox_host.sh`** — QEMU-free, deterministic host unit
   test (`user/hamtextbox_host.ad`, `--target=x86_64-linux`). 16/16 assertions:
   `htb_hit_test` is the EXACT inverse of `htb_caret_x` (for every caret index
   `i`, hitting caret `i`'s pixel returns `i`), boundary cases, monotonicity,
   and the full selection model (click collapses; drag forward/backward sets
   `[start,end)`; a typed key collapses). Runs on the real proportional-font
   path in milliseconds.

2. **`scripts/test_hamedit_clipboard.sh`** — on-device (OVMF/KVM, fresh
   installer image), **DETERMINISTIC** (no mouse / wid / keystroke injection on
   the critical path — those were load-sensitive). A `--selftest-copyall` hook
   makes the editor GENERATE a known payload and run the real
   `_handle_code(Ctrl+A)` + `_handle_code(Ctrl+C)` handlers on startup; the
   shell then reads that payload back from `/dev/snarf` (cross-process,
   device-only), and a SEPARATE `--selftest-paste` editor pastes it into a file
   the shell reads back. **3/3 PASS on a CPU-loaded host.** Screendump
   `armE_copyall.ppm` shows the blue selection band. Direct device probes also
   confirmed `/dev/snarf` and `/dev/snarf.primary` write+read independently.

## 4. What the deferred mouse confirmation was hiding (2026-07-27)

This section used to close by DEFERRING automated mouse confirmation of
drag-select and middle-paste, on the grounds that the DE mouse-injection
harness was too pixel/timing sensitive to assert deterministically. Both parts
of that were wrong, and the deferral is where the user's bug lived:

* **Nine host gates were green while the feature was completely dead on
  device.** They were green honestly — every one of them calls
  `devsnarf_primary_read/write` DIRECTLY, and both real defects sat on the
  syscall path those calls skip.
* **Defect 1 — `/dev/snarf.primary` was `-EBADF` on every read and write.**
  `namec.ad` admits an inline cdev only when `dev_type < DEV_MAX`.
  `DEV_SNARF_PRIMARY` is 132; `DEV_MAX` was 131. The file OPENED fine and then
  failed every access before the device body ran — silently, because a failed
  read looks like an empty file (`cat` prints nothing, exits 0) and a failed
  write looks like a successful shell redirect. So highlighting stored nothing
  and middle-click read nothing back: BOTH halves of the user's report, one
  constant. Guarded now by `scripts/test_devmax_covers_all_ids.sh`.
* **Defect 2 — `devsnarf` ignored the write offset.** It replaced the buffer on
  every write, so the shell's two-chunk `echo text > /dev/snarf` (payload, then
  the trailing newline) left one byte behind. Writes are offset-addressed now:
  offset 0 replaces, offset > 0 extends.
* **Why nobody could see it — a third defect.** `hamtermscene` wrote its proof
  markers to fd 1 and as `[term] ...`. `devcons_write` drops a BACKGROUND wsys
  window's console traffic unless the write starts with a whitelisted prefix
  (`[de_perf]`, `[hamterm]`, `[hambrowse]`), so serial could never carry them —
  and `test_de_wheel_scroll.sh` had already written that absence up as a
  "known harness limitation: mouse injection does not reach the kernel". It
  does. All markers now use the whitelisted prefix.

Mouse injection is also not too flaky to gate on: the fragility was aiming
clicks at blind screen coordinates. `scripts/test_middle_paste_ondevice.sh`
takes the terminal's wid off the kernel's window-mapped line, reads the real
rect from the window's per-window `/ctl` file, and derives every click from
`lib/htermsel.ad`'s own cell geometry, so a click cannot miss the window. It
boots the shipped image under OVMF/KVM and asserts the paste BY EFFECT (the
terminal executes the pasted line). It is in `ci_battery_manifest.txt`.

The decision logic itself moved into `lib/htermsel.ad`
(`htsel_evt_parse_m` / `htsel_pointer_step`) so it can be driven from raw wire
bytes by `scripts/test_htermsel_evt_host.sh` — the altitude the nine gates
missed. That gate also fails if `hamtermscene` stops calling the step, so it
cannot decay into testing dead code.

Still deferred: terminal SCROLLBACK-region selection (selection is grid-row
indexed, so it is gated on the live tail; the middle-click paste is
deliberately view-independent and works while scrolled).
