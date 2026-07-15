#!/usr/bin/env python3
"""Real-time pleasant tone generator for the CATap smoke test.

Generates a soft, ear-friendly tone in real time (not file playback) using
python-sounddevice. The tone deliberately changes frequency partway through so
the smoke-test harness can confirm that the Scratch Now tap follows the change
with a small delay.

Two phases (durations are configurable via CLI):
  Phase A: soft tone around a base frequency (default 220 Hz).
  Phase B: glides up a perfect fifth (default 330 Hz).

Phase boundaries are logged to stdout as machine-readable lines so the harness
knows when to expect the captured dominant frequency to shift.
"""

import argparse
import sys
import threading
import time

import numpy as np
import sounddevice as sd

PHASE_A = "A"
PHASE_B = "B"


def log_event(message: str) -> None:
    # Machine-readable, line-buffered so the harness can follow along live.
    print(f"[tone] {time.time():.3f} {message}", flush=True)


class ToneGenerator:
    """Renders a soft two-partial tone with a slow amplitude envelope.

    The frequency glides smoothly between phase targets to avoid audible clicks
    that could confuse the frequency estimator on the capture side.
    """

    def __init__(self, sample_rate: int, base_hz: float, fifth_hz: float,
                 phase_a_seconds: float, glide_seconds: float, amplitude: float):
        self.sample_rate = sample_rate
        self.base_hz = base_hz
        self.fifth_hz = fifth_hz
        self.phase_a_seconds = phase_a_seconds
        self.glide_seconds = glide_seconds
        self.amplitude = amplitude

        self._phase = 0.0
        self._start_time = time.time()
        self._current_phase_label = None
        self._lock = threading.Lock()

    def _target_frequency(self, elapsed: float) -> float:
        # Smoothly interpolate from base to fifth across the glide window that
        # starts at the end of phase A.
        if elapsed < self.phase_a_seconds:
            return self.base_hz
        glide_pos = (elapsed - self.phase_a_seconds) / self.glide_seconds
        if glide_pos >= 1.0:
            return self.fifth_hz
        # Cosine ease for a musical, click-free transition.
        eased = 0.5 - 0.5 * np.cos(np.pi * glide_pos)
        return self.base_hz + (self.fifth_hz - self.base_hz) * eased

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

        label = PHASE_A if elapsed < self.phase_a_seconds else PHASE_B
        with self._lock:
            if label != self._current_phase_label:
                self._current_phase_label = label
                target = self.base_hz if label == PHASE_A else self.fifth_hz
                log_event(f"phase={label} target_hz={target:.2f}")

        freq = self._target_frequency(elapsed)
        env = self._envelope(elapsed)

        # Per-sample phase accumulation keeps continuity across callbacks.
        phase_increment = 2.0 * np.pi * freq / self.sample_rate
        phases = self._phase + phase_increment * np.arange(1, frames + 1)
        self._phase = float(phases[-1] % (2.0 * np.pi))

        # Fundamental plus a quiet octave partial for warmth.
        fundamental = np.sin(phases)
        octave = 0.15 * np.sin(2.0 * phases)
        mono = self.amplitude * env * (fundamental + octave)

        outdata[:, 0] = mono
        if outdata.shape[1] > 1:
            outdata[:, 1] = mono


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=12.0,
                        help="total playback seconds")
    parser.add_argument("--phase-a-seconds", type=float, default=5.0,
                        help="seconds before gliding to the fifth")
    parser.add_argument("--glide-seconds", type=float, default=1.5,
                        help="seconds spent gliding between phases")
    parser.add_argument("--base-hz", type=float, default=220.0)
    parser.add_argument("--fifth-hz", type=float, default=330.0)
    parser.add_argument("--amplitude", type=float, default=0.25,
                        help="peak amplitude (0..1); kept moderate on purpose")
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--device", default=None,
                        help="optional sounddevice output device name/index")
    args = parser.parse_args()

    if args.device is not None:
        try:
            args.device = int(args.device)
        except ValueError:
            pass
        sd.default.device = (None, args.device)

    generator = ToneGenerator(
        sample_rate=args.sample_rate,
        base_hz=args.base_hz,
        fifth_hz=args.fifth_hz,
        phase_a_seconds=args.phase_a_seconds,
        glide_seconds=args.glide_seconds,
        amplitude=args.amplitude,
    )

    log_event(
        f"config sample_rate={args.sample_rate} base_hz={args.base_hz:.2f} "
        f"fifth_hz={args.fifth_hz:.2f} phase_a_seconds={args.phase_a_seconds:.2f} "
        f"glide_seconds={args.glide_seconds:.2f} duration={args.duration:.2f}"
    )

    try:
        with sd.OutputStream(samplerate=args.sample_rate, channels=2,
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
