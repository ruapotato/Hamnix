#!/usr/bin/env python3
"""Adjudicate a boot-armed-tracker log (leak pass 22).

Separate from the gate that captures the log, for the reason leak pass 21
made a rule: judging a captured log must not need a boot, and the verdict
must be reproducible by someone who did not run the machine.

Exit codes:  0 PASS   1 FAIL   125 INCONCLUSIVE

INCONCLUSIVE IS NOT PASS. A log with no guest markers proves nothing; it is
a dark gate, and it exits 125.
"""
import re
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: track_boot_armed_report.py <serial.log> [boot_seconds]")
        return 125
    path = sys.argv[1]
    boot_s = sys.argv[2] if len(sys.argv) > 2 else "?"
    try:
        with open(path, "rb") as fh:
            log = fh.read().decode("utf-8", "replace")
    except OSError as exc:
        print(f"INCONCLUSIVE: cannot read {path}: {exc}")
        return 125

    print("=== boot-armed page tracker ===")
    print(f"boot-to-handoff: {boot_s}s")

    # --- the guest has to have said SOMETHING -------------------------
    if "MARK_TB_READY" not in log:
        print("INCONCLUSIVE: no guest ready marker — the gate is dark, "
              "not green")
        return 125

    fails, incs = [], []

    # --- 1. the arm happened on the BOOT path -------------------------
    # The marker must appear BEFORE the shell handoff. A boot-arm marker
    # printed after the handoff would be a late arm wearing the right name.
    m = re.search(r"\[trk\] boot-arm mode=(\d+) frames=(\d+)", log)
    handoff = log.find("handing off to interactive shell")
    if not m:
        if "[trk] boot-arm FAILED" in log:
            fails.append("the kernel printed `[trk] boot-arm FAILED` — "
                         "memblock could not supply the tracking arrays, so "
                         "the tracker is DISARMED and every later leak "
                         "reading on this boot is a false negative")
        else:
            fails.append("no `[trk] boot-arm` marker in the boot log at all")
        mode = frames = 0
    else:
        mode, frames = int(m.group(1)), int(m.group(2))
        if handoff >= 0 and m.start() > handoff:
            fails.append("the boot-arm marker appears AFTER the shell "
                         "handoff — that is a late arm, not a boot arm")
        else:
            print(f"OK: armed on the boot path, before the shell handoff "
                  f"(mode={mode}, frames={frames})")
        if mode < 2:
            incs.append(f"armed at mode {mode}, not 2 — per-frame tag words "
                        f"are absent, so frames allocated during bringup "
                        f"carry no VA tag (the blind spot moved rather than "
                        f"closed)")

    mb = re.search(r"\[trk\] boot-arm bytes=(\d+) site0=(\d+)", log)
    if mb:
        b, s0 = int(mb.group(1)), int(mb.group(2))
        print(f"tracker arrays: {b} bytes ({b / 1048576.0:.2f} MiB) "
              f"for {frames} frames")
        if frames:
            print(f"                {b / float(frames):.1f} bytes/frame")
        # Site 0 at the instant of arming is the population the tracker
        # never saw allocated. Arming before the buddy allocator has handed
        # out anything is what makes it zero, and zero is the whole point.
        if s0 != 0:
            fails.append(f"site 0 held {s0} pages at the instant of arming — "
                         f"the arm is too late in mem_init(), frames had "
                         f"already left the buddy allocator")
        else:
            print("OK: site 0 was EMPTY at the arm — nothing had been "
                  "allocated unwatched")

    # --- 2. the FILE says so ------------------------------------------
    mboot = re.search(r"^PgTrackBoot:\s+(\d+)", log, re.M)
    mmode = re.search(r"^PgTrackMode:\s+(\d+)", log, re.M)
    mbytes = re.search(r"^PgTrackBytes:\s+(\d+)", log, re.M)
    if not mmode:
        incs.append("/proc/meminfo carried no PgTrackMode line — could not "
                    "read tracker state through the file interface")
    elif not mboot:
        fails.append("/proc/meminfo has PgTrackMode but no PgTrackBoot "
                     "field")
    elif int(mboot.group(1)) != 1:
        fails.append("PgTrackBoot is 0 — the file reports the tracker was "
                     "armed from userland, not by the boot path")
    else:
        print(f"OK: /proc/meminfo reports PgTrackBoot: 1, "
              f"PgTrackMode: {mmode.group(1)}"
              + (f", PgTrackBytes: {mbytes.group(1)}" if mbytes else ""))

    # --- 3. COVERAGE: the counters actually span bringup ---------------
    # This is the load-bearing proof. A tracker armed after boot can report
    # PgTrackBoot: 1 only by lying; what it cannot fake is a cumulative
    # alloc count far exceeding the live population, because those frames
    # were allocated and freed while it was watching. Under late arming the
    # cumulative counters started at zero minutes ago.
    sites = {}
    for sm in re.finditer(r"^PgSite(\d+):\s+(\d+)\s+(\d+)\s+(\d+)", log,
                          re.M):
        sites[int(sm.group(1))] = (int(sm.group(2)), int(sm.group(3)),
                                   int(sm.group(4)))
    if not sites:
        incs.append("no PgSite lines in the guest's /proc/meminfo read")
    else:
        live = sum(v[0] for v in sites.values())
        allocs = sum(v[1] for v in sites.values())
        frees = sum(v[2] for v in sites.values())
        s0_live = sites.get(0, (0, 0, 0))[0]
        print(f"live={live} cumulative allocs={allocs} frees={frees}")
        print(f"site 0 (unknown) live={s0_live}")
        if allocs == 0:
            fails.append("cumulative allocs are 0 — the tracker is armed but "
                         "counted nothing, so it was not stamping during "
                         "bringup")
        elif allocs <= live:
            incs.append(f"cumulative allocs ({allocs}) do not exceed the live "
                        f"population ({live}) — cannot distinguish bringup "
                        f"coverage from a fresh baseline")
        else:
            print(f"OK: {allocs} cumulative allocs against {live} live pages "
                  f"— {frees} frames were allocated AND freed while the "
                  f"tracker watched, which only a tracker running during "
                  f"bringup could have counted")
        # The pre-arming population is what boot-arming exists to delete.
        if live and s0_live * 2 > live:
            fails.append(f"site 0 holds {s0_live} of {live} live pages — the "
                         f"majority is still unattributed, which is the "
                         f"late-arming shape this change was supposed to "
                         f"remove")
        elif live:
            print(f"OK: site 0 is {100.0 * s0_live / live:.1f}% of the live "
                  f"population (it was ~100% under late arming)")

    # --- 4. the deep audit must NOT be on ------------------------------
    if "[stale] reap slot" in log:
        fails.append("`[stale] reap slot` lines are present — the per-reap "
                     "page-table walk is running on a normal boot, which is "
                     "the boot-cost regression this change had to avoid")
    else:
        print("OK: deep-audit walk is OFF (no [stale] reap lines)")

    for f in fails:
        print(f"FAIL: {f}")
    for i in incs:
        print(f"INCONCLUSIVE: {i}")
    if fails:
        return 1
    if incs:
        return 125
    print("PASS: the page tracker is armed through bringup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
