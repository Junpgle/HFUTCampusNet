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
    private var emptyClassroomMenuItem: NSMenuItem!
    private var dormElectricityMenuItem: NSMenuItem!
    private var checkUpdateMenuItem: NSMenuItem!
    private var quotaMenuCardView: CampusQuotaCardView?

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
            selector: #selector(onEmptyClassroomUpdated),
            name: .emptyClassroomDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDormElectricityUpdated),
            name: .dormElectricityDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUpdateCheckFinished),
            name: .updateCheckDidFinish,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onHistoryStatsUpdated),
            name: .historyStatsDidUpdate,
            object: nil
        )
    }

    @objc private func onHistoryStatsUpdated() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let todayMB = CampusHistoryManager.shared.todayFlowDeltaMB
            let todayStr = todayMB >= 1024.0
                ? String(format: "%.2f GB", todayMB / 1024.0)
                : String(format: "%.0f MB", todayMB)
            self.availFlowMenuItem?.title = "今日已用：\(todayStr) / 30 GB (单日限额)"
            self.quotaMenuCardView?.refresh(mode: 0)
        }
    }

    private func symbolImage(_ name: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        img?.isTemplate = true
        return img
    }

    private func statusDotImage(color: NSColor, diameter: CGFloat = 7) -> NSImage {
        let canvasSize = NSSize(width: 14, height: 14)
        let img = NSImage(size: canvasSize, flipped: false) { rect in
            let dotRect = NSRect(
                x: (rect.width - diameter) / 2.0,
                y: (rect.height - diameter) / 2.0,
                width: diameter,
                height: diameter
            )
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
            button.image = symbolImage("wifi", pointSize: 12.5, weight: .medium)
            button.imagePosition = .imageLeading
            button.title = " 检测网络中..."
        }

        setupMenu()
        statusItem.menu = menu
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self

        // 1. 顶部单行实时状态（在线状态 + 实时上下行网速合并）
        networkStatusMenuItem = NSMenuItem(title: "已在线认证  ·  ↓ 0 B/s  ↑ 0 B/s", action: nil, keyEquivalent: "")
        networkStatusMenuItem.image = statusDotImage(color: .systemGreen)
        networkStatusMenuItem.isEnabled = false
        menu.addItem(networkStatusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 2. 核心服务概览（校园网、宿舍电费、今日课程、自习教室）
        networkSummaryMenuItem = NSMenuItem(title: "校园网：检测中...", action: nil, keyEquivalent: "")
        networkSummaryMenuItem.image = symbolImage("wifi")
        let netSubmenu = NSMenu()

        // 顶部嵌入「单日限额 30GB / 每月限额 200GB免费·400GB上限」进度卡片（自适应子菜单宽度）
        let quotaContainer = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 112))
        quotaContainer.autoresizingMask = [.width]
        let qCard = CampusQuotaCardView(frame: NSRect(x: 12, y: 4, width: 316, height: 104))
        qCard.autoresizingMask = [.width]
        qCard.isCompactMenuMode = true
        quotaContainer.addSubview(qCard)
        self.quotaMenuCardView = qCard
        let quotaMenuItem = NSMenuItem()
        quotaMenuItem.view = quotaContainer
        netSubmenu.addItem(quotaMenuItem)
        netSubmenu.addItem(NSMenuItem.separator())

        availFlowMenuItem = NSMenuItem(title: "今日已用：-- / 30 GB (单日限额)", action: #selector(openHistoryStatsAction), keyEquivalent: "")
        availFlowMenuItem.target = self
        netSubmenu.addItem(availFlowMenuItem)

        usedFlowMenuItem = NSMenuItem(title: "本月已用：-- / 200 GB (免费额度)", action: nil, keyEquivalent: "")
        usedFlowMenuItem.isEnabled = false
        netSubmenu.addItem(usedFlowMenuItem)

        balMenuItem = NSMenuItem(title: "账户余额：--", action: nil, keyEquivalent: "")
        balMenuItem.isEnabled = false
        netSubmenu.addItem(balMenuItem)

        protMenuItem = NSMenuItem(title: "消费保护：--", action: nil, keyEquivalent: "")
        protMenuItem.isEnabled = false
        netSubmenu.addItem(protMenuItem)

        updateTimeMenuItem = NSMenuItem(title: "上次更新：等待初次抓取", action: nil, keyEquivalent: "")
        updateTimeMenuItem.isEnabled = false
        netSubmenu.addItem(updateTimeMenuItem)

        netSubmenu.addItem(NSMenuItem.separator())

        let oneClickLoginItem = NSMenuItem(title: "一键登录校园网 (172.18.3.3)", action: #selector(oneClickLoginAction), keyEquivalent: "")
        oneClickLoginItem.target = self
        netSubmenu.addItem(oneClickLoginItem)

        let logoutPortalItem = NSMenuItem(title: "注销本机网关认证", action: #selector(logoutPortalAction), keyEquivalent: "")
        logoutPortalItem.target = self
        netSubmenu.addItem(logoutPortalItem)

        let loginItem = NSMenuItem(title: "自服务授权 (获取可用流量/保护)...", action: #selector(loginAction), keyEquivalent: "l")
        loginItem.target = self
        netSubmenu.addItem(loginItem)

        let openWebItem = NSMenuItem(title: "打开校园网自服务网页...", action: #selector(openWebAction), keyEquivalent: "o")
        openWebItem.target = self
        netSubmenu.addItem(openWebItem)

        networkSummaryMenuItem.submenu = netSubmenu
        menu.addItem(networkSummaryMenuItem)

        dormElectricityMenuItem = NSMenuItem(title: "宿舍电费：加载中...", action: #selector(openElectricityStatsAction), keyEquivalent: "")
        dormElectricityMenuItem.image = symbolImage("bolt")
        dormElectricityMenuItem.target = self
        menu.addItem(dormElectricityMenuItem)
        updateDormElectricityMenu()

        courseParentMenuItem = NSMenuItem(title: "今日课程：加载中...", action: nil, keyEquivalent: "")
        courseParentMenuItem.image = symbolImage("calendar")
        let courseSubmenu = NSMenu()
        courseParentMenuItem.submenu = courseSubmenu
        menu.addItem(courseParentMenuItem)
        updateCourseSubmenu()

        emptyClassroomMenuItem = NSMenuItem(title: "自习教室：未设定", action: nil, keyEquivalent: "")
        emptyClassroomMenuItem.image = symbolImage("building.2")
        let emptyRoomSubmenu = NSMenu()
        emptyClassroomMenuItem.submenu = emptyRoomSubmenu
        menu.addItem(emptyClassroomMenuItem)
        updateEmptyClassroomSubmenu()

        menu.addItem(NSMenuItem.separator())

        // 3. 快捷分析与同步操作
        let historyStatsItem = NSMenuItem(title: "用量统计与历史分析...", action: #selector(openHistoryStatsAction), keyEquivalent: "h")
        historyStatsItem.image = symbolImage("chart.bar")
        historyStatsItem.target = self
        menu.addItem(historyStatsItem)

        let unifiedLoginItem = NSMenuItem(title: "统一身份认证同步...", action: #selector(unifiedLoginAction), keyEquivalent: "u")
        unifiedLoginItem.image = symbolImage("person.badge.key")
        unifiedLoginItem.target = self
        menu.addItem(unifiedLoginItem)

        let refreshItem = NSMenuItem(title: "立即刷新数据", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.image = symbolImage("arrow.clockwise")
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
            let item = NSMenuItem(title: name, action: #selector(changeDisplayStyle(_:)), keyEquivalent: "")
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

        let displayParentItem = NSMenuItem(title: "显示与刷新选项", action: nil, keyEquivalent: "")
        displayParentItem.image = symbolImage("slider.horizontal.3")
        displayParentItem.submenu = displaySubmenu
        menu.addItem(displayParentItem)

        let portalSettingsItem = NSMenuItem(title: "偏好设置...", action: #selector(openPortalSettingsAction), keyEquivalent: ",")
        portalSettingsItem.image = symbolImage("gearshape")
        portalSettingsItem.target = self
        menu.addItem(portalSettingsItem)

        checkUpdateMenuItem = NSMenuItem(
            title: "检查软件更新 (v\(UpdateChecker.shared.currentVersion))...",
            action: #selector(checkUpdateAction),
            keyEquivalent: ""
        )
        checkUpdateMenuItem.image = symbolImage("arrow.triangle.2.circlepath")
        checkUpdateMenuItem.target = self
        menu.addItem(checkUpdateMenuItem)

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
        let statusPrefix = currentData.isLoggedIn ? "已在线" : "未认证"
        networkStatusMenuItem?.image = statusDotImage(color: currentData.isLoggedIn ? .systemGreen : .systemOrange)
        networkStatusMenuItem?.title = "\(statusPrefix)  ·  ↓ \(currentDownloadSpeed)   ↑ \(currentUploadSpeed)"
    }

    public func speedMonitorDidUpdate(download: String, upload: String, compact: String) {
        currentDownloadSpeed = download
        currentUploadSpeed = upload
        currentSpeedCompact = compact

        updateTopStatusLine()
        DesktopWidgetController.shared.speedMonitorDidUpdate(download: download, upload: upload, compact: compact)

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
        let devSuffix = devCount > 0 ? " (\(devCount) 台在线)" : ""

        networkSummaryMenuItem?.title = "校园网：已用 \(data.formattedUsed) · 余额 \(data.balance)\(devSuffix)"

        let todayMB = CampusHistoryManager.shared.todayFlowDeltaMB
        let todayStr = todayMB >= 1024.0
            ? String(format: "%.2f GB", todayMB / 1024.0)
            : String(format: "%.0f MB", todayMB)
        availFlowMenuItem.title = "今日已用：\(todayStr) / 30 GB (单日限额)"
        usedFlowMenuItem.title = "本月已用：\(data.formattedUsed) / 200 GB (免费额度 · 400 GB 封顶)"
        balMenuItem.title = "账户余额：\(data.balance)"
        protMenuItem.title = "消费保护：\(data.flowProtection)"

        if let time = data.lastUpdated {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            updateTimeMenuItem.title = "上次更新：\(formatter.string(from: time))"
        }

        rebuildOnlineDevicesSection()
        quotaMenuCardView?.refresh(mode: 0)
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
        let headerTitle = devices.isEmpty ? "在线设备：暂无或正在加载..." : "当前在线设备 (\(devices.count) 台 · 点击即可强制下线)"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        headerItem.tag = 9901
        netSubmenu.insertItem(headerItem, at: insertIdx)
        insertIdx += 1

        for dev in devices {
            let devItem = NSMenuItem(
                title: "\(dev.displayTitle)   点击注销",
                action: #selector(kickDeviceAction(_:)),
                keyEquivalent: ""
            )
            devItem.image = symbolImage(dev.terminalType.contains("移动") ? "iphone" : "laptopcomputer", pointSize: 12)
            devItem.target = self
            devItem.representedObject = dev.sessionId
            devItem.toolTip = "上线时间: \(dev.loginTime) | MAC: \(dev.formattedMAC) | 会话ID: \(dev.sessionId)"
            devItem.tag = 9901
            netSubmenu.insertItem(devItem, at: insertIdx)
            insertIdx += 1

            let macPart = (dev.formattedMAC == "00-00-00-00-00-00" || dev.mac.isEmpty) ? "" : "  ·  MAC: \(dev.formattedMAC)"
            let detailItem = NSMenuItem(
                title: "    上线：\(dev.loginTime)\(macPart)",
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
        let isOffline = !currentData.isLoggedIn && (currentData.usedFlow == "-- M" || currentData.usedFlow.isEmpty)
        let flowTitle: String

        if isOffline {
            flowTitle = " 离线/未认证"
        } else {
            flowTitle = " 已用 \(currentData.formattedUsed) | \(currentData.balance)"
        }

        let wifiIcon = symbolImage(isOffline ? "wifi.slash" : "wifi", pointSize: 12.5, weight: .medium)

        switch style {
        case 0:
            if carouselToggle {
                button.image = nil
                button.title = currentSpeedCompact
            } else {
                button.image = wifiIcon
                button.title = flowTitle
            }
        case 1:
            button.image = wifiIcon
            button.title = flowTitle
        case 2:
            button.image = nil
            button.title = currentSpeedCompact
        case 3:
            button.image = wifiIcon
            button.title = isOffline
                ? " 离线 · \(currentSpeedCompact)"
                : " 已用 \(currentData.formattedUsed) · \(currentSpeedCompact)"
        default:
            button.image = wifiIcon
            button.title = flowTitle
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        updateWidgetMenuState()
        updateCourseSubmenu()
        updateEmptyClassroomSubmenu()
        updateDormElectricityMenu()
        quotaMenuCardView?.refresh(mode: 0)
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
            item.title = "宿舍电费：未配置宿舍 (点击设置)"
            return
        }
        if let elec = ElectricityService.shared.latestData {
            let warnSuffix = elec.isLowBalance ? " · 余额偏低" : ""
            let daysLeft = CampusHistoryManager.shared.estimatedElectricityDaysRemaining
            let daysStr = (daysLeft != nil) ? " (约余 \(daysLeft!) 天)" : ""
            item.title = "宿舍电费：\(elec.displayBalance)\(daysStr) · \(elec.formattedRoom)\(warnSuffix)"
        } else {
            item.title = "宿舍电费：正在获取数据..."
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
        EmptyClassroomService.shared.syncTodayAndTomorrowStudyRooms(forceRefresh: true) { _ in }
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
        courseParent.isHidden = !SettingsManager.shared.courseTableEnabled
        submenu.removeAllItems()

        let schedule = CourseScheduleService.shared.currentSchedule
        let todayLessons = schedule?.todayLessons() ?? []

        if let schedule = schedule, !schedule.lessons.isEmpty {
            if todayLessons.isEmpty {
                courseParent.title = "今日课程：今日无课"
                let noClassItem = NSMenuItem(title: "今日暂无排课", action: nil, keyEquivalent: "")
                noClassItem.isEnabled = false
                submenu.addItem(noClassItem)
            } else {
                courseParent.title = "今日课程：\(todayLessons.count) 节课"
                for lesson in todayLessons {
                    let room = lesson.classroom.map { "· \($0)" } ?? ""
                    let teacher = lesson.teacher.map { "(\($0))" } ?? ""
                    let title = "\(lesson.formattedTime)  \(lesson.courseName) \(room) \(teacher)"
                    let item = NSMenuItem(title: title, action: #selector(openCourseTableAction), keyEquivalent: "")
                    if lesson.isOngoing() {
                        item.image = statusDotImage(color: .systemGreen)
                    }
                    item.target = self
                    submenu.addItem(item)
                }
            }
        } else {
            courseParent.title = "教务课表：未同步"
            let promptItem = NSMenuItem(title: "点击登录教务系统同步课表...", action: #selector(openCourseLoginAction), keyEquivalent: "")
            promptItem.target = self
            submenu.addItem(promptItem)
        }

        submenu.addItem(NSMenuItem.separator())

        let openTableItem = NSMenuItem(title: "查看完整周课表...", action: #selector(openCourseTableAction), keyEquivalent: "k")
        openTableItem.target = self
        submenu.addItem(openTableItem)

        let refreshCourseItem = NSMenuItem(title: "立即刷新教务课表", action: #selector(refreshCourseAction), keyEquivalent: "")
        refreshCourseItem.target = self
        submenu.addItem(refreshCourseItem)

        let authCourseItem = NSMenuItem(title: "教务系统登录与授权...", action: #selector(openCourseLoginAction), keyEquivalent: "")
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
                        title: "课表刷新成功",
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

    // MARK: - 自习空教室查询与推荐

    @objc private func onEmptyClassroomUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.updateEmptyClassroomSubmenu()
        }
    }

    private func updateEmptyClassroomSubmenu() {
        guard let emptyParent = emptyClassroomMenuItem, let submenu = emptyParent.submenu else { return }
        submenu.removeAllItems()

        let service = EmptyClassroomService.shared
        let nowMin = EmptyClassroomService.currentMinutesOfDay()

        if let record = SettingsManager.shared.currentStudyRoom {
            if let liveRoom = service.currentStudyRoomItem() {
                let (conflict, isOngoing, minsUntil, switches) = service.nearbySwitchRecommendations(for: liveRoom, limit: 4)
                if let occ = conflict, isOngoing {
                    emptyParent.title = "自习教室：\(liveRoom.nameZh) (\(occ.causeTitle)中 · 点击切换)"
                    let warnItem = NSMenuItem(
                        title: "当前 \(liveRoom.nameZh) 正在被\(occ.causeTitle)占用 (\(occ.startTimeString)-\(occ.endTimeString) \(occ.shortCourseName))",
                        action: #selector(openEmptyClassroomWindowAction),
                        keyEquivalent: ""
                    )
                    warnItem.image = statusDotImage(color: .systemRed)
                    warnItem.target = self
                    submenu.addItem(warnItem)
                } else if let occ = conflict, let mins = minsUntil, mins <= 35 {
                    emptyParent.title = "自习教室：\(liveRoom.nameZh) (\(mins) 分钟后有\(occ.causeTitle))"
                    let warnItem = NSMenuItem(
                        title: "\(mins) 分钟后 (\(occ.startTimeString)) 将有《\(occ.shortCourseName)》，建议提前切换",
                        action: #selector(openEmptyClassroomWindowAction),
                        keyEquivalent: ""
                    )
                    warnItem.image = statusDotImage(color: .systemOrange)
                    warnItem.target = self
                    submenu.addItem(warnItem)
                } else if let nextOcc = liveRoom.nextOccupation(afterMinutes: nowMin) {
                    emptyParent.title = "自习教室：\(liveRoom.nameZh) (空闲至 \(nextOcc.startTimeString))"
                    let statusItem = NSMenuItem(
                        title: "当前自习：\(liveRoom.nameZh) · 空闲至 \(nextOcc.startTimeString) (\(nextOcc.shortCourseName))",
                        action: #selector(openEmptyClassroomWindowAction),
                        keyEquivalent: ""
                    )
                    statusItem.image = statusDotImage(color: .systemGreen)
                    statusItem.target = self
                    submenu.addItem(statusItem)
                } else {
                    emptyParent.title = "自习教室：\(liveRoom.nameZh) (今日余下全空)"
                    let statusItem = NSMenuItem(
                        title: "当前自习：\(liveRoom.nameZh) · 今日余下时段全部空闲",
                        action: #selector(openEmptyClassroomWindowAction),
                        keyEquivalent: ""
                    )
                    statusItem.image = statusDotImage(color: .systemGreen)
                    statusItem.target = self
                    submenu.addItem(statusItem)
                }

                // 附近换教室推荐
                if !switches.isEmpty {
                    let switchHeader = NSMenuItem(title: "附近可切换空教室 (点击直接切换)", action: nil, keyEquivalent: "")
                    switchHeader.isEnabled = false
                    submenu.addItem(switchHeader)
                    for rec in switches {
                        let item = NSMenuItem(
                            title: "切换至 \(rec.room.nameZh)  (\(rec.proximity.badgeText) · \(rec.freeUntilText))",
                            action: #selector(quickSelectStudyRoomMenuAction(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = rec.room
                        submenu.addItem(item)
                    }
                }
            } else {
                emptyParent.title = "自习教室：\(record.roomName)"
                let statusItem = NSMenuItem(
                    title: "当前设定自习室：\(record.roomName) (正在同步占用状态...)",
                    action: #selector(openEmptyClassroomWindowAction),
                    keyEquivalent: ""
                )
                statusItem.target = self
                submenu.addItem(statusItem)
            }

            let clearItem = NSMenuItem(title: "取消当前自习教室设定", action: #selector(clearStudyRoomMenuAction), keyEquivalent: "")
            clearItem.target = self
            submenu.addItem(clearItem)
        } else {
            let allDayCount = service.recommendedTodayAllDayFreeRooms(limit: 20).count
            if allDayCount > 0 {
                emptyParent.title = "自习教室：未设定 (今日 \(allDayCount)+ 间全天空闲)"
            } else {
                emptyParent.title = "自习教室：未设定"
            }
            let promptItem = NSMenuItem(
                title: "尚未设定今日自习教室，可从下方列表直接选择",
                action: #selector(openEmptyClassroomWindowAction),
                keyEquivalent: ""
            )
            promptItem.target = self
            submenu.addItem(promptItem)
        }

        // 当天全天空闲推荐
        let todayPicks = service.recommendedTodayAllDayFreeRooms(limit: 5)
        if !todayPicks.isEmpty {
            submenu.addItem(NSMenuItem.separator())
            let todayHeader = NSMenuItem(title: "今日全天空闲教室 (点击设为当前自习)", action: nil, keyEquivalent: "")
            todayHeader.isEnabled = false
            submenu.addItem(todayHeader)
            for room in todayPicks {
                let isCurrent = (SettingsManager.shared.currentStudyRoom?.roomId == room.id)
                let seatText = room.seatsForLesson.map { "\($0)座 · " } ?? ""
                let item = NSMenuItem(
                    title: "\(room.nameZh)  (\(room.inferredFloor)楼 · \(seatText)全天无课)",
                    action: #selector(quickSelectStudyRoomMenuAction(_:)),
                    keyEquivalent: ""
                )
                item.state = isCurrent ? .on : .off
                item.target = self
                item.representedObject = room
                submenu.addItem(item)
            }
        }

        // 明日全天空闲（搬书推荐）
        let tomorrowRec = service.buildTomorrowRecommendation(limit: 4)
        if !tomorrowRec.candidates.isEmpty || tomorrowRec.isCurrentRoomAllDayFreeTomorrow {
            submenu.addItem(NSMenuItem.separator())
            let tmrHeaderTitle: String
            if tomorrowRec.isCurrentRoomAllDayFreeTomorrow, let curName = tomorrowRec.currentStudyRoomName {
                tmrHeaderTitle = "明日自习：\(curName) 明天继续全天无课"
            } else {
                tmrHeaderTitle = "明日全天空闲教室 (点击可预约明日自习)"
            }
            let tmrHeader = NSMenuItem(title: tmrHeaderTitle, action: nil, keyEquivalent: "")
            tmrHeader.isEnabled = false
            submenu.addItem(tmrHeader)

            for cand in tomorrowRec.candidates {
                let isNext = (SettingsManager.shared.nextDayStudyRoom?.roomId == cand.room.id)
                let item = NSMenuItem(
                    title: "\(cand.room.nameZh)  (\(cand.badgeText))",
                    action: #selector(quickReserveTomorrowRoomMenuAction(_:)),
                    keyEquivalent: ""
                )
                item.state = isNext ? .on : .off
                item.target = self
                item.representedObject = cand.room
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let openWinItem = NSMenuItem(title: "打开空教室查询与自习管理面板...", action: #selector(openEmptyClassroomWindowAction), keyEquivalent: "e")
        openWinItem.target = self
        submenu.addItem(openWinItem)

        let refreshRoomsItem = NSMenuItem(title: "立即刷新空教室占用数据", action: #selector(refreshEmptyClassroomsMenuAction), keyEquivalent: "")
        refreshRoomsItem.target = self
        submenu.addItem(refreshRoomsItem)
    }

    @objc private func openEmptyClassroomWindowAction() {
        EmptyClassroomWindowController.shared.showWindowAndSync()
    }

    @objc private func quickSelectStudyRoomMenuAction(_ sender: NSMenuItem) {
        guard let room = sender.representedObject as? EmptyClassroomItem else { return }
        let campus = EmptyClassroomService.shared.currentPreferredCampus
        EmptyClassroomService.shared.setCurrentStudyRoom(room, campus: campus)
        NotificationHelper.sendNotification(
            title: "已设定当前自习教室",
            body: "当前自习室：\(room.nameZh)。当有课程或考试占用前会自动提醒切换。"
        )
    }

    @objc private func quickReserveTomorrowRoomMenuAction(_ sender: NSMenuItem) {
        guard let room = sender.representedObject as? EmptyClassroomItem else { return }
        let campus = EmptyClassroomService.shared.currentPreferredCampus
        EmptyClassroomService.shared.setNextDayStudyRoom(room, campus: campus)
        NotificationHelper.sendNotification(
            title: "已预约明日自习教室",
            body: "明日自习室：\(room.nameZh)。明天打开软件时将自动切换为当前自习教室。"
        )
    }

    @objc private func clearStudyRoomMenuAction() {
        EmptyClassroomService.shared.clearCurrentStudyRoom()
    }

    @objc private func refreshEmptyClassroomsMenuAction() {
        EmptyClassroomService.shared.syncTodayAndTomorrowStudyRooms(forceRefresh: true) { _ in }
    }

    @objc private func checkUpdateAction() {
        checkUpdateMenuItem?.title = "正在检查更新..."
        UpdateChecker.shared.checkForUpdates(manual: true) { [weak self] _ in
            self?.refreshUpdateMenuItemTitle()
        }
    }

    @objc private func onUpdateCheckFinished() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshUpdateMenuItemTitle()
        }
    }

    private func refreshUpdateMenuItemTitle() {
        if let release = UpdateChecker.shared.availableUpdate {
            checkUpdateMenuItem?.image = statusDotImage(color: .systemRed)
            checkUpdateMenuItem?.title = "发现新版本 \(release.tagName) (点击下载更新)..."
        } else {
            checkUpdateMenuItem?.image = symbolImage("arrow.triangle.2.circlepath")
            checkUpdateMenuItem?.title = "检查软件更新 (v\(UpdateChecker.shared.currentVersion))..."
        }
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
