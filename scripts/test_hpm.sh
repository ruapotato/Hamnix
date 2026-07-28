#!/usr/bin/env bash
# scripts/test_hpm.sh - end-to-end test for the Hamnix package manager.
#
# IMPORTANT - PATH SCOPE: this test runs against a vanilla initramfs
# (cpio is read-only; tmpfs owns /tmp/* and /var/*). The fixture
# packages therefore target /var/lib/<file> rather than the
# canonical /bin/<file>. This is a TEST-ENVIRONMENT restriction, NOT
# a limitation of hpm: hpm itself happily writes /bin/foo / /lib/foo
# / /etc/foo when those paths are writable, which is exactly the
# state of a real installer-time install (the installer formats a
# fresh disk + binds it as / before running `hpm install
# hamnix-base`). A future test that exercises that installer path
# end-to-end belongs in scripts/test_installer_full.sh.
#
# Builds two file:// repo fixtures on the HOST, plants them in the cpio
# initramfs at /test-hpm-repo/ and /test-hpm-repo-conflict/, boots
# Hamnix in QEMU, and drives hpm through:
#   1. hpm --repo=file:///test-hpm-repo/ refresh
#   2. hpm search hello                 (positive substring match)
#   3. hpm install hpm-hello             (resolves deps, fetches, sha,
#                                          extracts, runs install.hamsh)
#   4. hpm list                          (asserts hpm-hello listed)
#   5. cat /var/lib/hpm-hello-greet          (asserts file was placed)
#   6. hpm remove hpm-hello              (asserts files removed,
#                                          installed.json empty)
#   7. hpm --repo=file:///test-hpm-repo-conflict/ install pkg-a
#   8. hpm install pkg-b                 (NEGATIVE: a declared conflict
#                                          between pkg-a and pkg-b must
#                                          abort with a clear message)
#
# Pure file:// — no network required, deterministic against the same
# fixture tarballs every run.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
FIXDIR="$(mktemp -d /tmp/test-hpm-fixtures.XXXXXX)"
trap 'rm -rf "$FIXDIR"' EXIT

# -- Fixture 1: the happy-path repo (one package, hpm-hello@1.0). -----
# Channel layout (2026-05-27 pivot): top-level dirs under the repo
# root are channels. Default install subscribes to `main` only, so
# the fixture's only channel-subdir is `main/`.
REPO="$FIXDIR/repo"
mkdir -p "$REPO/main/packages"

PKG_BUILD="$FIXDIR/build/hpm-hello-1.0"
mkdir -p "$PKG_BUILD/files/var/lib"
cat > "$PKG_BUILD/PKGINFO" <<'EOF'
name: hpm-hello
version: 1.0
arch: any
description: hpm test package — Phase 6 end-to-end exercise
target: #hamnix-system
EOF
# Phase 6 fixture writes to /var/lib/ — that's the tmpfs-backed
# writable subtree on a vanilla Hamnix initramfs (cpio owns /bin etc.
# read-only). A real Hamnix package would install /bin/<binary> onto
# ext4-backed /var/lib/distros/... or a real-disk-backed rootfs; the
# fixture target keeps the test on initramfs-only writable storage so
# no disk image is required.
printf 'hello from hpm-hello\n' > "$PKG_BUILD/files/var/lib/hpm-hello-greet"
cat > "$PKG_BUILD/install.hamsh" <<'EOF'
echo HOOK_INSTALL_RAN
EOF
(cd "$FIXDIR/build" && tar czf "$REPO/main/packages/hpm-hello-1.0.tar.gz" hpm-hello-1.0)

PKG_SHA=$(sha256sum "$REPO/main/packages/hpm-hello-1.0.tar.gz" \
            | awk '{print $1}')
PKG_SIZE=$(stat -c%s "$REPO/main/packages/hpm-hello-1.0.tar.gz")

# A second package that DEPENDS on hpm-hello — gives `hpm why hpm-hello`
# a real reverse-dependency edge to report, and `hpm files` a package to
# enumerate.
PKG_DEP_BUILD="$FIXDIR/build/hpm-hello-dep-1.0"
mkdir -p "$PKG_DEP_BUILD/files/var/lib"
cat > "$PKG_DEP_BUILD/PKGINFO" <<'EOF'
name: hpm-hello-dep
version: 1.0
arch: any
description: hpm test package that depends on hpm-hello
target: #hamnix-system
EOF
printf 'dep-mark\n' > "$PKG_DEP_BUILD/files/var/lib/hpm-hello-dep-mark"
(cd "$FIXDIR/build" && tar czf "$REPO/main/packages/hpm-hello-dep-1.0.tar.gz" hpm-hello-dep-1.0)
PKG_DEP_SHA=$(sha256sum "$REPO/main/packages/hpm-hello-dep-1.0.tar.gz" | awk '{print $1}')
PKG_DEP_SIZE=$(stat -c%s "$REPO/main/packages/hpm-hello-dep-1.0.tar.gz")

cat > "$REPO/main/index.json" <<EOF
{
  "schema": 1,
  "repo": "test/hpm",
  "channel": "main",
  "url": "file:///test-hpm-repo/main/",
  "updated": "2026-05-26",
  "description": "hpm Phase 6 test fixture (main channel)",
  "packages": [
    {
      "name": "hpm-hello",
      "version": "1.0",
      "arch": "any",
      "channel": "main",
      "url": "packages/hpm-hello-1.0.tar.gz",
      "sha256": "$PKG_SHA",
      "size": $PKG_SIZE,
      "description": "hpm test package",
      "depends": [],
      "target": "#hamnix-system"
    },
    {
      "name": "hpm-hello-dep",
      "version": "1.0",
      "arch": "any",
      "channel": "main",
      "url": "packages/hpm-hello-dep-1.0.tar.gz",
      "sha256": "$PKG_DEP_SHA",
      "size": $PKG_DEP_SIZE,
      "description": "hpm test package depending on hpm-hello",
      "depends": ["hpm-hello"],
      "target": "#hamnix-system"
    }
  ]
}
EOF

# -- Fixture 2: a conflict repo (two packages that declare each other
# as conflicts).  Install pkg-a first, then pkg-b MUST fail loudly. ---
REPO_C="$FIXDIR/repo-conflict"
mkdir -p "$REPO_C/main/packages"

PKG_A="$FIXDIR/build-c/pkg-a-1.0"
mkdir -p "$PKG_A/files/var/lib"
printf 'A\n' > "$PKG_A/files/var/lib/conflict-mark-a"
cat > "$PKG_A/PKGINFO" <<'EOF'
name: pkg-a
version: 1.0
arch: any
description: conflict-test A
conflicts: pkg-b
EOF
(cd "$FIXDIR/build-c" && tar czf "$REPO_C/main/packages/pkg-a-1.0.tar.gz" pkg-a-1.0)

PKG_B="$FIXDIR/build-c/pkg-b-1.0"
mkdir -p "$PKG_B/files/var/lib"
printf 'B\n' > "$PKG_B/files/var/lib/conflict-mark-b"
cat > "$PKG_B/PKGINFO" <<'EOF'
name: pkg-b
version: 1.0
arch: any
description: conflict-test B
conflicts: pkg-a
EOF
(cd "$FIXDIR/build-c" && tar czf "$REPO_C/main/packages/pkg-b-1.0.tar.gz" pkg-b-1.0)

PKG_A_SHA=$(sha256sum "$REPO_C/main/packages/pkg-a-1.0.tar.gz" | awk '{print $1}')
PKG_A_SZ=$(stat -c%s "$REPO_C/main/packages/pkg-a-1.0.tar.gz")
PKG_B_SHA=$(sha256sum "$REPO_C/main/packages/pkg-b-1.0.tar.gz" | awk '{print $1}')
PKG_B_SZ=$(stat -c%s "$REPO_C/main/packages/pkg-b-1.0.tar.gz")

cat > "$REPO_C/main/index.json" <<EOF
{
  "schema": 1,
  "repo": "test/hpm-conflict",
  "channel": "main",
  "url": "file:///test-hpm-repo-conflict/main/",
  "updated": "2026-05-26",
  "description": "hpm Phase 6 conflict-detect fixture (main channel)",
  "packages": [
    {
      "name": "pkg-a",
      "version": "1.0",
      "arch": "any",
      "channel": "main",
      "url": "packages/pkg-a-1.0.tar.gz",
      "sha256": "$PKG_A_SHA",
      "size": $PKG_A_SZ,
      "description": "conflict-A",
      "conflicts": ["pkg-b"]
    },
    {
      "name": "pkg-b",
      "version": "1.0",
      "arch": "any",
      "channel": "main",
      "url": "packages/pkg-b-1.0.tar.gz",
      "sha256": "$PKG_B_SHA",
      "size": $PKG_B_SZ,
      "description": "conflict-B",
      "conflicts": ["pkg-a"]
    }
  ]
}
EOF

echo "[test_hpm] fixture repos built under $FIXDIR"

echo "[test_hpm] (1/3) Build userland + initramfs (with fixture repos)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
HAMNIX_HPM_TEST_REPO="$REPO" \
HAMNIX_HPM_TEST_REPO_CONFLICT="$REPO_C" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_hpm] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-hpm.XXXXXX.log)
trap 'rm -f "$LOG"; rm -rf "$FIXDIR"' EXIT

echo "[test_hpm] (3/3) Boot QEMU + drive hpm CLI"
set +e
# A generous overall timeout: boot + the command sequence + per-cmd
# delays. The fixture is tiny (~1 KB tarballs); per-cmd time is bounded
# by SHA-256 + inflate, both microseconds.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "echo HPM_STAGE_START"                                              2 \
       "hpm '--repo=file:///test-hpm-repo/' --allow-unsigned refresh"                       4 \
       "echo HPM_STAGE_REFRESHED"                                          2 \
       "hpm '--repo=file:///test-hpm-repo/' search hello"                  3 \
       "echo HPM_STAGE_SEARCHED"                                           2 \
       "hpm '--repo=file:///test-hpm-repo/' install hpm-hello"             6 \
       "echo HPM_STAGE_INSTALLED"                                          2 \
       "hpm list"                                                          3 \
       "echo HPM_STAGE_LISTED"                                             2 \
       "cat /var/lib/hpm-hello-greet"                                          2 \
       "echo HPM_STAGE_CAT_DONE"                                           2 \
       "hpm '--repo=file:///test-hpm-repo/' install hpm-hello-dep"         6 \
       "echo HPM_STAGE_DEP_INSTALLED"                                      2 \
       "hpm files hpm-hello-dep"                                           3 \
       "echo HPM_STAGE_FILES_DONE"                                         2 \
       "hpm why hpm-hello"                                                 3 \
       "echo HPM_STAGE_WHY_DONE"                                           2 \
       "hpm '--repo=file:///test-hpm-repo/' --allow-unsigned upgrade"                       5 \
       "echo HPM_STAGE_UPGRADE_DONE"                                       2 \
       "hpm remove hpm-hello-dep"                                          4 \
       "echo HPM_STAGE_DEP_REMOVED"                                        2 \
       "hpm remove hpm-hello"                                              4 \
       "echo HPM_STAGE_REMOVED"                                            2 \
       "hpm list"                                                          2 \
       "echo HPM_STAGE_LIST_AFTER_REMOVE"                                  2 \
       "hpm '--repo=file:///test-hpm-repo-conflict/' --allow-unsigned refresh"              3 \
       "echo HPM_STAGE_CONFLICT_REFRESHED"                                 2 \
       "hpm '--repo=file:///test-hpm-repo-conflict/' install pkg-a"        4 \
       "echo HPM_STAGE_PKG_A_INSTALLED"                                    2 \
       "hpm '--repo=file:///test-hpm-repo-conflict/' install pkg-b"        4 \
       "echo HPM_STAGE_PKG_B_TRIED"                                        2 \
       "exit"                                                              1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hpm] --- captured output ---"
cat "$LOG"
echo "[test_hpm] --- end output ---"

fail=0

# 1. The shell came up.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_hpm] FAIL: hamsh never reached the interactive loop"
    exit 1
fi

# 2. refresh succeeded.
refresh_block=$(sed -n '/HPM_STAGE_START/,/HPM_STAGE_REFRESHED/p' "$LOG")
if echo "$refresh_block" | grep -q "refreshed index from file:///test-hpm-repo/"; then
    echo "[test_hpm] OK: refresh succeeded"
else
    echo "[test_hpm] MISS: refresh did not report success"
    fail=1
fi

# 3. search found hpm-hello.
search_block=$(sed -n '/HPM_STAGE_REFRESHED/,/HPM_STAGE_SEARCHED/p' "$LOG")
if echo "$search_block" | grep -q "hpm-hello"; then
    echo "[test_hpm] OK: search returned hpm-hello"
else
    echo "[test_hpm] MISS: search did not return hpm-hello"
    fail=1
fi

# 4. install succeeded — files placed, hook ran.
install_block=$(sed -n '/HPM_STAGE_SEARCHED/,/HPM_STAGE_INSTALLED/p' "$LOG")
if echo "$install_block" | grep -q "SHA-256 verified"; then
    echo "[test_hpm] OK: install verified SHA-256"
else
    echo "[test_hpm] MISS: install did not verify SHA-256"
    fail=1
fi
if echo "$install_block" | grep -q "HOOK_INSTALL_RAN"; then
    echo "[test_hpm] OK: install.hamsh hook ran"
else
    echo "[test_hpm] MISS: install hook output not seen"
    fail=1
fi
if echo "$install_block" | grep -q "hpm: installed hpm-hello@1.0"; then
    echo "[test_hpm] OK: install reported success"
else
    echo "[test_hpm] MISS: install did not report success"
    fail=1
fi

# 5. list shows hpm-hello.
list_block=$(sed -n '/HPM_STAGE_INSTALLED/,/HPM_STAGE_LISTED/p' "$LOG")
if echo "$list_block" | grep -E -q "hpm-hello[[:space:]]+1\.0"; then
    echo "[test_hpm] OK: list shows hpm-hello@1.0"
else
    echo "[test_hpm] MISS: list did not show hpm-hello"
    fail=1
fi

# 6. file was placed at /bin/hpm-hello-greet.
cat_block=$(sed -n '/HPM_STAGE_LISTED/,/HPM_STAGE_CAT_DONE/p' "$LOG")
if echo "$cat_block" | grep -q "hello from hpm-hello"; then
    echo "[test_hpm] OK: installed file is readable + has expected content"
else
    echo "[test_hpm] MISS: /var/lib/hpm-hello-greet content not found"
    fail=1
fi

# 6b. dep install pulled hpm-hello-dep (hpm-hello already present).
dep_block=$(sed -n '/HPM_STAGE_CAT_DONE/,/HPM_STAGE_DEP_INSTALLED/p' "$LOG")
if echo "$dep_block" | grep -q "hpm: installed hpm-hello-dep@1.0"; then
    echo "[test_hpm] OK: hpm-hello-dep installed (dep on hpm-hello satisfied)"
else
    echo "[test_hpm] MISS: hpm-hello-dep did not install"
    fail=1
fi

# 6c. `hpm files <pkg>` lists the package's installed files.
files_block=$(sed -n '/HPM_STAGE_DEP_INSTALLED/,/HPM_STAGE_FILES_DONE/p' "$LOG")
if echo "$files_block" | grep -q "hpm-hello-dep-mark"; then
    echo "[test_hpm] OK: files listed the installed file"
else
    echo "[test_hpm] MISS: files did not list hpm-hello-dep-mark"
    fail=1
fi

# 6d. `hpm why hpm-hello` reports the reverse-dependency edge.
why_block=$(sed -n '/HPM_STAGE_FILES_DONE/,/HPM_STAGE_WHY_DONE/p' "$LOG")
if echo "$why_block" | grep -q "hpm-hello-dep depends on hpm-hello"; then
    echo "[test_hpm] OK: why reported the reverse-dependency edge"
else
    echo "[test_hpm] MISS: why did not report hpm-hello-dep -> hpm-hello"
    fail=1
fi

# 6e. `hpm upgrade` is a working alias for `update` (world upgrade).
upgrade_block=$(sed -n '/HPM_STAGE_WHY_DONE/,/HPM_STAGE_UPGRADE_DONE/p' "$LOG")
if echo "$upgrade_block" | grep -q "hpm: update done"; then
    echo "[test_hpm] OK: upgrade alias drove the world upgrade"
else
    echo "[test_hpm] MISS: upgrade alias did not run cmd_update"
    fail=1
fi

# 6f. remove the dep before the hpm-hello removal so the empty-DB check
#     downstream still holds.
dep_rm_block=$(sed -n '/HPM_STAGE_UPGRADE_DONE/,/HPM_STAGE_DEP_REMOVED/p' "$LOG")
if echo "$dep_rm_block" | grep -q "hpm: removed hpm-hello-dep"; then
    echo "[test_hpm] OK: hpm-hello-dep removed"
else
    echo "[test_hpm] MISS: hpm-hello-dep removal not reported"
    fail=1
fi

# 7. remove deleted the file.
remove_block=$(sed -n '/HPM_STAGE_DEP_REMOVED/,/HPM_STAGE_REMOVED/p' "$LOG")
if echo "$remove_block" | grep -q "hpm: removed hpm-hello"; then
    echo "[test_hpm] OK: remove reported success"
else
    echo "[test_hpm] MISS: remove did not report success"
    fail=1
fi

# 8. list-after-remove is empty.
empty_list_block=$(sed -n '/HPM_STAGE_REMOVED/,/HPM_STAGE_LIST_AFTER_REMOVE/p' "$LOG")
if echo "$empty_list_block" | grep -q "no packages installed"; then
    echo "[test_hpm] OK: list-after-remove shows empty DB"
else
    echo "[test_hpm] MISS: installed DB not empty after remove"
    fail=1
fi

# 9. conflict negative test: pkg-a installs, pkg-b is REJECTED.
pkg_a_block=$(sed -n '/HPM_STAGE_CONFLICT_REFRESHED/,/HPM_STAGE_PKG_A_INSTALLED/p' "$LOG")
if echo "$pkg_a_block" | grep -q "hpm: installed pkg-a@1.0"; then
    echo "[test_hpm] OK: pkg-a installed (no conflict yet)"
else
    echo "[test_hpm] MISS: pkg-a did not install"
    fail=1
fi
pkg_b_block=$(sed -n '/HPM_STAGE_PKG_A_INSTALLED/,/HPM_STAGE_PKG_B_TRIED/p' "$LOG")
if echo "$pkg_b_block" | grep -q "declared-conflict"; then
    echo "[test_hpm] OK: pkg-b install rejected with a conflict diagnostic"
else
    echo "[test_hpm] MISS: pkg-b install did NOT report a conflict"
    fail=1
fi
if echo "$pkg_b_block" | grep -q "hpm: installed pkg-b@1.0"; then
    echo "[test_hpm] FAIL: pkg-b was installed despite conflict!"
    fail=1
fi

# 10. Shell survived.
if ! grep -F -q "HPM_STAGE_PKG_B_TRIED" "$LOG"; then
    echo "[test_hpm] MISS: shell died before completing the sequence"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hpm] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hpm] PASS (qemu rc=$rc)"
