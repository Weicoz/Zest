# 05: 链路搜索、筛选与 CSV 导出

**What to build:** 链路页支持按域名、规则、出口、应用搜索，筛选「仅代理」或「仅直连」，并把当前筛选和时间范围内的链路账本导出为 CSV。CSV 字段与流量喵链路导出一致：日期、小时、域名、地址、端口、应用、规则、规则载荷、策略链、出口、下载、上传。

**Blocked by:** 04

**Status:** ready-for-agent

规格：`.scratch/zest-plus/spec.md`

- [ ] 搜索与筛选同时作用于列表、汇总与柱图
- [ ] 超过 30 天的范围导出时域名列留空，按规则 × 出口 × 应用粒度导出
- [ ] CSV 中含逗号、引号、换行的字段正确转义
- [ ] CSV 不含 secret
- [ ] CSV 转义有单元测试
- [ ] `VERIFY_TIER=full BASE=main Tools/verify.sh` 末行 `结论：通过`
- [ ] 新增界面文字含 `zh-Hans` 与 `en`，`Tools/check_quick_tools.py` 通过
- [ ] 启动 `build/Zest.app` 截图验收，写明未看画面
