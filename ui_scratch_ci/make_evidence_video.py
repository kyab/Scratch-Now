#!/usr/bin/env python3
"""Mux the screen recording and the app's rendered output audio into one file.

The CI runner has no audio loopback device, so the screen capture is video
only. The app under test dumps exactly what it renders to the speaker as raw
PCM (output.pcm + output_pcm_meta.json with the wall-clock start time). This
script aligns the two on the wall clock and produces evidence.mp4: the GUI
interaction (with the mouse cursor) plus the audible scratch effect.

Alignment model:

* Video: the wall-clock capture end is recorded by the harness just before it
  signals ffmpeg to stop. The capture start is that stop time minus the last
  video packet's presentation time.
* Audio: the runner's virtual audio device does NOT consume samples at the
  nominal rate (observed ~2-3% slow), so interpreting the PCM as 48 kHz makes
  the audio drift ahead of the video by more than a second over a ~35 s run.
  The app logs cumulative rendered frame counts with wall-clock timestamps to
  output.jsonl; a least-squares fit of frames-vs-time yields the *effective*
  sample rate and the wall-clock time of PCM sample 0. The raw PCM input is
  declared at the effective rate (then resampled to 48 kHz for AAC), which
  pins the audio timeline to the wall clock with no cumulative drift.

After muxing, the audio track is decoded back and the longest silent run (the
table-stop window) is compared against the click timestamps in phases.json as
a sync self-check; the residual error is printed to the log.
"""

import argparse
import json
import struct
import subprocess
import sys

NOMINAL_RATE_TOLERANCE = 0.10  # reject fits further than 10% from nominal
SILENCE_RMS_THRESHOLD = 0.01
SILENCE_WINDOW_SECONDS = 0.010


def probe_last_video_pts(ffprobe: str, path: str) -> float:
    """Wall-clock length of the capture: last video packet pts + one frame."""
    result = subprocess.run(
        [ffprobe, "-v", "quiet", "-select_streams", "v:0",
         "-show_entries", "packet=pts_time", "-of", "json", path],
        capture_output=True, text=True, check=True)
    packets = json.loads(result.stdout).get("packets", [])
    pts = [float(p["pts_time"]) for p in packets if "pts_time" in p]
    if not pts:
        raise RuntimeError(f"no video packets found in {path}")
    frame_duration = (pts[-1] - pts[0]) / max(len(pts) - 1, 1)
    return max(pts) + frame_duration


def fit_audio_clock(output_jsonl: str, nominal_rate: float, fallback_t0: float):
    """Least-squares fit of framesTotal vs wall time -> (rate Hz, t0 of sample 0)."""
    points = []
    with open(output_jsonl, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            if "ts" in entry and "framesTotal" in entry:
                points.append((float(entry["ts"]), float(entry["framesTotal"])))
    if len(points) < 5:
        print(f"[mux] WARNING: only {len(points)} clock points in "
              f"{output_jsonl}; falling back to nominal rate", flush=True)
        return nominal_rate, fallback_t0
    mean_ts = sum(ts for ts, _ in points) / len(points)
    mean_fr = sum(fr for _, fr in points) / len(points)
    denom = sum((ts - mean_ts) ** 2 for ts, _ in points)
    slope = sum((ts - mean_ts) * (fr - mean_fr) for ts, fr in points) / denom
    if abs(slope / nominal_rate - 1.0) > NOMINAL_RATE_TOLERANCE:
        print(f"[mux] WARNING: fitted rate {slope:.1f} Hz implausible vs "
              f"nominal {nominal_rate:.0f} Hz; falling back", flush=True)
        return nominal_rate, fallback_t0
    t0 = mean_ts - mean_fr / slope
    return slope, t0


def decode_mono_f32(ffmpeg: str, path: str, rate: int) -> list:
    result = subprocess.run(
        [ffmpeg, "-v", "quiet", "-i", path,
         "-f", "f32le", "-ar", str(rate), "-ac", "1", "-"],
        capture_output=True, check=True)
    raw = result.stdout
    count = len(raw) // 4
    return list(struct.unpack(f"<{count}f", raw[:count * 4]))


def longest_silent_run(samples: list, rate: int):
    """Return (start_sec, end_sec) of the longest silent stretch, or None."""
    window = max(int(rate * SILENCE_WINDOW_SECONDS), 1)
    silent_flags = []
    for offset in range(0, len(samples) - window + 1, window):
        chunk = samples[offset:offset + window]
        rms = (sum(v * v for v in chunk) / len(chunk)) ** 0.5
        silent_flags.append(rms < SILENCE_RMS_THRESHOLD)
    best = current = None
    for index, silent in enumerate(silent_flags):
        if silent:
            if current is None:
                current = [index, index]
            else:
                current[1] = index
        else:
            if current is not None:
                if best is None or (current[1] - current[0]) > (best[1] - best[0]):
                    best = current
                current = None
    if current is not None and (best is None
                                or (current[1] - current[0]) > (best[1] - best[0])):
        best = current
    if best is None:
        return None
    seconds_per_window = window / rate
    return best[0] * seconds_per_window, (best[1] + 1) * seconds_per_window


def sync_self_check(ffmpeg: str, out_path: str, phases_path: str,
                    video_start: float) -> None:
    with open(phases_path, "r", encoding="utf-8") as handle:
        phases = {p["name"]: p for p in json.load(handle)["phases"]}
    stop_phase = phases.get("stopRamp")
    resume_phase = phases.get("resumeFromStop")
    if stop_phase is None or resume_phase is None:
        print("[mux] sync check skipped: stop phases missing", flush=True)
        return
    probe_rate = 8000
    samples = decode_mono_f32(ffmpeg, out_path, probe_rate)
    run = longest_silent_run(samples, probe_rate)
    if run is None:
        print("[mux] sync check skipped: no silent run found", flush=True)
        return
    silence_start, silence_end = run
    # The resume click's mouseUp is ~0.10 s into the phase and the app fades
    # back in within ~10 ms, so the silence end is a sharp, predictable edge.
    expected_end = resume_phase["start"] + 0.10 - video_start
    delta_end = silence_end - expected_end
    print(f"[mux] sync check: silence {silence_start:.2f}-{silence_end:.2f}s "
          f"(video time); resume click expected at {expected_end:.2f}s; "
          f"audio-vs-click residual {delta_end:+.3f}s", flush=True)
    if abs(delta_end) > 0.35:
        print(f"[mux] WARNING: residual audio offset {delta_end:+.3f}s "
              f"exceeds 0.35s", flush=True)


def run_mux(args, skip: float, rate: int, burn_timestamp: bool) -> int:
    video_filter = []
    if burn_timestamp:
        # Burnt-in elapsed time lets a human verify sync frame by frame.
        video_filter = [
            "-vf",
            "drawtext=text='%{pts\\:hms}':fontcolor=yellow:fontsize=28:"
            "box=1:boxcolor=black@0.5:x=8:y=8",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
        ]
    else:
        video_filter = ["-c:v", "copy"]
    cmd = [args.ffmpeg, "-hide_banner", "-loglevel", "warning", "-y",
           "-i", args.video,
           "-ss", f"{skip:.3f}",
           "-f", "f32le", "-ar", str(rate), "-ac", "1",
           "-i", args.pcm,
           "-map", "0:v", "-map", "1:a",
           *video_filter,
           "-c:a", "aac", "-b:a", "128k", "-ar", "48000",
           "-shortest", "-movflags", "+faststart",
           args.out]
    print(f"[mux] {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd).returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", required=True)
    parser.add_argument("--pcm", required=True)
    parser.add_argument("--pcm-meta", required=True)
    parser.add_argument("--output-jsonl", default=None,
                        help="app render log used to fit the effective "
                             "sample rate against the wall clock")
    parser.add_argument("--phases", default=None,
                        help="driver phases.json for the post-mux sync check")
    parser.add_argument("--out", required=True)
    parser.add_argument("--video-stop-ts", type=float, required=True,
                        help="wall-clock time just before ffmpeg was stopped")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    args = parser.parse_args()

    with open(args.pcm_meta, "r", encoding="utf-8") as handle:
        meta = json.load(handle)
    nominal_rate = float(meta["sampleRate"])
    meta_start = float(meta["startTs"])

    if args.output_jsonl:
        rate, pcm_t0 = fit_audio_clock(args.output_jsonl, nominal_rate,
                                       meta_start)
    else:
        rate, pcm_t0 = nominal_rate, meta_start
    print(f"[mux] audio clock: effective rate={rate:.1f} Hz "
          f"(nominal {nominal_rate:.0f}, {((rate / nominal_rate) - 1) * 100:+.2f}%) "
          f"sample0 wall={pcm_t0:.3f} (meta {meta_start:.3f})", flush=True)

    duration = probe_last_video_pts(args.ffprobe, args.video)
    video_start = args.video_stop_ts - duration
    skip = video_start - pcm_t0
    print(f"[mux] video span={duration:.3f}s start={video_start:.3f} "
          f"-> audio skip={skip:.3f}s", flush=True)
    if skip < 0:
        # Audio began after the video; keep sync by not skipping and accept
        # that the first |skip| seconds of video have no audio reference.
        print(f"[mux] WARNING: audio starts {-skip:.3f}s after video; "
              f"clamping skip to 0", flush=True)
        skip = 0.0

    rate_int = int(round(rate))
    code = run_mux(args, skip, rate_int, burn_timestamp=True)
    if code != 0:
        # drawtext needs fontconfig; fall back to a plain stream copy.
        print("[mux] WARNING: timestamp overlay failed; retrying with "
              "video stream copy", flush=True)
        code = run_mux(args, skip, rate_int, burn_timestamp=False)
    if code != 0:
        return code

    if args.phases:
        try:
            sync_self_check(args.ffmpeg, args.out, args.phases, video_start)
        except Exception as error:  # diagnostics only; never fail the mux
            print(f"[mux] sync check errored: {error}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
