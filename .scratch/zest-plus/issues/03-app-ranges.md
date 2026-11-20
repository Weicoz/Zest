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

## 偏差

- 应用页保留原有「本次」芯片，另加最近 24 小时、今日、昨日、7 天、本月；原范围存储键 `appsRange` 的旧值（hour / day）仍兼容。
- 日汇总应用的名称与图标沿用 `apps` 表；`prune` 改为保留日汇总里仍出现的应用元数据，否则分钟明细清理后日汇总排行会丢名称。
- 未新增界面文字，范围名复用已有的 zh-Hans / en 条目。
- 截图验收未做（按派单不启动 `build/Zest.app`）。
