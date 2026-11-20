//
//  DiskHealthPage.swift
//  Zest
//
//  磁盘窗口「健康」页：打开时读取一次，之后每小时一次，后台队列执行；失败只影响本页。
//

import SwiftUI

@MainActor
final class DiskHealthModel: ObservableObject {
    @Published private(set) var result: DiskHealthResult?
    private let queue = DispatchQueue(label: "app.zest.diskhealth", qos: .utility)
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func reload() {
        queue.async { [weak self] in
            let r = DiskHealthReader.read()
            DispatchQueue.main.async { self?.result = r }
        }
    }
}

struct DiskHealthPage: View {
    @StateObject private var model = DiskHealthModel()

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—").monospacedDigit()
        }
    }

    var body: some View {
        Group {
            switch model.result {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unsupported:
                Text(L10n.text("此磁盘未提供 SMART 健康信息")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let reason):
                Text("\(L10n.text("读取健康信息失败")): \(reason)").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .health(let h):
                VStack(spacing: 10) {
                    row(L10n.text("SMART 状态"), statusText(h.status))
                    row(L10n.text("寿命已用"), h.percentUsed.map { "\($0)%" })
                    row(L10n.text("累计写入"), h.bytesWritten.map { Fmt.bytes(Double($0)) })
                    row(L10n.text("温度"), h.temperatureC.map { String(format: "%.0f °C", $0) })
                    Spacer()
                }
                .font(.system(size: 13))
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func statusText(_ s: DiskHealth.Status) -> String {
        switch s {
        case .verified: return L10n.text("正常")
        case .failing: return L10n.text("异常")
        case .other(let v): return v
        }
    }
}
