#!/usr/bin/env bash
# scripts/test_de_new_apps.sh
#
# FAST regression guard for the DE features wave (no VM / KVM needed):
#
#   1. The three new scene apps COMPILE clean to user ELFs:
#        haminstallui  — visual installer GUI front-end over /bin/install
#        hamsettings   — wallpaper + panel settings
#        hammonscene   — system monitor (uptime/mem/process list)
#   2. hamdesktop COMPILES with the icon drag-rearrange + persist logic.
#   3. Each new app is REGISTERED: built by build_user.sh, listed in the
#      Applications menu (hampanelscene), and present in /etc/desktop.icons.
#   4. The desktop-icon DRAG-PERSIST wiring is present: hamdesktop parses the
#      optional "|x|y" position fields, writes them back, and the persisted
#      /etc/desktop.icons format is round-trippable (parser accepts the
#      extended 5-field line AND the legacy 3-field line).
#
# These are the load-bearing invariants a later refactor could silently
# break; the heavy VM gates (test_de_scene_*) prove the live visuals. This
# gate is the cheap always-runs companion.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
note() { echo "[de_new_apps] $*"; }
failed() { echo "[de_new_apps] FAIL $*" >&2; fail=1; }
passed() { echo "[de_new_apps] PASS $*"; }

# --- 1/2. Compile each app to a user ELF -----------------------------
compile_one() {
    local name="$1"
    local out
    out="$(mktemp --tmpdir "hamnix-${name}.XXXXXX.elf")"
    if python3 -m compiler.adder compile --target=x86_64-adder-user \
            "user/${name}.ad" -o "$out" >/tmp/de_new_apps.$name.log 2>&1; then
        if file "$out" | grep -q ELF; then
            passed "$name compiles to an ELF"
        else
            failed "$name produced no ELF"
        fi
    else
        failed "$name did NOT compile (see /tmp/de_new_apps.$name.log)"
        tail -5 "/tmp/de_new_apps.$name.log" >&2 || true
    fi
    rm -f "$out"
}

for app in haminstallui hamsettings hammonscene hamdesktop; do
    compile_one "$app"
done

# --- 3. Registration: build_user.sh + Applications menu + desktop icons
for app in haminstallui hamsettings hammonscene; do
    if grep -q "build_adder_user ${app}\b" scripts/build_user.sh; then
        passed "$app registered in build_user.sh"
    else
        failed "$app NOT in build_user.sh"
    fi
done

# Applications menu (hampanelscene) launches each new app.
# NOTE: hamsettings is intentionally DELISTED — the legacy "Settings" app
# duplicated the Control Center (/bin/hamctl) Appearance/wallpaper capplet, so
# it was removed from the menu, desktop icons and .desktop entries. Its source
# still compiles and ships (checked above); it is just no longer launchable.
for prog in haminstallui hammonscene; do
    if grep -q "/bin/${prog}" user/hampanelscene.ad; then
        passed "$prog wired into the Applications menu"
    else
        failed "$prog NOT in the Applications menu (hampanelscene)"
    fi
done

# Desktop icons reference each new app. The desktop is now REAL, filesystem-
# backed: /bin/hamdesktop renders its icon grid from the CONTENTS of
# ~/Desktop, whose default launcher template ships as real `.desktop` files
# under /etc/skel/Desktop (build_initramfs plants them at /home/live/Desktop).
# So the registration invariant is "the app has a .desktop launcher in the
# skel Desktop template", grep'd across those files' Exec= lines.
for prog in haminstallui hammonscene; do
    if grep -rq "Exec=/bin/${prog}\b" etc/skel/Desktop/; then
        passed "$prog has a desktop launcher (.desktop in etc/skel/Desktop)"
    else
        failed "$prog NOT launchable from ~/Desktop (no .desktop in etc/skel/Desktop)"
    fi
done

# --- 3b. GUI installer drives the PACKAGE-based install path ----------
# The GUI must spawn `/bin/install --auto` (Debian-style hpm package install)
# NOT the legacy `/bin/haminstall` (dd ESP + manifest rootfs copy that pulled
# bytes from /n/distros and failed with "skip missing source"). Guard both:
# the right binary is spawned, AND the GUI never references /n/distros.
if grep -q 'spawn(cast\[Ptr\[char\]\]("/bin/install")' user/haminstallui.ad \
        && grep -q '"--auto"' user/haminstallui.ad; then
    passed "haminstallui spawns /bin/install --auto (package-based install)"
else
    failed "haminstallui does NOT spawn /bin/install --auto (package path missing)"
fi
if grep -q 'spawn(cast\[Ptr\[char\]\]("/bin/haminstall")' user/haminstallui.ad; then
    failed "haminstallui still spawns the legacy /bin/haminstall (dd/manifest path)"
else
    passed "haminstallui no longer spawns the legacy /bin/haminstall"
fi
# Check code lines only (strip '#' comments) — the header doc may mention
# /n/distros to explain what it deliberately does NOT do.
#
# GATE HYGIENE (2026-07-31). This check and the haminstall.gui.log one below
# used to be spelled
#     grep -vE '^\s*#' user/haminstallui.ad | grep -q '<pattern>'
# under `set -o pipefail`. Both are ABSENT-assertions: a MATCH is the
# regression and must take the `then` branch. But `grep -q` exits the instant
# it matches, closing the pipe under the still-writing `grep -vE` (~43 KB of
# code lines, emitted in ~130-byte write() chunks, never one blob). The writer
# dies of SIGPIPE (141), `pipefail` promotes 141 to the pipeline's status, the
# `if` is therefore FALSE, and the ELSE branch reports PASS. The guard could
# only ever fire when the offending line happened to sit near the END of the
# file, where grep has already drained the writer before it matches.
# PROVEN by mutation on 2026-07-31: with
#     DISTRO_SRC_MUTATION_PROBE: Ptr[char] = "/n/distros"
# inserted at the FIRST code line, the old form reported
#     PASS haminstallui code never references /n/distros
# on 7 of 7 runs — while the same probe APPENDED at the end went red. A guard
# that passes exactly when you mutation-test it the obvious way.
# Materialise the comment-stripped view ONCE and grep that FILE: no pipeline,
# no race, and file position no longer decides the verdict.
HAMINSTALLUI_CODE="$(mktemp --tmpdir hamnix-haminstallui-code.XXXXXX)"
trap 'rm -f "$HAMINSTALLUI_CODE"' EXIT
grep -vE '^\s*#' user/haminstallui.ad >"$HAMINSTALLUI_CODE"
if grep -q '/n/distros' "$HAMINSTALLUI_CODE"; then
    failed "haminstallui CODE references /n/distros (must source from the hpm repo only)"
else
    passed "haminstallui code never references /n/distros"
fi
# Online-repo option present + local fallback is the default.
if grep -q 'use_online' user/haminstallui.ad \
        && grep -q 'file:///iso-packages' user/haminstallui.ad; then
    passed "haminstallui offers an online-repo toggle with local-repo fallback"
else
    failed "haminstallui missing the online-repo toggle / local fallback"
fi

# --- 3c. GUI install progress STREAMING (regression: "installing from
# repo" hang) -------------------------------------------------------------
# The GUI froze forever on "installing from repo ..." because it redirected
# only the install child's stdout to a /tmp file via an integer-fd dup2 (which
# lib/p9 spawn silently SKIPS when the fd number is >= 16) and dropped stderr
# entirely — so a real install failure printed only to fd 2 and was never seen.
# The fix routes BOTH stdout (fd 1) and stderr (fd 2) through a pipe the GUI
# drains non-blocking, detects the child's completion/FAIL markers, AND
# surfaces a clean pipe-EOF so a child that exits without a marker no longer
# hangs the pane. Guard every load-bearing piece of that data path.
if grep -q 'sys_pipechan()' user/haminstallui.ad \
        && grep -q 'DEVFD_PIPE_R' user/haminstallui.ad \
        && grep -q 'DEVFD_PIPE_W' user/haminstallui.ad; then
    passed "haminstallui captures install output through a pipe (not a /tmp file)"
else
    failed "haminstallui install-output capture is not pipe-based (fd>=16 redirect trap)"
fi
# The install child must be spawned with the stdio-namespace sentinel for BOTH
# stdin and stdout so the post-spawn fdbinds (fd 1 AND fd 2 -> the pipe) land.
if grep -q 'SPAWN_STDIO_NS, SPAWN_STDIO_NS' user/haminstallui.ad; then
    passed "haminstallui spawns /bin/install with SPAWN_STDIO_NS stdio"
else
    failed "haminstallui does not spawn install with SPAWN_STDIO_NS (fdbind won't take)"
fi
# Both fd 1 and fd 2 of the child must be bound to the pipe WRITE end so the
# installer's stderr FAIL lines reach the pane (the original drop that hid the
# failure and produced the hang).
if grep -q 'sys_fdbind(pid, 1, DEVFD_PIPE_W' user/haminstallui.ad \
        && grep -q 'sys_fdbind(pid, 2, DEVFD_PIPE_W' user/haminstallui.ad; then
    passed "haminstallui binds child stdout AND stderr to the progress pipe"
else
    failed "haminstallui does not capture child stderr (FAIL lines invisible -> hang)"
fi
# The poll loop must be non-blocking (sys_read_nb) and treat a pipe EOF (-1)
# as terminal so an install that exits without a marker can't freeze the pane.
if grep -q 'sys_read_nb(inst_out_fd' user/haminstallui.ad \
        && grep -q 'inst_eof' user/haminstallui.ad \
        && grep -q "installer exited without 'install complete'" user/haminstallui.ad; then
    passed "haminstallui drains the pipe non-blocking + handles EOF-without-marker"
else
    failed "haminstallui poll loop missing non-blocking drain / EOF-without-marker guard"
fi
# The completion + failure markers the GUI scans for must match what
# /bin/install actually prints to stdout/stderr ("install complete" / "FAIL").
if grep -q '"install complete"' user/haminstallui.ad \
        && grep -q '"FAIL"' user/haminstallui.ad \
        && grep -q 'install complete on' user/install.ad \
        && grep -q '\[install\] FAIL' user/install.ad; then
    passed "haminstallui completion/FAIL markers match /bin/install output"
else
    failed "haminstallui markers do not match /bin/install output (pane can't detect done)"
fi
# The legacy /tmp log-file redirect path must be gone (it was the fd>=16 trap).
if grep -q 'haminstall.gui.log' "$HAMINSTALLUI_CODE"; then
    failed "haminstallui still uses the /tmp log-file redirect (fd>=16 dup2 trap)"
else
    passed "haminstallui no longer uses the fragile /tmp log-file redirect"
fi

# The live install medium must be filtered out of the candidate target list
# UP FRONT (at enumerate time), not just refused after Install is clicked.
# haminstallui must carry the same FAT-volume-label ("HAMNIXINST") boot-medium
# predicate install.ad uses, and apply it inside _enumerate_disks.
if grep -q 'HAMNIXINST' user/haminstallui.ad \
        && grep -q 'def _is_boot_medium' user/haminstallui.ad \
        && grep -q '_is_boot_medium(&nm\[0\], nl)' user/haminstallui.ad; then
    passed "haminstallui filters the live install medium from the target list"
else
    failed "haminstallui does NOT filter the live medium at enumerate time (dead-end refusal)"
fi
# RAM/loop/live pseudo-disks must also be excluded at list time.
if grep -q 'def _is_ram_backed' user/haminstallui.ad \
        && grep -q '_is_ram_backed(&nm\[0\])' user/haminstallui.ad; then
    passed "haminstallui excludes ram/loop/live pseudo-disks from the target list"
else
    failed "haminstallui does not exclude ram/loop/live pseudo-disks"
fi
# When the filtered list is empty, the GUI must show clear guidance (attach a
# blank disk) plus a Rescan affordance — not an empty picker / bare refusal.
if grep -q 'No installable target disk detected' user/haminstallui.ad \
        && grep -q 'Attach a blank disk' user/haminstallui.ad \
        && grep -q '"Rescan"' user/haminstallui.ad; then
    passed "haminstallui shows empty-target guidance + a Rescan button"
else
    failed "haminstallui missing the empty-target guidance / Rescan affordance"
fi
# The install-time REFUSING guard must remain as a belt-and-suspenders backstop.
if grep -q 'REFUSING: target IS the live install medium' user/install.ad; then
    passed "install.ad keeps the live-medium REFUSING backstop"
else
    failed "install.ad lost the live-medium REFUSING backstop"
fi

# --- 4. Desktop-icon rendering + drag-persist wiring -----------------
# The desktop renders its icons from the REAL ~/Desktop directory (scanned
# via the shared FM directory scanner) and parses `.desktop` launchers.
if grep -q '_load_icons_from_dir' user/hamdesktop.ad \
        && grep -q 'fmc_load_dir' user/hamdesktop.ad \
        && grep -q 'desktop_parse' user/hamdesktop.ad; then
    passed "hamdesktop renders icons from the ~/Desktop directory contents"
else
    failed "hamdesktop does not render from a real directory (dir scan missing)"
fi
# A CLI-created folder/file must appear via the periodic re-scan.
if grep -q 'fmc_refresh_if_changed' user/hamdesktop.ad \
        && grep -q 'sys_waitfds' user/hamdesktop.ad; then
    passed "hamdesktop periodically re-scans ~/Desktop (CLI changes appear)"
else
    failed "hamdesktop missing the periodic re-scan / waitfds park"
fi
# Drag positions persist to the writable ~/Desktop sidecar (NOT the read-only
# /etc), keyed by label so a rearrange survives a re-scan + relaunch.
if grep -q '_save_positions' user/hamdesktop.ad \
        && grep -q '.hamdesktop.pos' user/hamdesktop.ad; then
    passed "hamdesktop persists drag positions to the ~/Desktop sidecar"
else
    failed "hamdesktop missing the position-persist path"
fi
if grep -q 'DRAG_THRESH' user/hamdesktop.ad \
        && grep -q 'dragging' user/hamdesktop.ad; then
    passed "hamdesktop has the click-vs-drag threshold logic"
else
    failed "hamdesktop missing the drag-threshold logic"
fi
# The shipped default launcher template must be real, valid `.desktop` files
# under etc/skel/Desktop (each with a Name + an Exec=/bin program) so a fresh
# boot shows the same icon set, now as CLI-manipulable files.
skel_ok=1
for f in etc/skel/Desktop/*.desktop; do
    [ -e "$f" ] || { skel_ok=0; break; }
    grep -q '^Name=' "$f" && grep -q '^Exec=/bin/' "$f" || skel_ok=0
done
if [ "$skel_ok" = "1" ] && ls etc/skel/Desktop/*.desktop >/dev/null 2>&1 \
        && grep -q 'ic_x\[n_icons\]' user/hamdesktop.ad; then
    passed "etc/skel/Desktop ships valid .desktop launchers + icons carry positions"
else
    failed "etc/skel/Desktop launcher template missing/invalid or position fields gone"
fi

if [ "$fail" = "0" ]; then
    echo "[de_new_apps] RESULT: PASS"
    exit 0
fi
echo "[de_new_apps] RESULT: FAIL"
exit 1
