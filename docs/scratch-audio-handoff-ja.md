# スクラッチ音声処理 — 申し送り（既知不具合）

本ドキュメントは、新スクラッチ音声処理（Hermite 補間 + スムージング + フェード状態機械）移植後の **未修正不具合** を、別セッションで Fix するためのメモです。

関連変更ファイル:

- `Scratch Now/AppController.h`
- `Scratch Now/AppController.m`
- `Scratch Now/TurnTableView.h`
- `Scratch Now/TurnTableView.m`

---

## 1. Start/Stop ボタンが正しく機能しない（無音に聞こえる）

### 症状

- `[S]top` / `[S]tart` ボタンを押しても、期待どおりの減速停止・再開が聞こえない（無音のように感じる）。

### 想定原因

1. **停止完了後の出力パスが dry のみで、デフォルト `_dryVolume = 0.0`**
   - `outCallback` 内 `_tableStopped && !_tableStopTimer` 分岐（`AppController.m`）は `readPtr` を `_dryVolume` のみで出力している。
   - UI の Dry スライダー初期値も 0 のため、停止完了後は **常に無音** になりうる。

2. **`tableStopTimer:` がスクラッチ状態機械を経由しない**
   - 減速中は `_speedRate` を直接減らすだけで、`turnTableSpeedRateChanged:` を呼ばない。
   - `_isScratching` 等のフラグが減速・停止と連動しない可能性がある。

3. **Going Zero との差分**
   - Going Zero は `processStoppedState` で入力バッファ（live 1x）に `_dryVolume` を掛ける。
   - Scratch Now は CATap 分離構成のため、停止時の音源参照・ミックス設計が未整理。

### 修正のヒント

- 停止完了時は **wet も含めた通常再生**、または **readPtr から dry+wet ミックス** に戻す。
- `tableStopTimer:` から `turnTableSpeedRateChanged:` 相当の状態遷移を呼ぶか、Going Zero の `forceStoppedState` / `resumeFromStoppedState` パターンを参考に専用ハンドラを追加する。
- `_dryVolume == 0` でも停止中に無音にならないよう、停止状態の出力仕様を決める（例: 停止中は wet ミュート・dry 1.0 固定など）。

### 再現手順（案）

1. アプリ起動 → システム音声再生
2. `[S]top` を押して減速停止
3. 無音になる / `[S]tart` で期待どおり復帰しない

---

## 2. Dry/Wet スライダーが機能していない

### 症状

- Dry スライダーを動かしてもミックスが変わらない、またはスクラッチ中だけ効かない。

### 想定原因

1. **スクラッチ中の dry 参照が未初期化バッファ**
   - `processScratchBlock:` 内で `float dryL = leftBuf[i] * _dryVolume;` としているが、`leftBuf` は `outCallback` の出力バッファ（未初期化）。
   - Going Zero では `leftBuf` が **そのブロックの live 1x 入力** であるため、dry ミックスが成立している。

2. **Wet 用 UI スライダーが存在しない**
   - `MainMenu.xib` には Dry スライダー（`_sliderDry`）のみ接続。
   - `_wetVolume` はコード上 `1.0` 固定で、IBAction もない。

3. **通常再生時は readPtr 参照のため Dry は一応動く可能性**
   - `processNormalState:` では `readPtr` から dry/wet を生成しているため、**通常再生時のみ**スライダーが効く可能性がある。
   - スクラッチ中は上記 1 の理由で dry が無効。

### 修正のヒント

- `processScratchBlock:` の dry を `readPtr` の 1x 読み出し（または別途コピーした 1x バッファ）に変更する。
- Wet スライダーを UI に追加するか、既存 Dry スライダーの仕様（dry only / dry-wet balance）を明確化する。
- Going Zero `processLeft` の「入力バッファ = dry/wet 共通ソース」モデルを、CATap in/out 分離構成にどう適応するか整理する。

### 再現手順（案）

1. Dry スライダーを 0 → 1 に変更
2. 通常再生で変化があるか確認
3. スクラッチ中に同様に変更 → 変化がない（またはノイズ）なら本件

---

## 参考: 移植済みだが UI 層で追加した改善

- `TurnTableView` に Going Zero 同等の **10 点移動平均**（`_history[10]`）と **実測 delta** を導入済み。
- これにより速度入力のガクつきは改善方向だが、上記 2 件は別問題として残っている。

---

## 関連コード位置（クイックリファレンス）

| 項目 | ファイル | おおよその位置 |
|------|----------|----------------|
| 停止時 dry のみ出力 | `AppController.m` | `outCallback` `_tableStopped` 分岐 |
| 減速タイマー | `AppController.m` | `tableStopTimer:` |
| Start/Stop ボタン | `AppController.m` | `startStopButtonClicked:` |
| スクラッチ dry 参照 | `AppController.m` | `processScratchBlock:` |
| Dry スライダー | `AppController.m` / `MainMenu.xib` | `dryVolumeChanged:` / `_sliderDry` |
| 速度平滑化 | `TurnTableView.m` | `onTimerScratch:` |
