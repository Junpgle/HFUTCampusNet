import Foundation
import AppKit

public class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    public static let shared = SettingsWindowController()

    // 校园网网关与信息门户控件
    private var usernameField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var casPasswordField: NSSecureTextField!
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
    private var initialUsername: String = ""
    private var initialStdId: String = ""

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 590),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "偏好设置"
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onExternalServiceUpdated),
            name: .courseScheduleDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onExternalServiceUpdated),
            name: .dormElectricityDidUpdate,
            object: nil
        )
    }

    @objc private func onExternalServiceUpdated() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !SettingsManager.shared.courseStudentId.isEmpty {
                self.courseStudentIdField?.stringValue = SettingsManager.shared.courseStudentId
            }
            if !SettingsManager.shared.courseSemesterId.isEmpty {
                self.courseSemesterIdField?.stringValue = SettingsManager.shared.courseSemesterId
            }
            self.updateCourseStatusDisplay()
            self.updateDormStatusDisplay()
        }
    }

    @objc private func onControlChanged() {
        let prevCampus = SettingsManager.shared.dormCampus
        let prevEnd = SettingsManager.shared.dormEndNumber
        saveCredentials()
        if (prevCampus != SettingsManager.shared.dormCampus || prevEnd != SettingsManager.shared.dormEndNumber),
           SettingsManager.shared.isDormConfigured {
            ElectricityService.shared.fetchData { _ in }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeGroupCard(frame: NSRect) -> FlippedTimelineView {
        let box = FlippedTimelineView(frame: frame)
        box.dynamicCornerRadius = 8
        box.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.035)
        box.dynamicBorderColor = NSColor.labelColor.withAlphaComponent(0.10)
        box.dynamicBorderWidth = 1.0
        return box
    }

    private func makeFieldLabel(_ text: String, frame: NSRect) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.frame = frame
        lbl.alignment = .right
        lbl.font = NSFont.systemFont(ofSize: 12)
        lbl.textColor = .labelColor
        return lbl
    }

    private func makeStatusAttributedString(dotColor: NSColor, text: String, textColor: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let dotAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: dotColor,
            .baselineOffset: 1.0
        ]
        result.append(NSAttributedString(string: "● ", attributes: dotAttrs))
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: textColor
        ]
        result.append(NSAttributedString(string: text, attributes: textAttrs))
        return result
    }

    private func setupUI() {
        guard let window = self.window else { return }
        let contentView = FlippedTimelineView(frame: NSRect(x: 0, y: 0, width: 540, height: 590))

        // 0. 顶部统一身份认证与统计栏
        let ssoBox = makeGroupCard(frame: NSRect(x: 20, y: 16, width: 500, height: 54))

        let ssoTitle = NSTextField(labelWithString: "统一身份认证与全量同步")
        ssoTitle.frame = NSRect(x: 16, y: 9, width: 260, height: 18)
        ssoTitle.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        ssoTitle.textColor = .labelColor
        ssoBox.addSubview(ssoTitle)

        let ssoSub = NSTextField(labelWithString: "登录信息门户后，自动联动课表、电费与校园网自服务")
        ssoSub.frame = NSRect(x: 16, y: 29, width: 280, height: 16)
        ssoSub.font = NSFont.systemFont(ofSize: 11)
        ssoSub.textColor = .secondaryLabelColor
        ssoBox.addSubview(ssoSub)

        let statsBtn = NSButton(title: "用量统计...", target: self, action: #selector(openHistoryStatsWindow))
        statsBtn.bezelStyle = .rounded
        statsBtn.font = NSFont.systemFont(ofSize: 12)
        statsBtn.frame = NSRect(x: 298, y: 13, width: 88, height: 28)
        ssoBox.addSubview(statsBtn)

        let ssoLoginBtn = NSButton(title: "统一认证登录", target: self, action: #selector(openUnifiedLoginWindow))
        ssoLoginBtn.bezelStyle = .rounded
        ssoLoginBtn.font = NSFont.systemFont(ofSize: 12)
        ssoLoginBtn.frame = NSRect(x: 390, y: 13, width: 98, height: 28)
        ssoBox.addSubview(ssoLoginBtn)

        contentView.addSubview(ssoBox)

        // 1. 校园网与门户账号分区
        let netHeader = NSTextField(labelWithString: "校园网网关与信息门户账号")
        netHeader.frame = NSRect(x: 22, y: 84, width: 180, height: 18)
        netHeader.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        netHeader.textColor = .labelColor
        contentView.addSubview(netHeader)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 200, y: 85, width: 318, height: 16)
        statusLabel.alignment = .right
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(statusLabel)

        let netCard = makeGroupCard(frame: NSRect(x: 20, y: 106, width: 500, height: 142))

        netCard.addSubview(makeFieldLabel("学号 / 账号：", frame: NSRect(x: 12, y: 15, width: 86, height: 18)))
        usernameField = NSTextField(frame: NSRect(x: 104, y: 12, width: 380, height: 22))
        usernameField.placeholderString = "例如 2024xxxxxx"
        usernameField.stringValue = SettingsManager.shared.portalUsername
        usernameField.delegate = self
        netCard.addSubview(usernameField)

        netCard.addSubview(makeFieldLabel("校园网密码：", frame: NSRect(x: 12, y: 47, width: 86, height: 18)))
        passwordField = NSSecureTextField(frame: NSRect(x: 104, y: 44, width: 380, height: 22))
        passwordField.placeholderString = "用于校园网网关 (172.18.3.3) 与自服务系统 (xywzz:8443)"
        passwordField.stringValue = SettingsManager.shared.portalPassword
        passwordField.delegate = self
        netCard.addSubview(passwordField)

        netCard.addSubview(makeFieldLabel("信息门户密码：", frame: NSRect(x: 12, y: 79, width: 86, height: 18)))
        casPasswordField = NSSecureTextField(frame: NSRect(x: 104, y: 76, width: 380, height: 22))
        casPasswordField.placeholderString = "用于统一身份认证 (cas.hfut.edu.cn) 与教务课表同步"
        casPasswordField.stringValue = SettingsManager.shared.casPassword
        casPasswordField.delegate = self
        netCard.addSubview(casPasswordField)

        autoLoginCheckbox = NSButton(checkboxWithTitle: "断网或切换 Wi-Fi 时自动重连并发送通知", target: self, action: #selector(onControlChanged))
        autoLoginCheckbox.font = NSFont.systemFont(ofSize: 12)
        autoLoginCheckbox.frame = NSRect(x: 104, y: 110, width: 266, height: 20)
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        netCard.addSubview(autoLoginCheckbox)

        let openSelfBtn = NSButton(title: "自服务授权...", target: self, action: #selector(openSelfLoginWindow))
        openSelfBtn.bezelStyle = .rounded
        openSelfBtn.controlSize = .small
        openSelfBtn.font = NSFont.systemFont(ofSize: 11.5)
        openSelfBtn.frame = NSRect(x: 384, y: 108, width: 102, height: 24)
        netCard.addSubview(openSelfBtn)

        contentView.addSubview(netCard)

        // 2. 宿舍电费配置分区
        let elecTitle = NSTextField(labelWithString: "宿舍电费配置 (慧新易校)")
        elecTitle.frame = NSRect(x: 22, y: 262, width: 170, height: 18)
        elecTitle.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        elecTitle.textColor = .labelColor
        contentView.addSubview(elecTitle)

        dormStatusLabel = NSTextField(labelWithString: "")
        dormStatusLabel.frame = NSRect(x: 195, y: 263, width: 323, height: 16)
        dormStatusLabel.alignment = .right
        dormStatusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dormStatusLabel.textColor = .secondaryLabelColor
        dormStatusLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(dormStatusLabel)

        let elecCard = makeGroupCard(frame: NSRect(x: 20, y: 284, width: 500, height: 80))

        elecCard.addSubview(makeFieldLabel("校区：", frame: NSRect(x: 12, y: 15, width: 46, height: 18)))
        dormCampusPopup = NSPopUpButton(frame: NSRect(x: 62, y: 11, width: 148, height: 25))
        dormCampusPopup.addItems(withTitles: ["宣城校区", "合肥翡翠湖校区", "合肥屯溪路校区"])
        dormCampusPopup.selectItem(withTitle: SettingsManager.shared.dormCampus)
        dormCampusPopup.target = self
        dormCampusPopup.action = #selector(onControlChanged)
        elecCard.addSubview(dormCampusPopup)

        elecCard.addSubview(makeFieldLabel("楼栋：", frame: NSRect(x: 216, y: 15, width: 44, height: 18)))
        dormBuildingField = NSTextField(frame: NSRect(x: 264, y: 12, width: 68, height: 22))
        dormBuildingField.placeholderString = "例如 7"
        dormBuildingField.stringValue = SettingsManager.shared.dormBuilding
        dormBuildingField.delegate = self
        elecCard.addSubview(dormBuildingField)

        elecCard.addSubview(makeFieldLabel("房间：", frame: NSRect(x: 340, y: 15, width: 44, height: 18)))
        dormRoomField = NSTextField(frame: NSRect(x: 388, y: 12, width: 96, height: 22))
        dormRoomField.placeholderString = "例如 315"
        dormRoomField.stringValue = SettingsManager.shared.dormRoom
        dormRoomField.delegate = self
        elecCard.addSubview(dormRoomField)

        elecCard.addSubview(makeFieldLabel("端口：", frame: NSRect(x: 12, y: 47, width: 46, height: 18)))
        dormEndPopup = NSPopUpButton(frame: NSRect(x: 62, y: 43, width: 148, height: 25))
        dormEndPopup.addItem(withTitle: "南楼/南照明 (11)")
        dormEndPopup.lastItem?.representedObject = "11"
        dormEndPopup.addItem(withTitle: "南楼空调 (12)")
        dormEndPopup.lastItem?.representedObject = "12"
        dormEndPopup.addItem(withTitle: "北楼/北照明 (21)")
        dormEndPopup.lastItem?.representedObject = "21"
        dormEndPopup.addItem(withTitle: "北楼空调 (22)")
        dormEndPopup.lastItem?.representedObject = "22"

        for item in dormEndPopup.itemArray {
            if (item.representedObject as? String) == SettingsManager.shared.dormEndNumber {
                dormEndPopup.select(item)
                break
            }
        }
        dormEndPopup.target = self
        dormEndPopup.action = #selector(onControlChanged)
        elecCard.addSubview(dormEndPopup)

        elecCard.addSubview(makeFieldLabel("预警阈值：", frame: NSRect(x: 216, y: 47, width: 66, height: 18)))
        dormThresholdField = NSTextField(frame: NSRect(x: 286, y: 44, width: 54, height: 22))
        dormThresholdField.stringValue = String(format: "%.0f", SettingsManager.shared.electricityLowWarningThreshold)
        dormThresholdField.delegate = self
        elecCard.addSubview(dormThresholdField)

        let yuanLabel = NSTextField(labelWithString: "元")
        yuanLabel.frame = NSRect(x: 344, y: 47, width: 20, height: 18)
        yuanLabel.font = NSFont.systemFont(ofSize: 12)
        yuanLabel.textColor = .secondaryLabelColor
        elecCard.addSubview(yuanLabel)

        let testElecBtn = NSButton(title: "查询电费", target: self, action: #selector(testElectricityClicked))
        testElecBtn.bezelStyle = .rounded
        testElecBtn.controlSize = .small
        testElecBtn.font = NSFont.systemFont(ofSize: 11.5)
        testElecBtn.frame = NSRect(x: 388, y: 43, width: 98, height: 24)
        elecCard.addSubview(testElecBtn)

        contentView.addSubview(elecCard)

        // 3. 教务课表设置分区
        let courseTitle = NSTextField(labelWithString: "教务课表 (jxglstu.hfut.edu.cn)")
        courseTitle.frame = NSRect(x: 22, y: 378, width: 200, height: 18)
        courseTitle.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        courseTitle.textColor = .labelColor
        contentView.addSubview(courseTitle)

        courseStatusLabel = NSTextField(labelWithString: "")
        courseStatusLabel.frame = NSRect(x: 225, y: 379, width: 293, height: 16)
        courseStatusLabel.alignment = .right
        courseStatusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        courseStatusLabel.textColor = .secondaryLabelColor
        courseStatusLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(courseStatusLabel)

        let courseCard = makeGroupCard(frame: NSRect(x: 20, y: 400, width: 500, height: 112))

        courseCard.addSubview(makeFieldLabel("学生 ID：", frame: NSRect(x: 12, y: 15, width: 66, height: 18)))
        courseStudentIdField = NSTextField(frame: NSRect(x: 82, y: 12, width: 150, height: 22))
        courseStudentIdField.placeholderString = "自动识别 (或手动填写)"
        courseStudentIdField.stringValue = SettingsManager.shared.courseStudentId
        courseStudentIdField.delegate = self
        courseCard.addSubview(courseStudentIdField)

        courseCard.addSubview(makeFieldLabel("学期代码：", frame: NSRect(x: 246, y: 15, width: 68, height: 18)))
        courseSemesterIdField = NSTextField(frame: NSRect(x: 318, y: 12, width: 166, height: 22))
        courseSemesterIdField.placeholderString = "例如 354"
        courseSemesterIdField.stringValue = SettingsManager.shared.courseSemesterId
        courseSemesterIdField.delegate = self
        courseCard.addSubview(courseSemesterIdField)

        courseTableCheckbox = NSButton(checkboxWithTitle: "在桌面悬浮组件与状态栏菜单中显示今日课程", target: self, action: #selector(onControlChanged))
        courseTableCheckbox.font = NSFont.systemFont(ofSize: 12)
        courseTableCheckbox.frame = NSRect(x: 82, y: 44, width: 390, height: 20)
        courseTableCheckbox.state = SettingsManager.shared.courseTableEnabled ? .on : .off
        courseCard.addSubview(courseTableCheckbox)

        let webAuthBtn = NSButton(title: "网页授权同步", target: self, action: #selector(openCourseLoginWindow))
        webAuthBtn.bezelStyle = .rounded
        webAuthBtn.controlSize = .small
        webAuthBtn.font = NSFont.systemFont(ofSize: 11.5)
        webAuthBtn.frame = NSRect(x: 82, y: 74, width: 104, height: 24)
        courseCard.addSubview(webAuthBtn)

        let syncCourseBtn = NSButton(title: "一键同步", target: self, action: #selector(syncCourseClicked))
        syncCourseBtn.bezelStyle = .rounded
        syncCourseBtn.controlSize = .small
        syncCourseBtn.font = NSFont.systemFont(ofSize: 11.5)
        syncCourseBtn.frame = NSRect(x: 194, y: 74, width: 88, height: 24)
        courseCard.addSubview(syncCourseBtn)

        let viewTableBtn = NSButton(title: "查看完整课表", target: self, action: #selector(viewTableClicked))
        viewTableBtn.bezelStyle = .rounded
        viewTableBtn.controlSize = .small
        viewTableBtn.font = NSFont.systemFont(ofSize: 11.5)
        viewTableBtn.frame = NSRect(x: 290, y: 74, width: 104, height: 24)
        courseCard.addSubview(viewTableBtn)

        contentView.addSubview(courseCard)

        // 4. 底部分割线与操作栏
        let bottomSep = NSBox(frame: NSRect(x: 20, y: 528, width: 500, height: 1))
        bottomSep.boxType = .separator
        contentView.addSubview(bottomSep)

        let updateBtn = NSButton(title: "检查更新...", target: self, action: #selector(checkUpdateClicked))
        updateBtn.bezelStyle = .rounded
        updateBtn.frame = NSRect(x: 20, y: 542, width: 96, height: 30)
        contentView.addSubview(updateBtn)

        let testBtn = NSButton(title: "测试网关登录", target: self, action: #selector(testLoginClicked))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: 202, y: 542, width: 106, height: 30)
        contentView.addSubview(testBtn)

        let logoutBtn = NSButton(title: "注销网关", target: self, action: #selector(logoutClicked))
        logoutBtn.bezelStyle = .rounded
        logoutBtn.frame = NSRect(x: 314, y: 542, width: 86, height: 30)
        contentView.addSubview(logoutBtn)

        let saveBtn = NSButton(title: "保存设置", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 406, y: 542, width: 114, height: 30)
        contentView.addSubview(saveBtn)

        window.contentView = contentView
    }

    @objc private func checkUpdateClicked() {
        UpdateChecker.shared.checkForUpdates(manual: true)
    }

    public func showSettings() {
        initialUsername = SettingsManager.shared.portalUsername
        initialStdId = SettingsManager.shared.courseStudentId
        usernameField.stringValue = SettingsManager.shared.portalUsername
        passwordField.stringValue = SettingsManager.shared.portalPassword
        casPasswordField.stringValue = SettingsManager.shared.casPassword
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
                guard let self = self else { return }
                switch status {
                case .online(let uid, let ip, _, let fee, _):
                    self.statusLabel.attributedStringValue = self.makeStatusAttributedString(
                        dotColor: .systemGreen,
                        text: "网关已在线 (\(uid) · \(ip) · 余额 \(String(format: "%.2f", fee)) 元)"
                    )
                case .offline(let reason):
                    self.statusLabel.attributedStringValue = self.makeStatusAttributedString(
                        dotColor: .systemOrange,
                        text: "网关未认证：\(reason)"
                    )
                case .notInCampusNet:
                    self.statusLabel.attributedStringValue = self.makeStatusAttributedString(
                        dotColor: .systemRed,
                        text: "未连接校园网"
                    )
                }
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateCourseStatusDisplay() {
        if let schedule = CourseScheduleService.shared.currentSchedule, !schedule.lessons.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            let timeStr = schedule.lastSyncTime.map { f.string(from: $0) } ?? "未知"
            courseStatusLabel.attributedStringValue = makeStatusAttributedString(
                dotColor: .systemGreen,
                text: "已同步 \(schedule.lessons.count) 节课程 (\(timeStr))"
            )
        } else {
            courseStatusLabel.stringValue = "尚未同步课表"
            courseStatusLabel.textColor = .tertiaryLabelColor
        }
    }

    private func updateDormStatusDisplay() {
        if let elec = ElectricityService.shared.latestData {
            let bal = elec.displayBalance
            let pwr = elec.displayPower
            let warn = elec.isLowBalance ? " · 低电费预警" : ""
            dormStatusLabel.attributedStringValue = makeStatusAttributedString(
                dotColor: elec.isLowBalance ? .systemRed : .systemGreen,
                text: "剩余 \(bal) · \(pwr)\(warn)",
                textColor: elec.isLowBalance ? .systemRed : .secondaryLabelColor
            )
        } else {
            dormStatusLabel.stringValue = "尚未获取电费数据"
            dormStatusLabel.textColor = .tertiaryLabelColor
        }
    }

    @objc private func testElectricityClicked() {
        saveCredentials()
        dormStatusLabel.stringValue = "正在查询宿舍电费..."
        dormStatusLabel.textColor = .secondaryLabelColor

        ElectricityService.shared.fetchData { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let elec):
                    self.updateDormStatusDisplay()
                    NotificationHelper.showNotification(
                        title: "宿舍电费查询成功",
                        subtitle: "\(SettingsManager.shared.dormRoomName)",
                        body: "当前剩余电费: \(elec.displayBalance)  剩余电量: \(elec.displayPower)"
                    )
                case .failure(let err):
                    self.dormStatusLabel.attributedStringValue = self.makeStatusAttributedString(
                        dotColor: .systemRed,
                        text: "查询失败：\(err.localizedDescription)",
                        textColor: .systemRed
                    )
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
        courseStatusLabel.stringValue = "正在同步教务课表..."
        courseStatusLabel.textColor = .secondaryLabelColor

        CourseScheduleService.shared.syncSchedule { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let schedule):
                    self.updateCourseStatusDisplay()
                    NotificationHelper.sendNotification(
                        title: "课表同步成功",
                        body: "已同步 \(schedule.lessons.count) 门排课数据"
                    )
                case .failure(let error):
                    if let syncErr = error as? CourseScheduleService.CourseSyncError, case .needLogin = syncErr {
                        self.courseStatusLabel.attributedStringValue = self.makeStatusAttributedString(
                            dotColor: .systemOrange,
                            text: "需要教务授权，正在打开登录页...",
                            textColor: .systemOrange
                        )
                        CourseLoginWebViewController.shared.showLoginWindow()
                    } else {
                        self.courseStatusLabel.attributedStringValue = self.makeStatusAttributedString(
                            dotColor: .systemRed,
                            text: "同步失败：\(error.localizedDescription)",
                            textColor: .systemRed
                        )
                    }
                }
            }
        }
    }

    @objc private func testLoginClicked() {
        let user = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !user.isEmpty else {
            statusLabel.attributedStringValue = makeStatusAttributedString(
                dotColor: .systemOrange,
                text: "请先输入学号",
                textColor: .systemOrange
            )
            return
        }

        statusLabel.stringValue = "正在检测与认证网关..."
        statusLabel.textColor = .secondaryLabelColor

        PortalAuthService.shared.login(username: user, password: pass) { [weak self] success, msg in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.statusLabel.attributedStringValue = self.makeStatusAttributedString(
                    dotColor: success ? .systemGreen : .systemRed,
                    text: msg,
                    textColor: success ? .secondaryLabelColor : .systemRed
                )
                if success {
                    self.saveCredentials()
                    CampusNetworkClient.shared.fetchData()
                }
            }
        }
    }

    @objc private func logoutClicked() {
        statusLabel.stringValue = "正在注销当前网关设备..."
        statusLabel.textColor = .secondaryLabelColor
        PortalAuthService.shared.logout { [weak self] success, msg in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.statusLabel.attributedStringValue = self.makeStatusAttributedString(
                    dotColor: success ? .systemOrange : .systemRed,
                    text: msg
                )
                CampusNetworkClient.shared.fetchData()
            }
        }
    }

    @objc private func saveClicked() {
        saveCredentials()
        handleAccountSwitchIfNeeded()
        window?.close()
        CampusNetworkClient.shared.fetchData()
        ElectricityService.shared.fetchData { _ in }
    }

    private func handleAccountSwitchIfNeeded() {
        let currentU = SettingsManager.shared.portalUsername
        guard !initialUsername.isEmpty, !currentU.isEmpty, currentU != initialUsername else { return }
        initialUsername = currentU
        SettingsManager.shared.sessionCookie = nil
        SettingsManager.shared.courseSessionCookie = nil
        SettingsManager.shared.casTgcCookie = nil
        SettingsManager.shared.huixinAuthToken = nil
        SettingsManager.shared.uniAppJwt = nil
        SettingsManager.shared.jxglstuDefaultPasswordCache = nil
        if SettingsManager.shared.courseStudentId == initialStdId {
            SettingsManager.shared.courseStudentId = ""
            courseStudentIdField?.stringValue = ""
        }
    }

    private func saveCredentials() {
        SettingsManager.shared.portalUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.portalPassword = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.casPassword = casPasswordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prevAutoLogin = SettingsManager.shared.autoLoginPortal
        let newAutoLogin = (autoLoginCheckbox.state == .on)
        SettingsManager.shared.autoLoginPortal = newAutoLogin
        if !prevAutoLogin && newAutoLogin {
            CampusNetworkClient.shared.clearManualLogout()
        }
        SettingsManager.shared.courseStudentId = courseStudentIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.courseSemesterId = courseSemesterIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prevCourseEnabled = SettingsManager.shared.courseTableEnabled
        let newCourseEnabled = (courseTableCheckbox.state == .on)
        SettingsManager.shared.courseTableEnabled = newCourseEnabled
        if prevCourseEnabled != newCourseEnabled {
            NotificationCenter.default.post(name: .courseScheduleDidUpdate, object: nil)
        }

        let prevCampus = SettingsManager.shared.dormCampus
        let prevBuilding = SettingsManager.shared.dormBuilding
        let prevRoom = SettingsManager.shared.dormRoom
        let prevEnd = SettingsManager.shared.dormEndNumber

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

        if prevCampus != SettingsManager.shared.dormCampus ||
           prevBuilding != SettingsManager.shared.dormBuilding ||
           prevRoom != SettingsManager.shared.dormRoom ||
           prevEnd != SettingsManager.shared.dormEndNumber {
            ElectricityService.shared.invalidateCacheIfDormChanged()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        saveCredentials()
        handleAccountSwitchIfNeeded()
        if SettingsManager.shared.isDormConfigured && ElectricityService.shared.latestData == nil {
            ElectricityService.shared.fetchData { _ in }
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        saveCredentials()
    }
}
