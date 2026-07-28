#!/usr/bin/env bash
# scripts/test_ntp.sh — regression for user/ntpd.ad + SYS_SET_REALTIME.
#
# Boots Hamnix with virtio-net + SLIRP. SLIRP forwards outbound UDP
# datagrams to the host network, so a UDP/123 request to a real NTP
# server (pool.ntp.org by default) is reachable when the host has
# internet — same path test_dns.sh / test_https.sh ride. The fixture
# resolves the hostname (sys_resolve → in-kernel DNS at 10.0.2.3),
# dials /net/udp/<N>/{ctl,data}, sends the 48-byte NTPv3 request,
# parses the response, and calls sys_set_realtime(epoch).
#
# Assertion strategy mirrors test_ping.sh:
#
#   FULL PASS (host has internet):
#     "ntpd: wall clock anchored" appears AND a subsequent
#     `cat /proc/realtime` reads back an epoch within 24h of the
#     host's `date -u +%s`. This proves end-to-end NTP -> kernel
#     wall clock.
#
#   INCONCLUSIVE, exit 125 (no internet / sandboxed CI):
#     "ntpd: cannot resolve" OR "ntpd: timeout / no reply" appears —
#     the binary launched and dialed but no NTP server was reachable,
#     so the anchor was never observed. SLIRP's external reachability
#     is an ENVIRONMENT dependency; absence of evidence, not a pass.
#
#   FAIL: ntpd never produced a banner (binary missing / crashed) OR
#         no kernel boot OR a TRAP/panic happened during the run OR
#         "ntpd: cannot open /net/udp conn" — the /net/udp dial path IS
#         the code under test, so a clone failure inside the guest is an
#         OBSERVED violation, never an "external unavailable" skip.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ntp] (1/3) Build userland + swap /init = hamsh"
bash scripts/build_user.sh >/dev/null
if [ ! -x "build/user/ntpd.elf" ]; then
    echo "[test_ntp] FAIL: build/user/ntpd.elf missing after build"
    exit 1
fi
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ntp] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ntp] (3/3) Boot QEMU with virtio-net + SLIRP"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Capture host wall clock to range-check the guest later.
HOST_EPOCH_BEFORE=$(date -u +%s)

set +e
(
    # The kernel runs DHCP + DNS + the in-kernel networking smokes during
    # boot, so by the time hamsh's prompt appears the network is up.
    # rc.boot already invoked `ntpd` once — we just need to give it a
    # window to complete, then read /proc/realtime to check the anchor
    # stuck. 75 s matches test_ping.sh's window (kernel net-smoke chain
    # is long).
    sleep 75
    printf 'echo NTP_PROBE_BEGIN\n'
    # The rc-side `ntpd` already ran; re-invoke it explicitly so we
    # capture the markers between sentinels even if rc.boot's output
    # raced past the readline buffer.
    printf '/bin/ntpd\n'
    sleep 15
    printf 'echo NTP_PROBE_END\n'
    printf 'echo REALTIME_BEGIN\n'
    printf 'cat /proc/realtime\n'
    sleep 2
    printf 'echo REALTIME_END\n'
    sleep 1
    printf 'exit\n'
    sleep 2
) | timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

HOST_EPOCH_AFTER=$(date -u +%s)

echo "[test_ntp] --- relevant lines ---"
grep -E 'ntpd:|REALTIME_|NTP_PROBE_|TRAP: vector' "$LOG" || true
echo "[test_ntp] --- end ---"

fail=0

# No kernel TRAP during the run.
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_ntp] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
else
    echo "[test_ntp] OK: no kernel TRAP / panic"
fi

# Hamsh came up at all (banner / sentinel).
if ! grep -F -q "NTP_PROBE_BEGIN" "$LOG"; then
    echo "[test_ntp] FAIL: hamsh never reached the interactive loop"
    fail=1
fi

# ntpd must have at least printed its banner — proves the binary
# launched. Banner is "ntpd: syncing time from <server>".
if grep -F -q "ntpd: syncing time from" "$LOG"; then
    echo "[test_ntp] OK: ntpd banner printed"
else
    echo "[test_ntp] MISS: ntpd never printed its banner"
    fail=1
fi

# FULL PASS path: anchor succeeded.
anchored=0
if grep -F -q "ntpd: wall clock anchored" "$LOG"; then
    anchored=1
    echo "[test_ntp] OK: 'ntpd: wall clock anchored'"
fi

# Range-check /proc/realtime against host wall clock (only meaningful
# if ntpd anchored; otherwise rtc_boot_epoch still came from CMOS,
# which qemu defaults to the host's RTC so the line still appears).
realtime_iso=$(sed -n '/REALTIME_BEGIN/,/REALTIME_END/p' "$LOG" \
    | grep -E -o '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z [0-9]+' \
    | head -n1 || true)
if [ -z "$realtime_iso" ]; then
    echo "[test_ntp] MISS: /proc/realtime line absent / unparseable"
    fail=1
else
    guest_epoch=$(echo "$realtime_iso" | awk '{print $2}')
    delta=$(( guest_epoch - HOST_EPOCH_BEFORE ))
    if [ "$delta" -lt 0 ]; then delta=$(( -delta )); fi
    if [ "$delta" -gt 86400 ]; then
        echo "[test_ntp] FAIL: guest epoch $guest_epoch and host epoch" \
             "$HOST_EPOCH_BEFORE differ by ${delta}s (>24h)"
        fail=1
    else
        echo "[test_ntp] OK: guest epoch $guest_epoch within ${delta}s of host (line='$realtime_iso')"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ntp] FAIL (qemu rc=$rc)"
    echo "[test_ntp] --- full log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

if [ "$anchored" -eq 1 ]; then
    echo "[test_ntp] PASS (full NTP round-trip + kernel anchor)"
    exit 0
fi

# Anchor path didn't fire. Sort the remaining markers into the three-valued
# vocabulary (scripts/_verdict.sh) — NOT all into "PASS".
#
# ORDER MATTERS, and getting it wrong was the bug (2026-07-28). The
# `timeout / no reply` branch used to be tested BEFORE the `cannot open
# /net/udp conn` branch, so a run in which ntpd could not clone /net/udp AT
# ALL — and then, unsurprisingly, also timed out — printed
#
#     [test_ntp] PASS (/net/udp dial wired; external NTP unavailable)
#
# i.e. it claimed the dial path was wired using the log of a run in which the
# dial path failed. The IN-GUEST failure is checked FIRST now.
#
# (1) IN-GUEST FAILURE => FAIL. `cannot open /net/udp conn` means the clone of
#     /net/udp — THE CODE UNDER TEST per this file's header — failed inside
#     the guest. No DNS lookup, no packet, no server: nothing external is
#     involved. It is an OBSERVED violation of this gate's assertion.
if grep -F -q "ntpd: cannot open /net/udp conn" "$LOG"; then
    echo "[test_ntp] FAIL: ntpd could not open a /net/udp conn — the Plan 9"
    echo "[test_ntp]   UDP dial path (the code under test) is broken in the"
    echo "[test_ntp]   guest. This is NOT an 'external NTP unavailable' skip:"
    echo "[test_ntp]   the clone never left the kernel."
    grep -F "ntpd:" "$LOG" | tail -10 || true
    echo "[test_ntp] --- full log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi
# (2) EXTERNAL DEPENDENCY UNREACHABLE => INCONCLUSIVE, not PASS. ntpd
#     demonstrably launched and dialed, but the assertion this gate is named
#     for (NTP round-trip anchors the kernel wall clock) was never observed.
#     Absence of evidence. ci_run_gate.sh turns 125 into a ::warning::, so
#     this stays non-failing in CI without being counted as proof.
if grep -F -q "ntpd: cannot resolve" "$LOG"; then
    echo "[test_ntp] INCONCLUSIVE: ntpd ran but DNS was unreachable in this" >&2
    echo "[test_ntp]   sandbox, so no NTP round-trip and no wall-clock anchor" >&2
    echo "[test_ntp]   was observed. NOT a pass. Re-run with internet." >&2
    exit 125
fi
if grep -F -q "ntpd: timeout / no reply" "$LOG"; then
    echo "[test_ntp] INCONCLUSIVE: ntpd ran and dialed /net/udp, but no NTP" >&2
    echo "[test_ntp]   server replied, so the anchor was never observed." >&2
    echo "[test_ntp]   NOT a pass. Re-run with internet." >&2
    exit 125
fi
# (3) A KoD / bogus reply is a REAL packet that came back over the wire and
#     went through the wire-format parser — genuinely observed behaviour of
#     the code under test, so this one stays a pass.
if grep -F -q "ntpd: bogus / KoD reply" "$LOG"; then
    echo "[test_ntp] NOTE: ntpd ran; server returned a KoD / empty packet"
    echo "[test_ntp] PASS (ntpd wire-format parser exercised)"
    exit 0
fi

echo "[test_ntp] FAIL: ntpd produced no anchored / fallback markers (qemu rc=$rc)"
echo "[test_ntp] --- full log (last 200 lines) ---"
tail -n 200 "$LOG"
exit 1
