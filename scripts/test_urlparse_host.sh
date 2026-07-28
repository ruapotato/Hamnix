#!/usr/bin/env bash
# scripts/test_urlparse_host.sh — FAST, QEMU-free gate for the URL parser
# (user/http9.http_parse_url) that native curl / wget / hpm and hambrowse
# all feed their argument through.
#
# REGRESSION GUARD for the hands-on-QA bug where `curl google.com` failed
# with "malformed or unsupported URL": a SCHEME-LESS bare host must parse
# as http://host/ exactly like real curl (which prepends http:// and lets
# the redirect chain reach https). Explicit http://…/https://… URLs must
# keep parsing unchanged.
#
# The parser is exercised directly via a freestanding x86_64-linux host
# ELF (user/urlparse_host.ad) — no QEMU, no network. Built with the frozen
# Python seed compiler, so this gate is dependency-light. It also confirms
# native curl (x86_64-adder-user) still compiles after any http9 change.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/urlparse_host"
mkdir -p "$OUT"

echo "[urlparse-host] compiling URL-parse unit test for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/urlparse_host.ad "$BIN" 2>"$OUT/urlparse.compile.log"; then
    echo "[urlparse-host] FAIL: host harness did not compile"
    cat "$OUT/urlparse.compile.log"; exit 1
fi
echo "[urlparse-host] PASS host harness compiled -> $BIN"

# Confirm native curl (pulls http9) still compiles for the device target.
echo "[urlparse-host] compiling native curl (pulls http9) ..."
if ! adder_bin x86_64-adder-user user/curl.ad "$OUT/curl_native.elf" 2>"$OUT/urlparse.native.log"; then
    echo "[urlparse-host] FAIL: native http9 consumer did not compile"
    cat "$OUT/urlparse.native.log"; exit 1
fi
echo "[urlparse-host] PASS native curl still compiles"

echo "[urlparse-host] running URL-parse unit test ..."
DUMP="$OUT/urlparse.txt"
"$BIN" >"$DUMP" 2>&1
rc=$?
cat "$DUMP"

if [ "$rc" -ne 0 ]; then
    echo "[urlparse-host] RESULT: FAIL (harness exit $rc)"; exit 1
fi
if ! grep -q '^\[urlparse\] RESULT: PASS' "$DUMP"; then
    echo "[urlparse-host] RESULT: FAIL (no PASS summary)"; exit 1
fi
# Guard the specific cases explicitly — the schemeless ones are the fix.
for c in schemeless-bare-host schemeless-with-path schemeless-with-port \
         explicit-http explicit-https reject-empty \
         post-request-line post-host-header post-content-type \
         post-content-length post-default-ctype; do
    if ! grep -q "^\[urlparse\] PASS $c" "$DUMP"; then
        echo "[urlparse-host] RESULT: FAIL (case '$c' did not pass)"; exit 1
    fi
done
echo "[urlparse-host] RESULT: PASS"
exit 0
