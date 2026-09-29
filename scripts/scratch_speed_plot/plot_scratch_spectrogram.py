#!/usr/bin/env python3
"""Plot the spectrogram of the captured Scratch Now output WAV together with the
[SpeedLog] speed of every processVariableRateBlock() call on the same time axis.

Time axis = output frame / sample rate. Each [SpeedLog] record carries the output
frame of its callback start (within one output callback, i.e. <= 32 frames).
Intervals with |speed| > 1 are shaded. With --tone-hz, the frequencies where each
test tone and its first interpolation images should land (after folding at Nyquist)
are overlaid per call, so aliased components can be told apart from real ones."""

from __future__ import annotations

import argparse
import math
import re
import struct
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


NUMBER = r"(?:[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[+-]?(?:nan|inf))"
RECORD_RE = re.compile(
    rf"\[SpeedLog\] speedStart\s*=\s*(?P<start>{NUMBER})\s*,\s*"
    rf"speedEnd\s*=\s*(?P<end>{NUMBER})\s*,\s*"
    rf"samples\s*=\s*(?P<samples>\d+)\s*,\s*"
    rf"outputFrame\s*=\s*(?P<frame>\d+)"
)
RECORD_LABEL_RE = re.compile(r"\[SpeedLog\] speedStart")
CAPTURE_DROP_RE = re.compile(r"WARNING dropped output capture frames total = (?P<n>\d+)")
RECORD_DROP_RE = re.compile(r"WARNING dropped records total = (?P<n>\d+)")

# Consecutive calls are <= 1 callback apart while the variable-rate path runs.
GAP_BREAK_SEC = 0.05


class InputError(ValueError):
    pass


def read_float_wav(path: Path) -> tuple[np.ndarray, int]:
    data = path.read_bytes()
    if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise InputError(f"{path} is not a RIFF/WAVE file.")
    pos = 12
    fmt = None
    while pos + 8 <= len(data):
        chunk_id = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if chunk_id == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif chunk_id == b"data":
            if fmt is None:
                raise InputError("data chunk before fmt chunk.")
            audio_format, channels, rate, _, _, bits = fmt
            if audio_format != 3 or bits != 32:
                raise InputError(f"Expected 32-bit float WAV, got format={audio_format} bits={bits}.")
            usable = len(body) - len(body) % (4 * channels)
            frames = np.frombuffer(body[:usable], dtype="<f4").reshape(-1, channels)
            return frames, rate
        pos += 8 + size + (size & 1)
    raise InputError("No data chunk found.")


def parse_log(text: str) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    records = list(RECORD_RE.finditer(text))
    labels = len(RECORD_LABEL_RE.findall(text))
    if not records:
        raise InputError("No [SpeedLog] records with outputFrame were found.")
    if labels != len(records):
        raise InputError(f"Malformed [SpeedLog] records (labels: {labels}, complete: {len(records)}).")
    start = np.array([float(m.group("start")) for m in records])
    end = np.array([float(m.group("end")) for m in records])
    frame = np.array([int(m.group("frame")) for m in records], dtype=np.int64)
    if not (np.all(np.isfinite(start)) and np.all(np.isfinite(end))):
        raise InputError("Non-finite speed value in log.")
    if np.any(np.diff(frame) < 0):
        raise InputError("outputFrame is not monotonic; log order is invalid.")
    return start, end, frame


def stft_db(x: np.ndarray, rate: int, nfft: int, hop: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    window = np.hanning(nfft).astype(np.float64)
    count = 1 + max(0, (len(x) - nfft) // hop)
    idx = np.arange(nfft)[None, :] + hop * np.arange(count)[:, None]
    spec = np.fft.rfft(x[idx] * window, axis=1)
    power = (np.abs(spec) ** 2) / (window.sum() ** 2)
    db = 10.0 * np.log10(power + 1e-20)
    times = (np.arange(count) * hop + nfft / 2) / rate
    freqs = np.fft.rfftfreq(nfft, 1.0 / rate)
    return times, freqs, db.T


def fold(freq: np.ndarray, rate: float) -> np.ndarray:
    f = np.mod(freq, rate)
    return np.where(f > rate / 2, rate - f, f)


def with_gap_breaks(xs: np.ndarray, ys: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    breaks = np.where(np.diff(xs) > GAP_BREAK_SEC)[0] + 1
    return np.insert(xs, breaks, np.nan), np.insert(ys, breaks, np.nan)


def fast_spans(t: np.ndarray, speed: np.ndarray, block_sec: float) -> list[tuple[float, float]]:
    spans: list[tuple[float, float]] = []
    fast = np.abs(speed) > 1.0
    i = 0
    while i < len(t):
        if not fast[i]:
            i += 1
            continue
        j = i
        while j + 1 < len(t) and fast[j + 1] and t[j + 1] - t[j] <= GAP_BREAK_SEC:
            j += 1
        spans.append((t[i], t[j] + block_sec))
        i = j + 1
    return spans


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("wav", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--tone-hz", type=float, nargs="*", default=[], help="Test tone frequencies to overlay")
    parser.add_argument("--t-min", type=float, default=None)
    parser.add_argument("--t-max", type=float, default=None)
    parser.add_argument("--nfft", type=int, default=2048)
    parser.add_argument("--hop", type=int, default=128)
    parser.add_argument("--width", type=float, default=None)
    parser.add_argument("--title", default="Scratch Now output spectrogram vs speed")
    args = parser.parse_args()

    try:
        text = args.log.read_text(encoding="utf-8-sig", errors="replace")
        speed_start, speed_end, frame = parse_log(text)
        audio, rate = read_float_wav(args.wav)
    except (OSError, InputError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    t_call = frame / rate
    x = audio[:, 0].astype(np.float64)
    t_audio_end = len(x) / rate
    lo = args.t_min if args.t_min is not None else 0.0
    hi = args.t_max if args.t_max is not None else t_audio_end
    a0, a1 = int(lo * rate), min(len(x), int(hi * rate))
    if a1 - a0 < args.nfft:
        print("ERROR: time window is shorter than one FFT frame.", file=sys.stderr)
        return 1
    times, freqs, db = stft_db(x[a0:a1], rate, args.nfft, args.hop)
    times += a0 / rate
    sel = (t_call >= lo) & (t_call <= hi)

    duration = hi - lo
    fig_width = args.width if args.width is not None else min(max(14.0, duration * 1.5), 80.0)
    fig, (ax_spec, ax_speed) = plt.subplots(
        2, 1, figsize=(fig_width, 9), sharex=True, constrained_layout=True,
        gridspec_kw={"height_ratios": [3, 1.2]},
    )
    vmax = np.percentile(db, 99.9)
    mesh = ax_spec.pcolormesh(times, freqs / 1000.0, db, shading="auto", cmap="magma",
                              vmin=vmax - 100.0, vmax=vmax)
    fig.colorbar(mesh, ax=ax_spec, label="Power [dB, left channel]", pad=0.005)

    block_sec = 32 / rate
    spans = fast_spans(t_call[sel], speed_end[sel], block_sec)
    for s0, s1 in spans:
        ax_speed.axvspan(s0, s1, color="#56B4E9", alpha=0.25, lw=0)
        ax_spec.axvspan(s0, s1, ymin=0.985, ymax=1.0, color="#56B4E9", lw=0)

    # Okabe-Ito colors; each overlay point is one call.
    tone_colors = ["#009E73", "#F0E442", "#0072B2", "#CC79A7"]
    abs_speed = np.abs(speed_end[sel])
    tc = t_call[sel]
    for k, f0 in enumerate(args.tone_hz):
        color = tone_colors[k % len(tone_colors)]
        main = abs_speed * f0
        aliased = main > rate / 2
        direct = np.where(aliased, np.nan, main)
        folded = np.where(aliased, fold(main, rate), np.nan)
        ax_spec.plot(*with_gap_breaks(tc, direct / 1000.0), color=color, lw=0.6, ls="-",
                     marker=".", ms=1.0, label=f"{f0/1000:g} kHz x |speed| (expected)")
        ax_spec.plot(*with_gap_breaks(tc, folded / 1000.0), color=color, lw=0.9, ls="--",
                     marker=".", ms=1.0, label=f"{f0/1000:g} kHz x |speed| folded at Nyquist (alias)")
        image = fold(abs_speed * (rate - f0), rate)
        ax_spec.plot(*with_gap_breaks(tc, image / 1000.0), color=color, lw=0.6, ls=":",
                     marker=".", ms=1.0, label=f"{f0/1000:g} kHz 1st interpolation image")
    ax_spec.axhline(rate / 2000.0, color="white", lw=0.6, ls="--")
    ax_spec.set_ylim(0, rate / 2000.0)
    ax_spec.set_ylabel("Frequency [kHz]")
    ax_spec.set_title(args.title)
    if args.tone_hz:
        ax_spec.legend(loc="lower right", fontsize=7, framealpha=0.6)

    ax_speed.plot(*with_gap_breaks(tc, speed_start[sel]), color="#0072B2", lw=0.8, ls="-",
                  marker="o", ms=1.4, label="speedStart")
    ax_speed.plot(*with_gap_breaks(tc, speed_end[sel]), color="#D55E00", lw=0.8, ls=":",
                  marker="s", ms=1.0, label="speedEnd")
    for y in (1.0, -1.0):
        ax_speed.axhline(y, color="#56B4E9", lw=0.8, ls="--")
    ax_speed.axhline(0, color="black", lw=0.8, ls="--")
    ax_speed.grid(True, alpha=0.35)
    ax_speed.set_ylabel("Speed rate")
    ax_speed.set_xlabel("Output time [s] (output frame / sample rate)")
    ax_speed.legend(loc="upper right", fontsize=8)
    ax_speed.set_xlim(lo, hi)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=150)
    plt.close(fig)

    cap_drop = [int(m.group("n")) for m in CAPTURE_DROP_RE.finditer(text)]
    rec_drop = [int(m.group("n")) for m in RECORD_DROP_RE.finditer(text)]
    print(f"Created: {args.output}")
    print(f"Audio: {len(x)} frames @ {rate} Hz ({t_audio_end:.3f} s)")
    print(f"Calls in window: {int(sel.sum())} of {len(frame)}")
    print(f"|speed|>1 spans in window: {len(spans)}")
    print(f"Dropped: records {max(rec_drop) if rec_drop else 0}, capture frames {max(cap_drop) if cap_drop else 0}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
