#!/usr/bin/env bash
# scripts/test_forkexec_static.sh -- QA-N29 minimal fork+execve repro.
# static-PIE parent fork()s, child execve()s /bin/u_glibc_hello.
# PASS markers: "FES: parent before fork" + "U18: glibc static hello"
#             + "FES: parent reaped child status=0"

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

make -C tests/u-binary/src/glibc_hello install >/dev/null 2>&1 || true
make -C tests/u-binary/src/forkexec_static install >/dev/null 2>&1 || true
[ -f tests/u-binary/u_forkexec_static ] || { echo "SKIP: fixture not built"; exit 0; }

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[fes] build user + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[fes] embed ubin + hamsh init"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[fes] build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

QEMU_EXTRA_ARGS="-enable-kvm -cpu host" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "u_forkexec_static" 8 \
       "exit" 1
echo "[fes] --- output ---"; cat "$LOG"; echo "[fes] --- end ---"
echo "=== VERDICT ==="
grep -aF "FES: parent reaped child status=0" "$LOG" && echo "PASS" || echo "FAIL"
# FALSE-POSITIVE FIX (2026-07-28): the bare `coredump` term matched the
# BENIGN boot lines every healthy boot prints --
#     [boot:30.d] coredump gate
#     [coredump] skipped (no /etc/coredump-test marker)
#     [coredump] module linked; fatal-sig table OK
# -- so this gate printed FAULT-SEEN on a completely clean run. The real
# evidence of a fault is a coredump actually being TAKEN ("[coredump] pid=N
# capturing core..."), an NX exec-fault, or a 139 exit; match only those.
grep -aiE "NX exec-fault|capturing core|code=139|\[coredump\] wrote /tmp/core" "$LOG" \
    && echo "FAULT-SEEN" || true
