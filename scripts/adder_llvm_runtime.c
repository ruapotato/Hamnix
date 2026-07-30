/* scripts/adder_llvm_runtime.c — minimal C runtime for the OPTIONAL Adder LLVM
 * backend (adder/compiler/ssa_llvm.ad, wired into host_ac.elf via
 * --backend=llvm). A whole Adder program lowered to .ll and linked with clang
 * gets its entry (_start -> main) from the C library; this stub supplies the
 * prelude/IO helpers that fall OUTSIDE the SSA integer subset and therefore
 * emit as external `declare`s in the .ll:
 *
 *   print_u64(v) — writes a decimal uint64 + newline to stdout, byte-for-byte
 *                  identical to tests/bench/opt/_prelude.ad's print_u64 (which
 *                  bails: it takes the address of a global array and issues a
 *                  raw write syscall). Returns i64 so the `.ll` ABI
 *                  `declare i64 @print_u64(i64)` matches.
 *
 * Build wrapper: scripts/adder_cc_llvm.sh. */
#include <unistd.h>

/* WEAK: an Adder program that DEFINES print_u64 itself (the differential
 * fuzzer's PRELUDE does, on top of extern sys_write) emits a strong definition
 * in its .ll; this stub must then yield instead of colliding at link time. */
__attribute__((weak)) long print_u64(unsigned long v) {
    char buf[32];
    char tmp[32];
    int n = 0, t = 0;
    if (v == 0) { buf[n++] = '0'; }
    while (v) { tmp[t++] = (char)('0' + (v % 10)); v /= 10; }
    while (t) buf[n++] = tmp[--t];
    buf[n++] = '\n';
    (void)!write(1, buf, n);
    return 0;
}

/* sys_write(fd, buf, count) — the raw-syscall primitive an Adder program
 * declares `extern` and builds its own print_u64 on top of (the differential
 * fuzzer's PRELUDE and tests/fuzz/regress_ptr_signedness.ad both do). It is
 * `extern` in Adder, so the .ll emits `declare i64 @sys_write(i32, ptr, i64)`
 * and the link needs a definition. Without it NO fuzzer-shaped program could
 * be run through the LLVM lane at all — which is why the lane that ships all
 * 272 userland apps had no execution-differential coverage, and why the
 * Ed25519 lshr-for-ashr miscompile reached every binary unseen. */
__attribute__((weak)) long sys_write(int fd, const char *buf, unsigned long count) {
    return (long)write(fd, buf, count);
}
