#!/usr/bin/env bash
# scripts/test_de_snarf_wctl.sh — structural guard for the three DE
# primitives that landed in "DE: snarf clipboard + wctl resize/move/focus":
#
#   1. /dev/snarf — global one-buffer clipboard (sys/src/9/port/devsnarf.ad).
#                   Write replaces; read snapshots; max 64 KiB.
#
#   2. /dev/wsys/<N>/wctl — per-window rio-shape control file
#                   (sys/src/9/port/devwsys.ad). Three verbs:
#                       resize <w> <h>
#                       move   <x> <y>
#                       focus  click|sloppy
#                   Snapshot read returns "<x> <y> <w> <h> <focus>\n".
#
#   3. Both surfaces wired into the namec devtab — DEV_SNARF +
#      DEV_WSYS_WCTL constants, path resolvers ("#c/snarf",
#      "#c/wsys/<N>/wctl"), and read/write dispatches.
#
# Grep-only (no QEMU boot). Same shape as
# scripts/test_de_windowshade_guard.sh — fast, deterministic, calls out
# the exact broken link by name.
#
# Pass marker:  PASS: DE snarf/wctl primitives intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

SNARF_SRC="sys/src/9/port/devsnarf.ad"
WSYS_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"

fail=0

fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

require_file() {
    if [ ! -f "$1" ]; then
        fail_link "source file missing: $1"
        return 1
    fi
    return 0
}

require_file "$SNARF_SRC" || true
require_file "$WSYS_SRC"  || true
require_file "$NAMEC_SRC" || true
if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE snarf/wctl guard — required source file(s) missing" >&2
    exit 1
fi

# --- /dev/snarf clipboard ----------------------------------------------------
if ! grep -Eq "^def[[:space:]]+devsnarf_read" "$SNARF_SRC"; then
    fail_link "snarf: devsnarf_read() definition gone"
fi
if ! grep -Eq "^def[[:space:]]+devsnarf_write\(off:" "$SNARF_SRC"; then
    fail_link "snarf: devsnarf_write() is gone or is no longer" \
              "offset-addressed (a chunked writer would clobber itself)"
fi
# 64 KiB cap is the spec'd ceiling — assert it stayed.
if ! grep -Eq "SNARF_MAX[[:space:]]*:[[:space:]]*uint64[[:space:]]*=[[:space:]]*65536" "$SNARF_SRC"; then
    fail_link "snarf: SNARF_MAX 64 KiB cap is gone or changed"
fi
# Backing buffer must exist with the same 64 KiB extent.
if ! grep -Eq "snarf_buf:[[:space:]]*Array\[65536" "$SNARF_SRC"; then
    fail_link "snarf: snarf_buf[65536] backing array gone"
fi

# --- /dev/wsys/<N>/wctl per-window control -----------------------------------
if ! grep -Eq "^def[[:space:]]+devwsys_wctl_write" "$WSYS_SRC"; then
    fail_link "wctl: devwsys_wctl_write() definition gone"
fi
if ! grep -Eq "^def[[:space:]]+devwsys_wctl_read" "$WSYS_SRC"; then
    fail_link "wctl: devwsys_wctl_read() definition gone"
fi
# Three verbs must all parse — the verb strings appear as literals in
# the parser.
if ! grep -q '"resize"' "$WSYS_SRC"; then
    fail_link "wctl: resize verb literal gone"
fi
if ! grep -q '"move"' "$WSYS_SRC"; then
    fail_link "wctl: move verb literal gone"
fi
if ! grep -q '"focus"' "$WSYS_SRC"; then
    fail_link "wctl: focus verb literal gone"
fi
# Both focus modes must be recognised.
if ! grep -q '"click"' "$WSYS_SRC"; then
    fail_link "wctl: 'click' focus mode literal gone"
fi
if ! grep -q '"sloppy"' "$WSYS_SRC"; then
    fail_link "wctl: 'sloppy' focus mode literal gone"
fi
# Per-window storage backing the focus verb.
for arr in wsys_wctl_focus wsys_wctl_serial; do
    if ! grep -Eq "${arr}:[[:space:]]*Array" "$WSYS_SRC"; then
        fail_link "wctl: per-window storage ${arr}[] gone"
    fi
done
# THE resize/move INVARIANT (not its spelling): both verbs must reach the
# LIVE geometry sink, and the status line must render the LIVE rect. They
# used to read and write a private wsys_wctl_x/y/w/h store that nothing
# else in the system touched, so `wctl resize`/`move` silently did nothing
# and every window read back as "0 0 0 0 click". A surface that lies is
# worse than one that errors, so the store is gone and this guards the
# wiring that replaced it.
if ! grep -Eq "^def[[:space:]]+_wsys_apply_geometry" "$WSYS_SRC"; then
    fail_link "wctl: _wsys_apply_geometry() sink gone — geometry has no single authority"
fi
if [ "$(awk '/^def devwsys_wctl_write/,/^def _wctl_emit_i64/' "$WSYS_SRC" \
        | grep -c '_wsys_apply_geometry(')" -lt 2 ]; then
    fail_link "wctl: resize/move no longer APPLY geometry (they must not park numbers nobody reads)"
fi
if ! grep -A 40 '^def devwsys_wctl_read' "$WSYS_SRC" | grep -q 'wsys_win_x\['; then
    fail_link "wctl: the status line no longer reports the LIVE window rect"
fi
# Compositor-facing accessor: per-window focus mode.
if ! grep -Eq "^def[[:space:]]+wsys_wctl_focus_mode" "$WSYS_SRC"; then
    fail_link "wctl: wsys_wctl_focus_mode() accessor gone — compositor can't read per-window focus policy"
fi

# --- namec.ad wiring ---------------------------------------------------------
# DEV_ constants.
if ! grep -Eq "^DEV_SNARF:[[:space:]]*int32" "$NAMEC_SRC"; then
    fail_link "namec: DEV_SNARF constant gone"
fi
if ! grep -Eq "^DEV_WSYS_WCTL:[[:space:]]*int32" "$NAMEC_SRC"; then
    fail_link "namec: DEV_WSYS_WCTL constant gone"
fi
# Import lines bring the backends into scope.
if ! grep -q "from sys.src.port9.port.devsnarf import" "$NAMEC_SRC"; then
    fail_link "namec: devsnarf import gone"
fi
if ! grep -q "devwsys_wctl_write" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_wctl_write not imported"
fi
if ! grep -q "devwsys_wctl_read" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_wctl_read not imported"
fi
# Path resolvers.
if ! grep -q '"#c/snarf"' "$NAMEC_SRC"; then
    fail_link "namec: #c/snarf path lookup gone"
fi
if ! grep -q '"/wctl"' "$NAMEC_SRC"; then
    fail_link "namec: /dev/wsys/<N>/wctl path lookup gone"
fi
# Read + write dispatches (both surfaces).
if ! grep -q "devsnarf_read(off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devsnarf_read dispatch gone"
fi
# The write dispatch must pass the OFFSET through. Pinning the exact old
# argument list here ("devsnarf_write(buf, count)") was worse than useless: it
# was green for the whole time /dev/snarf silently discarded every chunk but
# the last of a multi-write (the shell's `echo text > /dev/snarf` writes the
# payload and its newline separately, so the clipboard ended up holding "\n"),
# and it went RED for the fix. Assert the invariant, not the spelling.
if ! grep -q "devsnarf_write(off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devsnarf_write dispatch gone, or no longer passes the" \
              "write offset (a chunked write then clobbers earlier chunks)"
fi
if ! grep -q "devsnarf_primary_write(off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devsnarf_primary_write dispatch gone, or no longer" \
              "passes the write offset"
fi
if ! grep -q "devsnarf_primary_read(off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devsnarf_primary_read dispatch gone"
fi
if ! grep -q "devwsys_wctl_read(wid, off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_wctl_read dispatch gone"
fi
if ! grep -q "devwsys_wctl_write(wid, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_wctl_write dispatch gone"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE snarf/wctl primitives BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE snarf/wctl primitives intact"
exit 0
