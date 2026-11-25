//
//  NetworkTests.swift
//  ZestTests
//

import XCTest
@testable import Zest

final class NettopParserTests: XCTestCase {
    static let csv = """
    ,state,bytes_in,bytes_out,
    Google Chrome H.812,,1000,200,
    tcp4 192.168.1.5:50000<->142.250.1.1:443,Established,900,150,
    udp6 *.5353<->*.*,,100,50,
    my.dotted.app.42,,10,20,
    tcp6 fe80::1%en0.60000<->fe80::2%en0.7000,Established,10,20,
    tcp4 *:22<->*:*,Listen,,,
    ,state,bytes_in,bytes_out,
    """

    func testParsesProcessesAndConnections() throws {
        let p = NettopParser()
        var samples: [NettopSample] = []
        for line in NettopParserTests.csv.split(separator: "\n") { if let s = p.feed(line) { samples.append(s) } }
        XCTAssertEqual(samples.count, 1)   // 第二个表头到来时产出第一份完整采样
        let s = try XCTUnwrap(samples.last)
        XCTAssertEqual(s.processes.map(\.name), ["Google Chrome H", "my.dotted.app"])
        XCTAssertEqual(s.processes.map(\.pid), [812, 42])
        XCTAssertEqual(s.connections.count, 4)
        let tcp = s.connections[0]
        XCTAssertEqual(tcp.pid, 812)
        XCTAssertEqual(tcp.remote, Endpoint(address: "142.250.1.1", port: 443))
        XCTAssertEqual(tcp.state, "Established")
        XCTAssertEqual(tcp.bytesIn, 900)
        XCTAssertNil(s.connections[1].remote)                    // UDP 监听
        XCTAssertEqual(s.connections[1].local, Endpoint(address: "*", port: 5353))
        XCTAssertEqual(s.connections[2].remote, Endpoint(address: "fe80::2%en0", port: 7000))
        XCTAssertEqual(s.connections[2].pid, 42)
        XCTAssertEqual(s.connections[3].local, Endpoint(address: "*", port: 22))   // 所有接口
        XCTAssertNil(s.connections[3].remote)
        XCTAssertEqual(s.connections[3].state, "Listen")
    }

    func testParsesInterfaceColumnAndTunnelFlag() throws {
        let csv = """
        ,interface,state,bytes_in,bytes_out,
        easytier-gui.66130,,,190000000,6000000000,
        udp4 *:11010<->*.*,en0,,100,200,
        tcp4 10.144.144.110:50000<->10.144.144.2:22,utun1,Established,300,400,
        udp6 *.5353<->*.*,utun7,,10,20,
        udp6 *.5353<->*.*,en0,,50,60,
        ,interface,state,bytes_in,bytes_out,
        """
        let p = NettopParser()
        var samples: [NettopSample] = []
        for line in csv.split(separator: "\n") {
            if let s = p.feed(line) { samples.append(s) }
        }
        let s = try XCTUnwrap(samples.first)
        XCTAssertEqual(s.connections.count, 4)
        XCTAssertEqual(s.connections[0].interface, "en0")
        XCTAssertFalse(s.connections[0].isTunnelOrP2PInterface)
        XCTAssertEqual(s.connections[1].interface, "utun1")
        XCTAssertTrue(s.connections[1].isTunnelOrP2PInterface)
        // 同四元组跨不同接口应拥有独立的去重 key
        XCTAssertNotEqual(s.connections[2].key, s.connections[3].key)
        XCTAssertTrue(s.connections[2].isTunnelOrP2PInterface)
        XCTAssertFalse(s.connections[3].isTunnelOrP2PInterface)
    }

    func testStringScopes() {
        XCTAssertEqual(AddressScopes.scope(of: "8.8.8.8"), .internet)
        XCTAssertEqual(AddressScopes.scope(of: "192.168.1.1"), .lan)
        XCTAssertEqual(AddressScopes.scope(of: "198.18.0.5"), .reserved)
        XCTAssertEqual(AddressScopes.scope(of: "fe80::2%en0"), .lan)
        XCTAssertEqual(AddressScopes.scope(of: "::1"), .loopback)
        XCTAssertEqual(AddressScopes.scope(of: "2606:4700::1111"), .internet)
    }
}

final class NetworkTrackerTests: XCTestCase {
    private func tracker() -> NetworkTracker {
        let t = NetworkTracker()
        t.ownerLookup = { pid, name in
            let key = pid < 100 ? "AppA" : name
            return ProcessOwner(key: key, bundlePath: nil, name: key, kind: .app)
        }
        return t
    }

    private func sample(_ rows: [(String, pid_t, UInt64, UInt64)]) -> NettopSample {
        NettopSample(processes: rows.map { NettopProcessRow(name: $0.0, pid: $0.1, bytesIn: $0.2, bytesOut: $0.3) })
    }

    func testRatesAndSessionTotalsAggregatePerApp() {
        let t = tracker()
        let s0: UInt64 = 1_000_000_000
        _ = t.ingest(sample([("a", 1, 1000, 100), ("b", 2, 500, 50)]), now: s0)
        // 两秒后：pid1 +2000/+200，pid2 +1000/+0（同属 AppA）
        let st = t.ingest(sample([("a", 1, 3000, 300), ("b", 2, 1500, 50)]), now: s0 + 2_000_000_000)
        let app = try! XCTUnwrap(st.apps.first { $0.key == "AppA" })
        XCTAssertEqual(app.sessionIn, 3000)
        XCTAssertEqual(app.sessionOut, 200)
        XCTAssertEqual(app.rateIn, 1500, accuracy: 0.001)
        XCTAssertEqual(app.rateOut, 100, accuracy: 0.001)
        XCTAssertEqual(st.sessionIn, 3000)
        XCTAssertEqual(st.rateIn, 1500, accuracy: 0.001)
    }

    func testBurstArrivalUsesNettopInterval() {
        let t = tracker()
        let s0: UInt64 = 1_000_000_000
        _ = t.ingest(sample([("a", 1, 0, 0)]), now: s0)
        // 两份采样因管道缓冲在 1ms 内先后到达：速率应按 2 秒采样间隔计算，而不是 1ms。
        let st = t.ingest(sample([("a", 1, 4000, 0)]), now: s0 + 1_000_000, interval: 2)
        XCTAssertEqual(st.rateIn, 2000, accuracy: 0.001)
    }

    func testNewProcessHistoryIsNotCountedAndResetIsSafe() {
        let t = tracker()
        let s0: UInt64 = 1_000_000_000
        _ = t.ingest(sample([("a", 1, 1000, 0)]), now: s0)
        // 新进程 pid 500 带着 9GB 历史出现：不应计入本次流量。
        var st = t.ingest(sample([("a", 1, 1000, 0), ("x", 500, 9_000_000_000, 0)]), now: s0 + 1_000_000_000)
        XCTAssertEqual(st.sessionIn, 0)
        // nettop -L 1 进程行总和只是存活连接之和：短连接关闭导致计数变小时记 0，绝不可把整笔计数当增量累加。
        st = t.ingest(sample([("a", 1, 10, 0), ("x", 500, 9_000_000_000, 0)]), now: s0 + 2_000_000_000)
        XCTAssertEqual(st.sessionIn, 0)
    }

    func testPerConnectionDeltaIgnoresClosedShortSocketsOnLargeTunnel() throws {
        let t = tracker()
        let s0: UInt64 = 1_000_000_000
        let tunnelAddr = Endpoint(address: "*", port: 11010)
        let shortAddr = Endpoint(address: "10.0.0.2", port: 59592)
        let newShortAddr = Endpoint(address: "10.0.0.2", port: 59593)

        func conn(portEndpoint: Endpoint, iface: String, out: UInt64) -> NettopConnectionRow {
            NettopConnectionRow(pid: 661, proto: .udp, ipv6: false, local: portEndpoint, remote: nil,
                                state: "", bytesIn: 0, bytesOut: out, interface: iface)
        }

        // 第 1 轮基线：6 GB 常驻隧道 + 500 B 临时探测连接（进程总和 6,000,000,500）
        let baseSample = NettopSample(
            processes: [NettopProcessRow(name: "easytier-gui", pid: 661, bytesIn: 0, bytesOut: 6_000_000_500)],
            connections: [
                conn(portEndpoint: tunnelAddr, iface: "en0", out: 6_000_000_000),
                conn(portEndpoint: shortAddr, iface: "en0", out: 500)
            ]
        )
        _ = t.ingest(baseSample, now: s0)

        // 第 2 轮：短连接 59592 关闭，常驻隧道仅增 +250 B（进程总和从 6,000,000,500 降到 6,000,000,250）
        let s2 = NettopSample(
            processes: [NettopProcessRow(name: "easytier-gui", pid: 661, bytesIn: 0, bytesOut: 6_000_000_250)],
            connections: [conn(portEndpoint: tunnelAddr, iface: "en0", out: 6_000_000_250)]
        )
        var st = t.ingest(s2, now: s0 + 2_000_000_000)
        var app = try XCTUnwrap(st.apps.first { $0.name == "easytier-gui" })
        XCTAssertEqual(app.sessionOut, 250)

        // 第 3 轮：新开临时连接 59593 带 300 B，应精确计入 +300 B
        let s3 = NettopSample(
            processes: [NettopProcessRow(name: "easytier-gui", pid: 661, bytesIn: 0, bytesOut: 6_000_000_550)],
            connections: [
                conn(portEndpoint: tunnelAddr, iface: "en0", out: 6_000_000_250),
                conn(portEndpoint: newShortAddr, iface: "en0", out: 300)
            ]
        )
        st = t.ingest(s3, now: s0 + 4_000_000_000)
        app = try XCTUnwrap(st.apps.first { $0.name == "easytier-gui" })
        XCTAssertEqual(app.sessionOut, 550)

        // 第 4 轮：常驻隧道瞬时漏采 1 轮
        let s4 = NettopSample(
            processes: [NettopProcessRow(name: "easytier-gui", pid: 661, bytesIn: 0, bytesOut: 300)],
            connections: [conn(portEndpoint: newShortAddr, iface: "en0", out: 300)]
        )
        st = t.ingest(s4, now: s0 + 6_000_000_000)
        app = try XCTUnwrap(st.apps.first { $0.name == "easytier-gui" })
        XCTAssertEqual(app.sessionOut, 550)

        // 第 5 轮（宽限期内）：隧道在 en5 接口重现并多发了 +150 B，应按旧基线增量只计 +150 B
        let s5 = NettopSample(
            processes: [NettopProcessRow(name: "easytier-gui", pid: 661, bytesIn: 0, bytesOut: 6_000_000_700)],
            connections: [
                conn(portEndpoint: tunnelAddr, iface: "en5", out: 6_000_000_400),
                conn(portEndpoint: newShortAddr, iface: "en0", out: 300)
            ]
        )
        st = t.ingest(s5, now: s0 + 8_000_000_000)
        app = try XCTUnwrap(st.apps.first { $0.name == "easytier-gui" })
        XCTAssertEqual(app.sessionOut, 700)
    }

    func testTunnelInterfaceExcludedFromOverviewTotalsButKeptOnApp() throws {
        let t = tracker()
        let s0: UInt64 = 1_000_000_000
        let localSSH = Endpoint(address: "10.144.144.110", port: 50000)
        let remoteSSH = Endpoint(address: "10.144.144.2", port: 22)
        let etLocal = Endpoint(address: "*", port: 11010)

        let base = NettopSample(
            processes: [
                NettopProcessRow(name: "ssh", pid: 101, bytesIn: 0, bytesOut: 0),
                NettopProcessRow(name: "easytier-gui", pid: 102, bytesIn: 0, bytesOut: 0)
            ],
            connections: [
                NettopConnectionRow(pid: 101, proto: .tcp, ipv6: false, local: localSSH, remote: remoteSSH,
                                    state: "Established", bytesIn: 0, bytesOut: 0, interface: "utun1"),
                NettopConnectionRow(pid: 102, proto: .udp, ipv6: false, local: etLocal, remote: nil,
                                    state: "", bytesIn: 0, bytesOut: 0, interface: "en0")
            ]
        )
        _ = t.ingest(base, now: s0)

        let next = NettopSample(
            processes: [
                NettopProcessRow(name: "ssh", pid: 101, bytesIn: 0, bytesOut: 1000),
                NettopProcessRow(name: "easytier-gui", pid: 102, bytesIn: 0, bytesOut: 1100)
            ],
            connections: [
                NettopConnectionRow(pid: 101, proto: .tcp, ipv6: false, local: localSSH, remote: remoteSSH,
                                    state: "Established", bytesIn: 0, bytesOut: 1000, interface: "utun1"),
                NettopConnectionRow(pid: 102, proto: .udp, ipv6: false, local: etLocal, remote: nil,
                                    state: "", bytesIn: 0, bytesOut: 1100, interface: "en0")
            ]
        )
        let st = t.ingest(next, now: s0 + 2_000_000_000)
        let sshApp = try XCTUnwrap(st.apps.first { $0.name == "ssh" })
        let etApp = try XCTUnwrap(st.apps.first { $0.name == "easytier-gui" })
        XCTAssertEqual(sshApp.sessionOut, 1000)
        XCTAssertEqual(etApp.sessionOut, 1100)
        // utun1 流量计入 ssh 自身，不叠加到总览总流量（否则 1000 + 1100 = 2100 双计）
        XCTAssertEqual(st.sessionOut, 1100)
    }

    func testRelayClassifierIdentifiesGatewaysAndMeshVPNs() {
        XCTAssertEqual(NetworkRelayClassifier.role(appKey: "/Applications/Bettbox.app", appName: "Bettbox",
                                                   bundlePath: "/Applications/Bettbox.app"), .proxyGateway)
        XCTAssertEqual(NetworkRelayClassifier.role(appKey: "/Applications/Clash Verge.app", appName: "Clash Verge"), .proxyGateway)
        XCTAssertEqual(NetworkRelayClassifier.role(appKey: "mihomo", appName: "mihomo"), .proxyGateway)
        XCTAssertEqual(NetworkRelayClassifier.role(appKey: "/Applications/FlClash.app", appName: "FlClash"), .proxyGateway)
        XCTAssertEqual(NetworkRelayClassifier.role(appKey: "/Applications/easytier-gui.app", appName: "easytier-gui"), .meshVPN)
        XCTAssertEqual(NetworkRelayClassifier.role(appKey: "zerotier-one", appName: "zerotier-one"), .meshVPN)
        XCTAssertEqual(NetworkRelayClassifier.role(appKey: "/Applications/Tailscale.app", appName: "Tailscale"), .meshVPN)
        XCTAssertNil(NetworkRelayClassifier.role(appKey: "/Applications/WeChat.app", appName: "WeChat"))
        XCTAssertNil(NetworkRelayClassifier.role(appKey: "/Applications/Xcode.app", appName: "Xcode"))
        XCTAssertNil(NetworkRelayClassifier.role(appKey: "ssh", appName: "ssh"))
    }

    func testLiveSeedResampleInterpolatesAndRespectsGapAndStaleness() throws {
        let now: TimeInterval = 1_795_570_000
        // 主进程每 8s 采样一次，测试线性插值到 2s 网格、>20s 休眠空档填 0、以及截尾到 capacity
        let snapshot = LiveSeedSnapshot(
            savedAt: now,
            points: [
                LiveSeedPoint(timestamp: now - 40, bytesIn: 100, bytesOut: 50),
                LiveSeedPoint(timestamp: now - 32, bytesIn: 500, bytesOut: 250),
                // 中间 24 秒休眠空档 (> 20s)
                LiveSeedPoint(timestamp: now - 8, bytesIn: 800, bytesOut: 400),
                LiveSeedPoint(timestamp: now, bytesIn: 1200, bytesOut: 600),
            ]
        )
        let points = snapshot.resampled(now: now, stepSeconds: 2.0, capacity: 150, maxGapSeconds: 20.0)
        // [now-40 ... now] 步长 2s 共 21 个点
        XCTAssertEqual(points.count, 21)
        XCTAssertEqual(points[0].bytesIn, 100, accuracy: 0.001)
        XCTAssertEqual(points[2].bytesIn, 300, accuracy: 0.001)   // now-36 线性中点
        XCTAssertEqual(points[4].bytesIn, 500, accuracy: 0.001)   // now-32
        XCTAssertEqual(points[8].bytesIn, 0, accuracy: 0.001)     // 休眠空档填 0
        XCTAssertEqual(points[16].bytesIn, 800, accuracy: 0.001)  // now-8
        XCTAssertEqual(points[18].bytesIn, 1000, accuracy: 0.001) // now-4 线性中点
        XCTAssertEqual(points[20].bytesIn, 1200, accuracy: 0.001)
        XCTAssertEqual(points[20].bytesOut, 600, accuracy: 0.001)

        // capacity 限制仅保留最新的 N 个点
        let capped = snapshot.resampled(now: now, stepSeconds: 2.0, capacity: 5, maxGapSeconds: 20.0)
        XCTAssertEqual(capped.count, 5)
        XCTAssertEqual(capped.first?.bytesIn ?? -1, 800, accuracy: 0.001)
        XCTAssertEqual(capped.last?.bytesIn ?? -1, 1200, accuracy: 0.001)

        // 快照超过 60s 视为过期，返回空数组
        let stale = snapshot.resampled(now: now + 61, stepSeconds: 2.0, capacity: 150)
        XCTAssertTrue(stale.isEmpty)

        // preloadLive 应预填并可无缝接续后续 ingest
        let t = tracker()
        let seedTime = Date(timeIntervalSince1970: now)
        t.preloadLive(capped, now: seedTime, stepSeconds: 2.0)
        let firstIngest = t.ingest(sample([("a", 1, 1000, 500)]), now: 1_000_000_000, date: seedTime.addingTimeInterval(2))
        XCTAssertEqual(firstIngest.live.count, 5)
        XCTAssertEqual(firstIngest.rateIn, 1200, accuracy: 0.001)
        let secondIngest = t.ingest(sample([("a", 1, 5000, 1500)]), now: 3_000_000_000,
                                    date: seedTime.addingTimeInterval(4), interval: 2.0)
        XCTAssertEqual(secondIngest.live.count, 6)
        XCTAssertEqual(secondIngest.live.last?.bytesIn ?? -1, 2000, accuracy: 0.001)
        XCTAssertEqual(t.liveSeedSnapshot(now: seedTime.addingTimeInterval(4)).points.count, 6)
    }

    func testLiveWaveMathRightAlignedContinuousScrollAndMonotoneClamping() {
        let width: CGFloat = 298
        let cap = 150
        // 右对齐：单点贴在右边缘 width
        XCTAssertEqual(LiveWaveMath.xCoordinate(index: 0, count: 1, capacity: cap, width: width, subStep: 0), width, accuracy: 0.001)

        // 当 count=10 且 subStep=1.0 时，最新点(index=9)刚好到达 width；
        // 下一采样到来变为 count=11 且 subStep=0.0 时，同一点(index=9)仍在 width，零跳变连续左滑
        let xArrived = LiveWaveMath.xCoordinate(index: 9, count: 10, capacity: cap, width: width, subStep: 1.0)
        let xNextFrame = LiveWaveMath.xCoordinate(index: 9, count: 11, capacity: cap, width: width, subStep: 0.0)
        XCTAssertEqual(xArrived, width, accuracy: 0.001)
        XCTAssertEqual(xNextFrame, width, accuracy: 0.001)

        // 历史点(index=5)在滑步推进期间也严格连续
        let hArrived = LiveWaveMath.xCoordinate(index: 5, count: 10, capacity: cap, width: width, subStep: 1.0)
        let hNextFrame = LiveWaveMath.xCoordinate(index: 5, count: 11, capacity: cap, width: width, subStep: 0.0)
        XCTAssertEqual(hArrived, hNextFrame, accuracy: 0.001)

        // 单调三次样条在陡升后骤降至 0 轴时不得向下过冲跌破 maxY 或冲出 minY
        let minY: CGFloat = 20
        let maxY: CGFloat = 150
        let wavePts = [
            CGPoint(x: 0, y: 150),
            CGPoint(x: 20, y: 20),
            CGPoint(x: 40, y: 150),
            CGPoint(x: 60, y: 150),
            CGPoint(x: 80, y: 80),
        ]
        let path = LiveWaveMath.monotoneCubicPath(points: wavePts, minY: minY, maxY: maxY)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minY, minY - 0.001)
        XCTAssertLessThanOrEqual(path.boundingRect.maxY, maxY + 0.001)

        let edgeY = LiveWaveMath.rightEdgeY(points: wavePts, edgeX: 70, minY: minY, maxY: maxY)
        XCTAssertNotNil(edgeY)
        if let edgeY {
            XCTAssertGreaterThanOrEqual(edgeY, minY - 0.001)
            XCTAssertLessThanOrEqual(edgeY, maxY + 0.001)
        }
    }
}

final class AnomalyDetectorTests: XCTestCase {
    private func flow(_ app: String, remote: String, port: UInt16, local: UInt16 = 50000, proto: NetProtocol = .tcp,
                      state: String = "Established") -> FlowInfo {
        FlowInfo(id: "\(app)|\(remote)|\(port)|\(local)", appKey: app, appName: app, pid: 1, proto: proto,
                 local: Endpoint(address: "192.168.1.5", port: local), remote: Endpoint(address: remote, port: port),
                 state: state, scope: AddressScopes.scope(of: remote), bytesIn: 0, bytesOut: 0, firstSeen: Date())
    }

    private func state(_ flows: [FlowInfo], apps: [AppTraffic] = []) -> NetworkState {
        var s = NetworkState()
        s.flows = flows
        s.apps = apps
        return s
    }

    func testWarmupSuppressesNewAppThenFires() {
        let d = AnomalyDetector()
        d.warmup = 60
        let t0 = Date()
        XCTAssertTrue(d.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 443)]), devices: [], now: t0).isEmpty)
        let later = d.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 443), flow("B", remote: "1.1.1.1", port: 443)]),
                               devices: [], now: t0.addingTimeInterval(120))
        XCTAssertEqual(later.map(\.kind), [.newInternetApp])
        XCTAssertEqual(later.first?.appKey, "B")
    }

    func testPlaintextAndSuspiciousPortsDedup() {
        let d = AnomalyDetector()
        d.warmup = 0
        let t0 = Date()
        let s = state([flow("A", remote: "8.8.8.8", port: 80), flow("A", remote: "9.9.9.9", port: 4444)])
        let first = d.evaluate(state: s, devices: [], now: t0).map(\.kind)
        XCTAssertTrue(first.contains(.plaintext))
        XCTAssertTrue(first.contains(.suspiciousPort))
        // 冷却期内不重复
        let again = d.evaluate(state: s, devices: [], now: t0.addingTimeInterval(10)).map(\.kind)
        XCTAssertFalse(again.contains(.plaintext))
        XCTAssertFalse(again.contains(.suspiciousPort))
        // 局域网地址的 80 端口不算明文公网连接
        let d2 = AnomalyDetector(); d2.warmup = 0
        XCTAssertFalse(d2.evaluate(state: state([flow("A", remote: "192.168.1.1", port: 80)]), devices: []).map(\.kind).contains(.plaintext))
    }

    func testRestoredAlertsPreventDuplicatesAfterRestart() {
        let t0 = Date()
        let d = AnomalyDetector()
        d.warmup = 0
        let fired = d.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 80)]), devices: [], now: t0)
        XCTAssertEqual(fired.map(\.kind), [.newInternetApp, .plaintext])
        // 模拟重启：新的检测器从持久化的告警恢复状态
        let restarted = AnomalyDetector()
        restarted.warmup = 0
        restarted.restore(from: fired)
        XCTAssertTrue(restarted.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 80)]), devices: [],
                                         now: t0.addingTimeInterval(600)).isEmpty)
        // 冷却期（明文 1 小时）过后可以再次告警；“新的联网应用”永不重复
        let later = restarted.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 80)]), devices: [],
                                       now: t0.addingTimeInterval(3700)).map(\.kind)
        XCTAssertEqual(later, [.plaintext])
    }

    func testRegularPeriodDetection() {
        let t0 = Date()
        let regular = (0..<7).map { t0.addingTimeInterval(Double($0) * 30 + ($0 % 2 == 0 ? 1 : -1)) }
        XCTAssertEqual(AnomalyDetector.regularPeriod(regular) ?? 0, 30, accuracy: 1)
        let irregular = [0, 5, 70, 80, 200, 210, 400].map { t0.addingTimeInterval(Double($0)) }
        XCTAssertNil(AnomalyDetector.regularPeriod(irregular))
        XCTAssertNil(AnomalyDetector.regularPeriod(Array(regular.prefix(5))))
        let tooFast = (0..<8).map { t0.addingTimeInterval(Double($0) * 2) }
        XCTAssertNil(AnomalyDetector.regularPeriod(tooFast))
    }

    func testBeaconFiresForRegularNewConnections() {
        let d = AnomalyDetector()
        d.warmup = 0
        let t0 = Date()
        var kinds: [AlertKind] = []
        var flows: [FlowInfo] = []
        for i in 0..<7 {
            flows.append(flow("Agent", remote: "5.6.7.8", port: 8443, local: UInt16(50000 + i)))
            kinds += d.evaluate(state: state(flows), devices: [], now: t0.addingTimeInterval(Double(i) * 60)).map(\.kind)
        }
        XCTAssertTrue(kinds.contains(.beacon))
    }

    func testVolumeSpike() {
        XCTAssertTrue(AnomalyDetector.isSpike(recent: 5_000_000, baseline: 10_000))
        XCTAssertFalse(AnomalyDetector.isSpike(recent: 500_000, baseline: 0))        // 低于 1 MB/s
        XCTAssertFalse(AnomalyDetector.isSpike(recent: 5_000_000, baseline: 2_000_000)) // 只有 2.5×
    }

    func testSuppressionRule() {
        let a = NetworkAlert(date: Date(), kind: .plaintext, appKey: "A", appName: "A", detail: "", dedupKey: "x")
        XCTAssertTrue(SuppressionRule(kind: .plaintext).matches(a))
        XCTAssertTrue(SuppressionRule(kind: .plaintext, appKey: "A").matches(a))
        XCTAssertFalse(SuppressionRule(kind: .plaintext, appKey: "B").matches(a))
        XCTAssertFalse(SuppressionRule(kind: .beacon).matches(a))
    }

    func testPrivacyScoreExplainsPenalties() {
        var s = NetworkState()
        s.flows = [flow("A", remote: "8.8.8.8", port: 80),
                   FlowInfo(id: "l", appKey: "B", appName: "B", pid: 2, proto: .tcp, local: Endpoint(address: "*", port: 8080),
                            remote: nil, state: "Listen", scope: .loopback, bytesIn: 0, bytesOut: 0, firstSeen: Date())]
        let score = PrivacyScore.compute(state: s, alerts: [])
        XCTAssertEqual(score.score, 100 - 6 - 2)
        XCTAssertEqual(score.factors.count, 2)
        XCTAssertEqual(PrivacyScore.compute(state: NetworkState(), alerts: []).score, 100)
        // 连接已关闭，但最近的明文告警仍然扣分
        let notice = NetworkAlert(date: Date(), kind: .plaintext, appKey: "A", appName: "A", detail: "", dedupKey: "p")
        XCTAssertEqual(PrivacyScore.compute(state: NetworkState(), alerts: [notice]).score, 97)
    }

    func testRelaySuppressesPlaintextAndBeaconButKeepsRegularApps() {
        let d = AnomalyDetector()
        d.warmup = 0
        let t0 = Date()

        // 1. 网关进程 Bettbox 发起 :80 明文及连续 7 次 60s 规律外连均不触发 .plaintext / .beacon
        var relayAlerts: [AlertKind] = []
        var relayFlows: [FlowInfo] = [
            FlowInfo(id: "bettbox|80", appKey: "/Applications/Bettbox.app", appName: "Bettbox", pid: 10,
                     proto: .tcp, local: Endpoint(address: "10.0.0.1", port: 51000),
                     remote: Endpoint(address: "8.8.8.8", port: 80), state: "Established",
                     scope: .internet, bytesIn: 0, bytesOut: 0, firstSeen: t0)
        ]
        for i in 0..<7 {
            relayFlows.append(
                FlowInfo(id: "bettbox|hb|\(i)", appKey: "/Applications/Bettbox.app", appName: "Bettbox", pid: 10,
                         proto: .tcp, local: Endpoint(address: "10.0.0.1", port: UInt16(52000 + i)),
                         remote: Endpoint(address: "5.6.7.8", port: 443), state: "Established",
                         scope: .internet, bytesIn: 0, bytesOut: 0, firstSeen: t0)
            )
            relayAlerts += d.evaluate(state: state(relayFlows), devices: [], now: t0.addingTimeInterval(Double(i) * 60)).map(\.kind)
        }
        XCTAssertFalse(relayAlerts.contains(.plaintext))
        XCTAssertFalse(relayAlerts.contains(.beacon))

        // 可疑端口仍对中继进程生效
        let suspiciousFlow = FlowInfo(id: "bettbox|4444", appKey: "/Applications/Bettbox.app", appName: "Bettbox", pid: 10,
                                      proto: .tcp, local: Endpoint(address: "10.0.0.1", port: 53000),
                                      remote: Endpoint(address: "9.9.9.9", port: 4444), state: "Established",
                                      scope: .internet, bytesIn: 0, bytesOut: 0, firstSeen: t0)
        let suspiciousAlerts = d.evaluate(state: state([suspiciousFlow]), devices: [], now: t0.addingTimeInterval(400)).map(\.kind)
        XCTAssertTrue(suspiciousAlerts.contains(.suspiciousPort))

        // 2. 普通应用仍照常触发 .plaintext 与 .beacon
        var regularAlerts: [AlertKind] = []
        var regularFlows: [FlowInfo] = [flow("AppA", remote: "8.8.8.8", port: 80, local: 60000)]
        for i in 0..<7 {
            regularFlows.append(flow("AppA", remote: "5.6.7.9", port: 8443, local: UInt16(61000 + i)))
            regularAlerts += d.evaluate(state: state(regularFlows), devices: [], now: t0.addingTimeInterval(Double(i) * 60)).map(\.kind)
        }
        XCTAssertTrue(regularAlerts.contains(.plaintext))
        XCTAssertTrue(regularAlerts.contains(.beacon))
    }
}

final class LANTests: XCTestCase {
    func testParseARP() {
        let text = """
        ? (192.168.50.1) at a0:36:bc:71:70:d8 on en7 ifscope [ethernet]
        ? (192.168.50.61) at cc:b8:a8:4:4c:2e on en7 ifscope [ethernet]
        ? (192.168.50.77) at (incomplete) on en7 ifscope [ethernet]
        ? (192.168.50.255) at ff:ff:ff:ff:ff:ff on en7 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en7 ifscope permanent [ethernet]
        """
        let e = LANScanner.parseARP(text)
        XCTAssertEqual(e.map(\.ip), ["192.168.50.1", "192.168.50.61"])
        XCTAssertEqual(e[1].mac, "cc:b8:a8:04:4c:2e")
        XCTAssertEqual(e[0].interface, "en7")
    }

    func testOUIVendorAndRandomizedMAC() {
        // 00:03:93 为 Apple 的注册前缀（IEEE 公开注册表）。
        XCTAssertEqual(OUIDatabase.shared.vendor(for: "00:03:93:12:34:56")?.hasPrefix("Apple"), true)
        XCTAssertNil(OUIDatabase.shared.vendor(for: "56:f7:92:89:1b:50"))
        let d = LANDevice(ip: "1.2.3.4", mac: "56:f7:92:89:1b:50", interface: "en0", isGateway: false, vendor: nil, firstSeen: Date())
        XCTAssertTrue(d.isRandomizedMAC)
        XCTAssertNotNil(LANScanner.defaultGateway())
    }
}
