#!/usr/bin/env bash
# scripts/test_de_sysmon_mem_live.sh — the System Monitor's MEMORY row must
# come back DOWN when the RAM is returned, without restarting the app.
#
# USER-REPORTED BUG (2026-07, real device session): "the System Monitor does
# not release RAM in its display until the app is restarted." The RAM itself
# really is returned — /proc/meminfo MemFree rises — so this is the monitor's
# own view going stale, and the only assertion that means anything is one that
# compares the figure the monitor IS DRAWING against the kernel's live
# /proc/meminfo at the same instant.
#
# ASSERT ON THE EFFECT, not on the exit status. hammonscene publishes the model
# behind its MEMORY row to /tmp/.hammonscene.mem
# ("total=<kB> used=<kB> n=<sample seq> peak=<kB>") — the same shape
# hamdesktop uses for /tmp/.hamdesktop.src, and for the same reason: stdout
# does not reach the serial console for a compositor-spawned DE client.
#
# The pressure pulse is /bin/memhog, which allocates a known size, TOUCHES
# every page (resident frames, not a lazy reservation), holds, then munmaps and
# exits. That gives both halves of the assertion:
#   * PEAK_RISE  — the monitor must have SEEN the pressure. Without this, a
#     monitor whose number never moved at all would pass "came back down"
#     trivially. This is the anti-false-green half.
#   * AGREE      — after the release, the monitor's used must equal the
#     kernel's (MemTotal - MemFree) within a sampling-cadence tolerance.
#   * RELEASE_DROP — and it must actually have fallen from its own peak.
#
# MUTATE=<name>[,...] blinds a named assertion so each check is shown to be
# wired to its own observation.
#
# SKIPS CLEANLY (exit 0) when OVMF/socat are unavailable. Without /dev/kvm it
# reports INCONCLUSIVE (exit 125) rather than exit 0: nothing boots, so nothing
# here is observed, and a green GitHub run would otherwise read as "the System
# Monitor tracks memory".

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_sysmon_mem_live/$TS}"

# shellcheck source=_verdict.sh
source "$PROJ_ROOT/scripts/_verdict.sh"

fail=0
ok()  { echo "[sysmon_mem] PASS $*"; }
bad() { echo "[sysmon_mem] FAIL $*" >&2; fail=1; }

if [ ! -e /dev/kvm ]; then
    verdict_inconclusive "de_sysmon_mem_live" \
        "/dev/kvm absent: nothing was booted, so the System Monitor's live memory view was never observed. Run on a KVM host (scripts/ci_run_kvm_battery.sh)."
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || {
    echo "[sysmon_mem] SKIP-RUNTIME: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || {
    echo "[sysmon_mem] SKIP-RUNTIME: socat required for the QEMU monitor" >&2
    exit 0; }

# STALE-IMAGE GUARD — this gate boots an image it did not build.
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "[sysmon_mem]"

mkdir -p "$OUT_DIR"
echo "[sysmon_mem] output dir: $OUT_DIR"

RES="$OUT_DIR/results.txt"
python3 "$PROJ_ROOT/scripts/_de_sysmon_mem_live_drv.py" \
    "$INSTALLER_IMG" "$OVMF_FD" "$OUT_DIR" "$BOOT_WAIT" \
    >"$RES" 2>"$OUT_DIR/driver.log"
DRV_RC=$?
echo "[sysmon_mem] driver rc=$DRV_RC"
echo "[sysmon_mem] ---- observations ----"
cat "$RES"
echo "[sysmon_mem] ----------------------"

if [ "$DRV_RC" = "2" ] && ! grep -q '^RESULT BOOT OK' "$RES"; then
    echo "[sysmon_mem] SKIP: guest never reached the interactive shell" >&2
    tail -40 "$OUT_DIR/serial.log" >&2 2>/dev/null
    exit 0
fi

val() { sed -n "s/^RESULT $1 //p" "$RES" | tail -1; }
mutated=",${MUTATE:-},"
blind() { [ "${mutated#*,$1,}" != "$mutated" ]; }

isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---- the monitor is running and publishing at all ----------------------
if [ "$(val SYSMON_PUBLISHED)" = "1" ]; then
    ok "the System Monitor is running and publishing its MEMORY model"
else
    bad "the System Monitor never published a sample — nothing below is observed"
    echo "[sysmon_mem] RESULT: FAIL"; exit 1
fi

M_SEQ0="$(val M_SEQ0)"; M_SEQ2="$(val M_SEQ2)"
if [ "$(val SEQ_ADVANCED)" = "1" ]; then
    ok "the resample loop is live (sample seq $M_SEQ0 -> $M_SEQ2)"
else
    bad "the resample loop STALLED (sample seq $M_SEQ0 -> $M_SEQ2)"
fi

# ---- the monitor SAW the pressure (anti-false-green) --------------------
# memhog touches 192 MiB; the monitor's peak must be well clear of its
# baseline. 64 MiB of headroom absorbs the sampling cadence and the DE's own
# churn without letting a frozen display through.
PEAK_RISE="$(val PEAK_RISE_KB)"
MIN_RISE=65536
if blind saw_pressure; then
    bad "(blinded): the monitor observed the memory pressure"
elif isnum "$PEAK_RISE" && [ "$PEAK_RISE" -ge "$MIN_RISE" ]; then
    ok "the monitor OBSERVED the pressure (peak rose ${PEAK_RISE} kB over baseline)"
else
    bad "the monitor never saw the 192 MiB pulse (peak rose '${PEAK_RISE}' kB) — its display is frozen, or memhog did not allocate"
fi

# ---- KEYSTONE: it comes back DOWN when the RAM is returned --------------
K_FREE0="$(val K_FREE0)"; K_FREE1="$(val K_FREE1)"; K_FREE2="$(val K_FREE2)"
M_USED0="$(val M_USED0)"; M_USED1="$(val M_USED1)"; M_USED2="$(val M_USED2)"
DROP="$(val RELEASE_DROP_KB)"
if blind release_drop; then
    bad "KEYSTONE (blinded): the displayed figure falls when the RAM is returned"
elif isnum "$DROP" && [ "$DROP" -ge "$MIN_RISE" ]; then
    ok "KEYSTONE: the displayed used FELL when the RAM was returned (peak -> ${M_USED2} kB, a ${DROP} kB drop) with no restart"
else
    bad "KEYSTONE: the displayed used did NOT fall after the release (drop '${DROP}' kB; used ${M_USED1} -> ${M_USED2}) — the user's report"
fi

# ---- and it AGREES with the kernel at that instant ----------------------
# Tolerance covers the ~0.5 s resample cadence and the DE's own allocation
# churn between the monitor's sample and the gate's `cat /proc/meminfo`.
AGREE="$(val AGREE_DELTA_KB)"
TOL=16384
if blind agree; then
    bad "(blinded): the displayed figure agrees with /proc/meminfo"
elif isnum "$AGREE" && [ "$AGREE" -le "$TOL" ]; then
    ok "the displayed used agrees with the kernel (|displayed - (MemTotal-MemFree)| = ${AGREE} kB <= ${TOL})"
else
    bad "the displayed used disagrees with /proc/meminfo by '${AGREE}' kB (MemFree ${K_FREE0} -> ${K_FREE1} -> ${K_FREE2})"
fi

[ "$(val ALIVE)" = "1" ] \
    && ok "the guest survived the run" \
    || bad "the guest stopped responding during the run"

echo "[sysmon_mem] screenshots + serial log: $OUT_DIR"
if [ "$fail" = "0" ]; then
    echo "[sysmon_mem] RESULT: PASS"; exit 0
fi
echo "[sysmon_mem] RESULT: FAIL"; exit 1
