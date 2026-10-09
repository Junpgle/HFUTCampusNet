import Foundation
import AppKit

public class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    // 校园网网关控件
    private var usernameField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var autoLoginCheckbox: NSButton!
    private var statusLabel: NSTextField!

    // 教务课表设置控件
    private var courseStudentIdField: NSTextField!
    private var courseSemesterIdField: NSTextField!
    private var courseTableCheckbox: NSButton!
    private var courseStatusLabel: NSTextField!

    // 宿舍电费配置控件
    private var dormCampusPopup: NSPopUpButton!
    private var dormBuildingField: NSTextField!
    private var dormRoomField: NSTextField!
    private var dormEndPopup: NSPopUpButton!
    private var dormThresholdField: NSTextField!
    private var dormStatusLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 730),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学助手 - 综合服务配置"
        window.center()
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)

        var curY: CGFloat = 730 - 36

        // 0. 顶部统一身份认证快捷入口卡片
        let ssoBox = NSView(frame: NSRect(x: 20, y: curY - 60, width: 480, height: 60))
        ssoBox.wantsLayer = true
        ssoBox.layer?.cornerRadius = 8
        ssoBox.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        ssoBox.layer?.borderWidth = 1.0
        ssoBox.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor

        let ssoIcon = NSImageView(frame: NSRect(x: 12, y: 18, width: 24, height: 24))
        ssoIcon.image = NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: nil)
        ssoIcon.contentTintColor = NSColor.systemBlue
        ssoBox.addSubview(ssoIcon)

        let ssoTitle = NSTextField(labelWithString: "统一身份认证 · 一键自动刷新全部")
        ssoTitle.frame = NSRect(x: 44, y: 32, width: 260, height: 18)
        ssoTitle.font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
        ssoBox.addSubview(ssoTitle)

        let ssoSub = NSTextField(labelWithString: "登录信息门户后，自动联动课表、电费与校园网自服务")
        ssoSub.frame = NSRect(x: 44, y: 12, width: 280, height: 16)
        ssoSub.font = NSFont.systemFont(ofSize: 10.5)
        ssoSub.textColor = .secondaryLabelColor
        ssoBox.addSubview(ssoSub)

        let ssoLoginBtn = NSButton(title: "🔑 一键登录", target: self, action: #selector(openUnifiedLoginWindow))
        ssoLoginBtn.bezelStyle = .rounded
        ssoLoginBtn.frame = NSRect(x: 335, y: 14, width: 85, height: 30)
        ssoBox.addSubview(ssoLoginBtn)

        let statsBtn = NSButton(title: "📊 统计", target: self, action: #selector(openHistoryStatsWindow))
        statsBtn.bezelStyle = .rounded
        statsBtn.frame = NSRect(x: 420, y: 14, width: 55, height: 30)
        ssoBox.addSubview(statsBtn)

        contentView.addSubview(ssoBox)
        curY -= 72

        // 1. 宿舍电费设置部分
        let elecTitle = NSTextField(labelWithString: "⚡ 宿舍电费配置 (慧新易校)")
        elecTitle.frame = NSRect(x: 24, y: curY, width: 440, height: 20)
        elecTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        contentView.addSubview(elecTitle)
        curY -= 28

        let campusLabel = NSTextField(labelWithString: "校区：")
        campusLabel.frame = NSRect(x: 24, y: curY, width: 60, height: 20)
        contentView.addSubview(campusLabel)

        dormCampusPopup = NSPopUpButton(frame: NSRect(x: 85, y: curY - 2, width: 140, height: 26))
        dormCampusPopup.addItems(withTitles: ["宣城校区", "合肥翡翠湖校区", "合肥屯溪路校区"])
        dormCampusPopup.selectItem(withTitle: SettingsManager.shared.dormCampus)
        contentView.addSubview(dormCampusPopup)

        let buildLabel = NSTextField(labelWithString: "楼栋：")
        buildLabel.frame = NSRect(x: 235, y: curY, width: 45, height: 20)
        contentView.addSubview(buildLabel)

        dormBuildingField = NSTextField(frame: NSRect(x: 280, y: curY, width: 60, height: 22))
        dormBuildingField.placeholderString = "例如 7"
        dormBuildingField.stringValue = SettingsManager.shared.dormBuilding
        contentView.addSubview(dormBuildingField)

        let roomLabel = NSTextField(labelWithString: "房间：")
        roomLabel.frame = NSRect(x: 350, y: curY, width: 45, height: 20)
        contentView.addSubview(roomLabel)

        dormRoomField = NSTextField(frame: NSRect(x: 395, y: curY, width: 85, height: 22))
        dormRoomField.placeholderString = "例如 315"
        dormRoomField.stringValue = SettingsManager.shared.dormRoom
        contentView.addSubview(dormRoomField)
        curY -= 30

        let portLabel = NSTextField(labelWithString: "电表端口：")
        portLabel.frame = NSRect(x: 24, y: curY, width: 70, height: 20)
        contentView.addSubview(portLabel)

        dormEndPopup = NSPopUpButton(frame: NSRect(x: 95, y: curY - 2, width: 130, height: 26))
        dormEndPopup.addItem(withTitle: "南边照明 (11)")
        dormEndPopup.lastItem?.representedObject = "11"
        dormEndPopup.addItem(withTitle: "南边空调 (12)")
        dormEndPopup.lastItem?.representedObject = "12"
        dormEndPopup.addItem(withTitle: "北边照明 (21)")
        dormEndPopup.lastItem?.representedObject = "21"
        dormEndPopup.addItem(withTitle: "北边空调 (22)")
        dormEndPopup.lastItem?.representedObject = "22"

        for item in dormEndPopup.itemArray {
            if (item.representedObject as? String) == SettingsManager.shared.dormEndNumber {
                dormEndPopup.select(item)
                break
            }
        }
        contentView.addSubview(dormEndPopup)

        let threshLabel = NSTextField(labelWithString: "预警阈值：")
        threshLabel.frame = NSRect(x: 235, y: curY, width: 65, height: 20)
        contentView.addSubview(threshLabel)

        dormThresholdField = NSTextField(frame: NSRect(x: 300, y: curY, width: 55, height: 22))
        dormThresholdField.stringValue = String(format: "%.0f", SettingsManager.shared.electricityLowWarningThreshold)
        contentView.addSubview(dormThresholdField)

        let yuanLabel = NSTextField(labelWithString: "元")
        yuanLabel.frame = NSRect(x: 358, y: curY, width: 25, height: 20)
        contentView.addSubview(yuanLabel)

        let testElecBtn = NSButton(title: "⚡ 查询电费", target: self, action: #selector(testElectricityClicked))
        testElecBtn.bezelStyle = .rounded
        testElecBtn.frame = NSRect(x: 388, y: curY - 4, width: 95, height: 28)
        contentView.addSubview(testElecBtn)
        curY -= 26

        dormStatusLabel = NSTextField(labelWithString: "")
        dormStatusLabel.frame = NSRect(x: 24, y: curY, width: 460, height: 18)
        dormStatusLabel.font = NSFont.systemFont(ofSize: 11)
        dormStatusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(dormStatusLabel)
        curY -= 16

        // 分割线 1
        let sep1 = NSBox(frame: NSRect(x: 20, y: curY, width: 480, height: 1))
        sep1.boxType = .separator
        contentView.addSubview(sep1)
        curY -= 22

        // 2. 校园网网关认证部分
        let title = NSTextField(labelWithString: "📶 校园网网关认证 (http://172.18.3.3)")
        title.frame = NSRect(x: 24, y: curY, width: 440, height: 20)
        title.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        contentView.addSubview(title)
        curY -= 28

        let userLabel = NSTextField(labelWithString: "学号 / 账号：")
        userLabel.frame = NSRect(x: 24, y: curY, width: 95, height: 20)
        contentView.addSubview(userLabel)

        usernameField = NSTextField(frame: NSRect(x: 125, y: curY, width: 355, height: 22))
        usernameField.placeholderString = "例如 2024xxxxxx"
        usernameField.stringValue = SettingsManager.shared.portalUsername
        contentView.addSubview(usernameField)
        curY -= 28

        let passLabel = NSTextField(labelWithString: "校园网密码：")
        passLabel.frame = NSRect(x: 24, y: curY, width: 95, height: 20)
        contentView.addSubview(passLabel)

        passwordField = NSSecureTextField(frame: NSRect(x: 125, y: curY, width: 355, height: 22))
        passwordField.placeholderString = "请输入校园网认证密码"
        passwordField.stringValue = SettingsManager.shared.portalPassword
        contentView.addSubview(passwordField)
        curY -= 26

        autoLoginCheckbox = NSButton(checkboxWithTitle: "断网或切换 Wi-Fi 时自动重连并发送系统通知", target: nil, action: nil)
        autoLoginCheckbox.frame = NSRect(x: 125, y: curY, width: 355, height: 20)
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        contentView.addSubview(autoLoginCheckbox)
        curY -= 26

        let selfTitle = NSTextField(labelWithString: "自服务系统 (xywzz:8443 可用流量与消费保护)：")
        selfTitle.frame = NSRect(x: 24, y: curY, width: 310, height: 20)
        selfTitle.font = NSFont.systemFont(ofSize: 11)
        selfTitle.textColor = .secondaryLabelColor
        contentView.addSubview(selfTitle)

        let openSelfBtn = NSButton(title: "🔑 自服务授权", target: self, action: #selector(openSelfLoginWindow))
        openSelfBtn.bezelStyle = .rounded
        openSelfBtn.frame = NSRect(x: 345, y: curY - 4, width: 135, height: 28)
        contentView.addSubview(openSelfBtn)
        curY -= 20

        // 分割线 2
        let sep2 = NSBox(frame: NSRect(x: 20, y: curY, width: 480, height: 1))
        sep2.boxType = .separator
        contentView.addSubview(sep2)
        curY -= 22

        // 3. 教务课表设置部分
        let courseTitle = NSTextField(labelWithString: "📚 合工大教务课表 (jxglstu.hfut.edu.cn)")
        courseTitle.frame = NSRect(x: 24, y: curY, width: 440, height: 20)
        courseTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        contentView.addSubview(courseTitle)
        curY -= 28

        let stdLabel = NSTextField(labelWithString: "学生ID：")
        stdLabel.frame = NSRect(x: 24, y: curY, width: 65, height: 20)
        contentView.addSubview(stdLabel)

        courseStudentIdField = NSTextField(frame: NSRect(x: 90, y: curY, width: 140, height: 22))
        courseStudentIdField.placeholderString = "例如 178506"
        courseStudentIdField.stringValue = SettingsManager.shared.courseStudentId
        contentView.addSubview(courseStudentIdField)

        let semLabel = NSTextField(labelWithString: "学期代码：")
        semLabel.frame = NSRect(x: 245, y: curY, width: 75, height: 20)
        contentView.addSubview(semLabel)

        courseSemesterIdField = NSTextField(frame: NSRect(x: 320, y: curY, width: 160, height: 22))
        courseSemesterIdField.placeholderString = "例如 354"
        courseSemesterIdField.stringValue = SettingsManager.shared.courseSemesterId
        contentView.addSubview(courseSemesterIdField)
        curY -= 26

        courseTableCheckbox = NSButton(checkboxWithTitle: "在桌面悬浮小组件与状态栏菜单中显示今日课程", target: nil, action: nil)
        courseTableCheckbox.frame = NSRect(x: 90, y: curY, width: 390, height: 20)
        courseTableCheckbox.state = SettingsManager.shared.courseTableEnabled ? .on : .off
        contentView.addSubview(courseTableCheckbox)
        curY -= 32

        let webAuthBtn = NSButton(title: "🌐 网页同步", target: self, action: #selector(openCourseLoginWindow))
        webAuthBtn.bezelStyle = .rounded
        webAuthBtn.frame = NSRect(x: 90, y: curY, width: 110, height: 28)
        contentView.addSubview(webAuthBtn)

        let syncCourseBtn = NSButton(title: "⚡ 一键同步", target: self, action: #selector(syncCourseClicked))
        syncCourseBtn.bezelStyle = .rounded
        syncCourseBtn.frame = NSRect(x: 210, y: curY, width: 100, height: 28)
        contentView.addSubview(syncCourseBtn)

        let viewTableBtn = NSButton(title: "📅 查看完整课表", target: self, action: #selector(viewTableClicked))
        viewTableBtn.bezelStyle = .rounded
        viewTableBtn.frame = NSRect(x: 320, y: curY, width: 160, height: 28)
        contentView.addSubview(viewTableBtn)
        curY -= 26

        courseStatusLabel = NSTextField(labelWithString: "")
        courseStatusLabel.frame = NSRect(x: 24, y: curY, width: 460, height: 18)
        courseStatusLabel.font = NSFont.systemFont(ofSize: 11)
        courseStatusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(courseStatusLabel)
        curY -= 16

        // 分割线 3
        let sep3 = NSBox(frame: NSRect(x: 20, y: curY, width: 480, height: 1))
        sep3.boxType = .separator
        contentView.addSubview(sep3)
        curY -= 24

        // 网关状态信息
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 24, y: curY, width: 460, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)
        curY -= 36

        // 底部保存与测试按钮
        let testBtn = NSButton(title: "测试网关登录", target: self, action: #selector(testLoginClicked))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: 100, y: 14, width: 115, height: 32)
        contentView.addSubview(testBtn)

        let logoutBtn = NSButton(title: "注销网关", target: self, action: #selector(logoutClicked))
        logoutBtn.bezelStyle = .rounded
        logoutBtn.frame = NSRect(x: 225, y: 14, width: 95, height: 32)
        contentView.addSubview(logoutBtn)

        let saveBtn = NSButton(title: "保存设置", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 330, y: 14, width: 150, height: 32)
        contentView.addSubview(saveBtn)

        window.contentView = contentView
    }

    public func showSettings() {
        usernameField.stringValue = SettingsManager.shared.portalUsername
        passwordField.stringValue = SettingsManager.shared.portalPassword
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        courseStudentIdField.stringValue = SettingsManager.shared.courseStudentId
        courseSemesterIdField.stringValue = SettingsManager.shared.courseSemesterId
        courseTableCheckbox.state = SettingsManager.shared.courseTableEnabled ? .on : .off

        dormCampusPopup.selectItem(withTitle: SettingsManager.shared.dormCampus)
        dormBuildingField.stringValue = SettingsManager.shared.dormBuilding
        dormRoomField.stringValue = SettingsManager.shared.dormRoom
        dormThresholdField.stringValue = String(format: "%.0f", SettingsManager.shared.electricityLowWarningThreshold)

        for item in dormEndPopup.itemArray {
            if (item.representedObject as? String) == SettingsManager.shared.dormEndNumber {
                dormEndPopup.select(item)
                break
            }
        }

        updateCourseStatusDisplay()
        updateDormStatusDisplay()

        PortalAuthService.shared.checkStatus { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .online(let uid, let ip, _, let fee, _):
                    self?.statusLabel.stringValue = "🟢 网关已认证在线 (学号: \(uid), IP: \(ip), 余额: \(String(format: "%.2f", fee))元)"
                    self?.statusLabel.textColor = .systemGreen
                case .offline(let reason):
                    self?.statusLabel.stringValue = "🟡 网关离线未认证: \(reason)"
                    self?.statusLabel.textColor = .systemOrange
                case .notInCampusNet:
                    self?.statusLabel.stringValue = "🔴 未连接校园网络 Wi-Fi"
                    self?.statusLabel.textColor = .systemRed
                }
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateCourseStatusDisplay() {
        if let schedule = CourseScheduleService.shared.currentSchedule, !schedule.lessons.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            let timeStr = schedule.lastSyncTime.map { f.string(from: $0) } ?? "未知"
            courseStatusLabel.stringValue = "✓ 已同步 \(schedule.lessons.count) 节课程 (最后更新: \(timeStr))"
            courseStatusLabel.textColor = .systemGreen
        } else {
            courseStatusLabel.stringValue = "尚未同步课表，可点击「网页同步」或「一键同步」"
            courseStatusLabel.textColor = .secondaryLabelColor
        }
    }

    private func updateDormStatusDisplay() {
        if let elec = ElectricityService.shared.latestData {
            let bal = elec.displayBalance
            let pwr = elec.displayPower
            let warn = elec.isLowBalance ? " (⚠️ 低电费预警)" : ""
            dormStatusLabel.stringValue = "✓ 最新剩余: \(bal) | 剩余: \(pwr)\(warn)"
            dormStatusLabel.textColor = elec.isLowBalance ? .systemRed : .systemGreen
        } else {
            dormStatusLabel.stringValue = "尚未抓取到电费数据，可点击「查询电费」或「一键登录」"
            dormStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func testElectricityClicked() {
        saveCredentials()
        dormStatusLabel.stringValue = "正在连接慧新易校查询宿舍电费..."
        dormStatusLabel.textColor = .secondaryLabelColor

        ElectricityService.shared.fetchData { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let elec):
                    self?.updateDormStatusDisplay()
                    NotificationHelper.showNotification(
                        title: "⚡ 宿舍电费查询成功",
                        subtitle: "\(SettingsManager.shared.dormRoomName)",
                        body: "当前剩余电费: \(elec.displayBalance)  剩余电量: \(elec.displayPower)"
                    )
                case .failure(let err):
                    self?.dormStatusLabel.stringValue = "❌ 查询失败: \(err.localizedDescription)"
                    self?.dormStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    @objc private func openUnifiedLoginWindow() {
        saveCredentials()
        UnifiedLoginWebViewController.shared.showLoginWindow()
    }

    @objc private func openHistoryStatsWindow() {
        HistoryStatsWindowController.shared.showWindow(nil)
    }

    @objc private func openSelfLoginWindow() {
        LoginWebViewController.shared.showLoginWindow()
    }

    @objc private func openCourseLoginWindow() {
        saveCredentials()
        CourseLoginWebViewController.shared.showLoginWindow()
    }

    @objc private func viewTableClicked() {
        CourseScheduleWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func syncCourseClicked() {
        saveCredentials()
        courseStatusLabel.stringValue = "正在从合工大教务系统同步课表..."
        courseStatusLabel.textColor = .secondaryLabelColor

        CourseScheduleService.shared.syncSchedule { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let schedule):
                    self?.updateCourseStatusDisplay()
                    NotificationHelper.sendNotification(
                        title: "🎉 课表同步成功",
                        body: "已同步 \(schedule.lessons.count) 门排课数据"
                    )
                case .failure(let error):
                    if let syncErr = error as? CourseScheduleService.CourseSyncError, case .needLogin = syncErr {
                        self?.courseStatusLabel.stringValue = "⚠️ 需要教务系统授权，正在打开登录页面..."
                        CourseLoginWebViewController.shared.showLoginWindow()
                    } else {
                        self?.courseStatusLabel.stringValue = "❌ 同步失败: \(error.localizedDescription)"
                        self?.courseStatusLabel.textColor = .systemRed
                    }
                }
            }
        }
    }

    @objc private func testLoginClicked() {
        let user = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !user.isEmpty else {
            statusLabel.stringValue = "⚠️ 请先输入学号"
            statusLabel.textColor = .systemOrange
            return
        }

        statusLabel.stringValue = "正在检测与认证网关..."
        statusLabel.textColor = .secondaryLabelColor

        PortalAuthService.shared.login(username: user, password: pass) { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = (success ? "✓ " : "❌ ") + msg
                self?.statusLabel.textColor = success ? .systemGreen : .systemRed
                if success {
                    self?.saveCredentials()
                    CampusNetworkClient.shared.fetchData()
                }
            }
        }
    }

    @objc private func logoutClicked() {
        statusLabel.stringValue = "正在注销当前网关设备..."
        PortalAuthService.shared.logout { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = msg
                self?.statusLabel.textColor = success ? .systemOrange : .systemRed
                CampusNetworkClient.shared.fetchData()
            }
        }
    }

    @objc private func saveClicked() {
        saveCredentials()
        window?.close()
        CampusNetworkClient.shared.fetchData()
        ElectricityService.shared.fetchData { _ in }
    }

    private func saveCredentials() {
        SettingsManager.shared.portalUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.portalPassword = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.autoLoginPortal = (autoLoginCheckbox.state == .on)
        SettingsManager.shared.courseStudentId = courseStudentIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.courseSemesterId = courseSemesterIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.courseTableEnabled = (courseTableCheckbox.state == .on)

        if let selectedCampus = dormCampusPopup.titleOfSelectedItem {
            SettingsManager.shared.dormCampus = selectedCampus
        }
        SettingsManager.shared.dormBuilding = dormBuildingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.dormRoom = dormRoomField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedEnd = dormEndPopup.selectedItem?.representedObject as? String {
            SettingsManager.shared.dormEndNumber = selectedEnd
        }
        if let thresh = Double(dormThresholdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), thresh > 0 {
            SettingsManager.shared.electricityLowWarningThreshold = thresh
        }
    }
}
