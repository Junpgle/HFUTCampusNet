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

    // 应用内省电措施控件
    private var powerEnableCheckbox: NSButton!
    private var powerApplyOnACCheckbox: NSButton!
    private var powerStatusLabel: NSTextField!
    private var powerScrollView: NSScrollView!
    /// key → 「纳入」复选框（仅值类措施）
    private var powerCheckControls: [String: NSButton] = [:]
    /// key → 值控件（开关）
    private var powerValueControls: [String: NSControl] = [:]
    /// key → 可自由填写的数值框（仅值类措施）
    private var powerValueFields: [String: NSTextField] = [:]
    /// key → 说明行
    private var powerDescLabels: [String: NSTextField] = [:]
    private var powerStatusTimer: Timer?
    private let powerCardHeight: CGFloat = 516
    private let powerCardTop: CGFloat = 524

    // 宿舍电费配置控件
    private var dormCampusPopup: NSPopUpButton!
    private var dormBuildingField: NSTextField!
    private var dormRoomField: NSTextField!
    private var dormEndPopup: NSPopUpButton!
    private var dormThresholdField: NSTextField!
    private var dormStatusLabel: NSTextField!
    private var initialUsername: String = ""
    private var initialStdId: String = ""
    private var initialDormConfig: (campus: String, building: String, room: String, end: String) = ("", "", "", "")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
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
        // 省电设置被别处改动时（如菜单栏勾选项）同步刷新卡片
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPowerConfigChanged),
            name: .powerModeConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPowerSourceChanged),
            name: .powerSourceDidChange,
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
        let contentView = FlippedTimelineView(frame: NSRect(x: 0, y: 0, width: 540, height: 1256))

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
        viewTableBtn.frame = NSRect(x: 290, y: 74, width: 102, height: 24)
        courseCard.addSubview(viewTableBtn)

        let viewAcademicBtn = NSButton(title: "成绩与考试", target: self, action: #selector(viewAcademicClicked))
        viewAcademicBtn.bezelStyle = .rounded
        viewAcademicBtn.controlSize = .small
        viewAcademicBtn.font = NSFont.systemFont(ofSize: 11.5)
        viewAcademicBtn.frame = NSRect(x: 398, y: 74, width: 90, height: 24)
        courseCard.addSubview(viewAcademicBtn)

        contentView.addSubview(courseCard)

        // 4. 应用内省电措施卡片
        buildPowerSaverCard(in: contentView)

        // 5. 关于 HFUTCampusNet 与开源鸣谢卡片
        buildAboutCard(in: contentView)

        // 6. 主体放入滚动视图，底部保留固定操作栏
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 674))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.documentView = contentView
        powerScrollView = scrollView

        let footer = FlippedTimelineView(frame: NSRect(x: 0, y: 674, width: 540, height: 46))
        let footerSep = NSBox(frame: NSRect(x: 0, y: 0, width: 540, height: 1))
        footerSep.boxType = .separator
        footer.addSubview(footerSep)

        let updateBtn = NSButton(title: "检查更新...", target: self, action: #selector(checkUpdateClicked))
        updateBtn.bezelStyle = .rounded
        updateBtn.frame = NSRect(x: 20, y: 8, width: 96, height: 30)
        footer.addSubview(updateBtn)

        let testBtn = NSButton(title: "测试网关登录", target: self, action: #selector(testLoginClicked))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: 202, y: 8, width: 106, height: 30)
        footer.addSubview(testBtn)

        let logoutBtn = NSButton(title: "注销网关", target: self, action: #selector(logoutClicked))
        logoutBtn.bezelStyle = .rounded
        logoutBtn.frame = NSRect(x: 314, y: 8, width: 86, height: 30)
        footer.addSubview(logoutBtn)

        let saveBtn = NSButton(title: "保存设置", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 406, y: 8, width: 114, height: 30)
        footer.addSubview(saveBtn)

        let rootView = FlippedTimelineView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        rootView.addSubview(scrollView)
        rootView.addSubview(footer)
        window.contentView = rootView
    }

    @objc private func checkUpdateClicked() {
        UpdateChecker.shared.checkForUpdates(manual: true)
    }

    // MARK: - 应用内省电措施（仅电池供电时生效）

    private func buildPowerSaverCard(in contentView: NSView) {
        let card = makeGroupCard(frame: NSRect(x: 20, y: powerCardTop, width: 500, height: powerCardHeight))

        let title = NSTextField(labelWithString: "应用内省电措施")
        title.frame = NSRect(x: 16, y: 12, width: 300, height: 18)
        title.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        card.addSubview(title)

        powerEnableCheckbox = NSButton(checkboxWithTitle: "启用省电措施（默认仅电池供电时生效）", target: self, action: #selector(onPowerMasterChanged))
        powerEnableCheckbox.font = NSFont.systemFont(ofSize: 12)
        powerEnableCheckbox.frame = NSRect(x: 16, y: 34, width: 420, height: 20)
        powerEnableCheckbox.state = SettingsManager.shared.powerSaverEnabled ? .on : .off
        card.addSubview(powerEnableCheckbox)

        powerApplyOnACCheckbox = NSButton(checkboxWithTitle: "插电时也应用（始终省电，不再区分电源类型）", target: self, action: #selector(onPowerApplyOnACChanged))
        powerApplyOnACCheckbox.font = NSFont.systemFont(ofSize: 12)
        powerApplyOnACCheckbox.frame = NSRect(x: 16, y: 56, width: 420, height: 20)
        powerApplyOnACCheckbox.state = SettingsManager.shared.powerSaverApplyOnAC ? .on : .off
        card.addSubview(powerApplyOnACCheckbox)

        let hint = NSTextField(wrappingLabelWithString: "只调整本应用自身的后台同步与刷新节奏，不改动任何系统电源设置；改完即时生效并长期保存。")
        hint.frame = NSRect(x: 16, y: 78, width: 468, height: 30)
        hint.font = NSFont.systemFont(ofSize: 10.5)
        hint.textColor = .secondaryLabelColor
        card.addSubview(hint)

        let sepTop = NSBox(frame: NSRect(x: 14, y: 112, width: 472, height: 1))
        sepTop.boxType = .separator
        card.addSubview(sepTop)

        for (index, measure) in PowerSaver.measures.enumerated() {
            let base = 120 + CGFloat(index) * 44
            let control: NSControl

            if measure.kind == .toggle {
                let sw = NSSwitch(frame: NSRect(x: 444, y: base, width: 40, height: 24))
                sw.tag = index
                sw.target = self
                sw.action = #selector(onPowerRowChanged(_:))
                sw.state = PowerSaver.isIncluded(measure.key) ? .on : .off
                control = sw
            } else {
                let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(onPowerRowChanged(_:)))
                check.tag = index
                check.frame = NSRect(x: 16, y: base + 2, width: 18, height: 20)
                check.state = PowerSaver.isIncluded(measure.key) ? .on : .off
                card.addSubview(check)
                powerCheckControls[measure.key] = check

                control = makePowerValueField(measure: measure, frame: NSRect(x: 350, y: base + 1, width: 72, height: 22))

                let unitLabel = NSTextField(labelWithString: PowerSaver.unit(for: measure.kind))
                unitLabel.frame = NSRect(x: 428, y: base + 4, width: 56, height: 16)
                unitLabel.font = NSFont.systemFont(ofSize: 11)
                unitLabel.textColor = .secondaryLabelColor
                card.addSubview(unitLabel)
            }

            let nameLabel = NSTextField(labelWithString: measure.title)
            let nameWidth: CGFloat = measure.kind == .toggle ? 398 : 300
            nameLabel.frame = NSRect(x: 38, y: base + 4, width: nameWidth, height: 16)
            nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            nameLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(nameLabel)

            let desc = NSTextField(labelWithString: powerDescText(for: measure))
            desc.frame = NSRect(x: 38, y: base + 26, width: 446, height: 13)
            desc.font = NSFont.systemFont(ofSize: 10.5)
            desc.textColor = .secondaryLabelColor
            desc.lineBreakMode = .byTruncatingTail
            card.addSubview(desc)
            powerDescLabels[measure.key] = desc

            card.addSubview(control)
            powerValueControls[measure.key] = control
        }

        let sepBottom = NSBox(frame: NSRect(x: 14, y: 476, width: 472, height: 1))
        sepBottom.boxType = .separator
        card.addSubview(sepBottom)

        powerStatusLabel = NSTextField(labelWithString: "")
        powerStatusLabel.frame = NSRect(x: 16, y: 486, width: 468, height: 18)
        powerStatusLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(powerStatusLabel)

        contentView.addSubview(card)
    }

    /// 说明行文案：值类措施给出可填范围，插电同样生效时不再提示插电侧默认值
    private func powerDescText(for measure: PowerSaverMeasure) -> String {
        guard measure.kind != .toggle else { return measure.detail }
        var parts = [PowerSaver.rangeHint(for: measure)]
        parts.append(SettingsManager.shared.powerSaverApplyOnAC ? "插电同样生效" : measure.acHint)
        return "\(measure.detail)（\(parts.joined(separator: " · "))）"
    }

    private func updatePowerRowDescriptions() {
        for measure in PowerSaver.measures {
            powerDescLabels[measure.key]?.stringValue = powerDescText(for: measure)
        }
    }

    /// 可自由填写的数值框；失焦或回车时提交并限制在合法范围内
    private func makePowerValueField(measure: PowerSaverMeasure, frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.target = self
        field.action = #selector(onPowerValueFieldChanged(_:))
        powerValueFields[measure.key] = field
        field.stringValue = String(PowerSaver.displayValue(measure.key))
        return field
    }

    /// 提交数值框：解析、限制范围并写回（未变化时不触发重建定时器）
    private func commitPowerValueField(_ field: NSTextField?) {
        guard let field = field,
              let key = powerValueFields.first(where: { $0.value === field })?.key,
              let measure = PowerSaver.measures.first(where: { $0.key == key }) else { return }
        let current = PowerSaver.displayValue(key)
        let value = PowerSaver.clamp(field.stringValue, fallback: current, measure: measure)
        field.stringValue = String(value)
        if value != current {
            PowerSaver.setDisplayValue(value, for: key)
        }
    }

    @objc private func onPowerValueFieldChanged(_ sender: NSTextField) {
        commitPowerValueField(sender)
    }

    /// 从 SettingsManager 重新填充省电卡片（外部改动或重新打开窗口时）
    private func reloadPowerCard() {
        guard powerEnableCheckbox != nil else { return }
        powerEnableCheckbox.state = SettingsManager.shared.powerSaverEnabled ? .on : .off
        powerApplyOnACCheckbox?.state = SettingsManager.shared.powerSaverApplyOnAC ? .on : .off
        for measure in PowerSaver.measures {
            let included = PowerSaver.isIncluded(measure.key)
            powerCheckControls[measure.key]?.state = included ? .on : .off
            if let sw = powerValueControls[measure.key] as? NSSwitch {
                sw.state = included ? .on : .off
            }
            if let field = powerValueFields[measure.key] {
                field.stringValue = String(PowerSaver.displayValue(measure.key))
            }
        }
        updatePowerRowDescriptions()
        updatePowerControlEnabledStates()
        updatePowerStatusLine()
    }

    private func updatePowerControlEnabledStates() {
        let masterOn = SettingsManager.shared.powerSaverEnabled
        powerApplyOnACCheckbox?.isEnabled = masterOn
        for measure in PowerSaver.measures {
            guard let control = powerValueControls[measure.key] else { continue }
            if measure.kind == .toggle {
                control.isEnabled = masterOn
            } else {
                let check = powerCheckControls[measure.key]
                check?.isEnabled = masterOn
                control.isEnabled = masterOn && check?.state == .on
            }
        }
    }

    private func updatePowerStatusLine() {
        guard powerStatusLabel != nil else { return }
        let prefs = SettingsManager.shared
        guard prefs.powerSaverEnabled else {
            powerStatusLabel.attributedStringValue = makePowerStatus(
                .secondaryLabelColor, "省电措施已停用 · 后台始终按全速节奏同步")
            return
        }
        let onBattery = SettingsManager.isOnBatteryPower()
        let count = PowerSaver.activeCount(onBattery: onBattery)

        if prefs.powerSaverApplyOnAC {
            powerStatusLabel.attributedStringValue = makePowerStatus(
                .systemGreen,
                onBattery
                    ? (count > 0 ? "电池供电 · 已生效 \(count) 项省电措施" : "电池供电 · 尚未勾选任何省电措施")
                    : (count > 0 ? "插电 · 省电措施始终生效（\(count) 项）" : "插电 · 省电措施始终生效，尚未勾选项")
            )
            return
        }
        guard onBattery else {
            powerStatusLabel.attributedStringValue = makePowerStatus(
                .secondaryLabelColor, "接通电源 · 省电措施暂不生效")
            return
        }
        powerStatusLabel.attributedStringValue = makePowerStatus(
            .systemGreen,
            count > 0 ? "电池供电 · 已生效 \(count) 项省电措施" : "电池供电 · 尚未勾选任何省电措施"
        )
    }

    private func makePowerStatus(_ dotColor: NSColor, _ text: String) -> NSAttributedString {
        makeStatusAttributedString(dotColor: dotColor, text: text)
    }

    /// 插拔电源不会触发任何配置通知，窗口打开期间轮询一次当前电源状态
    private func startPowerStatusTimer() {
        powerStatusTimer?.invalidate()
        powerStatusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.updatePowerStatusLine()
        }
    }

    @objc private func onPowerMasterChanged() {
        SettingsManager.shared.powerSaverEnabled = (powerEnableCheckbox.state == .on)
    }

    @objc private func onPowerApplyOnACChanged() {
        SettingsManager.shared.powerSaverApplyOnAC = (powerApplyOnACCheckbox.state == .on)
    }

    @objc private func onPowerRowChanged(_ sender: NSControl) {
        guard sender.tag >= 0, sender.tag < PowerSaver.measures.count else { return }
        let measure = PowerSaver.measures[sender.tag]

        if let control = sender as? NSButton {
            // 开关类措施用 NSSwitch，不会走到这里；这里是值类措施的「纳入」复选框
            PowerSaver.setIncluded(control.state == .on, for: measure.key)
            updatePowerControlEnabledStates()
        } else if let sw = sender as? NSSwitch {
            PowerSaver.setIncluded(sw.state == .on, for: measure.key)
        }
        updatePowerStatusLine()
    }

    @objc private func onPowerConfigChanged() {
        reloadPowerCard()
    }

    @objc private func onPowerSourceChanged() {
        updatePowerStatusLine()
    }

    public func showSettings() {
        initialUsername = SettingsManager.shared.portalUsername
        initialStdId = SettingsManager.shared.courseStudentId
        initialDormConfig = (
            SettingsManager.shared.dormCampus,
            SettingsManager.shared.dormBuilding,
            SettingsManager.shared.dormRoom,
            SettingsManager.shared.dormEndNumber
        )
        usernameField.stringValue = SettingsManager.shared.portalUsername
        passwordField.stringValue = SettingsManager.shared.portalPassword
        casPasswordField.stringValue = SettingsManager.shared.casPassword
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        courseStudentIdField.stringValue = SettingsManager.shared.courseStudentId
        courseSemesterIdField.stringValue = SettingsManager.shared.courseSemesterId
        courseTableCheckbox.state = SettingsManager.shared.courseTableEnabled ? .on : .off

        let savedCampus = SettingsManager.shared.dormCampus
        if dormCampusPopup.indexOfItem(withTitle: savedCampus) != -1 {
            dormCampusPopup.selectItem(withTitle: savedCampus)
        } else if savedCampus.contains("屯溪路") {
            dormCampusPopup.selectItem(withTitle: "合肥屯溪路校区")
        } else if savedCampus.contains("合肥") || savedCampus.contains("翡翠湖") {
            dormCampusPopup.selectItem(withTitle: "合肥翡翠湖校区")
        } else {
            dormCampusPopup.selectItem(withTitle: "宣城校区")
        }
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

        reloadPowerCard()
        startPowerStatusTimer()
        powerScrollView?.contentView.scroll(to: .zero)
        powerScrollView?.reflectScrolledClipView(powerScrollView!.contentView)

        PortalAuthService.shared.checkStatus { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch status {
                case .online(let uid, let ip, _, let fee, _):
                    let ipPart = ip.isEmpty ? "" : " · \(ip)"
                    let feePart = fee >= 0 ? " · 余额 \(String(format: "%.2f", fee)) 元" : ""
                    self.statusLabel.attributedStringValue = self.makeStatusAttributedString(
                        dotColor: .systemGreen,
                        text: "网关已在线 (\(uid)\(ipPart)\(feePart))"
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
        saveCredentials()
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

    @objc private func viewAcademicClicked() {
        AcademicWindowController.shared.showWindow(mode: 0)
    }

    @objc private func syncCourseClicked() {
        saveCredentials()
        courseStatusLabel.stringValue = "正在同步教务课表..."
        courseStatusLabel.textColor = .secondaryLabelColor
        AcademicService.shared.syncAll(silent: true)

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

        saveCredentials()
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
            }
        }
    }

    @objc private func saveClicked() {
        saveCredentials()
        window?.close()
        CampusNetworkClient.shared.fetchData()
        ElectricityService.shared.fetchData { _ in }
        CampusCardService.shared.fetchData { _ in }
        AcademicService.shared.syncAll(silent: true)
    }

    private static func invalidateAccountScopedData(previousUsername: String, previousStudentID: String) {
        let previousUser = previousUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentUser = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentUser != previousUser else { return }

        CourseScheduleService.shared.clearSchedule()
        SettingsManager.shared.sessionCookie = nil
        SettingsManager.shared.courseSessionCookie = nil
        SettingsManager.shared.casTgcCookie = nil
        UnifiedLoginWebViewController.invalidateAccountSession()
        ElectricityService.shared.cancelPendingRequests()
        SettingsManager.shared.huixinAuthToken = nil
        EmptyClassroomService.shared.cancelPendingAuthentication()
        StudentPortraitEatService.shared.clearCache()
        SettingsManager.shared.uniAppJwt = nil
        SettingsManager.shared.jxglstuDefaultPasswordCache = nil
        if SettingsManager.shared.courseStudentId == previousStudentID {
            SettingsManager.shared.courseStudentId = ""
        }
        CampusCardService.shared.clearCache()
        AcademicService.shared.clearCache()
        LibraryBorrowManager.shared.clearCache()
    }

    public func handleExternalAccountSwitch(previousUsername: String, previousStudentID: String) {
        Self.invalidateAccountScopedData(
            previousUsername: previousUsername,
            previousStudentID: previousStudentID
        )
        initialUsername = SettingsManager.shared.portalUsername
        let currentStdId = SettingsManager.shared.courseStudentId
        initialStdId = currentStdId
        usernameField?.stringValue = initialUsername
        casPasswordField?.stringValue = SettingsManager.shared.casPassword
        courseStudentIdField?.stringValue = currentStdId
        updateCourseStatusDisplay()
    }

    private func handleAccountSwitchIfNeeded() {
        let currentUsername = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentUsername != initialUsername.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        handleExternalAccountSwitch(previousUsername: initialUsername, previousStudentID: initialStdId)
    }

    private func saveCredentials(checkDormInvalidation: Bool = true) {
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
        if checkDormInvalidation {
            handleAccountSwitchIfNeeded()
        }
        SettingsManager.shared.courseSemesterId = courseSemesterIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prevCourseEnabled = SettingsManager.shared.courseTableEnabled
        let newCourseEnabled = (courseTableCheckbox.state == .on)
        SettingsManager.shared.courseTableEnabled = newCourseEnabled
        if prevCourseEnabled != newCourseEnabled {
            NotificationCenter.default.post(name: .courseScheduleDidUpdate, object: nil)
        }

        if let selectedCampus = dormCampusPopup.titleOfSelectedItem {
            SettingsManager.shared.dormCampus = selectedCampus
        }
        SettingsManager.shared.dormBuilding = dormBuildingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.dormRoom = dormRoomField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedEnd = dormEndPopup.selectedItem?.representedObject as? String {
            SettingsManager.shared.dormEndNumber = selectedEnd
        }
        let prevThreshold = SettingsManager.shared.electricityLowWarningThreshold
        if let thresh = Double(dormThresholdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), thresh > 0 {
            SettingsManager.shared.electricityLowWarningThreshold = thresh
        }
        if prevThreshold != SettingsManager.shared.electricityLowWarningThreshold {
            updateDormStatusDisplay()
            NotificationCenter.default.post(name: .dormElectricityDidUpdate, object: ElectricityService.shared.latestData)
        }

        if checkDormInvalidation {
            let curCampus = SettingsManager.shared.dormCampus
            let curBuilding = SettingsManager.shared.dormBuilding
            let curRoom = SettingsManager.shared.dormRoom
            let curEnd = SettingsManager.shared.dormEndNumber
            if initialDormConfig.campus != curCampus ||
               initialDormConfig.building != curBuilding ||
               initialDormConfig.room != curRoom ||
               initialDormConfig.end != curEnd {
                initialDormConfig = (curCampus, curBuilding, curRoom, curEnd)
                ElectricityService.shared.invalidateCacheIfDormChanged()
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        powerStatusTimer?.invalidate()
        powerStatusTimer = nil
        saveCredentials(checkDormInvalidation: true)
        if SettingsManager.shared.isDormConfigured && ElectricityService.shared.latestData == nil {
            ElectricityService.shared.fetchData { _ in }
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        saveCredentials(checkDormInvalidation: false)
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        commitPowerValueField(obj.object as? NSTextField)
        saveCredentials(checkDormInvalidation: true)
    }

    // MARK: - 关于与开源鸣谢卡片

    private func buildAboutCard(in contentView: NSView) {
        let cardTop: CGFloat = powerCardTop + powerCardHeight + 16
        let card = makeGroupCard(frame: NSRect(x: 20, y: cardTop, width: 500, height: 182))

        let title = NSTextField(labelWithString: "关于 HFUTCampusNet 与开源鸣谢")
        title.frame = NSRect(x: 16, y: 12, width: 320, height: 18)
        title.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = .labelColor
        card.addSubview(title)

        let versionLabel = NSTextField(labelWithString: "当前版本：v\(UpdateChecker.shared.currentVersion) (Universal)")
        versionLabel.frame = NSRect(x: 16, y: 32, width: 280, height: 16)
        versionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        card.addSubview(versionLabel)

        let descLabel = NSTextField(labelWithString: "专为合肥工业大学（HFUT）打造的原生 macOS 状态栏与桌面效率伴侣。")
        descLabel.frame = NSRect(x: 16, y: 52, width: 468, height: 16)
        descLabel.font = NSFont.systemFont(ofSize: 11.5)
        descLabel.textColor = .labelColor
        card.addSubview(descLabel)

        let ackTitle = NSTextField(labelWithString: "🙏 特别鸣谢参考的开源项目：")
        ackTitle.frame = NSRect(x: 16, y: 74, width: 468, height: 16)
        ackTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        ackTitle.textColor = .labelColor
        card.addSubview(ackTitle)

        let ackContent = NSTextField(wrappingLabelWithString: "• Chiu-xaH/HFUT-Schedule (聚在工大) — 教务系统、统一认证 CAS 与生活服务协议参考\n• elonzh/hfut — 合工大教务系统 (EAMS) 接口封装与会话处理参考\n• drcom-generic 与工大校园网认证工具 — Dr.COM 网关协议与断线重连参考")
        ackContent.frame = NSRect(x: 16, y: 94, width: 468, height: 48)
        ackContent.font = NSFont.systemFont(ofSize: 11)
        ackContent.textColor = .secondaryLabelColor
        card.addSubview(ackContent)

        let repoBtn = NSButton(title: "🌐 访问开源项目主页", target: self, action: #selector(openGitHubRepoClicked))
        repoBtn.bezelStyle = .rounded
        repoBtn.controlSize = .small
        repoBtn.font = NSFont.systemFont(ofSize: 11)
        repoBtn.frame = NSRect(x: 14, y: 148, width: 140, height: 24)
        card.addSubview(repoBtn)

        contentView.addSubview(card)
    }

    @objc private func openGitHubRepoClicked() {
        if let url = URL(string: "https://github.com/Junpgle/HFUTCampusNet") {
            NSWorkspace.shared.open(url)
        }
    }
}
