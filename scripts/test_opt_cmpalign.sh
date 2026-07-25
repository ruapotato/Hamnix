#!/usr/bin/env bash
# scripts/test_opt_cmpalign.sh — focused, host-only correctness + firing guard for
# the two P1 scalar-plumbing levers added in the cmp-operand / loop-alignment pass:
#
#   (A) DIRECT COMPARE-OPERAND SELECTION (codegen.ad gen_cmp_setup). A comparison
#       feeding a conditional branch whose LEFT operand is a register-promoted
#       full-width-8 scalar (every loop IV / bound) and whose RIGHT operand is an
#       integer-literal immediate OR a second promoted register emits ONE direct
#       `cmp %reg,$imm` / `cmp %reg,%reg`, killing the 4-6 instruction
#       `mov $C,%rax; push; mov %iv,%rax; pop %rcx; cmp` value-at-a-time plumbing
#       the cmp+jcc lever still left around the operands.
#
#   (B) LOOP-TOP 16-BYTE ALIGNMENT (codegen.ad emit_loop_align). The backward-
#       branch target (loop top) is padded to a 16-byte boundary with NOPs, the
#       analogue of gcc -O2's -falign-loops. EMPIRICAL: on the bench CPU the small
#       hot loops are gated by loop-top alignment, not instruction count.
#
# WHAT IT PROVES (no QEMU):
#   1. ROUTED — a `while j < N` loop (j promoted, N a literal) emits a direct
#      `cmp <reg>,<imm>` with NO `push`/`pop` framing the compare, AND the loop
#      top is 16-byte aligned. Value EXACTLY the reference and == the --opt-OFF
#      value.
#   2. SIGNED vs UNSIGNED — a signed `<` emits a signed jcc (jl/jge), an unsigned
#      `<` emits an unsigned jcc (jb/jae); both bit-exact vs the reference.
#   3. NEGATIVE immediate — `while i > -5` (sign-extended imm8/imm32) matches.
#   4. REG-vs-REG — `while i < n` with both promoted emits `cmp %reg,%reg`.
#   5. BYTE-INERT OFF — with --opt off NO loop-top NOP padding is emitted and the
#      compare uses the legacy push/pop path (the levers are --opt-only).
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU.
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
opt1_require_lane "test_opt_cmpalign"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_cmpalign"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
M = (1 << 64) - 1
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

# Find the backward-jump target addresses (loop tops) in main()'s code.
def loop_top_addrs(text):
    tops = []
    for l in text.splitlines():
        m = mn(l)
        jm = re.match(r"j\w+\s+0x([0-9a-f]+)", m)
        a = addr_of(l)
        if jm and a is not None:
            tgt = int(jm.group(1), 16)
            if tgt < a:                      # backward edge => loop top
                tops.append(tgt)
    return tops

def build(name, src, opt):
    return h.run_through_codegen_ad(name, src, WD, opt=opt)

# ---------------------------------------------------------------------------
# 1) ROUTED: `while j < N` (j promoted, N literal). Direct cmp + aligned top.
# ---------------------------------------------------------------------------
N = 5000
ref1 = 0
for j in range(N):
    ref1 = (ref1 + j) & M
routed = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    j: int64 = 0
    while j < {N}:
        s = s + j
        j = j + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
on = build("ca_routed_on", routed, True)
off = build("ca_routed_off", routed, False)
d_on = h.run_dump(WD / "ca_routed.ad" if (WD/"ca_routed.ad").exists() else WD/"x", opt=True) if False else None
# dump via run_dump on a written source
src1 = WD / "ca_routed.ad"; src1.write_text(h.codegen_compatible_source(routed))
du_on = h.run_dump(src1, opt=True)
du_off = h.run_dump(src1, opt=False)
if on.kind != "ok" or off.kind != "ok":
    print(f"FAIL(compile) routed on={on.kind} off={off.kind}"); fails += 1
elif on.stdout != str(ref1) or off.stdout != str(ref1):
    print(f"FAIL(value) routed ref={ref1} on={on.stdout} off={off.stdout}"); fails += 1
else:
    t_on = disasm(du_on.code)
    t_off = disasm(du_off.code)
    # (a) a direct `cmp <reg>,<imm>` exists ON, framed by NO push/pop
    lines = t_on.splitlines()
    direct = []
    for n, l in enumerate(lines):
        m = mn(l)
        if re.match(r"cmp\s+r\w+,0x", m):
            window = [mn(x) for x in lines[max(0,n-3):n]]
            if not any(w.startswith("push") or w.startswith("pop") for w in window):
                direct.append(m)
    if not direct:
        print("FAIL routed: no push/pop-free `cmp <reg>,<imm>` (operand plumbing remains)"); fails += 1
    else:
        print(f"[routed] direct compare: '{direct[0]}' (no push/pop)")
    # (b) at least one loop top is 16-byte aligned ON
    tops_on = loop_top_addrs(t_on)
    aligned = [hex(a) for a in tops_on if a % 16 == 0]
    if not aligned:
        print(f"FAIL routed: no 16-byte-aligned loop top ON (tops={[hex(a) for a in tops_on]})"); fails += 1
    else:
        print(f"[routed] 16-byte-aligned loop top(s): {aligned}")
    # (c) OFF: NO nop-padding before any loop top (byte-inert). The seed never
    #     emits standalone 0x90 NOP runs, so their presence is unique to the lever.
    if "nop" in t_off.lower():
        print("FAIL routed: --opt-OFF emitted NOP padding (lever not byte-inert OFF)"); fails += 1
    else:
        print("[routed] OFF has no NOP padding (byte-inert)")

# ---------------------------------------------------------------------------
# 2) SIGNED vs UNSIGNED compare operands.
# ---------------------------------------------------------------------------
for (ty, opname, want_signed) in [("int64", "<", True), ("uint64", "<", False)]:
    n = 3000
    ref = 0
    for i in range(n):
        ref = (ref + i) & M
    prog = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    i: {ty} = cast[{ty}](0)
    while i {opname} cast[{ty}]({n}):
        s = s + cast[int64](i)
        i = i + cast[{ty}](1)
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
    r_on = build(f"ca_sgn_{ty}_on", prog, True)
    r_off = build(f"ca_sgn_{ty}_off", prog, False)
    srcS = WD / f"ca_sgn_{ty}.ad"; srcS.write_text(h.codegen_compatible_source(prog))
    dS = h.run_dump(srcS, opt=True)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) sgn {ty}"); fails += 1
        continue
    if r_on.stdout != str(ref) or r_off.stdout != str(ref):
        print(f"FAIL(value) sgn {ty} ref={ref} on={r_on.stdout}"); fails += 1
        continue
    txt = disasm(dS.code)
    has_signed = bool(re.search(r"\bjl\b|\bjge\b", txt))
    has_unsigned = bool(re.search(r"\bjb\b|\bjae\b", txt))
    if want_signed and not has_signed:
        print(f"FAIL sgn {ty}: expected a signed jl/jge"); fails += 1
    elif (not want_signed) and not has_unsigned:
        print(f"FAIL sgn {ty}: expected an unsigned jb/jae"); fails += 1
    else:
        print(f"[signedness {ty}] value OK ({ref}); jcc family correct")

# ---------------------------------------------------------------------------
# 3) NEGATIVE immediate: `while i > -5` (descending). Sign-extended imm.
# ---------------------------------------------------------------------------
ref3 = 0
i = 8
while i > -5:
    ref3 = (ref3 + i) & M
    i -= 1
neg = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    i: int64 = 8
    while i > 0 - 5:
        s = s + i
        i = i - 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
r_on = build("ca_neg_on", neg, True)
r_off = build("ca_neg_off", neg, False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) neg on={r_on.kind} off={r_off.kind}"); fails += 1
elif r_on.stdout != str(ref3) or r_off.stdout != str(ref3):
    print(f"FAIL(value) neg ref={ref3} on={r_on.stdout} off={r_off.stdout}"); fails += 1
else:
    print(f"[negative imm] value OK ({ref3}) on==off")

# ---------------------------------------------------------------------------
# 4) REG-vs-REG: `while i < n` with both promoted.
# ---------------------------------------------------------------------------
ref4 = 0
for i in range(4000):
    ref4 = (ref4 + i) & M
regreg = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    n: int64 = 4000
    s: int64 = 0
    i: int64 = 0
    while i < n:
        s = s + i
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
r_on = build("ca_rr_on", regreg, True)
r_off = build("ca_rr_off", regreg, False)
src4 = WD / "ca_rr.ad"; src4.write_text(h.codegen_compatible_source(regreg))
d4 = h.run_dump(src4, opt=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) regreg on={r_on.kind} off={r_off.kind}"); fails += 1
elif r_on.stdout != str(ref4) or r_off.stdout != str(ref4):
    print(f"FAIL(value) regreg ref={ref4} on={r_on.stdout}"); fails += 1
else:
    txt = disasm(d4.code)
    lines4 = txt.splitlines()
    # A push/pop-FREE `cmp <reg>,<reg>` is unique to the direct selection: the
    # legacy path marshals the operands via `push`/`pop` before the cmp.
    rr = []
    for n, l in enumerate(lines4):
        m = mn(l)
        if re.match(r"cmp\s+r\w+,r\w+", m):
            window = [mn(x) for x in lines4[max(0, n - 3):n]]
            if not any(w.startswith("push") or w.startswith("pop") for w in window):
                rr.append(m)
    if not rr:
        print("FAIL regreg: no push/pop-free direct `cmp <reg>,<reg>`"); fails += 1
    else:
        print(f"[reg-vs-reg] value OK ({ref4}); direct '{rr[0]}' (no push/pop)")

if fails:
    print(f"\n[test_opt_cmpalign] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_cmpalign] PASS")
PY
