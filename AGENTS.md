# Scratch Now — 開発者/Agent向けメモ

## Agentとユーザーとの会話
### 開発者の想定
- 開発者がDSPの専門家と想定しないこと。DSP、音響における専門用語については適時解説を入れること。

### 質問と確認
**「不明な点」「曖昧な要件」「複数の選択肢」がある状態での推測によるコード生成や実装を禁止します。**
手戻りを防ぎ、正確な成果物を出すために、不確実な要素がある場合は必ず実装をストップし、ユーザーに質問・確認を行ってください。
確認の質問の際には、あなたにおまかせするといった選択肢も用意して。その場合は適時適切な推測や仮説をたててすすめて。


## オーディオキャプチャ構造（CATap 方式）の概要

本アプリはシステム音声のキャプチャに Core Audio Process Tap（CATap, macOS 14.4+）を使用する。
以前の仮想オーディオドライバ（AudioServerPlugIn）方式は廃止済み。中核は `AudioEngine.m`。

- 起動時にデフォルト出力デバイスの UID とストリーム 0 を指定し、
  `AudioHardwareCreateProcessTap` でデバイス固有タップを作成する。
  `CATapMutedWhenTapped` によりタップ中は元のシステム出力が自動でミュートされる。
  またタップからは自プロセスは除外して本アプリの出力のループバックを防止する。
- デバイス固有タップの実フォーマット（`kAudioTapPropertyFormat`）を 1 回だけ読み、
  そのサンプルレートにパイプライン全体（出力 ASBD / RingBuffer / TurnTableView）を追従させる。
  44.1 kHz・48 kHzの両方でタップASBDと実コールバック周期の一致を確認済み。
- タップ単体では I/O できないため、Aggregate Device を作成して包む。
  無音バッファ回避のため、起動時のデフォルト出力デバイスをメインサブデバイス
  （`kAudioAggregateDeviceMainSubDeviceKey` + サブデバイスリスト）として必ず含める。
- `AudioDeviceCreateIOProcID` + `AudioDeviceStart` でキャプチャ開始。
  初回の `AudioDeviceStart` が TCC ダイアログ（システムオーディオ録音の許可）を出す。
- 取り込んだ音声は RingBuffer（vm_remap ミラーリング、60 秒分）に書き込まれ、
  出力側は HALOutput AU（フレームサイズ 32 の低レイテンシ設定）で再生する。

### デフォルト出力デバイス変更の追従

- **監視:** デフォルト出力デバイスと、そのデバイスのサンプルレートを監視する。
- **再構築:** 変更時は入出力を停止し、CATap / Aggregate Device / IOProc /
  HALOutput / RingBuffer を新しい出力デバイスの ASBD で作り直して再開する。

### 関連ドキュメント

- 移行計画の詳細: `docs/catap-migration-phase1-ja.md`

## TurnTable動作

### 状態遷移表 (TBD)
| -          | スクラッチ開始 | スクラッチ終了(release) | 停止ボタン | 再開ボタン | follow |
| ---------- | -------------- | ----------------------- | ---------- | ---------- | ------ |
| 通常再生中 | TD             |                         |            |            |        |
| 減速中     | 4              |                         |            |            |        |
| 完全停止   |                | eee                     |            |            |        |

## 開発プロセス・基準

## PR
- PRのタイトルと本文は英語で記載する。

## コード中のコメントの指針。
- 処理の内容や関数の役割を説明するコメントはわざわざ書かない。
- 分岐や呼び出しのたびに「なぜこうするか」を書かない。残す価値のある理由は AGENTS.md か docs に一度だけ書く。
- コードだけでは読めない DSP の式やアルゴリズムに限って、その場で意図を書いてよい。

## コマンドラインでのビルドと実行方法

### コマンドによるビルドと実行
```sh
xcodebuild -project "Scratch Now.xcodeproj" -scheme "Scratch Now" -configuration Release -destination 'platform=macOS' build && OS_ACTIVITY_MODE=disable "$(xcodebuild -project "Scratch Now.xcodeproj" -scheme "Scratch Now" -configuration Release -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/Scratch Now.app/Contents/MacOS/Scratch Now" 2>&1
```

### Agentによるビルドと実行の指針
ビルドや実行にサンドボックスは使わないこと。サンドボックスだと失敗する。
