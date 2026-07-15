# Tap smoke CI

CATap（Core Audio Process Tap）が別プロセスのシステム音声を継続的にキャプチャできていることを確認する、最小限のスモークテストです。GitHub Actions と手元の MacBook の両方で同じスクリプトを実行できます（実体は `tap_smoke_ci/` にあり、CI の YAML は薄いラッパーです）。

## 動作説明

1. `play_pleasant_tone.py` が python-sounddevice でリアルタイムに再生開始する。
2. `SCRATCH_NOW_TAP_SMOKE_CI` を有効にした Scratch Now をビルド・起動し、タップ入力を監視する。再生音は途中で周波数を変え（基音 → 完全五度上）、その変化が多少の遅延を持ってタップ側に追従して現れることを確認する。
3. Scratch Now を終了し、再生を停止する。

タップ側ではゼロクロス由来で音の高さを簡易的に推定し、再生側の周波数変化への追従を確認します。

## ローカル実行

macOS 14.4+ / Xcode / Python 3 が必要です。初回のシステムオーディオ録音ダイアログは許可してください。

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r ./tap_smoke_ci/requirements.txt
./tap_smoke_ci/run_tap_smoke_test.sh
```
