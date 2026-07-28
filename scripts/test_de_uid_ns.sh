#!/usr/bin/env bash
#
# ON-DEMAND *AND CURRENTLY RED*: not in ci_battery_manifest.txt because it
# FAILS on 55c842b9 (2026-07-28 unregistered-gate sweep, <0.1 s).
#
# THE FAILURE LOOKS LIKE A REAL PERMISSION REGRESSION, and it is the most
# alarming thing this sweep turned up:
#     FAIL: namec: DEV_WSYS_NS  no longer routed to devwsys_readonly_write
#           (writes to /ns now accepted!)
#     FAIL: namec: DEV_WSYS_UID no longer routed to devwsys_readonly_write
#           (writes to /uid now accepted!)
# /dev/wsys/<N>/uid and /dev/wsys/<N>/ns are SNAPSHOT surfaces — a window's
# effective uid and its namespace listing. They were deliberately wired to
# devwsys_readonly_write so a write is rejected at the file-server boundary
# (the Plan 9 "perms live in the file server, not in mode bits" invariant).
# Something in namec's dev-ID routing stopped sending those two IDs there, so
# the kernel now ACCEPTS writes to a read-only capability surface. Triage
# this against namec/dev-ID changes before deciding the gate is stale — a
# renamed handler would be gate rot, a lost route is a privilege bug.
# scripts/test_de_uid_ns.sh — structural guard for the TODO DE close-out:
# per-window uid + ns visibility on the rio `#w/` per-process namespace.
#
# What landed (kernel surface, no userland changes):
#
#   1. /dev/wsys/<N>/uid  (DEV_WSYS_UID)
#      Snapshot read returns "<uid>\n" — the WINDOW's effective uid (the
#      bound task's uid, not the reader's). A `newshell hostowner`
#      running INSIDE the window stamps the bound task's uid via
#      SYS_SETUID / SYS_SETUID_AUTH (set_current_task_uid in
#      kernel/sched/core.ad), so reading `#w/uid` from outside reflects
#      the elevation — NO bespoke setuid hook needed; the next read
#      walks task_lookup_by_pid + task_uid_at.
#
#   2. /dev/wsys/<N>/ns   (DEV_WSYS_NS)
#      Snapshot read returns a textual dump of the WINDOW'S mtab — the
#      bound task's pgrp, resolved via task_pgrp. Walks MountEntry
#      slots, emits "bind: <from> <to>\n" / "mount: <from> 9p\n" lines.
#
#   3. Both leaves are read-ONLY. Writes funnel into
#      devwsys_readonly_write — already in the readonly branch of the
#      namec write dispatch (DEV_WSYS_UID / DEV_WSYS_NS listed there).
#
# Grep-only (no QEMU). Same shape as scripts/test_de_snarf_wctl.sh —
# fast, deterministic, calls out the exact broken link by name.
#
# Pass marker:  PASS: DE per-window uid/ns visibility intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

WSYS_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
CORE_SRC="kernel/sched/core.ad"

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

require_file "$WSYS_SRC"  || true
require_file "$NAMEC_SRC" || true
require_file "$CORE_SRC"  || true
if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE uid/ns guard — required source file(s) missing" >&2
    exit 1
fi

# --- devwsys.ad: per-window renderers & wrappers -----------------------------

# The uid renderer must take a wid (per-window, not global).
if ! grep -Eq "^def[[:space:]]+_wsys_render_uid\(wid:[[:space:]]*int32" "$WSYS_SRC"; then
    fail_link "uid: _wsys_render_uid lost its wid arg (regressed to wid-less / reader's-uid)"
fi
# The ns renderer must take a wid (dump the WINDOW's mtab, not reader's).
if ! grep -Eq "^def[[:space:]]+_wsys_render_ns\(wid:[[:space:]]*int32" "$WSYS_SRC"; then
    fail_link "ns: _wsys_render_ns lost its wid arg (regressed to pgrp_current-only)"
fi

# The uid wrapper must take a wid and ENOENT-gate on wsys_wid_in_use,
# matching the pid/text leaves.
if ! grep -Eq "^def[[:space:]]+devwsys_uid_read\(wid:[[:space:]]*int32" "$WSYS_SRC"; then
    fail_link "uid: devwsys_uid_read lost its wid arg"
fi
if ! grep -Eq "^def[[:space:]]+devwsys_ns_read\(wid:[[:space:]]*int32" "$WSYS_SRC"; then
    fail_link "ns: devwsys_ns_read lost its wid arg"
fi

# The uid resolution path must walk task_lookup_by_pid + task_uid_at —
# that's what makes SYS_SETUID inside the window visible without a
# setuid hook.
if ! grep -q "task_lookup_by_pid" "$WSYS_SRC"; then
    fail_link "uid: devwsys.ad no longer imports / uses task_lookup_by_pid"
fi
if ! grep -q "task_uid_at" "$WSYS_SRC"; then
    fail_link "uid: devwsys.ad no longer uses task_uid_at — the SETUID-visibility chain is broken"
fi
# The ns resolution path must walk task_pgrp on the bound task — that's
# what makes the dump the WINDOW's namespace, not the reader's.
if ! grep -q "task_pgrp" "$WSYS_SRC"; then
    fail_link "ns: devwsys.ad no longer uses task_pgrp — ns leaks the reader's namespace"
fi

# core.ad must still export the three accessors we lean on.
if ! grep -Eq "^def[[:space:]]+task_lookup_by_pid" "$CORE_SRC"; then
    fail_link "core: task_lookup_by_pid accessor gone"
fi
if ! grep -Eq "^def[[:space:]]+task_uid_at" "$CORE_SRC"; then
    fail_link "core: task_uid_at accessor gone"
fi
if ! grep -Eq "^def[[:space:]]+task_pgrp" "$CORE_SRC"; then
    fail_link "core: task_pgrp accessor gone"
fi
# And the SETUID stamp point — set_current_task_uid — must still exist
# so the elevation a `newshell hostowner` does inside the window
# actually lands on the task we'll then read back via task_uid_at.
if ! grep -Eq "^def[[:space:]]+set_current_task_uid" "$CORE_SRC"; then
    fail_link "core: set_current_task_uid stamp point gone — newshell hostowner has nowhere to record the new uid"
fi

# --- namec.ad: per-window dispatch + read-only write gate --------------------

# DEV_WSYS_UID / DEV_WSYS_NS constants intact.
if ! grep -Eq "^DEV_WSYS_UID:[[:space:]]*int32" "$NAMEC_SRC"; then
    fail_link "namec: DEV_WSYS_UID constant gone"
fi
if ! grep -Eq "^DEV_WSYS_NS:[[:space:]]*int32" "$NAMEC_SRC"; then
    fail_link "namec: DEV_WSYS_NS constant gone"
fi
# Path resolvers still recognise /uid and /ns suffixes.
if ! grep -q '"/uid"' "$NAMEC_SRC"; then
    fail_link "namec: /dev/wsys/<N>/uid path lookup gone"
fi
if ! grep -q '"/ns"' "$NAMEC_SRC"; then
    fail_link "namec: /dev/wsys/<N>/ns path lookup gone"
fi
# Read dispatches must pass wid into BOTH leaves now.
if ! grep -q "devwsys_uid_read(wid, off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_uid_read dispatch no longer passes wid (regressed to global uid)"
fi
if ! grep -q "devwsys_ns_read(wid, off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_ns_read dispatch no longer passes wid (regressed to caller's pgrp)"
fi
# Write to /uid and /ns must be REJECTED — both must remain listed in
# the readonly_write branch.
if ! awk '/devwsys_readonly_write\(buf, count\)/{found=1} END{exit !found}' "$NAMEC_SRC"; then
    fail_link "namec: devwsys_readonly_write fallthrough gone"
fi
# Both constants must appear in the readonly OR-chain (which terminates
# at devwsys_readonly_write).
if ! grep -A 10 "DEV_WSYS_OUTPUT or dev_type == DEV_WSYS_NS" "$NAMEC_SRC" \
        | grep -q "devwsys_readonly_write"; then
    fail_link "namec: DEV_WSYS_NS no longer routed to devwsys_readonly_write (writes to /ns now accepted!)"
fi
if ! grep -A 10 "DEV_WSYS_PID or dev_type == DEV_WSYS_UID" "$NAMEC_SRC" \
        | grep -q "devwsys_readonly_write"; then
    fail_link "namec: DEV_WSYS_UID no longer routed to devwsys_readonly_write (writes to /uid now accepted!)"
fi

# --- vfs.ad: the `#w` rio bind must still rewrite into #c/wsys/<wid>/ ---------
# So /uid and /ns reach the dispatch via the same path #w/uid → #c/wsys/<N>/uid.
if [ -f fs/vfs.ad ]; then
    if ! grep -q "wsys_wid_for_current" fs/vfs.ad; then
        fail_link "vfs: #w rio rewrite (wsys_wid_for_current) gone — #w/uid and #w/ns can't reach the dispatch"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE per-window uid/ns visibility BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE per-window uid/ns visibility intact"
exit 0
