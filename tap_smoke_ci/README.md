# Tap smoke CI

CATap（Core Audio Process Tap）が別プロセスのシステム音声を継続的にキャプチャできていることを確認する、最小限のスモークテストです。GitHub Actions と手元の MacBook の両方で同じスクリプトを実行できます（実体は `tap_smoke_ci/` にあり、CI の YAML は薄いラッパーです）。

## 何を確認するか

1. `play_pleasant_tone.py` が python-sounddevice でリアルタイムに耳あたりの良い音を再生開始する。
2. `SCRATCH_NOW_TAP_SMOKE_CI` を有効にした Scratch Now をビルド・起動し、タップ入力を監視する。再生音は途中で周波数を変え（基音 → 完全五度上）、その変化が多少の遅延を持ってタップ側に追従して現れることを確認する。
3. Scratch Now を終了し、再生を停止する。

タップは自プロセスを除外するため、キャプチャ対象は Scratch Now 自身の出力ではなく、別プロセスである `play_pleasant_tone.py` の再生音です。

## 主な環境変数

| 変数 | 既定 | 説明 |
|------|------|------|
| `PYTHON_BIN` | `python3` | 使用する Python |
| `DERIVED_DIR` | `build/tap-smoke-ci` | xcodebuild の derivedData |
| `PHASE_A_SECONDS` | `5.0` | 基音フェーズの長さ |
| `GLIDE_SECONDS` | `1.5` | 五度へのグライド時間 |
| `TONE_DURATION` | `14.0` | 再生総時間 |
| `TAP_SMOKE_CI_ENABLE_DIALOG_WATCHER` | `0` | ダイアログ自動クリックの併用 |

## 判定基準

`assert_tap_capture.py` が以下を満たせば成功（終了コード 0）です。

- 非無音: `framesTotal` が増加し、`rms` が閾値（既定 0.005）を超える。
- 追従: 基音バンド（~220 Hz）を観測した後に、五度バンド（~330 Hz）へ移る。
