# 03: 应用页范围切换

**What to build:** 应用流量按日汇总并永久保留；网络窗口应用页可切换最近 24 小时、今日、昨日、7 天、本月。应用流量与整机总量分开显示，不互相校正。

**Blocked by:** 02

**Status:** ready-for-agent

规格：`.scratch/zest-plus/spec.md`

- [ ] 各范围的应用排行与写入的数据一致
- [ ] 最近 24 小时仍来自分钟明细，其余范围来自日汇总
- [ ] 接缝 B 测试覆盖应用日汇总的范围查询
- [ ] `VERIFY_TIER=full BASE=main Tools/verify.sh` 末行 `结论：通过`
- [ ] 新增界面文字含 `zh-Hans` 与 `en`，`Tools/check_quick_tools.py` 通过
- [ ] 启动 `build/Zest.app` 截图验收，写明未看画面
