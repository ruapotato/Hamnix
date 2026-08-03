# Hamnix 1.0

<p align="center">
  <img src="https://255.one/img/desktop.png" alt="The Hamnix desktop: panel, clock, desktop icons and wallpaper" width="900">
</p>

A from-scratch operating system — kernel, drivers, filesystems, network
stack, desktop and package manager — written in **Adder**, a Python-syntax
systems language with its own compiler. Plan 9-shape namespaces at the
syscall layer, a Linux ABI shim above them, sharing one kernel.

This release exists because the project set out to find whether something
like this was possible. It is. 1.0 means *the thing works and is worth
looking at* — not *ready to be your daily driver*. The difference is spelled
out below, and on [255.one](https://255.one/).

---

## What it is

|  |  |
|---|---|
| Native Plan 9-shape syscalls | 106 |
| Userland applications | 278 |
| Packages in the repository | 100 |
| Host test gates | 577 |
| Lines of C in the kernel | 0 |

- **Two worlds, one kernel.** Native code sees Plan 9-shape files —
  `/dev/cpuinfo`, `/net/tcp`, per-process namespaces built with `bind`.
  Linux binaries run inside `enter linux { … }`, where the *same* kernel
  file servers are bound at the paths Debian expects. No string rewriting
  in the syscall path.
- **No sockets.** TCP, UDP and TLS 1.3 are the `/net` file tree. There are
  zero BSD socket syscalls at the native layer.
- **Its own everything** — language, compiler, web engine, package manager,
  scene-file desktop where the kernel owns no pixels.

## Verified for this release

Measured on **2026-08-03** from a freshly built image booted six times under
OVMF/KVM. Every claim is backed by a real framebuffer scanout or serial
transcript, kept in [`docs/screenshots/`](https://github.com/HamnixOS/Hamnix/tree/main/docs/screenshots).

| | |
|---|---|
| Desktop launchers shipped | 26 |
| Launched and painted a real UI | **26 / 26** |
| Responded to keystrokes sent | **16 / 26** |
| Could be closed | **0 / 26** |
| Kernel faults across six boots | **0** |

A separate **four-hour soak** — 2,444 application launches and closes —
finished with **no measurable leak**.

## What does not work

Stated plainly, because a release nobody can trust is worse than a small one.

- **Bare metal is unverified at this revision.** It booted an Intel NUC and
  an Asus laptop historically, hundreds of commits ago. Everything since has
  been QEMU/KVM. Treat bare metal as "worked once, expect to need work".
- **Nothing can be closed from a script.** `kill` does not unmap a scene
  window, and the `free <wid>` ctl verb is hostowner-gated.
- **No Wi-Fi** (wired only) and **no GPU acceleration** (software rasteriser).
- **The web engine reaches ~83%** of a pinned Web Platform Tests subset;
  Chromium scores ~91% on the identical harness. Real pages render; heavy
  JavaScript sites will not work.
- Rough edges reproduced and recorded: the Applications menu has no keyboard
  navigation and ignores Backspace; the Software app renders `hpm`'s stdout
  as package rows and disagrees with `hpm list` on the same boot; pointer
  latency degrades as windows accumulate (117 ms at two windows, 310 ms at
  twenty).
- The AArch64 port boots to EL0 on QEMU `virt` with per-task address spaces,
  demand paging and per-task kernel stacks — but there is no hardware port.

> **Please do not install this on a machine you care about.** It partitions
> and formats real disks. A virtual machine is the right place to try it.

## Getting it

The recommended artifact is the **in-RAM installer image**: firmware loads
the kernel and a squashfs root entirely into memory, so nothing is read from
the boot medium after handoff.

```sh
# try it in a VM
qemu-system-x86_64 -enable-kvm -m 2G \
    -bios /usr/share/OVMF/OVMF_CODE.fd \
    -drive file=hamnix-installer.img,format=raw
```

Or build it yourself — the tree is self-contained; the host needs Python,
`clang` and QEMU:

```sh
git clone https://github.com/HamnixOS/Hamnix
cd Hamnix
bash scripts/build_installer_img.sh
```

## Reports welcome

Bare-metal results — **working or not** — boot logs from machines that fail,
and pages the browser renders badly are all genuinely useful.
[Open an issue](https://github.com/HamnixOS/Hamnix/issues).

---

*Hamnix and Adder written by David Hamner. Packages and site:
[255.one](https://255.one/).*
