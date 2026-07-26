# The desktop stress soak (`scripts/test_de_stress_soak.sh`)

USER, 2026-07-25:

> a sort of stress test where we load up the current image and open a bunch of
> apps close a bunch of apps open a bunch of apps close a bunch of apps and see
> how long the whole system stays up... I want to stress the operating system
> for at least 30 minutes to see if any low hanging fruit exists. can it free
> its RAM and then close the apps and recover that RAM for example.

## Why a soak, and not another short gate

`scripts/test_de_open_close_cycles.sh` already proves ONE open/close cycle
works. `scripts/test_de_app_churn.sh` proves a burst of launches maps windows.
Neither can see a slow leak: a few hundred KiB lost per app-close is inside the
noise of a boot at 24 cycles, and fatal over a working day's session. Only
wall-clock soak time makes the slope measurable.

So this gate does not compare a before/after pair. It runs continuous
open/close churn for `SOAK_MINUTES` (default 30; `0` = until killed) and
reports the **least-squares regression slope per cycle** of each resource
counter, sampled at two points in every cycle:

* **OPEN** — right after the cycle's apps have launched and painted.
* **CLOSED** — after every one of them has been closed with the Plan 9
  terminate note and reaped.

The **CLOSED series is the load-bearing one.** Memory is *supposed* to dip at
the OPEN sample — the apps are running. Recovery means the CLOSED series is
FLAT across cycles. A downward MemFree slope on the CLOSED series is a leak,
and its magnitude in KiB/cycle is the actionable number.

Counters tracked (all from `/proc/meminfo`, `sys/src/9/port/devmeminfo.ad`,
plus the live window table from `/dev/wsys/windows`):

| counter | leak direction | why it matters |
|---|---|---|
| `MemFree` / `MemUsed` | down / up | the user's actual question |
| `PagesInUse` | up | buddy-allocator pages never returned |
| `VmaNodesLive` | up | address-space nodes leaked per exit |
| `KmallocLive` | up | kernel heap objects leaked per exit |
| `TasksLive`, `TasksSpawned - TasksReaped` | up | zombies / task-slot leak |
| live wid count | up | the wsys window table is **32 slots** (`MAX_WINDOWS`, `sys/src/9/port/devwsys.ad`); an earlier leak exhausted it and the desktop stopped opening anything |

It also fails on the ways a desktop dies that are not leaks: a launch that maps
no window, `newwindow: table full`, `create_user_task: no free task slot`, a
`code=143` exit the gate cannot **attribute** to a note it posted (see
"SIGTERM accounting" below), kernel `PANIC`/`TRAP`/`BUG`
/OOM markers, and a missed serial round-trip (the box wedged).

## Running it

```sh
bash scripts/test_de_stress_soak.sh                 # 30 minutes, default mix
SOAK_MINUTES=120 bash scripts/test_de_stress_soak.sh
SOAK_MINUTES=0   bash scripts/test_de_stress_soak.sh   # until killed
APPS_PER_CYCLE=6 SNAP_EVERY=5 bash scripts/test_de_stress_soak.sh
```

It **builds** the installer image rather than warning about staleness: thirty
minutes of soak against a stale image is thirty minutes of confident nonsense.
The build is now guaranteed fresh by the always-overwrite contract
(`scripts/_fresh_artifact.sh`).

Artifacts land in `build/de_stress_soak/<ts>/`: `serial.log`, periodic
`.ppm`/`.png` screendumps, `meminfo_series.tsv` (the full numeric series, one
row per sample) and `summary.txt` (the table + trends + verdict).

Registered in `scripts/ci_battery_manifest.txt` behind `HAMNIX_SOAK=1`. It is
deliberately too slow for the 50-minute per-shard budget and is a no-op in the
normal battery — run it nightly, by hand, or before a release.

## Three gate defects found on the very first run (all fixed)

Recorded because all three are easy to reintroduce in any gate that drives
hamsh over a serial FIFO for a long time.

1. **`code=143` is not a failure when you are the one sending the note.**
   The gate closes apps with `/bin/kill <pid>`, i.e. the Plan 9 terminate
   note, and 143 *is* that note's normal exit status. A raw `code=143` counter
   is therefore 100% false positives — it fired on cycle 1. The first fix
   counted notes *issued* against 143s *observed* and failed on the excess.
   **That fix was itself wrong**, and was replaced — see "SIGTERM accounting"
   below.

2. **Waiting for an exit by grep *presence*.** `grep -q "task: pid $pid
   exited"` can match an older line, so the gate compares occurrence *counts*
   before and after rather than testing presence. (The original rationale
   given here — "pid recycling" — was wrong; see below. Counting is still the
   right shape, it is just cheap insurance rather than a necessity.)

3. **hamsh's command echo contains your markers before the command runs.**
   hamsh echoes the line it is being fed one character at a time, redrawing
   the whole line after each keystroke, so the log contains a single line
   reading `hamsh$ echo SOAKSMP_c0closed_B; cat /proc/meminfo; ... echo
   SOAKSMP_c0closed_E` — **both** delimiters, in order, on one line, before
   any output exists. An unanchored `MARKER_B(.*?)MARKER_E` non-greedy match
   finds that echo first and captures an empty region, silently parsing zero
   fields out of every sample. Markers must be anchored with `^...$` under
   `re.M` (and `\r` normalised first).

## SIGTERM accounting: the "spurious SIGTERM" that never was

A 61-cycle / 244-launch soak at `9263715b` reported, twice:

```
[soak] FAIL cycle 59: 262 code=143 exits but only 261 terminate notes issued —
       something we did NOT kill took a SIGTERM: task: pid 794 exited (code=143)
```

That reads like processes being killed at random. **It was a gate bug**, and
the raw serial log proves it exactly:

| | |
|---|---|
| `/bin/kill <pid>` commands issued | 244 |
| `exited (code=143)` lines | 271 |
| surplus | **27** |

Every one of the 27 surplus 143s satisfies all of:

* it immediately follows a kill whose target was **`hamtermscene`** (27 of the
  244 launches were hamtermscene — the app pool has 9 entries);
* its pid is the kill target's pid **+ 1**;
* its pid **never mapped a window**, so it was never a launch of ours.

It is hamtermscene's inner `/bin/hamsh`, and killing it is *the whole point*:
`/bin/kill` goes through `lib/p9.ad`'s **`p9_note_tree()`**, which notes a pid
**and its attached descendants** precisely so a closed terminal does not
strand a live shell (that leak is documented further down this file). One note
issued, two processes correctly terminated. The old "one note ⇒ exactly one
143" invariant was invalidated by the very fix that closed the leak, so it
cried wolf once per hamtermscene close — and because it re-baselined its
counter on each report, it also *masked* everything in between.

There was **no** spurious kill: pid 794 was killed by `/bin/kill 794` on the
line directly above it in the log. The named pids resolve as:

```
hamsh$ /bin/kill 794
[runtime:kill] _start
[023946] task: pid 800 exited (code=0)      <- the /bin/kill process itself
[023947] task: pid 794 exited (code=143)    <- the app we asked to close
```

### The "pids recycle" premise was false

Both the old check and defect 2 above justified themselves with pid recycling.
HamnixOS pids **do not recycle**: `kernel/sched/core.ad` stamps every task from
a monotonically increasing `next_pid` (`uint64`) that is set to 1 once at boot
and only ever incremented. Task *slots* are reused; pid *numbers* are not. A
pid therefore identifies one process for the whole life of the boot.

Two consequences:

* set-based accounting is **sound**, which is what the gate now does;
* **`p9_note_tree` cannot mis-target via a stale ppid.** Its descendant walk
  matches `/proc/<n>/stat`'s ppid field against the target pid, and a dead
  parent's pid is never reissued, so a stale ppid on an orphan can never come
  to alias a live, unrelated process.

### What the gate checks now

Per cycle, immediately before the close loop (the only moment the descendant
cohort is knowable, since it is about to be killed):

1. read `/proc/tasks` for the live pid set (one command);
2. `cat /proc/<p>/stat` for the non-system pids to record `pid -> ppid` (one
   command; ~5 files, so the guest's per-keystroke line redraw stays cheap).

Then a `code=143` exit is **attributable** iff its pid is a pid we handed to
`/bin/kill`, or is reachable downward through the accumulated parent map from
one that was — the same closure `p9_note_tree` walks. Anything else fails the
cycle by pid, not by count.

Layered on top, and the assertion that actually matters: the **SYSTEM cohort**
— every pid alive before the first app launch (`hamUId`, `hamdesktop`,
`hampanel`, the driving `hamsh`, `init`) — is snapshotted at soak start and
must never take a note at all. "A process nobody asked to kill got SIGTERMed"
is now a direct, named assertion instead of an inference from two totals.

## The kernel bug the soak found on its first two cycles

**`/proc/meminfo` was silently truncated to the reader's first buffer.**

`devmeminfo_read()` was offset-blind — it always returned the first
`min(count, n)` bytes of a freshly rendered snapshot — and `namec.ad`'s
dispatcher turned any non-zero offset into EOF:

```
    if dev_type == DEV_MEMINFO:
        if off > 0:
            return 0
        return devmeminfo_read(buf, count)
```

`/bin/cat` reads in 128-byte chunks (`CHUNK` in `user/cat.ad`). The meminfo
blob is ~590 bytes. So read #1 returned bytes 0..127, read #2 returned 0, and
`cat /proc/meminfo` printed exactly 128 bytes and stopped mid-word:

```
MemTotal: 873959 kB
MemFree:  672568 kB
MemAvailable: 672568 kB
Buffers: 0 kB
Cached: 0 kB
SwapTotal: 0 kB
SwapFree: 0 kB
MemUse                        <- 128 bytes, then EOF
```

Everything past byte 128 — `MemUsed`, `Pages`, `PagesFree`, `KmallocLive`,
`PagesTotal`, `PagesFreedTotal`, `PagesInUse`, `VmaNodesLive`,
`TasksSpawned`, `TasksReaped`, `TasksLive` and the `HugePages` fields — was
**unreachable to any chunked reader**. Those are exactly the leak-accounting
counters the file exists to expose, so every one of them was invisible to the
tools most likely to look at it. `/bin/free` was unaffected only because it
happens to read with a buffer larger than the whole blob, which is why this
survived so long.

Fixed by `devmeminfo_read_at(buf, count, off)` (offset-aware; returns 0 only
once `off >= n`) with `devmeminfo_read` kept as an offset-0 wrapper, and the
`if off > 0: return 0` arm removed from the meminfo dispatch.

### The same shape is latent on `/dev/cpuinfo`

Eleven other synthetic device reads in `namec.ad` share the `if off > 0:
return 0` arm (`DEV_TIME`, `DEV_PID`, `DEV_CPUINFO`, `DEV_UPTIME`,
`DEV_LOADAVG`, `DEV_VERSION`, `DEV_HOSTNAME`, `DEV_NSCAP`, `DEV_P9MAX`,
`DEV_MOUSE`). For most of them the rendered blob is comfortably under 128
bytes, so the truncation never shows. **`/dev/cpuinfo` is not** — it renders
into a 1536-byte scratch (`sys/src/9/port/devcpuinfo.ad`), so `cat
/proc/cpuinfo` truncates the same way. The fix is mechanically identical to
the meminfo one; it is left as a separate change so this one stays
independently bisectable.

---

# RESULTS — first full run, 2026-07-25

Image: `build/hamnix-installer.img` built the same hour from this tree
(98 566 144 bytes, always-overwrite contract). Host: OVMF + KVM, `-m 1G`,
`-vga std`, 1 vCPU. Two runs, identical except for the app pool.

| | run 2 (full pool, 9 apps) | run 3 (control, 8 apps — **no** `hamtermscene`) |
|---|---|---|
| cycles completed | 36 | 36 |
| wall clock | 922 s | 862 s |
| apps launched / closed | 141 / 140 | 142 / 140 |
| windows mapped | 144 | 145 |
| **MemFree slope** | **−4 525 kB/cycle** | **−1 443 kB/cycle** |
| **PagesInUse slope** | **+148.8 pg/cycle** | **+24.4 pg/cycle** |
| **VmaNodesLive slope** | **+0.89 /cycle** (28 → 58) | **+0.00 /cycle** (28 → 28) |
| **TasksLive slope** | **+0.44 /cycle** (20 → 35) | **+0.00 /cycle** (20 → 20) |
| KmallocLive slope | +155 /cycle | +50 /cycle |
| live wids | 0, max 4 of 32 — **no wid leak** | 0, max 4 of 32 — **no wid leak** |
| mean recovery ratio | 0.912 | 0.960 |
| verdict | LEAK, then **hard failure at cycle 36** | LEAK, then **hard failure at cycle 36** |

**Answer to the user's question: NO — closing the apps does not fully recover
the RAM, and the system does not survive 30 minutes of app churn.** It dies
after ~15 minutes and ~141 app launches, in both configurations.

## Ranked findings

### 1. FATAL — after ~141 app launches, `exec` fails forever and the desktop can no longer open anything

Reproduced identically in both runs, at cycle 36. The failing launch spawns a
task which immediately exits **`code=127`**, and hamsh then walks its whole
PATH spawning one 127-exiting task per candidate:

```
[141] 463
[014178] [devwsys] window 5 mapped pid=463      <- launch 141 still fine
[014184] task: pid 464 exited (code=127)        <- launch 142: exec fails
[014192] task: pid 465 exited (code=127)        <- ... and every PATH retry
```

There is **no** `newwindow: table full`, **no** `create_user_task: no free
task slot`, **no** OOM message, **no** panic, and the serial console stays
responsive. From userspace this is indistinguishable from *"command not
found"* — the single most misleading diagnostic the kernel could emit for
"the machine is out of usable memory". Anyone hitting this on a real desktop
would go looking for a missing binary.

It is **not** a memory-*quantity* failure, and this is the surprising part:

| at the moment of death | run 2 | run 3 |
|---|---|---|
| `MemFree` | 334 304 kB | **504 512 kB** |
| `PagesFree` | 2 | 1 |
| `PagesTotal` | 18 432 (72 MiB) | 15 360 (60 MiB) |

**`MemFree` reports a third to half a gigabyte free while the page allocator
has one free page and every `exec` fails.** `MemFree` is
`memblock_avail() + buddy_free`, so it is counting memory the page allocator
cannot actually obtain.

Why it cannot obtain it: `mm/page_alloc.ad` grows the buddy pool **only** by
cold-carving a fresh run out of memblock with
`memblock_alloc(size, size)` (line 389, gated by `memblock_can_alloc(size,
size)` at line 337) — i.e. **alignment equal to the allocation size**. As
memblock's one-way bump pointer advances, size-aligned runs of the larger
orders stop being available long before the byte count runs out, so
`PagesTotal` stalls (at 60 MiB in run 3, 72 MiB in run 2) while
`memblock_avail()` stays enormous. `PagesFree` then sits pinned at 0-1 from
about cycle 5 onward — the allocator has been running on fumes for 90 % of
the soak — and the first cycle whose peak demand exceeds the frozen ceiling
kills every subsequent `exec`.

That also explains why the leakier run survived exactly as long as the
cleaner one: the pool grew to whatever each run's peak demand needed, until
it couldn't grow at all.

**Fix directions** (not attempted here — this is a memory-architecture
change, not a one-liner): let the buddy pool accept *unaligned* / smaller
carves and coalesce, or pre-hand the whole of memblock to the buddy
allocator at boot instead of cold-carving on demand. Independently, and
cheaply: **`MemFree` must not report memory the page allocator cannot get**,
and a failed ELF load must say so on the console instead of surfacing as
`127`.

### 2. `hamtermscene` orphans its child shell on every close — the dominant leak

`user/hamtermscene.ad:898-905` spawns a long-lived
`/bin/hamsh --no-echo /etc/rc.de-user` as the terminal's inner shell. The only
teardown path is `_reap_shell()` (line 977), a `WNOHANG` poll from the main
loop that reaps the child **when the child exits on its own**. Nothing sends
the child a note when *hamtermscene itself* is terminated. So closing a
terminal window leaves its shell running forever.

The control run isolates it exactly. Dropping `hamtermscene` from the pool
and changing nothing else:

* `TasksLive` **28 → 28**: the task leak goes to **zero** (was +15 over 35 cycles).
* `VmaNodesLive` **28 → 28**: the VMA-node leak goes to **zero** (was +30).
* `MemFree` slope improves **3.1×** (−4 525 → −1 443 kB/cycle).
* `PagesInUse` slope improves **6.1×** (+148.8 → +24.4 pg/cycle).

Per terminal open/close the orphan costs **1 task, 2 VMA nodes and ~300 pages
(~1.2 MiB)**. The cycles where `TasksLive` steps up (3, 5, 7, 9, 12, 14, 16,
18, 21, 23, 25, 27, 30, 32, 34) are *exactly* the cycles containing
`hamtermscene`.

This is the highest-value fix on the list and it is local: note `sh_pid` from
hamtermscene's own exit path.

#### FIXED, 2026-07-25 — and the first guess about the mechanism was wrong

hamtermscene **cannot** note `sh_pid` from its own exit path: closing the
window posts the Plan 9 `terminate` note to hamtermscene, and a note to a
handler-less process terminates it *outright*
(`sys/src/9/port/sysnote.ad`, default action → `signal_post(SIGTERM)`). It
never runs another instruction. Installing a note handler is not an option
either — cross-task handler retarget is still an open kernel milestone, so a
handler would only make the terminal **unkillable**.

The mechanism that was *supposed* to collect the shell is the oldest rule in
the book: the terminal goes away, the shell reads EOF on stdin and exits. It
never fired, and the reason is one refcount:

* hamtermscene binds the stdin pipe's **write** end at its own `/fd/10`
  *before* the spawn;
* `rfork`'s `RFNAMEG` clones the whole `/fd` row into the child
  (`chan.ad` `pgrp_clone` → `devfd_clone_row`), which `pipe_inc_writer()`s
  **every** copied `DEVFD_PIPE_W` slot;
* so the child held a second writer reference **on its own stdin**, and
  nothing dropped it — `lib/p9.ad`'s `p9_closefrom(3)` sweeps *integer* fds,
  not `/fd/N` names, and hamsh's `_setup_fd_namespace` only seeds 0/1/2.

When hamtermscene died, `in_slot`'s writer count fell 2 → 1 and stopped. No
`wq_wake_all`, no EOF: hamsh's `sys_read_nb(0)` kept returning "would block"
and its REPL idled forever.

The fix is two lines in `_start_shell()`: after wiring the child's stdio,
rebind the child's *inherited* copies of the two scratch names to the console
(`sys_fdbind(pid, TERM_IN_FD, DEVFD_CONS, 0)` and the same for `TERM_OUT_FD`).
`devfd_bind` releases whatever Chan sits at the name first, which drops
exactly the two references the clone added. Rebinding, rather than deferring
our own binds until after the spawn, keeps a writer pinned across the whole
fork window — had the count been allowed to reach zero, a child that got to
its first read first would have seen an instant EOF and the terminal would
open with a dead shell.

Now the terminal is self-healing against *any* killer: close box, `/bin/kill`,
crash. Its `/fd` row is released at teardown, `in_slot` hits zero writers, and
hamsh takes its EOF exit. Belt and braces on top of that:

* `lib/p9.ad` gained `p9_note_tree()` — note a pid **and its attached
  descendants** — used by the DE close paths (`hamUId` `daemon_close_slot`,
  `hamUI close`) and `/bin/kill`. Detached (`RFNOWAIT` / `spawn_detached`)
  processes have `parent_pid == 0` and are never reached, so independently
  launched DE apps still survive their launcher.
* `hamtermscene` gained `_shutdown_shell()` for its own orderly exits.
* The same `/fd`-row-clone reference pin was fixed in the three siblings that
  copy hamtermscene's spawn shape — `hampkgscene`, `hamsoftware`,
  `haminstallui` (they pin the *read* end, so the symptom there is a missing
  EPIPE rather than a stranded shell).

Measured with `scripts/test_de_term_child_reap.sh`, 12 terminal open/close
cycles, same image before and after:

| counter | before | after |
|---|---|---|
| `TasksLive` | 20 → 32, monotone (**+1 per close**) | oscillates 20 ↔ 22, **settled floor exactly 20** |
| `VmaNodesLive` | 28 → 52, monotone (**+2 per close**) | oscillates 28 ↔ 32, **settled floor exactly 28** |
| live `hamsh` rows | 4 → 16 (**+1 per close**) | never above 5, back to 4 (**+0 per close**) |
| `PagesInUse` | 5 947 → 9 427 (**+290/cycle**) | settled samples 5 968 → 6 076 (**+13.5/cycle**, 21×) |
| `MemFree` | −2 236 kB/cycle | settled samples **−666 kB/cycle** (3.4×) |

The after-fix oscillation is expected and is not a leak: a close leaves a
zombie for a beat, because `reap_orphan_zombies` collects an orphan at the
next task ALLOCATION — i.e. when the next app launches. A sample that lands
mid-teardown reads baseline+1 task / +2 VMA nodes; the next settled sample is
back at baseline exactly. The gate therefore judges the **settled floor over
the back third of the run** (0 with the fix, +9 tasks / +18 VMA nodes
without), not any single sample.

The residual −666 kB/cycle is finding #3 below (the ~6-pages-per-app-open/close
leak), which is a different bug and still open.

### 3. Residual page leak of ~6 pages (~24 KiB) per app open/close

With the terminal removed, `PagesInUse` still climbs **+24.4 pages/cycle** at
4 apps/cycle ≈ **6 pages (~24 KiB) per app open/close**, while `TasksLive` and
`VmaNodesLive` stay perfectly flat. Tasks are being reaped and their VMAs
freed, but pages are not all returned — so this is a kernel-side page leak in
task teardown, not an orphaned-process artifact. `KmallocLive` climbs
+50/cycle alongside it.

Small in isolation; it is what pushes peak demand into finding #1 over time.

### 4. `PagesInUse` and `KmallocLive` disagree with `PagesTotal − PagesFree`

At run 2's last sample: `PagesTotal 18432`, `PagesFree 2`, so
`PagesTotal − PagesFree = 18430` — which is exactly what `KmallocLive`
reports (it is defined that way in `devmeminfo.ad`). But `PagesInUse` says
`11216`. Two counters that should describe the same quantity differ by 7 214
pages (28 MiB). At least one of them is wrong, and `KmallocLive` is in any
case mislabelled — it is a page count, not a kmalloc-object count, as its own
comment admits ("KmallocLive proxy"). A leak gate that trusts the wrong one
draws the wrong conclusion.

### 5. Two unexplained ~147 MB cliffs in `MemFree`

`MemFree` drops ~147-148 MB in a single cycle twice in run 2 (c1→c2:
656 312 → 508 564; c31→c32: 483 092 → 335 704) and once in run 3 (during the
first five cycles). `PagesTotal` grows only 4 096 pages (16 MiB) across the
same boundary, so ~130 MB left `memblock_avail()` without reaching the buddy
pool. Not diagnosed; flagged because a 147 MB step is far too large to be
per-app churn and it repeats at a suspiciously identical magnitude.

### 6. Things that are FINE

* **The 32-slot wid table does not leak.** Live wids returned to 0 after every
  single one of the 70 close phases across both runs; peak concurrent was 4.
  `wsys_free_wid` / `wsys_reap_dead_wids` are doing their job. The historical
  slot-exhaustion bug has not regressed.
* **No kernel faults.** Zero `PANIC` / `TRAP` / `BUG` / OOM-kill markers in
  28 minutes of combined churn.
* **No wedge.** Every liveness round-trip succeeded, including after the
  system could no longer exec anything — the console stayed interactive
  throughout, which is why this failure is silent rather than obvious.
* **Close is reliable.** 140/140 apps in each run took the terminate note and
  exited; the only survivor was the app caught by finding #1.
* **Boot is fast.** 6 s from QEMU start to DE handoff, both runs.
