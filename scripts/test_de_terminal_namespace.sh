#!/usr/bin/env bash
#
# REGISTERED in scripts/ci_battery_manifest.txt (2026-07-28, <0.1 s, no QEMU).
#
# This gate was unregistered and red in the 2026-07-28 sweep, failing with
# "etc/rc.de-user must NOT bind '#distro' (hostowner-only surface)". Triage
# verdict: STALE EXPECTATION, not a privilege leak. rc.de-user never binds
# #distro ambiently — only inside captured `ns clean { … }` templates, which is
# exactly what the documented invariant permits, and what this gate REQUIRES of
# rc.de-hostowner two sections down. The full disproof (including that the
# kernel applies no principal check on #distro at all, so there is no hostowner
# boundary to leak) is in the AMBIENT vs CAPTURED block below.
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
#   1. etc/rc.de-user exists with the expected user-surface binds in its
#      AMBIENT namespace, and no rc.de profile binds '#distro' ambiently
#      (it may only appear inside a captured `ns clean { … }` template).
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

# AMBIENT vs CAPTURED (2026-07-28 correction — read this before editing).
# ----------------------------------------------------------------------
# An rc.de profile has TWO namespace scopes and they are NOT the same thing:
#
#   * AMBIENT   — top-level `bind` statements. These take effect immediately
#                 and are the capabilities the spawned DE program actually
#                 runs with.
#   * CAPTURED  — `<name> = ns clean { … }` template blocks. A captured
#                 template grants NOTHING until an explicit `enter <name>
#                 { … }`, and what it enters is a DIFFERENT namespace.
#
# The project invariant is about the AMBIENT scope only. docs/rootfs_partition.md
# ("Don't bind the distro/ subtree into the init namespace's /": `#distro` "must
# only be bound at / inside the `ns clean { ... }` linux recipe — NOT in the init
# Pgrp") and etc/rc.boot.full ("the distro subtree must NEVER appear in PID 1's
# AMBIENT namespace … reachable ONLY through the hermetic runtime namespace")
# both state it that way. Neither says `#distro` is hostowner-only.
#
# This section previously asserted `! grep -qF "'#distro'"` and `! grep -qE
# '^linux = ns'` over the WHOLE FILE, i.e. it forbade the captured template too.
# That expectation is PROVABLY WRONG, on three independent grounds:
#
#   1. SELF-CONTRADICTION. Section 2 below REQUIRES etc/rc.de-hostowner to
#      contain `^linux = ns clean`, `^debian = ns clean` and `bind '#distro' /`.
#      The old rule forbade in rc.de-user the byte-identical construct it
#      demanded in rc.de-hostowner — so "captured `#distro` template" cannot be
#      the hostowner marker it was claimed to be.
#   2. rc.de-hostowner — the HOSTOWNER profile — does not ambient-bind
#      `#distro` either (see its own comment: "Per the rc.boot.full isolation
#      invariant we do NOT bind '#distro' into the ambient namespace — only
#      inside the captured hermetic ns at enter-time"). Both profiles treat
#      `#distro` identically, so the presence of the template distinguishes
#      nothing about privilege.
#   3. The kernel applies NO principal check on binding `#distro`: it is a
#      named root resolved in sys/src/9/port/chan.ad (_freeze_named_source /
#      _word_is_distro) and do_bind in sys/src/9/port/syschan.ad has no uid
#      check — syschan.ad explicitly whitelists `#distro` as a legitimate
#      unprobeable bind source. There is no hostowner boundary to leak.
#
# The template was added to rc.de-user deliberately by 5b486aa6 so the DE
# terminal can `enter linux { … }` at all (etc/rc.de-wayland does the same and
# then RUNS a Debian binary that way, by design). The gate predates it (b4904bff)
# and was never updated.
#
# So the assertion is retargeted at the invariant that is actually real, and in
# the process made STRICTLY STRONGER in two ways: the required-bind checks now
# have to be satisfied in the AMBIENT scope (previously a bind hidden inside a
# captured template would have satisfied them), and the `#distro` prohibition is
# now enforced on ALL THREE rc.de profiles rather than only rc.de-user.

# Print only the AMBIENT lines of an rc profile — everything outside a
# `<name> = ns clean { … }` capture block.
ambient_lines() {
    awk '
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*ns[[:space:]]+clean[[:space:]]*\{/ {
            depth++; next
        }
        depth > 0 { if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) depth--; next }
        { print }
    ' "$1"
}

# Required binds for a usable regular-user namespace, in the AMBIENT scope.
# Each grep is a single line: "bind '#X' /path" so the regex is conservative.
RC_USER_AMBIENT="$(ambient_lines "$RC_USER")"
[ -n "$RC_USER_AMBIENT" ] || fail "$RC_USER has no ambient lines (unbalanced 'ns clean {' block?)"
for bind in \
    "bind '#c' /dev" \
    "bind '#p' /proc" \
    "bind '#s' /srv" \
    "bind '#/' /n" \
    "bind '#I' /net" \
    "bind '#w' /dev/win"; do
    printf '%s\n' "$RC_USER_AMBIENT" | grep -qF "$bind" \
        || fail "$RC_USER missing required AMBIENT bind: $bind"
done
ok "rc.de-user has all required regular-user binds, in the ambient namespace"

# `#distro` must never be bound AMBIENTLY in any rc.de profile — only inside a
# captured `ns clean { … }` template, entered on demand. Comment lines are
# excluded by requiring an actual `bind` statement (optional flags, e.g. -r).
for rcf in etc/rc.de-user etc/rc.de-hostowner etc/rc.de-wayland; do
    [ -f "$rcf" ] || continue
    if ambient_lines "$rcf" \
            | grep -qE "^[[:space:]]*bind([[:space:]]+-[a-zA-Z]+)*[[:space:]]+'#distro'"; then
        fail "$rcf binds '#distro' into the AMBIENT namespace — the distro subtree" \
             "must be reachable ONLY through a captured 'ns clean { … }' template" \
             "(docs/rootfs_partition.md, etc/rc.boot.full)"
    fi
done
ok "no rc.de profile binds '#distro' ambiently (hermetic-ns-only invariant holds)"

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
#
# GATE-ROT FIX (2026-07-28): this used to match `spawn\(hamsh_path` only. Commit
# 1ce9eed3 ("de: fix long-session address-space leak — DE window launcher uses
# spawn_detached") switched daemon_spawn_window_prog's two call sites to
# spawn_detached(hamsh_path, …) so the never-wait4'd DE children are published
# as DETACHED zombies and reclaimed by reap_orphan_zombies. The launcher's
# BINARY is still /bin/hamsh and argv still carries rc.de-user + prog — exactly
# what this assertion is about — so the old regex was pinning the reaping
# discipline, not the namespace wiring it claims to guard. Accept either
# launcher; a future third variant should be added here rather than silently
# re-reddening this gate. (This failure was previously INVISIBLE: the gate is
# `set -e` + `exit 1` and died at the earlier '#distro' assertion above, so
# fixing that one is what surfaced this.)
grep -qE 'spawn(_detached)?\(hamsh_path' "$HAMUID" \
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
