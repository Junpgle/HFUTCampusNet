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
    private var pinWidgetToDesktopMenuItem: NSMenuItem!
    private var courseParentMenuItem: NSMenuItem!
    private var emptyClassroomMenuItem: NSMenuItem!
    private var dormElectricityMenuItem: NSMenuItem!
    private var campusCardMenuItem: NSMenuItem!
    private var academicMenuItem: NSMenuItem!
    private var checkUpdateMenuItem: NSMenuItem!
    private var hideSpeedOnBatteryMenuItem: NSMenuItem?
    private var quotaMenuCardView: CampusQuotaCardView?

    private var currentData: CampusNetworkData = CampusNetworkData()
    private var currentSpeedCompact: String = "↓ 0B/s  ↑ 0B/s"
    private var currentDownloadSpeed: String = "0 B/s"
    private var currentUploadSpeed: String = "0 B/s"

    private var carouselTimer: Timer?
    private var carouselToggle: Bool = false
    private var isMenuOpen: Bool = false
    private var isPausedForSleep: Bool = false

    private override init() {
        super.init()
        setupStatusItem()
        startCarousel()
        NetworkSpeedMonitor.shared.delegate = self
        NetworkSpeedMonitor.shared.evaluateState()

        // 监听屏幕睡眠与点亮（合盖/息屏自动挂起网速与轮播）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onScreenSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onScreenWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onSystemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPowerConfigChanged),
            name: .powerModeConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPowerConfigChanged),
            name: .powerSourceDidChange,
            object: nil
        )

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
            selector: #selector(onCampusCardUpdated),
            name: .campusCardDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAcademicDataUpdated),
            name: .academicDataDidUpdate,
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
            self.renderTitle()
            self.quotaMenuCardView?.refresh(mode: 0)
        }
    }

    private func symbolImage(_ name: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        img?.isTemplate = true
        return img
    }

    private static let greenDotImage: NSImage = makeStatusDotImage(color: .systemGreen)
    private static let orangeDotImage: NSImage = makeStatusDotImage(color: .systemOrange)

    private static func makeStatusDotImage(color: NSColor, diameter: CGFloat = 7) -> NSImage {
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

    private func statusDotImage(color: NSColor, diameter: CGFloat = 7) -> NSImage {
        if color == .systemGreen && diameter == 7 {
            return Self.greenDotImage
        }
        if color == .systemOrange && diameter == 7 {
            return Self.orangeDotImage
        }
        return Self.makeStatusDotImage(color: color, diameter: diameter)
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

        campusCardMenuItem = NSMenuItem(title: "校园一卡通：加载中...", action: nil, keyEquivalent: "")
        campusCardMenuItem.image = symbolImage("creditcard")
        let cardSubmenu = NSMenu()
        campusCardMenuItem.submenu = cardSubmenu
        menu.addItem(campusCardMenuItem)
        updateCampusCardMenu()

        courseParentMenuItem = NSMenuItem(title: "今日课程：加载中...", action: nil, keyEquivalent: "")
        courseParentMenuItem.image = symbolImage("calendar")
        let courseSubmenu = NSMenu()
        courseParentMenuItem.submenu = courseSubmenu
        menu.addItem(courseParentMenuItem)
        updateCourseSubmenu()

        academicMenuItem = NSMenuItem(title: "考试与成绩：加载中...", action: nil, keyEquivalent: "")
        academicMenuItem.image = symbolImage("graduationcap")
        let academicSubmenu = NSMenu()
        academicMenuItem.submenu = academicSubmenu
        menu.addItem(academicMenuItem)
        updateAcademicSubmenu()

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

        let aiAssistantItem = NSMenuItem(title: "校园 AI 助手...", action: #selector(openAIAssistantAction), keyEquivalent: "")
        aiAssistantItem.image = symbolImage("bubble.left.and.text.bubble.right")
        aiAssistantItem.target = self
        menu.addItem(aiAssistantItem)

        let libraryItem = NSMenuItem(title: "图书馆借阅服务...", action: #selector(openLibraryAction), keyEquivalent: "")
        libraryItem.image = symbolImage("books.vertical")
        libraryItem.target = self
        menu.addItem(libraryItem)

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

        toggleWidgetMenuItem = NSMenuItem(title: "显示桌面小组件", action: #selector(toggleWidgetAction), keyEquivalent: "w")
        toggleWidgetMenuItem.target = self
        displaySubmenu.addItem(toggleWidgetMenuItem)

        pinWidgetToDesktopMenuItem = NSMenuItem(title: "小组件嵌入桌面层 (不遮挡窗口，F11驻留)", action: #selector(toggleWidgetPinToDesktopAction), keyEquivalent: "")
        pinWidgetToDesktopMenuItem.target = self
        displaySubmenu.addItem(pinWidgetToDesktopMenuItem)

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

        displaySubmenu.addItem(NSMenuItem.separator())

        let batterySpeedItem = NSMenuItem(
            title: "隐藏网速以省电",
            action: #selector(toggleHideSpeedOnBatteryAction(_:)),
            keyEquivalent: ""
        )
        batterySpeedItem.target = self
        batterySpeedItem.state = SettingsManager.shared.hideSpeedOnBattery ? .on : .off
        hideSpeedOnBatteryMenuItem = batterySpeedItem
        displaySubmenu.addItem(batterySpeedItem)

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

        let aboutItem = NSMenuItem(title: "关于 HFUTCampusNet...", action: #selector(showAboutAction), keyEquivalent: "")
        aboutItem.image = symbolImage("info.circle")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出校园网监测", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    public func startCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = nil

        // 电池供电且开启省电轮播、或隐藏网速、或状态栏不是智能轮播模式，都无需唤醒轮播定时器
        if SettingsManager.shared.shouldHideSpeedNow
            || SettingsManager.shared.shouldPauseCarouselNow
            || isPausedForSleep
            || SettingsManager.shared.menubarStyle != 0 {
            carouselToggle = false
            return
        }

        let interval = SettingsManager.shared.carouselInterval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.carouselTick()
        }
        t.tolerance = 0.5
        carouselTimer = t
    }

    public func stopCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = nil
    }

    private func carouselTick() {
        carouselToggle.toggle()
        renderTitle()
    }

    private func updateTopStatusLine() {
        let statusPrefix = currentData.isLoggedIn ? "已在线" : "未认证"
        networkStatusMenuItem?.image = statusDotImage(color: currentData.isLoggedIn ? .systemGreen : .systemOrange)
        if SettingsManager.shared.shouldHideSpeedNow {
            networkStatusMenuItem?.title = "\(statusPrefix)  ·  🔋 省电模式 (网速休眠)"
        } else {
            networkStatusMenuItem?.title = "\(statusPrefix)  ·  ↓ \(currentDownloadSpeed)   ↑ \(currentUploadSpeed)"
        }
    }

    public func speedMonitorDidUpdate(download: String, upload: String, compact: String) {
        currentDownloadSpeed = download
        currentUploadSpeed = upload
        currentSpeedCompact = compact

        // 仅在用户实际点开菜单栏时才刷新顶部状态行，杜绝每秒后台重复渲染
        if isMenuOpen {
            updateTopStatusLine()
        }
        DesktopWidgetController.shared.speedMonitorDidUpdate(download: download, upload: upload, compact: compact)

        if SettingsManager.shared.shouldHideSpeedNow {
            return
        }

        let style = SettingsManager.shared.menubarStyle
        if style == 2 || style == 3 || (style == 0 && carouselToggle) {
            renderTitle()
        }
    }

    @objc private func onScreenSleep() {
        pauseForSleepIfNeeded()
    }

    @objc private func onSystemWillSleep() {
        pauseForSleepIfNeeded()
    }

    private func pauseForSleepIfNeeded() {
        guard SettingsManager.shared.shouldPauseOnScreenSleep, !isPausedForSleep else { return }
        isPausedForSleep = true
        stopCarousel()
        NetworkSpeedMonitor.shared.isScreenSleeping = true
    }

    @objc private func onScreenWake() {
        resumeFromSleep()
    }

    @objc private func onSystemDidWake() {
        resumeFromSleep()
    }

    private func resumeFromSleep() {
        guard isPausedForSleep else { return }
        isPausedForSleep = false
        NetworkSpeedMonitor.shared.isScreenSleeping = false
        startCarousel()
        renderTitle()
    }

    @objc private func onPowerConfigChanged() {
        if isPausedForSleep && !SettingsManager.shared.shouldPauseOnScreenSleep {
            isPausedForSleep = false
            NetworkSpeedMonitor.shared.isScreenSleeping = false
        }
        hideSpeedOnBatteryMenuItem?.state = SettingsManager.shared.hideSpeedOnBattery ? .on : .off
        startCarousel()
        renderTitle()
        NetworkSpeedMonitor.shared.evaluateState()
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
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = success ? "设备强制注销成功" : "设备注销失败"
                alert.informativeText = msg
                alert.alertStyle = success ? .informational : .warning
                alert.runModal()
            }
        }
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        let style = SettingsManager.shared.menubarStyle
        let isOffline = !currentData.isLoggedIn
        let hasFlowData = (currentData.usedFlow != "-- M" && !currentData.usedFlow.isEmpty)
        let flowTitle: String

        if isOffline {
            flowTitle = hasFlowData ? " 离线 | 已用 \(currentData.formattedUsed)" : " 离线/未认证"
        } else {
            flowTitle = adaptiveTrafficSummary()
        }

        let wifiIcon = symbolImage(isOffline ? "wifi.slash" : "wifi", pointSize: 12.5, weight: .medium)

        if SettingsManager.shared.shouldHideSpeedNow {
            // 电池模式且开启隐藏网速：统一显示流量与状态，彻底隐藏网速
            button.image = wifiIcon
            button.title = flowTitle
            return
        }

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
                : "\(flowTitle) · \(currentSpeedCompact)"
        default:
            button.image = wifiIcon
            button.title = flowTitle
        }
    }

    private func adaptiveTrafficSummary() -> String {
        let history = CampusHistoryManager.shared
        let monthlyHistoryUsedMB = history.currentMonthUsedFlowMB
        let monthlyCandidates = [currentData.usedMB, monthlyHistoryUsedMB].compactMap { $0 }
        guard let monthlyUsedMB = monthlyCandidates.max(), monthlyUsedMB >= 0 else {
            return " 已用 \(currentData.formattedUsed)"
        }

        let dailyLimitMB = 30.0 * 1024.0
        let monthlyFreeLimitMB = 200.0 * 1024.0
        let dailyUsedMB = max(0.0, history.todayFlowDeltaMB)
        let dailyProgress = min(1.0, dailyUsedMB / dailyLimitMB)
        let monthlyProgress = min(1.0, monthlyUsedMB / monthlyFreeLimitMB)

        if monthlyUsedMB > monthlyFreeLimitMB {
            let overFreeGB = (monthlyUsedMB - monthlyFreeLimitMB) / 1024.0
            var summary = " 本月超免费 \(String(format: "%.2f", overFreeGB))G"
            let balance = currentData.balance.trimmingCharacters(in: .whitespacesAndNewlines)
            if !balance.isEmpty && balance != "-- 元" {
                summary += " | \(balance)"
            }
            return summary
        }

        let dailyIsNearLimit = dailyProgress >= 0.8
        let monthlyIsNearLimit = monthlyProgress >= 0.8
        if dailyIsNearLimit && (!monthlyIsNearLimit || dailyProgress >= monthlyProgress) {
            let dailyRemainingGB = max(0.0, dailyLimitMB - dailyUsedMB) / 1024.0
            return " 今日余 \(String(format: "%.1f", dailyRemainingGB))G"
        }

        if monthlyIsNearLimit {
            let monthlyRemainingGB = max(0.0, monthlyFreeLimitMB - monthlyUsedMB) / 1024.0
            return " 本月余 \(String(format: "%.1f", monthlyRemainingGB))G"
        }

        return " 本月已用 \(String(format: "%.1f", monthlyProgress * 100.0))%"
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        updateTopStatusLine()
        hideSpeedOnBatteryMenuItem?.state = SettingsManager.shared.hideSpeedOnBattery ? .on : .off
        updateWidgetMenuState()
        updateCourseSubmenu()
        updateAcademicSubmenu()
        updateEmptyClassroomSubmenu()
        updateDormElectricityMenu()
        updateCampusCardMenu()
        quotaMenuCardView?.refresh(mode: 0)
        CampusNetworkClient.shared.fetchOnlineDevices()
    }

    public func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func updateWidgetMenuState() {
        let isShowing = SettingsManager.shared.showDesktopWidget
        toggleWidgetMenuItem.title = isShowing ? "隐藏桌面小组件" : "显示桌面小组件"
        toggleWidgetMenuItem.state = isShowing ? .on : .off
        pinWidgetToDesktopMenuItem?.state = SettingsManager.shared.widgetPinToDesktop ? .on : .off
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
            item.title = "宿舍电费：\(elec.displayBalance)\(daysStr)\(warnSuffix)"
        } else if let lastRecord = CampusHistoryManager.shared.latestElectricityRecord {
            let balStr = String(format: "%.2f 元", lastRecord.balanceRMB)
            let warnSuffix = lastRecord.balanceRMB < SettingsManager.shared.electricityLowWarningThreshold ? " · 余额偏低" : ""
            let daysLeft = CampusHistoryManager.shared.estimatedElectricityDaysRemaining
            let daysStr = (daysLeft != nil) ? " (约余 \(daysLeft!) 天)" : ""
            item.title = "宿舍电费：\(balStr)\(daysStr)\(warnSuffix)"
        } else {
            item.title = "宿舍电费：正在获取数据..."
        }
    }

    // MARK: - 校园一卡通菜单

    @objc private func onCampusCardUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.updateCampusCardMenu()
        }
    }

    private func updateCampusCardMenu() {
        guard let parentItem = campusCardMenuItem, let submenu = parentItem.submenu else { return }
        submenu.removeAllItems()

        if let card = CampusCardService.shared.latestData {
            let now = Date()
            let warnSuffix = card.isLowBalance ? " · 余额偏低" : ""
            let todayCount = card.todayExpenseCount(at: now)
            let todaySpent = card.todaySpentRMB(at: now)
            let todayPart = todayCount > 0 ? " · 今日消费 ¥\(String(format: "%.2f", todaySpent))" : " · 今日无消费"
            parentItem.title = "校园一卡通：\(card.displayBalance)\(todayPart)\(warnSuffix)"

            let balHeader = NSMenuItem(
                title: "卡内可用余额：\(card.displayBalance)  ·  状态：\(card.cardStatusText)",
                action: #selector(openCampusCardStatsAction),
                keyEquivalent: ""
            )
            balHeader.image = statusDotImage(color: card.isLowBalance ? .systemRed : .systemGreen)
            balHeader.target = self
            submenu.addItem(balHeader)

            if card.unsettleAmountRMB > 0.001 {
                let unsettleItem = NSMenuItem(
                    title: "    待圈存/过渡余额：\(String(format: "%.2f 元", card.unsettleAmountRMB)) (刷卡后自动入账)",
                    action: nil,
                    keyEquivalent: ""
                )
                unsettleItem.isEnabled = false
                submenu.addItem(unsettleItem)
            }

            let dailyList = card.dailyExpenseSummary(days: 7, at: now)
            let avg7Day = dailyList.isEmpty ? 0.0 : dailyList.reduce(0.0) { $0 + $1.spentRMB } / Double(dailyList.count)
            let summaryItem = NSMenuItem(
                title: "    今日消费：¥\(String(format: "%.2f", todaySpent)) (\(todayCount) 笔)   ·   近7日日均：¥\(String(format: "%.2f", avg7Day))",
                action: nil,
                keyEquivalent: ""
            )
            summaryItem.isEnabled = false
            submenu.addItem(summaryItem)

            submenu.addItem(NSMenuItem.separator())

            let recentHeader = NSMenuItem(title: "最近消费/充值流水 (前 6 笔)", action: nil, keyEquivalent: "")
            recentHeader.isEnabled = false
            submenu.addItem(recentHeader)

            let recentTx = Array(card.transactions.prefix(6))
            if recentTx.isEmpty {
                let emptyItem = NSMenuItem(title: "暂无近期交易记录", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                submenu.addItem(emptyItem)
            } else {
                for tx in recentTx {
                    let sign = tx.isExpense ? "-" : "+"
                    let amountStr = String(format: "%@¥%.2f", sign, tx.amountRMB)
                    let balPart = tx.balanceAfterRMB.map { String(format: "  (余 ¥%.2f)", $0) } ?? ""
                    let timeDisplay = String(tx.dateTimeString.dropFirst(5).prefix(11))
                    let item = NSMenuItem(
                        title: "\(timeDisplay)   \(amountStr)   \(tx.cleanMerchantName)\(balPart)",
                        action: #selector(openCampusCardStatsAction),
                        keyEquivalent: ""
                    )
                    item.target = self
                    submenu.addItem(item)
                }
            }
        } else {
            parentItem.title = "校园一卡通：未同步 (点击查看)"
            let promptItem = NSMenuItem(
                title: "点击同步校园一卡通余额与消费账单...",
                action: #selector(refreshCampusCardMenuAction),
                keyEquivalent: ""
            )
            promptItem.target = self
            submenu.addItem(promptItem)
        }

        submenu.addItem(NSMenuItem.separator())

        let openBillItem = NSMenuItem(title: "查看完整消费账单与趋势图...", action: #selector(openCampusCardStatsAction), keyEquivalent: "b")
        openBillItem.target = self
        submenu.addItem(openBillItem)

        let refreshCardItem = NSMenuItem(title: "立即刷新校园卡余额", action: #selector(refreshCampusCardMenuAction), keyEquivalent: "")
        refreshCardItem.target = self
        submenu.addItem(refreshCardItem)
    }

    @objc private func openCampusCardStatsAction() {
        CampusCardService.shared.fetchData { _ in }
        HistoryStatsWindowController.shared.showWindow(mode: 2)
    }

    @objc private func refreshCampusCardMenuAction() {
        CampusCardService.shared.fetchData { result in
            DispatchQueue.main.async {
                if case .failure(let err) = result {
                    UnifiedLoginWebViewController.shared.showLoginWindow()
                    print("[CampusCard] 手动刷新失败: \(err.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 考试倒计时与成绩/GPA 菜单

    @objc private func onAcademicDataUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.updateAcademicSubmenu()
        }
    }

    private func updateAcademicSubmenu() {
        guard let parentItem = academicMenuItem, let submenu = parentItem.submenu else { return }
        submenu.removeAllItems()

        let now = Date()
        let snapshot = AcademicService.shared.latestData
        let upcomingExams = snapshot?.upcomingExams(at: now) ?? []
        let totalCount = snapshot?.allGrades.count ?? 0
        let unreadCount = AcademicService.shared.unreadGradeCount

        if unreadCount > 0, let nextExam = upcomingExams.first {
            parentItem.title = "考试与成绩：成绩有更新 · 距《\(nextExam.courseName)》\(nextExam.countdownBadgeText(at: now))"
        } else if unreadCount > 0 {
            parentItem.title = "考试与成绩：成绩有更新 (点击查看)"
        } else if let nextExam = upcomingExams.first {
            parentItem.title = "考试与成绩：距《\(nextExam.courseName)》\(nextExam.countdownBadgeText(at: now))"
        } else if totalCount > 0 {
            parentItem.title = "考试与成绩：暂无新出分"
        } else {
            parentItem.title = "考试与成绩：点击同步查询"
        }

        // 1. 校历与学期进度里程碑
        let milestone = SemesterMilestoneInfo.calculate(at: now)
        let milestoneItem = NSMenuItem(
            title: "校历进度：\(milestone.currentWeekText) (\(milestone.progressPercentage)%)  ·  距期末周约 \(milestone.daysUntilExamWeek) 天  ·  距\(milestone.vacationName) \(milestone.remainingDays) 天",
            action: #selector(openExamScheduleWindowAction),
            keyEquivalent: ""
        )
        milestoneItem.image = statusDotImage(color: .systemIndigo)
        milestoneItem.target = self
        submenu.addItem(milestoneItem)

        let calendarSourceItem = NSMenuItem(
            title: "打开\(milestone.campusName)官方校历...",
            action: #selector(openOfficialCalendarAction),
            keyEquivalent: ""
        )
        calendarSourceItem.image = statusDotImage(color: .systemBlue)
        calendarSourceItem.target = self
        submenu.addItem(calendarSourceItem)

        submenu.addItem(NSMenuItem.separator())

        // 2. 近期考试安排
        let examHeader = NSMenuItem(
            title: upcomingExams.isEmpty ? "近期考试安排：当前暂无待考科目" : "近期考试倒计时 (\(upcomingExams.count) 场待考)",
            action: nil,
            keyEquivalent: ""
        )
        examHeader.isEnabled = false
        submenu.addItem(examHeader)

        for exam in upcomingExams.prefix(4) {
            let item = NSMenuItem(
                title: "[\(exam.countdownBadgeText(at: now))] \(exam.courseName)  ·  \(exam.dateTimeString)  ·  \(exam.displayLocation)",
                action: #selector(openExamScheduleWindowAction),
                keyEquivalent: ""
            )
            let days = exam.daysRemaining(at: now)
            item.image = statusDotImage(color: days <= 3 ? .systemRed : (days <= 7 ? .systemOrange : .systemBlue))
            item.target = self
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        // 3. 成绩更新监控状态（不直接暴露具体 GPA 和学科分数）
        if unreadCount > 0 {
            let updateItem = NSMenuItem(
                title: "检测到成绩有更新（新增 \(unreadCount) 门出分，点击查看详情）",
                action: #selector(openGradeWindowAction),
                keyEquivalent: ""
            )
            updateItem.image = statusDotImage(color: .systemOrange)
            updateItem.target = self
            submenu.addItem(updateItem)
        } else if totalCount > 0 {
            let statHeader = NSMenuItem(
                title: "成绩监控：后台静默监控中 · 暂无新出分",
                action: #selector(openGradeWindowAction),
                keyEquivalent: ""
            )
            statHeader.image = statusDotImage(color: .systemGreen)
            statHeader.target = self
            submenu.addItem(statHeader)
        } else {
            let emptyGradeItem = NSMenuItem(
                title: "尚未同步成绩单数据 (点击打开面板并同步)",
                action: #selector(openGradeWindowAction),
                keyEquivalent: ""
            )
            emptyGradeItem.target = self
            submenu.addItem(emptyGradeItem)
        }

        // 4. 培养方案学分与教材/评教概览
        if let prog = snapshot?.programCompletion {
            let progSummaryItem = NSMenuItem(
                title: String(format: "培养方案：已修 %.1f / %.0f 学分 (在修 +%.1f 分 · 预计完成 %.1f%%)", prog.passedCredits, prog.requiredCredits, prog.takingCredits, prog.projectedPercentageWithTaking),
                action: #selector(openProgramCompletionWindowAction),
                keyEquivalent: ""
            )
            progSummaryItem.image = statusDotImage(color: .systemBlue)
            progSummaryItem.target = self
            submenu.addItem(progSummaryItem)
        }

        let tbCount = snapshot?.textbooks.count ?? 0
        let pendingSurveys = snapshot?.pendingSurveyCount ?? 0
        if tbCount > 0 || pendingSurveys > 0 {
            let surveyText = pendingSurveys > 0 ? "⚠️ 待评教 \(pendingSurveys) 项" : "评教已完成/未开放"
            let tbItem = NSMenuItem(
                title: "教材与评教：本学期 \(tbCount) 门课程教材清单 · \(surveyText)",
                action: #selector(openTextbooksWindowAction),
                keyEquivalent: ""
            )
            tbItem.image = statusDotImage(color: pendingSurveys > 0 ? .systemRed : .systemTeal)
            tbItem.target = self
            submenu.addItem(tbItem)
        }

        submenu.addItem(NSMenuItem.separator())

        let openGradeItem = NSMenuItem(title: "打开成绩单与 GPA 测算面板...", action: #selector(openGradeWindowAction), keyEquivalent: "g")
        openGradeItem.target = self
        submenu.addItem(openGradeItem)

        let openExamItem = NSMenuItem(title: "打开考试安排与校历进度面板...", action: #selector(openExamScheduleWindowAction), keyEquivalent: "")
        openExamItem.target = self
        submenu.addItem(openExamItem)

        let openProgramItem = NSMenuItem(title: "打开培养方案与毕业学分审计...", action: #selector(openProgramCompletionWindowAction), keyEquivalent: "")
        openProgramItem.target = self
        submenu.addItem(openProgramItem)

        let openTextbookItem = NSMenuItem(title: "打开本学期课程教材与评教清单...", action: #selector(openTextbooksWindowAction), keyEquivalent: "")
        openTextbookItem.target = self
        submenu.addItem(openTextbookItem)

        submenu.addItem(NSMenuItem.separator())

        let refreshAcademicItem = NSMenuItem(title: "立即同步成绩 / 排考 / 培养方案 / 教材", action: #selector(refreshAcademicMenuAction), keyEquivalent: "")
        refreshAcademicItem.target = self
        submenu.addItem(refreshAcademicItem)
    }

    @objc private func openAIAssistantAction() {
        CampusAIAssistantWindowController.shared.showAssistant()
    }

    @objc private func openGradeWindowAction() {
        AcademicWindowController.shared.showWindow(mode: 0)
    }

    @objc private func openExamScheduleWindowAction() {
        AcademicWindowController.shared.showWindow(mode: 1)
    }

    @objc private func openProgramCompletionWindowAction() {
        AcademicWindowController.shared.showWindow(mode: 2)
    }

    @objc private func openTextbooksWindowAction() {
        AcademicWindowController.shared.showWindow(mode: 3)
    }

    @objc private func refreshAcademicMenuAction() {
        AcademicService.shared.syncAll(silent: false) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let snap):
                    NotificationHelper.sendNotification(
                        title: "教务学业数据同步完成",
                        body: "已同步 \(snap.allGrades.count) 门成绩、培养方案学分审计与 \(snap.textbooks.count) 门课程教材。"
                    )
                case .failure:
                    AcademicWindowController.shared.showWindow(mode: 0)
                }
            }
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

    @objc private func openLibraryAction() {
        LibraryWindowController.shared.showWindow(nil)
    }

    @objc private func openOfficialCalendarAction() {
        NSWorkspace.shared.open(CampusCalendarService.calendarURL())
    }

    @objc private func changeDisplayStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? Int else { return }
        SettingsManager.shared.menubarStyle = style
        if let parent = sender.menu {
            for item in parent.items where item.action == #selector(changeDisplayStyle(_:)) {
                item.state = (item == sender) ? .on : .off
            }
        }
        startCarousel()
        renderTitle()
        NetworkSpeedMonitor.shared.evaluateState()
    }

    @objc private func toggleHideSpeedOnBatteryAction(_ sender: NSMenuItem) {
        SettingsManager.shared.hideSpeedOnBattery.toggle()
        sender.state = SettingsManager.shared.hideSpeedOnBattery ? .on : .off
        startCarousel()
        renderTitle()
        NetworkSpeedMonitor.shared.evaluateState()
    }

    @objc private func oneClickLoginAction() {
        if SettingsManager.shared.portalPassword.isEmpty {
            SettingsWindowController.shared.showSettings()
            return
        }
        PortalAuthService.shared.login { success, msg in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
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
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "校园网设备注销"
                alert.informativeText = msg
                alert.alertStyle = .informational
                alert.runModal()
            }
        }
    }

    @objc private func openPortalSettingsAction() {
        SettingsWindowController.shared.showSettings()
    }

    @objc private func refreshAction() {
        CampusNetworkClient.shared.fetchData()
        ElectricityService.shared.fetchData { _ in }
        CampusCardService.shared.fetchData { _ in }
        AcademicService.shared.syncAll(silent: true)
        if SettingsManager.shared.courseTableEnabled {
            CourseScheduleService.shared.syncSchedule { _ in }
        }
        EmptyClassroomService.shared.syncTodayAndTomorrowStudyRooms(forceRefresh: true) { _ in }
    }

    @objc private func toggleWidgetAction() {
        DesktopWidgetController.shared.toggleWidget()
        updateWidgetMenuState()
    }

    @objc private func toggleWidgetPinToDesktopAction() {
        DesktopWidgetController.shared.togglePinToDesktopMode()
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
        let milestone = SemesterMilestoneInfo.calculate(schedule: schedule)

        let milestoneHeader = NSMenuItem(
            title: "校历：\(milestone.currentWeekText) (进度 \(milestone.progressPercentage)%)  ·  距\(milestone.vacationName) \(milestone.remainingDays) 天",
            action: #selector(openCourseTableAction),
            keyEquivalent: ""
        )
        milestoneHeader.image = statusDotImage(color: .systemIndigo)
        milestoneHeader.target = self
        submenu.addItem(milestoneHeader)
        submenu.addItem(NSMenuItem.separator())

        if let schedule = schedule, !schedule.lessons.isEmpty {
            if todayLessons.isEmpty {
                courseParent.title = "今日课程：今日无课 (\(milestone.currentTeachingWeekText))"
                let noClassItem = NSMenuItem(title: "今日暂无排课", action: nil, keyEquivalent: "")
                noClassItem.isEnabled = false
                submenu.addItem(noClassItem)
            } else {
                courseParent.title = "今日课程：\(todayLessons.count) 节课 (\(milestone.currentTeachingWeekText))"
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

        let openTextbookItem = NSMenuItem(title: "查看本学期课程教材与评教清单...", action: #selector(openTextbooksWindowAction), keyEquivalent: "")
        openTextbookItem.target = self
        submenu.addItem(openTextbookItem)

        let openProgramItem = NSMenuItem(title: "查看培养方案与毕业学分审计...", action: #selector(openProgramCompletionWindowAction), keyEquivalent: "")
        openProgramItem.target = self
        submenu.addItem(openProgramItem)

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
                    let shouldOpenLogin: Bool = {
                        guard let syncErr = error as? CourseScheduleService.CourseSyncError else { return false }
                        switch syncErr {
                        case .needLogin:
                            return true
                        case .emptySchedule:
                            return CourseScheduleService.shared.currentSchedule == nil
                        default:
                            return false
                        }
                    }()
                    if shouldOpenLogin {
                        CourseLoginWebViewController.shared.showLoginWindow()
                    } else {
                        NSApp.activate(ignoringOtherApps: true)
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
        if !tomorrowRec.candidates.isEmpty || tomorrowRec.isCurrentRoomAllDayFreeTomorrow || SettingsManager.shared.nextDayStudyRoom != nil {
            submenu.addItem(NSMenuItem.separator())
            let tmrHeaderTitle: String
            if let nextRecord = SettingsManager.shared.nextDayStudyRoom {
                tmrHeaderTitle = "明日自习：已预约 \(nextRecord.roomName)"
            } else if tomorrowRec.isCurrentRoomAllDayFreeTomorrow, let curName = tomorrowRec.currentStudyRoomName {
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

            if let nextRecord = SettingsManager.shared.nextDayStudyRoom {
                let clearNextItem = NSMenuItem(
                    title: "取消明日自习预约 (\(nextRecord.roomName))",
                    action: #selector(clearNextDayStudyRoomMenuAction),
                    keyEquivalent: ""
                )
                clearNextItem.target = self
                submenu.addItem(clearNextItem)
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
        if SettingsManager.shared.currentStudyRoom?.roomId == room.id {
            EmptyClassroomService.shared.clearCurrentStudyRoom()
            return
        }
        let campus = EmptyClassroomService.shared.inferCampus(for: room)
        EmptyClassroomService.shared.setCurrentStudyRoom(room, campus: campus)
        NotificationHelper.sendNotification(
            title: "已设定当前自习教室",
            body: "当前自习室：\(room.nameZh)。当有课程或考试占用前会自动提醒切换。"
        )
    }

    @objc private func quickReserveTomorrowRoomMenuAction(_ sender: NSMenuItem) {
        guard let room = sender.representedObject as? EmptyClassroomItem else { return }
        if SettingsManager.shared.nextDayStudyRoom?.roomId == room.id {
            EmptyClassroomService.shared.clearNextDayStudyRoom()
            return
        }
        let campus = EmptyClassroomService.shared.inferCampus(for: room)
        EmptyClassroomService.shared.setNextDayStudyRoom(room, campus: campus)
        NotificationHelper.sendNotification(
            title: "已预约明日自习教室",
            body: "明日自习室：\(room.nameZh)。明天打开软件时将自动切换为当前自习教室。"
        )
    }

    @objc private func clearStudyRoomMenuAction() {
        EmptyClassroomService.shared.clearCurrentStudyRoom()
    }

    @objc private func clearNextDayStudyRoomMenuAction() {
        EmptyClassroomService.shared.clearNextDayStudyRoom()
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

    @objc private func showAboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "HFUT 校园网与生活助手"
        alert.informativeText = """
        版本：v\(UpdateChecker.shared.currentVersion) (macOS 原生 Universal)
        专为合肥工业大学学子打造的状态栏与桌面效率伴侣。

        【特别鸣谢参考的开源项目】
        • Chiu-xaH/HFUT-Schedule (聚在工大)
          提供教务、CAS 统一认证与慧新生活服务协议与业务设计的重要参考
        • elonzh/hfut
          提供合工大教务系统 (EAMS) 接口封装与会话维持机制的重要参考
        • drcom-generic 与校园网自动登录开源实现
          提供 Dr.COM (172.18.3.3) 网关认证与掉线自动重连的重要思路

        开源协议：MIT License
        项目主页：https://github.com/Junpgle/HFUTCampusNet
        """
        alert.alertStyle = .informational
        if let icon = NSApp.applicationIconImage {
            alert.icon = icon
        }
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "访问 GitHub 仓库")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "https://github.com/Junpgle/HFUTCampusNet") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
