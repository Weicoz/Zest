//
//  AppDelegate.swift
//  Zest
//

import AppKit
import Combine
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let store = MonitorStore()
    private let engine = MonitorEngine()
    private lazy var network = NetworkMonitor(settings: settings, role: AppDelegate.isNetworkViewer ? .viewer : .primary)
    private(set) var networkWindow: NetworkWindowController?
    /// 独立的“网络监控”窗口进程。
    private var viewerProcess: Process?
    private var parentWatcher: DispatchSourceProcess?
    /// 独立的“磁盘”窗口进程与主进程的磁盘采样服务。
    private var diskProcess: Process?
    private var diskWindow: DiskWindowController?
    private let diskService = DiskIOService()
    private let nodeService = NodeMonitorService()
    private let nodeSummary = NodeSummaryStore()
    private let processes = ProcessMonitor()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    /// 只在菜单栏进程启动。网络窗口进程与测试进程不检查更新。
    private var updaterController: SPUStandardUpdaterController?
    private var quickTools: QuickToolsController?
    private var cancellables = Set<AnyCancellable>()
    private var screensAsleep = false
    private var applicationExitObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?

    static var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// 以 `--network-window` 启动时作为独立的“网络监控”窗口进程运行：
    /// 不创建菜单栏图标，窗口关闭即退出，从而把 SwiftUI / 图表占用的内存完整归还系统。
    static let isNetworkViewer = CommandLine.arguments.contains("--network-window")
    /// 以 `--disk-window` 启动时作为独立的“磁盘”窗口进程运行（只读库，关窗即退出）。
    static let isDiskViewer = CommandLine.arguments.contains("--disk-window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppDelegate.isRunningTests else { return }
        installMainMenu()
        observeLanguageChanges()
        PerformanceLog.shared.event("start", ["refresh_seconds": settings.refreshInterval,
            "network_monitoring": settings.networkMonitoring,
            "process_refresh_seconds": processes.interval,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"])
        if AppDelegate.isNetworkViewer {
            launchAsNetworkViewer()
            return
        }
        if AppDelegate.isDiskViewer {
            launchAsDiskViewer()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let feedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Bundle.main.object(forInfoDictionaryKey: "ZestCustomBuild") as? Bool != true, !feedURL.isEmpty {
            updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        let tools = QuickToolsController(settings: settings)
        quickTools = tools
        tools.closePanel = { [weak self] in self?.statusItem?.closePanel() }
        tools.start()

        // 网络监控窗口进程修改了告警或忽略规则：重新加载。
        DistributedNotificationCenter.default().addObserver(
            forName: NetworkMonitor.alertsChangedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.settings.reloadSuppressions()
            self?.network.reloadAlertsFromStore()
        }
        // 节点监测配置变更与手动触发探测（来自网络监控窗口或设置窗口，优先从 userInfo 读取避开 cfprefsd 竞态）。
        DistributedNotificationCenter.default().addObserver(
            forName: AppSettings.nodeProbeSettingsChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.settings.reloadNodeProbeSettings(note)
            self.syncNodeServiceConfig()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NodeMonitorService.triggerActiveProbeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.settings.reloadNodeProbeSettings(note)
            self.syncNodeServiceConfig()
            let adHoc = note.userInfo?["adHocGroup"] as? String
            self.nodeService.triggerActiveProbeNow(adHocGroup: adHoc)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NodeMonitorService.cancelActiveProbeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.nodeService.cancelProbesByUser()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NodeMonitorService.queryProbeProgressNotification, object: nil, queue: .main) { [weak self] _ in
            self?.nodeService.rebroadcastProgress()
        }

        statusItem = StatusItemController(store: store, settings: settings, network: network, processes: processes,
                                          openSettings: { [weak self] in self?.openSettings() },
                                          openNetworkWindow: { [weak self] page in self?.openNetworkWindow(page: page) },
                                          openDiskWindow: { [weak self] in self?.openDiskWindow() },
                                          tools: tools, nodeSummary: nodeSummary)
        statusItem?.onPanelVisibilityChange = { [weak self] visible in
            guard let self else { return }
            let tab = UserDefaults.standard.string(forKey: "panelTab") ?? "overview"
            nodeService.setPanelVisible(visible && tab == "network")
            if visible && tab != "processes" { engine.refreshCapacity() }
            PerformanceLog.shared.event("panel_visibility", ["visible": visible])
            updateSampleOptions()
        }
        statusItem?.onPanelTabChange = { [weak self] tab in
            guard let self else { return }
            self.nodeService.setPanelVisible(self.store.isPanelVisible && tab == .network)
            self.updateSampleOptions()
        }

        store.setCoreKinds(engine.coreKinds)
        engine.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            store.ingest(snapshot)
            statusItem?.update(snapshot: snapshot)
            if let usage = snapshot.selfUsage {
                PerformanceLog.shared.sample(usage, panelVisible: store.isPanelVisible,
                    tab: UserDefaults.standard.string(forKey: "panelTab") ?? "overview",
                    refreshInterval: settings.refreshInterval)
            }
        }
        updateSampleOptions()
        engine.start(interval: settings.refreshInterval)
        network.start()
        diskService.setThresholds(hourGB: settings.writeAlertHourGB, dayGB: settings.writeAlertDayGB)   // 先于 start，队列保序
        diskService.start()
        syncNodeServiceConfig()
        nodeService.onSummary = { [weak self] summary in
            DispatchQueue.main.async { self?.nodeSummary.update(summary) }
        }
        if settings.networkMonitoring { nodeService.start() }
        settings.$writeAlertHourGB.combineLatest(settings.$writeAlertDayGB).sink { [diskService] h, d in
            diskService.setThresholds(hourGB: h, dayGB: d)
        }.store(in: &cancellables)
        Publishers.CombineLatest4(settings.$nodeActiveProbeEnabled, settings.$nodeProbeIntervalMinutes,
                                  settings.$nodeProbeScopes, settings.$nodeGroupAlertEnabled)
            .combineLatest(settings.$nodeGroupWatchIntervalMinutes, settings.$proxyClientSource,
                           settings.$proxyCustomConfigPath)
            .dropFirst()
            .sink { [nodeService] config, watchMinutes, source, customPath in
                let (enabled, interval, scopes, alertEnabled) = config
                nodeService.updateConfig(activeEnabled: enabled, intervalMinutes: interval,
                                         scopes: scopes, groupAlertEnabled: alertEnabled,
                                         watchIntervalMinutes: watchMinutes,
                                         source: source, customConfigPath: customPath)
            }
            .store(in: &cancellables)
        network.onHistoryWillClear = { [nodeService] in nodeService.clearSync() }
        network.onHistoryCleared = { [diskService] in diskService.clear() }
        settings.$networkMonitoring.dropFirst().removeDuplicates().sink { [weak self] on in
            on ? self?.network.start() : self?.network.stop()
            on ? self?.diskService.start() : self?.diskService.stop()
            on ? self?.nodeService.start() : self?.nodeService.stop()
        }.store(in: &cancellables)

        #if PERFORMANCE_TEST
        if CommandLine.arguments.contains("--performance-panel") {
            performancePanelPreference = UserDefaults.standard.object(forKey: "panelTab")
            isPerformanceRun = true
            UserDefaults.standard.set("processes", forKey: "panelTab")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                statusItem?.debugShowPanel()
                print("PERFORMANCE_PANEL visible=\(store.isPanelVisible)")
                fflush(stdout)
            }
        }
        #endif

        #if DEBUG
        if ProcessInfo.processInfo.environment["ZEST_DEBUG_LAYOUT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in statusItem?.debugShowPanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
        }
        if ProcessInfo.processInfo.environment["ZEST_DEBUG_WINDOW_CYCLE"] != nil {
            // 打开网络监控窗口 20 秒后关闭，再观察 20 秒，用于检查关闭后内存是否回落。
            func footprint() -> String {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
                _ = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                return "\(info.phys_footprint / 1_048_576) MB"
            }
            print("启动后: \(footprint())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
                print("打开窗口前（菜单栏进程）: \(footprint())")
                openNetworkWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
                    print("窗口打开 20 秒（菜单栏进程）: \(footprint())，窗口进程 pid \(viewerProcess?.processIdentifier ?? 0)")
                    viewerProcess?.terminate()
                    for delay in [2.0, 10, 45] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            print("关闭后 \(Int(delay)) 秒: \(footprint())")
                            if delay == 45 { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["ZEST_DEBUG_NETWORK_WINDOW"] {
            presentNetworkWindowInProcess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [self] in
                SnapshotExporter.captureWindows(to: URL(fileURLWithPath: dir), page: networkWindow) { NSApp.terminate(nil) }
            }
        }
        if let dir = SnapshotExporter.outputDirectory {
            UserDefaults.standard.set("overview", forKey: "panelTab")
            store.isPanelVisible = true
            updateSampleOptions()
            network.setVisible(true)
            nodeService.refreshPanelSummaryNow()
            processes.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [self] in
                SnapshotExporter.export(store: store, settings: settings, network: network, processes: processes, nodeSummary: nodeSummary, to: dir)
                NSApp.terminate(nil)
            }
        }
        #endif

        settings.$refreshInterval.dropFirst().removeDuplicates().sink { [weak self] interval in
            guard let self, !screensAsleep else { return }
            engine.start(interval: interval)
        }.store(in: &cancellables)

        Publishers.Merge(settings.$menuBarEntries.map { _ in () },
                         settings.$temperatureUnit.map { _ in () })
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                updateSampleOptions()
                statusItem?.forceRedraw(snapshot: store.snapshot)
            }.store(in: &cancellables)

        // 菜单栏图片按上一帧内容缓存；语言变化时必须强制重画，并同步刷新应用主菜单语言。
        settings.$appLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                statusItem?.forceRedraw(snapshot: store.snapshot)
                installMainMenu()
            }.store(in: &cancellables)

        // 屏幕休眠/锁屏时暂停采样，节省电量。
        let ws = NSWorkspace.shared.notificationCenter
        applicationExitObserver = ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                  object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            PerformanceLog.shared.event("application_exit", ["target_pid": app.processIdentifier,
                "bundle_id": app.bundleIdentifier ?? "unknown"])
        }
        ws.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// 菜单栏进程和网络窗口进程都订阅。收到后重新读取语言，@Published 会刷新 SwiftUI。
    private func observeLanguageChanges() {
        guard languageObserver == nil else { return }
        languageObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppSettings.languageChangedNotification, object: nil, queue: .main) { [weak self] note in
                self?.settings.reloadLanguage(note)
                self?.installMainMenu()
            }
        if AppDelegate.isNetworkViewer {
            DistributedNotificationCenter.default().addObserver(
                forName: AppSettings.nodeProbeSettingsChangedNotification, object: nil, queue: .main) { [weak self] note in
                    self?.settings.reloadNodeProbeSettings(note)
                }
        }
    }

    /// 只有菜单栏显示温度/风扇或面板打开时才读取 SMC。
    private func updateSampleOptions() {
        let overviewVisible = store.isPanelVisible &&
            (UserDefaults.standard.string(forKey: "panelTab") ?? "overview") == "overview"
        let needsSensors = overviewVisible || settings.enabledItems.contains { $0.needsSensors }
        engine.setOptions(SampleOptions(sensors: needsSensors))
    }

    @objc private func screensDidSleep() {
        guard !screensAsleep else { return }
        screensAsleep = true
        engine.stop()
        nodeService.setPaused(true)
    }

    @objc private func screensDidWake() {
        guard screensAsleep else { return }
        screensAsleep = false
        store.resetHistory()
        engine.start(interval: settings.refreshInterval)
        nodeService.setPaused(false)
    }

    private func syncNodeServiceConfig() {
        nodeService.updateConfig(activeEnabled: settings.nodeActiveProbeEnabled,
                                 intervalMinutes: settings.nodeProbeIntervalMinutes,
                                 scopes: settings.nodeProbeScopes,
                                 groupAlertEnabled: settings.nodeGroupAlertEnabled,
                                 watchIntervalMinutes: settings.nodeGroupWatchIntervalMinutes,
                                 source: settings.proxyClientSource,
                                 customConfigPath: settings.proxyCustomConfigPath)
    }

    #if PERFORMANCE_TEST
    private var performancePanelPreference: Any?
    private var isPerformanceRun = false
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        quickTools?.stop()
        #if PERFORMANCE_TEST
        if isPerformanceRun {
            if let performancePanelPreference {
                UserDefaults.standard.set(performancePanelPreference, forKey: "panelTab")
            } else {
                UserDefaults.standard.removeObject(forKey: "panelTab")
            }
        }
        #endif
        network.flushSync()
        network.stop()
        nodeService.stop()
        diskService.flushSync()
        viewerProcess?.terminate()
        diskProcess?.terminate()
        PerformanceLog.shared.event("stop")
        PerformanceLog.shared.flush()
    }

    /// 打开网络监控：启动（或激活已在运行的）独立窗口进程；传入 page 时直达对应页签。
    private func openNetworkWindow(page: NetworkPage? = nil) {
        if let page {
            UserDefaults.standard.set(page.rawValue, forKey: "networkPage")
        }
        if let running = viewerProcess, running.isRunning {
            if let page {
                DistributedNotificationCenter.default().postNotificationName(
                    NetworkWindowView.selectPageNotification, object: nil,
                    userInfo: ["page": page.rawValue], deliverImmediately: true)
            }
            NSRunningApplication(processIdentifier: running.processIdentifier)?.activate(options: [.activateAllWindows])
            return
        }
        guard let executable = Bundle.main.executableURL else { return }
        let seedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zest-live-seed-\(UUID().uuidString).json")
        network.exportLiveSeed(to: seedURL)
        let task = Process()
        task.executableURL = executable
        task.arguments = ["--network-window", "--live-seed", seedURL.path]
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.viewerProcess = nil
                self?.engine.setChildProcesses([])
                self?.settings.reloadSuppressions()
                self?.network.reloadAlertsFromStore()
                self?.network.markAlertsRead()
            }
        }
        do {
            try task.run()
            viewerProcess = task
            engine.setChildProcesses([task.processIdentifier])
        } catch {
            try? FileManager.default.removeItem(at: seedURL)
            // 无法启动独立进程时退回到本进程内打开。
            presentNetworkWindowInProcess()
            if let page {
                DistributedNotificationCenter.default().postNotificationName(
                    NetworkWindowView.selectPageNotification, object: nil,
                    userInfo: ["page": page.rawValue], deliverImmediately: true)
            }
        }
    }

    /// 打开磁盘窗口：启动（或激活已在运行的）独立窗口进程，并把磁盘采样提到 2 秒。
    private func openDiskWindow() {
        if let running = diskProcess, running.isRunning {
            NSRunningApplication(processIdentifier: running.processIdentifier)?.activate(options: [.activateAllWindows])
            return
        }
        guard let executable = Bundle.main.executableURL else { return }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["--disk-window"]
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.diskProcess = nil
                self?.diskService.setWindowVisible(false)
            }
        }
        do {
            try task.run()
            diskProcess = task
            diskService.setWindowVisible(true)
        } catch {}
    }

    private func launchAsDiskViewer() {
        NSApp.setActivationPolicy(.regular)
        let controller = DiskWindowController(settings: settings)
        controller.onClose = { NSApp.terminate(nil) }
        diskWindow = controller
        controller.present()
        let parent = getppid()
        let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        watcher.setEventHandler { NSApp.terminate(nil) }
        watcher.resume()
        parentWatcher = watcher
        if parent == 1 && ProcessInfo.processInfo.environment["ZEST_DEBUG_DISK_WINDOW"] == nil { NSApp.terminate(nil) }
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["ZEST_DEBUG_DISK_WINDOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [self] in
                SnapshotExporter.captureDiskWindow(to: URL(fileURLWithPath: dir), page: diskWindow) { NSApp.terminate(nil) }
            }
        }
        #endif
    }

    private func presentNetworkWindowInProcess() {
        if networkWindow == nil { networkWindow = NetworkWindowController(monitor: network, settings: settings) }
        networkWindow?.present()
    }

    // MARK: 网络监控窗口进程

    private func launchAsNetworkViewer() {
        NSApp.setActivationPolicy(.regular)
        if let seedIdx = CommandLine.arguments.firstIndex(of: "--live-seed"),
           seedIdx + 1 < CommandLine.arguments.count {
            let seedPath = CommandLine.arguments[seedIdx + 1]
            network.preloadLiveSeed(from: URL(fileURLWithPath: seedPath))
        }
        network.start()
        let controller = NetworkWindowController(monitor: network, settings: settings)
        controller.onClose = { NSApp.terminate(nil) }
        networkWindow = controller
        controller.present()
        // 菜单栏主进程退出时随之退出，不残留窗口进程。
        let parent = getppid()
        let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        watcher.setEventHandler { NSApp.terminate(nil) }
        watcher.resume()
        parentWatcher = watcher
        if parent == 1 && ProcessInfo.processInfo.environment["ZEST_DEBUG_NETWORK_WINDOW"] == nil { NSApp.terminate(nil) }
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["ZEST_DEBUG_NETWORK_WINDOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [self] in
                SnapshotExporter.captureWindows(to: URL(fileURLWithPath: dir), page: networkWindow) { NSApp.terminate(nil) }
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppDelegate.isNetworkViewer || AppDelegate.isDiskViewer
    }

    private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, network: network, updater: updaterController?.updater, tools: quickTools)
        }
        settingsWindow?.present()
    }

    private func installMainMenu() {
        let menu = AppDelegate.makeMainMenu()
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.last?.submenu
    }

    /// 主进程（菜单栏/设置）、独立网络监控窗口进程与磁盘窗口进程共用标准主菜单：
    /// 无 NIB 的纯代码菜单栏应用缺省没有 Edit 菜单，会导致 ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 无法经 First Responder 路由到文本框与可选文本。
    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Zest Plus")
        appMenu.addItem(withTitle: L10n.text("menu.hide", defaultValue: "隐藏 Zest Plus"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.text("menu.hideOthers", defaultValue: "隐藏其他"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L10n.text("menu.showAll", defaultValue: "全部显示"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("menu.quit", defaultValue: "退出 Zest Plus"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // 编辑菜单：target 保持 nil，全部走 First Responder 响应链。
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text("menu.edit", defaultValue: "编辑"))
        editMenu.addItem(withTitle: L10n.text("menu.undo", defaultValue: "撤销"),
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.text("menu.redo", defaultValue: "重做"),
                                    action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("menu.cut", defaultValue: "剪切"),
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text("menu.copy", defaultValue: "拷贝"),
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("menu.paste", defaultValue: "粘贴"),
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = editMenu.addItem(withTitle: L10n.text("menu.pasteAndMatchStyle", defaultValue: "粘贴并匹配样式"),
                                          action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(withTitle: L10n.text("menu.delete", defaultValue: "删除"),
                         action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("menu.selectAll", defaultValue: "全选"),
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // 窗口菜单
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.text("menu.window", defaultValue: "窗口"))
        windowMenu.addItem(withTitle: L10n.text("menu.closeWindow", defaultValue: "关闭窗口"),
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L10n.text("menu.minimize", defaultValue: "最小化"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }
}
