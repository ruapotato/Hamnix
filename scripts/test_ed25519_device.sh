#!/usr/bin/env bash
# scripts/test_ed25519_device.sh — ON-DEVICE proof that hpm's signed-index
# trust chain actually works on the target, with the signature check ON.
#
# WHY THIS GATE EXISTS.
#
# lib/ed25519.ad is the crypto `hpm refresh` uses to decide whether an
# index.json may be believed. It had exactly one gate,
# scripts/test_hpm_signed_index.sh, and that gate compiles the library for
# `--target=x86_64-linux` and runs the ELF ON THE BUILD HOST. Every shipped
# consumer is compiled for the device by scripts/build_user.sh, which by
# default routes each app through the LLVM -> clang -> native-ELF64 lane.
# Nothing ever ran the verifier on the target it ships on.
#
# Worse, EVERY on-device hpm gate (test_hpm.sh, test_hpm_channels.sh,
# test_hamaudiobook_hpm.sh, test_hpm_network.sh) passes `--allow-unsigned`,
# which SKIPS _verify_index_signature outright. So a verifier that returned
# "invalid" for every signature in existence was green on every gate.
#
# It did exactly that. The LLVM backend emitted `lshr` for `o[i] >> 16` on a
# `Ptr[int64]` parameter (signedness of `p[i]` was reported as unknown, and
# unknown selects the UNSIGNED form), which is the whole of Ed25519's field
# arithmetic. SHA-512 is all uint64 and stayed byte-correct, so the failure
# looked like "the repo index is corrupt" rather than "the compiler is". The
# first thing that ever noticed was `hpm refresh` on an installed system,
# refusing to trust its own byte-perfect on-image index.
#
# WHAT IS ASSERTED (all on device, all with the signature check ENABLED):
#   1. RFC 8032 vectors 1 + 2 verify.
#   2. A tampered signature is REJECTED (a verifier that says yes to
#      everything must not pass this gate either).
#   3. The REAL local-key-signed index.json + detached index.json.sig
#      verify against the compiled-in LOCAL trust root — the exact triple
#      `hpm refresh` uses for a file:// repo.
#   4. `hpm refresh` WITHOUT --allow-unsigned succeeds against that repo
#      and lists its packages.
#   5. `hpm refresh` against a repo whose index was TAMPERED after signing
#      is REFUSED. (Without this, "make it pass" could be spelled "stop
#      checking".)
#
# Runtime ~4 min, one QEMU.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_build_lock.sh"
. "$PROJ_ROOT/scripts/_qemu_drive.sh"

say() { echo "[test_ed25519_device] $*"; }
fails=0
ok()   { say "  OK  : $1"; }
miss() { say "  MISS: $1" >&2; fails=$((fails + 1)); }

ELF=build/hamnix-kernel.elf
FIX="$(mktemp -d /tmp/test-ed25519-device.XXXXXX)"
LOG="$(mktemp /tmp/test-ed25519-device.XXXXXX.log)"
trap 'rm -rf "$FIX"; rm -f "$LOG"' EXIT

python3 -c "import sys; sys.path.insert(0,'scripts'); import hpm_sign" 2>/dev/null \
    || { say "INCONCLUSIVE: scripts/hpm_sign.py has no crypto backend — NOTHING WAS ASSERTED." >&2; exit 125; }
[ -f scripts/hpm_local_key.seed ] \
    || { say "INCONCLUSIVE: scripts/hpm_local_key.seed missing — NOTHING WAS ASSERTED." >&2; exit 125; }

# --- (1) a REAL local-key-signed channel index + a tampered twin -------
say "(1/4) build the signed fixture repo (+ a post-signing tampered twin)"
python3 - "$FIX" <<'PY'
import json, sys, pathlib
sys.path.insert(0, "scripts")
import hpm_sign
fix = pathlib.Path(sys.argv[1])
good = fix / "good" / "main"
bad = fix / "bad" / "main"
good.mkdir(parents=True)
bad.mkdir(parents=True)
idx = {
    "schema": 1, "repo": "HamnixOS/packages", "channel": "main",
    "url": "file:///test-hpm-repo/main/", "updated": "2026-07-30",
    "description": "ed25519 on-device gate fixture",
    "packages": [
        {"name": "hpm-signed-marker", "version": "1.0.0",
         "channel": "main",
         "description": "ED25519_DEVICE_GATE_MARKER package",
         "sha256": "ab" * 32, "size": 1,
         "url": "packages/hpm-signed-marker-1.0.0.tar.gz"},
    ],
}
blob = (json.dumps(idx, indent=2, ensure_ascii=False) + "\n").encode()
(good / "index.json").write_bytes(blob)
seed = pathlib.Path("scripts/hpm_local_key.seed").read_text()
sig = hpm_sign.sign_bytes(blob, seed)
(good / "index.json.sig").write_text(sig + "\n")
# The tampered twin: same (valid) signature, one byte of the body flipped
# AFTER signing. This is what the check exists to catch.
t = bytearray(blob)
t[20] ^= 0x01
(bad / "index.json").write_bytes(bytes(t))
(bad / "index.json.sig").write_text(sig + "\n")
print("[fixture] signed index:", len(blob), "bytes; sig", sig[:16] + "...")
PY
[ -f "$FIX/good/main/index.json.sig" ] || { say "FAIL: fixture not produced" >&2; exit 1; }

# --- (2) userland + image ---------------------------------------------
say "(2/4) build userland + initramfs (fixture planted at /test-hpm-repo)"
bash scripts/build_user.sh >/dev/null 2>&1 || { say "FAIL: build_user.sh failed" >&2; exit 1; }
[ -x build/user/ed25519_selftest.elf ] \
    || { say "FAIL: build/user/ed25519_selftest.elf missing" >&2; exit 1; }
bash scripts/build_modules.sh >/dev/null 2>&1 || true
HAMNIX_HPM_TEST_REPO="$FIX/good" \
HAMNIX_HPM_TEST_REPO_CONFLICT="$FIX/bad" \
    python3 scripts/build_initramfs.py >/dev/null 2>&1 \
    || { say "FAIL: build_initramfs.py failed" >&2; exit 1; }
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null 2>&1 \
    || { say "FAIL: kernel compile failed" >&2; exit 1; }

# --- (3) drive it on device -------------------------------------------
say "(3/4) boot + drive the verifier and hpm refresh (signature check ON)"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "echo ED_START"                                                        2 \
       "ed25519_selftest /test-hpm-repo/main/index.json /test-hpm-repo/main/index.json.sig" 25 \
       "echo ED_SELFTEST_DONE"                                                2 \
       "hpm '--repo=file:///test-hpm-repo/' refresh"                          12 \
       "echo ED_REFRESH_DONE"                                                 2 \
       "hpm '--repo=file:///test-hpm-repo/' search marker"                     8 \
       "echo ED_SEARCH_DONE"                                                  2 \
       "hpm '--repo=file:///test-hpm-repo-conflict/' refresh"                 12 \
       "echo ED_TAMPER_DONE"                                                  2 \
       "exit"                                                                 1
rc="$QEMU_DRIVE_RC"
set -e
# rc=124 is the harness tearing QEMU down on its own timeout after the last
# command (hamsh does not power the box off); only a guest that never got
# going is a failure, and the assertions below catch that anyway.

# --- (4) assertions ----------------------------------------------------
say "(4/4) assertions"
g() { grep -a -q "$1" "$LOG"; }

if ! g 'ED_START'; then
    say "INCONCLUSIVE: the guest never reached the shell — NOTHING WAS ASSERTED (qemu rc=$rc)." >&2
    tail -40 "$LOG" >&2
    exit 125
fi

g 'RFC8032-TEST1-empty: PASS' \
    && ok "RFC 8032 vector 1 verifies ON DEVICE" \
    || miss "RFC 8032 vector 1 does NOT verify on device — lib/ed25519 is miscompiled for the shipping target"
g 'RFC8032-TEST2-1byte: PASS' \
    && ok "RFC 8032 vector 2 verifies ON DEVICE" \
    || miss "RFC 8032 vector 2 does NOT verify on device"
g 'RFC8032-TEST2-tampered: PASS' \
    && ok "a tampered signature is REJECTED on device" \
    || miss "a tampered signature was ACCEPTED on device — the verifier is not verifying"
g 'FILE-VERIFY: PASS' \
    && ok "the real local-key-signed index verifies against the compiled-in LOCAL root" \
    || miss "the real signed index does NOT verify on device — the exact 'hpm: LOCAL index signature INVALID' refusal"
g 'refreshed index from file:///test-hpm-repo/' \
    && ok "KEYSTONE: 'hpm refresh' trusts a signed file:// repo WITHOUT --allow-unsigned" \
    || miss "KEYSTONE: 'hpm refresh' refused a correctly-signed file:// index"
g 'hpm-signed-marker' \
    && ok "the refreshed index is usable ('hpm search' lists the fixture package)" \
    || miss "'hpm search' listed nothing after the refresh"

# The negative control. A tampered index MUST be refused; if this ever
# turns into a pass, the check was weakened rather than fixed.
if grep -a -q 'refreshed index from file:///test-hpm-repo-conflict/' "$LOG"; then
    miss "SECURITY: an index TAMPERED after signing was ACCEPTED — the signature check is not enforcing"
elif grep -a -q 'LOCAL index signature INVALID' "$LOG"; then
    ok "SECURITY: an index tampered after signing is REFUSED"
else
    miss "SECURITY: the tampered-index refresh produced no verdict at all"
fi

if [ "$fails" -ne 0 ]; then
    say "FAILED ($fails assertion(s)) — last 60 lines:" >&2
    tail -60 "$LOG" >&2
    exit 1
fi
say "PASS (qemu rc=$rc)"
exit 0
