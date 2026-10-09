import Foundation
import AppKit

public class MenubarController: NSObject, NSMenuDelegate, NetworkSpeedMonitorDelegate {
    public static let shared = MenubarController()

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var networkStatusMenuItem: NSMenuItem!
    private var speedMenuItem: NSMenuItem!
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

        let titleItem = NSMenuItem(title: "合肥工业大学校园网监测", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        networkStatusMenuItem = NSMenuItem(title: "网络状态: 🟢 已在线", action: nil, keyEquivalent: "")
        networkStatusMenuItem.isEnabled = false
        menu.addItem(networkStatusMenuItem)

        speedMenuItem = NSMenuItem(title: "实时网速: ↓ 0 B/s   ↑ 0 B/s", action: nil, keyEquivalent: "")
        speedMenuItem.isEnabled = false
        menu.addItem(speedMenuItem)

        menu.addItem(NSMenuItem.separator())

        availFlowMenuItem = NSMenuItem(title: "可用流量: --", action: nil, keyEquivalent: "")
        availFlowMenuItem.isEnabled = false
        menu.addItem(availFlowMenuItem)

        usedFlowMenuItem = NSMenuItem(title: "已用流量: --", action: nil, keyEquivalent: "")
        usedFlowMenuItem.isEnabled = false
        menu.addItem(usedFlowMenuItem)

        balMenuItem = NSMenuItem(title: "账户余额: --", action: nil, keyEquivalent: "")
        balMenuItem.isEnabled = false
        menu.addItem(balMenuItem)

        protMenuItem = NSMenuItem(title: "消费保护: --", action: nil, keyEquivalent: "")
        protMenuItem.isEnabled = false
        menu.addItem(protMenuItem)

        updateTimeMenuItem = NSMenuItem(title: "上次更新: 等待初次抓取", action: nil, keyEquivalent: "")
        updateTimeMenuItem.isEnabled = false
        menu.addItem(updateTimeMenuItem)

        menu.addItem(NSMenuItem.separator())

        courseParentMenuItem = NSMenuItem(title: "📚 今日课程: 加载中...", action: nil, keyEquivalent: "")
        let courseSubmenu = NSMenu()
        courseParentMenuItem.submenu = courseSubmenu
        menu.addItem(courseParentMenuItem)
        updateCourseSubmenu()

        dormElectricityMenuItem = NSMenuItem(title: "⚡ 宿舍电费: 加载中...", action: #selector(openElectricityStatsAction), keyEquivalent: "")
        dormElectricityMenuItem.target = self
        menu.addItem(dormElectricityMenuItem)
        updateDormElectricityMenu()

        menu.addItem(NSMenuItem.separator())

        let unifiedLoginItem = NSMenuItem(title: "🔑 统一身份认证登录 (信息门户 · 自动刷新全部)...", action: #selector(unifiedLoginAction), keyEquivalent: "u")
        unifiedLoginItem.target = self
        menu.addItem(unifiedLoginItem)

        let historyStatsItem = NSMenuItem(title: "📊 校园用量统计与历史分析...", action: #selector(openHistoryStatsAction), keyEquivalent: "h")
        historyStatsItem.target = self
        menu.addItem(historyStatsItem)

        menu.addItem(NSMenuItem.separator())

        let styleMenu = NSMenu()
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
            styleMenu.addItem(item)
        }
        let styleParentItem = NSMenuItem(title: "状态栏显示模式", action: nil, keyEquivalent: "")
        styleParentItem.submenu = styleMenu
        menu.addItem(styleParentItem)

        let oneClickLoginItem = NSMenuItem(title: "⚡ 一键登录校园网 (172.18.3.3)", action: #selector(oneClickLoginAction), keyEquivalent: "")
        oneClickLoginItem.target = self
        menu.addItem(oneClickLoginItem)

        let logoutPortalItem = NSMenuItem(title: "🔌 注销校园网当前设备", action: #selector(logoutPortalAction), keyEquivalent: "")
        logoutPortalItem.target = self
        menu.addItem(logoutPortalItem)

        let portalSettingsItem = NSMenuItem(title: "⚙️ 自动登录与账号设置...", action: #selector(openPortalSettingsAction), keyEquivalent: ",")
        portalSettingsItem.target = self
        menu.addItem(portalSettingsItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "立即刷新数据", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        toggleWidgetMenuItem = NSMenuItem(title: "显示桌面悬浮卡片", action: #selector(toggleWidgetAction), keyEquivalent: "w")
        toggleWidgetMenuItem.target = self
        menu.addItem(toggleWidgetMenuItem)

        let loginItem = NSMenuItem(title: "自服务授权 (xywzz:8443)...", action: #selector(loginAction), keyEquivalent: "l")
        loginItem.target = self
        menu.addItem(loginItem)

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
        menu.addItem(intervalParentItem)

        let openWebItem = NSMenuItem(title: "打开校园网自服务网页...", action: #selector(openWebAction), keyEquivalent: "o")
        openWebItem.target = self
        menu.addItem(openWebItem)

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

    public func speedMonitorDidUpdate(download: String, upload: String, compact: String) {
        currentDownloadSpeed = download
        currentUploadSpeed = upload
        currentSpeedCompact = compact

        speedMenuItem?.title = "🚀 实时网速: ↓ \(download)   ↑ \(upload)"

        let style = SettingsManager.shared.menubarStyle
        if style == 2 || style == 3 || (style == 0 && carouselToggle) {
            renderTitle()
        }
    }

    public func updateData(_ data: CampusNetworkData) {
        currentData = data
        renderTitle()

        if currentData.isLoggedIn {
            networkStatusMenuItem.title = "网络状态: 🟢 已在线认证"
        } else {
            networkStatusMenuItem.title = "网络状态: 🟡 未认证，点击一键登录"
        }

        if data.availableFlow != "-- M" {
            availFlowMenuItem.title = "📶 可用流量: \(data.availableFlow) (\(data.formattedAvailable))"
        } else {
            availFlowMenuItem.title = "📶 可用流量: 点击自服务授权查看"
        }
        
        usedFlowMenuItem.title = "📊 已用流量: \(data.usedFlow) (\(data.formattedUsed))"
        balMenuItem.title = "💰 账户余额: \(data.balance)"
        protMenuItem.title = "🛡️ 消费保护: \(data.flowProtection)"

        if let time = data.lastUpdated {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            updateTimeMenuItem.title = "⏱️ 上次更新: \(formatter.string(from: time))"
        }

        updateWidgetMenuState()
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
            for item in parent.items {
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
