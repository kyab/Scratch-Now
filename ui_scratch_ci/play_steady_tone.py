#!/usr/bin/env python3
"""Steady reference tone for the UI scratch E2E test.

Plays a constant 220 Hz tone (plus a quiet octave partial, same voicing as the
tap smoke tone) in real time. The scratch harness then drives the turntable
with synthetic mouse events and asserts that the app's output pitch follows
the platter speed (e.g. 2x forward -> ~440 Hz).

A constant pitch keeps the analysis simple: any frequency deviation seen on
the output side must come from the scratch resampler, not from the source.
"""

import argparse
import sys
import time

import numpy as np
import sounddevice as sd

SAMPLE_RATE = 48000
BASE_HZ = 220.0
AMPLITUDE = 0.25


def log_event(message: str) -> None:
    print(f"[tone] {time.time():.3f} {message}", flush=True)


class SteadyToneGenerator:
    def __init__(self):
        self._phase = 0.0
        self._start_time = time.time()

    def callback(self, outdata, frames, time_info, status):
        if status:
            log_event(f"stream_status {status}")

        elapsed = time.time() - self._start_time
        fade_in = min(1.0, elapsed / 0.75)

        phase_increment = 2.0 * np.pi * BASE_HZ / SAMPLE_RATE
        phases = self._phase + phase_increment * np.arange(1, frames + 1)
        self._phase = float(phases[-1] % (2.0 * np.pi))

        fundamental = np.sin(phases)
        octave = 0.15 * np.sin(2.0 * phases)
        mono = AMPLITUDE * fade_in * (fundamental + octave)

        outdata[:, 0] = mono
        if outdata.shape[1] > 1:
            outdata[:, 1] = mono


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=90.0,
                        help="playback duration in seconds")
    args = parser.parse_args()

    generator = SteadyToneGenerator()
    log_event(f"config sample_rate={SAMPLE_RATE} base_hz={BASE_HZ:.2f} "
              f"duration={args.duration:.2f}")

    try:
        with sd.OutputStream(samplerate=SAMPLE_RATE, channels=2,
                             dtype="float32", callback=generator.callback):
            log_event("stream_started")
            time.sleep(args.duration)
    except Exception as exc:  # noqa: BLE001 - surface any audio backend error
        log_event(f"error {exc!r}")
        return 1

    log_event("stream_stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
