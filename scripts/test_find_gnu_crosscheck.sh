#!/usr/bin/env bash
# scripts/test_find_gnu_crosscheck.sh
#
# On-device cross-check of native `user/find.ad` against GNU `find`.
#
# WHY ON-DEVICE (not the host x86_64-linux trick sort/sed/diff use):
# find's two load-bearing primitives — directory enumeration (p9_listdir,
# a "NAME\n" stream) and metadata (sys_stat_p9, the 9P Dir record) — are
# kernel services with NO faithful host-syscall equivalent (Linux read()
# on a directory fd returns EISDIR; getdents has a different shape). A
# host build would have to exercise a DIFFERENT enumeration path than the
# one that ships, so the strong test is the real boot path.
#
# METHOD: build an identical fixture TREE two ways —
#   * on the host, under $WORK/ft, and run GNU `find` on it (the oracle);
#   * in the booted guest, under /tmp/ft (a real tmpfs: `mkdir` makes
#     GENUINE empty directories, so even -empty on a dir is exercised).
# For each predicate we compare the SORTED, root-normalised path set
# (guest "/tmp/ft/…" and host "ft/…" both reduce to "ft/…") and assert
# they are byte-identical. Predicate coverage: -name / -iname (glob incl.
# a [class]) / -type f / -type d / -maxdepth / -mindepth / -size (c-unit)
# / -empty (file AND empty dir) / multiple start paths / -print0.
#
# Registered in scripts/ci_battery_manifest.txt.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

# NOTE: the sourced helpers above may enable `set -e`; the assertion loop
# below runs pipelines whose grep legitimately finds nothing (exit 1), so
# we deliberately do NOT want -e killing the script mid-comparison. Keep
# -u/-o pipefail for real errors; guard the extraction pipelines with
# `|| true`.
set +e
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
WORK="$PROJ_ROOT/build/find_crosscheck"

fail() { echo "[test_find] FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------
# 1. Build the host reference tree. The construction MUST mirror the
#    guest hamsh commands byte-for-byte so file sizes match: hamsh
#    `echo X > f` writes "X\n"; `touch f` makes a 0-byte file.
# ---------------------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK/ft/sub/deep" "$WORK/ft/ed"
printf 'aaaaa\n'     > "$WORK/ft/a.txt"       # 6 bytes
printf 'bb\n'        > "$WORK/ft/b.log"       # 3 bytes
: >                    "$WORK/ft/empty.txt"   # 0 bytes (empty file)
printf 'nested\n'    > "$WORK/ft/sub/c.txt"   # 7 bytes
printf 'markdownx\n' > "$WORK/ft/sub/d.md"    # 10 bytes
printf 'deep\n'      > "$WORK/ft/sub/deep/e.txt"  # 5 bytes
# ft/ed stays a genuinely empty directory.

# ---------------------------------------------------------------------
# 2. Case table. Each case = an id, the start-path list (relative to the
#    tree root, space-separated), and the predicate string. Guest and
#    host share the predicate string verbatim; only the root differs.
# ---------------------------------------------------------------------
CASE_ID=()      ; CASE_PATHS=() ; CASE_PREDS=()
add_case() { CASE_ID+=("$1"); CASE_PATHS+=("$2"); CASE_PREDS+=("$3"); }

# Globs are SINGLE-QUOTED so neither bash (host oracle, via eval) nor
# hamsh (guest) glob-expands them against the cwd — find must receive the
# literal pattern.
add_case name      "ft" "-name '*.txt'"
add_case iname     "ft" "-iname '*.TXT'"
add_case typef     "ft" "-type f"
add_case typed     "ft" "-type d"
add_case maxdepth1 "ft" "-maxdepth 1"
add_case mindepth2 "ft" "-mindepth 2"
# Size args are single-quoted: hamsh's tokenizer treats a bare leading
# '+' / '-' as an operator ("unexpected token after command"), so the
# threshold must reach find as a literal string — exactly how a hamsh
# user writes it. bash's eval (host oracle) strips the quotes too.
add_case size6c    "ft" "-type f -size '6c'"
add_case sizep6c   "ft" "-type f -size '+6c'"
add_case sizem3c   "ft" "-type f -size '-3c'"
add_case empty     "ft" "-empty"
add_case class     "ft" "-name '[ab]*'"
add_case multi     "ft/sub ft/ed" "-type d"

# ---------------------------------------------------------------------
# 3. Compute the GNU-find oracle for every case (run from $WORK so paths
#    come out "ft/…", matching the guest after /tmp/ stripping).
# ---------------------------------------------------------------------
declare -A EXPECT
for i in "${!CASE_ID[@]}"; do
    id="${CASE_ID[$i]}"
    EXPECT["$id"]="$( cd "$WORK" && \
        eval "find ${CASE_PATHS[$i]} ${CASE_PREDS[$i]}" \
        2>/dev/null | LC_ALL=C sort -u )"
done

# ---------------------------------------------------------------------
# 4. Build userland + a hamsh-as-init image and boot it.
# ---------------------------------------------------------------------
echo "[test_find] (1/3) Build userland + hamsh-as-init initramfs"
bash scripts/build_user.sh >/dev/null || fail "build_user failed"
for tool in find mkdir touch echo; do
    [ -x "build/user/${tool}.elf" ] || fail "build/user/${tool}.elf missing"
done
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || fail "build_initramfs failed"

echo "[test_find] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || fail "kernel compile failed"

echo "[test_find] (3/3) Boot QEMU + build the fixture tree + run find"
LOG=$(mktemp /tmp/test-find.XXXXXX.log)
trap '[ "${FIND_KEEP_LOG:-0}" = 1 ] || rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT
[ "${FIND_KEEP_LOG:-0}" = 1 ] && echo "[test_find] serial log kept at: $LOG"

# Assemble the driven command list: build the tree, echo a built marker,
# then run each case bracketed by unique B/E markers so the per-case
# output block can be sliced out of the serial log.
CMDS=(
    "mkdir /tmp/ft"                       1
    "mkdir /tmp/ft/sub"                   1
    "mkdir /tmp/ft/sub/deep"             1
    "mkdir /tmp/ft/ed"                   1
    "echo aaaaa > /tmp/ft/a.txt"         1
    "echo bb > /tmp/ft/b.log"            1
    "touch /tmp/ft/empty.txt"           1
    "echo nested > /tmp/ft/sub/c.txt"   1
    "echo markdownx > /tmp/ft/sub/d.md" 1
    "echo deep > /tmp/ft/sub/deep/e.txt" 1
    "echo FT_BUILT"                      2
)
for i in "${!CASE_ID[@]}"; do
    id="${CASE_ID[$i]}"
    # Prefix each start path with /tmp/.
    guest_paths=""
    for pth in ${CASE_PATHS[$i]}; do guest_paths+=" /tmp/$pth"; done
    CMDS+=( "echo FTB_${id}" 1 )
    CMDS+=( "find${guest_paths} ${CASE_PREDS[$i]}" 2 )
    CMDS+=( "echo FTE_${id}" 1 )
done
# -print0 vs -print separator proof on the SAME single-match query:
#   * with -print  the path is a standalone, newline-terminated line;
#   * with -print0 the NUL (not a newline) terminates it, so the path is
#     NOT a whole line by itself — whatever the serial emits next is glued
#     onto the same line.
CMDS+=( "echo FTB_pN" 1 )
CMDS+=( "find /tmp/ft -name empty.txt -print" 1 )
CMDS+=( "echo FTE_pN" 1 )
CMDS+=( "echo FTB_p0" 1 )
CMDS+=( "find /tmp/ft -name empty.txt -print0" 1 )
CMDS+=( "echo FTE_p0" 1 )
CMDS+=( "exit" 2 )

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 360 -- "${CMDS[@]}"
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_find] --- fixture-built marker + a sample block ---"
grep -aF "FT_BUILT" "$LOG" || true
echo "[test_find] ---"

# ---------------------------------------------------------------------
# 5. Assertions.
# ---------------------------------------------------------------------
fails=0

if grep -aqF "TRAP: vector" "$LOG"; then
    echo "[test_find] FAIL: kernel TRAP during run"
    grep -aF "TRAP: vector" "$LOG" | head -3
    fails=$((fails + 1))
fi
if ! grep -aqF "FT_BUILT" "$LOG"; then
    echo "[test_find] FAIL: fixture never built (shell not consuming stdin?)"
    tail -n 80 "$LOG"
    exit 1
fi

# Slice the guest output for one case out of the log: everything between
# the FTB_<id> and FTE_<id> markers, keep only lines that ARE a path
# under /tmp/ft (find's stdout), strip the /tmp/ root, sort -u.
guest_set() {
    local id="$1"
    sed -n "/FTB_${id}\$/,/FTE_${id}\$/p" "$LOG" \
        | tr -d '\r' \
        | grep -aoE '^/tmp/ft[^[:space:]]*' \
        | sed 's#^/tmp/##' \
        | LC_ALL=C sort -u || true
}

for i in "${!CASE_ID[@]}"; do
    id="${CASE_ID[$i]}"
    want="${EXPECT[$id]}"
    got="$(guest_set "$id")"
    if [ "$got" == "$want" ]; then
        echo "[test_find] OK: ${id} matches GNU find"
    else
        echo "[test_find] FAIL: ${id} differs from GNU find"
        echo "  preds : ${CASE_PREDS[$i]}   paths: ${CASE_PATHS[$i]}"
        echo "  gnu   : $(printf '%s' "$want" | tr '\n' '|')"
        echo "  native: $(printf '%s' "$got"  | tr '\n' '|')"
        fails=$((fails + 1))
    fi
done

# -print0 proof. Control: with -print the path IS a standalone line.
pN_standalone="$(sed -n '/FTB_pN$/,/FTE_pN$/p' "$LOG" | tr -d '\r' \
                 | grep -axF '/tmp/ft/empty.txt' | head -1 || true)"
# With -print0 the path must NOT be a standalone (newline-terminated) line,
# yet its text must still be present (glued to the following bytes by NUL).
p0_standalone="$(sed -n '/FTB_p0$/,/FTE_p0$/p' "$LOG" | tr -d '\r' \
                 | grep -axF '/tmp/ft/empty.txt' | head -1 || true)"
p0_present="$(sed -n '/FTB_p0$/,/FTE_p0$/p' "$LOG" | tr -d '\r' \
              | grep -a 'empty.txt' | head -1 || true)"
if [ -z "$pN_standalone" ]; then
    echo "[test_find] FAIL: -print control did not emit a newline-terminated path"
    fails=$((fails + 1))
elif [ -n "$p0_standalone" ] || [ -z "$p0_present" ]; then
    echo "[test_find] FAIL: -print0 did not replace the newline with a NUL"
    fails=$((fails + 1))
else
    echo "[test_find] OK: -print newline vs -print0 NUL separator confirmed"
fi

if [ "$fails" -ne 0 ]; then
    echo "[test_find] FAIL ($fails case(s); qemu rc=$rc)"
    exit 1
fi
echo "[test_find] PASS: native find matches GNU find across ${#CASE_ID[@]} predicates + -print0"
exit 0
