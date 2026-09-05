#!/usr/bin/env python3
"""Dismiss the macOS legacy screen-capture approval prompt if it is showing.

On macOS 15+ starting an AVCaptureScreenInput capture pops a system dialog
('"bash" is requesting to bypass the system private window picker...') even
when kTCCServiceScreenCapture is pre-granted in the TCC databases. The dialog
floats over the app under test and steals focus, which breaks the synthetic
mouse interaction. Pre-seeding replayd's ScreenCaptureApprovals.plist did not
reliably silence it on the CI image, so this helper detects the dialog window
via CGWindowList and clicks its Allow button with a posted mouse event.

No-op when the dialog is not present.
"""

import sys
import time

import Quartz

# Observed dialog geometry on the 1024x768 runner display: ~261x327 points,
# horizontally centered. Keep the match ranges loose across OS versions.
MIN_W, MAX_W = 220, 340
MIN_H, MAX_H = 260, 420
# The Allow button sits above 'Open System Settings', ~63 pt from the bottom.
ALLOW_OFFSET_FROM_BOTTOM = 63.0

IGNORED_OWNERS = {"Scratch Now", "Dock", "Window Server", "WindowManager",
                  "Wallpaper", "Finder", "SystemUIServer", "Spotlight",
                  "Control Center", "Notification Center"}


def log(message: str) -> None:
    print(f"[dismiss-prompt] {time.time():.3f} {message}", flush=True)


def find_prompt_window():
    infos = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly
        | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    for info in infos or []:
        owner = info.get("kCGWindowOwnerName", "")
        if owner in IGNORED_OWNERS:
            continue
        bounds = info.get("kCGWindowBounds") or {}
        width = bounds.get("Width", 0.0)
        height = bounds.get("Height", 0.0)
        if MIN_W <= width <= MAX_W and MIN_H <= height <= MAX_H:
            return owner, bounds
    return None


def post_mouse(event_type, point):
    event = Quartz.CGEventCreateMouseEvent(None, event_type, point,
                                           Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def click(x: float, y: float) -> None:
    post_mouse(Quartz.kCGEventMouseMoved, (x, y))
    time.sleep(0.1)
    post_mouse(Quartz.kCGEventLeftMouseDown, (x, y))
    time.sleep(0.1)
    post_mouse(Quartz.kCGEventLeftMouseUp, (x, y))


def main() -> int:
    for attempt in range(5):
        found = find_prompt_window()
        if not found:
            if attempt == 0:
                log("no capture prompt window found; nothing to do")
            else:
                log("capture prompt dismissed")
            return 0
        owner, bounds = found
        allow_x = bounds["X"] + bounds["Width"] / 2.0
        allow_y = bounds["Y"] + bounds["Height"] - ALLOW_OFFSET_FROM_BOTTOM
        log(f"prompt window owner={owner!r} bounds={dict(bounds)} -> "
            f"clicking Allow at ({allow_x:.0f}, {allow_y:.0f})")
        click(allow_x, allow_y)
        time.sleep(1.0)
    log("WARNING: capture prompt still present after retries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
