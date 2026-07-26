#!/usr/bin/env bash
# scripts/test_grep_host.sh — FAST, QEMU-free host gate for the native
# `grep` tool (user/grep.ad + the shared lib/regex.ad engine): real
# EXTENDED regular expressions (`-E`/egrep), cross-checked byte-for-byte
# against GNU grep with the SAME arguments.
#
# It compiles user/grep.ad for the x86_64-linux Adder target (so the
# SAME source that ships on-device runs as a host process — the runtime
# maps sys_open/read/write/close to real syscalls; files are opened with
# the 1-arg sys_open thunk so real file operands work), then for each
# fixture asserts our stdout AND exit status are identical to GNU grep's.
#
# Fixtures cover EXACTLY the implemented ERE subset + flags:
#   ERE: a+ , ab?c , (foo|bar) , [0-9]{2,4} , {n} , {n,} , ^start ,
#        end$ , [[:alpha:]]+ , alternation with groups , . , * , [..] ,
#        [^..] , escaped metachars.
#   flags: -E -i -v -c -n -o -w -x -F -e (repeatable), FILE operands +
#          stdin, multi-file filename prefixing.
# Deliberately NOT gated (unimplemented / divergent): back-references,
# malformed `{}` intervals (GNU errors; we treat `{` as literal),
# POSIX leftmost-longest for length-overlapping alternations.
#
# Also confirms the native on-device binary still compiles clean.
# Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/grep_host"
FX="$OUT/grep_fx"
mkdir -p "$OUT" "$FX"
fail=0

# Resolve a GENUINE GNU grep — this dev host wraps `grep` as a `ugrep`
# shell function, so probe explicit binaries and demand "GNU grep".
GREP=""
for cand in /usr/bin/grep /bin/grep "$(command -v grep 2>/dev/null)"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if "$cand" --version 2>/dev/null | head -1 | grep -q "GNU grep"; then
        GREP="$cand"; break
    fi
done
if [ -z "$GREP" ]; then
    echo "[grep-host] SKIP: no GNU grep found for cross-check"; exit 0
fi
echo "[grep-host] cross-checking against $($GREP --version | head -1)"

echo "[grep-host] compiling user/grep.ad for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/grep.ad -o "$BIN" 2>"$OUT/grep_compile.log"; then
    echo "[grep-host] FAIL: host build did not compile"; cat "$OUT/grep_compile.log"; exit 1
fi
echo "[grep-host] PASS host build compiled -> $BIN"

# Native on-device binary must still compile clean.
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/grep.ad -o "$OUT/grep_native.elf" 2>"$OUT/grep_native.log"; then
    echo "[grep-host] PASS native grep compiles (x86_64-adder-user)"
else
    echo "[grep-host] FAIL native grep did not compile"; cat "$OUT/grep_native.log"; fail=1
fi

# ---- fixtures ----
printf 'aaa\nbaaac\nno a here\nAAA\n'                > "$FX/aa"
printf 'foo\nbar\nfoobar\nbaz\n'                     > "$FX/words"
printf 'cat dog\ncatalog\nscat\nthe cat sat\n'       > "$FX/pets"
printf 'x12\nab1234567\n99\n1\n'                      > "$FX/nums"
printf 'start of line\nnot start\nrestart here\n'     > "$FX/anchor"
printf 'hello world\nHELLO\n123abc\n'                > "$FX/mix"
printf 'aa\naaa\naaaa\na\n'                           > "$FX/runs"
printf 'abab\nabc\nba\n'                              > "$FX/ab"
printf 'color\ncolour\ncolora\n'                     > "$FX/colour"

# STDIN cross-check: $1=label, $2=fixture, then the grep arg vector.
cross() {
    local label="$1"; local fx="$2"; shift 2
    local g o grc orc
    g=$("$GREP" "$@" < "$FX/$fx" 2>/dev/null); grc=$?
    o=$("$BIN"  "$@" < "$FX/$fx" 2>/dev/null); orc=$?
    if [ "$g" != "$o" ]; then
        echo "[grep-host] FAIL $label: stdout differs from GNU grep"
        echo "--- GNU ---"; printf '%s\n' "$g"
        echo "--- ours ---"; printf '%s\n' "$o"
        fail=1; return
    fi
    if [ "$grc" != "$orc" ]; then
        echo "[grep-host] FAIL $label: exit=$orc want=$grc"; fail=1; return
    fi
    echo "[grep-host] PASS $label (matches GNU, exit=$orc)"
}

# FILE-operand cross-check (exercises the real sys_open path).
cross_file() {
    local label="$1"; shift
    local g o grc orc
    local -a args=()
    for a in "$@"; do args+=("${a//@FX@/$FX}"); done
    g=$("$GREP" "${args[@]}" 2>/dev/null); grc=$?
    o=$("$BIN"  "${args[@]}" 2>/dev/null); orc=$?
    if [ "$g" = "$o" ] && [ "$grc" = "$orc" ]; then
        echo "[grep-host] PASS $label (file, matches GNU, exit=$orc)"
    else
        echo "[grep-host] FAIL $label: file out/exit differ (GNU exit=$grc ours=$orc)"
        echo "--- GNU ---"; printf '%s\n' "$g"
        echo "--- ours ---"; printf '%s\n' "$o"
        fail=1
    fi
}

# ---- ERE feature coverage ----
cross "a+ (one-or-more)"      aa     -E 'a+'
cross "ab?c (optional)"       ab     -E 'ab?c'
cross "(foo|bar) alternation" words  -E '(foo|bar)'
cross "[0-9]{2,4} interval"   nums   -E -o '[0-9]{2,4}'
cross "a{3} exact"            runs   -E -o 'a{3}'
cross "a{2,} at-least"        runs   -E -o 'a{2,}'
cross "^start anchor"         anchor -E '^start'
cross "line\$ end anchor"     anchor -E 'line$'
cross "[[:alpha:]]+ posix"    mix    -E -o '[[:alpha:]]+'
cross "(cat|dog)s? grouping"  pets   -E -o '(cat|dog)s?'
cross ". any-char"            pets   -E 'c.t'
cross "co*l star"             colour -E -o 'colou*r'
cross "[^0-9] neg class"      mix    -E -o '[^0-9]+'
cross "escaped metachar"      colour -E 'colora'

# ---- flag coverage ----
cross "-i ignore-case"        mix    -E -i 'hello'
cross "-v invert"             words  -E -v '(foo|bar)'
cross "-c count"              aa     -E -c 'a'
cross "-n line-number"        words  -E -n 'bar'
cross "-o only-matching"      nums   -E -o '[0-9]+'
cross "-w word"              pets   -E -w 'cat'
cross "-x whole-line"         nums   -E -x '[0-9]+'
cross "-F fixed a+"           aa     -F 'a+'
cross "-in bundled"           mix    -in 'hello'
cross "-vn combined"          words  -E -vn 'foo|bar'
cross "-wo combined"          pets   -E -wo '[a-z]+'
cross "-e repeated"           words  -E -e 'foo' -e 'baz'
cross "no-match exit 1"       words  -E 'zzzz'

# ---- FILE operands (real sys_open) ----
cross_file "single file"      -E 'foo|bar' '@FX@/words'
cross_file "multi-file prefix" -E 'cat' '@FX@/pets' '@FX@/words'
cross_file "multi-file -n"    -E -n 'a' '@FX@/aa' '@FX@/words'
cross_file "multi-file -c"    -E -c 'a' '@FX@/aa' '@FX@/words'
cross_file "missing file exit2" -E 'x' '@FX@/does_not_exist'

if [ "$fail" = 0 ]; then
    echo "[grep-host] ALL PASS"; exit 0
fi
echo "[grep-host] FAILURES present"; exit 1
