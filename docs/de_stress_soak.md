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
`code=143` exit of a pid the gate did **not** kill, kernel `PANIC`/`TRAP`/`BUG`
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

## Two gate defects found on the very first run (both fixed)

Recorded because both are easy to reintroduce in any gate that drives hamsh
over a serial FIFO.

1. **`code=143` is not a failure when you are the one sending the note.**
   The gate closes apps with `/bin/kill <pid>`, i.e. the Plan 9 terminate
   note, and 143 *is* that note's normal exit status. A raw `code=143` counter
   is therefore 100% false positives — it fired on cycle 1. The gate now
   tracks the pids it noted and only fails on a 143 exit it did not cause.

2. **hamsh's command echo contains your markers before the command runs.**
   hamsh echoes the line it is being fed one character at a time, redrawing
   the whole line after each keystroke, so the log contains a single line
   reading `hamsh$ echo SOAKSMP_c0closed_B; cat /proc/meminfo; ... echo
   SOAKSMP_c0closed_E` — **both** delimiters, in order, on one line, before
   any output exists. An unanchored `MARKER_B(.*?)MARKER_E` non-greedy match
   finds that echo first and captures an empty region, silently parsing zero
   fields out of every sample. Markers must be anchored with `^...$` under
   `re.M` (and `\r` normalised first).

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
