# What works — an honest inventory

**Measured 2026-08-03** against a freshly built `build/hamnix-installer.img`
(SHA-256 `77c6a4f4…31fbc75`, sources at `main` @ `238ba35f`) booted under
OVMF/KVM six times. Every claim below is backed by a real framebuffer
scanout (QEMU monitor `screendump`) or a real serial-console transcript, both
kept in [`docs/screenshots/`](screenshots/). Nothing here is a host-side
render, a mock, or a source-code inference.

This document is deliberately unflattering where the system is unflattering.
If something is not listed as working, assume it does not.

---

## The short version

The desktop is real. All 26 shipped launchers start, map a window, and paint
a genuine UI — there are no empty frames in the gallery. What is thin is the
*second* minute of use: several apps do not respond to the keyboard, nothing
can be closed, and two of the three games are already in a GAME OVER state by
the time you can look at them.

| | |
|---|---|
| Launchers shipped | 26 (`etc/hamde/apps/*.desktop`) |
| Launched and mapped a window | **26 / 26** |
| Painted a real UI (not a blank frame) | **26 / 26** |
| Responded to the keystrokes we sent | **16 / 26** |
| Could be closed | **0 / 26** (Screenshot closes *itself* on a keypress) |
| Kernel faults across all six boots | **0** |

---

## The desktop

Real and MATE-shaped. Wallpaper, a top panel with an Applications menu, a
clock and a CPU applet, 16 desktop icons in two columns, a bottom taskbar with
window-list buttons, and a 4-workspace switcher.

**Works**

* Wallpaper and desktop icons render; icon labels wrap to two lines.
* The Applications menu opens as a real popup with a search box and seven
  categories (Accessories, Internet, Office, Games, Sound & Video, System,
  Settings). The panel absorbed all 26 native launchers plus one Linux entry:
  the serial log reports `[panel] appmenu entries: 27 (linux section: 1)`.
* Typing in the menu's search box filters the catalogue live and groups the
  results by category.
* The taskbar gains a button per window; the window-list stays in sync.
* Windows are decorated with minimise / maximise / close buttons and drop
  shadows, and stack correctly.

**Does not work / rough**

* **Nothing can be closed from a script.** `kill <pid>` does not tear down a
  scene client's window — no `task: pid N exited` follows and the frame is
  pixel-identical afterwards. The `free <wid>` verb on `/dev/wsys/ctl` is
  hostowner-gated and a serial-console `hamsh` does not pass the gate. The
  close button in the title bar has not been driven end-to-end here because
  `/dev/mouse` injection is unreliable. **Treat "can the user close a window?"
  as unverified, and "can a script?" as no.**
* The Applications menu has **no keyboard navigation** — Down/Right does not
  enter or expand a category. Only the search box is reachable by keyboard.
* The menu's search box **ignores Backspace**; a mistyped filter can only be
  cleared by closing and reopening the menu.
* The menu popup is a **fixed size and truncates** its results rather than
  growing or scrolling — filtering on "a" cuts off mid-way through the Games
  category.
* Desktop icon labels **break mid-word**: "Spreadshee/t", "Presentati/on".
* `/etc/desktop.icons` is **dead config**. It ships with 15 entries including
  an "Input Inspector" and a "Home" folder, neither of which appears on the
  desktop, and lacks Audio Player / Software / Video Player, which do. The
  desktop actually renders `~/Desktop/*.desktop` (16 entries, from
  `etc/skel/Desktop/`) — `user/hamdesktop.ad` builds its grid "from the REAL
  desktop directory (~/Desktop)". The file's own header still claims
  hamdesktop reads it at startup.
* Pointer latency degrades badly as windows accumulate. The kernel's own
  `[ptrlat-trace]` instrument logged a 1.95 s stall during boot, then gaps
  growing from ~117 ms to ~310 ms as the session went from 2 to 20 windows.
  A quarter-second cursor freeze is visible to a user.

---

## Applications

All 26 launch and paint. Per-app detail, and the shots themselves, are in
[`docs/screenshots/index.md`](screenshots/index.md). Highlights and problems:

### Genuinely good

* **Web Browser (`hambrowse`)** — Chrome-shaped chrome: tab strip, back /
  forward / reload / home, URL bar, search box, overflow menu. Renders its
  built-in `about:demo` page with h1–h3, bold/italic/nested inline markup,
  coloured text via `font` and `span`, bullet lists, hyperlinks, a decoded PNG
  blitted at 2×, preformatted code, entity decoding, and word wrap to the
  window width. It reacts to input (21,832 changed pixels on a keypress).
  *But the tab title reads `ignored` instead of the page title.*
* **Control Center (`hamctl`)** — ten settings categories (Appearance, Date &
  Time, Display, Mouse, Keyboard, Sound, Power, Network, About) with a working
  Appearance pane offering six background colours and four wallpaper images.
* **Software (`hamsoftware`)** — a Synaptic-shaped package manager: search
  box, Refresh / Install / Remove / Upgrade, All / Installed / Available /
  Upgradable filters with counts, a package list with "installed" badges, and
  a status bar.
* **Install Hamnix (`haminstallui`)** — a real five-step wizard; step 1 is
  "System name" with a pre-filled hostname field and Back/Next.
* **System Monitor (`hammonscene`)** — uptime, a live CPU sparkline, memory
  gauge (`327134 / 800946 kB (40%)`), and a PID/CPU%/command process table.
* **Log Viewer (`hamlogscene`)** — the real kernel ring buffer, 256 lines,
  scrollable.
* **Office suite** — HamWrite (formatting toolbar, ruler, colour swatches,
  word/char counter), HamSheet (A–G × 1–16 grid, formula bar, cell reference,
  CSV/Open/SaveAs/Save), HamSlides (slide sorter, layout/theme controls,
  speaker notes, present mode). All three accept typed input.
* **Audio Player**, **Video Player**, **Calendar**, **Calculator**, **Files**,
  **Notes**, **Terminal**, **Editor**, **Screenshot**, **Minesweeper**,
  **Chess**, **2048** — all render complete, recognisable UIs.

### Problems a 1.0 should not ship with

* **Both Snake games show `GAME OVER` on arrival.** `hamsnakescene` and
  `hamgamesnake` start the snake moving the moment the window maps; by the
  time the window has painted and settled the snake has hit a wall. The
  launch screenshot of each is a game-over dialog with score 0.
* **Ten apps did not respond to the keystrokes we sent**: Audio Player,
  Control Center, Files, Chess, Snake (hamGame), Input Inspector, Snake,
  Install Hamnix, Log Viewer, Software. Some of these are legitimately
  mouse-driven, but "mouse-only" is itself a problem given how unreliable
  pointer injection is here — and Chess and Snake are games that document
  keyboard controls.
* **Input Inspector (`haminput`) is a developer diagnostic**, not an
  application: a black window reading *"ready — click the window, then press
  keys / click mouse buttons"*. It ships in the Applications menu and, per
  `/etc/desktop.icons`, was meant to be a desktop icon too.
* **Software's package list is parsing `hpm`'s stdout as data.** The first
  two rows are `[runtime:hpm]` (a loader log line) and `hpm: cached index; run
  \`hpm refresh\` first` (a diagnostic), both rendered as installed packages
  with badges.
* **`hpm list` and the Software GUI disagree.** On the same boot the CLI says
  `hpm: no packages installed` while the GUI says `28 packages in the index /
  28 installed / 0 upgradable`.
* **`uname` reports `Hamnix x86_64 0.1`.** If this is being called 1.0, the
  version string has to move with it.
* System Monitor's process table shows `__rfork_` as the command name for
  most processes.
* Most apps draw **their own title bar underneath the window manager's**, so
  the window title appears twice (Coin Dash, Calendar, Control Center, Notes,
  Chess, Audio Player, Software, Install Hamnix, Video Player, …).
* Cosmetic: the Audio Player has an unpainted black band along the bottom of
  its window and its "Level" label overlaps the seek bar; Chess draws pieces
  as the letters R N B Q K P rather than glyphs.

---

## Browser: what it can and cannot do

**Can.** Parse and lay out a tolerant subset of HTML; headings, paragraphs,
line breaks, bold/italic/nested inline markup, bullet lists, hyperlinks,
preformatted blocks, HTML entities, word wrap to the window width, CSS colour
via `font` and `span`, decoded PNG images blitted at 2×, and a status line.
The browser chrome (tabs, navigation, URL bar) is real and the page reacts to
input.

**Not shown here.** The capture VM was booted **without a network device**, so
every browser claim above is against the built-in `about:demo` page. Loading a
page over HTTP, DNS resolution, and real-world site compatibility are **not**
evidenced by this run and must not be inferred from it. See
`docs/browser_wpt_conformance.md` for the conformance position, which is a
separate and much more heavily qualified story.

---

## What is VM-only in this evidence

Everything on this page was measured under QEMU/OVMF with KVM and `-cpu host`,
1 GiB of RAM, `-vga std`, no network device, and a virtio disk. In particular:

* No real hardware was exercised — no GPU, no USB, no NIC, no NVMe.
* The installer's **UI** was screenshotted; the installer was **not run to
  completion** against a disk in this session.
* Audio and video playback were screenshotted, not *heard* or timed. The
  Video Player plays a bundled synthetic clip (`test.hmjv`, 30 frames) in a
  project-specific container, not a standard video format.
* SMP was not exercised (single vCPU).

---

## Build facts worth knowing

* The shipped kernel is built with **`HAMNIX_KERNEL_BACKEND=llvm` by default**
  (`scripts/build_installer_img.sh`), via `build_kernel_llvm.sh` in
  native-hybrid mode: 11,398 of 11,398 functions emitted through LLVM, with
  `memblock_alloc` forced back to the native backend. If a document says the
  shipped kernel is compiled by the native x86 backend, that document is
  describing the fallback (`HAMNIX_KERNEL_BACKEND=native`), not the default.
* `build/hamnix-installer.img` is 98 MiB, ESP-only GPT, kernel + embedded
  4.0 MiB squashfs root loaded entirely into RAM.

## Known documentation drift

* `README.md` describes the **`hamUId` renderer daemon** with its panel,
  taskbar and clock as the current UI. `etc/rc.d/rc.5` says the "hamUId
  procedural present is retired"; the running desktop is `hamdesktop` plus
  `hampanelscene`, both scene clients over `/dev/wsys/<wid>/scene`.
* `README.md` describes **`hamfm`** as "a TUI file manager". The Files app on
  the desktop is `hamfmscene`, a graphical scene client.
* `/etc/desktop.icons` (see above) documents a mechanism the desktop no longer
  uses.
