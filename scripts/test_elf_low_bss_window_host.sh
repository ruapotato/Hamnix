#!/usr/bin/env bash
# test_elf_low_bss_window_host.sh — assert no shipped user binary asks the
# ELF64 loader for a demand-BSS window big enough to swallow the kernel's own
# direct map.
#
# WHY THIS GATE EXISTS
# --------------------
# A native Hamnix ELF64 app is ET_EXEC linked at 0x400000 (user/init64.lds), so
# its user virtual addresses are NUMERICALLY IDENTICAL to low physical RAM —
# the kernel's identity direct map. fs/elf.ad splits such an image into an
# eager file-backed extent plus a demand-zero BSS tail, and
# mm/vma.ad::vma_register_bss_demand -> fs/elf.ad::elf_prepare_demand_range
# PUNCHES EVERY LEAF in [bss_lo, bss_hi) not-present in that task's PML4.
#
# Once punched, ANY kernel low-identity access to a physical page that falls
# inside the window — made under this task's CR3 — takes a supervisor #PF. The
# demand resolver is itself such an access: alloc_page() hands back a low frame
# and the zero-fill/map touches it through its identity vaddr. So a window that
# covers a large fraction of MEMBLOCK's [0x200000, 0x0F000000) pool makes the
# FIRST BSS store fault recursively and wedge the box with interrupts off.
#
# This is not hypothetical and it is not a codegen bug. On 2026-07-30 the LLVM
# lane built hambrowse as a real ELF64 ET_EXEC with a 173.8 MiB BSS tail —
# window [0x589000, 0xB35E000) — and it wedged the machine on device at its
# first global store (`he_click_links`, +135 MiB inside the window), reaching
# `[runtime:hambrowse] _start` and never rendering. That cost a full bisect to
# attribute because nothing in the build or the host differential could see it:
# the ELF is fine, the IR verifies, the engine computes identically on the
# host. The failure lives entirely in the SHAPE of the image the loader is
# handed, which is exactly what this gate reads.
#
# fs/elf.ad now caps the window (ELF_MAX_LOW_BSS_DEMAND) and falls back to an
# eager full-span load above it — the same policy the ELF32 path has always
# used for the same aliasing reason. This gate is the ratchet on the other
# side of that cap: it reads the cap out of fs/elf.ad and reports every shipped
# binary's window against it, so BSS growth in any of the ~278 apps can never
# again silently walk into the dangerous band unnoticed.
#
# WHAT IT ASSERTS
#   1. For every build/user/*.elf that is a low-linked ELF64 ET_EXEC, compute
#      lowest PT_LOAD vaddr, the page-rounded file extent, and the page-rounded
#      memory extent — mirroring _load_elf64's first pass exactly.
#   2. Every such image is classified DEMAND (window <= cap) or EAGER
#      (window > cap, loader suppresses the split). Both are safe; the report
#      names which and why.
#   3. FAIL if any image would take the DEMAND path with a window larger than
#      the cap — that would mean the gate's model and fs/elf.ad have drifted
#      apart, which is the only way this class ships again.
#   4. WARN (not fail) when an image crosses onto the EAGER path for the first
#      time: it is safe, but it means that app now pays a large contiguous
#      region_alloc at exec, which is a real OOM risk on a small image.
#
# Host-only: no QEMU, no device. Reads ELF program headers with python3.
#
# VERDICT CODES (scripts/_verdict.sh): 0 = PASS, 1 = FAIL, 125 = INCONCLUSIVE.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT" || exit 1

command -v python3 >/dev/null 2>&1 || {
    echo "[elfbss] INCONCLUSIVE: python3 required" >&2; exit 125; }

ELF_SRC="fs/elf.ad"
[ -f "$ELF_SRC" ] || { echo "[elfbss] INCONCLUSIVE: $ELF_SRC missing" >&2; exit 125; }

# Read the cap straight out of the kernel source so the gate can never disagree
# with the loader about what the threshold is.
CAP_HEX="$(grep -E '^ELF_MAX_LOW_BSS_DEMAND: *uint64 *=' "$ELF_SRC" \
           | head -1 | sed -E 's/.*= *//; s/ *(#.*)?$//')"
LOWTOP_HEX="$(grep -E '^ELF_LOW_IMAGE_VADDR_TOP: *uint64 *=' "$ELF_SRC" \
           | head -1 | sed -E 's/.*= *//; s/ *(#.*)?$//')"
if [ -z "$CAP_HEX" ] || [ -z "$LOWTOP_HEX" ]; then
    echo "[elfbss] INCONCLUSIVE: could not read ELF_MAX_LOW_BSS_DEMAND /" \
         "ELF_LOW_IMAGE_VADDR_TOP from $ELF_SRC" >&2
    exit 125
fi

ELF_DIR="${ELF_DIR:-build/user}"
if [ ! -d "$ELF_DIR" ] || [ -z "$(ls -A "$ELF_DIR"/*.elf 2>/dev/null)" ]; then
    echo "[elfbss] INCONCLUSIVE: no ELFs in $ELF_DIR (run scripts/build_user.sh)" >&2
    exit 125
fi

echo "[elfbss] cap=$CAP_HEX  low-image-vaddr-top=$LOWTOP_HEX  dir=$ELF_DIR"

python3 - "$CAP_HEX" "$LOWTOP_HEX" "$ELF_DIR" <<'PY'
import glob, struct, sys, os

cap     = int(sys.argv[1], 0)
low_top = int(sys.argv[2], 0)
elfdir  = sys.argv[3]

PT_LOAD = 1
PAGE    = 4096

def rounddown_page(v): return v & ~(PAGE - 1)
def roundup_page(v):   return (v + PAGE - 1) & ~(PAGE - 1)

def window(path):
    """Mirror fs/elf.ad::_load_elf64's first pass. Returns
    (lowest_v, file_hi_rel, mem_hi_rel) or None if not a low ELF64 ET_EXEC."""
    with open(path, 'rb') as f:
        blob = f.read()
    if len(blob) < 64 or blob[:4] != b'\x7fELF':
        return None
    if blob[4] != 2:                       # EI_CLASS: 2 = ELF64
        return None
    e_type = struct.unpack_from('<H', blob, 16)[0]
    if e_type != 2:                        # ET_EXEC only; ET_DYN sits high
        return None
    e_phoff     = struct.unpack_from('<Q', blob, 32)[0]
    e_phentsize = struct.unpack_from('<H', blob, 54)[0]
    e_phnum     = struct.unpack_from('<H', blob, 56)[0]
    lowest_v, highest_v, highest_file_v = None, 0, 0
    for i in range(e_phnum):
        ph = e_phoff + i * e_phentsize
        if ph + 56 > len(blob):
            return None
        p_type = struct.unpack_from('<I', blob, ph)[0]
        if p_type != PT_LOAD:
            continue
        p_vaddr  = struct.unpack_from('<Q', blob, ph + 16)[0]
        p_filesz = struct.unpack_from('<Q', blob, ph + 32)[0]
        p_memsz  = struct.unpack_from('<Q', blob, ph + 40)[0]
        lowest_v = p_vaddr if lowest_v is None else min(lowest_v, p_vaddr)
        highest_v = max(highest_v, p_vaddr + p_memsz)
        highest_file_v = max(highest_file_v, p_vaddr + p_filesz)
    if lowest_v is None or highest_v == 0:
        return None
    mem_hi_rel  = roundup_page(highest_v - lowest_v)
    file_hi_rel = min(roundup_page(highest_file_v - lowest_v), mem_hi_rel)
    return lowest_v, file_hi_rel, mem_hi_rel

rows, bad, eager = [], [], []
for path in sorted(glob.glob(os.path.join(elfdir, '*.elf'))):
    w = window(path)
    if w is None:
        continue
    lowest_v, file_hi_rel, mem_hi_rel = w
    is_low = lowest_v < low_top
    # The loader's rule (fs/elf.ad): a low-linked ET_EXEC whose FULL span
    # exceeds the cap gets no demand split at all -- eager full span.
    suppressed = is_low and mem_hi_rel > cap
    bss_lo = lowest_v + file_hi_rel
    bss_hi = lowest_v + mem_hi_rel
    win = 0 if suppressed else (mem_hi_rel - file_hi_rel)
    rows.append((os.path.basename(path), lowest_v, bss_lo, bss_hi,
                 mem_hi_rel, win, suppressed, is_low))
    if suppressed:
        eager.append((os.path.basename(path), mem_hi_rel))
    elif is_low and win > cap:
        # Model/loader drift: a demand window past the cap must be impossible.
        bad.append((os.path.basename(path), win))

if not rows:
    print('[elfbss] INCONCLUSIVE: no low-linked ELF64 ET_EXEC images found')
    sys.exit(125)

rows.sort(key=lambda r: -r[4])
print('[elfbss] %d low-linked ELF64 ET_EXEC images; top 10 by span:' % len(rows))
print('[elfbss]   %-28s %10s %10s  %s' % ('image', 'span', 'bss-window', 'path'))
for name, lowv, blo, bhi, span, win, sup, _ in rows[:10]:
    print('[elfbss]   %-28s %9.1fM %9.1fM  %s  [0x%x, 0x%x)'
          % (name, span / 1048576.0, win / 1048576.0,
             'EAGER(capped)' if sup else 'demand', blo, bhi))

for name, span in eager:
    print('[elfbss] WARNING: %s span %.1f MiB exceeds the cap -> EAGER full-span '
          'load. Safe (no direct-map alias) but it pays a %.1f MiB contiguous '
          'region_alloc at every exec; shrink its static BSS.'
          % (name, span / 1048576.0, span / 1048576.0))

if bad:
    for name, win in bad:
        print('[elfbss] FAIL: %s would take the DEMAND path with a %.1f MiB '
              'window -- past ELF_MAX_LOW_BSS_DEMAND. The gate model and '
              'fs/elf.ad have drifted; the loader will punch that window into '
              'the kernel direct map and the box wedges on the first BSS store.'
              % (name, win / 1048576.0))
    sys.exit(1)

biggest_demand = max((r[5] for r in rows if not r[6]), default=0)
print('[elfbss] PASS: largest live demand-BSS window %.1f MiB, cap %.1f MiB, '
      '%d image(s) on the eager fallback.'
      % (biggest_demand / 1048576.0, cap / 1048576.0, len(eager)))
sys.exit(0)
PY
rc=$?
case "$rc" in
    0)   echo "[elfbss] PASS" ;;
    125) echo "[elfbss] INCONCLUSIVE" >&2 ;;
    *)   echo "[elfbss] FAIL" >&2 ;;
esac
exit $rc
