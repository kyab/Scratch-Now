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

### デフォルト出力デバイス変更への追従

- `kAudioHardwarePropertyDefaultOutputDevice` と、現在の出力デバイスの
  `kAudioDevicePropertyNominalSampleRate` を専用シリアルキューで監視する。
  通知時の再構築処理はメインスレッドへ移し、通知コールバック自体では Core Audio
  リソースを操作しない。
- 出力デバイスだけ、サンプルレートだけ、または両方が変更された場合に同じ再構築経路を使う。
- 出力変更時は、IOProc、Aggregate Device、デバイス固有 CATap、HALOutput AUGraph、
  RingBuffer を出力デバイス依存の一単位として停止・破棄・再構築する。
  再構築中の短時間の音声断は許容する。
- 新しい CATap ASBD が新しいパイプラインの唯一のレート源となる。
  AppController は再構築通知を受けて RingBuffer を新規生成し、TurnTableView を再接続する。
- Aggregate Device は再構築ごとに一意な UID を使用し、破棄直後の UID 衝突を避ける。
- 再構築に失敗した場合は旧リソースを部分的に再利用せず、停止状態を維持してログを出す。
  終了時はリスナーを解除してから全リソースを破棄する。

### 関連ドキュメント

- 移行計画の詳細: `docs/catap-migration-phase1-ja.md`
