# Hamnix — Gap audit vs. a credible Linux/Unix desktop + server

**Date:** 2026-07-10
**HEAD at audit:** `a19720e0` (docs/orchestrator: host ACPI-thermal degradation root-caused)
**Auditor:** orchestrator read-only worktree sweep
**Supersedes:** `docs/audit_gap_vs_linux_2026-06-13.md` (~1 month stale; the top-3
lifts it flagged are now DONE — see §0).
**Method:** read-only. `wc -l`/`grep`/`sed` against the working tree at
`a19720e0`; STATUS.md milestone rows T1–T88 + M/L/U/F series; TODO.md open
markers; memory `feedback_*`/`project_*` for context. No QEMU boots (no
verification of runtime pass/fail beyond what STATUS/CI rows assert — see
§Method caveats). Numbers are lexical unless a body was read.

---

## 0. Executive summary — what moved since 2026-06-13

The single most important finding: **the three "distro-blocker" lifts the
June audit ranked #1/#2/#3 are all CLOSED.**

| June-audit blocker | June state | Now (2026-07-10) | Proof |
|---|---|---|---|
| `NTASKS=16` | hard cap, wedges past toy load | **256** | `kernel/sched/core.ad:2290,7139,10975`; `cgroup_cpu.ad:35` |
| `NR_FDS=16` per task | Debian builds need hundreds | **64** | `kernel/sched/core.ad:258,7421` ("bumped to 64 … Debian server workloads") |
| 8 TCP slots, no listen | client-only; every server binary broken | **256 slots + real `accept/bind/listen`** bridged to `/net` | `drivers/net/tcp.ad:188`; `u_syscalls.ad:5090,5268,5385`; T71 inbound-SSH "WORKING" |

So the June headline — *"Debian server in `enter linux` is fiction"* — is no
longer true. `_u_listen` (`u_syscalls.ad:5385`) does a real `/net` announce +
`tcp_listen`; `_u_accept`/`_u_accept4` exist (`:5090,:5251`); AF_UNIX
`bind/listen/connect/accept` exist (`:458`). STATUS T71 ("inbound-TCP-accept …
inbound SSH TIER-3 working") and T72 (host a website) are the runtime evidence.
This is the biggest credibility gain in the tree since June.

Other June "missing" items now landed:
- **Swap** (June §1: "no swap subsystem at all") → `mm/swap.ad` (RAM-backed
  zram-model evict/restore) + `mm/reclaim.ad`.
- **SMEP/SMAP** (June §8: "not wired at boot") → T10, `cpu_mitigations.ad:524`
  `setup_smep_smap`, unconditional US=0 restamp, audit shows 0 high-half leaks.
- **KASLR** (June §8: "no KASLR") → **partial**: T12/`cpu_kaslr.ad` randomizes
  the *module-mapping window* per boot; the kernel *image* base is still fixed
  (honest, documented — see §8).
- **cgroup CPU controller** (June §1: "no cgroups at all") → **partial**:
  `kernel/sched/cgroup_cpu.ad` (8 cgroups, weight-based CPU). Memory/pids/io
  controllers + full v2 hierarchy still absent.
- **Native browser** (June §6: "browser engine in any path — absent") →
  `user/hambrowse.ad` (T75): fetch-over-HTTP/TLS + HTML-subset layout + render
  + clickable links + address bar. **No CSS/JS/tables/images/forms** (§12).
- **DE breadth** (June §6): notifications (`hamnotif`/`hamosd`/`hamtoast`),
  settings (`hamsettings`), session (`hamsession`/`hamsessui`), tray
  (`hamtray`), sysmon (`hamsysmon`), screenshot (`hamshot`), lock/saver — all
  now present as native tools (§10b).

### The current top-10 gaps, ranked (impact × tractability)

1. **DE cursor-hotspot + ~0.5 s terminal input lag** — the first thing a user
   touches still feels broken (`TODO.md:601` "cursor hotspot … terminal ~0.5s
   input lag"). Native-first. **S–M.**
2. **`-smp 2` guest wedge (regression)** — an idle shell/pipeline halts in
   `yield_to_others`; tests dodge it at `-smp 1`, hiding it. Ships in the image.
   `TODO.md` "Open blockers". Native-first. **M.**
3. **hambrowse can't render the real web** — no CSS/JS/tables/images/forms;
   most sites are unusable. The "native browser" claim needs this. Native-first.
   **L (per capability).**
4. **KPTI + SMAP CR4-flip + full CPU-mitigations** — SMEP/SMAP page-stamp
   landed, but `TODO.md:509` "SMAP CR4-flip + KASLR + KPTI" still open;
   `cpu_mitigations.ad` has no retpoline/IBRS/IBPB/MDS. Native-first. **M.**
5. **Firefox last mile (Linux-ns Wayland)** — reaches
   `wl_compositor.create_surface` then never maps an `xdg_surface`; GDK realize
   never advances to map. The whole "real browser" fallback rides on this.
   Linux-ns-fallback. **M.**
6. **Package signing / signed indexes** — hpm verifies sha256 of tarballs but
   the *index is unsigned* (`TODO.md` "Signed package indexes"); no GPG/ed25519
   trust root. A distro that fetches over the network needs this. Native-first.
   **M.**
7. **glibc `ld.so` for dynamic Debian binaries** — native is musl-static-PIE
   only; CPython C-extensions + most `.deb` binaries that aren't static need a
   dynamic loader (`TODO.md:664`). Linux-ns-fallback. **L.**
8. **Kernel parity long tail: RCU, EEVDF/CFS, hrtimers, page cache** — still
   `[ ]` in `TODO.md:147,149,155,192`; scheduler is O(NTASKS) linear
   min-vruntime, timers are tick-granular. Native-first. **L each.**
9. **Networking still codec-only for the protocol zoo** — WireGuard/IPsec/
   SCTP/MPTCP/VXLAN/etc. remain in-memory selftests, not `/net`-wired (§3,
   unchanged since June). IPv6 not in the datapath. Native-first. **L per
   protocol.**
10. **Real-HW input still dead** — NUC USB mouse dead on metal; Asus keyboard
    never responded (`TODO.md` "Metal bring-up"). Native-first. **L.**

---

## 1. Linux kernel ABI breadth & depth

### Real (verified this pass)
- `linux_abi/u_syscalls.ad` is now **19,765 lines** (was 14,637 in June).
- **Server sockets are REAL.** `_u_bind` (`:5268`), `_u_listen` (`:5385`),
  `_u_accept`/`_u_accept4` (`:5090,:5251`) call the in-kernel `tcp_listen`/
  `tcp_accept` via a `/net` clone+announce. AF_UNIX `SOCK_STREAM` bind/listen/
  connect/accept present (`:451-458`). Dispatch wired at `:19541-19557`.
- **Swap** exists (`mm/swap.ad`, `mm/reclaim.ad`) — anonymous-page evict/restore
  on memory pressure; RAM-backed store (zram model, honest in the header).
- **cgroup CPU controller** (`kernel/sched/cgroup_cpu.ad`, 8 cgroups).
- FUTEX self-heal sweep landed (`_futex_sweep_expired` on the arch tick — QA
  sweep 2026-07-08 fixed an infinite `FUTEX_WAIT` park that killed threaded
  apps).
- Confined Layer-2 leaves from June still present (`u_epoll`, `u_iouring`,
  `u_bpf`, `u_netlink`, `u_caps`, `u_landlock`, `u_perf`, `u_pidfd`, `u_memfd`,
  `u_userfaultfd`, etc.).

### Partial / still dishonest
- **`u_caps.ad` still gates nothing** (unchanged since June — the cap sets exist
  for libcap round-trip only). Any Debian binary that relies on capability
  *enforcement* sees a paper response.
- **cgroups is CPU-only.** No memory/pids/io controllers, no unified v2
  hierarchy/delegation, no `/sys/fs/cgroup` tree that systemd would walk.
- **44 `return -ENOSYS` sites** in `u_syscalls.ad` (was 28 — the file grew, so
  did the honestly-unimplemented arm count).
- **`setns`/nsfs, `clone3` full flag set** — still not honored (`TODO.md`
  "cgroup ns once we grow do_clone").
- **`enter linux { /bin/sh }` interactive stdin still doesn't reach the process**
  (`TODO.md:660`) — batch `apt install foo` works, an interactive shell inside
  `enter linux` does not (sshd sessions have their own pty and DO work — T74).

### Missing vs modern Linux
- cgroup v2 memory/pids/io controllers + delegation (blocks systemd/containers).
- AF_PACKET / SOCK_RAW (tcpdump/dhclient/nmap).
- NETLINK families beyond NETLINK_ROUTE.
- LSM hook framework (SELinux/AppArmor/Smack/Tomoyo) — still zero hits.
- `kexec`, `sched_setattr` (deadline), UFFD-WP, hugepages.

### Impact
The June "no Debian server runs" wall is gone. The remaining ABI wall is
**systemd-shaped**: a real Debian `postinst` that touches `/sys/fs/cgroup`,
`setcap`-enforced binaries, or `systemctl` still fails. "Runs Debian *server
daemons* over the socket ABI" is now true; "runs a *systemd* Debian" is not.

---

## 2. Driver coverage (real silicon)

Largely unchanged from June; the honest gaps persist.

### Real
- Block: AHCI, NVMe, virtio-blk (native). NIC: virtio-net native + `.ko` shims
  (e1000e/r8169/igb/tg3/…). USB: native EHCI + xHCI + HID + MSC. Audio: native
  HDA. Input: PS/2 kbd + AUX mouse. Video: VGA text, `/dev/fb`, virtio-gpu.
  ACPI power-button → S5.
- **S3 suspend path is now "real"** per `TODO.md:513` ("S3 path real; HW
  wake-vector trampoline … remaining") — a step past June's "no `/sys/power`
  consumer at all", but the wake trampoline is unfinished.

### Partial / dishonest
- **Real-HW USB is still the chronic wall**: NUC mouse dead on metal, Asus
  built-in keyboard never responded (`TODO.md` "Metal bring-up"). In a VM with
  virtio it's fine.
- **`.ko` = "loads", not "works"** (per `feedback_loading_vs_working.md`) — iwlwifi
  loads, never trains; no wifi in practice.
- AHCI serializes on slot 0 (no NCQ); NVMe single-queue/namespace (`TODO.md`
  "Driver / storage / input maturity").
- GPU: virtio-gpu + a native software-raster spine in progress (#181–185, all
  `[~]`); no accelerated path on the boot line.

### Missing
- Real wifi end-to-end, Bluetooth, UVC camera, suspend *wake*, I2C/SPI/GPIO,
  DP/HDMI hotplug, PCI/USB hotplug surface.

### Impact
Unchanged: on a real laptop the surface is "keyboard + screen + wired ethernet",
and even that is flaky. Suspend can now enter S3 but the wake path isn't done —
a lid-close on metal is still unsafe.

---

## 3. Networking maturity — "are we lying?" (mostly UNCHANGED)

The **server-side unblock** (§0/§1) is the big win. But the June "are we lying"
finding stands almost verbatim:

### Real, in the datapath
- `tcp.ad` (client + now server-side accept), `udp.ad`, `ip.ad`, `arp.ad`,
  `icmp.ad`, `tls.ad` (TLS 1.3), `dhcp.ad`, `dns.ad`, `http.ad`, `firewall.ad`.
- **TCP slots now 256** (`tcp.ad:188`) — up from 8.
- Inbound + outbound SSH work (T70/T71), httpd serves (T72, MAX_WORKERS→4 in
  T87).

### Still codec-only (NOT wired to a NIC or `/net`)
`sctp/mptcp/wireguard/ipsec/macsec/vxlan/geneve/gre/l2tp/ipip/sit/nat64/ipv6/
igmp/vlan/bond/bridge/ipvlan/macvlan` remain **pure in-memory boot selftests**
(each file's own header says so). Great RFC-codec engineering; **not** shippable
"WireGuard support". IPv6 is a selftest, not a `/net6` interface.

### Still missing
- **`TCP_WIN_MAX=65535`, no window scaling** (`tcp.ad:163`) — throughput cap
  survives from June; big `apt` downloads over long fat pipes stall.
- AF_PACKET/SOCK_RAW; multicast on the wire; nftables wire ABI; BBR/CUBIC;
  nl80211 wifi associate; forwarding is gated off by default
  (`ip_forwarding_enabled=0`).

### Impact
"Client + server TCP/UDP + TLS + SSH + HTTP" is now genuinely true and tested.
Everything past that (VPN, IPv6 routing, tunnels) is still brochure-ware.

---

## 4. Filesystem maturity

### Real (strong)
- `fs/ext4.ad` (~15k LOC) read+write; FAT read+write; exFAT/NTFS/iso9660/
  squashfs/btrfs read. **dcache + inode cache landed** (`TODO.md:175` `[x]`,
  "+ rcu-walk"). **per-VMA locking + maple tree** landed (`TODO.md:186` `[x]`).
- QA sweep fix: the global open-file table went **8 → 512** (the 9th concurrent
  file no longer laundered ENOENT).

### Partial
- **No VFS page cache (`address_space`)** — `TODO.md:155` `[ ]`, "block-only
  today"; **no dirty writeback throttling / per-bdi flushers** (`:184`) — `fsync`
  is synchronous.
- jbd2 journaling still not on the real write path.
- ext4 truncate-of-index-node + growing a full dir block still broken (a prior
  attempt reverted, broke heartbeat) — `TODO.md` "Driver / storage".
- FUSE surface exists but unproven under stress.

### Missing
- f2fs, real COW btrfs/ZFS write, fs-verity/IMA/EVM, disk quotas on a real path,
  LUKS in the installer flow (the `aes_xts` codec exists, no installer uses it),
  LVM/RAID.

### Impact
ext4 remains the crown jewel and is now install-backing (T83: the disk boots off
ext4 — "the OS is INSTALLABLE"). The gap is the *page cache* (every read hits
the block layer) + mount-semantics + verity.

---

## 5. Userspace base (native)

### Real
- **217 native `user/*.ad` tools** (June: 211). Full coreutils-ish set + `hamsh`
  (shell + jobs + supervisor + runlevels), `hpm`, `sshd`/`ssh`/`httpd`/`ntpd`/
  `crond`, `useradd`/`passwd`/`login`/`su`, `vi`/`hamedit`, `tar`/`gzip`.
- Real Debian apt 3.0.3 + dpkg 1.22.22 in `enter linux` — and per **T15/T19**
  `dpkg -i` and `apt-get install` from a repo now **complete** ("Setting up …"),
  including the apt↔dpkg pty deadlock fix. This is a genuine June→July upgrade
  (June: "non-interactive apt install only, install pipeline incomplete").
- Identity: `hostowner` (admin) vs `live` (default regular user, uid 1001);
  per-user `/home/<name>` wired end-to-end (T79/T82/T84); privilege escalation
  verified both ways (T67).

### Partial / missing
- **No systemd, no D-Bus, no glibc `ld.so`, no PAM/nsswitch/getent** natively —
  all unchanged. `svc`+runlevels is the (correct, Plan-9-ethos) substitute, but
  systemd-targeted Debian units don't translate.
- Native is **musl-static-PIE only**; dynamic `.deb` binaries + CPython
  C-extensions need a U-track `ld.so` (`TODO.md:664`).
- No native container runtime (needs cgroup memory/pids + pivot_root +
  capability enforcement).
- busybox `ls` enumeration XFAIL; `sh -c "a|b"` internal-pipeline `#GP`
  (`TODO.md:662`).

### Impact
Native userland is broad and increasingly self-consistent (home dirs, identity,
FS coherence all fixed since June). The "be a Debian" gap is now concentrated in
**systemd + D-Bus + glibc-ld.so**, not in the socket/fd/task ceilings.

---

## 5b. NEW LENS — native apps/tools breadth vs a mature Unix userland

The 217 tools cover coreutils, a shell, an editor, networking clients/servers, a
package manager, and a DE. What a mature Unix userland has that we lack:

- **Toolchain:** no native `cc`/`make`/`binutils`/`ld`/`as`/`ar`. Self-host is
  Adder-only; there is no native C build path (by design — but a would-be
  developer on-device has nothing but Adder). **Native-first gap.**
- **Text/data:** have `awk`/`sed`/`grep`/`sort`/`cut`/`tr`/`jq`-less. Missing
  `perl`/`python`-native (CPython only runs in the Linux ns), `bc`/`dc`,
  `patch`, `diff3`, `xxd`(have `hxd`), `getopt`.
- **Admin:** missing `mount`/`umount` as classic tools (namespace-bind instead),
  `fdisk`/`parted` (have `hamnix_partition`), `cron`(have `crond`), `at`,
  `logrotate`, `rsync`, `screen`/`tmux`, `sudo` (have `su`), `systemctl`-analog
  beyond `initctl`/`service`.
- **Dev/net:** missing `git`, `openssl` CLI, `nc`/`socat`, `dig`/`nslookup`
  (have `host`), `traceroute` (have `ping`), `tcpdump` (blocked on AF_PACKET).
- **Editors/pagers:** have `vi`/`less`/`more`; missing `nano`/`emacs`-class,
  `grep -P` (PCRE).

Priority read: the highest-value native additions are a **native archiver/patch/
diff3 trio** and **`git`-native** (huge for self-host credibility) — but `git`
is enormous; a realistic near-term win is `nc`/`socat`-native (now possible
because listen/accept work) and `dig`/`openssl`-CLI-native.

---

## 6 / 10b. Desktop environment maturity (the June audit under-weighted this)

### Real — and MUCH broader than June
File-server-per-window UI (`/dev/wsys/N/{…}`) + display-list **scene files**
(`docs/de_scene_file_arch.md`). Native DE tools now present:

| Capability | Tool(s) | Status |
|---|---|---|
| Panel + app menu + taskbar + clock | `hampanel`,`hamappmenu`,`hamtray`,`hamclock` | live taskbar (T77), arbitrary widget move (T61) |
| Notifications | `hamnotif`,`hamnotify`,`hamosd`,`hamtoast` | present |
| Settings | `hamsettings` | present |
| Session mgmt | `hamsession`,`hamsessui` | present; workspace isolation (T61) |
| System monitor | `hamsysmon`,`hammon` | present |
| Screenshot / snap | `hamshot`,`hamsnap` | present |
| Lock / screensaver | `hamlock`,`hamscreensaver` | present |
| Window ops | `hamresize`,`hamrband`(rubber-band),`hamcycler`(Alt-Tab),`hamctxmenu`,`hamrun` | present |
| File manager | `hamfm`,`hamfiles`,`hamfmscene` | present |
| Widget toolkit | `lib/hamui.ad` (4,561 LOC) — MATE-class widget set `[~]` | menu/dialog/notebook/slider/treeview/textview landed |
| Apps | `hamedit`,`hamcalc`,`ham2048`,`hamsnake`,`hambrowse`,`hamview` | present |
| AI-drivable windows | `cat /dev/wsys/N/text` + `echo cmd > …/cmd` | genuine differentiator |

### Partial / dishonest
- **Cursor hotspot bug** — clicks register at the arrow's *bottom*, not its tip
  (`TODO.md:601`). Every click is off by the cursor height — very visible.
- **~0.5 s terminal input lag** (`TODO.md:601`). The June "0.5 Hz interactive
  collapse" is largely gone (T81 latency work, T77 live taskbar), but latency
  findings remain and there's no evidence of a metal-verified interactive DE.
- **~20K dead LOC** of `daemon_pixel` render fallbacks still in `user/hamUId.ad`
  (`TODO.md` "DE pivot finish — substitution not addition"); the scene pivot is
  additive, not yet a clean substitution.
- Settings/notifications/session tools exist but their *depth* is unverified
  (does `hamsettings` actually change display/theme/network? unknown from a
  read-only pass — flag for runtime QA).

### Missing vs GNOME/MATE/macOS
- Display config UI (resolution/multi-monitor/scaling), HiDPI, Wayland,
  full X11/Xvfb bridge (`[ ]`), IME/dead-key/compose, accessibility (screen
  reader/contrast/large-text), GPU compositing, drag-and-drop between apps, a
  real clipboard manager, theming engine.

### Impact
The DE is now *feature-broad* (notifications, settings, session, tray, monitor
all exist as tools) — a real leap past June. But **cursor-hotspot + input lag
are day-1 dismissal bugs**, and none of it is proven on metal. Breadth is there;
polish and verification are the gap.

---

## 7. Distro / install

### Real
- ESP-only UEFI installer (`build/hamnix-installer.img`); in-RAM live →
  writes ext4 to NVMe → reboots off disk. **T83: installs and boots off ext4**
  (the long-standing "installable?" question is answered yes).
- Live image defaults to a minimal busybox namespace (T11/T20) to fit `-m 1G`;
  heavy Debian closure moves to the installed disk / opt-in flag.
- `hpm` channels (main live; non-free placeholders); multi-user; `enter linux
  { apt install }`.

### Partial / missing (mostly unchanged)
- UEFI-only (no BIOS/CSM, no GRUB). No rescue/recovery, no A/B updates, no
  rollback of the *system* (hpm has package-level rollback — §8b).
- **No signed package indexes** (sha256 covers tarballs; the index is unsigned).
- No Secure Boot end-to-end (shim/KEK), no TPM2/measured boot, no LUKS-on-install,
  no LVM/RAID, no preseed/unattended, no locale/timezone selection in installer.

### Impact
The install path works in OVMF+KVM and on the NUC. For a *credible distro* the
"Secure Boot + LUKS + signed indexes" trio remains table-stakes and absent.

---

## 8. Security / hardening

### Real — improved since June
- **SMEP + SMAP page-protection** (T10, `cpu_mitigations.ad:524`
  `setup_smep_smap`; unconditional US=0 restamp; audit 0 high-half US=1 leaks;
  SMAP-enforcement test PASS). June's "SMAP not enabled" comment is fixed.
- **KASLR v2** (T12, `cpu_kaslr.ad`): per-boot randomization of the
  module-mapping window from RDRAND/RDTSC.
- Plan-9 hostowner model; `/dev/auth` + SHA-512 shadow + rate-limit; default
  task uid NOBODY; `access_ok` boundary validator; seccomp-bpf; W^X + NX +
  stack/ET_DYN/mmap ASLR. Password echo suppressed in DE terminal (T80).

### Partial / dishonest
- **KASLR randomizes the module window, NOT the kernel image** — the image base
  is still fixed at `0xffffffff80000000` (`cpu_kaslr.ad` header is admirably
  honest about why: no PIE reloc table). Don't let "KASLR: Done" imply full
  kernel-image KASLR.
- **No KPTI; no SMAP CR4-flip completion** (`TODO.md:509` still open).
- **`u_caps` gates nothing; Landlock is Linux-ABI furniture** — unchanged.
- **No retpoline/IBRS/IBPB/MDS_CLEAR** in `cpu_mitigations.ad` (name is
  aspirational; it's SMEP/SMAP-only today).

### Missing
- LSM framework, auditd, Secure Boot chain, TPM2, dm-verity/fs-verity, kernel
  lockdown, AppArmor profiles for daemons.

### Impact
Posture climbed from "below 2008-era Linux" (June) to "SMEP/SMAP + module KASLR
+ seccomp + ASLR present" — a real improvement. But no KPTI/no LSM/paper-caps
mean it still fails any modern compliance review.

---

## 8b. NEW LENS — package management + upgrade maturity (hpm vs apt/dnf/pacman/brew)

`user/hpm.ad` is **7,629 LOC** — substantially more capable than the June
"5,400 LOC BFS solver" framing.

### Real
- Subcommands (`hpm.ad:7541-7618`): `refresh`, `channels`, `enable`/`disable`,
  `list`, `search`, `show`, `history`, `install`, `remove`, `update`, `pin`/
  `unpin`, **`rollback`**.
- **BFS dependency solver** + **channels** + **pinning**.
- **Transaction log** (`hpm.ad:1811`: `{id, ts, op: install|remove|rollback,
  …}`) with reversible **rollback** driver (`:7269-7403`) — each reversal
  records its own explicit `rollback` txn. This is *better* than base apt (no
  built-in rollback) and comparable to `dnf history undo`.
- **sha256 verification** of package tarballs (`pkg_sha256_off/len`,
  `hpm.ad:896,1201`).
- Source-primary + binary-cache design (#186) is the intended model.

### Partial / missing vs apt/dnf/pacman/brew
- **No index/repo signing** (no GPG/ed25519, no `Release.gpg`/`InRelease`
  equivalent) — the trust root is a plaintext sha256 in an *unsigned* index. A
  MITM can swap both. **This is the #1 hpm gap.**
- **No system-wide `upgrade`/`dist-upgrade`** distinct from per-package `update`
  (needs a whole-world consistency solve + conflict/obsolete handling).
- No `provides`/virtual packages, no version-constraint solving beyond BFS
  (no SAT/backtracking like modern apt/dnf), no `autoremove`/orphan GC visible,
  no triggers/hooks (dpkg triggers), no delta/binary-diff downloads.
- No parallel downloads, no mirror failover, no `hpm clean`/cache GC surfaced.

### Impact
hpm's rollback + txn-log is genuinely ahead of apt; its **missing signature
trust root** is a hard blocker for shipping a networked distro. Signing is the
highest-leverage package-mgmt lift.

---

## 9. Observability

### Real
- `/proc/{uptime,loadavg,meminfo,cpuinfo,version,diskstats,net/*}`; `dmesg` +
  per-svc logs; `man`; `u_perf` software counters. QA sweep fixed `/proc` read-
  offset (df no longer spins), `uptime` units, `ps` uninitialized-memory.

### Missing (unchanged)
- **Kernel oops/panic capture to disk** — panics still vanish into serial
  (the ESP LOG.TXT extent helps on the NUC, but there's no kdump).
- ftrace/kprobes on the running M16 kernel; bpftrace/bcc; journald-shape
  structured logging; real coredump path beyond veneer.

### Impact
A sysadmin has `dmesg` + svc logs. No `journalctl`, no `bpftrace`, no kdump.
Production debugging story remains weak.

---

## 10. Multi-arch (unchanged)
x86_64 is production; aarch64 backend exists + a single `kmain.ad` EL0
round-trip. No arch-interface factoring, no arm64 chan/proc/sched port, no
riscv64. Single-arch in practice.

---

## 11. Test / CI honesty

- **~1,000 `test_*.sh` scripts** exist in-tree (`find . -name test_*.sh` → 1020;
  998 under tests/scripts). The "CI gates 116+" figure is the *green-on-CI*
  subset.
- **~600 `-kernel -m 256M` gates are DARK on any dev host that ran debootstrap**
  (`TODO.md` "Systemic test-infra finding"): `build_initramfs.py` defaults
  `HAMNIX_DEFAULT_REAL_DEBIAN=1`, bloating the kernel ELF past GRUB's `-m256M` →
  every assertion "fails" before the kernel runs. Green on fixtureless CI, red
  locally. **Fix at the harness source, not 600 files.** This is the single
  biggest CI-integrity issue and it masks real regressions (a dev host cannot
  trust its own kernel-unit lane).
- QA sweep 2026-07-08 found **7 lying gates** (5 false-red, 2 false-green),
  including `test_pipe.sh` green while hamsh pipelines carried zero bytes.
  Lesson (memory `feedback_false_green_console_leak`): a gate grepping serial
  for a payload can't prove the payload traversed the pipe.

---

## 12. NEW LENS — native web browser (hambrowse vs a real browser)

`user/hambrowse.ad` (1,658 LOC, T75). **Honest scope, real value.**

### Real
- Fetches over HTTP **and HTTPS/TLS 1.3** (reuses `user/http9.ad` — same client
  as wget/curl), or reads a local file.
- Parses a **tolerant HTML subset**: h1–h3, p/div/br, b/strong/i/em, `a href`
  (clickable → navigates, relative/root/absolute resolved), ul/ol/li, pre,
  entities. Ignores script/style/head/title content.
- **Block+inline layout** wrapped to window width; renders as a scene display
  list in its own DE window. Editable **address bar** + Go button; keyboard/
  wheel scroll.

### Missing (the file's own header says "NOT handled")
- **CSS** (no styling, no box model beyond block/inline, no colors/fonts/margins
  from the page).
- **JavaScript** (no engine at all — no DOM, no events, no fetch).
- **Tables, images, forms** — so no login pages, no search boxes, no layouts.
- No cookies/sessions, no history/back-forward, no tabs, no HTTP redirects
  visible, no `<video>`/`<canvas>`, no web fonts.

### Impact
hambrowse honestly closes the "no HTML renderer exists" gap and can display a
documentation page or a simple site. It is **not** a browser for the modern web
(any JS-driven or CSS-laid-out site renders as unstyled text). Two credible
paths: (a) grow hambrowse toward CSS + tables + images + forms (native-first,
large but tractable, no JS); (b) ride the Linux-ns Firefox-over-Wayland path
(§0 #5) for full fidelity. Both are worth pursuing — (a) for the native story,
(b) for real-world usability.

---

## 13. Prioritized, DISJOINT close-the-gap worklist (up to 8 parallel agents)

Ranked by (user-visible impact × tractability). Each item names the
subsystem/files it touches so agents don't collide. **[N]** = native-first
(strategic priority); **[F]** = Linux-ns fallback. Size: S ≤1wk, M ≤1mo,
L ≤1qtr, XL sustained.

| # | Item | Subsystem / files (disjoint) | Tier | Size |
|---|------|------------------------------|------|------|
| **A** | **Fix DE cursor hotspot (click at tip) + terminal input lag** — the day-1 dismissal bugs | `lib/hamui.ad`, `user/hamUId.ad`, `user/hamterm*.ad`, `sys/.../devwsys` cursor path | **[N]** | S–M |
| **B** | **Root-cause the `-smp 2` idle wedge** in `yield_to_others`; re-enable `-smp 2` for pipe tests | `kernel/sched/core.ad` (`yield_to_others`), `project_smp2_idle_wedge` | **[N]** | M |
| **C** | **hpm signed indexes** — ed25519/GPG trust root over the index; verify before install; `Release`/`InRelease`-analog | `user/hpm.ad` (add verify path), `drivers/net/tls.ad` (reuse crypto), repo tooling in `scripts/`, `packages/` | **[N]** | M |
| **D** | **KPTI + SMAP CR4-flip completion + retpoline/IBRS/IBPB** | `arch/x86/kernel/cpu_mitigations.ad`, `arch/x86/mm/*`, `arch/x86/kernel/cpuregs_asm.S` | **[N]** | M |
| **E** | **hambrowse: CSS subset + tables + images** (no JS) — inline styles, `<table>`, `<img>` via a decoder | `user/hambrowse.ad`, `lib/hamui.ad` (scene prims), maybe a native PNG decoder in `user/` | **[N]** | L |
| **F** | **Firefox last mile** — get GDK realize→map to emit `xdg_surface`/`xdg_wm_base`; MOZ_LOG out of the forked child | Wayland compositor path (`user/hamUId.ad` wl), Linux-ns GDK; `project_wayland_passthrough_track` | **[F]** | M |
| **G** | **Kernel oops/panic capture to disk** (kdump-lite: panic → ext4/ESP extent) + coredump real path | `kernel/` panic path, `fs/ext4.ad`/ESP LOG, `sys/src/9/port` | **[N]** | S–M |
| **H** | **cgroup v2 memory + pids controllers** (systemd/container prerequisite) | `kernel/sched/cgroup_cpu.ad` → generalize; `linux_abi/u_syscalls.ad` clone3/cgroup ns; new `kernel/cgroup*` | **[N]** | XL |
| **I** | **glibc `ld.so` for dynamic Debian binaries** (unblocks CPython C-ext + most .deb) | `linux_abi/` loader, `fs/elf.ad`, U-track runtime | **[F]** | L |
| **J** | **VFS page cache (`address_space`) + dirty writeback** — every read hits block today | `fs/vfs.ad`, `mm/`, `fs/ext4.ad`; `TODO.md:155,184` | **[N]** | L |
| **K** | **Wire ONE tunnel protocol for real** (WireGuard `/net` interface, not selftest) — or re-frame the codec dir | `drivers/net/wireguard.ad` + `/net` glue, `drivers/net/ip.ad` | **[N]** | L |
| **L** | **TCP window scaling** (lift `TCP_WIN_MAX` 16-bit cap) | `drivers/net/tcp.ad:163` | **[N]** | S–M |
| **M** | **Native `nc`/`socat` + `dig` + `openssl`-CLI** (now possible: listen/accept work) | new `user/*.ad`, reuse `drivers/net`, `tls.ad`, `dns.ad` | **[N]** | S–M |
| **N** | **DE dead-code substitution** — remove ~20K `daemon_pixel` LOC; thin router | `user/hamUId.ad` (isolated to one file) | **[N]** | M |
| **O** | **Fix the ~600 dark `-kernel` gates at the harness source** (busybox-default initramfs; real-Debian opt-in) | `scripts/build_initramfs.py`, `scripts/_kernel_iso.sh` | **[N]** | S–M |
| **P** | **`hpm upgrade` (whole-world consistent) + autoremove/orphan GC** | `user/hpm.ad` (solver + txn) | **[N]** | M |

### Disjointness map (safe to run concurrently)
- **A** (hamui/hamterm) vs **N** (hamUId dead-code) vs **F** (hamUId wl path) all
  touch DE files — assign **A+N** to one agent OR carve: A=cursor/hamui, N=router
  refactor, F=Linux-ns wl handshake. Sequence A→N if both touch `hamUId.ad`.
- **B**/**D**/**G**/**H**/**J**/**L** are kernel/arch/mm/net — mostly disjoint
  files; **H** and **J** both touch `mm/` — serialize or split by subdir.
- **C**/**P** both touch `user/hpm.ad` — one agent, two commits.
- **E** (hambrowse) and **M** (net CLIs) reuse `drivers/net` read-only; safe.
- **O** is scripts-only; fully isolated; do FIRST (unblocks everyone's local
  verification).

### Recommended first wave (8 agents, minimal collision)
**O** (unblock CI) · **A** (DE feel) · **B** (smp wedge) · **C** (signing) ·
**D** (KPTI/mitigations) · **G** (kdump) · **L**+**M** (net CLIs + winscale) ·
**E** (hambrowse CSS). That covers day-1 UX (A), a live regression (B), the two
biggest security gaps (C,D), dev-velocity (G,O), and the native-web + native-net
stories (E,M) without two agents writing the same file.

---

## 14. Method caveats
- Read-only; no compilation, no QEMU boot. Runtime "works" claims are taken from
  STATUS rows + TODO markers, discounted per `feedback_merged_is_not_working`
  (merged ≠ VM-verified ≠ HW-verified). Where a claim is only asserted, it's
  flagged for runtime QA (e.g. hamsettings depth §6).
- Line numbers/LOC from `wc -l`/`grep` at HEAD `a19720e0`. Stub/ENOSYS counts
  are lexical — they understate a paper stub with no TODO (as the net codecs
  show) and overstate honest `-ENOSYS` arms.
- The DE-tool *breadth* (§6/§10b) is proven by file existence; the *depth* of
  settings/notifications/session was not exercised — a runtime QA pass should
  confirm each does something real.

End of audit.
