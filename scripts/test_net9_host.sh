#!/usr/bin/env bash
# scripts/test_net9_host.sh — prove the UNCHANGED Plan-9 /net networking stack
# (user/http9.ad + user/net9.ad) fetches REAL, LIVE websites on the Linux HOST,
# over both http AND https, via the host /net SHIM (scripts/net9_host_shim.c).
#
# HOW IT STAYS FAITHFUL:
#   * user/http9.ad and user/net9.ad are compiled BYTE-FOR-BYTE unchanged. They
#     issue the identical Plan-9 file ops (open /net/tcp/clone, write
#     "connect ip!port" / "tls host" to the ctl file, read/write the data file)
#     and sys_resolve(2) for DNS.
#   * The ONLY host-specific piece is the LINK: instead of the freestanding
#     user/linux-runtime.S (whose sys_resolve / clone opens are fail-closed
#     stubs), the driver (user/net9_host.ad) is linked against net9_host_shim.c,
#     which backs the /net file dance with real sockets + OpenSSL TLS. The
#     sockets + TLS live ONLY in that host shim — the [[no-sockets]] invariant
#     holds in the native Adder code.
#
# DEVICE PARITY (non-negotiable): also confirms user/hambrowse.ad, user/http9.ad
# and user/net9.ad STILL compile for x86_64-adder-user — the shim is host-only
# and must not perturb the on-device build.
#
# Pass marker: [test_net9_host] PASS     Fail marker: [test_net9_host] FAIL
#
# Requires network access + libssl-dev. If the host has no network, the two
# live-fetch cases SKIP (reported, non-fatal) but the build + device-parity
# gates still run and must pass.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/net9_host"
ASM="$OUT/net9_host.s"
SHIM_O="$OUT/net9_host_shim.o"
fail=0

# ---- (1) compile the UNCHANGED http9/net9 stack for the host ---------------
echo "[test_net9_host] (1/4) compiling driver+http9+net9 (x86_64-linux, emit-asm) ..."
# --emit-asm writes user/net9_host.s beside the source; we relocate it and do
# our OWN gcc link (libc + OpenSSL) instead of the freestanding -nostdlib one.
if ! python3 -m compiler.adder compile --target=x86_64-linux --emit-asm \
        user/net9_host.ad -o "$OUT/net9_host_freestanding.elf" \
        >"$OUT/net9_host_compile.log" 2>&1; then
    echo "[test_net9_host] FAIL: driver did not compile"
    cat "$OUT/net9_host_compile.log"; exit 1
fi
mv -f user/net9_host.s "$ASM"
echo "[test_net9_host] PASS http9/net9 compiled unchanged -> $ASM"

# ---- (2) link the host /net shim (sockets + OpenSSL TLS) -------------------
echo "[test_net9_host] (2/4) linking against the /net shim + OpenSSL ..."
if ! gcc -O2 -c scripts/net9_host_shim.c -o "$SHIM_O" \
        2>"$OUT/net9_host_shim_compile.log"; then
    echo "[test_net9_host] FAIL: shim did not compile"
    cat "$OUT/net9_host_shim_compile.log"; exit 1
fi
if ! gcc -no-pie -O2 "$ASM" "$SHIM_O" -lssl -lcrypto -o "$BIN" \
        2>"$OUT/net9_host_link.log"; then
    echo "[test_net9_host] FAIL: link failed"
    cat "$OUT/net9_host_link.log"; exit 1
fi
echo "[test_net9_host] PASS linked -> $BIN"

# ---- (3) device-parity: the on-device build must not regress ---------------
# user/hambrowse.ad is the on-device browser; it transitively imports
# user/http9.ad -> user/net9.ad, so a full compile+LINK of hambrowse for
# x86_64-adder-user proves all three still build on-device. net9/http9 are
# libraries (no main) so cannot standalone-LINK; for them we assert CODEGEN
# succeeds via --emit-asm (the freestanding "undefined main" link error is
# expected and ignored — we only require the .s to be produced).
echo "[test_net9_host] (3/4) device parity: compiling for x86_64-adder-user ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_device.elf" >"$OUT/hambrowse_device.log" 2>&1; then
    echo "[test_net9_host] FAIL: device build of user/hambrowse.ad regressed"
    cat "$OUT/hambrowse_device.log"; fail=1
else
    echo "[test_net9_host] PASS user/hambrowse.ad links for x86_64-adder-user (pulls in http9+net9)"
fi
for mod in user/net9.ad user/http9.ad; do
    stem="$(basename "$mod" .ad)"
    rm -f "user/${stem}.s"
    python3 -m compiler.adder compile --target=x86_64-adder-user --emit-asm \
        "$mod" -o "$OUT/${stem}_device.elf" >"$OUT/${stem}_device.log" 2>&1 || true
    if [ -s "user/${stem}.s" ]; then
        echo "[test_net9_host] PASS $mod codegens for x86_64-adder-user"
        mv -f "user/${stem}.s" "$OUT/${stem}_device.s"
    else
        echo "[test_net9_host] FAIL: device codegen of $mod regressed"
        cat "$OUT/${stem}_device.log"; fail=1
    fi
done

# ---- (4) live fetch: http AND https ----------------------------------------
have_net=0
if getent hosts example.com >/dev/null 2>&1; then have_net=1; fi

run_fetch() {
    local name="$1" url="$2"
    echo "[test_net9_host] fetching $url ..."
    local got
    got="$(timeout 30 "$BIN" "$url" 2>"$OUT/net9_${name}.err")"
    local hdr
    hdr="$(printf '%s\n' "$got" | head -1)"
    echo "[test_net9_host]   $hdr"
    # RC=0 (completed transport), STATUS 200, and the body must contain real
    # HTML from example.com.
    if printf '%s' "$hdr" | grep -q "RC=0 STATUS=200 " \
       && printf '%s' "$got" | grep -qi "example domain"; then
        echo "[test_net9_host] PASS $name: live 200 + real HTML off the wire"
        # Show a proof snippet (title line).
        printf '%s\n' "$got" | grep -io "<title>[^<]*</title>" | head -1 \
            | sed 's/^/[test_net9_host]     /'
        return 0
    fi
    echo "[test_net9_host] FAIL $name: unexpected response:"
    printf '%s\n' "$got" | head -5 | sed 's/^/    /'
    cat "$OUT/net9_${name}.err" | head -3 | sed 's/^/    err: /'
    return 1
}

echo "[test_net9_host] (4/4) live fetch over the Plan-9 /net shim ..."
if [ "$have_net" -eq 1 ]; then
    run_fetch http  "http://example.com/"  || fail=1
    run_fetch https "https://example.com/" || fail=1
else
    echo "[test_net9_host] SKIP live fetch: host has no DNS/network (build + parity still gated)"
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_net9_host] PASS"
else
    echo "[test_net9_host] FAIL"
fi
exit $fail
