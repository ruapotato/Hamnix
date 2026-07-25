#!/usr/bin/env bash
# scripts/test_de_stress_soak.sh — LONG-RUNNING desktop soak: open a bunch of
# apps, close a bunch of apps, repeat for half an hour, and answer ONE
# question with numbers:
#
#     WHEN THE DESKTOP CLOSES AN APP, DOES THE SYSTEM GET THE RAM BACK?
#
# USER REQUEST (2026-07-25): "a sort of stress test where we load up the
# current image and open a bunch of apps close a bunch of apps open a bunch of
# apps close a bunch of apps and see how long the whole system stays up... I
# want to stress the operating system for at least 30 minutes to see if any
# low hanging fruit exists. can it free its RAM and then close the apps and
# recover that RAM for example."
#
# WHY A SOAK AND NOT ANOTHER SHORT GATE
# =====================================
# scripts/test_de_open_close_cycles.sh already proves ONE open/close cycle
# works, and scripts/test_de_app_churn.sh proves a burst of launches maps
# windows. Neither can see a SLOW leak: 24 cycles at a few hundred KiB of
# drift each is inside the noise of a boot. A leak that costs 300 KiB per
# app-close is invisible at 24 cycles and fatal at 4 000 — which is what a
# real desktop session does in a working day. Only wall-clock soak time makes
# the slope measurable, so this gate runs for SOAK_MINUTES (default 30) of
# continuous open/close churn and reports the REGRESSION SLOPE of MemFree
# against cycle number, not a single before/after pair.
#
# WHAT IT MEASURES, PER CYCLE, AT TWO POINTS (apps OPEN and apps CLOSED)
# =====================================================================
#   MemFree / MemAvailable / MemUsed   — /proc/meminfo (sys/src/9/port/devmeminfo.ad)
#   PagesInUse, PagesFreedTotal        — buddy-allocator page accounting
#   VmaNodesLive                       — per-VMA node leak counter
#   KmallocLive                        — kmalloc leak counter
#   TasksLive / TasksSpawned / TasksReaped — zombie / task-slot leak
#   live wids                          — `cat /dev/wsys/windows`, the 32-slot
#                                        window table (MAX_WINDOWS in
#                                        sys/src/9/port/devwsys.ad). An earlier
#                                        leak exhausted it and the desktop
#                                        stopped opening anything at all.
#
# The CLOSED-point series is the load-bearing one: apps are open at the OPEN
# sample by construction, so OPEN memory is *supposed* to dip. Recovery means
# the CLOSED series is FLAT across cycles. A negative slope on the CLOSED
# series is a leak, and its magnitude in KiB/cycle is the actionable number.
#
# ALSO FAILS ON (the ways a desktop dies that aren't leaks):
#   * a launch that maps no window            (DE can no longer open apps)
#   * "newwindow: table full"                 (wid-slot exhaustion)
#   * "create_user_task: no free task slot"   (pid-slot exhaustion)
#   * an unexpected `exited (code=143)`       (something SIGTERMed itself)
#   * kernel PANIC / TRAP / BUG / OOM markers
#   * a missed serial round-trip              (the box wedged)
#
# ARTIFACTS (build/de_stress_soak/<ts>/): serial.log, periodic .ppm/.png
# screendumps, meminfo_series.tsv (the whole numeric series, one row per
# sample) and summary.txt.
#
# RUNTIME: SOAK_MINUTES (default 30) + ~4 min boot/teardown. This gate is
# DELIBERATELY too slow for a per-shard CI budget — it is registered in
# scripts/ci_battery_manifest.txt behind HAMNIX_SOAK=1 so the battery skips it
# by default and a nightly/manual run opts in.
#
# Env:
#   SOAK_MINUTES    soak duration, minutes (default 30; 0 = run until killed)
#   APPS_PER_CYCLE  apps opened per cycle before closing them (default 4)
#   INSTALLER_IMG   image to boot (default build/hamnix-installer.img)
#   SNAP_EVERY      screendump every N cycles (default 10)
#   LEAK_TOL_KB     allowed CLOSED-series MemFree drift, KiB/cycle (default 64)
#   BOOT_WAIT, OVMF_FD, OUT_DIR

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[soak]"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
SOAK_MINUTES="${SOAK_MINUTES:-30}"
APPS_PER_CYCLE="${APPS_PER_CYCLE:-4}"
SNAP_EVERY="${SNAP_EVERY:-10}"
LEAK_TOL_KB="${LEAK_TOL_KB:-64}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_stress_soak/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

# --- environment gates (SKIP cleanly, exit 0 — never a false red) ------
[ -e /dev/kvm ] || { echo "$TAG SKIP-RUNTIME: /dev/kvm absent" >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP-RUNTIME: no OVMF" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP-RUNTIME: no socat" >&2; exit 0; }

# --- the image MUST be fresh ------------------------------------------
# A 30-minute soak against a stale image is 30 minutes of confident nonsense,
# so this gate BUILDS rather than warns. scripts/build_installer_img.sh now
# honours the always-overwrite contract (scripts/_fresh_artifact.sh), so what
# it leaves behind was produced by THIS tree or does not exist at all.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
ensure_installer_img "$INSTALLER_IMG" "$TAG" || {
    echo "$TAG SKIP-RUNTIME: no usable installer image" >&2; exit 0; }

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/serial.log"
SERIES="$OUT_DIR/meminfo_series.tsv"
SUMMARY="$OUT_DIR/summary.txt"
echo "$TAG output dir: $OUT_DIR"
echo "$TAG image      : $INSTALLER_IMG ($(installer_img_age_str "$INSTALLER_IMG"))"
echo "$TAG soak       : ${SOAK_MINUTES}m, ${APPS_PER_CYCLE} apps/cycle"

OVMF_RW=$(mktemp --tmpdir hamnix-soak.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-soak.img.XXXXXX.raw)
MON=$(mktemp --tmpdir -u hamnix-soak-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-soak.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
}
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1; }
snapshot() {
    local ppm="$OUT_DIR/$1.ppm"
    rm -f "$ppm"
    mon_cmd "screendump $ppm" || return 1
    # screendump is ASYNC: poll for a non-empty file, then let it finish.
    local i=0
    while [ "$i" -lt 40 ]; do [ -s "$ppm" ] && break; sleep 0.1; i=$((i+1)); done
    [ -s "$ppm" ] || return 1
    sleep 0.3
    command -v convert >/dev/null 2>&1 && convert "$ppm" "$OUT_DIR/$1.png" 2>/dev/null
    return 0
}
# grep -a is MANDATORY: the serial log carries NUL bytes and grep otherwise
# treats it as binary and silently never matches.
wait_for() {
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
mapped_count() { grep -ac "\[devwsys\] window .* mapped" "$LOG"; }

qemu-system-x86_64 \
    -enable-kvm -cpu host -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!
BOOT_T0=$SECONDS

echo "$TAG waiting up to ${BOOT_WAIT}s for the DE handoff..."
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || {
    echo "$TAG FAIL: no handoff marker in ${BOOT_WAIT}s" >&2
    tail -40 "$LOG" >&2
    exit 1
}
echo "$TAG booted to handoff in $(( SECONDS - BOOT_T0 ))s"
sleep 8
# hamsh drops the FIRST serial command; burn one on a ready marker.
printf 'echo MARK_SOAK_READY\n' >&3
sleep 1
wait_for MARK_SOAK_READY 12 || { printf 'echo MARK_SOAK_READY\n' >&3; sleep 2; }

fail=0
say_fail() { echo "$TAG FAIL $*" >&2; fail=1; }
alive_n=0
assert_alive() {
    alive_n=$((alive_n+1))
    local m="MARK_ALIVE_${alive_n}"
    printf 'echo %s\n' "$m" >&3
    local d=$(( SECONDS + 25 ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "$m" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || { say_fail "QEMU DIED at $1"; return 1; }
        sleep 1
    done
    say_fail "SYSTEM WEDGED at $1 (no serial round-trip in 25s)"
    snapshot "WEDGED_$1"
    return 1
}

# sample <label> — dump the full kernel resource accounting + the live wsys
# window table between unique markers, for host-side parsing at the end.
sample() {
    local lbl="$1"
    printf 'echo SOAKSMP_%s_B; cat /proc/meminfo; echo SOAKWIN_%s_B; cat /dev/wsys/windows; echo SOAKSMP_%s_E\n' \
        "$lbl" "$lbl" "$lbl" >&3
    local d=$(( SECONDS + 25 ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "SOAKSMP_${lbl}_E" "$LOG" && return 0
        sleep 1
    done
    return 1
}

# Unexpected-SIGTERM watch: we kill apps with the Plan 9 terminate note, which
# is a NORMAL exit for them; what must not happen is anything ELSE exiting 143.
sig143_base=$(grep -ac "exited (code=143)" "$LOG")

# The app mix. Spans the office suite, the scene apps, the browser and a
# terminal — deliberately heterogeneous so a leak in one app's teardown does
# not hide behind another's. hambrowse gets --demo so it renders a
# deterministic offline page instead of waiting on a network that isn't there.
APP_POOL=(hamwrite hamsheet hamslides hamfmscene hammonscene
          hamaudioscene hamcalcscene hambrowse hamtermscene)
APP_ARGS_hambrowse="--demo"

snapshot 000_idle
sample c0closed || say_fail "baseline sample timed out"

DEADLINE=$(( SECONDS + SOAK_MINUTES * 60 ))
c=0
pool_i=0
launched_total=0
closed_total=0
SOAK_T0=$SECONDS

while [ "$SOAK_MINUTES" -eq 0 ] || [ "$SECONDS" -lt "$DEADLINE" ]; do
    c=$((c+1))
    open_pids=""
    open_names=""
    stop=0

    # ---- open a bunch of apps ----------------------------------------
    n=0
    while [ "$n" -lt "$APPS_PER_CYCLE" ]; do
        app="${APP_POOL[$(( pool_i % ${#APP_POOL[@]} ))]}"
        pool_i=$((pool_i+1))
        n=$((n+1))
        eval "extra=\${APP_ARGS_${app}:-}"
        before=$(mapped_count)
        # Launch as a CHILD OF THIS SHELL so devproc's caller-uid == target-uid
        # note gate lets us close it the same way the DE's own close path does.
        printf '/bin/%s %s &\n' "$app" "$extra" >&3
        launched_total=$((launched_total+1))
        d=$(( SECONDS + 30 ))
        while [ "$SECONDS" -lt "$d" ]; do
            [ "$(mapped_count)" -gt "$before" ] && break
            sleep 1
        done
        if [ "$(mapped_count)" -le "$before" ]; then
            say_fail "cycle $c: $app mapped NO window after 30s (DE can no longer open apps)"
            snapshot "STUCK_c${c}_${app}"
            sample "c${c}stuck"
            stop=1
            break
        fi
        line=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)
        pid=$(echo "$line" | sed -n 's/.*mapped pid=\([0-9]*\).*/\1/p')
        [ -n "$pid" ] && { open_pids="$open_pids $pid"; open_names="$open_names $app"; }
        sleep 1
    done

    # let them actually paint before we measure "apps open"
    sleep 2
    sample "c${c}open" || say_fail "cycle $c: OPEN sample timed out"
    [ $(( c % SNAP_EVERY )) -eq 0 ] && snapshot "c${c}_open"

    # ---- close a bunch of apps ---------------------------------------
    for pid in $open_pids; do
        printf '/bin/kill %s\n' "$pid" >&3
        if ! wait_for "task: pid $pid exited" 20; then
            say_fail "cycle $c: pid $pid survived the terminate note for 20s"
            stop=1
            break
        fi
        closed_total=$((closed_total+1))
    done

    # Give the kernel a beat to reap and to run wsys_reap_dead_wids (which
    # `cat /dev/wsys/windows` triggers), then measure "apps closed" — the
    # series that answers the RAM-recovery question.
    sleep 3
    sample "c${c}closed" || say_fail "cycle $c: CLOSED sample timed out"

    # ---- per-cycle health --------------------------------------------
    now=$(grep -ac "exited (code=143)" "$LOG")
    if [ "$now" -gt "$sig143_base" ]; then
        say_fail "cycle $c: unexpected SIGTERM exit: $(grep -a 'exited (code=143)' "$LOG" | tail -1)"
        sig143_base=$now
    fi
    assert_alive "cycle_$c" || stop=1
    if grep -aq "newwindow: table full" "$LOG"; then
        say_fail "cycle $c: wsys window table EXHAUSTED (32 slots) — wid leak"
        stop=1
    fi
    if grep -aq "create_user_task: no free task slot" "$LOG"; then
        say_fail "cycle $c: task slots EXHAUSTED — pid leak"
        stop=1
    fi
    if grep -aqE 'PANIC|panic:|TRAP:|BUG:' "$LOG"; then
        say_fail "cycle $c: kernel fault: $(grep -aE 'PANIC|panic:|TRAP:|BUG:' "$LOG" | tail -1)"
        stop=1
    fi
    [ $(( c % SNAP_EVERY )) -eq 0 ] && snapshot "c${c}_closed"

    el=$(( SECONDS - SOAK_T0 ))
    echo "$TAG cycle $c done (${el}s elapsed, ${launched_total} launched, ${closed_total} closed)"
    [ "$stop" -eq 1 ] && break
done

CYCLES_RUN=$c
SOAK_SECONDS=$(( SECONDS - SOAK_T0 ))
snapshot 999_final
assert_alive final
sleep 2

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

# --- analysis ---------------------------------------------------------
# Done in python3 over the raw serial bytes: the log is binary-ish (NULs, ANSI)
# and the numbers matter too much to trust a shell pipeline with.
python3 - "$LOG" "$SERIES" "$LEAK_TOL_KB" "$CYCLES_RUN" "$SOAK_SECONDS" \
         "$launched_total" "$closed_total" > "$SUMMARY" 2>&1 <<'PY'
import re, sys

log, series_path, tol_kb, cycles, soak_s, launched, closed = sys.argv[1:8]
tol_kb = int(tol_kb); cycles = int(cycles); soak_s = int(soak_s)
text = open(log, 'rb').read().decode('utf-8', 'replace')

# Split the log into the marked sample regions.
FIELDS = ["MemTotal", "MemFree", "MemAvailable", "MemUsed", "PagesInUse",
          "PagesFreedTotal", "VmaNodesLive", "KmallocLive", "TasksLive",
          "TasksSpawned", "TasksReaped"]
samples = []                       # (label, {field: int}, live_wids)
for m in re.finditer(r'SOAKSMP_(\w+)_B(.*?)SOAKSMP_\1_E', text, re.S):
    label, body = m.group(1), m.group(2)
    win = ''
    wm = re.search(r'SOAKWIN_\w+_B(.*)$', body, re.S)
    if wm:
        win = wm.group(1)
        body = body[:wm.start()]
    vals = {}
    for f in FIELDS:
        mm = re.search(rf'^\s*{f}:\s+(\d+)', body, re.M)
        if mm:
            vals[f] = int(mm.group(1))
    # /dev/wsys/windows: one "<wid> <title>" line per live decorated window.
    wids = len([l for l in win.splitlines()
                if re.match(r'^\s*\d+\s+\S', l)])
    samples.append((label, vals, wids))

closed_s = [(l, v, w) for (l, v, w) in samples if l.endswith('closed')]
open_s = [(l, v, w) for (l, v, w) in samples if l.endswith('open')]

with open(series_path, 'w') as f:
    f.write("sample\t" + "\t".join(FIELDS) + "\tliveWids\n")
    for l, v, w in samples:
        f.write(l + "\t" + "\t".join(str(v.get(k, -1)) for k in FIELDS)
                + f"\t{w}\n")

def slope(ys):
    """Least-squares slope of ys against index (units: y per cycle)."""
    n = len(ys)
    if n < 2:
        return 0.0
    mx = (n - 1) / 2.0
    my = sum(ys) / n
    num = sum((i - mx) * (y - my) for i, y in enumerate(ys))
    den = sum((i - mx) ** 2 for i in range(n))
    return num / den if den else 0.0

print(f"cycles={cycles} soak_seconds={soak_s} "
      f"launched={launched} closed={closed} samples={len(samples)}")
print()

if len(closed_s) < 3:
    print("VERDICT: INCONCLUSIVE — fewer than 3 CLOSED samples parsed; "
          "the guest never produced enough /proc/meminfo output.")
    sys.exit(0)

print("=== CLOSED-state series (apps launched AND closed; this is the one "
      "that answers 'does closing recover the RAM?') ===")
hdr = ["sample", "MemFree", "MemUsed", "PagesInUse", "VmaNodesLive",
       "KmallocLive", "TasksLive", "wids"]
print("  " + "  ".join(f"{h:>14}" for h in hdr))
for l, v, w in closed_s:
    row = [l, v.get('MemFree', -1), v.get('MemUsed', -1),
           v.get('PagesInUse', -1), v.get('VmaNodesLive', -1),
           v.get('KmallocLive', -1), v.get('TasksLive', -1), w]
    print("  " + "  ".join(f"{str(x):>14}" for x in row))
print()

def report(name, key, unit, per_cycle_tol=None, invert=False):
    ys = [v.get(key) for _, v, _ in closed_s if key in v]
    if len(ys) < 3:
        print(f"  {name:<16} (not reported by this kernel)")
        return None
    d = ys[-1] - ys[0]
    s = slope(ys)
    # For MemFree a NEGATIVE slope is a leak; for the *Live counters a
    # POSITIVE slope is a leak. `invert` normalises the sign so "leak" is
    # always the bad direction.
    lk = -s if not invert else s
    flag = ""
    if per_cycle_tol is not None:
        flag = "  <-- LEAK" if lk > per_cycle_tol else "  ok"
    print(f"  {name:<16} first={ys[0]:<12} last={ys[-1]:<12} "
          f"drift={d:+d} {unit:<4} slope={s:+.1f} {unit}/cycle{flag}")
    return lk

print("=== TRENDS across the CLOSED series ===")
leak_memfree = report("MemFree", "MemFree", "kB", per_cycle_tol=tol_kb)
report("MemUsed", "MemUsed", "kB")
leak_pages = report("PagesInUse", "PagesInUse", "pg", per_cycle_tol=1.0,
                    invert=True)
leak_vma = report("VmaNodesLive", "VmaNodesLive", "n", per_cycle_tol=0.5,
                  invert=True)
leak_kmalloc = report("KmallocLive", "KmallocLive", "n", per_cycle_tol=2.0,
                      invert=True)
leak_tasks = report("TasksLive", "TasksLive", "n", per_cycle_tol=0.25,
                    invert=True)
wids = [w for _, _, w in closed_s]
print(f"  {'liveWids':<16} first={wids[0]:<12} last={wids[-1]:<12} "
      f"max={max(wids)} of 32 slots  slope={slope(wids):+.2f} /cycle"
      + ("  <-- WID LEAK" if slope(wids) > 0.1 else "  ok"))
print()

if open_s and closed_s:
    # Recovery ratio: of the memory an app set consumes while open, how much
    # comes back when it is closed? 1.0 = perfect recovery.
    rec = []
    for i, (_, ov, _) in enumerate(open_s):
        if i + 1 >= len(closed_s):
            break
        base = closed_s[i][1].get('MemFree')
        after = closed_s[i + 1][1].get('MemFree')
        opened = ov.get('MemFree')
        if None in (base, after, opened):
            continue
        used = base - opened            # kB the open apps took
        back = after - opened           # kB returned by closing them
        if used > 0:
            rec.append(back / used)
    if rec:
        print(f"=== RECOVERY RATIO (MemFree returned / MemFree consumed) ===")
        print(f"  samples={len(rec)}  mean={sum(rec)/len(rec):.4f}  "
              f"min={min(rec):.4f}  max={max(rec):.4f}   (1.0 = perfect)")
        print()

leaks = [(n, v) for n, v in [
    ("MemFree", (leak_memfree, tol_kb)),
    ("PagesInUse", (leak_pages, 1.0)),
    ("VmaNodesLive", (leak_vma, 0.5)),
    ("KmallocLive", (leak_kmalloc, 2.0)),
    ("TasksLive", (leak_tasks, 0.25)),
] if v[0] is not None and v[0] > v[1]]

if leaks:
    print("VERDICT: LEAK — the following counters drift in the bad direction "
          "faster than tolerance across CLOSED samples:")
    for n, (v, t) in leaks:
        print(f"  {n}: {v:+.2f}/cycle (tolerance {t})")
else:
    print("VERDICT: NO LEAK DETECTED — every CLOSED-state counter is flat "
          "within tolerance; closing apps recovers the RAM.")
PY

cat "$SUMMARY"

echo "$TAG --------------------------------------------------------------"
echo "$TAG cycles run     : $CYCLES_RUN over ${SOAK_SECONDS}s"
echo "$TAG apps launched  : $launched_total   closed: $closed_total"
echo "$TAG windows mapped : $(mapped_count)"
echo "$TAG code=143 exits : $(grep -ac 'exited (code=143)' "$LOG")"
echo "$TAG table-full hits: $(grep -ac 'newwindow: table full' "$LOG")"
echo "$TAG artifacts      : $OUT_DIR"
grep -q "VERDICT: LEAK" "$SUMMARY" && fail=1
[ "$fail" -ne 0 ] && { echo "$TAG OVERALL FAIL"; exit 1; }
echo "$TAG OVERALL PASS"
