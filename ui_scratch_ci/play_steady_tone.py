#!/usr/bin/env python3
"""Steady reference tone for the UI scratch E2E test.

Generates a constant 220 Hz tone file (plus a quiet octave partial, same
voicing as the tap smoke tone) and plays it with afplay. The scratch harness
then drives the turntable with synthetic mouse events and asserts that the
app's output pitch follows the platter speed (e.g. 2x forward -> ~440 Hz).

File playback through afplay is used instead of a Python real-time render
callback on purpose: on loaded CI VMs the sounddevice/PortAudio stream was
observed to fall into a persistent ~40% duty stutter roughly 30 s into the
run, which corrupted the capture-side reference and failed the test even
though the app behaved correctly.

A constant pitch keeps the analysis simple: any frequency deviation seen on
the output side must come from the scratch resampler, not from the source.
"""

import argparse
import os
import sys
import time
import wave

import numpy as np

SAMPLE_RATE = 48000
BASE_HZ = 220.0
AMPLITUDE = 0.25
FADE_IN_SECONDS = 0.75
WAV_PATH = "/tmp/scratch-now-ui-scratch-steady-tone.wav"
AFPLAY = "/usr/bin/afplay"


def log_event(message: str) -> None:
    print(f"[tone] {time.time():.3f} {message}", flush=True)


def write_wav(path: str, duration: float) -> None:
    frames = int(SAMPLE_RATE * duration)
    t = np.arange(frames, dtype=np.float64) / SAMPLE_RATE
    fade_in = np.minimum(1.0, t / FADE_IN_SECONDS)
    two_pi_t = 2.0 * np.pi * BASE_HZ * t
    mono = AMPLITUDE * fade_in * (np.sin(two_pi_t) + 0.15 * np.sin(2.0 * two_pi_t))
    pcm = (np.clip(mono, -1.0, 1.0) * 32767.0).astype("<i2")
    stereo = np.repeat(pcm, 2)  # interleave identical L/R channels
    with wave.open(path, "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(stereo.tobytes())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=90.0,
                        help="playback duration in seconds")
    args = parser.parse_args()

    log_event(f"config sample_rate={SAMPLE_RATE} base_hz={BASE_HZ:.2f} "
              f"duration={args.duration:.2f}")
    write_wav(WAV_PATH, args.duration)
    log_event(f"wav_written {WAV_PATH}")

    # Replace this process with afplay so that killing the tone PID (as the
    # run script does on cleanup) also stops playback.
    log_event("stream_started")
    os.execv(AFPLAY, [AFPLAY, WAV_PATH])
    return 1  # unreachable


if __name__ == "__main__":
    sys.exit(main())
