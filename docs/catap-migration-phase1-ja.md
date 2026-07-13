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

4. **フォーマット整合（要検証ポイント）**

- 既存パイプラインは 44.1kHz / Float32 / 非インターリーブ 2ch 固定
- タップのフォーマットはタップ先（システム出力デバイス）に追従するため、48kHz などになる場合がある
- タップのストリームフォーマット（`kAudioTapPropertyFormat`）を実行時に取得し、以下の方針で整合させる:
  1. まず Aggregate Device / タップが 44.1kHz で動くか検証する
  2. 異なる場合は、リングバッファ書き込み前に変換するか、パイプライン全体のサンプルレートをタップのレートに合わせる（出力側 ASBD の 44100 固定も同時に変更）
- インターリーブ形式で渡ってくる場合は、リングバッファ書き込み時に L/R へデインターリーブする

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
- 出力経路（AUGraph → HAL Output）、`RingBuffer.m`、スクラッチ DSP、UI の変更
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

---

## 7. 変更対象ファイル一覧

| ファイル | 変更内容 |
|----------|----------|
| `Scratch Now/AudioEngine.m` | 入力経路を CATap + Aggregate Device + IOProc に差し替え。不要コード削除 |
| `Scratch Now/AudioEngine.h` | 入力関連メンバー・メソッド宣言の更新 |
| `Scratch Now/AppController.m` | デフォルト出力の奪取・復元呼び出しの削除 |
| `Scratch Now/Info.plist` | `NSAudioCaptureUsageDescription` 追加、`NSMicrophoneUsageDescription` 削除 |
| `Scratch Now.xcodeproj/project.pbxproj` | `MACOSX_DEPLOYMENT_TARGET` を 14.4 へ |

変更しないもの: `RingBuffer.m` / `TurnTableView.m` / `MiniFader.m` / `MainMenu.xib` / `Scratch Now Driver` 一式

---

## 8. 参考リソース

- [Capturing system audio with Core Audio taps — Apple Developer Docs](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [CATapDescription — Apple Developer Docs](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) — Swift での実践的なタップ実装
- [sbetko/catap](https://github.com/sbetko/catap) — mute behavior の詳細ドキュメント
