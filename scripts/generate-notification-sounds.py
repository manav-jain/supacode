#!/usr/bin/env python3
"""Synthesize Supacode's bundled notification sounds.

Every sound this script emits is generated from scratch with additive
synthesis — there is no sampled or third-party audio involved, so the
output is original work that ships under the repository's license with
no attribution or trademark concerns. (Notably we deliberately do *not*
reproduce real transit jingles such as SNCF, NYC MTA, SF Muni or the
Paris Métro, which are trademarked recordings.)

Run from the repo root:

    python3 scripts/generate-notification-sounds.py

It (re)writes the .wav files under supacode/Sounds/. The existing
"Classic" sound (supacode/notification.wav) is left untouched.

Pure standard library — no numpy / ffmpeg / sox required.
"""

import array
import math
import os
import random
import struct
import wave

SAMPLE_RATE = 44_100
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "supacode", "Sounds")


class Buffer:
    """A mono float sample buffer that mixes partials additively."""

    def __init__(self, duration):
        self.samples = [0.0] * int(duration * SAMPLE_RATE)

    def __len__(self):
        return len(self.samples)

    def add_partial(self, freq, amp, start, decay, *, vibrato_hz=0.0, vibrato_depth=0.0):
        """Add an exponentially-decaying sine partial (bell / chime / gong)."""
        start_i = int(start * SAMPLE_RATE)
        phase = 0.0
        for i in range(start_i, len(self.samples)):
            t = (i - start_i) / SAMPLE_RATE
            env = math.exp(-t / decay)
            if env < 1e-4:
                break
            f = freq
            if vibrato_depth:
                f += vibrato_depth * math.sin(2 * math.pi * vibrato_hz * t)
            phase += 2 * math.pi * f / SAMPLE_RATE
            self.samples[i] += amp * env * math.sin(phase)

    def add_tone(self, freq, amp, start, duration, *, attack=0.02, release=0.08,
                 vibrato_hz=0.0, vibrato_depth=0.0, noise=0.0):
        """Add a sustained tone with an attack/sustain/release envelope (whistle)."""
        start_i = int(start * SAMPLE_RATE)
        end_i = min(len(self.samples), start_i + int(duration * SAMPLE_RATE))
        phase = 0.0
        last_noise = 0.0
        for i in range(start_i, end_i):
            t = (i - start_i) / SAMPLE_RATE
            remaining = (end_i - i) / SAMPLE_RATE
            env = min(1.0, t / attack) * min(1.0, remaining / release)
            f = freq
            if vibrato_depth:
                f += vibrato_depth * math.sin(2 * math.pi * vibrato_hz * t)
            phase += 2 * math.pi * f / SAMPLE_RATE
            value = math.sin(phase)
            if noise:
                # One-pole low-passed white noise for a touch of steam "air".
                last_noise = 0.85 * last_noise + 0.15 * (random.random() * 2 - 1)
                value += noise * last_noise
            self.samples[i] += amp * env * value


def normalize(buf, peak=0.89):
    """Scale to a target peak and apply tiny fades to avoid edge clicks."""
    hi = max((abs(s) for s in buf.samples), default=0.0)
    if hi > 0:
        gain = peak / hi
        buf.samples = [s * gain for s in buf.samples]
    fade = int(0.003 * SAMPLE_RATE)
    n = len(buf.samples)
    for i in range(min(fade, n)):
        buf.samples[i] *= i / fade
        buf.samples[n - 1 - i] *= i / fade
    return buf


def write_wav(name, buf):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    path = os.path.join(OUTPUT_DIR, name)
    data = array.array("h", (int(max(-1.0, min(1.0, s)) * 32767) for s in buf.samples))
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(struct.pack("<%dh" % len(data), *data))
    print("wrote %s (%.2fs)" % (os.path.normpath(path), len(buf) / SAMPLE_RATE))


# --- Individual sounds ------------------------------------------------------

def chime():
    """A friendly major-triad mallet arpeggio (C6 / E6 / G6)."""
    buf = Buffer(1.4)
    for note, start in ((1046.50, 0.0), (1318.51, 0.09), (1567.98, 0.18)):
        buf.add_partial(note, 1.0, start, 0.55)
        buf.add_partial(note * 2.0, 0.32, start, 0.40)
        buf.add_partial(note * 3.01, 0.12, start, 0.30)
    return normalize(buf)


def ding():
    """A single crisp bell — quick and unobtrusive."""
    buf = Buffer(0.6)
    base = 1760.0  # A6
    buf.add_partial(base, 1.0, 0.0, 0.32)
    buf.add_partial(base * 2.76, 0.36, 0.0, 0.20)  # inharmonic bell ratios
    buf.add_partial(base * 5.40, 0.14, 0.0, 0.12)
    return normalize(buf)


def gong():
    """A deep, slowly-shimmering gong with inharmonic partials."""
    buf = Buffer(2.4)
    base = 138.59  # C#3
    ratios = ((1.0, 1.0), (1.52, 0.7), (2.31, 0.5), (2.95, 0.4), (3.74, 0.28), (4.61, 0.2))
    for ratio, amp in ratios:
        buf.add_partial(base * ratio, amp, 0.0, 1.25,
                        vibrato_hz=0.8, vibrato_depth=base * ratio * 0.004)
    return normalize(buf)


def choo_choo():
    """A two-blast steam train whistle ("choo… choooo")."""
    buf = Buffer(1.7)
    # A wailing chord of partials gives the classic steam-whistle timbre.
    chord = ((392.00, 1.0), (466.16, 0.85), (587.33, 0.7), (784.00, 0.4))
    blasts = ((0.0, 0.34), (0.46, 0.78))  # (start, duration) — short then long
    for start, duration in blasts:
        for freq, amp in chord:
            buf.add_tone(freq, amp, start, duration,
                         attack=0.025, release=0.12,
                         vibrato_hz=5.5, vibrato_depth=freq * 0.01,
                         noise=0.18)
    return normalize(buf)


def inbound_train():
    """An ascending two-note arrival chime (perfect fourth up)."""
    buf = Buffer(1.2)
    for note, start in ((739.99, 0.0), (987.77, 0.26)):  # F#5 -> B5
        buf.add_partial(note, 1.0, start, 0.6)
        buf.add_partial(note * 2.0, 0.28, start, 0.45)
    return normalize(buf)


def stand_clear():
    """A descending three-note "doors closing" alert."""
    buf = Buffer(1.1)
    for note, start in ((1318.51, 0.0), (1046.50, 0.18), (880.00, 0.36)):  # E6 -> C6 -> A5
        buf.add_partial(note, 1.0, start, 0.4)
        buf.add_partial(note * 2.0, 0.3, start, 0.28)
    return normalize(buf)


def main():
    # Deterministic noise so reruns produce byte-identical files.
    random.seed(20260629)
    write_wav("chime.wav", chime())
    write_wav("ding.wav", ding())
    write_wav("gong.wav", gong())
    write_wav("choo-choo.wav", choo_choo())
    write_wav("inbound-train.wav", inbound_train())
    write_wav("stand-clear.wav", stand_clear())


if __name__ == "__main__":
    main()
