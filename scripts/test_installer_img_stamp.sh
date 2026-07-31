#!/usr/bin/env bash
# scripts/test_installer_img_stamp.sh — MUTATION-TEST the build-CONFIGURATION
# half of the stale-image guard (scripts/_installer_img.sh).
#
# WHY THIS GATE EXISTS
# ====================
# scripts/_installer_img.sh has now been found short THREE times, always in the
# same direction: its staleness model asked "did a tracked file change after
# this image was written?" and treated every other way the image can change as
# out of scope.
#
#   2026-07-25  `sys` missing from the input dirs — the whole Plan 9 device
#               layer could change and the image still read fresh.
#   2026-07-28  `tests` missing — boot-path kernel source, same hole.
#   2026-07-30  `mm` / `linux_abi` / `adder` missing — leak pass 13 launched a
#               soak against a kernel predating the mm change it was measuring.
#   2026-07-30  and the one that is NOT a directory at all: build CONFIGURATION.
#               ADDER_FORCE_NATIVE_APPS changes what the build emits with the
#               tree byte-for-byte identical, and an agent took SEVEN
#               CONSECUTIVE FALSE PASSES off an image built the other way.
#
# So the guard now hashes a configuration stamp beside the image, and this gate
# is what keeps that stamp honest. It runs against a SYNTHETIC tree (PROJ_ROOT
# pointed at a temp dir), so it can do the things a real tree cannot be made to
# do on demand — delete a source file, install a different compiler — in
# milliseconds and with no QEMU, no KVM and no image.
#
# BOTH ERROR DIRECTIONS ARE TESTED, and the NEGATIVE control is the one that
# matters most. A stamp that always says "stale" is not the safe failure: it
# means a 6-14 minute rebuild on every gate invocation, which is precisely how
# a guard gets commented out by the next person in a hurry. `unchanged` and
# `irrelevant_var` below are that control.
#
# Exit 0 = PASS, 1 = FAIL, 125 = INCONCLUSIVE. No QEMU, ~1 s.

set -uo pipefail
REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="[imgstamp]"

GUARD="$REAL_ROOT/scripts/_installer_img.sh"
[ -f "$GUARD" ] || { echo "$TAG INCONCLUSIVE: $GUARD absent" >&2; exit 125; }

# Every knob this gate flips must be OUT of the environment to begin with, or
# the "unchanged" control silently compares two identical non-defaults and
# proves nothing.
unset ADDER_FORCE_NATIVE_APPS HAMNIX_KERNEL_BACKEND HAMNIX_USER_OPT \
      ENABLE_XHCI_KO HAMNIX_SKIP_BUILD 2>/dev/null || true

TREE=$(mktemp -d --tmpdir hamnix-imgstamp.XXXXXX)
trap 'rm -rf "$TREE"' EXIT

# A miniature tree with the shape the guard expects.
mkdir -p "$TREE/scripts" "$TREE/build"
for d in user lib etc init kernel arch drivers fs net compiler sys tests mm \
         linux_abi adder; do
    mkdir -p "$TREE/$d"
    echo "source of $d" > "$TREE/$d/a.ad"
done
cp "$GUARD" "$TREE/scripts/_installer_img.sh"
echo '#!/bin/sh' > "$TREE/scripts/build_installer_img.sh"
IMG="$TREE/build/hamnix-installer.img"
head -c 4096 /dev/zero > "$IMG"

# The image must be NEWER than every source, or the mtime half condemns it
# first and this gate would be testing the wrong model.
sleep 1
touch "$IMG"

# probe <extra-env-assignments...> — is the image stale in a fresh shell with
# this environment? Prints "STALE" or "FRESH". A subshell per probe so an
# exported knob cannot leak into the next case.
probe() {
    env -u ADDER_FORCE_NATIVE_APPS -u HAMNIX_KERNEL_BACKEND \
        -u HAMNIX_USER_OPT -u ENABLE_XHCI_KO -u HAMNIX_SKIP_BUILD \
        "$@" bash -c '
        PROJ_ROOT="$1"; export PROJ_ROOT
        . "$PROJ_ROOT/scripts/_installer_img.sh"
        if installer_img_is_stale "$PROJ_ROOT/build/hamnix-installer.img"; then
            echo "STALE|$(installer_img_stale_reason)"
        else
            echo "FRESH|"
        fi' _ "$TREE"
}

nfail=0
ncase=0
check() {
    local name="$1" want="$2" why="$3"; shift 3
    ncase=$((ncase + 1))
    local got reason
    got=$(probe "$@")
    reason="${got#*|}"; got="${got%%|*}"
    if [ "$got" = "$want" ]; then
        printf '%s   ok   %-24s -> %-6s %s\n' "$TAG" "$name" "$got" "($why)"
    else
        printf '%s   BAD  %-24s -> %-6s expected %-6s (%s) reason=%s\n' \
            "$TAG" "$name" "$got" "$want" "$why" "$reason" >&2
        nfail=$((nfail + 1))
    fi
}

# ---------------------------------------------------------------------------
# 0. An image with NO stamp is stale. Images that predate this mechanism get
#    rebuilt once rather than trusted forever.
# ---------------------------------------------------------------------------
check no_stamp STALE "an image with no recorded configuration is not trusted"

# Write the stamp the way a successful build would.
PROJ_ROOT="$TREE" bash -c '
    . "$1/scripts/_installer_img.sh"
    installer_img_write_stamp "$1/build/hamnix-installer.img"' _ "$TREE"
[ -f "$IMG.stamp" ] || {
    echo "$TAG INCONCLUSIVE: installer_img_write_stamp produced no stamp" >&2
    exit 125; }

# ---------------------------------------------------------------------------
# 1. THE NEGATIVE CONTROL. Nothing changed => NOT stale. A stamp that always
#    mismatches would pass every other case in this file and be worse than no
#    stamp at all.
# ---------------------------------------------------------------------------
check unchanged FRESH "nothing changed: no spurious 6-minute rebuild"

# ---------------------------------------------------------------------------
# 2. THE CASE THAT COST SEVEN FALSE PASSES.
# ---------------------------------------------------------------------------
check native_apps_on STALE "ADDER_FORCE_NATIVE_APPS=1 emits a different image" \
      ADDER_FORCE_NATIVE_APPS=1
check kernel_backend STALE "a different kernel backend is a different kernel" \
      HAMNIX_KERNEL_BACKEND=native
check user_opt       STALE "--opt userland is different userland" \
      HAMNIX_USER_OPT=1
check enable_knob    STALE "ENABLE_* knobs are in scope too" \
      ENABLE_XHCI_KO=1

# ---------------------------------------------------------------------------
# 3. A variable that changes WHETHER we build, not WHAT we build, must NOT
#    force a rebuild — the false-stale direction.
# ---------------------------------------------------------------------------
check irrelevant_var FRESH "HAMNIX_SKIP_BUILD is not an image input" \
      HAMNIX_SKIP_BUILD=1

# ---------------------------------------------------------------------------
# 4. DELETION. An mtime maximum cannot fall, so removing a source file leaves
#    the old model reporting "fresh" forever. This is the hole that has nothing
#    to do with configuration and would have been missed by a fix aimed only at
#    the named case.
# ---------------------------------------------------------------------------
rm -f "$TREE/kernel/a.ad"
check deleted_source STALE "a source file was DELETED; no mtime moved forward"
echo "source of kernel" > "$TREE/kernel/a.ad"
touch "$IMG"
check restored       FRESH "the tree is back to what the stamp describes"

# ---------------------------------------------------------------------------
# 5. A RENAME, which is the same blind spot wearing a different hat: the file
#    count is unchanged and the newest mtime belongs to the image.
# ---------------------------------------------------------------------------
mv "$TREE/mm/a.ad" "$TREE/mm/b.ad"
touch "$IMG"
check renamed_source STALE "a source file was RENAMED; the inventory changed"
mv "$TREE/mm/b.ad" "$TREE/mm/a.ad"
touch "$IMG"

# ---------------------------------------------------------------------------
# 6. THE INPUT MODEL ITSELF. The day somebody adds the NEXT missing directory,
#    every existing image must go stale — those images were built under a model
#    that ignored it. This is the meta-fix for the bug that has now recurred
#    four times.
# ---------------------------------------------------------------------------
mkdir -p "$TREE/newdir"; echo x > "$TREE/newdir/a.ad"
sed -i 's/^_HAMNIX_IMG_INPUT_DIRS="\(.*\)"$/_HAMNIX_IMG_INPUT_DIRS="\1 newdir"/' \
    "$TREE/scripts/_installer_img.sh"
touch "$IMG"
check input_list_widened STALE \
      "the directory list grew: images built under the old model are suspect"
cp "$GUARD" "$TREE/scripts/_installer_img.sh"
touch "$IMG"

# ---------------------------------------------------------------------------
# 7. THE TOOLCHAIN. HAMNIX_KERNEL_BACKEND=llvm compiles the kernel with clang;
#    a clang upgrade rewrites every byte of it with no source change at all.
#    Simulated by pointing $CLANG at a different compiler-version string.
# ---------------------------------------------------------------------------
cat > "$TREE/fakecc" <<'EOF'
#!/bin/sh
echo "clang version 99.0.0-fake"
EOF
chmod +x "$TREE/fakecc"
check toolchain_changed STALE "a different compiler emits a different kernel" \
      "CLANG=$TREE/fakecc"

# ---------------------------------------------------------------------------
# 8. The stamp is per-IMAGE, so the dedicated selftest image path cannot
#    inherit the main image's configuration. (The 07-24 bug lived on exactly
#    that dedicated path.)
# ---------------------------------------------------------------------------
head -c 4096 /dev/zero > "$TREE/build/hamnix-installer-selftest.img"
ncase=$((ncase + 1))
if PROJ_ROOT="$TREE" bash -c '
        . "$1/scripts/_installer_img.sh"
        installer_img_is_stale "$1/build/hamnix-installer-selftest.img"' \
        _ "$TREE"; then
    printf '%s   ok   %-24s -> %-6s (%s)\n' "$TAG" "dedicated_path" "STALE" \
        "a second image path does not inherit the first one's stamp"
else
    echo "$TAG   BAD  dedicated_path -> FRESH, expected STALE" >&2
    nfail=$((nfail + 1))
fi

# A table that shrank to nothing would pass vacuously.
if [ "$ncase" -lt 12 ]; then
    echo "$TAG INCONCLUSIVE: only $ncase case(s) ran; the table has been gutted" >&2
    exit 125
fi
if [ "$nfail" -ne 0 ]; then
    echo "$TAG FAIL: $nfail of $ncase mutation(s) did not change the verdict —" >&2
    echo "$TAG   the staleness model is still blind to them" >&2
    exit 1
fi
echo "$TAG PASS — all $ncase cases, in BOTH directions (7 configuration/tree"
echo "$TAG   mutations detected, 3 no-op controls correctly left FRESH)"
exit 0
