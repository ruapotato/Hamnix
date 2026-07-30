#!/usr/bin/env bash
# scripts/test_de_desktop_live_view.sh — the GUI desktop must BE a live view of
# the user's ~/Desktop, and dragging an app out of the Applications menu must
# actually pin it.
#
# THREE USER-REPORTED FAILURES, all "the desktop does not reflect reality":
#
#  1. "Dragging an app from the app menu to the panel seems to not work now."
#     REGRESSION from the #327 drag-drop-placement rework (135013df). That
#     commit turned the drop into an OFFER the receiver commits on its OWN
#     button release — correct placement — but gave the offer a 48-jiffy TTL.
#     Jiffies are HZ=100, so the offer self-destructed 480 ms after the panel
#     first SAW it, and the panel sees it the instant the menu crosses its
#     14 px drag threshold: the START of the gesture. Every human drag takes
#     longer than that, so the release always found an empty sidecar.
#     Measured on a real boot before the fix: an offer + click issued inside a
#     single guest command line (~50 ms apart) commits; the same pair 2.5 s
#     apart finds the sidecar already truncated.
#  2. "Dragging from the menu to the desktop should create a .desktop file."
#     Same offer, same 480 ms TTL, same outcome — it never worked at all.
#  3. "/home/<username>/Desktop does not seem to reflect the GUI desktop."
#     hamdesktop resolved <home>/Desktop from $HOME with a HARDCODED
#     /home/live fallback, and compositor-spawned DE clients have NO $HOME
#     (probed on a real boot: `cat /env/HOME` -> "file does not exist"), so
#     the fallback always won. Right by accident on the live image, wrong on
#     every installed system. The periodic re-scan was never broken — it was
#     watching somebody else's directory. Fixed by resolving through
#     /etc/passwd BY UID (lib/homedir.ad); the uid-dependent half of that is
#     gated deterministically by scripts/test_de_home_resolve_host.sh.
#
# ASSERT ON THE EFFECT. Every check below is a state change observed on a
# REAL UEFI/OVMF boot of the shipped installer image:
#   * a file CREATED in ~/Desktop from the shell makes the rendered icon count
#     go UP; deleting it makes the count go back DOWN (item 3's live view).
#   * a REAL pointer drag — open Applications, hover a category, press an app
#     row in the fly-out, drag with the button HELD across the screen, release
#     on the top bar — leaves a NEW `widget launcher` in the panel config
#     (item 1). No synthesised sidecar: the whole handshake runs through the
#     compositor's pointer path.
#   * the same drag released on the DESKTOP leaves a real
#     ~/Desktop/<Name>.desktop carrying the app's Exec, and the icon count
#     goes up (item 2).
#
# MUTATION-TESTED: restoring PEND_TTL_JIF/DROP_TTL_JIF to 48 turns the panel
# and desktop drop assertions RED while the live-view assertions stay green.
#
# SKIPS CLEANLY (exit 0) when OVMF/socat/the image are unavailable. Without
# /dev/kvm it reports INCONCLUSIVE (exit 125) rather than exit 0: nothing boots,
# so no pixel assertion here is observed, and a green GitHub run would otherwise
# read as "the desktop renders".

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_desktop_live_view/$TS}"

# Sourced up here, not next to the image guard below: the /dev/kvm check that
# follows immediately needs verdict_inconclusive.
# shellcheck source=_verdict.sh
source "$PROJ_ROOT/scripts/_verdict.sh"

fail=0
ok()   { echo "[live_view] PASS $*"; }
bad()  { echo "[live_view] FAIL $*" >&2; fail=1; }

# --- environment gates --------------------------------------------------
# INCONCLUSIVE, not exit 0: every assertion in this gate is about pixels on a
# live desktop, and without /dev/kvm nothing is booted and nothing is rendered.
# A green GitHub run here would read as "the desktop renders", which it cannot
# possibly have checked. exit 125 -> ::warning:: via scripts/ci_run_gate.sh.
if [ ! -e /dev/kvm ]; then
    verdict_inconclusive "de_desktop_live_view" \
        "/dev/kvm absent: nothing was booted and no desktop pixels were observed. Run on a KVM host (scripts/ci_run_kvm_battery.sh)."
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || {
    echo "[live_view] SKIP-RUNTIME: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || {
    echo "[live_view] SKIP-RUNTIME: socat required for the QEMU monitor" >&2
    exit 0; }

# STALE-IMAGE GUARD: this gate BOOTS a pre-existing image it did not build.
# ensure_installer_img REBUILDS when the image is older than any tracked build
# input (tests/ included), so editing a driver correctly marks it stale.
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "[de_desktop_live_view]"

mkdir -p "$OUT_DIR"
echo "[live_view] output dir: $OUT_DIR"

RES="$OUT_DIR/results.txt"
python3 "$PROJ_ROOT/scripts/_de_desktop_live_view_drv.py" \
    "$INSTALLER_IMG" "$OVMF_FD" "$OUT_DIR" "$BOOT_WAIT" >"$RES" 2>"$OUT_DIR/driver.log"
DRV_RC=$?
echo "[live_view] driver rc=$DRV_RC"
echo "[live_view] ---- observations ----"
cat "$RES"
echo "[live_view] ----------------------"

if [ "$DRV_RC" = "2" ] && ! grep -q '^RESULT BOOT OK' "$RES"; then
    echo "[live_view] SKIP: guest never reached the interactive shell" >&2
    tail -40 "$OUT_DIR/serial.log" >&2 2>/dev/null
    exit 0
fi

val() { sed -n "s/^RESULT $1 //p" "$RES" | tail -1; }

# MUTATE=<name>[,...] blinds a named assertion so each check can be shown to be
# wired to its own observation rather than to a shared code path.
mutated=",${MUTATE:-},"
blind() { [ "${mutated#*,$1,}" != "$mutated" ]; }

# ---- item 3: the desktop is a LIVE VIEW of the user's ~/Desktop ----------
SRC="$(val SRC)"
case "$SRC" in
    */Desktop) ok "icon source is a Desktop directory: $SRC" ;;
    *)         bad "icon source is not a Desktop directory: '$SRC'" ;;
esac
N0="$(val N0)"; N1="$(val N1)"; N2="$(val N2)"
SL="$(val SHIPPED_LAUNCHERS)"
if [ -n "$SL" ] && [ "$SL" -ge 4 ]; then
    ok "the resolved desktop dir carries the shipped launcher set ($SL .desktop files)"
else
    bad "the resolved desktop dir has almost nothing in it ($SL .desktop files) — wrong home?"
fi
[ "$(val PROBE_WRITTEN)" = "1" ] \
    && ok "the probe file was created in $SRC" \
    || bad "could not create a probe file in $SRC"
if blind live_add; then
    bad "KEYSTONE (blinded): a file created in ~/Desktop appears on the desktop"
elif [ -n "$N0" ] && [ -n "$N1" ] && [ "$N1" -gt "$N0" ]; then
    ok "KEYSTONE: a file created in ~/Desktop APPEARS on the GUI desktop ($N0 -> $N1 icons)"
else
    bad "KEYSTONE: creating a file in ~/Desktop did not change the desktop ($N0 -> $N1)"
fi
if blind live_del; then
    bad "(blinded): deleting the file removes its icon"
elif [ -n "$N2" ] && [ "$N2" -lt "$N1" ]; then
    ok "deleting it removes the icon again ($N1 -> $N2)"
else
    bad "deleting the probe file left the desktop unchanged ($N1 -> $N2)"
fi

# ---- item 1: drag from the Applications menu ONTO THE PANEL --------------
PB="$(val PANELCONF_BEFORE_LAUNCHERS)"; PA="$(val PANELCONF_AFTER_LAUNCHERS)"
if blind panel_drop; then
    bad "KEYSTONE (blinded): a menu->panel drag pins a launcher"
elif [ "$(val PANEL_DROPPED_CALC)" = "1" ]; then
    ok "KEYSTONE: dragging an app from the menu onto the PANEL pinned it (launchers $PB -> $PA)"
else
    bad "KEYSTONE: a menu->panel drag pinned NOTHING (launchers $PB -> $PA) — the user's report"
fi
SCB="$(val SIDECAR_BYTES_AFTER_PANEL)"
[ "$SCB" = "0" ] \
    && ok "the drop offer was consumed exactly once (sidecar 0 bytes)" \
    || bad "the drop offer was left pending after the panel commit ($SCB bytes)"
[ "$(val MENU_OPENED_PANEL)" = "1" ] \
    && ok "the Applications menu opened for the panel drag" \
    || bad "the Applications menu never opened — the panel gesture is untested"

# ---- item 2: drag from the Applications menu ONTO THE DESKTOP -----------
N3="$(val N3)"; N4="$(val N4)"
if blind desk_drop; then
    bad "KEYSTONE (blinded): a menu->desktop drag writes a .desktop file"
elif [ "$(val DESKTOP_DROPPED_CALC)" = "1" ]; then
    ok "KEYSTONE: dragging an app onto the DESKTOP created a real .desktop file"
else
    bad "KEYSTONE: a menu->desktop drag created NO .desktop file — the user's report"
fi
[ "$(val DESKTOP_ENTRY_HAS_EXEC)" = "1" ] \
    && ok "the created launcher carries the app's Exec (it is usable later)" \
    || bad "the created .desktop has no usable Exec line"
if [ -n "$N3" ] && [ -n "$N4" ] && [ "$N4" -gt "$N3" ]; then
    ok "the dropped launcher is RENDERED on the desktop ($N3 -> $N4 icons)"
else
    bad "the dropped launcher never showed up in the icon grid ($N3 -> $N4)"
fi
[ "$(val MENU_OPENED_DESKTOP)" = "1" ] \
    && ok "the Applications menu opened for the desktop drag" \
    || bad "the Applications menu never opened — the desktop gesture is untested"

[ "$(val ALIVE)" = "1" ] \
    && ok "the guest stayed alive through every gesture" \
    || bad "the guest did not answer the liveness probe"

if [ "$fail" -eq 0 ]; then
    echo "[live_view] RESULT: PASS"
    exit 0
fi
echo "[live_view] RESULT: FAIL — see $OUT_DIR" >&2
exit 1
