#!/usr/bin/env bash
# scripts/test_linux_namespace.sh - Linux runtime namespace primitives.
#
# Verifies that `enter linux { ... }` works end-to-end against the
# `/var/lib/distros/default` distro tree that build_initramfs.py
# populates (busybox-musl applet symlinks + tests/distros/default/
# fixture):
#
#   1. `enter linux { /bin/ls / }`             — lists distro root,
#                                                showing bin/ etc/.
#   2. `enter linux { /bin/echo hello world }` — runs a Linux ABI
#                                                static-PIE binary
#                                                (busybox echo applet)
#                                                inside the namespace.
#   3. `enter linux { /bin/cat /etc/debian_version }` — reads the
#                                                distro tree's
#                                                /etc/debian_version
#                                                via the `/` rebind
#                                                ("12.4" fixture).
#   4. `enter linux { /bin/ls }`               — lists cwd (`/`) — proves
#                                                cwd is sane inside the
#                                                clean namespace and
#                                                resolves the same as
#                                                `/bin/ls /`.
#
# This is the regression test the linux-namespace task's
# acceptance criteria call for. Per [[feedback-regression-prone-needs-
# test]] — broken Linux ns is exactly the silent-fail surface that
# wants a CI grep test.
#
# DRIVE STRATEGY (task #29 — starvation-hardening): this gate USED to
# drive several `enter linux { … }` commands into the serial console
# with FIXED `sleep N` pauses. On a loaded host the boot / per-command
# line-editor echo overran those fixed delays, the input was shoved
# before the readline consumed it, the trailing markers missed the wall
# clock, and the gate reported a starvation-FALSE-FAIL — a driving
# confounder, not a code signal (the same class the spawn-fd gate hit
# under -smp 2).
#
# It now boots hamsh as /init directly (INIT_ELF=hamsh.elf — no rc.boot,
# so no sshd accept-loop to starve the interactive shell) and drives
# through the load-adaptive scripts/_hamsh_drive.sh handshake: wait for
# the boot-ready marker, prove a live readline with a FEEDER_SYNC probe,
# then send each command ONCE and wait on its OWN observable effect (a
# unique post-command echo barrier) for as long as the guest needs and
# no longer. A run that never reaches its markers is reported
# INCONCLUSIVE (scripts/_verdict.sh), never a starvation-false-FAIL. We
# plant a custom /etc/hamsh.rc (HAMNIX_HAMSH_RC) that defines the same
# `linux = ns clean { … }` template rc.boot uses, with no service spawns,
# so a failure here flags a real ns regression, not rc divergence. Uses
# -smp 1 for a trustworthy verdict (an -smp 2 boot only false-FAILs
# under contention; a PASS stays trustworthy).

. "$(dirname "$0")/_build_lock.sh"
# Real-Debian opt-in: this gate verifies `enter linux` against the real
# /var/lib/distros/default Debian tree, so it needs the debootstrap
# closure that _build_lock.sh defaults OFF for the bare-kernel unit lane.
# _kernel_iso.sh (sourced by _hamsh_drive.sh) raises -m for the large kernel.
export HAMNIX_DEFAULT_REAL_DEBIAN=1

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_linux_namespace
# -smp 1 keeps the verdict trustworthy under host load (see header).
export HAMNIX_TEST_SMP="${HAMNIX_TEST_SMP:-1}"
BOOT_WAIT="${BOOT_WAIT:-600}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# HOST GUARD (host-image analog): the distro `/bin` is populated from the
# gitignored musl-static-PIE busybox fixture tests/u-binary/u_busybox_musl
# (build_initramfs.py stages it under /var/lib/distros/default/bin/). If it
# is absent — a fresh checkout / a battery shard that never ran
# `make -C tests/u-binary/src/musl_busybox install` — the distro ships with
# NO /bin and every `enter linux { /bin/… }` exec is a legitimate
# command-not-found (127). That is a MISSING-DEPENDENCY condition, not a
# code regression, so report it INCONCLUSIVE (a clean SKIP under
# ci_run_gate.sh) instead of a false FAIL.
BB_FIXTURE=tests/u-binary/u_busybox_musl
if [ ! -f "$BB_FIXTURE" ]; then
    verdict_inconclusive "$TAG" \
        "Linux runtime shell fixture '$BB_FIXTURE' absent — the distro tree" \
        "ships without /bin, so 'enter linux { /bin/… }' cannot exec. Build" \
        "it with 'make -C tests/u-binary/src/musl_busybox install' (needs" \
        "musl-gcc + network), then re-run. Not a regression."
fi

echo "[test_linux_namespace] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_linux_namespace] (2/4) Plant /etc/hamsh.rc with the linux recipe"
# /etc/hamsh.rc is run by hamsh-as-PID-1 when invoked with no rc-path
# argv. This stripped-down recipe captures the linux runtime namespace
# without launching any boot services (rc.boot's sshd is what wedges
# the heartbeat — see header). Same `ns clean { ... }` body
# rc.boot uses; the test must match the production shape so failures
# here flag real regressions, not divergence between rcs.
RC_TMP=$(mktemp /tmp/hamsh-rc-linuxns.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns clean {
    bind '#distro' /
    bind '#r/home' /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind '#t/tmp' /tmp
}
debian = ns clean {
    bind '#distro' /
    bind '#r/home' /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind '#t/tmp' /tmp
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_linux_namespace] (3/4) Build initramfs (hamsh as /init)"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-linux-ns.XXXXXX.log)
cleanup() {
    hamsh_shutdown
    rm -f "$LOG" "${LOG_RAW:-}" "$RC_TMP"
    # Restore the default initramfs (default /init shim + no rc override)
    # so subsequent tests boot the production path.
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_linux_namespace] (3/4) Build kernel"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_linux_namespace] (4/4) Boot QEMU + drive test commands"
hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# Adaptive per-command drive. Each enter-linux command is sent ONCE
# (the sync proved a live readline consuming stdin in order), bracketed
# by a START banner the assertions key on and an END echo barrier we
# wait on — so we pace on the guest's real progress, not a fixed sleep.
drive_enter() {                 # $1 = START banner  $2 = enter-cmd  $3 = END banner
    hamsh_send "echo $1"
    hamsh_send "$2"
    hamsh_send_await "echo $3" "$3" "$CMD_WAIT" || true
}

# 1. enter linux { /bin/ls / } — lists distro root (bin/, etc/, ...).
drive_enter BANNER_LS_ROOT_START "enter linux { /bin/ls / }"     BANNER_LS_ROOT_END
# 2. enter linux { /bin/echo hello world } — Linux ABI binary in ns.
drive_enter BANNER_ECHO_START "enter linux { /bin/echo hello world }" BANNER_ECHO_END
# 3. enter linux { /bin/cat /etc/debian_version } — distro-tree read.
drive_enter BANNER_CAT_START "enter linux { /bin/cat /etc/debian_version }" BANNER_CAT_END
# 4. enter linux { /bin/ls } — bare ls (cwd) inside the ns; cwd is "/".
drive_enter BANNER_LS_DOT_START "enter linux { /bin/ls }"        BANNER_LS_DOT_END
# 5. debian alias also resolves.
drive_enter BANNER_ALIAS_START "enter debian { /bin/cat /etc/debian_version }" BANNER_ALIAS_END
# 6. UNDEFINED template must LOUDLY refuse and NOT run the body in the
#    current namespace (the silent-no-op bug). The body prints a
#    sentinel; if it appears, the body ran (regression). The stderr
#    error string "enter: not a namespace:" MUST appear.
drive_enter BANNER_UNDEF_START "enter foobar { echo BODY_RAN_IN_CURRENT_NS }" BANNER_UNDEF_END

hamsh_send 'echo BANNER_DONE'
hamsh_send_await 'echo BANNER_DONE2' 'BANNER_DONE2' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_linux_namespace] --- captured output (tail) ---"
tail -200 "$LOG" | strings
echo "[test_linux_namespace] --- end output ---"

# Normalise the serial capture before any banner assertion. busybox ls
# colourises directory names with ANSI SGR escapes and the hamsh line
# editor echoes typed input char-by-char with cursor-control codes
# (ESC[K, ESC[<n>C) and carriage returns. Left raw, those control bytes
# split the visible tokens (PROVENANCE / bin / etc) across rebuilt lines
# and swallow whole banner-echo lines, so the byte-exact banner-window
# awk would mis-flag working output as a MISS. Strip ESC-sequences and
# CRs into a cleaned copy and run every assertion against it. The raw
# capture stays in $LOG for the human-readable tail above.
LOG_RAW="$LOG"
LOG=$(mktemp /tmp/test-linux-ns-clean.XXXXXX.log)
sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b[()][AB0]//g' -e 's/\r//g' \
    "$LOG_RAW" > "$LOG"

# Zero guest markers at all -> INCONCLUSIVE (a starved boot), not a wall
# of false FAILs. Only proceed to the substantive assertions once the
# guest demonstrably drove.
verdict_boot_gate "$TAG" "$LOG" 0 'TEST_RC_START|BANNER_LS_ROOT_START|BANNER_DONE'

fail=0

check_present() {
    local needle="$1"
    local label="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_linux_namespace] OK: $label"
    else
        echo "[test_linux_namespace] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Precise per-command windowing: VALUE must appear on a REAL OUTPUT line
# between this command's START and END banners. The adaptive driver
# brackets every `enter` with a unique START/END echo pair, so the window
# is the exact byte-range that command produced — robust to the number of
# char-by-char line-editor echo lines (which blew past the old fixed
# 30-line window and mis-flagged working output as a MISS). We SKIP the
# hamsh prompt-echo lines ("hamsh$ …"): the line editor re-renders the
# typed command char by char on those lines, so a token that only appears
# in the COMMAND text (e.g. "bin" inside "/bin/ls", or the "hello world"
# argument) is not execution output — matching it would be a typed-input-
# echo false-green. Real program output lands on its own prompt-less line.
check_win() {                     # $1 START  $2 END  $3 value  $4 label
    if LC_ALL=C awk -v s="$1" -v e="$2" -v v="$3" '
        index($0, "hamsh$") > 0 { next }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, s) > 0 { armed=1; next }
        index($0, e) > 0 { armed=0 }
        armed && index($0, v) > 0 { found=1 }
        END { exit found ? 0 : 1 }
    ' "$LOG"; then
        echo "[test_linux_namespace] OK: $4"
    else
        echo "[test_linux_namespace] MISS: $4 (window $1..$2 value='$3')"
        fail=1
    fi
}

# Companion: VALUE must be ABSENT on real output lines in the START..END
# window (prompt-echo lines skipped, same rationale as check_win).
check_win_absent() {              # $1 START  $2 END  $3 value  $4 label
    if LC_ALL=C awk -v s="$1" -v e="$2" -v v="$3" '
        index($0, "hamsh$") > 0 { next }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, s) > 0 { armed=1; next }
        index($0, e) > 0 { armed=0 }
        armed && index($0, v) > 0 { found=1 }
        END { exit found ? 1 : 0 }
    ' "$LOG"; then
        echo "[test_linux_namespace] OK: $4"
    else
        echo "[test_linux_namespace] FAIL: $4 (window $1..$2 must NOT contain '$3')"
        fail=1
    fi
}

# Sanity: hamsh sourced the rc and defined the linux/debian ns values.
check_present "TEST_RC_DONE_DEFINING_NS" \
              "/etc/hamsh.rc captured linux + debian ns values"

# 1. ls / inside the linux ns lists distro root from the distro tree.
# The "ls: /: No such file or directory" failure is the bug the linux-
# namespace task aimed to fix — assert the negative AND positive. The
# distro tree's top level carries the distro-ONLY PROVENANCE file plus
# bin/ and etc/, so all three enumerate over `#distro`.
check_win_absent "BANNER_LS_ROOT_START" "BANNER_LS_ROOT_END" "ls: /: No such file" \
                 "enter linux { /bin/ls / } does NOT report ENOENT"
check_win "BANNER_LS_ROOT_START" "BANNER_LS_ROOT_END" "PROVENANCE" \
          "enter linux { /bin/ls / } lists the distinct Debian root (PROVENANCE)"
check_win "BANNER_LS_ROOT_START" "BANNER_LS_ROOT_END" "bin" \
          "enter linux { /bin/ls / } shows bin/"
check_win "BANNER_LS_ROOT_START" "BANNER_LS_ROOT_END" "etc" \
          "enter linux { /bin/ls / } shows etc/"

# 2. /bin/echo hello world runs and prints "hello world".
check_win "BANNER_ECHO_START" "BANNER_ECHO_END" "hello world" \
          "enter linux { /bin/echo hello world } prints"

# 3. /bin/cat /etc/debian_version reads "12.4" from the distro tree.
check_win "BANNER_CAT_START" "BANNER_CAT_END" "12.4" \
          "enter linux { /bin/cat /etc/debian_version } reads distro"

# 4. /bin/ls (no arg) lists cwd; cwd is /, same as `ls /`.
check_win "BANNER_LS_DOT_START" "BANNER_LS_DOT_END" "bin" \
          "enter linux { /bin/ls } lists cwd shows bin/"

# 5. debian alias resolves the same backing tree.
check_win "BANNER_ALIAS_START" "BANNER_ALIAS_END" "12.4" \
          "enter debian alias also reads distro"

# 6. Undefined-template enter: LOUD error fires, body does NOT run.
#    This is the silent-no-op root-cause fix (exec_enter refuses a
#    non-VT_NS name instead of running the body in the current ns).
check_win "BANNER_UNDEF_START" "BANNER_UNDEF_END" "not a namespace" \
          "enter foobar { } prints loud 'not a namespace' error"
check_win_absent "BANNER_UNDEF_START" "BANNER_UNDEF_END" "BODY_RAN_IN_CURRENT_NS" \
          "enter foobar { } does NOT run the body in current ns"

# 7. rc.de-user now exposes the linux/debian templates (DE terminal can
#    enter the Linux ns from the desktop). Static grep — no boot needed.
if grep -Eq "^linux = ns clean \{" etc/rc.de-user \
   && grep -Eq "^debian = ns clean \{" etc/rc.de-user \
   && grep -q "bind '#distro' /" etc/rc.de-user; then
    echo "[test_linux_namespace] OK: rc.de-user defines linux+debian (#distro) templates"
else
    echo "[test_linux_namespace] FAIL: rc.de-user missing linux/debian #distro templates"
    fail=1
fi

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a Linux-namespace assertion was VIOLATED (see MISS:/FAIL lines above)."
verdict_pass "$TAG" "enter linux/debian runs real Debian binaries in a clean ns; undefined template refuses loudly."
