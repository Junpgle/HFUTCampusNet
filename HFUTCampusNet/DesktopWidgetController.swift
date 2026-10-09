import Foundation
import AppKit

public class DesktopWidgetController: NSWindowController, NetworkSpeedMonitorDelegate {
    public static let shared = DesktopWidgetController()

    private var visualEffectView: NSVisualEffectView!
    private var usedFlowNumLabel: NSTextField!
    private var usedFlowUnitLabel: NSTextField!
    private var availFlowNumLabel: NSTextField!
    private var availFlowUnitLabel: NSTextField!
    private var protNumLabel: NSTextField!
    private var protUnitLabel: NSTextField!
    private var balNumLabel: NSTextField!
    private var balUnitLabel: NSTextField!
    private var updateTimeLabel: NSTextField!
    private var speedBadgeLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var courseTitleLabel: NSTextField!
    private var courseDetailLabel: NSTextField!

    private var currentData: CampusNetworkData = CampusNetworkData()
    private var currentSpeedString: String = "↓ 0B/s  ↑ 0B/s"
    private var carouselTimer: Timer?
    private var carouselIndex: Int = 0

    private init() {
        let width: CGFloat = 340
        let height: CGFloat = 256

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let savedOrigin = SettingsManager.shared.widgetOrigin
        let initialX = savedOrigin?.x ?? (screen.maxX - width - 24)
        let initialY = savedOrigin?.y ?? (screen.maxY - height - 36)

        let window = CustomDraggableWindow(
            contentRect: NSRect(x: initialX, y: initialY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: window)
        setupUI(width: width, height: height)

        NetworkSpeedMonitor.shared.start()
        startSpeedCarousel()

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
        updateCourseDisplay()
    }

    @objc private func onDormElectricityUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.renderBottomLabel()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(width: CGFloat, height: CGFloat) {
        guard let window = self.window else { return }

        // 毛玻璃背景
        visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1.0
        visualEffectView.layer?.borderColor = NSColor.separatorColor.cgColor

        window.contentView = visualEffectView

        // 顶部小标题栏
        let titleLabel = NSTextField(labelWithString: "合工大校园网")
        titleLabel.frame = NSRect(x: 16, y: height - 28, width: 85, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        visualEffectView.addSubview(titleLabel)

        // 顶部微型实时网速胶囊标签
        speedBadgeLabel = NSTextField(labelWithString: "↓ 0K/s  ↑ 0K/s")
        speedBadgeLabel.frame = NSRect(x: 102, y: height - 28, width: 175, height: 18)
        speedBadgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        speedBadgeLabel.textColor = NSColor.systemTeal
        visualEffectView.addSubview(speedBadgeLabel)

        // 刷新按钮
        let refreshBtn = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新") ?? NSImage(), target: self, action: #selector(refreshClicked))
        refreshBtn.isBordered = false
        refreshBtn.frame = NSRect(x: width - 52, y: height - 28, width: 18, height: 18)
        refreshBtn.toolTip = "立即刷新数据"
        visualEffectView.addSubview(refreshBtn)

        // 关闭按钮
        let closeBtn = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "隐藏") ?? NSImage(), target: self, action: #selector(hideWidget))
        closeBtn.isBordered = false
        closeBtn.frame = NSRect(x: width - 30, y: height - 28, width: 18, height: 18)
        closeBtn.toolTip = "隐藏桌面组件 (可在顶部菜单栏重新开启)"
        visualEffectView.addSubview(closeBtn)

        // 四格卡片区域
        let cardW: CGFloat = 148
        let cardH: CGFloat = 62
        let marginX: CGFloat = 14
        let row1Y: CGFloat = height - 98
        let row2Y: CGFloat = height - 168

        // 卡片 1: 已用流量 (左上)
        let (card1, num1, unit1) = makeMetricCard(
            frame: NSRect(x: marginX, y: row1Y, width: cardW, height: cardH),
            label: "已用流量",
            defaultNum: "--",
            defaultUnit: "M"
        )
        usedFlowNumLabel = num1
        usedFlowUnitLabel = unit1
        visualEffectView.addSubview(card1)

        // 卡片 2: 可用流量 (右上 - 支持点击授权)
        let (card2, num2, unit2) = makeMetricCard(
            frame: NSRect(x: marginX + cardW + 12, y: row1Y, width: cardW, height: cardH),
            label: "可用流量 (点此授权)",
            defaultNum: "--",
            defaultUnit: "M",
            action: #selector(openSelfLogin)
        )
        card2.toolTip = "点击打开自服务登录窗口，授权后即可获取可用流量与保护配额"
        availFlowNumLabel = num2
        availFlowUnitLabel = unit2
        visualEffectView.addSubview(card2)

        // 卡片 3: 消费保护 (左下 - 支持点击授权)
        let (card3, num3, unit3) = makeMetricCard(
            frame: NSRect(x: marginX, y: row2Y, width: cardW, height: cardH),
            label: "消费保护",
            defaultNum: "--",
            defaultUnit: "元",
            hasHelpIcon: true,
            action: #selector(openSelfLogin)
        )
        card3.toolTip = "点击授权自服务获取保护额度"
        protNumLabel = num3
        protUnitLabel = unit3
        visualEffectView.addSubview(card3)

        // 卡片 4: 账户余额 (右下)
        let (card4, num4, unit4) = makeMetricCard(
            frame: NSRect(x: marginX + cardW + 12, y: row2Y, width: cardW, height: cardH),
            label: "账户余额",
            defaultNum: "--",
            defaultUnit: "元"
        )
        balNumLabel = num4
        balUnitLabel = unit4
        visualEffectView.addSubview(card4)

        // 课程卡片区域 (横跨两列)
        let courseCardH: CGFloat = 44
        let courseCardY: CGFloat = 34
        let (cardCourse, cTitle, cDetail) = makeCourseCard(
            frame: NSRect(x: marginX, y: courseCardY, width: width - marginX * 2, height: courseCardH)
        )
        courseTitleLabel = cTitle
        courseDetailLabel = cDetail
        visualEffectView.addSubview(cardCourse)

        // 底部进度条
        progressBar = NSProgressIndicator(frame: NSRect(x: marginX, y: 19, width: width - marginX * 2, height: 4))
        progressBar.isIndeterminate = false
        progressBar.minValue = 0.0
        progressBar.maxValue = 100.0
        progressBar.doubleValue = 0.0
        visualEffectView.addSubview(progressBar)

        // 底部轮播文本栏
        updateTimeLabel = NSTextField(labelWithString: "等待更新...")
        updateTimeLabel.frame = NSRect(x: marginX, y: 3, width: width - marginX * 2, height: 14)
        updateTimeLabel.font = NSFont.systemFont(ofSize: 9.5)
        updateTimeLabel.textColor = .tertiaryLabelColor
        updateTimeLabel.toolTip = "点击打开校园用量统计与历史分析窗口"
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(bottomLabelClicked))
        updateTimeLabel.addGestureRecognizer(clickGesture)
        visualEffectView.addSubview(updateTimeLabel)
    }

    private func makeMetricCard(frame: NSRect, label: String, defaultNum: String, defaultUnit: String, hasHelpIcon: Bool = false, action: Selector? = nil) -> (NSView, NSTextField, NSTextField) {
        let card: NSView
        if let act = action {
            let button = ClickableCardButton(frame: frame)
            button.target = self
            button.action = act
            card = button
        } else {
            card = NSView(frame: frame)
        }

        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor

        if hasHelpIcon {
            let helpImg = NSImageView(frame: NSRect(x: 8, y: frame.height - 20, width: 12, height: 12))
            helpImg.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
            helpImg.contentTintColor = .tertiaryLabelColor
            card.addSubview(helpImg)
        }

        let numLabel = NSTextField(labelWithString: defaultNum)
        numLabel.frame = NSRect(x: 10, y: 22, width: frame.width - 40, height: 28)
        numLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        numLabel.textColor = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 1.0)
        numLabel.alignment = .center
        card.addSubview(numLabel)

        let unitLabel = NSTextField(labelWithString: defaultUnit)
        unitLabel.frame = NSRect(x: frame.width - 32, y: 24, width: 28, height: 16)
        unitLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        unitLabel.textColor = .secondaryLabelColor
        card.addSubview(unitLabel)

        let title = NSTextField(labelWithString: label)
        title.frame = NSRect(x: 0, y: 6, width: frame.width, height: 16)
        title.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        card.addSubview(title)

        return (card, numLabel, unitLabel)
    }

    private func makeCourseCard(frame: NSRect) -> (NSView, NSTextField, NSTextField) {
        let button = ClickableCardButton(frame: frame)
        button.target = self
        button.action = #selector(courseCardClicked)
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor

        let icon = NSImageView(frame: NSRect(x: 10, y: 14, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "book.closed.fill", accessibilityDescription: nil)
        icon.contentTintColor = NSColor.systemIndigo
        button.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: "📚 正在加载今日课程...")
        titleLabel.frame = NSRect(x: 32, y: 22, width: frame.width - 40, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        button.addSubview(titleLabel)

        let detailLabel = NSTextField(labelWithString: "点击查看完整周课表")
        detailLabel.frame = NSRect(x: 32, y: 5, width: frame.width - 40, height: 15)
        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        button.addSubview(detailLabel)

        return (button, titleLabel, detailLabel)
    }

    @objc private func onCourseScheduleUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.updateCourseDisplay()
        }
    }

    private func updateCourseDisplay() {
        guard let titleLabel = courseTitleLabel, let detailLabel = courseDetailLabel else { return }

        guard let schedule = CourseScheduleService.shared.currentSchedule, !schedule.lessons.isEmpty else {
            titleLabel.stringValue = "📚 教务课表: 点击同步课程"
            titleLabel.textColor = NSColor.systemBlue
            detailLabel.stringValue = "支持合工大 EAMS 5.0 课表自动读取与提醒"
            detailLabel.textColor = .secondaryLabelColor
            return
        }

        let now = Date()
        let todayLessons = schedule.todayLessons(at: now)
        let currentWeek = schedule.currentWeek(at: now) ?? 1
        let weekStr = "第 \(currentWeek) 周"

        if let ongoing = schedule.currentLesson(at: now) {
            titleLabel.stringValue = "🟢 上课中: \(ongoing.courseName)"
            titleLabel.textColor = NSColor.systemGreen
            let room = ongoing.classroom.map { "@ \($0)" } ?? ""
            detailLabel.stringValue = "\(ongoing.formattedTime) \(room) | 教师: \(ongoing.teacher ?? "--")"
            detailLabel.textColor = .labelColor
        } else if let next = schedule.nextLesson(at: now) {
            titleLabel.stringValue = "📚 下一节: \(next.formattedStartTime) \(next.courseName)"
            titleLabel.textColor = NSColor.systemIndigo
            let room = next.classroom.map { "@ \($0)" } ?? "待定"
            detailLabel.stringValue = "地点: \(room) | \(next.formattedTime)"
            detailLabel.textColor = .secondaryLabelColor
        } else if !todayLessons.isEmpty {
            titleLabel.stringValue = "🎉 今日课程已全部结束"
            titleLabel.textColor = .labelColor
            detailLabel.stringValue = "今日共 \(todayLessons.count) 节课 · \(weekStr) · 点击查看完整课表"
            detailLabel.textColor = .secondaryLabelColor
        } else {
            titleLabel.stringValue = "🎉 今日暂无排课"
            titleLabel.textColor = .labelColor
            detailLabel.stringValue = "\(weekStr) · 周\(CourseCalendarHelper.weekday(from: now)) · 点击查看完整周课表"
            detailLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func courseCardClicked() {
        CourseScheduleWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startSpeedCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            self?.renderBottomLabel()
        }
    }

    public func speedMonitorDidUpdate(download: String, upload: String, compact: String) {
        currentSpeedString = "↓ \(download)   ↑ \(upload)"
        speedBadgeLabel?.stringValue = compact
    }

    public func updateData(_ data: CampusNetworkData) {
        currentData = data
        let (usedNum, usedUnit) = splitNumAndUnit(data.usedFlow, fallbackUnit: "M")
        let (availNum, availUnit) = splitNumAndUnit(data.availableFlow, fallbackUnit: "M")
        let (protNum, protUnit) = splitNumAndUnit(data.flowProtection, fallbackUnit: "元")
        let (balNum, balUnit) = splitNumAndUnit(data.balance, fallbackUnit: "元")

        usedFlowNumLabel.stringValue = usedNum
        usedFlowUnitLabel.stringValue = usedUnit

        availFlowNumLabel.stringValue = availNum
        availFlowUnitLabel.stringValue = availUnit

        protNumLabel.stringValue = protNum
        protUnitLabel.stringValue = protUnit

        balNumLabel.stringValue = balNum
        balUnitLabel.stringValue = balUnit

        let percentage = data.usagePercentage * 100.0
        progressBar.doubleValue = min(max(percentage, 0.0), 100.0)

        updateCourseDisplay()
        renderBottomLabel()
    }

    private func renderBottomLabel() {
        carouselIndex = (carouselIndex + 1) % 3

        if let err = currentData.errorMessage {
            updateTimeLabel.stringValue = err
            updateTimeLabel.textColor = .systemRed
            return
        }

        switch carouselIndex {
        case 0:
            // 实时网速
            updateTimeLabel.stringValue = "🚀 实时速率: \(currentSpeedString)"
            updateTimeLabel.textColor = NSColor.systemTeal
        case 1:
            // 更新时间与百分比
            let timeStr: String
            if let time = currentData.lastUpdated {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                timeStr = "更新于 \(formatter.string(from: time))"
            } else {
                timeStr = "未更新"
            }
            let percentage = currentData.usagePercentage * 100.0
            updateTimeLabel.stringValue = "\(timeStr) · 已用 \(String(format: "%.1f", percentage))%"
            updateTimeLabel.textColor = .tertiaryLabelColor
        default:
            // 宿舍电费与历史用量提示
            if let elec = ElectricityService.shared.latestData {
                let warn = elec.isLowBalance ? "⚠️ " : ""
                let daysLeft = CampusHistoryManager.shared.estimatedElectricityDaysRemaining
                let daysText = (daysLeft != nil) ? " · 约余\(daysLeft!)天" : ""
                updateTimeLabel.stringValue = "\(warn)⚡ 宿舍电费: \(elec.displayBalance)\(daysText)"
                updateTimeLabel.textColor = elec.isLowBalance ? NSColor.systemRed : NSColor.systemOrange
            } else {
                updateTimeLabel.stringValue = "⚡ 宿舍电费: 点击查看历史用量与配置"
                updateTimeLabel.textColor = NSColor.systemOrange
            }
        }
    }

    @objc private func bottomLabelClicked() {
        HistoryStatsWindowController.shared.showWindow(nil)
    }

    private func splitNumAndUnit(_ text: String, fallbackUnit: String) -> (String, String) {
        let pattern = "^([0-9\\.]+)\\s*(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return (text, fallbackUnit)
        }
        let numRange = Range(match.range(at: 1), in: text)
        let unitRange = Range(match.range(at: 2), in: text)
        let num = numRange != nil ? String(text[numRange!]) : text
        let unit = (unitRange != nil && !text[unitRange!].isEmpty) ? String(text[unitRange!]) : fallbackUnit
        return (num, unit)
    }

    @objc private func openSelfLogin() {
        LoginWebViewController.shared.showLoginWindow()
    }

    @objc private func refreshClicked() {
        CampusNetworkClient.shared.fetchData()
    }

    @objc public func hideWidget() {
        SettingsManager.shared.showDesktopWidget = false
        window?.orderOut(nil)
    }

    public func showWidget() {
        SettingsManager.shared.showDesktopWidget = true
        window?.makeKeyAndOrderFront(nil)
    }

    public func toggleWidget() {
        if window?.isVisible == true {
            hideWidget()
        } else {
            showWidget()
        }
    }
}

class CustomDraggableWindow: NSWindow {
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        SettingsManager.shared.widgetOrigin = self.frame.origin
    }
}

// 可点击的卡片按钮
class ClickableCardButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.isBordered = false
        self.title = ""
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
