# Zest Plus

## 验证约定

按 `weicoz-verify` 执行。

- 状态：已确认（2026-11-20）
- 适配器：自建（`Tools/verify.sh`）
- 秒级检查：`python3 Tools/check_quick_tools.py`（约 9 秒）；改 Swift 时加 `xcodebuild build -project Zest.xcodeproj -scheme Zest -derivedDataPath build/DerivedData`
- 快检：`VERIFY_TIER=quick BASE=main Tools/verify.sh`（快捷工具检查 + XCTest 单测）
- 全检：`VERIFY_TIER=full BASE=main Tools/verify.sh`（快检 + `Tools/build_local.py` 本地构建）；阶段门与合并前各跑一次
- 已知问题：Xcode 27 命令行 `xcodebuild test` 启动宿主报 `childPID > 0`，界面正常；`verify.sh` 经 AppleScript 让 Xcode 跑测试，会打开 Xcode
- 目标环境：本机 `build/Zest.app`；与 `/Applications/Zest.app` 同 bundle ID，试用前由用户退出正式版
- 高风险目录：`Sources/Network/HistoryStore.swift`（SQLite 格式，菜单栏与网络窗口两进程共用）；改动交独立审查
- 禁改目录：`~/File/git/flowcat-plus`（只读参考）
