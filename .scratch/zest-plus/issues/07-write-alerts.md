# 07: 写入提醒

**What to build:** 某程序一小时写入超过阈值（默认 2 GB）或一天超过阈值（默认 10 GB）时，发系统通知。阈值可在设置里调整，设为 0 关闭。磁盘窗口「写入提醒」页显示最近提醒记录。

**Blocked by:** 06

**Status:** ready-for-agent

规格：`.scratch/zest-plus/spec.md`

- [ ] 同一程序同一时段每档只提醒一次，重启后不重复
- [ ] 阈值 0 关闭该档
- [ ] 提醒记录写入历史存储，随「清除历史」清除
- [ ] 接缝 C 测试：每小时与每天阈值、同时段去重、阈值 0
- [ ] `VERIFY_TIER=full BASE=main Tools/verify.sh` 末行 `结论：通过`
- [ ] 新增界面文字含 `zh-Hans` 与 `en`，`Tools/check_quick_tools.py` 通过
- [ ] 启动 `build/Zest.app` 截图验收，写明未看画面

## 偏差

- 写入提醒系统通知不受「出现警告时发送系统通知」开关限制，只受两档阈值控制（0 关闭）；系统通知权限沿用现有流程，未授权时通知被系统丢弃，记录仍写入。可逆：在 `DiskIOService.flush` 加开关判断即可。
- 提醒记录保留 30 天（`pruneWriteAlerts`），超期删除；去重只需当前时段。
- 阈值为整数 GB（1 GB = 2^30 字节），超过为严格大于。
- 未启动 `build/Zest.app` 截图，未看画面。
