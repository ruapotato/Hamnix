#!/usr/bin/env bash
# test_elf_low_bss_window_host.sh — assert no shipped user binary asks the
# ELF64 loader for a demand-BSS window big enough to swallow the kernel's own
# direct map.
#
# WHY THIS GATE EXISTS  (history — see THE LIFT below for today's shape)
# ----------------------------------------------------------------------
# A native Hamnix ELF64 app USED TO BE ET_EXEC linked at 0x400000
# (user/init64.lds), so its user virtual addresses were
# NUMERICALLY IDENTICAL to low physical RAM —
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
# THE LIFT (2026-07-30): the native ELF64 lane is now linked PIE.
# ---------------------------------------------------------------
# scripts/adder_cc_llvm_native64.sh links ET_DYN at base 0
# (user/init64_pie.lds) instead of ET_EXEC at 0x400000. fs/elf.ad's ET_DYN arm
# rebases such an image onto a base of the KERNEL's choosing — the high ASLR
# vbase, or identity at the image's own memblock `region` on a deterministic
# boot — so its user vaddrs only ever cover its OWN pages. The aliasing is gone
# BY CONSTRUCTION for every app on the lane, not avoided by a size budget.
# fs/elf.ad::_elf64_apply_relative_relocs applies the resulting
# R_X86_64_RELATIVE entries at load time and REFUSES the load on any other
# relocation kind.
#
# A LOW BASE NOW MEANS NO DEMAND SPLIT AT ANY SIZE. The ELF32 lane, Debian's
# busybox-static, the ADDER_NATIVE64_ETEXEC=1 debug link, and an ET_DYN identity
# load on a deterministic (aslr_disabled) boot can all still put an image in the
# low band, and fs/elf.ad backs those EAGER full-span so vaddr == phys holds
# across the whole image.
#
# That rule used to be capped at ELF_MAX_LOW_BSS_DEMAND, and the cap was WRONG:
# device evidence (test_cow_fork, a PIE hamsh exec'ing /bin/test_cow_fork) gave
# `vec=0xe err=0x2 cr2=0x0c000000` with pde[96] cracked and pte[0]=0 — a
# demand window FAR UNDER the cap, punched by an ET_DYN image loaded identity at
# its own ~192 MiB region, sitting exactly at the allocator's high-water mark.
# The size of the window was never the real variable; WHERE it lands is. A low
# ET_EXEC at 0x400000 punches a window over RAM the allocator consumed long ago,
# which is the only reason a 23 MiB window ever survived. ELF_MAX_LOW_BSS_DEMAND
# survives only as the threshold for WARNING about the contiguous region_alloc
# that an eager load costs.
#
# WHAT IT ASSERTS
#   1. For every build/user/*.elf that is an ELF64 image, compute lowest PT_LOAD
#      vaddr, the page-rounded file extent, and the page-rounded memory extent —
#      mirroring _load_elf64's first pass exactly.
#   2. ET_DYN images are SAFE BY CONSTRUCTION (rebased away from the direct
#      map); they are reported, and their dynamic relocations are checked
#      against what the loader can actually apply.
#   3. Any remaining low-linked ET_EXEC is EAGER full-span, whatever its size.
#   4. FAIL if a LOW-based image would take the DEMAND path with ANY window —
#      that would mean the gate's model and fs/elf.ad have drifted apart, which
#      is the only way this class ships again.
#   5. FAIL if an ET_DYN image carries a relocation kind the loader refuses
#      (anything but R_X86_64_RELATIVE / R_X86_64_NONE) — on device that is a
#      refused exec, and the point of a host gate is to catch it here.
#   6. FAIL if NO ELF64 images are found at all, and FAIL if the whole
#      population went ET_EXEC again — a silent lane regression would otherwise
#      read as a quiet PASS.
#   7. WARN (not fail) when an image past the cap would take the EAGER path in
#      the low band: safe, but it pays a large contiguous region_alloc at exec.
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

DT_RELA, DT_RELASZ, DT_RELAENT = 7, 8, 9
R_X86_64_NONE, R_X86_64_RELATIVE = 0, 8


def reloc_kinds(blob, phdrs):
    """Mirror fs/elf.ad::_elf64_apply_relative_relocs: walk PT_DYNAMIC for
    DT_RELA/DT_RELASZ/DT_RELAENT and return the set of relocation TYPES the
    loader would be handed, plus the entry count."""
    dyn = [p for p in phdrs if p[0] == 2]            # PT_DYNAMIC
    if not dyn:
        return set(), 0
    _, d_off, _, d_filesz, _ = dyn[0]
    rela_v = rela_sz = 0
    rela_ent = 24
    off = 0
    while off + 16 <= d_filesz and d_off + off + 16 <= len(blob):
        tag, val = struct.unpack_from('<QQ', blob, d_off + off)
        if tag == 0:                                  # DT_NULL
            break
        if tag == DT_RELA:    rela_v = val
        if tag == DT_RELASZ:  rela_sz = val
        if tag == DT_RELAENT: rela_ent = val
        off += 16
    if not rela_sz or rela_ent != 24:
        return set(), 0
    # vaddr -> file offset via the containing file-backed PT_LOAD
    rela_off = None
    for p_type, p_off, p_vaddr, p_filesz, _ in phdrs:
        if p_type == PT_LOAD and p_vaddr <= rela_v < p_vaddr + p_filesz:
            rela_off = p_off + (rela_v - p_vaddr)
            break
    if rela_off is None or rela_off + rela_sz > len(blob):
        return {'<DT_RELA not file-backed>'}, 0
    kinds, n = set(), 0
    for r in range(0, rela_sz, rela_ent):
        _, r_info, _ = struct.unpack_from('<QQq', blob, rela_off + r)
        kinds.add(r_info & 0xffffffff)
        n += 1
    return kinds, n


def window(path):
    """Mirror fs/elf.ad::_load_elf64's first pass. Returns
    (e_type, lowest_v, file_hi_rel, mem_hi_rel, reloc_kinds, n_relocs)
    or None if not an ELF64 image."""
    with open(path, 'rb') as f:
        blob = f.read()
    if len(blob) < 64 or blob[:4] != b'\x7fELF':
        return None
    if blob[4] != 2:                       # EI_CLASS: 2 = ELF64
        return None
    e_type = struct.unpack_from('<H', blob, 16)[0]
    if e_type not in (2, 3):               # ET_EXEC / ET_DYN
        return None
    e_phoff     = struct.unpack_from('<Q', blob, 32)[0]
    e_phentsize = struct.unpack_from('<H', blob, 54)[0]
    e_phnum     = struct.unpack_from('<H', blob, 56)[0]
    lowest_v, highest_v, highest_file_v = None, 0, 0
    phdrs = []
    for i in range(e_phnum):
        ph = e_phoff + i * e_phentsize
        if ph + 56 > len(blob):
            return None
        p_type = struct.unpack_from('<I', blob, ph)[0]
        p_offset = struct.unpack_from('<Q', blob, ph + 8)[0]
        p_vaddr  = struct.unpack_from('<Q', blob, ph + 16)[0]
        p_filesz = struct.unpack_from('<Q', blob, ph + 32)[0]
        p_memsz  = struct.unpack_from('<Q', blob, ph + 40)[0]
        phdrs.append((p_type, p_offset, p_vaddr, p_filesz, p_memsz))
        if p_type != PT_LOAD:
            continue
        lowest_v = p_vaddr if lowest_v is None else min(lowest_v, p_vaddr)
        highest_v = max(highest_v, p_vaddr + p_memsz)
        highest_file_v = max(highest_file_v, p_vaddr + p_filesz)
    if lowest_v is None or highest_v == 0:
        return None
    mem_hi_rel  = roundup_page(highest_v - lowest_v)
    file_hi_rel = min(roundup_page(highest_file_v - lowest_v), mem_hi_rel)
    kinds, n_rel = reloc_kinds(blob, phdrs)
    return e_type, lowest_v, file_hi_rel, mem_hi_rel, kinds, n_rel

ET_EXEC, ET_DYN = 2, 3
LOADER_APPLIES = {R_X86_64_NONE, R_X86_64_RELATIVE}

execs, dyns, bad, badrel, eager = [], [], [], [], []
for path in sorted(glob.glob(os.path.join(elfdir, '*.elf'))):
    w = window(path)
    if w is None:
        continue
    e_type, lowest_v, file_hi_rel, mem_hi_rel, kinds, n_rel = w
    name = os.path.basename(path)

    if e_type == ET_DYN:
        # SAFE BY CONSTRUCTION: _load_elf64's ET_DYN arm rebases the image onto
        # a base of the kernel's choosing, so its user vaddrs cover only its own
        # pages. There is no window to bound. Two things can still go wrong:
        #   * a relocation kind the loader refuses -> a refused exec on device;
        #   * a BSS tail past the cap. On the DEFAULT (ASLR-on) boot the image
        #     sits at a high vbase and keeps the cheap demand split. On a
        #     DETERMINISTIC (aslr_disabled) boot it loads IDENTITY at its own
        #     region, where the loader suppresses the split and backs the FULL
        #     span eagerly to keep vaddr == phys -- correct, but it pays a large
        #     contiguous region_alloc at every exec, which is a real OOM risk.
        unsupported = sorted(k for k in kinds if k not in LOADER_APPLIES)
        dyns.append((name, mem_hi_rel, mem_hi_rel - file_hi_rel, n_rel))
        if unsupported:
            badrel.append((name, unsupported))
        if mem_hi_rel > cap:
            eager.append((name, mem_hi_rel))
        continue

    is_low = lowest_v < low_top
    # The loader's rule (fs/elf.ad): a LOW-BASED image gets NO demand split at
    # any size -- eager full span, so vaddr == phys across the whole image.
    # The cap is no longer a correctness knob, only the threshold for warning
    # about the contiguous region_alloc that eager load costs.
    suppressed = is_low
    bss_lo = lowest_v + file_hi_rel
    bss_hi = lowest_v + mem_hi_rel
    win = 0 if suppressed else (mem_hi_rel - file_hi_rel)
    execs.append((name, lowest_v, bss_lo, bss_hi, mem_hi_rel, win,
                  suppressed, is_low))
    if suppressed:
        if mem_hi_rel > cap:
            eager.append((name, mem_hi_rel))
    elif is_low:
        # Model/loader drift: a LOW-based image with ANY demand window must be
        # impossible -- that is the exact shape that halted the box with
        # cr2=0x0c000000 (a punched not-present leaf at the allocator's
        # high-water mark).
        bad.append((name, win))

if not execs and not dyns:
    print('[elfbss] FAIL: no ELF64 images found in %s at all. This gate is the '
          'ratchet on the low-BSS/direct-map class; an empty population means '
          'it is asserting nothing, which is how the class ships again.' % elfdir)
    sys.exit(1)

print('[elfbss] %d ET_DYN (PIE, safe by construction) + %d ET_EXEC ELF64 images'
      % (len(dyns), len(execs)))

if dyns:
    dyns.sort(key=lambda r: -r[1])
    print('[elfbss] top 5 ET_DYN by span:')
    print('[elfbss]   %-28s %10s %10s %8s' % ('image', 'span', 'bss-tail', 'relocs'))
    for name, span, bsstail, n_rel in dyns[:5]:
        print('[elfbss]   %-28s %9.1fM %9.1fM %8d'
              % (name, span / 1048576.0, bsstail / 1048576.0, n_rel))

if execs:
    execs.sort(key=lambda r: -r[4])
    print('[elfbss] top 10 ET_EXEC by span:')
    print('[elfbss]   %-28s %10s %10s  %s' % ('image', 'span', 'bss-window', 'range'))
    for name, lowv, blo, bhi, span, win, sup, _ in execs[:10]:
        print('[elfbss]   %-28s %9.1fM %9.1fM  %s  [0x%x, 0x%x)'
              % (name, span / 1048576.0, win / 1048576.0,
                 'EAGER(capped)' if sup else 'demand', blo, bhi))

for name, span in eager:
    print('[elfbss] WARNING: %s span %.1f MiB exceeds the cap -> EAGER full-span '
          'load whenever it lands in the low band (a low ET_EXEC link, or an '
          'ET_DYN identity load on a deterministic/aslr_disabled boot). Safe '
          '(vaddr == phys, no direct-map alias) but it pays a %.1f MiB '
          'contiguous region_alloc at every exec; shrink its static BSS.'
          % (name, span / 1048576.0, span / 1048576.0))

failed = False

if badrel:
    for name, kinds in badrel:
        print('[elfbss] FAIL: %s (ET_DYN) carries dynamic relocation type(s) %s. '
              'fs/elf.ad::_elf64_apply_relative_relocs applies R_X86_64_RELATIVE '
              'only and REFUSES the load on anything else, so this image will '
              'not exec on device.' % (name, ', '.join(str(k) for k in kinds)))
    failed = True

if bad:
    for name, win in bad:
        print('[elfbss] FAIL: %s is LOW-based and would take the DEMAND path '
              'with a %.1f MiB window. A low-based image must get NO demand '
              'split at any size (fs/elf.ad); the gate model and the loader '
              'have drifted, and the loader will punch that window into the '
              'kernel direct map.' % (name, win / 1048576.0))
    failed = True

# LANE REGRESSION GUARD. The native ELF64 lane links PIE; a big population of
# ELF64 images with ZERO ET_DYN among them means the lane silently reverted to
# the low-ET_EXEC link (e.g. ADDER_NATIVE64_ETEXEC leaked into a build), which
# reintroduces the aliasing hazard for every app at once. Without this check
# that regression reads as a quiet PASS.
if not dyns and len(execs) >= 10:
    print('[elfbss] FAIL: %d ELF64 images and NOT ONE is ET_DYN. The native '
          'ELF64 lane is supposed to link PIE (user/init64_pie.lds); every '
          'image being a low ET_EXEC means the lane reverted and the '
          'direct-map aliasing hazard is back for all of them.' % len(execs))
    failed = True

if failed:
    sys.exit(1)

biggest_demand = max((r[5] for r in execs if not r[6]), default=0)
print('[elfbss] PASS: %d PIE image(s) safe by construction (%d total relocs, all '
      'R_X86_64_RELATIVE); largest ET_EXEC demand-BSS window %.1f MiB vs cap '
      '%.1f MiB, %d image(s) on the eager fallback.'
      % (len(dyns), sum(r[3] for r in dyns), biggest_demand / 1048576.0,
         cap / 1048576.0, len(eager)))
sys.exit(0)
PY
rc=$?
case "$rc" in
    0)   echo "[elfbss] PASS" ;;
    125) echo "[elfbss] INCONCLUSIVE" >&2 ;;
    *)   echo "[elfbss] FAIL" >&2 ;;
esac
exit $rc
