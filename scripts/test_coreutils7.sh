#!/usr/bin/env bash
# scripts/test_coreutils7.sh - verify the native sum / sha1sum / arch /
# unlink / link / pathchk tools added to Hamnix's init-namespace userland
# (#143 native-userland batch).
#
# Drives hamsh through one scenario per new tool against deterministic
# inputs seeded in /tmp, asserting the exact bytes a Linux user would
# expect (cross-checked against GNU coreutils 9.7 on the host):
#
#   sha1sum:  printf abc | sha1sum -> a9993e36...  -   (40-hex + "  -")
#             sha1sum /tmp/hw      -> 22596363...  /tmp/hw
#   sum:      printf abc | sum     -> "16556 1"        (BSD, %05d checksum)
#             printf abc | sum -s  -> "294 1"          (SysV additive)
#             sum /tmp/hw          -> "03762 1 /tmp/hw"
#   arch:     arch                 -> "x86_64"
#   unlink:   unlink a real file   -> rc 0; a missing file -> rc 1; the
#             file's contents (ZZUL token) must be GONE afterwards.
#   link:     link A B; cat B      -> B carries A's bytes (LINKDATA)
#   pathchk:  -p good_name.txt     -> rc 0
#             -p bad:name          -> rc 1 (nonportable ':')
#             -p <15-char comp>    -> rc 1 (NAME_MAX 14); default -> rc 0
#             -P -- -lead          -> rc 1 (leading '-')
#
# Exit-status assertions use hamsh's `$status`. Whitespace-bearing output is
# squeezed by the serial-log cleaner, so multi-space GNU fields collapse
# to single spaces (checksum zero-padding survives — it's real digits).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_coreutils7] (1/4) Build userland"
bash scripts/build_user.sh

echo "[test_coreutils7] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_coreutils7] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "[test_coreutils7] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 480 \
    -- \
       'echo WARMUP' 2 \
       'printf "hello world\n" > /tmp/hw; printf "LINKDATA" > /tmp/lk1; echo SEEDA' 3 \
       'printf "ZZUL" > /tmp/ul; echo SEEDB' 2 \
       'echo S1A_BEGIN; printf "abc" | sha1sum; echo S1A_END' 3 \
       'echo S1F_BEGIN; sha1sum /tmp/hw; echo S1F_END' 3 \
       'echo SUB_BEGIN; printf "abc" | sum; echo SUB_END' 3 \
       'echo SUS_BEGIN; printf "abc" | sum -s; echo SUS_END' 3 \
       'echo SUF_BEGIN; sum /tmp/hw; echo SUF_END' 3 \
       'echo AR_BEGIN; arch; echo AR_END' 3 \
       'echo UL_BEGIN; unlink /tmp/ul; echo UL_RC=$status; cat /tmp/ul; echo UL_MID; unlink /tmp/nope; echo ULN_RC=$status; echo UL_END' 4 \
       'echo LK_BEGIN; link /tmp/lk1 /tmp/lk2; echo LK_RC=$status; cat /tmp/lk2; echo LK_END2' 4 \
       'echo PCG_BEGIN; pathchk -p good_name.txt; echo PCG_RC=$status; echo PCG_END' 3 \
       'echo PCP_BEGIN; pathchk -p "bad:name"; echo PCP_RC=$status; echo PCP_END' 3 \
       'echo PCL_BEGIN; pathchk -p abcdefghijklmno; echo PCL_RC=$status; echo PCL_END' 3 \
       'echo PCD_BEGIN; pathchk abcdefghijklmno; echo PCD_RC=$status; echo PCD_END' 3 \
       'echo PCE_BEGIN; pathchk -P -- -lead; echo PCE_RC=$status; echo PCE_END' 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_coreutils7] --- captured output ---"
cat "$LOG"
echo "[test_coreutils7] --- end output ---"

fail=0
cleaned=$(
    sed -E \
        -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        -e 's/\[runtime:[a-zA-Z0-9_]*\] _start//g' \
        -e 's/task: pid -*[0-9]* exited \(code=-*[0-9]*\)//g' \
        -e 's/\[hamsh-alive\][^[:cntrl:]]*//g' \
        "$LOG" \
    | grep -av -E '^\[[0-9]{6}\]|hamsh\$' \
    | tr -c 'A-Za-z0-9_,.>/;:=+ \n\t-' ' ' \
    | tr '\n\t' '  ' \
    | tr -s ' '
)
cleaned=$(echo "$cleaned" | sed -E 's/ f( f)* / /g' | tr -s ' ')

check() {
    local needle="$1" label="$2"
    if echo "$cleaned" | grep -F -q "$needle"; then
        echo "[test_coreutils7] OK: $label"
    else
        echo "[test_coreutils7] MISS: $label — '$needle' not seen"
        fail=1
    fi
}

nocheck() {
    local needle="$1" label="$2"
    if echo "$cleaned" | grep -F -q "$needle"; then
        echo "[test_coreutils7] BAD: $label — '$needle' unexpectedly present"
        fail=1
    else
        echo "[test_coreutils7] OK: $label"
    fi
}

# ---- sha1sum ----------------------------------------------------------
# The runtime banner can glue a stray byte before the tool's first byte,
# so the unique 40-hex digest (grep -F substring) is the load-bearing
# proof — its presence at all means the SHA-1 was computed correctly.
check "a9993e364706816aba3e25717850c26c9cd0d89d" "sha1sum(abc) digest"
check "22596363b3de40b06f981fb85d82312e8c0ed511 /tmp/hw" "sha1sum(/tmp/hw) digest + name"

# ---- sum --------------------------------------------------------------
check "SUB_BEGIN 16556 1 SUB_END" "sum(abc) BSD checksum 16556, 1 block"
check "SUS_BEGIN 294 1 SUS_END"   "sum -s(abc) SysV checksum 294, 1 block"
check "03762 1 /tmp/hw"           "sum(/tmp/hw) BSD 03762, 1 block, name"

# ---- arch -------------------------------------------------------------
check "AR_BEGIN x86_64 AR_END" "arch -> x86_64"

# ---- unlink -----------------------------------------------------------
check "UL_RC=0"   "unlink real file exits 0"
check "ULN_RC=1"  "unlink missing file exits 1"
nocheck "ZZUL"    "unlinked file contents are gone"

# ---- link -------------------------------------------------------------
check "LK_RC=0"           "link creates hard link, exits 0"
check "LINKDATA LK_END2"  "linked file carries source bytes"

# ---- pathchk ----------------------------------------------------------
check "PCG_RC=0" "pathchk -p good_name.txt valid (exit 0)"
check "PCP_RC=1" "pathchk -p bad:name nonportable char (exit 1)"
check "PCL_RC=1" "pathchk -p 15-char component too long (exit 1)"
check "PCD_RC=0" "pathchk default 15-char component ok (exit 0)"
check "PCE_RC=1" "pathchk -P leading-dash component (exit 1)"

if [ "$fail" -ne 0 ]; then
    echo "[test_coreutils7] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_coreutils7] PASS"
