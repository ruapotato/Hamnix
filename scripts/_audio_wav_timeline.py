#!/usr/bin/env python3
"""scripts/_audio_wav_timeline.py — analyse a QEMU `-audiodev wav` capture.

Shared by the audio stream-lifetime gates. It turns the captured codec output
into a per-window TIMELINE of "which tone was sounding", which is the only
evidence that actually answers the user's reports: what came out of the DAC.

Method (integer-honest, no guesswork):
  * fold to mono, slice into fixed windows (default 25 ms);
  * per window compute RMS and a GOERTZEL magnitude at each probe frequency;
  * a window is "sounding <hz>" when its RMS clears a loudness floor AND that
    frequency's normalised magnitude is the strongest of the probes.

A square wave at f has all its odd harmonics, so 300/1000/1500 Hz are chosen so
that no probe sits on another's harmonic (300's harmonics are 900, 1500, ... —
so 1500 is deliberately compared by RATIO against 300, and the caller checks
CO-PRESENCE rather than dominance when it wants "both at once").

Usage:  _audio_wav_timeline.py <wav> [--json]
"""
import json
import math
import sys
import wave

import numpy as np

WINDOW_MS = 25.0
# RMS below this (out of 32768) is treated as silence. The scenario tones are
# amplitude 12000, so a sounding window is ~12000 RMS for a square wave; 400 is
# ~30 dB below that and comfortably above capture dither.
SILENCE_RMS = 400.0
PROBES = (300, 1000, 1500)


def load_mono(path):
    w = wave.open(path, "rb")
    sw, ch, rate, n = (w.getsampwidth(), w.getnchannels(),
                       w.getframerate(), w.getnframes())
    raw = w.readframes(n)
    w.close()
    if sw != 2:
        raise SystemExit(f"{path}: expected 16-bit PCM, got {sw*8}-bit")
    a = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    return a, rate


def goertzel(block, rate, hz):
    """Magnitude of `block` at `hz` (Goertzel, normalised by block length)."""
    n = len(block)
    if n == 0:
        return 0.0
    k = int(0.5 + n * hz / rate)
    w = 2.0 * math.pi * k / n
    coeff = 2.0 * math.cos(w)
    s1 = s2 = 0.0
    for x in block:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return math.sqrt(max(power, 0.0)) / n * 2.0


def goertzel_fast(block, rate, hz):
    """Vectorised equivalent of goertzel() (same normalisation)."""
    n = len(block)
    if n == 0:
        return 0.0
    t = np.arange(n)
    ph = 2.0 * np.pi * hz * t / rate
    re = float(np.dot(block, np.cos(ph)))
    im = float(np.dot(block, np.sin(ph)))
    return math.hypot(re, im) / n * 2.0


def timeline(path, window_ms=WINDOW_MS, probes=PROBES):
    a, rate = load_mono(path)
    wn = max(1, int(rate * window_ms / 1000.0))
    out = []
    for i in range(0, len(a) - wn + 1, wn):
        blk = a[i:i + wn]
        rms = float(np.sqrt(np.mean(blk * blk)))
        mags = {hz: goertzel_fast(blk, rate, hz) for hz in probes}
        best = max(mags, key=mags.get) if rms >= SILENCE_RMS else None
        out.append({
            "t": i / float(rate),
            "rms": rms,
            "mag": mags,
            "tone": best,
        })
    return out, rate, len(a) / float(rate)


def label(e):
    if e["tone"] is None:
        return "."
    return {300: "s", 1000: "J", 1500: "M"}.get(e["tone"], "?")


def main():
    path = sys.argv[1]
    tl, rate, dur = timeline(path)
    if "--json" in sys.argv:
        print(json.dumps({"rate": rate, "duration": dur, "timeline": tl}))
        return
    print(f"rate={rate} duration={dur:.3f}s windows={len(tl)}")
    strip = "".join(label(e) for e in tl)
    for i in range(0, len(strip), 80):
        t0 = tl[i]["t"]
        print(f"{t0:7.2f}s |{strip[i:i+80]}|")
    print("legend: J=1000Hz(jingle) s=300Hz(sfx) M=1500Hz(music) .=silence")


if __name__ == "__main__":
    main()
