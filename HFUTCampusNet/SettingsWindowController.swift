import Foundation
import AppKit

public class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    private var usernameField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var autoLoginCheckbox: NSButton!
    private var statusLabel: NSTextField!

    // 教务课表设置控件
    private var courseStudentIdField: NSTextField!
    private var courseSemesterIdField: NSTextField!
    private var courseTableCheckbox: NSButton!
    private var courseStatusLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 530),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学助手 - 校园网与教务课表配置"
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

        // 1. 校园网认证部分
        let title = NSTextField(labelWithString: "📶 校园网网关认证 (http://172.18.3.3)")
        title.frame = NSRect(x: 24, y: 486, width: 440, height: 22)
        title.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        contentView.addSubview(title)

        let subtitle = NSTextField(labelWithString: "配置账号密码后，掉线或唤醒时自动完成无感登录并在通知栏提醒。")
        subtitle.frame = NSRect(x: 24, y: 464, width: 440, height: 18)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        contentView.addSubview(subtitle)

        // 学号/账号
        let userLabel = NSTextField(labelWithString: "学号 / 账号：")
        userLabel.frame = NSRect(x: 24, y: 426, width: 95, height: 20)
        contentView.addSubview(userLabel)

        usernameField = NSTextField(frame: NSRect(x: 125, y: 424, width: 330, height: 24))
        usernameField.placeholderString = "例如 2024xxxxxx"
        usernameField.stringValue = SettingsManager.shared.portalUsername
        contentView.addSubview(usernameField)

        // 密码
        let passLabel = NSTextField(labelWithString: "校园网密码：")
        passLabel.frame = NSRect(x: 24, y: 390, width: 95, height: 20)
        contentView.addSubview(passLabel)

        passwordField = NSSecureTextField(frame: NSRect(x: 125, y: 388, width: 330, height: 24))
        passwordField.placeholderString = "请输入校园网认证密码"
        passwordField.stringValue = SettingsManager.shared.portalPassword
        contentView.addSubview(passwordField)

        // 自动登录复选框
        autoLoginCheckbox = NSButton(checkboxWithTitle: "断网或切换 Wi-Fi 时自动重连并发送系统通知", target: nil, action: nil)
        autoLoginCheckbox.frame = NSRect(x: 125, y: 358, width: 330, height: 20)
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        contentView.addSubview(autoLoginCheckbox)

        // 分割线 1
        let sep1 = NSBox(frame: NSRect(x: 24, y: 346, width: 442, height: 1))
        sep1.boxType = .separator
        contentView.addSubview(sep1)

        // 自服务授权区域
        let selfTitle = NSTextField(labelWithString: "📊 自服务平台 (xywzz:8443 可用流量与消费保护)：")
        selfTitle.frame = NSRect(x: 24, y: 316, width: 300, height: 20)
        selfTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        contentView.addSubview(selfTitle)

        let openSelfBtn = NSButton(title: "🔑 登录自服务授权...", target: self, action: #selector(openSelfLoginWindow))
        openSelfBtn.bezelStyle = .rounded
        openSelfBtn.frame = NSRect(x: 325, y: 310, width: 130, height: 28)
        contentView.addSubview(openSelfBtn)

        // 分割线 2
        let sep2 = NSBox(frame: NSRect(x: 24, y: 298, width: 442, height: 1))
        sep2.boxType = .separator
        contentView.addSubview(sep2)

        // 2. 教务课表设置部分
        let courseTitle = NSTextField(labelWithString: "📚 合工大教务课表 (jxglstu.hfut.edu.cn)")
        courseTitle.frame = NSRect(x: 24, y: 268, width: 440, height: 22)
        courseTitle.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        contentView.addSubview(courseTitle)

        let courseSub = NSTextField(labelWithString: "支持从新版 EAMS 5.0 教务系统一键读取排课，并在菜单栏/小组件显示。")
        courseSub.frame = NSRect(x: 24, y: 246, width: 440, height: 18)
        courseSub.font = NSFont.systemFont(ofSize: 11)
        courseSub.textColor = .secondaryLabelColor
        contentView.addSubview(courseSub)

        let stdLabel = NSTextField(labelWithString: "课表学生ID：")
        stdLabel.frame = NSRect(x: 24, y: 212, width: 95, height: 20)
        contentView.addSubview(stdLabel)

        courseStudentIdField = NSTextField(frame: NSRect(x: 125, y: 210, width: 130, height: 24))
        courseStudentIdField.placeholderString = "例如 178506"
        courseStudentIdField.stringValue = SettingsManager.shared.courseStudentId
        contentView.addSubview(courseStudentIdField)

        let semLabel = NSTextField(labelWithString: "学期代码：")
        semLabel.frame = NSRect(x: 270, y: 212, width: 75, height: 20)
        contentView.addSubview(semLabel)

        courseSemesterIdField = NSTextField(frame: NSRect(x: 345, y: 210, width: 110, height: 24))
        courseSemesterIdField.placeholderString = "例如 354"
        courseSemesterIdField.stringValue = SettingsManager.shared.courseSemesterId
        contentView.addSubview(courseSemesterIdField)

        courseTableCheckbox = NSButton(checkboxWithTitle: "在桌面悬浮小组件与状态栏菜单中显示今日课程", target: nil, action: nil)
        courseTableCheckbox.frame = NSRect(x: 125, y: 180, width: 330, height: 20)
        courseTableCheckbox.state = SettingsManager.shared.courseTableEnabled ? .on : .off
        contentView.addSubview(courseTableCheckbox)

        // 课表操作按钮行
        let webAuthBtn = NSButton(title: "🌐 网页登录同步", target: self, action: #selector(openCourseLoginWindow))
        webAuthBtn.bezelStyle = .rounded
        webAuthBtn.frame = NSRect(x: 120, y: 142, width: 115, height: 30)
        contentView.addSubview(webAuthBtn)

        let syncCourseBtn = NSButton(title: "⚡ 一键同步", target: self, action: #selector(syncCourseClicked))
        syncCourseBtn.bezelStyle = .rounded
        syncCourseBtn.frame = NSRect(x: 240, y: 142, width: 95, height: 30)
        contentView.addSubview(syncCourseBtn)

        let viewTableBtn = NSButton(title: "📅 查看完整周课表", target: self, action: #selector(viewTableClicked))
        viewTableBtn.bezelStyle = .rounded
        viewTableBtn.frame = NSRect(x: 340, y: 142, width: 120, height: 30)
        contentView.addSubview(viewTableBtn)

        // 课表状态
        courseStatusLabel = NSTextField(labelWithString: "")
        courseStatusLabel.frame = NSRect(x: 24, y: 116, width: 440, height: 20)
        courseStatusLabel.font = NSFont.systemFont(ofSize: 11)
        courseStatusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(courseStatusLabel)

        // 分割线 3
        let sep3 = NSBox(frame: NSRect(x: 24, y: 104, width: 442, height: 1))
        sep3.boxType = .separator
        contentView.addSubview(sep3)

        // 网关状态信息
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 24, y: 64, width: 440, height: 30)
        statusLabel.font = NSFont.systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        // 底部保存与测试按钮
        let testBtn = NSButton(title: "测试网关登录", target: self, action: #selector(testLoginClicked))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: 120, y: 16, width: 115, height: 34)
        contentView.addSubview(testBtn)

        let logoutBtn = NSButton(title: "注销网关", target: self, action: #selector(logoutClicked))
        logoutBtn.bezelStyle = .rounded
        logoutBtn.frame = NSRect(x: 240, y: 16, width: 95, height: 34)
        contentView.addSubview(logoutBtn)

        let saveBtn = NSButton(title: "保存设置", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 340, y: 16, width: 115, height: 34)
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

        updateCourseStatusDisplay()

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
            courseStatusLabel.stringValue = "尚未同步课表，可点击「网页登录同步」或「一键同步」"
            courseStatusLabel.textColor = .secondaryLabelColor
        }
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
    }

    private func saveCredentials() {
        SettingsManager.shared.portalUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.portalPassword = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.autoLoginPortal = (autoLoginCheckbox.state == .on)
        SettingsManager.shared.courseStudentId = courseStudentIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.courseSemesterId = courseSemesterIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.courseTableEnabled = (courseTableCheckbox.state == .on)
    }
}
