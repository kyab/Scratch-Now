---
name: scratch-now-build-run
description: Build and run Scratch Now from the command line (xcodebuild, Release, Xcode Derived Data, NSLog to terminal). Use when CLI build, rebuild, run, or runtime log verification is needed.
---

# Scratch Now — Build & Run

Run from the repository root:

```sh
xcodebuild -project "Scratch Now.xcodeproj" -scheme "Scratch Now" -configuration Release -destination 'platform=macOS' build && OS_ACTIVITY_MODE=disable "$(xcodebuild -project "Scratch Now.xcodeproj" -scheme "Scratch Now" -configuration Release -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/Scratch Now.app/Contents/MacOS/Scratch Now" 2>&1
```
