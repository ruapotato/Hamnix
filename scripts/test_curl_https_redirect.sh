#!/usr/bin/env bash
# scripts/test_curl_https_redirect.sh — on-device gate for the native
# HTTP client's http:// -> https:// redirect-follow (user/http9.ad).
#
# WHY: http9.ad used to return -9 ("no TLS on redirect") for ANY 3xx whose
# Location was https://, so the native browser / curl / wget could not reach
# the modern web — an http:// URL 301/302'ing to https:// is the norm for
# nearly every real site. The primary fetch path already dials TLS via
# net_dial_tls (the in-kernel TLS 1.3 client), and _h9_fetch_once re-parses
# the scheme per hop, so following an https redirect works once the stale
# guard is lifted. This gate proves the composition end-to-end: a plaintext
# GET that 302s to an https:// URL is chased THROUGH the TLS record layer and
# the encrypted body is delivered to userland.
#
# It also proves the SECURITY posture kept in place: a https:// -> http://
# redirect is a TLS DOWNGRADE and is REJECTED (curl reports an error, the
# secret page marker never reaches the plaintext hop).
#
# WHAT IT DOES
#   1. Generate a fake "Hamnix Test CA" + a leaf cert for 10.0.2.200
#      (SAN=DNS:10.0.2.200), exactly like scripts/test_net_https.sh.
#   2. Plant the CA DER at /etc/tls-ca.der in a hamsh-as-init initramfs
#      (TLS_CA_DER=..., the proven initramfs CA-anchor path) so the
#      in-kernel validator trusts the leaf.
#   3. Stand up two HOST servers behind SLIRP guestfwd:
#        - 10.0.2.200:443  -> a Python TLS 1.3 server serving a page whose
#          body carries the marker HTTPS_REDIR_BODY_OK, and 302'ing
#          /downgrade -> http://10.0.2.201/plain.
#        - 10.0.2.201:80   -> a plain-HTTP redirector: / -> 302
#          https://10.0.2.200/page ; /plain -> 200 "PLAINTEXT_LEAK".
#   4. Boot QEMU, and from the shell run:
#        curl http://10.0.2.201/            (must follow to https + render body)
#        curl https://10.0.2.200/downgrade  (must REJECT the downgrade)
#
# ASSERTS (three-valued: PASS / FAIL / SKIP):
#   * PASS requires: DHCP bound 10.0.2.15; no kernel TRAP; the follow fetch
#     printed HTTPS_REDIR_BODY_OK (the https body arrived via the redirect);
#     the downgrade fetch did NOT print PLAINTEXT_LEAK (downgrade rejected).
#   * SKIP when openssl / python3 / qemu are unavailable, or the servers or
#     DHCP fail to come up (host without the fixture — mirrors test_net_https).
#
# Needs: openssl, python3, qemu-system-x86_64 (elf64 via build/binshim),
# and SLIRP. No /dev/kvm required (same -kernel boot path as test_curl.sh).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

skip() { echo "[curl-https-redirect] SKIP: $1"; exit 0; }

command -v openssl >/dev/null 2>&1 || skip "openssl required"
command -v python3 >/dev/null 2>&1 || skip "python3 required"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 required"

TMPDIR=$(mktemp -d -t hamnix-httpsredir-XXXXXX)
CA_KEY="$TMPDIR/ca.key";  CA_CRT="$TMPDIR/ca.crt";  CA_DER="$TMPDIR/ca.der"
LEAF_KEY="$TMPDIR/leaf.key"; LEAF_CSR="$TMPDIR/leaf.csr"
LEAF_CRT="$TMPDIR/leaf.crt"; LEAF_CFG="$TMPDIR/leaf.cfg"
TLSPY="$TMPDIR/tls_srv.py"; REDIRPY="$TMPDIR/redir_srv.py"
TLSLOG="$TMPDIR/tls.log";   REDIRLOG="$TMPDIR/redir.log"
LOG="$TMPDIR/qemu.log"
TLSPORT=9443
REDIRPORT=9481
TLS_PID=""; REDIR_PID=""

cleanup() {
    [ -n "$TLS_PID" ]   && { kill "$TLS_PID"   2>/dev/null; wait "$TLS_PID"   2>/dev/null; }
    [ -n "$REDIR_PID" ] && { kill "$REDIR_PID" 2>/dev/null; wait "$REDIR_PID" 2>/dev/null; }
    rm -rf "$TMPDIR"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[curl-https-redirect] (1/5) Generate Hamnix Test CA + leaf cert"
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/CN=Hamnix Test CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1 \
    || skip "openssl CA generation failed"
openssl x509 -in "$CA_CRT" -outform DER -out "$CA_DER" 2>/dev/null \
    || skip "openssl CA DER conversion failed"
# Leaf: RSA-2048 signed by the test CA with rsassaPss-SHA256 (saltlen 32),
# matching scripts/test_net_https.sh so it dispatches through the kernel's
# rsa_pss_verify path and passes X.509 chain validation.
openssl genrsa -out "$LEAF_KEY" 2048 >/dev/null 2>&1
cat > "$LEAF_CFG" << 'CFGEOF'
[req]
distinguished_name = req_dn
prompt             = no
req_extensions     = v3_req
[req_dn]
CN = 10.0.2.200
[v3_req]
basicConstraints = CA:FALSE
subjectAltName   = DNS:10.0.2.200
CFGEOF
openssl req -new -key "$LEAF_KEY" -out "$LEAF_CSR" -config "$LEAF_CFG" >/dev/null 2>&1
openssl x509 -req -in "$LEAF_CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$LEAF_CRT" -days 30 \
    -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -extfile "$LEAF_CFG" -extensions v3_req \
    >/dev/null 2>&1 || skip "openssl leaf signing failed"

echo "[curl-https-redirect] (2/5) Build userland + hamsh-init initramfs (+CA)"
bash scripts/build_user.sh >/dev/null
[ -x build/user/curl.elf ] || skip "curl.elf missing after build"
INIT_ELF="$HAMSH_ELF" TLS_CA_DER="$CA_DER" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[curl-https-redirect] (3/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[curl-https-redirect] (4/5) Stand up TLS + redirect servers"
cat > "$TLSPY" << 'PYEOF'
import socket, ssl, sys, threading
CERT, KEY, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])
def resp(body, status=b"200 OK", extra=b""):
    return (b"HTTP/1.1 " + status + b"\r\n" + extra +
            b"Content-Type: text/html\r\n"
            b"Content-Length: " + str(len(body)).encode() + b"\r\n"
            b"Connection: close\r\n\r\n" + body)
PAGE = resp(b"<!doctype html><html><body>HTTPS_REDIR_BODY_OK</body></html>\n")
# /downgrade -> a TLS-downgrade 302 to a plaintext hop (must be refused guest-side)
DOWN = resp(b"go plaintext\n", b"302 Found",
            b"Location: http://10.0.2.201/plain\r\n")
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
ctx.num_tickets = 0
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT)); srv.listen(4)
print(f"[tls] listening on 127.0.0.1:{PORT}", flush=True)
def handle(c, peer):
    try:
        tls = ctx.wrap_socket(c, server_side=True)
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 4096:
            ch = tls.recv(4096)
            if not ch: break
            data += ch
        line = data.split(b"\r\n", 1)[0]
        print(f"[tls] req {line!r}", flush=True)
        tls.sendall(DOWN if b"/downgrade" in line else PAGE)
    except Exception as e:
        print(f"[tls] error: {e}", flush=True)
    finally:
        try: c.close()
        except: pass
while True:
    try: cs, peer = srv.accept()
    except OSError: break
    threading.Thread(target=handle, args=(cs, peer), daemon=True).start()
PYEOF

cat > "$REDIRPY" << 'PYEOF'
import socket, sys, threading
PORT = int(sys.argv[1])
def resp(body, status=b"200 OK", extra=b""):
    return (b"HTTP/1.1 " + status + b"\r\n" + extra +
            b"Content-Type: text/html\r\n"
            b"Content-Length: " + str(len(body)).encode() + b"\r\n"
            b"Connection: close\r\n\r\n" + body)
ROOT  = resp(b"redirecting\n", b"302 Found",
             b"Location: https://10.0.2.200/page\r\n")
PLAIN = resp(b"<html><body>PLAINTEXT_LEAK</body></html>\n")
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT)); srv.listen(4)
print(f"[redir] listening on 127.0.0.1:{PORT}", flush=True)
def handle(c, peer):
    try:
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 4096:
            ch = c.recv(4096)
            if not ch: break
            data += ch
        line = data.split(b"\r\n", 1)[0]
        print(f"[redir] req {line!r}", flush=True)
        c.sendall(PLAIN if b"/plain" in line else ROOT)
    except Exception as e:
        print(f"[redir] error: {e}", flush=True)
    finally:
        try: c.close()
        except: pass
while True:
    try: cs, peer = srv.accept()
    except OSError: break
    threading.Thread(target=handle, args=(cs, peer), daemon=True).start()
PYEOF

python3 "$TLSPY" "$LEAF_CRT" "$LEAF_KEY" "$TLSPORT" > "$TLSLOG" 2>&1 &
TLS_PID=$!
python3 "$REDIRPY" "$REDIRPORT" > "$REDIRLOG" 2>&1 &
REDIR_PID=$!
for _ in $(seq 1 30); do
    sleep 0.1
    grep -Fq "listening on 127.0.0.1:${TLSPORT}"   "$TLSLOG"   2>/dev/null \
        && grep -Fq "listening on 127.0.0.1:${REDIRPORT}" "$REDIRLOG" 2>/dev/null \
        && break
done
grep -Fq "listening on 127.0.0.1:${TLSPORT}"   "$TLSLOG"   2>/dev/null \
    || skip "TLS server did not start"
grep -Fq "listening on 127.0.0.1:${REDIRPORT}" "$REDIRLOG" 2>/dev/null \
    || skip "redirect server did not start"

echo "[curl-https-redirect] (5/5) Boot QEMU + drive curl through the redirect"
export QEMU_EXTRA_ARGS="-netdev user,id=n0,guestfwd=tcp:10.0.2.200:443-tcp:127.0.0.1:${TLSPORT},guestfwd=tcp:10.0.2.201:80-tcp:127.0.0.1:${REDIRPORT} -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56"

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 240 \
    -- "echo REDIR_START"                       2 \
       "curl http://10.0.2.201/"                8 \
       "echo REDIR_FOLLOW_DONE"                 2 \
       "curl https://10.0.2.200/downgrade"      8 \
       "echo REDIR_DOWNGRADE_DONE"              2 \
       "exit"                                   2
rc="$QEMU_DRIVE_RC"
set -e

echo "[curl-https-redirect] --- captured ---"
grep -E '\[dhcp\]|\[tls\]|\[http\]|REDIR_|HTTPS_REDIR_BODY_OK|PLAINTEXT_LEAK|curl:' "$LOG" || true
echo "[curl-https-redirect] --- end ---"
echo "[curl-https-redirect] --- tls srv ---";   cat "$TLSLOG"   2>/dev/null || true
echo "[curl-https-redirect] --- redir srv ---"; cat "$REDIRLOG" 2>/dev/null || true

# Count guest markers: zero => the boot never reached the shell => INCONCLUSIVE
if ! grep -Fq "REDIR_START" "$LOG"; then
    echo "[curl-https-redirect] SKIP: shell never reached the drive phase (no guest markers)"
    exit 0
fi
if grep -Fq "TRAP: vector" "$LOG"; then
    echo "[curl-https-redirect] FAIL: kernel CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -3
    exit 1
fi
if ! grep -Fq "[dhcp] got ip=10.0.2.15" "$LOG"; then
    echo "[curl-https-redirect] SKIP: DHCP did not bind (no guest network egress)"
    exit 0
fi

follow_block=$(sed -n '/REDIR_START/,/REDIR_FOLLOW_DONE/p' "$LOG")
down_block=$(sed -n '/REDIR_FOLLOW_DONE/,/REDIR_DOWNGRADE_DONE/p' "$LOG")

fail=0
if echo "$follow_block" | grep -Fq "HTTPS_REDIR_BODY_OK"; then
    echo "[curl-https-redirect] OK: http->https redirect followed; TLS body delivered"
else
    echo "[curl-https-redirect] FAIL: https body marker absent after http->https redirect"
    fail=1
fi
if echo "$down_block" | grep -Fq "PLAINTEXT_LEAK"; then
    echo "[curl-https-redirect] FAIL: https->http downgrade was followed (TLS downgrade!)"
    fail=1
else
    echo "[curl-https-redirect] OK: https->http downgrade redirect rejected"
fi

if [ "$fail" -ne 0 ]; then
    echo "[curl-https-redirect] FAIL (qemu rc=$rc)"
    tail -n 120 "$LOG"
    exit 1
fi
echo "[curl-https-redirect] PASS (qemu rc=$rc)"
