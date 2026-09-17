#!/usr/bin/env bash
# **预览体检**：真播一遍，用数字判断平不平稳。
#
#   ./scripts/preview_health.sh <任务ID> [播几秒]
#   ./scripts/preview_health.sh            # 不给就列出可用的任务
#
# 为什么要有它：接缝闪一下、一句话说两遍这类毛病，**代码扫描一个都看不出来**
# ——闸和守卫挡的是「有人绕过规则」，挡不住「代理规格改了」「新素材类型带来
# 别的毛病」「机器慢到接缝撑不住」。那些只有真播一遍才知道。
#
# 产品负责人 2026-09-16：「每次都是在开发一些其他功能以后，这种问题就又出现。」
# 这条检查就是为了让「又出现」在他看到之前先被逮住。
#
# 怎么驱动的：用 `--task=<id>` 直接把 app 拉到那条任务上，再发一个空格
# （播放快捷键）。**不点坐标**——窗口一挪、布局一改，点坐标的脚本就废了。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/macos/Build/Products/Release/ishkafel.app"
BIN="$APP/Contents/MacOS/ishkafel"
DATA="$HOME/Library/Application Support/com.jichuang.ishkafel/ishkafel_data"
SECONDS_TO_PLAY="${2:-60}"

if [[ ! -x "$BIN" ]]; then
  echo "没有 $BIN —— 先跑 ./scripts/build_macos.sh --release" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "用法：$0 <任务ID> [播几秒]"
  echo
  echo "这台机器上的任务："
  for f in "$DATA"/tasks/*.json; do
    [[ -e "$f" ]] || continue
    python3 - "$f" <<'PY'
import json, sys, os
t = json.load(open(sys.argv[1]))
units = t.get('units') or []
print(f"  {t['id']}  #{t.get('seq')}  {t.get('name','')[:40]}  （{len(units)} 个单元）")
PY
  done
  exit 64
fi

TASK="$1"
LOG="$(mktemp -t ishkafel_health).log"
trap 'rm -f "$LOG"' EXIT

echo "开一条 ${TASK}，播 ${SECONDS_TO_PLAY} 秒…"

# 退掉在跑的，免得两个实例抢同一份数据
pkill -f "Release/ishkafel.app/Contents/MacOS/ishkafel" 2>/dev/null || true
sleep 1

"$BIN" --task="$TASK" > "$LOG" 2>&1 &
APP_PID=$!
# 无论怎么退出都要收掉它——留一个后台实例在那儿会和下一次体检抢数据
trap 'kill $APP_PID 2>/dev/null || true; rm -f "$LOG"' EXIT

# 等轨道铺好。**等日志不等固定秒数**：机器快慢差很多，等死时间要么白等
# 要么没等到
for _ in $(seq 60); do
  grep -q "画面轨换源" "$LOG" && break
  sleep 1
done
if ! grep -q "画面轨换源" "$LOG"; then
  echo "等了 60 秒也没把轨道铺起来——这条任务可能还没挑素材" >&2
  sed -n '1,20p' "$LOG" >&2
  exit 1
fi
sleep 2 # 让画面轨真的把第一帧解出来

osascript -e 'tell application "System Events" to tell process "ishkafel"
  set frontmost to true
  if (count of windows) > 0 then perform action "AXRaise" of window 1
end tell' >/dev/null 2>&1 || true
sleep 1

# 从这一刻起才算数：前面那些是加载期的日志。
# **`-n 0` 不能省**：tail -f 默认还会吐最后 10 行，加载期那次正常的
# 视频输出初始化会被算成「接缝闪了一下」
: > "${LOG}.play"
tail -n 0 -f "$LOG" > "${LOG}.play" &
TAIL_PID=$!
trap 'kill $APP_PID $TAIL_PID 2>/dev/null || true; rm -f "$LOG" "${LOG}.play"' EXIT

osascript -e 'tell application "System Events" to keystroke " "' >/dev/null 2>&1
sleep "$SECONDS_TO_PLAY"
osascript -e 'tell application "System Events" to keystroke " "' >/dev/null 2>&1

sleep 1
kill $TAIL_PID 2>/dev/null || true
kill $APP_PID 2>/dev/null || true

echo
dart run tool/preview_health.dart "${LOG}.play"
