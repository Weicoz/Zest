//
//  DiskHealth.swift
//  Zest
//
//  内置 NVMe 盘 SMART 健康：解析 `diskutil info -plist` 的纯函数，加后台读取。
//  NVMe 的 DATA_UNITS_WRITTEN 以 512000 字节为单位，TEMPERATURE 为开尔文。
//

import Foundation

struct DiskHealth: Equatable {
    enum Status: Equatable { case verified, failing, other(String) }
    var status: Status
    var percentUsed: Int?
    var bytesWritten: UInt64?
    var temperatureC: Double?
}

enum DiskHealthResult: Equatable {
    case health(DiskHealth)
    /// 外置盘或磁盘未提供 SMART。
    case unsupported
    case failed(String)
}

enum DiskHealthParser {
    static func parse(_ data: Data) -> DiskHealthResult {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return .failed(L10n.text("无法解析 diskutil 输出"))
        }
        guard (dict["Internal"] as? Bool) == true,
              let raw = dict["SMARTStatus"] as? String, raw != "Not Supported", !raw.isEmpty else { return .unsupported }
        let status: DiskHealth.Status = raw == "Verified" ? .verified : (raw == "Failing" ? .failing : .other(raw))
        let nvme = dict["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
        // 负数或超出 Int64 的值按缺失处理
        func int(_ k: String) -> Int? { (nvme[k] as? NSNumber).flatMap { Int(exactly: $0.int64Value) == nil || $0.int64Value < 0 ? nil : Int($0.int64Value) } }
        return .health(DiskHealth(
            status: status,
            percentUsed: int("PERCENTAGE_USED"),
            bytesWritten: int("DATA_UNITS_WRITTEN_0").flatMap { UInt64($0).multipliedReportingOverflow(by: 512_000) }.flatMap { $0.overflow ? nil : $0.partialValue },
            temperatureC: int("TEMPERATURE").map { Double($0) - 273.15 }))
    }
}

enum DiskHealthReader {
    /// 同步读取，调用方放后台队列。shortcut: 固定读 disk0（Apple 芯片内置盘），无 IOKit 回退，见票据偏差。
    static func read(timeout: TimeInterval = 10) -> DiskHealthResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", "disk0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .failed(L10n.text("diskutil 执行失败")) }
        // 超时后终止进程，管道关闭，读取随之返回
        var timedOut = false
        let lock = NSLock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { lock.lock(); timedOut = true; lock.unlock(); p.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        lock.lock(); defer { lock.unlock() }
        if timedOut { return .failed(L10n.text("diskutil 读取超时")) }
        return p.terminationStatus == 0 ? DiskHealthParser.parse(data) : .failed(L10n.text("diskutil 执行失败"))
    }
}
