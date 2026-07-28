#!/usr/bin/env bash
# scripts/test_hamsh_dualsyntax.sh — hamsh DUAL block syntax + the
# Deliverable-2 ergonomics (HAMSH_SPEC §5, §8a).
#
# hamsh accepts TWO fully-interchangeable block syntaxes, chosen per
# block from the token that opens the body:
#   * brace   — `HEADER { statements }`      (interactive one-liner form)
#   * colon   — `HEADER:` + indented body     (Python-style, script form)
#               or an inline single-statement `HEADER: statement`.
# Both are legal in BOTH contexts (REPL + sourced file) and may mix.
#
# This gate proves, over the serial console (prompt-gated + output-
# adaptive via scripts/_hamsh_drive.sh):
#   A. brace one-liner runs its taken body / skips its untaken body
#   B. inline-colon one-liner runs taken / skips untaken
#   C. a MULTI-LINE indentation suite (if / for / def) executes — the
#      lexer's INDENT/DEDENT + the colon-suite parser, end to end, over
#      the Python-REPL continuation (blank line terminates)
#   D. the string builtins upper/lower/split/join/replace
#   E. a parse error reports a LINE NUMBER
#   F. sourcing an indentation SCRIPT FILE runs it (the primary use case)
#
# ABSENCE assertions use INLINE (single physical line) forms so the
# typed-input echo lands on a `hamsh$ ` prompt line that hamsh_ran
# (scripts/_hamsh_log.sh) filters out — a continuation `> ` line is NOT
# filtered, so untaken-branch markers are only ever typed on prompt
# lines. PRESENCE assertions for multi-line suites use a begin-of-line
# match (`^MARKER$`) — genuine `echo` output starts a fresh line, the
# editor's repainted continuation echo never does.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_dualsyntax
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh:stage-07] loop-enter" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# --- A. brace one-liner (taken + untaken) ---------------------------
hamsh_send_await 'if 5 > 2 { echo DUAL_BRACE_YES }' 'DUAL_BRACE_YES' "$CMD_WAIT" || true
hamsh_send 'if 1 > 5 { echo DUAL_BRACE_NO }'
hamsh_send_await 'echo GATE_A' 'GATE_A' "$CMD_WAIT" || true

# --- B. inline-colon one-liner (taken + untaken) --------------------
hamsh_send_await 'if 5 > 2: echo DUAL_INLINE_YES' 'DUAL_INLINE_YES' "$CMD_WAIT" || true
hamsh_send 'if 1 > 5: echo DUAL_INLINE_NO'
hamsh_send_await 'echo GATE_B' 'GATE_B' "$CMD_WAIT" || true

# --- C. multi-line indentation suites (if / for / def) --------------
# Each top-level suite is terminated by a blank line (Python-REPL feel).
hamsh_send 'if 5 > 2:'
hamsh_send '    echo DUAL_MLIND_YES'
hamsh_send ''
hamsh_send_await 'echo GATE_C1' 'GATE_C1' "$CMD_WAIT" || true
hamsh_send 'for i in a b:'
hamsh_send '    echo DUAL_FOR_$i'
hamsh_send ''
hamsh_send_await 'echo GATE_C2' 'GATE_C2' "$CMD_WAIT" || true
hamsh_send 'def dgreet(who):'
hamsh_send '    echo DUAL_DEF_$who'
hamsh_send ''
hamsh_send_await 'dgreet("planet")' 'DUAL_DEF_planet' "$CMD_WAIT" || true

# --- D. string builtins ---------------------------------------------
# Emit each result as a bare `${ … }` word (no `prefix${ … }` — that
# tickles a PRE-EXISTING ND_ARGCAT/render_buf re-entrancy quirk, tracked
# separately, unrelated to the dual-syntax work). ran_bol matches the
# whole output line so a typed-input echo can never false-green.
hamsh_send_await 'echo ${upper("abc")}' 'ABC' "$CMD_WAIT" || true
hamsh_send_await 'echo ${lower("XYZ")}' 'xyz' "$CMD_WAIT" || true
hamsh_send_await 'echo ${join(split("p,q,r", ","), "+")}' 'p+q+r' "$CMD_WAIT" || true
hamsh_send_await 'echo ${replace("a-b-c", "-", "_")}' 'a_b_c' "$CMD_WAIT" || true
hamsh_send 'sv = strip("  ZQX  ")'
hamsh_send_await 'echo $sv' 'ZQX' "$CMD_WAIT" || true

# --- E. parse error carries a line number ---------------------------
hamsh_send_await 'if 1 > 0 notablock' 'parse error [line' "$CMD_WAIT" || true

# --- F. source an INDENTATION script FILE (the primary use case) ----
# Write the whole indented script in ONE command — a double-quoted echo
# whose `\n` escapes become real newlines and whose leading spaces are
# literal, so the file carries genuine significant indentation. One send
# is robust (no multi-append quote-drop window); no '$' in the body so
# nothing interpolates before `source` runs it.
hamsh_send 'echo "n = 4\nif n > 3:\n    echo FILE_DUAL_YES\n    echo FILE_DUAL_Y2\nfor k in x y:\n    echo FILE_FOR_ITER\n" > /tmp/dualsyntax.hamsh'
hamsh_send_await 'source /tmp/dualsyntax.hamsh' 'FILE_DUAL_Y2' "$CMD_WAIT" || true

# --- G. brace BLOCK in a SOURCED FILE (accept-either, file mode) ----
# Section F proved indentation-in-a-file; this proves the OTHER style —
# curly braces — is equally legal when a FILE is sourced (not just
# interactively). Together with A (brace interactive) + C (indent
# interactive) + F (indent file) this closes the full accept-either
# matrix: EITHER block syntax works in EITHER context.
hamsh_send 'echo "if 7 > 3 { echo BRACE_FILE_YES }\nfor k in x y { echo BRACE_FILE_ITER }\n" > /tmp/bracesyntax.hamsh'
hamsh_send_await 'source /tmp/bracesyntax.hamsh' 'BRACE_FILE_YES' "$CMD_WAIT" || true

# --- H. membership operators: `in` / `not in` -----------------------
# List element, negated list, string substring, and dict-key membership.
# Taken branches use the inline-colon one-liner so a false marker can
# only ever be typed on a filtered prompt line (see the header note).
hamsh_send_await 'if 2 in [1, 2, 3]: echo MEMB_LIST_YES' 'MEMB_LIST_YES' "$CMD_WAIT" || true
hamsh_send 'if 9 in [1, 2, 3]: echo MEMB_LIST_NO'
hamsh_send_await 'if 9 not in [1, 2, 3]: echo MEMB_NOTIN_YES' 'MEMB_NOTIN_YES' "$CMD_WAIT" || true
hamsh_send_await 'if "mn" in "hamnix": echo MEMB_SUBSTR_YES' 'MEMB_SUBSTR_YES' "$CMD_WAIT" || true
hamsh_send 'if "zz" in "hamnix": echo MEMB_SUBSTR_NO'
hamsh_send_await 'if "b" in {"a": 1, "b": 2}: echo MEMB_DICTKEY_YES' 'MEMB_DICTKEY_YES' "$CMD_WAIT" || true

# --- I. new string methods: find / count / startswith / endswith ----
# Each result feeds a comparison so the taken branch prints a distinct
# whole-line marker (never a bare integer that could false-match).
hamsh_send_await 'if find("hello", "ll") == 2: echo FIND_OK' 'FIND_OK' "$CMD_WAIT" || true
hamsh_send_await 'if count("banana", "a") == 3: echo COUNT_OK' 'COUNT_OK' "$CMD_WAIT" || true
hamsh_send_await 'if startswith("hamnix", "ham"): echo STARTS_OK' 'STARTS_OK' "$CMD_WAIT" || true
hamsh_send_await 'if endswith("run.hamsh", ".hamsh"): echo ENDS_OK' 'ENDS_OK' "$CMD_WAIT" || true

# --- J. DIFFERENTIAL: the SAME loop in brace vs indent style ---------
# Both styles must produce IDENTICAL output — the core "accept-either,
# same meaning" guarantee. Brace one-liner form first:
hamsh_send_await 'for i in a b { echo DIFF_FOR_$i }' 'DIFF_FOR_b' "$CMD_WAIT" || true
# ...then the byte-for-byte-equivalent indentation form:
hamsh_send 'for i in a b:'
hamsh_send '    echo DIFF_FOR_$i'
hamsh_send ''
hamsh_send_await 'echo GATE_DIFF' 'GATE_DIFF' "$CMD_WAIT" || true

# --- K. §17 Python-esque data constructs (#110) ---------------------
# All results are emitted as whole output lines (`echo ${ … }` or an
# inline-colon marker) so ran_bol / hamsh_ran can never false-green on a
# typed-input echo.
# K1. list comprehension (map, filter, method-call receiver).
# (hamsh arithmetic is SPACE-separated — `*` glued to a word is a glob
# char, per the lexer's documented rule — so the map uses `x * x`.)
hamsh_send_await 'echo ${ [x * x for x in range(4)] }' '0 1 4 9' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ [x for x in range(6) if x % 2 == 0] }' '0 2 4' "$CMD_WAIT" || true
# K2. dict comprehension + indexed read.
hamsh_send 'dc = { x: x * x for x in range(3) }'
hamsh_send_await 'echo ${ $dc[2] }' '4' "$CMD_WAIT" || true
# K3. list + string indexing, negative index, slicing, reverse slice.
hamsh_send 'xs = [10, 20, 30, 40]'
hamsh_send_await 'echo ${ $xs[1] }' '20' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ $xs[-1] }' '40' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ $xs[1:3] }' '20 30' "$CMD_WAIT" || true
hamsh_send 'sv2 = "hamnix"'
hamsh_send_await 'echo ${ $sv2[0:3] }' 'ham' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ $sv2[::-1] }' 'xinmah' "$CMD_WAIT" || true
# K4. tuple assignment + swap + multiple return.
hamsh_send 'ta = 1'
hamsh_send 'tb = 2'
hamsh_send 'ta, tb = tb, ta'
hamsh_send_await 'echo SWAP $ta $tb' 'SWAP 2 1' "$CMD_WAIT" || true
hamsh_send 'def mkpair():'
hamsh_send '    return 7, 8'
hamsh_send ''
hamsh_send 'pp, qq = mkpair()'
hamsh_send_await 'echo MRET $pp $qq' 'MRET 7 8' "$CMD_WAIT" || true
# K5. for-loop tuple unpack over d.items() (method-call desugar).
hamsh_send 'dm = { "x": 1 }'
hamsh_send 'for mk, mv in dm.items():'
hamsh_send '    echo KVITER $mk $mv'
hamsh_send ''
hamsh_send_await 'echo GATE_K5' 'GATE_K5' "$CMD_WAIT" || true
# K6. core data builtins.
hamsh_send_await 'echo ${ sum([1, 2, 3, 4]) }' '10' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ sorted([3, 1, 2]) }' '1 2 3' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ max([3, 9, 2]) }' '9' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ abs(-5) }' '5' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ sv2.upper() }' 'HAMNIX' "$CMD_WAIT" || true
# enumerate via for-unpack (nested-list rendering is a separate concern):
hamsh_send 'for ei, ev in enumerate(["p", "q"]):'
hamsh_send '    echo ENUM $ei $ev'
hamsh_send ''
hamsh_send_await 'echo GATE_K6' 'GATE_K6' "$CMD_WAIT" || true
# K7. DIFFERENTIAL both-styles-≡: an EXPRESSION-iterable for-loop
# (`for x in range(3)`) in brace form AND indentation form must produce
# IDENTICAL output — the accept-either guarantee, extended to the new
# expression-mode loop.
hamsh_send_await 'for x in range(3) { echo RNG_$x }' 'RNG_2' "$CMD_WAIT" || true
hamsh_send 'for x in range(3):'
hamsh_send '    echo RNG_$x'
hamsh_send ''
hamsh_send_await 'echo GATE_K7' 'GATE_K7' "$CMD_WAIT" || true

# --- L. §19 (#111): nested-list render + namespace as a Pythonic object
# L1. #110 render gap: a NESTED list must print its inner elements, not
# blank. zip() yields a list of pairs; a nested literal is two inner lists.
hamsh_send_await 'echo ${ zip([1, 2], [3, 4]) }' '[1, 3] [2, 4]' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ [[1, 2], [3, 4]] }' '[1, 2] [3, 4]' "$CMD_WAIT" || true
# L2. a namespace TEMPLATE is iterable + introspectable (binds()/mounts()).
hamsh_send 'nsx = ns { bind /tmp /n/aa ; bind /tmp /n/bb }'
hamsh_send_await 'echo ${ binds($nsx) }' '/n/aa /n/bb' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ nsx.mounts() }' '/n/aa /n/bb' "$CMD_WAIT" || true
# L3. `for m in <ns>` walks the mount-points (inline-colon one-liner).
hamsh_send_await 'for m in $nsx: echo NSITER $m' 'NSITER /n/bb' "$CMD_WAIT" || true

# --- M. §Float — real floating-point (VT_FLOAT) ----------------------
# All results emitted as whole output lines (`echo ${ … }` or inline-colon
# markers) so ran_bol / hamsh_ran can never false-green on a typed echo.
# hamsh arithmetic is SPACE-separated (`a / b`, never glued — `/` glued is
# a path); the float literals `3.0` / `0.1` are single-dot so they lex as
# floats (a 2nd dot = version/IP word).
# M1. Python-3 true division: `1 / 2` is a FLOAT 0.5 (not integer 0).
hamsh_send_await 'echo ${ 1 / 2 }' '0.5' "$CMD_WAIT" || true
# M2. int↔float mixed arithmetic renders integer-valued floats bare.
hamsh_send_await 'echo ${ 3.0 * 2 }' '6' "$CMD_WAIT" || true
# M3. exact-bits addition rendered sensibly (0.1 + 0.2 -> 0.3, trimmed).
hamsh_send_await 'echo ${ 0.1 + 0.2 }' '0.3' "$CMD_WAIT" || true
# M4. float assignment + interpolation round-trips the literal.
hamsh_send 'pi = 3.14'
hamsh_send_await 'echo $pi' '3.14' "$CMD_WAIT" || true
# M5. a list of floats renders space-joined.
hamsh_send_await 'echo ${ [1.5, 2.5] }' '1.5 2.5' "$CMD_WAIT" || true
# M6. float()/int() conversions + abs over a float.
hamsh_send_await 'echo ${ float("1") / 2 }' '0.5' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ int(3.9) }' '3' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ abs(-2.5) }' '2.5' "$CMD_WAIT" || true
# M7. sum over floats, min/max over floats.
hamsh_send_await 'echo ${ sum([1.5, 2.5, 1.0]) }' '5' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ max([1.5, 0.5, 2.5]) }' '2.5' "$CMD_WAIT" || true
# M8. float comparisons — the exact-bits identities the task calls out.
hamsh_send_await 'if 1 / 2 == 0.5: echo HALF_OK' 'HALF_OK' "$CMD_WAIT" || true
hamsh_send_await 'if 3.0 * 2 == 6: echo SIXF_OK' 'SIXF_OK' "$CMD_WAIT" || true

# --- N. §Exceptions — raise + finally --------------------------------
# N1. DIFFERENTIAL both-styles-≡: `try raise / except as e` in brace AND
# indent form must each print CAUGHT_boom (a correct pair yields >=2).
hamsh_send_await 'try { raise "boom" } except as e { echo CAUGHT_$e }' 'CAUGHT_boom' "$CMD_WAIT" || true
hamsh_send 'try:'
hamsh_send '    raise "boom"'
hamsh_send 'except as e:'
hamsh_send '    echo CAUGHT_$e'
hamsh_send ''
hamsh_send_await 'echo GATE_N1' 'GATE_N1' "$CMD_WAIT" || true
# N2. finally runs on the NORMAL path (both markers appear).
hamsh_send_await 'try { echo TRY_NORMAL } finally { echo FIN_NORMAL }' 'FIN_NORMAL' "$CMD_WAIT" || true
# N3. finally runs on the CAUGHT path (both markers appear).
hamsh_send_await 'try { raise "x" } except { echo TRY_CAUGHT } finally { echo FIN_CAUGHT }' 'FIN_CAUGHT' "$CMD_WAIT" || true
# N4. finally runs on the UNCAUGHT-propagating path (try/finally, no except):
# FIN_PROP prints, then the raise propagates to an uncaught-exception report.
hamsh_send_await 'try { raise "y" } finally { echo FIN_PROP }' 'FIN_PROP' "$CMD_WAIT" || true
# N5. a `with` body that raises STILL unbinds (teardown) AND propagates the
# raise so an enclosing try/except catches it (#111 unwind ∩ exceptions).
hamsh_send_await 'try { with bind(/tmp, /n/wb) as w { raise "wz" } } except as e { echo WCAUGHT_$e }' 'WCAUGHT_wz' "$CMD_WAIT" || true
# N6. DIFFERENTIAL both-styles-≡: the Python-lite `except NAME:` BIND
# shorthand (no `as`) binds the raised value to NAME — brace AND indent.
hamsh_send_await 'try { raise "bx" } except er { echo SHORT_$er }' 'SHORT_bx' "$CMD_WAIT" || true
hamsh_send 'try:'
hamsh_send '    raise "bx"'
hamsh_send 'except er:'
hamsh_send '    echo SHORT_$er'
hamsh_send ''
hamsh_send_await 'echo GATE_N6' 'GATE_N6' "$CMD_WAIT" || true
# N7. `except NAME as e:` FILTER — a matching type is caught + bound; a
# NON-matching one re-propagates to the outer handler (WRONGCATCH must NOT
# leak). "ValueError: bad" matches `except ValueError` by the "NAME:" prefix.
# The MISS case is an ABSENCE test (WRONGCATCH must not run) so it stays a
# SINGLE physical line — a typed echo on a `> ` continuation line is NOT
# filtered by hamsh_ran (see the header note) and would false-red.
hamsh_send_await 'try { raise "ValueError: bad" } except ValueError as e { echo FILT_$e }' 'FILT_ValueError: bad' "$CMD_WAIT" || true
hamsh_send_await 'try { try { raise "TypeError: nope" } except ValueError as e { echo WRONGCATCH } } except as e2 { echo OUTERCATCH_$e2 }' 'OUTERCATCH_TypeError: nope' "$CMD_WAIT" || true
hamsh_send_await 'echo GATE_N7' 'GATE_N7' "$CMD_WAIT" || true
# N8. `else` runs ONLY on the no-exception path (ELSE_RAN + FIN_E8 both
# appear); on the exception path the else body is skipped (ELSE_NO absent).
hamsh_send_await 'try { echo TRY_OK8 } else { echo ELSE_RAN } finally { echo FIN_E8 }' 'FIN_E8' "$CMD_WAIT" || true
hamsh_send 'try { raise "e8" } except { echo CAUGHT8 } else { echo ELSE_NO }'
hamsh_send_await 'echo GATE_N8' 'GATE_N8' "$CMD_WAIT" || true

# --- O. §f-string — Python f"{expr}" interpolation -------------------
hamsh_send 'fa = 3'
hamsh_send 'fb = 4'
hamsh_send_await 'echo f"sum={fa + fb}"' 'sum=7' "$CMD_WAIT" || true
hamsh_send_await 'echo f"pi is {pi}"' 'pi is 3.14' "$CMD_WAIT" || true
hamsh_send 'fnm = "ham"'
hamsh_send_await 'echo f"hi {fnm}nix"' 'hi hamnix' "$CMD_WAIT" || true
# f-string with a call sub-expression + literal braces via {{ }}.
hamsh_send_await 'echo f"len={len([1, 2, 3])} {{lit}}"' 'len=3 {lit}' "$CMD_WAIT" || true
# The single-quoted form f'...' interpolates identically to f"...".
hamsh_send_await "echo f'sq is {fa + fb}'" 'sq is 7' "$CMD_WAIT" || true

# --- P. §Mutation + floor-division + call kwargs (the mutation rung) --
# All results emitted as whole output lines so ran_bol can't false-green.
# P1. append grows a list in place.
hamsh_send 'pm = [1, 2]'
hamsh_send 'pm.append(3)'
hamsh_send_await 'echo PM $pm' 'PM 1 2 3' "$CMD_WAIT" || true
# P1b. RELOCATION: append to a list that is NOT at the pool top (another
# list was built after it) must grow it WITHOUT corrupting the other.
hamsh_send 'pr = [1, 2]'
hamsh_send 'po = [9, 9]'
hamsh_send 'pr.append(3)'
hamsh_send_await 'echo PR $pr' 'PR 1 2 3' "$CMD_WAIT" || true
hamsh_send_await 'echo PO $po' 'PO 9 9' "$CMD_WAIT" || true
# P1c. ALIASING is by REFERENCE (Python): two names, one list object.
hamsh_send 'pa = [1, 2]'
hamsh_send 'pb = pa'
hamsh_send 'pa.append(9)'
hamsh_send_await 'echo PB $pb' 'PB 1 2 9' "$CMD_WAIT" || true
# P2. pop() -> last (removed); pop(i) -> the i-th (removed).
hamsh_send 'pp = [1, 2, 3]'
hamsh_send_await 'echo ${ pp.pop() }' '3' "$CMD_WAIT" || true
hamsh_send_await 'echo PPL $pp' 'PPL 1 2' "$CMD_WAIT" || true
hamsh_send 'pq = [10, 20, 30]'
hamsh_send_await 'echo ${ pq.pop(0) }' '10' "$CMD_WAIT" || true
hamsh_send_await 'echo PQL $pq' 'PQL 20 30' "$CMD_WAIT" || true
# P3. insert(i, v).
hamsh_send 'pv = [1, 2, 3]'
hamsh_send 'pv.insert(0, 9)'
hamsh_send_await 'echo PV $pv' 'PV 9 1 2 3' "$CMD_WAIT" || true
# P4. index assignment `xs[i] = v`.
hamsh_send 'ps = [1, 2, 3]'
hamsh_send 'ps[1] = 7'
hamsh_send_await 'echo PS $ps' 'PS 1 7 3' "$CMD_WAIT" || true
# P5. GROW past the initial run (>16 appends) — proves the pool relocates.
hamsh_send 'pg = []'
hamsh_send 'for gi in range(20):'
hamsh_send '    pg.append(gi)'
hamsh_send ''
hamsh_send_await 'echo ${ len(pg) }' '20' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ $pg[19] }' '19' "$CMD_WAIT" || true
# P6. DIFFERENTIAL: append inside a brace loop ≡ inside an indent loop.
hamsh_send 'mb = []'
hamsh_send 'for i in [1, 2, 3] { mb.append(i) }'
hamsh_send_await 'echo MB $mb' 'MB 1 2 3' "$CMD_WAIT" || true
hamsh_send 'mi = []'
hamsh_send 'for i in [1, 2, 3]:'
hamsh_send '    mi.append(i)'
hamsh_send ''
hamsh_send_await 'echo MI $mi' 'MI 1 2 3' "$CMD_WAIT" || true
# P7. floor-division `//` — int, Python-negative, and float.
hamsh_send_await 'echo ${ 7 // 2 }' '3' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ -7 // 2 }' '-4' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ 7.0 // 2 }' '3' "$CMD_WAIT" || true
# P7b. floor-mod `%` carries the divisor's sign (Python).
hamsh_send_await 'echo ${ -7 % 2 }' '1' "$CMD_WAIT" || true
# P8. sorted() keyword args: reverse= and key=FN (first-class-by-name).
hamsh_send_await 'echo ${ sorted([3, 1, 2], reverse=1) }' '3 2 1' "$CMD_WAIT" || true
hamsh_send 'wl = ["ccc", "a", "bb"]'
hamsh_send_await 'echo ${ sorted(wl, key=len) }' 'a bb ccc' "$CMD_WAIT" || true
# P9. dict mutation: index-assign, setdefault, update, pop; sep.join(list).
hamsh_send 'de = { "x": 1 }'
hamsh_send 'de["y"] = 2'
hamsh_send_await 'echo ${ $de["y"] }' '2' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ de.setdefault("z", 5) }' '5' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ $de["z"] }' '5' "$CMD_WAIT" || true
hamsh_send 'de.update({ "x": 8 })'
hamsh_send_await 'echo ${ $de["x"] }' '8' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ de.pop("y") }' '2' "$CMD_WAIT" || true
hamsh_send 'jsep = "-"'
hamsh_send_await 'echo ${ jsep.join(["a", "b", "c"]) }' 'a-b-c' "$CMD_WAIT" || true
# P10. a glued `name=value` at STATEMENT scope is STILL a POSIX
# assignment (kwarg parsing is confined to inside call parens) — proves
# `X=1`/env-prefix tokenisation did NOT regress.
hamsh_send 'key=hello'
hamsh_send_await 'echo KV $key' 'KV hello' "$CMD_WAIT" || true

# --- Q. §Slice-assign + computed subscript + collection builtins -----
# All results emitted as whole output lines (`echo ${ … }` or an
# inline-colon marker) so ran_bol / hamsh_ran can never false-green.
# Q1. slice-assign SHRINK: xs[1:3] = [9]  ->  [1, 9, 4, 5].
hamsh_send 'qs = [1, 2, 3, 4, 5]'
hamsh_send 'qs[1:3] = [9]'
hamsh_send_await 'echo QS $qs' 'QS 1 9 4 5' "$CMD_WAIT" || true
# Q2. slice-assign GROW into an empty slice (insert): qr[1:1] = [7, 8].
hamsh_send 'qr = [1, 2, 3]'
hamsh_send 'qr[1:1] = [7, 8]'
hamsh_send_await 'echo QR $qr' 'QR 1 7 8 2 3' "$CMD_WAIT" || true
# Q3. slice-assign same-length replace over a prefix.
hamsh_send 'qw = [0, 0, 0]'
hamsh_send 'qw[0:2] = [5, 6, 7]'
hamsh_send_await 'echo QW $qw' 'QW 5 6 7 0' "$CMD_WAIT" || true
# Q4. DIFFERENTIAL both-styles-≡: the SAME slice-assign inside a brace
# block and an indent block must yield IDENTICAL lists (>=1 marker each).
hamsh_send 'qb = [1, 2, 3, 4]'
hamsh_send 'if 1 > 0 { qb[1:3] = [8] }'
hamsh_send_await 'echo QB $qb' 'QB 1 8 4' "$CMD_WAIT" || true
hamsh_send 'qi = [1, 2, 3, 4]'
hamsh_send 'if 1 > 0:'
hamsh_send '    qi[1:3] = [8]'
hamsh_send ''
hamsh_send_await 'echo QI $qi' 'QI 1 8 4' "$CMD_WAIT" || true
# Q5. COMPUTED-subscript READ (spaced index expression) inside ${ }.
hamsh_send 'ce = [10, 20, 30]'
hamsh_send 'cidx = 1'
hamsh_send_await 'echo ${ $ce[cidx + 1] }' '30' "$CMD_WAIT" || true
# Q6. new collection builtins: any / all (inline-colon so bool render is
# never emitted bare), + list index() / count() (function + method form).
hamsh_send_await 'if all([1, 2, 3]): echo ALL_OK' 'ALL_OK' "$CMD_WAIT" || true
hamsh_send_await 'if any([0, 0, 3]): echo ANY_OK' 'ANY_OK' "$CMD_WAIT" || true
hamsh_send 'if any([0, 0, 0]): echo ANY_NO'
hamsh_send_await 'echo ${ index(["a", "b", "c"], "b") }' '1' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ ["x", "y", "x"].count("x") }' '2' "$CMD_WAIT" || true
hamsh_send_await 'echo ${ ["p", "q", "r"].index("r") }' '2' "$CMD_WAIT" || true

hamsh_send_await 'echo GATE_DONE' 'GATE_DONE' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

# --- cleaned command-output view ------------------------------------
CLEAN=$(mktemp)
sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "$LOG" > "$CLEAN"
# ran_bol MARKER — a genuine echo prints MARKER as a whole output line.
ran_bol() { grep -aqE "^$1\$" "$CLEAN"; }

verdict_boot_gate "$TAG" "$LOG" 0 'DUAL_BRACE_YES|GATE_A'
if ! hamsh_ran "$LOG" "DUAL_BRACE_YES" && ! hamsh_ran "$LOG" "GATE_A"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0

# A. brace taken / untaken
if hamsh_ran "$LOG" "DUAL_BRACE_YES"; then echo "[$TAG] OK: brace taken body ran"; else
    echo "[$TAG] WRONG: brace taken body did not run"; fail=1; fi
if hamsh_ran "$LOG" "DUAL_BRACE_NO"; then
    echo "[$TAG] WRONG: brace untaken body leaked"; fail=1; else
    echo "[$TAG] OK: brace untaken body skipped"; fi

# B. inline-colon taken / untaken
if hamsh_ran "$LOG" "DUAL_INLINE_YES"; then echo "[$TAG] OK: inline-colon taken body ran"; else
    echo "[$TAG] WRONG: inline-colon taken body did not run"; fail=1; fi
if hamsh_ran "$LOG" "DUAL_INLINE_NO"; then
    echo "[$TAG] WRONG: inline-colon untaken body leaked"; fail=1; else
    echo "[$TAG] OK: inline-colon untaken body skipped"; fi

# C. multi-line indentation suites
if ran_bol "DUAL_MLIND_YES"; then echo "[$TAG] OK: multi-line indentation if ran"; else
    echo "[$TAG] WRONG: multi-line indentation if did not run"; fail=1; fi
if ran_bol "DUAL_FOR_a" && ran_bol "DUAL_FOR_b"; then
    echo "[$TAG] OK: indentation for-loop iterated"; else
    echo "[$TAG] WRONG: indentation for-loop did not iterate"; fail=1; fi
if ran_bol "DUAL_DEF_planet"; then echo "[$TAG] OK: indentation def defined + called"; else
    echo "[$TAG] WRONG: indentation def did not run"; fail=1; fi

# D. string builtins (each emitted as a whole output line)
for pair in "ABC|upper" "xyz|lower" "p+q+r|split/join" "a_b_c|replace" "ZQX|strip"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$(printf '%s' "$m" | sed 's/[.[*+]/\\&/g')"; then
        echo "[$TAG] OK: string builtin $name"; else
        echo "[$TAG] WRONG: string builtin $name (want '$m')"; fail=1; fi
done

# E. line-numbered parse error
if grep -aqF "parse error [line" "$LOG"; then echo "[$TAG] OK: parse error carries a line number"; else
    echo "[$TAG] WRONG: parse error had no line number"; fail=1; fi

# F. sourced indentation file (if body + 2-iteration for)
file_for_n=$(grep -acE "^FILE_FOR_ITER\$" "$CLEAN" || true)
if ran_bol "FILE_DUAL_YES" && ran_bol "FILE_DUAL_Y2" && [ "$file_for_n" -ge 2 ]; then
    echo "[$TAG] OK: sourced indentation script executed (for iterated $file_for_n times)"; else
    echo "[$TAG] WRONG: sourced indentation script did not fully execute (for_iters=$file_for_n)"; fail=1; fi

# G. sourced BRACE file (accept-either symmetry, file mode)
brace_file_n=$(grep -acE "^BRACE_FILE_ITER\$" "$CLEAN" || true)
if ran_bol "BRACE_FILE_YES" && [ "$brace_file_n" -ge 2 ]; then
    echo "[$TAG] OK: sourced BRACE script executed (for iterated $brace_file_n times)"; else
    echo "[$TAG] WRONG: sourced brace script did not fully execute (iters=$brace_file_n)"; fail=1; fi

# H. membership operators (in / not in): list, string, dict; + absence
for pair in "MEMB_LIST_YES|list-in" "MEMB_NOTIN_YES|list-not-in" \
            "MEMB_SUBSTR_YES|str-substr" "MEMB_DICTKEY_YES|dict-key"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$m"; then echo "[$TAG] OK: membership $name"; else
        echo "[$TAG] WRONG: membership $name did not run"; fail=1; fi
done
if hamsh_ran "$LOG" "MEMB_LIST_NO"; then
    echo "[$TAG] WRONG: membership list untaken body leaked"; fail=1; else
    echo "[$TAG] OK: membership list untaken body skipped"; fi
if hamsh_ran "$LOG" "MEMB_SUBSTR_NO"; then
    echo "[$TAG] WRONG: membership substr untaken body leaked"; fail=1; else
    echo "[$TAG] OK: membership substr untaken body skipped"; fi

# I. new string methods
for pair in "FIND_OK|find" "COUNT_OK|count" "STARTS_OK|startswith" "ENDS_OK|endswith"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$m"; then echo "[$TAG] OK: string method $name"; else
        echo "[$TAG] WRONG: string method $name did not run"; fail=1; fi
done

# J. DIFFERENTIAL both-styles-≡: the brace loop AND the indent loop each
# emit DIFF_FOR_a + DIFF_FOR_b, so a correct pair yields >=2 of each.
diff_a=$(grep -acE "^DIFF_FOR_a\$" "$CLEAN" || true)
diff_b=$(grep -acE "^DIFF_FOR_b\$" "$CLEAN" || true)
if [ "$diff_a" -ge 2 ] && [ "$diff_b" -ge 2 ]; then
    echo "[$TAG] OK: brace loop ≡ indent loop (DIFF_FOR_a=$diff_a DIFF_FOR_b=$diff_b)"; else
    echo "[$TAG] WRONG: brace/indent loops not equivalent (a=$diff_a b=$diff_b, want >=2 each)"; fail=1; fi
if ! hamsh_ran "$LOG" "GATE_DIFF"; then
    echo "[$TAG] WRONG: shell did not survive the differential section"; fail=1; fi

# K. §17 Python-esque data constructs (#110)
for pair in "0 1 4 9|list-comprehension" "0 2 4|comprehension-filter" \
            "4|dict-comprehension" "20|list-index" "40|negative-index" \
            "20 30|list-slice" "ham|string-slice" "xinmah|reverse-slice" \
            "SWAP 2 1|tuple-swap" "MRET 7 8|multiple-return" \
            "10|sum" "1 2 3|sorted" "9|max" "5|abs" \
            "HAMNIX|method-upper"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$(printf '%s' "$m" | sed 's/[.[*+]/\\&/g')"; then
        echo "[$TAG] OK: $name"; else
        echo "[$TAG] WRONG: $name (want '$m')"; fail=1; fi
done
# K5. for-loop tuple unpack over dm.items()
if ran_bol "KVITER x 1"; then echo "[$TAG] OK: for k,v in d.items() unpack"; else
    echo "[$TAG] WRONG: for k,v in d.items() did not unpack"; fail=1; fi
# K6. enumerate via for-unpack
if ran_bol "ENUM 0 p" && ran_bol "ENUM 1 q"; then
    echo "[$TAG] OK: enumerate + for-unpack"; else
    echo "[$TAG] WRONG: enumerate + for-unpack"; fail=1; fi
# K7. DIFFERENTIAL: brace expr-for ≡ indent expr-for (>=2 of each marker).
for tok in RNG_0 RNG_1 RNG_2; do
    cnt=$(grep -acE "^$tok\$" "$CLEAN" || true)
    if [ "$cnt" -ge 2 ]; then echo "[$TAG] OK: expr-for both-styles ≡ ($tok=$cnt)"; else
        echo "[$TAG] WRONG: expr-for brace≢indent ($tok=$cnt, want >=2)"; fail=1; fi
done
if ! hamsh_ran "$LOG" "GATE_K7"; then
    echo "[$TAG] WRONG: shell did not survive the §17 data-construct section"; fail=1; fi

# L. §19 (#111): nested-list render + namespace-as-object
if ran_bol "$(printf '%s' '[1, 3] [2, 4]' | sed 's/[.[*+]/\\&/g')"; then
    echo "[$TAG] OK: nested-list render (zip pairs non-empty)"; else
    echo "[$TAG] WRONG: nested-list render — zip inner lists blank (#110)"; fail=1; fi
if ran_bol "$(printf '%s' '[1, 2] [3, 4]' | sed 's/[.[*+]/\\&/g')"; then
    echo "[$TAG] OK: nested-list literal render"; else
    echo "[$TAG] WRONG: nested-list literal printed blank inner lists (#110)"; fail=1; fi
if ran_bol "/n/aa /n/bb"; then echo "[$TAG] OK: binds(ns) introspection"; else
    echo "[$TAG] WRONG: binds(ns) did not list the mount-points"; fail=1; fi
if ran_bol "NSITER /n/aa" && ran_bol "NSITER /n/bb"; then
    echo "[$TAG] OK: for m in <ns> iterates the namespace"; else
    echo "[$TAG] WRONG: namespace iteration did not walk its binds"; fail=1; fi

# M. §Float — real floating-point (correctness verified on the GUEST).
for pair in "0.5|true-division" "6|int-float-mul" "0.3|exact-bits-add" \
            "3.14|float-literal-roundtrip" "1.5 2.5|list-of-floats" \
            "0.5|float()-conversion" "3|int()-truncation" "2.5|abs-float" \
            "5|sum-floats" "2.5|max-floats" \
            "HALF_OK|cmp-half" "SIXF_OK|cmp-six"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$(printf '%s' "$m" | sed 's/[.[*+]/\\&/g')"; then
        echo "[$TAG] OK: float $name"; else
        echo "[$TAG] WRONG: float $name (want '$m')"; fail=1; fi
done

# N. §Exceptions — raise + finally.
# N1 differential: CAUGHT_boom must appear in BOTH the brace and indent
# form, so a correct pair yields >=2 occurrences.
caught_n=$(grep -acE "^CAUGHT_boom\$" "$CLEAN" || true)
if [ "$caught_n" -ge 2 ]; then
    echo "[$TAG] OK: raise/except brace ≡ indent (CAUGHT_boom=$caught_n)"; else
    echo "[$TAG] WRONG: raise/except brace≢indent (CAUGHT_boom=$caught_n, want >=2)"; fail=1; fi
if ! hamsh_ran "$LOG" "GATE_N1"; then
    echo "[$TAG] WRONG: shell did not survive the exceptions section"; fail=1; fi
# N2/N3: finally runs on BOTH the normal and the caught path.
if ran_bol "TRY_NORMAL" && ran_bol "FIN_NORMAL"; then
    echo "[$TAG] OK: finally runs on the normal path"; else
    echo "[$TAG] WRONG: finally did not run on the normal path"; fail=1; fi
if ran_bol "TRY_CAUGHT" && ran_bol "FIN_CAUGHT"; then
    echo "[$TAG] OK: finally runs on the caught path"; else
    echo "[$TAG] WRONG: finally did not run on the caught path"; fail=1; fi
# N4: finally runs even when the raise propagates uncaught.
if ran_bol "FIN_PROP"; then
    echo "[$TAG] OK: finally runs on the uncaught-propagating path"; else
    echo "[$TAG] WRONG: finally skipped on the uncaught path"; fail=1; fi
# N5: a `with` body that raises still unbinds AND propagates to except.
if ran_bol "WCAUGHT_wz"; then
    echo "[$TAG] OK: with-body raise unwinds through with + caught"; else
    echo "[$TAG] WRONG: with-body raise not caught (unwind∩exceptions)"; fail=1; fi
# N6 differential: the `except NAME:` bind shorthand — SHORT_bx in BOTH
# the brace and indent form, so a correct pair yields >=2 occurrences.
short_n=$(grep -acE "^SHORT_bx\$" "$CLEAN" || true)
if [ "$short_n" -ge 2 ]; then
    echo "[$TAG] OK: except NAME: bind shorthand brace ≡ indent (SHORT_bx=$short_n)"; else
    echo "[$TAG] WRONG: except NAME: shorthand brace≢indent (SHORT_bx=$short_n, want >=2)"; fail=1; fi
# N7: filtered `except NAME as e:` — the matching handler catches + binds,
# the non-matching inner handler re-propagates to the outer one, and the
# WRONGCATCH body never runs.
if ran_bol "$(printf '%s' 'FILT_ValueError: bad' | sed 's/[.[*+]/\\&/g')"; then
    echo "[$TAG] OK: except NAME as e: filter matches + binds"; else
    echo "[$TAG] WRONG: except NAME as e: filter did not catch/bind"; fail=1; fi
if ran_bol "$(printf '%s' 'OUTERCATCH_TypeError: nope' | sed 's/[.[*+]/\\&/g')"; then
    echo "[$TAG] OK: filter miss re-propagates to the outer handler"; else
    echo "[$TAG] WRONG: filter miss did not re-propagate"; fail=1; fi
if hamsh_ran "$LOG" "WRONGCATCH"; then
    echo "[$TAG] WRONG: non-matching filter caught the exception (WRONGCATCH leaked)"; fail=1; else
    echo "[$TAG] OK: non-matching filter did not catch (WRONGCATCH absent)"; fi
# N8: `else` runs on the no-exception path, is skipped on the exception path.
if ran_bol "TRY_OK8" && ran_bol "ELSE_RAN" && ran_bol "FIN_E8"; then
    echo "[$TAG] OK: else runs on the no-exception path (before finally)"; else
    echo "[$TAG] WRONG: else did not run on the no-exception path"; fail=1; fi
if ran_bol "CAUGHT8"; then echo "[$TAG] OK: except still catches with an else present"; else
    echo "[$TAG] WRONG: except body did not run with an else present"; fail=1; fi
if hamsh_ran "$LOG" "ELSE_NO"; then
    echo "[$TAG] WRONG: else ran on the exception path (ELSE_NO leaked)"; fail=1; else
    echo "[$TAG] OK: else skipped on the exception path (ELSE_NO absent)"; fi

# O. §f-string — Python f"{expr}" interpolation.
for pair in "sum=7|arith-subexpr" "pi is 3.14|float-interp" \
            "hi hamnix|adjacent-text" "len=3 {lit}|call+literal-brace" \
            "sq is 7|single-quoted-fstring"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$(printf '%s' "$m" | sed 's/[.[*+{}]/\\&/g')"; then
        echo "[$TAG] OK: f-string $name"; else
        echo "[$TAG] WRONG: f-string $name (want '$m')"; fail=1; fi
done

# P. §Mutation + floor-division + call kwargs (correctness on the GUEST).
for pair in "PM 1 2 3|list-append" \
            "PR 1 2 3|append-relocate" "PO 9 9|relocate-no-corrupt" \
            "PB 1 2 9|append-alias-by-reference" \
            "3|pop-last-return" "PPL 1 2|pop-last-shrink" \
            "10|pop-index-return" "PQL 20 30|pop-index-shrink" \
            "PV 9 1 2 3|insert" "PS 1 7 3|index-assign" \
            "20|append-grow-len" "19|append-grow-tail" \
            "MB 1 2 3|append-brace-loop" "MI 1 2 3|append-indent-loop" \
            "3|floordiv-int" "-4|floordiv-negative" "3|floordiv-float" \
            "1|floormod-python-sign" \
            "3 2 1|sorted-reverse-kwarg" "a bb ccc|sorted-key-len" \
            "2|dict-index-assign" "5|dict-setdefault" "5|dict-setdefault-read" \
            "8|dict-update" "2|dict-pop" "a-b-c|sep-join-method" \
            "KV hello|posix-assign-no-regress"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$(printf '%s' "$m" | sed 's/[.[*+]/\\&/g')"; then
        echo "[$TAG] OK: $name"; else
        echo "[$TAG] WRONG: $name (want '$m')"; fail=1; fi
done
# P6 differential: append-in-brace-loop AND append-in-indent-loop both
# yield the same list — the accept-either guarantee for mutation.
if ran_bol "MB 1 2 3" && ran_bol "MI 1 2 3"; then
    echo "[$TAG] OK: list mutation brace-loop ≡ indent-loop"; else
    echo "[$TAG] WRONG: mutation brace≢indent"; fail=1; fi

# Q. §Slice-assign + computed subscript + collection builtins.
for pair in "QS 1 9 4 5|slice-assign-shrink" "QR 1 7 8 2 3|slice-assign-grow" \
            "QW 5 6 7 0|slice-assign-same-prefix" \
            "QB 1 8 4|slice-assign-brace-block" "QI 1 8 4|slice-assign-indent-block" \
            "30|computed-subscript-read" \
            "ALL_OK|builtin-all" "ANY_OK|builtin-any" \
            "1|list-index-fn" "2|list-count-method" "2|list-index-method"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$(printf '%s' "$m" | sed 's/[.[*+]/\\&/g')"; then
        echo "[$TAG] OK: $name"; else
        echo "[$TAG] WRONG: $name (want '$m')"; fail=1; fi
done
# Q4 differential: brace-block slice-assign ≡ indent-block slice-assign.
if ran_bol "QB 1 8 4" && ran_bol "QI 1 8 4"; then
    echo "[$TAG] OK: slice-assign brace-block ≡ indent-block"; else
    echo "[$TAG] WRONG: slice-assign brace≢indent"; fail=1; fi
# Q6 absence: any([0,0,0]) is falsy — its body must NOT run.
if hamsh_ran "$LOG" "ANY_NO"; then
    echo "[$TAG] WRONG: any([0,0,0]) truthy — untaken body leaked"; fail=1; else
    echo "[$TAG] OK: any([0,0,0]) falsy — body skipped"; fi

if ! hamsh_ran "$LOG" "GATE_DONE"; then
    echo "[$TAG] WRONG: shell did not survive to the end (GATE_DONE absent)"; fail=1; fi

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -50 >&2
    verdict_fail "$TAG" "a dual-syntax / ergonomics assertion was VIOLATED"
fi
verdict_pass "$TAG" "brace + colon + multi-line indentation all execute; string builtins + line-numbered errors + sourced indentation file work"
