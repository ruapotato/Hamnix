#!/usr/bin/env bash
# scripts/test_hpm_channels.sh — exercise hpm's channel subcommands.
#
# Pins the channel-state semantics introduced by the 2026-05-27
# "channels-as-subdirs" pivot (memory/project_nonfree_repo.md):
#
#   * /etc/hpm/channels lists enabled channels, one per line. Lines
#     starting with `#` are comments. Default contents subscribe to
#     `main` only.
#   * `hpm channels`            — prints enabled channels.
#   * `hpm enable <name>`       — appends <name> to the file.
#   * `hpm disable <name>`      — removes <name> from the file.
#   * `hpm refresh` fetches each enabled channel's index.json from
#     <repo-base>/<channel>/index.json and merges the entries. Each
#     merged package entry carries a `channel` field; the install
#     path uses it to derive the per-channel tarball URL.
#
# Why a dedicated test (regression-prone-needs-test): channel routing
# is silently breakable — a refactor that loses the per-pkg channel
# field would still print "hpm: refreshed index ..." but installs
# would silently fetch from the wrong directory. This test asserts
# that the CLI surface AND the underlying file state stay coherent.
#
# What it does (purely offline, no network):
#   1. Build a fixture repo with `main/` AND `extra-channel/` subdirs
#      under one repo root. Each carries a tiny tarball + index.json.
#   2. Boot Hamnix. With default channels (just `main`), verify
#      `hpm channels` prints `main`.
#   3. `hpm refresh` against the fixture. Verify the merged index
#      lists only the `main`-channel package.
#   4. `hpm enable extra-channel` then `hpm refresh`. Verify both
#      packages are now visible (and a per-channel install works).
#   5. `hpm disable extra-channel` then `hpm channels`. Verify only
#      `main` is back.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
FIXDIR="$(mktemp -d /tmp/test-hpm-channels.XXXXXX)"
trap 'rm -rf "$FIXDIR"' EXIT

# -- Two-channel fixture ----------------------------------------------
# Repo root:
#   $REPO/main/index.json                    (one pkg: chan-main-hello)
#   $REPO/main/packages/chan-main-hello-1.0.tar.gz
#   $REPO/extra-channel/index.json           (one pkg: chan-extra-hello)
#   $REPO/extra-channel/packages/chan-extra-hello-1.0.tar.gz
REPO="$FIXDIR/repo"
mkdir -p "$REPO/main/packages" "$REPO/extra-channel/packages"

build_pkg() {
    local channel=$1 name=$2
    local pkgdir="$FIXDIR/stage/$name-1.0"
    mkdir -p "$pkgdir/files/var/lib"
    cat > "$pkgdir/PKGINFO" <<EOF
name: $name
version: 1.0
arch: any
description: channel-test pkg from $channel
target: #hamnix-system
EOF
    printf 'hello from %s\n' "$name" > "$pkgdir/files/var/lib/$name-greet"
    (cd "$FIXDIR/stage" && tar czf "$REPO/$channel/packages/$name-1.0.tar.gz" "$name-1.0")
    rm -rf "$pkgdir"
}

build_pkg main          chan-main-hello
build_pkg extra-channel chan-extra-hello

write_channel_index() {
    local channel=$1 name=$2
    local tarball="$REPO/$channel/packages/$name-1.0.tar.gz"
    local sha
    sha=$(sha256sum "$tarball" | awk '{print $1}')
    local size
    size=$(stat -c%s "$tarball")
    cat > "$REPO/$channel/index.json" <<EOF
{
  "schema": 1,
  "repo": "test/hpm-channels",
  "channel": "$channel",
  "url": "file:///test-hpm-repo/$channel/",
  "updated": "2026-05-27",
  "description": "channel test fixture ($channel)",
  "packages": [
    {
      "name": "$name",
      "version": "1.0",
      "arch": "any",
      "channel": "$channel",
      "url": "packages/$name-1.0.tar.gz",
      "sha256": "$sha",
      "size": $size,
      "description": "channel-test pkg from $channel",
      "depends": [],
      "target": "#hamnix-system"
    }
  ]
}
EOF
}
write_channel_index main          chan-main-hello
write_channel_index extra-channel chan-extra-hello

echo "[test_hpm_channels] fixture two-channel repo built under $FIXDIR"

echo "[test_hpm_channels] (1/3) Build userland + initramfs (with fixture repo)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
HAMNIX_HPM_TEST_REPO="$REPO" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_hpm_channels] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-hpm-channels.XXXXXX.log)
trap '[ "${HPM_CHANNELS_KEEP_LOG:-0}" = 1 ] || rm -f "$LOG"; rm -rf "$FIXDIR"' EXIT

echo "[test_hpm_channels] (3/3) Boot QEMU + drive hpm channel CLI"
set +e
# Channel-aware refresh on a two-channel fixture: default subscribes
# to `main` only; `hpm enable extra-channel` widens the view; the
# subsequent refresh merges both indexes; install resolves to the
# right channel sub-dir.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "echo CHAN_STAGE_START"                                              2 \
       "hpm channels"                                                       2 \
       "echo CHAN_STAGE_LIST_DEFAULT"                                       2 \
       "hpm '--repo=file:///test-hpm-repo/' --allow-unsigned refresh"                        4 \
       "echo CHAN_STAGE_REFRESH_DEFAULT"                                    2 \
       "hpm search hello"                                                   2 \
       "echo CHAN_STAGE_SEARCH_DEFAULT"                                     2 \
       "hpm enable extra-channel"                                           2 \
       "echo CHAN_STAGE_ENABLE_EXTRA"                                       2 \
       "hpm channels"                                                       2 \
       "echo CHAN_STAGE_LIST_AFTER_ENABLE"                                  2 \
       "hpm '--repo=file:///test-hpm-repo/' --allow-unsigned refresh"                        5 \
       "echo CHAN_STAGE_REFRESH_TWO"                                        2 \
       "hpm search hello"                                                   2 \
       "echo CHAN_STAGE_SEARCH_TWO"                                         2 \
       "hpm '--repo=file:///test-hpm-repo/' install chan-extra-hello"       6 \
       "echo CHAN_STAGE_INSTALL_EXTRA"                                      2 \
       "cat /var/lib/chan-extra-hello-greet"                                2 \
       "echo CHAN_STAGE_CAT_EXTRA"                                          2 \
       "hpm disable extra-channel"                                          2 \
       "echo CHAN_STAGE_DISABLE_EXTRA"                                      2 \
       "hpm channels"                                                       2 \
       "echo CHAN_STAGE_LIST_AFTER_DISABLE"                                 2 \
       "exit"                                                               1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hpm_channels] --- captured output ---"
cat "$LOG"
echo "[test_hpm_channels] --- end output ---"

fail=0

# Shell came up.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_hpm_channels] FAIL: hamsh never reached interactive loop"
    exit 1
fi

# 1. Default `hpm channels` shows just `main`.
list1_block=$(sed -n '/CHAN_STAGE_START/,/CHAN_STAGE_LIST_DEFAULT/p' "$LOG")
if echo "$list1_block" | grep -aF -q -- "- main"; then
    echo "[test_hpm_channels] OK: default channels list contains main"
else
    echo "[test_hpm_channels] FAIL: default channels list does not contain main"
    fail=1
fi
if echo "$list1_block" | grep -aF -q -- "- extra-channel"; then
    echo "[test_hpm_channels] FAIL: extra-channel listed before enable"
    fail=1
fi

# 2. Refresh against default channels picks up ONLY main-channel pkg.
refresh1_block=$(sed -n '/CHAN_STAGE_LIST_DEFAULT/,/CHAN_STAGE_REFRESH_DEFAULT/p' "$LOG")
if echo "$refresh1_block" | grep -aq "refreshed index"; then
    echo "[test_hpm_channels] OK: default-channel refresh reported success"
else
    echo "[test_hpm_channels] FAIL: default refresh did not report success"
    fail=1
fi

search1_block=$(sed -n '/CHAN_STAGE_REFRESH_DEFAULT/,/CHAN_STAGE_SEARCH_DEFAULT/p' "$LOG")
if echo "$search1_block" | grep -aq "chan-main-hello"; then
    echo "[test_hpm_channels] OK: search finds chan-main-hello after default refresh"
else
    echo "[test_hpm_channels] FAIL: chan-main-hello missing from default-refresh search"
    fail=1
fi
if echo "$search1_block" | grep -aq "chan-extra-hello"; then
    echo "[test_hpm_channels] FAIL: chan-extra-hello visible before enable"
    fail=1
fi

# 3. enable widens to two channels.
list2_block=$(sed -n '/CHAN_STAGE_ENABLE_EXTRA/,/CHAN_STAGE_LIST_AFTER_ENABLE/p' "$LOG")
# Only grep the lines `hpm channels` itself emitted (not the
# echo CHAN_STAGE_* boilerplate that mentions the strings too).
# `hpm channels` emits "  - <name>" lines after the diagnostic
# n=<count> header. Both names must appear in the post-enable block.
if echo "$list2_block" | grep -aF -q -- "- main" && \
   echo "$list2_block" | grep -aF -q -- "- extra-channel"; then
    echo "[test_hpm_channels] OK: channels list contains both main + extra-channel"
else
    echo "[test_hpm_channels] FAIL: post-enable list missing main or extra-channel"
    fail=1
fi

# 4. Refresh with both channels surfaces both packages.
search2_block=$(sed -n '/CHAN_STAGE_REFRESH_TWO/,/CHAN_STAGE_SEARCH_TWO/p' "$LOG")
if echo "$search2_block" | grep -aq "chan-main-hello" && \
   echo "$search2_block" | grep -aq "chan-extra-hello"; then
    echo "[test_hpm_channels] OK: search after two-channel refresh sees both pkgs"
else
    echo "[test_hpm_channels] FAIL: two-channel search missing one of the pkgs"
    fail=1
fi

# 5. Install of extra-channel pkg resolves to the right channel-subdir.
install_block=$(sed -n '/CHAN_STAGE_SEARCH_TWO/,/CHAN_STAGE_INSTALL_EXTRA/p' "$LOG")
if echo "$install_block" | grep -aq "installed chan-extra-hello@1.0"; then
    echo "[test_hpm_channels] OK: chan-extra-hello installed from extra-channel"
else
    echo "[test_hpm_channels] FAIL: chan-extra-hello did NOT install"
    fail=1
fi

# 6. File from extra-channel package is on disk.
cat_block=$(sed -n '/CHAN_STAGE_INSTALL_EXTRA/,/CHAN_STAGE_CAT_EXTRA/p' "$LOG")
if echo "$cat_block" | grep -aq "hello from chan-extra-hello"; then
    echo "[test_hpm_channels] OK: extra-channel pkg file landed on disk"
else
    echo "[test_hpm_channels] FAIL: extra-channel pkg file MISSING"
    fail=1
fi

# 7. disable restores single-channel state.
list3_block=$(sed -n '/CHAN_STAGE_DISABLE_EXTRA/,/CHAN_STAGE_LIST_AFTER_DISABLE/p' "$LOG")
# Same filter as list2: only `hpm channels` output, not the
# CHAN_STAGE_DISABLE_EXTRA echo boilerplate.
if echo "$list3_block" | grep -aF -q -- "- main" && \
   ! echo "$list3_block" | grep -aF -q -- "- extra-channel"; then
    echo "[test_hpm_channels] OK: disable removed extra-channel; only main remains"
else
    echo "[test_hpm_channels] FAIL: disable did not restore single-channel state"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hpm_channels] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hpm_channels] PASS (qemu rc=$rc)"
