#!/usr/bin/env python3
"""Synthetic-mouse scratch driver for the UI scratch E2E test.

Plays the role of a browser-automation tool (Playwright/Selenium) for the
Scratch Now turntable: it reads the platter geometry the CI build logged to
ui.jsonl, then posts real CGEvents (mouse down / circular drags / mouse up)
so the app's normal UI path (TurnTableView -> AppController -> scratch DSP)
runs exactly as it would for a human.

Scenario (phase timestamps are written to phases.json for the assert step):
  baseline : no interaction, platter at 1x.
  reverse  : hold + rotate backward at -1x. This also builds ring-buffer
             headroom so the following fast-forward phase cannot overrun the
             live record head (which would produce silence by design).
  forward2x: hold + rotate forward at 2x -> output pitch should double.
  release  : mouse up, platter returns to 1x.

Table-stop cases (Stop button clicks):
  stopRamp      : click Stop -> platter decelerates (1x -> 0 in ~0.5 s).
  stopped       : fully stopped platter -> silence, tableStopped flag set.
  resumeFromStop: click Start -> back to live at 1x (~220 Hz).
  midStopRamp   : click Stop, then click Start mid-deceleration (~0.3 s in),
                  before the platter ever reaches a full stop.
  resumeMidStop : back to live at 1x without passing through tableStopped.
"""

import json
import math
import os
import sys
import time

import Quartz

STATUS_DIR = "/tmp/scratch-now-tap-smoke-ci"
UI_FILE = os.path.join(STATUS_DIR, "ui.jsonl")
PHASES_FILE = os.path.join(STATUS_DIR, "phases.json")

# Must match TurnTableView baseRadS (33.3 RPM, negative = forward direction).
BASE_RAD_S = -33.3 / 60.0 * 2.0 * math.pi

CLICK_RADIUS_RATIO = 0.6
EVENT_INTERVAL = 0.016

BASELINE_SECONDS = 4.0
REVERSE_SECONDS = 4.0
REVERSE_SPEED_RATE = -1.0
FORWARD_SECONDS = 5.0
FORWARD_SPEED_RATE = 2.0
RELEASE_SECONDS = 4.0

# Table-stop cases. The Stop ramp runs 1.0 -> 0 in ~0.5 s (0.02 per 10 ms
# tick), so the mid-stop resume click must land well inside that window.
STOP_RAMP_SECONDS = 1.5
STOPPED_SECONDS = 3.0
RESUME_SECONDS = 3.0
MID_STOP_RESUME_AFTER = 0.2


def log(message: str) -> None:
    print(f"[driver] {time.time():.3f} {message}", flush=True)


def load_geometry(timeout: float = 30.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(UI_FILE):
            with open(UI_FILE, "r", encoding="utf-8") as handle:
                lines = [l.strip() for l in handle if l.strip()]
            for line in reversed(lines):
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "centerX" in entry:
                    return entry
        time.sleep(0.5)
    raise RuntimeError(f"turntable geometry never appeared in {UI_FILE}")


def point_for_theta(geo: dict, theta: float) -> tuple:
    # theta is in view coordinates (y-up); CGEvent global space is y-down.
    r = geo["radius"] * CLICK_RADIUS_RATIO
    x = geo["centerX"] + r * math.cos(theta)
    y = geo["centerY"] - r * math.sin(theta)
    return (x, y)


def post_mouse(event_type: int, point: tuple) -> None:
    event = Quartz.CGEventCreateMouseEvent(None, event_type, point,
                                           Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def current_cursor_location() -> tuple:
    event = Quartz.CGEventCreate(None)
    loc = Quartz.CGEventGetLocation(event)
    return (loc.x, loc.y)


def verify_cursor_control(point: tuple) -> None:
    post_mouse(Quartz.kCGEventMouseMoved, point)
    time.sleep(0.2)
    actual = current_cursor_location()
    dx = abs(actual[0] - point[0])
    dy = abs(actual[1] - point[1])
    log(f"cursor check requested=({point[0]:.1f},{point[1]:.1f}) "
        f"actual=({actual[0]:.1f},{actual[1]:.1f})")
    if dx > 4.0 or dy > 4.0:
        raise RuntimeError(
            "cursor did not follow the posted CGEvent; event posting is "
            "likely blocked by TCC (Accessibility not granted)")


def click(point: tuple) -> None:
    post_mouse(Quartz.kCGEventMouseMoved, point)
    time.sleep(0.05)
    post_mouse(Quartz.kCGEventLeftMouseDown, point)
    time.sleep(0.05)
    post_mouse(Quartz.kCGEventLeftMouseUp, point)


def rotate(geo: dict, theta: float, speed_rate: float, seconds: float) -> float:
    """Drag along the platter at a constant speedRate; returns the end angle."""
    omega = speed_rate * BASE_RAD_S
    start = time.time()
    last = start
    while True:
        now = time.time()
        if now - start >= seconds:
            break
        theta += omega * (now - last)
        last = now
        post_mouse(Quartz.kCGEventLeftMouseDragged, point_for_theta(geo, theta))
        time.sleep(EVENT_INTERVAL)
    return theta


def main() -> int:
    if hasattr(Quartz, "CGPreflightPostEventAccess"):
        log(f"post-event access preflight: {Quartz.CGPreflightPostEventAccess()}")

    geo = load_geometry()
    log(f"turntable geometry: {geo}")

    phases = []

    def run_phase(name, seconds, action):
        start = time.time()
        log(f"phase {name} start ({seconds:.1f}s)")
        result = action()
        end = time.time()
        phases.append({"name": name, "start": start, "end": end})
        log(f"phase {name} end")
        return result

    # Baseline: leave the platter alone at 1x.
    run_phase("baseline", BASELINE_SECONDS,
              lambda: time.sleep(BASELINE_SECONDS))

    # Park the cursor on the platter and verify we actually control it before
    # pressing the button.
    theta = math.pi / 2.0
    verify_cursor_control(point_for_theta(geo, theta))

    post_mouse(Quartz.kCGEventLeftMouseDown, point_for_theta(geo, theta))
    time.sleep(0.05)

    theta = run_phase("reverse", REVERSE_SECONDS,
                      lambda: rotate(geo, theta, REVERSE_SPEED_RATE,
                                     REVERSE_SECONDS))
    theta = run_phase("forward2x", FORWARD_SECONDS,
                      lambda: rotate(geo, theta, FORWARD_SPEED_RATE,
                                     FORWARD_SECONDS))

    post_mouse(Quartz.kCGEventLeftMouseUp, point_for_theta(geo, theta))

    run_phase("release", RELEASE_SECONDS,
              lambda: time.sleep(RELEASE_SECONDS))

    # Table-stop cases via the Stop button.
    btn_x = geo.get("btnStopCenterX", 0.0)
    btn_y = geo.get("btnStopCenterY", 0.0)
    if btn_x <= 0.0 and btn_y <= 0.0:
        raise RuntimeError("Stop button geometry missing from ui.jsonl")
    btn = (btn_x, btn_y)

    # Case 1: simple stop -> full stop -> resume from the Stop button.
    def stop_ramp():
        click(btn)
        time.sleep(STOP_RAMP_SECONDS)
    run_phase("stopRamp", STOP_RAMP_SECONDS, stop_ramp)
    run_phase("stopped", STOPPED_SECONDS,
              lambda: time.sleep(STOPPED_SECONDS))

    def resume_from_stop():
        click(btn)
        time.sleep(RESUME_SECONDS)
    run_phase("resumeFromStop", RESUME_SECONDS, resume_from_stop)

    # Case 2: click Stop, then return to live mid-deceleration.
    def mid_stop_ramp():
        click(btn)
        time.sleep(MID_STOP_RESUME_AFTER)
    run_phase("midStopRamp", MID_STOP_RESUME_AFTER, mid_stop_ramp)

    def resume_mid_stop():
        click(btn)
        time.sleep(RESUME_SECONDS)
    run_phase("resumeMidStop", RESUME_SECONDS, resume_mid_stop)

    with open(PHASES_FILE, "w", encoding="utf-8") as handle:
        json.dump({"phases": phases}, handle, indent=2)
    log(f"wrote {PHASES_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
