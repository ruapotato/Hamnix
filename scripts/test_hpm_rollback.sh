#!/usr/bin/env bash
# scripts/test_hpm_rollback.sh - end-to-end test for hpm's transaction
# history + rollback (Phase 7).
#
# Modeled on scripts/test_hpm.sh: builds a tiny file:// repo fixture on
# the HOST with two packages (roll-a, roll-b), plants it in the cpio
# initramfs at /test-hpm-repo/ via HAMNIX_HPM_TEST_REPO, boots Hamnix
# under QEMU -nographic, and drives hpm through:
#
#   1. refresh + install roll-a
#   2. hpm history                 — shows the install txn (id 1)
#   3. hpm list                    — shows roll-a installed
#   4. hpm rollback                — reverses the latest txn (removes
#                                    roll-a), recording a rollback txn
#   5. hpm list                    — roll-a is GONE
#   6. install roll-a (txn 3) then install roll-b (txn 4)
#   7. hpm rollback 3              — reverts every txn AFTER id 3 (i.e.
#                                    removes roll-b), leaving roll-a
#   8. hpm list                    — roll-a present, roll-b absent
#
# The default boot identity is uid 1 (hostowner), so the hostowner-gated
# install/remove/rollback commands run without a `newshell hostowner`
# (mirrors test_hpm.sh, which installs directly on the boot shell).
#
# PASS/FAIL is reported via explicit `[test_hpm_rollback] PASS` /
# `[test_hpm_rollback] FAIL` lines (the orchestrator reads those lines,
# not the exit code), plus a no-kernel-PANIC check.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
FIXDIR="$(mktemp -d /tmp/test-hpm-rb-fixtures.XXXXXX)"
trap 'rm -rf "$FIXDIR"' EXIT

# -- Fixture repo: two trivial packages, channel `main`. --------------
REPO="$FIXDIR/repo"
mkdir -p "$REPO/main/packages"

make_pkg() {
    local name="$1"
    local pbuild="$FIXDIR/build/${name}-1.0"
    mkdir -p "$pbuild/files/var/lib"
    cat > "$pbuild/PKGINFO" <<EOF
name: ${name}
version: 1.0
arch: any
description: hpm rollback test package ${name}
target: #hamnix-system
EOF
    printf 'hello from %s\n' "$name" > "$pbuild/files/var/lib/${name}-greet"
    # NOTE: deliberately NO install.hamsh / remove.hamsh hooks. Each hook
    # makes hpm spawn a nested /bin/hamsh, and Hamnix's current
    # fork/spawn path is flaky after many detached spawns
    # (memory/project_rfork_detached_bug.md). This rollback flow runs
    # several install/remove ops back-to-back; dropping hooks keeps the
    # cumulative spawn count low so the Nth hpm invocation still launches.
    (cd "$FIXDIR/build" && tar czf "$REPO/main/packages/${name}-1.0.tar.gz" "${name}-1.0")
}

make_pkg roll-a
make_pkg roll-b

A_SHA=$(sha256sum "$REPO/main/packages/roll-a-1.0.tar.gz" | awk '{print $1}')
A_SZ=$(stat -c%s "$REPO/main/packages/roll-a-1.0.tar.gz")
B_SHA=$(sha256sum "$REPO/main/packages/roll-b-1.0.tar.gz" | awk '{print $1}')
B_SZ=$(stat -c%s "$REPO/main/packages/roll-b-1.0.tar.gz")

cat > "$REPO/main/index.json" <<EOF
{
  "schema": 1,
  "repo": "test/hpm-rollback",
  "channel": "main",
  "url": "file:///test-hpm-repo/main/",
  "updated": "2026-05-30",
  "description": "hpm rollback test fixture (main channel)",
  "packages": [
    {
      "name": "roll-a",
      "version": "1.0",
      "arch": "any",
      "channel": "main",
      "url": "packages/roll-a-1.0.tar.gz",
      "sha256": "$A_SHA",
      "size": $A_SZ,
      "description": "rollback-A",
      "depends": [],
      "target": "#hamnix-system"
    },
    {
      "name": "roll-b",
      "version": "1.0",
      "arch": "any",
      "channel": "main",
      "url": "packages/roll-b-1.0.tar.gz",
      "sha256": "$B_SHA",
      "size": $B_SZ,
      "description": "rollback-B",
      "depends": [],
      "target": "#hamnix-system"
    }
  ]
}
EOF

echo "[test_hpm_rollback] fixture repo built under $FIXDIR"

echo "[test_hpm_rollback] (1/3) Build userland + initramfs (with fixture repo)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
HAMNIX_HPM_TEST_REPO="$REPO" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_hpm_rollback] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-hpm-rb.XXXXXX.log)
trap 'rm -f "$LOG"; rm -rf "$FIXDIR"' EXIT

echo "[test_hpm_rollback] (3/3) Boot QEMU + drive hpm rollback flow"
set +e
# Generous first-command delay: early keystrokes get eaten before hamsh
# settles on the serial RX FIFO.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 480 \
    -- "echo RB_STAGE_START"                                         6 \
       "hpm '--repo=file:///test-hpm-repo/' --allow-unsigned refresh"                 4 \
       "echo RB_STAGE_REFRESHED"                                     2 \
       "hpm '--repo=file:///test-hpm-repo/' install roll-a"          6 \
       "echo RB_STAGE_A_INSTALLED"                                   2 \
       "hpm history"                                                 3 \
       "echo RB_STAGE_HISTORY_1"                                     2 \
       "hpm list"                                                    3 \
       "echo RB_STAGE_LIST_1"                                        2 \
       "hpm rollback"                                                5 \
       "echo RB_STAGE_ROLLED_BACK_1"                                 2 \
       "hpm list"                                                    3 \
       "echo RB_STAGE_LIST_2"                                        2 \
       "hpm '--repo=file:///test-hpm-repo/' install roll-a"          6 \
       "echo RB_STAGE_A_REINSTALLED"                                 2 \
       "hpm '--repo=file:///test-hpm-repo/' install roll-b"          6 \
       "echo RB_STAGE_B_INSTALLED"                                   2 \
       "hpm rollback 3"                                              6 \
       "echo RB_STAGE_ROLLED_BACK_2"                                 2 \
       "hpm list"                                                    3 \
       "echo RB_STAGE_LIST_3"                                        2 \
       "exit"                                                        1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hpm_rollback] --- captured output ---"
cat "$LOG"
echo "[test_hpm_rollback] --- end output ---"

fail=0

# 0. No kernel explosion anywhere in the log.
if grep -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hpm_rollback] FAIL: kernel PANIC/TRAP/BUG in log"
    echo "[test_hpm_rollback] FAIL"
    exit 1
fi

# 1. Shell came up + completed the sequence.
if ! grep -F -q "RB_STAGE_LIST_3" "$LOG"; then
    echo "[test_hpm_rollback] FAIL: shell died before completing the sequence"
    echo "[test_hpm_rollback] FAIL"
    exit 1
fi

# 2. install roll-a succeeded.
inst_block=$(sed -n '/RB_STAGE_REFRESHED/,/RB_STAGE_A_INSTALLED/p' "$LOG")
if echo "$inst_block" | grep -q "hpm: installed roll-a@1.0"; then
    echo "[test_hpm_rollback] OK: roll-a installed"
else
    echo "[test_hpm_rollback] MISS: roll-a did not install"
    fail=1
fi

# 3. history shows the install txn for roll-a.
hist1_block=$(sed -n '/RB_STAGE_A_INSTALLED/,/RB_STAGE_HISTORY_1/p' "$LOG")
if echo "$hist1_block" | grep -E -q "txn 1 .* install .* roll-a"; then
    echo "[test_hpm_rollback] OK: history shows install txn for roll-a"
else
    echo "[test_hpm_rollback] MISS: history did not show roll-a install txn"
    fail=1
fi

# 4. list shows roll-a.
list1_block=$(sed -n '/RB_STAGE_HISTORY_1/,/RB_STAGE_LIST_1/p' "$LOG")
if echo "$list1_block" | grep -E -q "roll-a[[:space:]]+1\.0"; then
    echo "[test_hpm_rollback] OK: list shows roll-a before rollback"
else
    echo "[test_hpm_rollback] MISS: list did not show roll-a before rollback"
    fail=1
fi

# 5. rollback removed roll-a.
rb1_block=$(sed -n '/RB_STAGE_LIST_1/,/RB_STAGE_ROLLED_BACK_1/p' "$LOG")
if echo "$rb1_block" | grep -q "hpm: rollback complete"; then
    echo "[test_hpm_rollback] OK: rollback reported complete"
else
    echo "[test_hpm_rollback] MISS: rollback did not report complete"
    fail=1
fi

# 6. list-after-rollback no longer shows roll-a.
list2_block=$(sed -n '/RB_STAGE_ROLLED_BACK_1/,/RB_STAGE_LIST_2/p' "$LOG")
if echo "$list2_block" | grep -E -q "roll-a[[:space:]]+1\.0"; then
    echo "[test_hpm_rollback] MISS: roll-a still listed after rollback"
    fail=1
else
    echo "[test_hpm_rollback] OK: roll-a gone after rollback"
fi

# 7. install roll-a (txn 3) + roll-b (txn 4) both succeed.
reinst_block=$(sed -n '/RB_STAGE_LIST_2/,/RB_STAGE_B_INSTALLED/p' "$LOG")
if echo "$reinst_block" | grep -q "hpm: installed roll-a@1.0" \
   && echo "$reinst_block" | grep -q "hpm: installed roll-b@1.0"; then
    echo "[test_hpm_rollback] OK: roll-a + roll-b reinstalled"
else
    echo "[test_hpm_rollback] MISS: reinstall of roll-a/roll-b incomplete"
    fail=1
fi

# 8. rollback 3 reverts back to the as-of-txn-3 state (removes roll-b,
#    keeps roll-a). Assert it removed roll-b specifically.
rb2_block=$(sed -n '/RB_STAGE_B_INSTALLED/,/RB_STAGE_ROLLED_BACK_2/p' "$LOG")
if echo "$rb2_block" | grep -q "hpm: rollback complete"; then
    echo "[test_hpm_rollback] OK: rollback <txnid> reported complete"
else
    echo "[test_hpm_rollback] MISS: rollback <txnid> did not complete"
    fail=1
fi
if echo "$rb2_block" | grep -q "hpm: removed roll-b"; then
    echo "[test_hpm_rollback] OK: rollback 3 removed roll-b (reverted txn 4)"
else
    echo "[test_hpm_rollback] MISS: rollback 3 did not remove roll-b"
    fail=1
fi
if echo "$rb2_block" | grep -q "hpm: removed roll-a"; then
    echo "[test_hpm_rollback] MISS: rollback 3 wrongly removed roll-a too"
    fail=1
fi

# 9. final list: roll-a present, roll-b absent.
list3_block=$(sed -n '/RB_STAGE_ROLLED_BACK_2/,/RB_STAGE_LIST_3/p' "$LOG")
if echo "$list3_block" | grep -E -q "roll-a[[:space:]]+1\.0"; then
    echo "[test_hpm_rollback] OK: roll-a still present after rollback 3"
else
    echo "[test_hpm_rollback] MISS: roll-a missing after rollback 3"
    fail=1
fi
if echo "$list3_block" | grep -E -q "roll-b[[:space:]]+1\.0"; then
    echo "[test_hpm_rollback] MISS: roll-b still present after rollback 3"
    fail=1
else
    echo "[test_hpm_rollback] OK: roll-b removed by rollback 3"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hpm_rollback] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hpm_rollback] PASS (qemu rc=$rc)"
