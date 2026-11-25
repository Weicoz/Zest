//
//  NetworkOverviewPage.swift
//  Zest
//

import Charts
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour, day
    var id: String { rawValue }
    var title: String { self == .hour ? L10n.text("1 小时") : L10n.text("24 小时") }
}

/// 流量排行的通用行数据（本次 / 24 小时）。
struct TrafficRow: Identifiable {
    var key: String
    var name: String
    var bundlePath: String?
    var bytesIn: UInt64
    var bytesOut: UInt64
    var id: String { key }
    var total: UInt64 { bytesIn &+ bytesOut }
}

struct NetworkOverviewPage: View {
    @ObservedObject var monitor: NetworkMonitor
    var showApp: (String) -> Void
    @AppStorage("overviewRange") private var range = HistoryRange.hour

    var body: some View {
        let s = monitor.state
        let h = monitor.history
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: L10n.text("总览"), subtitle: L10n.text("所有进程的实时流量、连接与告警（数据来自系统 nettop，不抓包、不联网）")) {
                    HStack(spacing: 4) {
                        ForEach(HistoryRange.allCases) { r in
                            ChipButton(title: r.title, count: nil, selected: range == r) { range = r }
                        }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    KPI(title: L10n.text("traffic.download", defaultValue: "下载"), value: Fmt.rate(s.rateIn), tint: Palette.download)
                    KPI(title: L10n.text("traffic.upload", defaultValue: "上传"), value: Fmt.rate(s.rateOut), tint: Palette.upload)
                    if range == .hour {
                        KPI(title: L10n.text("本次流量"), value: Fmt.bytes(Double(s.sessionIn + s.sessionOut)),
                            sub: "↓\(Fmt.bytes(Double(s.sessionIn))) ↑\(Fmt.bytes(Double(s.sessionOut)))")
                    } else {
                        KPI(title: L10n.text("24 小时流量"), value: Fmt.bytes(Double(h.bytesIn + h.bytesOut)),
                            sub: "↓\(Fmt.bytes(Double(h.bytesIn))) ↑\(Fmt.bytes(Double(h.bytesOut)))")
                    }
                    KPI(title: L10n.text("活跃连接"), value: "\(s.activeFlows.filter { $0.scope != .loopback }.count)",
                        sub: String(format: L10n.text("监听 %lld"), Int64(s.flows.filter(\.isListening).count)))
                    KPI(title: L10n.text("联网应用"), value: "\(s.onlineApps.count)")
                    KPI(title: L10n.text("隐私评分"), value: "\(monitor.score.score)", tint: ScoreRing.color(monitor.score.score))
                }
                DailyTotalsCards(totals: h.totals)
                HStack(alignment: .top, spacing: 12) {
                    Card {
                        CardHeader(symbol: "waveform.path.ecg", title: L10n.text("实时（最近 5 分钟）"), tint: Palette.download)
                        LiveChart(points: s.live, sampledAt: s.sampledAt).frame(height: 170)
                    }
                    Card {
                        if range == .hour {
                            CardHeader(symbol: "chart.bar", title: L10n.text("最近 60 分钟（每分钟）"), tint: Palette.cpu)
                            MinuteChart(points: s.minutes).frame(height: 170)
                        } else {
                            CardHeader(symbol: "chart.bar", title: L10n.text("最近 24 小时（每 10 分钟）"), tint: Palette.cpu,
                                       trailing: String(format: L10n.text("已保存 %@"), Fmt.bytes(Double(h.storeSize))))
                            DayChart(points: h.day).frame(height: 170)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Card {
                        CardHeader(symbol: "list.number", title: range == .hour ? L10n.text("流量最多的应用（本次）") : L10n.text("流量最多的应用（24 小时）"),
                                   tint: Palette.cpu)
                        TopTrafficList(rows: topRows(s, h), showApp: showApp)
                    }
                    VStack(spacing: 12) {
                        Card {
                            CardHeader(symbol: "lock.shield", title: L10n.text("隐私评分"), tint: ScoreRing.color(monitor.score.score))
                            HStack(spacing: 14) {
                                ScoreRing(score: monitor.score.score, color: ScoreRing.color(monitor.score.score), lineWidth: 7)
                                    .frame(width: 70, height: 70)
                                VStack(alignment: .leading, spacing: 3) {
                                    if monitor.score.factors.isEmpty {
                                        Text(L10n.text("没有扣分项：未发现明文连接、可疑告警或对外开放的端口。"))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    ForEach(monitor.score.factors) { f in
                                        HStack {
                                            Text(f.label).font(.system(size: 11))
                                            Spacer()
                                            Text("−\(f.penalty)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                                .foregroundStyle(Palette.heat)
                                        }
                                    }
                                }
                            }
                        }
                        Card {
                            CardHeader(symbol: "bell.badge", title: L10n.text("最近告警"), tint: Palette.heat)
                            if monitor.alerts.isEmpty {
                                Label(L10n.text("未发现异常"), systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Palette.memory)
                            }
                            ForEach(monitor.alerts.prefix(4)) { AlertLine(alert: $0, compact: true) }
                        }
                    }
                    .frame(width: 330)
                }
                HStack(alignment: .top, spacing: 12) {
                    Card {
                        CardHeader(symbol: "globe.asia.australia", title: L10n.text("连接的国家 / 地区"), tint: Palette.download,
                                   trailing: L10n.text("按当前公网连接统计"))
                        GeoBreakdown(items: GeoAggregate.countries(s.activeFlows))
                    }
                    Card {
                        CardHeader(symbol: "building.2", title: L10n.text("主要网络服务商（ASN）"), tint: Palette.compressed)
                        GeoBreakdown(items: GeoAggregate.organizations(s.activeFlows))
                    }
                }
                Text(GeoAggregate.footnote(s.activeFlows))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
    }

    private func topRows(_ s: NetworkState, _ h: HistorySummary) -> [TrafficRow] {
        if range == .hour {
            return s.apps.filter { $0.sessionTotal > 0 }.sorted { $0.sessionTotal > $1.sessionTotal }.prefix(8)
                .map { TrafficRow(key: $0.key, name: $0.name, bundlePath: $0.bundlePath, bytesIn: $0.sessionIn, bytesOut: $0.sessionOut) }
        }
        return h.apps.prefix(8).map { TrafficRow(key: $0.key, name: $0.name, bundlePath: $0.bundlePath, bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) }
    }
}

/// 按国家 / 服务商汇总当前公网连接。
enum GeoAggregate {
    struct Item: Identifiable {
        var id: String
        var label: String
        var connections: Int
        var bytes: UInt64
    }

    static func countries(_ flows: [FlowInfo]) -> [Item] {
        group(flows) { g in
            guard let cc = g.countryCode else { return nil }
            return (cc, "\(g.flag) \(g.countryName ?? cc)")
        }
    }

    static func organizations(_ flows: [FlowInfo]) -> [Item] {
        group(flows) { g in
            guard let org = g.organization else { return nil }
            return ("\(g.asn ?? 0)", "\(org)  AS\(g.asn ?? 0)")
        }
    }

    private static func group(_ flows: [FlowInfo], key: (GeoInfo) -> (String, String)?) -> [Item] {
        var map: [String: Item] = [:]
        for f in flows where f.scope == .internet {
            guard let g = f.geo, let (id, label) = key(g) else { continue }
            map[id, default: Item(id: id, label: label, connections: 0, bytes: 0)].connections += 1
            map[id]?.bytes &+= f.bytesIn &+ f.bytesOut
        }
        return map.values.sorted { ($0.bytes, $0.connections) > ($1.bytes, $1.connections) }.prefix(8).map { $0 }
    }

    static func footnote(_ flows: [FlowInfo]) -> String {
        let reserved = flows.filter { $0.scope == .reserved }.count
        let edition = GeoIP.dataMonth.map { String(format: L10n.text("，%@ 版"), $0) } ?? ""
        var text = String(format: L10n.text("IP 归属地离线查询，数据来自 DB-IP Lite（CC BY 4.0，db-ip.com）%@；为国家级与 ASN 级精度。"), edition)
        if reserved > 0 {
            text += String(format: L10n.text("另有 %lld 条连接指向 198.18.0.0/15 等保留地址（通常是代理软件的 Fake IP），真实目的地无法从本机得知。"), Int64(reserved))
        }
        return text
    }
}

struct GeoBreakdown: View {
    var items: [GeoAggregate.Item]

    var body: some View {
        let top = Double(items.first?.bytes ?? 1)
        if items.isEmpty { Unavailable(text: L10n.text("暂无公网连接")) }
        ForEach(items) { item in
            HStack(spacing: 8) {
                Text(item.label).font(.system(size: 11.5)).lineLimit(1).frame(width: 220, alignment: .leading)
                GeometryReader { g in
                    Capsule().fill(Palette.download.opacity(0.75))
                        .frame(width: max(g.size.width * CGFloat(Double(item.bytes) / max(top, 1)), 3))
                }
                .frame(height: 6)
                Text(String(format: L10n.text("%lld 条"), Int64(item.connections))).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Text(Fmt.bytes(Double(item.bytes))).font(.system(size: 10.5).monospacedDigit())
                    .frame(width: 66, alignment: .trailing)
            }
            .frame(height: 20)
        }
    }
}

/// 24 小时柱状图（每 10 分钟一个桶）。
struct DayChart: View {
    var points: [TrafficPoint]
    var language: AppLanguage = .system

    var body: some View {
        let _ = language
        let n = points.count
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                BarMark(x: .value(L10n.text("时间"), i), y: .value(L10n.text("流量"), p.bytesIn), width: .fixed(2.5))
                    .foregroundStyle(Palette.download)
                BarMark(x: .value(L10n.text("时间"), i), y: .value(L10n.text("流量"), p.bytesOut), width: .fixed(2.5))
                    .foregroundStyle(Palette.upload)
            }
        }
        .chartXScale(domain: 0...max(n, 1))
        .chartXAxis {
            AxisMarks(values: stride(from: 0, through: max(n, 1), by: 36).map { $0 }) { v in
                AxisValueLabel {
                    if let i = v.as(Int.self) {
                        let hoursAgo = Int((Double(n - 1 - i) * Double(HistorySummary.bucketMinutes) / 60).rounded())
                        Text(hoursAgo <= 0 ? L10n.text("现在") : String(format: L10n.text("−%lld 小时"), Int64(hoursAgo))).font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compactBytes(d)).font(.system(size: 9)) } }
            }
        }
        .overlay {
            if points.allSatisfy({ $0.bytesIn + $0.bytesOut == 0 }) {
                Text(L10n.text("历史数据从首次运行开始累积，每分钟保存一次")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

enum LiveWaveMath {
    static func niceCeiling(maxValue: Double) -> Double {
        max(maxValue * 1.15, 1024)
    }

    static func scrollSubStep(since arrival: Date?, now: Date,
                              stepSeconds: TimeInterval = 2.0, pointCount: Int) -> Double {
        guard pointCount >= 2, let arrival, stepSeconds > 0 else { return 0 }
        return min(max(now.timeIntervalSince(arrival) / stepSeconds, 0), 1)
    }

    static func xCoordinate(index: Int, count: Int, capacity: Int,
                            width: CGFloat, subStep: Double) -> CGFloat {
        guard count > 1 else { return width }
        let dx = width / CGFloat(max(capacity - 1, 1))
        let trailingIndex = count - 2
        return width - (CGFloat(trailingIndex - index) + CGFloat(subStep)) * dx
    }

    private static func monotoneCubicSlopes(for points: [CGPoint]) -> [CGFloat] {
        let n = points.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }
        var secant = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            secant[i] = abs(dx) > 1e-6 ? (points[i + 1].y - points[i].y) / dx : 0
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = secant[0]
        m[n - 1] = secant[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                if secant[i - 1] * secant[i] <= 0 {
                    m[i] = 0
                } else {
                    m[i] = (secant[i - 1] + secant[i]) * 0.5
                }
            }
        }
        for i in 0..<(n - 1) {
            let d = secant[i]
            if abs(d) < 1e-9 {
                m[i] = 0
                m[i + 1] = 0
            } else {
                let alpha = m[i] / d
                let beta = m[i + 1] / d
                let s = alpha * alpha + beta * beta
                if s > 9.0 {
                    let tau = 3.0 / sqrt(s)
                    m[i] = tau * alpha * d
                    m[i + 1] = tau * beta * d
                }
            }
        }
        return m
    }

    static func monotoneCubicPath(points: [CGPoint], minY: CGFloat, maxY: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let clampedFirst = CGPoint(x: first.x, y: min(max(first.y, minY), maxY))
        path.move(to: clampedFirst)
        guard points.count >= 2 else { return path }
        if points.count == 2 {
            let second = points[1]
            path.addLine(to: CGPoint(x: second.x, y: min(max(second.y, minY), maxY)))
            return path
        }
        let clampedPoints = points.map { CGPoint(x: $0.x, y: min(max($0.y, minY), maxY)) }
        let slopes = monotoneCubicSlopes(for: clampedPoints)
        for i in 0..<(clampedPoints.count - 1) {
            let p0 = clampedPoints[i]
            let p1 = clampedPoints[i + 1]
            let dx = p1.x - p0.x
            let c1y = min(max(p0.y + slopes[i] * dx / 3.0, minY), maxY)
            let c2y = min(max(p1.y - slopes[i + 1] * dx / 3.0, minY), maxY)
            path.addCurve(to: p1,
                          control1: CGPoint(x: p0.x + dx / 3.0, y: c1y),
                          control2: CGPoint(x: p1.x - dx / 3.0, y: c2y))
        }
        return path
    }

    static func rightEdgeY(points: [CGPoint], edgeX: CGFloat, minY: CGFloat, maxY: CGFloat) -> CGFloat? {
        guard !points.isEmpty else { return nil }
        if points.count == 1 {
            return min(max(points[0].y, minY), maxY)
        }
        let clamped = points.map { CGPoint(x: $0.x, y: min(max($0.y, minY), maxY)) }
        let n = clamped.count
        let p0 = clamped[n - 2]
        let p1 = clamped[n - 1]
        let dx = p1.x - p0.x
        guard dx > 1e-6 else { return p1.y }
        let t = min(max((edgeX - p0.x) / dx, 0), 1)
        if n == 2 {
            return min(max(p0.y + (p1.y - p0.y) * t, minY), maxY)
        }
        let slopes = monotoneCubicSlopes(for: clamped)
        let c1y = min(max(p0.y + slopes[n - 2] * dx / 3.0, minY), maxY)
        let c2y = min(max(p1.y - slopes[n - 1] * dx / 3.0, minY), maxY)
        let omt = 1.0 - t
        let y = omt * omt * omt * p0.y
            + 3.0 * omt * omt * t * c1y
            + 3.0 * omt * t * t * c2y
            + t * t * t * p1.y
        return min(max(y, minY), maxY)
    }
}

struct LiveChart: View {
    var points: [TrafficPoint]
    var sampledAt: Date? = nil
    var language: AppLanguage = .system

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastArrival: Date?
    @State private var displayTop: Double = 1024

    private var targetTop: Double {
        let rawMax = max(points.map(\.bytesIn).max() ?? 0, points.map(\.bytesOut).max() ?? 0)
        return LiveWaveMath.niceCeiling(maxValue: rawMax)
    }

    var body: some View {
        let _ = language
        LiveWaveCanvas(points: points,
                       lastArrival: lastArrival,
                       ceiling: displayTop,
                       reduceMotion: reduceMotion,
                       waitingText: L10n.text("live.waiting", defaultValue: "等待实时采样…"),
                       nowLabel: L10n.text("现在"),
                       minuteFormat: L10n.text("−%lld 分"))
        .overlay(alignment: .topTrailing) { ChartLegend(language: language) }
        .onAppear {
            displayTop = targetTop
            lastArrival = sampledAt
        }
        .onChange(of: sampledAt) { _ in
            lastArrival = Date()
            updateDisplayTop()
        }
        .onChange(of: points.count) { _ in
            if sampledAt != nil { lastArrival = Date() }
            updateDisplayTop()
        }
    }

    private func updateDisplayTop() {
        let next = targetTop
        if reduceMotion {
            displayTop = next
        } else {
            withAnimation(.easeOut(duration: 0.45)) {
                displayTop = next
            }
        }
    }
}

private struct LiveWaveCanvas: View, Animatable {
    var points: [TrafficPoint]
    var lastArrival: Date?
    var ceiling: Double
    var reduceMotion: Bool
    var waitingText: String
    var nowLabel: String
    var minuteFormat: String

    var animatableData: Double {
        get { ceiling }
        set { ceiling = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || points.isEmpty)) { timeline in
            Canvas { context, size in
                let leftMargin: CGFloat = 52
                let rightMargin: CGFloat = 8
                let topMargin: CGFloat = 20
                let bottomMargin: CGFloat = 18
                let plotWidth = max(size.width - leftMargin - rightMargin, 1)
                let plotHeight = max(size.height - topMargin - bottomMargin, 1)
                let plotRect = CGRect(x: leftMargin, y: topMargin, width: plotWidth, height: plotHeight)
                let safeTop = max(ceiling, 1024)

                // Y 轴 4 档参考线与刻度
                for step in 0...3 {
                    let frac = CGFloat(step) / 3.0
                    let y = plotRect.maxY - frac * plotRect.height
                    var grid = Path()
                    grid.move(to: CGPoint(x: plotRect.minX, y: y))
                    grid.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                    context.stroke(grid, with: .color(.primary.opacity(step == 0 ? 0.14 : 0.07)), lineWidth: 0.5)

                    let label = step == 0 ? Fmt.compactRate(0) : Fmt.compactRate(safeTop * Double(frac))
                    let text = Text(label).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
                    context.draw(text, at: CGPoint(x: plotRect.minX - 6, y: y), anchor: .trailing)
                }

                // 底部时间轴：-5 分、-3 分、-1 分、现在
                let xTicks: [(CGFloat, String, UnitPoint)] = [
                    (0.0, String(format: minuteFormat, Int64(5)), .leading),
                    (0.4, String(format: minuteFormat, Int64(3)), .center),
                    (0.8, String(format: minuteFormat, Int64(1)), .center),
                    (1.0, nowLabel, .trailing)
                ]
                let xLabelY = size.height - 3
                for (frac, label, anchor) in xTicks {
                    let x = plotRect.minX + frac * plotRect.width
                    let text = Text(label).font(.system(size: 9)).foregroundColor(.secondary)
                    context.draw(text, at: CGPoint(x: x, y: xLabelY), anchor: anchor)
                }

                guard !points.isEmpty else {
                    let wait = Text(waitingText).font(.system(size: 11)).foregroundColor(.secondary)
                    context.draw(wait, at: CGPoint(x: plotRect.midX, y: plotRect.midY), anchor: .center)
                    return
                }

                let stepSeconds = Double(NetworkMonitor.foregroundInterval)
                let subStep = reduceMotion ? 0 : LiveWaveMath.scrollSubStep(
                    since: lastArrival, now: timeline.date, stepSeconds: stepSeconds, pointCount: points.count
                )
                let count = points.count
                var downPts: [CGPoint] = []
                var upPts: [CGPoint] = []
                downPts.reserveCapacity(count)
                upPts.reserveCapacity(count)

                for i in 0..<count {
                    let x = plotRect.minX + LiveWaveMath.xCoordinate(
                        index: i, count: count, capacity: NetworkTracker.liveCapacity,
                        width: plotRect.width, subStep: subStep
                    )
                    let inFrac = CGFloat(min(max(points[i].bytesIn / safeTop, 0), 1))
                    let outFrac = CGFloat(min(max(points[i].bytesOut / safeTop, 0), 1))
                    downPts.append(CGPoint(x: x, y: plotRect.maxY - inFrac * plotRect.height))
                    upPts.append(CGPoint(x: x, y: plotRect.maxY - outFrac * plotRect.height))
                }

                context.drawLayer { layer in
                    layer.clip(to: Path(plotRect))
                    drawSeries(in: &layer, pts: upPts, plotRect: plotRect, color: Palette.upload,
                               topAlpha: 0.16, bottomAlpha: 0.01, lineWidth: 1.55)
                    drawSeries(in: &layer, pts: downPts, plotRect: plotRect, color: Palette.download,
                               topAlpha: 0.30, bottomAlpha: 0.02, lineWidth: 1.75)
                }

                // 右边缘实时脉冲点
                let pulsePhase = reduceMotion
                    ? 0.0
                    : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                if let upY = LiveWaveMath.rightEdgeY(points: upPts, edgeX: plotRect.maxX,
                                                     minY: plotRect.minY, maxY: plotRect.maxY) {
                    drawLiveIndicator(in: &context, at: CGPoint(x: plotRect.maxX, y: upY),
                                      color: Palette.upload, phase: pulsePhase, reduceMotion: reduceMotion)
                }
                if let downY = LiveWaveMath.rightEdgeY(points: downPts, edgeX: plotRect.maxX,
                                                       minY: plotRect.minY, maxY: plotRect.maxY) {
                    drawLiveIndicator(in: &context, at: CGPoint(x: plotRect.maxX, y: downY),
                                      color: Palette.download, phase: pulsePhase, reduceMotion: reduceMotion)
                }
            }
        }
    }

    private func drawSeries(in context: inout GraphicsContext, pts: [CGPoint], plotRect: CGRect,
                            color: Color, topAlpha: Double, bottomAlpha: Double, lineWidth: CGFloat) {
        guard pts.count >= 2 else { return }
        let linePath = LiveWaveMath.monotoneCubicPath(points: pts, minY: plotRect.minY, maxY: plotRect.maxY)
        var areaPath = linePath
        areaPath.addLine(to: CGPoint(x: pts.last!.x, y: plotRect.maxY))
        areaPath.addLine(to: CGPoint(x: pts.first!.x, y: plotRect.maxY))
        areaPath.closeSubpath()

        context.fill(
            areaPath,
            with: .linearGradient(
                Gradient(colors: [color.opacity(topAlpha), color.opacity(bottomAlpha)]),
                startPoint: CGPoint(x: plotRect.midX, y: plotRect.minY),
                endPoint: CGPoint(x: plotRect.midX, y: plotRect.maxY)
            )
        )
        context.stroke(linePath, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func drawLiveIndicator(in context: inout GraphicsContext, at point: CGPoint,
                                   color: Color, phase: Double, reduceMotion: Bool) {
        if !reduceMotion {
            let haloRadius = CGFloat(3.4 + phase * 5.2)
            let haloAlpha = (1.0 - phase) * 0.45
            let haloRect = CGRect(x: point.x - haloRadius, y: point.y - haloRadius,
                                  width: haloRadius * 2, height: haloRadius * 2)
            context.fill(Path(ellipseIn: haloRect), with: .color(color.opacity(haloAlpha)))
        }
        let dotRadius: CGFloat = 2.8
        let dotRect = CGRect(x: point.x - dotRadius, y: point.y - dotRadius,
                             width: dotRadius * 2, height: dotRadius * 2)
        context.fill(Path(ellipseIn: dotRect), with: .color(color))
        context.stroke(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.85)), lineWidth: 1.0)
    }
}

struct MinuteChart: View {
    var points: [TrafficPoint]
    var language: AppLanguage = .system

    var body: some View {
        let _ = language
        let indexed = Array(points.enumerated())
        let offset = max(NetworkTracker.minuteCapacity + 1 - points.count, 0)
        Chart {
            ForEach(indexed, id: \.offset) { i, p in
                BarMark(x: .value(L10n.text("分钟"), i + offset), y: .value(L10n.text("流量"), p.bytesIn), width: .fixed(5))
                    .foregroundStyle(Palette.download)
                BarMark(x: .value(L10n.text("分钟"), i + offset), y: .value(L10n.text("流量"), p.bytesOut), width: .fixed(5))
                    .foregroundStyle(Palette.upload)
            }
        }
        .chartXScale(domain: 0...NetworkTracker.minuteCapacity + 1)
        .chartXAxis {
            AxisMarks(values: [0, 15, 30, 45, 60]) { v in
                AxisValueLabel {
                    if let m = v.as(Int.self) { Text(m == 60 ? L10n.text("现在") : String(format: L10n.text("−%lld 分"), Int64(60 - m))).font(.system(size: 9)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compactBytes(d)).font(.system(size: 9)) } }
            }
        }
        .overlay(alignment: .topTrailing) { ChartLegend(language: language) }
    }
}

private struct ChartLegend: View {
    var language: AppLanguage = .system

    var body: some View {
        let _ = language
        HStack(spacing: 8) {
            Label { Text(L10n.text("traffic.download", defaultValue: "下载")) } icon: { Circle().fill(Palette.download).frame(width: 6, height: 6) }
            Label { Text(L10n.text("traffic.upload", defaultValue: "上传")) } icon: { Circle().fill(Palette.upload).frame(width: 6, height: 6) }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(4)
    }
}

private struct TopTrafficList: View {
    var rows: [TrafficRow]
    var showApp: (String) -> Void

    var body: some View {
        let top = Double(rows.first?.total ?? 1)
        if rows.isEmpty { Unavailable(text: L10n.text("开始监控后将在这里列出流量最多的应用")) }
        ForEach(rows) { app in
            Button { showApp(app.key) } label: {
                HStack(spacing: 8) {
                    AppIcon(bundlePath: app.bundlePath, size: 18)
                    HStack(spacing: 4) {
                        Text(app.name).font(.system(size: 12)).lineLimit(1)
                        if let role = NetworkRelayClassifier.role(appKey: app.key, appName: app.name, bundlePath: app.bundlePath) {
                            RelayRoleTag(role: role)
                        }
                    }
                    .frame(width: 150, alignment: .leading)
                    GeometryReader { g in
                        HStack(spacing: 0) {
                            Rectangle().fill(Palette.download)
                                .frame(width: g.size.width * CGFloat(Double(app.bytesIn) / max(top, 1)))
                            Rectangle().fill(Palette.upload)
                                .frame(width: g.size.width * CGFloat(Double(app.bytesOut) / max(top, 1)))
                            Spacer(minLength: 0)
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 6)
                    Text(Fmt.bytes(Double(app.total))).font(.system(size: 11).monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 22)
        }
    }
}
