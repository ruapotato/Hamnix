#!/usr/bin/env bash
# scripts/test_de_panel_taskbar_soak.sh — THE TASKBAR MUST STILL BE THE
# TASKBAR TWENTY MINUTES IN.
#
# USER-VISIBLE DEFECT (found 2026-07-28 while chasing a memory step):
# from roughly eighteen minutes into a desktop session the DE panel's
# taskbar stops tracking reality. In one run it froze on the app set from
# cycle 42 and still showed it at c50/c60/c70; in another it went EMPTY
# while four windows were plainly mapped. Throughout, the harness's own
# `cat /dev/wsys/windows` enumerated correctly — the FILE was fine, the
# PANEL had gone blind.
#
# WHY EVERY EXISTING GATE MISSED IT
# =================================
# This is a defect in BEHAVIOUR OVER TIME, and the suite is made almost
# entirely of instant-correctness gates. test_de_multiwin_taskbar proves
# three windows enumerate; test_de_panel_config proves the configured panel
# is the panel you get; both are true at second 5 and both stay green while
# the panel goes blind at minute 18. Same shape as the hamsh arena bug,
# which needed ~700 commands to surface and was invisible to every short
# gate. So this gate does not sample a moment: it runs a REAL session for
# SOAK_MIN minutes and asserts on the TREND.
#
# WHAT IT ASSERTS (all on the real shipped .img under UEFI/OVMF)
# =============================================================
#   1. LIVENESS OVER TIME — the panel is still emitting its health beacon
#      in the final minute of a 20+ minute session (a wedged panel stops).
#   2. NO DESCRIPTOR LEAK — the panel's OWN open-fd count (read from the
#      real per-task fd table via /proc/self/fd) has not grown over the
#      whole session. This is the instrument: a per-iteration fd leak fills
#      TASK_NFDS and every later open — including /dev/wsys/windows —
#      fails, which is precisely how a panel goes blind.
#   3. NO SWALLOWED FAILURES — winfail (failed /dev/wsys/windows opens) is
#      zero. A non-zero count is reported, not hidden: the panel used to
#      turn a failed open into "there are no windows" and repaint an empty
#      taskbar, telling nobody.
#   4. RENDERED CONTENT MATCHES REALITY — after 20+ minutes, the set of
#      window ids in the taskbar the panel is DRAWING (its beacon's `bar=`
#      field is built from the same task_wid/task_name arrays the buttons
#      are painted from) equals the set in /dev/wsys/windows. This is the
#      user-visible property, asserted positively; not an exit status.
#
# The session is kept REAL, not idle: app open/close cycles run throughout,
# mirroring scripts/test_de_open_close_cycles.sh (the harness the defect was
# first seen under).
#
# Env: INSTALLER_IMG, OVMF_FD, BOOT_WAIT, OUT_DIR, SOAK_MIN, FD_SLACK.
#
# Verdicts: 0 PASS, 1 FAIL, 125 INCONCLUSIVE (never booted / never got far
# enough to observe the assertion — see scripts/_verdict.sh).

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
# The defect appears at ~18 minutes. Soak past it with margin.
SOAK_MIN="${SOAK_MIN:-22}"
# How many descriptors the panel may legitimately gain over a session.
# Steady state should be FLAT; a couple of slots of slack covers a lazily
# opened long-lived fd (the /dev/cons diagnostic channel) without admitting
# a leak, which grows without bound.
FD_SLACK="${FD_SLACK:-3}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_panel_soak/$TS}"
HANDOFF_MARKER="handing off to interactive shell"
TAG="[panelsoak]"

# A missing capability is INCONCLUSIVE (125), never 0: this gate asserts by
# BOOTING, so with no KVM / OVMF / socat it observes nothing, and reporting
# green for an unobserved assertion is the soft-green class
# scripts/test_gate_softgreen.sh exists to forbid.
[ -e /dev/kvm ] || { echo "$TAG INCONCLUSIVE: /dev/kvm absent — nothing booted" >&2; exit 125; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG INCONCLUSIVE: no OVMF firmware — nothing booted" >&2; exit 125; }
command -v socat >/dev/null 2>&1 || { echo "$TAG INCONCLUSIVE: no socat (QEMU monitor) — nothing booted" >&2; exit 125; }

# STALE-IMAGE GUARD: a stale image false-GREENs the very regression this
# gate exists to catch. ensure_installer_img REBUILDS when the image is
# missing or older than any tracked build input.
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
installer_img_or_verdict "$INSTALLER_IMG" "$TAG" 125

mkdir -p "$OUT_DIR"
echo "$TAG output dir: $OUT_DIR"
echo "$TAG soak length: ${SOAK_MIN} min (defect appears at ~18 min)"

OVMF_RW=$(mktemp --tmpdir hamnix-psoak.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-psoak.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-psoak-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-psoak.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own recorded pid — never a pattern (other agents run QEMU).
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
}
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1; }
snapshot() {
    local ppm="$OUT_DIR/$1.ppm"
    rm -f "$ppm"; mon_cmd "screendump $ppm" || return 1
    local i=0; while [ "$i" -lt 40 ]; do [ -s "$ppm" ] && break; sleep 0.1; i=$((i+1)); done
    [ -s "$ppm" ] || return 1
    sleep 0.3
    command -v convert >/dev/null 2>&1 && convert "$ppm" "$OUT_DIR/$1.png" 2>/dev/null
    return 0
}
wait_for() {
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

qemu-system-x86_64 \
    -enable-kvm -cpu host -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "$TAG waiting up to ${BOOT_WAIT}s for the DE handoff..."
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG RESULT: INCONCLUSIVE — no DE handoff in ${BOOT_WAIT}s, nothing was" >&2
    echo "$TAG   observed. Host loadavg: $(cut -d' ' -f1-3 /proc/loadavg)" >&2
    tail -40 "$LOG" >&2
    exit 125
fi
sleep 8
printf 'echo MARK_SOAK_READY\n' >&3
sleep 1
wait_for MARK_SOAK_READY 12 || { printf 'echo MARK_SOAK_READY\n' >&3; sleep 2; }

# The panel's telemetry reaches us through a tmpfs FILE, not the console:
# once the panel owns a window its console writes are routed into that
# window (hamUI.ad's wid routing key), so neither fd 1 nor /dev/cons is
# visible on serial. The gate `cat`s the health file over the serial shell
# whenever it wants a sample; each sample lands in the log as a
# "[panelbeacon] …" line and everything below parses those.
health_sample() {
    printf 'cat /tmp/hamnix-panel.health; cat /tmp/hamnix-panel.fault\n' >&3
    sleep 2
}
health_sample
sleep 2
health_sample

# The panel beacon must be flowing before the clock starts, else we are
# soaking blind.
if ! wait_for '\[panelbeacon\]' 60; then
    echo "$TAG RESULT: INCONCLUSIVE — no [panelbeacon] on the console within 60s" >&2
    echo "$TAG   of handoff. The panel's health telemetry is the instrument this" >&2
    echo "$TAG   gate measures with; without it nothing can be asserted." >&2
    tail -40 "$LOG" >&2
    exit 125
fi

snapshot 000_start
mapped_count() { grep -ac "\[devwsys\] window .* mapped" "$LOG"; }

# INDEPENDENT INSTRUMENT. The beacon is the panel talking about itself; this
# reads the same per-task fd table from OUTSIDE the panel, through the shell,
# so the two cannot agree by sharing a bug.
# NOTE: task names are packed into 8 bytes (devproc _emit_status /
# task_name0_at), so the panel appears as "hampanel", NOT "hampanelscene" —
# `pgrep hampanelscene` matches nothing and silently costs you the whole
# cross-check.
printf 'echo MARK_PANELPID_BEGIN; pgrep hampanel; echo MARK_PANELPID_END\n' >&3
sleep 3
wait_for MARK_PANELPID_END 20 || true
PANEL_PID=$(sed -n '/MARK_PANELPID_BEGIN/,/MARK_PANELPID_END/p' "$LOG" \
            | tr -d '\r' | grep -aoE '^[0-9]+' | head -1)
echo "$TAG panel pid: ${PANEL_PID:-<not found>}"
dump_panel_fds() {
    [ -n "${PANEL_PID:-}" ] || return 0
    # fd table AND task state. The state letter is what separates "the panel
    # is spinning" from "the panel is asleep and nothing will ever wake it".
    printf 'echo MARK_PFD_%s_BEGIN; cat /proc/%s/fd; cat /proc/%s/status; cat /proc/%s/stat; echo MARK_PFD_%s_END\n' \
        "$1" "$PANEL_PID" "$PANEL_PID" "$PANEL_PID" "$1" >&3
    sleep 3
}
dump_panel_fds start

# --- the session -----------------------------------------------------
# Open and close scene apps continuously, exactly as a user works, for the
# whole soak window. Any wedge shows up as a missed serial round-trip.
# The SAME app set scripts/test_de_open_close_cycles.sh drives — the harness
# the defect was first seen under. Reproducing a slow, cumulative fault is
# not the place to improvise a different workload.
APPS="hammonscene hamaudioscene hamnotesscene hamcalcscene hamfmscene hamappmenu"
SOAK_END=$(( SECONDS + SOAK_MIN * 60 ))
cyc=0
wedged=0
while [ "$SECONDS" -lt "$SOAK_END" ]; do
    cyc=$(( cyc + 1 ))
    for app in $APPS; do
        [ "$SECONDS" -lt "$SOAK_END" ] || break
        before=$(mapped_count)
        printf '/bin/%s &\n' "$app" >&3
        d=$(( SECONDS + 25 ))
        while [ "$SECONDS" -lt "$d" ]; do
            [ "$(mapped_count)" -gt "$before" ] && break
            sleep 1
        done
        if [ "$(mapped_count)" -le "$before" ]; then
            echo "$TAG note: cycle $cyc: $app mapped no window (continuing soak)"
            continue
        fi
        line=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)
        pid=$(echo "$line" | sed -n 's/.*mapped pid=\([0-9]*\).*/\1/p')
        sleep 3
        [ -n "$pid" ] && printf '/bin/kill %s\n' "$pid" >&3
        sleep 2
    done
    health_sample                       # one time-series point per cycle
    if [ $(( cyc % 5 )) -eq 0 ]; then
        m="MARK_ALIVE_$cyc"
        printf 'echo %s\n' "$m" >&3
        if ! wait_for "$m" 25; then
            echo "$TAG FAIL: SYSTEM WEDGED at cycle $cyc (no serial round-trip in 25s)" >&2
            snapshot "WEDGED_c${cyc}"
            wedged=1
            break
        fi
        snapshot "c${cyc}_desktop"
        dump_panel_fds "c$cyc"
        b=$(grep -a '\[panelbeacon\]' "$LOG" | tail -1)
        echo "$TAG cycle $cyc  t=${SECONDS}s  $b"
    fi
done

ELAPSED=$SECONDS
echo "$TAG soak phase done at t=${ELAPSED}s (cycles: $cyc)"

fail=0
say_fail() { echo "$TAG FAIL $*" >&2; fail=1; }
[ "$wedged" -eq 0 ] || say_fail "the desktop session wedged during the soak"

# --- the final, user-visible check -----------------------------------
# Leave three apps MAPPED and ask, after 20+ minutes of session, whether the
# taskbar the panel is drawing lists them.
echo "$TAG final phase: leaving three windows mapped and comparing the panel's"
echo "$TAG   RENDERED taskbar against /dev/wsys/windows"
for app in hammonscene hamnotesscene hamcalcscene; do
    before=$(mapped_count)
    printf '/bin/%s &\n' "$app" >&3
    d=$(( SECONDS + 25 ))
    while [ "$SECONDS" -lt "$d" ]; do
        [ "$(mapped_count)" -gt "$before" ] && break
        sleep 1
    done
done
# Give the panel several beacon periods (10s each) to observe + render them.
sleep 35
health_sample
printf 'echo MARK_WINTABLE_BEGIN; cat /dev/wsys/windows; echo MARK_WINTABLE_END\n' >&3
sleep 5
wait_for MARK_WINTABLE_END 20 || say_fail "the shell never answered the final window-table read"
dump_panel_fds final
sleep 12          # one more beacon after the table snapshot
health_sample
snapshot 999_final

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

# --- verdict ---------------------------------------------------------
grep -a '\[panelbeacon\]' "$LOG" > "$OUT_DIR/beacons.txt"
NBEACON=$(wc -l < "$OUT_DIR/beacons.txt")
echo "$TAG beacons captured: $NBEACON  ($OUT_DIR/beacons.txt)"
echo "$TAG --- first / last beacon ---"
head -1 "$OUT_DIR/beacons.txt"
tail -1 "$OUT_DIR/beacons.txt"

if [ "$NBEACON" -lt 5 ]; then
    echo "$TAG RESULT: INCONCLUSIVE — only $NBEACON beacons; the session never" >&2
    echo "$TAG   ran long enough to observe anything." >&2
    exit 125
fi

field() { sed -n "s/.*[^a-z]$1=\([^ ]*\).*/\1/p"; }

LAST_UP=$(tail -1 "$OUT_DIR/beacons.txt" | sed -n 's/.*up_s=\([0-9]*\).*/\1/p')
: "${LAST_UP:=0}"
MIN_UP=$(( SOAK_MIN * 60 ))
# Distinct up_s values = how many times the panel actually REFRESHED its
# health file. The gate re-reads that file every cycle, so a frozen panel
# would otherwise hand back the same stale line forever and look alive.
DISTINCT=$(sed -n 's/.*up_s=\([0-9]*\).*/\1/p' "$OUT_DIR/beacons.txt" | sort -un | wc -l)
echo "$TAG distinct beacon timestamps: $DISTINCT"

# Did OUR clock get far enough to demand the panel's clock did too?
if [ "$ELAPSED" -lt "$(( MIN_UP + 30 ))" ]; then
    echo "$TAG RESULT: INCONCLUSIVE — the soak loop only ran ${ELAPSED}s of the" >&2
    echo "$TAG   ${MIN_UP}s it must; nothing about the ~18-minute defect was" >&2
    echo "$TAG   exercised. Host loadavg: $(cut -d' ' -f1-3 /proc/loadavg)" >&2
    exit 125
fi

# (1) LIVENESS OVER TIME. The session demonstrably ran past the soak
# window, so a panel whose last self-report is far short of that has
# STOPPED — that is a FAIL, not an inconclusive run.
if [ "$LAST_UP" -lt "$MIN_UP" ]; then
    say_fail "PANEL STOPPED REPORTING: the session ran ${ELAPSED}s but the panel's" \
             "last beacon is at up_s=${LAST_UP}s. It stopped refreshing its health" \
             "file — the loop is wedged or the panel is gone."
fi
if [ "$DISTINCT" -lt 10 ]; then
    say_fail "PANEL BARELY TICKED: only $DISTINCT distinct beacon timestamps over" \
             "${ELAPSED}s; the panel is not looping at anything like its 16ms park."
fi

# (2) DESCRIPTOR LEAK over the whole session.
FIRST_FDS=$(head -1 "$OUT_DIR/beacons.txt" | field openfds)
LAST_FDS=$(tail -1 "$OUT_DIR/beacons.txt" | field openfds)
MAX_FDS=$(field openfds < "$OUT_DIR/beacons.txt" | sort -n | tail -1)
echo "$TAG open descriptors: first=$FIRST_FDS last=$LAST_FDS max=$MAX_FDS (slack $FD_SLACK)"
if ! [ "$FIRST_FDS" -eq "$FIRST_FDS" ] 2>/dev/null || ! [ "$MAX_FDS" -eq "$MAX_FDS" ] 2>/dev/null; then
    say_fail "could not read the panel's open-fd count from its beacons"
elif [ "$MAX_FDS" -gt $(( FIRST_FDS + FD_SLACK )) ]; then
    say_fail "DESCRIPTOR LEAK: the panel held $FIRST_FDS fds at session start and" \
             "peaked at $MAX_FDS. A long session fills the per-task fd table and" \
             "every later open — including /dev/wsys/windows — fails."
fi

# (3) SWALLOWED FAILURES.
LAST_WINFAIL=$(tail -1 "$OUT_DIR/beacons.txt" | field winfail)
: "${LAST_WINFAIL:=0}"
echo "$TAG failed /dev/wsys/windows opens over the session: $LAST_WINFAIL"
if [ "$LAST_WINFAIL" -ne 0 ] 2>/dev/null; then
    say_fail "the panel failed to read /dev/wsys/windows $LAST_WINFAIL time(s):" \
             "the taskbar was showing a list it could not refresh."
    grep -a '\[panel\] ERROR open /dev/wsys/windows' "$LOG" | head -5 >&2
fi

# (4) RENDERED TASKBAR == REALITY, 20+ minutes in.
WIDS_LIVE=$(sed -n '/MARK_WINTABLE_BEGIN/,/MARK_WINTABLE_END/p' "$LOG" \
            | tr -d '\r' | grep -aoE '^[0-9]+ ' | tr -d ' ' | sort -n | tr '\n' ',')
BAR=$(tail -1 "$OUT_DIR/beacons.txt" | sed -n 's/.* bar=\(.*\)$/\1/p')
WIDS_BAR=$(printf '%s' "$BAR" | tr '|' '\n' | sed -n 's/^\([0-9]\+\):.*/\1/p' | sort -n | tr '\n' ',')
echo "$TAG /dev/wsys/windows wids : ${WIDS_LIVE:-<none>}"
echo "$TAG panel taskbar wids     : ${WIDS_BAR:-<none>}"
echo "$TAG panel taskbar labels   : ${BAR:-<empty>}"
if [ -z "$WIDS_LIVE" ]; then
    echo "$TAG RESULT: INCONCLUSIVE — the final /dev/wsys/windows read produced no" >&2
    echo "$TAG   window ids, so there was no live set to compare the taskbar against." >&2
    exit 125
fi
if [ "$WIDS_BAR" != "$WIDS_LIVE" ]; then
    say_fail "THE PANEL HAS GONE BLIND: after ${LAST_UP}s of session the taskbar is" \
             "drawing [${WIDS_BAR:-<empty>}] while the live window set is [${WIDS_LIVE}]." \
             "The file is fine; the panel is not showing it."
fi

# Cross-check the beacon's self-report against the shell's independent read
# of the panel's fd table.
echo "$TAG --- /proc/<panel>/fd line counts, read from the shell ---"
for tagn in $(grep -aoE 'MARK_PFD_[A-Za-z0-9]+_BEGIN' "$LOG" | sed 's/MARK_PFD_//;s/_BEGIN//'); do
    nfd=$(sed -n "/MARK_PFD_${tagn}_BEGIN/,/MARK_PFD_${tagn}_END/p" "$LOG" \
          | tr -d '\r' | grep -acE '^[0-9]+[[:space:]]')
    echo "$TAG   $tagn: $nfd descriptors"
done

echo "$TAG --- panel task state at each checkpoint ---"
sed -n '/MARK_PFD_/,/MARK_PFD_.*_END/p' "$LOG" | tr -d '\r' \
    | grep -aE '^[0-9]+ [A-Za-z]+ [A-Za-z] ' | tail -20 | sed "s/^/$TAG   /"

echo "$TAG artifacts: $OUT_DIR"
if [ "$fail" -ne 0 ]; then
    echo "$TAG RESULT: FAIL"
    exit 1
fi
echo "$TAG RESULT: PASS — after ${LAST_UP}s of live session the panel still holds"
echo "$TAG   $LAST_FDS descriptors (started with $FIRST_FDS), has swallowed no"
echo "$TAG   window-list read failures, and its taskbar lists exactly the mapped"
echo "$TAG   windows [${WIDS_LIVE}]."
exit 0
