//
//  NodeMonitorTests.swift
//  ZestTests
//
//  Bettbox 节点与分组出口连通监测测试（v2 校准版）：
//  - /proxies 解码、策略组展开、嵌套分组穿透解析、链式前置解析与防环；
//  - 被动清洗：3900ms/4000ms/5000ms 超时边界判离线、30 秒冷却折叠多组重复、15 秒断网风暴门控、清库防回灌；
//  - 主动探测规划：链式前置自动联动（含 ⛓ 中转节点）与落地桶交错排序；
//  - 等权节点聚合、URL 编码与跨进程配置负载同步；
//  - HistoryStore+Nodes：v1→v2 迁移保留非节点表、按来源筛选（all / activeOnly）、分组通道 1d/7d/30d 与连续失败计数。
//

import SQLite3
import XCTest
@testable import Zest

final class NodeMonitorCoreTests: XCTestCase {
    private let sampleJSON = """
    {
      "proxies": {
        "DIRECT": {"name": "DIRECT", "type": "Direct", "alive": true, "history": []},
        "REJECT": {"name": "REJECT", "type": "Reject", "alive": true, "history": []},
        "DNS": {"name": "DNS", "type": "Dns", "alive": true, "history": []},
        "EmptyGroup": {"name": "EmptyGroup", "type": "Selector", "all": null},
        "GLOBAL": {"name": "GLOBAL", "type": "Selector", "all": ["TransitGroup", "NodeA"], "now": "TransitGroup"},
        "NodeA": {
          "name": "NodeA", "type": "AnyTLS", "alive": true, "dialer-proxy": "",
          "history": [
            {"time": "2026-11-23T09:00:00.123456+08:00", "delay": 0},
            {"time": "2026-11-23T09:00:00.320000+08:00", "delay": 0},
            {"time": "2026-11-23T01:30:00Z", "delay": 80},
            {"time": "2026-11-23T01:30:00.400Z", "delay": 85},
            {"time": "2026-11-23T18:00:00+08:00", "delay": 55}
          ]
        },
        "⛓ RelayB": {
          "name": "⛓ RelayB", "type": "Vless", "alive": true, "dialer-proxy": "",
          "history": []
        },
        "NodeB": {
          "name": "NodeB", "type": "Vless", "alive": true, "dialer-proxy": "",
          "history": [
            {"time": "2026-11-23T09:40:00.5+08:00", "delay": 4000},
            {"time": "2026-11-23T09:45:00+08:00", "delay": 5003}
          ]
        },
        "NodeA → Portland HTTP": {
          "name": "NodeA → Portland HTTP", "type": "Http", "alive": true, "dialer-proxy": "NodeA",
          "history": [{"time": "2026-11-23T09:45:00+08:00", "delay": 230}]
        },
        "RelayB → Portland HTTP": {
          "name": "RelayB → Portland HTTP", "type": "Http", "alive": false, "dialer-proxy": "⛓ RelayB",
          "history": []
        },
        "NodeA → Portland SOCKS5": {
          "name": "NodeA → Portland SOCKS5", "type": "Socks5", "alive": true, "dialer-proxy": "NodeA",
          "history": []
        },
        "DynamicExit": {
          "name": "DynamicExit", "type": "Socks5", "alive": true, "dialer-proxy": "TransitGroup",
          "history": []
        },
        "TopService": {
          "name": "TopService", "type": "Selector", "all": ["ChainGroup", "DIRECT"], "now": "ChainGroup"
        },
        "DirectService": {
          "name": "DirectService", "type": "Selector", "all": ["DIRECT"], "now": "DIRECT"
        },
        "TransitGroup": {
          "name": "TransitGroup", "type": "Selector", "all": ["AutoGroup", "NodeB"], "now": "AutoGroup"
        },
        "AutoGroup": {
          "name": "AutoGroup", "type": "URLTest", "all": ["NodeA", "NodeB"], "now": "NodeA"
        },
        "ChainGroup": {
          "name": "ChainGroup", "type": "Selector",
          "all": ["NodeA → Portland HTTP", "RelayB → Portland HTTP", "NodeA → Portland SOCKS5"],
          "now": "NodeA → Portland HTTP"
        },
        "CycleA": {"name": "CycleA", "type": "Selector", "all": ["CycleB", "NodeA"], "now": "CycleB"},
        "CycleB": {"name": "CycleB", "type": "Selector", "all": ["CycleA"], "now": "CycleA"}
      }
    }
    """

    func testTopologyParsingGroupPenetrationAndCycleSafety() throws {
        let payload = try JSONDecoder().decode(BettboxProxiesPayload.self, from: Data(sampleJSON.utf8))
        let topo = NodeTopology(payload: payload)

        // 7 个叶节点（含 ⛓ RelayB），内置 DIRECT/REJECT/DNS 与所有策略组均排除
        XCTAssertEqual(topo.leaves.count, 7)
        XCTAssertNil(topo.groupsByName["GLOBAL"])
        XCTAssertEqual(topo.groupsByName["TransitGroup"]?.resolvedLeaves.map(\.name).sorted(), ["NodeA", "NodeB"])
        XCTAssertEqual(topo.groupsByName["CycleA"]?.resolvedLeaves.map(\.name), ["NodeA"])

        // 嵌套分组穿透解析当前实际出站叶节点
        XCTAssertEqual(topo.resolveCurrentLeaf(ofGroup: "TopService")?.name, "NodeA → Portland HTTP")
        XCTAssertEqual(topo.resolveCurrentLeaf(ofGroup: "TransitGroup")?.name, "NodeA")
        XCTAssertNil(topo.resolveCurrentLeaf(ofGroup: "DirectService"))
        XCTAssertNil(topo.resolveCurrentLeaf(ofGroup: "CycleA"))

        let watched = ActiveProbePlanner.planWatchedGroups(topology: topo, watchedGroups: ["TopService", "DirectService", "Missing"])
        XCTAssertEqual(watched.map(\.groupName), ["TopService"])
        XCTAssertEqual(watched.first?.leaf.name, "NodeA → Portland HTTP")
    }

    func testPassiveCooldownFoldingTimeoutThresholdAndClearedAt() throws {
        let payload = try JSONDecoder().decode(BettboxProxiesPayload.self, from: Data(sampleJSON.utf8))
        let topo = NodeTopology(payload: payload)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10, minute: 0))!

        let first = PassiveHistoryExtractor.extract(from: topo, now: now)
        // NodeA: 09:00 两笔 200ms 内重复折叠为 1 笔离线；01:30Z 两笔 400ms 内重复折叠为 1 笔在线（取最后一条 85ms）；未来 18:00 拦截
        // NodeB: 4000ms 与 5003ms 均 >= 3900ms 超时边界，全部判为离线（ok == false, delayMs == 0）
        // NodeA → Portland HTTP: 230ms 在线
        let nodeASamples = first.filter { $0.node == "NodeA" }
        XCTAssertEqual(nodeASamples.count, 2)
        XCTAssertEqual(nodeASamples.map(\.ok), [false, true])
        XCTAssertEqual(nodeASamples.last?.delayMs, 85)

        let nodeBSamples = first.filter { $0.node == "NodeB" }
        XCTAssertEqual(nodeBSamples.count, 2)
        XCTAssertTrue(nodeBSamples.allSatisfy { !$0.ok && $0.delayMs == 0 })

        // 冷却窗口保护：若新样本距离 lastSeenMs 不足 30 秒，不再重复采纳
        var seen: [NodeKey: Int64] = [:]
        for s in first { seen[s.key] = max(seen[s.key] ?? Int64.min, s.tsMs) }
        XCTAssertTrue(PassiveHistoryExtractor.extract(from: topo, now: now, lastSeenMs: seen).isEmpty)

        // 清库时间戳保护
        let clearedAt = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        XCTAssertTrue(PassiveHistoryExtractor.extract(from: topo, now: now, clearedAtMs: clearedAt).isEmpty)
    }

    func testPassiveStormGateDropsMassOutageBucket() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10, minute: 5))!
        var map: [String: ProxyEntry] = [:]
        // 构造恰好 10 个节点（9 失败 + 1 成功，90% >= 80% 风暴阈值），验证丢弃水位推进后次轮不会因剩余 9<10 而漏写！
        for i in 1...10 {
            let delay = (i == 1) ? 90 : 0
            map["N\(i)"] = ProxyEntry(name: "N\(i)", type: "AnyTLS", alive: delay > 0,
                                      history: [ProxyHistoryEntry(time: "2026-11-23T10:00:05+08:00", delay: delay)])
        }
        let topo = NodeTopology(payload: BettboxProxiesPayload(proxies: map))
        let round1 = PassiveHistoryExtractor.extractWithWatermarks(from: topo, now: now)
        XCTAssertEqual(round1.samples.count, 1)
        XCTAssertEqual(round1.samples.first?.node, "N1")
        XCTAssertEqual(round1.samples.first?.ok, true)
        XCTAssertEqual(round1.droppedWatermarks.count, 9)

        // 模拟 NodeMonitorService 推进已落盘 + 风暴丢弃水位后的第 2 轮提取：必须返回空，绝不漏写 9 条假离线。
        var lastSeen = round1.droppedWatermarks
        for s in round1.samples { lastSeen[s.key] = max(lastSeen[s.key] ?? Int64.min, s.tsMs) }
        let round2 = PassiveHistoryExtractor.extractWithWatermarks(from: topo, now: now.addingTimeInterval(60), lastSeenMs: lastSeen)
        XCTAssertTrue(round2.samples.isEmpty)
        XCTAssertTrue(round2.droppedWatermarks.isEmpty)
    }

    func testPassiveExtraPrecedenceCooldownAndTimeoutExactBoundaries() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10, minute: 10))!
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        let url = BettboxClient.defaultProbeURL

        // 1) extra[preferredURL] 较旧(10:00) 而顶层 history 较新(10:05)：不得永久遮蔽顶层策略组健康检查
        let fresherTop = ProxyEntry(
            name: "FresherTop", type: "AnyTLS", alive: true,
            history: [ProxyHistoryEntry(time: "2026-11-23T10:05:00+08:00", delay: 120)],
            extra: [url: ProxyExtraEntry(alive: true, history: [ProxyHistoryEntry(time: "2026-11-23T10:00:00+08:00", delay: 95)])]
        )
        // 2) extra[preferredURL] 不早于顶层 history（且顶层为其他 URL 的 0ms）：优先采用 extra[preferredURL]
        let fresherExtra = ProxyEntry(
            name: "FresherExtra", type: "AnyTLS", alive: true,
            history: [ProxyHistoryEntry(time: "2026-11-23T10:05:00+08:00", delay: 0)],
            extra: [url: ProxyExtraEntry(alive: true, history: [ProxyHistoryEntry(time: "2026-11-23T10:05:00+08:00", delay: 180)])]
        )
        // 3) 精确超时边界：3899ms 在线，3900ms 离线
        let edgeOk = ProxyEntry(name: "Edge3899", type: "Vless", alive: true,
                                history: [ProxyHistoryEntry(time: "2026-11-23T10:01:00+08:00", delay: 3899)])
        let edgeTimeout = ProxyEntry(name: "Edge3900", type: "Vless", alive: true,
                                     history: [ProxyHistoryEntry(time: "2026-11-23T10:01:00+08:00", delay: 3900)])
        // 4) 精确 30 秒冷却跨轮边界：prevSeen=10:00:00，+29.9s 跳过，+30.0s 放行
        let coolNode = ProxyEntry(name: "Cool", type: "Vless", alive: true, history: [
            ProxyHistoryEntry(time: "2026-11-23T10:00:29.900+08:00", delay: 77),
            ProxyHistoryEntry(time: "2026-11-23T10:00:30.000+08:00", delay: 88)
        ])

        let topo = NodeTopology(payload: BettboxProxiesPayload(proxies: [
            "FresherTop": fresherTop, "FresherExtra": fresherExtra,
            "Edge3899": edgeOk, "Edge3900": edgeTimeout, "Cool": coolNode
        ]))
        let baseTs = MihomoTimestamp.parseMs("2026-11-23T10:00:00+08:00")!
        let samples = PassiveHistoryExtractor.extract(
            from: topo, now: now,
            lastSeenMs: [NodeKey(name: "Cool", dialer: ""): baseTs],
            preferredURL: url
        )
        let byName = Dictionary(uniqueKeysWithValues: samples.map { ($0.node, $0) })
        XCTAssertEqual(byName["FresherTop"]?.delayMs, 120)
        XCTAssertEqual(byName["FresherExtra"]?.delayMs, 180)
        XCTAssertEqual(byName["Edge3899"]?.ok, true)
        XCTAssertEqual(byName["Edge3899"]?.delayMs, 3899)
        XCTAssertEqual(byName["Edge3900"]?.ok, false)
        XCTAssertEqual(byName["Edge3900"]?.delayMs, 0)
        XCTAssertEqual(byName["Cool"]?.delayMs, 88)

        // latestValidFallback 必须遵循 clearedAtMs 约束，清库后不再回魂
        XCTAssertEqual(PassiveHistoryExtractor.latestValidFallback(for: fresherExtra, nowMs: nowMs, clearedAtMs: 0)?.delayMs, 180)
        XCTAssertNil(PassiveHistoryExtractor.latestValidFallback(for: fresherExtra, nowMs: nowMs, clearedAtMs: nowMs))
    }

    func testActiveProbePlannerLinksChainUpstreamsAndEqualWeightAggregate() throws {
        let payload = try JSONDecoder().decode(BettboxProxiesPayload.self, from: Data(sampleJSON.utf8))
        let topo = NodeTopology(payload: payload)
        let scope = NodeProbeScope(groups: ["ChainGroup", "DeletedGroup"], nodes: ["DynamicExit"])

        // 组型 dialer-proxy（DynamicExit -> TransitGroup -> AutoGroup -> NodeA）解析正确
        XCTAssertEqual(topo.resolveDialer(for: NodeKey(name: "DynamicExit", dialer: "TransitGroup")),
                       .group(groupName: "TransitGroup", currentLeaf: NodeKey(name: "NodeA", dialer: "")))

        // 自动联动链式节点前置（NodeA 与 ⛓ RelayB），共 3 链式 + DynamicExit + 2 前置 = 6 目标
        let targets = ActiveProbePlanner.plan(topology: topo, scope: scope, includeChainUpstreams: true)
        XCTAssertEqual(targets.count, 6)
        XCTAssertTrue(targets.contains { $0.key.name == "⛓ RelayB" })
        XCTAssertTrue(targets.contains { $0.key.name == "NodeA" })
        XCTAssertTrue(targets.contains { $0.key.name == "DynamicExit" })
        // 两个 Portland HTTP 同落地桶交错不相邻
        let httpIndices = targets.enumerated().compactMap { $0.element.landingBucket == "Portland HTTP" ? $0.offset : nil }
        XCTAssertEqual(httpIndices.count, 2)
        XCTAssertGreaterThan(httpIndices[1] - httpIndices[0], 1)

        // planWatchedGroups 去重重复组名
        let dedupWatched = ActiveProbePlanner.planWatchedGroups(topology: topo, watchedGroups: ["TopService", "TopService", "ChainGroup"])
        XCTAssertEqual(dedupWatched.map(\.groupName), ["TopService", "ChainGroup"])
        XCTAssertEqual(dedupWatched.map(\.leaf.name), ["NodeA → Portland HTTP", "NodeA → Portland HTTP"])

        // 分组切节点后旧节点的失败记录不张冠李戴到新节点
        let switched = GroupWatchSummaryRecord(
            groupName: "TopService", currentNode: "NodeB", dialer: "",
            latest: GroupWatchLatest(tsMs: 1000, currentNode: "NodeA", dialer: "", ok: false, delayMs: 0, consecutiveFailures: 2)
        )
        XCTAssertFalse(switched.latestMatchesCurrentNode)
        XCTAssertEqual(switched.liveState, .untested)

        // 等权节点汇总验证：100 次样本的 100% 节点与 2 次样本的 50% 节点等权平均应为 75%（不是 101/102=99%）
        let highFreq = NodeWindowMetrics(probes: 100, ok: 100, sumDelayMs: 10_000, minDelayMs: 80, maxDelayMs: 120)
        let lowFreq = NodeWindowMetrics(probes: 2, ok: 1, sumDelayMs: 300, minDelayMs: 300, maxDelayMs: 300)
        let agg = NodeEqualWeightAggregate.compute(from: [highFreq, lowFreq, NodeWindowMetrics()])
        XCTAssertEqual(agg.sampledNodeCount, 2)
        XCTAssertEqual(agg.avgUptimeRate ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(agg.avgDelayMs, 200)   // (100 + 300) / 2
        XCTAssertTrue(lowFreq.isLowSample)
        XCTAssertFalse(highFreq.isLowSample)
    }

    func testDelayRequestPercentEncodesSpecialProxyNamesAndLoadsProfile() throws {
        let client = try BettboxClient.make(config: "external-controller: 127.0.0.1:9090\nsecret: s3cr3t\n").get()
        let weirdName = "[Demo] 🇨🇳 台湾 01/A | test → 落地 HTTP"
        let req = try XCTUnwrap(client.delayRequest(proxyName: weirdName, probeURL: "http://cp.cloudflare.com/generate_204", timeoutMs: 4000))
        let rawURL = try XCTUnwrap(req.url?.absoluteString)
        XCTAssertTrue(rawURL.hasPrefix("http://127.0.0.1:9090/proxies/"))
        XCTAssertTrue(rawURL.contains("%2F"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer s3cr3t")
        XCTAssertNil(client.delayRequest(proxyName: "."))
        XCTAssertNil(client.delayRequest(proxyName: ".."))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bettbox-cfg-\(UUID().uuidString).json")
        let yamlTmp = FileManager.default.temporaryDirectory.appendingPathComponent("bettbox-cfg-\(UUID().uuidString).yaml")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: yamlTmp)
        }
        try Data("external-controller: 127.0.0.1:9090\n".utf8).write(to: yamlTmp)
        try Data("""
        {"currentProfileId":"p2","profiles":[{"id":"p1","label":"alpha"},{"id":"p2","label":"beta-profile"}]}
        """.utf8).write(to: tmp)
        XCTAssertEqual(BettboxClient.loadProfile(from: tmp), BettboxProfileInfo(id: "p2", label: "beta-profile"))
        XCTAssertEqual(BettboxClient.loadProfile(from: tmp.appendingPathComponent("missing")), .fallback)

        // configFingerprint 不应因 config.json 写入无关 UI 字段/修改时间变化而误触发配置变更；但切 currentProfileId 必须立即感知
        let fp1 = BettboxClient.configFingerprint(config: yamlTmp, appConfig: tmp)
        try Data("""
        {"currentProfileId":"p2","windowWidth":1280,"profiles":[{"id":"p1","label":"alpha"},{"id":"p2","label":"beta-profile"}]}
        """.utf8).write(to: tmp)
        let fp2 = BettboxClient.configFingerprint(config: yamlTmp, appConfig: tmp)
        XCTAssertEqual(fp1, fp2)

        try Data("""
        {"currentProfileId":"p1","windowWidth":1280,"profiles":[{"id":"p1","label":"alpha"},{"id":"p2","label":"beta-profile"}]}
        """.utf8).write(to: tmp)
        let fp3 = BettboxClient.configFingerprint(config: yamlTmp, appConfig: tmp)
        XCTAssertNotEqual(fp2, fp3)

        // NodeProbeLiveProgress 跨进程编解码与运行态判定
        let live = NodeProbeLiveProgress(
            runId: 3, phase: .probingBulk, total: 20, completed: 5, online: 4, offline: 1,
            activeNodes: ["NodeA", "NodeB"],
            recentResults: [NodeProbeLiveEvent(id: "1", node: "NodeA", groupName: nil, ok: true, delayMs: 123, tsMs: 1000)],
            flushedSamples: 4, updatedAt: 1234.5
        )
        let doneDecoded = try JSONDecoder().decode(NodeProbeLiveProgress.self, from: JSONEncoder().encode(live))
        XCTAssertEqual(doneDecoded, live)
        XCTAssertTrue(doneDecoded.isRunning)
        var done = doneDecoded
        done.phase = .finished
        XCTAssertFalse(done.isRunning)
    }

    func testCustomTrendGroupRegexCaptureCustomRulesAndAggregation() throws {
        let candidates: [NodeRuleCandidate] = [
            NodeRuleCandidate(key: NodeKey(name: "[Alpha] 🇭🇰 香港 01", dialer: ""), isChain: false, groups: ["AutoGroup", "HK"]),
            NodeRuleCandidate(key: NodeKey(name: "[Alpha] 🇯🇵 日本 01", dialer: ""), isChain: false, groups: ["AutoGroup", "JP"]),
            NodeRuleCandidate(key: NodeKey(name: "[Beta] 🇭🇰 香港 02 → 落地 HTTP", dialer: "[Beta] 🇭🇰 香港 02"), isChain: true, groups: ["ChainGroup"]),
            NodeRuleCandidate(key: NodeKey(name: "[Beta] 🇺🇸 美国 01 → 落地 SOCKS5", dialer: "[Beta] 🇺🇸 美国 01"), isChain: true, groups: ["ChainGroup"]),
            NodeRuleCandidate(key: NodeKey(name: "[Alpha] 台湾 02 -> 落地 HTTP", dialer: "[Alpha] 台湾 02"), isChain: true, groups: ["ChainGroup"]),
            NodeRuleCandidate(key: NodeKey(name: "Claude Relay Node Network Plus", dialer: ""), isChain: false, groups: ["ManualGroup"])
        ]

        let presets = NodeTrendGroupSet.defaultPresets()
        XCTAssertEqual(presets.count, 4)

        // 1) 预设「按机场」正则自动捕获 [Alpha] / [Beta]，并支持外部按 普通/链式 覆写筛选
        let providerAll = NodeTrendGroupMatcher.resolveBuckets(set: presets[0], candidates: candidates)
        XCTAssertEqual(Set(providerAll.map(\.name)), ["Alpha", "Beta"])
        let providerDirectOnly = NodeTrendGroupMatcher.resolveBuckets(set: presets[0], kindOverride: .directOnly, candidates: candidates)
        XCTAssertEqual(providerDirectOnly.map(\.name), ["Alpha"])
        XCTAssertEqual(providerDirectOnly.first?.nodeKeys.count, 2)

        // 2) 预设「按国家/地区」：精确识别入口国别（兼容 → 与 ->），且英文单词子串（Claude/Relay/Node/Network/Plus）不误命中 US/LA/DE/TW
        let regionBuckets = NodeTrendGroupMatcher.resolveBuckets(set: presets[1], candidates: candidates)
        let byRegion = Dictionary(uniqueKeysWithValues: regionBuckets.map { ($0.name, $0.nodeKeys) })
        XCTAssertEqual(byRegion["香港"]?.count, 2)
        XCTAssertEqual(byRegion["台湾"]?.count, 1)
        XCTAssertEqual(byRegion["日本"]?.count, 1)
        XCTAssertEqual(byRegion["美国"]?.count, 1)
        XCTAssertNil(byRegion["欧洲"])

        // 3) 预设「普通 vs 链式」与「链式落地对比」
        let kindBuckets = NodeTrendGroupMatcher.resolveBuckets(set: presets[2], candidates: candidates)
        XCTAssertEqual(kindBuckets.map(\.name), ["普通直连", "链式节点"])
        XCTAssertEqual(kindBuckets[0].nodeKeys.count, 3)
        XCTAssertEqual(kindBuckets[1].nodeKeys.count, 3)

        let landingBuckets = NodeTrendGroupMatcher.resolveBuckets(set: presets[3], candidates: candidates)
        XCTAssertEqual(Set(landingBuckets.map(\.name)), ["落地 HTTP", "落地 SOCKS5"])

        // 4) 自由组合规则：正则 + Bettbox 策略组 + 手选节点 + 链式筛选 + 非法正则安全拦截
        let customSet = NodeTrendGroupSet(name: "Custom", mode: .customRules, rules: [
            NodeTrendGroupRule(name: "MixDirect", kindFilter: .directOnly, regex: "日本",
                               bettboxGroups: ["ManualGroup"], explicitNodes: ["[Alpha] 🇭🇰 香港 01"]),
            NodeTrendGroupRule(name: "BadRegexOnly", kindFilter: .all, regex: "[unclosed")
        ])
        let customBuckets = NodeTrendGroupMatcher.resolveBuckets(set: customSet, candidates: candidates)
        XCTAssertEqual(customBuckets.count, 1)
        XCTAssertEqual(customBuckets[0].name, "MixDirect")
        XCTAssertEqual(customBuckets[0].nodeKeys.count, 3)
        XCTAssertNotNil(NodeTrendGroupMatcher.validateRegex("[unclosed"))
        XCTAssertNil(NodeTrendGroupMatcher.validateRegex(#"\[([^\]]+)\]"#))

        // 5) 多时间槽等权趋势聚合
        let k1 = candidates[0].key
        let k2 = candidates[1].key
        let m1 = NodeWindowMetrics(probes: 10, ok: 10, sumDelayMs: 1000, minDelayMs: 100, maxDelayMs: 100) // 100%, 100ms
        let m2 = NodeWindowMetrics(probes: 2, ok: 1, sumDelayMs: 300, minDelayMs: 300, maxDelayMs: 300)    // 50%, 300ms
        let series = NodeTrendGroupMatcher.aggregateSeries(
            buckets: [NodeTrendGroupBucket(id: "b1", name: "Alpha", nodeKeys: [k1, k2])],
            slotKeys: [2026112309, 2026112310],
            labels: ["09", "10"],
            byNode: [k1: [2026112310: m1], k2: [2026112310: m2]],
            rangeMetrics: [k1: m1, k2: m2]
        )
        XCTAssertEqual(series.count, 1)
        XCTAssertNil(series[0].points[0].avgDelayMs)
        XCTAssertEqual(series[0].points[1].avgDelayMs, 200)
        XCTAssertEqual(series[0].points[1].uptimeRate ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(series[0].summary.avgDelayMs, 200)
    }
}

final class NodeHistoryStoreTests: XCTestCase {
    private var url: URL!
    private var cal: Calendar!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-nodes-\(UUID().uuidString).sqlite")
        cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    }

    override func tearDown() {
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) }
    }

    private func date(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    private func sample(_ at: Date, node: String = "N1", dialer: String = "", type: String = "AnyTLS",
                        delay: Int, ok: Bool = true, source: NodeProbeSource = .active) -> NodeProbeSample {
        NodeProbeSample(tsMs: Int64((at.timeIntervalSince1970 * 1000.0).rounded()),
                        node: node, dialer: dialer, nodeType: type, delayMs: delay, ok: ok, source: source)
    }

    func testIdempotentInsertSourceFilteringAndWeightedAverage() throws {
        let store = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        let key = NodeKey(name: "N1", dialer: "")
        let now = date(11, 23, 10, 0)

        let batch = [
            sample(date(11, 23, 8, 10), delay: 0, ok: false, source: .passive),
            sample(date(11, 23, 8, 20), delay: 100, ok: true, source: .active),
            sample(date(11, 23, 9, 10), delay: 200, ok: true, source: .passive),
            sample(date(11, 23, 9, 20), delay: 0, ok: false, source: .active),
            sample(date(11, 18, 12, 0), delay: 300, ok: true, source: .active),
            sample(date(11, 3, 12, 0), delay: 400, ok: true, source: .passive),
            sample(date(10, 19, 12, 0), delay: 999, ok: true, source: .active)
        ]
        XCTAssertTrue(store.addNodeProbes(batch, calendar: cal))
        XCTAssertTrue(store.addNodeProbes(batch, calendar: cal))   // 幂等不累加

        let all = try XCTUnwrap(store.nodeSummaries(sourceFilter: .all, now: now, calendar: cal)[key])
        XCTAssertEqual(all.day1.probes, 4)
        XCTAssertEqual(all.day1.ok, 2)
        XCTAssertEqual(all.day1.avgDelayMs, 150)
        XCTAssertEqual(all.day1.minDelayMs, 100)
        XCTAssertEqual(all.day7.probes, 5)
        XCTAssertEqual(all.day7.avgDelayMs, 200)
        XCTAssertEqual(all.day30.probes, 6)
        XCTAssertEqual(all.day30.avgDelayMs, 250)

        // 仅主动来源筛选（排除 passive 样本）
        let activeOnly = try XCTUnwrap(store.nodeSummaries(sourceFilter: .activeOnly, now: now, calendar: cal)[key])
        XCTAssertEqual(activeOnly.day1.probes, 2)
        XCTAssertEqual(activeOnly.day1.ok, 1)
        XCTAssertEqual(activeOnly.day1.avgDelayMs, 100)
        XCTAssertEqual(activeOnly.day7.probes, 3)
        XCTAssertEqual(activeOnly.day7.ok, 2)
        XCTAssertEqual(activeOnly.day7.avgDelayMs, 200)
        XCTAssertEqual(activeOnly.day30.probes, 3)

        // 全节点批量分小时/分日时间网格查询（供自定义分组趋势聚合）
        let hourlyGrid = store.nodeAllHourlySeries(hours: 24, sourceFilter: .activeOnly, now: now, calendar: cal)
        XCTAssertEqual(hourlyGrid.keys.count, 24)
        let h8 = DayRange.hourKey(of: date(11, 23, 8, 20), calendar: cal)
        XCTAssertEqual(hourlyGrid.byNode[key]?[h8]?.avgDelayMs, 100)
        let dailyGrid = store.nodeAllDailySeries(days: 7, sourceFilter: .activeOnly, now: now, calendar: cal)
        XCTAssertEqual(dailyGrid.keys.count, 7)
        let d18 = DayRange.key(of: date(11, 18, 12, 0), calendar: cal)
        XCTAssertEqual(dailyGrid.byNode[key]?[d18]?.avgDelayMs, 300)
    }

    func testGroupWatchChannelContinuityAndConsecutiveFailures() throws {
        let store = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        let now = date(11, 23, 10, 20)
        let ms: (Date) -> Int64 = { Int64(($0.timeIntervalSince1970 * 1000.0).rounded()) }

        // 1) 上午用节点 A 在线 120ms；2) 切到节点 B 后连续 2 次超时；3) 第 3 次恢复在线 180ms
        let r1 = store.addGroupWatchSamples([
            GroupWatchSample(tsMs: ms(date(11, 23, 10, 0)), profileId: "p1", groupName: "OpenAI",
                             currentNode: "NodeA", dialer: "", delayMs: 120, ok: true)
        ], calendar: cal)
        XCTAssertEqual(r1?["OpenAI"], 0)

        let r2 = store.addGroupWatchSamples([
            GroupWatchSample(tsMs: ms(date(11, 23, 10, 5)), profileId: "p1", groupName: "OpenAI",
                             currentNode: "NodeB", dialer: "NodeA", delayMs: 0, ok: false)
        ], calendar: cal)
        XCTAssertEqual(r2?["OpenAI"], 1)

        let r3 = store.addGroupWatchSamples([
            GroupWatchSample(tsMs: ms(date(11, 23, 10, 10)), profileId: "p1", groupName: "OpenAI",
                             currentNode: "NodeB", dialer: "NodeA", delayMs: 0, ok: false)
        ], calendar: cal)
        XCTAssertEqual(r3?["OpenAI"], 2)   // 正好触发连续 2 次断线通知

        let r4 = store.addGroupWatchSamples([
            GroupWatchSample(tsMs: ms(date(11, 23, 10, 15)), profileId: "p1", groupName: "OpenAI",
                             currentNode: "NodeB", dialer: "NodeA", delayMs: 180, ok: true)
        ], calendar: cal)
        XCTAssertEqual(r4?["OpenAI"], 0)   // 恢复在线后连续失败清零

        // 4) 跨长时间中断（如合盖休眠 3 小时）后单次超时不得与休眠前的失败拼接成“连续 2 次”
        let r5 = store.addGroupWatchSamples([
            GroupWatchSample(tsMs: ms(date(11, 23, 10, 20)), profileId: "p1", groupName: "SleepTest",
                             currentNode: "NodeA", dialer: "", delayMs: 0, ok: false)
        ], calendar: cal)
        XCTAssertEqual(r5?["SleepTest"], 1)
        let r6 = store.addGroupWatchSamples([
            GroupWatchSample(tsMs: ms(date(11, 23, 13, 25)), profileId: "p1", groupName: "SleepTest",
                             currentNode: "NodeA", dialer: "", delayMs: 0, ok: false)
        ], calendar: cal)
        XCTAssertEqual(r6?["SleepTest"], 1)   // 间隔 > 20 分钟自动归零重算

        let summary = try XCTUnwrap(store.groupWatchSummaries(profileId: "p1", now: now, calendar: cal)["OpenAI"])
        XCTAssertEqual(summary.currentNode, "NodeB")
        XCTAssertEqual(summary.day1.probes, 4)
        XCTAssertEqual(summary.day1.ok, 2)
        XCTAssertEqual(summary.day1.avgDelayMs, 150)   // (120 + 180) / 2，跨节点切换连续统计
        XCTAssertEqual(summary.latest?.consecutiveFailures, 0)
        XCTAssertTrue(store.groupWatchSummaries(profileId: "p2", now: now, calendar: cal).isEmpty)
    }

    func testSchemaV1ToV2ConcurrentMigrationPreservesAllNonNodeTables() throws {
        // 连续 5 轮并发压测模拟 v1 真实 WAL 旧库（含 traffic / apps / daily_physical / daily_apps / link_days / disk_days + 无 source 列的旧 node_days 脏表）
        for round in 0..<5 {
            let raceURL = url.deletingLastPathComponent().appendingPathComponent("zest-nodes-v1-\(UUID().uuidString).sqlite")
            defer { ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: raceURL.path + $0) } }

            var raw: OpaquePointer?
            XCTAssertEqual(sqlite3_open(raceURL.path, &raw), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(raw, """
                PRAGMA journal_mode=WAL;
                CREATE TABLE traffic(minute INTEGER NOT NULL, app_key TEXT NOT NULL, bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL, PRIMARY KEY(minute, app_key)) WITHOUT ROWID;
                INSERT INTO traffic VALUES(29920000, 'com.apple.Safari', 100, 200);
                CREATE TABLE apps(app_key TEXT PRIMARY KEY, name TEXT NOT NULL, bundle TEXT, kind INTEGER NOT NULL);
                INSERT INTO apps VALUES('com.apple.Safari', 'Safari', '/Applications/Safari.app', 0);
                CREATE TABLE daily_physical(day INTEGER PRIMARY KEY, bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL);
                INSERT INTO daily_physical VALUES(20261123, 12345, 6789);
                CREATE TABLE daily_apps(day INTEGER NOT NULL, app_key TEXT NOT NULL, bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL, PRIMARY KEY(day, app_key)) WITHOUT ROWID;
                INSERT INTO daily_apps VALUES(20261123, 'com.apple.Safari', 500, 600);
                CREATE TABLE link_days(day INTEGER NOT NULL, rule TEXT NOT NULL, egress TEXT NOT NULL, app TEXT NOT NULL, bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL, PRIMARY KEY(day, rule, egress, app)) WITHOUT ROWID;
                INSERT INTO link_days VALUES(20261123, 'MATCH', 'NodeA', 'curl', 10, 20);
                CREATE TABLE disk_days(day INTEGER NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL, bytes_read INTEGER NOT NULL, bytes_written INTEGER NOT NULL, PRIMARY KEY(day, path)) WITHOUT ROWID;
                INSERT INTO disk_days VALUES(20261123, '/Applications/Xcode.app', 'Xcode', 700, 800);
                CREATE TABLE node_days(day INTEGER NOT NULL, node TEXT NOT NULL, dialer TEXT NOT NULL,
                    node_type TEXT NOT NULL, probes INTEGER NOT NULL, ok INTEGER NOT NULL,
                    sum_delay_ms INTEGER NOT NULL, min_delay_ms INTEGER NOT NULL, max_delay_ms INTEGER NOT NULL,
                    PRIMARY KEY(day, node, dialer)) WITHOUT ROWID;
                INSERT INTO node_days VALUES(20261123, 'DirtyNode', '', 'AnyTLS', 1, 1, 5003, 5003, 5003);
                """, nil, nil, nil), SQLITE_OK)
            sqlite3_close(raw)

            // 并发模拟主进程 4 条写入连接（NetworkMonitor / DiskIOService / NodeMonitorService 等）+ 2 条只读窗口连接同时打开升级
            let lock = NSLock()
            var openedWriters = 0
            DispatchQueue.concurrentPerform(iterations: 6) { idx in
                let s = HistoryStore(url: raceURL, migrate: idx < 4, calendar: cal)
                if idx < 4, s != nil {
                    lock.lock(); openedWriters += 1; lock.unlock()
                }
            }
            XCTAssertEqual(openedWriters, 4, "round \(round)")

            let store = try XCTUnwrap(HistoryStore(url: raceURL, migrate: true, calendar: cal))
            XCTAssertEqual(store.physicalTotals(DayRange(from: 20261123, to: 20261123)),
                           InterfaceCounters(bytesIn: 12345, bytesOut: 6789))
            XCTAssertEqual(store.appTotals(DayRange(from: 20261123, to: 20261123)).first?.name, "Safari")
            XCTAssertEqual(store.diskTotals(DayRange(from: 20261123, to: 20261123)).first?.name, "Xcode")
            XCTAssertEqual(store.linkSnapshot(.today, rule: nil, now: date(11, 23, 12, 0), calendar: cal).total.down, 10)
            XCTAssertTrue(store.nodeSummaries(now: date(11, 23, 12, 0), calendar: cal).isEmpty)
            XCTAssertTrue(store.addNodeProbes([sample(date(11, 23, 11, 0), delay: 88, source: .active)], calendar: cal))
            XCTAssertEqual(store.nodeSummaries(now: date(11, 23, 12, 0), calendar: cal)[NodeKey(name: "N1", dialer: "")]?.day1.avgDelayMs, 88)
        }
    }

    func testPruneRetentionDayBoundariesClearAndViewerReadOnly() throws {
        let now = date(11, 23, 12, 0)
        let ms: (Date) -> Int64 = { Int64(($0.timeIntervalSince1970 * 1000.0).rounded()) }
        do {
            let store = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
            // 精确自然日边界：11/17(-6天) 在 7 天内，11/16(-7天) 不在 7 天内；10/25(-29天) 在 30 天内，10/24(-30天) 不在 30 天内
            XCTAssertTrue(store.addNodeProbes([
                sample(date(10, 24, 12, 0), delay: 500),
                sample(date(10, 25, 12, 0), delay: 400),
                sample(date(11, 16, 12, 0), delay: 300),
                sample(date(11, 17, 12, 0), delay: 200),
                sample(date(11, 23, 11, 0), delay: 100)
            ], calendar: cal))
            // 陈旧 >30 天的 group_watch_latest 应在 prune 时被清理
            XCTAssertNotNil(store.addGroupWatchSamples([
                GroupWatchSample(tsMs: ms(date(10, 1, 12, 0)), profileId: "p1", groupName: "StaleGroup",
                                 currentNode: "N1", dialer: "", delayMs: 100, ok: true),
                GroupWatchSample(tsMs: ms(date(11, 23, 11, 0)), profileId: "p1", groupName: "FreshGroup",
                                 currentNode: "N1", dialer: "", delayMs: 100, ok: true)
            ], calendar: cal))
            store.prune(nowMinute: Int(now.timeIntervalSince1970 / 60), now: now, calendar: cal)
        }

        let viewer = try XCTUnwrap(HistoryStore(url: url, migrate: false, calendar: cal))
        XCTAssertFalse(viewer.addNodeProbes([sample(date(11, 23, 11, 30), delay: 50)], calendar: cal))
        XCTAssertNil(viewer.addGroupWatchSamples([
            GroupWatchSample(tsMs: ms(now), profileId: "p1", groupName: "G",
                             currentNode: "N1", dialer: "", delayMs: 80, ok: true)
        ], calendar: cal))
        viewer.prune(nowMinute: Int(date(12, 31, 12, 0).timeIntervalSince1970 / 60), now: date(12, 31, 12, 0), calendar: cal)

        let key = NodeKey(name: "N1", dialer: "")
        let s = try XCTUnwrap(viewer.nodeSummaries(now: now, calendar: cal)[key])
        XCTAssertEqual(s.day1.probes, 1)
        XCTAssertEqual(s.day7.probes, 2)    // 11/23 + 11/17（排除 11/16）
        XCTAssertEqual(s.day30.probes, 4)   // 11/23 + 11/17 + 11/16 + 10/25（排除 10/24）
        XCTAssertEqual(s.day30.avgDelayMs, 250)

        let groups = viewer.groupWatchSummaries(profileId: "p1", now: now, calendar: cal)
        XCTAssertNil(groups["StaleGroup"]?.latest)
        XCTAssertNotNil(groups["FreshGroup"]?.latest)

        // clearAll 清空数据但保留 node_meta schema_version，再次打开不会重复删表
        let primary = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        primary.clearAll()
        XCTAssertTrue(primary.nodeSummaries(now: now, calendar: cal).isEmpty)
        XCTAssertTrue(primary.addNodeProbes([sample(date(11, 23, 11, 50), delay: 75)], calendar: cal))
        let reopened = try XCTUnwrap(HistoryStore(url: url, migrate: true, calendar: cal))
        XCTAssertEqual(reopened.nodeSummaries(now: now, calendar: cal)[key]?.day1.avgDelayMs, 75)
    }

    func testCrossProcessNodeProbeSettingsPayloadRoundTrip() throws {
        let suiteA = "app.zest.test.nodeprobe.a.\(UUID().uuidString)"
        let suiteB = "app.zest.test.nodeprobe.b.\(UUID().uuidString)"
        guard let dA = UserDefaults(suiteName: suiteA), let dB = UserDefaults(suiteName: suiteB) else {
            return XCTFail("Failed to create test UserDefaults suites")
        }
        defer {
            dA.removePersistentDomain(forName: suiteA)
            dB.removePersistentDomain(forName: suiteB)
        }
        let sender = AppSettings(defaults: dA)
        let receiver = AppSettings(defaults: dB)
        sender.nodeActiveProbeEnabled = true
        sender.nodeProbeIntervalMinutes = 15
        sender.nodeGroupAlertEnabled = false
        sender.setScope(NodeProbeScope(groups: ["ChainGroup"], nodes: ["NodeA"], watchedGroups: ["OpenAI"]), forProfile: "prof-1")

        let note = Notification(name: AppSettings.nodeProbeSettingsChangedNotification,
                                object: nil, userInfo: sender.nodeProbeUserInfo())
        receiver.reloadNodeProbeSettings(note)
        XCTAssertTrue(receiver.nodeActiveProbeEnabled)
        XCTAssertEqual(receiver.nodeProbeIntervalMinutes, 15)
        XCTAssertFalse(receiver.nodeGroupAlertEnabled)
        XCTAssertEqual(receiver.scope(forProfile: "prof-1"),
                       NodeProbeScope(groups: ["ChainGroup"], nodes: ["NodeA"], watchedGroups: ["OpenAI"]))
    }
}
