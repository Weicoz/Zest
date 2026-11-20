# 01: 链路页实时链路

**What to build:** 网络窗口新增「链路」页（排在「连接」之后）。Zest Plus 自动读取 Bettbox 配置里的控制器地址和 secret，按现有网络采样节奏（后台 8 秒、窗口可见 2 秒）读取连接列表，显示当前每条链路的域名、目标 IP、端口、应用、命中规则、策略链、出口和实时速率，以及本次运行期间按规则、出口、应用的累计和未归属。本票不落盘。口径见 ADR 0001。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

规格：`.scratch/zest-plus/spec.md`

- [ ] 内部连接（类型 Inner）不出现、不计入累计
- [ ] 总量取 Bettbox 自报总量差分；未归属 = 总量增量 − 逐链路增量之和，负值记 0
- [ ] Bettbox 重启（自报总量变小）后不出现负数或巨大跳变
- [ ] 出口取策略链最后一跳，直连识别为 DIRECT
- [ ] Bettbox 未运行、配置缺失、认证失败、解码失败时链路页显示对应原因，其他页照常
- [ ] 读不到 Bettbox 配置时不轮询
- [ ] 控制器为 0.0.0.0 时只连 127.0.0.1
- [ ] secret 不出现在日志、数据库或任何文件
- [ ] 接缝 A 测试（JSON 夹具快照序列）：内部连接、新/关闭连接、计数重置、Bettbox 重启、未归属负值、直连出口；每个测试先证明能失败
- [ ] `VERIFY_TIER=full BASE=main Tools/verify.sh` 末行 `结论：通过`
- [ ] 新增界面文字含 `zh-Hans` 与 `en`，`Tools/check_quick_tools.py` 通过
- [ ] 启动 `build/Zest.app` 截图验收，写明未看画面
