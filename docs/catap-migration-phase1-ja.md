# Scratch Now — CATap 移行フェーズ1: キャプチャ経路置き換えの実装計画

作成日: 2026年7月13日
対象ブランチ: `feature/catap-migration`

参考: [Anytime Scratch — Mac App Store 配布調査レポート](https://github.com/kyab/Anytime-Scratch/blob/cursor/appstore-distribution-plan-ja-017b/docs/appstore-distribution-plan-ja.md)

---

## 1. 背景

Scratch Now は現在、リポジトリに同梱した仮想オーディオドライバー `Scratch Now Driver`（AudioServerPlugIn）が作るループバックデバイス「Scratch Now」に依存してシステム音声をキャプチャしている。

- 仮想ドライバーのインストールは `/Library/Audio/Plug-Ins/HAL/` への書き込み（管理者権限）が必要であり、App Store 審査ガイドライン 2.4.5(iv) により配布不可
- Anytime-Scratch と同じ構成のため、同レポートのフェーズ1（キャプチャ経路の置き換え）に従い、macOS 14.2+ の公式 API である **Core Audio Process Tap（CATap）** へ移行する

### Anytime-Scratch との相違点

| 項目 | Anytime-Scratch | Scratch Now |
|------|-----------------|-------------|
| 仮想デバイスの提供元 | 外部アプリ Background Music | 同梱ドライバー `Scratch Now Driver` |
| ループバックデバイス名 | "Background Music" | "Scratch Now" |
| 出力先 | Built-in Output 固定 | 起動時のデフォルト出力デバイス（`_preOutputDeviceID`） |

---

## 2. 現状のアーキテクチャ

```
[各アプリの音声]
    ↓（デフォルト出力 = "Scratch Now" に強制変更）
[Scratch Now 仮想デバイス]  ← 同梱ドライバーのインストール必須
    ↓ HAL Input Unit（AudioEngine.m: initializeInput）
[RingBuffer + スクラッチ DSP]（AppController.m）
    ↓ AUGraph HAL Output（AudioEngine.m: initializeOutput）
[元のデフォルト出力デバイス]
```

### 起動時の処理（`AppController.m: awakeFromNib`）

1. `[_ae initialize]` — 元のデフォルト出力の記憶、出力 AUGraph 初期化、入力 HAL Unit 初期化、音量同期のセットアップ
2. `[_ae changeSystemOutputDeviceToBGM]` — システムのデフォルト出力を「Scratch Now」に強制変更
3. `[_ae startOutput]` / `[_ae startInput]`

### 終了時の処理（`AppController.m: terminate`）

- `stopOutput` / `stopInput` / `restoreSystemOutputDevice`（元のデフォルト出力の復元）

---

## 3. 移行後のアーキテクチャ

```
[各アプリの音声]
    ↓（デフォルト出力はそのまま）
[Core Audio Process Tap]  ← アプリ内で作成・破棄。自プロセス除外 + mutedWhenTapped
    ↓ プライベート Aggregate Device + AudioDeviceIOProc
[RingBuffer + スクラッチ DSP]  ← 既存コードそのまま
    ↓ AUGraph HAL Output  ← 既存コードそのまま
[デフォルト出力デバイス]
```

- `muteBehavior = CATapMutedWhenTapped` により、タップ読み取り中は元のシステム出力が自動ミュートされ、停止すれば復帰する（デフォルト出力の奪取・復元処理が丸ごと不要になる）
- 自プロセスを除外することで、加工後の出力がループしてタップに戻ることを防ぐ
- タップは `privateTap = YES` とし、他プロセスから不可視にする

---

## 4. 実装ステップ

### 4.1 `AudioEngine.m` 入力経路の差し替え（コア作業）

対象: `initializeInput` / `setInputDevice` / `setInputFormat` / `setInputCallback` / `startInput` / `stopInput`

1. **タップの作成**

```objc
// Exclude own process so the processed output does not loop back into the tap
NSNumber *ownPID = @([[NSProcessInfo processInfo] processIdentifier]);
AudioObjectID ownProcessObj = /* translate PID via kAudioHardwarePropertyTranslatePIDToProcessObject */;

CATapDescription *desc = [[CATapDescription alloc]
    initStereoGlobalTapButExcludeProcesses:@[ @(ownProcessObj) ]];
desc.muteBehavior = CATapMutedWhenTapped;
desc.privateTap = YES;
desc.name = @"Scratch Now Tap";

AudioObjectID tapID = kAudioObjectUnknown;
OSStatus ret = AudioHardwareCreateProcessTap(desc, &tapID);
```

2. **プライベート Aggregate Device の作成**

Aggregate Device は**実在する出力デバイスをメインサブデバイス**（`kAudioAggregateDeviceMainSubDeviceKey` + `kAudioAggregateDeviceSubDeviceListKey`）として構成し、タップはサブタップリスト（`kAudioAggregateDeviceTapListKey`）に載せる。

> **注意**: タップだけを持つ Aggregate Device（サブデバイスリスト空）にすると、各 API は `noErr` を返し IOProc も発火するのに、バッファが**すべてゼロ（無音）になる**ことが知られている。必ずデフォルト出力デバイスの UID をメインサブデバイスに指定すること。

メインサブデバイスの UID は、既に保持しているデフォルト出力デバイス（`_preOutputDeviceID`）から `kAudioDevicePropertyDeviceUID` で取得する。

```objc
// Resolve the UID of the default output device (the aggregate must be
// anchored to a real device; a tap-only aggregate silently produces zeros)
CFStringRef outputUID = NULL;
UInt32 size = sizeof(outputUID);
AudioObjectPropertyAddress addr = {
    kAudioDevicePropertyDeviceUID,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain,
};
ret = AudioObjectGetPropertyData(_preOutputDeviceID, &addr, 0, NULL, &size, &outputUID);

NSDictionary *aggDesc = @{
    @(kAudioAggregateDeviceNameKey)          : @"Scratch Now Tap Aggregate",
    @(kAudioAggregateDeviceUIDKey)           : @"com.kyab.Scratch-Now.tap-aggregate",
    @(kAudioAggregateDeviceMainSubDeviceKey) : (__bridge NSString *)outputUID,
    @(kAudioAggregateDeviceIsPrivateKey)     : @YES,
    @(kAudioAggregateDeviceIsStackedKey)     : @NO,
    @(kAudioAggregateDeviceTapAutoStartKey)  : @YES,
    @(kAudioAggregateDeviceSubDeviceListKey) : @[
        @{ @(kAudioSubDeviceUIDKey) : (__bridge NSString *)outputUID },
    ],
    @(kAudioAggregateDeviceTapListKey)       : @[
        @{ @(kAudioSubTapUIDKey) : desc.UUID.UUIDString,
           @(kAudioSubTapDriftCompensationKey) : @YES },
    ],
};
AudioObjectID aggregateID = kAudioObjectUnknown;
ret = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggDesc, &aggregateID);
```

- デフォルト出力デバイスがユーザー操作で切り替わった場合、メインサブデバイスが古いデバイスを指したままになる。`kAudioHardwarePropertyDefaultOutputDevice` の変更を監視して Aggregate Device を作り直す対応は、フェーズ1では既知の制限として記載に留める（現行実装も出力先は起動時のデバイス固定であり退行はない）

3. **IOProc の登録**

`AudioDeviceCreateIOProcID` で IOProc を登録する。IOProc の `inInputData` にタップのキャプチャ音声が入るので、そこから既存の delegate 経由の流れ（`inCallback` → `RingBuffer` 書き込み）へ橋渡しする。

```objc
AudioDeviceIOProcID ioProcID = NULL;
ret = AudioDeviceCreateIOProcID(aggregateID, TapIOProc,
                                (__bridge void *)self, &ioProcID);
```

- 既存の `inCallback`（`AppController.m`）は「`readFromInput` を呼び返してリングバッファに書き込ませる」プル型の設計になっている。CATap の IOProc はプッシュ型（バッファが渡ってくる）なので、以下のいずれかで整合させる:
  - **案 A（推奨）**: `readFromInput` の実装を「IOProc が受け取ったバッファを `ioData` へコピーする」形に差し替える。`AppController.m` 側は無変更で済む
  - 案 B: delegate プロトコルを変更してプッシュ型に作り直す（`AppController.m` にも修正が波及）

4. **フォーマット整合（方針: デバイス固有タップのレートに合わせる）**

起動時のデフォルト出力デバイスの UID とストリーム 0 を指定してCATapを作成し、**そのタップの実フォーマットをパイプライン全体の唯一のフォーマットとして採用する**。サンプルレート変換（SRC）は入れない。

2026-07 の実機検証で、`initStereoGlobalTapButExcludeProcesses:` によるデバイス非指定のグローバルタップは、MacBook スピーカーを44.1 kHzに設定しても48 kHzを報告し続ける一方、IOProc には44,100 frames/sの周期でデータを渡すことが確認された。この報告値を採用すると、入力44,100 frames/sに対して出力が48,000 frames/sとなり、約8.84%の音程上昇とリングバッファ不足ノイズが発生する。

`initExcludingProcesses:andDeviceUID:withStream:` でデフォルト出力デバイスを明示すると、AppleのAPI契約どおりタップ形式が指定ストリーム形式と一致する。44.1 kHz・48 kHzの両設定で、タップASBD、Aggregate Device、入力・出力の実測周期がすべて一致することを確認済み。

初期化シーケンス:

```objc
// 1. Read the default output device and its UID.
// 2. Create a device-specific process tap for output stream 0.
// 3. Read the tap's stream format; this becomes the pipeline format.
AudioStreamBasicDescription tapASBD = {0};
UInt32 size = sizeof(tapASBD);
AudioObjectPropertyAddress addr = {
    kAudioTapPropertyFormat,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain,
};
ret = AudioObjectGetPropertyData(tapID, &addr, 0, NULL, &size, &tapASBD);
_engineSampleRate = tapASBD.mSampleRate;
// 4. Initialize output with mSampleRate = _engineSampleRate
// 5. Allocate RingBuffer with capacity = _engineSampleRate * 30 (seconds)
// 6. Create the aggregate device and IOProc (see steps 2-3)
```

これに伴い、44100 固定を前提としていた以下の箇所を `_engineSampleRate` 基準に変更する:

| 箇所 | 現状 | 変更 |
|------|------|------|
| `AudioEngine.m: initializeOutput` の ASBD | `mSampleRate = 44100.0` | `mSampleRate = _engineSampleRate` |
| `RingBuffer.h` の `RING_SIZE_SAMPLE`（44100×30 のコンパイル時定数） | 固定長 | `-initWithSampleRate:` を追加し、実行時に「レート × 30秒」で確保 |
| `TurnTableView.m` の回転角計算（`recordFrame / 44100.0`） | 44100 固定 | エンジンのレートを渡して計算（33.3rpm の見た目を維持） |

- チャンネルレイアウトも初期化時の `tapASBD` で1回だけ確定させる。インターリーブで渡ってくる場合は IOProc 内で L/R へデインターリーブしてからリングバッファへ書き込む（これはチャンネル並び替えのみで、レート変換ではない）
- `MiniFader` の `FADE_SAMPLE_NUM` はサンプル数基準のため、48kHz ではフェード時間が約 8% 短くなるが聴感上問題ないレベル。気になる場合のみ「レート × 秒数」に置き換える
- 実行中にデフォルト出力デバイスやそのレートが変わった場合の Aggregate Device / パイプライン再構築は、前述のデバイス切替と同様フェーズ1では既知の制限とする

5. **start / stop / 破棄**

- `startInput`: `AudioDeviceStart(aggregateID, ioProcID)`
- `stopInput`: `AudioDeviceStop(aggregateID, ioProcID)`
- 終了時: `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap` の順で破棄

### 4.2 不要コードの削除

`AudioEngine.m` / `AudioEngine.h`:

- `changeSystemOutputDeviceToBGM` / `restoreSystemOutputDevice`（デフォルト出力の奪取・復元）
- `setupVolumeSync` / `syncVolume` / `PropListenerProc`（「Scratch Now」デバイスとの音量同期。タップ経由では出力デバイスの音量がそのまま効くため不要）
- `LOOPBACK_DEVICE` 定数
- `changeInputDeviceTo:` / `listDevices:`（入力デバイス選択が不要になる場合。UI から参照が無いことを確認して削除）
- `getDeviceForName:` はループバック用途では不要になるが、他で使う場合は残す

`AppController.m`:

- `awakeFromNib` の `[_ae changeSystemOutputDeviceToBGM]` 呼び出し
- `terminate` の `[_ae restoreSystemOutputDevice]` 呼び出し

### 4.3 `Info.plist` の変更

- `NSAudioCaptureUsageDescription` を追加（例: 「再生中のシステム音声にスクラッチ加工を行うためにオーディオをキャプチャします / Scratch Now captures system audio to apply real-time scratch effects.」）
- 空文字の `NSMicrophoneUsageDescription` を削除（マイクは使用しない）

### 4.4 プロジェクト設定の変更

- `MACOSX_DEPLOYMENT_TARGET` を 14.4 に引き上げ（現状: アプリターゲット 10.14 / プロジェクト 11.3）
- `Scratch Now Driver` ターゲットはビルド対象から外さず現状維持（削除はフェーズ1のスコープ外）

---

## 5. フェーズ1でやらないこと（スコープ外）

- `Scratch Now Driver` ターゲット・ソースの削除（アプリが依存しなくなった後、別途整理）
- 出力経路（AUGraph → HAL Output）の構造変更、スクラッチ DSP、UI の変更（ASBD のレートを `_engineSampleRate` にする等、レート追従のための最小限の修正は除く）
- TCC 許可拒否時の誘導 UI（フェーズ3）
- 署名・entitlements・Hardened Runtime の整備（フェーズ2）

---

## 6. 動作確認手順

1. クリーンビルドして起動し、初回に TCC ダイアログ（システムオーディオ録音の許可）が表示されること
2. `Scratch Now Driver` をアンインストールした環境（`/Library/Audio/Plug-Ins/HAL/` から削除 + coreaudiod 再起動）で、Spotify / Apple Music / YouTube の音がキャプチャされ、ターンテーブルでスクラッチできること
3. アプリ動作中（タップ読み取り中）は元のシステム出力がミュートされ、アプリ終了で自動復帰すること
4. デフォルト出力デバイスが変更されないこと（システム設定のサウンド出力がそのままであること）
5. 自プロセスの出力（加工後の音）がループしてタップに戻らないこと
6. 音量キー（メディアキー）での音量調整が自然に効くこと
7. デフォルト出力デバイスが 48kHz で動作する環境（Audio MIDI 設定で変更可能）でも、ピッチ・再生速度が正しいこと（SRC を入れていないため、レート追従が正しければピッチずれは起き得ない）

---

## 7. 変更対象ファイル一覧

| ファイル | 変更内容 |
|----------|----------|
| `Scratch Now/AudioEngine.m` | 入力経路をデバイス固有 CATap + Aggregate Device + IOProc に差し替え。出力 ASBD をタップのレートに追従。不要コード削除 |
| `Scratch Now/AudioEngine.h` | 入力関連メンバー・メソッド宣言の更新、`_engineSampleRate` の追加 |
| `Scratch Now/AppController.m` | デフォルト出力の奪取・復元呼び出しの削除、RingBuffer 初期化へのレート受け渡し |
| `Scratch Now/RingBuffer.m` / `RingBuffer.h` | `RING_SIZE_SAMPLE` 固定長を廃止し、レート × 30秒で実行時に確保 |
| `Scratch Now/TurnTableView.m` | 回転角計算の 44100 固定をエンジンのレート参照に変更 |
| `Scratch Now/Info.plist` | `NSAudioCaptureUsageDescription` 追加、`NSMicrophoneUsageDescription` 削除 |
| `Scratch Now.xcodeproj/project.pbxproj` | `MACOSX_DEPLOYMENT_TARGET` を 14.4 へ |

変更しないもの: `MiniFader.m` / `MainMenu.xib` / `Scratch Now Driver` 一式、スクラッチ DSP 本体（`AppController.m` の補間処理）

---

## 8. 参考リソース

- [Capturing system audio with Core Audio taps — Apple Developer Docs](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [CATapDescription — Apple Developer Docs](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) — Swift での実践的なタップ実装
- [sbetko/catap](https://github.com/sbetko/catap) — mute behavior の詳細ドキュメント
