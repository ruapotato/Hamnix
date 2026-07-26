# scripts/_hamsh_log.sh — hamsh interactive-log assertion helpers.
#
# WHY THIS EXISTS
#
# hamsh's interactive prompt now has a full line editor (user/hamsh.ad
# :: ed_readline). Like any real interactive shell, it ECHOES what you
# type and repaints the line as the cursor moves. When a test drives
# hamsh over the serial console, that echo is recorded in the captured
# serial log alongside genuine command output.
#
# A naive `grep -F "MARKER" log` therefore matches the MARKER both
# when a command actually PRINTED it and when the test merely TYPED
# `echo MARKER` (the editor echoed the keystrokes back). Tests that
# assert a marker is absent — or count how many times it ran — need to
# look at command OUTPUT only, not input echo.
#
# THE DISCRIMINATOR
#
# The line editor always repaints the prompt (`hamsh$ ` or the `> `
# continuation) at the start of the line it is editing, and the whole
# interactive edit of one input line lands on a SINGLE serial-log line
# (the editor uses CR, not LF, to repaint — only Enter emits a
# newline). Genuine command output, by contrast, is written on its own
# line with no prompt. So:
#
#   * a log line containing the marker AND a prompt  -> input echo
#   * a log line containing the marker and NO prompt -> command output
#
# These helpers grep only the command-output lines.

# _ho_outlines <logfile> — emit just the command-output lines (drop any
# line carrying a shell prompt, i.e. input being echoed back).
#
# `-a` forces text mode: a QEMU serial log carries raw terminal-control
# bytes (ANSI escapes, the editor's CR repaints) that grep otherwise
# samples as "binary", whereupon it suppresses ALL output — silently
# turning every assertion into a false "absent". -a keeps it line-wise.
# The CONTINUATION prompt ("> ", printed while a brace block is still
# open) is a prompt too, and its echoed line must be dropped exactly like
# the primary one. The old pattern only recognised it as `] > ` — i.e.
# when it followed a kernel timestamp on the same line. A block typed at
# a fresh line starts the log line with `> ` and slipped through, so
# `echo IF_FALSE_BRANCH` merely TYPED into a not-taken else-branch read
# as command output and any "this must NOT have run" assertion fired a
# false positive (scripts/test_hamsh_blocks.sh, 2026-07-25). Anchor the
# continuation prompt at line start as well.
_ho_outlines() {
    grep -a -vE 'hamsh\$|\] > |^> ' "$1" 2>/dev/null || true
}

# hamsh_ran <logfile> <marker> — succeeds iff <marker> appears in
# genuine command output (not merely typed at the prompt).
hamsh_ran() {
    _ho_outlines "$1" | grep -a -F -q "$2"
}

# hamsh_ran_count <logfile> <marker> — number of command-output lines
# containing <marker>.
hamsh_ran_count() {
    _ho_outlines "$1" | grep -a -F -c "$2" || true
}

# --- EXACT-LINE assertions -------------------------------------------
#
# WHY A SUBSTRING GREP IS NOT ENOUGH FOR A PIPE TEST
#
# A pipe gate has to prove the bytes travelled the PIPE rather than
# leaking to the console. The only assertion that can tell those apart is
# the CONSUMER's computed answer — a number the producer never prints,
# e.g. `seq 1000 1041 | wc -l` -> 42. But a substring grep for "42" also
# matches the kernel's own "[001042]" serial timestamps, hamsh's
# "[hamsh-alive] tick=42" heartbeat, and the "task: pid 42 exited" log.
# So the check must be: some command printed a line whose ENTIRE content
# is "42", with the shell's CR-repainted prompt echo and all kernel
# chatter removed first.
#
# hamsh_outlines <logfile> — genuine command-output lines, one per line:
# prompt/input-echo lines dropped (_ho_outlines), CR repaints split into
# real lines, ANSI escapes stripped, kernel + heartbeat chatter removed,
# surrounding whitespace trimmed.
hamsh_outlines() {
    _ho_outlines "$1" \
        | tr '\r' '\n' \
        | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[()][A-Za-z0-9]//g' \
        | grep -a -vE '^\[[0-9]{6}\]|^task: pid |^\[hamsh' \
        | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//'
}

# hamsh_out_eq <logfile> <text> — succeeds iff some command printed a line
# whose entire content is <text>.
hamsh_out_eq() {
    hamsh_outlines "$1" | grep -a -q -x -F "$2"
}

# hamsh_out_count <logfile> <text> — how many command-output lines have
# exactly <text> as their whole content.
hamsh_out_count() {
    hamsh_outlines "$1" | grep -a -c -x -F "$2" || true
}
