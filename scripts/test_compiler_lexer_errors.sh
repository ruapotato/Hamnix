#!/usr/bin/env bash
# scripts/test_compiler_lexer_errors.sh — the native front end must REPORT
# what it cannot compile, never discard it.
#
# WHY THIS GATE EXISTS. The native lexer had an error channel that nothing
# read: lex_read_string() returned -1 for an unterminated string / a newline
# inside a string / EOF-in-string and all FOUR of its call sites discarded
# the value; lex_tokenize() returned "-1 or count" and all SEVEN of its
# drivers threw it away. A malformed literal simply never became a token.
# Three more caps (MAX_TOKENS, STRBUF_SIZE, MAX_INDENT) did not even
# detect — they dropped output and returned, so an over-cap source compiled
# to a TRUNCATED program and exited 0. That is the same shape as the
# adjacent-string-literal miscompile, which survived because its feature had
# a fixture and NO GATE.
#
# It also pins four SEED/NATIVE DIVERGENCES. kobjdiff can only compare
# programs both front ends agree to compile, so a construct the seed
# REJECTS and native silently ACCEPTS is invisible to every object-level
# differential we own:
#
#   "a\xZZ"                 native decoded byte 0 -> NUL-terminated literal
#   18446744073709551617    native wrapped to 1
#   @totally_bogus          native compiled it and ignored it
#   xs: List[int32]         native accepted an 8-byte slot
#
# The seed is the ORACLE: for every case below both compilers must reject.
#
# PART C exercises the ON-DEVICE caps. build/cutover/host_ac.elf is fused
# with whole-tree buffer overrides (MAX_TOKENS 4 Mi, STRBUF 16 Mi), so it
# cannot reach them; the on-device drivers keep the on-disk 65536 / 524288.
# Nine files in the tree already exceed 65536 tokens, so on-device
# self-hosting would have silently compiled a PREFIX of the program. Part C
# builds a deliberately SMALL-CAP compiler and proves the caps are loud.
#
# HOST-ONLY: python3 + the seed. NO QEMU. PASS criterion:
#   "[compiler_lexer_errors] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_lexer_errors"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

source scripts/_adder_cc.sh
ADDER_CC=adder PROJ_ROOT="$PROJ_ROOT" adder_cc_bootstrap >/dev/null 2>&1 \
    || { echo "[$TAG] FAIL: host_ac.elf bootstrap failed"; exit 1; }
NATIVE="$PROJ_ROOT/build/cutover/host_ac.elf"

fail=0

# ---------------------------------------------------------------------------
# Part A — every malformed program must be rejected by BOTH front ends.
#
# `name|expected native stderr substring|source` (source uses \n escapes).
# ---------------------------------------------------------------------------
mk() { printf '%b' "$2" > "$WORK/$1.ad"; }

reject_case() {
    local name="$1" want="$2"
    local out rc

    out="$("$NATIVE" --target=x86_64-adder-user "$WORK/$name.ad" \
            "$WORK/$name.o" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[$TAG] FAIL: native ACCEPTED $name (it must be rejected)"
        fail=1
        return
    fi
    case "$out" in
        *"$want"*) ;;
        *) echo "[$TAG] FAIL: native rejected $name but the diagnostic did"
           echo "        not mention '$want'; got: $out"
           fail=1
           return ;;
    esac

    if python3 -m compiler.adder asm --target=x86_64-adder-user -O0 \
            "$WORK/$name.ad" -o "$WORK/$name.s" >/dev/null 2>&1; then
        echo "[$TAG] FAIL: the SEED accepted $name but native rejects it —"
        echo "        a divergence in the OTHER direction; the seed is the"
        echo "        oracle, so re-check the native rule."
        fail=1
        return
    fi
    echo "[$TAG]   reject $name: both front ends agree"
}

# -- lexer error channel (reasons 1-5) --------------------------------------
mk unterminated_eof  'def f() -> int32:\n    s: Ptr[uint8] = "abc'
reject_case unterminated_eof "unterminated string literal"

mk newline_in_string 'def f() -> int32:\n    s: Ptr[uint8] = "abc\n    return 0\n'
reject_case newline_in_string "newline inside string literal"

mk bad_hex_escape    'def f() -> int32:\n    s: Ptr[uint8] = "a\\xZZ"\n    return 0\n'
reject_case bad_hex_escape "hex escape"

mk bad_hex_char_lit  "def f() -> int32:\n    c: uint8 = '\\\\xZg'\n    return 0\n"
reject_case bad_hex_char_lit "hex escape"

mk int_over_64_dec   'def f() -> uint64:\n    return 18446744073709551617\n'
reject_case int_over_64_dec "too large for 64 bits"

mk int_over_64_hex   'def f() -> uint64:\n    return 0x1FFFFFFFFFFFFFFFF\n'
reject_case int_over_64_hex "too large for 64 bits"

# -- codegen acceptance check (reasons 13/14) -------------------------------
mk bogus_decorator   '@totally_bogus\ndef f() -> int32:\n    return 0\n'
reject_case bogus_decorator "unsupported decorator"

mk list_type         'def f() -> int32:\n    xs: List[int32] = 0\n    return 0\n'
reject_case list_type "not implemented"

mk dict_type         'def f() -> int32:\n    d: Dict[int32, int32] = 0\n    return 0\n'
reject_case dict_type "not implemented"

mk optional_param    'def f(x: Optional[int32]) -> int32:\n    return 0\n'
reject_case optional_param "not implemented"

mk tuple_ret         'def f() -> Tuple[int32, int32]:\n    return 0\n'
reject_case tuple_ret "not implemented"

# ---------------------------------------------------------------------------
# Part B — CONTROL: well-formed programs must still compile, on both front
# ends. A rejection rule that also rejects valid code is worse than the bug.
# ---------------------------------------------------------------------------
mk ok_literals 'def f() -> uint64:\n    s: Ptr[uint8] = "a\\x41b\\ttail" "joined"\n    c: uint8 = 65\n    m: uint64 = 18446744073709551615\n    h: uint64 = 0xFFFFFFFFFFFFFFFF\n    o: uint64 = 0o777\n    b2: uint64 = 0b1011\n    return m + cast[uint64](c) + h + o + b2\n@unsafe\ndef g() -> int32:\n    return 0\n'
if ! "$NATIVE" --target=x86_64-adder-user "$WORK/ok_literals.ad" \
        "$WORK/ok_literals.o" >/dev/null 2>&1; then
    echo "[$TAG] FAIL: native REJECTED the well-formed control program"
    "$NATIVE" --target=x86_64-adder-user "$WORK/ok_literals.ad" "$WORK/ok.o" || true
    fail=1
else
    echo "[$TAG]   control: native accepts the well-formed program"
fi
if ! python3 -m compiler.adder asm --target=x86_64-adder-user -O0 \
        "$WORK/ok_literals.ad" -o "$WORK/ok_literals.s" >/dev/null 2>&1; then
    echo "[$TAG] FAIL: the SEED rejected the well-formed control program"
    fail=1
else
    echo "[$TAG]   control: seed accepts the well-formed program"
fi
# The valid \x41 escapes must still decode to 'A' in the emitted object.
if ! strings -a "$WORK/ok_literals.o" | grep -q 'aAb'; then
    echo "[$TAG] FAIL: valid \\x41 escape no longer decodes to 'A'"
    fail=1
fi

# ---------------------------------------------------------------------------
# Part C — the ON-DEVICE caps must be loud, not truncating.
#
# host_ac.elf carries whole-tree overrides so it cannot reach MAX_TOKENS /
# STRBUF_SIZE. Fuse a SMALL-CAP compiler (caps only — the backing arrays stay
# large, so this exercises the exact cap code path the on-device drivers run)
# and feed it sources that cross each cap.
# ---------------------------------------------------------------------------
echo "[$TAG] Part C: building the small-cap compiler (on-device cap paths)"
# The seed's driver requires the input to live under the project root.
mkdir -p "$PROJ_ROOT/build/compiler_lexer_errors"
SMALL_AD="$PROJ_ROOT/build/compiler_lexer_errors/small_compiler.ad"
python3 - "$PROJ_ROOT" "$SMALL_AD" <<'PY'
import sys, importlib.util, os
root, out = sys.argv[1], sys.argv[2]
os.chdir(root)
spec = importlib.util.spec_from_file_location("ccs", "scripts/concat_compiler_source.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.DRIVER_MAIN = "fused_driver_host_main.ad"
rc = m.main(["concat", "-o", out, "--with-driver"])
if rc:
    raise SystemExit(rc)
src = open(out).read()
# Shrink the CAPS ONLY (leave the tok_*/strbuf arrays at whole-tree size, so
# this is a pure test of the cap branches, not of array bounds).
subs = [("MAX_TOKENS: uint32 = 4194304",  "MAX_TOKENS: uint32 = 2048"),
        ("STRBUF_SIZE: uint32 = 16777216", "STRBUF_SIZE: uint32 = 4096"),
        ("MAX_INDENT: uint32 = 64",        "MAX_INDENT: uint32 = 8")]
for a, b in subs:
    if src.count(a) != 1:
        raise SystemExit(f"cap substitution '{a}' matched {src.count(a)} times "
                         f"(expected 1) — the small-cap build has gone blind")
    src = src.replace(a, b)
open(out, "w").write(src)
PY
SMALL_ELF="$WORK/small_ac.elf"
ADDER_X86_LINUX_PIE=1 python3 -m compiler.adder compile \
    --target=x86_64-linux "$SMALL_AD" -o "$SMALL_ELF" >/dev/null 2>&1 \
    || { echo "[$TAG] FAIL: small-cap compiler build failed"; exit 1; }

cap_case() {
    local name="$1" want="$2"
    local out rc
    out="$("$SMALL_ELF" --target=x86_64-adder-user "$WORK/$name.ad" \
            "$WORK/$name.o" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[$TAG] FAIL: the small-cap compiler ACCEPTED $name — the cap is"
        echo "        still silently truncating the program"
        fail=1
        return
    fi
    case "$out" in
        *"$want"*) echo "[$TAG]   cap $name: loud ($want)" ;;
        *) echo "[$TAG] FAIL: $name was rejected but not for the cap; got: $out"
           fail=1 ;;
    esac
}

# > 2048 tokens.
{ echo 'def f() -> int32:'
  echo '    a: int32 = 0'
  for i in $(seq 1 1200); do echo "    a = a + $i"; done
  echo '    return a'
} > "$WORK/cap_tokens.ad"
cap_case cap_tokens "MAX_TOKENS"

# > 4096 bytes of string text (few tokens, lots of strbuf).
python3 - "$WORK/cap_strbuf.ad" <<'PY'
import sys
big = "x" * 6000
open(sys.argv[1], "w").write(
    'def f() -> int32:\n    s: Ptr[uint8] = "%s"\n    return 0\n' % big)
PY
cap_case cap_strbuf "STRBUF_SIZE"

# > 8 levels of indentation.
python3 - "$WORK/cap_indent.ad" <<'PY'
import sys
lines = ["def f(x: int32) -> int32:"]
for d in range(1, 14):
    lines.append("    " * d + "if x > %d:" % d)
lines.append("    " * 14 + "return 1")
lines.append("    return 0")
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
cap_case cap_indent "MAX_INDENT"

# CONTROL for Part C: a small program must still compile with small caps, so
# a blanket "always error" mutation cannot pass this part.
if ! "$SMALL_ELF" --target=x86_64-adder-user "$WORK/ok_literals.ad" \
        "$WORK/small_ok.o" >/dev/null 2>&1; then
    echo "[$TAG] FAIL: the small-cap compiler rejected a small VALID program"
    fail=1
else
    echo "[$TAG]   cap control: small-cap compiler still accepts valid input"
fi

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] FAIL"
    exit 1
fi
echo "[$TAG] PASS"
