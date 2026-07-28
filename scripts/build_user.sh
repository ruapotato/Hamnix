#!/usr/bin/env bash
# scripts/build_user.sh - assemble + link userland binaries.
#
# Builds two kinds of user binary:
#   * a couple of hand-written .S programs (hello, stdin_demo) linked
#     with user/init.lds — elf32-i386 wrappers with 64-bit code inside.
#   * the Adder-compiled userland (init, hamsh, coreutils, daemons).
# The output ELFs are read by scripts/build_initramfs.py and embedded
# into the cpio archive; build/user/init.elf becomes the kernel's
# /init (a thin shim that execs /bin/hamsh with boot rc /etc/rc.boot).
#
# Run this whenever you touch a user/*.S / user/*.ad file or the
# linker script. scripts/build_initramfs.py is what gets called next.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Track-3 self-hosting: the Adder-compiler backend selector. `adder_cc_compile`
# is a drop-in for `python3 -m compiler.adder compile`, routed by $ADDER_CC
# (default `python` = the frozen seed; `adder` = the self-hosted host_ac.elf).
# See scripts/_adder_cc.sh + docs/subsystems/adder-compiler.md.
# shellcheck source=_adder_cc.sh
source "$PROJ_ROOT/scripts/_adder_cc.sh"

mkdir -p build/user

# --- Up-to-date short-circuit (content-addressed, NOT existence-based) -----
#
# 179 gates in scripts/ci_battery_manifest.txt open with `bash
# scripts/build_user.sh`, and this script is NOT incremental: 89 s wall /
# 7m43 s CPU on this 12-core host for a completely unchanged tree (measured
# 2026-07-28), and roughly 200 s on a 4-core GitHub runner. 179 x 200 s is
# ~10 h of rebuilding per battery run, ~37 min of every 50-min shard — one
# of the three costs that made the 2026-07-27 battery time out on all 16
# shards.
#
# The guard below is NOT the banned `if [ -f "$OUT" ]; then exit 0; fi`
# stale-artifact factory that scripts/test_artifact_freshness.sh lints for.
# It is strictly STRONGER than the mtime freshness rule that gate enforces:
# it re-runs unless BOTH
#   (a) every buildable input in the tree hashes to the same value it had
#       when the stamp was written (scripts/_tree_fingerprint.sh: content of
#       every tracked + untracked-not-ignored file, plus ADDER_*/HAMNIX_*),
#   AND
#   (b) every file this script recorded as its own output still hashes to
#       the value it had then (fixtures a gate later drops into build/user/
#       are ignored - they are not this script's output).
# Touch any source, any compiler file, any build flag, or any output ELF and
# the build runs for real. A skip therefore cannot produce a different
# artifact from a full build — which is the property the freshness gate is
# defending, expressed as content equality instead of mtime ordering.
#
# HAMNIX_BUILD_USER_FORCE=1 (or removing build/user/.stamp) forces a rebuild.
# shellcheck source=_tree_fingerprint.sh
source "$PROJ_ROOT/scripts/_tree_fingerprint.sh"
_bu_stamp="build/user/.stamp"
_bu_key="$(hamnix_tree_fingerprint)|$(hamnix_build_env_fingerprint)"
# The stamp records the key on line 1 and a `sha256  path` manifest of the
# files THIS script produced. Verification requires every recorded path to
# still hash to its recorded value; files a gate later ADDS to build/user
# (test fixtures) are ignored, because they are not this script's output.
if [ "${HAMNIX_BUILD_USER_FORCE:-0}" != "1" ] && [ -f "$_bu_stamp" ] \
   && [ "$(head -n1 "$_bu_stamp")" = "$_bu_key" ] \
   && tail -n +2 "$_bu_stamp" | sha256sum --quiet --check - >/dev/null 2>&1; then
    echo "[build_user] up to date (tree + recorded outputs unchanged) - nothing to do"
    exit 0
fi
rm -f "$_bu_stamp"
_bu_write_stamp() {
    { printf '%s\n' "$_bu_key"
      find build/user -type f ! -name '.stamp' | LC_ALL=C sort \
        | tr '\n' '\0' | xargs -0 -r sha256sum
    } > "$_bu_stamp"
}

# --- Parallel-compile infrastructure --------------------------------------
# The 250+ Adder userland programs are INDEPENDENT whole-program compiles,
# each writing its own build/user/<name>.elf. They were historically built
# strictly sequentially; here we fan them out across cores.
#
# CORRECTNESS INVARIANTS (do not break):
#   * The native-compiler bootstrap (host_ac.elf) is built ONCE, up front,
#     BEFORE any parallel job starts — otherwise N jobs would race to
#     produce build/cutover/host_ac.elf. We call adder_cc_bootstrap here
#     explicitly; every fanned-out job then inherits _ADDER_CC_BOOTSTRAPPED=1
#     and skips it. Under ADDER_CC=python the bootstrap no-ops (returns 0).
#   * No shared per-invocation scratch: for ADDER_CC=adder each compile is
#     `host_ac.elf <in> <out>` writing straight to the unique <out> ELF (no
#     fixed temp file); for ADDER_CC=python the seed uses tempfile.* which
#     mints unique paths. So concurrent compiles cannot collide.
#   * Fail-fast on OUTPUT: every job records a failure marker; after the pool
#     drains we exit non-zero if ANY compile failed (a backgrounded failure
#     is never silently swallowed).
#
# Concurrency level: HAMNIX_BUILD_JOBS (default: nproc).
_BUILD_JOBS="${HAMNIX_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
[ "$_BUILD_JOBS" -ge 1 ] 2>/dev/null || _BUILD_JOBS=1

# Build host_ac.elf ONCE before fanning out (no-op under ADDER_CC=python).
adder_cc_bootstrap || { echo "[build_user] ERROR: compiler bootstrap failed" >&2; exit 1; }

# Failure markers land here; presence of any file == a compile failed
# (i.e. BOTH the LLVM lane AND the native fallback failed for that app).
_FAILDIR="$(mktemp -d)"
# Per-app lane outcome markers: "<name>.llvm" (built as native ELF64 via the
# LLVM->clang lane) or "<name>.native" (fell back to the native SSA ELF32
# lane). Native fallbacks also drop a one-line "<name>.reason" (bail class).
_LANEDIR="$(mktemp -d)"
trap 'rm -rf "$_FAILDIR" "$_LANEDIR"' EXIT

# --- DEFAULT BACKEND SELECTION ---------------------------------------------
# USER directive: EVERY user app should compile through the LLVM->clang->native
# ELF64 lane (scripts/adder_cc_llvm_native64.sh) by DEFAULT, with an automatic
# per-app fallback to the native SSA ELF32 lane whenever the LLVM build bails
# (an SSA-subset function is not emitted -> link undef, or clang/emit fails).
# So the build ALWAYS completes and produces a bootable image; the native lane
# stays the bootstrap floor + safety net.
#
# Knobs:
#   ADDER_LLVM_DEFAULT=0        force the native lane for ALL apps (debug/A-B).
#   ADDER_FORCE_NATIVE_APPS="a b"  force the native lane for just these apps.
_LLVM_DEFAULT="${ADDER_LLVM_DEFAULT:-1}"
_FORCE_NATIVE=" ${ADDER_FORCE_NATIVE_APPS:-} "

# _classify_bail <llvm-logfile> — reduce an LLVM-lane failure to a short bail
# class for the coverage report (why this app fell back to native).
_classify_bail() {
    local log="$1" stat reason sym
    stat="$(grep -m1 'ADDER_STAT' "$log" 2>/dev/null | sed 's/^; *//')"
    if grep -q 'no @main emitted' "$log" 2>/dev/null; then
        reason="no-main(main-body-bailed)"
    elif grep -q 'undefined reference to' "$log" 2>/dev/null; then
        sym="$(grep -m1 'undefined reference to' "$log" | sed -E "s/.*undefined reference to \`([^']+)'.*/\1/")"
        reason="link-undef:$sym(callee bailed SSA subset)"
    elif grep -q 'backend=llvm failed' "$log" 2>/dev/null; then
        reason="hostac-emit-err"
    elif grep -q 'clang -c failed' "$log" 2>/dev/null; then
        reason="clang-err"
    elif grep -q 'ERROR assembling' "$log" 2>/dev/null; then
        reason="as-err"
    elif grep -q 'ERROR linking' "$log" 2>/dev/null; then
        reason="link-err"
    else
        reason="other"
    fi
    echo "$reason | ${stat:-no-stat}"
}

# _compile_one_app <src.ad> <out.elf> <basename> — LLVM-first with native
# fallback. Records the winning lane (+ bail reason on fallback), and a hard
# FAILDIR marker only if BOTH lanes fail.
_compile_one_app() {
    local src="$1" out="$2" base="$3" nm=" $3 " llog
    if [ "$_LLVM_DEFAULT" = "1" ] && [[ "$_FORCE_NATIVE" != *"$nm"* ]]; then
        llog="$(mktemp)"
        if ADDER_HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}" \
                bash scripts/adder_cc_llvm_native64.sh "$src" "$out" >"$llog" 2>&1; then
            : > "$_LANEDIR/$base.llvm"
            rm -f "$llog"
            echo "[build_user] LLVM   wrote $out"
            return 0
        fi
        # LLVM bailed -> classify, then fall back to the native lane.
        _classify_bail "$llog" > "$_LANEDIR/$base.reason"
        rm -f "$llog"
    fi
    if adder_cc_compile compile --target=x86_64-adder-user "$src" -o "$out"; then
        : > "$_LANEDIR/$base.native"
        echo "[build_user] native wrote $out"
    else
        echo "[build_user] ERROR: compile FAILED (both lanes): $src -> $out" >&2
        : > "$_FAILDIR/$base"
    fi
}

# Queue of (src -> out) compile jobs, run by _run_compile_pool.
_Q_SRC=()
_Q_OUT=()

# queue_adder_compile <src.ad> <out.elf> — enqueue one whole-program compile.
queue_adder_compile() {
    _Q_SRC+=("$1")
    _Q_OUT+=("$2")
}

# _run_compile_pool — fan the queued compiles out across $_BUILD_JOBS workers
# with a sliding concurrency gate (wait -n throttles to the pool size). Each
# job compiles to its unique output ELF and, on failure, drops a marker in
# $_FAILDIR keyed by the output basename.
_run_compile_pool() {
    local n=${#_Q_SRC[@]} i
    echo "[build_user] compiling $n Adder programs across $_BUILD_JOBS jobs (ADDER_CC=${ADDER_CC:-adder})"
    for (( i=0; i<n; i++ )); do
        # Throttle: keep at most $_BUILD_JOBS background jobs in flight.
        while [ "$(jobs -rp | wc -l)" -ge "$_BUILD_JOBS" ]; do
            wait -n 2>/dev/null || true
        done
        local src="${_Q_SRC[$i]}" out="${_Q_OUT[$i]}" base
        base="$(basename "$out" .elf)"
        ( _compile_one_app "$src" "$out" "$base" ) &
    done
    wait
    # Fail-fast: propagate any compile that failed BOTH lanes to the whole build.
    if [ -n "$(ls -A "$_FAILDIR" 2>/dev/null)" ]; then
        echo "[build_user] ERROR: $(ls -1 "$_FAILDIR" | wc -l) user compile(s) FAILED (both LLVM + native lanes):" >&2
        ls -1 "$_FAILDIR" >&2
        exit 1
    fi
    echo "[build_user] all $n Adder programs compiled OK"

    # --- LLVM-default coverage report --------------------------------------
    local _llvm _nat _total
    _llvm=$(ls -1 "$_LANEDIR"/*.llvm   2>/dev/null | wc -l)
    _nat=$(ls -1 "$_LANEDIR"/*.native 2>/dev/null | wc -l)
    _total=$(( _llvm + _nat ))
    echo "[build_user] ================ LLVM-default coverage ================"
    if [ "$_LLVM_DEFAULT" = "1" ]; then
        echo "[build_user] LLVM ELF64 (default): $_llvm / $_total apps built via LLVM->clang"
        echo "[build_user] native fallback:      $_nat / $_total apps"
        if [ "$_nat" -gt 0 ]; then
            echo "[build_user] --- native fallbacks (app: bail-class | ADDER_STAT) ---"
            for r in "$_LANEDIR"/*.reason; do
                [ -f "$r" ] || continue
                printf '[build_user]   %s: %s\n' "$(basename "$r" .reason)" "$(cat "$r")"
            done | sort
        fi
    else
        echo "[build_user] ADDER_LLVM_DEFAULT=0 -> all $_total apps built via native lane"
    fi
    echo "[build_user] ======================================================="
}

build_one() {
    local name="$1"
    as --32 -o "build/user/${name}.o" "user/${name}.S"
    ld -m elf_i386 -nostdlib -static \
       -T user/init.lds \
       -o "build/user/${name}.elf" \
       "build/user/${name}.o"
    echo "[build_user] wrote $(pwd)/build/user/${name}.elf"
    file "build/user/${name}.elf"
}

build_one hello
build_one stdin_demo                   # used by scripts/test_stdin.sh

# Hamnix-compiled userland binaries.
build_adder_user() {
    local name="$1"
    # Source lives in user/<name>.ad normally; a regression-test fixture
    # (e.g. test_hugepage) lives in tests/<name>.ad. Prefer user/, fall
    # back to tests/ so a test program can be registered here too.
    local src="user/${name}.ad"
    if [ ! -f "$src" ] && [ -f "tests/${name}.ad" ]; then
        src="tests/${name}.ad"
    fi
    queue_adder_compile "$src" "build/user/${name}.elf"
}

build_adder_user init                 # PID 1 shim: execs /bin/hamsh with boot rc /etc/rc.boot
build_adder_user hamsh                # M16.35: interactive shell
build_adder_user ps                   # M16.36: dumps /proc snapshots
build_adder_user echo                 # M16.37: writes argv to stdout
build_adder_user cat                  # M16.37: streams files to stdout
build_adder_user aplay                # native HDA: streams a PCM/WAV file to /dev/audio
build_adder_user playtone             # native HDA: self-contained tone generator -> /dev/audio (no input file)
build_adder_user dup_demo             # M16.41: exercises sys_dup / sys_dup2
build_adder_user ls                   # M16.46: directory listing
build_adder_user lsblk                # enumerate /dev/blk devices + sizes (pre-install disk check)
build_adder_user pwd                  # M16.47: print working dir
build_adder_user head                 # M16.57: first N lines
build_adder_user wc                   # M16.57: line/word/byte count
build_adder_user grep                 # egrep: ERE (-E) via shared lib/regex.ad; flags -i/-v/-c/-n/-o/-w/-x/-F/-e
build_adder_user seq                  # M16.64: 1..N or M..N output
build_adder_user bc                   # native infix arithmetic calculator (integer POSIX subset)
build_adder_user js                   # native ES5/basic-ES6 JavaScript engine (lib/jsengine.ad); FILE.js or built-in demo
build_adder_user sha256sum            # SHA-256 digest of files/stdin (+ -c check mode); integrity verification
build_adder_user fmt                   # reflow text to a goal width (-w N); paragraph-aware greedy fill
build_adder_user uname                # M16.64: system identification
build_adder_user true                 # M16.64: exit 0
build_adder_user false                # M16.64: exit 1
build_adder_user nsbindprobe          # HAMSH §18 stage-5: external-bind COW probe
build_adder_user yes                  # M16.64: repeat-until-SIGINT
build_adder_user sleep                # M16.64: jiffies-based delay
build_adder_user sort                 # M16.64: insertion sort of stdin
build_adder_user tee                  # M16.64: fan stdin to stdout + file
build_adder_user rev                  # M16.64: per-line reverse
build_adder_user uniq                 # collapse adjacent dup lines (-c/-d/-u)
build_adder_user nl                   # number stdin lines (-ba/-bt)
build_adder_user tac                  # cat in reverse line order
build_adder_user fold                 # wrap lines to width (-w N)
build_adder_user cksum                # POSIX CRC32 + byte count of stdin
build_adder_user rm                   # M16.65: tmpfs unlink
build_adder_user touch                # M16.65: create-empty / truncate
build_adder_user mkdir                # M16.65: no-op stub (flat tmpfs)
build_adder_user basename             # M16.66: strip path prefix
build_adder_user dirname              # M16.66: keep path prefix
build_adder_user cut                  # M16.66: -c column / range slice
build_adder_user paste                # merge lines of files (-d DELIM, -s serial)
build_adder_user comm                 # compare two SORTED files (3-col, -1/-2/-3)
build_adder_user split                # split a file into pieces (-l lines / -b bytes)
build_adder_user realpath             # canonicalise a path to absolute form
build_adder_user truncate             # set a file's size (-s SIZE, K/M suffix)
build_adder_user stat                 # file/inode status: name/size/type (-c %n/%s/%F)
build_adder_user nproc                # online CPU count from /proc/cpuinfo cpus_online
build_adder_user printenv             # print env (argv NAME=VALUE convention) or a named value
build_adder_user tty                  # print stdin terminal name (/dev/cons) via /fd/0 kind
build_adder_user mktemp               # create unique temp file/dir (-d) from a TEMPLATE
build_adder_user join                 # relational join of two SORTED files (-1/-2/-j field, -t sep, -a outer, -o/-e format, -i)
build_adder_user expand               # convert tabs to spaces honoring column (-t N)
build_adder_user unexpand             # leading-blank runs to tabs (-a all, -t N)
build_adder_user shuf                 # random permutation of lines (-n N, -i LO-HI, -e ARGS)
build_adder_user factor               # prime factorization of integers (argv or stdin)
build_adder_user csplit               # split FILE into sections on PATTERNs (xx00, xx01, ...)
build_adder_user numfmt               # convert numbers to/from human-readable forms
build_adder_user pr                   # paginate text for printing (header + columns)
build_adder_user tsort                # topological sort of whitespace-separated token pairs
build_adder_user dircolors            # emit shell command setting LS_COLORS
build_adder_user tr                   # M16.66: SRC->DST byte translate
build_adder_user od                   # M16.66: -An -tx1 hex dump
build_adder_user printf               # M16.66: %s/%d + \n/\t/\\ escapes
build_adder_user cp                   # M16.66: SRC->DST file copy (<=8 KiB)
build_adder_user whoami               # current uid -> name via /etc/passwd
build_adder_user id                   # real uid/gid -> names via /etc/passwd + /etc/group
build_adder_user clear                # M16.67: ANSI clear-screen + home
build_adder_user hostname             # M16.67: /etc/hostname with fallback
build_adder_user date                 # /proc/realtime — RTC + TSC delta
build_adder_user more                 # M16.67: 24-line pager over stdin
build_adder_user find                 # M16.67: recursive listdir walk
build_adder_user diff                 # LCS line diff: normal + unified (-u) output
build_adder_user patch                # apply unified/normal diffs (-pN/-R/--dry-run/-i/-o/-b); GNU-interoperable
build_adder_user motd  # M16.68: print /etc/motd
build_adder_user df                   # M16.70: dump /proc/mounts
build_adder_user du                   # M16.70: entry-count under path
build_adder_user tail                 # M16.70: last N lines of stdin
build_adder_user cmp                  # M16.70: byte-compare two files
build_adder_user which                # M16.74: PATH lookup tool
build_adder_user free                 # M16.74: /proc/meminfo as free table
build_adder_user uptime               # M16.74: /proc/uptime in seconds
build_adder_user mv                   # M16.74: copy + unlink (no rename(2))
build_adder_user ln                   # M16.74: placeholder for symlink/hardlink
build_adder_user cal                  # M16.74: hard-coded May 2026 month grid
build_adder_user expr                 # M16.74: A OP B for + - * /
build_adder_user test                 # M16.74: -z/-n/=/!= predicates
build_adder_user banner               # M16.81: ASCII-art big text
build_adder_user strings              # M16.81: print printable runs from a binary
build_adder_user service              # native service mgmt: service <name> start|stop|restart|status|enable|disable
build_adder_user initctl              # native runlevel control: initctl <N> (telinit alias) via /proc/svc/ctl (F2 #447)
build_adder_user halt                 # M16.82: graceful exit / future ACPI halt
build_adder_user poweroff             # M16.82: same as halt for now
build_adder_user reboot               # M16.82: future i8042 0xFE pulse
build_adder_user insmod               # L1: load stock Linux 6.12 .ko
build_adder_user modprobe             # L1: resolve modules.dep + load deps
build_adder_user rmmod                # L1: unload by slot id
build_adder_user pgrep                # /proc/tasks comm-substring -> PIDs
build_adder_user kill                 # sys_kill(pid, sig); -SIG flag
build_adder_user sed                  # stream editor: s/RE/repl/[gp] (scoped regex: . * [..] ^ $), p/d, N/$/N,M addrs, -n/-e
build_adder_user vi                   # modal full-screen editor (NORMAL/INSERT/ex)
build_adder_user hamfm                # TUI file manager (navigate dirs, view files)
build_adder_user column               # format text into columns (fill / -t table / -s sep / -c width)
build_adder_user hxd                  # TUI hex+ASCII file viewer (xxd/hexdump -C, scrollable)
build_adder_user tree                 # recursive directory lister with box-drawing connectors
build_adder_user sum                   # BSD (default) / SysV (-s) 16-bit checksum + block count
build_adder_user sha1sum               # SHA-1 (FIPS 180-4) digest of files/stdin (+ -c check mode)
build_adder_user arch                  # print machine hardware name (x86_64) — uname -m
build_adder_user unlink                # remove exactly ONE file via the unlink primitive
build_adder_user link                  # create a hard link FILE2 -> FILE1 via the link primitive
build_adder_user pathchk                # validate a pathname (-p POSIX portability, -P extra checks)
build_adder_user hdu                  # ncdu-style interactive disk-usage browser (recursive sizes, bar, navigate)
build_adder_user hlog                 # TUI kernel-log viewer/follower (dmesg -w / journalctl -f) over /proc/kmsg
build_adder_user oopsread             # F-oops: render persisted kernel panic record from /proc/oops
build_adder_user awk                  # tree-walk interpreter: fields/NF/NR, FS/OFS, /re/+relational+&&||! patterns, BEGIN/END, print/printf, if/while/for, assoc arrays, length/substr/index/split/toupper/tolower; flags -F/-v/-f (lib/regex.ad)
build_adder_user less                 # alias for more (24-line pager)
build_adder_user xargs                # stdin items -> batched fork/exec (-0/-n/-I/-r)
build_adder_user ascii                # printable ASCII 32..126 table
build_adder_user base64               # M16.86: RFC 4648 encode/decode
build_adder_user tar                  # native ustar (POSIX tar): -c/-x/-t -f ARCHIVE; -z read (inflate) + write (-czf, lib/zlib/deflate)
build_adder_user gzip                 # native gzip: fixed-Huffman + LZ77 DEFLATE (lib/zlib/deflate) + .gz framing; -d via inflate
build_adder_user gunzip               # native gunzip: full INFLATE (stored/fixed/dynamic) via lib/zlib/inflate
build_adder_user md5sum               # M16.86: fixed-hash stub (real MD5 deferred)
build_adder_user env_show             # M16.86: hint about hamsh's `env` builtin
build_adder_user watch                # M16.86: -n N CMD, runs CMD twice w/ delay
build_adder_user crond                # cron daemon: /var/cron/crontab, minute-edge scheduler
build_adder_user crontab              # cron CLI: install FILE / -l list / -r remove
build_adder_user whatis               # M16.86: one-line description table
build_adder_user man                  # discovery: read /usr/share/man/<topic>.<N>.md
build_adder_user help                 # discovery: man-page index + `help <topic>` sugar
build_adder_user hamUI                # hamUI Phase 2: multi-window CLI (new/list/close)
build_adder_user hamUId               # hamUI Phase 4b: userland renderer (render <wid> -> AI-readable dump)
build_adder_user hamui_demo           # GTK/Qt-style toolkit (lib/hamui.ad) demo: label/button/entry/check/list
build_adder_user ham2048              # 2048 game on the hamui toolkit (lib/hamui.ad)
build_adder_user hamsnake             # Snake game on the hamui toolkit (lib/hamui.ad)
build_adder_user hamterm              # hamui GUI terminal: runs commands via real hamsh + piped stdout
build_adder_user hamedit              # hamui GUI text editor: open/save real files
build_adder_user hamfiles             # hamui GUI file browser: sys_listdir + launch hamedit
build_adder_user hamde                # hamui-based DE panel (Applications menu + clock + taskbar)
build_adder_user hampanel             # DE panel extracted from daemon_pixel: standalone hamui-client app on the #442 (c) v2 blit protocol (taskbar + clock + Applications launcher)
build_adder_user hambottom            # DE bottom panel (MATE-style window list strip + Show Desktop + workspace switcher; v2 client; reads /dev/wsys/session)
build_adder_user hamappmenu           # DE pivot wave 2: cascading Applications menu (v2 client; reads /dev/wsys/appmenu, writes /dev/wsys/appmenu/launch)
build_adder_user hamcycler            # DE pivot wave 3: Alt-Tab window switcher overlay (v2 client; reads /dev/wsys/cycler, poked via /dev/wsys/cycler/show)
build_adder_user hamcalpop            # DE pivot wave 4: clock-panel calendar drop-down popup (v2 client; reads /dev/wsys/calpop, poked via /dev/wsys/calpop/show; distinct from /bin/hamclock)
build_adder_user hamrun               # DE pivot wave 4: Run-Application (Alt-F2) modal dialog (v2 client; reads /dev/wsys/run, poked via /dev/wsys/run/show, launches via /dev/wsys/run/launch)
build_adder_user hamcalc              # integer calculator on the hamui toolkit (lib/hamui.ad)
build_adder_user hamctl               # scene-DE Control Center hub (dual-target lib/hamctlcore): Appearance (wallpaper ctl verb) + Date & Time (clock + UTC offset -> /tmp/hamnix-tz.conf) + About (hostname/kernel/uptime/mem/CPUs/procs)
build_adder_user hamview              # image viewer (Eye-of-MATE equiv) on the hamui toolkit: decodes PPM(P6)/BMP, blits via an fb draw-layer
build_adder_user hamabout             # About-this-system dialog (scene client): OS name + kernel + memory + uptime
build_adder_user hamshot              # screenshot CLI (MATE-screenshot equiv): /dev/fb geometry + /dev/fbpix pixel stream -> timestamped PNG (lib/pngwrite.ad; view with hamview) + desktop notification; [--crop X Y W H] captures a sub-rectangle
build_adder_user hamshotui            # screenshot chooser (scene client): Whole Desktop / Select Area (rubber-band) / Application Window -> spawns hamshot [--crop] (app-drawer Screenshot entry)
build_adder_user hammon               # live system monitor (uptime/mem/process list) on the hamui toolkit (lib/hamui.ad) — reads /proc/uptime,/proc/meminfo,/proc/tasks
build_adder_user hamecho              # Increment-1 DE rewrite: first SEPARATE-PROCESS app; echoes routed keys (proves focus-gated input ownership)
build_adder_user hamlock              # DE pivot wave 5: full-screen screen-lock overlay (v2 client; reads /dev/wsys/lock, poked via /dev/wsys/lock/show, verify posted to /dev/wsys/lock/verify)
build_adder_user hamrband             # DE pivot wave 7: rubber-band drag-to-create overlay (v2 client; reads /dev/wsys/rband, poked via /dev/wsys/rband/set)
build_adder_user hamnotif             # DE pivot wave 7: transient notification toast banner (v2 client; reads /dev/wsys/notif, poked via /dev/wsys/notif/show)
build_adder_user hamnotify            # libnotify-shape CLI sender: writes "<title>\t<body>\t<icon>\n" to /dev/wsys/post (inbox ring drained by the panel broker)
build_adder_user hamtoast             # scene-native transient notification toast (top-right, auto-dismiss); title/body via argv, spawned by the panel notification broker
build_adder_user haminbox             # scene-native notification inbox/history (reads /tmp/hamnix-notif.log written by the panel broker); spawned from the tray bell
build_adder_user hamsessui            # DE pivot wave 8: modal End Session dialog (Lock/Log Out/Shut Down/Cancel) (v2 client; reads /dev/wsys/sessui, poked via /dev/wsys/sessui/show)
build_adder_user hamdesktop           # scene-file DE desktop backdrop + clickable launcher icons (scene client; renders icons from the REAL ~/Desktop dir — .desktop launchers + files/folders — with a periodic re-scan; double-click spawns via lib/p9 spawn)
build_adder_user hamsysmon            # DE pivot wave 2 (round 2): desktop system-monitor applet (CPU/MEM bars) (v2 client; reads /dev/wsys/sysmon, poked via /dev/wsys/sysmon/show)
build_adder_user hamctxmenu           # DE pivot wave 3 (round 2): right-click context menu (v2 client; reads /dev/wsys/ctxmenu, poked via /dev/wsys/ctxmenu/show)
build_adder_user hamsnap              # DE pivot wave 4 (round 2): snap-zone preview during window move-drag (v2 client; reads /dev/wsys/snap, poked via /dev/wsys/snap/show)
build_adder_user hamresize            # DE pivot wave 5 (round 2): live resize + kmode frame outline (v2 client; reads /dev/wsys/resize, poked via /dev/wsys/resize/show)
build_adder_user hamosd               # DE pivot wave 6 (round 2): workspace/volume/brightness OSD popup (v2 client; reads /dev/wsys/osd, poked via /dev/wsys/osd/show)
build_adder_user hamtray              # DE pivot wave 7 (round 2): message-tray history panel (v2 client; reads /dev/wsys/tray, poked via /dev/wsys/tray/show)
build_adder_user hamscreensaver       # DE screensaver daemon: idle timer then spawns /bin/hamlock; cycle repeats
build_adder_user hamsession           # DE session save/restore: reads /dev/wsys/session snapshot, persists/replays the open window set
build_adder_user top                  # Linux-style live process TUI (sorted %CPU/%MEM/TIME, in-place refresh; -b one-shot) — reads /proc/toptable via lib/toprender.ad
build_adder_user keydemo              # terminal GAME demo: opts into hamtermscene GAME input (ESC[?9003h) to observe key DOWN *and* UP (lib/gamekey.ad); q quits
build_adder_user ifconfig             # M16.87: stub lo 127.0.0.1/8
build_adder_user ping                 # native Adder ping: Plan-9-shaped /net/icmp client
build_adder_user host                 # native Adder DNS resolver: forward (A) + reverse (PTR) via SYS_RESOLVE/SYS_RESOLVE_PTR
build_adder_user curl                 # native Adder HTTP/HTTPS fetch (body to stdout/-o FILE) over user/http9.ad
build_adder_user wget                 # native Adder HTTP/HTTPS fetch saved to a file over user/http9.ad
build_adder_user ntpd                 # native Adder NTP client: anchors rtc_boot_epoch via /net/udp
build_adder_user route                # M16.87: stub loopback routing row
build_adder_user lsmod                # M16.87: stub module table
build_adder_user dmesg                # M16.87: placeholder until kernel ring buf
build_adder_user su                   # switch user: /dev/auth verify + SYS_SETUID_AUTH
build_adder_user passwd               # set password via hostowner-gated /dev/auth setpass
build_adder_user useradd              # per-user home FILE SERVER on the shared ext4 root (docs/security.md)
build_adder_user login                # real login: /dev/auth verify + identity change + exec shell
build_adder_user getty                # M16.87: VT-aware getty: opens /dev/vt/N then exec /bin/hamsh
build_adder_user chvt                 # VT: switch active virtual terminal (writes to /dev/vt/ctl)
build_adder_user loadkeys             # task #178: select keyboard layout (writes a name to /dev/keymap)
build_adder_user hfw                  # native firewall control: list/add/flush rules + policy via /dev/firewall
# distrorun RETIRED: the distro-shape namespace is no longer a bespoke
# launcher binary. /etc/rc.boot defines it as a captured `ns clean {}`
# value (`linux`, with a `debian` alias for the same body); a Linux
# binary is run with plain namespace verbs — `enter linux { ... }`.
# See HAMSH_SPEC §0/§11 and etc/rc.boot.
build_adder_user hamwd                # Phase D: Hamnix Window Daemon (Layer 3 / 9P file server skeleton)
build_adder_user p9srv_demo           # Phase D / V4: minimum-viable userspace 9P server (test fixture)
build_adder_user spawnfdprobe         # task #28 fixture: proves spawn's clean-fd contract (no launcher-fd leak)
build_adder_user distrofs             # Plan 9 distro: userland 9P file-server daemon for the distro /var tree
build_adder_user nsrun                 # Plan 9 shim launcher: runs a program in a private distrofs-backed namespace
# apt/dpkg/dpkg_deb RETIRED — replaced by real Debian binaries run via
# `enter linux { /usr/bin/apt-get ... }` against the debootstrap'd tree
# staged at /var/lib/distros/default/ (HAMNIX_DEFAULT_REAL_DEBIAN=1).
# Per the user's direction: "apt should be a Linux binary running in a
# Linux namespace." See scripts/test_linux_apt_install.sh.
build_adder_user u_server             # U-socket V1: native TCP server (bind/listen/accept smoke test)
build_adder_user u_tlstest            # U-TLS: native HTTPS client (TLS over the /net file tree)
build_adder_user httpd                # native concurrent web server (master: accept loop + per-conn worker spawn)
build_adder_user httpd_worker         # web server per-connection worker: vhost routing + static files + CGI
build_adder_user cgi_echo             # sample CGI script: echoes CGI env + request body (test fixture)
build_adder_user sshd                 # SSH-2.0 server daemon: curve25519-sha256 KEX + chacha20-poly1305 + hamsh shell
build_adder_user ssh                  # SSH-2.0 OUTBOUND client: ssh [user@]host [cmd] over /net (mirrors sshd's transport)
build_adder_user preempt_hog          # preemption test: syscall-free infinite CPU hog
build_adder_user preempt_demo         # preemption test: spawns the hog, proves the timer preempts it
build_adder_user nice_hi              # #151 CFS-lite: high-priority (nice -20) CPU hog
build_adder_user nice_lo              # #151 CFS-lite: low-priority  (nice +19) CPU hog
build_adder_user nice_demo            # #151 CFS-lite: spawns nice_hi + nice_lo, proves CPU-share ratio
build_adder_user test_hugepage        # §hugepage: 2 MiB MAP_HUGETLB mmap test (tests/test_hugepage.ad)
build_adder_user test_errstr_perbackend  # TODO net-item: per-backend errstr prefixes + perror (tests/test_errstr_perbackend.ad)
build_adder_user hpm                  # Hamnix package manager (docs/packages.md)
build_adder_user mkfs_ext4            # installer: format a /dev/blk/<dev> as ext4 (via /ctl)
build_adder_user mkfs_fat             # installer: format a /dev/blk/<dev> as FAT (via /ctl; stub)
build_adder_user hamnix_partition     # installer: GPT init + ESP + rootfs mkpart on /dev/blk/<dev>
build_adder_user dd_blk               # installer: sector-aligned /dev/blk/SRC -> /dev/blk/DST copy
build_adder_user install_file_to_slot # installer: copy one local file → target ext4 partition (via /ctl install_file verb)
build_adder_user mkdir_at_slot        # installer: mkdir -p a dir on target ext4 partition (via /ctl mkdir verb; trailing-slash tolerant)
build_adder_user install_rootfs_from_manifest  # installer: walk manifest, install_file_to_slot each (target_path source_path) pair
build_adder_user haminstall           # installer: one-shot on-target install (GPT+mkfs+ESP+rootfs) with live-root safety guard
build_adder_user install              # installer: interactive `install` (disk picker + confirm) + --auto; Debian-style hpm package root install
build_adder_user losetup              # attach/detach a file as a loop block device via /dev/loop/ctl
build_adder_user sqfs_to_blk          # installer: stream a file from an in-RAM squashfs -> block dev (no media read)
build_adder_user live_distro_up       # live medium: extract live-distro.ext4 from the in-RAM squashfs -> RAM blockdev, post #distro (#410)
build_adder_user scenetest            # scene-file DE gate driver: newwindow + scene/ctl + cursor (docs/de_scene_file_arch.md)
build_adder_user multiwintest         # multi-window proof: ONE pid opens TWO windows (main + child popup), each renders + routes input independently
build_adder_user hampanelscene        # scene-file DE top panel (Applications + clock) drawn as a scene display list
build_adder_user hamtermscene         # scene-file DE terminal: glyphs content + window-local input routing proof
build_adder_user hamfmscene           # scene-file DE file manager: directory listing as glyphs, click->descend (via lib/hamui hamscene_*)
build_adder_user hamcalcscene         # scene-file DE calculator: button grid + display, click->compute (via lib/hamui hamscene_*)
build_adder_user hameditscene         # scene-file DE text editor: scrollable text area + cursor, /keys input, Ctrl-S saves
build_adder_user ham2048scene         # scene-file DE 2048 game: coloured 4x4 tile board, WASD/arrow keys + on-screen controls (scene port of ham2048; lib/hamui hamscene_*)
build_adder_user hamsnakescene        # scene-file DE Snake game: 16x16 board, WASD/arrow keys + on-screen controls, food/grow/collision/score (lib/hamsnakecore, dual-target; host gate: scripts/test_hamsnake_host.sh)
build_adder_user hamchessscene        # scene-file DE Chess game: 8x8 board, full legal move gen + check/checkmate/stalemate, click-to-move hot-seat two-player (lib/hamchesscore, dual-target; host gate: scripts/test_hamchess_host.sh)
build_adder_user hamtetrisscene       # scene-file DE Tetris game: 10x20 well, 7 tetrominoes, rotate+wall-kick/gravity/lock, line-clear+scoring+level, arrow keys + on-screen controls (lib/hamtetriscore, dual-target; host gate: scripts/test_hamtetris_host.sh)
build_adder_user hamminescene         # scene-file DE Minesweeper game: 9x9 field/10 mines (LCG placement), neighbour counts, flood-fill reveal, flag toggle, first-click-safe, win/loss; mouse (left reveal / right flag) + arrow-key cursor (lib/hamminescore, dual-target; host gate: scripts/test_hammine_host.sh)
build_adder_user hamimgscene          # scene-file DE image demo (#128): synthesizes an RGBA image, uploads via draw/ctl 'I' verb, draws it with the scene `image` verb (compositor blits+scales)
build_adder_user sdlpong              # hamSDL demo game: one-paddle bounce built entirely on the lib/hamsdl.ad game API (drawing + events + timing); dual-target (host gate: scripts/test_hamsdl_host.sh)
build_adder_user hamgamedemo          # hamGame demo "Coin Dash": pygame-shaped Surface/Sprite/Rect/Clock over hamSDL (lib/hamgame.ad + lib/hamgame_dev.ad; shared game lib/hamgamedemo.ad); arrow-key sprite + AABB coin pickup; dual-target (host gate: scripts/test_hamgame_host.sh)
build_adder_user hamgamesnake         # hamGame arcade "Snake": pygame-shaped Surface backbuffer + font HUD over hamSDL (lib/hamgame.ad + lib/hamgame_dev.ad; shared game lib/hamgamesnake.ad); grid snake, arrow/WASD turn, deterministic-PRNG food, grow/score/wall+self collision, game-over replay prompt; dual-target (host gate: scripts/test_hamgamesnake_host.sh)
# NOTE: the hamGame "Chess" build (hamgamechess) was retired — it was the inferior,
# pseudo-legal, mouse-only twin. The shipping Chess is hamchessscene (lib/hamchesscore.ad):
# full legal moves + check/checkmate/stalemate + promotion (see build line above).
build_adder_user hambrowse           # scene-file DE web browser: fetch HTTP (user/http9) + parse HTML subset + block/inline layout + render (lib/hamui hamscene_*); links click-navigate
build_adder_user haminstallui         # scene-file DE visual installer: GUI front-end over /bin/haminstall (host name + disk picker + progress)
build_adder_user hamsettings          # scene-file DE settings: wallpaper swatches (ctl wallpaper verb) + panel position/applet prefs (/etc/panel.conf)
build_adder_user hammonscene          # scene-file DE system monitor: uptime + memory bar + /proc/tasks process list (ported from hammon)
build_adder_user hamcalscene          # scene-file DE calendar: month grid with prev/next + today highlight, real clock (lib/hamcalcore, dual-target)
build_adder_user hamnotesscene        # scene-file DE Notes scratchpad: keyboard text entry, auto-persists /tmp/hamnix-notes.txt (lib/hamnotescore, dual-target)

build_adder_user hampaint             # v2-blit DE HamPaint raster drawing app (MS-Paint/Tux-Paint style): canvas + pencil/eraser/line/rect/filled-rect/ellipse/flood-fill tools, S/M/L brush, colour palette, Clear/new, save-as-PNG (lib/pngwrite). REPO-ONLY (hpm install hamnix-hampaint), NOT pre-installed (lib/hampaintcore, dual-target; host gate: scripts/test_hampaint_host.sh)
build_adder_user hamwrite             # scene-file DE HamWrite word processor: the office-suite flagship — File/Edit/Format menu bar + two-row formatting toolbar, pixel word-wrap + scrolling, bold/italic/underline, H1-H3 headings, four text sizes, eight-colour text palette + highlighter, left/centre/right alignment, bullet/numbered LISTS with indent, a ruler, MULTI-LEVEL UNDO/REDO (^Z/^Y), FIND & REPLACE (^F), selection+clipboard, New/Open/Save/Save As of a HAMWRITE2 document container. PRE-INSTALLED first-class DE app (pkg hamnix-hamwrite, launcher etc/hamde/apps/hamwrite.desktop; lib/hamwritecore, dual-target; host gate: scripts/test_hamwrite_host.sh)
build_adder_user hamsheet             # scene-file DE HamSheet spreadsheet: the office suite's 2nd app — scrollable A/B/C… grid with RANGE selection, cells hold numbers/text/=formulas. Formula engine has numbers/strings/booleans/typed errors (#DIV/0! #REF! #NAME? #VALUE! #CIRC!), relative AND absolute ($A$1) refs, + - * / ^ & and = <> < <= > >=, and SUM/AVG/MIN/MAX/COUNT/COUNTA/COUNTIF/SUMIF/IF/AND/OR/NOT/IFERROR/ABS/SQRT/ROUND/INT/SIGN/POWER/MOD/LEN/UPPER/LOWER/TRIM/LEFT/RIGHT/MID/CONCAT. Copy/cut/paste + fill with reference ADJUSTMENT, insert/delete row+col (formulas re-pointed), multi-level undo, per-cell number formats/bold/align, column widths, CSV import/export, and a HAMSHEET2 document container (HAMSHEET1 still loads). PRE-INSTALLED first-class DE app (pkg hamnix-hamsheet, launcher etc/hamde/apps/hamsheet.desktop; lib/hamsheetcore, dual-target; host gate: scripts/test_hamsheet_host.sh)
build_adder_user hamslides            # scene-file DE HamSlides presentation app: the office suite's 3rd app — a deck of slides (title + MULTI-LEVEL bullets + speaker notes + one of five LAYOUTS), four deck-wide THEMES, a File/Edit/Slide/View menu bar + toolbar, add/duplicate/delete/reorder slides with 4-deep UNDO, an EDIT view (thumbnail rail, large current slide, notes strip, status bar) and a full-window PRESENT view (arrows/Space/Home/End, 'n' notes overlay, 'b' blank, progress bar), save/load a HAMSLIDES2 document container that round-trips the WHOLE deck (HAMSLIDES1 still loads). PRE-INSTALLED first-class DE app (pkg hamnix-hamslides, launcher etc/hamde/apps/hamslides.desktop; lib/hamslidescore, dual-target; host gate: scripts/test_hamslides_host.sh)
build_adder_user hamclock             # scene-file DE HamClock clock/calendar/timer utility: large 7-segment digital HH:MM:SS + analog clock face (hands at correct angles), month calendar with today highlighted + prev/next paging (leap-year correct), and a start/stop/reset stopwatch. Wall clock from /proc/realtime (jiffies uptime fallback). REPO-ONLY (hpm install hamnix-hamclock), NOT pre-installed (lib/hamclockcore, dual-target; host gate: scripts/test_hamclock_host.sh)
build_adder_user hammark              # v2-blit DE HamMark Markdown document viewer: parses a useful CommonMark subset (ATX headings, **bold**/*italic*/`code`, [links], fenced code, - / 1. lists, > quotes, --- rules) and lays it out as a scrollable formatted page (larger headings, wrapped paragraphs, code slab, quote accent bar, scrollbar). Arrow/PageUp-Down/wheel scroll. Reads a .md file at the driver edge. REPO-ONLY (hpm install hamnix-hammark), NOT pre-installed (lib/hammarkcore, dual-target; host gate: scripts/test_hammark_host.sh)
build_adder_user hamconvert           # scene-file DE HamConvert unit converter: 8 categories (Length/Mass/Temperature/Volume/Area/Time/Data/Speed) with a category sidebar, FROM/TO unit lists, live float64 result + quick table, swap; exact factors incl. affine temperature (C/F/K). REPO-ONLY (hpm install hamnix-hamconvert), NOT pre-installed (lib/hamconvertcore, dual-target; host gate: scripts/test_hamconvert_host.sh)
build_adder_user hammath              # scene-file DE HamMath expression calculator: build a whole arithmetic expression on the LCD (2+3*4, (2+3)*4, -(3+2)) and evaluate it with correct operator PRECEDENCE, PARENTHESES + unary minus via a recursive-descent, fixed-point (no-FPU) evaluator; 5x4 keypad (digits, + - * /, parens, backspace, =). Distinct from the immediate calculator hamcalc. REPO-ONLY (hpm install hamnix-hammath), NOT pre-installed (lib/hammathcore, dual-target; host gate: scripts/test_hammath_host.sh)
build_adder_user hampkgscene          # scene-file DE Package Manager: searchable package list + detail pane + Install/Remove/Upgrade over the native hpm engine (lib/hampkgcore, dual-target)
build_adder_user hamsoftware          # scene-file DE "Software": hampkgscene + a category sidebar (All/Installed/Available/Upgradable) — richer Synaptic front-end over hpm (lib/hampkgcore, dual-target)
build_adder_user hamlogscene          # scene-file DE Log Viewer: tails /proc/kmsg into a scrollable ring, page/tail/wheel scroll (lib/hamlogcore, dual-target)
build_adder_user haminput             # scene-file DE Input Event Inspector: live-logs /event key+mouse events (MIDDLE-button in amber) + reads /dev/snarf.primary on middle-click to debug PRIMARY paste
build_adder_user hamaudioscene        # scene-file DE Audio Player: decodes a .wav (lib/wavdecode) + streams PCM to the native HDA sink (/dev/audio), progress bar + level meter + play/pause/stop/seek (lib/hamaudiocore, dual-target)
build_adder_user hamaudioselftest     # on-device audio-playback self-test /init: reads /usr/share/sounds/test.wav, decodes (lib/wavdecode), streams PCM to the HDA sink (scripts/test_hamaudio_playback.sh captures + verifies the codec output)
build_adder_user hamaudiobook         # scene-file DE Audiobook player: the FIRST repo-ONLY (255.one / hpm install hamnix-hamaudiobook), NOT-preinstalled app. MP3/WAV playback with SAVE/RESUME position per book (/var/hamaudiobook.state) + SLEEP TIMER (night mode) + skip +-30s (lib/hamaudiobookcore, dual-target; host gate: scripts/test_hamaudiobook_host.sh)
build_adder_user hamangrybirds        # scene-file DE Ham Angry Birds: repo-ONLY (255.one / hpm install hamnix-hamangrybirds), NOT-preinstalled slingshot physics game. Gravity-arc projectile + AABB block collision, destructible wood/stone towers + pig targets, aim (angle/power) by keys or on-screen controls, score, 3 levels, win/lose/restart (lib/hamangrycore, dual-target; host gate: scripts/test_hamangrybirds_host.sh)
build_adder_user hamvideoscene        # scene-file DE Video Player: demuxes a Motion-JPEG .hmjv (lib/mjpegdemux) + decodes each frame (lib/jpeg) + blits it to the window's named image ('I' verb), jiffies-paced playback, scrub bar + play/pause/stop (lib/hamvideocore, dual-target)
build_adder_user hamvideoselftest     # on-device video-decode self-test /init: reads /usr/share/videos/test.hmjv, demuxes + decodes every frame (lib/mjpegdemux + lib/jpeg), blits a mid frame to a wsys window (scripts/test_hamvideo_playback.sh screendumps the rendered frame)
build_adder_user umdf_host            # Track 4: user-mode driver host — loads a stock .ko in USERLAND via the UMDF kernel primitives

# --- X11 server + client (user/x11/ subdirectory) -------------------
# The source lives in user/x11/<name>.ad but the ELF goes into
# build/user/<name>.elf so build_initramfs.py's *.elf glob picks it up
# and installs it at /bin/<name>.
build_adder_x11() {
    local name="$1"
    queue_adder_compile "user/x11/${name}.ad" "build/user/${name}.elf"
}

build_adder_x11 x11srv        # X11 core-protocol server: listens on :6000, renders into wsys fb layer
build_adder_x11 xfill         # X11 demo client: CreateWindow + CreateGC + PolyFillRectangle round-trip
build_adder_x11 x11test       # X11 self-test driver: spawns x11srv + xfill, asserts both PASS
build_adder_x11 xclient_demo  # Standalone X11 app client: purple/cyan fill, used by test_x11_app.sh
build_adder_x11 x11apptest    # X11 app-in-desktop test: spawns x11srv + xclient_demo, checks wsys flush

# --- Self-hosting milestones + on-box compiler drivers ---------------
# These are ordinary independent whole-program compiles (unique outputs),
# so they join the same parallel queue as the userland above.
#   * lex/parse/codegen_selftest      — Adder-in-Adder pipeline selftests
#   * codegen_elf_selftest            — emits+dumps a loadable ELF (test_selfhost_elf.sh)
#   * codegen_bss_selftest            — .bss + .data model emitter (test_selfhost_bss.sh)
#   * codegen_ac_driver               — on-box compile driver from /src/input.ad (hamnix-ac)
#   * adder_cc                        — generic on-box Adder compiler tool (#186), staged /bin/adder_cc
queue_adder_compile adder/compiler/lex_selftest.ad       build/user/lex_selftest.elf
queue_adder_compile adder/compiler/parse_selftest.ad     build/user/parse_selftest.elf
queue_adder_compile adder/compiler/codegen_selftest.ad   build/user/codegen_selftest.elf
queue_adder_compile adder/compiler/codegen_elf_selftest.ad build/user/codegen_elf_selftest.elf
queue_adder_compile adder/compiler/codegen_bss_selftest.ad build/user/codegen_bss_selftest.elf
queue_adder_compile adder/compiler/codegen_ac_driver.ad  build/user/codegen_ac_driver.elf
queue_adder_compile adder/compiler/adder_cc_driver.ad    build/user/adder_cc.elf

# --- Fan out every queued Adder compile across cores -----------------
_run_compile_pool

# --- LEGACY OPT-IN: force-rebuild selected apps as NATIVE ELF64 (LLVM) -----
# NOTE: LLVM->ELF64 is now the DEFAULT for EVERY app (see _compile_one_app),
# so this block is redundant for normal builds. It is retained only for the
# ADDER_LLVM_DEFAULT=0 debug mode: set ADDER_LLVM_DEFAULT=0 (native for all)
# plus ADDER_ELF64_APPS="foo bar" to force just those apps back onto the LLVM
# lane for an A/B comparison.
# Set ADDER_ELF64_APPS to a space-separated list of app names (matching
# build/user/<name>.elf) to OVERWRITE those binaries with a native ELF64
# build via scripts/adder_cc_llvm_native64.sh (clang codegen of the LLVM
# IR, real ELF64 EXEC, OSABI=SYSV, Hamnix native syscall ABI). This is the
# execution-proof staging hook for the LLVM-native-ELF64 track: e.g.
#   ADDER_ELF64_APPS="echo" bash scripts/build_user.sh
# rebuilds /bin/echo as a native ELF64 so a normal boot exercises the
# loader's native-ELF64 path (fs/elf.ad: EI_CLASS==2 + OSABI=SYSV ->
# native syscall routing). DEFAULT-OFF: with the var unset this block is a
# no-op, so every existing image build stays byte-for-byte the ELF32
# native path — native-safe.
if [ -n "${ADDER_ELF64_APPS:-}" ]; then
    for _e64 in $ADDER_ELF64_APPS; do
        _src="user/${_e64}.ad"
        if [ ! -f "$_src" ] && [ -f "tests/${_e64}.ad" ]; then
            _src="tests/${_e64}.ad"
        fi
        if [ ! -f "$_src" ]; then
            echo "[build_user] ERROR: ELF64 app source not found: $_e64" >&2
            exit 1
        fi
        echo "[build_user] ELF64: rebuilding $_e64 as native ELF64 (LLVM backend)"
        if ! ADDER_HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}" \
                bash scripts/adder_cc_llvm_native64.sh "$_src" "build/user/${_e64}.elf"; then
            echo "[build_user] ERROR: ELF64 build FAILED for $_e64" >&2
            exit 1
        fi
        file "build/user/${_e64}.elf"
    done
fi

# Record what this successful build produced, so the next invocation over an
# unchanged tree can prove it would produce the same bytes and short-circuit.
# Reached only on success: `set -e` is in force and every failure path above
# exits non-zero before here.
_bu_write_stamp
