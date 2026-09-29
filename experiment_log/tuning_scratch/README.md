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
