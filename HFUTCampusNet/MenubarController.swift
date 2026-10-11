import Foundation
import AppKit

public class MenubarController: NSObject, NSMenuDelegate, NetworkSpeedMonitorDelegate {
    public static let shared = MenubarController()

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var networkStatusMenuItem: NSMenuItem!
    private var networkSummaryMenuItem: NSMenuItem!
    private var usedFlowMenuItem: NSMenuItem!
    private var availFlowMenuItem: NSMenuItem!
    private var protMenuItem: NSMenuItem!
    private var balMenuItem: NSMenuItem!
    private var updateTimeMenuItem: NSMenuItem!
    private var toggleWidgetMenuItem: NSMenuItem!
    private var courseParentMenuItem: NSMenuItem!
    private var dormElectricityMenuItem: NSMenuItem!

    private var currentData: CampusNetworkData = CampusNetworkData()
    private var currentSpeedCompact: String = "↓ 0B/s  ↑ 0B/s"
    private var currentDownloadSpeed: String = "0 B/s"
    private var currentUploadSpeed: String = "0 B/s"

    private var carouselTimer: Timer?
    private var carouselToggle: Bool = false

    private override init() {
        super.init()
        setupStatusItem()
        startCarousel()
        NetworkSpeedMonitor.shared.delegate = self
        NetworkSpeedMonitor.shared.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCourseScheduleUpdated),
            name: .courseScheduleDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDormElectricityUpdated),
            name: .dormElectricityDidUpdate,
            object: nil
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "📶 检测网络中..."
            button.imagePosition = .imageLeft
        }

        setupMenu()
        statusItem.menu = menu
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self

        // 1. 顶部单行实时状态（在线状态 + 实时上下行网速合并）
        networkStatusMenuItem = NSMenuItem(title: "🟢 已在线认证  ·  ↓ 0 B/s  ↑ 0 B/s", action: nil, keyEquivalent: "")
        networkStatusMenuItem.isEnabled = false
        menu.addItem(networkStatusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 2. 三大核心服务概览（校园网、宿舍电费、今日课程）
        networkSummaryMenuItem = NSMenuItem(title: "📶 校园网: 检测中...", action: nil, keyEquivalent: "")
        let netSubmenu = NSMenu()

        availFlowMenuItem = NSMenuItem(title: "📶 可用流量: 点击自服务授权查看", action: #selector(loginAction), keyEquivalent: "")
        availFlowMenuItem.target = self
        netSubmenu.addItem(availFlowMenuItem)

        usedFlowMenuItem = NSMenuItem(title: "📊 已用流量: --", action: nil, keyEquivalent: "")
        usedFlowMenuItem.isEnabled = false
        netSubmenu.addItem(usedFlowMenuItem)

        balMenuItem = NSMenuItem(title: "💰 账户余额: --", action: nil, keyEquivalent: "")
        balMenuItem.isEnabled = false
        netSubmenu.addItem(balMenuItem)

        protMenuItem = NSMenuItem(title: "🛡️ 消费保护: --", action: nil, keyEquivalent: "")
        protMenuItem.isEnabled = false
        netSubmenu.addItem(protMenuItem)

        updateTimeMenuItem = NSMenuItem(title: "⏱️ 上次更新: 等待初次抓取", action: nil, keyEquivalent: "")
        updateTimeMenuItem.isEnabled = false
        netSubmenu.addItem(updateTimeMenuItem)

        netSubmenu.addItem(NSMenuItem.separator())

        let oneClickLoginItem = NSMenuItem(title: "⚡ 一键登录校园网 (172.18.3.3)", action: #selector(oneClickLoginAction), keyEquivalent: "")
        oneClickLoginItem.target = self
        netSubmenu.addItem(oneClickLoginItem)

        let logoutPortalItem = NSMenuItem(title: "🔌 注销本机网关认证", action: #selector(logoutPortalAction), keyEquivalent: "")
        logoutPortalItem.target = self
        netSubmenu.addItem(logoutPortalItem)

        let loginItem = NSMenuItem(title: "🔑 自服务授权 (获取可用流量/保护)...", action: #selector(loginAction), keyEquivalent: "l")
        loginItem.target = self
        netSubmenu.addItem(loginItem)

        let openWebItem = NSMenuItem(title: "🌍 打开校园网自服务网页...", action: #selector(openWebAction), keyEquivalent: "o")
        openWebItem.target = self
        netSubmenu.addItem(openWebItem)

        networkSummaryMenuItem.submenu = netSubmenu
        menu.addItem(networkSummaryMenuItem)

        dormElectricityMenuItem = NSMenuItem(title: "⚡ 宿舍电费: 加载中...", action: #selector(openElectricityStatsAction), keyEquivalent: "")
        dormElectricityMenuItem.target = self
        menu.addItem(dormElectricityMenuItem)
        updateDormElectricityMenu()

        courseParentMenuItem = NSMenuItem(title: "📚 今日课程: 加载中...", action: nil, keyEquivalent: "")
        let courseSubmenu = NSMenu()
        courseParentMenuItem.submenu = courseSubmenu
        menu.addItem(courseParentMenuItem)
        updateCourseSubmenu()

        menu.addItem(NSMenuItem.separator())

        // 3. 快捷分析与同步操作
        let historyStatsItem = NSMenuItem(title: "📊 用量统计与历史分析...", action: #selector(openHistoryStatsAction), keyEquivalent: "h")
        historyStatsItem.target = self
        menu.addItem(historyStatsItem)

        let unifiedLoginItem = NSMenuItem(title: "🔑 统一身份认证同步...", action: #selector(unifiedLoginAction), keyEquivalent: "u")
        unifiedLoginItem.target = self
        menu.addItem(unifiedLoginItem)

        let refreshItem = NSMenuItem(title: "🔄 立即刷新数据", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // 4. 外观、刷新频率与偏好设置
        let displaySubmenu = NSMenu()

        toggleWidgetMenuItem = NSMenuItem(title: "显示桌面悬浮卡片", action: #selector(toggleWidgetAction), keyEquivalent: "w")
        toggleWidgetMenuItem.target = self
        displaySubmenu.addItem(toggleWidgetMenuItem)

        displaySubmenu.addItem(NSMenuItem.separator())

        let styleHeader = NSMenuItem(title: "状态栏显示模式", action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        displaySubmenu.addItem(styleHeader)

        let styles: [(String, Int)] = [
            ("智能轮播 (流量与网速交替)", 0),
            ("仅显示校园网流量与余额", 1),
            ("仅显示实时下载与上传速度", 2),
            ("并排紧凑显示 (流量 · 网速)", 3)
        ]
        let currentStyle = SettingsManager.shared.menubarStyle
        for (name, val) in styles {
            let item = NSMenuItem(title: "  " + name, action: #selector(changeDisplayStyle(_:)), keyEquivalent: "")
            item.representedObject = val
            item.target = self
            if currentStyle == val {
                item.state = .on
            }
            displaySubmenu.addItem(item)
        }

        displaySubmenu.addItem(NSMenuItem.separator())

        let intervalMenu = NSMenu()
        let intervals: [(String, Double)] = [
            ("1 分钟", 60.0),
            ("3 分钟", 180.0),
            ("5 分钟 (推荐)", 300.0),
            ("10 分钟", 600.0),
            ("30 分钟", 1800.0)
        ]
        let currentInterval = SettingsManager.shared.refreshInterval
        for (name, val) in intervals {
            let item = NSMenuItem(title: name, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.representedObject = val
            item.target = self
            if abs(currentInterval - val) < 1.0 {
                item.state = .on
            }
            intervalMenu.addItem(item)
        }
        let intervalParentItem = NSMenuItem(title: "数据刷新频率", action: nil, keyEquivalent: "")
        intervalParentItem.submenu = intervalMenu
        displaySubmenu.addItem(intervalParentItem)

        let displayParentItem = NSMenuItem(title: "🎨 显示与刷新选项", action: nil, keyEquivalent: "")
        displayParentItem.submenu = displaySubmenu
        menu.addItem(displayParentItem)

        let portalSettingsItem = NSMenuItem(title: "⚙️ 偏好设置...", action: #selector(openPortalSettingsAction), keyEquivalent: ",")
        portalSettingsItem.target = self
        menu.addItem(portalSettingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出校园网监测", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func startCarousel() {
        carouselTimer?.invalidate()
        let interval = SettingsManager.shared.carouselInterval
        carouselTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.carouselTick()
        }
    }

    private func carouselTick() {
        carouselToggle.toggle()
        renderTitle()
    }

    private func updateTopStatusLine() {
        let statusPrefix = currentData.isLoggedIn ? "🟢 已在线" : "🟡 未认证"
        networkStatusMenuItem?.title = "\(statusPrefix)  ·  🚀 ↓ \(currentDownloadSpeed)  ↑ \(currentUploadSpeed)"
    }

    public func speedMonitorDidUpdate(download: String, upload: String, compact: String) {
        currentDownloadSpeed = download
        currentUploadSpeed = upload
        currentSpeedCompact = compact

        updateTopStatusLine()

        let style = SettingsManager.shared.menubarStyle
        if style == 2 || style == 3 || (style == 0 && carouselToggle) {
            renderTitle()
        }
    }

    public func updateData(_ data: CampusNetworkData) {
        currentData = data
        renderTitle()
        updateTopStatusLine()

        let devCount = data.onlineDevices.count
        let devSuffix = devCount > 0 ? " (\(devCount)台在线)" : ""

        if data.availableFlow != "-- M" {
            networkSummaryMenuItem?.title = "📶 校园网: 可用 \(data.formattedAvailable) · 余额 \(data.balance)\(devSuffix)"
            availFlowMenuItem.title = "📶 可用流量: \(data.availableFlow) (\(data.formattedAvailable))"
        } else {
            networkSummaryMenuItem?.title = "📶 校园网: 已用 \(data.formattedUsed) · 余额 \(data.balance)\(devSuffix)"
            availFlowMenuItem.title = "📶 可用流量: 点击自服务授权查看..."
        }
        
        usedFlowMenuItem.title = "📊 已用流量: \(data.usedFlow) (\(data.formattedUsed))"
        balMenuItem.title = "💰 账户余额: \(data.balance)"
        protMenuItem.title = "🛡️ 消费保护: \(data.flowProtection)"

        if let time = data.lastUpdated {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            updateTimeMenuItem.title = "⏱️ 上次更新: \(formatter.string(from: time))"
        }

        rebuildOnlineDevicesSection()
        updateWidgetMenuState()
    }

    private func rebuildOnlineDevicesSection() {
        guard let netSubmenu = networkSummaryMenuItem?.submenu else { return }
        // 移除旧的动态在线设备项 (tag == 9901)
        for item in netSubmenu.items.reversed() where item.tag == 9901 {
            netSubmenu.removeItem(item)
        }

        // 在 updateTimeMenuItem 之后插入在线设备列表
        let baseIdx = netSubmenu.index(of: updateTimeMenuItem)
        guard baseIdx >= 0 else { return }
        var insertIdx = baseIdx + 1

        let sep = NSMenuItem.separator()
        sep.tag = 9901
        netSubmenu.insertItem(sep, at: insertIdx)
        insertIdx += 1

        let devices = currentData.onlineDevices
        let headerTitle = devices.isEmpty ? "📱 在线设备: 暂无或正在加载..." : "📱 当前在线设备 (\(devices.count) 台 · 点击即可强制注销):"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        headerItem.tag = 9901
        netSubmenu.insertItem(headerItem, at: insertIdx)
        insertIdx += 1

        for dev in devices {
            let devItem = NSMenuItem(
                title: "\(dev.displayTitle)  — 🔌 点击注销",
                action: #selector(kickDeviceAction(_:)),
                keyEquivalent: ""
            )
            devItem.target = self
            devItem.representedObject = dev.sessionId
            devItem.toolTip = "上线时间: \(dev.loginTime) | MAC: \(dev.formattedMAC) | 会话ID: \(dev.sessionId)"
            devItem.tag = 9901
            netSubmenu.insertItem(devItem, at: insertIdx)
            insertIdx += 1

            let detailItem = NSMenuItem(
                title: "    ↳ 上线: \(dev.loginTime)  ·  MAC: \(dev.formattedMAC)",
                action: nil,
                keyEquivalent: ""
            )
            detailItem.isEnabled = false
            detailItem.tag = 9901
            netSubmenu.insertItem(detailItem, at: insertIdx)
            insertIdx += 1
        }
    }

    @objc private func kickDeviceAction(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        CampusNetworkClient.shared.kickOnlineDevice(sessionId: sessionId) { success, msg in
            let alert = NSAlert()
            alert.messageText = success ? "设备强制注销成功" : "设备注销失败"
            alert.informativeText = msg
            alert.alertStyle = success ? .informational : .warning
            alert.runModal()
        }
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        let style = SettingsManager.shared.menubarStyle
        let flowTitle: String

        if !currentData.isLoggedIn && (currentData.usedFlow == "-- M" || currentData.usedFlow.isEmpty) {
            flowTitle = "📶 离线/未认证"
        } else if currentData.availableFlow != "-- M" {
            flowTitle = "📶 \(currentData.formattedAvailable) | \(currentData.balance)"
        } else {
            // 网关数据
            flowTitle = "📶 \(currentData.formattedUsed) | \(currentData.balance)"
        }

        switch style {
        case 0:
            if carouselToggle {
                button.title = currentSpeedCompact
            } else {
                button.title = flowTitle
            }
        case 1:
            button.title = flowTitle
        case 2:
            button.title = currentSpeedCompact
        case 3:
            let flowStr = (currentData.availableFlow != "-- M") ? currentData.formattedAvailable : currentData.formattedUsed
            button.title = "📶 \(flowStr) · \(currentSpeedCompact)"
        default:
            button.title = flowTitle
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        updateWidgetMenuState()
        updateCourseSubmenu()
        updateDormElectricityMenu()
        CampusNetworkClient.shared.fetchOnlineDevices()
    }

    private func updateWidgetMenuState() {
        let isShowing = SettingsManager.shared.showDesktopWidget
        toggleWidgetMenuItem.title = isShowing ? "隐藏桌面悬浮卡片" : "显示桌面悬浮卡片"
        toggleWidgetMenuItem.state = isShowing ? .on : .off
    }

    @objc private func onDormElectricityUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.updateDormElectricityMenu()
        }
    }

    private func updateDormElectricityMenu() {
        guard let item = dormElectricityMenuItem else { return }
        if !SettingsManager.shared.isDormConfigured {
            item.title = "⚡ 宿舍电费: 未配置宿舍 (点击前往设置)"
            return
        }
        if let elec = ElectricityService.shared.latestData {
            let warnIcon = elec.isLowBalance ? "⚠️ " : ""
            let daysLeft = CampusHistoryManager.shared.estimatedElectricityDaysRemaining
            let daysStr = (daysLeft != nil) ? " (约余\(daysLeft!)天)" : ""
            item.title = "\(warnIcon)⚡ 宿舍电费: \(elec.displayBalance)\(daysStr) @ \(elec.formattedRoom)"
        } else {
            item.title = "⚡ 宿舍电费: 正在获取数据 (点击刷新)"
        }
    }

    @objc private func unifiedLoginAction() {
        UnifiedLoginWebViewController.shared.showLoginWindow()
    }

    @objc private func openElectricityStatsAction() {
        if !SettingsManager.shared.isDormConfigured {
            SettingsWindowController.shared.showSettings()
            return
        }
        ElectricityService.shared.fetchData { _ in }
        HistoryStatsWindowController.shared.showWindow(mode: 1)
    }

    @objc private func openHistoryStatsAction() {
        HistoryStatsWindowController.shared.showWindow(mode: 0)
    }

    @objc private func changeDisplayStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? Int else { return }
        SettingsManager.shared.menubarStyle = style
        if let parent = sender.menu {
            for item in parent.items where item.action == #selector(changeDisplayStyle(_:)) {
                item.state = (item == sender) ? .on : .off
            }
        }
        renderTitle()
    }

    @objc private func oneClickLoginAction() {
        if SettingsManager.shared.portalPassword.isEmpty {
            SettingsWindowController.shared.showSettings()
            return
        }
        PortalAuthService.shared.login { success, msg in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = success ? "校园网登录成功" : "校园网登录失败"
                alert.informativeText = msg
                alert.alertStyle = success ? .informational : .warning
                alert.runModal()
                if success {
                    CampusNetworkClient.shared.fetchData()
                }
            }
        }
    }

    @objc private func logoutPortalAction() {
        PortalAuthService.shared.logout { success, msg in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "校园网设备注销"
                alert.informativeText = msg
                alert.alertStyle = .informational
                alert.runModal()
                CampusNetworkClient.shared.fetchData()
            }
        }
    }

    @objc private func openPortalSettingsAction() {
        SettingsWindowController.shared.showSettings()
    }

    @objc private func refreshAction() {
        CampusNetworkClient.shared.fetchData()
        ElectricityService.shared.fetchData { _ in }
    }

    @objc private func toggleWidgetAction() {
        DesktopWidgetController.shared.toggleWidget()
        updateWidgetMenuState()
    }

    @objc private func loginAction() {
        LoginWebViewController.shared.showLoginWindow()
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Double else { return }
        CampusNetworkClient.shared.updateInterval(interval)

        if let parent = sender.menu {
            for item in parent.items {
                item.state = (item == sender) ? .on : .off
            }
        }
    }

    @objc private func openWebAction() {
        if let url = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/dashboard") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 课程表更新与交互

    @objc private func onCourseScheduleUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.updateCourseSubmenu()
        }
    }

    private func updateCourseSubmenu() {
        guard let courseParent = courseParentMenuItem, let submenu = courseParent.submenu else { return }
        submenu.removeAllItems()

        let schedule = CourseScheduleService.shared.currentSchedule
        let todayLessons = schedule?.todayLessons() ?? []

        if let schedule = schedule, !schedule.lessons.isEmpty {
            if todayLessons.isEmpty {
                courseParent.title = "📚 今日课程 (今日无课 🎉)"
                let noClassItem = NSMenuItem(title: "🎉 今日暂无排课，享受轻松时光！", action: nil, keyEquivalent: "")
                noClassItem.isEnabled = false
                submenu.addItem(noClassItem)
            } else {
                courseParent.title = "📚 今日课程 (\(todayLessons.count) 节)"
                for lesson in todayLessons {
                    let ongoing = lesson.isOngoing() ? "🟢 " : ""
                    let room = lesson.classroom.map { "@ \($0)" } ?? ""
                    let teacher = lesson.teacher.map { "(\($0))" } ?? ""
                    let title = "\(ongoing)\(lesson.formattedTime)  \(lesson.courseName) \(room) \(teacher)"
                    let item = NSMenuItem(title: title, action: #selector(openCourseTableAction), keyEquivalent: "")
                    item.target = self
                    submenu.addItem(item)
                }
            }
        } else {
            courseParent.title = "📚 教务课表 (未同步)"
            let promptItem = NSMenuItem(title: "点击登录教务系统同步课表...", action: #selector(openCourseLoginAction), keyEquivalent: "")
            promptItem.target = self
            submenu.addItem(promptItem)
        }

        submenu.addItem(NSMenuItem.separator())

        let openTableItem = NSMenuItem(title: "📅 查看完整周课表...", action: #selector(openCourseTableAction), keyEquivalent: "k")
        openTableItem.target = self
        submenu.addItem(openTableItem)

        let refreshCourseItem = NSMenuItem(title: "🔄 立即刷新教务课表", action: #selector(refreshCourseAction), keyEquivalent: "")
        refreshCourseItem.target = self
        submenu.addItem(refreshCourseItem)

        let authCourseItem = NSMenuItem(title: "🔑 教务系统登录/授权 (网页)...", action: #selector(openCourseLoginAction), keyEquivalent: "")
        authCourseItem.target = self
        submenu.addItem(authCourseItem)
    }

    @objc private func openCourseTableAction() {
        CourseScheduleWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openCourseLoginAction() {
        CourseLoginWebViewController.shared.showLoginWindow()
    }

    @objc private func refreshCourseAction() {
        CourseScheduleService.shared.syncSchedule { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let schedule):
                    NotificationHelper.sendNotification(
                        title: "🎉 课表刷新成功",
                        body: "已同步 \(schedule.lessons.count) 节课程安排"
                    )
                case .failure(let error):
                    if let syncErr = error as? CourseScheduleService.CourseSyncError, case .needLogin = syncErr {
                        CourseLoginWebViewController.shared.showLoginWindow()
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "课表同步失败"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
