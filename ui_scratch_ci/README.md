# UI scratch E2E CI

スクラッチ操作（ターンテーブルのマウスドラッグ）による音声効果を、実機の UI 操作込みでエンドツーエンドに検証するテストです。ブラウザテスト（Playwright 等）の macOS ネイティブ版に相当し、合成マウスイベント（CGEvent）で実際にプラッターを回し、アプリが出力する音のピッチが追従することを確認します。GitHub Actions と手元の MacBook の両方で同じスクリプトを実行できます。

## 動作説明

1. `play_steady_tone.py` が別プロセスで 220 Hz の定常トーンを再生する（CATap のキャプチャ元）。
   WAV を生成して `afplay` で再生する（Python のリアルタイム描画は CI VM のジッタで途切れが発生したため不採用）。

> **注意（macos-latest / macOS 26 ランナー）:** macos-latest では音声開始から約 20〜35 秒後に
> ランナーの仮想オーディオが恒久的な断続状態（デューティ約 20%）に劣化することがある。
> トーンプレイヤーを sounddevice → afplay に替えても発生するため、テスト側ではなくランナー
> イメージ由来と判断。`assert_scratch_effect.py` の INFRA チェック（tap.jsonl の rms 監視）が
> この状態を明示的に検出する。workflow では macos-latest を `continue-on-error` にしてあり、
> 必須シグナルは安定している macos-15。
2. `SCRATCH_NOW_TAP_SMOKE_CI` を有効にした Scratch Now をビルド・起動する。この CI ビルドは以下を `/tmp/scratch-now-tap-smoke-ci/` に書き出す:
   - `ui.jsonl` — ターンテーブルの画面座標（CGEvent グローバル座標系）
   - `output.jsonl` — スクラッチ DSP 通過後にスピーカーへ送る音の rms / ゼロクロス由来の推定周波数（毎秒 1 行）
   - `scratch.jsonl` — スクラッチ状態（speedRate、押下中フラグ等、10 Hz）
3. `drive_scratch.py` が CGEvent で実際にマウスを動かし、通常の UI 経路（`TurnTableView` → `AppController` → 可変速リサンプラ）でスクラッチを実行する:
   - ベースライン（無操作、1x）→ 逆回転 -1x（4 秒）→ 順方向 2x（5 秒）→ リリース
   - 逆回転を先に行うのは、リングバッファに再生ヘッドの余裕を作り、順方向 2x が録音ヘッドを追い越して仕様上の無音になるのを防ぐため。
   - 続けて Stop ボタンで table-stop の 2 ケースを実行:
     - 単純停止: Stop クリック → 減速（約 0.5 秒）→ 完全停止 → 再クリックで live 復帰
     - 停止途中で live 復帰: Stop クリック → 減速途中（約 0.3 秒後）に再クリック
4. `assert_scratch_effect.py` が検証する:
   - ベースライン: 出力 ≈ 220 Hz・非無音
   - 逆回転: 非無音 かつ DSP 速度が負（正弦波は逆再生しても同じピッチになるため、方向は状態ストリームで確認）
   - 順方向 2x: **出力 ≈ 440 Hz（ピッチ 2 倍）— これがスクラッチ効果本体の検証**
   - リリース: ≈ 220 Hz に復帰
   - 単純停止: 停止後は無音 かつ `tableStopped` がセットされ、再クリックで ≈ 220 Hz に復帰
   - 停止途中で live 復帰: 減速中の速度（0 < speedRate < 1）を観測しつつ `tableStopped` を経由せず ≈ 220 Hz に復帰
5. 証拠動画 `evidence.mp4` を CI アーティファクトに保存する:
   - ffmpeg（avfoundation, `-capture_cursor 1`）でマウスポインタ込みの画面を録画
   - ランナーには音声ループバックが無いため、アプリがスピーカーへレンダリングした
     出力そのもの（`output.pcm`, mono f32le）をアプリ側 CI フックでダンプし、
     壁時計タイムスタンプで映像と整列して mux する（`make_evidence_video.py`）
   - 同期精度は ±0.1 秒程度（録画停止時刻 − 動画長 で開始時刻を逆算）

## TCC（権限）について

- システムオーディオ録音: `tap_smoke_ci/grant_audio_capture_tcc.sh` を再利用してアプリに事前付与。
- 合成マウスイベント: `grant_ui_automation_tcc.sh` が Python 実行ファイルに Accessibility / PostEvent を事前付与（GitHub ランナーは TCC DB へ書き込み可能）。ローカル Mac では初回にシステム設定でターミナル/Python にアクセシビリティを許可してください。

## ローカル実行

macOS 14.4+ / Xcode / Python 3 が必要です。実行中はマウスカーソルがテストに奪われる点に注意してください。

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r ./ui_scratch_ci/requirements.txt
./ui_scratch_ci/run_ui_scratch_test.sh
```
