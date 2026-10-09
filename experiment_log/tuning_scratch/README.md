# Scratch speed tuning runs

Each run records `speedStart` / `speedEnd` of every `processVariableRateBlock()` call
(see `scripts/scratch_speed_plot/README.md`). Plots draw every call as one point.

Common environment unless noted: tap/output 44.1 kHz, output callback 32 frames
(~0.73 ms per call), input callback 64 frames.

## 01 baseline (SPEED_SMOOTH_ALPHA = 0.5), trackpad touch

- Files: `01-baseline-alpha0.5-trackpad.txt`, `.png`, `-zoom-0.05-0.35s.png`
- Recorded: 2026-09-29 18:07:33 (JST), 18.26 s, 17,921 calls, 0 dropped
- Code: `feat/tuning-scratch` @ `d2cc289`
- Input: trackpad touch (two-finger scratch on the platter)

| Parameter | Value | File |
| --- | --- | --- |
| `SPEED_SMOOTH_ALPHA` | 64/128 = 0.5 per sample (tau ~ 1.4 samples ~ 0.03 ms) | `TurnTable.m` |
| `GAIN_SMOOTH_ALPHA` | 1/256 per sample | `TurnTable.m` |
| `GAIN_SLOPE` | 4.0 | `TurnTable.m` |
| `DC_BLOCKER_R` | 0.995 | `TurnTable.m` |
| `FADE_SAMPLE_NUM` | 500 | `TurnTable.m` |
| `COAST_TAU_SEC` / `COAST_FORWARD_TAU_SEC` | 0.1086 / 0.1086 | `TurnTable.m` |
| `COAST_TIMER_SEC` | 0.01 | `TurnTable.m` |
| `COAST_SKIP_EPSILON` / `COAST_FORWARD_SKIP_EPSILON` / `COAST_END_EPSILON` | 0.80 / 0.40 / 0.05 | `TurnTable.m` |
| `TOUCH_TIMER_SEC` | 0.01 | `PlatterView.m` |
| `TOUCH_SPEED_TAU_SEC` | 0.01 | `PlatterView.m` |
| `TOUCH_TARGET_WINDOW_SEC` | 0.05 | `PlatterView.m` |
| `TOUCH_TARGET_IDLE_SEC` | 0.1 | `PlatterView.m` |
| `TOUCH_Y_PER_SEC_FOR_1X` | 1.0 | `PlatterView.m` |

Findings in reverse x0.5..x2.0 (5,192 calls):

- Speed is a staircase: 88% of calls have `speedStart == speedEnd`; the remaining 12%
  jump by a median 8.7% of the current speed (p90 21%, max 1.07 absolute).
- Steps arrive every ~6 ms (median; p10 1.5 ms, p90 10 ms), i.e. ~100-170 Hz pitch steps.
- The per-sample EMA reaches the new target within a few samples, so it passes the
  steps from the UI thread (touch events / 10 ms touch timer) straight to the resampler.
- Coast after release is smooth by comparison.

## 02 SPEED_SMOOTH_TAU_SEC = 20 ms, trackpad touch

- Files: `02-tau20ms-trackpad.txt`, `.png`, `-zoom-8.85-9.35s.png`
- Recorded: 2026-09-29 18:27:21 (JST), 23.84 s, 25,866 calls, 0 dropped
- Code: `feat/tuning-scratch` @ `1548e04`
- Input: trackpad touch
- Change from 01: `SPEED_SMOOTH_ALPHA = 0.5` replaced by `SPEED_SMOOTH_TAU_SEC = 0.020`
  (per-sample alpha = 1 - exp(-1 / (tau * fs)) = 0.00113 at 44.1 kHz). Everything else as 01.

Comparison in reverse x0.5..x2.0 (01: 5,192 calls, 02: 6,495 calls):

| Metric | 01 | 02 |
| --- | --- | --- |
| Calls with no speed change | 88.1% | 0.0% |
| Per-call relative change, p99 | 23.1% | 5.2% |
| Per-call relative change, max | 180% | 13.5% |
| Change of per-call step between consecutive calls, p99 / max | 0.311 / 1.073 | 0.0078 / 0.055 |

- The staircase is gone; speed is a continuous curve (see zoom).
- Listening impression (user): the "jobo-jobo" change is marginal, so speed steps are
  probably not the main cause.

## 03 aliasing check: tau = 20 ms, trackpad touch, test tone

- Files: `03-tau20ms-trackpad-tone.txt`, `03-spectrogram-full.png`,
  `03-spectrogram-zoom-62.5-63.8s.png` (expected lines overlaid), `...-no-overlay.png`.
  The output WAV (`03-tau20ms-trackpad-tone-output.wav`, 83 s, 29 MB) is kept locally, not committed.
- Recorded: 2026-09-29 19:04:01 (JST), 26,397 calls, 0 dropped records, 0 dropped capture frames
- Code: `feat/tuning-scratch` @ `dae5258` (parameters as 02)
- Source: `make_test_tone.py` default, 1 kHz (amp 0.10) + 15 kHz (0.20) + 18 kHz (0.20), played by `afplay`
- Scratching happens at ~52-80 s of the output time axis.

Findings:

- Clear aliasing whenever |speed| x f0 > 22.05 kHz: the 15 kHz and 18 kHz tones fold back
  down (V shapes to ~8 kHz and ~1 kHz at |speed| ~ 2.4) exactly on the predicted
  `fs - |speed| x f0` lines.
- Alias level, per-frame peak normalized to source amplitude and relative to the 1 kHz line
  (frames with near-constant speed only):

  | abs speed | 18 kHz | 15 kHz | 18 kHz image | 15 kHz image |
  | --- | --- | --- | --- | --- |
  | 0.5-1.0 | -9.9 (direct) | -7.5 (direct) | -21.4 | -25.6 |
  | 1.25-1.47 | -7.4 (aliased) | -6.0 (direct) | -20.3 | -27.2 |
  | 1.5-2.0 | -8.0 (aliased) | -5.8 (aliased) | -16.1 | -25.1 |
  | 2.0-2.6 | -6.0 (aliased) | -5.7 (aliased) | -17.8 | -27.6 |

  Aliased components are as strong as non-aliased ones: nothing band-limits the signal
  before the resampler. Cubic interpolation images stay ~16-28 dB below.
- For music, content above fs / (2 x |speed|) (above 11 kHz at x2) folds down. This cannot
  explain artefacts at |speed| <= 1, where only the weaker interpolation images exist.
