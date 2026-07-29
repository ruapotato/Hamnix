#!/usr/bin/env bash
#
# scripts/test_llvm_kernel_unsafe_link.sh — `unsafe:` must work in KERNEL code
# on the LLVM lane, and no bailed function may be unlinkable.
#
# REGISTERED in scripts/ci_battery_manifest.txt (2026-07-28, ~95 s, no QEMU).
#
# THE BUG THIS PINS (2026-07-28, commit d00aa40c reverted by e638df5a)
# -------------------------------------------------------------------
# Six one-line `unsafe:` annotations were added to kernel functions (the
# documented --check-bounds / --check-arith opt-out). The DEFAULT ship build
# (scripts/build_installer_img.sh -> the LLVM kernel lane) then died at ld:
#
#   ld: build/kllvm/kernel_main_llvm.o: in function `start_kernel_early':
#   kernel_main.ll:(.text+0x5fa927): undefined reference to `__stack_chk_init'
#
# Two independent facts combined:
#   1. `unsafe:` (ND_UNSAFE) was outside the SSA subset, so ssa_lower_stmt
#      BAILED the whole ENCLOSING function; the LLVM lane then emits only a
#      `declare` and leans on the hybrid native_main.o for the definition.
#   2. elf_emit.ad emits every LEADING-UNDERSCORE function as STB_LOCAL
#      ("module-private"). `__stack_chk_init` is a codegen-RESERVED name, so the
#      driver never mangles its leading `_` away -- its native definition is
#      LOCAL, and `ld` cannot bind the LLVM object's UNDEF to it.
# Net: any `_`-prefixed function that bails is UNLINKABLE on the LLVM lane.
# There were ZERO prior `unsafe:` uses in kernel-linked .ad, so this had never
# been hit -- the construct's very first kernel use broke the ship build.
#
# WHY kobjdiff COULD NOT CATCH IT
# -------------------------------
# scripts/test_native_vs_seed_kobjdiff.sh compares NATIVE-vs-SEED codegen for
# the same source. This defect is LLVM-lane-only and is a LINK-RESOLUTION
# failure, so kobjdiff is structurally blind to it: it passed with 0
# divergences across all 11158 functions while the ship build was broken.
# Only an assertion on the LLVM lane's LINK can see it. This is that assertion
# (the sibling of scripts/test_napi.sh PART 1, which does the same job for the
# native x86_64 kernel link).
#
# PART 1 (~1 s) — SSA-SUBSET ASSERTION
#   Compile tests/fixtures/llvm_unsafe_kernel_fn.ad through the LLVM backend
#   and assert `unsafe:` does NOT bail: bailed=0, no `; BAILED`, and both
#   functions are DEFINED (`define`), not merely `declare`d.
#
# PART 2 (~95 s) — WHOLE-KERNEL LLVM LANE LINK
#   Run scripts/build_kernel_llvm.sh over the real init/main.ad closure and
#   assert:
#     2a. NO bailed function name begins with `_` (the unlinkable class).
#     2b. `__stack_chk_init` is DEFINED in the emitted IR (it carries an
#         `unsafe:` block; it was the messenger for this bug).
#     2c. the only undefined references at ld are the lone
#         initramfs_cpio_base/initramfs_cpio_size pair, which the real image
#         build supplies via HAMNIX_INITRAMFS_BLOB (same tolerance as
#         scripts/test_napi.sh PART 1).
#
# Pass marker:  [test_llvm_unsafe] PASS
# Fail marker:  [test_llvm_unsafe] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() {
    echo "[test_llvm_unsafe] FAIL $*"
    exit 1
}

command -v clang-19 >/dev/null 2>&1 || command -v "${CLANG:-clang-19}" >/dev/null 2>&1 \
    || fail "clang-19 not found (LLVM lane toolchain)"
command -v ld >/dev/null 2>&1 || fail "ld not found (apt install binutils)"

# --- host_ac.elf (the self-hosted compiler carrying the LLVM backend) ---
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
if [ ! -x "$HOST_AC" ]; then
    echo "[test_llvm_unsafe] bootstrapping $HOST_AC"
    # shellcheck source=_adder_cc.sh
    source "$PROJ_ROOT/scripts/_adder_cc.sh"
    adder_cc_bootstrap >/dev/null 2>&1 || fail "host_ac.elf bootstrap failed"
fi
[ -x "$HOST_AC" ] || fail "no host_ac.elf at $HOST_AC"

WORK="$PROJ_ROOT/build/llvm_unsafe_test"
rm -rf "$WORK"
mkdir -p "$WORK"

# =======================================================================
# PART 1 — `unsafe:` must stay inside the SSA subset
# =======================================================================
echo "[test_llvm_unsafe] (1/2) SSA-subset check: unsafe: must not bail the enclosing function"
FIX="tests/fixtures/llvm_unsafe_kernel_fn.ad"
[ -f "$FIX" ] || fail "missing fixture $FIX"
FIX_LL="$WORK/fixture.ll"
"$HOST_AC" --backend=llvm --target=x86_64-bare-metal "$FIX" "$FIX_LL" \
    || fail "LLVM-lane compile of $FIX failed"

if grep -q '; BAILED' "$FIX_LL"; then
    grep '; BAILED' "$FIX_LL"
    fail "unsafe: bailed out of the SSA subset (this is the __stack_chk_init regression)"
fi
FIX_STAT="$(grep '; ADDER_STAT' "$FIX_LL" || true)"
echo "[test_llvm_unsafe]   $FIX_STAT"
echo "$FIX_STAT" | grep -q 'bailed=0' || fail "fixture reported a non-zero bail count: $FIX_STAT"
# The private mixer is module-mangled (<modslug>__unsafe_mix); match the suffix.
grep -qE '^define .*@[A-Za-z0-9_]*_unsafe_mix\(' "$FIX_LL" \
    || fail "the unsafe:-carrying function has no 'define' in the emitted IR (declare-only == the bug)"
grep -qE '^define .*@unsafe_fixture_entry\(' "$FIX_LL" \
    || fail "the public caller has no 'define' in the emitted IR"
echo "[test_llvm_unsafe]   OK — unsafe: lowers inline, both functions DEFINED"

# =======================================================================
# PART 2 — whole-kernel LLVM lane: bails must be linkable, link must be clean
# =======================================================================
echo "[test_llvm_unsafe] (2/2) whole-kernel LLVM lane link (init/main.ad closure, ~95 s)"
BUILD_LOG="$WORK/build_kernel_llvm.log"
ADDER_HOST_AC="$HOST_AC" bash scripts/build_kernel_llvm.sh > "$BUILD_LOG" 2>&1
BUILD_RC=$?

KLL="build/kllvm/kernel_main.ll"
[ -f "$KLL" ] || { tail -30 "$BUILD_LOG"; fail "no $KLL produced (LLVM IR emit failed)"; }

grep '; ADDER_STAT' "$KLL" | sed 's/^/[test_llvm_unsafe]   /'

# 2a. UNLINKABLE-BAIL CLASS: a leading-underscore function is emitted STB_LOCAL
#     by elf_emit.ad, so the hybrid native_main.o fallback cannot satisfy the
#     LLVM object's UNDEF for it. Any such bail is a broken link waiting to
#     happen (or, thanks to build_kernel_llvm.sh step 2b, a silently
#     native-executed function). Fix the compiler, don't widen this check.
UBAILS="$(grep '; BAILED @' "$KLL" | sed 's/.*; BAILED @//; s/ .*//' | grep '^_' || true)"
if [ -n "$UBAILS" ]; then
    echo "[test_llvm_unsafe]   leading-underscore bails: $(printf '%s' "$UBAILS" | tr '\n' ' ')"
    fail "a leading-underscore (STB_LOCAL in native) function BAILED the LLVM lane — unlinkable"
fi
echo "[test_llvm_unsafe]   OK — no leading-underscore bails"

# 2b. __stack_chk_init carries an `unsafe:` block and was the function that
#     vanished. It must be DEFINED, not declare-only.
if ! grep -qE '^define .*@__stack_chk_init\(' "$KLL"; then
    grep -n '@__stack_chk_init' "$KLL" | head -5
    fail "__stack_chk_init is not DEFINED in the emitted kernel IR"
fi
echo "[test_llvm_unsafe]   OK — __stack_chk_init DEFINED in kernel_main.ll"

# 2c. LINK: tolerate ONLY the lone initramfs pair (supplied by the real image
#     build through HAMNIX_INITRAMFS_BLOB).
LINKERRS="$(grep 'undefined reference to' "$BUILD_LOG" || true)"
if [ -n "$LINKERRS" ]; then
    BAD="$(echo "$LINKERRS" | grep -vE "initramfs_cpio_base|initramfs_cpio_size" || true)"
    if [ -n "$BAD" ]; then
        echo "$BAD"
        fail "unexpected undefined references in the LLVM kernel link"
    fi
    echo "[test_llvm_unsafe]   link clean (only the lone initramfs symbols unresolved — expected)"
elif [ "$BUILD_RC" -ne 0 ]; then
    tail -30 "$BUILD_LOG"
    fail "build_kernel_llvm.sh failed (rc=$BUILD_RC) with no undefined-reference diagnostic"
else
    echo "[test_llvm_unsafe]   link clean (fully linked kernel ELF)"
fi

echo "[test_llvm_unsafe] PASS"
exit 0
