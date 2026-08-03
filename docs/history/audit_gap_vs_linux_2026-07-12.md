# Hamnix — Candid gap audit vs. a credible Linux/Unix desktop

**Date:** 2026-07-12
**HEAD at audit:** `4efc3f5d` (hamsh: index-assign before scalar assign)
**Auditor:** orchestrator, read-only worktree — **boot + drive + LOOK**, not a lexical sweep.
**Supersedes context:** `docs/audit_gap_vs_linux_2026-07-10.md` (that one was explicitly
"no QEMU boots"). This one boots the freshly-built live image on KVM twice, screendumps
the DE, renders the browser engine, and grades against what the pixels actually show.
**Method:** built `build/hamnix-installer.img` from *this* worktree (the prior main-tree
image was stale — `lib/htmlengine.ad`, `lib/htmlpaint.ad`, `lib/browserfonts.ad`,
`lib/hamui.ad` were all newer than it). Booted it under OVMF/KVM, `-vga std`, monitor
`screendump`. Also ran the QEMU-free host pixel path (`run_hambrowse_gfx.sh`). Three
read-only source sweeps (hamsh scripts, packaging, DE apps) cross-checked the pixels.
**Evidence artifacts:** `build/audit_2026-07-12/*.png` + `de_boot1_serial.log`.

---

## 0. Executive summary — the owner's critique, graded honestly

The owner pushed back that the orchestrator over-claims ("usable", "MATE parity",
"renders real pages"). **Graded against real pixels, the truth is split:** the
*artifacts* (browser pixel engine, DE apps, file manager) are genuinely good and the
"ASCII browser" claim is **out of date** — but **boot reliability and breadth are the
real problem**, and the owner's instinct that something is off is correct, just aimed
one layer away from the root cause.

| # | Owner's critique | Honest verdict | Key evidence |
|---|---|---|---|
| 1 | DE not MATE parity; too few apps, weak settings | **PARTLY TRUE** — shell/apps are MATE-shaped and real, but Settings is narrow and boot is flaky | `de_boot2_full_desktop.png` vs `de_boot1_BARE_wallpaper.png` |
| 2 | Browser "still looks mostly ASCII" | **FALSE (stale)** — current engine renders proportional AA pixels | `browser_host_pixel_render.png`, `browser_ondevice_demo.png` |
| 3 | Firefox can't open | **TRUE** — confirmed, Gecko-internal deadlock, correctly parked | STATUS "Firefox window PAUSED"; memory `project_firefox_startup_deadlock` |
| 4 | hamsh init/rc scripts should be rewritten in new Python-like syntax | **TRUE** — 0 of 17 scripts use the new syntax | inventory below |
| 5 | Packaging reverts to static baked-in packages | **PARTLY TRUE** — real hpm install + hybrid baked ESP/Debian; desktop is one lumped package | `install.hamsh:131,158,188` |
| 6 | Networking in the VM | **STACK WORKS; DEFAULT boot ships no NIC** — owner is right it's a default gap, not a broken stack | `_installed_boot.sh:112`, no `-netdev` in any DE/installer script |
| 7 | Linux apps rendering (Wayland passthrough) | **WORKS for GTK/Wayland/Qt/XWayland; only Firefox blocked** | STATUS "foot is a FULLY WORKING terminal" |

**The single most important finding this audit surfaced that the green gates hide:**
**the DE boots nondeterministically.** Two back-to-back boots of the *same* image:
boot #1 came up as a **bare teal wallpaper with only a cursor — no panel, no icons, no
windows** (`de_boot1_BARE_wallpaper.png`); boot #2 came up as a **full MATE-style
desktop** (`de_boot2_full_desktop.png`). This is the documented rc.5 scene-client launch
race (STATUS T63 deferred item #1) biting in production. A user who hits boot #1 sees a
dead desktop. **This, not the browser, is what makes it feel "not usable."**

---

## 1. DE — MATE parity (critique #1)

**Verdict: DEMO-QUALITY-WHEN-IT-WORKS, but flaky and narrow. Not parity.**

### What actually renders (boot #2, `de_boot2_full_desktop.png`)
A genuinely MATE-2/GNOME-2-shaped desktop: top panel with an Applications menu +
per-app launchers, a system tray (CPU/mem gauges, notification bell, clock
"Sun Jul 12 22:11"), a left column of desktop launcher icons (Files, Terminal,
Calculator, Text Editor, Install Hamnix, Settings, System Monitor, Home), a bottom
taskbar with **4 workspaces** + a window list, and live app windows: **System Monitor**
(uptime, `Mem 647063/1944739 kB used (33%)`, a PID/STATE/COMMAND task table showing
`sshd`, `hamsh`, `kworker`), **Calculator** (real keypad), and **Files** (`hamfm: /`
with folder icons for init/bin/etc/usr/var/lib/home/…). The prior on-device captures
corroborate a full desktop with a browser window (`browser_ondevice_demo.png`).

### The reliability gap (the honest headline)
Boot #1 of the identical image produced **only wallpaper + cursor**
(`de_boot1_BARE_wallpaper.png`, 4.2 KB PNG = nearly uniform). Serial
(`de_boot1_serial.log:1023-1035`) shows rc.5 *reported* launching the desktop icons +
panel (`rfork` pids 21-25, "pre-warming shell + command cache") — but nothing painted.
Root cause is on file: **STATUS T63 deferred #1**, the rc.5 `spawn detached <ns> { /bin/hamX }`
probes `/bin/hamX` inside the child's empty `ns {}` overlay *before* `/bin` is bound →
nondeterministic "command not found" → partial/no DE. Green DE gates hide this because
they retry / self-drive; a cold user boot does not.

### Built-in apps — count & reality (source sweep)
The live Applications menu is data-driven from **9** `.desktop` files in
`etc/hamde/apps/` (`lib/desktopentry.ad` parser, 7 categories). Each maps to a real
built binary:

| Menu entry | Binary | Real? | Gap vs MATE |
|---|---|---|---|
| Web Browser | hambrowse | real (partial) | no CSS-full/JS-full/forms |
| Calculator | hamcalcscene | real | integer only, no float/scientific |
| Editor | hameditscene | real | no find/replace/undo/syntax |
| Files | hamfmscene | real (mkdir/rename/del/copy/paste + ctx menu) | ✓ closes MATE #1 gap |
| 2048 | ham2048scene | real | — |
| Install Hamnix | haminstallui | real | — |
| Settings | hamsettings | real (narrow, §2) | — |
| System Monitor | hammonscene | real (read-only) | no CPU%, no kill |
| Terminal | hamtermscene | real | no tabs/selection |

Plus reachable-but-not-in-catalogue: `hamctl` (a second control center), `hamsnake`,
`hamabout`, `hamshot` (screenshot), `hamlock`/`hamscreensaver`, `hamsessui` (logout).

### MATE control-center parity — the real weakness (critique #1 "settings lacking")
Settings is **real, not a mockup, but only 3 things actually change system state:**
wallpaper (solid-color PPM → `/dev/wsys/ctl wallpaper`, consumed at
`sys/src/9/port/devwsys.ad:2980`), panel layout (full multi-panel editor →
`/tmp/hamnix-panel.conf`, live-polled by `hampanelscene.ad:1006`), and master volume
(`hamctl` → `/dev/audioctl master <pct>`). **Everything else is read-only or dead:**
- `hamctl` Display / Keyboard / Network / Power / About panels are read-only textviews
  (header self-describes "intentionally MINIMAL").
- The `hamappmenu` Settings submenu advertises `/bin/hamset-display`, `-mouse`,
  `-keyboard`, `-network`, `-sound`, and `/bin/gnome-disks-shape`
  (`user/hamappmenu.ad:346-356`) — **none of these binaries exist.** Clicking them is a
  no-op. This is exactly the "settings are lacking" the owner reported.

**Missing vs MATE:** image viewer with real formats (`hamview` is PPM/BMP only — no
PNG/JPEG display/zoom), PDF viewer (none), theme/icon/font appearance, Displays/resolution,
Keyboard-shortcuts, Mouse, Date/Time, Power management, Default-applications, a real
sound mixer, a real system tray/StatusNotifier.

---

## 2. Web browser — "looks mostly ASCII" (critique #2)

**Verdict: FALSE as stated — the claim describes an OLD build. The current engine
renders real proportional anti-aliased pixels.**

This was the sharpest test, so I proved it two independent ways:

1. **Host pixel path** (`run_hambrowse_gfx.sh`, the *same* `lib/htmlpaint` +
   `lib/htmlengine` engine the on-device browser links, compiled for the host, QEMU-free)
   on `tests/fixtures/hambrowse_article.html` → `browser_host_pixel_render.png`. It is a
   clean, proportional, anti-aliased sans-serif render: navy **bold headings** with
   horizontal rules, justified-measure body prose, real **underlined blue hyperlinks**, a
   gray blockquote, and a **teal syntax-colored monospace code block**. The engine even
   reports `AAGRAY 46734` (46 734 anti-aliased edge pixels) — that is not a character grid.
   Font tech = an embedded TrueType face (`lib/browserfonts.ad`: cmap/glyf/hmtx tables) with
   a coverage-blending rasterizer (`lib/htmlpaint.ad:_blit_ttf_glyph`, `_blend_px` alpha
   compositing).

2. **On-device** (prior scene-DE captures, same engine): `browser_ondevice_demo.png`
   shows the demo page in a real DE window — "Hamnix Web" navy heading, red CSS-colored
   text, a **decoded PNG blitted at 2×**, colored bulleted lists, blue links.
   `browser_ondevice_debian_https.png` shows it **fetching https://www.debian.org over
   the network (HTTP 200, 7778 bytes) and rendering it** — proportional "Debian" heading,
   underlined links (Blog/Micronews/Planet/Wiki).

**So where did "ASCII" come from?** Two honest caveats keep this from being a clean win:
- The **image was stale** in the main tree (browser sources newer than the built img) —
  a QA run there would boot the *old* VGA-font scene path. Classic stale-image trap.
- **Real pages degrade visibly:** on debian.org the logo is a **broken-image red-X**
  (unsupported image format) and the search form renders as ASCII placeholders
  `[______] [ Search ]` (no real form widgets). So on a rich real site it is real-pixel
  *text* with **missing images and form controls** — not "ASCII", but not a faithful
  render either. No JS-driven layout, no full CSS, no tables-as-grid on complex sites.

**On-device launch is also unreliable in the harness:** in this audit's boot, the
`sshd` accept-timeout path **floods the serial console 74×** with
`[tcp] accept timeout on listener slot=0` (`de_boot1_serial.log`), which swamped the
shell's input echo so the timed `hambrowse --demo` launch was lost every one of 6
attempts. That serial-console flood is itself a real bug worth fixing.

---

## 3. Firefox (critique #3)

**Verdict: TRUE, confirmed, correctly parked.** Not re-investigated per instruction.
STATUS "Firefox window PAUSED": the SCM_RIGHTS fix moved it from "parent exits 255
pre-chrome" to "persists, builds full GTK chrome, binds all Wayland globals", but it
then hangs on a **Gecko-internal circular-wait deadlock** in libxul's own multithread
startup (kernel futex diag: stuck-waiter keys have zero overlap with wake keys). 46 MB
stripped libxul, no symbols — an unbounded target. Memory `project_firefox_startup_deadlock`.
This is an app-level Gecko bug, **not a Hamnix ABI gap** (every other GUI toolkit works).

---

## 4. hamsh init/rc scripts — Python-syntax rewrite (critique #4)

**Verdict: TRUE. 0 of 17 executable scripts use the new syntax.** They are all in the
old imperative brace-block dialect (`if $x > 0 { … }`, `` `{ cmd } ``, `try/except`,
`ns {}`, `spawn detached`). None use comprehensions, `with`, float literals, list
mutation (`.append`/index-assign), `sorted(key=/reverse=)`, or floor-division `//` — a
grep for every one of those idioms across `etc/` returned zero hits. ~1 657 LOC of
load-bearing init/service script that dogfoods **none** of the language the team just built.

**Rewrite candidates, priority order:**
- Tier 1 (core boot): `etc/rc.boot` (287), `etc/rc.boot.full` (265), `etc/rc.d/rc.5`
  (251) — nested `if $flag > 0` device ladders + repeated `spawn detached ns { … }`
  clusters that collapse into loops/comprehensions over a service list.
- Tier 2 (session rc, 4 files near-duplicate): `etc/rc.de-user` (221), `rc.de-wayland`
  (128), `rc.de-hostowner` (98), `rc.ssh` (81) — a shared helper would dedupe them.
- Tier 3 (installers, linear/low-risk): `etc/install.hamsh` (238), `install_nvme.hamsh`
  (82), `install_multipkg.hamsh` (60).

---

## 5. Packaging — baked-in vs hosted repo (critique #5)

**Verdict: PARTLY TRUE. The repo IS used at install time — but it's a Debian-installer-
shaped HYBRID, and the desktop is one lumped package.**

- **Package count:** 112 packages emitted by `scripts/build_packages.py` (17 literal
  specs + 92 auto per-command `hamnix-<cmd>` leaves + hamnix-base/-bootloader/linux-debian-12).
  CLI granularity is **excellent** (92 single-binary packages). **Desktop granularity is
  poor:** all 36 DE app binaries ship in ONE `hamnix-desktop-apps` package
  (`build_packages.py:622-639` explicitly rejects a per-app split — "you want the whole
  desktop or none"). **2048 is NOT its own package** — it's bundled in `hamnix-desktop-apps`.
  `hamnix-desktop` is a real metapackage (deps only); `hamnix-base` is the install root metapackage.
- **hpm is real:** `user/hpm.ad` (7 994 LOC), channels main/non-free/non-free-firmware,
  default repo `https://255.one/` (hpm.ad:621), **Ed25519-signed** `index.json` +
  detached `.sig` verified against `etc/hpm/trusted.pub` (`lib/ed25519.ad`), per-tarball SHA-256.
- **Install-time behavior is a hybrid** (`etc/install.hamsh`): it **does** run
  `hpm --repo=file:///iso-packages refresh` (`:131`) + `hpm ... install hamnix-base`
  (`:158`) — real solver, real tarball extraction, populates `installed.json` so
  `hpm list/remove` work. **But** the ESP (bootloader+kernel) is `dd`-copied from a
  pre-built source ESP (`:176`) and the Debian runtime + busybox + man pages are copied
  file-by-file from the pre-baked live rootfs via `install_rootfs_from_manifest` (`:188`),
  **explicitly "not by hpm's extraction path"** (`:149-156`). So: hpm-driven for
  first-party native packages, baked-image copy for the ESP and the heavyweight Debian side.
- **255.one is a real hosted artifact** (per-channel `index.json`+`.sig`+`*.tar.gz`,
  GitHub-backed `HamnixOS/packages`); the ISO ships a RAM copy of the `main` channel at
  `/iso-packages/`, and post-install hpm defaults back to the network repo.

The owner's "keeps reverting to static baked-in" is **half right**: native packages flow
through hpm, but the bulky/foreign bytes are still baked and copied. The dogfooding gap is
real (the installer doesn't `hpm install` the Debian side) and the desktop-as-one-lump is
the opposite of the "2048 is its own package, DE = metapackage-of-packages" ideal.

---

## 6. Networking in the VM (critique #6)

**Verdict: STACK WORKS; the DEFAULT boot ships NO NIC. The owner's diagnosis (missing-NIC
default, not a broken stack) is CONFIRMED.**

- **Stack is real:** DHCP lease 10.0.2.15, DNS, and `hpm refresh` against
  `https://255.one/` all work when a NIC is attached (`test_hpm_network.sh` — DHCP marker
  + `(dhcp)` cfg-src + index fetch; the rc.boot static-IP override that used to clobber
  DHCP was removed). A prior on-device capture shows hambrowse fetching debian.org over
  SLIRP (HTTP 200).
- **But the default paths attach no NIC:** the **installed** boot
  (`scripts/_installed_boot.sh:112`) wires only the NVMe drive — **no `-netdev`,
  no `-device virtio-net`**. **None** of the DE/live/installer scripts
  (`test_de_*.sh`, `build_installer_img.sh`) attach a NIC either. Only
  `run_x86_module.sh` and the explicit net tests do. So a user booting the shipped image
  in plain QEMU/Boxes has a working stack with **no device to bind** → "networking
  doesn't work" that is actually "no NIC was plugged in." **This is a one-line default
  fix with outsized payoff.**

---

## 7. Linux apps rendering — Wayland passthrough (critique #7)

**Verdict: WORKS broadly; only Firefox blocked.** STATUS (2026-07-07): **`foot` is a
fully working multithreaded terminal** (screendump: injected input echoes, command
executes); weston-simple-shm/damage/flower/eventdemo render; a **Qt5 Widgets app renders
content**; **X11 apps via XWayland** (`xsetroot -solid red`) render on the `-shm` software
path. The default live image bundles weston-terminal's GL-free closure (77 files) and a
"Linux Namespace" DE menu category launches them via `etc/rc.de-wayland`. The lone
holdout is Firefox (§3). This area is **stronger than the owner's framing implies.**

---

## 8. Prioritized roadmap — the ordered high-leverage work

Ranked by (user-visible impact × tractability). This is the grounding for the push.

1. **Fix the rc.5 scene-client launch race (DE boots bare ~half the time).** *S–M,
   native.* Highest impact: it is the difference between "dead teal screen" and "MATE
   desktop" on a cold boot, and it is already diagnosed (STATUS T63 #1). Bind `/bin`
   (and the DE ns overlay) *before* the `spawn detached ns { /bin/hamX }` probe runs, or
   resolve the exec inside the parent ns. Add a boot gate that fails if the panel window
   never appears within N s of rl5 (count guest markers, not serial).
2. **Ship a NIC by default (networking "just works").** *S, config.* Add
   `-netdev user -device virtio-net-pci` to `_installed_boot.sh` and every live/installer
   run path + document it for real QEMU/Boxes users. The stack already works; this is the
   cheapest credibility win in the tree.
3. **Fix the sshd accept-timeout console flood.** *S, native.* 74 `[tcp] accept timeout
   on listener slot=0` lines per boot spam `/dev/cons`, make the serial shell unusable, and
   block scripted/interactive app launch. Demote to a debug level or drop on timeout.
4. **Real MATE control-center capplets (Settings is the owner's #1 complaint).** *M,
   native.* Build the advertised-but-missing `/bin/hamset-{display,keyboard,mouse,network,
   sound}` and Date/Time + Power, each writing a ctl-file a consumer reads (the wallpaper/
   panel/volume pattern already proves the model). Kill the dead menu entries until their
   binaries exist. Add an image-file wallpaper picker.
5. **Browser real-page fidelity: images + forms.** *M, native.* The text engine is
   already real AA pixels; the visible gaps on real sites are broken-image placeholders
   (add JPEG/more PNG/GIF decode to the page path — decoders exist in `lib/`) and form
   widgets rendered as `[___]` ASCII (render real input/button boxes). This directly
   answers "make it render real pages," building on a solid base.
6. **Granular desktop packaging + dogfood the repo end-to-end.** *M.* Split
   `hamnix-desktop-apps` into per-app packages (2048, calculator, editor, files… each its
   own leaf), keep `hamnix-desktop` the metapackage-of-packages. Route (at least the
   native side of) the install through hpm extraction rather than the baked manifest so
   "install from the hosted repo" is the real path, not a parallel artifact.
7. **Rewrite the init/rc scripts in the new Python-like hamsh syntax.** *M, dogfooding.*
   Start with `rc.boot.full` / `rc.5` (loops/comprehensions over a service list) — it both
   modernizes the load-bearing scripts and stress-tests the new language surface on real code.
8. **DE app breadth: image viewer (PNG/JPEG display) + PDF, editor find/replace/undo,
   terminal tabs.** *M.* The current app set is real but thin vs MATE's eom/atril/pluma depth.
9. **Firefox** — leave parked (§3); the Wayland stack is proven with foot/Qt5/XWayland, so
   the payoff/effort is poor until libxul symbols or a lighter Gecko target appear.

### Honest bottom line
The parts the owner doubted most — the browser and the Linux-app stack — are **better
than claimed** (real AA pixels; foot/Qt5/XWayland render). The parts called "shipped" that
are really **demo-grade** are the **DE boot reliability** (bare wallpaper ~half of cold
boots) and the **control-center breadth** (3 real toggles; the rest read-only or dead
links). Fix items 1-3 (all Small) and the desktop stops feeling broken; items 4-6 are what
turn "impressive demo" into "credible contender."
