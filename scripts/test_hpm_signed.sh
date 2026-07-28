#!/usr/bin/env bash
# scripts/test_hpm_signed.sh — end-to-end (QEMU) proof that hpm's
# `refresh` actually enforces the Ed25519 index signature.
#
# Two file:// fixtures are planted in the initramfs:
#   /test-hpm-repo/            main/index.json + a MATCHING index.json.sig
#                              (signed with an ephemeral key) + trusted.pub
#   /test-hpm-repo-conflict/   main/index.json TAMPERED after signing (one
#                              hex digit of a sha256 flipped) + the
#                              ORIGINAL .sig (now stale)
#
# Boot Hamnix and drive:
#   (a) refresh + install against the signed repo (--trusted-key) — the
#       signature verifies and the package installs (file lands).
#   (b) refresh against the tampered repo (--trusted-key) — hpm reports
#       the signature INVALID and refuses (non-zero, no "refreshed").
#   (c) refresh against the tampered repo with --allow-unsigned — the
#       override skips verification and refresh succeeds.
#
# Revert-sensitive: if cmd_refresh stops verifying, (b) goes green-wrong
# (refresh succeeds) and the gate fails; if verification is over-strict,
# (a)/(c) fail.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
FIXDIR="$(mktemp -d /tmp/test-hpm-signed.XXXXXX)"
trap 'rm -rf "$FIXDIR"' EXIT

python3 -c "import cryptography" 2>/dev/null \
    || { echo "[test_hpm_signed] SKIP: python3 'cryptography' missing"; exit 0; }

# -- Ephemeral repo key + trust root -----------------------------------
python3 scripts/hpm_sign.py keygen --out-pub "$FIXDIR/trusted.pub" \
        --out-sec "$FIXDIR/repo.sec" >/dev/null

# -- Signed happy-path repo --------------------------------------------
REPO="$FIXDIR/repo"
mkdir -p "$REPO/main/packages"
PKG_BUILD="$FIXDIR/build/sig-hello-1.0"
mkdir -p "$PKG_BUILD/files/var/lib"
cat > "$PKG_BUILD/PKGINFO" <<'EOF'
name: sig-hello
version: 1.0
arch: any
description: signed-index test package
target: #hamnix-system
EOF
printf 'signed hello\n' > "$PKG_BUILD/files/var/lib/sig-hello-greet"
(cd "$FIXDIR/build" && tar czf "$REPO/main/packages/sig-hello-1.0.tar.gz" sig-hello-1.0)
PKG_SHA=$(sha256sum "$REPO/main/packages/sig-hello-1.0.tar.gz" | awk '{print $1}')
PKG_SIZE=$(stat -c%s "$REPO/main/packages/sig-hello-1.0.tar.gz")

cat > "$REPO/main/index.json" <<EOF
{
  "schema": 1,
  "repo": "test/hpm-signed",
  "channel": "main",
  "url": "file:///test-hpm-repo/main/",
  "updated": "2026-07-10",
  "description": "hpm signed-index test fixture (main channel)",
  "packages": [
    {
      "name": "sig-hello",
      "version": "1.0",
      "arch": "any",
      "channel": "main",
      "url": "packages/sig-hello-1.0.tar.gz",
      "sha256": "$PKG_SHA",
      "size": $PKG_SIZE,
      "description": "signed-index test package",
      "depends": [],
      "target": "#hamnix-system"
    }
  ]
}
EOF
# Sign the index, plant the trust root inside the repo tree.
python3 scripts/hpm_sign.py sign "$REPO/main/index.json" "$FIXDIR/repo.sec" \
        "$REPO/main/index.json.sig"
cp "$FIXDIR/trusted.pub" "$REPO/trusted.pub"

# -- Tampered repo: sign, then corrupt the index (keep the stale .sig) --
REPO_T="$FIXDIR/repo-tampered"
mkdir -p "$REPO_T/main/packages"
cp "$REPO/main/packages/sig-hello-1.0.tar.gz" "$REPO_T/main/packages/"
cp "$REPO/main/index.json"     "$REPO_T/main/index.json"
cp "$REPO/main/index.json.sig" "$REPO_T/main/index.json.sig"
# Flip one hex digit of the sha256 string — JSON stays valid (so an
# --allow-unsigned refresh still parses) but the signed bytes change.
python3 - "$REPO_T/main/index.json" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); t = p.read_text()
m = re.search(r'"sha256":\s*"([0-9a-f]{64})"', t)
h = m.group(1); flip = ('0' if h[0] != '0' else '1') + h[1:]
p.write_text(t.replace(h, flip, 1))
PY

echo "[test_hpm_signed] fixtures built under $FIXDIR"

echo "[test_hpm_signed] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
HAMNIX_HPM_TEST_REPO="$REPO" \
HAMNIX_HPM_TEST_REPO_CONFLICT="$REPO_T" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_hpm_signed] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-hpm-signed.XXXXXX.log)
trap 'rm -f "$LOG"; rm -rf "$FIXDIR"' EXIT

TK="--trusted-key=/test-hpm-repo/trusted.pub"
echo "[test_hpm_signed] (3/3) Boot QEMU + drive hpm"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "echo SIG_START"                                                       2 \
       "hpm '--repo=file:///test-hpm-repo/' '$TK' refresh"                    4 \
       "echo SIG_GOOD_REFRESH_DONE"                                           2 \
       "hpm '--repo=file:///test-hpm-repo/' '$TK' install sig-hello"          6 \
       "echo SIG_INSTALL_DONE"                                                2 \
       "cat /var/lib/sig-hello-greet"                                         2 \
       "echo SIG_CAT_DONE"                                                    2 \
       "hpm '--repo=file:///test-hpm-repo-conflict/' '$TK' refresh"           4 \
       "echo SIG_TAMPER_REFRESH_DONE"                                         2 \
       "hpm '--repo=file:///test-hpm-repo-conflict/' --allow-unsigned refresh" 4 \
       "echo SIG_OVERRIDE_REFRESH_DONE"                                       2 \
       "exit"                                                                 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hpm_signed] --- captured output ---"
cat "$LOG"
echo "[test_hpm_signed] --- end output ---"

# Guest liveness: count our stage markers. Zero markers = dead gate.
markers=$(grep -c -E 'SIG_(START|GOOD_REFRESH_DONE|INSTALL_DONE|CAT_DONE|TAMPER_REFRESH_DONE|OVERRIDE_REFRESH_DONE)' "$LOG" || true)
if [ "$markers" -eq 0 ]; then
    echo "[test_hpm_signed] INCONCLUSIVE: no guest markers (boot/env failure, rc=$rc)"
    exit 2
fi

fail=0

# (a) signed refresh + install succeed, file lands.
good_block=$(sed -n '/SIG_START/,/SIG_GOOD_REFRESH_DONE/p' "$LOG")
if echo "$good_block" | grep -q "refreshed index from file:///test-hpm-repo/"; then
    echo "[test_hpm_signed] OK (a1): signed refresh verified + succeeded"
else
    echo "[test_hpm_signed] FAIL (a1): signed refresh did not succeed"; fail=1
fi
cat_block=$(sed -n '/SIG_INSTALL_DONE/,/SIG_CAT_DONE/p' "$LOG")
if echo "$cat_block" | grep -q "signed hello"; then
    echo "[test_hpm_signed] OK (a2): package installed (file present)"
else
    echo "[test_hpm_signed] FAIL (a2): installed file not found"; fail=1
fi

# (b) tampered refresh REJECTED — must report INVALID and NOT succeed.
tamper_block=$(sed -n '/SIG_CAT_DONE/,/SIG_TAMPER_REFRESH_DONE/p' "$LOG")
if echo "$tamper_block" | grep -q "signature INVALID"; then
    echo "[test_hpm_signed] OK (b1): tampered index reported INVALID"
else
    echo "[test_hpm_signed] FAIL (b1): no INVALID signature report on tampered repo"; fail=1
fi
if echo "$tamper_block" | grep -q "refreshed index from file:///test-hpm-repo-conflict/"; then
    echo "[test_hpm_signed] FAIL (b2): tampered refresh WRONGLY succeeded"; fail=1
else
    echo "[test_hpm_signed] OK (b2): tampered refresh refused (no success line)"
fi

# (c) --allow-unsigned override lets the tampered repo refresh through.
ovr_block=$(sed -n '/SIG_TAMPER_REFRESH_DONE/,/SIG_OVERRIDE_REFRESH_DONE/p' "$LOG")
if echo "$ovr_block" | grep -q "refreshed index from file:///test-hpm-repo-conflict/"; then
    echo "[test_hpm_signed] OK (c): --allow-unsigned override refreshed"
else
    echo "[test_hpm_signed] FAIL (c): --allow-unsigned override did not refresh"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hpm_signed] FAIL"
    exit 1
fi
echo "[test_hpm_signed] PASS"
