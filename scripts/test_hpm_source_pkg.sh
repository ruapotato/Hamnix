#!/usr/bin/env bash
# scripts/test_hpm_source_pkg.sh — #186 SOURCE-package end-to-end test.
#
# Proves the native hpm SOURCE-package path (Gentoo-style: ship .ad
# source + a recipe, compile ON-BOX at install time with Hamnix's
# self-hosted Adder compiler, then install the resulting binary).
#
# The fixture package `hello-src` ships ONLY its Adder source
# (src/greet.ad) + a `recipe` and PKGINFO — there is NO prebuilt binary
# in the tarball. So `hpm install hello-src` is FORCED through the
# on-box compile path: hpm stages the tarball, sees the recipe, spawns
# /bin/adder_cc to compile src/greet.ad into files/var/lib/hello-src-greet,
# and installs that freshly-compiled binary.
#
# The test then RUNS the installed binary and asserts BOTH unforgeable
# witnesses of a real on-box compile-then-run:
#   * the [adder_cc] ... PASS markers from the on-box compiler step,
#   * "hpm: source package — compiling on-box" from hpm,
#   * the program's printed marker HELLO_SRC_ONBOX_BUILT_OK (the marker
#     string is interned by the self-hosted codegen into the program's
#     .data — it cannot appear unless the source was compiled on-box),
#   * the kernel scheduler reporting the program exited with code=137
#     (main()'s return value via the elf_emit _start stub).
#
# Pure file:// repo planted in the cpio initramfs at /test-hpm-repo/ —
# no network, no disk image. Modeled on scripts/test_hpm.sh.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
FIXDIR="$(mktemp -d /tmp/test-hpm-src.XXXXXX)"
trap 'rm -rf "$FIXDIR"' EXIT

REPO="$FIXDIR/repo"

EXPECT_MARKER="HELLO_SRC_ONBOX_BUILT_OK"
EXPECT_EXIT=137

# -- (1/4) Build the SOURCE-package fixture repo ----------------------
echo "[test_hpm_src] (1/4) Build source-package fixture repo"
python3 scripts/build_source_pkg_fixture.py "$REPO"

# Sanity: the tarball must NOT contain a prebuilt binary — only source +
# recipe + PKGINFO. This is what forces the install through on-box compile.
TARBALL="$REPO/main/packages/hello-src-1.0.tar.gz"
if tar tzf "$TARBALL" | grep -qE 'files/'; then
    echo "[test_hpm_src] FAIL: fixture tarball ships a prebuilt files/ artifact" >&2
    echo "  (a source package must compile on-box; no binary may be shipped)" >&2
    tar tzf "$TARBALL" >&2
    exit 1
fi
echo "[test_hpm_src]   OK : tarball ships SOURCE only (no prebuilt binary):"
tar tzf "$TARBALL" | sed 's/^/[test_hpm_src]     /'

# -- (2/4) Build userland (incl. /bin/adder_cc) + plant the repo ------
echo "[test_hpm_src] (2/4) Build userland + initramfs (with fixture repo)"
bash scripts/build_user.sh >/dev/null
if [ ! -s build/user/adder_cc.elf ]; then
    echo "[test_hpm_src] FAIL: /bin/adder_cc (on-box compiler) was not built" >&2
    exit 1
fi
bash scripts/build_modules.sh >/dev/null 2>&1 || true
HAMNIX_HPM_TEST_REPO="$REPO" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hpm_src] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-hpm-src.XXXXXX.log)
trap 'rm -f "$LOG"; rm -rf "$FIXDIR"' EXIT

# -- (4/4) Boot QEMU + drive the source-install + run the binary ------
echo "[test_hpm_src] (4/4) Boot QEMU: install (compile on-box) + run"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 240 \
    -- "echo SRC_STAGE_START"                                          2 \
       "hpm '--repo=file:///test-hpm-repo/' --allow-unsigned refresh"                   4 \
       "echo SRC_STAGE_REFRESHED"                                      2 \
       "hpm '--repo=file:///test-hpm-repo/' install hello-src"        12 \
       "echo SRC_STAGE_INSTALLED"                                      2 \
       "hpm list"                                                      3 \
       "echo SRC_STAGE_LISTED"                                         2 \
       "/var/lib/hello-src-greet"                                      3 \
       "echo SRC_STAGE_RAN"                                            2 \
       "exit"                                                          1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hpm_src] --- captured output ---"
cat "$LOG"
echo "[test_hpm_src] --- end output ---"

fail=0

# Shell came up + completed the sequence.
if ! grep -F -q "SRC_STAGE_RAN" "$LOG"; then
    echo "[test_hpm_src] FAIL: shell died before completing the sequence" >&2
    exit 1
fi

# refresh succeeded.
if grep -q "refreshed index from file:///test-hpm-repo/" "$LOG"; then
    echo "[test_hpm_src]   OK : refresh succeeded"
else
    echo "[test_hpm_src]   MISS: refresh did not report success" >&2
    fail=1
fi

install_block=$(sed -n '/SRC_STAGE_REFRESHED/,/SRC_STAGE_INSTALLED/p' "$LOG")

# hpm announced the SOURCE-package path.
if echo "$install_block" | grep -q "hpm: source package — compiling on-box"; then
    echo "[test_hpm_src]   OK : hpm selected the SOURCE-package path"
else
    echo "[test_hpm_src]   MISS: hpm did not enter the source-package path" >&2
    fail=1
fi

# The on-box compiler actually ran (its markers are emitted only by
# /bin/adder_cc running ON the box).
if echo "$install_block" | grep -q "\[adder_cc\] start"; then
    echo "[test_hpm_src]   OK : on-box Adder compiler (/bin/adder_cc) ran"
else
    echo "[test_hpm_src]   MISS: /bin/adder_cc did not run on-box" >&2
    fail=1
fi
if echo "$install_block" | grep -q "\[adder_cc\] PASS"; then
    echo "[test_hpm_src]   OK : on-box compile reported PASS"
else
    echo "[test_hpm_src]   MISS: on-box compile did not reach PASS" >&2
    fail=1
fi

# install reported success.
if echo "$install_block" | grep -q "hpm: installed hello-src@1.0"; then
    echo "[test_hpm_src]   OK : install reported success"
else
    echo "[test_hpm_src]   MISS: install did not report success" >&2
    fail=1
fi

# list shows hello-src.
list_block=$(sed -n '/SRC_STAGE_INSTALLED/,/SRC_STAGE_LISTED/p' "$LOG")
if echo "$list_block" | grep -E -q "hello-src[[:space:]]+1\.0"; then
    echo "[test_hpm_src]   OK : list shows hello-src@1.0"
else
    echo "[test_hpm_src]   MISS: list did not show hello-src" >&2
    fail=1
fi

# The compiled-on-box binary RAN and printed its unforgeable marker.
run_block=$(sed -n '/SRC_STAGE_LISTED/,/SRC_STAGE_RAN/p' "$LOG")
if echo "$run_block" | grep -q "$EXPECT_MARKER"; then
    echo "[test_hpm_src]   OK : on-box-compiled binary printed marker $EXPECT_MARKER"
else
    echo "[test_hpm_src]   MISS: compiled binary did not print $EXPECT_MARKER" >&2
    fail=1
fi

# The kernel scheduler witnessed the binary exit with the expected code.
if grep -aE -q "task: pid [0-9]+ exited \(code=${EXPECT_EXIT}\)" "$LOG"; then
    echo "[test_hpm_src]   OK : kernel reports the binary exited code=${EXPECT_EXIT}"
else
    echo "[test_hpm_src]   MISS: kernel did not report code=${EXPECT_EXIT} exit" >&2
    grep -aE "task: pid [0-9]+ exited" "$LOG" >&2 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hpm_src] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hpm_src] PASS (qemu rc=$rc) — native source package compiled ON-BOX via the self-hosted Adder compiler and ran"
