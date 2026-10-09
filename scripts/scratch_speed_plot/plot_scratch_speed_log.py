#!/usr/bin/env python3
"""Validate a [SpeedLog] log and chart speedStart/speedEnd of every
processVariableRateBlock() call as a PNG (one call = one point, no reduction)."""

from __future__ import annotations

import argparse
import math
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


NUMBER = r"(?:[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[+-]?(?:nan|inf))"
RECORD_RE = re.compile(
    rf"\[SpeedLog\] speedStart\s*=\s*(?P<start>{NUMBER})\s*,\s*"
    rf"speedEnd\s*=\s*(?P<end>{NUMBER})\s*,\s*"
    rf"samples\s*=\s*(?P<samples>\d+)"
)
RECORD_LABEL_RE = re.compile(r"\[SpeedLog\] speedStart")
TIMESTAMP_RE = re.compile(r"^\s*Timestamp:\s*(?P<value>.+?)\s*$", re.MULTILINE)
DROPPED_RE = re.compile(r"\[SpeedLog\] WARNING dropped records total = (?P<n>\d+)")

# Consecutive calls are ~1 ms apart while the variable-rate path runs; a larger
# gap means the path was idle (normal playback), so the line is broken there.
GAP_BREAK_SEC = 0.05


class LogValidationError(ValueError):
    """Raised when input cannot be mapped safely to chart samples."""


@dataclass(frozen=True)
class Sample:
    timestamp: datetime
    speed_start: float
    speed_end: float
    num_samples: int


def parse_timestamp(value: str, position: int) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise LogValidationError(f"Invalid Timestamp #{position}: {value!r}") from exc
    if parsed.tzinfo is None:
        raise LogValidationError(
            f"Timestamp #{position} has no UTC offset/time zone: {value!r}"
        )
    return parsed


def parse_log(text: str) -> list[Sample]:
    records = list(RECORD_RE.finditer(text))
    timestamps = list(TIMESTAMP_RE.finditer(text))
    labels = len(RECORD_LABEL_RE.findall(text))

    if not records:
        raise LogValidationError("No complete [SpeedLog] records were found.")
    if labels != len(records):
        raise LogValidationError(
            "A [SpeedLog] entry is missing a value or has an invalid numeric value "
            f"(labels: {labels}, complete records: {len(records)})."
        )
    if len(records) != len(timestamps):
        raise LogValidationError(
            "Record/Timestamp count mismatch: "
            f"{len(records)} complete [SpeedLog] records, {len(timestamps)} Timestamps."
        )

    samples: list[Sample] = []
    for index, (record, timestamp_match) in enumerate(zip(records, timestamps), start=1):
        if record.start() > timestamp_match.start():
            raise LogValidationError(
                f"Timestamp #{index} appears before its [SpeedLog] record; log order is invalid."
            )
        speed_start = float(record.group("start"))
        speed_end = float(record.group("end"))
        if not all(math.isfinite(value) for value in (speed_start, speed_end)):
            raise LogValidationError(f"Record #{index} contains a non-finite speed value.")
        samples.append(
            Sample(
                parse_timestamp(timestamp_match.group("value"), index),
                speed_start,
                speed_end,
                int(record.group("samples")),
            )
        )

    for index, (previous, current) in enumerate(zip(samples, samples[1:]), start=2):
        if current.timestamp < previous.timestamp:
            raise LogValidationError(
                f"Timestamp #{index} is earlier than Timestamp #{index - 1}; log order is invalid."
            )
    return samples


def with_gap_breaks(xs: list[float], ys: list[float]) -> tuple[list[float], list[float]]:
    """Insert NaN between points separated by an idle gap so no line bridges it.
    Every real point is kept."""
    out_x: list[float] = []
    out_y: list[float] = []
    for i, (x, y) in enumerate(zip(xs, ys)):
        if i > 0 and x - xs[i - 1] > GAP_BREAK_SEC:
            out_x.append(math.nan)
            out_y.append(math.nan)
        out_x.append(x)
        out_y.append(y)
    return out_x, out_y


def make_plot(
    samples: list[Sample], output: Path, title: str, width: float | None,
    t_min: float | None, t_max: float | None,
) -> tuple[int, float, float]:
    elapsed_all = [
        (sample.timestamp - samples[0].timestamp).total_seconds() for sample in samples
    ]
    lo = -math.inf if t_min is None else t_min
    hi = math.inf if t_max is None else t_max
    selected = [(t, s) for t, s in zip(elapsed_all, samples) if lo <= t <= hi]
    if not selected:
        raise LogValidationError("No samples fall inside the requested time window.")
    elapsed = [t for t, _ in selected]
    speed_start = [s.speed_start for _, s in selected]
    speed_end = [s.speed_end for _, s in selected]

    duration = elapsed[-1] - elapsed[0]
    fig_width = width if width is not None else min(max(12.0, duration * 1.5), 80.0)

    output.parent.mkdir(parents=True, exist_ok=True)
    fig, axis = plt.subplots(figsize=(fig_width, 6), constrained_layout=True)
    # Reverse x0.5..x2.0 is the range being tuned.
    axis.axhspan(-2.0, -0.5, color="#CC79A7", alpha=0.10, label="Reverse x0.5..x2.0")
    # Okabe-Ito colors remain distinguishable for common color-vision differences.
    axis.plot(
        *with_gap_breaks(elapsed, speed_start), label="speedStart", color="#0072B2",
        linewidth=0.8, linestyle="-", marker="o", markersize=1.6,
    )
    axis.plot(
        *with_gap_breaks(elapsed, speed_end), label="speedEnd", color="#D55E00",
        linewidth=0.8, linestyle=":", marker="s", markersize=1.2,
    )
    axis.axhline(0, color="black", linewidth=0.9, linestyle="--", label="0")
    axis.grid(True, alpha=0.35)
    axis.set_xlabel("Elapsed time from first Timestamp [s]")
    axis.set_ylabel("Speed rate (processVariableRateBlock)")
    axis.set_title(title)
    axis.legend(loc="upper right")
    fig.savefig(output, dpi=160)
    plt.close(fig)
    return len(selected), elapsed[0], elapsed[-1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Input log text file")
    parser.add_argument("output", type=Path, help="Output PNG path")
    parser.add_argument(
        "--title", default="Scratch speed per processVariableRateBlock() call",
        help="Chart title",
    )
    parser.add_argument("--width", type=float, default=None, help="Figure width in inches")
    parser.add_argument("--t-min", type=float, default=None, help="Window start [s] (zoom)")
    parser.add_argument("--t-max", type=float, default=None, help="Window end [s] (zoom)")
    args = parser.parse_args()

    try:
        text = args.input.read_text(encoding="utf-8-sig", errors="replace")
        samples = parse_log(text)
        count, start, end = make_plot(
            samples, args.output, args.title, args.width, args.t_min, args.t_max
        )
    except (OSError, LogValidationError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    dropped = [int(m.group("n")) for m in DROPPED_RE.finditer(text)]
    print(f"Created: {args.output}")
    print(f"Samples: {count} (of {len(samples)} in log)")
    print(f"Elapsed range: {start:.6f} to {end:.6f} s")
    print(f"Dropped records reported by app: {max(dropped) if dropped else 0}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
