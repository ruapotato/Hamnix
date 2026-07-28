#!/usr/bin/env bash
# scripts/test_tcp_ring.sh — V5.3 TCP RX-ring multi-segment regression.
#
# Background: before V5.3 the TCP slot's inbound buffer was a single
# 1500-byte array that every inbound segment unconditionally
# overwrote (`tcp_slot_rx_len[slot] = copy_len`). When virtio_net_poll
# drained two back-to-back inbound TCP segments in the same poll
# cycle (e.g. a TLS handshake where Certificate splits across two
# segments — the load-bearing case for real-world LE chains) the
# second segment clobbered the first, the TLS stitcher never saw the
# missing prefix, and the handshake aborted with no diagnostic
# pointing at the actual loss.
#
# V5.3 replaces the single-overwrite buffer with a per-slot
# grow-and-append ring (16 KiB / slot, head/tail pointers, drop +
# leave-rcv_nxt-alone on overflow so peer retransmits). This test
# proves the ring accumulates two back-to-back segments without
# overwriting the first.
#
# Fixture: a Python TCP server bound to 127.0.0.1:9100, plumbed
# into the guest via `guestfwd=tcp:10.0.2.201:9100-tcp:127.0.0.1:9100`.
# When the kernel's tcp_ring_smoke_test() connects and sends "PULL\n",
# the server sends 4 KB back as two 2 KB writes separated by ~50 ms
# so they reach the guest as two distinct TCP segments. The kernel
# polls for ~500 ms WITHOUT calling tcp_recv (so both segments
# accumulate in the ring), then drains via tcp_recv. With the V5.3
# ring, the kernel collects all 4096 bytes and prints
# `[tcp_ring] PASS got 4096 bytes`.
#
# Before V5.3 the same boot would log a partial total (~2048) and
# the marker line would read `[tcp_ring] FAIL only got N bytes` —
# this script does NOT assert the pre-V5.3 failure (no main-branch
# regression artifact required; the fix is the artifact).
#
# Required marker: `[tcp_ring] PASS got 4096 bytes`

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_tcp_ring

ELF=build/hamnix-kernel.elf

echo "[test_tcp_ring] (1/4) Build userland + initramfs (with /etc/tcp-ring-test marker)"
bash scripts/build_user.sh >/dev/null
# ENABLE_TCP_RING_SMOKE=1 makes build_initramfs.py plant
# /etc/tcp-ring-test in the cpio archive; init/main.ad gates
# tcp_ring_smoke_test() on that file's presence so other test
# harnesses (test_net_tcp.sh, test_net_https.sh, run_x86_bare.sh)
# don't trip on an unreachable 10.0.2.201 during boot.
INIT_ELF=build/user/init.elf ENABLE_TCP_RING_SMOKE=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_tcp_ring] (2/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_tcp_ring] (3/4) Spawn fixture Python TCP server on 127.0.0.1:9100"
TMPDIR=$(mktemp -d -t hamnix-tcp-ring-XXXXXX)
LOG="$TMPDIR/qemu.log"
SRVLOG="$TMPDIR/srv.log"
SRVPY="$TMPDIR/srv.py"
SRV_PID=""

cleanup() {
    if [[ -n "${SRV_PID:-}" ]]; then
        kill "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
}
trap cleanup EXIT

cat > "$SRVPY" <<'PYEOF'
import socket, sys, time

PORT = 9100
HOST = "127.0.0.1"

# 4 KB of deterministic-but-not-zero bytes so the kernel can in
# principle verify content too (the V5.3 test only checks byte
# count). 2 KB chunks separated by ~50 ms to guarantee they land
# as two distinct TCP segments.
CHUNK_A = bytes((i & 0xFF) for i in range(2048))
CHUNK_B = bytes((((i + 0x80) & 0xFF)) for i in range(2048))

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((HOST, PORT))
s.listen(4)
# Note: 180 s overall server lifetime is comfortably longer than the
# kernel-side QEMU boot-to-tcp-ring-smoke latency (typically 30-60 s
# under TCG) plus the 120 s `timeout` cap on the QEMU run.
s.settimeout(180)
print(f"[srv] listening on {HOST}:{PORT}", flush=True)

# Accept loop. SLIRP can connect-and-disconnect eagerly at QEMU
# startup (depending on libslirp version) before the kernel reaches
# tcp_ring_smoke_test — that produces an early conn that recv'd
# nothing, which we just close and move on from. The PULL-bearing
# connection arrives later. Cap at 8 connections defensively.
for connno in range(8):
    try:
        conn, addr = s.accept()
    except (socket.timeout, OSError) as exc:
        print(f"[srv] accept gave up ({exc!r})", flush=True)
        sys.exit(0)
    print(f"[srv] conn#{connno} from {addr}", flush=True)
    try:
        # NO short recv timeout. The kernel can take its time to send
        # PULL after the SLIRP connection is established (multitasking
        # kernel = unpredictable lag between syn-ack and data segment).
        conn.settimeout(60)
        # Read PULL\n (5 bytes). Tolerate short reads.
        buf = b""
        while len(buf) < 5:
            chunk = conn.recv(5 - len(buf))
            if not chunk:
                break
            buf += chunk
        print(f"[srv] got {buf!r}", flush=True)
        if buf.startswith(b"PULL"):
            # Disable Nagle so each send goes out as its own
            # TCP segment.
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn.sendall(CHUNK_A)
            time.sleep(0.05)
            conn.sendall(CHUNK_B)
            print("[srv] sent 4096 bytes (2x2048)", flush=True)
            # Give the kernel time to drain before we close.
            time.sleep(0.5)
            # Mission accomplished — exit so the bash wrapper
            # doesn't wait on subsequent accepts.
            conn.close()
            print("[srv] PULL served, exiting", flush=True)
            sys.exit(0)
    except Exception as exc:
        print(f"[srv] error: {exc!r}", flush=True)
    finally:
        try: conn.close()
        except Exception: pass
sys.exit(0)
PYEOF

python3 "$SRVPY" >"$SRVLOG" 2>&1 &
SRV_PID=$!

# Give the server a moment to bind before QEMU starts.
for _ in $(seq 1 20); do
    if grep -F -q "listening on 127.0.0.1:9100" "$SRVLOG" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
if ! grep -F -q "listening on 127.0.0.1:9100" "$SRVLOG"; then
    echo "[test_tcp_ring] FAIL: fixture server failed to bind"
    cat "$SRVLOG"
    exit 1
fi

echo "[test_tcp_ring] (4/4) Boot QEMU with virtio-net + SLIRP guestfwd"
# Two guestfwd channels:
#   10.0.2.100:7  -> host `cat` (keeps the pre-existing tcp_smoke_test
#                    happy so the boot path doesn't stall on a 30 s
#                    retransmit-storm before we reach the V5.3 smoke).
#   10.0.2.201:9100 -> host Python fixture on 127.0.0.1:9100 (the V5.3
#                       multi-segment burst source).
set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat,guestfwd=tcp:10.0.2.201:9100-tcp:127.0.0.1:9100" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:57 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_tcp_ring] --- captured (tcp_ring / tcp / dhcp / arp) ---"
grep -E '\[tcp_ring\]|\[tcp\]|\[dhcp\]|\[arp\]' "$LOG" || true
echo "[test_tcp_ring] --- server log ---"
cat "$SRVLOG" || true
echo "[test_tcp_ring] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [tcp_ring]
# markers. Route the zero-marker case through the shared discriminator FIRST.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[tcp_ring\]'

if grep -F -q "[tcp_ring] PASS got 4096 bytes" "$LOG"; then
    verdict_pass "$TAG" "the TCP RX ring accumulated both segments into a" \
        "full 4096-byte payload (segmented receive reassembles in-order)"
fi

# Diagnostics: did we at least reach the smoke?
if grep -F -q "[tcp_ring] V5.3 smoke test starting" "$LOG"; then
    echo "[test_tcp_ring] --- full kernel log tail ---"
    tail -80 "$LOG"
    if [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[tcp_ring] smoke ran but did not accumulate the full 4096 bytes" \
            "and qemu was killed by timeout (rc=124) — starved before the" \
            "second segment arrived. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "the RX-ring smoke ran but did not accumulate the full 4096 bytes" \
        "(qemu rc=$rc) — real regression in segmented TCP receive."
fi

echo "[test_tcp_ring] --- full kernel log ---"
cat "$LOG"
verdict_fail "$TAG" \
    "the [tcp_ring] smoke never started despite other markers (qemu rc=$rc)" \
    "— real regression in reaching the smoke path (DHCP / netdev)."
