/*
 * tests/wpt/hamnix_testharnessreport.js -- Hamnix's vendor hook for WPT.
 *
 * WPT ships resources/testharnessreport.js as an EMPTY, VENDOR-OWNED file:
 *
 *     "This file is intended for vendors to implement code needed to integrate
 *      testharness.js tests with their own test systems."
 *
 * This is our implementation of it. It is OUR code, not a modified WPT file --
 * scripts/wpt_run.py substitutes this in place of the upstream stub. No
 * vendored test and no vendored harness file is ever edited.
 *
 * It does exactly two things: turn off in-page result rendering, and stream
 * results out over console.log where the host driver can see them.
 */

/* Results are also buffered here so the chromium cross-check can read them out
 * of the dumped DOM (chromium --headless --dump-dom gives us markup, not a
 * console stream). Same reporter, same data, two transports -- so a
 * cross-check difference can only be an engine difference. */
var HAMNIX_WPT_OUT = [];

(function () {
    /* --- 1. no in-page output -------------------------------------------
     * testharness.js's default output_results() builds a results TABLE in the
     * live DOM. We are a headless scraper; we do not read pixels, and the
     * table costs a few hundred DOM nodes per test file. wptrunner turns this
     * off the same way (testharness_properties {"output": false}), so this is
     * the sanctioned automation configuration, not a workaround.
     */
    try {
        setup({ output: false });
    } catch (e) { /* a test may have already called setup(); harmless */ }

    /* --- 2. escaping, without regex -------------------------------------
     * Deliberately hand-rolled rather than String.replace(/../g, ...): the
     * result lines are the measurement instrument, so they must not depend on
     * the very regex engine under test. (They would have: our engine currently
     * mis-evaluates /[^\x20-\x7e]/g, which is how testharness's own message
     * formatter turns "expected 2 but got 1" into "U+65U+78...".)
     */
    function esc(s) {
        if (s === undefined || s === null) { return ""; }
        s = "" + s;
        var out = "";
        for (var i = 0; i < s.length; i++) {
            var c = s.charCodeAt(i);
            if (c === 9) { out += " "; }
            else if (c === 10 || c === 13) { out += "\\n"; }
            else { out += s.charAt(i); }
        }
        if (out.length > 400) { out = out.substring(0, 400) + "..."; }
        return out;
    }

    /* --- 3. per-test results, streamed as they land ----------------------
     * add_result_callback fires when each individual test finishes, which is
     * independent of whether the FILE-level harness ever reaches "complete".
     * That matters here: our engine does not yet dispatch `load` to `window`,
     * so testharness's completion path is reached via its own timeout rather
     * than the load event. Streaming per-test means a file whose harness never
     * completes still yields real per-assertion data instead of one opaque
     * ERROR -- the difference between a ranked gap list and a shrug.
     */
    add_result_callback(function (t) {
        HAMNIX_WPT_OUT.push(["R", t.status, esc(t.name), esc(t.message)]);
        console.log("WPT#RESULT\t" + t.status + "\t" + esc(t.name) + "\t" + esc(t.message));
    });

    add_completion_callback(function (tests, status) {
        HAMNIX_WPT_OUT.push(["S", status.status, esc(status.message), tests.length]);
        console.log("WPT#STATUS\t" + status.status + "\t" + esc(status.message));
        console.log("WPT#DONE\t" + tests.length);
    });
})();
