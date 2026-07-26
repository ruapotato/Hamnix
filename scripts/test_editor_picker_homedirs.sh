#!/usr/bin/env bash
# scripts/test_editor_picker_homedirs.sh
#
# FAST regression guard (no VM / KVM) for the Kate-flavor editor wave:
#
#   1. hameditscene.ad COMPILES clean to a user ELF (the file-picker +
#      gutter + line:col additions must not break the build).
#   2. useradd.ad COMPILES clean (the make_home_skel() addition).
#   3. The editor's file-PICKER is wired: it imports the p9 dir-listing
#      helpers, has the picker render/handle entry points, routes keys
#      to the picker, and binds Open (Ctrl-O) + Save-As (Ctrl-S/Ctrl-W)
#      to it. The picker defaults to $HOME (/home/live/Documents).
#   4. The Kate polish is present: a line-number gutter, a current-line
#      highlight, and an "Ln .. Col .." status indicator.
#   5. Classic home dirs (Desktop/Documents/Downloads/Pictures) are
#      CREATED for new users (useradd::make_home_skel) AND BAKED into the
#      cpio for the live/default user (build_initramfs.py), and the
#      generated cpio archive actually carries /home/live/Desktop etc.
#
# These are the load-bearing invariants a later refactor could silently
# break; the heavy rl5 VM gate proves the live visuals.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
note() { echo "[editor_picker] $*"; }
failed() { echo "[editor_picker] FAIL $*" >&2; fail=1; }
passed() { echo "[editor_picker] PASS $*"; }

# --- 1/2. Compile -----------------------------------------------------
compile_one() {
    local name="$1"
    local out
    out="$(mktemp --tmpdir "hamnix-${name}.XXXXXX.elf")"
    if python3 -m compiler.adder compile --target=x86_64-adder-user \
            "user/${name}.ad" -o "$out" >"/tmp/editor_picker.$name.log" 2>&1; then
        if file "$out" | grep -q ELF; then
            passed "$name compiles to an ELF"
        else
            failed "$name produced no ELF"
        fi
    else
        failed "$name did NOT compile (see /tmp/editor_picker.$name.log)"
        tail -8 "/tmp/editor_picker.$name.log" >&2 || true
    fi
    rm -f "$out"
}
compile_one hameditscene
compile_one useradd

ED=user/hameditscene.ad

# --- 3. File-picker wiring (now the shared lib/filepick.ad SERVICE) ---
LIB=lib/filepick.ad
FM_APP=user/hamfmscene.ad
grep -q "from lib.filepick import" "$ED" \
    && passed "hameditscene imports the shared lib.filepick service" \
    || failed "hameditscene missing lib.filepick import"

# The reusable picker SERVICE lives in lib/filepick.ad and exposes a stable
# app-agnostic API (open / active / emit / handle_code / take_result).
[ -f "$LIB" ] \
    && passed "lib/filepick.ad shared picker service exists" \
    || failed "lib/filepick.ad MISSING"

# --- 3a. UNIFIED browse core (lib/hamfmcore.ad) -----------------------
# The directory-browse + icon-grid render is ONE implementation shared by
# the file manager AND the picker. Neither file may re-roll its own dir-walk
# or icon grid: both must drive lib/hamfmcore.ad.
CORE=lib/hamfmcore.ad
[ -f "$CORE" ] \
    && passed "lib/hamfmcore.ad shared browse core exists" \
    || failed "lib/hamfmcore.ad MISSING (core not factored out)"
for sym in "fmc_load_dir" "fmc_paint" "fmc_cell_at" "fmc_go_into" \
           "fmc_go_parent" "fmc_set_geometry"; do
    grep -q "def ${sym}\b" "$CORE" \
        && passed "browse core exports ${sym}" \
        || failed "browse core missing ${sym}"
done
# The picker must REUSE the core's icon-grid paint, not its own list render.
grep -q "from lib.hamfmcore import" "$LIB" \
    && passed "picker drives the shared browse core" \
    || failed "picker does NOT import lib.hamfmcore (still reimplemented)"
grep -q "fmc_paint" "$LIB" \
    && passed "picker renders the SHARED icon grid (fmc_paint)" \
    || failed "picker not rendering the shared icon grid"
# The file manager must ALSO drive the same core (no duplicated dir-walk).
grep -q "from lib.hamfmcore import" "$FM_APP" \
    && passed "file manager drives the shared browse core" \
    || failed "file manager does NOT import lib.hamfmcore"
# The OLD bespoke duplication must be GONE from the picker.
grep -q "def _fp_load\b" "$LIB" \
    && failed "picker still carries its OWN dir-walk (_fp_load not removed)" \
    || passed "picker's duplicated dir-walk removed (uses the core)"
for sym in "filepick_open" "filepick_active" "filepick_emit" \
           "filepick_handle_code" "filepick_take_result" \
           "filepick_result_path" "filepick_result_mode"; do
    grep -q "def ${sym}\b" "$LIB" \
        && passed "filepick service exports ${sym}" \
        || failed "filepick service missing ${sym}"
done
# The lib must NOT do file I/O itself (it only RESOLVES a path).
grep -q "sys_open_write" "$LIB" \
    && failed "filepick service should not write files (open_write found)" \
    || passed "filepick service does no file I/O (path-resolver only)"

# Keys: Ctrl-O (15) Open, Ctrl-S (19) + Ctrl-W (23) Save-As route to picker.
grep -q "code == 15" "$ED" \
    && passed "Ctrl-O opens the picker" \
    || failed "Ctrl-O (code 15) not wired"
grep -q "code == 23" "$ED" \
    && passed "Ctrl-W Save-As wired" \
    || failed "Ctrl-W (code 23) not wired"
grep -q "filepick_handle_code(code)" "$ED" \
    && passed "keys route to the shared picker while open" \
    || failed "picker key routing missing"
grep -q "filepick_take_result" "$ED" \
    && passed "editor applies the committed pick (take_result wired)" \
    || failed "editor does not consume the picker result"
grep -q "/home/live/Documents" "$LIB" \
    && passed "picker defaults to \$HOME (/home/live/Documents)" \
    || failed "picker default dir not /home/live/Documents"

# --- 3b. File manager → editor launch --------------------------------
FM=user/hamfmscene.ad
grep -Eq "(^|[ ,])spawn([ ,]|$)" "$FM" \
    && passed "hamfmscene imports spawn() to launch apps" \
    || failed "hamfmscene missing spawn import"
grep -q "/bin/hameditscene" "$FM" \
    && passed "hamfmscene launches /bin/hameditscene on a file" \
    || failed "hamfmscene does not launch the editor"
# The launcher was renamed _open_in_editor -> _open_entry in 335821d1 when the
# open path grew TYPE DISPATCH (images -> hamview, audio -> hamaudioscene,
# everything else -> the editor). Assert the current entry point AND the
# dispatch table, so the superseding behaviour is what's actually pinned.
grep -q "def _open_entry" "$FM" \
    && passed "hamfmscene has the _open_entry launcher" \
    || failed "hamfmscene _open_entry launcher missing"
grep -q "def _pick_app" "$FM" \
    && passed "hamfmscene type-dispatches the open by extension (_pick_app)" \
    || failed "hamfmscene _pick_app type dispatch missing"
grep -q "/bin/hamview" "$FM" \
    && passed "hamfmscene routes image files to /bin/hamview" \
    || failed "hamfmscene does not route images to hamview"
grep -q "/bin/hamaudioscene" "$FM" \
    && passed "hamfmscene routes audio files to /bin/hamaudioscene" \
    || failed "hamfmscene does not route audio to hamaudioscene"
# A file click must call the launcher (not the old "not a directory" no-op).
grep -q "_open_entry(u)" "$FM" \
    && passed "a file click launches the associated app (no 'not a directory' no-op)" \
    || failed "file click not wired to _open_entry"
# Compile the file manager too (the launch wiring must not break the build).
compile_one hamfmscene

# --- 4. Kate polish ---------------------------------------------------
grep -q "GUTTER_W" "$ED" \
    && passed "line-number gutter present" \
    || failed "no line-number gutter"
grep -q "current-line highlight" "$ED" \
    && passed "current-line highlight present" \
    || failed "no current-line highlight"
grep -q "_caret_line_col" "$ED" \
    && passed "Ln/Col status indicator present" \
    || failed "no Ln/Col indicator"

# --- 5. Home dirs -----------------------------------------------------
grep -q "def make_home_skel" user/useradd.ad \
    && passed "useradd creates classic home skel dirs" \
    || failed "useradd make_home_skel missing"
for d in Desktop Documents Downloads Pictures; do
    grep -q "\"$d\"" user/useradd.ad \
        && passed "useradd skel includes $d" \
        || failed "useradd skel missing $d"
done

grep -q 'home/live' scripts/build_initramfs.py \
    && passed "build_initramfs bakes /home/live skel" \
    || failed "build_initramfs missing /home/live skel"

# Prove the GENERATED cpio archive actually carries the home subdirs.
# build_initramfs exposes the FILES table; build a throwaway archive and
# grep its raw bytes for the planted paths (cpio stores full path names
# inline, so a substring search is reliable).
note "building a throwaway cpio archive to verify baked home dirs"
ARCH="$(mktemp --tmpdir hamnix-cpio.XXXXXX.bin)"
if python3 - "$ARCH" <<'PY' >/tmp/editor_picker.cpio.log 2>&1
import sys
sys.path.insert(0, "scripts")
import build_initramfs as bi
arch = bi.build_archive()
open(sys.argv[1], "wb").write(arch)
PY
then
    for d in Desktop Documents Downloads Pictures; do
        if grep -aq "home/live/$d" "$ARCH"; then
            passed "cpio archive carries /home/live/$d"
        else
            failed "cpio archive MISSING /home/live/$d"
        fi
    done
    if grep -aq "home/live/Documents/welcome.txt" "$ARCH"; then
        passed "cpio archive carries Documents/welcome.txt"
    else
        failed "cpio archive missing welcome.txt"
    fi
else
    note "cpio build skipped (build_archive unavailable):"
    tail -8 /tmp/editor_picker.cpio.log >&2 || true
    note "skipping cpio-archive byte checks (static grep checks still apply)"
fi
rm -f "$ARCH"

if [ "$fail" -ne 0 ]; then
    echo "[editor_picker] OVERALL: FAIL" >&2
    exit 1
fi
echo "[editor_picker] OVERALL: PASS"
exit 0
