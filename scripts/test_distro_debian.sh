#!/usr/bin/env bash
# scripts/test_distro_debian.sh - real Debian rootfs running inside a
# Hamnix distro-shape namespace. The follow-on to
# scripts/test_distro_namespace.sh (which proves the namespace bind
# mechanism with the rc-defined `linux` ns value); this script proves
# the same mechanism with a REAL debootstrap'd Debian rootfs
# (tests/distros/debian-minbase/rootfs/). Defines its OWN `debianns`
# at the prompt rather than using the rc-defined `linux`/`debian`
# templates because it targets the `debian-minbase` backing tree
# rather than `default/`.
#
# The bespoke `distrorun` launcher is RETIRED (HAMSH_SPEC §0). A
# distro-shape namespace is a captured `ns { }` value entered with
# plain namespace verbs. This test DEFINES one at the hamsh prompt —
# `debianns = ns { bind /etc /var/lib/distros/debian-minbase/etc ... }`
# — and enters it with `enter debianns { ... }`. That is the
# define-and-enter ergonomics goal: no ceremony, no special command.
#
# Boot path:
#   1. HAMNIX_EMBED_DEBIAN=1 walks tests/distros/debian-minbase/rootfs/
#      and embeds every file at /var/lib/distros/debian-minbase/<rel>
#      in the cpio archive. (~80-150 MB - default-off because that
#      inflates fs/initramfs_blob.S past GitHub's 100 MB push limit.)
#   2. INIT_ELF=hamsh.elf plants hamsh at /init so the boot drops us
#      at a shell prompt.
#   3. The kernel is rebuilt with the larger initramfs.
#   4. QEMU boots; we drive hamsh to define `debianns` then run
#      `enter debianns { /bin/cat /etc/debian_version }` and assert
#      the captured output contains a plausible Debian release token.
#
# Skip-on-missing: if rootfs/bin/true is absent (host hasn't run
# tests/distros/debian-minbase/BUILD.sh), this exits 0 with a SKIP
# message — matching test_u5_linux_binary.sh's pattern, so CI on hosts
# without debootstrap still passes.
#
# Notes on what's actually testable today:
#
#   The Debian-shipped /bin/true + /bin/cat are dynamically linked
#   against glibc (interpreter /lib64/ld-linux-x86-64.so.2). Hamnix's
#   U-track ELF loader currently handles static-pie binaries; running
#   a dynamically-linked Debian binary needs ld-linux-x86-64.so.2 to
#   load as a real ELF interpreter — a separate, larger bring-up.
#
#   So the PRIMARY assertion this script makes is:
#     (a) `enter debianns { }` successfully entered the namespace
#         (the cat ran inside it)
#     (b) the namespace's /etc/debian_version path resolves to the
#         REAL Debian release string (e.g. "13.5" / "trixie/sid") —
#         proving the bind grafted the debootstrap'd /etc/ into the
#         entered task's view.
#
#   That's the same evidence shape test_distro_namespace.sh gathers
#   for the default fixture, just with a REAL backing tree. When the
#   dynamic-linker work lands, this script can be extended to actually
#   exec /bin/true + assert exit 0.
#
# PASS markers (greppable):
#   ENTERED-DEBIAN-NS
#   <Debian release token in /etc/debian_version, anywhere in the log>

. "$(dirname "$0")/_build_lock.sh"
# Real-Debian opt-in: this gate asserts genuine Debian identity, so it
# needs the debootstrap closure that _build_lock.sh defaults OFF for the
# bare-kernel unit lane. _kernel_iso.sh raises -m for the large kernel.
export HAMNIX_DEFAULT_REAL_DEBIAN=1

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ROOTFS=tests/distros/debian-minbase/rootfs
if [ ! -f "$ROOTFS/bin/true" ]; then
    echo "[test_distro_debian] SKIP: $ROOTFS/bin/true not staged"
    echo "    Build with: bash tests/distros/debian-minbase/BUILD.sh"
    echo "    (see tests/distros/debian-minbase/HOWTO.md)"
    exit 0
fi

# Probe the release token actually present in this rootfs. /etc/debian_version
# varies by archive snapshot (trixie 13.5 today, may shift over time);
# we assert "the in-VM read returns the same bytes the host sees" rather
# than hardcoding a specific number, so the test stays green as
# upstream rolls.
EXPECTED_VER="$(head -c 64 "$ROOTFS/etc/debian_version" | tr -d '\n')"
echo "[test_distro_debian] expected /etc/debian_version='$EXPECTED_VER'"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_distro_debian] (1/4) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_distro_debian] (2/4) Plant /init = hamsh + embed Debian rootfs"
HAMNIX_EMBED_DEBIAN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_distro_debian] (3/4) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_distro_debian] (4/4) Boot QEMU + drive via hamsh"
LOG=$(mktemp)
# Restore the baseline default initramfs on exit so subsequent tests
# (and a clean repo state) don't carry forward the 1.6 GB-blob form.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # 0) Define the distro-shape namespace as a captured `ns {}` value
    #    at the prompt — the define-and-enter ergonomics path. The
    #    binds graft the debootstrap'd rootfs subtrees onto the FHS
    #    paths. (Backing-subtree-absent binds record cleanly; only
    #    /etc is exercised here.)
    printf 'debianns = ns {\n'
    printf 'bind /var/lib/distros/debian-minbase/etc /etc\n'
    printf 'bind /var/lib/distros/debian-minbase/usr /usr\n'
    printf 'bind /var/lib/distros/debian-minbase/lib /lib\n'
    printf 'bind /var/lib/distros/debian-minbase/lib64 /lib64\n'
    printf 'bind /var/lib/distros/debian-minbase/var /var\n'
    printf '}\n'
    sleep 2
    # 1) Read /etc/debian_version inside the debian-minbase namespace.
    #    `enter` forks a child, applies a fresh COW instance of the
    #    template, runs the body. The bind grafts rootfs/etc/ onto
    #    /etc/ inside the entered task's view; the cat is Hamnix's
    #    /bin/cat, but it opens "/etc/debian_version" which resolves
    #    through the chan_resolve_prefix hook to the embedded
    #    /var/lib/distros/debian-minbase/etc/debian_version.
    printf '/bin/echo BANNER-DEB-VERSION\n'
    sleep 1
    printf 'enter debianns {\n/bin/echo ENTERED-DEBIAN-NS\n/bin/cat /etc/debian_version\n}\n'
    sleep 3
    # 2) Sanity check: native /etc/debian_version still reads Hamnix's
    #    string. Demonstrates the namespace mutation is per-task.
    printf '/bin/echo BANNER-NATIVE-AFTER\n'
    sleep 1
    printf '/bin/cat /etc/debian_version\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_distro_debian] --- captured output ---"
cat "$LOG"
echo "[test_distro_debian] --- end output ---"

fail=0

# 1. `enter debianns { }` ran the body inside the namespace — the
#    namespace was privatised (rfork), the captured ns template's
#    bind grafted backing/etc onto /etc, and the body ran. Hamnix's
#    own /bin/echo + /bin/cat are what run inside.
if grep -F -q "ENTERED-DEBIAN-NS" "$LOG"; then
    echo "[test_distro_debian] OK: enter debianns { } ran the body inside the ns"
else
    echo "[test_distro_debian] MISS: enter debianns never ran the body"
    fail=1
fi

# 2. The /etc/debian_version bytes from the Debian rootfs appear in
#    the log near the BANNER-DEB-VERSION marker. We look for the
#    full host-observed bytes within 20 lines of the banner.
assert_banner_value() {
    local banner="$1"
    local value="$2"
    local label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; win=0; found=0 }
        index($0, b) > 0 { armed=1; win=0; next }
        armed { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 20) armed=0 }
        END { exit found ? 0 : 1 }
    ' "$LOG"; then
        echo "[test_distro_debian] OK: $label"
    else
        echo "[test_distro_debian] MISS: $label" \
             "(banner='$banner' value='$value')"
        fail=1
    fi
}

assert_banner_value "BANNER-DEB-VERSION" "$EXPECTED_VER" \
    "namespaced /etc/debian_version reads debian-minbase backing"

# 3. After the entered child returns, hamsh's own /etc/debian_version
#    still reads Hamnix's native value — proving the enter child's
#    rfork didn't bleed into the parent's namespace.
assert_banner_value "BANNER-NATIVE-AFTER" "hamnix/1.0" \
    "post-enter native /etc/debian_version still reads Hamnix"

if [ "$fail" -ne 0 ]; then
    echo "[test_distro_debian] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_distro_debian] PASS — real Debian rootfs read inside namespace"
