//
//  DiskHealthTests.swift
//  ZestTests
//
//  接缝 C：diskutil info -plist 夹具（合成数据）解析为健康状态，外置盘与缺字段为「未提供」。
//

import XCTest
@testable import Zest

final class DiskHealthTests: XCTestCase {
    private func plist(isInternal: Bool = true, smart: String? = "Verified", nvme: String = "") -> Data {
        let status = smart.map { "<key>SMARTStatus</key><string>\($0)</string>" } ?? ""
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Internal</key><\(isInternal)/>
        \(status)\(nvme)
        </dict></plist>
        """.utf8)
    }

    private let nvme = """
        <key>SMARTDeviceSpecificKeysMayVaryNotGuaranteed</key><dict>
        <key>PERCENTAGE_USED</key><integer>8</integer>
        <key>DATA_UNITS_WRITTEN_0</key><integer>1000</integer>
        <key>TEMPERATURE</key><integer>325</integer></dict>
        """

    func testInternalNVMeParsesHealth() {
        guard case .health(let h) = DiskHealthParser.parse(plist(nvme: nvme)) else { return XCTFail("应为健康信息") }
        XCTAssertEqual(h.status, .verified)
        XCTAssertEqual(h.percentUsed, 8)
        XCTAssertEqual(h.bytesWritten, 512_000_000)
        XCTAssertEqual(h.temperatureC ?? 0, 51.85, accuracy: 0.01)
    }

    func testMissingNVMeFieldsStayNil() {
        guard case .health(let h) = DiskHealthParser.parse(plist(smart: "Failing")) else { return XCTFail("应为健康信息") }
        XCTAssertEqual(h.status, .failing)
        XCTAssertNil(h.percentUsed)
        XCTAssertNil(h.bytesWritten)
        XCTAssertNil(h.temperatureC)
    }

    func testExternalOrUnsupportedIsUnsupported() {
        XCTAssertEqual(DiskHealthParser.parse(plist(isInternal: false, nvme: nvme)), .unsupported)
        XCTAssertEqual(DiskHealthParser.parse(plist(smart: nil)), .unsupported)
        XCTAssertEqual(DiskHealthParser.parse(plist(smart: "Not Supported")), .unsupported)
    }

    func testNegativeOrHugeValuesDoNotCrash() {
        let bad = """
            <key>SMARTDeviceSpecificKeysMayVaryNotGuaranteed</key><dict>
            <key>PERCENTAGE_USED</key><integer>-5</integer>
            <key>DATA_UNITS_WRITTEN_0</key><integer>-1</integer>
            <key>TEMPERATURE</key><integer>-1</integer></dict>
            """
        guard case .health(let h) = DiskHealthParser.parse(plist(nvme: bad)) else { return XCTFail("应为健康信息") }
        XCTAssertNil(h.percentUsed)
        XCTAssertNil(h.bytesWritten)
        XCTAssertNil(h.temperatureC)
        let huge = bad.replacingOccurrences(of: "<integer>-1</integer></dict>", with: "<integer>9223372036854775807</integer></dict>")
            .replacingOccurrences(of: "<key>DATA_UNITS_WRITTEN_0</key><integer>-1</integer>", with: "<key>DATA_UNITS_WRITTEN_0</key><integer>9223372036854775807</integer>")
        guard case .health(let g) = DiskHealthParser.parse(plist(nvme: huge)) else { return XCTFail("应为健康信息") }
        XCTAssertNil(g.bytesWritten)
    }

    func testGarbageFails() {
        guard case .failed = DiskHealthParser.parse(Data("x".utf8)) else { return XCTFail("应为失败") }
    }
}
