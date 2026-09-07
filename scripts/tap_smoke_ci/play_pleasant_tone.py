#!/usr/bin/env python3
"""Real-time pleasant tone generator for the CATap smoke test.

Generates a soft, ear-friendly tone in real time (not file playback) using
python-sounddevice. The tone deliberately changes frequency partway through so
the smoke-test harness can confirm that the Scratch Now tap follows the change
with a small delay.

Two phases:
  Phase A: soft tone at 220 Hz.
  Phase B: glides up a perfect fifth to 330 Hz.

Phase boundaries are logged to stdout as machine-readable lines so the harness
knows when to expect the captured dominant frequency to shift.
"""

import sys
import threading
import time

import numpy as np
import sounddevice as sd

PHASE_A = "A"
PHASE_B = "B"

SAMPLE_RATE = 48000
BASE_HZ = 220.0
FIFTH_HZ = 330.0
PHASE_A_SECONDS = 8.0
GLIDE_SECONDS = 1.5
DURATION_SECONDS = 18.0
AMPLITUDE = 0.25


def log_event(message: str) -> None:
    # Machine-readable, line-buffered so the harness can follow along live.
    print(f"[tone] {time.time():.3f} {message}", flush=True)


class ToneGenerator:
    """Renders a soft two-partial tone with a slow amplitude envelope.

    The frequency glides smoothly between phase targets to avoid audible clicks
    that could confuse the frequency estimator on the capture side.
    """

    def __init__(self):
        self._phase = 0.0
        self._start_time = time.time()
        self._current_phase_label = None
        self._lock = threading.Lock()

    def _target_frequency(self, elapsed: float) -> float:
        # Smoothly interpolate from base to fifth across the glide window that
        # starts at the end of phase A.
        if elapsed < PHASE_A_SECONDS:
            return BASE_HZ
        glide_pos = (elapsed - PHASE_A_SECONDS) / GLIDE_SECONDS
        if glide_pos >= 1.0:
            return FIFTH_HZ
        # Cosine ease for a musical, click-free transition.
        eased = 0.5 - 0.5 * np.cos(np.pi * glide_pos)
        return BASE_HZ + (FIFTH_HZ - BASE_HZ) * eased

    def _envelope(self, elapsed: float) -> float:
        # Gentle fade-in and a slow tremolo so the sound is easy on the ears.
        fade_in = min(1.0, elapsed / 0.75)
        tremolo = 0.85 + 0.15 * np.sin(2.0 * np.pi * 0.25 * elapsed)
        return fade_in * tremolo

    def callback(self, outdata, frames, time_info, status):
        if status:
            log_event(f"stream_status {status}")

        now = time.time()
        elapsed = now - self._start_time

        label = PHASE_A if elapsed < PHASE_A_SECONDS else PHASE_B
        with self._lock:
            if label != self._current_phase_label:
                self._current_phase_label = label
                target = BASE_HZ if label == PHASE_A else FIFTH_HZ
                log_event(f"phase={label} target_hz={target:.2f}")

        freq = self._target_frequency(elapsed)
        env = self._envelope(elapsed)

        # Per-sample phase accumulation keeps continuity across callbacks.
        phase_increment = 2.0 * np.pi * freq / SAMPLE_RATE
        phases = self._phase + phase_increment * np.arange(1, frames + 1)
        self._phase = float(phases[-1] % (2.0 * np.pi))

        # Fundamental plus a quiet octave partial for warmth.
        fundamental = np.sin(phases)
        octave = 0.15 * np.sin(2.0 * phases)
        mono = AMPLITUDE * env * (fundamental + octave)

        outdata[:, 0] = mono
        if outdata.shape[1] > 1:
            outdata[:, 1] = mono


def main() -> int:
    generator = ToneGenerator()

    log_event(
        f"config sample_rate={SAMPLE_RATE} base_hz={BASE_HZ:.2f} "
        f"fifth_hz={FIFTH_HZ:.2f} phase_a_seconds={PHASE_A_SECONDS:.2f} "
        f"glide_seconds={GLIDE_SECONDS:.2f} duration={DURATION_SECONDS:.2f}"
    )

    try:
        with sd.OutputStream(samplerate=SAMPLE_RATE, channels=2,
                             dtype="float32", callback=generator.callback):
            log_event("stream_started")
            time.sleep(DURATION_SECONDS)
    except Exception as exc:  # noqa: BLE001 - surface any audio backend error
        log_event(f"error {exc!r}")
        return 1

    log_event("stream_stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
