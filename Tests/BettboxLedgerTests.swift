//
//  BettboxLedgerTests.swift
//  ZestTests
//
//  接缝 A：链路账本核心。内联 JSON 合成夹具，不含真实域名、进程或 secret。
//

import XCTest
@testable import Zest

final class BettboxLedgerTests: XCTestCase {
    private func conn(_ id: String, down: Int64, up: Int64, type: String = "HTTPS", chains: String = #""node-a","group-a""#,
                      rule: String = "RuleSet", payload: String = "p1", app: String = "app1") -> String {
        """
        {"id":"\(id)","download":\(down),"upload":\(up),"chains":[\(chains)],"rule":"\(rule)","rulePayload":"\(payload)",
         "metadata":{"type":"\(type)","host":"h.example.test","destinationIP":"192.0.2.1","destinationPort":"443","process":"\(app)"}}
        """
    }

    private func payload(down: Int64, up: Int64, _ conns: [String]) throws -> BettboxPayload {
        let json = #"{"downloadTotal":\#(down),"uploadTotal":\#(up),"connections":[\#(conns.joined(separator: ","))]}"#
        return try JSONDecoder().decode(BettboxPayload.self, from: Data(json.utf8))
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testInnerConnectionsAreExcluded() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 0, up: 0, [conn("a", down: 0, up: 0), conn("i", down: 0, up: 0, type: "Inner")]), at: at(0))
        l.ingest(try payload(down: 300, up: 30, [conn("a", down: 100, up: 10), conn("i", down: 200, up: 20, type: "inner")]), at: at(2))
        XCTAssertEqual(l.links.map(\.id), ["a"])
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 100, up: 10))
        XCTAssertEqual(l.unattributed, LedgerTraffic(down: 200, up: 20))   // Inner 的字节只留在总量差额里
    }

    func testNewAndClosedConnections() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 1000, up: 100, [conn("a", down: 1000, up: 100)]), at: at(0))   // 基线，不计入
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic())
        l.ingest(try payload(down: 1150, up: 115, [conn("a", down: 1100, up: 100), conn("b", down: 50, up: 15)]), at: at(2))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 150, up: 15))   // a 增 100，新连接 b 从 0 起算
        XCTAssertEqual(l.links.first { $0.id == "b" }?.downRate, 25)
        l.ingest(try payload(down: 1250, up: 115, [conn("b", down: 150, up: 15)]), at: at(4))   // a 已关闭
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 250, up: 15))
        XCTAssertEqual(l.links.map(\.id), ["b"])
        XCTAssertEqual(l.unattributed, LedgerTraffic())
    }

    func testCounterResetCountsFromZero() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 500, up: 0, [conn("a", down: 500, up: 0)]), at: at(0))
        l.ingest(try payload(down: 560, up: 0, [conn("a", down: 40, up: 0)]), at: at(2))   // 同 id 累计变小
        XCTAssertEqual(l.byApp["app1"]?.down, 40)
        XCTAssertEqual(l.unattributed.down, 20)
    }

    func testBettboxRestartHasNoNegativeOrJump() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 9_000_000, up: 800_000, [conn("a", down: 100, up: 10)]), at: at(0))
        // 重启：自报总量清零且大于逐连接之和（含已关闭连接），旧连接消失；未归属仍记 0。
        l.ingest(try payload(down: 100, up: 10, [conn("n", down: 70, up: 7)]), at: at(2))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 70, up: 7))
        XCTAssertEqual(l.unattributed, LedgerTraffic())
        l.ingest(try payload(down: 120, up: 12, [conn("n", down: 90, up: 9)]), at: at(4))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 90, up: 9))
        XCTAssertEqual(l.unattributed, LedgerTraffic())
    }

    func testNegativeUnattributedIsZero() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 0, up: 0, [conn("a", down: 0, up: 0)]), at: at(0))
        // 逐连接增量 100 大于总量增量 60：未归属记 0，不回填。
        l.ingest(try payload(down: 60, up: 50, [conn("a", down: 100, up: 20)]), at: at(2))
        XCTAssertEqual(l.unattributed, LedgerTraffic(down: 0, up: 30))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 100, up: 20))
    }

    func testExitIsOutboundNodeAndDirectIsRecognized() throws {
        var l = TrafficLedger()
        let direct = conn("d", down: 0, up: 0, chains: #""direct""#, rule: "Match", payload: "")
        let viaGroup = conn("g", down: 0, up: 0, chains: #""node-a","group-a","group-top""#)
        l.ingest(try payload(down: 0, up: 0, [direct, viaGroup]), at: at(0))
        let d2 = conn("d", down: 10, up: 0, chains: #""direct""#, rule: "Match", payload: "")
        let g2 = conn("g", down: 20, up: 0, chains: #""node-a","group-a","group-top""#)
        l.ingest(try payload(down: 30, up: 0, [d2, g2]), at: at(2))
        XCTAssertEqual(l.byExit["DIRECT"]?.down, 10)
        XCTAssertEqual(l.byExit["node-a"]?.down, 20)
        XCTAssertEqual(l.byRule["Match"]?.down, 10)
        XCTAssertEqual(l.links.first { $0.id == "g" }?.chain, ["group-top", "group-a", "node-a"])
    }

    func testResumeAfterOutageStartsNewBaseline() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 0, up: 0, [conn("a", down: 0, up: 0)]), at: at(0))
        l.ingest(try payload(down: 100, up: 10, [conn("a", down: 100, up: 10)]), at: at(2))
        l.interrupt()   // Bettbox 不可用
        XCTAssertTrue(l.links.isEmpty)
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 100, up: 10))   // 累计保留
        // 停机期间 a 与总量都涨了；恢复后的第一份只作基线。
        l.ingest(try payload(down: 5_000, up: 500, [conn("a", down: 4_000, up: 400)]), at: at(60))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 100, up: 10))
        XCTAssertEqual(l.unattributed, LedgerTraffic())
        XCTAssertEqual(l.links.first?.downRate, 0)
        l.ingest(try payload(down: 5_050, up: 505, [conn("a", down: 4_050, up: 405)]), at: at(62))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 150, up: 15))
    }
}

final class BettboxConfigTests: XCTestCase {
    private func client(_ cfg: String) throws -> BettboxClient { try BettboxClient.make(config: cfg).get() }
    private func url(_ cfg: String) throws -> String? { try client(cfg).request().url?.absoluteString }
    private func auth(_ cfg: String) throws -> String? { try client(cfg).request().value(forHTTPHeaderField: "Authorization") }
    private func failure(_ cfg: String) -> BettboxConfigError? {
        if case .failure(let e) = BettboxClient.make(config: cfg) { return e }
        return nil
    }

    func testWildcardHostsUseLoopback() throws {
        XCTAssertEqual(try url("external-controller: 0.0.0.0:9090\n"), "http://127.0.0.1:9090/connections")
        XCTAssertEqual(try url("external-controller: ':9091'\n"), "http://127.0.0.1:9091/connections")
        XCTAssertEqual(try url("external-controller: \"[::]:9092\"\n"), "http://127.0.0.1:9092/connections")
        XCTAssertEqual(try url("external-controller: localhost:9093\n"), "http://localhost:9093/connections")
        XCTAssertEqual(try url("external-controller: 127.0.0.5:9094\n"), "http://127.0.0.5:9094/connections")
        XCTAssertEqual(try url("external-controller: '[::1]:9095'\n"), "http://[::1]:9095/connections")
    }

    func testQuotedAndCommentedValues() throws {
        let q = "external-controller: '127.0.0.1:9090' # c\nsecret: \"ab # cd\" # note\n"
        XCTAssertEqual(try auth(q), "Bearer ab # cd")
        XCTAssertEqual(try auth("external-controller: 127.0.0.1:9090 # c\nsecret: abc # note\n"), "Bearer abc")
        XCTAssertEqual(try url("external-controller: 127.0.0.1:9090 # c\n"), "http://127.0.0.1:9090/connections")
        XCTAssertNil(try auth("external-controller: 127.0.0.1:9090\nsecret: ''\n"))
        XCTAssertNil(try auth("external-controller: 127.0.0.1:9090\n"))
    }

    func testMissingControllerOrBadPort() {
        XCTAssertEqual(failure("secret: x\n"), .missing)
        XCTAssertEqual(failure("external-controller: 127.0.0.1:0\n"), .missing)
        XCTAssertEqual(failure("external-controller: 127.0.0.1:65536\n"), .missing)
        XCTAssertEqual(failure("external-controller: 127.0.0.1:abc\n"), .missing)
        XCTAssertEqual(failure("external-controller: 127.0.0.1\n"), .missing)
    }

    func testNonLoopbackIsRefused() {
        XCTAssertEqual(failure("external-controller: 192.0.2.7:9090\nsecret: x\n"), .nonLocal)
        XCTAssertEqual(failure("external-controller: ctl.example.test:9090\n"), .nonLocal)
        XCTAssertEqual(failure("external-controller: 128.0.0.1:9090\n"), .nonLocal)
        XCTAssertEqual(failure("external-controller: 127.0.0.1.example.test:9090\n"), .nonLocal)
    }
}
