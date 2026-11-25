# Zest Plus

轻量的 macOS 菜单栏系统监控，基于 [Zest](https://github.com/biyan113/Zest) 二次开发，Swift + SwiftUI 原生实现。

下载：[GitHub Releases](https://github.com/Weicoz/Zest-plus/releases)（macOS 13 及以上）。

## 增强功能

- **链路账本**：对接本机 Clash / Mihomo 系列客户端（Bettbox、Clash Verge Rev、Mihomo Party / Clash Party、FlClash、ClashX / ClashX Pro / ClashX Meta、mihomo CLI，或自定义 `config.yaml`），按规则、出口、应用、域名统计流量，支持搜索、代理/直连筛选与 CSV 导出。
- **节点监测**：被动吸收客户端健康检查记录，按策略组原序展示节点；可勾选分组做「当前出口」连通监测、对候选组做低频主动补测，分组出口探测间隔支持 1/2/5/10/15/30 分钟。

> 只连接本机回环地址（`127.0.0.1`、`localhost`、`::1`）的 `external-controller`；`secret` 仅在本进程内存中使用，不写入偏好设置、日志或历史数据库。
- **长期历史与总量**：保存整机总量、应用流量与链路日汇总，支持今日、昨日、7 天、本月视图，以及从流量喵 Plus 导入历史汇总。
- **磁盘监控**：独立磁盘窗口展示按进程磁盘写入排行、按小时/按天写入提醒，以及内置 NVMe SMART 健康状态。
- **快捷工具**：支持 11 项快捷操作及启用、排序、全局快捷键设置，详见 [快捷工具说明](docs/quick-tools.md)。

## 构建

```bash
open Zest.xcodeproj
```

也可使用命令行工具构建本地版本：

```bash
python3 Tools/check_quick_tools.py
python3 Tools/build_local.py
open "build/Zest Plus.app"
```

## 许可

GPL-3.0-or-later，见 [LICENSE](LICENSE)。原版项目由 [@字节笔记本](https://www.bytenote.net) 开发。
