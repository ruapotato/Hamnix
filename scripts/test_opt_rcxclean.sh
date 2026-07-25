#!/usr/bin/env bash
# scripts/test_opt_rcxclean.sh — focused, host-only correctness + firing guard for
# the STORE-VALUE ROUND-TRIP ELISION (codegen.ad index_store_addr_rcx_clean).
# Armed only under --opt; byte-identical to the frozen seed OFF.
#
# THE LEVER: a self-referential in-place indexed store `arr[i] = <expr>` (licm's
# bucket[slot]=…, saxpy's ys[i]=…) computes the RHS into %rax, then must store it at
# &arr[i]. The address computation clobbers %rax, so the legacy path PARKS the value
# on the stack: `push %rax ; <addr>->%rax ; pop %rcx ; mov %rcx,(%rax)`. When the
# element address is a DIRECT-SIB lea (%rcx-clean — a bare-ident flat array/ptr base
# + a register-promoted index, so gen_index_addr never touches %rcx/%rdx), the value
# is instead held in %rcx via a reg-reg `mov %rax,%rcx` — one fewer instruction AND
# zero stack memory traffic per iteration:
#     mov %rax,%rcx ; <addr>->%rax ; mov %rcx,(%rax)
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + MATCHES OFF: licm/saxpy-shaped self-ref stores, a plain non-binop
#      store, and a sub-8-byte self-ref store all produce EXACTLY the reference
#      value under --opt AND equal the --opt-OFF value.
#   2. THE STACK ROUND-TRIP IS GONE: in the ON disassembly the store epilogue is
#      `mov rcx,rax ; lea …,rax ; mov [rax],rcx` with NO `push`/`pop` around the
#      address lea for that access.
#   3. FIRED + BYTE-INERT OFF: RCXCLEAN>0 under --opt; RCXCLEAN==0 with --opt off.
#   4. SAFETY (the rcx-clean gate is load-bearing): the deliberate break
#      (--rcxclean-break, which claims EVERY address is rcx-clean) miscompiles a
#      BINARY-index store (`arr[i+1]=v`, whose index computation goes through %rcx
#      and clobbers the parked value) — the differential corpus catches it — while
#      the binary-index FALLBACK stays correct on the legacy path unbroken.
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU. The cached dump
# driver under build/fuzz_ad_codegen AUTO-INVALIDATES on any compiler change.
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
opt1_require_lane "test_opt_rcxclean"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_rcxclean"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# ---------------------------------------------------------------------------
# A saxpy-shaped self-referential in-place reduction over a bare register index.
# ---------------------------------------------------------------------------
n = 256
ys = [(i * 5 + 1) % 97 for i in range(n)]
xs = [(i * 3 + 7) % 101 for i in range(n)]
for _ in range(6):
    for i in range(n):
        ys[i] = (ys[i] + 3 * xs[i]) & M
ref = 0
for i in range(n):
    ref = (ref + ys[i]) & M

SRC = PRELUDE + f"""
xs: Array[{n}, int64]
ys: Array[{n}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        xs[cast[int64](i)] = (i * 3 + 7) % 101
        ys[cast[int64](i)] = (i * 5 + 1) % 97
        i = i + 1
    a: int64 = 3
    reps: int64 = 0
    while reps < 6:
        i = 0
        while i < {n}:
            ys[cast[int64](i)] = ys[cast[int64](i)] + a * xs[cast[int64](i)]
            i = i + 1
        reps = reps + 1
    acc: int64 = 0
    i = 0
    while i < {n}:
        acc = acc + ys[cast[int64](i)]
        i = i + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""

r_on = h.run_through_codegen_ad("rcx_on", SRC, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("rcx_off", SRC, WD, opt=False, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) on={r_on.kind}/off={r_off.kind} "
          f"{(r_on.detail or r_off.detail)[:160]}")
    sys.exit(1)

# (1) correctness ON==OFF==ref
if r_on.stdout != str(ref) or r_off.stdout != str(ref):
    print(f"FAIL(value) ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
else:
    print(f"[value] on==off==ref ({ref}) OK")

# (3) fired + byte-inert OFF
rc_on = int(getattr(r_on, "rcxclean", 0) or 0)
rc_off = int(getattr(r_off, "rcxclean", 0) or 0)
if rc_on < 1:
    print(f"FAIL(no-fire) rcxclean_on={rc_on} (the self-ref store did not elide)")
    fails += 1
elif rc_off != 0:
    print(f"FAIL(off-fired) rcxclean_off={rc_off} (must be 0 — byte-inert OFF)")
    fails += 1
else:
    print(f"[fire] rcxclean_on={rc_on} rcxclean_off=0 OK")

# (2) DISASM: the store epilogue has NO push/pop around the address lea.
def disasm(dump):
    raw = WD / "rcx.code.bin"; raw.write_bytes(dump.code)
    txt = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout
    rows = []
    for ln in txt.splitlines():
        mm = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)$", ln)
        if mm:
            rows.append(mm.group(2).strip())
    return rows

try:
    dsrc = WD / "rcx_dump.ad"
    dsrc.write_text(h.codegen_compatible_source(SRC))
    d_on = h.run_dump(dsrc, opt=True)
    if d_on.status != "ok":
        raise RuntimeError(f"run_dump status={d_on.status} "
                           f"{getattr(d_on, 'detail', '')[:160]}")
    rows = disasm(d_on)
    # The elided store epilogue: `mov rcx,rax` then a scaled-index `lea rax,[..]`
    # then `mov [rax],rcx`, with NO `push`/`pop` between the mov and the store.
    found = 0
    for k, t in enumerate(rows):
        if not re.match(r"mov\s+rcx,rax", t):
            continue
        win = rows[k:k+4]
        if any(re.match(r"lea\s+rax,\[", w) for w in win) and \
           any(re.match(r"mov\s+(?:\w+ PTR )?\[rax\],[re]?[cl]x?", w) for w in win) and \
           not any(re.match(r"(push|pop)\b", w) for w in win):
            found += 1
    if found < 1:
        print(f"FAIL(disasm) no push/pop-free store epilogue found "
              f"(mov rcx,rax; lea; mov [rax],rcx)"); fails += 1
    else:
        print(f"[disasm] {found} store epilogue(s) hold the value in %rcx with NO "
              f"stack push/pop round-trip OK")
except Exception as ex:
    print(f"FAIL(disasm) exception: {ex}"); fails += 1

# (4) SAFETY: the differential corpus (self-ref/plain/sub-8 fire + correct, binary-
#     index fallback correct, and the --rcxclean-break deliberate break CAUGHT).
rc_ok, rc_total, rc_brk = F._run_rcxclean_corpus()
if not rc_ok:
    print(f"FAIL(corpus) rcxclean differential corpus miscompiled / inert")
    fails += 1
elif not rc_brk:
    print(f"FAIL(break) the --rcxclean-break deliberate break was NOT caught "
          f"(the rcx-clean gate is not proven load-bearing)")
    fails += 1
else:
    print(f"[corpus] rcxclean corpus OK ({rc_total} elisions, fallback correct, "
          f"deliberate break caught)")

if fails:
    print(f"\n[test_opt_rcxclean] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_rcxclean] PASS (store value held in %rcx, no stack round-trip, "
      "correct, fired, byte-inert OFF, break caught)")
PY
