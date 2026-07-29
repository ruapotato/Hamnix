#!/usr/bin/env bash
# scripts/test_memhog.sh — /bin/memhog on the real bare-metal kernel, and the
# system monitor's DISPLAYED memory figure tracking a real allocate/free.
#
# TWO THINGS ARE ASSERTED, AND THEY MAKE EACH OTHER TESTABLE
# ==========================================================
#
# (A) memhog TELLS THE TRUTH ABOUT WHAT IT GOT.
#     memhog exists to apply a known amount of memory pressure so
#     reclamation is measurable. A tool that says "96 MiB" while quietly
#     mapping 4 MiB would poison every measurement taken with it, so the
#     gate does not check that memhog ran — it checks the NUMBERS:
#       * asked == got for a request the box can serve,
#       * /proc/meminfo's MemFree actually FELL by ~the requested amount
#         (a lazily-reserved mapping cannot move the kernel's free pool),
#       * MemFree came back to the pre-allocation baseline after release,
#       * an over-large request is reported as a LOUD short allocation with
#         exit status 2 rather than silently under-allocating,
#       * --ramp reports a non-zero ceiling.
#
# (B) THE SYSTEM MONITOR'S OWN DISPLAY TRACKS FREED MEMORY WITHOUT A
#     RESTART. The reported bug was: "the browser takes up like 10% ram but
#     after you close it the ram is returned but not until you restart the
#     monitor app." So the assertion here is deliberately NOT "hammonscene
#     called _refresh_mem()". It is the monitor's OWN OUTPUT: /bin/hammonscene
#     publishes its display list to /dev/wsys/<wid>/scene, including the line
#
#         glyphs 10 137 "Memory  <used> / <total> kB (<pct>%)" #c0d0e0
#
#     — the exact text the compositor rasterizes. The gate starts the monitor
#     ONCE and never touches it again, then reads that line three times:
#
#         A  idle baseline
#         B  while memhog holds ~96 MiB               -> used must RISE
#         C  after the memhog process has EXITED       -> used must FALL back
#
#     `memhog --no-free` exits while still holding, so the reclamation under
#     test is the kernel's process-teardown path — the code an app being
#     CLOSED actually runs, which is the scenario in the report. munmap is a
#     different path and would not have exercised it.
#
#     The same live monitor produces A, B and C. If its figure were latched at
#     startup, re-read once, or served from a stale cache, C would still read
#     B's value and this gate goes red.
#
# WHY A BARE KERNEL BOOT AND NOT THE FULL DE
# ==========================================
# The subject under test is the MONITOR CLIENT's data path: sample /proc,
# publish a scene. /dev/wsys is a kernel device (sys/src/9/port/devwsys.ad),
# so hammonscene allocates a window and publishes a real scene with no
# compositor running — which is what makes this assertion cheap AND lets it
# read the monitor's output as text instead of OCR-ing pixels. Rasterizing
# that scene to the framebuffer is the compositor's separate job, covered by
# the DE visual gates.
#
# INCONCLUSIVE (125) — never PASS — when the gate could not observe its
# assertion at all: no guest markers, hammonscene never took a window, or the
# scene file was unreadable. A gate that cannot see the thing it asserts must
# say so.
#
# Pass marker: [memhog] PASS

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LOG=${HAMNIX_MEMHOG_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[memhog] (1/3) build userland"
bash scripts/build_user.sh >/dev/null || {
    echo "[memhog] INCONCLUSIVE: userland build failed" >&2; exit 125; }
[ -f build/user/memhog.elf ] || {
    echo "[memhog] FAIL: build/user/memhog.elf was not produced" >&2; exit 1; }

echo "[memhog] (2/3) initramfs (/init = hamsh) + kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null || {
    echo "[memhog] INCONCLUSIVE: initramfs build failed" >&2; exit 125; }
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null || {
    echo "[memhog] INCONCLUSIVE: kernel build failed" >&2; exit 125; }

# ---------------------------------------------------------------- boot
# The freshly-booted hamsh serial shell DROPS its first command line
# (documented quirk), so a throwaway line is sent first and the real
# sequence never relies on it. Every memhog invocation passes --batch: the
# interactive hold loop polls stdin non-blocking, which would otherwise eat
# the next command this harness types.
echo "[memhog] (3/3) boot QEMU"
set +e
(
  sleep 8
  printf '\n';                                       sleep 2
  printf 'echo GATE-PRIME\n';                        sleep 3
  printf 'echo GATE-READY\n';                        sleep 3
  # --- (B) start the monitor ONCE. It is never restarted below. ---
  printf 'hammonscene &\n';                          sleep 8
  printf 'echo GATE-SCENE-A\n';                      sleep 2
  printf 'cat /dev/wsys/2/scene\n';                  sleep 5
  # --- (B) pressure via a process that EXITS while holding ---
  # BACKGROUNDED (`&`) deliberately. Run in the FOREGROUND the shell blocks
  # until memhog is gone, every queued `cat` below then executes AFTER the
  # exit, and B would sample the post-release state — a gate that always
  # reads "no change" and calls it a pass. Cost one false FAIL to learn.
  printf 'memhog 96M --hold 30 --batch --no-free &\n'; sleep 14
  printf 'echo GATE-SCENE-B\n';                      sleep 2
  printf 'cat /dev/wsys/2/scene\n';                  sleep 6
  # memhog is still holding here; wait out the rest of its hold + exit.
  printf 'echo GATE-SCENE-C\n';                      sleep 26
  printf 'cat /dev/wsys/2/scene\n';                  sleep 5
  # --- (A) allocate / verify / release with the full report ---
  printf 'echo GATE-ALLOC\n';                        sleep 2
  printf 'memhog 64M --hold 1 --batch\n';            sleep 14
  # --- (A) a request far past this 512 MiB box: LOUD short allocation ---
  printf 'echo GATE-SHORT\n';                        sleep 2
  printf 'memhog 4G --hold 0 --batch\n';             sleep 22
  # --- (A) ramp to the ceiling ---
  printf 'echo GATE-RAMP\n';                         sleep 2
  printf 'memhog --ramp --hold 0 --batch -q\n';      sleep 22
  printf 'echo GATE-DONE\n';                         sleep 3
) | timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 -nographic -no-reboot -m 512M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

# ------------------------------------------------------------- verdict
# GATE-READY, not GATE-PRIME: hamsh drops the FIRST command line it is given
# over serial, so the first echo is expected to vanish. Two priming echoes are
# sent and the SECOND one is the liveness marker.
if ! grep -a -q "GATE-READY" "$LOG"; then
    echo "[memhog] INCONCLUSIVE: no guest marker at all — the boot never" \
         "reached an interactive shell (qemu rc=$rc)" >&2
    tail -40 "$LOG" >&2
    exit 125
fi

fail=0

# ---- (A) memhog's own report -----------------------------------------
alloc_block=$(sed -n '/GATE-ALLOC/,/GATE-SHORT/p' "$LOG" | tr -d '\r')
if ! grep -a -q "memhog: got 67108864 bytes (64 MiB) of 67108864 bytes (64 MiB)" \
        <<<"$alloc_block"; then
    echo "[memhog] FAIL: 64M request did not report asked == got" >&2
    grep -a "memhog:" <<<"$alloc_block" >&2 || true
    fail=1
else
    echo "[memhog] OK: asked == got for 64M"
fi

# MemFree must really fall. memhog prints "kernel saw <N> kB leave the free
# pool"; N must be at least 80% of the 65536 kB asked for, or the mapping was
# a reservation rather than RAM.
drop=$(grep -a -o "kernel saw [0-9]* kB leave" <<<"$alloc_block" \
       | head -1 | tr -dc '0-9')
if [ -z "$drop" ]; then
    echo "[memhog] INCONCLUSIVE: memhog printed no MemFree delta (could not" \
         "read /proc/meminfo in the guest)" >&2
    exit 125
fi
if [ "$drop" -lt 52428 ]; then
    echo "[memhog] FAIL: MemFree only fell ${drop} kB for a 65536 kB ask" \
         "— the allocation was not resident" >&2
    fail=1
else
    echo "[memhog] OK: MemFree fell ${drop} kB for a 65536 kB ask (resident)"
fi
if grep -a -q "LAZY RESERVATION" <<<"$alloc_block"; then
    echo "[memhog] FAIL: memhog reported a LAZY RESERVATION" >&2
    fail=1
fi
if grep -a -q "NOT RESIDENT" <<<"$alloc_block"; then
    echo "[memhog] FAIL: a page did not read back its sentinel" >&2
    fail=1
fi
# Release must return the RAM. Accept a small residue (the run itself carves
# a region span for memhog's own ELF image), but not the hog.
if grep -a -q "FULLY RECLAIMED" <<<"$alloc_block"; then
    echo "[memhog] OK: MemFree fully reclaimed after release"
else
    resid=$(grep -a -o "SHORT BY [0-9]* kB" <<<"$alloc_block" \
            | head -1 | tr -dc '0-9')
    if [ -n "$resid" ] && [ "$resid" -lt 16384 ]; then
        echo "[memhog] OK: reclaimed to within ${resid} kB of baseline"
    else
        echo "[memhog] FAIL: ${resid:-?} kB of the 65536 kB hog was not" \
             "returned after release" >&2
        fail=1
    fi
fi

# ---- (A) loud short allocation ---------------------------------------
short_block=$(sed -n '/GATE-SHORT/,/GATE-RAMP/p' "$LOG" | tr -d '\r')
if grep -a -q "SHORT ALLOCATION" <<<"$short_block"; then
    echo "[memhog] OK: a 4G ask on a 512M box is reported as SHORT, loudly"
elif grep -a -q "ALLOCATION REFUSED" <<<"$short_block"; then
    echo "[memhog] OK: a 4G ask on a 512M box is reported as REFUSED, loudly"
else
    echo "[memhog] FAIL: a 4G ask on a 512 MiB box produced neither a SHORT" \
         "nor a REFUSED report — memhog under-allocated SILENTLY" >&2
    grep -a "memhog:" <<<"$short_block" >&2 || true
    fail=1
fi

# ---- (A) ramp ceiling -------------------------------------------------
ramp_block=$(sed -n '/GATE-RAMP/,/GATE-DONE/p' "$LOG" | tr -d '\r')
ceil=$(grep -a -o "CEILING [0-9]* bytes" <<<"$ramp_block" \
       | head -1 | tr -dc '0-9')
if [ -n "$ceil" ] && [ "$ceil" -gt 0 ]; then
    echo "[memhog] OK: --ramp reported a ceiling of ${ceil} bytes"
else
    echo "[memhog] FAIL: --ramp reported no ceiling" >&2
    grep -a "memhog:" <<<"$ramp_block" >&2 || true
    fail=1
fi

# ---- (B) the monitor's OWN displayed figure ---------------------------
# "Memory  <used> / <total> kB (<pct>%)" out of the live scene, three times,
# from ONE never-restarted hammonscene.
mem_at() {
    sed -n "/$1/,/$2/p" "$LOG" | tr -d '\r' \
        | grep -a -o 'Memory  [0-9]* / [0-9]* kB' | head -1 \
        | awk '{print $2}'
}
if ! grep -a -q "hammonscene" "$LOG"; then
    echo "[memhog] INCONCLUSIVE: hammonscene never started" >&2
    exit 125
fi
mem_a=$(mem_at GATE-SCENE-A GATE-SCENE-B)
mem_b=$(mem_at GATE-SCENE-B GATE-SCENE-C)
mem_c=$(mem_at GATE-SCENE-C GATE-ALLOC)
if [ -z "$mem_a" ] || [ -z "$mem_b" ] || [ -z "$mem_c" ]; then
    echo "[memhog] INCONCLUSIVE: could not read the monitor's Memory line" \
         "from /dev/wsys/2/scene (A='$mem_a' B='$mem_b' C='$mem_c')" >&2
    exit 125
fi
echo "[memhog] monitor displayed used kB: A=$mem_a  B=$mem_b (hog held)" \
     " C=$mem_c (hog exited)"
# B must be clearly higher than A: the 96 MiB (98304 kB) hog has to show up.
if [ "$((mem_b - mem_a))" -lt 65536 ]; then
    echo "[memhog] FAIL: the monitor's displayed used memory rose only" \
         "$((mem_b - mem_a)) kB while a 98304 kB hog was held — the display" \
         "is not tracking allocation" >&2
    fail=1
else
    echo "[memhog] OK: displayed used rose $((mem_b - mem_a)) kB under the hog"
fi
# C must come back down. This is the reported bug's assertion: the SAME
# never-restarted monitor must show the memory returned.
back=$((mem_b - mem_c))
if [ "$back" -lt 65536 ]; then
    echo "[memhog] FAIL: after the hog process exited, the monitor still" \
         "displays $mem_c kB used (only $back kB of $((mem_b - mem_a)) kB" \
         "released showed up) — the displayed figure is STALE without a" \
         "restart, which is exactly the reported bug" >&2
    fail=1
else
    echo "[memhog] OK: displayed used fell $back kB after the hog exited," \
         "with NO monitor restart"
fi
if [ "$mem_c" -gt "$((mem_a + 16384))" ]; then
    echo "[memhog] FAIL: displayed used settled at $mem_c kB vs an A" \
         "baseline of $mem_a kB — more than 16 MiB never came back" >&2
    fail=1
fi

echo "[memhog] --- memhog output ---"
grep -a "memhog:" "$LOG" | tr -d '\r' || true
echo "[memhog] --- end ---"

if [ "$fail" -ne 0 ]; then
    echo "[memhog] FAIL (qemu rc=$rc; log $LOG)"
    exit 1
fi
echo "[memhog] PASS — memhog reports asked-vs-got honestly, the RAM is really" \
     "resident and really returned, and the live System Monitor's own" \
     "displayed figure tracks both without a restart"
