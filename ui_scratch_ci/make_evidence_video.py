#!/usr/bin/env python3
"""Mux the screen recording and the app's rendered output audio into one file.

The CI runner has no audio loopback device, so the screen capture is video
only. The app under test dumps exactly what it renders to the speaker as raw
PCM (output.pcm + output_pcm_meta.json with the wall-clock start time). This
script aligns the two on the wall clock and produces evidence.mp4: the GUI
interaction (with the mouse cursor) plus the audible scratch effect.

Alignment: the capture start time is derived from the wall-clock stop time
(recorded by the harness just before it signals ffmpeg to stop) minus the
video duration reported by ffprobe. That avoids guessing how long ffmpeg took
to initialize the screen device.
"""

import argparse
import json
import subprocess
import sys


def probe_duration(ffprobe: str, path: str) -> float:
    result = subprocess.run(
        [ffprobe, "-v", "quiet", "-print_format", "json", "-show_format", path],
        capture_output=True, text=True, check=True)
    return float(json.loads(result.stdout)["format"]["duration"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", required=True)
    parser.add_argument("--pcm", required=True)
    parser.add_argument("--pcm-meta", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--video-stop-ts", type=float, required=True,
                        help="wall-clock time just before ffmpeg was stopped")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    args = parser.parse_args()

    with open(args.pcm_meta, "r", encoding="utf-8") as handle:
        meta = json.load(handle)
    sample_rate = int(meta["sampleRate"])
    pcm_start = float(meta["startTs"])

    duration = probe_duration(args.ffprobe, args.video)
    video_start = args.video_stop_ts - duration
    skip = video_start - pcm_start
    print(f"[mux] video duration={duration:.3f}s start={video_start:.3f} "
          f"pcm start={pcm_start:.3f} -> audio skip={skip:.3f}s", flush=True)
    if skip < 0:
        # Audio began after the video; keep sync by not skipping and accept
        # that the first |skip| seconds of video have no audio reference.
        print(f"[mux] WARNING: audio starts {-skip:.3f}s after video; "
              f"clamping skip to 0", flush=True)
        skip = 0.0

    cmd = [args.ffmpeg, "-hide_banner", "-loglevel", "warning", "-y",
           "-i", args.video,
           "-ss", f"{skip:.3f}",
           "-f", "f32le", "-ar", str(sample_rate), "-ac", "1",
           "-i", args.pcm,
           "-map", "0:v", "-map", "1:a",
           "-c:v", "copy", "-c:a", "aac", "-b:a", "128k",
           "-shortest", "-movflags", "+faststart",
           args.out]
    print(f"[mux] {' '.join(cmd)}", flush=True)
    result = subprocess.run(cmd)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
