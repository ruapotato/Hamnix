#!/usr/bin/env bash
# scripts/test_arm64_llvm_kernel.sh — Phase A3 host gate for the ARM64 LLVM
# whole-kernel boot lane (docs/arm64_llvm_scoping.md).
#
# Builds the whole-kernel init/main.ad closure through the Adder LLVM backend for
# aarch64, links it against the arch/arm64/llvm/ boot layer into a bootable ELF,
# boots it on `qemu-system-aarch64 -M virt`, and asserts the PL011 serial shows:
#   (1) EL1 entry banner,
#   (2) MMU enabled,
#   (3) the pure emitted Adder leaf fmt_is_flag ran correctly: result "101110",
#   (4) the LLVM-ADDER-OK marker,
#   (5) A4: REAL kernel early-init ran over the PL011-routed 8250 console —
#       start_kernel_early() emitted by LLVM printed the kernel's own boot
#       banner, trap_init, CPU-mitigation + KASLR + sched-init lines, and
#       returned. This is the "runs real kernel init" milestone (past the A3
#       leaf-execution proof). mem_init (real x86 paging) is the A5 boundary.
# A PASS proves the aarch64 image LINKS (0 undefined) and that Adder code emitted
# by the LLVM backend EXECUTES correctly on real aarch64. NOT in the bare-metal
# battery (needs qemu-system-aarch64 + aarch64 binutils + a host_ac with the LLVM
# backend); a runnable host gate only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ELF="build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf"
SERIAL="build/kllvm_arm64/serial_gate.txt"

fail() { echo "[ARM64-LLVM] FAIL $*"; exit 1; }

command -v qemu-system-aarch64 >/dev/null || fail "qemu-system-aarch64 not found"
command -v aarch64-linux-gnu-ld >/dev/null || fail "aarch64 binutils not found"

mkdir -p build/kllvm_arm64   # ensure the log/serial dir exists on a clean checkout

echo "[ARM64-LLVM] building via scripts/build_kernel_llvm_arm64.sh ..."
bash scripts/build_kernel_llvm_arm64.sh "$ELF" >build/kllvm_arm64/build_gate.log 2>&1 \
    || { sed 's/^/[ARM64-LLVM]   | /' build/kllvm_arm64/build_gate.log; fail "build failed"; }
UNDEF="$(aarch64-linux-gnu-nm -u "$ELF" 2>/dev/null | grep -c ' U ')"
[ "$UNDEF" = "0" ] || fail "link left $UNDEF undefined symbols"
echo "[ARM64-LLVM] link: 0 undefined symbols"

echo "[ARM64-LLVM] booting qemu-system-aarch64 -M virt ..."
timeout 40 qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G -nographic -no-reboot \
    -kernel "$ELF" -serial mon:stdio >"$SERIAL" 2>&1
# timeout kills qemu (kernel halts in wfi) -> rc 124 expected.

[ -s "$SERIAL" ] || fail "no serial output"
grep -qa "EL1 entry OK"                 "$SERIAL" || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "no EL1 entry banner"; }
grep -qa "MMU: identity map enabled"    "$SERIAL" || fail "MMU not enabled"
grep -qa "fmt_is_flag\[+,A,0,#,sp,z\]=101110" "$SERIAL" || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "emitted Adder fmt_is_flag result wrong (expected 101110)"; }
grep_llvm_ok() { grep -qa "LLVM-ADDER-OK" "$SERIAL"; }
grep_llvm_ok || fail "no LLVM-ADDER-OK marker"
# A4 assertions: real kernel early-init (start_kernel_early) over PL011.
grep_a4() { grep -qa "$1" "$SERIAL"; }
grep_a4 "Hamnix kernel booting"           || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A4: kernel printk banner not seen"; }
grep_a4 "Hamnix: trap_init done"          || fail "A4: trap_init not reached"
grep_a4 "Hamnix: early cpu/sched init done" || fail "A4: early cpu/sched init not reached"
grep_a4 "A4: start_kernel_early returned" || fail "A4: start_kernel_early did not return cleanly"
# A5 assertions: aarch64 mem_init port (memblock -> buddy -> slab, skipping the
# x86 CR3/PML4 page-table work) + the arch-neutral MM/slab smoke proofs. This is
# the "meaningfully PAST mem_init" milestone (docs/arm64_llvm_scoping.md A5).
grep_a5() { grep -qa "$1" "$SERIAL"; }
grep_a5 "\[arm64-mm\] memblock region base=0x0000000050000000" || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A5: aarch64 memblock region not installed"; }
grep_a5 "\[cow\] refcount table"                || fail "A5: cow_init did not run (mem_init port)"
grep_a5 "\[arm64-mm\] mem_init_arm64 done"      || fail "A5: mem_init_arm64 (buddy+slab) did not complete"
grep_a5 "\[buddy-coalesce\] PASS"               || fail "A5: buddy allocator coalesce test did not PASS"
grep_a5 "\[pa-stress\] PASS"                     || fail "A5: page_alloc stress test did not PASS"
grep_a5 "A5: mm/slab smoke tests done"          || fail "A5: mm/slab smoke tests did not complete"
grep_a5 "A5: start_kernel_mem_arm64 returned"   || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A5: start_kernel_mem_arm64 did not return cleanly"; }

# A6 assertions: (1) the post-MM init slices (rcu/sched/softirq/workqueue) run
# past the A5 MM boundary as emitted LLVM Adder code, and (2) GICv2 + the ARM
# generic timer are brought up and the FIRST SCHEDULER TICK fires + is handled by
# the emitted-Adder tick handler arm64_do_timer_tick() (docs/arm64_llvm_scoping.md
# A6). A fault in any slice dumps ESR_EL1/ELR_EL1 via the vectors.S diagnostic.
grep_a6() { grep -qa "$1" "$SERIAL"; }
grep_a6 "A6: rcu_init done"                     || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A6: rcu_init did not complete"; }
grep_a6 "A6: sched_init done"                   || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A6: sched_init did not complete"; }
grep_a6 "A6: softirq_init done"                 || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A6: softirq_init did not complete"; }
grep_a6 "A6: workqueue_init done"               || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A6: workqueue_init did not complete"; }
grep_a6 "A6: start_kernel_post_mm_arm64 returned" || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A6: post-MM init slice did not return cleanly"; }
grep_a6 "\[arm64-llvm\] scheduler timer tick 1"  || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A6: FIRST timer tick never fired/handled"; }
grep_a6 "\[arm64-llvm\] timer IRQ OK"            || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A6: periodic timer tick did not reach the handler completion marker"; }

# A7 assertions: EL0 (user-mode) drop + `svc #0` syscall dispatch — the "RUNS
# USERSPACE" milestone (docs/arm64_llvm_scoping.md A7). head.S erets to EL0 and a
# tiny user program issues write(1,...) then exit(0) via `svc #0`; each svc traps
# to the vectors.S Lower-EL AArch64 synchronous slot (0x400) ->
# arm64_llvm_lower_sync_entry -> the emitted-Adder dispatcher
# arm64_svc_dispatch_arm64(), which services the syscall and returns. The svc
# reaching the LOWER-EL vector (not the Current-EL halt handler) proves the code
# genuinely executed at EL0. A fault dumps ESR_EL1/ELR_EL1 via vectors.S.
grep_a7() { grep -qa "$1" "$SERIAL"; }
grep_a7 "A7: dropping to EL0"                          || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A7: EL0 launch marker not seen"; }
grep_a7 "EL0 svc #0: write syscall entered"           || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A7: EL0 write svc did not reach the Adder dispatcher"; }
grep_a7 "HELLO-FROM-EL0-USERSPACE via svc #0"         || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A7: EL0 user write buffer was not emitted by the kernel"; }
grep_a7 "EL0 write syscall serviced"                  || fail "A7: write syscall not serviced"
grep_a7 "EL0 exit syscall serviced (status=0)"        || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A7: EL0 exit svc not serviced"; }
grep_a7 "A7: EL0 task exited, returned to kernel"     || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A7: EL0 svc round-trip did not return cleanly to the kernel"; }
# No EL0 access should have faulted into the diagnostic vector.
grep -qa "^EXC esr=" "$SERIAL" && { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "A7: an exception hit the diagnostic vector (unexpected fault)"; }

echo "[ARM64-LLVM] serial (furthest point):"
grep -a . "$SERIAL" | grep -vi terminating | sed 's/^/[ARM64-LLVM]   | /'
echo "[ARM64-LLVM] PASS"
