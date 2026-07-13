# Scratch Now — 開発者向けメモ

## オーディオキャプチャ構造（CATap 方式）の概要

本アプリはシステム音声のキャプチャに Core Audio Process Tap（CATap, macOS 14.4+）を使用する。
以前の仮想オーディオドライバ（AudioServerPlugIn）方式は廃止済み。中核は `AudioEngine.m`。

- 起動時に `AudioHardwareCreateProcessTap` でグローバルタップを作成する。
  自プロセスは除外し（出力のループバック防止）、`CATapMutedWhenTapped` により
  タップ中は元のシステム出力が自動でミュートされる。`privateTap = YES`。
- タップの実フォーマット（`kAudioTapPropertyFormat`）を 1 回だけ読み、
  そのサンプルレートにパイプライン全体（出力 ASBD / RingBuffer / TurnTableView）を追従させる。
  レート変換（SRC）はどこにも存在しない（決定論的動作のため）。
- タップ単体では I/O できないため、Aggregate Device を作成して包む。
  無音バッファ回避のため、起動時のデフォルト出力デバイスをメインサブデバイス
  （`kAudioAggregateDeviceMainSubDeviceKey` + サブデバイスリスト）として必ず含める。
- `AudioDeviceCreateIOProcID` + `AudioDeviceStart` でキャプチャ開始。
  初回の `AudioDeviceStart` が TCC ダイアログ（システムオーディオ録音の許可）を出す。
- 取り込んだ音声は RingBuffer（vm_remap ミラーリング、30 秒分）に書き込まれ、
  出力側は HALOutput AU（フレームサイズ 32 の低レイテンシ設定）で再生する。

## 未実装・未検証の重要事項

- **タップ中のデフォルト出力デバイス変更への追従は未実装**（2026-07 時点）。
  デフォルト出力デバイスは起動時に 1 回だけ取得され（`obtainDefaultOutputDevice`）、
  `kAudioHardwarePropertyDefaultOutputDevice` のリスナー登録は存在しない。
  そのため、動作中にユーザーが出力デバイスを切り替えても、再生出力（HALOutput AU）と
  Aggregate Device のアンカーは旧デバイスに固定されたままになる。
  タップ自体はプロセス単位のグローバルタップなのでキャプチャは継続する可能性があるが、
  動作確認は行っていない。本アプリにとって重要な未解決課題。

## 関連ドキュメント

- 移行計画の詳細: `docs/catap-migration-phase1-ja.md`
