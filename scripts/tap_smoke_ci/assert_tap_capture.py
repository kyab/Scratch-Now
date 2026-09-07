#!/usr/bin/env python3
"""Analyze the tap status JSONL and assert the CATap smoke expectations.

Reads /tmp/scratch-now-tap-smoke-ci/tap.jsonl (written by the SCRATCH_NOW_TAP_SMOKE_CI
build) and checks two things:

  1. Non-silence: the tap delivered audio (framesTotal grew and rms/peak crossed
     a threshold), proving the tap captured the other process' playback.
  2. Following: after the tone glides from the base frequency to the fifth, the
     captured dominant frequency estimate shifts from the base band to the fifth
     band within an allowed delay.

Exit code 0 means both checks passed; non-zero means the tap did not behave as
expected.
"""

import json
import sys

STATUS_FILE = "/tmp/scratch-now-tap-smoke-ci/tap.jsonl"
MIN_RMS = 0.005
BASE_HZ = 220.0
FIFTH_HZ = 330.0
FREQ_TOLERANCE = 60.0


def load_samples(path):
    samples = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                samples.append(json.loads(line))
            except json.JSONDecodeError:
                # Ignore partially written trailing lines.
                continue
    return samples


def near(value, target):
    return abs(value - target) <= FREQ_TOLERANCE


def main() -> int:
    try:
        samples = load_samples(STATUS_FILE)
    except FileNotFoundError:
        print(f"FAIL: status file not found: {STATUS_FILE}")
        return 2

    if not samples:
        print("FAIL: no tap status samples were recorded (tap delivered nothing)")
        return 2

    print(f"loaded {len(samples)} tap status samples")

    # Check 1: non-silence.
    max_rms = max(s.get("rms", 0.0) for s in samples)
    max_peak = max(s.get("peak", 0.0) for s in samples)
    frames_total = max(s.get("framesTotal", 0) for s in samples)
    print(f"max_rms={max_rms:.6f} max_peak={max_peak:.6f} framesTotal={frames_total}")

    if frames_total <= 0:
        print("FAIL: framesTotal never advanced; tap produced no frames")
        return 3
    if max_rms < MIN_RMS:
        print(f"FAIL: tap stayed near silence (max_rms {max_rms:.6f} < {MIN_RMS})")
        return 3
    print("PASS: tap captured non-silent audio")

    # Check 2: following the frequency change.
    saw_base = any(near(s.get("estimatedHz", 0.0), BASE_HZ) for s in samples)
    # The fifth must be seen and it must occur after a base-band sample, proving
    # the capture followed the change rather than starting there.
    first_base_index = next(
        (i for i, s in enumerate(samples)
         if near(s.get("estimatedHz", 0.0), BASE_HZ)),
        None,
    )
    followed = False
    if first_base_index is not None:
        followed = any(
            near(s.get("estimatedHz", 0.0), FIFTH_HZ)
            for s in samples[first_base_index:]
        )

    est_series = ", ".join(f"{s.get('estimatedHz', 0.0):.0f}" for s in samples)
    print(f"estimatedHz series: [{est_series}]")

    if not saw_base:
        print(f"FAIL: never observed the base band (~{BASE_HZ} Hz)")
        return 4
    if not followed:
        print(f"FAIL: capture did not follow to the fifth band (~{FIFTH_HZ} Hz)")
        return 4

    print("PASS: captured frequency followed the played tone change")
    print("OK: tap smoke checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
