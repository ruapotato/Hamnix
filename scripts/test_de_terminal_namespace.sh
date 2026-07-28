#!/usr/bin/env bash
#
# ON-DEMAND *AND CURRENTLY RED*: not in ci_battery_manifest.txt because it
# FAILS on 55c842b9 (2026-07-28 unregistered-gate sweep, <0.1 s). Everything
# passes except one assertion:
#     FAIL: etc/rc.de-user must NOT bind '#distro' (hostowner-only surface)
# i.e. the REGULAR-USER DE namespace profile currently binds the hostowner-only
# #distro file server, handing every DE terminal a capability it should not
# have. This is the privilege model, not cosmetics — triage against
# etc/rc.de-user and the hostowner/regular-user split before touching the gate.
# scripts/test_de_terminal_namespace.sh — STRUCTURAL guard for the
# DE-terminal namespace plumbing.
#
# The bug: a DE terminal spawned out of hamUId's daemon_spawn_window_prog
# inherited the bare compositor Pgrp. Running `cd / && ls` returned
# nothing — no /bin, no /net, no /dev — i.e. zero capabilities in the
# Plan-9 "files = caps" model. The fix routes every DE window spawn
# through `/bin/hamsh /etc/rc.de-user <real-prog>` (or rc.de-hostowner
# for hostowner elevation) so the regular-user / hostowner namespace
# surface is bound before the real DE program runs.
#
# This is a STRUCTURAL test, not an end-to-end QEMU test. It asserts:
#   1. etc/rc.de-user exists with the expected user-surface binds AND
#      does NOT include the hostowner-only distrofs / linux-ns bindings.
#   2. etc/rc.de-hostowner exists with the hostowner-surface binds
#      AND DOES include the captured linux / debian ns templates.
#   3. user/hamUId.ad's daemon_spawn_window_prog routes through
#      /bin/hamsh /etc/rc.de-user (so the rc lands on every DE window).
#   4. user/hamsh.ad stamps HAMNIX_DE_PROG from argv[2] before sourcing.
#   5. user/hamsh.ad's newshell builtin invokes rc.de-hostowner when the
#      target uid is 1 (hostowner elevation parity).
#
# Why structural and not VM-driven: the DE / installer / hamUId surface
# is a multi-minute build-and-boot loop; this guard locks the wiring
# at every commit. A separate behavioural test_security.sh / DE-hands-on
# QEMU run validates runtime behaviour.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[test_de_terminal_namespace] FAIL: $*" >&2; exit 1; }
ok()   { echo "[test_de_terminal_namespace] OK:   $*"; }

# --- 1. rc.de-user has the regular-user surface ---------------------
RC_USER=etc/rc.de-user
[ -f "$RC_USER" ] || fail "missing $RC_USER"

# Required binds for a usable regular-user namespace. Each grep is a
# single line: "bind '#X' /path" so the regex is conservative.
for bind in \
    "bind '#c' /dev" \
    "bind '#p' /proc" \
    "bind '#s' /srv" \
    "bind '#/' /n" \
    "bind '#I' /net" \
    "bind '#w' /dev/win"; do
    grep -qF "$bind" "$RC_USER" \
        || fail "$RC_USER missing required bind: $bind"
done
ok "rc.de-user has all required regular-user binds"

# Must NOT include hostowner-only bindings. Catching '#distro' OR
# 'ns clean' (the captured linux/debian ns shape) keeps a future
# hand-edit from accidentally leaking the L-shim into a regular-user
# template (the namespace-purity mandate).
if grep -qF "'#distro'" "$RC_USER"; then
    fail "$RC_USER must NOT bind '#distro' (hostowner-only surface)"
fi
if grep -qE "^[[:space:]]*linux[[:space:]]*=[[:space:]]*ns" "$RC_USER"; then
    fail "$RC_USER must NOT capture the linux ns template"
fi
ok "rc.de-user correctly excludes hostowner-only bindings"

# --- 2. rc.de-hostowner has the hostowner surface incl. distrofs ----
RC_HO=etc/rc.de-hostowner
[ -f "$RC_HO" ] || fail "missing $RC_HO"

for bind in \
    "bind '#c' /dev" \
    "bind '#p' /proc" \
    "bind '#s' /srv" \
    "bind '#/' /n" \
    "bind '#I' /net" \
    "bind '#b' /dev/blk" \
    "bind '#w' /dev/win"; do
    grep -qF "$bind" "$RC_HO" \
        || fail "$RC_HO missing required bind: $bind"
done
ok "rc.de-hostowner has all required hostowner binds (incl. #b raw block)"

# Must capture linux + debian ns templates that bind '#distro' / so
# `enter linux { ... }` from an elevated DE terminal reaches the
# Debian tree exactly like the serial shell can.
grep -qE "^[[:space:]]*linux[[:space:]]*=[[:space:]]*ns[[:space:]]+clean" "$RC_HO" \
    || fail "$RC_HO missing 'linux = ns clean { ... }' capture"
grep -qE "^[[:space:]]*debian[[:space:]]*=[[:space:]]*ns[[:space:]]+clean" "$RC_HO" \
    || fail "$RC_HO missing 'debian = ns clean { ... }' capture"
grep -qF "bind '#distro' /" "$RC_HO" \
    || fail "$RC_HO captured ns must bind '#distro' / (L-shim root)"
ok "rc.de-hostowner captures linux/debian ns templates with #distro root"

# --- 3. hamUId routes through hamsh + rc.de-user --------------------
HAMUID=user/hamUId.ad
[ -f "$HAMUID" ] || fail "missing $HAMUID"

grep -qE '"/etc/rc.de-user"' "$HAMUID" \
    || fail "$HAMUID daemon_spawn_window_prog must reference /etc/rc.de-user"
# The spawn itself must call /bin/hamsh as the actual binary, with the
# original prog passed along as a positional argv element.
grep -qE 'spawn\(hamsh_path' "$HAMUID" \
    || fail "$HAMUID must spawn /bin/hamsh (hamsh_path) as the DE-terminal wrapper"
ok "hamUId daemon_spawn_window_prog routes through /bin/hamsh + rc.de-user"

# --- 4. hamsh stamps HAMNIX_DE_PROG from argv[2] --------------------
HAMSH=user/hamsh.ad
[ -f "$HAMSH" ] || fail "missing $HAMSH"

grep -qE 'env_set\(cast\[Ptr\[uint8\]\]\("HAMNIX_DE_PROG"\)' "$HAMSH" \
    || fail "$HAMSH must env_set HAMNIX_DE_PROG from argv[2]"
ok "hamsh main() stamps HAMNIX_DE_PROG from argv[2]"

# --- 5. newshell hostowner sources rc.de-hostowner ------------------
grep -qE '"/etc/rc.de-hostowner"' "$HAMSH" \
    || fail "$HAMSH newshell builtin must invoke /etc/rc.de-hostowner for hostowner target"
ok "hamsh newshell builtin elevates to rc.de-hostowner template"

# --- rc tail prog dispatch ------------------------------------------
# Both templates must invoke $HAMNIX_DE_PROG so the real DE program
# runs after the binds land.
for rc in "$RC_USER" "$RC_HO"; do
    grep -qE '\$HAMNIX_DE_PROG' "$rc" \
        || fail "$rc must dispatch through \$HAMNIX_DE_PROG at its tail"
done
ok "both rc templates dispatch through \$HAMNIX_DE_PROG"

echo "[test_de_terminal_namespace] PASS"
