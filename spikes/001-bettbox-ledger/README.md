# 001: Bettbox 链路账本可行性

日期：2026-11-20。一次性实验，不进产品代码。

## 问题

1. Zest 能否读 Bettbox `GET /connections`，拿到规则、策略链、进程？
2. Zest 现有 nettop 采样（后台 8 秒 / 界面 2 秒）会不会像流量喵记录的那样慢（2–3.5 秒、120 秒超时）？
3. 按连接 id 轮询累加增量，能否记全流量？

## 结果

| 项 | 证据 | 结论 |
| --- | --- | --- |
| API | `127.0.0.1:9090/connections` 200，约 2 ms；无 secret 401 | 可用，secret 必须带 |
| 字段 | 192 条：`chains`、`rule`、`rulePayload`、`metadata.process/host/type`；process 157 条、host 114 条 | 满足链路页需要 |
| nettop | Zest 参数 `-L 1 -x -n -t external -J state,bytes_in,bytes_out` 5 次 0.03–0.04 s | 无慢调用，现采样可留 |
| 内部连接 | `metadata.type == "Inner"` 32 条，全无 process；不排除时覆盖率 107–190% | 必须排除（流量喵 `ProxyCore.swift:533` 已排除） |
| 覆盖率（排除 Inner，64 s） | 8 s 间隔：下行 99.6%、上行 83.3%；2 s 间隔：下行 99.7%、上行 87.3% | 下行准；上行短连接收尾漏记约 13–17% |

`ledger_probe.py <间隔秒> <时长秒>`：运行时从 Bettbox 配置读 secret，不打印、不落盘。

## Verdict: PARTIAL

### What worked
- 链路账本只依赖 Bettbox API，与 nettop 采样独立；API 开销可忽略。
- Zest 现 nettop 参数快，不需要照搬流量喵的超时/回退机制。

### What didn't
- 轮询差分漏记两次轮询之间关闭连接的最后字节，上行影响明显。

### Surprises
- `lsof` 在沙箱里看不到 9090 监听，但 curl 可连。
- 中转链的内部连接（Inner）会把同一流量记两次。

### Recommendation for the real build
- 账本只记非 Inner 连接；总量以 `downloadTotal/uploadTotal` 差分为准，按规则/出口的分布用连接差分，二者差额记为“未归属”。
- 可选：改用 `/connections` WebSocket 推送（Mihomo 支持）缩短漏记窗口；需另测。
- secret 只进内存；`0.0.0.0:9090` 改连 `127.0.0.1`。
