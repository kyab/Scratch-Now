# Scratch speed log plot

Records `speedStart` / `speedEnd` of every `processVariableRateBlock()` call
(`TurnTable.m`) and plots them, one call = one point, with no averaging or decimation.

The audio thread only writes into a preallocated lock-free ring; a main-thread timer
drains it and prints each record with `NSLog` in the same "record line + `Timestamp:` line"
style as the older `[LogTimer]` logs in `experiment_log/`. The app is sandboxed, so the log
is captured from the terminal instead of being written to a file by the app.

## Record

```sh
BIN="$(xcodebuild -project "Scratch Now.xcodeproj" -scheme "Scratch Now" -configuration Release -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/Scratch Now.app/Contents/MacOS/Scratch Now"
SCRATCH_SPEED_LOG=1 OS_ACTIVITY_MODE=disable "$BIN" 2>&1 | tee experiment_log/scratch_speed_log.txt
```

Recording runs for the whole session whenever the variable-rate path is active
(scratch, coast, Stop ramp, fully stopped). Quit the app (Cmd+Q) to finish.
Without `SCRATCH_SPEED_LOG=1` nothing is recorded.

## Plot

```sh
python3 -m venv scripts/scratch_speed_plot/.venv
scripts/scratch_speed_plot/.venv/bin/pip install -r scripts/scratch_speed_plot/requirements.txt
scripts/scratch_speed_plot/.venv/bin/python scripts/scratch_speed_plot/plot_scratch_speed_log.py \
    experiment_log/scratch_speed_log.txt experiment_log/scratch_speed_plot.png
```

`--t-min` / `--t-max` zoom into a time window (all points inside it are drawn);
`--width` sets the figure width in inches.

## Output capture and spectrogram (aliasing check)

With `SCRATCH_SPEED_LOG=1` the final output is also written as a 32-bit float stereo WAV to
the app container, e.g. `~/Library/Containers/com.kyab.Scratch-Now/Data/tmp/scratch_output_<date>.wav`
(the exact path is printed as `[SpeedLog] output capture: path = ...`). Each `[SpeedLog]` record has
`outputFrame` (output frame count at its callback start), so the speed log and the WAV share one
time axis with at most one callback (32 frames) of offset.

A known test tone makes aliases easy to identify:

```sh
PY=scripts/scratch_speed_plot/.venv/bin/python
$PY scripts/scratch_speed_plot/make_test_tone.py /tmp/scratch_test_tone.wav --seconds 180   # 1 kHz + 15 kHz + 18 kHz
afplay /tmp/scratch_test_tone.wav &   # play while scratching in Scratch Now
$PY scripts/scratch_speed_plot/plot_scratch_spectrogram.py LOG.txt OUTPUT.wav spectrogram.png --tone-hz 15000 18000
```

A tone f0 read at speed s lands at |s| * f0; above Nyquist (fs / 2) it folds to fs - |s| * f0.
The script overlays these expected lines per call and shades the |speed| > 1 intervals.
