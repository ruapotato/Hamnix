#!/usr/bin/env bash
# scripts/test_termcomplete_host.sh — FAST, QEMU-free host gate for the
# graphical terminal's Tab completion. hamterm/hamtermscene own line editing
# locally, so Tab must complete IN the terminal (hamsh's interactive
# _ed_complete never runs when the terminal feeds it whole lines). The apply
# policy lives in lib/hamcompgather.ad (atop the shared lib/hamcomplete.ad
# matching kernel); this gate compiles the harness (user/termcomplete_host.ad)
# for the host and runs it in milliseconds — asserting token analysis, unique
# completion, LCP extension, and the arm/list-on-second-Tab behaviour. It also
# confirms NATIVE hamtermscene still compiles with the completion wired in.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/termcomplete_host"
mkdir -p "$OUT"
fail=0

echo "[termcmp-host] compiling completion-apply layer + harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/termcomplete_host.ad "$BIN" 2>"$OUT/termcmp_compile.log"; then
    echo "[termcmp-host] FAIL: host harness did not compile"; cat "$OUT/termcmp_compile.log"; exit 1
fi
echo "[termcmp-host] PASS host harness compiled -> $BIN"

echo "[termcmp-host] compiling NATIVE hamtermscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamtermscene.ad "$OUT/hamtermscene_native.elf" 2>"$OUT/termcmp_native.log"; then
    echo "[termcmp-host] FAIL: native hamtermscene did not compile"; cat "$OUT/termcmp_native.log"; exit 1
fi
echo "[termcmp-host] PASS native hamtermscene still compiles with Tab completion"

DUMP="$OUT/termcmp_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[termcmp-host] FAIL: unit-test harness reported a failure"; cat "$DUMP"; fail=1
fi

echo "[termcmp-host] --- harness output ---"
cat "$DUMP"
echo "[termcmp-host] --- end output ---"

if grep -q '^FAIL ' "$DUMP"; then
    echo "[termcmp-host] FAIL: one or more unit cases failed"; fail=1
fi
if ! grep -q '^RESULT ok$' "$DUMP"; then
    echo "[termcmp-host] FAIL: missing 'RESULT ok' marker"; fail=1
fi

for c in token_start_arg unique_insert extend_lcp ambiguous_arm ambiguous_list; do
    if ! grep -q "^PASS $c$" "$DUMP"; then
        echo "[termcmp-host] FAIL: case '$c' did not PASS"; fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[termcmp-host] FAIL"
    exit 1
fi
echo "[termcmp-host] PASS"
