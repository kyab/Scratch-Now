#!/usr/bin/env python3
"""Assert that the UI-driven scratch changed the app's audible output.

Inputs (all produced during the run):
  output.jsonl : per-second peak/rms/zero-crossing pitch estimate of what the
                 app rendered to the speaker (written by the CI build).
  scratch.jsonl: 10 Hz scratch state stream (speedRate, pressing, ...) used to
                 verify direction and that the synthetic mouse events actually
                 reached the view.
  phases.json  : phase timeline written by drive_scratch.py (unix timestamps).

Expectations:
  baseline : ~220 Hz at 1x playthrough.
  reverse  : platter dragged backward at -1x -> audio keeps flowing and the
             DSP speed goes negative (a reversed sine keeps its pitch, so the
             direction check uses the state stream).
  forward2x: platter dragged forward at 2x -> output pitch doubles (~440 Hz).
             This is the audible scratch effect under test.
  release  : back to ~220 Hz at 1x.
"""

import json
import statistics
import sys

STATUS_DIR = "/tmp/scratch-now-tap-smoke-ci"
OUTPUT_FILE = f"{STATUS_DIR}/output.jsonl"
SCRATCH_FILE = f"{STATUS_DIR}/scratch.jsonl"
PHASES_FILE = f"{STATUS_DIR}/phases.json"

BASE_HZ = 220.0
DOUBLE_HZ = 440.0
MIN_RMS = 0.005
# Each output.jsonl line aggregates roughly the second ending at ts.
LINE_SPAN = 1.0
END_SLACK = 0.3


def load_jsonl(path):
    entries = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    return entries


def lines_in_window(entries, start, end, head_trim):
    return [e for e in entries
            if e.get("ts", 0.0) - LINE_SPAN >= start + head_trim
            and e.get("ts", 0.0) <= end + END_SLACK]


def state_in_window(entries, start, end, head_trim):
    return [e for e in entries
            if start + head_trim <= e.get("ts", 0.0) <= end]


def describe(name, lines):
    hz = ", ".join(f"{e.get('estimatedHz', 0.0):.0f}" for e in lines)
    rms = ", ".join(f"{e.get('rms', 0.0):.4f}" for e in lines)
    print(f"  {name}: estimatedHz=[{hz}] rms=[{rms}]")


def main() -> int:
    output = load_jsonl(OUTPUT_FILE)
    scratch = load_jsonl(SCRATCH_FILE)
    try:
        with open(PHASES_FILE, "r", encoding="utf-8") as handle:
            phases = {p["name"]: p for p in json.load(handle)["phases"]}
    except (FileNotFoundError, KeyError, json.JSONDecodeError) as exc:
        print(f"FAIL: cannot load phase timeline: {exc}")
        return 2

    if not output:
        print(f"FAIL: no output status lines in {OUTPUT_FILE}")
        return 2
    print(f"loaded {len(output)} output lines, {len(scratch)} scratch state lines")

    failures = []

    def expect(condition, message):
        if condition:
            print(f"PASS: {message}")
        else:
            print(f"FAIL: {message}")
            failures.append(message)

    def median_hz(lines):
        return statistics.median(e.get("estimatedHz", 0.0) for e in lines)

    def max_rms(lines):
        return max(e.get("rms", 0.0) for e in lines)

    # Baseline: normal 1x playthrough of the 220 Hz tone.
    phase = phases["baseline"]
    lines = lines_in_window(output, phase["start"], phase["end"], head_trim=0.5)
    describe("baseline", lines)
    expect(len(lines) >= 1, "baseline produced output status lines")
    if lines:
        expect(max_rms(lines) >= MIN_RMS, "baseline output is non-silent")
        hz = median_hz(lines)
        expect(abs(hz - BASE_HZ) <= 40.0,
               f"baseline pitch ~{BASE_HZ:.0f} Hz (got {hz:.0f})")

    # Reverse: audio keeps flowing and the DSP runs at negative speed.
    phase = phases["reverse"]
    lines = lines_in_window(output, phase["start"], phase["end"], head_trim=1.0)
    describe("reverse", lines)
    expect(len(lines) >= 1, "reverse produced output status lines")
    if lines:
        expect(max_rms(lines) >= MIN_RMS, "reverse playback is non-silent")
        hz = median_hz(lines)
        expect(abs(hz - BASE_HZ) <= 60.0,
               f"reverse pitch ~{BASE_HZ:.0f} Hz (got {hz:.0f})")
    states = state_in_window(scratch, phase["start"], phase["end"], head_trim=1.0)
    expect(len(states) >= 5, "reverse recorded scratch state samples")
    if states:
        pressing_ratio = sum(s.get("pressing", 0) for s in states) / len(states)
        expect(pressing_ratio >= 0.9,
               f"synthetic mouse press reached the turntable "
               f"(pressing ratio {pressing_ratio:.2f})")
        speed = statistics.median(s.get("smoothedSpeed", 0.0) for s in states)
        expect(speed < -0.5,
               f"reverse drag drove a negative DSP speed (got {speed:.2f})")

    # Forward 2x: the audible effect — output pitch doubles.
    phase = phases["forward2x"]
    lines = lines_in_window(output, phase["start"], phase["end"], head_trim=1.25)
    describe("forward2x", lines)
    expect(len(lines) >= 1, "forward2x produced output status lines")
    if lines:
        expect(max_rms(lines) >= MIN_RMS, "forward2x playback is non-silent")
        hz = median_hz(lines)
        expect(abs(hz - DOUBLE_HZ) <= 90.0,
               f"forward2x pitch ~{DOUBLE_HZ:.0f} Hz, i.e. scratch doubled "
               f"the pitch (got {hz:.0f})")
    states = state_in_window(scratch, phase["start"], phase["end"], head_trim=1.0)
    if states:
        speed = statistics.median(s.get("smoothedSpeed", 0.0) for s in states)
        expect(speed > 1.5,
               f"forward drag drove the DSP speed to ~2x (got {speed:.2f})")

    # Release: platter returns to 1x.
    phase = phases["release"]
    lines = lines_in_window(output, phase["start"], phase["end"], head_trim=1.5)
    describe("release", lines)
    expect(len(lines) >= 1, "release produced output status lines")
    if lines:
        hz = median_hz(lines)
        expect(abs(hz - BASE_HZ) <= 40.0,
               f"release returned to ~{BASE_HZ:.0f} Hz (got {hz:.0f})")

    if failures:
        print(f"FAILURES ({len(failures)}):")
        for message in failures:
            print(f"  - {message}")
        return 1

    print("OK: UI scratch E2E checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
