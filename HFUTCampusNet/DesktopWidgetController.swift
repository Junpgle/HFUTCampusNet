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

        let defaultScreen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var initialX = defaultScreen.maxX - width - 24
        var initialY = defaultScreen.maxY - height - 36
        if let saved = SettingsManager.shared.widgetOrigin {
            let savedRect = NSRect(x: saved.x, y: saved.y, width: width, height: height)
            if let matchingScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(savedRect) })?.visibleFrame {
                initialX = min(max(saved.x, matchingScreen.minX + 8), matchingScreen.maxX - width - 8)
                initialY = min(max(saved.y, matchingScreen.minY + 8), matchingScreen.maxY - height - 8)
            }
        }

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
            selector: #selector(onHistoryStatsUpdated),
            name: .historyStatsDidUpdate,
            object: nil
        )
        updateCourseDisplay()
    }

    @objc private func onHistoryStatsUpdated() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let todayMB = CampusHistoryManager.shared.todayFlowDeltaMB
            let todayFormatted = todayMB >= 1024.0
                ? String(format: "%.2f G", todayMB / 1024.0)
                : String(format: "%.0f M", todayMB)
            let (todayNum, todayUnit) = self.splitNumAndUnit(todayFormatted, fallbackUnit: "M")
            self.availFlowNumLabel?.stringValue = todayNum
            self.availFlowUnitLabel?.stringValue = todayUnit
            self.renderBottomLabel()
        }
    }

    @objc private func onEmptyClassroomUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.updateCourseDisplay()
            self?.renderBottomLabel()
        }
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

        // 卡片 1: 本月已用 (左上)
        let (card1, num1, unit1) = makeMetricCard(
            frame: NSRect(x: marginX, y: row1Y, width: cardW, height: cardH),
            label: "本月已用 (限200G)",
            defaultNum: "--",
            defaultUnit: "M",
            action: #selector(openFlowHistoryStats)
        )
        card1.toolTip = "本月校园网累计已用流量（每月 200GB 免费额度，400GB 封顶）· 点击查看流量统计"
        usedFlowNumLabel = num1
        usedFlowUnitLabel = unit1
        visualEffectView.addSubview(card1)

        // 卡片 2: 今日已用 (右上 - 单日限额 30GB)
        let (card2, num2, unit2) = makeMetricCard(
            frame: NSRect(x: marginX + cardW + 12, y: row1Y, width: cardW, height: cardH),
            label: "今日已用 (限30G)",
            defaultNum: "--",
            defaultUnit: "M",
            action: #selector(openFlowHistoryStats)
        )
        card2.toolTip = "今日新增校园网流量消耗（单日 30GB 限额）· 点击查看详细统计"
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
            defaultUnit: "元",
            action: #selector(openFlowHistoryStats)
        )
        card4.toolTip = "校园网账户余额 · 点击查看历史用量与余额统计"
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
            let box = AdaptiveBoxView(frame: frame)
            box.dynamicCornerRadius = 10
            box.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.05)
            box.dynamicBorderColor = NSColor.labelColor.withAlphaComponent(0.10)
            box.dynamicBorderWidth = 1.0
            card = box
        }

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

        let icon = NSImageView(frame: NSRect(x: 10, y: 14, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "book.closed.fill", accessibilityDescription: nil)
        icon.contentTintColor = NSColor.systemIndigo
        button.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: "正在加载今日课程...")
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

        let now = Date()
        let nowMin = EmptyClassroomService.currentMinutesOfDay(at: now)
        let service = EmptyClassroomService.shared

        // 如果当前自习室正在被占用或即将被占用（35分钟内），优先在卡片弹出醒目换教室提醒
        if let studyRoom = service.currentStudyRoomItem() {
            let (conflict, isOngoing, minsUntil, recs) = service.nearbySwitchRecommendations(for: studyRoom, limit: 2)
            if let occ = conflict, isOngoing {
                let nearNames = recs.map { "\($0.room.nameZh)(\($0.proximity.badgeText))" }.joined(separator: "、")
                titleLabel.stringValue = "自习冲突：\(studyRoom.nameZh) 正在\(occ.causeTitle)"
                titleLabel.textColor = NSColor.systemRed
                detailLabel.stringValue = nearNames.isEmpty ? "占用时段 \(occ.startTimeString)-\(occ.endTimeString) · 点击打开空教室面板切换" : "推荐换至：\(nearNames)"
                detailLabel.textColor = .labelColor
                return
            } else if let occ = conflict, let mins = minsUntil, mins <= 35 {
                let nearNames = recs.map { "\($0.room.nameZh)(\($0.proximity.badgeText))" }.joined(separator: "、")
                titleLabel.stringValue = "自习提醒：\(studyRoom.nameZh) \(mins) 分钟后有\(occ.causeTitle)"
                titleLabel.textColor = NSColor.systemOrange
                detailLabel.stringValue = nearNames.isEmpty ? "\(occ.startTimeString)-\(occ.endTimeString) 占用 · 点击查看附近空教室" : "建议切换：\(nearNames)"
                detailLabel.textColor = .labelColor
                return
            }
        }

        if !SettingsManager.shared.courseTableEnabled {
            if let studyRoom = service.currentStudyRoomItem() {
                titleLabel.stringValue = "当前自习：\(studyRoom.nameZh)"
                titleLabel.textColor = NSColor.systemGreen
                if let nextOcc = studyRoom.nextOccupation(afterMinutes: nowMin) {
                    detailLabel.stringValue = "空闲至 \(nextOcc.startTimeString) (\(nextOcc.shortCourseName)) · 点击查看空教室推荐"
                } else {
                    detailLabel.stringValue = "今日余下时段全部空闲 · 点击查看明日自习推荐"
                }
                detailLabel.textColor = .secondaryLabelColor
                return
            }
            let picks = service.recommendedTodayAllDayFreeRooms(limit: 2)
            if !picks.isEmpty {
                let names = picks.map { $0.nameZh }.joined(separator: "、")
                titleLabel.stringValue = "自习空教室：\(names) 全天空闲"
                titleLabel.textColor = NSColor.systemBlue
                detailLabel.stringValue = "点击打开自习空教室与时间轴面板"
            } else {
                titleLabel.stringValue = "自习空教室查询与推荐"
                titleLabel.textColor = NSColor.systemBlue
                detailLabel.stringValue = "点击查看全天空闲教室、课前换座与明日留座推荐"
            }
            detailLabel.textColor = .secondaryLabelColor
            return
        }

        guard let schedule = CourseScheduleService.shared.currentSchedule, !schedule.lessons.isEmpty else {
            if let studyRoom = service.currentStudyRoomItem() {
                titleLabel.stringValue = "当前自习：\(studyRoom.nameZh)"
                titleLabel.textColor = NSColor.systemGreen
                if let nextOcc = studyRoom.nextOccupation(afterMinutes: nowMin) {
                    detailLabel.stringValue = "空闲至 \(nextOcc.startTimeString) (\(nextOcc.shortCourseName)) · 点击查看空教室推荐"
                } else {
                    detailLabel.stringValue = "今日余下时段全部空闲 · 点击查看明日自习推荐"
                }
                detailLabel.textColor = .secondaryLabelColor
                return
            }
            titleLabel.stringValue = "教务课表：点击同步课程"
            titleLabel.textColor = NSColor.systemBlue
            detailLabel.stringValue = "支持合工大 EAMS 5.0 课表与自习空教室智能推荐"
            detailLabel.textColor = .secondaryLabelColor
            return
        }

        let todayLessons = schedule.todayLessons(at: now)
        let currentWeek = schedule.currentWeek(at: now) ?? 1
        let weekStr = "第 \(currentWeek) 周"

        if let ongoing = schedule.currentLesson(at: now) {
            titleLabel.stringValue = "上课中：\(ongoing.courseName)"
            titleLabel.textColor = NSColor.systemGreen
            let room = ongoing.classroom.map { "· \($0)" } ?? ""
            detailLabel.stringValue = "\(ongoing.formattedTime) \(room) | 教师: \(ongoing.teacher ?? "--")"
            detailLabel.textColor = .labelColor
        } else if let next = schedule.nextLesson(at: now) {
            titleLabel.stringValue = "下一节：\(next.formattedStartTime) \(next.courseName)"
            titleLabel.textColor = NSColor.systemIndigo
            let room = next.classroom.map { $0 } ?? "待定"
            detailLabel.stringValue = "地点: \(room) | \(next.formattedTime)"
            detailLabel.textColor = .secondaryLabelColor
        } else if let studyRoom = service.currentStudyRoomItem() {
            titleLabel.stringValue = "当前自习：\(studyRoom.nameZh)"
            titleLabel.textColor = NSColor.systemGreen
            if let nextOcc = studyRoom.nextOccupation(afterMinutes: nowMin) {
                detailLabel.stringValue = "空闲至 \(nextOcc.startTimeString) · 点击查看附近空教室与明日推荐"
            } else {
                detailLabel.stringValue = "今日余下全空 · 点击查看明日自习推荐"
            }
            detailLabel.textColor = .secondaryLabelColor
        } else if !todayLessons.isEmpty {
            titleLabel.stringValue = "今日课程已全部结束"
            titleLabel.textColor = .labelColor
            detailLabel.stringValue = "今日共 \(todayLessons.count) 节课 · \(weekStr) · 点击查看完整课表"
            detailLabel.textColor = .secondaryLabelColor
        } else {
            titleLabel.stringValue = "今日暂无排课"
            titleLabel.textColor = .labelColor
            let weekdayStr = CourseCalendarHelper.weekdayName(from: CourseCalendarHelper.weekday(from: now))
            detailLabel.stringValue = "\(weekStr) · \(weekdayStr) · 点击查看完整周课表"
            detailLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func courseCardClicked() {
        if !SettingsManager.shared.courseTableEnabled {
            EmptyClassroomWindowController.shared.showWindowAndSync()
            return
        }
        let schedule = CourseScheduleService.shared.currentSchedule
        if schedule == nil || schedule?.lessons.isEmpty == true {
            CourseScheduleWindowController.shared.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            CourseScheduleService.shared.syncSchedule { result in
                if case .failure(let error) = result,
                   let syncErr = error as? CourseScheduleService.CourseSyncError {
                    switch syncErr {
                    case .needLogin, .emptySchedule:
                        DispatchQueue.main.async {
                            CourseLoginWebViewController.shared.showLoginWindow()
                        }
                    default:
                        break
                    }
                }
            }
            return
        }
        let now = Date()
        let nowMin = EmptyClassroomService.currentMinutesOfDay(at: now)
        if let studyRoom = EmptyClassroomService.shared.currentStudyRoomItem() {
            if studyRoom.currentOccupation(atMinutes: nowMin) != nil || (studyRoom.minutesUntilNextOccupation(atMinutes: nowMin) ?? 999) <= 35 {
                EmptyClassroomWindowController.shared.showWindowAndSync()
                return
            }
            if schedule?.currentLesson(at: now) == nil && schedule?.nextLesson(at: now) == nil {
                EmptyClassroomWindowController.shared.showWindowAndSync()
                return
            }
        }
        CourseScheduleWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startSpeedCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.carouselIndex = (self.carouselIndex + 1) % 4
            if self.carouselIndex == 0 {
                self.updateCourseDisplay()
            }
            self.renderBottomLabel()
        }
    }

    public func speedMonitorDidUpdate(download: String, upload: String, compact: String) {
        currentSpeedString = "↓ \(download)   ↑ \(upload)"
        speedBadgeLabel?.stringValue = compact
        if carouselIndex == 0 {
            updateTimeLabel?.stringValue = "实时速率：\(currentSpeedString)"
            updateTimeLabel?.textColor = NSColor.systemTeal
        }
    }

    public func updateData(_ data: CampusNetworkData) {
        currentData = data
        let (usedNum, usedUnit) = splitNumAndUnit(data.formattedUsed, fallbackUnit: "M")
        let todayMB = CampusHistoryManager.shared.todayFlowDeltaMB
        let todayFormatted = todayMB >= 1024.0
            ? String(format: "%.2f G", todayMB / 1024.0)
            : String(format: "%.0f M", todayMB)
        let (todayNum, todayUnit) = splitNumAndUnit(todayFormatted, fallbackUnit: "M")
        let (protNum, protUnit) = splitNumAndUnit(data.flowProtection, fallbackUnit: "元")
        let (balNum, balUnit) = splitNumAndUnit(data.balance, fallbackUnit: "元")

        usedFlowNumLabel.stringValue = usedNum
        usedFlowUnitLabel.stringValue = usedUnit

        availFlowNumLabel.stringValue = todayNum
        availFlowUnitLabel.stringValue = todayUnit

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
        switch carouselIndex {
        case 0:
            // 实时网速
            updateTimeLabel.stringValue = "实时速率：\(currentSpeedString)"
            updateTimeLabel.textColor = NSColor.systemTeal
        case 1:
            // 更新时间与百分比（若网关未连接/离线则在此槽位提示）
            let percentage = currentData.usagePercentage * 100.0
            if let err = currentData.errorMessage {
                if currentData.usedMB != nil {
                    updateTimeLabel.stringValue = "\(err) · 本月已用 \(String(format: "%.1f", percentage))%"
                    updateTimeLabel.textColor = .systemOrange
                } else {
                    updateTimeLabel.stringValue = err
                    updateTimeLabel.textColor = .systemRed
                }
                return
            }
            let timeStr: String
            if let time = currentData.lastUpdated {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                timeStr = "更新于 \(formatter.string(from: time))"
            } else {
                timeStr = "未更新"
            }
            updateTimeLabel.stringValue = "\(timeStr) · 已用 \(String(format: "%.1f", percentage))%"
            updateTimeLabel.textColor = .tertiaryLabelColor
        case 2:
            // 宿舍电费与历史用量提示
            let elecData: ElectricityData? = ElectricityService.shared.latestData ?? {
                guard SettingsManager.shared.isDormConfigured,
                      let lastRec = CampusHistoryManager.shared.latestElectricityRecord else {
                    return nil
                }
                return ElectricityData(
                    campus: SettingsManager.shared.dormCampus,
                    building: SettingsManager.shared.dormBuilding,
                    room: SettingsManager.shared.dormRoom,
                    endNumber: SettingsManager.shared.dormEndNumber,
                    balanceRMB: lastRec.balanceRMB,
                    remainingKWh: lastRec.remainingKWh ?? ((lastRec.balanceRMB / 0.58 * 10).rounded() / 10.0),
                    lastUpdated: lastRec.lastUpdated
                )
            }()
            if let elec = elecData {
                let warn = elec.isLowBalance ? "余额偏低 · " : ""
                let daysLeft = CampusHistoryManager.shared.estimatedElectricityDaysRemaining
                let daysText = (daysLeft != nil) ? " · 约余 \(daysLeft!) 天" : ""
                updateTimeLabel.stringValue = "\(warn)宿舍电费：\(elec.displayBalance)\(daysText)"
                updateTimeLabel.textColor = elec.isLowBalance ? NSColor.systemRed : NSColor.systemOrange
            } else {
                updateTimeLabel.stringValue = "宿舍电费：点击查看历史用量与配置"
                updateTimeLabel.textColor = NSColor.systemOrange
            }
        default:
            // 自习空教室状态与推荐
            let nowMin = EmptyClassroomService.currentMinutesOfDay()
            if let record = SettingsManager.shared.currentStudyRoom {
                if let live = EmptyClassroomService.shared.currentStudyRoomItem() {
                    if let curOcc = live.currentOccupation(atMinutes: nowMin) {
                        updateTimeLabel.stringValue = "自习室：\(record.roomName) (当前\(curOcc.causeTitle)中至 \(curOcc.endTimeString) · 点击切换)"
                        updateTimeLabel.textColor = NSColor.systemRed
                    } else if let nextOcc = live.nextOccupation(afterMinutes: nowMin) {
                        updateTimeLabel.stringValue = "自习室：\(record.roomName) (空至 \(nextOcc.startTimeString) · 点击管理)"
                        updateTimeLabel.textColor = NSColor.systemGreen
                    } else {
                        updateTimeLabel.stringValue = "自习室：\(record.roomName) (今日余下全空 · 点击管理)"
                        updateTimeLabel.textColor = NSColor.systemGreen
                    }
                } else {
                    updateTimeLabel.stringValue = "自习室：\(record.roomName) (点击查看占用与推荐)"
                    updateTimeLabel.textColor = NSColor.systemGreen
                }
            } else {
                let picks = EmptyClassroomService.shared.recommendedTodayAllDayFreeRooms(limit: 2)
                if !picks.isEmpty {
                    let names = picks.map { $0.nameZh }.joined(separator: "、")
                    updateTimeLabel.stringValue = "今日全空推荐：\(names) (点击设定自习室)"
                } else {
                    updateTimeLabel.stringValue = "自习空教室：点击查询全天空闲教室与自习管理"
                }
                updateTimeLabel.textColor = NSColor.systemBlue
            }
        }
    }

    @objc private func bottomLabelClicked() {
        if carouselIndex == 3 {
            EmptyClassroomWindowController.shared.showWindowAndSync()
            return
        }
        let mode = (carouselIndex == 2) ? 1 : 0
        HistoryStatsWindowController.shared.showWindow(mode: mode)
    }

    private func splitNumAndUnit(_ text: String, fallbackUnit: String) -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "未设置" || trimmed == "无" {
            return (trimmed, "")
        }
        if trimmed.hasPrefix("--") {
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return ("--", rest.isEmpty ? fallbackUnit : rest)
        }
        let pattern = "^(-?[0-9\\.]+)\\s*(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
            return (trimmed, "")
        }
        let numRange = Range(match.range(at: 1), in: trimmed)
        let unitRange = Range(match.range(at: 2), in: trimmed)
        let num = numRange != nil ? String(trimmed[numRange!]) : trimmed
        let unit = (unitRange != nil && !trimmed[unitRange!].isEmpty) ? String(trimmed[unitRange!]) : fallbackUnit
        return (num, unit)
    }

    @objc private func openSelfLogin() {
        LoginWebViewController.shared.showLoginWindow()
    }

    @objc private func openFlowHistoryStats() {
        HistoryStatsWindowController.shared.showWindow(mode: 0)
    }

    @objc private func refreshClicked() {
        CampusNetworkClient.shared.fetchData()
        if SettingsManager.shared.courseTableEnabled {
            CourseScheduleService.shared.syncSchedule { _ in }
        }
        EmptyClassroomService.shared.syncTodayAndTomorrowStudyRooms(forceRefresh: true) { _ in }
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

// 可点击的卡片按钮（基于 draw(_:) 自适应浅色与深色模式）
class ClickableCardButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.isBordered = false
        self.title = ""
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
