#!/usr/bin/env bash
# scripts/test_de_home_resolve_host.sh — FAST, QEMU-free host gate for the
# shared home-directory resolver (lib/homedir.ad).
#
# THE BUG THIS GATES (USER report): "the /home/<username>/Desktop does not
# seem to reflect the GUI desktop background."
#
# hamdesktop resolves its icon source as <home>/Desktop and watches that
# directory on a ~1s timer. The watcher was fine; the DIRECTORY was wrong.
# The old chain was $HOME then a hardcoded /home/live — and DE clients are
# spawned by the COMPOSITOR, which gives them no HOME at all (probed on a real
# boot: `cat /env/HOME` -> "file does not exist"), so the hardcode ALWAYS won.
# On the live image `live` IS the session user, so it looked right. On an
# INSTALLED system the user is whatever the installer wizard named them, so
# the GUI desktop watched a directory that was not theirs and nothing the user
# created in their real ~/Desktop ever appeared.
#
# The fix routes resolution through /etc/passwd BY UID. That step can only be
# proven deterministically against a uid that is NOT the live image's 1001 —
# which is what this gate does, with no install and no QEMU: it runs
# hd_parse_passwd_home over a synthetic passwd table and asserts the home
# returned for each uid, including an installed-style account.
#
# Pass marker: RESULT: PASS

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/homedir_host"
mkdir -p "$OUT"
fail=0
pass() { echo "[homedir] PASS $*"; }
bad()  { echo "[homedir] FAIL $*" >&2; fail=1; }

# --- 1. the resolver is wired into the desktop ----------------------------
# A green parser that nothing calls is not a fix. hamdesktop MUST resolve its
# desktop dir through the shared resolver, and must no longer carry its own
# $HOME-only chain.
if grep -q 'from lib.homedir import' user/hamdesktop.ad \
        && grep -q 'hd_resolve_home' user/hamdesktop.ad; then
    pass "hamdesktop resolves its desktop dir through lib/homedir.ad"
else
    bad "hamdesktop does not use the shared home resolver"
fi

# --- 2. host unit test compiles + runs ------------------------------------
echo "[homedir] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux tests/homedir_host.ad "$BIN" 2>"$OUT/homedir_compile.log"; then
    echo "[homedir] FAIL: host harness did not compile"
    cat "$OUT/homedir_compile.log"; echo "[homedir] RESULT: FAIL"; exit 1
fi
pass "host harness compiled -> $BIN"

DUMP="$OUT/homedir_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[homedir] FAIL: host harness exited non-zero"; cat "$DUMP"
    echo "[homedir] RESULT: FAIL"; exit 1
fi
echo "[homedir] ---- resolver output ----"
cat "$DUMP"
echo "[homedir] -------------------------"

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then pass "$msg"; else
        bad "$msg (missing: $pat)"; fi
}

# The live image's user — the ONLY case the old hardcode got right.
assert_grep '^LIVE uid=1001 len=10 home=/home/live$' \
    "uid 1001 (live) resolves to /home/live"
# THE USER-REPORTED CASE: an installed system's wizard account MUST resolve to
# ITS OWN home, never to /home/live.
assert_grep '^INSTALLED uid=1002 len=11 home=/home/bobby$' \
    "KEYSTONE: an installed user's uid resolves to THEIR home, not /home/live"
assert_grep '^REGULAR uid=1000 len=10 home=/home/dave$' \
    "uid 1000 resolves to /home/dave"
assert_grep '^HOSTOWNER uid=1 len=15 home=/home/hostowner$' \
    "the hostowner uid resolves to /home/hostowner"
# An unknown uid must resolve to NOTHING so the caller can fall back — it must
# never silently borrow a neighbouring line's home.
assert_grep '^UNKNOWN uid=4242 len=0 home=<none>$' \
    "an unknown uid resolves to nothing (caller falls back)"
assert_grep '^NOBODY uid=65534 len=12 home=/nonexistent$' \
    "the parser is uid-exact (nobody returns its own field)"
assert_grep '^HOMEDIR_HOST_DONE$' "the harness ran to completion"

# --- 3. no stray /home/live hardcode left in the desktop's resolution -----
# The fallback constant is allowed to survive as a LAST resort, but the
# desktop must not reach it before consulting passwd. Assert the ORDER in the
# shared resolver: $HOME, then passwd, then /home/live.
body=$(sed -n '/^def hd_resolve_home/,/^$/p' lib/homedir.ad)
l_env=$(printf '%s\n' "$body" | grep -n 'hd_env_home(' | head -1 | cut -d: -f1)
l_pw=$(printf '%s\n' "$body"  | grep -n 'hd_home_from_passwd(' | head -1 | cut -d: -f1)
l_fb=$(printf '%s\n' "$body"  | grep -n '"/home/live"' | head -1 | cut -d: -f1)
if [ -n "$l_env" ] && [ -n "$l_pw" ] && [ -n "$l_fb" ] \
        && [ "$l_env" -lt "$l_pw" ] && [ "$l_pw" -lt "$l_fb" ]; then
    pass "hd_resolve_home order is \$HOME -> /etc/passwd(uid) -> /home/live"
else
    bad "hd_resolve_home does not consult /etc/passwd BEFORE the /home/live fallback"
fi

if [ "$fail" -eq 0 ]; then
    echo "[homedir] RESULT: PASS"
    exit 0
fi
echo "[homedir] RESULT: FAIL" >&2
exit 1
