---
title: Zest Plus：Bettbox 节点与分组出口连通监测（v2 校准版）
status: implemented
created: 2026-11-23
---

术语见仓库根 `GLOSSARY.md`；验证约定见 `AGENTS.md`。

## Problem Statement

1. 需要准确统计 Bettbox（Mihomo）普通节点与 `dialer-proxy` 链式节点在 1 天 / 7 天 / 30 天内的真实在线率与平均延时，杜绝 Mihomo `unified-delay` 超时边界假值（4000/5000ms）、多策略组重叠重复样本、未测节点默认 `alive: true` 误计在线、重载/断网风暴污染、低样本误导和前置节点缺失等失真问题。
2. 需要按当前 Bettbox 配置选定关键策略组，每 5 分钟监测该分组当前实际出站节点的连通率（服务通道视角：切换节点后连续记在分组头上），在连续 2 次超时（且本机 `DIRECT` 正常）时发 macOS 通知提醒，并在菜单栏弹窗与网络窗口置顶展示。
3. 支持主动一键测速时的增量刷盘与跨进程实时动态进度展示，以及按正则自动提取或自由组合规则（正则 / 策略组 / 指定节点 / 普通与链式筛选）的多分组趋势对比图。
4. 后台常驻资源占用必须无限接近于 0。

## Solution

### 1. 准确性全面校准（6 项根治）
- **超时边界判离线**：主动探测要求 HTTP 200 且 `0 < delay < timeoutMs`；被动吸收中 `delay >= 3900ms` 视为 Mihomo `unified-delay` 超时边界假值，按离线（`ok = false, delayMs = 0`）记录，不污染在线率与平均延时。
- **被动 30 秒冷却折叠**：同一 `(node, dialer)` 在 30 秒窗口内来自多个重叠策略组的并发测速折叠为最新 1 条，消除重复计数。
- **严格三态分离**：在线（绿）/ 离线（红）/ 未测（灰）。无任何探测历史的节点一律为「未测」，不得将 Mihomo 默认 `alive: true` 计入在线数。
- **被动风暴门控**：15 秒时间桶内若涉及 ≥ 10 个不同节点且失败率 ≥ 80%，整桶失败样本判定为本机断网或配置重载风暴，整批丢弃不污染离线分母；配置刚重载 30 秒内暂停吸收高失败突发。
- **等权聚合、低样本标注与按来源筛选**：顶部 KPI 与菜单栏弹窗改为对有样本节点等权平均；节点样本 `< 3` 时弱化并标注样本数（如 `100% (2)`）；支持切换「全部 / 仅主动基准」。
- **链式前置联动主动探测**：勾选链式策略组主动探测时默认自动纳入其 `dialer-proxy` 前置叶节点（含 `⛓` 中转节点），补齐链式归因对比。

### 2. 选定分组当前出口连通监测（服务通道视角）
- 按 `currentProfileId` 隔离保存 `watchedGroups: [String]`；Bettbox 切换配置时即时跟随。
- 每 **5 分钟** 穿透每个选定分组的 `now` 指针定位最终实际出站叶节点（防环，跳过 `DIRECT`/`REJECT`）；多个分组指向同一叶节点时本轮只发 1 次测速请求。
- 开轮前及出现超时后均以 `DIRECT` 核验本机联网，断网整轮跳过不计离线、不发通知。
- 1 天（滚动 24h）/ 7 天 / 30 天连通率与加权平均延时记在 `(profile_id, group_name)` 通道名下（切换节点无缝续算并记录当前节点名），单次测速结果同时复用到该叶节点的 `.active` 历史。
- 连续 **2 次** 探测超时且 `nodeGroupAlertEnabled` 开启时发 1 条 macOS 通知，同一故障不重复刷屏，恢复在线后重置。

### 3. 近零资源占用设计
- 用内核 `DispatchSourceFileSystemObject` 监听 Bettbox 配置目录变更（1 秒防抖），彻底移除每 10 秒空转定时器。
- 主进程仅保留 1 个 60 秒低频合并唤醒定时器（`leeway: 5s`）；屏幕/系统休眠时取消该定时器，休眠期间绝对零唤醒。
- 菜单栏弹窗关闭时不刷新节点摘要；网络窗口关闭即独立子进程退出归还内存；无新样本不开启 SQLite 写事务。

### 4. 存储迁移（`HistoryStore+Nodes.swift` schema v2）
- 新增 `node_meta(key, value)` 记录节点模块 `schema_version = 2`；首次从 v1 升级到 v2 时仅重置旧口径的 `node_*` 表（彻底清掉旧脏数据，不触碰流量、链路、磁盘等任何其他表），重构 `node_hours` / `node_days` 增加 `source` 列，并新增 `group_watch_hours`（7 天）、`group_watch_days`（永久）、`group_watch_latest` 三表。

### 5. 主动测速增量刷盘与实时动态进度
- `BettboxClient.configFingerprint()` 以 `config.yaml` 纳秒级签名 + `config.json` 的 `currentProfileId` 组合，避免 Bettbox 写入 UI 状态误取消在途测速。
- 在线样本每 3 条或每 1.5 秒增量入库；超时样本经 `DIRECT` 复检确认后刷盘；支持中途随时手动停止并保留已测结果。
- 仅测速运行期间跨进程限频广播 `NodeProbeLiveProgress`（空闲零通知、零定时器），窗口顶部呈现动态进度卡片（进度条、在途节点脉冲、最新结果流与停止按钮），表格与分组卡片行内同步显示 `测速中…`。

### 6. 自定义分组趋势对比
- 预置 4 套方案（按机场正则提取、按国家/地区、普通 vs 链式、链式落地对比），支持右上角按 全部/普通/链式 实时切换与点击图例单曲线显隐。
- 内置自由规则编辑器，支持「正则自动提取」与「自定义规则」（链路筛选 + 名称正则 + Bettbox 策略组 + 指定节点自由组合），在窗口侧单次批量只读查询聚合，后台零 CPU 开销。

## Verification Plan
- `Tests/NodeMonitorTests.swift` 覆盖 6 项校准（3900ms 假在线、30s 冷却折叠、三态未测、15s ≥80% 风暴过滤、等权汇总、链式前置联动）、分组穿透与同叶去重、分组通道 1d/7d/30d 统计、连续 2 次断线防抖重置、v1→v2 迁移保留非节点表、按来源筛选与查看器只读。
- 高风险目录 `HistoryStore.swift` / `HistoryStore+Nodes.swift` 独立审查。
- `VERIFY_TIER=full BASE=main Tools/verify.sh` 通过 + 内置 Debug 模式（`--render-snapshots` 与 `ZEST_DEBUG_NETWORK_WINDOW`）端到端截图目视验收 + 升级本机 `/Applications/Zest Plus.app`。
