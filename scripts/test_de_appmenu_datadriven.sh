#!/usr/bin/env bash
# scripts/test_de_appmenu_datadriven.sh
#
# FAST, QEMU-free structural gate for the DATA-DRIVEN DE Applications menu:
# adding an app = dropping a .desktop file under /etc/hamde/apps, with NO
# code edit. Guards every load-bearing link a later refactor could break:
#
#   1. lib/desktopentry.ad is the shared, extern-free parser + its host
#      unit gate passes (scripts/test_desktopentry_host.sh).
#   2. Every DE menu consumer (hampanelscene = live panel, hamappmenu = v2
#      cascade, hamde = toolkit panel) imports the parser AND scans
#      /etc/hamde/apps, and each still compiles native.
#   3. The shipped etc/hamde/apps/*.desktop files are well-formed (have a
#      Name + Exec) and their Exec program is a binary build_user.sh builds.
#   4. The catalogue dir is STAGED into the cpio initramfs, the ext4 rootfs
#      image, and the hamnix-desktop-config package.
#
# Pass marker: RESULT: PASS
#
# ASSERTION ALTITUDE — READ BEFORE TRUSTING A GREEN HERE.
# This gate proves the .desktop CATALOGUE is well-formed and staged — i.e. it
# asserts on a DIRECTORY LISTING. It does NOT prove the menu SHOWS those apps.
# Its predecessor stayed green while the live Applications menu silently
# dropped every app past an internal cap (AM_MAX): the listing was perfect and
# the menu was wrong. A green here is necessary, not sufficient; the
# shipped-menu verdict (`[panel] appmenu entries: N`, asserted against the
# catalogue size) comes from the gate named below.
# RESULT-LEVEL GATE: scripts/test_de_office_suite.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
passed() { echo "[dd_appmenu] PASS $*"; }
failed() { echo "[dd_appmenu] FAIL $*" >&2; fail=1; }

PARSER="lib/desktopentry.ad"
APPS_DIR="etc/hamde/apps"
CONSUMERS=(hampanelscene hamappmenu hamde)

# --- 1. Parser exists + is extern-free -------------------------------
if [ -f "$PARSER" ]; then
    passed "parser $PARSER present"
    if grep -qE '^\s*extern\b' "$PARSER"; then
        failed "$PARSER contains an 'extern' — it must stay pure/dual-target"
    else
        passed "$PARSER is extern-free (links host + native)"
    fi
else
    failed "$PARSER missing"; echo "[dd_appmenu] RESULT: FAIL"; exit 1
fi

# Parser host unit gate.
if bash scripts/test_desktopentry_host.sh >/tmp/dd_parser.log 2>&1; then
    passed "parser host unit gate green"
else
    failed "parser host unit gate FAILED (see /tmp/dd_parser.log)"
    tail -8 /tmp/dd_parser.log >&2
fi

# --- 2. Each consumer imports the parser + scans the dir + compiles ---
for app in "${CONSUMERS[@]}"; do
    src="user/${app}.ad"
    if ! grep -q 'from lib.desktopentry import' "$src"; then
        failed "$app does not import lib.desktopentry (not data-driven)"
    fi
    if ! grep -q 'desktop_parse' "$src"; then
        failed "$app never calls desktop_parse"
    fi
    if ! grep -q '/etc/hamde/apps' "$src"; then
        failed "$app does not scan /etc/hamde/apps"
    fi
    if ! grep -q 'p9_listdir' "$src"; then
        failed "$app does not enumerate the catalogue dir (p9_listdir)"
    fi
    out="build/host/${app}_dd.elf"
    mkdir -p build/host
    if python3 -m compiler.adder compile --target=x86_64-adder-user \
            "$src" -o "$out" >"/tmp/dd_${app}.log" 2>&1; then
        passed "$app data-driven + compiles native"
    else
        failed "$app did NOT compile (see /tmp/dd_${app}.log)"
        tail -6 "/tmp/dd_${app}.log" >&2
    fi
done

# --- 3. Shipped .desktop files are well-formed + Exec is a real binary -
REQUIRED=(terminal files browser calculator editor control-center sysmon ham2048 installer)
if [ ! -d "$APPS_DIR" ]; then
    failed "$APPS_DIR directory missing"
else
    for base in "${REQUIRED[@]}"; do
        df="$APPS_DIR/${base}.desktop"
        if [ ! -f "$df" ]; then
            failed "missing desktop file $df"
            continue
        fi
        name=$(grep -m1 '^Name=' "$df" | cut -d= -f2-)
        exec_line=$(grep -m1 '^Exec=' "$df" | cut -d= -f2-)
        if [ -z "$name" ]; then failed "$df has no Name="; fi
        if [ -z "$exec_line" ]; then
            failed "$df has no Exec="
            continue
        fi
        # First Exec token = program path; must be /bin/<stem> that
        # build_user.sh builds.
        prog=$(echo "$exec_line" | awk '{print $1}')
        stem=$(basename "$prog")
        if grep -qE "build_adder_user ${stem}\b" scripts/build_user.sh; then
            passed "$base -> $name ($prog) is a built binary"
        else
            failed "$base Exec $prog ($stem) is NOT built by build_user.sh"
        fi
    done
fi

# --- 3b. Linux-namespace section: bind + scan + launch-in-ns wiring ---
# The scene panel surfaces installed Debian/Linux apps in a distinct "Linux"
# menu section via a readonly-intent bind of #distro at /n/linux, a scan of
# /n/linux/usr/share/applications, and a launch that enters the linux ns.
PANEL="user/hampanelscene.ad"
# Flag-tolerant: #69 made this a kernel-enforced read-only bind (`bind -r
# '#distro' /n/linux`), so match `bind [flags] '#distro' /n/linux` rather than
# the old flagless form (which this assertion froze at — a stale false-FAIL).
if grep -qE "bind[[:space:]]+(-[a-z]+[[:space:]]+)*'#distro'[[:space:]]+/n/linux" etc/rc.d/rc.5; then
    passed "rc.5 read-binds #distro at /n/linux for the panel ns"
else
    failed "rc.5 does not bind #distro at /n/linux (panel can't see Linux apps)"
fi
if grep -q '/n/linux/usr/share/applications' "$PANEL"; then
    passed "panel scans /n/linux/usr/share/applications (Linux catalogue)"
else
    failed "panel does not scan the Linux .desktop catalogue"
fi
if grep -q 'DE_CAT_LINUX' "$PANEL" && grep -q 'DE_CAT_LINUX' "$PARSER"; then
    passed "distinct DE_CAT_LINUX menu section defined + used"
else
    failed "DE_CAT_LINUX section not wired (parser + panel)"
fi
if grep -q 'rc.de-wayland' "$PANEL"; then
    passed "panel launches Linux apps via the enter-linux (rc.de-wayland) path"
else
    failed "panel does not route Linux launches into the linux namespace"
fi
# The demo Linux .desktop is planted so the section is demonstrable on a
# stock (no-debootstrap) image.
if grep -q 'hamnix-linux-demo.desktop' scripts/build_rootfs_img.py; then
    passed "build_rootfs_img plants a demo Linux .desktop (section demonstrable)"
else
    failed "no demo Linux .desktop planted — 'Linux' section undemonstrable"
fi

# --- 4. Catalogue dir is staged into every ship vehicle --------------
if grep -q 'etc/hamde/apps' scripts/build_packages.py; then
    passed "hamnix-desktop-config package ships etc/hamde/apps"
else
    failed "build_packages.py does not package etc/hamde/apps"
fi
# The cpio + rootfs stagers must recurse one extra etc/ level (the nested
# hamde/apps dir). Both got a 'sub.is_dir()' recursion branch.
if grep -q 'hamde/apps' scripts/build_initramfs.py; then
    passed "cpio initramfs stages the nested catalogue dir"
else
    failed "build_initramfs.py does not stage etc/hamde/apps (nested recurse missing)"
fi
if grep -q 'hamde/apps' scripts/build_rootfs_img.py; then
    passed "ext4 rootfs image stages the nested catalogue dir"
else
    failed "build_rootfs_img.py does not stage etc/hamde/apps (nested recurse missing)"
fi

# --- 5. The menu MODELS have headroom for every shipped launcher ----
# REGRESSION GUARD (the office suite went missing here): the panel's
# _am_add() and the legacy DE's _hd_add() SILENTLY DROP every entry past
# their compile-time cap. With 26 shipped launchers and AM_MAX=24, three
# apps (hamwrite/hamsheet/hamslides) vanished from a correctly-staged
# image with no error on serial. Assert each cap clears the shipped
# launcher count PLUS the optional-package launchers PLUS headroom for
# the additive /n/linux section.
n_apps=$(ls "$APPS_DIR"/*.desktop 2>/dev/null | wc -l)
n_opt=$(ls etc/hamde/apps-optional/*.desktop 2>/dev/null | wc -l)
need=$(( n_apps + n_opt + 8 ))
for spec in "user/hampanelscene.ad:AM_MAX" "user/hamde.ad:HD_MAX"; do
    src="${spec%%:*}"; sym="${spec##*:}"
    cap=$(sed -n "s/^${sym}: *uint64 *= *\([0-9]*\).*/\1/p" "$src" | head -1)
    if [ -z "$cap" ]; then
        failed "$src: cannot read $sym (menu-model cap)"
    elif [ "$cap" -ge "$need" ]; then
        passed "$src $sym=$cap >= $need ($n_apps shipped + $n_opt optional + 8 linux headroom)"
    else
        failed "$src $sym=$cap < $need — menu SILENTLY DROPS apps ($n_apps shipped + $n_opt optional launchers)"
    fi
done

if [ "$fail" = "0" ]; then
    echo "[dd_appmenu] RESULT: PASS"
    exit 0
fi
echo "[dd_appmenu] RESULT: FAIL"
exit 1
