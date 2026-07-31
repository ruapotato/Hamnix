#!/usr/bin/env bash
# scripts/test_hamde_render.sh — acceptance gate for the hamui-based
# Desktop Environment shell (user/hamde.ad) built on lib/hamui.ad.
#
# WHAT IT PROVES
# ==============
# hamde is the DE panel rebuilt as an ordinary hamui consumer: it builds
# a widget tree (an Applications menubar, a clock label, a taskbar list)
# and the toolkit lays it out and paints it as hamML markup into the
# window's "ui" draw layer — NO hand-rolled panel markup. A correct shell
# therefore means the panel chrome genuinely turns into toolkit-emitted
# hamML the compositor can rasterise.
#
# This is an OFFLINE compile+markup gate (the robust path on this host;
# full in-VM boot of the live daemon times out under load — see the
# project's "Verification under load" / "Real boot-path testing" notes).
# It mirrors scripts/test_hamui_render.sh's offline section:
#   1. hamde.ad (auto-pulling lib/hamui.ad) compiles clean.
#   2. the compiled hamde.elf embeds the toolkit's hamML emitters
#      (<rect>/<text>/fill=) and the menubar/menu fills, proving the
#      panel paint code is linked + reachable.
#   3. it embeds the Applications-menu item text and the real app launch
#      paths, proving the menu launches the shipped GUI apps.
#   4. the new hamui_list_clear (taskbar row-pool recycle) is linked.
#
# A regression in the toolkit paint path, the menu wiring, or the launch
# table will drop one of these tokens and fail the gate.
#
# 2026-07-31 — VERDICT ON A RED: GATE ROT, in the worst flavour. Six tokens were
# missing and every one of them was missing BY DESIGN. Repairing the tree to
# satisfy them would have undone two shipped architecture changes:
#
#   '<rect x=' / '<text x=' / 'fill='   The toolkit no longer emits hamML
#       markup. lib/hamui.ad's _h_rect/_h_line/_h_text_widget call the scene
#       display list (hamscene_fill / hamscene_line / hamscene_glyphs) — the
#       whole point of the scene-file pivot (docs/de_scene_file_arch.md).
#       "Fixing" this would have reinstated the markup emitters the pivot
#       deleted.
#
#   'Snake' / '/bin/hamfiles' / '/bin/hamsnake'   The Applications menu is
#       DATA-DRIVEN now: _hd_load_menu scans /etc/hamde/apps/*.desktop and
#       _hd_fallback is only the empty-directory fallback. The launch table is
#       not supposed to be compiled into the binary any more, and the two paths
#       are dead names besides — hamfiles/hamsnake are the legacy pre-pivot
#       widgets that hamfm/hamsnakescene replaced (they are on
#       test_package_de_coverage's intentional-skip list for exactly that
#       reason). Re-hardcoding them would have re-created a menu that launches
#       binaries nothing ships.
#
# So the assertions are rewritten against what the DE actually is, and made
# STRONGER than the grep they replace: part (3) now reads the shipped
# etc/hamde/apps/*.desktop set and requires every Exec= to name a binary
# build_user.sh actually produced. A .desktop pointing at a dead path is the
# real failure mode here (it is how /bin/hamfiles would have shipped), and the
# old token grep could not see it at all.
#
# Symbol checks use `strings -a | grep -qx` (whole-line), not `grep -F`: a
# substring match makes 'hamui_menu' satisfied by 'hamui_menubar' and
# 'hamscene_commit' satisfied by 'hamscene_commitX'.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

mkdir -p build/user

echo "[test_hamde_render] (1/4) hamde.ad + lib/hamui.ad compile clean"
if ! python3 -m compiler.adder compile \
        --target=x86_64-adder-user \
        user/hamde.ad \
        -o build/user/hamde.elf >/tmp/hamde_compile.log 2>&1; then
    echo "[test_hamde_render] FAIL: user/hamde.ad did not compile"
    cat /tmp/hamde_compile.log
    exit 1
fi
echo "[test_hamde_render] OK: hamde + hamui compiled"

if [ ! -s build/user/hamde.elf ]; then
    echo "[test_hamde_render] FAIL: build/user/hamde.elf missing/empty"
    exit 1
fi

fail=0
ELFSTR=build/user/hamde.strings
strings -a build/user/hamde.elf > "$ELFSTR"

check_tok() {  # $1=token  $2=label   (substring; for literals, not symbols)
    if grep -aF -q "$1" build/user/hamde.elf; then
        echo "[test_hamde_render] OK: ${2} (token: ${1})"
    else
        echo "[test_hamde_render] MISS: ${2} (no '${1}')"
        fail=1
    fi
}
check_sym() { # $1=symbol $2=label — WHOLE-LINE, so hamui_menubar cannot satisfy
              # hamui_menu and hamscene_commitX cannot satisfy hamscene_commit.
    if grep -qx -- "$1" "$ELFSTR" || grep -qx -- ".__epilogue_$1" "$ELFSTR"; then
        echo "[test_hamde_render] OK: ${2} (symbol: ${1})"
    else
        echo "[test_hamde_render] MISS: ${2} (no symbol '${1}')"
        fail=1
    fi
}

echo "[test_hamde_render] (2/4) Panel chrome paints through the toolkit (SCENE display list)"
# The toolkit's paint primitives, post scene-file pivot: a filled rect, a
# stroked line and a glyph run, plus the commit that publishes the frame.
check_sym hamscene_fill    'toolkit rect primitive -> scene fill'
check_sym hamscene_line    'toolkit line primitive -> scene line'
check_sym hamscene_glyphs  'toolkit text primitive -> scene glyphs'
check_sym hamscene_commit  'panel publishes its scene frame'
# The panel still owns a "ui" draw layer and z-orders it, and still carries the
# menubar/menu fills (#333333 bar, #252525 popdown, #3584e4 open/selection).
check_tok 'mklayer ui markup' 'panel creates its ui layer'
check_tok 'setz ui'           'panel z-orders its ui layer'
check_tok '#333333'           'menubar background fill'
check_tok '#252525'           'menu popdown fill'
check_tok '#3584e4'           'menu open / selection highlight'

echo "[test_hamde_render] (3/4) Applications menu is data-driven and every entry resolves"
check_tok 'Applications'    'Applications menu title'
check_tok '/etc/hamde/apps' 'panel scans the .desktop launcher directory'
check_tok '.desktop'        'panel filters on the .desktop suffix'
check_sym p9_listdir            'launcher directory is really enumerated'
check_sym desktop_name_is_entry '.desktop entry filter linked'
check_sym desktop_parse         '.desktop parser linked'
check_sym hamui_menu_add        'parsed entries are added to the menu'
# The empty-directory fallback must still name live binaries.
for p in /bin/hamterm /bin/hamfm /bin/hamedit /bin/ham2048; do
    check_tok "$p" "fallback launch path ${p}"
done

# THE ASSERTION THE OLD TOKEN GREP COULD NOT MAKE: every shipped launcher must
# point at a binary that actually exists. This is precisely how '/bin/hamfiles'
# (a dead pre-pivot name) would have shipped in a menu.
APPS=etc/hamde/apps
nlaunch=0
if [ ! -d "$APPS" ]; then
    echo "[test_hamde_render] MISS: $APPS does not exist (the menu has no data)"
    fail=1
else
    for d in "$APPS"/*.desktop; do
        [ -f "$d" ] || continue
        exec_path="$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$d" | head -1)"
        name="$(sed -n 's/^Name=//p' "$d" | head -1)"
        if [ -z "$exec_path" ] || [ -z "$name" ]; then
            echo "[test_hamde_render] MISS: $d has no Exec=/Name="
            fail=1; continue
        fi
        # Resolved against the SOURCE tree, not build/user: this gate compiles
        # only hamde.elf, so a build/user probe would fail on a clean checkout
        # for a reason that has nothing to do with the menu. "Is it packaged"
        # is test_package_de_coverage's question; "does this launcher name a
        # program that exists at all" is this one's.
        base="$(basename "$exec_path")"
        if [ ! -f "user/${base}.ad" ] && [ -z "$(find user -name "${base}.ad" -print -quit)" ]; then
            echo "[test_hamde_render] MISS: $d ('$name') launches ${exec_path}, which no source builds"
            fail=1; continue
        fi
        nlaunch=$((nlaunch + 1))
    done
    echo "[test_hamde_render] OK: ${nlaunch} .desktop launchers, every Exec= names a real program"
    if [ "$nlaunch" -lt 10 ]; then
        echo "[test_hamde_render] MISS: only ${nlaunch} resolvable launchers (expected the shipped DE menu, >=10)"
        fail=1
    fi
fi

echo "[test_hamde_render] (4/4) Toolkit additions linked (taskbar row recycle + windowing)"
for sym in hamui_menubar hamui_menu hamui_list hamui_list_clear \
           hamui_window_on hamui_step hamui_take_event hamui_render; do
    check_sym "$sym" "links toolkit symbol"
done

if [ "$fail" -ne 0 ]; then
    echo "[test_hamde_render] FAIL: the DE panel's toolkit paint/menu/launch wiring is not fully linked"
    exit 1
fi

echo "[test_hamde_render] capture method: hamde builds its panel from hamui widgets; the compiled binary links the toolkit's SCENE paint primitives and the .desktop menu loader, and every shipped launcher names a real program — the panel chrome is toolkit-rendered, not hand-rolled, and its menu cannot ship a dead path"
echo "[test_hamde_render] PASS"
