#!/usr/bin/env python3
"""Detect a startup pop in a Background Music loopback recording.

Uses wall-clock timestamps plus the recorded tone onset so ffmpeg's capture
latency does not shift the inspect window onto the wrong part of the file.

Exit 0 always means the analysis ran. The JSON `noise` / `playthrough_ok`
fields are the verdict. Exit 2 means the recording cannot be analyzed.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import struct
import sys
import wave


def read_wav_mono(path: str) -> tuple[int, list[float]]:
    with wave.open(path, "rb") as w:
        nch = w.getnchannels()
        sw = w.getsampwidth()
        rate = w.getframerate()
        raw = w.readframes(w.getnframes())
        comptype = w.getcomptype()
    if comptype not in ("NONE", "not compressed"):
        raise SystemExit(f"unsupported wav compression: {comptype}")
    if sw == 2:
        fmt = "h"
        scale = 32768.0
    elif sw == 4:
        fmt = "i"
        scale = 2147483648.0
    else:
        raise SystemExit(f"unsupported sampwidth {sw}")
    if nch < 1:
        raise SystemExit("wav has no channels")
    frame_bytes = nch * sw
    usable = (len(raw) // frame_bytes) * frame_bytes
    raw = raw[:usable]
    n = usable // sw
    ints = struct.unpack("<" + fmt * n, raw)
    mono = []
    for i in range(0, len(ints), nch):
        acc = 0.0
        for c in range(nch):
            acc += ints[i + c] / scale
        mono.append(acc / nch)
    return rate, mono


def window_rms(x: list[float], start: int, length: int) -> float:
    if length <= 0:
        return 0.0
    end = min(len(x), start + length)
    if end <= start:
        return 0.0
    s = 0.0
    for i in range(start, end):
        v = x[i]
        s += v * v
    return math.sqrt(s / (end - start))


def slice_rms_series(x: list[float], start: int, end: int, hop: int) -> list[float]:
    values = []
    i = start
    while i + hop <= end and i + hop <= len(x):
        values.append(window_rms(x, i, hop))
        i += hop
    if not values and start < min(end, len(x)):
        values.append(window_rms(x, start, min(end, len(x)) - start))
    return values


def abs_diffs(x: list[float], start: int, end: int) -> list[float]:
    end = min(end, len(x))
    start = max(0, start)
    if end - start < 2:
        return [0.0]
    out = []
    prev = x[start]
    for i in range(start + 1, end):
        cur = x[i]
        d = cur - prev
        out.append(d if d >= 0.0 else -d)
        prev = cur
    return out


def percentile(sorted_vals: list[float], p: float) -> float:
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    idx = p * (len(sorted_vals) - 1)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return sorted_vals[lo]
    t = idx - lo
    return sorted_vals[lo] * (1.0 - t) + sorted_vals[hi] * t


def find_tone_onset(x: list[float], rate: int, threshold: float) -> int | None:
    hop = max(1, int(rate * 0.010))
    need = 5
    run = 0
    i = 0
    while i + hop <= len(x):
        if window_rms(x, i, hop) >= threshold:
            run += 1
            if run >= need:
                return i - hop * (need - 1)
        else:
            run = 0
        i += hop
    return None


def sec_to_index(sec: float, rate: int, n: int) -> int:
    i = int(round(sec * rate))
    if i < 0:
        return 0
    if i > n:
        return n
    return i


def find_jump_events(
    x: list[float],
    rate: int,
    ref_start: int,
    ref_end: int,
    scan_start: int,
    scan_end: int,
    jump_ratio_threshold: float = 3.0,
    min_gap_sec: float = 0.03,
) -> tuple[float, list[dict]]:
    ref_d = abs_diffs(x, ref_start, ref_end)
    p99 = percentile(sorted(ref_d), 0.99)
    if p99 <= 1e-6:
        return p99, []
    thresh = p99 * jump_ratio_threshold
    gap = max(1, int(rate * min_gap_sec))
    events = []
    last = -gap
    scan_end = min(scan_end, len(x))
    scan_start = max(1, scan_start)
    for i in range(scan_start, scan_end):
        d = x[i] - x[i - 1]
        ad = d if d >= 0.0 else -d
        if ad < thresh:
            continue
        if i - last < gap:
            if events and ad > events[-1]["abs_diff"]:
                events[-1] = {
                    "sec": i / float(rate),
                    "sample": i,
                    "abs_diff": ad,
                    "ratio": ad / p99,
                }
            continue
        events.append(
            {
                "sec": i / float(rate),
                "sample": i,
                "abs_diff": ad,
                "ratio": ad / p99,
            }
        )
        last = i
    return p99, events


def scan_file(wav_path: str, out_path: str) -> int:
    rate, x = read_wav_mono(wav_path)
    n = len(x)
    onset = find_tone_onset(x, rate, 0.01)
    result = {
        "mode": "scan_all",
        "wav": wav_path,
        "rate": rate,
        "n_samples": n,
        "duration_sec": n / float(rate) if rate else 0.0,
        "tone_onset_sec": None if onset is None else onset / float(rate),
        "jump_events": [],
        "jump_event_count": 0,
    }
    if onset is None:
        result["error"] = "no_tone_onset"
        _write(out_path, result)
        print(json.dumps(result, indent=2))
        return 2
    onset_sec = onset / float(rate)
    ref0 = sec_to_index(onset_sec + 0.25, rate, n)
    ref1 = sec_to_index(onset_sec + 1.00, rate, n)
    scan0 = sec_to_index(onset_sec + 0.25, rate, n)
    # Ignore the last 0.15s so tone-stop clicks are not counted as capture noise.
    scan1 = sec_to_index(max(0.0, n / float(rate) - 0.15), rate, n)
    p99, events = find_jump_events(x, rate, ref0, ref1, scan0, scan1)
    result["p99_ref_abs_diff"] = p99
    result["jump_events"] = events
    result["jump_event_count"] = len(events)
    _write(out_path, result)
    print(json.dumps(result, indent=2))
    print(f"JUMP_EVENTS={len(events)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wav", required=True)
    parser.add_argument("--times", default="")
    parser.add_argument("--out", required=True)
    parser.add_argument("--scan-all", action="store_true")
    args = parser.parse_args()

    if args.scan_all or not args.times:
        return scan_file(args.wav, args.out)

    with open(args.times, "r", encoding="utf-8") as f:
        times = json.load(f)

    rate, x = read_wav_mono(args.wav)
    n = len(x)
    duration = n / float(rate) if rate else 0.0

    play_wall = float(times["play_start"])
    app_wall = float(times["app_start"])
    # Quit is recorded but must not enter the inspect window.
    app_stop_wall = float(times.get("app_stop", app_wall + 3.0))

    onset = find_tone_onset(x, rate, 0.01)
    result = {
        "rate": rate,
        "n_samples": n,
        "duration_sec": duration,
        "tone_onset_sample": onset,
        "tone_onset_sec": None if onset is None else onset / float(rate),
        "noise": False,
        "playthrough_ok": False,
        "reasons": [],
        "metrics": {},
        "windows_sec": {},
    }

    if onset is None:
        result["reasons"].append("no_tone_onset")
        _write(args.out, result)
        print(json.dumps(result, indent=2))
        return 2

    dt_app = app_wall - play_wall
    dt_stop = app_stop_wall - play_wall
    onset_sec = onset / float(rate)

    baseline_start_sec = onset_sec + 0.25
    baseline_end_sec = onset_sec + dt_app - 0.08
    inspect_start_sec = onset_sec + dt_app - 0.05
    inspect_end_sec = onset_sec + dt_app + 0.80
    sustain_start_sec = onset_sec + dt_app + 0.80
    sustain_end_sec = onset_sec + min(dt_stop - 0.40, dt_app + 2.20)

    if baseline_end_sec <= baseline_start_sec + 0.15:
        result["reasons"].append("baseline_window_too_short")
        result["windows_sec"] = {
            "baseline": [baseline_start_sec, baseline_end_sec],
            "inspect": [inspect_start_sec, inspect_end_sec],
            "sustain": [sustain_start_sec, sustain_end_sec],
        }
        _write(args.out, result)
        print(json.dumps(result, indent=2))
        return 2

    result["windows_sec"] = {
        "baseline": [baseline_start_sec, baseline_end_sec],
        "inspect": [inspect_start_sec, inspect_end_sec],
        "sustain": [sustain_start_sec, sustain_end_sec],
    }

    b0 = sec_to_index(baseline_start_sec, rate, n)
    b1 = sec_to_index(baseline_end_sec, rate, n)
    i0 = sec_to_index(inspect_start_sec, rate, n)
    i1 = sec_to_index(inspect_end_sec, rate, n)
    s0 = sec_to_index(sustain_start_sec, rate, n)
    s1 = sec_to_index(sustain_end_sec, rate, n)

    hop = max(1, int(rate * 0.005))
    base_rms = slice_rms_series(x, b0, b1, hop)
    insp_rms = slice_rms_series(x, i0, i1, hop)
    sust_rms = slice_rms_series(x, s0, s1, hop)
    if not base_rms or not insp_rms or not sust_rms:
        result["reasons"].append("empty_rms_series")
        _write(args.out, result)
        print(json.dumps(result, indent=2))
        return 2

    median_base_rms = statistics.median(base_rms)
    max_insp_rms = max(insp_rms)
    min_insp_rms = min(insp_rms)
    median_sust_rms = statistics.median(sust_rms)

    base_d = abs_diffs(x, b0, b1)
    insp_d = abs_diffs(x, i0, i1)
    base_d_sorted = sorted(base_d)
    p99_base_d = percentile(base_d_sorted, 0.99)
    max_insp_d = max(insp_d) if insp_d else 0.0

    jump_ratio = max_insp_d / p99_base_d if p99_base_d > 1e-6 else float("inf")
    peak_ratio = max_insp_rms / median_base_rms if median_base_rms > 1e-6 else float("inf")
    dropout_ratio = min_insp_rms / median_base_rms if median_base_rms > 1e-6 else 0.0
    sustain_ratio = median_sust_rms / median_base_rms if median_base_rms > 1e-6 else 0.0

    result["metrics"] = {
        "median_baseline_rms": median_base_rms,
        "max_inspect_rms": max_insp_rms,
        "min_inspect_rms": min_insp_rms,
        "median_sustain_rms": median_sust_rms,
        "p99_baseline_abs_diff": p99_base_d,
        "max_inspect_abs_diff": max_insp_d,
        "jump_ratio": jump_ratio,
        "peak_ratio": peak_ratio,
        "dropout_ratio": dropout_ratio,
        "sustain_ratio": sustain_ratio,
        "thresholds": {
            "jump_ratio": 3.0,
            "peak_ratio": 1.6,
            "dropout_ratio": 0.35,
            "sustain_ratio": 0.45,
        },
    }

    if median_base_rms < 0.01:
        result["reasons"].append("baseline_too_quiet")
        _write(args.out, result)
        print(json.dumps(result, indent=2))
        return 2

    if jump_ratio >= 3.0:
        result["noise"] = True
        result["reasons"].append("sample_jump")
    if peak_ratio >= 1.6:
        result["noise"] = True
        result["reasons"].append("energy_spike")
    if dropout_ratio <= 0.35:
        result["noise"] = True
        result["reasons"].append("dropout")

    result["playthrough_ok"] = sustain_ratio >= 0.45
    if not result["playthrough_ok"]:
        result["reasons"].append("playthrough_lost")

    _write(args.out, result)
    print(json.dumps(result, indent=2))
    print(
        f"NOISE={str(result['noise']).lower()} "
        f"PLAYTHROUGH={str(result['playthrough_ok']).lower()} "
        f"reasons={','.join(result['reasons']) or 'none'}"
    )
    return 0


def _write(path: str, result: dict) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    sys.exit(main())
