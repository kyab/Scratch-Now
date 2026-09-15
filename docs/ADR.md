# Scrollイベントによる２本指でのスクラッチ処理について
仮実装までしたが、スクロール量の量子化が低い（粗い）のでデータ源としてはNSTouchに分があることがわかった。

# NSTouchイベントによる２本指でのスクラッチ処理について
(TurnTableViewクラス)

## NSTouchイベントの前提
イベントハンドラ内でしかタッチの場所が取得できない。mouseの場合のようにタイマーから任意の時点でのカーソルの位置取得は不可であり、
不等時間間隔でのタッチ座標履歴をベースに速度検出する必要がある。タッチは早く動かすとイベントが頻繁(最速4ms程度)となり、低速だと疎になる(100ms程度)。また指を置いたままの停止時はイベントが来ないため停止検出も別途行う必要がある。

## ノイズ対策、平滑化の階層
1. 生の瞬間速度 → target（時間窓平均）
二本指の重心移動から求めた生の瞬間速度を、直近100msの時間幅重み付き平均で平滑し target(_touchSpeedTarget) とする。
これの導入前は、中〜高速の測定ノイズや大ジャンプが見受けられた。その原因として、中〜高速域ではTouchイベントのOSによる合成、Touchデバイスの量子化ノイズ、２本指によるばらつき、さらにTouchイベントの配信頻度自体が高くなることが推察される。
不等時間間隔時な速度データとなるため、時間窓での（時間幅重み付き）平均を取る。なおTouchの動きが低速だとイベントは少なくなり、平均化につかわれるデータ数は少なくなる。

before例 : scratch_log.txt
after例 :  scratch_log2.txt
_speedRateByTouchEventのデータ参照

2. target(_touchSpeedTarget) → _speedRateByTouchEvents（イベント時EMA）
タッチイベントのたびに、target を時定数付きEMAで _speedRateByTouchEvents へ反映する。出力段の第一段で、target 更新時の段差を抑えつつ指の動きへ追従する。

3. _speedRateByTouchEvents の継続更新（onLogTimer補間）
イベントが来ない間も約10ms周期で、同じEMAにより _speedRateByTouchEvents を target へ寄せ続ける。
低速域でイベントが疎なときの速度の段差を埋め、100ms無更新なら target を0にして減速する。

## タッチ離し後の惰性（coast）
離した瞬間の `_speedRateByTouchEvents` を維持し、target=0 へ `TOUCH_COAST_TAU_SEC`（接触中の `TOUCH_SPEED_TAU_SEC` とは別）で EMA 減速する。
Stop ボタンの 1.0x→停止（約 0.5s）に合わせて tau を決め、|v| < `TOUCH_COAST_END_EPSILON` で handoff（1.0x）。
離し時 |v| < `TOUCH_COAST_SKIP_EPSILON` なら惰性なしで即 handoff。
coast 中は `_isCoastingForTouchEvent` により `isUnderManualControl` を維持する。

（将来案）トルク・加減速を取り入れたダイナミクスに基づくプラッターモデル。
Cursor Request ID : 71874cb8-3042-4512-9279-0fd771162878

## 検証のヒント
ChatGPTにログをプロットさせれば効果が確認しやすい。スキル化もよさそう。
