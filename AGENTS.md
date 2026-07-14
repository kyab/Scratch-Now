# Scratch Now — 開発者向けメモ

## オーディオキャプチャ構造（CATap 方式）の概要

本アプリはシステム音声のキャプチャに Core Audio Process Tap（CATap, macOS 14.4+）を使用する。
以前の仮想オーディオドライバ（AudioServerPlugIn）方式は廃止済み。中核は `AudioEngine.m`。

- 起動時にデフォルト出力デバイスの UID とストリーム 0 を指定し、
  `AudioHardwareCreateProcessTap` でデバイス固有タップを作成する。
  自プロセスは除外し（出力のループバック防止）、`CATapMutedWhenTapped` により
  タップ中は元のシステム出力が自動でミュートされる。`privateTap = YES`。
  グローバルタップは44.1 kHz出力時にも48 kHzを報告するため使用しない。
- デバイス固有タップの実フォーマット（`kAudioTapPropertyFormat`）を 1 回だけ読み、
  そのサンプルレートにパイプライン全体（出力 ASBD / RingBuffer / TurnTableView）を追従させる。
  44.1 kHz・48 kHzの両方でタップASBDと実コールバック周期の一致を確認済み。
- タップ単体では I/O できないため、Aggregate Device を作成して包む。
  無音バッファ回避のため、起動時のデフォルト出力デバイスをメインサブデバイス
  （`kAudioAggregateDeviceMainSubDeviceKey` + サブデバイスリスト）として必ず含める。
- `AudioDeviceCreateIOProcID` + `AudioDeviceStart` でキャプチャ開始。
  初回の `AudioDeviceStart` が TCC ダイアログ（システムオーディオ録音の許可）を出す。
- 取り込んだ音声は RingBuffer（vm_remap ミラーリング、30 秒分）に書き込まれ、
  出力側は HALOutput AU（フレームサイズ 32 の低レイテンシ設定）で再生する。

### 未実装・未検証の重要事項

- **タップ中のデフォルト出力デバイス変更への追従は未実装**（2026-07 時点）。
  デフォルト出力デバイスは起動時に 1 回だけ取得され（`obtainDefaultOutputDevice`）、
  `kAudioHardwarePropertyDefaultOutputDevice` のリスナー登録は存在しない。
  そのため、動作中にユーザーが出力デバイスを切り替えても、デバイス固有タップ、
  再生出力（HALOutput AU）、Aggregate Device のアンカーは旧デバイスに固定されたままになる。
  新しい出力デバイスへ追従するには、これらとサンプルレート依存のパイプラインを
  まとめて再構築する必要がある。本アプリにとって重要な未解決課題。
  実装時は動作中の部品を個別に差し替えず、CATap / Aggregate Device / HALOutput /
  RingBuffer を出力デバイス依存の一単位として、安全に停止・破棄・再構築する方針が望ましいとも思うが、計画時に再検討すること。

### 関連ドキュメント

- 移行計画の詳細: `docs/catap-migration-phase1-ja.md`
