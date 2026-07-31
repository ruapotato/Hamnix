#!/usr/bin/env bash
#
# REGISTERED in scripts/ci_battery_manifest.txt (2026-07-28, <0.1 s, no QEMU).
#
# This gate was unregistered and red in the 2026-07-28 sweep, with an alarming
# failure text ("writes to /uid now accepted!"). Triage verdict: GATE ROT, not a
# privilege bug. The route to devwsys_readonly_write was never removed or
# renamed; the two assertions were `grep -A 10` windows anchored on a
# continuation line of a multi-line `if`, so they tracked LINE DISTANCE and fell
# off the window as the read-only OR-chain grew. Full evidence is in the block
# above those assertions, further down this file. Registered now precisely
# because it rotted while dark.
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
#
# GATE-ROT FIX (2026-07-28). This was:
#     grep -A 10 "DEV_WSYS_OUTPUT or dev_type == DEV_WSYS_NS" | grep -q readonly
#     grep -A 10 "DEV_WSYS_PID or dev_type == DEV_WSYS_UID"   | grep -q readonly
# i.e. it anchored on ONE SPECIFIC CONTINUATION LINE of a multi-line `if`
# condition and asserted the chain's terminating `return` sat within 10 lines of
# it. That is a check on LINE DISTANCE, not on routing. The read-only OR-chain in
# _devtab_write() grows by one line every time a new read-only DE surface lands,
# so the terminator drifted to NS+19 / UID+18 and both greps went red — while the
# route they were guarding was not merely intact but had been EXTENDED.
#
# Evidence this is rot and not a lost route:
#   * `git log -S DEV_WSYS_UID -- sys/src/9/port/namec.ad` returns exactly ONE
#     commit ever (9747a0b6, its introduction). Nothing removed or renamed it.
#   * Replaying the two old greps over every historical revision of namec.ad
#     shows the NS check flipping red at 2caa9512 and the UID check at 13575674
#     — both commits that ADDED a surface (SESSUI, DESKTOP) to this same chain.
#     Two earlier reds self-HEALED when a later commit reflowed the identical
#     clauses onto fewer lines: proof the signal was line count, not semantics.
#   * `grep -n readonly` over namec.ad + devwsys.ad finds exactly one such
#     function, `devwsys_readonly_write`, with its original signature — there is
#     no renamed replacement handler.
#   * _devtab_write's fallthrough is `return -1`, so even a genuinely unrouted
#     dev ID would REJECT the write. The old failure text ("writes now
#     accepted!") could not have been true for this file under any edit.
#
# The replacement extracts the chain STRUCTURALLY — from its `if dev_type ==
# DEV_WSYS or` head through its terminating `return` — and asserts both
# constants are inside it AND that it returns devwsys_readonly_write. Immune to
# further growth of the chain, and stronger than the old check because it also
# pins the terminator rather than merely finding the name somewhere nearby.
RO_CHAIN="$(awk '
    /^[[:space:]]*if dev_type == DEV_WSYS or/ { inb = 1 }
    inb { print }
    inb && /^[[:space:]]*return / { exit }
' "$NAMEC_SRC")"
[ -n "$RO_CHAIN" ] || fail_link "namec: the read-only DE-surface OR-chain is gone entirely"
if ! grep -q "return devwsys_readonly_write(buf, count)" <<<"$RO_CHAIN"; then
    fail_link "namec: the read-only OR-chain no longer terminates in devwsys_readonly_write"
fi
if ! grep -q "dev_type == DEV_WSYS_NS" <<<"$RO_CHAIN"; then
    fail_link "namec: DEV_WSYS_NS no longer routed to devwsys_readonly_write (writes to /ns now accepted!)"
fi
if ! grep -q "dev_type == DEV_WSYS_UID" <<<"$RO_CHAIN"; then
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
