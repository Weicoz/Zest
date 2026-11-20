# 08: 磁盘健康

**What to build:** 磁盘窗口「健康」页显示内置 NVMe 盘的 SMART 状态、寿命已用百分比、累计写入量、温度等指标。外置盘和不支持的磁盘显示「此磁盘未提供 SMART 健康信息」。每小时刷新一次，打开健康页时刷新一次，不随读写采样调用。

**Blocked by:** 06

**Status:** ready-for-agent

规格：`.scratch/zest-plus/spec.md`

- [ ] 新系统优先用 diskutil 字段，缺字段时用 IOKit NVMe SMART 回退
- [ ] 读取失败不影响其他页签
- [ ] 接缝 C 测试：diskutil plist 夹具解析为健康状态与「未提供」
- [ ] `VERIFY_TIER=full BASE=main Tools/verify.sh` 末行 `结论：通过`
- [ ] 新增界面文字含 `zh-Hans` 与 `en`，`Tools/check_quick_tools.py` 通过
- [ ] 启动 `build/Zest.app` 截图验收，写明未看画面
