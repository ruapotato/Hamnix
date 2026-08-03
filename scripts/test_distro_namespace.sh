#!/usr/bin/env bash
# scripts/test_distro_namespace.sh - distro-shape namespace regression.
#
# The bespoke `distrorun` launcher is RETIRED (HAMSH_SPEC §0: one
# primitive, many skins — no special container command). Running a
# binary in a distro-shape namespace is now plain namespace verbs:
#
#   * /etc/rc.boot defines the Linux runtime namespace as a captured
#     `ns clean { }` value named `linux` (and an `debian` alias for
#     the same body) — the distro-shape recipe.
#   * `enter linux { <cmd> }` forks a child, applies a fresh COW
#     instance of the template, runs the command, blocks for it.
#
# CLEAN ISOLATION: the template is `ns clean { }` (hermetic base,
# RFCNAMEG), NOT an overlay of the ambient namespace. The container
# sees ONLY the explicit share list rc.boot enumerates:
#   /        -> /var/lib/distros/default      (distro tree as root)
#   /home    -> /home                         (user files)
#   /dev     -> '#c'                          (virtual devices)
#   /proc    -> '#p'                          (process introspection)
#   /srv     -> '#s'                          (9P server registry)
#   /n       -> '#/'                          (Plan 9 mount parent)
# Anything an apt-installed package writes to (/bin, /etc, /usr,
# /lib, /var, /opt, /root, /tmp) stays INSIDE the distro tree —
# nothing leaks onto the host. This test PROVES that isolation.
#
# This test boots via the DEFAULT /init shim (so /etc/rc.boot runs
# and `linux`/`debian` are defined), then verifies end-to-end on
# Phase C's rfork/bind/mount:
#
#   1. rc.boot defined the `linux` namespace value.
#   2. `enter linux { /bin/cat /etc/debian_version }` reads
#      /etc/debian_version from the distro backing
#      (/var/lib/distros/default/etc/debian_version = "12.4") — the
#      root-rebind grafts the distro tree into the child's view, so
#      /etc/debian_version resolves into the distro's etc/.
#   3. From OUTSIDE the namespace (hamsh's own view, unaffected by
#      the enter child's rfork), /etc/debian_version still reads
#      Hamnix's native value ("hamnix/1.0") — the namespace mutation
#      is per-task, not global.
#   4. `enter linux { ... } && echo CHAIN_OK` — the §11 namespace
#      verbs chain with && / || like any other command.
#   5. ISOLATION: a sentinel `bind /sentinel_host /tmp` set in the
#      AMBIENT namespace BEFORE entering is NOT visible inside
#      `enter linux { ... }` — clean isolation drops ambient binds
#      that aren't in the share list, so an apt-installed package
#      can't reach back through a stale ambient mount point.
#   6. The `debian` alias is the same template under a different
#      name (`enter debian { … }` reads "12.4" the same way).
#
# Test backing fixture is tests/distros/default/ (etc/debian_version
# = "12.4"). build_initramfs.py walks tests/distros/* and embeds each
# file at /var/lib/distros/<name>/<rel>. For this test we also stage
# Hamnix's own cat/echo/true/ls ELFs into tests/distros/default/bin/
# so the container has a working /bin/* (under clean isolation the
# host /bin is no longer visible; the distro tree's /bin is the only
# place to find executables). The trap restores the committed fixture.

. "$(dirname "$0")/_build_lock.sh"
# Real-Debian opt-in: this gate walks the real Debian distro tree and
# reads its debian_version, so it needs the debootstrap closure that
# _build_lock.sh defaults OFF for the bare-kernel unit lane.
# _kernel_iso.sh raises -m for the large kernel.
export HAMNIX_DEFAULT_REAL_DEBIAN=1

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_distro_namespace] (1/4) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_distro_namespace] (2/4) Plant default /init shim + " \
     "/var/lib/distros/default/* fixture"
# Under clean isolation `enter linux { /bin/cat ... }` cannot see the
# host /bin — the only /bin the container sees is the distro tree's
# own /var/lib/distros/default/bin/. Plant Hamnix's ELFs there so the
# fixture has a working userland to demonstrate path resolution.
DISTRO_BIN="tests/distros/default/bin"
mkdir -p "$DISTRO_BIN"
PLANTED_BINS=(cat echo true ls)
for b in "${PLANTED_BINS[@]}"; do
    cp "build/user/${b}.elf" "$DISTRO_BIN/${b}"
done

# Default /init = the shim — it execs hamsh with /etc/rc.boot, which
# defines the `linux` namespace value. No INIT_ELF override.
python3 scripts/build_initramfs.py >/dev/null

# Restore the committed fixture (no compiled ELFs in tests/distros/).
cleanup() {
    rm -f "$LOG"
    rm -rf "$DISTRO_BIN"
}
LOG=$(mktemp)
trap cleanup EXIT

echo "[test_distro_namespace] (3/4) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_distro_namespace] (4/4) Boot QEMU + drive via hamsh"

# In-VM script: drive hamsh through (a) native read of
# /etc/debian_version, (b) ambient sentinel bind that the linux ns
# must NOT see, (c) `enter linux { cat ... }` read inside the rc-
# defined namespace, (d) `cat /tmp/sentinel_host_marker` inside the
# entered ns asserting the ambient bind was dropped, (e) the same
# read through the `debian` alias, (f) a second native read AFTER
# the enter returns, (g) an `enter ... && echo` chain.
set +e
(
    sleep 4
    # 1) Baseline native read (before any enter).
    printf '/bin/echo BANNER-NATIVE-PRE\n'
    sleep 1
    printf '/bin/cat /etc/debian_version\n'
    sleep 1
    # 1a) Plant an AMBIENT sentinel bind at /sentinel_host pointing at
    #     the distro tree's etc/ (so the path is reachable on disk).
    #     Under the OLD overlay model this would leak into the linux
    #     ns and `cat /sentinel_host/debian_version` would read "12.4"
    #     inside the entered child too; under clean isolation the
    #     ambient bind is dropped and the cat fails (no leak).
    printf 'bind /var/lib/distros/default/etc /sentinel_host\n'
    sleep 1
    printf '/bin/echo BANNER-AMBIENT-SENTINEL\n'
    sleep 1
    printf '/bin/cat /sentinel_host/debian_version\n'
    sleep 2
    # 2) Namespaced read via `enter linux`.
    printf '/bin/echo BANNER-RUNTIME\n'
    sleep 1
    printf 'enter linux {\n/bin/cat /etc/debian_version\n}\n'
    sleep 3
    # 3) ISOLATION: the ambient /sentinel_host bind MUST NOT be visible
    #    inside the linux ns. `cat /sentinel_host/debian_version` must
    #    FAIL with "no such file" (the cat ELF prints the error string
    #    on stderr); the banner-window assertion later checks that the
    #    "12.4" string is absent in this window.
    printf '/bin/echo BANNER-ISOLATION\n'
    sleep 1
    printf 'enter linux {\n/bin/cat /sentinel_host/debian_version\n/bin/echo ISO_DONE\n}\n'
    sleep 3
    # 4) The `debian` alias resolves the SAME backing tree.
    printf '/bin/echo BANNER-DEBIAN-ALIAS\n'
    sleep 1
    printf 'enter debian {\n/bin/cat /etc/debian_version\n}\n'
    sleep 3
    # 5) Native read AFTER the entered children returned — proves
    #    hamsh's own namespace is untouched.
    printf '/bin/echo BANNER-NATIVE-POST\n'
    sleep 1
    printf '/bin/cat /etc/debian_version\n'
    sleep 1
    # 6) The §11 namespace verbs chain with && like any command.
    printf 'enter linux { /bin/true } && /bin/echo CHAIN_OK\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_distro_namespace] --- captured output ---"
cat "$LOG"
echo "[test_distro_namespace] --- end output ---"

fail=0

# 1. rc.boot defined the Linux runtime namespace value.
if grep -a -F -q "rc.boot: linux runtime namespace defined" "$LOG"; then
    echo "[test_distro_namespace] OK: rc.boot defined the linux ns value"
else
    echo "[test_distro_namespace] MISS: rc.boot did not define linux"
    fail=1
fi

# Helper: assert that VALUE appears in the captured log somewhere
# within the 20 lines following the BANNER marker. `[atkbd-diag]`
# periodic kernel keyboard-poll lines are skipped — they are neither
# program output nor window-consuming.
assert_banner_value() {
    local banner="$1"
    local value="$2"
    local label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; win=0; found=0 }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, b) > 0 { armed=1; win=0; next }
        armed { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 20) armed=0 }
        END { exit found ? 0 : 1 }
    ' "$LOG"; then
        echo "[test_distro_namespace] OK: $label"
    else
        echo "[test_distro_namespace] MISS: $label" \
             "(banner='$banner' value='$value')"
        fail=1
    fi
}

# Helper: assert that VALUE is ABSENT from the window after BANNER.
# Mirrors assert_banner_value but inverts the success condition. Used
# by the isolation assertion — "12.4" must NOT appear after
# BANNER-ISOLATION because the ambient /sentinel_host bind isn't
# visible inside the clean linux ns.
assert_banner_absent() {
    local banner="$1"
    local value="$2"
    local label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; win=0; found=0 }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, b) > 0 { armed=1; win=0; next }
        armed { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 20) armed=0 }
        END { exit found ? 1 : 0 }
    ' "$LOG"; then
        echo "[test_distro_namespace] OK: $label"
    else
        echo "[test_distro_namespace] FAIL: $label" \
             "(banner='$banner' must NOT contain '$value')"
        fail=1
    fi
}

# 2. Inside the linux namespace, /etc/debian_version came from the
#    default distro backing ("12.4"). The root rebind (bind /
#    /var/lib/distros/default) resolves /etc/debian_version through
#    the distro tree.
assert_banner_value "BANNER-RUNTIME" "12.4" \
    "enter linux: /etc/debian_version reads distro backing"

# 3. ISOLATION: the ambient `bind /sentinel_host …` MUST NOT be
#    visible inside the clean linux ns. Sanity-check the ambient bind
#    DOES read "12.4" outside (so the bind itself worked), confirm
#    the entered child actually ran (ISO_DONE), then assert "12.4"
#    is ABSENT in the BANNER-ISOLATION window — under a broken
#    overlay-leaking enter, cat would resolve /sentinel_host through
#    the leaked ambient bind and print "12.4".
assert_banner_value "BANNER-AMBIENT-SENTINEL" "12.4" \
    "ambient bind /sentinel_host resolves at the prompt"
assert_banner_value "BANNER-ISOLATION" "ISO_DONE" \
    "enter linux body actually ran in the isolation test"
assert_banner_absent "BANNER-ISOLATION" "12.4" \
    "clean ns drops the ambient /sentinel_host bind (no host leak)"

# 4. The `debian` alias resolves the same backing tree.
assert_banner_value "BANNER-DEBIAN-ALIAS" "12.4" \
    "enter debian alias: /etc/debian_version reads distro backing"

# 5. Outside the namespace (hamsh's own view), /etc/debian_version
#    still reads Hamnix's native value. Both the pre- and post-enter
#    reads — the post one is the real boundary test (proves the
#    enter child's rfork didn't bleed into hamsh's namespace).
assert_banner_value "BANNER-NATIVE-PRE" "hamnix/1.0" \
    "pre-enter native /etc/debian_version reads Hamnix"
assert_banner_value "BANNER-NATIVE-POST" "hamnix/1.0" \
    "post-enter native /etc/debian_version still reads Hamnix"

# 6. The namespace verb chained with && (HAMSH_SPEC §11).
if grep -a -F -q "CHAIN_OK" "$LOG"; then
    echo "[test_distro_namespace] OK: enter linux { } && echo chains"
else
    echo "[test_distro_namespace] MISS: enter did not chain with &&"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_distro_namespace] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_distro_namespace] PASS"
