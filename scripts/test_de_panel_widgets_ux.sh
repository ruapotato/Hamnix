#!/usr/bin/env bash
# scripts/test_de_panel_widgets_ux.sh — static guards for the DE panel /
# settings UX fixes (from a real hands-on session) so they don't silently
# regress. Cheap grep/compile assertions only — no QEMU. The live proofs are
# the KVM DE drivers + screendumps.
#
#   A1  WINDOW LIST tracks live windows: hampanelscene enumerates
#       /dev/wsys/windows, hashes the snapshot (FNV-1a) so ANY change (open /
#       close / title-late / same-count swap) repaints the taskbar.
#   A2  CPU widget reports real utilisation via a busy/total DELTA from
#       /dev/stat, through the shared lib/cpustat.ad parser; the first sample
#       has no baseline so it reports 0%, not "all busy".
#
#       2026-07-31: A2 used to require '"/dev/uptime"' and `_cpu_prev_total`.
#       The widget deliberately MOVED OFF /dev/uptime, and the reason is in
#       user/hampanelscene.ad's own comment: /dev/uptime's idle column
#       (kernel/sched/loadavg.ad _la_idle_jiffies) is "wall ticks minus ring-3
#       ticks", which folds ALL kernel/system time into idle -- so any load
#       whose busy work ran in the kernel read ~0% on the panel while the
#       System Monitor showed real usage. The widget now samples the aggregate
#       "cpu" row of /dev/stat via lib/cpustat.ad, the same source hammonscene
#       reads, so the two cannot diverge. The baseline global was renamed
#       _cpu_prev_total -> _cpu_prev_tot in the same change.
#
#       So the gate was pinning the SOURCE OF A FIXED BUG: it demanded the
#       widget keep reading the counter that made it report ~0% under kernel
#       load. Gate rot of the worst kind -- had anyone "fixed" the tree to
#       satisfy it, they would have reintroduced the defect. A2 now asserts the
#       /dev/stat delta, and asserts /dev/uptime does NOT come back as the CPU
#       source.
#   A3  Right-click on BLANK bar space (incl. the elastic tasks/spacer region)
#       opens the ADD-A-WIDGET menu, not Move/Remove.
#   A4  Right-click on a real widget INCLUDING the Applications button opens the
#       per-widget Move / Remove menu.
#   A5  hamsettings: edge selector keeps all four panels on DISTINCT edges; the
#       Add-widget chips live in their own sub-column (no overlap with
#       Up/Down/Del).
#   A6  The Applications dropdown lists the Web Browser (/bin/hambrowse) and the
#       file manager (Files).
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
pass() { echo "[panel_ux] PASS $1"; }
failf() { echo "[panel_ux] FAIL $1" >&2; fail=1; }
need() { grep -q -- "$2" "$1" && pass "$3" || failf "$3"; }

PS="user/hampanelscene.ad"; SET="user/hamsettings.ad"

echo "[panel_ux] --- A1: live window-list ---"
need "$PS" '"/dev/wsys/windows"' "panel enumerates /dev/wsys/windows"
need "$PS" "win_hash" "panel hashes the window snapshot for change-detect"
need "$PS" "if win_hash != last_win_hash" "panel repaints when the window set changes"
need "$PS" "def _render_tasks" "panel renders the window-list taskbar"

echo "[panel_ux] --- A2: CPU widget idle/total delta ---"
need "$PS" '"/dev/stat"' "CPU widget samples /dev/stat (busy+total)"
need "$PS" "cpustat_busy_pct" "CPU widget uses the shared lib/cpustat delta parser"
need "$PS" "_cpu_prev_tot" "CPU widget keeps a previous-sample baseline"
# The idle column of /dev/uptime folds kernel time into idle; the CPU widget
# must never go back to it. Scope the check to _cpu_pct so an unrelated
# uptime reader elsewhere in the panel is not caught.
cpu_body=$(awk '
    /^def[[:space:]]+_cpu_pct[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$PS")
if [ -z "$cpu_body" ]; then
    failf "CPU widget: _cpu_pct() not found - is it renamed?"
elif grep -q '"/dev/uptime"' <<<"$cpu_body"; then
    failf "CPU widget reads /dev/uptime again - its idle column folds kernel time into idle and reports ~0% under kernel load"
else
    pass "CPU widget does not read /dev/uptime (the wrong idle counter)"
fi
need "$PS" "_cpu_inited" "CPU widget has a first-sample guard"
if grep -q 'pct: uint64 = centi / 2' "$PS"; then
    failf "CPU widget still scales load-average (centi/2) — pegs at 100%"
else
    pass "CPU widget no longer uses the load-average*50 scaling"
fi

echo "[panel_ux] --- A3/A4: right-click context routing ---"
need "$PS" "if wsk == WK_TASKS or wsk == WK_SPACER:" "elastic tasks/spacer counts as blank space (Add menu)"
# The Apps/menu widget must NOT special-case into the CTXK_APPMENU shortcut in
# the right-click dispatch (it now uses the shared Move/Remove menu).
disp="$(awk '/def _handle_button/,/def _ctx_select_row/' "$PS")"
if grep -q "ctx_kind = CTXK_APPMENU" <<<"$disp"; then
    failf "right-click dispatch still routes the Apps widget to CTXK_APPMENU (should be Move/Remove)"
else
    pass "right-click on any widget (incl. Apps) opens Move/Remove"
fi

echo "[panel_ux] --- A5: settings edge distinctness + no overlap ---"
need "$SET" "Keep every panel on a DISTINCT edge" "edge selector keeps panels on distinct edges"
need "$SET" "WADD_X" "add-widget chips live in their own sub-column"
if grep -q 'bx: int32 = WACT_X + k \* 48' "$SET"; then
    failf "add-widget chips still start at WACT_X (overlap Up/Down/Del)"
else
    pass "add-widget chips no longer overlap the Up/Down/Del stack"
fi

echo "[panel_ux] --- A6: browser + files in the Applications menu ---"
need "$PS" '"/bin/hambrowse"' "Applications menu launches the Web Browser"
need "$PS" '"Web Browser"' "Applications menu shows a Web Browser row"
need "$PS" '"/bin/hamfmscene"' "Applications menu launches the file manager"

echo "[panel_ux] --- compile the touched user binaries ---"
# shellcheck source=_adder_cc.sh
source "$PROJ_ROOT/scripts/_adder_cc.sh"
mkdir -p build/user
for n in hampanelscene hamsettings; do
    if adder_cc_compile compile --target=x86_64-adder-user "user/${n}.ad" \
            -o "build/user/${n}.elf" >/dev/null 2>&1; then
        pass "user/${n}.ad compiles"
    else
        failf "user/${n}.ad failed to compile"
    fi
done

echo "[panel_ux] --- result ---"
if [ "$fail" = 0 ]; then echo "[panel_ux] RESULT: PASS"; exit 0
else echo "[panel_ux] RESULT: FAIL"; exit 1; fi
