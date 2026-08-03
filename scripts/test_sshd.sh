#!/usr/bin/env bash
# scripts/test_sshd.sh — Hamnix native SSH-2.0 server, end to end.
#
# Builds user/sshd.ad, boots it as /init in QEMU with a SLIRP hostfwd
# that maps a host port onto the guest's port 22, then runs the host's
# REAL OpenSSH client against it and asserts how far it gets.
#
# Pipeline:
#   1. Build userland (incl. sshd + hamsh) -> build/user/*.elf.
#   2. Embed sshd as /init, rebuild the kernel.
#   3. Boot QEMU with hostfwd=tcp::HOSTPORT-:22.
#   4. After the guest prints "[sshd] listening on port 22", run
#         ssh -v -p HOSTPORT root@127.0.0.1 ...
#      with password auth (sshpass if available) and a one-shot command.
#
# Success tiers (the script reports the highest tier reached):
#   TIER 1          : the SSH client's verbose log shows the key
#                     exchange completing — "expecting SSH2_MSG_NEWKEYS"
#                     plus the guest log shows
#                     "[sshd] key exchange complete".
#   TIER 2          : authentication succeeds ("[sshd] authentication
#                     succeeded").
#   TIER 2.5        : a session channel opened and hamsh was spawned
#                     and bridged to it.
#   TIER 3 (full)   : the remote command's output comes back over the
#                     SSH channel — a genuinely interactive session.
#
# The script PASSES only at TIER 3: a session that authenticates but
# cannot round-trip a command's output is still broken. TIER 1/2/2.5
# are reported as diagnostic milestones on the way there.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
SSHD_ELF=build/user/sshd.elf

# --- pick a free host port -------------------------------------------
HOST_PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_sshd] host port $HOST_PORT -> guest port 22"

echo "[test_sshd] (1/3) Build userland (incl. sshd)"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$SSHD_ELF" ]; then
    echo "[test_sshd] FAIL: $SSHD_ELF not built"
    exit 1
fi

echo "[test_sshd] (2/3) Embed sshd as /init + rebuild kernel"
INIT_ELF="$SSHD_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_sshd] (3/3) Boot QEMU with hostfwd tcp::${HOST_PORT}-:22"
LOG=$(mktemp)
SSHLOG=$(mktemp)
trap 'rm -f "$LOG" "$SSHLOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Background host-side SSH client. Wait for the guest's listener marker,
# then run the real OpenSSH client against the forwarded port.
(
    python3 - "$HOST_PORT" "$SSHLOG" "$LOG" <<'PY'
import subprocess, sys, time, os

port = sys.argv[1]
out_path = sys.argv[2]
log_path = sys.argv[3]

# Wait for the guest's listener marker (up to ~180 s of boot).
deadline = time.time() + 180
while time.time() < deadline:
    try:
        with open(log_path, "r", errors="replace") as f:
            if "[sshd] listening on port 22" in f.read():
                break
    except OSError:
        pass
    time.sleep(1)

# Give sshd a moment to reach accept().
time.sleep(2)

ssh_common = [
    "-v",
    "-tt",                       # force a pty + interactive shell
    "-p", port,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
    "-o", "ConnectTimeout=60",
    "-o", "NumberOfPasswordPrompts=1",
]

# Drive ssh through a REAL pty for its stdin/stdout. If ssh's stdin
# were a plain pipe, it would hit EOF the instant our scripted input
# was written and OpenSSH would tear the session down ("disconnected
# by user") before the remote shell's output round-tripped. A pty
# never EOFs, so ssh stays attached: we type `uname`, wait, read the
# echoed remote output, type `exit`, and let hamsh's exit close the
# channel — the clean teardown path. sshpass is used (when present)
# for non-interactive password entry; ssh writes the verbose log to a
# separate stderr pipe.
import pty, select, signal

result = ""
have_sshpass = subprocess.call(["which", "sshpass"],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL) == 0
try:
    if have_sshpass:
        cmd = (["sshpass", "-p", "hamnix", "ssh"] + ssh_common +
               ["root@127.0.0.1"])
    else:
        cmd = ["ssh"] + ssh_common + ["root@127.0.0.1"]

    m_fd, s_fd = pty.openpty()
    proc = subprocess.Popen(cmd, stdin=s_fd, stdout=s_fd,
                            stderr=subprocess.PIPE, text=False,
                            close_fds=True)
    os.close(s_fd)

    captured = b""
    err_chunks = []
    typed_cmd = False
    typed_exit = False
    deadline = time.time() + 75
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        rfds, _, _ = select.select([m_fd, proc.stderr], [], [], 0.5)
        if m_fd in rfds:
            try:
                chunk = os.read(m_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            captured += chunk
        if proc.stderr in rfds:
            ec = proc.stderr.read1(4096) if hasattr(proc.stderr, "read1") \
                 else proc.stderr.read(4096)
            if ec:
                err_chunks.append(ec)
        # Once ssh reports the interactive session is up, type `uname`.
        joined_err = b"".join(err_chunks)
        if (not typed_cmd) and b"Entering interactive session" in joined_err:
            time.sleep(2)
            os.write(m_fd, b"uname\n")
            typed_cmd = True
            cmd_at = time.time()
        # A short while after typing the command, send `exit` so hamsh
        # terminates and the server closes the channel cleanly.
        if typed_cmd and (not typed_exit) and \
                time.time() - cmd_at > 6:
            os.write(m_fd, b"exit\n")
            typed_exit = True
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
    rc = proc.returncode
    try:
        os.close(m_fd)
    except OSError:
        pass
    out = captured.decode("utf-8", "replace")
    err = b"".join(err_chunks).decode("utf-8", "replace")
    result = ("=== ssh stdout ===\n" + out +
              "\n=== ssh stderr (verbose) ===\n" + err +
              "\n=== ssh rc=%s ===\n" % rc)
except Exception as e:
    result = "ssh client error: %r\n" % e

with open(out_path, "w") as f:
    f.write(result)
PY
) &
CLIENT_PID=$!

set +e
timeout 280s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,hostfwd=tcp::${HOST_PORT}-:22,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

wait "$CLIENT_PID" 2>/dev/null || true

echo "[test_sshd] --- guest sshd log ---"
grep -E '\[sshd\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_sshd] --- ssh client log ---"
cat "$SSHLOG" 2>/dev/null || echo "(no ssh client output)"
echo "[test_sshd] --- end ---"

tier=0

# TIER 1: key exchange + NEWKEYS.
if grep -F -q "[sshd] key exchange complete" "$LOG"; then
    echo "[test_sshd] TIER 1 OK: guest completed KEX + NEWKEYS"
    tier=1
else
    echo "[test_sshd] TIER 1 MISS: guest did not complete KEX"
fi
if grep -E -q "SSH2_MSG_NEWKEYS|NEWKEYS received|kex: .* MAC" "$SSHLOG" 2>/dev/null; then
    echo "[test_sshd] TIER 1 corroborated by ssh client (-v shows NEWKEYS)"
fi

# TIER 2: authentication. sshd logs either "[sshd] password
# authentication succeeded" or "[sshd] publickey authentication
# succeeded" depending on which method the client used — accept either.
if grep -E -q "\[sshd\] (password|publickey) authentication succeeded" "$LOG"; then
    echo "[test_sshd] TIER 2 OK: authentication succeeded"
    tier=2
fi

# TIER 2.5: the connection layer — a session channel opened and hamsh
# was spawned and wired to it.
if grep -F -q "[sshd] session channel opened" "$LOG" && \
   grep -F -q "[sshd] hamsh spawned for SSH session" "$LOG"; then
    echo "[test_sshd] TIER 2.5 OK: session channel opened + hamsh spawned" \
         "and bridged to the SSH channel"
fi

# TIER 3: the remote command ran and its OUTPUT came back. `uname` on
# Hamnix prints the exact line "Hamnix x86_64 1.0"; we look for that
# inside ssh's stdout (pty) section only — the verbose stderr log never
# carries remote command output.
SSH_STDOUT=$(sed -n '/=== ssh stdout ===/,/=== ssh stderr/p' "$SSHLOG" 2>/dev/null || true)
if echo "$SSH_STDOUT" | grep -F -q "Hamnix x86_64"; then
    echo "[test_sshd] TIER 3 OK: remote 'uname' output received over the SSH channel"
    tier=3
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_sshd] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi

# The deliverable is a fully INTERACTIVE SSH session: `ssh` in, run a
# command, and get its output back. That is TIER 3. TIER 1/2/2.5 are
# only diagnostic milestones — a session that authenticates but cannot
# round-trip a command is still broken, so the script now REQUIRES
# tier 3 to pass.
if [ "$tier" -ge 3 ]; then
    echo "[test_sshd] PASS (tier $tier) — interactive SSH session works:" \
         "ssh in, ran 'uname', output came back over the channel"
    exit 0
fi

if [ "$tier" -ge 1 ]; then
    echo "[test_sshd] FAIL (tier $tier) — reached KEX/auth but the remote" \
         "command's output never came back over the SSH channel"
else
    echo "[test_sshd] FAIL (qemu rc=$rc) — KEX did not complete"
fi
echo "[test_sshd] --- full kernel log (last 200 lines) ---"
tail -n 200 "$LOG"
exit 1
