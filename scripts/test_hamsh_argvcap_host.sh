#!/usr/bin/env bash
# scripts/test_hamsh_argvcap_host.sh — FAST, QEMU-free host gate for the
# SILENT-PARTIAL-ACTION class in hamsh: an operation that does part of its
# work and reports success.
#
# THE BUG THIS EXISTS FOR (2026-07-28). _argv_push_cstr simply `return`ed
# once argv was full:
#
#     if argv_n + 1 >= ARGV_MAX:      # ARGV_MAX was 64
#         return
#
# so argument 64 onward vanished with no error, no status and no message.
# `rm *` in a 200-file directory unlinked a handful of files and exited 0 —
# the user believed the directory was empty. Every glob-fed tool (cp, mv,
# chmod, tar) had the same shape. Not a crash and not a wrong answer: a
# HALF-DONE one, reported as complete.
#
# WHY THE ASSERTIONS BELOW ARE SHAPED THE WAY THEY ARE
# The reason this survived so long is that the command EXITED 0. So no case
# here asserts on exit status. Each one asserts on the OBSERVABLE EFFECT:
# how many words actually reached the command, whether the command ran at
# all, whether the alias/def is really there afterwards.
#
# Drive seam: the same shell source that runs as /init, compiled for
# x86_64-linux and fed over a stdin pipe with --no-echo — identical to
# scripts/test_hamsh_nosilentwrong_host.sh. The device-side end-to-end
# proof (a real 230-file directory, a real `rm *`, and a real count of what
# survived) is scripts/test_hamsh_rmglob_ondevice.sh; host-gate-green is
# not device-working.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_argvcap_host"
mkdir -p "$OUT"
fail=0

echo "[argvcap-host] compiling hamsh for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsh.ad -o "$BIN" 2>"$OUT/argvcap_compile.log"; then
    echo "[argvcap-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/argvcap_compile.log"; exit 1
fi
echo "[argvcap-host] PASS host hamsh compiled -> $BIN"

echo "[argvcap-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamsh.ad -o "$OUT/hamsh_argvcap_native.elf" \
        2>"$OUT/argvcap_native.log"; then
    echo "[argvcap-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/argvcap_native.log"; exit 1
fi
echo "[argvcap-host] PASS native hamsh still compiles (device build unaffected)"

DUMP="$OUT/argvcap_dump.txt"
# run <script-text-on-stdin>
run() { printf '%s\nexit\n' "$1" | timeout 120 "$BIN" --no-echo >"$DUMP" 2>&1; }

want() {
    if grep -qF -- "$1" "$DUMP"; then
        echo "[argvcap-host] OK: $2"
    else
        echo "[argvcap-host] WRONG (want '$1'): $2"
        tail -n 12 "$DUMP"
        fail=1
    fi
}
nowant() {
    if grep -qF -- "$1" "$DUMP"; then
        echo "[argvcap-host] WRONG (must NOT contain '$1'): $2"
        tail -n 12 "$DUMP"
        fail=1
    else
        echo "[argvcap-host] OK: $2"
    fi
}

# ================================================================ case 1
# THE REGRESSION TEST FOR THE REPORTED BUG, at the argv seam.
# A command with 200 arguments must deliver ALL 200. Counting is the whole
# point: the pre-fix shell delivered 62 of them and said nothing.
# (62, not 63, because the line editor's own buffer clipped the tail first —
# see case 4.)
N=200
ARGS=$(python3 -c "print(' '.join('a%d' % i for i in range(1, $N + 1)))")
run "echo HEAD $ARGS TAIL"
got=$(tr ' ' '\n' <"$DUMP" | grep -c '^a[0-9]*$')
if [ "$got" = "$N" ]; then
    echo "[argvcap-host] OK: case 1a: all $N arguments reached the command (got $got)"
else
    echo "[argvcap-host] WRONG: case 1a: only $got of $N arguments reached the command"
    fail=1
fi
want "TAIL" "case 1b: the LAST argument is present (it used to be dropped silently)"

# ================================================================ case 2
# Overflow must be LOUD *and* SAFE. `y` is a 3000-element list, well past
# ARGV_MAX=2048, interpolated into command position. Two things must hold:
# the shell must say why, and the command must NOT RUN AT ALL — a partial
# `rm` is worse than a refused one.
run "$(printf 'echo CASE2_BEFORE\ny = range(3000)\necho CASE2_RAN OVERFLOWED $y\necho CASE2_AFTER\n')"
want "CASE2_BEFORE" "case 2a: the session is healthy before the overflow"
want "argv: too many arguments" \
     "case 2b: argv overflow RAISES and names the limit"
nowant "CASE2_RAN" \
     "case 2c: the over-long command did NOT run (no partial action)"
want "CASE2_AFTER" "case 2d: the session survives the refusal"

# ================================================================ case 3
# ALIAS. The 65th distinct alias used to be dropped while `alias x=y` still
# reported success, so the alias simply never fired — surfacing much later
# as "command not found". Assert on the alias FIRING, not on the exit code.
alias_script() {
    local n="$1" i
    for ((i = 1; i <= n; i++)); do echo "alias ax$i='echo AFIRED$i'"; done
}
run "$(alias_script 200; echo 'ax200')"
want "AFIRED200" "case 3a: the 200th alias is really defined and fires"
run "$(alias_script 520; echo 'echo CASE3_ALIVE')"
want "alias: too many aliases" \
     "case 3b: past ALIAS_MAX the definition FAILS LOUDLY, naming the limit"
want "CASE3_ALIVE" "case 3c: the session survives a refused alias"

# ================================================================ case 4
# INPUT LINE. Over-long lines were truncated at 1023 bytes and the
# SHORTENED command then ran — the argv bug reached through the reader.
# A truncated line must run NOTHING.
LONGARGS=$(python3 -c "print(' '.join('b%d' % i for i in range(1, 900)))")
run "$(printf 'echo CASE4_MARK %s DIDRUN\n' "$LONGARGS")"
want "input line too long" "case 4a: an over-long input line is reported"
nowant "CASE4_MARK" "case 4b: the truncated line ran NOTHING (not a short version of it)"

# ================================================================ case 5
# DEF. The 33rd `def` was silently ignored; the session then failed at the
# CALL with "undefined name", miles from the cause. Assert the function is
# callable, and that exhaustion is reported AT the def.
def_script() {
    local n="$1" i
    for ((i = 1; i <= n; i++)); do echo "def dx$i() { return $i }"; done
}
run "$(def_script 100; echo 'echo CASE5 ${ dx100() }')"
want "CASE5 100" "case 5a: the 100th def is registered and callable"
# Pre-fix, the 33rd+ def no-op'd AND call_user_fn returned a silent nil for
# the unregistered name, so `${ dx100() }` printed NOTHING and the script
# carried on with an empty value. Both halves must now be loud.
run "$(printf 'echo CASE5B ${ never_defined_fn() }\necho CASE5B_ALIVE\n')"
want "call to undefined function 'never_defined_fn'" \
     "case 5b2: calling an unregistered function RAISES instead of yielding nil"
want "CASE5B_ALIVE" "case 5b3: the session survives the undefined call"
run "$(def_script 520; echo 'echo CASE5_ALIVE')"
want "def: too many functions" \
     "case 5c: past FN_MAX the def FAILS LOUDLY at the def, naming the limit"
want "CASE5_ALIVE" "case 5d: the session survives a refused def"

# ================================================================ case 6
# `rm *` — the reported reproducer — did not even PARSE. A leading glob
# metacharacter always reached the operator dispatch and lexed as OP_STAR,
# so `rm *` and `ls *.txt` were "parse error: unexpected token after
# command"; only globs starting with an ident (`f*`, `./*`) worked. The
# fix must NOT cost multiplication, so both halves are asserted here.
run "$(printf 'echo C6A *\necho C6B *.txt\necho C6C f*\nfor q in * { echo C6D $q }\n')"
want "C6A *"     "case 6a: a bare '*' argument parses (rm */ls * are typeable)"
want "C6B *.txt" "case 6b: a leading-glob word '*.txt' parses"
want "C6C f*"    "case 6c: an ident-led glob still parses"
want "C6D *"     "case 6d: 'for q in *' parses"
run "$(printf 'x = 3\ny = 4\necho C6E ${ x * y }\necho C6F ${ x * 2 }\necho C6G ${ 2 ** 3 }\nz = x * y\necho C6H $z\n')"
want "C6E 12" 'case 6e: "x * y" is still multiplication, not a glob'
want "C6F 6"  'case 6f: "x * 2" is still multiplication'
want "C6G 8"  'case 6g: "2 ** 3" is still exponentiation'
want "C6H 12" "case 6h: multiplication in an assignment RHS is unaffected"

# ================================================================ case 7
# DICTIONARIES, the same defect one seam over. v_dict_set returns 0 when the
# shared list/dict element pool is at LISTELEM_MAX, and all three callers —
# `d[k] = v`, `d.get(k, default)` (documented to STORE the default) and
# `update()` — dropped that status. The pair was not stored, the caller was
# told it was, and the very next read of the same key handed back the
# default again: a dict that silently refuses to remember.
#
# NOTE ON REACHABILITY. In the shipping shell VAL_MAX (the value arena)
# exhausts a few cells BEFORE LISTELEM_MAX does, so today the observable
# raise carries the arena's name rather than the pool's. That is exactly
# why the assertions below are on the EFFECT — the store stops, LOUDLY,
# naming a limit, and the session survives — and not on one string. The
# v_dict_set checks are the second line of defence for the day the ratio
# changes; the ledger entry is retired either way.
run "$(printf 'echo C7_BEFORE\nd = {}\nn = 0\nwhile n < 20000 {\nd[n] = n\nn = n + 1\n}\necho C7_AFTER\n')"
want "C7_BEFORE" "case 7a: the session is healthy before the dict overflow"
want "exhausted" \
     "case 7b: a dict store past capacity RAISES rather than silently not storing"
want "16384" \
     "case 7c: the raise NAMES the limit and its value"
want "C7_AFTER" "case 7d: the session survives the refused dict store"

echo
if [ "$fail" = "0" ]; then
    echo "[argvcap-host] PASS — no silently truncated argument vector, alias, def, input line or dict store"
    exit 0
fi
echo "[argvcap-host] FAIL"
exit 1
