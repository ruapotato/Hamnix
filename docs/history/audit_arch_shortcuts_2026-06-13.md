# Audit — architectural shortcuts & stubs (2026-06-13)

Read-only architecture audit at HEAD `6135ebaf`. Sister to the prior
F10 audit (`audit_F10_report.md`, base `52812182`) and the graphical
stack audit (since superseded by the DE rearchitecture —
`docs/de_scene_file_arch.md`). This pass asks the
question: *now that F10-1/2/3/4/5/6 (MVP)/8/9/10/11/12 have landed, is
the codebase in the right shape, or have new shortcuts crept in?*

## Executive summary

- **Plan 9 substrate**: HELD. `resolve_path` is wired at every public
  open entry; `_path_owning_server` default-denies; per-server
  `<X>_perm_check` bodies live in each server's own file; `afd` is no
  longer dropped at `do_mount`. The headline F10 findings are real.
- **Per-server policy bodies**: PARTIAL. Three servers really enforce
  (`devblk`/`devproc`/`devnet`). Five (`tmpfs`/`fat`/`devcons`/`devsrv`/
  `devauth`) are world-r/w stubs with TODO tightening notes. They are
  *not* exploitable in isolation, but the docs/architecture surface
  reads as if "the server enforces" universally — it doesn't.
- **`linux_abi` as leaf**: HELD. Zero real `from linux_abi …` imports
  in `arch/`, `fs/`, `sys/`, `kernel/`, `drivers/`, `mm/`.
- **F2 syscall sprawl**: STILL PARTIAL. Retired arms (`SYS_NICE`,
  `SYS_SVC_CTL`, `SYS_WSYS_*`, `SYS_NETCFG`, `SYS_RESOLVE*`) keep full
  bodies; the docs admit they are "deprecated convenience shims" but
  they re-implement instead of delegating to the ctl-file path.
- **Compositor monolith**: BROKEN. `user/hamUId.ad` is still 28,152
  LOC / 642 functions. The DE pivot extracted 6 v2 clients (panel,
  appmenu, cycler, calpop, run, lock) — but the *bodies still exist*
  inside hamUId; the v2 clients are siblings, not replacements. The
  `daemon_pixel` cascade is 613 lines and still draws menus.
- **Test honesty**: BROKEN. All 17 `test_de_*.sh` guards are
  structural greps; none boot a VM. The "v2 client" landings are
  proven only by token-presence, not by rendering.
- **Hostowner reach**: PARTIAL. 12 raw `current_task_uid() != 1`
  checks in `arch/x86/kernel/syscall.ad` (SYS_SVC_CTL / SYS_WSYS_* /
  SYS_NETCFG / SYS_VK_* / SYS_REBOOT / SYS_SET_REALTIME / SYS_SETUID).
  These bypass the F10-2 dispatcher.
- **Memory/sched**: HELD for sched (per-CPU runqueues, IRQ-safe locks,
  nscap CPU factor inflates vruntime). One open known crash: `#439`
  probabilistic buddy double-free.
- **Right shape, wrong scale**: ext4 truncate, NVMe multi-queue, AHCI
  NCQ, FAT POSIX overlay — all listed in TODO; none are stubs, all
  are unfinished implementations of the right design.
- **Recommendation**: the next wave is **many parallel small fixes**,
  not a keystone. F10 already moved the keystones; what remains is
  filling in the bodies (perm stubs, syscall thin-shimming,
  daemon_pixel slicing, runtime DE tests). No single sweep is owed.

---

## 1. Plan 9 shape — HELD

### 1.1 `resolve_path` at every `vfs_open` entry — HELD

The F10 audit's first keystone. Verified at every claimed site:

- `fs/vfs.ad:1818` `vfs_open` calls `resolve_path` then dispatches.
- `fs/vfs.ad:1785` `vfs_open_kernel` resolves through the caller's Pgrp.
- `fs/vfs.ad:1796` `vfs_open_write_kernel` same.
- `fs/vfs.ad:3361` `vfs_open_write` same.
- `fs/vfs.ad:1749` `vfs_perm_check_exec` same (for `do_execve`).
- `fs/vfs.ad:3685`, `fs/vfs.ad:3773` `vfs_symlink`/`vfs_link` resolve
  `linkpath`/`newpath` before perm check.
- `fs/vfs.ad:986` `_vfs_open_post_perm`'s own resolve_path call
  (defense-in-depth — the public entries already resolved).

No new bypass paths found in `arch/x86/kernel/syscall.ad`. SYS_OPEN /
SYS_OPEN_WRITE / SYS_CHDIR pass the raw user path to the resolving
public entries.

### 1.2 namec literal `/dev/<leaf>` strcmp table — GONE

`grep -n 'namec("/dev/\|namec("/etc/\|namec("/proc/\|namec("/var/' --include="*.ad"`
across `kernel/ fs/ sys/ drivers/ mm/ arch/` returns NOTHING.

The four leftover kernel-context `namec` calls all use the `#c/<leaf>`
spelling:
- `drivers/audio/audio_capture_selftest.ad:70` `namec("#c/audioin", 0)`
- `drivers/audio/audio_selftest.ad:159,292,297` `namec("#c/audio…")`

### 1.3 9P `afd` Tauth/Tattach — HELD structurally, E2E TODO

`sys/src/9/port/syschan.ad:219` `do_mount(srvfd, afd, …)` no longer
reads `afd` into `_ignored`. When `afd != -1` the handler does a Tauth
on the auth-fd chan and passes the verified uname into Tattach
(STATUS:928 row). Live serial captured at F10-4-followup. **Caveat:**
no end-to-end test proves a userland mount with `afd` survives a real
9P server's Tauth challenge — the in-kernel `devauth_verified_uname_copy`
*is* the wire reference and there is no second implementation.

### 1.4 `_path_owning_server` default-deny — HELD

`fs/vfs.ad:1614` and `fs/vfs.ad:1652` both return `SERVER_UNKNOWN`
(=0). `fs/vfs.ad:1683` traps `SERVER_UNKNOWN` to `EPERM_PERM`. The
historical "cpio fallthrough" is gone.

### 1.5 Multi-character `#<word>` named roots — HELD

`fs/vfs.ad:1559` detects `name[2] != 0 && name[2] != '/'` and routes
to rootslot (`return 11`), so `#sysroot/...`, `#distro/...`, `#home/...`
keep working post-default-deny.

### 1.6 Server-letter routing carve-outs — REVIEWED

- `#c/auth[/]` → server 10 (devauth) — `fs/vfs.ad:1573`.
- `#c/blk[/]` → server 6 (devblk) — `fs/vfs.ad:1579`. Correct: raw
  block surface gets the sharper devblk policy.
- `#d` (HAMSH §7 fd) → server 5 (devs) — `fs/vfs.ad:1597`.
- `#w` (per-process wsys) → server 5 — `fs/vfs.ad:1607`. Safe default
  because `resolve_path` rewrites `#w` to `#c/wsys/<wid>` *before* the
  perm gate; the inline arm is the early-boot fallback.

The carve-outs are minimal and documented inline.

**Verdict:** the Plan 9 namespace substrate is real and consistently
threaded. No new bypass introduced post-F10.

---

## 2. Server-boundary permission bodies — PARTIAL

The dispatcher (`chan_permission_check`) reliably routes to the right
server's `<X>_perm_check`. Whether those bodies *do* anything is
mixed:

### 2.1 Real-enforcement bodies — HELD

- `sys/src/9/port/devblk.ad:104` `devblk_perm_check`: hostowner-only
  on `caller_uid == 1`, else `-1`. Five lines. Right call.
- `sys/src/9/port/devproc.ad:534` `devproc_perm_check`: world-r;
  writes require `caller_uid == 1 OR caller_uid == target_uid` via
  `_devproc_perm_path_pid` decoding. The per-pid lookup is real.
- `drivers/net/devnet.ad:34` `devnet_perm_check`: world-r; writes
  parse the tail and require hostowner only for `/net/dns` (server
  pin, not lookup), `/net/ipifc/ctl`, `/net/addr`. Per-conn writes
  world-OK because sockets are user-level. Correct.
- `fs/ext4.ad::ext4_perm_check` via `_perm_check_ext4` shim
  (`fs/vfs.ad:1465`): on-disk uid/gid + 9 mode bits.
- `_perm_check_cpio` (`fs/vfs.ad:1385`): per-entry mode-bit lookup;
  writes categorically refused. Correct.

### 2.2 World-r/w stubs — PARTIAL

These five all return 0 unconditionally with a TODO:

- `fs/tmpfs.ad:115` `tmpfs_perm_check` — `return 0`. Rationale: "v1
  tmpfs has no per-file owner/mode storage." Real, not a stub of
  policy but a stub of storage. Tighten when `TmpfsEntry` grows
  `uid/gid/mode`.
- `fs/fat.ad:44` `fat_perm_check` — `return 0`. FAT has no POSIX
  overlay; same shape.
- `sys/src/9/port/devcons.ad:67` `devcons_perm_check` — `return 0`.
  Rationale: "cdev-local hostowner-only writes are gated at the cdev."
  Verified at `devwsys.ad:2405,3654` (`current_task_uid() != 1`
  gates inside wsys ctl handlers). This is "world-OK to open; cdev
  filters writes" — correct architecturally, but a casual reader
  expects `devcons_perm_check` to be the gate.
- `sys/src/9/port/devsrv.ad:87` `devsrv_perm_check` — `return 0`.
  Rationale: SRV publishes via `SYS_SRV_POST`, not via `vfs_open_write`;
  the post handler validates the srvfd. Correct but again surprising.
- `sys/src/9/port/devauth.ad:114` `devauth_perm_check` — `return 0`.
  Rationale: "anyone has to be able to authenticate." Rate-limit +
  constant-time compare for verify; `caller_uid == 1 OR caller_uid ==
  target` for setpass live inside the cdev (verified at
  `devauth.ad:661`). Correct.

### 2.3 Exploitability of the world-r/w stubs

- **tmpfs**: a non-root user can read/write any other user's tmpfs
  file. Exploitable IF two non-root users coexist sharing `/tmp`. Today
  the boot DE has only `hostowner` and `nobody`-shaped tasks pre-login;
  the threat surface is small. **Severity: low today, medium when
  multi-user becomes real.**
- **fat**: read-only by default at mount; writes hit underlying FAT
  semantics. Mostly used for the ESP. **Severity: low.**
- **devcons**: cdev-internal gates are real (see §2.4). **Severity:
  none in current code.**
- **devsrv**: `SYS_SRV_POST` is the only write path that matters.
  **Severity: none in current code.**
- **devauth**: gate is in the cdev. **Severity: none in current code.**

**Verdict:** tmpfs is the one stub worth tightening before multi-user.
The others are correct-by-construction but the doc surface
overpromises (see §11).

### 2.4 Hidden in-cdev gates that the dispatcher table doesn't show

`grep -n 'current_task_uid() != 1' sys/src/9/port/`:
- `devwsys.ad:2405,3654` — wsys ctl write hostowner gate.
- `devauth.ad:661` — `_au_setpass` `caller==1 OR caller==target`.
- `devblk.ad:110` — duplicate of the perm_check (defense-in-depth).
- `devproc.ad:551` — duplicate of the perm_check (idem).

The wsys gate is the load-bearing one — it's NOT visible in
`docs/security.md`'s per-server table.

---

## 3. Hostowner reach — PARTIAL

### 3.1 Default uid flipped — HELD

`kernel/sched/core.ad:920` `UID_HOSTOWNER = 1`, `UID_NOBODY = 65534`.
`kernel/sched/core.ad:3089` user-task slot init falls back to
`UID_NOBODY` if `parent_uid == 0`. `init/main.ad:10695` stamps PID 1
to `UID_HOSTOWNER` after `create_user_task` and before
`start_first_task` — so PID 1 is never dispatched as NOBODY.

`kernel/sched/core.ad:2678` kthreads stay `UID_HOSTOWNER` (trusted).

### 3.2 Raw `uid == 1` checks in `arch/x86/kernel/syscall.ad` — STILL PRESENT

```
arch/x86/kernel/syscall.ad:3597   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:3643   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:3718   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:3762   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:3768   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:3819   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:3845   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:3876   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:3896   if current_task_uid() != 1:
arch/x86/kernel/syscall.ad:4371   if current_task_uid() != 1:
```

These are SYS_WSYS_ALLOC / SYS_WSYS_FREE, SYS_NETCFG, SYS_SVC_*,
SYS_SET_REALTIME, SYS_VK_*, SYS_SETUID, SYS_REBOOT. They are correct
in outcome (the rule is "hostowner-only") but architecturally they
bypass the F3 server boundary. Plan 9 shape would push the gate to
the ctl-file's write handler in the relevant server.

This is half-closed only because the matching ctl files exist
(`/proc/svc/ctl`, `/dev/wsys/ctl`, `/net/dns`, `/proc/<pid>/ctl
realtime`) but the syscall arms re-implement instead of delegating.
See §4.

### 3.3 No non-PID-1 elevation paths to uid=1

`set_task_uid_at(_, UID_HOSTOWNER)` is called from:
- `init/main.ad:10695` — PID 1 boot.
- `arch/x86/kernel/syscall.ad` SYS_SETUID_AUTH (post `devauth`
  verify) — the only login pathway.

No `current_task_uid_set(1)` exists outside these. **Verdict: HELD.**

---

## 4. F2 syscall sprawl — STILL PARTIAL

The F10 audit flagged: "every retired syscall arm is still wired and
still fully implemented." Status today:

- `arch/x86/kernel/syscall.ad:3098` `SYS_NICE`: ~20-line body that
  calls `sched_set_nice` / `sched_get_nice` directly. Comment
  acknowledges "DEPRECATED — Plan-9-shape replacement: write
  `/proc/<pid>/ctl pri <n>`" but the arm doesn't delegate.
- `arch/x86/kernel/syscall.ad:3742` `SYS_SVC_CTL`: full arm body.
- `arch/x86/kernel/syscall.ad:3827` `SYS_WSYS_ALLOC`: full arm body.
- `arch/x86/kernel/syscall.ad:3868` `SYS_WSYS_FREE`: full arm body.
- `arch/x86/kernel/syscall.ad:3937` `SYS_NETCFG`: full arm body.
- `arch/x86/kernel/syscall.ad:4177` `SYS_RESOLVE`: full arm body.
- `arch/x86/kernel/syscall.ad:4219` `SYS_RESOLVE_PTR`: full arm body.

**Why this matters:** The "policy lives in the server" claim is
double-implemented. If a future change tightens
`/proc/<pid>/ctl pri`, `SYS_NICE` callers bypass it. The legacy arms
have to be either deleted (with userland migrated) or rewritten as
thin pass-throughs that call the ctl-file write path.

**Verdict:** the headline "F2 closed" in STATUS is incorrect. F2
remains PARTIAL — the new ctl files exist but the old arms
re-implement. F10 already flagged this and it has not moved.

---

## 5. `linux_abi` as leaf — HELD

```
$ grep -rn '^from linux_abi\|^import linux_abi' \
    arch/ fs/ sys/ kernel/ drivers/ mm/ --include="*.ad"
(no real imports — all hits are F4 substrate comments)
```

The hook-table inversion is intact. `linux_abi/init.ad` registers all
its hooks via `register_*_hook` plants in `fs/vfs.ad` and
`arch/x86/kernel/syscall.ad`. `init/main.ad` retains its
`linux_abi.*` imports out-of-scope per F4 brief.

**Verdict: HELD.**

---

## 6. FD-mark fold (F7 / #390) — HELD for the legitimate remainder

After Phase 4a/4b/4c/4d folds, the residual `FD_*_MARK` set in
`fs/vfs.ad` is:

```
fs/vfs.ad:558 FD_EPOLL_MARK
fs/vfs.ad:559 FD_EVENTFD_MARK
fs/vfs.ad:560 FD_TIMERFD_MARK
fs/vfs.ad:561 FD_SIGNALFD_MARK
fs/vfs.ad:562 FD_INOTIFY_MARK
```

All five are Layer-2 (Linux ABI) event-fd primitives — the
boundary-discipline law explicitly preserves these as marks
(`TODO.md:73`). Pipe/sock/auth/net/devfd were folded.

**Verdict: HELD by design.** The TODO §F7 captures the open work
(stdio/tmpfs/pipes/socketpair/p9/net/epoll-family/ptmx/fuse + NR_FDS
bump), which is implementation scale-out, not architecture debt.

---

## 7. Native vs Linux-shim drivers — HELD

Per `feedback_native_vs_lshim_drivers` (native where HW is
standardized; `.ko` for vendor-mess):

- Standardized HW native: xHCI (`drivers/usb/xhci.ad`), virtio_blk,
  AHCI, NVMe, e1000. Correct.
- Vendor-mess `.ko`: iwlwifi, i915, alx, cfg80211/mac80211. Correct.
- e1000e: BOTH native (`drivers/net/e1000e.ad`) and `.ko`-shimmable.
  `feedback_loading_vs_working` makes this fine: e1000e is the
  PoC, not the spec.
- `drivers/net/sock_compat.ad` (post-F10-11 rename): header
  now states "L-shim adapter, not native API."

`drivers/audio/audio_*_selftest.ad` literal-path use was migrated to
`#c/<leaf>` (good). No new native-vs-shim misshape.

**Verdict: HELD.**

---

## 8. Compositor monolith — BROKEN

### 8.1 Sizes

```
user/hamUId.ad        28152 LOC   642 functions
user/hampanel.ad        663 LOC
user/hamappmenu.ad      532 LOC
user/hamcalpop.ad       509 LOC
user/hamcycler.ad       303 LOC
user/hamrun.ad          298 LOC
user/hamlock.ad         265 LOC
                  + 2570 LOC across 6 v2 client apps
```

`daemon_pixel` is 613 lines (lines 0…612 from its `def`). 52
top-level `panel_*` / `run_*` / `menu_*` / `submenu_*` / `cycler_*` /
`calpop_*` / `lock_*` / `appmenu_*` functions still live inside
`hamUId.ad`.

### 8.2 The pivot claim vs reality

STATUS:920 claims the pivot is the keystone "next wave: port panel +
menus + popups out of `daemon_pixel`." STATUS rows for waves 1–6
claim panel/appmenu/cycler/calpop/run/lock landed.

What actually happened: the v2 client apps **were created** and **are
spawned** from the compositor. But the compositor still has the
*original* code paths for those same widgets and `daemon_pixel`
still rasterizes them. The v2 clients are *additional* layers, not
*replacements*. (Compare wc -l: removing 6 widgets should drop
hamUId substantially; the file is still 28k.)

This is the classic "added the new without deleting the old"
shortcut. The tests (§11.1) only check that v2 client tokens exist,
not that the old monolith paths are gone.

### 8.3 Right next slice

Per STATUS:922's pivot brief, the target was "net ~10 KLOC deletion."
We've added ~2.5 KLOC of v2 clients but deleted ~0. Wave 7 needs to
*delete* the inline `panel_pos_toggle`, `menu_*`, `cycler_*`,
`calpop_*`, `run_*`, `lock_*` bodies from hamUId now that the v2
clients can render them. The test_de_panel_v2.sh-shape grep guards
must invert: instead of "token gone from daemon_pixel," assert
"function body absent from hamUId.ad."

**Verdict: BROKEN.** The pivot is half-done in a way that the test
suite cannot detect.

---

## 9. Memory / lifecycle — HELD, one known issue

- `mm/`, `kernel/sched/core.ad` show no obvious `kmalloc`/`kfree`
  mismatches or refcount cheats from a top-pass scan.
- `#439` (TODO:184) is an open known crash: probabilistic
  post-exit wedge, buddy double-free in `_try_remove_buddy`. The fix
  is parked on two worktree branches. **Locks alone insufficient —
  genuine double-free in some reclaim path.** Deferred behind F10.
- Several `kfree` paths in `9p_client.ad`/`namec.ad` carry
  defensive "do NOT double-free" comments — these are
  protocol-level lifecycle hazards, not active bugs.

**Verdict: HELD apart from #439.** That issue is real, known, and on
the queue.

---

## 10. Scheduler / SMP — HELD

`kernel/sched/core.ad:1000` `rq_locks: Array[16, uint32]`. The single
global `rq_lock` rename (the audit's F10 finding) is acknowledged at
line 1008:

```
rq_lock: uint32 = 0
# (legacy export, no active call sites)
```

`_rq_lock_cpu` / `_rq_unlock_cpu` are the only entry points (lines
1059–1086). nscap CPU factor inflates vruntime at `core.ad:3513`. Per
the F10 audit, "scheduler IS pgrp-aware via nscap CPU cap" still
holds.

Open: work stealing, CPU affinity (TODO:213). These are
right-shape-wrong-scale items, not shortcuts.

**Verdict: HELD.**

---

## 11. Test honesty — BROKEN

### 11.1 DE pivot tests are structural-only

All 17 `scripts/test_de_*.sh` files do structural grep against
source. **NONE boot a VM.** Sample `test_de_panel_v2.sh:46-60`
slices `daemon_pixel`'s function body and asserts a token list
(`on_panel_y(y)`, `clock_x`, etc.) is absent. Token absence proves
nothing about rendering, focus, or input.

```
$ grep -l "qemu-system" scripts/test_de_*.sh
(empty)
```

The DE v2 waves can therefore land green while the v2 panel's pixels
never actually appear on `/dev/fb`. This is the test-honesty bite
the user has flagged repeatedly (`feedback_merged_is_not_working`).

Repo-wide: 648 of 780 test scripts (~83%) invoke `qemu-system`
somewhere — so the runtime path exists; it's the DE family
specifically that is structural-only.

### 11.2 9P Tauth E2E

`test_p9_tauth.sh` (STATUS:928) was the second cut after the first
flaked on serial-loglevel masking. It now passes 7 markers — but the
markers are kernel printk strings, not "a mount succeeded with a
real uname." A real test would mount with `afd` from userland and
read back the uname through `/proc/mounts`.

### 11.3 F10-3 default-uid test

`test_default_uid.sh` does exercise SETUID + a real
`open("/dev/blk/sd0")` denial as `nobody`. Genuinely runtime. Good.

### 11.4 F10-6 Dir record test

`test_p9_dir.sh` walks records from `/srv/dirtest`. Genuinely runtime.
Good. But only `/srv` emits Dir records; devproc/devnet/devblk dir
backings still emit `NAME\n`. The STATUS:958 row admits this.

### 11.5 Heartbeat as a load-bearing canary

The heartbeat test is the only universal post-commit check on real
behaviour. It is **silently load-bearing** for the whole orchestration
loop (memory: `feedback_regression_prone_needs_test`). The recent
"24 vs 26 ticks; QEMU rc=124 acceptable" pattern signals it is
near-flaky — when the heartbeat needs `qemu rc=124` to "pass," that's
"timed out gracefully," not "actually ran the workload."

**Verdict: BROKEN for the DE family; PARTIAL elsewhere.** A future
DE wave that doesn't add a real-render runtime gate cannot be
trusted.

---

## 12. CI vs reality — spot checks

Sampling 5 STATUS "Done" rows against current code:

### 12.1 STATUS:912 "F1 namespace substrate"

Cross-checked. `resolve_path` is wired. `_path_owning_server`
default-denies. **HELD.**

### 12.2 STATUS:957 "F10-8 seccomp-native"

`grep -n "seccomp_native" kernel/sched/core.ad arch/x86/kernel/syscall.ad`:
field/accessor/probe present per claim. `do_syscall` entry consults
the bitmap. **HELD.**

### 12.3 STATUS:955 "F10-10 per-Pgrp oom_score_adj"

`grep -n "pgrp_oom_score_adj" sys/src/9/port/chan.ad`: field
present; `pgrp_clone` propagation present. **HELD.**

### 12.4 STATUS:958 "F10-6 Plan 9 Dir record MVP"

`lib/p9dir.ad`: present. `SYS_LISTDIR_RECORDS=318` arm present in
`arch/x86/kernel/syscall.ad`. **HELD as MVP.**

### 12.5 STATUS:959 "F10-9 strcmp-ladder retire"

PARTIAL. `is_ext_path` is still imported by `linux_abi/u_syscalls.ad`
at line 603 and used at 3338 / 7376. The STATUS row claims
`_statfs_classify_path` was migrated; that specific function is
fine, but other callers in u_syscalls.ad still use the strcmp
helpers. The row over-claims.

### 12.6 STATUS:920 "DE pivot #442 (c) blit protocol substrate"

The substrate is real (kernel parser + lib/hamui v2 emitter + v2
present arm in compositor). What's missing is *deletion of the v1
paths after the v2 clients are proven*. The STATUS row doesn't
claim that deletion — but the user-facing read of "panel landed as
v2 client" is misleading because the v1 panel still draws beneath.

### 12.7 STATUS:721 "hamUI Phase 4c — panel/menus/clock"

Pre-pivot. The panel/menus described there are now competing with
the v2 clients. The row doesn't acknowledge the pivot.

**Verdict on STATUS honesty:** mostly accurate, but the DE pivot
waves and F10-9 over-claim.

---

## Worst offenders — top 15 ranked

Ranking by *(architectural-debt × likelihood-of-bite-later)*.

1. **Compositor monolith not actually shrinking.** `hamUId.ad`
   stays 28k LOC with all extracted widgets still inline. The pivot
   has the wrong delete-vs-add balance. Tests can't see this. (§8)
2. **DE tests are structural-only.** Every v2 wave is provable by
   grep, not by render. The next regression will be silent until a
   human boots. (§11.1)
3. **F2 syscall arms re-implement instead of delegating.** SYS_NICE,
   SYS_SVC_CTL, SYS_NETCFG, SYS_WSYS_*, SYS_RESOLVE* still carry
   full bodies; the ctl files are a parallel implementation. (§4)
4. **Hostowner gates scattered in syscall arms.** 10 raw `uid != 1`
   checks in `arch/x86/kernel/syscall.ad`. Plan 9 shape would push
   these into the ctl-file write handlers. (§3.2)
5. **`#439` probabilistic post-exit buddy double-free.** Real crash
   class; fix attempts insufficient; parked behind F10. (TODO:184)
6. **tmpfs has no per-file uid/gid/mode.** `tmpfs_perm_check` is
   `return 0`. Exploitable once multi-user gets real
   (two non-root users sharing `/tmp`). (§2.2)
7. **F10-9 strcmp ladder retire is partial.** `is_ext_path` still
   imported and used in `linux_abi/u_syscalls.ad:3338,7376`. STATUS
   over-claims closed. (§12.5)
8. **`devcons_perm_check` returns 0; wsys hostowner gate is in the
   cdev write handler at `devwsys.ad:2405,3654`.** Real but
   non-discoverable from `docs/security.md` and from the dispatcher
   table. (§2.4)
9. **Heartbeat-as-canary is near-flaky.** `rc=124` acceptable means
   the test passes when QEMU runs out of time. (§11.5)
10. **Plan 9 `Dir` records emit only from `/srv`.** devproc, devnet,
    devblk listings still emit `NAME\n`. `ls -l` only works on /srv.
    The F10-6 MVP keystone needs the follow-throughs. (§12.4)
11. **`#444` audit said init/main.ad would shrink to "a couple
    hundred lines."** It is now 10,885 lines (down from 14k — real
    progress) but `start_kernel()` is still ~6700 lines of boot
    orchestration. F10-5 hit the easy half. (TODO STATUS:954)
12. **`task_uid_at(target_slot)` race in `devproc_perm_check`.** The
    target task could exit between `task_lookup_by_pid` and
    `task_uid_at` (`devproc.ad:534`). Race window is small but real.
    Defense-in-depth would re-validate after the perm check.
13. **`#w` early-boot fallback in `_path_owning_server` admits
    world.** `fs/vfs.ad:1607`. Comment says "in steady state we
    never see a literal `#w` here" — but the assumption is the kind
    of thing F1's "make this resolvable through the substrate"
    invariant should make impossible by construction, not
    by-comment.
14. **`audio_*_selftest.ad` literal opens.** Kernel-context selftest
    bodies open `#c/audio*` directly — not literal `/dev/`, so F10-1
    holds. But kernel selftests bypassing the namespace is the
    *category* of issue F10-5 was supposed to fix. Audio is left.
15. **DE terminal namespace template.** TODO:33-41 documents the
    issue: DE terminal opens to empty `/` (no `/bin`, no `/net`).
    Half-fixed at STATUS:0c6b3af4; the elevation path
    (`newshell hostowner` → reach `enter linux`) isn't built.

---

## Stubs claiming to be real — numbered

Functions whose body is "return 0" / "return -1" / pass-through, where
the function name implies real work.

1. **`tmpfs_perm_check`** (`fs/tmpfs.ad:115`) → `return 0`. Real
   policy would consult per-entry `uid/gid/mode` once `TmpfsEntry`
   carries them.
2. **`fat_perm_check`** (`fs/fat.ad:44`) → `return 0`. Real policy
   would consult a POSIX overlay.
3. **`devcons_perm_check`** (`sys/src/9/port/devcons.ad:67`) →
   `return 0`. Real policy would refuse non-hostowner write to
   `wsys/ctl`, `keymap`, and the SuperKey-suid cdevs at the server
   boundary, not inside each handler.
4. **`devsrv_perm_check`** (`sys/src/9/port/devsrv.ad:87`) → `return
   0`. Real policy would check srv-owner uid for `vfs_open_write`
   onto a `/srv/<entry>`. Today only `SYS_SRV_POST` enforces.
5. **`devauth_perm_check`** (`sys/src/9/port/devauth.ad:114`) →
   `return 0`. Real policy ALL lives inside the cdev. Architecturally
   fine, but the surface lies.
6. **`SYS_NICE` arm** (`arch/x86/kernel/syscall.ad:3098`) — calls
   `sched_set_nice` directly. Should be a 3-line shim that writes
   `"pri <n>\n"` to `/proc/<pid>/ctl`. Documented as deprecated, not
   actually deprecated.
7. **`SYS_SVC_CTL` arm** (`arch/x86/kernel/syscall.ad:3742`) — full
   body. Should be a shim to `/proc/svc/ctl` writes.
8. **`SYS_NETCFG` arm** (`arch/x86/kernel/syscall.ad:3937`) — full
   body. Should be a shim to `/net/...` ctl writes.
9. **`SYS_RESOLVE` / `SYS_RESOLVE_PTR`** (`syscall.ad:4177,4219`) —
   full bodies. Should be shims to `/net/dns/lookup` /
   `/net/dns/rlookup` writes/reads.
10. **`SYS_WSYS_ALLOC` / `SYS_WSYS_FREE`** (`syscall.ad:3827,3868`)
    — full bodies. Should write to `/dev/wsys/ctl`.
11. **9P `_dirfile_read` Dir-record emission** (per STATUS:933) —
    only `/srv` flips. devproc, devnet, devblk listings still emit
    `NAME\n`. The per-Chan `p9_dir_mode` flag exists but no callers
    flip it for these backings.
12. **`do_fstat` per-backend hook table** (STATUS:948) — deferred.
    `do_fstat` inline-dispatches per-backend; the hook-table
    migration that `do_stat` got has not happened for `do_fstat`.
13. **DE terminal hostowner elevation** (TODO:38-41) — the design
    exists; the `newshell hostowner` path is not built.
14. **`linux_abi/u_syscalls.ad:10523`** `return 0  # timed out,
    nothing ready` — quiet poll-timeout in an epoll-shaped path.
    Worth confirming this is a legitimate timeout, not an error.
15. **ext4 `truncate` of index-node files; growing a full ext4 dir
    block** (TODO:224) — one attempt reverted as a heartbeat
    breaker. Real shortcut: there is no live workaround; large dir
    writes will simply fail. Not "wrong shape," just missing.

---

## Right shape, wrong scale

These are not architectural shortcuts. They are correct designs with
missing implementation chunks. Separating them from the stub list
makes the "what's owed" cleaner.

- **ext4 truncate + htree dir grow** (TODO:224). One attempt reverted.
- **AHCI NCQ + hot-plug + multi-port `sd1…`** (TODO:261).
- **NVMe multi-queue + multi-namespace** (TODO:263).
- **GPT UTF-16 names, BSD disklabel, extended-CHS, APM** (TODO:264).
- **ext4 mkfs multi-block-group + journal at mkfs time** (TODO:266).
- **Dead-key / IME / compose** (TODO:270).
- **`busybox ls` enumeration XFAIL; `sh -c "a|b"` internal pipeline
  `#GP`** (TODO:283).
- **CPython frozen-stdlib trim; PGO/LTO** (TODO:286).
- **iwlwifi / ath11k / mt76** (TODO:291). Architecture is fine
  (the `.ko` loader, non-free repo, hpm plumbing); implementation
  needs the firmware.
- **Native Vulkan + i915 metal Phase 3** (TODO:169).
- **MADT IRQ-override consumption** (TODO:271).
- **`scripts/build_iso.sh` is a delegator shim** — STATUS:32. Fine.
- **Work stealing, CPU affinity for the per-CPU runqueue** (TODO:215).
- **NUC USB MSC HighSpeed train fix** (memory: `project_real_hw_usb_bulk_out`).
- **Per-window NS / uid in devwsys** — 7 `TODO DE close-out`
  comments in `sys/src/9/port/devwsys.ad` and `namec.ad`. The
  per-window ns dump and uid report fall back to caller identity
  today; the design is correct, the fields aren't wired.
- **`signed package indexes`** (TODO:308).
- **`ARM64 full bare-metal Phase 3+`** (TODO:295).

---

## Recommended cadence

Based on the spread of findings: **many parallel small fixes**, not
a keystone.

F10 already absorbed the keystone work. The remaining issues fall
into three disjoint piles, each of which fits a single 1–2 day
agent without crossing the others:

### Pile A — close F2 (delegate the syscall arms)

Rewrite SYS_NICE / SYS_SVC_CTL / SYS_NETCFG / SYS_WSYS_* /
SYS_RESOLVE* as thin shims that format the ctl-file argument and
call `vfs_open_write` + `vfs_write` on the matching ctl path. Single
agent, one file (`arch/x86/kernel/syscall.ad`). Runtime test:
asserting kernel printk fires from the ctl-file backend, not from
the legacy arm. Closes #1 in §worst-offenders, partially closes #4.

### Pile B — tighten the world-r/w stubs

`tmpfs_perm_check`: extend `TmpfsEntry` with `uid/gid/mode`, default
0644 owned by creator. Single agent in `fs/tmpfs.ad` + `fs/vfs.ad`
storage layout. Runtime test: two-uid scenario.

### Pile C — DE pivot follow-through

Delete the inline `panel_*` / `menu_*` / `cycler_*` / `calpop_*` /
`run_*` / `lock_*` function bodies from `hamUId.ad` now that v2
clients render them. Bake a runtime DE test that boots, takes a
framebuffer hash, and asserts the panel pixels are rendered through
the v2 path (kernel backbuffer read serial advances). This is the
*delete-then-test* loop the pivot owes. Closes #1 and #2 in
§worst-offenders. Likely needs `daemon_pixel`'s widget arms gated by
a "v2-client-installed?" check first, then the gated arm bodies
deleted in a follow-up.

Other small disjoint fixes:

- Pile D: `do_fstat` per-backend hook table (#12 in stubs).
- Pile E: devproc/devnet/devblk listings emit Dir records (#11).
- Pile F: `is_ext_path` callers in `linux_abi/u_syscalls.ad` migrate
  to `vfs_fs_kind` (#7 in worst-offenders).
- Pile G: `#439` buddy double-free triage (#5 in worst-offenders).
- Pile H: DE terminal hostowner elevation template (#15).

None of A–H share files of consequence. Up to 4 parallel agents
won't collide. The keystone-shaped lift (F1, F10-1, F10-6 keystone)
isn't on the table — the architecture is already right.

The single architectural item *not* in a disjoint pile is **the DE
test runtime gate** (§11.1). Without it the pivot waves remain
unverified; with it, all of Pile C becomes provable. That's the one
"must precede" dependency.

---

## Closing note

The F10 audit's two structural keystones — `resolve_path` at every
open entry, and Plan 9 `Dir` as the universal directory enumeration
shape — both landed. The codebase's Plan 9 spine is real today in a
way it wasn't on `52812182`.

The remaining work is small, disjoint, and the kind of debt that
accumulates back if not paid soon: stub bodies that look like real
policy, syscall arms that duplicate ctl-file logic, a DE pivot
that's adding without subtracting, and a DE test surface that can't
see render regressions.

Nothing in this audit suggests re-shaping the architecture. Several
items suggest *honesty fixes to STATUS rows* — the F2 "closed"
claim, the F10-9 "closed" claim, and the DE pivot "wave landed"
claims all run ahead of the code.
