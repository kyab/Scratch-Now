#!/usr/bin/env python3
"""Run one pop-startup capture: record BGM, play tone, launch app, quit, detect."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


BUNDLE_ID = "com.kyab.Scratch-Now"
SCHEME = "Scratch Now"
RECORD_DEVICE = "Background Music"


def log(msg: str) -> None:
    print(f"[pop-startup] {msg}", flush=True)


def find_tone_wav() -> Path:
    desktop = Path.home() / "Desktop"
    matches = sorted(desktop.glob("*longnote_C.wav"))
    if not matches:
        raise SystemExit(f"tone wav not found on Desktop: {desktop}/*longnote_C.wav")
    return matches[0]


def copy_tone(src: Path, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return dest


def resolve_sox_device(device_name: str) -> str:
    proc = subprocess.run(
        ["sox", "--help-format", "coreaudio"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 and "coreaudio" not in (proc.stdout + proc.stderr).lower():
        raise SystemExit("sox coreaudio support is missing")
    # Confirm the named device opens. trim 0 0 still initializes the HAL input.
    probe = subprocess.run(
        ["sox", "-t", "coreaudio", device_name, "-n", "trim", "0", "0.05"],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        raise SystemExit(
            f"sox could not open coreaudio input {device_name!r}:\n"
            f"{probe.stderr or probe.stdout}"
        )
    log(f"resolved device {device_name!r} -> sox coreaudio")
    return device_name


def quit_app() -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'],
        capture_output=True,
    )
    time.sleep(0.4)
    subprocess.run(["killall", SCHEME], capture_output=True)


def start_recorder(wav_path: Path, log_path: Path, device_name: str) -> subprocess.Popen:
    cmd = [
        "sox",
        "-q",
        "-t",
        "coreaudio",
        device_name,
        "-t",
        "wav",
        str(wav_path),
        "trim",
        "0",
        "12",
    ]
    log(f"recording: {' '.join(cmd)}")
    fh = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=fh,
        stderr=fh,
        start_new_session=True,
    )
    return proc


def stop_recorder(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGINT)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=3)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trial", default="T0")
    parser.add_argument("--app", default="", help="Path to Scratch Now.app")
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--detect-script", required=True)
    parser.add_argument("--no-app", action="store_true",
                        help="Record tone only; do not launch Scratch Now")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    app_path = Path(args.app) if args.app else Path()
    if not args.no_app:
        if not app_path.exists():
            raise SystemExit(f"app not found: {app_path}")

    record_device = os.environ.get("POP_STARTUP_RECORD_DEVICE", RECORD_DEVICE)
    sox_device = resolve_sox_device(record_device)
    tone_src = find_tone_wav()
    tone_copy = copy_tone(tone_src, out_dir / "longnote_C.wav")
    log(f"tone source={tone_src!s} copied={tone_copy}")

    rec_wav = out_dir / "capture.wav"
    rec_log = out_dir / "sox.log"
    app_log = out_dir / "app.log"
    times_path = out_dir / "times.json"
    detect_path = out_dir / "detect.json"

    quit_app()
    time.sleep(0.5)

    recorder = start_recorder(rec_wav, rec_log, sox_device)
    rec_start = time.time()
    time.sleep(0.6)
    if recorder.poll() is not None:
        raise SystemExit(f"sox recorder exited early; see {rec_log}")

    play = subprocess.Popen(
        ["afplay", str(tone_copy)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    play_start = time.time()
    log("playing tone")
    app_start = None
    app_stop = None
    if args.no_app:
        log("no-app baseline: not launching Scratch Now")
        if recorder.poll() is None:
            try:
                recorder.wait(timeout=14)
            except subprocess.TimeoutExpired:
                stop_recorder(recorder)
        rec_stop = time.time()
        log("stopped recorder")
    else:
        time.sleep(1.0)
        app_log_fh = open(app_log, "w", encoding="utf-8")
        subprocess.Popen(
            ["open", str(app_path)],
            stdout=app_log_fh,
            stderr=app_log_fh,
        )
        app_start = time.time()
        log(f"launched {app_path}")
        time.sleep(3.0)
        app_stop = time.time()
        log("quitting app")
        quit_app()
        time.sleep(0.3)

    if play.poll() is None:
        try:
            os.killpg(play.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            play.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(play.pid, signal.SIGKILL)
            play.wait(timeout=2)
    log("stopped tone")

    if not args.no_app:
        if recorder.poll() is None:
            try:
                recorder.wait(timeout=8)
            except subprocess.TimeoutExpired:
                stop_recorder(recorder)
        rec_stop = time.time()
        log("stopped recorder")

    times = {
        "trial": args.trial,
        "rec_start": rec_start,
        "play_start": play_start,
        "no_app": args.no_app,
        "app_start": app_start,
        "app_stop": app_stop,
        "rec_stop": rec_stop,
        "record_device": record_device,
        "recorder": "sox",
        "tone_wav": str(tone_src),
        "app": None if args.no_app else str(app_path),
    }
    with open(times_path, "w", encoding="utf-8") as f:
        json.dump(times, f, indent=2)
        f.write("\n")

    if not rec_wav.exists() or rec_wav.stat().st_size < 1000:
        raise SystemExit(f"capture wav missing or tiny: {rec_wav}")

    detect_cmd = [
        sys.executable,
        args.detect_script,
        "--wav",
        str(rec_wav),
        "--out",
        str(detect_path),
    ]
    if args.no_app:
        detect_cmd.append("--scan-all")
    else:
        detect_cmd.extend(["--times", str(times_path)])
    detect = subprocess.run(detect_cmd, check=False)

    wave_png = out_dir / "waveform.png"
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-y",
            "-i",
            str(rec_wav),
            "-filter_complex",
            "showwavespic=s=1920x320:split_channels=1",
            str(wave_png),
        ],
        capture_output=True,
    )
    log(f"waveform={wave_png}")
    return detect.returncode


if __name__ == "__main__":
    sys.exit(main())
