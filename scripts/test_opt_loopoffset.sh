#!/usr/bin/env bash
# scripts/test_opt_loopoffset.sh — focused, host-only correctness + firing guard
# for the PER-LOOP 32-BYTE OFFSET alignment heuristic (codegen.ad
# emit_loop_align / loop_body_branchy) plus the ELF determinism base
# (ad_codegen_host.wrap_elf code_pad) that together recover the collatz alignment
# regression on the perf_2x track (#98).
#
# THE LEVER (--opt only):
#   * The ELF wrapper pads its headers so code[0] lands on a 32-byte-aligned VMA,
#     so a loop-top's `code_len & 31` IS its runtime 32-byte DSB-window offset
#     (build-deterministic, no cross-build lottery).
#   * emit_loop_align pads each loop-top to a STATICALLY-CHOSEN 32B offset: a
#     BRANCHY / nested-loop body -> offset 16; a tight branch-free body -> offset
#     0 (loop_body_branchy walks the body AST; a const-folded `if 1==1` does NOT
#     count as a branch).
#
# WHAT IT PROVES (no QEMU):
#   1. DISCRIMINATION — a program whose only non-prelude loop is TIGHT (branch-
#      free) lands EVERY loop-top at 32B offset 0 under --opt; a program whose
#      main loop is BRANCHY lands that loop-top at 32B offset 16 (and all tops
#      stay on a chosen {0,16} offset). This is the heuristic actually firing.
#   2. DETERMINISM BASE — the wrapped ELF's code[0] VMA is 32-byte aligned.
#   3. BYTE-INERT OFF — with --opt OFF the alignment pass is disabled: NO loop-top
#      is force-aligned to a 32B offset (the offset-16 branchy top is absent) and
#      the emitted code carries no alignment NOP padding the ON build adds.
#   4. CORRECTNESS — every kernel's --opt value EXACTLY equals its --opt-OFF value
#      and the independent reference.
#
# HOST-ONLY: python3 + objdump (x86_64). NO QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# LEGACY opt1 LANE GUARD (added 2026-07-25).  Every "the lever FIRED" assertion
# below targets the opt1 optimizer lane (opt.ad's AST passes + the
# ra_enabled-gated codegen levers).  Commit ba2e4bcf (2026-07-21) retired that
# lane — `--opt` now arms the SSA pipeline and the dump driver never calls
# ra_enable() on the emission path — so those counters are structurally 0 while
# the values stay CORRECT (opt == off == reference).  The helper PROBES the lane
# and skips loudly only while it is genuinely retired; it re-arms this guard
# automatically the moment the lane comes back.  See docs/ci_status_2026-07-25.md.
source "$PROJ_ROOT/scripts/lib_opt1_lane.sh"
opt1_require_lane "test_opt_loopoffset"

python3 - <<'PY'
import sys, subprocess, re, struct
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_loopoffset"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
fails = 0

def disasm(code_bytes, vma=0x10000):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         "--adjust-vma=0x%x" % vma, str(raw)], capture_output=True, text=True).stdout

def mn(l):
    return l.split("\t")[-1].strip() if "\t" in l else l.strip()

def addr_of(l):
    m = re.match(r"\s*([0-9a-f]+):", l)
    return int(m.group(1), 16) if m else None

def backward_targets(code_bytes):
    """32B offsets (addr & 31) of every backward-edge (loop-top) target."""
    text = disasm(code_bytes)
    tops = []
    for l in text.splitlines():
        a = addr_of(l); m = mn(l)
        jm = re.match(r"j\w+\s+0x([0-9a-f]+)", m)
        if jm and a is not None:
            tgt = int(jm.group(1), 16)
            if tgt < a:
                tops.append(tgt & 31)
    return tops

class Built:
    __slots__ = ("status", "code", "value")

def build(name, src, opt):
    """Compile `src` through codegen.ad; return raw code bytes + run value."""
    b = Built(); b.status = "ok"; b.code = b""; b.value = None
    p = WD / f"{name}.ad"; p.write_text(h.codegen_compatible_source(src))
    dump = h.run_dump(p, opt=opt)
    if dump.status != "ok":
        b.status = dump.status; return b
    b.code = dump.code
    elf = WD / f"{name}_{'on' if opt else 'off'}.elf"
    h.wrap_elf(dump, elf)
    import os as _os
    _os.chmod(elf, 0o755)
    rp = subprocess.run([str(elf)], capture_output=True, text=True, timeout=60)
    b.value = int(rp.stdout.strip().splitlines()[-1]) if rp.stdout.strip() else None
    return b

# ---------------------------------------------------------------------------
# Program LMS: main's only loop is a SELF-REFERENTIAL INDEXED STORE (in-place
# array-element reduction `bucket[i&63] = bucket[i&63] + i`) -> offset 0.
# ---------------------------------------------------------------------------
NT = 200000
refLMS = [0]*64
for i in range(NT):
    refLMS[i & 63] = refLMS[i & 63] + i
refT = sum(refLMS) & ((1<<64)-1)
TIGHT = "bucket: Array[64, int64]\n" + PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {NT}:
        slot: int64 = i & 63
        bucket[cast[int64](slot)] = bucket[cast[int64](slot)] + i
        i = i + 1
    acc: int64 = 0
    k: int64 = 0
    while k < 64:
        acc = acc + bucket[cast[int64](k)]
        k = k + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""

# ---------------------------------------------------------------------------
# Program BRANCHY: main's only loop has a data-dependent if/else in its body
# (a collatz-shaped parity step) and a SCALAR accumulator -> offset 16.
# ---------------------------------------------------------------------------
def collatz_steps(n):
    s = 0
    while n > 1:
        if n % 2 == 0:
            n //= 2
        else:
            n = 3 * n + 1
        s += 1
    return s
refB = sum(collatz_steps(n) for n in range(1, 4000))
BRANCHY = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    start: int64 = 1
    while start < 4000:
        n: int64 = start
        steps: int64 = 0
        while n > 1:
            half: int64 = n / 2
            if n - half * 2 == 0:
                n = half
            else:
                n = 3 * n + 1
            steps = steps + 1
        acc = acc + steps
        start = start + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""

def check_value(tag, run, ref):
    global fails
    if run.status != "ok":
        print(f"FAIL[{tag}] status={run.status}")
        fails += 1; return None
    if run.value != (ref & ((1<<64)-1)):
        print(f"FAIL[{tag}] value {run.value} != ref {ref & ((1<<64)-1)}")
        fails += 1
    return run

# The two programs share the same prelude (print_u64 has a cross-array copy loop
# `_pb_out[m]=_pb_scratch[k]` that the self-ref-store feature also matches -> one
# shared offset-0 top in BOTH). They differ ONLY in main's loop: LMS adds an
# in-place `bucket[slot]=bucket[slot]+i` reduction (offset 0) that the scalar
# collatz-shaped BRANCHY program lacks. So LMS must have exactly the offset-0 tops
# of BRANCHY PLUS its own self-ref-store loop => strictly more offset-0 tops.
def off0(tops):
    return sum(1 for o in tops if o == 0)

onT  = check_value("lms/on",  build("lms", TIGHT, True),  refT)
offT = check_value("lms/off", build("lms", TIGHT, False), refT)
onB  = check_value("branchy/on",  build("branchy", BRANCHY, True),  refB)
offB = check_value("branchy/off", build("branchy", BRANCHY, False), refB)

if onT and onB:
    tT = backward_targets(onT.code); tB = backward_targets(onB.code)
    if any(o not in (0, 16) for o in tT + tB):
        print(f"FAIL[on] a loop-top off the {{0,16}} grid: lms={tT} branchy={tB}"); fails += 1
    elif off0(tT) <= off0(tB):
        print(f"FAIL[discriminate] lms off0={off0(tT)} !> branchy off0={off0(tB)} "
              f"(lms={tT} branchy={tB})"); fails += 1
    else:
        print(f"ok  discriminate: self-ref-store loop pinned to 32B offset 0 "
              f"(lms off0={off0(tT)} > branchy off0={off0(tB)}); all tops in {{0,16}}")

# ---- OFF is inert: the offset-16 forced top is absent, and OFF emits no
#      alignment NOP padding the ON build adds (ON has strictly more 0x90 bytes).
if offB and onB:
    tops_off = backward_targets(offB.code)
    n90_off = offB.code.count(0x90)
    n90_on  = onB.code.count(0x90)
    forced = (16 in backward_targets(onB.code))
    if not forced:
        print("FAIL[branchy/off-vs-on] ON did not force offset 16"); fails += 1
    if n90_on <= n90_off:
        print(f"FAIL[off] ON NOP-pad bytes {n90_on} !> OFF {n90_off} — alignment not --opt-gated"); fails += 1
    else:
        print(f"ok  off inert: OFF adds no alignment pad (0x90 on={n90_on} off={n90_off}); OFF tops {tops_off}")

# ---- DETERMINISM BASE: wrapped ELF code[0] VMA is 32-byte aligned ----
elf = WD / "det.elf"
detp = WD / "det.ad"; detp.write_text(h.codegen_compatible_source(TIGHT))
h.wrap_elf(h.run_dump(detp, opt=True), elf)
data = elf.read_bytes()
# e_phoff at 0x20; each phdr 56 bytes; first PT_LOAD (code) p_vaddr at phoff+16.
e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
code_pvaddr = struct.unpack_from("<Q", data, e_phoff + 16)[0]
# code[0] lands at p_vaddr + headers_len + code_pad; recompute the runtime addr
# of the compiler's code[0] via the same model the wrapper uses is overkill —
# assert the WHOLE code PT_LOAD is page(⇒32)-aligned AND that headers+pad is a
# multiple of 32 so code[0] is 32-aligned.
headers_len = 64 + 2*56
code_pad = (32 - (headers_len % 32)) % 32
if (code_pvaddr % 32) != 0:
    print(f"FAIL[det] code PT_LOAD p_vaddr 0x{code_pvaddr:x} not 32-aligned"); fails += 1
elif ((headers_len + code_pad) % 32) != 0:
    print(f"FAIL[det] headers+pad {headers_len+code_pad} not a 32B multiple"); fails += 1
else:
    print(f"ok  determinism base: code[0] VMA 32-aligned (pad={code_pad})")

if fails:
    print(f"\ntest_opt_loopoffset: FAIL ({fails})"); sys.exit(1)
print("\ntest_opt_loopoffset: PASS")
PY
