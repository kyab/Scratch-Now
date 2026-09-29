#!/usr/bin/env python3
"""Write a stereo 16-bit test-tone WAV (sum of sines) for aliasing checks."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

import numpy as np


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--rate", type=int, default=44100)
    parser.add_argument("--seconds", type=float, default=90.0)
    parser.add_argument("--tone", action="append", nargs=2, metavar=("HZ", "AMP"), type=float,
                        help="Tone frequency and linear amplitude (repeatable)")
    args = parser.parse_args()
    tones = args.tone or [[1000.0, 0.10], [15000.0, 0.20], [18000.0, 0.20]]

    t = np.arange(int(args.rate * args.seconds)) / args.rate
    x = sum(amp * np.sin(2 * np.pi * hz * t) for hz, amp in tones)
    x *= np.minimum(1.0, np.minimum(t / 0.05, (args.seconds - t) / 0.05))
    pcm = (np.clip(x, -1.0, 1.0) * 32767).astype("<i2")
    body = np.stack([pcm, pcm], axis=1).tobytes()
    header = (b"RIFF" + struct.pack("<I", 36 + len(body)) + b"WAVEfmt "
              + struct.pack("<IHHIIHH", 16, 1, 2, args.rate, args.rate * 4, 4, 16)
              + b"data" + struct.pack("<I", len(body)))
    args.output.write_bytes(header + body)
    print(f"Created: {args.output} tones={tones}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
