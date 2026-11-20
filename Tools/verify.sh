#!/usr/bin/env bash
# Tools/verify.sh：weicoz-verify 自建验证命令。
# 用法：VERIFY_TIER=quick|full [BASE=main] Tools/verify.sh
# 末行结论；退出码 0 通过 / 1 不通过 / 3 未验证。
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
TIER=${VERIFY_TIER:-quick}; export VERIFY_TIER=$TIER
BASE=${BASE:-main}
fails=(); missing=()
mkdir -p build
LOG=build/verify-xctest.log

# stamp.mjs 可选：WEICOZ_VERIFY_DIR 优先，其次按 skill 安装位置查找；找不到就不写戳记。
STAMP=""
for d in "${WEICOZ_VERIFY_DIR:-}" ~/.agents/skill-tiers/library/weicoz-verify ~/.agents/skills/weicoz-verify; do
  [ -n "$d" ] && [ -f "$d/scripts/stamp.mjs" ] && { STAMP=$(readlink -f "$d/scripts/stamp.mjs"); break; }  # stamp.mjs 经软链调用时不执行，需真实路径
done
stamp() { [ -n "$STAMP" ] && node "$STAMP" "$@"; }
stamp start

echo "档位：${TIER}；负载：$(uptime | sed 's/.*load averages*: //')；核数：$(sysctl -n hw.ncpu)"

check() { # check <名称> <命令...>
  local name=$1; shift
  if out=$("$@" 2>&1); then echo "✅ $name"
  else echo "❌ $name"; echo "$out" | tail -5 | sed 's/^/    /'; fails+=("$name"); fi
}

check 快捷工具与资源检查 python3 Tools/check_quick_tools.py

# 单测：Xcode 27 命令行 xcodebuild test 启动宿主报 childPID > 0（界面正常），
# 所以经 AppleScript 让 Xcode 跑测试，再用 xcresulttool 读本次结果。
# shortcut: 依赖 Xcode 界面；xcodebuild test 修好后改回命令行。
# Xcode 界面构建会自动抽取字符串、改写 .xcstrings；测试前备份，测试后写回。
mkdir -p build/xcstrings-backup
cp Resources/*.xcstrings build/xcstrings-backup/
touch "$LOG"
open -g Zest.xcodeproj
status=$(osascript 2>&1 <<'OSA'
tell application "Xcode"
  repeat 120 times
    try
      set d to workspace document "Zest.xcodeproj"
      if loaded of d then exit repeat
    end try
    delay 1
  end repeat
  set r to test d
  repeat 1200 times
    if completed of r then exit repeat
    delay 1
  end repeat
  return status of r as text
end tell
OSA
)
cp build/xcstrings-backup/*.xcstrings Resources/
xr=$(find ~/Library/Developer/Xcode/DerivedData/Zest-*/Logs/Test -maxdepth 1 -name '*.xcresult' -newer "$LOG" 2>/dev/null | sort | tail -1)
summary=""
[ -n "$xr" ] && summary=$(xcrun xcresulttool get test-results summary --path "$xr" --compact 2>&1)
printf '%s\n%s\n%s\n' "$status" "$xr" "$summary" > "$LOG"
passed=$(printf '%s' "$summary" | grep -Eo '"passedTests":[0-9]+' | head -1 | grep -Eo '[0-9]+')
failed=$(printf '%s' "$summary" | grep -Eo '"failedTests":[0-9]+' | head -1 | grep -Eo '[0-9]+')
if [ "$status" = succeeded ] && [ "${passed:-0}" -gt 0 ] && [ "${failed:-1}" -eq 0 ]; then
  echo "✅ 单测（${passed} 个，${xr}）"
elif [ -z "$summary" ]; then
  echo "⚠️ 单测：没拿到测试结果（Xcode 状态：$status），日志 $LOG"
  missing+=("XCTest 结果")
else
  echo "❌ 单测（Xcode 状态：$status，失败 ${failed:-?} 个），结果 $xr"
  fails+=("单测")
fi

if [ "$TIER" = full ]; then
  check 本地构建 python3 Tools/build_local.py
fi

if [ ${#fails[@]} -gt 0 ]; then
  stamp finish --tier "$TIER" --code 1 --base "$BASE"
  echo "结论：不通过（失败：$(IFS=、; echo "${fails[*]}")）"; exit 1
elif [ ${#missing[@]} -gt 0 ]; then
  stamp finish --tier "$TIER" --code 3 --base "$BASE"
  echo "结论：未验证（缺：$(IFS=、; echo "${missing[*]}")）"; exit 3
fi
stamp finish --tier "$TIER" --code 0 --base "$BASE"
echo "结论：通过"
