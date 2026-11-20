# 04: 链路账本持久化与时间范围

**What to build:** 链路账本写入历史存储：规则 × 出口 × 应用的日汇总（含未归属）永久保留，带域名的日记录保留 30 天，小时数据保留 24 小时。链路页可切换今日、昨日、7 天、本月，显示按小时和按天柱图；选中一条规则后，累计、下载/上传、实时速率、域名列表和柱图只统计该规则。

**Blocked by:** 01、02

**Status:** ready-for-agent

规格：`.scratch/zest-plus/spec.md`

- [ ] 跨本地 0 点时增量记入新的一天
- [ ] 域名日记录 30 天后清理，规则 × 出口 × 应用日汇总保留
- [ ] 未归属在每个范围单列一行
- [ ] 小时柱图只覆盖最近 24 小时，代码含 `shortcut:` 注释说明延长条件
- [ ] 接缝 A 测试补跨日；接缝 B 测试补链路日汇总范围查询与 30 天清理
- [ ] `VERIFY_TIER=full BASE=main Tools/verify.sh` 末行 `结论：通过`
- [ ] 新增界面文字含 `zh-Hans` 与 `en`，`Tools/check_quick_tools.py` 通过
- [ ] 启动 `build/Zest.app` 截图验收，写明未看画面

## 偏差

- 主进程链路采样：`LinkRecorder` 由 `NetworkMonitor.tick`（仅 `Role.primary`）每轮触发，节奏即 NetworkMonitor 的 interval；读不到配置不请求。上一轮请求未返回则跳过。每轮拿到快照即单事务写库，失败把增量放回待写；退出前 `flushSync` 同步写一次。
- 窗口进程仍自采实时链路与速率（`LiveLinksService`，2 秒）；累计、汇总、柱图、域名列表改读库（`LinkHistoryModel`，只读，4 秒刷新，范围或规则变化立即刷新）。旧文案「本窗口打开以来」已从界面与 xcstrings 删除。
- 未归属在库里用保留规则键 `LinkKey.unattributed`（控制字符前缀）存入日汇总与小时表；查询时单列，不进规则、出口、应用列表。选中规则后未归属显示 0。
- 小时数据含未归属行，保证按小时柱图总量与日柱一致；小时键为日期小时 yyyyMMddHH，保留 24 小时，柱图固定最近 24 小时（含当前小时），与范围切换无关；按天柱图覆盖所选范围每个自然日。`shortcut:` 注释在 `HistoryStore+Links.swift`。
- 域名列表只含 30 天内记录；范围超出 30 天的部分无域名数据（本月最长 31 天，影响至多 1 天）。
- 域名记录的域名为空时按空串存，界面显示「—」。
- `HistoryStore` 的 `db`、`exec`、`prepare`、`bind`、`text` 由 private 放宽为 internal，供扩展文件使用；`prune` 新增 `calendar` 参数（默认 `.current`）。查看器进程的 `prune`（既有行为）也会删链路过期行，与主进程规则一致。
- 「清除历史」确认文案未改（既有文案已写「每日汇总」，链路表属日汇总）。
- 未做：启动 `build/Zest.app` 截图、全检（主会话执行）。链路页布局未目视，窗口较矮时靠滚动。
