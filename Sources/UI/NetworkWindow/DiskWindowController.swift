//
//  DiskWindowController.swift
//  Zest
//
//  独立的“磁盘”窗口（独立进程，只读历史库）。关闭窗口即退出进程。
//

import AppKit
import SwiftUI

final class DiskWindowController: NSWindowController, NSWindowDelegate {
    private let settings: AppSettings
    var onClose: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.text("磁盘")
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ZestDiskWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        if window.contentViewController == nil {
            let hosting = NSHostingController(rootView: DiskWindowView(settings: settings))
            hosting.sizingOptions = [.minSize]
            window.contentViewController = hosting
            window.center()
        }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        onClose?()
    }
}
