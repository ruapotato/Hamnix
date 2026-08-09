<p align="center">
  <img src="logo.svg" alt="Hamnix logo" width="240"/>
</p>

<p align="center">
  <b><a href="https://255.one/">255.one</a></b> — website, screenshots and downloads
  &nbsp;·&nbsp;
  <a href="https://github.com/HamnixOS/Hamnix/releases/latest">Latest release</a>
</p>

# Hamnix

> **Sibling repositories.** The Adder language and compiler now also live on
> their own at **[HamnixOS/adder](https://github.com/HamnixOS/adder)**, and a
> second, parallel line — the same Adder userland running on the **Linux
> kernel** — has started at
> **[HamnixOS/hamnix-linux](https://github.com/HamnixOS/hamnix-linux)**. Both
> were split out with full history. Neither supersedes anything here: Hamnix
> 1.0 (tag [`v1.0`](https://github.com/HamnixOS/Hamnix/releases/tag/v1.0)) keeps
> its version number and its zero-C-in-the-kernel claim, and this tree still
> builds standalone. `hamnix-linux` is a sibling in the way Debian GNU/Hurd is a
> sibling of Debian, not a later release of it.

**A from-scratch x86_64 OS (with an in-progress AArch64 port), written
in Adder — a Python-syntax systems language with its own compiler.**
Hamnix is the OS; Adder is the language and compiler used to write it.

Adder has two backends. The **hand-written x86_64 backend** compiles the
kernel, and is both the bootstrap path and the differential oracle that
every other lane is checked against. An **LLVM backend** (SSA IR →
textual LLVM IR → clang) builds all 278 userland applications by
default, and is the only supported path for AArch64.

On x86_64 it is UEFI-only and boots off a GPT disk image to an
interactive shell. The AArch64 port boots to EL0 userspace on QEMU
`virt`, with per-task address spaces, demand paging, and per-task kernel
stacks — a task can block inside a syscall.

The novel claim is the **layered architecture**: native Plan 9-shape
syscalls underneath, with a Linux ABI shim sitting on top so unmodified
Linux binaries also run. Both worlds share one kernel.

---

## What's different about Hamnix

Most OS projects pick one of two stances: clone Linux, or implement
Plan 9 from scratch. Hamnix picks both, layered:

| Layer | Shape | What lives there |
|--|--|--|
| **5** | Apps | Stock Debian packages (apt-installed) + Hamnix-native binaries |
| **4** | Wire protocols | 9P (kernel↔userspace), [DE scene files](docs/de_scene_file_arch.md) (file-server-per-window UI; rearchitecting) |
| **3** | Userspace services | 9P file servers (hamwd, distrofs, ...) — Hamnix programs |
| **2** | Linux ABI shims | `linux_abi/` — translates Linux syscalls onto Layer 1 |
| **1** | Native syscalls | **Plan 9-shape** — 106 calls including `rfork`, `bind`, `mount`, `errstr`. See [`docs/native-api.md`](docs/native-api.md) |
| **0** | Kernel internals | Linux-shape — task_struct, scheduler, allocators. Porting `kernel/sched/core.c` → `kernel/sched/core.ad` is the unit of work. |

The clearest demonstration: the **cdev family**. Native code reads
system state via Plan 9-shape paths like `/dev/cpuinfo`, `/dev/meminfo`,
`/dev/uptime`, `/dev/loadavg`, `/dev/version`, `/dev/hostname`. For
Linux binaries, `enter linux { ... }` constructs a Linux-shape
namespace by binding the same kernel device file servers at Debian-
expected paths (`bind '#c' /dev`, `bind '#p' /proc`, `bind '#distro'
/`). Inside, `cat /proc/cpuinfo` opens Hamnix's proc cdev directly —
no string rewriting in the syscall path; the same kernel file server
answers both worlds via different namespace bindings.

Per-process namespaces via `rfork(RFNAMEG)`, real `Pgrp` struct with
refcount, bind-freeze so `#<word>` resolves to `#by-id/<partuuid>` at
bind time (hot-plug can't yank a running namespace), end-to-end 9P
loop through userspace-posted srvfds. See
[`docs/architecture.md`](docs/architecture.md) for the full design.

---

## What actually works — measured, not asserted

Everything below was captured on **2026-08-03** from a freshly built image
booted six times under OVMF/KVM, with every claim backed by a real
framebuffer scanout or serial transcript. The gallery is in
[`docs/screenshots/`](docs/screenshots/) and the full inventory —
deliberately unflattering — is [`docs/what_works.md`](docs/what_works.md).

| | |
|---|---|
| Desktop launchers shipped | 26 |
| Launched and mapped a window | **26 / 26** |
| Painted a real UI (not a blank frame) | **26 / 26** |
| Responded to the keystrokes sent | **16 / 26** |
| Could be closed | **0 / 26** |
| Kernel faults across six boots | **0** |

**The desktop is real.** What is thin is the *second* minute of use:
several applications ignore the keyboard, nothing can be closed from a
script (`kill` does not unmap a scene window, and the `free <wid>` ctl
verb is hostowner-gated), and two of the three games are already showing
GAME OVER by the time the window settles.

Known rough edges at 1.0, all reproduced: the Applications menu has no
keyboard navigation and ignores Backspace in its search box; the Software
app renders `hpm`'s stdout as package rows and disagrees with `hpm list`
on the same boot; the Input Inspector is a debug console shipping as an
application; pointer latency degrades as windows accumulate (117 ms at
two windows, 310 ms at twenty).

**Not evidenced by that run:** the capture machine had no network card, so
every browser claim there is against the built-in `about:demo` page rather
than the live web; no real hardware; no completed install; no audio
actually heard; a single vCPU.

---

## What it boots into today

- **Real hardware — historically yes, UNVERIFIED AT THIS REVISION.**
  Read this before trying it on a machine you care about. The NUC and
  laptop results below are real and reproducible *as recorded*, but they
  were taken many hundreds of commits ago. Development and testing since
  have been almost entirely under QEMU/KVM, and **no bare-metal boot has
  been re-confirmed at 1.0**. Treat bare metal as "known to have worked
  once, expected to need work again", not as a supported configuration.
  - Intel Skull Canyon NUC — booted end-to-end (UEFI, USB keyboard via
    the L-shim USB-HC bridge, hamsh prompt, `enter linux { /bin/sh }`
    against real Debian apt/dpkg).
  - Asus i5-4210U — booted to hamsh prompt in Legacy/BIOS mode; built-in
    keyboard unresponsive (leading hypothesis: EHCI-routed, not i8042).
  - See [`docs/REAL_HARDWARE.md`](docs/REAL_HARDWARE.md). If you do try
    it, a report either way is genuinely useful.
- **In-RAM installer image** (`build/hamnix-installer.img`) via
  `scripts/build_installer_img.sh` — **the recommended real-hardware
  artifact.** An ESP-only GPT image: UEFI firmware loads the installer
  kernel plus an embedded squashfs of the root filesystem entirely into
  RAM, so Hamnix never reads the boot medium after handoff (the
  unfinished native USB driver is never on the path). The in-RAM
  installer partitions the target's internal NVMe, writes a persistent
  ext4 root + ESP, and reboots off the NVMe alone. Proven end-to-end
  under OVMF+KVM by `scripts/test_installer_nvme_inram.sh`.
- **Installed ext4-on-NVMe system** — there is no pre-baked root disk
  image anymore. A real system is laid down by the installer above onto
  a real disk (GPT + ESP + ext4 root on NVMe); the resulting golden disk
  for VM testing is `build/hamnix-installed.qcow2`, produced by
  `scripts/build_installed_nvme.sh` running the real installer path once.
  Feature tests boot a fresh copy of that installed disk via the shared
  harness `scripts/_installed_boot.sh`. BIOS/legacy boot is dropped;
  Hamnix is UEFI-only by design.
- **Linux ABI** — ~250 syscalls; 24 stock Debian `.ko` modules load
  cleanly. CPython 3.11.10 and busybox 1.36 run as musl static-PIE
  binaries. Real Debian `apt 3.0.3` + `dpkg 1.22.22` install packages
  inside `enter linux { … }` against the `#distro` root served off the
  ext4 partition.
- **Network** — virtio-net / e1000e / r8169 drivers; ARP / IP / UDP /
  TCP / ICMP / DHCP / DNS / HTTP / TLS 1.3 end-to-end. **TCP / UDP /
  TLS exposed as the `/net` 9P file tree** (Plan-9-shape, zero BSD
  socket syscalls at Layer 1). `sshd` ships and auto-spawns at boot.
  NTP client syncs the wall clock via `/net/udp`. `curl` + `wget`
  dial out over HTTP/HTTPS via the shared `user/http9.ad` client.
- **Filesystem** — ext4 read + write (files up to 512 MiB, multi-block
  extent leaves), FAT32, MBR + GPT, partition-aware block-device names
  (`sd0p1`, `nvme0n1p2`).
- **Storage** — AHCI + NVMe.
- **USB** — native EHCI 2.0 + xHCI 3.0 + HID boot keyboard.
- **Shell (`hamsh`)** — Python-syntax single language; line editor +
  Tab completion + history; in-init service supervisor (`svc start /
  status / restart`, restart-on-crash, persistent logs at
  `/var/log/svc/<name>.log`); rc-in-hamsh at `/etc/rc.boot`. Builtins
  honour `>`/`>>`/`<`/`2>` redirects. **Job control** (`&` background,
  `jobs` / `fg` / `bg`, Ctrl-Z → SIGTSTP / SIGCONT). **Native
  runlevels** — `service` + `initctl` CLI; `runlevel: N` bitmask in
  service declarations; default multi-user runlevel 3.
- **Package manager (`hpm`)** — Hamnix-native, binary-only, BFS dep
  solver, `hpm install hamnix-base` metapackage pulls 17 component
  packages. Debian-shape subdirectory channels at
  [`https://255.one/`](https://255.one/) — the project's website, which is
  also the live package repository
  (`/main/` live; `/non-free/` + `/non-free-firmware/` placeholders);
  `hpm channels` / `enable` / `disable` for subscription. Default:
  `main` only.
- **Installer** — `etc/install.hamsh`: `hpm install`-driven Debian-
  installer-shape script. Partitions disk, mkfs ESP + ext4 rootfs,
  installs from a local mini-repo, plants `/etc/passwd` + `/etc/shadow`,
  ext4 grow-to-fit on first boot. (There is no pre-baked root image; the
  installer lays the ext4 root onto the real disk, where it grows to fill
  the disk and every named root draws from that one shared pool.)
- **Multi-user auth** — `useradd` / `passwd` / `login` / `su` /
  `whoami` real end-to-end; `/dev/auth` cdev with `setpass` verb;
  `SYS_SETUID_AUTH` (300) syscall; SHA-512 shadow hashes (rate-limited).
- **Security** — Plan-9-shape: single hostowner (uid 1) per installed
  system; regular users (uid ≥ 1000) get a restricted namespace and
  literally can't address dangerous file servers; no setuid bits, no
  `sudo`. Elevation is `newshell hostowner` (a hamsh builtin).
  Syscall-boundary `access_ok` pointer/length validator rejects
  kernel-address userland pointers on every native write/read path.
  See [`docs/security.md`](docs/security.md).
- **hamUI** — file-server-per-window UI. Phases 1, 2, 4a, 4b, 4c
  landed: `/dev/wsys/<N>/{text,output,cmd,ns,pid,uid,kind,geometry}`
  per window; layered draw protocol under `/dev/wsys/<N>/draw/`;
  the desktop is `hamdesktop` + `hampanelscene` over the scene-file
  protocol, with a GNOME2/MATE-style panel, taskbar (window-list
  buttons), minimise, live clock and a 4-workspace switcher;
  drag-title-to-move window management; `/dev/fb` framebuffer cdev;
  interactive windowed hamsh terminal. (The older `hamUId` renderer
  daemon is retired — `rc.5` no longer starts it.) An AI agent can
  `cat /dev/wsys/N/text` to see screen content and
  `echo cmd > /dev/wsys/N/cmd` to drive it. **X11 first slice**: native
  X11 server in `user/x11/` over `/net/tcp` (core-protocol subset).
  Phase 3 (per-window namespace elevation) and Phase 5 (full X11/Xvfb
  bridge) remain open. See [`docs/de_scene_file_arch.md`](docs/de_scene_file_arch.md).
- **AI agents** — `/dev/wsys/N/*` + svc logs + persistent `man` pages
  at `/usr/share/man/` make Hamnix the OS an AI can fully debug from
  a serial console.
- **Time** — RTC at boot + NTP-anchored wall clock + `/proc/realtime`
  + `date(1)` print real UTC.
- **`/dev/urandom` + `/dev/random`** — ChaCha20 CSPRNG, RDSEED/RDRAND
  seeded.
- **Power** — clean `shutdown` / `reboot` / `halt` / `poweroff`: a
  Plan-9-native `/dev/reboot` cdev and the Linux `reboot(2)` syscall
  share one kernel routine that flushes filesystems, then ACPI-S5
  poweroff / i8042 reset / triple-fault reboot.
- **SMP** — MADT-driven N-AP bringup; per-CPU `%gs`, per-CPU
  `current_task`; per-CPU runqueues with load balancing
  (`sched_pick_target_cpu`); idle APs HLT and wake on a reschedule IPI
  (tickless).
- **Virtual terminals** — VT1..VT4 (`/dev/vt/1`..`/dev/vt/4` +
  `/dev/vt/ctl`); `chvt <N>` switches the active console; Alt+F1..F4
  keyboard shortcuts.
- **Native cron daemon** — `crond` + `crontab` CLI; standard 5-field
  crontab syntax; spawns jobs in the background.
- **Native HTTP server** — `httpd` concurrent web server; per-connection
  worker processes; name-based virtual hosts; static files; CGI.
- **`vi`** — native Adder `vi` modal text editor.
- **`hamfmscene`** — graphical file manager (the desktop's "Files"),
  with an Applications menu entry. A TUI `hamfm` also exists for the
  serial console.
- **`tar` + `gzip` / `gunzip`** — native ustar archiver and DEFLATE
  compressor; survival primitives for the native namespace.
- ~80 native userland binaries (`ls`, `cat`, `cp -r`, `find`, `du`,
  `df`, `ps`, `dmesg`, `top`, `man`, `help`, `ping`, `ifconfig`,
  `route`, `hpm`, `hamUI`, `date`, `ntpd`, `vi`, `tar`, `gzip`,
  `crond`, `httpd`, `dpkg-deb`, ...).

For the full milestone log (140+ entries) see **[STATUS.md](STATUS.md)**.
For what's still open, **[TODO.md](TODO.md)**.

---

## Quick start

Requirements: `gcc`, `make`, `qemu-system-x86_64`, `flex`, `bison`,
`libelf-dev`, `mtools`, `parted`, `e2fsprogs`, Python 3.10+. For UEFI
testing also `ovmf`.

```bash
git clone https://github.com/HamnixOS/Hamnix
cd Hamnix

./scripts/build_installer_img.sh       # produces build/hamnix-installer.img (real-HW installer)
./scripts/build_installed_nvme.sh      # installs once → build/hamnix-installed.qcow2 (golden VM disk)
./scripts/test_installer_nvme_inram.sh # OVMF: installer writes ext4-on-NVMe, reboots off it
```

`build/hamnix-installer.img` is the **only install artifact**: an
ESP-only GPT image whose kernel + embedded squashfs root are loaded
entirely into RAM by firmware, so Hamnix never reads the boot medium. It
then writes a persistent ext4 root to the target's internal NVMe and
reboots off that disk alone — keeping the unfinished native USB driver
off the boot path.

There is no pre-baked root disk image. A real system is the ext4-on-NVMe
result of running that installer on a disk. For VM testing,
`scripts/build_installed_nvme.sh` runs the real installer path once into
a golden disk `build/hamnix-installed.qcow2`; feature tests boot a fresh
copy of it via `scripts/_installed_boot.sh`. Hamnix is UEFI-only; there
is no BIOS/GRUB path. (`scripts/build_iso.sh` is now a thin shim that
delegates to `build_installer_img.sh`.)

Flash to USB and boot on real hardware (use the installer image):

```bash
sudo dd if=build/hamnix-installer.img of=/dev/sdX bs=4M conv=fsync status=progress   # confirm /dev/sdX first!
sync
```

**`dd` will silently overwrite whichever device you point it at — confirm
the device with `lsblk` first.** See
[`docs/REAL_HARDWARE.md`](docs/REAL_HARDWARE.md) for the full procedure.

---

## Using hamsh

`hamsh` is the shell and PID 1 — the kernel `/init` shim execs
`/bin/hamsh /etc/rc.boot`. Python-syntax with C-style `{ }` blocks;
single grammar; deterministic statement dispatch by the first token.
Full reference in [`docs/HAMSH_SPEC.md`](docs/HAMSH_SPEC.md).

```
hamsh$ ls /dev                          # native binary on PATH
hamsh$ cat /proc/cpuinfo                # Plan 9-shape cdev
hamsh$ ifconfig                         # network info
hamsh$ ls /usr/bin | wc -l              # pipes work
hamsh$ echo hello > /tmp/x              # builtin redirects work
hamsh$ man hpm                          # discover commands
hamsh$ hpm install hamnix-coreutils     # native package manager
hamsh$ enter linux { /usr/bin/apt install hello }   # real Debian apt
hamsh$ hamUI new                        # spawn a bg window
hamsh$ cat /dev/wsys/2/text             # see what's on bg window 2
hamsh$ echo "ls /etc" > /dev/wsys/2/cmd # drive bg window 2 from here
hamsh$ newshell hostowner               # elevate (password prompt)
```

`/etc/rc.boot` is plain hamsh — namespace recipe + service launches +
the `linux = ns clean { … }` template definition all live there. Edit
it to change boot; no kernel rebuild.

---

## How it works

```
Adder source (.ad — Python syntax, static types)
   │
   ▼
adder/  ──►  codegen_x86.py   (hand-written x86_64 backend)
   │         (inlined in-tree since commit 9a8801e; no longer a submodule)
   ├──►  x86_64-bare-metal       → hamnix-kernel.elf  (M16+ kernel; DEFAULT)
   ├──►  x86_64-adder-user       → CPL-3 ELF          (bootstrap + oracle)
   └──►  x86_64-linux-kernel-module → .ko             (stock-Linux .ko regression)

adder/  ──►  ssa.ad → ssa_llvm.ad → clang   (LLVM backend)
   ├──►  x86_64 userland          → ET_DYN/PIE ELF64  (DEFAULT: 278/278 apps)
   └──►  aarch64                  → kernel + EL0      (the ONLY AArch64 path)
```

Kernel codegen honours SysV AMD64, 16-byte stack alignment, ENDBR64
for IBT, no red zone, RIP-relative `.rodata`. See
[`docs/x86-backend.md`](docs/x86-backend.md).

---

## Agent-orchestrated development

Hamnix is built with AI-assisted development running in parallel
worktrees. Each independent piece of work happens in a `git worktree`
clone under `.claude/worktrees/agent-<id>/`; an orchestrator session on
`main` reviews and cherry-picks. Discipline:

- Agents commit on their throwaway branch; only the orchestrator pushes
  to `origin`.
- Agents use `git add <specific paths>` — never `-A` or `.`.
- `README.md`, `TODO.md`, `STATUS.md` are orchestrator-only.
- Agents commit incrementally — the harness reaps quiet workers, so
  uncommitted WIP is lost.

The orchestrator's session memory is in [`memory/`](memory/) (not in
the repo). [`memory/feedback_compiler_quirks.md`](memory/feedback_compiler_quirks.md)
is the canonical example of how compiler quirks get tracked and fixed.

---

## Project structure

```
adder/           Adder compiler + LANGUAGE.md — inlined in-tree (was a submodule)
compiler -> adder/compiler              (symlink)

arch/x86/        Kernel architecture-specific (boot, kernel, mm, realmode)
drivers/         Native Adder drivers (ata/nvme/net/block/input/usb/tty/video/pci/rtc)
mm/              Memory management (memblock → page_alloc → slab/kmalloc)
kernel/sched/    Task struct, preemptive scheduler, per-task PML4
fs/              VFS, cpio initramfs, pipe, socketpair, ext4, fat, tmpfs, procfs
sys/src/9/port/  Plan 9 kernel surface — channels, namespaces, cdevs
lib/9p/          9P2000 codec
linux_abi/       Layer-2 Linux syscall shims + .ko-shim helpers
user/            Hamnix userland (hamsh, hpm, init, man, help, hamUI, ntpd, ...)
init/            start_kernel(), /init shim, boot smoke tests

kernel-modules/  M1..M15 stock-Linux .ko regression baseline
tests/           Integration tests + compiler regression fixtures
scripts/         build_installer_img.sh, test_*.sh, build_packages.py, gen_install_manifest.py
docs/            Project documentation (see index below)
memory/          Orchestrator session memory (not in repo)
```

---

## Documentation index

**Start here: [`docs/README.md`](docs/README.md)** — the navigable,
per-subsystem documentation map (generated from source, kept in sync per
[`docs/CONVENTIONS.md`](docs/CONVENTIONS.md)). The links below are the
cross-cutting design specs; the subsystem docs live under
[`docs/subsystems/`](docs/subsystems/).

- [`STATUS.md`](STATUS.md) — full M / L / U milestone log.
- [`TODO.md`](TODO.md) — what's still open.
- [`docs/architecture.md`](docs/architecture.md) — layered model,
  boundary rules, migration phases.
- [`docs/native-api.md`](docs/native-api.md) — Plan 9-shape syscall
  reference.
- [`docs/security.md`](docs/security.md) — hostowner, `/dev/auth`,
  namespace-as-authority.
- [`docs/packages.md`](docs/packages.md) — `hpm` v1 package format.
- [`docs/de_scene_file_arch.md`](docs/de_scene_file_arch.md) — scene-file
  display architecture (per-window display-list files, compositor-diffed
  damage, server-side decorations, evictable pixel caches, text-asserting gates).
- [`docs/HAMSH_SPEC.md`](docs/HAMSH_SPEC.md) — hamsh language + shell
  reference.
- [`docs/rootfs_partition.md`](docs/rootfs_partition.md) — ext4
  discovery, `.hamnix-roots` sentinel, named file-server stacks.
- [`docs/9p.md`](docs/9p.md) — 9P2000 wire spec.
- [`docs/distro-namespaces.md`](docs/distro-namespaces.md) — Phase C.5
  distro-shape namespace design.
- [`docs/BOOT.md`](docs/BOOT.md) — building + booting the UEFI installer
  image and the installed ext4-on-NVMe system.
- [`docs/REAL_HARDWARE.md`](docs/REAL_HARDWARE.md) — physical-hardware
  procedure + per-vendor firmware checklist.
- [`docs/x86-backend.md`](docs/x86-backend.md) — hand-written backend
  rationale.
- [`docs/L_TRACK_HOWTO.md`](docs/L_TRACK_HOWTO.md) — adding a stock-
  Debian `.ko` to the L-track.
- [`LANGUAGE.md`](LANGUAGE.md) — Adder language reference (symlink
  into `adder/LANGUAGE.md`; the compiler is inlined in-tree).
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — agent + human workflow.

---

## Working agreements

- Small commits that boot. A non-loading `.ko` is worse than fewer
  features.
- When a kernel idiom is awkward, propose a minimal language extension
  before working around it. Compiler bugs get **real fixes in the
  Adder compiler (in `adder/`) + a regression fixture in `tests/`**,
  never per-site workarounds.
- Naming: the language and compiler are **Adder**. The OS is **Hamnix**.
  Source files end in `.ad`.

---

## Links

- **[255.one](https://255.one/)** — the project's website: what it is,
  screenshots from a running system, an honest status table, and downloads.
  It is also the live `hpm` package repository.
- **[Releases](https://github.com/HamnixOS/Hamnix/releases)** — installer
  images, with checksums and release notes.
- **[docs/BOOT.md](docs/BOOT.md#0-try-it-build-an-image-boot-it-install-it-boot-the-result)**
  — build an image, boot it, install it, boot the result, as plain `qemu`
  commands.
- **[docs/what_works.md](docs/what_works.md)** — the measured, deliberately
  unflattering inventory of what does and does not work.
- **[HamnixOS/packages](https://github.com/HamnixOS/packages)** — the site
  and the package channels.

---

## License

GPL-3.0 — see [LICENSE](LICENSE).
