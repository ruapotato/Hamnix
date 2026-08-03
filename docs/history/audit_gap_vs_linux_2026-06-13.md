# Hamnix — Gap audit vs. a credible Linux/Unix distro

**Date:** 2026-06-13
**HEAD at audit:** `6135ebaf` (Docs: DE pivot wave 6 landed)
**Auditor:** orchestrator read-only sweep
**Supersedes:** the 2026-06-01 informal gap analysis referenced in memory
(the file `docs/competitor_gap_2026-06-01.md` is NOT actually present in
the working tree; this report stands as the new baseline).

This is a fresh, brutal cross-cut of what Hamnix would still need to be a
real Linux/Unix competitor that consumes Debian repos and ships as a
distro. The north-star is set; the question is what's actually in the
tree vs. what the docs claim.

---

## 0. Executive summary (read this if nothing else)

Where Hamnix is **genuinely competitive** today:
- Plan-9-shape native syscall surface + per-process Pgrp + 9P plumbing
  (`sys/src/9/port/`) is real and well-shaped (F1..F10 wave landed).
- ext4 read+write (15k LOC, `fs/ext4.ad`), FAT, exFAT read, ISO9660,
  squashfs, NTFS read, btrfs read — a *broader* read-side filesystem
  surface than most hobby kernels.
- ~240 Linux syscall handlers in `linux_abi/u_syscalls.ad` (14,637
  lines), enough to run real `apt 3.0.3` + `dpkg 1.22.22` inside
  `enter linux { … }`, plus CPython 3.11.10 and busybox under musl.
- Native net stack runs ARP/IP/UDP/TCP/ICMP/DHCP/DNS/HTTP/TLS 1.3 with
  a real `/net/tcp` 9P file tree; `sshd`/`httpd`/`curl`/`ntpd` are real.
- The L-shim loads ~24 stock-Debian `.ko` modules cleanly — the
  generic mechanism (the product, not the per-driver coverage) works.

Where Hamnix is **NOT yet** a Linux competitor:
- Hard, low resource caps in the kernel: **NTASKS=16**, **NR_FDS=16
  per task**, **8 TCP slots**. None of that survives contact with real
  Debian server software.
- Listen/accept side of `socket()` is **stubbed** in the Linux ABI
  (`u_syscalls.ad:14421`). sshd/nginx/postgres/mariadb cannot run as
  unmodified Linux binaries.
- No cgroups, no real LSM (SELinux/AppArmor/Landlock-only stub), no
  KASLR, no KPTI/SMEP/SMAP wiring, no kernel oops capture, no
  suspend/resume, no real wifi (iwlwifi loads but never trains).
- "Native" SCTP/MPTCP/WireGuard/IPsec/VXLAN/GRE/L2TP/MACsec/IPv6/etc.
  are **in-memory protocol selftests**, not wired into the `/net` tree
  or any NIC datapath (see §3 below — biggest single "are we lying?"
  finding).
- ARM64 is bring-up only (single `kmain.ad`, EL0 round-trip). Not a
  real second arch.
- Real-hardware bring-up still flaky: NUC USB mouse dead on metal,
  Asus keyboard never responded, no working wifi NIC.

The top three lifts that block "ship as a distro" credibility (full
ranking in §11):
1. **Lift NTASKS / NR_FDS / TCP slots** to dynamic + 4-digit ceilings.
2. **Real `accept/listen/bind`** through to the kernel TCP stack —
   without it, "Debian server in `enter linux`" is fiction.
3. **CPU mitigations + KASLR + KPTI + kernel oops capture** — security
   posture parity is currently below 2008-era Linux.

---

## 1. Linux kernel ABI breadth & depth

### What's there (cite first)
- 240 `_u_*` handler defs in `linux_abi/u_syscalls.ad` (14,637 lines).
- Confined Layer-2 leaves: `u_epoll.ad` (1,068), `u_iouring.ad` (2,167),
  `u_bpf.ad` (1,383), `u_netlink.ad` (1,146 — NETLINK_ROUTE), `u_caps.ad`
  (446), `u_keyring.ad`, `u_landlock.ad`, `u_perf.ad` (709 — software
  counters), `u_ptrace.ad`, `u_pidfd.ad`, `u_memfd.ad`, `u_userfaultfd.ad`,
  `u_quota.ad`, `u_fhandle.ad`, `u_process_vm.ad`, `u_sysvipc.ad`,
  `u_unixsock.ad`, `u_posixmq.ad`, `u_termios.ad`, `u_pty.ad`,
  `u_adjtimex.ad`, `u_mempolicy.ad`, `u_mseal.ad`, `u_cachestat.ad`,
  `u_process_madvise.ad`, `u_fuse.ad`, `u_futexv.ad`.
- 22 `api_l*.ad` files (`api_l49` … `api_l79`) carry 1,077 Linux-side
  function defs total — the `.ko` export surface.
- Real bpf(2) interpreter + lite verifier (`u_syscalls.ad:3247`-ish
  surrounding bpf hookup; `u_bpf.ad` 1,383 lines).
- seccomp-bpf classic filter landed (commit `c637c595`, 2026-06-12).
- io_uring SQ/CQ fixture landed (`65f870ca`).
- inotify init / add_watch / rm_watch real (`u_syscalls.ad:9880`).

### Partial / dishonest
- **`accept` / `bind` / `listen` are stubs** (`u_syscalls.ad:14421`:
  "V0 is client-side connect only — server sockets are V1"). This is the
  single most consequential gap for "Debian binaries just run".
- **`u_caps.ad` is faithful in shape, but gates NOTHING**
  (`u_caps.ad:18-20`: "cap sets here do not gate any kernel operation;
  they exist so libcap's get/set round-trip is faithful"). The shipping
  README "Plan 9 hostowner" model is fine; but any Debian binary that
  checks for a capability sees a paper response, not enforcement.
- **`setns(2)` registered but rejects** (`u_syscalls.ad:_u_setns` —
  "registered to reject gracefully" until nsfs exists).
- **No cgroups at all** (`u_syscalls.ad:7754` comment: "cgroup ns once
  we grow do_clone"). systemd-shape workloads won't run; container
  runtimes can't enforce limits.
- **No fanotify enforcement** — `_u_fanotify_init/_mark` defined
  (`u_syscalls.ad:10291,10324`) but the impl extent is unverified;
  watch-mode only is the kindest reading.
- **No real `init_module`/`finit_module`** path for non-L-shim modules
  (it's a stub for Debian-bundled `.ko`; the L-shim has its own loader).
- **No `keyctl` enforcement** — present as a Layer-2 leaf but, like
  caps, almost certainly bookkeeping-only.
- **ENOSYS count:** 28 `return -ENOSYS` sites in `u_syscalls.ad`. Not
  catastrophic, but the list includes shipping-tool-relevant arms
  (search `:14632` for the unknown-syscall trap).

### Missing
- Cgroups v1 + v2 (controllers, hierarchy, delegation).
- AF_UNIX `SOCK_SEQPACKET`, abstract socket namespace fully wired (declared
  as "stub-but-honest", `u_syscalls.ad:1161`).
- AF_PACKET / raw sockets — needed by tcpdump/dhclient.
- AF_NETLINK families beyond NETLINK_ROUTE (NETLINK_GENERIC, NL_AUDIT,
  NL_KOBJECT_UEVENT, NL_NETFILTER) — `u_netlink.ad:NL_NETLINK_ROUTE=0`
  only.
- `clone3` flag coverage (`u_syscalls.ad:7754` "set_tid lists, cgroup
  ns" missing).
- `kexec_load` / `kexec_file_load` — no kernel-replace path.
- `swapon` / `swapoff` — no swap subsystem at all (memory pressure
  blows up at NTASKS=16, see §0).
- `sched_setattr` / `sched_getattr` (deadline class).
- `userfaultfd` is registered (`u_syscalls.ad:237`), but UFFD-WP and
  hugepage handling are not real.
- Linux SELinux/AppArmor/Smack/Tomoyo LSM hooks (search yielded zero
  hits across the tree).

### Concrete impact
A real Debian server install would fail at `dpkg --configure -a` the
moment a postinst runs `systemctl`, `setcap`, `mount --bind`, or
anything pertaining to `/sys/fs/cgroup`.

---

## 2. Driver coverage (real silicon)

### What's there
- **Block:** AHCI (native), NVMe (native), virtio-blk
  (`drivers/block/`, `drivers/ata/`, `drivers/nvme/`).
- **NIC:** virtio-net (native), e1000e (`.ko` shim, `kernel-modules/e1000e/`),
  r8169 (native, 1,576 LOC), alx, atlantic, igb, sky2, tg3 — all `.ko`
  shim probes (loading != working: per `feedback_loading_vs_working.md`,
  one exercise test per subsystem class).
- **USB:** native EHCI 2.0 (`drivers/usb/ehci.ad`, 2,606), native xHCI
  (`drivers/usb/xhci.ad`, 5,522), HID boot keyboard, mass-storage.
- **Audio:** native HDA (`drivers/audio/hda.ad`, 999 — real PCM
  playback path) + mixer + capture selftest + `/dev/audio` cdev.
- **Input:** PS/2 keyboard (`drivers/input/atkbd.ad`) + AUX mouse
  (`drivers/input/auxmouse.ad`).
- **Video:** VGA text, `/dev/fb` framebuffer cdev, virtio-gpu
  (`drivers/video/virtio_gpu.ad`).
- **ACPI:** present (`drivers/acpi/acpi.ad`) — ACPI power-button → S5
  works (landed `d46cac42`).

### Partial / dishonest
- **USB on real hardware is the chronic wall** — NUC mouse dead on
  metal even after xHCI was rewritten; latest WIP is the .ko fallback
  path (`project_usb_ko_real_path` in memory).
- **xHCI on Asus i5-4210U built-in keyboard never responded**
  (`TODO.md:248`).
- **GPU:** virtio-gpu is the only video driver beyond framebuffer.
  i915 is in `kernel-modules/` but not on the boot path; native ANV
  is open (`TODO.md:#185`).
- **Wifi:** iwlwifi `.ko` loads (per `feedback_loading_vs_working`),
  but training was never validated. No wireless connectivity in
  practice.
- **No PCI hotplug / no USB hotplug surface on the cdev side.**
- **No sensor / hwmon path** even though `linux_abi/api_hwmon.ad`
  exists (it serves `.ko` consumers, not native temp/fan probes).

### Missing
- Suspend / resume / hibernate (`grep '/sys/power'` returns 0 matches
  outside fb-console suspend, which is a different concept).
- Real wifi end-to-end (iwlwifi, ath11k, mt76 all in
  `TODO.md:Bigger lifts`).
- Camera / webcam (UVC).
- Bluetooth — completely absent.
- Thunderbolt / DisplayPort / HDMI hotplug.
- Modern NVMe features: multi-queue, multi-namespace (`TODO.md:263`).
- AHCI NCQ (serialised on slot 0 today, `TODO.md:261`).
- I2C / SPI / GPIO subsystems.

### Concrete impact
Hamnix runs fine in QEMU with virtio devices; on a real laptop the
user surface is "keyboard + screen + ethernet via e1000e", and even
that's flaky. No suspend means a laptop install would burn battery on
the lid close.

---

## 3. Networking maturity — "are we lying about ourselves?"

This lens has the worst dishonesty risk in the tree.

### Real, in the data path
- `drivers/net/tcp.ad` (3,104 LOC) — real client TCP with RTO + Karn's
  algorithm, retransmit, but **only 8 slots**:
  `tcp_slot_state: Array[8, uint32]` (`tcp.ad:187`) and "no window
  scaling — 16-bit cap" (`tcp.ad:162`, `TCP_WIN_MAX=65535`).
- `drivers/net/udp.ad` (660) — used by ntpd / DNS.
- `drivers/net/ip.ad` (2,059) + `arp.ad` + `icmp.ad` (1,151) —
  unicast ARP + ICMP time-exceeded + redirect helpers landed
  (`056d4500`, `TODO.md:218`).
- `drivers/net/tls.ad` (5,535) — real TLS 1.3 with X25519 + ChaCha20-
  Poly1305, used by curl/wget/apt.
- `drivers/net/dhcp.ad` (761), `dns.ad` (2,137), `http.ad` (2,340).
- `firewall.ad` (1,918) — nftables-shape filter.
- `netfilter.ad` — packet hook.
- `qdisc.ad`, `fq_codel.ad`, `htb.ad` — queueing disciplines.

### "Are we lying" — the in-memory selftest cluster
The following files in `drivers/net/` are **NOT** wired to the NIC
datapath or the `/net` 9P tree; they are pure boot-time protocol
selftests. The file headers say so plainly, but the README narrative
("ARP / IP / UDP / TCP / ICMP / DHCP / DNS / HTTP / TLS 1.3
end-to-end") leaves the impression that the rest of the protocol
zoo is just as live. Each file's own header:

| File | LOC | Self-described scope |
|------|-----|----------------------|
| `sctp.ad` | 1,017 | "pure in-memory, two-endpoint association ... NO socket API and touches NO NIC" (`sctp.ad:3-7`) |
| `mptcp.ad` | 934 | in-memory selftest only |
| `wireguard.ad` | 1,264 | "the wireguard/ipsec/macsec self-tests this carries NO socket API and touches NO NIC" (cross-cite) |
| `ipsec.ad` | 728 | in-memory selftest only |
| `macsec.ad` | 1,039 | in-memory selftest only |
| `vxlan.ad` | 754 | in-memory selftest only |
| `geneve.ad` | 901 | in-memory selftest only |
| `gre.ad` | 629 | in-memory selftest only |
| `l2tp.ad` | 772 | in-memory selftest only |
| `ipip.ad` | 519 | in-memory selftest only |
| `sit.ad` | 559 | in-memory selftest only |
| `nat64.ad` | 1,281 | in-memory selftest only |
| `ipv6.ad` | 1,734 | in-memory selftest only (verify; the file is large but no `/net6` interface is wired) |
| `vlan.ad`, `bond.ad`, `bridge.ad`, `ipvlan.ad`, `macvlan.ad` | ~3k total | in-memory |
| `igmp.ad` | 785 | in-memory |

29 of the `drivers/net/*.ad` files match `selftest` literally. These
implementations are *real* RFC codecs that boot-time-prove the wire
format works — that is genuine engineering value. But shipping a
distro that says "WireGuard support" implies a user can `wg-quick up`
and route packets. None of that path exists. **The honest framing is
"protocol-codec library, no driver", not "WireGuard".**

### Listen / accept missing (repeating from §1 because it lives here)
- `u_syscalls.ad:14421` confirms `accept/bind/listen` are V1 stubs.
- The native `/net/tcp` 9P path *does* support listen — `sshd` and
  `httpd` use it. The Linux ABI cannot reach that path because the
  shim isn't bridged on the server side. **Every Debian server binary
  is currently broken**, regardless of how nicely apt installs it.

### Missing (real Linux-competitor surface)
- IPv6 routing/forwarding actually in the path (not just selftest).
- Multicast on the wire (no `IP_MULTICAST_IF`).
- AF_PACKET / SOCK_RAW — dhclient/tcpdump/nmap broken.
- TCP window scaling, SACK enforcement (parsed in `tcp.ad:335-340` but
  cap is 16-bit per `TCP_WIN_MAX`).
- nftables wire ABI (only an internal filter exists).
- BPF socket filter on real fds.
- TCP congestion control beyond the basic one (BBR, CUBIC tunables).
- Wifi association (no `nl80211` real handler).
- TLS 1.3 0-RTT, post-quantum hybrid — not on the path.

### Concrete impact
Anything beyond "client-side TCP/UDP" is brochure-ware. A would-be
Hamnix user trying to host a WireGuard VPN has nothing.

---

## 4. Filesystem maturity

### What's there (well)
- `fs/ext4.ad` 15,288 LOC — read + write, files up to 512 MiB,
  multi-block extent leaves. Realistically the most complete native
  Linux-ABI fs of any hobby kernel.
- Read-only: btrfs (`btrfs.ad`, 838), exfat (1,218), ntfs (934),
  iso9660 (579), squashfs (931), fat (2,299 — write too).
- jbd2 journaling stub (`jbd2.ad`, 733 — stubs=2; not load-bearing).
- overlayfs (1,163, selftest=1 — likely not on the path).
- VFS (`fs/vfs.ad`), tmpfs, procfs, pipe, socketpair, aes_xts (full-
  disk encryption codec).

### Partial
- **No working ext4 truncate-of-indexed-htree** (`TODO.md:223` — one
  attempt reverted, heartbeat regressed).
- **jbd2 is not on the write path** in real workloads.
- **No FUSE actually exposed** (`u_fuse.ad` exists; `FD_FUSE_*` folded
  onto Chan in `cd533a79`, but a real FUSE filesystem mounted from
  userspace isn't demonstrated under stress).
- **xattr surface** — present via `ext4_setxattr_path` etc.
  (`u_syscalls.ad:609-612`); ACLs (`system.posix_acl_*`) verified?
  Unclear.
- **overlayfs**: file exists but is selftest-driven; not used by
  `enter linux { … }`.

### Missing
- f2fs (Android default).
- ZFS (out of license scope; mention only).
- fs-verity / IMA / EVM (zero hits in tree).
- Disk quotas in any path (`u_quota.ad` is a stub for libquota
  round-trip).
- Real mount-namespace pivot_root (Hamnix uses Pgrp bind instead;
  Linux binaries that call `pivot_root(2)` still need a faithful path).
- A real Btrfs/ZFS COW write path.
- ENOTBLK, mounting block devices by UUID/LABEL (planted under
  `#by-id` is namespace-shaped, not classic mount semantics).
- `inotify` proven on real ext4 fanout (the inotify family is wired
  but unproven against shipping tooling load).

### Concrete impact
ext4 maturity is actually surprisingly good. The gap is in mount
semantics + fs-verity (Android, ChromeOS demand it).

---

## 5. Userspace base

### What's there
- 211 native binaries in `user/`. Real `hamsh` (Python-syntax shell +
  job control + service supervisor + runlevels).
- `hpm` package manager (5,400 LOC, BFS dep solver, channels).
- Real Debian apt 3.0.3 + dpkg 1.22.22 inside `enter linux { … }`.
- CPython 3.11.10 + busybox 1.36 as musl static-PIE.
- `crond`, `httpd`, `sshd`, `ntpd`, `vi`, `tar`, `gzip`, `hamfm`,
  `useradd`/`passwd`/`login`/`su`/`whoami`.
- `hamUI` DE with panel + menu + clock + drag-to-move.
- X11 first slice (core-protocol subset in `user/x11/`).

### Partial
- **No systemd** — Hamnix has `svc` + runlevels (correct call; but
  systemd-targeted Debian units won't translate).
- **No bash** in the native namespace; native shell is `hamsh`.
  `bash` runs only inside `enter linux`.
- **No `getent`, `nsswitch`, `pam`, `glibc`** native. (musl-PIE only.)
- **DE perf** — pivot in flight, mouse drops to 0.5 Hz on interaction
  (`TODO.md:16-31`).
- **`enter linux { /bin/sh }` interactive stdin doesn't reach the
  process** (`TODO.md:275` — known regression family #439).
- **Native packages are still binary-only**; source-based mode is
  planned (#186) but not landed.
- **NR_FDS = 16** per task is the real ceiling; Debian builds need
  hundreds.

### Missing
- `ld.so` for dynamically linked Debian binaries against glibc
  (currently all native is musl-static-PIE; `TODO.md:286` flags
  CPython's `_ssl`/`_socket` C extensions as "once a U-track `ld.so`
  exists").
- A real container runtime (runc / crun / podman) — needs cgroups +
  AF_UNIX abstract + pivot_root + capabilities enforcement.
- `make` / `gcc` / `binutils` in the native namespace (Debian
  toolchain works inside `enter linux`, but native self-host depends
  on Adder only).
- A login manager (gdm/lightdm) — `hamlogin` is custom; no PAM.
- D-Bus — completely absent.

### Concrete impact
Userspace is in good shape for "Plan 9 ethos" hobby use; "Debian
distro replacement" needs systemd/D-Bus/glibc-ld.so.

---

## 6. Desktop / DE

### What's there
- `hamUI` file-server-per-window UI (Phases 1, 2, 4a-4c). Per-window
  `/dev/wsys/N/{text,output,cmd,ns,pid,uid,kind,geometry}`.
- Panel + Applications menu + taskbar + clock (`hampanel.ad`,
  `hamappmenu.ad`, etc. — DE pivot waves 1-6 just landed).
- Drag-title-to-move + click-to-close + Alt-Tab cycler + Run dialog
  + screen lock overlay + screensaver.
- BDF font store (`24d867eb`); 3 fonts under `fonts/`.
- Snake + 2048 + hamedit + hamfm.
- X11 core-protocol subset (`user/x11/`).
- AI agents can drive a window via `cat /dev/wsys/N/text` +
  `echo cmd > /dev/wsys/N/cmd` — genuine differentiator.

### Partial
- **Interactive perf collapses to 0.5 Hz on drag/menu/rubber-band**
  (the entire `TODO.md` direction header — primary current focus).
- **Spurious keystrokes during window drag** — input mis-stitch
  (`a465991f` dropped keystrokes during drag; full fix pending).
- **DE terminal opens to empty `/`** — namespace template gap
  (`TODO.md:33-40`).
- **DE never validated on metal** — `feedback_merged_is_not_working`
  in memory.

### Missing
- Wayland — absent.
- Full X11/Xvfb bridge (gated on Phase 5 of hamUI).
- HiDPI scaling.
- IME / dead-key / compose (`TODO.md:270`).
- Accessibility (screen reader / large-text / contrast).
- Multi-monitor.
- GPU compositing (Phase 3+ of #181-185).
- Browser engine in any path.

### Concrete impact
The DE is shipping and clever (file-server-per-window is genuinely
novel), but **DE perf is the single biggest user-visible blocker** —
0.5 Hz interactive operations means a real user dismisses Hamnix in
30 seconds.

---

## 7. Distro / install

### What's there
- ESP-only UEFI installer (`build/hamnix-installer.img`).
- In-RAM root → writes ext4 to NVMe → reboots into installed system.
- `hpm` channels: `main` live; `non-free` + `non-free-firmware`
  placeholders.
- Multi-user (`useradd`/`passwd`/`login`/`su`/`whoami`).
- `enter linux { apt install … }` inside the distrofs namespace.

### Partial
- **UEFI only** — no BIOS/CSM. Fine for modern hardware, blocker for
  legacy.
- **Single installer flow** — no rescue/recovery, no A/B updates, no
  rollback.
- **No signed package indexes** (`TODO.md:308`).

### Missing
- GRUB / systemd-boot integration (Hamnix has its own PE/COFF stub).
- Multi-distro dual-boot (no chainloader).
- Secure Boot end-to-end (no Microsoft KEK / shim).
- Unattended/preseeded install.
- LUKS full-disk encryption on install (the `aes_xts` codec exists
  in `fs/aes_xts.ad` but no installer flow uses it).
- LVM, RAID (mdadm), thin pools.
- A/B kernel updates + rollback.
- Localization (locale, timezone selection in installer).

### Concrete impact
Install path works in OVMF+KVM, and on the NUC. For a credible distro
the "secure boot signed kernel + LUKS + LVM" trio is table-stakes.

---

## 8. Security / hardening

### What's there
- Plan-9-shape security model (`docs/security.md`): hostowner uid=1,
  regular users uid≥1000 get a restricted namespace.
- `/dev/auth` cdev + `setpass` verb + SHA-512 shadow + rate-limit.
- Default task uid is NOBODY (65534) per F10-3 (`79a260a1`).
- `access_ok` syscall-boundary pointer/length validator on every
  user pointer (`#163` uaccess audit landed, `STATUS.md:1c7d3524`).
- seccomp-bpf classic filter (`c637c595`, 2026-06-12).
- W^X + NX + stack-base ASLR + ET_DYN load-bias + interp + mmap-base
  ASLR (`STATUS.md:778`, `46491912`).
- Landlock as Linux-ABI-only furniture (`u_landlock.ad`).

### Partial / dishonest
- **`u_caps.ad` does NOT gate operations** (`u_caps.ad:18-20` — own
  file says so). README claims capabilities support; the cap sets are
  paper.
- **Landlock is Linux-ABI furniture only** (`u_syscalls.ad:325-329`),
  not an actual enforcement plane on the native side.
- **No KASLR** — kernel base is fixed at `0xffffffff80000000`
  (`STATUS.md:449` references `KASLR address bases` but only in the
  `exports.ad` sense for `.ko` consumers; the kernel itself doesn't
  randomise).
- **No KPTI** (page-table isolation against Meltdown).
- **No SMEP/SMAP wiring at boot** (`trap_diag.ad:382` reads "SMAP is
  not enabled" as a comment).
- **No CPU mitigations**: retpoline, IBRS, IBPB, MDS_CLEAR, eIBRS.

### Missing
- LSM (SELinux/AppArmor/Smack/Tomoyo) — zero hits across the tree.
- audit subsystem (`auditd` shape).
- secure boot end-to-end (shim → grub → signed kernel).
- TPM2 / measured boot.
- DM-verity / fs-verity enforcement.
- Kernel lockdown mode.
- `prctl(PR_SET_NO_NEW_PRIVS)` enforcement on real binaries (declared
  but enforcement coverage unclear).
- AppArmor profiles for shipped daemons.
- `auditd` event stream.

### Concrete impact
Hamnix's security posture is **below 2008-era Linux**. Plan-9
namespace authority + access_ok + seccomp + ASLR are real and good,
but the absent CPU mitigations + no LSM + paper-only capabilities
mean a distro built on Hamnix would not pass any modern compliance
review (PCI DSS, FedRAMP, anything).

---

## 9. Observability

### What's there
- `/proc/uptime`, `/proc/loadavg`, `/proc/meminfo`, `/proc/cpuinfo`,
  `/proc/version`, `/proc/diskstats`, `/proc/net/{dev,route,arp,tcp,udp,sockstat}`
  (`e7d68cc3`, 2026-06-12).
- `dmesg` + per-svc logs at `/var/log/svc/`.
- Live `man` pages.
- `u_perf.ad` (709) — perf_event_open software counters.

### Partial
- **perf is software-counter only** (`u_perf.ad:1` — explicit).
- No PMU access (no Intel PT, no LBR, no PEBS).
- `/proc/<pid>/{maps,status,stat,cmdline}` partially present.

### Missing
- ftrace / kprobes on running kernel (kprobes work on `.ko` regression
  baseline M7.1, not on the M16 kernel itself).
- eBPF observability (`bcc`, `bpftrace`) — bpf interp is there but
  the tracepoint sources aren't.
- Kernel oops capture / kdump (`TODO.md:309` — "kernel panics vanish
  into the serial console").
- systemd-journald-shape structured logging.
- coredumps on a real path (`u_syscalls.ad` references `/tmp/core` but
  that path is veneer-only now).

### Concrete impact
A sysadmin trying to debug a flaky daemon has `dmesg` and svc logs.
No `journalctl`, no `bpftrace`, no kdump on panic. Production
debugging story is weak.

---

## 10. Multi-arch

### What's there
- x86_64 is the production target. `arch/x86/` 17k LOC including
  `.S` boot stubs.
- aarch64 backend exists (Adder codegen), and `arch/arm64/`:
  - `boot.S`, `vectors.S`, `kernel.lds`, single `kmain.ad` (31k LOC).
  - QEMU `virt` target; EL0 round-trip works.

### Partial
- **arm64 is bring-up only**: one giant `kmain.ad`, no chan/proc/
  scheduler port. No `arch/arm64/{kernel,mm,...}` parallel of x86.
- **No arch-interface factored** (`TODO.md:298` — "do once ARM64
  bring-up is stable").

### Missing
- riscv64 — entirely absent.
- 32-bit x86 — explicitly out of scope (acceptable).
- Real-HW arm64 (Pinebook Pro target per `project_arm64_bringup_target`).
- GICv3 / SMMU.

### Concrete impact
Hamnix is single-arch in practice. ARM64 deprioritised (`TODO.md:147`).
Calling Hamnix "multi-arch" would be a stretch.

---

## 11. Top-15 lifts ranked by (impact × tractability)

| # | Lens | Gap | Effort | Impact | Distro blocker? |
|---|------|-----|--------|--------|----------------|
| 1 | Kernel | Lift `NTASKS=16` (`kernel/sched/core.ad:939`) and `NR_FDS=16` (`core.ad:5553`) to dynamic + ≥1024 ceilings | M | Critical | YES — anything beyond toy load wedges |
| 2 | Linux ABI | Real `accept` / `bind` / `listen` bridged to native TCP stack (`u_syscalls.ad:14421`) | M-L | Critical | YES — no Debian server runs today |
| 3 | Kernel | TCP slot table to ≥256 + window scaling (`drivers/net/tcp.ad:162,187`) | S-M | High | YES — `apt install` of any big package starves connections |
| 4 | Security | KASLR + KPTI + SMEP/SMAP wiring at boot | M | High | YES for any compliance use |
| 5 | Observability | Kernel oops / panic capture to disk (`TODO.md:309`) | S-M | High | NO but huge dev-velocity hit |
| 6 | Driver | Suspend/resume — no `/sys/power` consumer at all | L | High | YES on laptops |
| 7 | Distro | Real LSM (Landlock enforce, or AppArmor surface) — currently `u_caps.ad` and `u_landlock.ad` are paper | L | High | YES for compliance |
| 8 | Linux ABI | Cgroups v2 controllers + delegation (currently zero) | XL | High | YES for systemd / containers |
| 9 | DE | Fix interactive-perf collapse to 0.5 Hz (`TODO.md:16-31`) | M | High | NO (dev-fac) but Day-1 user dismissal risk |
| 10 | Networking | Land wireguard/ipsec/vxlan/macsec/gre/l2tp as *real* drivers, not selftests (or stop marketing them) | L per protocol | Medium | NO directly but a credibility risk |
| 11 | Filesystem | Real Btrfs/ZFS write OR drop the claim; jbd2 actually on path | XL | Medium | NO (ext4 is fine) |
| 12 | Linux ABI | `ld.so` for glibc-dynamic Debian binaries (`TODO.md:286`) | L | Medium | YES for ".deb just runs" |
| 13 | Kernel | Swap — currently no swap subsystem, OOM-at-16-tasks hits fast | M | Medium | NO but velocity hit |
| 14 | Driver | Bluetooth + UVC (camera) + nl80211 wifi associate | XL | Medium | NO for server, YES for desktop |
| 15 | Multi-arch | Factor arch-interface; finish arm64 chan/proc/sched (`TODO.md:298`) | L | Medium | NO but blocks the second-arch claim |

Effort key: S = ≤1 week, M = ≤1 month, L = ≤1 quarter, XL = > 1
quarter, sustained.

---

## 12. "Are we lying about ourselves?" — brutal section

Items where docs/STATUS/README assert completeness but the code
behind it is meaningfully thinner than the claim. None of these is
malicious; some are stylistic. All deserve a doc tightening.

1. **README §Network claim: "ARP / IP / UDP / TCP / ICMP / DHCP /
   DNS / HTTP / TLS 1.3 end-to-end"** — true. But the *adjacency* of
   29 `drivers/net/*.ad` files for WireGuard/IPsec/SCTP/MPTCP/MACsec/
   VXLAN/GRE/L2TP/IPIP/SIT/NAT64/IPv6/IGMP suggests parity that does
   not exist. Each file's own header is honest ("pure in-memory ...
   NO socket API and touches NO NIC"). **Recommendation:** rename
   the directory or split it (`drivers/net/proto-codecs/`) and add
   one paragraph to the README distinguishing "on-the-wire" from
   "codec-only" net code.

2. **README §Linux ABI: "~250 syscalls"** — true (240 `_u_*`
   handlers). But the sentence omits that **`accept/bind/listen` are
   stubs** (`u_syscalls.ad:14421`). For a reader trying to gauge
   "will my Debian server binary run", this is the most consequential
   omission. **Recommendation:** add a sentence: "Client-side
   socket(2) calls work; `accept/bind/listen` are stubbed (V1)".

3. **README §Security: "POSIX capabilities"** — implied by the apt/
   dpkg shipping path. `u_caps.ad:18-20` explicitly says **the cap
   sets gate NO kernel operation**. **Recommendation:** "Capability
   syscalls are honoured at the API level (libcap round-trips) but
   are not yet enforced in Hamnix's privilege checks."

4. **STATUS §Stack-base ASLR (M..., "Done")** — true. But the row is
   adjacent to "Stage-2 ET_DYN/interp/mmap ASLR" and a reader might
   infer **KASLR (kernel-side)**, which does not exist. The kernel
   itself loads at a fixed `0xffffffff80000000`.

5. **README §Storage: "AHCI + NVMe"** — true at probe, but `TODO.md`
   itself says AHCI is "serialises on slot 0 today; no NCQ", and
   NVMe has no multi-queue/namespace. **Recommendation:** mark these
   "single-queue".

6. **STATUS .ko cluster (24 stock Debian .ko load cleanly)** — true,
   per `feedback_loading_vs_working.md` itself: "The product is shim
   genericity, not per-driver completeness." A casual reader sees a
   real iwlwifi driver; the reality is "load + a one-shot exercise
   per subsystem class". **Recommendation:** README footnote already
   exists ("loading != working"); make sure the iwlwifi row in any
   shipping marketing copy is gated.

7. **README §"hamUI Phase 1, 2, 4a, 4b, 4c landed"** — true (the
   code is in `user/`). Not addressed: under the same documented
   workload, **interactive operations drop to 0.5 Hz** (own
   `TODO.md:21`). A user reading "shipping DE" infers "usable DE".

8. **README §Multi-user auth "real end-to-end"** — true on the
   /dev/auth + setpass + SHA-512 path. **Default task uid was 1
   (hostowner) until 4 days ago** (`79a260a1`, 2026-06-13); pre-fix
   running services were silently hostowner-privileged. STATUS
   captures this as F10-3; users of older installer images should
   be told to reinstall.

9. **README §"Real Debian apt 3.0.3 + dpkg 1.22.22"** — true. But
   the `enter linux { /bin/sh }` *interactive* path doesn't deliver
   keystrokes (`TODO.md:275`); only batch (`apt install foo`) runs.
   **Recommendation:** add "(non-interactive)" qualifier to the apt
   row.

10. **README §"sshd ships and auto-spawns at boot"** — true (native
    sshd over the /net 9P tree). Reader infers Debian's openssh-server
    would work; it would NOT (no listen on the Linux ABI). Document
    that "sshd" here is native, not openssh-server.

---

## 13. What would I cut from the marketing?

If the goal is to be a credible Linux competitor:
- Move 14 net-protocol files (`sctp/mptcp/wireguard/ipsec/macsec/
  vxlan/geneve/gre/l2tp/ipip/sit/nat64/bond/bridge/ipvlan/macvlan/
  vlan/igmp`) under `drivers/net/codecs/` with a clear
  README — they're great code, badly framed.
- Re-tag `u_caps`, `u_landlock`, `u_perf`, `u_keyring`, `u_quota` as
  "API-faithful, not enforcing" until they are enforcing.
- Add a "**Not yet**" section to the README covering: KASLR, KPTI,
  SMEP/SMAP, cgroups, suspend/resume, real wifi, Wayland, listen(2),
  systemd, glibc-ld.so, kdump. A blunt "not yet" list is more
  credible than implicit absence.

---

## 14. What I'd queue next (orchestrator's call)

Three independent agent worktrees, max one concurrent per memory rules:
- **Track A — server-binary unblock:** real `bind/listen/accept` in
  `u_syscalls.ad` bridged to `drivers/net/tcp.ad`. Lifts TCP slot
  table to ≥256 + window scaling. Prereq for every other Linux
  server-binary use case. Estimate: 2-3 weeks.
- **Track B — security baseline catch-up:** wire SMEP+SMAP at boot,
  add KASLR (kernel base randomise), KPTI page-table isolation.
  Estimate: 3-4 weeks; touches `arch/x86/kernel/` and the mm layer.
- **Track C — DE perf:** finish the active pivot (`TODO.md:16-31`)
  so that mouse cursor renders independently of compositor work and
  drag/menu/rubber-band don't drop to 0.5 Hz. Currently the user's
  hard focus.

Out of the three, Track A is the one that single-handedly moves the
"Linux competitor" story forward most. Track C is what an end-user
notices first. Track B is what a security auditor notices first.

---

## 15. Methodology + caveats

- Read-only audit; no compilation done.
- Numbers from `wc -l` and `grep` on HEAD `6135ebaf`.
- TODO/FIXME/stub/ENOSYS counts are lexical, not semantic — they
  understate sophisticated dishonesty (a file with no `TODO`s can
  still be a paper stub, as the in-memory net protocols show).
- Memory notes (`/home/david/.claude/projects/-home-david-Hamnix/memory/`)
  were consulted for context, including
  `project_competitor_gap_analysis`, `project_endgame`,
  `project_north_star`, and the `feedback_*` files.
- No verification of test pass/fail; trust the STATUS rows for
  landings dated through 2026-06-13.

End of audit.
