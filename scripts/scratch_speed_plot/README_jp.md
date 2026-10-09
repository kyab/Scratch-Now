# スクラッチ速度ログのプロット

`TurnTable.m` の `processVariableRateBlock()` が呼ばれるたびに `speedStart` と `speedEnd` を記録し、`plot_scratch_speed_log.py` でプロットする。1回の呼び出しを1点として描き、平均化や間引きはしない。

オーディオスレッドは、事前に確保したロックフリーのリングへ書き込むだけである。メインスレッドのタイマーがその内容を読み出し、`experiment_log/` にある古い `[LogTimer]` ログと同じ「レコード行 + `Timestamp:` 行」形式で `NSLog` する。アプリにはサンドボックスがあるため、アプリ本体はファイルへ書かず、ログはターミナル出力として取る。

English: [README.md](README.md)

## 記録

```sh
BIN="$(xcodebuild -project "Scratch Now.xcodeproj" -scheme "Scratch Now" -configuration Release -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')/Scratch Now.app/Contents/MacOS/Scratch Now"
SCRATCH_SPEED_LOG=1 OS_ACTIVITY_MODE=disable "$BIN" 2>&1 | tee experiment_log/scratch_speed_log.txt
```

可変レート経路が動いている間（スクラッチ、惰性、Stop 減速、完全停止）は、セッション全体で記録される。終わらせるときはアプリを終了する（Cmd+Q）。`SCRATCH_SPEED_LOG=1` が無いと記録されない。

## プロット

```sh
python3 -m venv scripts/scratch_speed_plot/.venv
scripts/scratch_speed_plot/.venv/bin/pip install -r scripts/scratch_speed_plot/requirements.txt
scripts/scratch_speed_plot/.venv/bin/python scripts/scratch_speed_plot/plot_scratch_speed_log.py \
    experiment_log/scratch_speed_log.txt experiment_log/scratch_speed_plot.png
```

`--t-min` / `--t-max` で時間窓にズームする（窓の中の点はすべて描く）。 
`--width` で図の幅をインチ単位で指定する。

## 依存関係

`requirements.txt`.
