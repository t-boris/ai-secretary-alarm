#!/usr/bin/env python3
"""Generate short, original alarm melodies using only Python's standard library."""

from array import array
from math import exp, pi, sin, tanh
from pathlib import Path
import sys
import wave

RATE = 22050
ROOT = Path(__file__).resolve().parents[1] / "Resources" / "Sounds"

# MIDI note, onset in seconds, length in seconds.
MELODIES = {
    "training": [(72, 0.0, .26), (76, .29, .26), (79, .58, .26),
                 (84, .89, .40), (79, 1.36, .26), (84, 1.69, .55)],
    "meeting": [(67, 0.0, .42), (71, .48, .42), (74, .97, .55),
                (71, 1.60, .42), (74, 2.09, .68)],
    "appointment": [(72, 0.0, .46), (67, .55, .42), (69, 1.05, .48),
                     (65, 1.63, .55), (72, 2.30, .68)],
    "social": [(76, 0.0, .25), (79, .28, .25), (83, .57, .34),
               (81, .98, .25), (79, 1.28, .25), (83, 1.58, .34), (88, 2.00, .62)],
    "other": [(72, 0.0, .42), (74, .51, .42), (67, 1.02, .50), (72, 1.62, .74)],
}


def hz(midi: int) -> float:
    return 440.0 * 2.0 ** ((midi - 69) / 12)


def pluck(note: int, age: float, length: float) -> float:
    if age < 0 or age > length + .8:
        return 0.0
    attack = min(1.0, age / .018)
    release = min(1.0, max(0.0, (length + .8 - age) / .40))
    envelope = attack * release * exp(-age * .95)
    phase = 2 * pi * hz(note) * age
    return envelope * (sin(phase) + .23 * sin(2 * phase) + .08 * sin(3 * phase))


def write(name: str, notes: list[tuple[int, float, float]]) -> None:
    length = max(start + duration for _, start, duration in notes) + 1.05
    count = int(length * RATE)
    samples = array("h")
    for n in range(count):
        t = n / RATE
        value = sum(pluck(note, t - start, duration) for note, start, duration in notes)
        value *= min(1.0, (length - t) / .35)
        samples.append(int(21000 * tanh(value * .30)))
    if sys.byteorder != "little":
        samples.byteswap()
    with wave.open(str(ROOT / f"{name}.wav"), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(samples.tobytes())


if __name__ == "__main__":
    ROOT.mkdir(parents=True, exist_ok=True)
    for title, melody in MELODIES.items():
        write(title, melody)
