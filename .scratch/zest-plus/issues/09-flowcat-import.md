# 09: 从流量喵 Plus 导入

**What to build:** 设置窗口新增「从流量喵 Plus 导入」按钮。只读流量喵数据目录，导入每日整机总量、每日应用流量、每日按规则 × 出口 × 应用的链路汇总、每日按进程磁盘读写，完成后显示导入报告。小时数据、域名级链路、写入提醒记录不导入。字段与单位以流量喵源码为准，实现前先读源码确认。

**Blocked by:** 03、04、06

**Status:** ready-for-agent

规格：`.scratch/zest-plus/spec.md`

- [ ] 不修改流量喵任何文件
- [ ] 同一日期同一类别整体覆盖，重复导入不累加，单事务完成
- [ ] 报告列出每类导入天数、跳过的日期及原因
- [ ] 目录缺失或文件损坏时显示原因，已有数据不变
- [ ] 接缝 B 测试（流量喵 JSON 夹具目录）：正确导入、重复导入不累加、损坏文件不改已有数据
- [ ] `VERIFY_TIER=full BASE=main Tools/verify.sh` 末行 `结论：通过`
- [ ] 新增界面文字含 `zh-Hans` 与 `en`，`Tools/check_quick_tools.py` 通过
- [ ] 启动 `build/Zest.app` 截图验收，写明未看画面

## 偏差

**字段映射**（流量喵源码均在 `~/File/git/flowcat-plus/Sources/`；单位全为字节，日期键 `yyyy-MM-dd` 本地日，见 `Core.swift:231`）：

| 流量喵字段 | Zest 表.列 | 依据 |
|---|---|---|
| ledger.json `days.<日>.physical.received/sent` | `daily_physical.bytes_in/bytes_out` | Core.swift:66-69, 85-87 |
| ledger.json `days.<日>.processes.<进程名>.received/sent` | `daily_apps.bytes_in/bytes_out`，键见下 | Core.swift:85-88 |
| ledger.json `processPaths.<进程名>` | 决定应用键与 `apps` 元数据 | Core.swift:111, 121 |
| connections.json `days.<日>.routes.*`（规则 rule/rulePayload、`chains[0]`、`processes[0]`、`bytes.download/upload`） | `link_days.rule/egress/app/bytes_in/bytes_out`，按（规则，出口，应用）求和 | ProxyCore.swift:4-8, 88-100, 162-166 |
| disk-ledger.json `days.<日>.processes.*`（`name`、`path`、`bytes.read/written`） | `disk_days.name/path/bytes_read/bytes_written`，同 path 求和 | DiskCore.swift:3-12, 36-40 |

目录：`~/Library/Application Support/流量账本Plus/`（ProxyCore.swift:969-973）。

**自定方案**

1. 应用键：进程路径含 `.app/` 时用最外层 `.app` 路径（与 Zest `ProcessOwners.outermostApp` 一致，kind 同 `ProcessOwners.kind`），否则用进程名；`apps` 元数据只在不存在时补（INSERT OR IGNORE）。无路径的进程 kind 为系统（沿用 Zest 对读不到路径的处理）。流量喵 `ledger.processes` 以进程名为键，同一 `.app` 下多个进程名会合并。
2. 规则名：`rule` + `": "` + `rulePayload`（与 Zest `BettboxConnection.ruleName` 一致）；出口 = `chains[0]`，`direct` 大小写不敏感归一为 `DIRECT`。
3. 链路应用：流量喵 route 记录可能含多个进程（最多 12 个，无逐进程字节），只取第一个归属；无进程记空串。不导入域名（host）与小时数据；流量喵没有「未归属」行，不写未归属。同日导入会删除该日全部 `link_days` 行（含 Zest 自己的未归属行）。
4. 覆盖粒度：只处理文件里出现的日期；每日期每类别先删后写（`daily_physical`、`daily_apps`、`link_days`、`disk_days`），全部在一个事务。流量喵没有的日期保持不变。
5. 缺失与损坏：目录缺失整体失败；单个文件缺失只跳过该类别（ledger.json 缺失跳过整机与应用两类）并在报告列出；任一文件 JSON 损坏或字段类型不符整体失败，不写库。无法识别的日期键跳过并列入报告。数值超 Int64 按 Int64.max 截断。
6. 通知窗口刷新：现有机制只有告警变更通知，未新增；窗口下次刷新读取即可见。导入前若主进程尚未打开历史库（后台监控关闭）会先打开。
7. 未做：启动 `build/Zest.app` 截图验收（按派单留给主会话），界面未看画面；未跑全检。

### 审查修复补充（fix(09)，2026-11-21）

- 某天缺 `physical` 字段时，不删也不写该日整机总量，报告记为「缺少该字段」。
- 日期按公历校验，不存在的日期（如 2026-02-30）按无法识别跳过。
- 磁盘记录 `path` 为空时跳过，报告里每天记一次。
- 有 bundle 时应用名取 `.app` 显示名，与 Zest 采集一致。
- 非主进程调用导入时返回独立原因「仅菜单栏主进程可导入」。
- 真实数据演练（临时库，只读真实目录，连续导入两次）：两次的天数都是应用 13、磁盘 13、链路 12、整机 13，跳过 0；第二次后各表行数与第一次相同。
