#!/usr/bin/env bash
# scripts/test_patch_host.sh — FAST, QEMU-free host gate for the native
# `patch` tool (user/patch.ad): applies unified + normal diffs to a file,
# proven by ROUND-TRIP with our own `diff` and by INTEROP with GNU patch.
#
# It compiles user/patch.ad (and user/diff.ad) for the x86_64-linux Adder
# target so the SAME source that ships on-device runs as a host process —
# sys_open opens real file operands read-only and sys_open_write
# creates/truncates the real target file. Then:
#
#   ROUND-TRIP:  native diff -u A B -> patch.diff; native patch A < patch.diff
#                must reproduce B byte-for-byte. Same for normal diffs and
#                for -R (reverse-patch B back to A).
#   INTEROP:     apply a GNU-produced `diff -u` with native patch and get the
#                same file as GNU patch; apply a native-diff patch with GNU
#                patch. Covers -pN, a multi-hunk patch, an offset-relocated
#                hunk, and a failing-hunk case (exit 1).
#
# Also confirms the native on-device binary still compiles clean.
# Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
PBIN="$OUT/patch_host"
DBIN="$OUT/diff_host"
FX="$OUT/patch_fx"
mkdir -p "$OUT" "$FX"
fail=0

command -v patch >/dev/null 2>&1 || { echo "[patch-host] SKIP: no system patch"; exit 0; }
command -v diff  >/dev/null 2>&1 || { echo "[patch-host] SKIP: no system diff";  exit 0; }

echo "[patch-host] compiling user/patch.ad for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/patch.ad "$PBIN" 2>"$OUT/patch_compile.log"; then
    echo "[patch-host] FAIL: host build did not compile"; cat "$OUT/patch_compile.log"; exit 1
fi
echo "[patch-host] PASS host build compiled -> $PBIN"

echo "[patch-host] compiling user/diff.ad for x86_64-linux ..."
if ! adder_bin x86_64-linux user/diff.ad "$DBIN" 2>"$OUT/patch_diff_compile.log"; then
    echo "[patch-host] FAIL: diff host build did not compile"; cat "$OUT/patch_diff_compile.log"; exit 1
fi

# Native on-device binary must still compile clean.
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/patch.ad -o "$OUT/patch_native.elf" 2>"$OUT/patch_native.log"; then
    echo "[patch-host] PASS native patch compiles (x86_64-adder-user)"
else
    echo "[patch-host] FAIL native patch did not compile"; cat "$OUT/patch_native.log"; fail=1
fi

pass() { echo "[patch-host] PASS $1"; }
bad()  { echo "[patch-host] FAIL $1"; fail=1; }

# ---- fixtures ----
printf 'alpha\nbeta\ngamma\ndelta\nepsilon\n'           > "$FX/a"
printf 'alpha\nbeta\nINSERTED\ngamma\ndelta\nepsilon\n' > "$FX/b"      # mid-file insert
seq 1 20                                                 > "$FX/c"
{ echo HEAD; seq 2 5; echo CHANGED6; seq 7 14; seq 16 20; echo TAIL; } > "$FX/d"  # multi-hunk

# ---- ROUND-TRIP with our own diff --------------------------------------

# unified A->B
"$DBIN" -u "$FX/a" "$FX/b" > "$FX/u.diff"
cp "$FX/a" "$FX/w"; "$PBIN" "$FX/w" < "$FX/u.diff" >/dev/null 2>&1
cmp -s "$FX/w" "$FX/b" && pass "round-trip unified (diff -u A B | patch == B)" \
                       || bad  "round-trip unified"

# unified reverse B->A
cp "$FX/b" "$FX/w"; "$PBIN" -R "$FX/w" < "$FX/u.diff" >/dev/null 2>&1
cmp -s "$FX/w" "$FX/a" && pass "round-trip unified -R (reverse == A)" \
                       || bad  "round-trip unified -R"

# unified multi-hunk C->D
"$DBIN" -u "$FX/c" "$FX/d" > "$FX/u2.diff"
cp "$FX/c" "$FX/w"; "$PBIN" "$FX/w" < "$FX/u2.diff" >/dev/null 2>&1
cmp -s "$FX/w" "$FX/d" && pass "round-trip unified multi-hunk (== D)" \
                       || bad  "round-trip unified multi-hunk"
cp "$FX/d" "$FX/w"; "$PBIN" -R "$FX/w" < "$FX/u2.diff" >/dev/null 2>&1
cmp -s "$FX/w" "$FX/c" && pass "round-trip unified multi-hunk -R (== C)" \
                       || bad  "round-trip unified multi-hunk -R"

# normal A->B
"$DBIN" "$FX/a" "$FX/b" > "$FX/n.diff"
cp "$FX/a" "$FX/w"; "$PBIN" "$FX/w" < "$FX/n.diff" >/dev/null 2>&1
cmp -s "$FX/w" "$FX/b" && pass "round-trip normal (diff A B | patch == B)" \
                       || bad  "round-trip normal"
cp "$FX/b" "$FX/w"; "$PBIN" -R "$FX/w" < "$FX/n.diff" >/dev/null 2>&1
cmp -s "$FX/w" "$FX/a" && pass "round-trip normal -R (reverse == A)" \
                       || bad  "round-trip normal -R"

# ---- INTEROP with GNU patch --------------------------------------------

# GNU diff -u, applied by native patch, must match GNU patch's result.
diff -u "$FX/c" "$FX/d" > "$FX/gnu.diff"
cp "$FX/c" "$FX/rn"; "$PBIN" -o "$FX/rn_out" "$FX/rn" < "$FX/gnu.diff" >/dev/null 2>&1
cp "$FX/c" "$FX/rg"; patch -o "$FX/rg_out" "$FX/rg" "$FX/gnu.diff"   >/dev/null 2>&1
cmp -s "$FX/rn_out" "$FX/rg_out" && pass "interop: native patch of GNU -u == GNU patch" \
                                 || bad  "interop native-applies-GNU"
cmp -s "$FX/rn_out" "$FX/d"      && pass "interop: native patch of GNU -u == D" \
                                 || bad  "interop native-applies-GNU vs D"

# Native diff -u, applied by GNU patch, must yield D.
"$DBIN" -u "$FX/c" "$FX/d" > "$FX/nat.diff"
cp "$FX/c" "$FX/wg"; patch "$FX/wg" < "$FX/nat.diff" >/dev/null 2>&1
cmp -s "$FX/wg" "$FX/d" && pass "interop: GNU patch of native diff -u == D" \
                        || bad  "interop GNU-applies-native"

# ---- -pN strip ---------------------------------------------------------
mkdir -p "$FX/pd/a" "$FX/pd/b"
printf 'l1\nl2\nl3\n'      > "$FX/pd/a/foo"
printf 'l1\nCHANGED\nl3\n' > "$FX/pd/b/foo"
( cd "$FX/pd" && diff -u a/foo b/foo > p1.diff
  cp a/foo foo
  "$(cd ../.. && pwd)/patch_host" -p1 foo < p1.diff >/dev/null 2>&1 )
cmp -s "$FX/pd/foo" "$FX/pd/b/foo" && pass "-p1 strip (target from header)" \
                                   || bad  "-p1 strip"

# ---- offset-relocated hunk ---------------------------------------------
{ echo X0; echo X1; cat "$FX/c"; } > "$FX/cshift"
{ echo X0; echo X1; cat "$FX/d"; } > "$FX/dshift"
cp "$FX/cshift" "$FX/w"; "$PBIN" "$FX/w" < "$FX/gnu.diff" >/dev/null 2>&1
cmp -s "$FX/w" "$FX/dshift" && pass "offset search relocates a drifted hunk" \
                            || bad  "offset search"

# ---- failing hunk -> exit 1, file untouched ----------------------------
printf 'totally\ndifferent\nfile\ncontent\nhere\n' > "$FX/mismatch"
cp "$FX/mismatch" "$FX/w"; "$PBIN" "$FX/w" < "$FX/gnu.diff" >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && cmp -s "$FX/w" "$FX/mismatch"; then
    pass "failing hunk -> exit 1, file left unchanged"
else
    bad "failing hunk (rc=$rc, want 1; file must be unchanged)"
fi

# ---- --dry-run changes nothing -----------------------------------------
cp "$FX/c" "$FX/w"; "$PBIN" --dry-run "$FX/w" < "$FX/gnu.diff" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && cmp -s "$FX/w" "$FX/c"; then
    pass "--dry-run reports success without modifying the file"
else
    bad "--dry-run (rc=$rc, want 0; file must be unchanged)"
fi

# ---- -b backup ---------------------------------------------------------
cp "$FX/a" "$FX/w"; "$PBIN" -b "$FX/w" < "$FX/u.diff" >/dev/null 2>&1
if cmp -s "$FX/w" "$FX/b" && cmp -s "$FX/w.orig" "$FX/a"; then
    pass "-b backup: result == B and .orig == original"
else
    bad "-b backup"
fi

if [ "$fail" = 0 ]; then
    echo "[patch-host] ALL PASS"; exit 0
fi
echo "[patch-host] FAILURES present"; exit 1
