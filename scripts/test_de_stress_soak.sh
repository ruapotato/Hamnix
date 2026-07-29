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
#   * an UNATTRIBUTABLE `exited (code=143)`   (a process nothing noted took a
#                                              SIGTERM — see the accounting
#                                              block further down)
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
installer_img_or_verdict "$INSTALLER_IMG" "$TAG"

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

# ALLOCATION TRACKING (opt-in). HAMNIX_TRACK_ALLOCS=1 arms the page
# allocator's per-frame call-site tagger (mm/page_alloc.ad) right here —
# AFTER boot has settled, so boot-time allocations land in the UNKNOWN
# bucket and drain out instead of polluting every site's baseline. Every
# subsequent `sample` then carries PgSite<N>: <live> <allocs> <frees>
# lines, and scripts/leakprobe_slopes.py slopes them per site. This is the
# whole point of the tracker being first-class: a leak hunt now starts with
# one env var instead of a day of hand-rolled instrumentation.
#   HAMNIX_TRACK_ALLOCS=full  also records a per-frame tag word (the
#   faulting VA), readable via `echo 'track dump' > /proc/meminfo`.
case "${HAMNIX_TRACK_ALLOCS:-0}" in
    1|on)   printf "echo 'track on' > /proc/meminfo\n"   >&3; sleep 2 ;;
    full)   printf "echo 'track full' > /proc/meminfo\n" >&3; sleep 2 ;;
esac

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

# ======================================================================
# UNEXPECTED-SIGTERM WATCH — pid ATTRIBUTION, not a count
# ======================================================================
# We close apps with the Plan 9 terminate note and code=143 IS that note's
# normal exit status, so a raw `code=143` count is 100% false positives here.
#
# THE COUNT-BASED CHECK THAT USED TO LIVE HERE WAS WRONG (2026-07-25).
# It asserted "every terminate note we issue is entitled to exactly ONE 143,
# so total143 > notes_issued means something else took a SIGTERM". That
# invariant died the day /bin/kill started going through lib/p9.ad's
# p9_note_tree(), which notes a pid AND ITS ATTACHED DESCENDANTS. One note to
# hamtermscene legitimately produces TWO 143s: the scene AND the
# /bin/hamsh it spawned for its terminal. The old check therefore cried wolf
# once per hamtermscene close (27 times in a 61-cycle run) and, worse,
# re-baselined itself each time — so it ALSO masked real events in between.
#
# THE PREMISE OF THE OLD COMMENT WAS ALSO FALSE. It claimed a pid SET can't
# work because "pids RECYCLE". They do not: kernel/sched/core.ad allocates
# from a monotonically increasing `next_pid` (uint64) and NEVER reuses a
# number. A pid identifies a process for the whole life of the boot, which is
# exactly what makes set-based attribution sound — and it is also why
# p9_note_tree's ppid match cannot alias a recycled parent.
#
# WHAT WE CHECK INSTEAD: every code=143 exit must be ATTRIBUTABLE, i.e. its
# pid is either (i) a pid we handed to /bin/kill, or (ii) a descendant of one
# via the parent map we snapshot from /proc immediately before each close
# loop. Anything else is a process nobody noted taking a SIGTERM. On top of
# that, the SYSTEM cohort — every pid alive before the first app launch
# (hamUId, hamdesktop, hampanel, the driving hamsh, init...) — must never
# take a note at all; that is the failure mode this gate actually exists to
# catch, and it is now asserted directly.
KILLED_F="$OUT_DIR/killed_pids.txt"    # every pid we handed to /bin/kill
PARENT_F="$OUT_DIR/parent_map.txt"     # "<pid> <ppid>", accumulated
SYSPIDS_F="$OUT_DIR/system_pids.txt"   # pids alive before the first launch
: > "$KILLED_F"; : > "$PARENT_F"; : > "$SYSPIDS_F"

# guest_capture <shell-command> — run a SHORT command in the guest and echo
# its output. The command is bracketed by unique markers.
#
# The READINESS TEST IS THE EXTRACTION ITSELF, not a grep for the closing
# marker. hamsh redraws the whole command line after every keystroke, so the
# log holds a line containing BOTH markers before the command has even run —
# an unanchored `grep -q MARKER_E` therefore succeeds INSTANTLY, on the echo,
# and we would parse a region that does not exist yet. (This is the same trap
# the summary parser documents; it bites twice as hard here because the
# result is consumed immediately rather than after the run.) So: poll the
# ^-anchored two-marker match and only stop when it yields a real region.
# Commands must stay short — every character costs a redrawn log line.
#
# The marker serial lives in a FILE, not a shell variable. This function is
# called from command substitution (`x=$(guest_live_pids)`), which runs it in
# a SUBSHELL — a `cap_n=$((cap_n+1))` would be discarded on return, every
# capture would reuse marker 1, and the non-greedy `_B(.*?)_E` match would
# hand back the FIRST such region in the log forever. That is not
# hypothetical: it silently pinned every cycle's process listing to the
# pre-launch baseline, so no app pid was ever seen and every descendant
# looked unattributed.
CAPN_F="$OUT_DIR/.capture_serial"
echo 0 > "$CAPN_F"
guest_capture() {
    local n
    n=$(( $(cat "$CAPN_F") + 1 ))
    echo "$n" > "$CAPN_F"
    local m="SOAKCAP${n}" out d
    printf 'echo %s_B; %s; echo %s_E\n' "$m" "$1" "$m" >&3
    d=$(( SECONDS + 30 ))
    while [ "$SECONDS" -lt "$d" ]; do
        if out=$(python3 - "$LOG" "$m" <<'PY'
import re, sys
t = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').replace('\r', '\n')
m = re.search(r'^%s_B\s*$(.*?)^%s_E\s*$' % (sys.argv[2], sys.argv[2]),
              t, re.S | re.M)
if m is None or not m.group(1).strip():
    sys.exit(1)
sys.stdout.write(m.group(1))
PY
        ); then
            printf '%s' "$out"
            return 0
        fi
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    echo "$TAG WARN: guest capture $m timed out ($1)" >&2
    return 1
}

# guest_live_pids — the live pid set, one read of /proc/tasks
# ("PID\tSTATE\tCOMM\tUTIME\tSTIME", fs/procfs.ad::render_tasks).
guest_live_pids() {
    guest_capture "cat /proc/tasks" \
        | awk -F'\t' '$1 ~ /^[0-9]+$/ { print $1 }' | sort -un | tr '\n' ' '
}

# snapshot_parents <pids...> — append "<pid> <ppid>" to PARENT_F for each
# given pid, from ONE `cat /proc/<p>/stat ...`. /proc/<pid>/stat is the
# Linux-shape one-liner devproc renders: "pid (comm) state ppid ...", and
# comm can hold spaces and parens, so ppid is found past the LAST ')'.
snapshot_parents() {
    local args="" p
    for p in "$@"; do args="$args /proc/$p/stat"; done
    [ -n "$args" ] || return 0
    guest_capture "cat$args" | python3 -c '
import re, sys
for l in sys.stdin.read().split("\n"):
    l = l.strip()
    if not re.match(r"^\d+ \(", l):
        continue
    r = l.rfind(")")
    f = l[r + 1:].split()
    if len(f) >= 2 and f[1].isdigit():
        print(l.split()[0], f[1])
' >> "$PARENT_F"
}

# audit_143 <cycle> — every code=143 exit in the log so far must be
# attributable to a note WE posted (directly or through p9_note_tree's
# descendant walk). Prints the offending pids; empty output means sound.
audit_143() {
    python3 - "$LOG" "$KILLED_F" "$PARENT_F" "$SYSPIDS_F" <<'PY'
import re, sys
log, killed_f, parent_f, sys_f = sys.argv[1:5]
text = open(log, 'rb').read().decode('utf-8', 'replace').replace('\r', '\n')
# NOT ^-anchored: an exit line can be emitted mid-prompt ("hamsh$ task: pid
# 121 exited (code=143)"), and dropping those would hide real events.
got = [int(m.group(1)) for m in
       re.finditer(r'task: pid (\d+) exited \(code=143\)', text)]
killed = {int(x) for x in open(killed_f).read().split()}
syspids = {int(x) for x in open(sys_f).read().split()}
parent = {}
for line in open(parent_f):
    p = line.split()
    if len(p) == 2:
        parent[int(p[0])] = int(p[1])
# Attributable = killed, closed transitively downwards through the parent
# map (a child of an attributable pid is attributable: that is exactly what
# p9_note_tree walks).
ok = set(killed)
changed = True
while changed:
    changed = False
    for c, pp in parent.items():
        if c not in ok and pp in ok:
            ok.add(c)
            changed = True
bad = sorted({p for p in got if p not in ok})
sysbad = sorted({p for p in got if p in syspids})
if sysbad:
    print("SYSTEM " + " ".join(str(x) for x in sysbad))
if bad:
    print("UNATTRIBUTED " + " ".join(str(x) for x in bad))
PY
}

# wait_exit <pid> <timeout> — wait for a NEW "task: pid <pid> exited" line.
# Counts rather than greps for presence: cheap insurance against a stale
# match, and it costs nothing.
wait_exit() {
    local pid="$1" base="$2" deadline=$(( SECONDS + $3 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ "$(grep -ac "task: pid $pid exited" "$LOG")" -gt "$base" ] && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

# The app mix. Spans the office suite, the scene apps, the browser and a
# terminal — deliberately heterogeneous so a leak in one app's teardown does
# not hide behind another's. hambrowse gets --demo so it renders a
# deterministic offline page instead of waiting on a network that isn't there.
# SOAK_APPS overrides the pool, which is how you turn this gate into a
# BISECTION tool: drop one app and re-run to see which counter's slope
# collapses. That is how hamtermscene was identified as the dominant leaker
# (its orphaned child shell) — see docs/de_stress_soak.md.
read -r -a APP_POOL <<< "${SOAK_APPS:-hamwrite hamsheet hamslides hamfmscene hammonscene hamaudioscene hamcalcscene hambrowse hamtermscene}"
APP_ARGS_hambrowse="--demo"

snapshot 000_idle
sample c0closed || say_fail "baseline sample timed out"

# The SYSTEM cohort: everything alive before a single app has been launched.
# None of these may ever take a terminate note.
guest_live_pids | tr ' ' '\n' | grep -E '^[0-9]+$' > "$SYSPIDS_F"
if [ ! -s "$SYSPIDS_F" ]; then
    say_fail "could not read /proc/tasks — the SIGTERM audit would be blind"
else
    echo "$TAG system pids (never noteable): $(tr '\n' ' ' < "$SYSPIDS_F")"
fi

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

    # ---- snapshot parentage BEFORE closing ---------------------------
    # p9_note_tree walks /proc for ppid == target, so the only moment the
    # descendant cohort is knowable is while the apps are still alive. Only
    # the NON-system pids are interesting (everything else predates the
    # first launch and can never be a legitimate note target), which keeps
    # this to one short `cat` of ~5 stat files.
    new_pids=$(guest_live_pids | tr ' ' '\n' | grep -E '^[0-9]+$' \
               | grep -vxF -f "$SYSPIDS_F" | tr '\n' ' ')
    if [ -z "$new_pids" ]; then
        say_fail "cycle $c: /proc/tasks showed no non-system pids while ${APPS_PER_CYCLE} apps are open — the SIGTERM audit is blind this cycle"
    fi
    # shellcheck disable=SC2086
    snapshot_parents $new_pids

    # ---- close a bunch of apps ---------------------------------------
    for pid in $open_pids; do
        exit_base=$(grep -ac "task: pid $pid exited" "$LOG")
        echo "$pid" >> "$KILLED_F"
        printf '/bin/kill %s\n' "$pid" >&3
        if ! wait_exit "$pid" "$exit_base" 20; then
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
    audit=$(audit_143)
    if [ -n "$audit" ]; then
        while IFS= read -r a; do
            case "$a" in
              SYSTEM*)
                say_fail "cycle $c: a SYSTEM process took a terminate note — ${a#SYSTEM } (nothing may note the DE/shell cohort)"
                stop=1 ;;
              UNATTRIBUTED*)
                # NOT fatal to the run: fail=1 is already set, and letting
                # the soak continue still yields the leak series.
                say_fail "cycle $c: code=143 exit(s) attributable to NO note we posted (not a kill target, not a descendant of one): ${a#UNATTRIBUTED }" ;;
            esac
        done <<< "$audit"
        # Retire the offenders into the killed set so one event is reported
        # exactly once instead of on every remaining cycle.
        printf '%s\n' "$audit" | sed 's/^[A-Z]* //' | tr ' ' '\n' >> "$KILLED_F"
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
text = open(log, 'rb').read().decode('utf-8', 'replace').replace('\r', '\n')

# Split the log into the marked sample regions.
#
# The markers MUST be anchored to the start of a line. hamsh echoes back the
# command it is being fed one character at a time, redrawing the whole line
# after each keystroke, so the raw log contains a line reading
#   hamsh$ echo SOAKSMP_c0closed_B; cat /proc/meminfo; ... echo SOAKSMP_c0closed_E
# — i.e. BOTH markers, in order, on a single line, before the command has run.
# An unanchored `SOAKSMP_(\w+)_B(.*?)SOAKSMP_\1_E` matches THAT echo first and
# captures an empty region, silently yielding zero parsed fields for every
# sample. Anchoring to ^...$ skips the echo and finds the real output.
FIELDS = ["MemTotal", "MemFree", "MemAvailable", "MemUsed", "PagesInUse",
          "PagesFreedTotal", "VmaNodesLive", "KmallocLive", "TasksLive",
          "TasksSpawned", "TasksReaped"]
samples = []                       # (label, {field: int}, live_wids)
for m in re.finditer(r'^SOAKSMP_(\w+)_B\s*$(.*?)^SOAKSMP_\1_E\s*$',
                     text, re.S | re.M):
    label, body = m.group(1), m.group(2)
    win = ''
    wm = re.search(r'^SOAKWIN_\w+_B\s*$(.*)$', body, re.S | re.M)
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


# ======================================================================
# WHY A PLAIN LEAST-SQUARES SLOPE IS THE WRONG VERDICT STATISTIC HERE
# ======================================================================
# The CLOSED series is not "flat + noise". It has two NON-LEAK structures
# that a least-squares fit smears into a per-cycle rate, inflating the
# reported leak by an order of magnitude:
#
#  (1) A STEP. The window system claims its per-window layer framebuffer /
#      backbuffer in 4 MiB blocks. Several can be claimed in one cycle and
#      then held for the rest of the run — a ONE-TIME plateau shift of a
#      few thousand pages, not a recurring cost. Least-squares spreads that
#      single jump across EVERY cycle (a 4115-page step at cycle 30 of 60
#      alone contributes ~+68 pg/cycle to the fit).
#
#  (2) A PERIOD-2 SAWTOOTH. Whether a CLOSED sample lands while one 4 MiB
#      block is still held depends on where the sample falls relative to
#      the compositor's own release, so alternate cycles differ by ~1040
#      pages. That is a SAMPLING PHASE artifact: the same instant measured
#      one beat later reads the other value.
#
# This is NOT a reason to widen the tolerance — a real per-cycle leak of
# 1 page/cycle must still fail. It is a reason to measure the STEADY-STATE
# rate rather than a rate contaminated by a step and a phase artifact:
#
#   * smooth2() averages adjacent samples, which EXACTLY cancels a period-2
#     square wave of any amplitude while leaving a linear trend untouched;
#   * steps are then detected as cycle-to-cycle jumps far outside the
#     series' own robust scale (median |delta|), and the slope is fitted on
#     the LONGEST STEP-FREE SEGMENT — the steady state;
#   * a Theil-Sen slope (median of all pairwise slopes) over the whole
#     series is reported alongside as an independent robust cross-check.
#
# Steps are NOT swept under the rug: every one is printed with its cycle
# and size, and RECURRING steps in the bad direction (>= 3) fail the gate
# on their own — a leak that arrives in 4 MiB chunks is still a leak.
STEP_RECUR_FAIL = 3


def _median(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return 0.0
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def med3(ys):
    """Median-of-3 filter: removes ISOLATED spikes (a CLOSED sample that
    happened to land while one app had not finished exiting) without
    touching a trend or a genuine step. Endpoints pass through."""
    if len(ys) < 3:
        return [float(y) for y in ys]
    out = [float(ys[0])]
    for i in range(1, len(ys) - 1):
        out.append(float(sorted(ys[i - 1:i + 2])[1]))
    out.append(float(ys[-1]))
    return out


def smooth2(ys):
    """Pairwise means — cancels a period-2 sawtooth, preserves a trend."""
    if len(ys) < 2:
        return [float(y) for y in ys]
    return [(ys[i] + ys[i + 1]) / 2.0 for i in range(len(ys) - 1)]


def theil_sen(ys):
    """Median of all pairwise slopes: a single step cannot dominate it."""
    n = len(ys)
    if n < 2:
        return 0.0
    return _median([(ys[j] - ys[i]) / float(j - i)
                    for i in range(n) for j in range(i + 1, n)])


def steady(ys):
    """(steady_slope, steps, (lo, hi)) — the per-cycle rate of the STEADY
    STATE, with period-2 phase artifacts cancelled, isolated spikes removed
    and one-time plateau steps excised.

    `steps` is [(index_into_ys, size), ...]; (lo, hi) is the segment fitted.

    VALIDATED against synthetic series before it was trusted (see the block
    comment above): flat + sawtooth + one 4115 step -> +0.000/cycle where a
    least-squares fit reports +103.8; a REAL 1.0/cycle leak buried under the
    same sawtooth and step -> +1.000; a real 13/cycle leak -> +13.000; and
    the pre-fix desktop series -> +25.8 pg/cycle, independently reproducing
    the +26 pg/cycle that pass measured by hand. It does not hide leaks; it
    removes two structures that are provably not per-cycle costs."""
    sm = smooth2(med3(ys))
    # med3 passes the endpoints through unfiltered, so the first and last
    # smoothed points can carry a spike the interior does not. Drop them.
    lo, hi = 1, len(sm) - 1
    if hi - lo < 4:
        lo, hi = 0, len(sm)
    sm = sm[lo:hi]
    d = [sm[i + 1] - sm[i] for i in range(len(sm) - 1)]
    if len(d) < 3:
        return slope(sm), [], (lo, lo + len(sm))
    scale = _median([abs(x) for x in d])
    # A floor keeps a perfectly flat series from calling ordinary jitter a
    # step (scale == 0 would make every non-zero delta infinitely large).
    thr = max(10.0 * scale, 0.01 * (max(sm) - min(sm)) + 1.0)
    raw = [i for i in range(len(d)) if abs(d[i]) > thr]
    # Smoothing spreads ONE step across a few adjacent deltas; coalesce a
    # run of near-adjacent flagged deltas into a single step EVENT so a
    # solitary plateau shift is never miscounted as "recurring".
    ev = []
    for i in raw:
        if ev and i - ev[-1][-1] <= 3:
            ev[-1].append(i)
        else:
            ev.append([i])
    steps = [(lo + g[0] + 1, sum(d[i] for i in g)) for g in ev]
    # Fit on the LONGEST step-free run of the smoothed series.
    bounds = []
    prev = 0
    for g in ev:
        if g[0] + 1 - prev >= 2:
            bounds.append((prev, g[0] + 1))
        prev = g[-1] + 1
    bounds.append((prev, len(sm)))
    best = max(bounds, key=lambda ab: ab[1] - ab[0])
    return slope(sm[best[0]:best[1]]), steps, (lo + best[0], lo + best[1])

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

STEP_NOTES = []


def report(name, key, unit, per_cycle_tol=None, invert=False):
    ys = [v.get(key) for _, v, _ in closed_s if key in v]
    labels = [l for l, v, _ in closed_s if key in v]
    if len(ys) < 3:
        print(f"  {name:<16} (not reported by this kernel)")
        return None
    d = ys[-1] - ys[0]
    s = slope(ys)                       # raw least squares (reference only)
    ts = theil_sen(ys)                  # robust cross-check
    st, steps, seg = steady(ys)         # THE VERDICT STATISTIC
    # For MemFree a NEGATIVE slope is a leak; for the *Live counters a
    # POSITIVE slope is a leak. `invert` normalises the sign so "leak" is
    # always the bad direction.
    sign = 1.0 if invert else -1.0
    lk = sign * st
    # A step only counts toward the RECURRENCE test if it is comparable in
    # size to the largest one seen. Smoothing leaves small residues behind a
    # big plateau shift; those are the same event, not new ones.
    big = max([abs(x[1]) for x in steps], default=0.0) * 0.5
    bad_steps = [x for x in steps if sign * x[1] > 0 and abs(x[1]) >= big]
    flag = ""
    if per_cycle_tol is not None:
        if lk > per_cycle_tol:
            flag = "  <-- LEAK"
        elif len(bad_steps) >= STEP_RECUR_FAIL:
            flag = "  <-- LEAK (recurring steps)"
        else:
            flag = "  ok"
    print(f"  {name:<16} first={ys[0]:<12} last={ys[-1]:<12} "
          f"drift={d:+d} {unit}")
    print(f"  {'':<16}   steady={st:+.2f} {unit}/cycle over cycles "
          f"[{labels[seg[0]]}..{labels[min(seg[1], len(labels) - 1)]}]"
          f"  (raw least-squares={s:+.1f}, Theil-Sen={ts:+.2f}){flag}")
    if steps:
        for i, dv in steps:
            lab = labels[i] if i < len(labels) else f"idx{i}"
            STEP_NOTES.append(f"{name} @ {lab}: {dv:+.0f} {unit} step")
        print(f"  {'':<16}   {len(steps)} step(s) excluded from the steady "
              f"fit (listed below); {len(bad_steps)} in the leak direction")
    if per_cycle_tol is not None and len(bad_steps) >= STEP_RECUR_FAIL:
        # Recurring chunky growth IS a leak — surface it as one.
        return max(lk, per_cycle_tol * 1.0001)
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

if STEP_NOTES:
    print("=== STEPS EXCLUDED FROM THE STEADY-STATE FIT ===")
    print("  (one-time plateau shifts — typically a 4 MiB wsys layer block")
    print("   claimed and then HELD. Each is reported here rather than")
    print("   smeared across every cycle by a least-squares fit. Three or")
    print("   more in the leak direction fail the gate on their own.)")
    for n in STEP_NOTES:
        print(f"  {n}")
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
echo "$TAG code=143 exits : $(grep -ao 'exited (code=143)' "$LOG" | wc -l) (notes posted: $(wc -l < "$KILLED_F"); the surplus is p9_note_tree's attached descendants)"
echo "$TAG SIGTERM audit  : $(a=$(audit_143); [ -z "$a" ] && echo 'CLEAN — every code=143 attributable to a note we posted' || echo "$a")"
echo "$TAG table-full hits: $(grep -ac 'newwindow: table full' "$LOG")"
echo "$TAG artifacts      : $OUT_DIR"
grep -q "VERDICT: LEAK" "$SUMMARY" && fail=1
[ "$fail" -ne 0 ] && { echo "$TAG OVERALL FAIL"; exit 1; }
echo "$TAG OVERALL PASS"
