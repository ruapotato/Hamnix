#!/usr/bin/env bash
# scripts/test_xargs.sh — verify the native `xargs` (user/xargs.ad).
#
# xargs reads items from stdin and SPAWNS a real child per batch through
# the same Plan-9 fork/exec/wait spine hamsh uses for foreground externals
# (lib.p9 spawn + sys_waitpid), so this is an on-device QEMU gate: a host
# shim can't fork the target. Drives hamsh over serial and asserts on the
# guest's OWN output. Cross-checked against GNU xargs:
#
#   printf 'a\nb\nc\n' | xargs echo        -> "a b c"
#   printf 'a\0b\0'    | xargs -0 echo     -> "a b"       (NUL-delimited)
#   ... | xargs -n1 echo LINE              -> "LINE a" per item (per spawn)
#   printf 'a\nb\n' | xargs -I NN echo pre-NN-post -> "pre-a-post" per line
#   printf 'hi\n'  | xargs                 -> "hi"        (default cmd echo)
#   printf ''      | xargs -r echo NOPE    -> nothing     (-r skips empty)
#   printf ''      | xargs echo YES        -> "YES"       (empty runs once)
#   printf 'x\n'   | xargs false; $status  -> 1           (exit propagated)
#
# HARNESS NOTES: the -0 input uses SINGLE quotes so hamsh passes '\0' to
# printf verbatim (double quotes mangle it to a literal '0'); printf emits
# a real NUL for '\0' (user/printf.ad). The -I token is alphanumeric 'NN'
# because hamsh reserves '{ }' for block syntax and rewrites '@'.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_xargs] (1/4) Build userland"
bash scripts/build_user.sh

echo "[test_xargs] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_xargs] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "[test_xargs] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 480 \
    -- \
       'echo WARMUP' 2 \
       'echo X1_BEGIN; printf "a\nb\nc\n" | xargs echo; echo X1_END' 3 \
       "echo X2_BEGIN; printf 'a\0b\0' | xargs -0 echo; echo X2_END" 3 \
       'echo X3_BEGIN; printf "a\nb\nc\n" | xargs -n1 echo LINE; echo X3_END' 4 \
       'echo X4_BEGIN; printf "a\nb\n" | xargs -I NN echo pre-NN-post; echo X4_END' 3 \
       'echo X5_BEGIN; printf "hi\n" | xargs; echo X5_END' 3 \
       'echo X6_BEGIN; printf "" | xargs -r echo NOPE; echo X6_END' 3 \
       'echo X7_BEGIN; printf "" | xargs echo YES; echo X7_END' 3 \
       'echo X8_BEGIN; printf "x\n" | xargs false; echo XRC=$status; echo X8_END' 3 \
       'echo X9_BEGIN; printf "x\n" | xargs true; echo YRC=$status; echo X9_END' 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_xargs] --- captured output ---"
cat "$LOG"
echo "[test_xargs] --- end output ---"

fail=0
# Clean the serial log: drop kernel timestamp lines, runtime banners,
# task-exit notices, hamsh heartbeat + prompt/echo lines, strip ANSI,
# collapse newlines+tabs to single spaces, squeeze runs.
cleaned=$(
    sed -E \
        -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        -e 's/\[runtime:[a-zA-Z0-9_]*\] _start//g' \
        -e 's/task: pid -*[0-9]* exited \(code=-*[0-9]*\)//g' \
        -e 's/\[hamsh-alive\][^[:cntrl:]]*//g' \
        "$LOG" \
    | grep -av -E '^\[[0-9]{6}\]|hamsh\$' \
    | tr -c 'A-Za-z0-9_,.>/;:={}+ \n\t-' ' ' \
    | tr '\n\t' '  ' \
    | tr -s ' '
)
# Drop the lone "f" glyph the runtime banner leaves before a tool's first
# byte (same fixup as the other coreutils gates).
cleaned=$(echo "$cleaned" | sed -E 's/ f( f)* / /g' | tr -s ' ')

check() {
    local needle="$1" label="$2"
    if echo "$cleaned" | grep -F -q "$needle"; then
        echo "[test_xargs] OK: $label"
    else
        echo "[test_xargs] MISS: $label — '$needle' not seen"
        fail=1
    fi
}

# 1. whitespace/newline split, single batch appended to echo.
check "X1_BEGIN a b c X1_END" "xargs echo -> a b c"
# 2. -0 splits on NUL (printf emits real NUL bytes for \0).
check "X2_BEGIN a b X2_END" "xargs -0 echo -> a b"
# 3. -n1 spawns the command once per item (fixed arg LINE repeats).
check "X3_BEGIN LINE a LINE b LINE c X3_END" "xargs -n1 -> per-item spawn"
# 4. -I substitutes the token in the arg template, one invocation/line.
#    Token 'NN' (alphanumeric — hamsh reserves '{}' for block syntax and
#    mangles '@'); template 'pre-NN-post' -> 'pre-a-post' / 'pre-b-post'.
check "X4_BEGIN pre-a-post pre-b-post X4_END" "xargs -I NN -> pre-a-post pre-b-post"
# 5. default command (none given) is echo.
check "X5_BEGIN hi X5_END" "xargs (default echo) -> hi"
# 6. -r: empty input runs nothing (BEGIN/END adjacent, no NOPE output).
check "X6_BEGIN X6_END" "xargs -r on empty -> no run"
# 7. empty input WITHOUT -r runs the command once (with no items).
check "X7_BEGIN YES X7_END" "xargs on empty -> runs once (YES)"
# 8. a non-zero child exit propagates into xargs's status.
check "XRC=1" "non-zero child exit propagated (false -> 1)"
# 9. a zero child exit -> status 0.
check "YRC=0" "zero child exit -> status 0 (true)"

# Count guest markers: zero begin/end markers => the gate never really ran
# (dead-boot false-red guard). Require the bookends we asserted above.
if [ "$fail" -ne 0 ]; then
    echo "[test_xargs] RESULT: FAIL"
    exit 1
fi
echo "[test_xargs] RESULT: PASS (qemu rc=$rc)"
exit 0
