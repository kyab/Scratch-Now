# スクラッチ速度ログのプロット

`TurnTable.m` の `processVariableRateBlock()` 呼び出しごとの `speedStart` /
`speedEnd` を記録し、`plot_scratch_speed_log.py` でプロットする。1呼び出し =
1点で、平均化や間引きはしない。

オーディオスレッドは事前確保したロックフリーのリングに書くだけ。メインスレッドの
タイマーがそれを読み出し、`experiment_log/` にある古い `[LogTimer]` ログと同じ
「レコード行 + `Timestamp:` 行」形式で `NSLog` する。アプリはサンドボックス付き
なので、アプリ本体がファイルへ書くのではなく、ターミナル出力をキャプチャする。

English: [README.md](README.md)

## 記録

```sh
BIN="$(xcodebuild -project "Scratch Now.xcodeproj" -scheme "Scratch Now" -configuration Release -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/Scratch Now.app/Contents/MacOS/Scratch Now"
SCRATCH_SPEED_LOG=1 OS_ACTIVITY_MODE=disable "$BIN" 2>&1 | tee experiment_log/scratch_speed_log.txt
```

可変レート経路が動いている間（スクラッチ、惰性、Stop 減速、完全停止）はセッション
全体で記録される。終了はアプリを終了（Cmd+Q）。`SCRATCH_SPEED_LOG=1` が無いと
記録されない。

## プロット

```sh
python3 -m venv scripts/scratch_speed_plot/.venv
scripts/scratch_speed_plot/.venv/bin/pip install -r scripts/scratch_speed_plot/requirements.txt
scripts/scratch_speed_plot/.venv/bin/python scripts/scratch_speed_plot/plot_scratch_speed_log.py \
    experiment_log/scratch_speed_log.txt experiment_log/scratch_speed_plot.png
```

`--t-min` / `--t-max` で時間窓にズーム（その中の点はすべて描画）。
`--width` で図の幅（インチ）を指定する。

## 依存関係

`requirements.txt` は、標準ライブラリ以外で `plot_scratch_speed_log.py` が使う
ものだけを列挙している（`matplotlib>=3.8`）。
