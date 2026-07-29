#!/usr/bin/env python3
"""scripts/_audio_lifetime_assert.py — the assertions of
scripts/test_audio_stream_lifetime.sh, made on the PCM the codec emitted.

Input is the WAV that QEMU's `-audiodev wav` backend captured while
user/audiolife.ad ran the three-part scenario. NOTE that this backend records
only what the DMA engine actually delivered — a stopped stream contributes no
samples — so the capture is the sounding content, concatenated. That is exactly
the right witness here: every one of the three bugs shows up as the WRONG AMOUNT
OF AUDIO (a clip that repeats, an effect emitted twice, effects that never
reach the mix), and durations survive the concatenation.

The scenario submits, in order:
    D  3.000 s of 1000 Hz   (staged clip; the process exits right after `start`)
    E  0.150 s of  300 Hz   (one raw write, no ctl verbs; the process exits)
    C  4.000 s of 1500 Hz   (streaming ring; a long-lived producer)
    B  0.600 s of  300 Hz   (six 100 ms effects, WHILE C is producing)

so the capture must contain each of those, ONCE, and B's must be summed with
C's rather than queued after it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _audio_wav_timeline import goertzel_fast, load_mono   # noqa: E402

WINDOW_MS = 25.0
# A probe tone is "present" in a window when its Goertzel magnitude clears this.
# The scenario's square waves are amplitude 12000, giving ~8600 in their own
# bin. A 300 Hz square's 5th harmonic lands ON 1500 Hz but only reaches ~1730,
# and a 1500 Hz tone shows ~20 in the 300 Hz bin — so 4000 separates them with
# 2x margin on the worst case.
PRESENT = 4000.0
JINGLE, SFX, MUSIC = 1000, 300, 1500

# What the scenario submitted, and how much slack the 25 ms window grid needs.
EXPECT = {
    "clip":        (3.000, 0.30),   # D: one staged clip
    "effect_solo": (0.150, 0.10),   # E: one raw effect, nothing else sounding
    "music":       (4.000, 0.40),   # C: the streaming ring
    "effect_mix":  (0.600, 0.15),   # B: six effects, summed into C
}


def presence(path):
    a, rate = load_mono(path)
    wn = max(1, int(rate * WINDOW_MS / 1000.0))
    out = []
    for i in range(0, len(a) - wn + 1, wn):
        blk = a[i:i + wn]
        out.append({hz: goertzel_fast(blk, rate, hz) >= PRESENT
                    for hz in (JINGLE, SFX, MUSIC)})
    return out, wn / float(rate)


def runs(flags, win):
    out, c = [], 0
    for v in flags:
        if v:
            c += 1
        elif c:
            out.append(c * win)
            c = 0
    if c:
        out.append(c * win)
    return out


def main():
    path = sys.argv[1]
    w, win = presence(path)
    tag = "[audio_lifetime]"

    jing = runs([f[JINGLE] for f in w], win)
    music = runs([f[MUSIC] for f in w], win)
    # An effect heard WHILE the music plays is a mix; one heard with no music
    # is a solo effect. Splitting them is what separates symptom 1 from 3.
    solo = runs([f[SFX] and not f[MUSIC] for f in w], win)
    mixed = runs([f[SFX] and f[MUSIC] for f in w], win)

    print(f"{tag}   1000 Hz (staged clip):  {sum(jing):.3f}s in {len(jing)} run(s) "
          f"{[round(r, 3) for r in jing]}")
    print(f"{tag}    300 Hz (solo effect):  {sum(solo):.3f}s in {len(solo)} run(s) "
          f"{[round(r, 3) for r in solo]}")
    print(f"{tag}   1500 Hz (music):        {sum(music):.3f}s in {len(music)} run(s)")
    print(f"{tag}    300 Hz OVER the music: {sum(mixed):.3f}s in {len(mixed)} run(s) "
          f"{[round(r, 3) for r in mixed]}")

    bad = 0

    def check(label, got, key):
        nonlocal bad
        want, slack = EXPECT[key]
        if abs(got - want) <= slack:
            print(f"{tag} PASS: {label} — {got:.3f}s (submitted {want:.3f}s)")
        else:
            print(f"{tag} FAIL: {label} — {got:.3f}s emitted, {want:.3f}s "
                  f"submitted (tolerance {slack:.3f}s)", file=sys.stderr)
            bad = 1

    # SYMPTOM 2 — "on close it played the last sound effect over and over".
    # The staging process exited right after `start`; a cyclic buffer nobody
    # stops replays forever. Pre-fix: 7.272 s of a 3.000 s clip, in 3 runs.
    check("a staged clip plays ONCE after its process exits", sum(jing), "clip")
    if len(jing) != 1:
        print(f"{tag} FAIL: the staged clip sounded in {len(jing)} separate runs; "
              f"one clip must be one run — it is repeating", file=sys.stderr)
        bad = 1

    # SYMPTOM 1 — "the first sound effect played the end of the boot jingle".
    # ONE raw effect was written. Pre-fix it was emitted TWICE (once per lap of
    # the previous clip's still-running buffer), each time trailed by that
    # clip's remaining samples.
    check("one raw effect is emitted ONCE, not re-played", sum(solo),
          "effect_solo")
    if len(solo) != 1:
        print(f"{tag} FAIL: the single raw effect sounded {len(solo)} times — "
              f"a previous stream's buffer is being re-read", file=sys.stderr)
        bad = 1

    # SYMPTOM 3 — "1/2 the sounds don't play while the music is playing".
    # Pre-fix: 0.000 s of the effects overlapped the music (all six were queued
    # behind it) and 4 % were lost.
    check("music plays through", sum(music), "music")
    check("EVERY effect submitted during the music is IN the mix", sum(mixed),
          "effect_mix")
    if sum(mixed) < 0.001:
        print(f"{tag} FAIL: not one effect overlapped the music — they were "
              f"queued behind it, not mixed into it", file=sys.stderr)
        bad = 1

    return bad


if __name__ == "__main__":
    sys.exit(main())
