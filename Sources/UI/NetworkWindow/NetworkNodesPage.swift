//
//  NetworkNodesPage.swift
//  Zest
//
//  网络窗口「节点」页：
//  - 顶部置顶「分组出口监测」区块（选定分组按用户设置的间隔穿透检测当前出站节点，1d/7d/30d 服务通道连通率与断线标红）；
//  - 全量节点 1d/7d/30d 统计（严格三态、等权平均、低样本标注、按来源筛选「全部 / 仅主动」、链式前置对比）。
//

import AppKit
import Charts
import SwiftUI

private enum NodeKindFilter: String, CaseIterable, Identifiable {
    case all, direct, chain
    var id: String { rawValue }
}

private enum NodeSortOrder: String, CaseIterable, Identifiable {
    case uptimeAsc, uptimeDesc, delayAsc, delayDesc, nameAsc
    var id: String { rawValue }
}

struct NetworkNodesPage: View {
    @ObservedObject var model: NodeMonitorModel
    @ObservedObject var settings: AppSettings

    @State private var range: NodeStatsRange = .day1
    @State private var kindFilter: NodeKindFilter = .all
    @State private var sortOrder: NodeSortOrder = .uptimeDesc
    @State private var selectedGroup: String = ""
    @State private var search: String = ""
    @State private var currentConfigOnly: Bool = true
    @State private var selectedNodeId: NodeKey?
    @State private var showProbeConfig = false

    private var filteredRows: [NodeDisplayRow] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = model.rows.filter { row in
            if currentConfigOnly && !row.inCurrentConfig { return false }
            switch kindFilter {
            case .all: break
            case .direct: if row.isChain { return false }
            case .chain: if !row.isChain { return false }
            }
            if !selectedGroup.isEmpty && !row.groups.contains(selectedGroup) { return false }
            if !q.isEmpty {
                let matched = row.name.lowercased().contains(q)
                    || row.dialer.lowercased().contains(q)
                    || row.nodeType.lowercased().contains(q)
                if !matched { return false }
            }
            return true
        }
        return list.sorted { lhs, rhs in
            let tie = (lhs.name, lhs.dialer) < (rhs.name, rhs.dialer)
            switch sortOrder {
            case .uptimeAsc:
                let a = lhs.metrics(for: range).uptimeRate ?? 2.0
                let b = rhs.metrics(for: range).uptimeRate ?? 2.0
                if a != b { return a < b }
                let da = lhs.metrics(for: range).avgDelayMs ?? Int.max
                let db = rhs.metrics(for: range).avgDelayMs ?? Int.max
                if da != db { return da < db }
                return tie
            case .uptimeDesc:
                let a = lhs.metrics(for: range).uptimeRate ?? -1.0
                let b = rhs.metrics(for: range).uptimeRate ?? -1.0
                if a != b { return a > b }
                let da = lhs.metrics(for: range).avgDelayMs ?? Int.max
                let db = rhs.metrics(for: range).avgDelayMs ?? Int.max
                if da != db { return da < db }
                return tie
            case .delayAsc:
                let a = lhs.metrics(for: range).avgDelayMs ?? Int.max
                let b = rhs.metrics(for: range).avgDelayMs ?? Int.max
                if a != b { return a < b }
                return tie
            case .delayDesc:
                let a = lhs.metrics(for: range).avgDelayMs ?? -1
                let b = rhs.metrics(for: range).avgDelayMs ?? -1
                if a != b { return a > b }
                return tie
            case .nameAsc:
                return tie
            }
        }
    }

    var body: some View {
        let rows = filteredRows
        let activeScope = settings.scope(forProfile: model.profile.id)
        let plannedCount = ActiveProbePlanner.plan(topology: model.topology, scope: activeScope, includeChainUpstreams: true).count
        let watchedItems = watchedGroupRows(scope: activeScope)
        let isProbing = model.liveProgress?.isRunning == true
        let probingNames = Set(isProbing ? (model.liveProgress?.activeNodes ?? []) : [])

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PageHeader(title: L10n.text("tab.nodes", defaultValue: "节点"), subtitle: headerSubtitle) {
                    HStack(spacing: 8) {
                        Button {
                            showProbeConfig = true
                        } label: {
                            Label(L10n.text("nodes.probe.config", defaultValue: "主动探测"),
                                  systemImage: (settings.nodeActiveProbeEnabled || activeScope.hasWatchedGroups) ? "waveform.path.ecg" : "slider.horizontal.3")
                        }
                        .popover(isPresented: $showProbeConfig, arrowEdge: .bottom) {
                            ActiveProbeConfigPopover(model: model, settings: settings)
                        }
                        if isProbing {
                            Button {
                                model.cancelActiveProbe()
                            } label: {
                                Label(L10n.text("nodes.probe.stop", defaultValue: "停止测速"), systemImage: "stop.circle.fill")
                            }
                            .tint(Palette.heat)
                        } else {
                            Button {
                                if activeScope.hasAnySelection {
                                    model.triggerActiveProbe(settings: settings)
                                } else if !selectedGroup.isEmpty {
                                    model.triggerActiveProbe(settings: settings, adHocGroup: selectedGroup)
                                } else {
                                    showProbeConfig = true
                                }
                            } label: {
                                Label(L10n.text("nodes.probe.now", defaultValue: "立即探测"), systemImage: "arrow.clockwise")
                            }
                            .disabled(!settings.networkMonitoring || model.status != .available)
                            .help(!activeScope.hasAnySelection && selectedGroup.isEmpty
                                  ? L10n.text("nodes.probe.emptyTip", defaultValue: "请先点击“主动探测”勾选当前配置下要监测的分组")
                                  : L10n.text("nodes.probe.nowTip", defaultValue: "立即对当前配置勾选的分组与节点执行一轮受控测速"))
                        }
                    }
                }

                // 范围、类型、数据来源与排序行
                HStack(spacing: 6) {
                    ForEach(NodeStatsRange.allCases) { r in
                        ChipButton(title: rangeTitle(r), count: nil, selected: range == r) { range = r }
                    }
                    Divider().frame(height: 16).padding(.horizontal, 2)
                    Picker("", selection: $kindFilter) {
                        Text(L10n.text("nodes.kind.all", defaultValue: "全部")).tag(NodeKindFilter.all)
                        Text(L10n.text("nodes.kind.direct", defaultValue: "普通")).tag(NodeKindFilter.direct)
                        Text(L10n.text("nodes.kind.chain", defaultValue: "链式")).tag(NodeKindFilter.chain)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 165)
                    Picker("", selection: Binding(get: { model.sourceFilter }, set: { model.setSourceFilter($0) })) {
                        Text(L10n.text("nodes.source.all", defaultValue: "全部样本")).tag(NodeSourceFilter.all)
                        Text(L10n.text("nodes.source.active", defaultValue: "仅主动")).tag(NodeSourceFilter.activeOnly)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 135)
                    Spacer()
                    Picker(L10n.text("nodes.sort", defaultValue: "排序"), selection: $sortOrder) {
                        Text(L10n.text("nodes.sort.uptimeDesc", defaultValue: "在线率从高到低")).tag(NodeSortOrder.uptimeDesc)
                        Text(L10n.text("nodes.sort.uptimeAsc", defaultValue: "在线率从低到高")).tag(NodeSortOrder.uptimeAsc)
                        Text(L10n.text("nodes.sort.delayAsc", defaultValue: "延时从低到高")).tag(NodeSortOrder.delayAsc)
                        Text(L10n.text("nodes.sort.delayDesc", defaultValue: "延时从高到低")).tag(NodeSortOrder.delayDesc)
                        Text(L10n.text("nodes.sort.nameAsc", defaultValue: "按名称")).tag(NodeSortOrder.nameAsc)
                    }
                    .frame(maxWidth: 165)
                }

                // 搜索、策略组与当前配置过滤行
                HStack(spacing: 8) {
                    TextField(L10n.text("nodes.search", defaultValue: "搜索节点、前置链或协议"), text: $search)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 250)
                    Picker("", selection: $selectedGroup) {
                        Text(L10n.text("nodes.group.all", defaultValue: "全部策略组")).tag("")
                        ForEach(model.topology.groups) { g in
                            Text("\(g.name) (\(g.resolvedLeaves.count))").tag(g.name)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 220)
                    if !selectedGroup.isEmpty && settings.networkMonitoring && model.status == .available && !isProbing {
                        Button {
                            model.triggerActiveProbe(settings: settings, adHocGroup: selectedGroup)
                        } label: {
                            Label(L10n.text("nodes.probe.thisGroup", defaultValue: "测此组"), systemImage: "play.circle")
                                .font(.system(size: 11))
                        }
                        .controlSize(.small)
                        .help(L10n.text("nodes.probe.thisGroupTip", defaultValue: "立即对该策略组（含链式前置节点）执行一轮测速"))
                    }
                    Spacer()
                    Toggle(L10n.text("nodes.currentOnly", defaultValue: "仅当前配置"), isOn: $currentConfigOnly)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }

                if let reason = statusReason {
                    Card {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.heat)
                    }
                    .frame(maxHeight: 56)
                }

                // KPI 汇总卡（严格三态 + 等权节点平均）
                kpiBar(rows: rows, activeScope: activeScope, plannedCount: plannedCount)

                // 主动测速实时动态进度卡（仅测速进行中及刚结束时出现，空闲零占用）
                if let progress = model.liveProgress {
                    NodeLiveProbeBanner(progress: progress,
                                        onStop: { model.cancelActiveProbe() },
                                        onDismiss: { model.dismissLiveProgress() })
                }

                // 选定分组当前出口连通监测置顶卡（1A 服务通道视角 + 2B 5 分钟探测）
                if !watchedItems.isEmpty {
                    watchedGroupsCard(items: watchedItems, probingNames: probingNames)
                }

                // 主节点表
                Table(rows, selection: $selectedNodeId) {
                    TableColumn(L10n.text("nodes.col.node", defaultValue: "节点")) { r in
                        let active = probingNames.contains(r.name)
                        HStack(spacing: 6) {
                            if active {
                                NodePulseDot(color: Palette.cpu)
                            } else {
                                Circle().fill(statusDotColor(r.liveState)).frame(width: 7, height: 7)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(r.name)
                                        .fontWeight(active ? .semibold : .regular)
                                        .lineLimit(1).truncationMode(.middle)
                                    if !r.inCurrentConfig {
                                        Text(L10n.text("nodes.badge.removed", defaultValue: "历史"))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 4).padding(.vertical, 0.5)
                                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                                    }
                                }
                                if r.isChain {
                                    Text("↳ \(r.dialer)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        .help(r.isChain ? "\(r.name)\n\(r.nodeType) · dialer-proxy: \(r.dialer)" : "\(r.name) (\(r.nodeType))")
                        .contextMenu {
                            Button(L10n.text("nodes.copyName", defaultValue: "拷贝节点名")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(r.name, forType: .string)
                            }
                            if r.isChain {
                                Button(L10n.text("nodes.copyDialer", defaultValue: "拷贝前置链")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(r.dialer, forType: .string)
                                }
                            }
                        }
                    }
                    .width(min: 240, ideal: 340)

                    TableColumn(L10n.text("nodes.col.bar24h", defaultValue: "24h")) { r in
                        NodeMiniBar24h(points: r.hourly24)
                    }
                    .width(min: 84, ideal: 98)

                    TableColumn(L10n.text("nodes.col.latest", defaultValue: "最近")) { r in
                        if probingNames.contains(r.name) {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(L10n.text("nodes.probe.testing", defaultValue: "测速中…"))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Palette.cpu)
                            }
                        } else {
                            Text(latestText(r))
                                .monospacedDigit()
                                .foregroundStyle(latestColor(r))
                        }
                    }
                    .width(min: 66, ideal: 76)

                    TableColumn(L10n.text("nodes.range.day1", defaultValue: "1 天")) { r in
                        metricsCell(r.day1)
                    }
                    .width(min: 88, ideal: 98)

                    TableColumn(L10n.text("nodes.range.day7", defaultValue: "7 天")) { r in
                        metricsCell(r.day7)
                    }
                    .width(min: 88, ideal: 98)

                    TableColumn(L10n.text("nodes.range.day30", defaultValue: "30 天")) { r in
                        metricsCell(r.day30)
                    }
                    .width(min: 88, ideal: 98)
                }
                .font(.system(size: 11.5))
                .frame(minHeight: 260, maxHeight: 340)

                // 自定义分组趋势对比（按机场 / 按国家 / 普通 vs 链式 / 链式落地 / 用户自由定制规则与正则）
                NodeGroupTrendsSection(model: model, settings: settings, range: range, currentConfigOnly: currentConfigOnly)

                if let key = selectedNodeId, let row = rows.first(where: { $0.key == key }) {
                    NodeDetailSection(row: row, range: range, detail: model.detail)
                } else {
                    Text(L10n.text("nodes.selectHint", defaultValue: "点选任意节点查看 1 天 / 7 天 / 30 天趋势曲线；选中链式节点可对比前置节点的同期在线率与延时。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(String(format: L10n.text("nodes.footnote", defaultValue: "被动吸收每 60 秒清洗 30 秒内多组重复与超时边界假值，风暴期自动跳过；选定分组出口每 %lld 分钟独立检测并在连续 2 次超时后通知。未测节点单列，低样本标注次数。"), Int64(settings.nodeGroupWatchIntervalMinutes)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .id(settings.appLanguage)
        .onAppear { model.select(key: selectedNodeId, range: range); model.start() }
        .onDisappear { model.stop() }
        .onChange(of: selectedNodeId) { model.select(key: $0, range: range) }
        .onChange(of: range) { model.select(key: selectedNodeId, range: $0) }
        .onChange(of: model.topology.groups.map(\.name)) { names in
            if !selectedGroup.isEmpty && !names.contains(selectedGroup) {
                selectedGroup = ""
            }
        }
        .onChange(of: rows.map(\.key)) { visibleKeys in
            if let key = selectedNodeId, !visibleKeys.contains(key) {
                selectedNodeId = nil
            }
        }
    }

    private func watchedGroupRows(scope: NodeProbeScope) -> [GroupWatchSummaryRecord] {
        // 置顶卡按策略组拓扑顺序展示，不再二次按勾选写入顺序或字母序打乱。
        let known = Set(model.topology.groups.map(\.name))
        let ordered = model.topology.groups.map(\.name).filter { scope.watchedGroups.contains($0) }
            + scope.watchedGroups.filter { !known.contains($0) }
        return ordered.compactMap { gName in
            let liveLeaf = model.topology.resolveCurrentLeaf(ofGroup: gName)
            if var rec = model.groupWatches[gName] {
                if let liveLeaf {
                    rec.currentNode = liveLeaf.name
                    rec.dialer = liveLeaf.dialerProxy
                }
                if rec.hourly24.isEmpty { rec.hourly24 = model.emptyHours24 }
                return rec
            }
            guard let liveLeaf else { return nil }
            return GroupWatchSummaryRecord(groupName: gName, currentNode: liveLeaf.name, dialer: liveLeaf.dialerProxy,
                                           hourly24: model.emptyHours24)
        }
    }

    @ViewBuilder
    private func watchedGroupsCard(items: [GroupWatchSummaryRecord], probingNames: Set<String>) -> some View {
        Card {
            CardHeader(symbol: "shield.checkered",
                       title: String(format: L10n.text("nodes.watch.title", defaultValue: "分组当前出口监测（每 %lld 分钟）"),
                                     Int64(settings.nodeGroupWatchIntervalMinutes)),
                       tint: Palette.memory,
                       trailing: settings.nodeGroupAlertEnabled
                           ? L10n.text("nodes.watch.alertOn", defaultValue: "连续 2 次超时通知")
                           : L10n.text("nodes.watch.alertOff", defaultValue: "断线通知已关"))
            ForEach(items) { item in
                let active = probingNames.contains(item.currentNode)
                HStack(spacing: 8) {
                    if active {
                        NodePulseDot(color: Palette.cpu)
                    } else {
                        Circle().fill(statusDotColor(item.liveState)).frame(width: 7, height: 7)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(item.groupName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if item.latestMatchesCurrentNode, let f = item.latest?.consecutiveFailures, f >= 2 {
                                Text(String(format: L10n.text("nodes.watch.failBadge"), Int64(f)))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Palette.heat))
                            }
                        }
                        Text("↳ \(item.currentNode)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

                    NodeMiniBar24h(points: item.hourly24).frame(width: 84)
                    if active {
                        HStack(spacing: 3) {
                            ProgressView().controlSize(.mini)
                            Text(L10n.text("nodes.probe.testing", defaultValue: "测速中…"))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Palette.cpu)
                        }
                        .frame(width: 68, alignment: .trailing)
                    } else {
                        Text(watchLatestText(item))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(watchLatestColor(item))
                            .frame(width: 68, alignment: .trailing)
                    }
                    watchRangeBadge("1d", item.day1)
                    watchRangeBadge("7d", item.day7)
                    watchRangeBadge("30d", item.day30)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    let key = NodeKey(name: item.currentNode, dialer: item.dialer)
                    guard model.rowsByKey[key] != nil else { return }
                    if !filteredRows.contains(where: { $0.key == key }) {
                        kindFilter = .all
                        selectedGroup = ""
                        search = ""
                        currentConfigOnly = false
                    }
                    selectedNodeId = key
                }
            }
        }
    }

    private func watchRangeBadge(_ label: String, _ m: NodeWindowMetrics) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            if m.probes == 0 {
                Text("—").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                Text(formatUptime(m.uptimeRate))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(uptimeColor(m.uptimeRate))
                Text(formatDelay(m.avgDelayMs))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, alignment: .trailing)
        .help(m.probes > 0
              ? String(format: L10n.text("nodes.cell.help"), Int64(m.ok), Int64(m.probes), formatDelay(m.avgDelayMs), minMaxText(m))
              : L10n.text("nodes.noSamples", defaultValue: "暂无样本"))
    }

    private func watchLatestText(_ item: GroupWatchSummaryRecord) -> String {
        guard item.latestMatchesCurrentNode, let latest = item.latest else {
            return L10n.text("nodes.untested", defaultValue: "未测")
        }
        return latest.ok ? "\(latest.delayMs) ms" : L10n.text("nodes.offline", defaultValue: "离线")
    }

    private func watchLatestColor(_ item: GroupWatchSummaryRecord) -> Color {
        guard item.latestMatchesCurrentNode, let latest = item.latest else { return .secondary }
        return latest.ok ? delayColor(latest.delayMs) : Palette.heat
    }

    private var headerSubtitle: String {
        let total = model.topology.leaves.count
        let chains = model.topology.leaves.values.filter(\.isChain).count
        let direct = total - chains
        let profileName = model.profile.label.isEmpty ? model.profile.id : model.profile.label
        return String(format: L10n.text("nodes.subtitle"), profileName, Int64(total), Int64(direct), Int64(chains))
    }

    private var statusReason: String? {
        let name = model.clientName
        switch model.status {
        case .available: return nil
        case .starting: return String(format: L10n.text("nodes.client.connecting", defaultValue: "正在连接 %@…"), name)
        case .notRunning: return String(format: L10n.text("nodes.client.notRunning", defaultValue: "%@ 未运行，或控制器无法连接"), name)
        case .configMissing: return String(format: L10n.text("nodes.client.configMissing", defaultValue: "找不到 %@ 配置，未读取节点"), name)
        case .nonLocalController: return String(format: L10n.text("nodes.client.nonLocal", defaultValue: "%@ 控制器不是本机地址，为保护 secret 不连接"), name)
        case .authFailed: return String(format: L10n.text("nodes.client.authFailed", defaultValue: "%@ 控制器认证失败，请检查配置里的 secret"), name)
        case .decodeFailed: return String(format: L10n.text("nodes.client.decodeFailed", defaultValue: "无法解析 %@ 返回的节点数据"), name)
        }
    }

    @ViewBuilder
    private func kpiBar(rows: [NodeDisplayRow], activeScope: NodeProbeScope, plannedCount: Int) -> some View {
        let agg = NodeEqualWeightAggregate.compute(from: rows.map { $0.metrics(for: range) })
        let onlineNow = rows.filter { $0.liveState == .online }.count
        let offlineNow = rows.filter { $0.liveState == .offline }.count
        let untestedNow = rows.filter { $0.liveState == .untested }.count

        let activeValue: String = {
            if activeScope.hasWatchedGroups && settings.nodeActiveProbeEnabled {
                return String(format: L10n.text("nodes.active.both"), Int64(activeScope.watchedGroups.count), Int64(settings.nodeProbeIntervalMinutes))
            }
            if activeScope.hasWatchedGroups {
                return String(format: L10n.text("nodes.active.watchOnly"),
                              Int64(activeScope.watchedGroups.count),
                              Int64(settings.nodeGroupWatchIntervalMinutes))
            }
            if settings.nodeActiveProbeEnabled {
                return String(format: L10n.text("nodes.active.on"), Int64(settings.nodeProbeIntervalMinutes))
            }
            return L10n.text("nodes.active.off", defaultValue: "仅被动采集")
        }()

        let activeSub: String = {
            if let run = model.lastActiveRun, run.profileId == model.profile.id {
                if run.skippedReason == "offline" {
                    return L10n.text("nodes.active.skippedOffline", defaultValue: "上次跳过：本机断网")
                }
                return String(format: L10n.text("nodes.active.lastRun"), Int64(run.online), Int64(run.probed))
            }
            return String(format: L10n.text("nodes.active.scope"), Int64(activeScope.groups.count), Int64(plannedCount))
        }()

        HStack(spacing: 10) {
            KPI(title: L10n.text("nodes.kpi.count", defaultValue: "监测节点"),
                value: "\(rows.count)",
                sub: String(format: L10n.text("nodes.kpi.triState"), Int64(onlineNow), Int64(offlineNow), Int64(untestedNow)))
            KPI(title: String(format: L10n.text("nodes.kpi.uptime"), rangeTitle(range)),
                value: formatUptime(agg.avgUptimeRate),
                sub: agg.sampledNodeCount > 0
                    ? String(format: L10n.text("nodes.kpi.equalWeight"), Int64(agg.sampledNodeCount), Int64(agg.totalProbes))
                    : L10n.text("nodes.noSamples", defaultValue: "暂无样本"),
                tint: uptimeColor(agg.avgUptimeRate))
            KPI(title: String(format: L10n.text("nodes.kpi.delay"), rangeTitle(range)),
                value: formatDelay(agg.avgDelayMs),
                sub: minMaxAggText(agg),
                tint: Palette.cpu)
            KPI(title: L10n.text("nodes.kpi.active", defaultValue: "主动探测"),
                value: activeValue,
                sub: activeSub,
                tint: (settings.nodeActiveProbeEnabled || activeScope.hasWatchedGroups) ? Palette.memory : .secondary,
                size: 15)
        }
    }

    @ViewBuilder
    private func metricsCell(_ m: NodeWindowMetrics) -> some View {
        if m.probes == 0 {
            Text("—").foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 3) {
                Text(m.isLowSample ? "\(formatUptime(m.uptimeRate))(\(m.probes))" : formatUptime(m.uptimeRate))
                    .foregroundStyle(uptimeColor(m.uptimeRate).opacity(m.isLowSample ? 0.72 : 1.0))
                    .fontWeight(m.isLowSample ? .regular : .medium)
                Text("·").foregroundStyle(.tertiary)
                Text(formatDelay(m.avgDelayMs))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .help(String(format: L10n.text("nodes.cell.help"), Int64(m.ok), Int64(m.probes), formatDelay(m.avgDelayMs), minMaxText(m)))
        }
    }

    private func rangeTitle(_ r: NodeStatsRange) -> String {
        switch r {
        case .day1: return L10n.text("nodes.range.day1", defaultValue: "1 天")
        case .day7: return L10n.text("nodes.range.day7", defaultValue: "7 天")
        case .day30: return L10n.text("nodes.range.day30", defaultValue: "30 天")
        }
    }

    private func statusDotColor(_ state: NodeLiveState) -> Color {
        switch state {
        case .online: return Palette.memory
        case .offline: return Palette.heat
        case .untested: return Color.gray.opacity(0.45)
        }
    }

    private func latestText(_ r: NodeDisplayRow) -> String {
        switch r.liveState {
        case .online: return r.latestDelayMs.map { "\($0) ms" } ?? "—"
        case .offline: return L10n.text("nodes.offline", defaultValue: "离线")
        case .untested: return L10n.text("nodes.untested", defaultValue: "未测")
        }
    }

    private func latestColor(_ r: NodeDisplayRow) -> Color {
        switch r.liveState {
        case .online: return r.latestDelayMs.map(delayColor) ?? .secondary
        case .offline: return Palette.heat
        case .untested: return .secondary
        }
    }
}

// MARK: - 实时主动测速动态状态卡与脉冲指示点

private struct NodePulseDot: View {
    var color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(pulse ? 0.16 : 0.45))
                .frame(width: 11, height: 11)
                .scaleEffect(pulse ? 1.25 : 0.8)
            Circle()
                .fill(color)
                .frame(width: 6.5, height: 6.5)
        }
        .frame(width: 11, height: 11)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct NodeLiveProbeBanner: View {
    var progress: NodeProbeLiveProgress
    var onStop: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if progress.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(statusTint)
                    }
                    Text(phaseTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(progress.isRunning ? .primary : statusTint)
                    if progress.total > 0 {
                        Text(String(format: L10n.text("nodes.live.stats"),
                                    Int64(progress.completed), Int64(progress.total),
                                    Int64(progress.online), Int64(progress.offline)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if progress.isRunning {
                        Button(L10n.text("nodes.probe.stop", defaultValue: "停止测速"), action: onStop)
                            .controlSize(.small)
                            .tint(Palette.heat)
                    } else {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if progress.isRunning {
                    if progress.total > 0 {
                        ProgressView(value: Double(min(progress.completed, progress.total)),
                                     total: Double(max(progress.total, 1)))
                            .progressViewStyle(.linear)
                            .tint(Palette.cpu)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(Palette.cpu)
                    }
                }

                if progress.isRunning && !progress.activeNodes.isEmpty {
                    HStack(alignment: .center, spacing: 6) {
                        Text(L10n.text("nodes.live.testingNow", defaultValue: "正在测"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(progress.activeNodes, id: \.self) { name in
                                    HStack(spacing: 4) {
                                        NodePulseDot(color: Palette.cpu)
                                        Text(name)
                                            .font(.system(size: 10.5, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: 210, alignment: .leading)
                                    }
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(Palette.cpu.opacity(0.12)))
                                }
                            }
                        }
                    }
                }

                if !progress.recentResults.isEmpty {
                    HStack(alignment: .center, spacing: 6) {
                        Text(L10n.text("nodes.live.recent", defaultValue: "最新结果"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(progress.recentResults.prefix(5)) { ev in
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(ev.ok ? Palette.memory : Palette.heat)
                                            .frame(width: 6, height: 6)
                                        Text(ev.groupName.map { "\($0) · \(ev.node)" } ?? ev.node)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: 165, alignment: .leading)
                                        Text(ev.ok ? "\(ev.delayMs) ms" : L10n.text("nodes.live.timeout", defaultValue: "超时"))
                                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(ev.ok ? Palette.memory : Palette.heat)
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.05)))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var phaseTitle: String {
        switch progress.phase {
        case .checkingDirect: return L10n.text("nodes.live.checkingDirect", defaultValue: "正在校验本机网络…")
        case .watchingGroups: return L10n.text("nodes.live.watchingGroups", defaultValue: "正在检测分组当前出口…")
        case .probingBulk: return L10n.text("nodes.live.probingBulk", defaultValue: "正在测速节点…")
        case .finished: return L10n.text("nodes.live.finished", defaultValue: "本轮测速完成")
        case .cancelled: return L10n.text("nodes.live.cancelled", defaultValue: "已停止测速（已测结果已保存）")
        case .skippedOffline: return L10n.text("nodes.live.skippedOffline", defaultValue: "本机断网，已跳过本轮测速")
        }
    }

    private var statusIcon: String {
        switch progress.phase {
        case .finished: return "checkmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .skippedOffline: return "wifi.slash"
        default: return "waveform.path.ecg"
        }
    }

    private var statusTint: Color {
        switch progress.phase {
        case .finished: return Palette.memory
        case .cancelled: return .secondary
        case .skippedOffline: return Palette.heat
        default: return Palette.cpu
        }
    }
}

// MARK: - 监测与主动探测配置弹窗（统一管理：分组出口周期监测 + 候选组批量探测）

private struct ActiveProbeConfigPopover: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NodeMonitorModel
    @ObservedObject var settings: AppSettings
    @State private var tab = 0
    @State private var groupSearch = ""

    var body: some View {
        let profileId = model.profile.id
        let profileLabel = model.profile.label.isEmpty ? profileId : model.profile.label
        let scope = settings.scope(forProfile: profileId)
        let watchedSet = Set(scope.watchedGroups)
        let bulkSet = Set(scope.groups)
        let plannedCount = ActiveProbePlanner.plan(topology: model.topology, scope: scope, includeChainUpstreams: true).count
        let filteredGroups = model.topology.groups.filter { g in
            groupSearch.isEmpty || g.name.localizedCaseInsensitiveContains(groupSearch)
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("nodes.probe.title", defaultValue: "主动探测设置"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(profileLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }

            Picker("", selection: $tab) {
                Text(String(format: L10n.text("nodes.probe.tabWatch", defaultValue: "分组当前出口 (%lld分)"),
                            Int64(settings.nodeGroupWatchIntervalMinutes))).tag(0)
                Text(L10n.text("nodes.probe.tabBulk", defaultValue: "候选组全量测速")).tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()

            if tab == 0 {
                Toggle(L10n.text("nodes.watch.alertToggle", defaultValue: "连续 2 次超时发送断线系统通知"), isOn: $settings.nodeGroupAlertEnabled)
                    .font(.system(size: 12))
                HStack {
                    Text(L10n.text("nodes.probe.interval", defaultValue: "探测间隔"))
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $settings.nodeGroupWatchIntervalMinutes) {
                        ForEach(AppSettings.nodeGroupWatchIntervalChoices, id: \.self) { m in
                            Text(String(format: L10n.text("%lld 分钟"), Int64(m))).tag(m)
                        }
                    }
                    .labelsHidden().frame(width: 110)
                }
                Text(String(format: L10n.text("nodes.watch.desc", defaultValue: "每 %lld 分钟穿透检测选定分组当前实际出站的叶节点（同叶合并只测 1 次），切换节点后连通率连续记在该分组名下。"),
                            Int64(settings.nodeGroupWatchIntervalMinutes)))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                Toggle(L10n.text("nodes.probe.enable", defaultValue: "启用定时主动探测"), isOn: $settings.nodeActiveProbeEnabled)
                    .font(.system(size: 12))
                HStack {
                    Text(L10n.text("nodes.probe.interval", defaultValue: "探测间隔"))
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $settings.nodeProbeIntervalMinutes) {
                        ForEach(AppSettings.nodeProbeIntervalChoices, id: \.self) { m in
                            Text(String(format: L10n.text("%lld 分钟"), Int64(m))).tag(m)
                        }
                    }
                    .labelsHidden().frame(width: 110)
                }
            }

            Divider()

            HStack {
                Text(tab == 0
                     ? L10n.text("nodes.watch.groupsTitle", defaultValue: "勾选要持续盯住当前出口的分组")
                     : L10n.text("nodes.probe.groupsTitle", defaultValue: "当前配置勾选的策略组"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(tab == 0
                     ? String(format: L10n.text("nodes.watch.count"), Int64(scope.watchedGroups.count))
                     : String(format: L10n.text("nodes.active.scope"), Int64(scope.groups.count), Int64(plannedCount)))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }

            TextField(L10n.text("nodes.probe.searchGroup", defaultValue: "筛选策略组"), text: $groupSearch)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if filteredGroups.isEmpty {
                        Text(String(format: L10n.text("nodes.probe.noGroups", defaultValue: "当前 %@ 未返回可用策略组"), model.clientName))
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(filteredGroups) { g in
                            if tab == 0 {
                                let isOn = watchedSet.contains(g.name)
                                let currentLeafName = model.topology.resolveCurrentLeaf(ofGroup: g.name)?.name ?? (g.now ?? "—")
                                Toggle(isOn: Binding(
                                    get: { isOn },
                                    set: { checked in
                                        var next = watchedSet
                                        if checked { next.insert(g.name) } else { next.remove(g.name) }
                                        settings.setScope(NodeProbeScope(groups: scope.groups, nodes: scope.nodes,
                                                                  watchedGroups: model.topology.groups.map(\.name).filter { next.contains($0) }),
                                                          forProfile: profileId)
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(g.name).lineLimit(1).truncationMode(.middle)
                                        Text("↳ \(currentLeafName)")
                                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5))
                            } else {
                                let isOn = bulkSet.contains(g.name)
                                Toggle(isOn: Binding(
                                    get: { isOn },
                                    set: { checked in
                                        var next = bulkSet
                                        if checked { next.insert(g.name) } else { next.remove(g.name) }
                                        settings.setScope(NodeProbeScope(groups: model.topology.groups.map(\.name).filter { next.contains($0) }, nodes: scope.nodes, watchedGroups: scope.watchedGroups),
                                                          forProfile: profileId)
                                    }
                                )) {
                                    HStack(spacing: 6) {
                                        Text(g.name).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("\(g.type) · \(g.resolvedLeaves.count)")
                                            .font(.system(size: 10).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5))
                            }
                        }
                    }
                }
            }
            .frame(height: 195)

            HStack {
                Button(L10n.text("nodes.probe.clear", defaultValue: "清空当前配置勾选")) {
                    if tab == 0 {
                        settings.setScope(NodeProbeScope(groups: scope.groups, nodes: scope.nodes, watchedGroups: []), forProfile: profileId)
                    } else {
                        settings.setScope(NodeProbeScope(groups: [], nodes: [], watchedGroups: scope.watchedGroups), forProfile: profileId)
                    }
                }
                .disabled(tab == 0 ? !scope.hasWatchedGroups : scope.isEmpty)
                Spacer()
                if model.liveProgress?.isRunning == true {
                    Button(L10n.text("nodes.probe.stop", defaultValue: "停止测速")) {
                        model.cancelActiveProbe()
                        dismiss()
                    }
                    .tint(Palette.heat)
                } else {
                    Button(L10n.text("nodes.probe.now", defaultValue: "立即探测")) {
                        model.triggerActiveProbe(settings: settings)
                        dismiss()
                    }
                    .disabled(!settings.networkMonitoring || !scope.hasAnySelection || model.status != .available)
                }
            }
            .font(.system(size: 11))

            Text(String(format: L10n.text("nodes.probe.note", defaultValue: "勾选按 %@ 配置独立保存；链式组主动测速自动联动其前置中转节点，同落地串行限流，超时 4000ms。"), model.clientName))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 360)
    }
}

// MARK: - 24h 微型状态条

private struct NodeMiniBar24h: View {
    var points: [NodeHourPoint]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, pt in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color(for: pt.health))
                    .frame(height: 12)
                    .help(helpText(pt))
            }
        }
    }

    private func color(for health: NodeSlotHealth) -> Color {
        switch health {
        case .noData: return Color.primary.opacity(0.10)
        case .healthy: return Palette.memory
        case .degraded: return Palette.wired
        case .down: return Palette.heat
        }
    }

    private func helpText(_ pt: NodeHourPoint) -> String {
        let hour = pt.hour % 100
        if pt.metrics.probes == 0 {
            return String(format: L10n.text("nodes.slot.empty"), Int64(hour))
        }
        return String(format: L10n.text("nodes.slot.help"), Int64(hour), formatUptime(pt.metrics.uptimeRate),
                      Int64(pt.metrics.ok), Int64(pt.metrics.probes), formatDelay(pt.metrics.avgDelayMs))
    }
}

// MARK: - 选中节点详情与链式前置对比

private struct NodeDetailSection: View {
    var row: NodeDisplayRow
    var range: NodeStatsRange
    var detail: NodeDetailComparison?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                        Text(metaLine).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    rangeCard(L10n.text("nodes.range.day1", defaultValue: "1 天"), row.day1)
                    rangeCard(L10n.text("nodes.range.day7", defaultValue: "7 天"), row.day7)
                    rangeCard(L10n.text("nodes.range.day30", defaultValue: "30 天"), row.day30)
                }
                .padding(.top, 4)
            }

            if row.isChain {
                chainComparisonCard
            }

            if let detail, detail.primaryKey == row.key {
                HStack(spacing: 10) {
                    Card {
                        CardHeader(symbol: "chart.xyaxis.line",
                                   title: L10n.text("nodes.chart.delay", defaultValue: "平均延时趋势 (ms)"),
                                   tint: Palette.cpu,
                                   trailing: detail.upstreamRow != nil ? L10n.text("nodes.chart.dualLegend", defaultValue: "蓝：当前链式 · 绿：前置节点") : nil)
                        NodeDelayChart(primary: detail.primarySeries, upstream: detail.upstreamSeries)
                            .frame(height: 130)
                    }
                    Card {
                        CardHeader(symbol: "checkmark.seal",
                                   title: L10n.text("nodes.chart.uptime", defaultValue: "在线率趋势 (%)"),
                                   tint: Palette.memory)
                        NodeUptimeChart(points: detail.primarySeries)
                            .frame(height: 130)
                    }
                }
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if !row.nodeType.isEmpty { parts.append(row.nodeType) }
        if row.isChain { parts.append("dialer-proxy: \(row.dialer)") }
        if !row.groups.isEmpty {
            let shown = row.groups.prefix(3).joined(separator: ", ")
            parts.append(row.groups.count > 3 ? "\(shown) +\(row.groups.count - 3)" : shown)
        }
        return parts.joined(separator: " · ")
    }

    private func rangeCard(_ title: String, _ m: NodeWindowMetrics) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatUptime(m.uptimeRate))
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(uptimeColor(m.uptimeRate))
                Text(formatDelay(m.avgDelayMs))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(m.probes > 0
                 ? "\(m.ok)/\(m.probes) · \(minMaxText(m))"
                 : L10n.text("nodes.noSamples", defaultValue: "暂无样本"))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    @ViewBuilder
    private var chainComparisonCard: some View {
        let upstream = detail?.primaryKey == row.key ? detail?.upstreamRow : nil
        let resolution = row.dialerResolution
        Card {
            CardHeader(symbol: "point.topleft.down.curvedto.point.bottomright.up",
                       title: L10n.text("nodes.chain.title", defaultValue: "链式前置归因对比"),
                       tint: Palette.disk,
                       trailing: upstreamLabel(resolution))
            if let upstream {
                HStack(spacing: 10) {
                    compareColumn(L10n.text("nodes.range.day1", defaultValue: "1 天"), chain: row.day1, upstream: upstream.day1)
                    compareColumn(L10n.text("nodes.range.day7", defaultValue: "7 天"), chain: row.day7, upstream: upstream.day7)
                    compareColumn(L10n.text("nodes.range.day30", defaultValue: "30 天"), chain: row.day30, upstream: upstream.day30)
                }
            } else {
                Text(L10n.text("nodes.chain.noUpstream", defaultValue: "未找到前置节点的同期历史数据（开启对应链式组主动探测将自动联动测速前置节点）。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func upstreamLabel(_ r: DialerResolution) -> String {
        switch r {
        case .leaf(let k): return k.name
        case .group(let g, let leaf):
            if let leaf { return "\(g) → \(leaf.name)" }
            return g
        case .unresolved(let raw): return raw
        case .direct: return ""
        }
    }

    private func compareColumn(_ title: String, chain: NodeWindowMetrics, upstream: NodeWindowMetrics) -> some View {
        let deltaMs: String = {
            guard let c = chain.avgDelayMs, let u = upstream.avgDelayMs else { return "—" }
            let d = c - u
            return d >= 0 ? "+\(d) ms" : "\(d) ms"
        }()
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            StatRow(label: L10n.text("nodes.chain.current", defaultValue: "当前链式"),
                    value: "\(formatUptime(chain.uptimeRate)) · \(formatDelay(chain.avgDelayMs))",
                    dot: Palette.cpu)
            StatRow(label: L10n.text("nodes.chain.upstream", defaultValue: "前置节点"),
                    value: "\(formatUptime(upstream.uptimeRate)) · \(formatDelay(upstream.avgDelayMs))",
                    dot: Palette.memory)
            StatRow(label: L10n.text("nodes.chain.overhead", defaultValue: "落地增延"), value: deltaMs)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

// MARK: - 趋势图组件

private struct NodeDelayChart: View {
    var primary: [NodeTrendPoint]
    var upstream: [NodeTrendPoint]

    var body: some View {
        let hasData = primary.contains { $0.avgDelayMs != nil } || upstream.contains { $0.avgDelayMs != nil }
        if !hasData {
            Unavailable(text: L10n.text("nodes.noSamples", defaultValue: "暂无样本"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(primary) { pt in
                    if let ms = pt.avgDelayMs {
                        LineMark(x: .value("T", pt.index), y: .value("ms", ms), series: .value("S", "chain"))
                            .foregroundStyle(Palette.cpu)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("T", pt.index), y: .value("ms", ms))
                            .foregroundStyle(Palette.cpu)
                            .symbolSize(16)
                    }
                }
                ForEach(upstream) { pt in
                    if let ms = pt.avgDelayMs {
                        LineMark(x: .value("T", pt.index), y: .value("ms", ms), series: .value("S", "upstream"))
                            .foregroundStyle(Palette.memory)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                        PointMark(x: .value("T", pt.index), y: .value("ms", ms))
                            .foregroundStyle(Palette.memory)
                            .symbolSize(12)
                    }
                }
            }
            .chartXScale(domain: 0...max(primary.count - 1, 1))
            .chartXAxis {
                let step = max(1, primary.count / 6)
                AxisMarks(values: Array(stride(from: 0, to: max(primary.count, 1), by: step))) { v in
                    AxisValueLabel {
                        if let i = v.as(Int.self), primary.indices.contains(i) {
                            Text(primary[i].label).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ms = v.as(Int.self) { Text("\(ms)").font(.system(size: 9)) }
                    }
                }
            }
        }
    }
}

private struct NodeUptimeChart: View {
    var points: [NodeTrendPoint]

    var body: some View {
        let hasData = points.contains { $0.uptimeRate != nil }
        if !hasData {
            Unavailable(text: L10n.text("nodes.noSamples", defaultValue: "暂无样本"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(points) { pt in
                    if let rate = pt.uptimeRate {
                        BarMark(x: .value("T", pt.index), y: .value("%", rate * 100.0), width: .ratio(0.65))
                            .foregroundStyle(uptimeColor(rate))
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: 0...max(points.count - 1, 1))
            .chartXAxis {
                let step = max(1, points.count / 6)
                AxisMarks(values: Array(stride(from: 0, to: max(points.count, 1), by: step))) { v in
                    AxisValueLabel {
                        if let i = v.as(Int.self), points.indices.contains(i) {
                            Text(points[i].label).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let p = v.as(Int.self) { Text("\(p)%").font(.system(size: 9)) }
                    }
                }
            }
        }
    }
}

// MARK: - 自定义分组趋势对比（多曲线平均延时趋势 + 在线率趋势 + 自由规则编辑器）

private let groupTrendPalette: [Color] = [
    Palette.cpu,
    Palette.memory,
    Palette.disk,
    Palette.wired,
    Color(red: 0.68, green: 0.44, blue: 0.96),
    Color(red: 0.96, green: 0.42, blue: 0.64),
    Color(red: 0.22, green: 0.78, blue: 0.76),
    Color(red: 0.45, green: 0.56, blue: 0.98),
    Color(red: 0.40, green: 0.84, blue: 0.56),
    Color(red: 0.88, green: 0.62, blue: 0.36),
    Color(red: 0.30, green: 0.76, blue: 0.96),
    Color(red: 0.92, green: 0.78, blue: 0.28),
]

private func groupTrendColor(at index: Int) -> Color {
    groupTrendPalette[index % groupTrendPalette.count]
}

private struct NodeGroupTrendsSection: View {
    @ObservedObject var model: NodeMonitorModel
    @ObservedObject var settings: AppSettings
    var range: NodeStatsRange
    var currentConfigOnly: Bool

    @State private var selectedSetId: UUID?
    @State private var kindFilter: NodeRuleKindFilter = .all
    @State private var hiddenSeriesIds: Set<String> = []
    @State private var showEditor = false

    private var activeSet: NodeTrendGroupSet? {
        if let id = selectedSetId, let hit = settings.nodeTrendGroupSets.first(where: { $0.id == id }) {
            return hit
        }
        return settings.nodeTrendGroupSets.first
    }

    var body: some View {
        let scopeRows = currentConfigOnly ? model.rows.filter(\.inCurrentConfig) : model.rows
        let candidates = scopeRows.map { NodeRuleCandidate(key: $0.key, isChain: $0.isChain, groups: $0.groups) }
        let rangeMetrics = Dictionary(uniqueKeysWithValues: scopeRows.map { ($0.key, $0.metrics(for: range)) })
        let currentSet = activeSet
        let buckets = currentSet.map {
            NodeTrendGroupMatcher.resolveBuckets(set: $0, kindOverride: kindFilter, candidates: candidates)
        } ?? []
        let allSeries = NodeTrendGroupMatcher.aggregateSeries(
            buckets: buckets,
            slotKeys: model.trendGrid.slotKeys,
            labels: model.trendGrid.labels,
            byNode: model.trendGrid.byNode,
            rangeMetrics: rangeMetrics
        )
        let coloredSeries: [(index: Int, series: NodeGroupTrendSeries, color: Color)] = allSeries.enumerated().map {
            ($0.offset, $0.element, groupTrendColor(at: $0.offset))
        }
        let visibleSeries = coloredSeries.filter { !hiddenSeriesIds.contains($0.series.id) }

        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.cpu)
                            Text(L10n.text("nodes.gtrend.title", defaultValue: "分组趋势对比"))
                                .font(.system(size: 12.5, weight: .semibold))
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(settings.nodeTrendGroupSets) { preset in
                                    ChipButton(title: preset.name, count: nil, selected: currentSet?.id == preset.id) {
                                        selectedSetId = preset.id
                                        kindFilter = preset.defaultKindFilter
                                        hiddenSeriesIds.removeAll()
                                    }
                                }
                            }
                        }

                        Picker("", selection: $kindFilter) {
                            Text(L10n.text("nodes.gtrend.kindAll", defaultValue: "全部")).tag(NodeRuleKindFilter.all)
                            Text(L10n.text("nodes.gtrend.kindDirect", defaultValue: "普通")).tag(NodeRuleKindFilter.directOnly)
                            Text(L10n.text("nodes.gtrend.kindChain", defaultValue: "链式")).tag(NodeRuleKindFilter.chainOnly)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 145)

                        Button {
                            showEditor = true
                        } label: {
                            Label(L10n.text("nodes.gtrend.manage", defaultValue: "管理分组"), systemImage: "slider.horizontal.3")
                                .font(.system(size: 11))
                        }
                        .controlSize(.small)
                    }

                    if coloredSeries.isEmpty {
                        Text(L10n.text("nodes.gtrend.noMatch", defaultValue: "当前分组方案未匹配到节点，请切换链路筛选或点击“管理分组”修改规则。"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(coloredSeries, id: \.series.id) { item in
                                    let isHidden = hiddenSeriesIds.contains(item.series.id)
                                    Button {
                                        if isHidden { hiddenSeriesIds.remove(item.series.id) }
                                        else { hiddenSeriesIds.insert(item.series.id) }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(item.color.opacity(isHidden ? 0.25 : 1.0))
                                                .frame(width: 7, height: 7)
                                            Text("\(item.series.name)")
                                                .font(.system(size: 11, weight: .semibold))
                                                .strikethrough(isHidden)
                                            Text("(\(item.series.matchedNodeCount))")
                                                .font(.system(size: 10).monospacedDigit())
                                                .foregroundStyle(.secondary)
                                            if item.series.summary.sampledNodeCount > 0 {
                                                Text("·")
                                                    .foregroundStyle(.tertiary)
                                                Text(formatUptime(item.series.summary.avgUptimeRate))
                                                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                                    .foregroundStyle(isHidden ? .secondary : uptimeColor(item.series.summary.avgUptimeRate))
                                                Text(formatDelay(item.series.summary.avgDelayMs))
                                                    .font(.system(size: 10).monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(isHidden ? Color.primary.opacity(0.025) : item.color.opacity(0.11))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(isHidden ? Color.primary.opacity(0.08) : item.color.opacity(0.32), lineWidth: 0.75)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .opacity(isHidden ? 0.55 : 1.0)
                                    .help(L10n.text("nodes.gtrend.legendTip", defaultValue: "点击图例可切换单条曲线显隐"))
                                }
                            }
                        }
                    }
                }
            }

            if !coloredSeries.isEmpty {
                HStack(spacing: 10) {
                    Card {
                        CardHeader(symbol: "chart.xyaxis.line",
                                   title: L10n.text("nodes.chart.delay", defaultValue: "平均延时趋势 (ms)"),
                                   tint: Palette.cpu,
                                   trailing: currentSet?.name)
                        NodeGroupMultiDelayChart(seriesList: visibleSeries, labels: model.trendGrid.labels)
                            .frame(height: 150)
                    }
                    Card {
                        CardHeader(symbol: "checkmark.seal",
                                   title: L10n.text("nodes.chart.uptime", defaultValue: "在线率趋势 (%)"),
                                   tint: Palette.memory,
                                   trailing: currentSet?.name)
                        NodeGroupMultiUptimeChart(seriesList: visibleSeries, labels: model.trendGrid.labels)
                            .frame(height: 150)
                    }
                }
            }
        }
        .onAppear {
            if selectedSetId == nil, let first = settings.nodeTrendGroupSets.first {
                selectedSetId = first.id
                kindFilter = first.defaultKindFilter
            }
        }
        .sheet(isPresented: $showEditor) {
            NodeTrendGroupEditorSheet(settings: settings, model: model, candidates: candidates,
                                      initialSetId: currentSet?.id,
                                      onSelectSet: { newId in
                                          selectedSetId = newId
                                          if let hit = settings.nodeTrendGroupSets.first(where: { $0.id == newId }) {
                                              kindFilter = hit.defaultKindFilter
                                          }
                                          hiddenSeriesIds.removeAll()
                                      })
        }
    }
}

private struct NodeGroupMultiDelayChart: View {
    var seriesList: [(index: Int, series: NodeGroupTrendSeries, color: Color)]
    var labels: [String]

    var body: some View {
        let hasData = seriesList.contains { item in item.series.points.contains { $0.avgDelayMs != nil } }
        if !hasData {
            Unavailable(text: L10n.text("nodes.noSamples", defaultValue: "暂无样本"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(seriesList, id: \.series.id) { item in
                    ForEach(item.series.points) { pt in
                        if let ms = pt.avgDelayMs {
                            LineMark(x: .value("T", pt.index), y: .value("ms", ms), series: .value("G", item.series.id))
                                .foregroundStyle(item.color)
                                .lineStyle(StrokeStyle(lineWidth: 1.9))
                            PointMark(x: .value("T", pt.index), y: .value("ms", ms))
                                .foregroundStyle(item.color)
                                .symbolSize(16)
                        }
                    }
                }
            }
            .chartXScale(domain: 0...max(labels.count - 1, 1))
            .chartXAxis {
                let step = max(1, labels.count / 6)
                AxisMarks(values: Array(stride(from: 0, to: max(labels.count, 1), by: step))) { v in
                    AxisValueLabel {
                        if let i = v.as(Int.self), labels.indices.contains(i) {
                            Text(labels[i]).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ms = v.as(Int.self) { Text("\(ms)").font(.system(size: 9)) }
                    }
                }
            }
        }
    }
}

private struct NodeGroupMultiUptimeChart: View {
    var seriesList: [(index: Int, series: NodeGroupTrendSeries, color: Color)]
    var labels: [String]

    var body: some View {
        let hasData = seriesList.contains { item in item.series.points.contains { $0.uptimeRate != nil } }
        if !hasData {
            Unavailable(text: L10n.text("nodes.noSamples", defaultValue: "暂无样本"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(seriesList, id: \.series.id) { item in
                    ForEach(item.series.points) { pt in
                        if let rate = pt.uptimeRate {
                            LineMark(x: .value("T", pt.index), y: .value("%", rate * 100.0), series: .value("G", item.series.id))
                                .foregroundStyle(item.color)
                                .lineStyle(StrokeStyle(lineWidth: 1.9))
                            PointMark(x: .value("T", pt.index), y: .value("%", rate * 100.0))
                                .foregroundStyle(item.color)
                                .symbolSize(16)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: 0...max(labels.count - 1, 1))
            .chartXAxis {
                let step = max(1, labels.count / 6)
                AxisMarks(values: Array(stride(from: 0, to: max(labels.count, 1), by: step))) { v in
                    AxisValueLabel {
                        if let i = v.as(Int.self), labels.indices.contains(i) {
                            Text(labels[i]).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let p = v.as(Int.self) { Text("\(p)%").font(.system(size: 9)) }
                    }
                }
            }
        }
    }
}

// MARK: - 自定义分组管理弹窗（支持正则自动提取、自由组合规则：正则 + 策略组 + 手选节点 + 链路筛选）

private struct NodeTrendGroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: NodeMonitorModel
    var candidates: [NodeRuleCandidate]
    var initialSetId: UUID?
    var onSelectSet: (UUID) -> Void

    @State private var editingSetId: UUID?

    private var selectedIndex: Int? {
        if let id = editingSetId, let idx = settings.nodeTrendGroupSets.firstIndex(where: { $0.id == id }) {
            return idx
        }
        return settings.nodeTrendGroupSets.isEmpty ? nil : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("nodes.gtrend.editorTitle", defaultValue: "自定义趋势分组"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L10n.text("nodes.gtrend.reset", defaultValue: "恢复默认")) {
                    settings.resetNodeTrendGroupSets()
                    if let first = settings.nodeTrendGroupSets.first {
                        editingSetId = first.id
                        onSelectSet(first.id)
                    }
                }
                .controlSize(.small)
                Button(L10n.text("nodes.gtrend.done", defaultValue: "完成")) {
                    if let idx = selectedIndex {
                        onSelectSet(settings.nodeTrendGroupSets[idx].id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            HStack(spacing: 0) {
                // 左侧方案列表
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(settings.nodeTrendGroupSets) { set in
                                let isSelected = (selectedIndex.map { settings.nodeTrendGroupSets[$0].id == set.id } ?? false)
                                Button {
                                    editingSetId = set.id
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(set.name)
                                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(set.mode == .regexCapture
                                             ? L10n.text("nodes.gtrend.badgeRegex", defaultValue: "正则")
                                             : String(format: L10n.text("nodes.gtrend.badgeRules"), Int64(set.rules.count)))
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? Palette.cpu.opacity(0.18) : Color.clear))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }

                    Divider()

                    HStack(spacing: 6) {
                        Button {
                            let created = NodeTrendGroupSet(
                                name: L10n.text("nodes.gtrend.defaultNewSetName", defaultValue: "自定义分组"),
                                mode: .customRules,
                                defaultKindFilter: .all,
                                rules: [NodeTrendGroupRule(name: L10n.text("nodes.gtrend.defaultNewRuleName", defaultValue: "新规则"))]
                            )
                            settings.nodeTrendGroupSets.append(created)
                            editingSetId = created.id
                        } label: {
                            Label(L10n.text("nodes.gtrend.newSet", defaultValue: "新建方案"), systemImage: "plus")
                                .font(.system(size: 11))
                        }
                        .controlSize(.small)

                        Spacer()

                        Button {
                            guard let idx = selectedIndex, settings.nodeTrendGroupSets.count > 1 else { return }
                            settings.nodeTrendGroupSets.remove(at: idx)
                            let nextIdx = min(idx, settings.nodeTrendGroupSets.count - 1)
                            editingSetId = settings.nodeTrendGroupSets[nextIdx].id
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .controlSize(.small)
                        .disabled(settings.nodeTrendGroupSets.count <= 1)
                    }
                    .padding(8)
                }
                .frame(width: 210)

                Divider()

                // 右侧方案详情与规则编辑器
                if let idx = selectedIndex {
                    let targetId = settings.nodeTrendGroupSets[idx].id
                    let fallback = settings.nodeTrendGroupSets[idx]
                    let setBinding = Binding<NodeTrendGroupSet>(
                        get: { settings.nodeTrendGroupSets.first(where: { $0.id == targetId }) ?? fallback },
                        set: { updated in
                            if let i = settings.nodeTrendGroupSets.firstIndex(where: { $0.id == targetId }) {
                                settings.nodeTrendGroupSets[i] = updated
                            }
                        }
                    )
                    NodeTrendGroupSetDetailEditor(set: setBinding, model: model, candidates: candidates)
                } else {
                    Spacer()
                }
            }
        }
        .frame(width: 780, height: 520)
        .onAppear {
            editingSetId = initialSetId ?? settings.nodeTrendGroupSets.first?.id
        }
    }
}

private struct NodeTrendGroupSetDetailEditor: View {
    @Binding var set: NodeTrendGroupSet
    @ObservedObject var model: NodeMonitorModel
    var candidates: [NodeRuleCandidate]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("nodes.gtrend.setName", defaultValue: "方案名称"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    TextField("", text: $set.name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("nodes.gtrend.defaultKind", defaultValue: "默认链路筛选"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Picker("", selection: $set.defaultKindFilter) {
                        Text(L10n.text("nodes.gtrend.kindAll", defaultValue: "全部")).tag(NodeRuleKindFilter.all)
                        Text(L10n.text("nodes.gtrend.kindDirect", defaultValue: "普通")).tag(NodeRuleKindFilter.directOnly)
                        Text(L10n.text("nodes.gtrend.kindChain", defaultValue: "链式")).tag(NodeRuleKindFilter.chainOnly)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 165)
                }
            }

            Picker("", selection: $set.mode) {
                Text(L10n.text("nodes.gtrend.modeCustom", defaultValue: "自定义规则")).tag(NodeTrendGroupSet.Mode.customRules)
                Text(L10n.text("nodes.gtrend.modeRegex", defaultValue: "正则自动提取")).tag(NodeTrendGroupSet.Mode.regexCapture)
            }
            .pickerStyle(.segmented).labelsHidden()

            Divider()

            if set.mode == .regexCapture {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("nodes.gtrend.capturePattern", defaultValue: "提取正则（第 1 捕获组为分组名）"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField(#"\[([^\]]+)\]"#, text: $set.captureRegex)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    if let err = NodeTrendGroupMatcher.validateRegex(set.captureRegex) {
                        Text(err).font(.system(size: 10.5)).foregroundStyle(Palette.heat)
                    }

                    let previewBuckets = NodeTrendGroupMatcher.resolveBuckets(set: set, candidates: candidates)
                    Text(L10n.text("nodes.gtrend.capturePreview", defaultValue: "实时匹配预览（最多 12 组）"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.top, 4)

                    if previewBuckets.isEmpty {
                        Text(L10n.text("nodes.gtrend.noMatch", defaultValue: "当前分组方案未匹配到节点，请切换链路筛选或点击“管理分组”修改规则。"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                                ForEach(Array(previewBuckets.enumerated()), id: \.element.id) { idx, b in
                                    HStack(spacing: 5) {
                                        Circle().fill(groupTrendColor(at: idx)).frame(width: 7, height: 7)
                                        Text(b.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text("\(b.nodeKeys.count)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                                }
                            }
                        }
                    }
                }
                Spacer()
            } else {
                HStack {
                    Text(L10n.text("nodes.gtrend.modeCustom", defaultValue: "自定义规则"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        set.rules.append(NodeTrendGroupRule(
                            name: L10n.text("nodes.gtrend.defaultNewRuleName", defaultValue: "新规则")
                        ))
                    } label: {
                        Label(L10n.text("nodes.gtrend.addRule", defaultValue: "添加规则"), systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                }

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(set.rules) { rule in
                            let ruleId = rule.id
                            let ruleBinding = Binding<NodeTrendGroupRule>(
                                get: { set.rules.first(where: { $0.id == ruleId }) ?? rule },
                                set: { updated in
                                    if let idx = set.rules.firstIndex(where: { $0.id == ruleId }) {
                                        set.rules[idx] = updated
                                    }
                                }
                            )
                            NodeTrendRuleRowEditor(
                                rule: ruleBinding,
                                setKind: set.defaultKindFilter,
                                model: model,
                                candidates: candidates,
                                onDelete: { set.rules.removeAll { $0.id == ruleId } }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NodeTrendRuleRowEditor: View {
    @Binding var rule: NodeTrendGroupRule
    var setKind: NodeRuleKindFilter
    @ObservedObject var model: NodeMonitorModel
    var candidates: [NodeRuleCandidate]
    var onDelete: () -> Void

    @State private var showGroupsPicker = false
    @State private var showNodesPicker = false
    @State private var nodeSearch = ""

    var body: some View {
        let hitCount = NodeTrendGroupMatcher.matchRule(rule, setKind: setKind, candidates: candidates).count
        let regexError = NodeTrendGroupMatcher.validateRegex(rule.regex)
        let sortedNodeNames = Array(Set(candidates.map(\.key.name))).sorted()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(L10n.text("nodes.gtrend.ruleName", defaultValue: "分组名"), text: $rule.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)

                Picker("", selection: $rule.kindFilter) {
                    Text(L10n.text("nodes.gtrend.kindAll", defaultValue: "全部")).tag(NodeRuleKindFilter.all)
                    Text(L10n.text("nodes.gtrend.kindDirect", defaultValue: "普通")).tag(NodeRuleKindFilter.directOnly)
                    Text(L10n.text("nodes.gtrend.kindChain", defaultValue: "链式")).tag(NodeRuleKindFilter.chainOnly)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 145)

                Button(String(format: L10n.text("nodes.gtrend.pickGroups"), Int64(rule.bettboxGroups.count))) {
                    showGroupsPicker = true
                }
                .controlSize(.small)
                .popover(isPresented: $showGroupsPicker, arrowEdge: .bottom) {
                    groupPickerPopover
                }

                Button(String(format: L10n.text("nodes.gtrend.pickNodes"), Int64(rule.explicitNodes.count))) {
                    showNodesPicker = true
                }
                .controlSize(.small)
                .popover(isPresented: $showNodesPicker, arrowEdge: .bottom) {
                    nodePickerPopover(allNames: sortedNodeNames)
                }

                Spacer()

                Text(String(format: L10n.text("nodes.gtrend.hitCount"), Int64(hitCount)))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(hitCount > 0 ? Palette.memory : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            TextField(L10n.text("nodes.gtrend.ruleRegexPlaceholder", defaultValue: "名称正则（可选，可配合策略组/节点或纯按链路筛选）"),
                      text: $rule.regex)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            if let regexError {
                Text(regexError).font(.system(size: 10)).foregroundStyle(Palette.heat)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
    }

    private var groupPickerPopover: some View {
        let selected = Set(rule.bettboxGroups)
        let topologyOrder = model.topology.groups.map(\.name)
        let known = Set(topologyOrder)
        return VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.topology.groups) { g in
                        Toggle(isOn: Binding(
                            get: { selected.contains(g.name) },
                            set: { on in
                                var next = selected
                                if on { next.insert(g.name) } else { next.remove(g.name) }
                                // 按策略组拓扑顺序保存，未知旧条目追加在末尾。
                                rule.bettboxGroups = topologyOrder.filter { next.contains($0) }
                                    + next.filter { !known.contains($0) }.sorted()
                            }
                        )) {
                            Text("\(g.name) (\(g.resolvedLeaves.count))").lineLimit(1)
                        }
                        .toggleStyle(.checkbox).font(.system(size: 11.5))
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(10)
        .frame(width: 280)
    }

    private func nodePickerPopover(allNames: [String]) -> some View {
        let selected = Set(rule.explicitNodes)
        let filtered = allNames.filter { nodeSearch.isEmpty || $0.localizedCaseInsensitiveContains(nodeSearch) }
        return VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.text("nodes.gtrend.searchNode", defaultValue: "搜索节点名称"), text: $nodeSearch)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { selected.contains(name) },
                            set: { on in
                                var next = selected
                                if on { next.insert(name) } else { next.remove(name) }
                                rule.explicitNodes = next.sorted()
                            }
                        )) {
                            Text(name).lineLimit(1).truncationMode(.middle)
                        }
                        .toggleStyle(.checkbox).font(.system(size: 11))
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(10)
        .frame(width: 320)
    }
}

// MARK: - 格式化辅助

private func formatUptime(_ rate: Double?) -> String {
    guard let rate else { return "—" }
    let pct = rate * 100.0
    return pct >= 99.95 ? "100%" : String(format: "%.1f%%", pct)
}

private func formatDelay(_ ms: Int?) -> String {
    guard let ms, ms > 0 else { return "—" }
    return "\(ms) ms"
}

private func minMaxText(_ m: NodeWindowMetrics) -> String {
    guard let lo = m.minDelayMs, let hi = m.maxDelayMs else { return "—" }
    return "\(lo)–\(hi) ms"
}

private func minMaxAggText(_ a: NodeEqualWeightAggregate) -> String {
    guard let lo = a.minDelayMs, let hi = a.maxDelayMs else { return "—" }
    return "\(lo)–\(hi) ms"
}

private func uptimeColor(_ rate: Double?) -> Color {
    guard let rate else { return .secondary }
    if rate >= 0.95 { return Palette.memory }
    if rate >= 0.70 { return Palette.wired }
    return Palette.heat
}

private func delayColor(_ ms: Int) -> Color {
    if ms < 150 { return Palette.memory }
    if ms < 350 { return Palette.wired }
    return Palette.heat
}
