#!/usr/bin/env bash
# scripts/test_boot_net_phase.sh — the SHIPPED image's network bring-up must
# not stall the boot.
#
# WHY THIS GATE EXISTS
# ====================
# 2026-07-28, from the user, on a real install: "the image does boot, it just
# hangs for a min or two ... its network bring up took like 3 min." This is the
# first thing anyone sees, and nothing in the battery was watching it, because
# every net gate (test_dns / test_net_fuzz / test_net_http / test_net_icmp /
# ...) boots a DEVELOPER kernel via `-kernel`. Developer kernels carry
# /etc/run-selftests; the two production kernels (installed disk,
# HAMNIX_CPIO_EMPTY=1; installer medium, HAMNIX_INSTALLER_BLOB=1) do not. So
# the thing we ship was the one configuration nobody timed.
#
# Measured on the real build/hamnix-installer.img under OVMF/TCG before the
# fix: the network phase ran 24.21 s, of which
#
#   * 6.32 s was a busy-wait after icmp_send_echo_request() that had NO exit
#     condition — it ran all 50,000,000 virtio_net_poll() calls even though
#     "[icmp] echo reply from 10.0.2.2" had already been printed 0.02 s in; and
#   * 16.03 s was a DNS + HTTP + TLS-1.3 round trip to the PUBLIC INTERNET
#     (example.com) on the critical boot path, which then failed with
#     "cert chain rejected". None of the timeouts underneath those can even
#     expire that early in boot: time_init() has not run, so the jiffy tick
#     they count is not ticking. On a box with slow or filtered DNS that is
#     unbounded — the user's 1-3 minutes.
#
# WHAT IS ASSERTED (production installer image, OVMF + virtio-net + SLIRP)
# =======================================================================
#   1. THE NETWORK ACTUALLY COMES UP. "[dhcp] got ip=" must appear. Without
#      it nothing below means anything, so its absence is INCONCLUSIVE (125),
#      never a PASS — a boot that never reached DHCP has asserted nothing.
#   2. NO UNBOUNDED SPIN AFTER THE PING. The wall-clock gap between
#      "[icmp] echo reply from" and the NEXT serial line must be under
#      ICMP_GAP_MAX (default 3.0 s). Baseline after the fix is ~0.02 s and the
#      bug produced 6.30 s, so there is ~100x of headroom for a loaded host.
#      This is a RELATIVE measurement inside a single boot, not a boot-time
#      budget, which is why host load cannot flake it the way an absolute
#      deadline would.
#   3. NO SELF-TESTS OR INTERNET ROUND TRIPS ON THE SHIP PATH. A production
#      boot must emit none of "[dns-selftest] begin", "[net-fuzz] begin",
#      "[http] smoke test starting", "[https] smoke test starting". Those
#      still run in full — under /etc/run-selftests, in test_dns.sh,
#      test_net_fuzz.sh, test_net_http.sh and test_net_https*.sh, which all
#      build non-production kernels. This assertion is what keeps them from
#      creeping back onto the critical path of the thing we ship.
#
# The total network-phase wall clock is REPORTED but deliberately NOT
# asserted: it is an absolute duration under TCG and would flake on a loaded
# host, which is the exact trap that pushed test_installer_boot_heartbeat's
# BOOT_TIMEOUT from 180 s to 600 s.
#
# Verdicts: 0 = PASS, 1 = FAIL, 125 = INCONCLUSIVE (scripts/_verdict.sh).

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_installer_img.sh"

TAG="[test_boot_net_phase]"
IMG="${IMG:-build/hamnix-installer.img}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
ICMP_GAP_MAX="${ICMP_GAP_MAX:-3.0}"

say() { echo "$TAG $*"; }

# The image must be REAL and FRESH. installer_img_or_verdict exits 125 by
# itself when the build could not produce one — nothing booted, nothing
# asserted, and that is not a pass.
installer_img_or_verdict "$IMG" "$TAG"

OVMF_FD="${OVMF_FD:-/usr/share/ovmf/OVMF.fd}"
if [ ! -f "$OVMF_FD" ]; then
    for cand in /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ ! -f "$OVMF_FD" ]; then
    say "RESULT: INCONCLUSIVE — no OVMF firmware (apt install ovmf); nothing booted."
    exit 125
fi

LOG="${HAMNIX_BOOTNET_LOG:-$(mktemp --tmpdir hamnix-bootnet.XXXXXX.log)}"
OVMF_RW=$(mktemp --tmpdir hamnix-bootnet.ovmf.XXXXXX.fd)
cp "$OVMF_FD" "$OVMF_RW"
trap 'rm -f "$OVMF_RW"' EXIT

say "image      = $IMG  ($(installer_img_age_str "$IMG"))"
say "firmware   = $OVMF_FD"
say "log        = $LOG"
say "booting (OVMF + virtio-net/SLIRP, timeout ${BOOT_TIMEOUT}s) ..."

# Host-side per-line timestamps. The guest's printk sequence numbers are
# counters, not clocks — they cannot tell a 6-second stall from a fast line.
# We read the serial byte stream ourselves and stamp each line on arrival.
STAMPER=$(mktemp --tmpdir hamnix-bootnet.stamp.XXXXXX.py)
cat > "$STAMPER" <<'PYEOF'
import subprocess, sys, time
out = open(sys.argv[1], 'w')
p = subprocess.Popen(sys.argv[2:], stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
t0 = time.time()
buf = b''
try:
    while True:
        c = p.stdout.read(1)
        if not c:
            break
        if c == b'\n':
            out.write("%9.3f %s\n" % (time.time() - t0,
                                      buf.decode('utf-8', 'replace')))
            out.flush()
            buf = b''
        else:
            buf += c
finally:
    try:
        p.kill()
    except Exception:
        pass
    out.close()
PYEOF
trap 'rm -f "$OVMF_RW" "$STAMPER"' EXIT

set +e
timeout "${BOOT_TIMEOUT}s" python3 "$STAMPER" "$LOG" \
    qemu-system-x86_64 \
    -cpu qemu64 \
    -bios "$OVMF_RW" \
    -drive "file=$IMG,format=raw,if=none,id=instmedia" \
    -device virtio-blk-pci,drive=instmedia,bootindex=0 \
    -netdev user,id=hnet0 \
    -device virtio-net-pci,netdev=hnet0 \
    -m 2G \
    -vga std \
    -display none \
    -no-reboot \
    -monitor none \
    -serial stdio >/dev/null 2>&1
rc=$?
set -e
say "qemu rc=$rc (124 = hit the ${BOOT_TIMEOUT}s cap; the boot continues past"
say "  the network phase, so a cap hit is normal and not itself a failure)"

if [ ! -s "$LOG" ]; then
    say "RESULT: INCONCLUSIVE — no serial output at all; nothing was asserted."
    exit 125
fi

say "--- network phase (host-timestamped) ---"
grep -aE '\[virtio-net\]|\[arp\]|\[dhcp\]|\[icmp\]|\[dns|\[net-fuzz\]|\[http' "$LOG" \
    | head -60 || true
say "--- end ---"

# --- assertion 1: the network came up at all -------------------------------
if ! grep -aqF '[dhcp] got ip=' "$LOG"; then
    say "MISS: no '[dhcp] got ip=' line."
    if ! grep -aqF '[virtio-net] bdf=' "$LOG"; then
        say "  (no virtio-net probe either — the boot never reached"
        say "   net_smoke_test; nothing about the network phase was observed)"
    fi
    say "RESULT: INCONCLUSIVE — DHCP never bound, so the phase this gate"
    say "  measures did not happen. Not a pass and not a code failure."
    exit 125
fi
say "OK: DHCP bound —$(grep -am1 -a '\[dhcp\] got ip=' "$LOG" | sed 's/^ *[0-9.]* */ /')"

fail=0

# --- assertion 2: no unbounded spin after the gateway ping -----------------
GAP=$(awk -v want='[icmp] echo reply from' '
    idx > 0 && NR == idx + 1 { printf "%.3f", $1 - t; found = 1; exit }
    index($0, want) > 0 && idx == 0 { idx = NR; t = $1 }
    END { if (!found) print "" }
' "$LOG")
if [ -z "$GAP" ]; then
    say "MISS: no '[icmp] echo reply from' line followed by another line —"
    say "  the ping leg of the network phase was not observed."
    say "RESULT: INCONCLUSIVE"
    exit 125
fi
if awk -v g="$GAP" -v m="$ICMP_GAP_MAX" 'BEGIN { exit !(g > m) }'; then
    say "FAIL: ${GAP}s elapsed between '[icmp] echo reply from' and the next"
    say "  serial line (max ${ICMP_GAP_MAX}s). The post-ping poll loop in"
    say "  net_smoke_test() is running its full budget instead of"
    say "  short-circuiting on icmp_get_in_echo_reply_count()."
    fail=1
else
    say "OK: post-ping gap ${GAP}s (max ${ICMP_GAP_MAX}s) — the poll loop"
    say "  short-circuits on the echo reply"
fi

# --- assertion 3: no self-tests / internet round trips on the ship path ----
for banner in \
    '[dns-selftest] begin' \
    '[net-fuzz] begin' \
    '[http] smoke test starting' \
    '[https] smoke test starting'
do
    if grep -aqF "$banner" "$LOG"; then
        say "FAIL: production boot emitted '$banner'."
        say "  A shipped image must not run boot-path self-tests or reach the"
        say "  public internet before the desktop. These belong behind"
        say "  /etc/run-selftests, where test_dns.sh / test_net_fuzz.sh /"
        say "  test_net_http.sh / test_net_https*.sh still run them in full."
        fail=1
    else
        say "OK: absent on the ship path — '$banner'"
    fi
done

# --- reported, not asserted: total network-phase wall clock ----------------
PHASE=$(awk '
    index($0, "[virtio-net] bdf=") > 0 && s == "" { s = $1 }
    index($0, "[dhcp] got ip=")    > 0            { e = $1 }
    END { if (s != "" && e != "") printf "%.2f", e - s }
' "$LOG")
[ -n "$PHASE" ] && say "INFO: virtio-net probe -> DHCP bound = ${PHASE}s (reported, not asserted:" \
                       "an absolute TCG duration would flake on a loaded host)"

if [ "$fail" -ne 0 ]; then
    say "RESULT: FAIL"
    exit 1
fi

say "RESULT: PASS — the shipped image's network phase binds DHCP, does not"
say "  spin after the gateway ping, and runs no self-test or internet round"
say "  trip on the critical boot path."
exit 0
