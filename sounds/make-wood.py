#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.24"]
# ///
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

"""The source of sounds/wood.wav, scrubjay's notification bell: two marimba strikes, A4 then D5.

Synthesized, not recorded. Nothing runs this; it is here so the sound has a source.

    uv run --script sounds/make-wood.py [out.wav]
"""

import sys
import wave

import numpy as np

SR = 44100
t = np.arange(int(SR * 0.9)) / SR
rng = np.random.default_rng(7)


def lowpass(x: np.ndarray, fc: float) -> np.ndarray:
    a = np.exp(-2 * np.pi * fc / SR)
    y, acc = np.zeros_like(x), 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def strike(f: float, start: float, gain: float = 1.0) -> np.ndarray:
    x = np.zeros_like(t)
    m = t >= start
    tt = t[m] - start
    attack = 1 - np.exp(-tt / 0.0025)                                # a soft mallet
    body = (np.sin(2 * np.pi * f * tt) * np.exp(-tt / 0.32)          # the bar's fundamental
            + 0.18 * np.sin(2 * np.pi * 3.93 * f * tt) * np.exp(-tt / 0.045)   # the ~4x partial
            + 0.04 * np.sin(2 * np.pi * 9.8 * f * tt) * np.exp(-tt / 0.012))   # the ~10x: the wood
    knock = lowpass(rng.standard_normal(len(tt)), 1800) * np.exp(-tt / 0.006) * 0.35  # contact
    x[m] = gain * (attack * body + knock)
    return x


y = strike(440.00, 0.0) + strike(587.33, 0.14, gain=0.9)
n = int(SR * 0.12)
y[-n:] *= np.linspace(1, 0, n)
y = lowpass(y, 5000)
y = y / np.abs(y).max() * 10 ** (-8 / 20)                            # peak at -8 dBFS

with wave.open(sys.argv[1] if len(sys.argv) > 1 else "wood.wav", "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((y * 32767).astype("<i2").tobytes())
