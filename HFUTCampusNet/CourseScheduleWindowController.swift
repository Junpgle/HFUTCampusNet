import Foundation
import AppKit

public class FlippedTimelineView: NSView {
    public var dynamicBackgroundColor: NSColor? {
        didSet { needsDisplay = true }
    }
    public var dynamicBorderColor: NSColor? {
        didSet { needsDisplay = true }
    }
    public var dynamicCornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    public var dynamicBorderWidth: CGFloat = 1.0 {
        didSet { needsDisplay = true }
    }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        if let fill = dynamicBackgroundColor {
            let rect = (dynamicBorderColor != nil && dynamicBorderWidth > 0) ? bounds.insetBy(dx: 0.5, dy: 0.5) : bounds
            if dynamicCornerRadius > 0 {
                let path = NSBezierPath(roundedRect: rect, xRadius: dynamicCornerRadius, yRadius: dynamicCornerRadius)
                fill.setFill()
                path.fill()
                if let stroke = dynamicBorderColor, dynamicBorderWidth > 0 {
                    stroke.setStroke()
                    path.lineWidth = dynamicBorderWidth
                    path.stroke()
                }
            } else {
                fill.setFill()
                rect.fill()
            }
        } else if let stroke = dynamicBorderColor, dynamicBorderWidth > 0 {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: dynamicCornerRadius, yRadius: dynamicCornerRadius)
            stroke.setStroke()
            path.lineWidth = dynamicBorderWidth
            path.stroke()
        }
    }
}

public class AdaptiveBoxView: NSView {
    public var dynamicBackgroundColor: NSColor? {
        didSet { needsDisplay = true }
    }
    public var dynamicBorderColor: NSColor? {
        didSet { needsDisplay = true }
    }
    public var dynamicCornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    public var dynamicBorderWidth: CGFloat = 1.0 {
        didSet { needsDisplay = true }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if let fill = dynamicBackgroundColor {
            let rect = (dynamicBorderColor != nil && dynamicBorderWidth > 0) ? bounds.insetBy(dx: 0.5, dy: 0.5) : bounds
            if dynamicCornerRadius > 0 {
                let path = NSBezierPath(roundedRect: rect, xRadius: dynamicCornerRadius, yRadius: dynamicCornerRadius)
                fill.setFill()
                path.fill()
                if let stroke = dynamicBorderColor, dynamicBorderWidth > 0 {
                    stroke.setStroke()
                    path.lineWidth = dynamicBorderWidth
                    path.stroke()
                }
            } else {
                fill.setFill()
                rect.fill()
            }
        } else if let stroke = dynamicBorderColor, dynamicBorderWidth > 0 {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: dynamicCornerRadius, yRadius: dynamicCornerRadius)
            stroke.setStroke()
            path.lineWidth = dynamicBorderWidth
            path.stroke()
        }
    }
}

public class CourseScheduleWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = CourseScheduleWindowController()

    private var currentWeek: Int = 1
    private var maxWeek: Int = 20
    private var weekPopUp: NSPopUpButton!
    private var semesterLabel: NSTextField!
    private var statusInfoLabel: NSTextField!
    private var headerBarView: FlippedTimelineView!
    private var gridScrollView: NSScrollView!
    private var gridContainerView: FlippedTimelineView!
    private var refreshTimer: Timer?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学课程表"
        window.minSize = NSSize(width: 880, height: 600)
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScheduleUpdated),
            name: .courseScheduleDidUpdate,
            object: nil
        )

        // 每分钟刷新一次当前时间指示线，容差 5 秒允许定时器合并
        let cTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.renderSchedule()
        }
        cTimer.tolerance = 5.0
        refreshTimer = cTimer

        // 初始化当前周次
        if let schedule = CourseScheduleService.shared.currentSchedule {
            currentWeek = schedule.currentWeek() ?? 1
        }
        renderSchedule()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func windowDidResize(_ notification: Notification) {
        renderSchedule()
    }

    private func setupUI() {
        guard let window = self.window else { return }

        let mainView = NSView(frame: window.contentView!.bounds)
        mainView.autoresizingMask = [.width, .height]

        // 1. 顶部控制栏
        let topBarH: CGFloat = 56
        let topBar = AdaptiveBoxView(frame: NSRect(x: 0, y: mainView.frame.height - topBarH, width: mainView.frame.width, height: topBarH))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.dynamicBackgroundColor = .windowBackgroundColor

        // 标题与学期
        let titleLabel = NSTextField(labelWithString: "合工大课程表")
        titleLabel.frame = NSRect(x: 20, y: 26, width: 140, height: 22)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        topBar.addSubview(titleLabel)

        semesterLabel = NSTextField(labelWithString: "当前学期")
        semesterLabel.frame = NSRect(x: 20, y: 8, width: 295, height: 16)
        semesterLabel.font = NSFont.systemFont(ofSize: 11)
        semesterLabel.textColor = .secondaryLabelColor
        topBar.addSubview(semesterLabel)

        // 周次切换
        let prevWeekBtn = NSButton(title: "◀", target: self, action: #selector(prevWeekAction))
        prevWeekBtn.bezelStyle = .rounded
        prevWeekBtn.frame = NSRect(x: 320, y: 13, width: 36, height: 28)
        topBar.addSubview(prevWeekBtn)

        weekPopUp = NSPopUpButton(frame: NSRect(x: 360, y: 13, width: 130, height: 28), pullsDown: false)
        for w in 1...24 {
            weekPopUp.addItem(withTitle: "第 \(w) 周")
        }
        weekPopUp.target = self
        weekPopUp.action = #selector(weekChangedAction)
        topBar.addSubview(weekPopUp)

        let nextWeekBtn = NSButton(title: "▶", target: self, action: #selector(nextWeekAction))
        nextWeekBtn.bezelStyle = .rounded
        nextWeekBtn.frame = NSRect(x: 495, y: 13, width: 36, height: 28)
        topBar.addSubview(nextWeekBtn)

        let todayWeekBtn = NSButton(title: "本周", target: self, action: #selector(todayWeekAction))
        todayWeekBtn.bezelStyle = .rounded
        todayWeekBtn.frame = NSRect(x: 535, y: 13, width: 56, height: 28)
        topBar.addSubview(todayWeekBtn)

        // 右侧操作按钮
        let textbookBtn = NSButton(title: "教材与学分", target: self, action: #selector(openTextbooksAndCreditsAction))
        textbookBtn.bezelStyle = .rounded
        textbookBtn.frame = NSRect(x: topBar.frame.width - 325, y: 13, width: 100, height: 28)
        textbookBtn.autoresizingMask = [.minXMargin]
        topBar.addSubview(textbookBtn)

        let authBtn = NSButton(title: "网页登录同步", target: self, action: #selector(openLoginAuthAction))
        authBtn.bezelStyle = .rounded
        authBtn.frame = NSRect(x: topBar.frame.width - 220, y: 13, width: 110, height: 28)
        authBtn.autoresizingMask = [.minXMargin]
        topBar.addSubview(authBtn)

        let syncBtn = NSButton(title: "立即刷新", target: self, action: #selector(refreshScheduleAction))
        syncBtn.bezelStyle = .rounded
        syncBtn.frame = NSRect(x: topBar.frame.width - 105, y: 13, width: 90, height: 28)
        syncBtn.autoresizingMask = [.minXMargin]
        topBar.addSubview(syncBtn)

        mainView.addSubview(topBar)

        // 2. 固定星期与日期表头栏
        let headerBarH: CGFloat = 48
        headerBarView = FlippedTimelineView(frame: NSRect(x: 0, y: mainView.frame.height - topBarH - headerBarH, width: mainView.frame.width, height: headerBarH))
        headerBarView.autoresizingMask = [.width, .minYMargin]
        headerBarView.dynamicBackgroundColor = .windowBackgroundColor
        mainView.addSubview(headerBarView)

        // 3. 底部信息栏
        let bottomBarH: CGFloat = 32
        let bottomBar = AdaptiveBoxView(frame: NSRect(x: 0, y: 0, width: mainView.frame.width, height: bottomBarH))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.dynamicBackgroundColor = .windowBackgroundColor

        statusInfoLabel = NSTextField(labelWithString: "正在加载课表...")
        statusInfoLabel.frame = NSRect(x: 20, y: 6, width: mainView.frame.width - 40, height: 18)
        statusInfoLabel.autoresizingMask = [.width]
        statusInfoLabel.font = NSFont.systemFont(ofSize: 11)
        statusInfoLabel.textColor = .tertiaryLabelColor
        bottomBar.addSubview(statusInfoLabel)

        mainView.addSubview(bottomBar)

        // 4. 中间连续时间轴滚动视图
        let contentH = mainView.frame.height - topBarH - headerBarH - bottomBarH
        gridScrollView = NSScrollView(frame: NSRect(x: 0, y: bottomBarH, width: mainView.frame.width, height: contentH))
        gridScrollView.autoresizingMask = [.width, .height]
        gridScrollView.hasVerticalScroller = true
        gridScrollView.hasHorizontalScroller = false
        gridScrollView.borderType = .noBorder

        gridContainerView = FlippedTimelineView(frame: NSRect(x: 0, y: 0, width: mainView.frame.width, height: contentH))
        gridContainerView.autoresizingMask = [.width]
        gridScrollView.documentView = gridContainerView

        mainView.addSubview(gridScrollView)
        window.contentView = mainView
    }

    // MARK: - 渲染连续时间轴周课表

    public func renderSchedule() {
        guard let container = gridContainerView, let headerBar = headerBarView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        headerBar.subviews.forEach { $0.removeFromSuperview() }

        let schedule = CourseScheduleService.shared.currentSchedule
        let milestone = SemesterMilestoneInfo.calculate(schedule: schedule)
        let semTitle = schedule?.semesterName ?? milestone.semesterName
        semesterLabel?.stringValue = "\(milestone.campusName) · \(semTitle) · 进度 \(milestone.progressPercentage)% (距\(milestone.vacationName) \(milestone.remainingDays)天)"

        if let syncTime = schedule?.lastSyncTime {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            let count = schedule?.lessons.count ?? 0
            let examWeekText = milestone.examWeekStartDateString.map { " · 考试周 \($0) 至 \(milestone.examWeekEndDateString ?? $0)" } ?? " · 距考试周约 \(milestone.daysUntilExamWeek) 天"
            statusInfoLabel?.stringValue = "最后同步: \(f.string(from: syncTime)) | 本学期共 \(count) 节排课 | \(milestone.campusName)校历: \(milestone.startDateString) ~ \(milestone.endDateString) (第 \(milestone.currentWeek)/\(milestone.totalWeeks) 周\(examWeekText))"
        } else {
            statusInfoLabel?.stringValue = "尚未同步教务课表，请点击右上角「网页登录同步」"
        }

        let targetMaxWeek = max(24, schedule?.allWeeks.last ?? 24, currentWeek)
        maxWeek = targetMaxWeek
        if weekPopUp != nil {
            if weekPopUp.numberOfItems != maxWeek {
                weekPopUp.removeAllItems()
                for w in 1...maxWeek {
                    weekPopUp.addItem(withTitle: "第 \(w) 周")
                }
            }
            if currentWeek >= 1 && currentWeek <= maxWeek {
                weekPopUp.selectItem(at: currentWeek - 1)
            }
        }

        let weekLessons = schedule?.lessonsForWeek(currentWeek) ?? []
        let weekDates = schedule?.datesForWeek(currentWeek) ?? [:]

        // 时间轴范围：默认 08:00 ~ 22:00，若本周有更早或更晚的课按 60 进制分钟向上/向下扩展
        let minLessonHour = weekLessons.map { $0.startMinutes / 60 }.min() ?? 8
        let maxLessonHour = weekLessons.map { ($0.endMinutes + 59) / 60 }.max() ?? 22
        let startHour = min(8, minLessonHour)
        let endHour = min(24, max(22, maxLessonHour))
        let totalHours = max(1, endHour - startHour)
        let axisStartMin = startHour * 60

        let containerW = max(gridScrollView.contentSize.width, 860)
        let timeColumnW: CGFloat = 72
        let rightPadding: CGFloat = 14
        let dayColumnW: CGFloat = (containerW - timeColumnW - rightPadding) / 7.0

        let topPadding: CGFloat = 14
        let bottomPadding: CGFloat = 20
        let availableH = gridScrollView.contentSize.height - topPadding - bottomPadding
        let hourHeight: CGFloat = max(54.0, availableH / CGFloat(totalHours))
        let totalH = topPadding + CGFloat(totalHours) * hourHeight + bottomPadding

        container.frame = NSRect(x: 0, y: 0, width: containerW, height: totalH)

        let now = Date()
        let todayStr = CourseCalendarHelper.dateString(from: now)
        let currentWeekday = CourseCalendarHelper.weekday(from: now)
        let isCurrentWeek = (1...7).contains { d in
            guard let wDate = weekDates[d] else { return false }
            return CourseCalendarHelper.dateString(from: wDate) == todayStr
        }

        // 1. 绘制固定顶部星期与日期表头
        let timeHeaderLabel = NSTextField(labelWithString: "时间")
        timeHeaderLabel.frame = NSRect(x: 8, y: 15, width: timeColumnW - 12, height: 18)
        timeHeaderLabel.alignment = .center
        timeHeaderLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        timeHeaderLabel.textColor = .tertiaryLabelColor
        headerBar.addSubview(timeHeaderLabel)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MM/dd"
        dateFmt.timeZone = CourseCalendarHelper.beijingCalendar.timeZone

        for d in 1...7 {
            let x = timeColumnW + CGFloat(d - 1) * dayColumnW
            let headerCard = FlippedTimelineView(frame: NSRect(x: x + 2, y: 4, width: dayColumnW - 4, height: 40))
            headerCard.dynamicCornerRadius = 6

            let isToday = (isCurrentWeek && d == currentWeekday)
            if isToday {
                headerCard.dynamicBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.14)
            } else {
                headerCard.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.04)
            }

            let dayTitle = CourseCalendarHelper.weekdayName(from: d) + (isToday ? " · 今天" : "")
            let nameLabel = NSTextField(labelWithString: dayTitle)
            nameLabel.frame = NSRect(x: 0, y: 4, width: dayColumnW - 4, height: 17)
            nameLabel.alignment = .center
            nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: isToday ? .bold : .semibold)
            nameLabel.textColor = isToday ? .systemBlue : .labelColor
            headerCard.addSubview(nameLabel)

            let dateText = weekDates[d].map { dateFmt.string(from: $0) } ?? "--/--"
            let dateLabel = NSTextField(labelWithString: dateText)
            dateLabel.frame = NSRect(x: 0, y: 21, width: dayColumnW - 4, height: 15)
            dateLabel.alignment = .center
            dateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            dateLabel.textColor = isToday ? NSColor.systemBlue.withAlphaComponent(0.85) : .secondaryLabelColor
            headerCard.addSubview(dateLabel)

            headerBar.addSubview(headerCard)
        }

        let headerBottomLine = AdaptiveBoxView(frame: NSRect(x: 0, y: headerBar.frame.height - 1, width: headerBar.frame.width, height: 1))
        headerBottomLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.09)
        headerBar.addSubview(headerBottomLine)

        // 2. 绘制 7 天列背景与纵向分隔线
        let gridHeight = CGFloat(totalHours) * hourHeight
        for d in 1...7 {
            let colX = timeColumnW + CGFloat(d - 1) * dayColumnW
            let isToday = (isCurrentWeek && d == currentWeekday)
            if isToday {
                let todayBg = AdaptiveBoxView(frame: NSRect(x: colX + 1, y: topPadding, width: dayColumnW - 2, height: gridHeight))
                todayBg.dynamicBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.035)
                container.addSubview(todayBg)
            }

            let vLine = AdaptiveBoxView(frame: NSRect(x: colX, y: topPadding, width: 1, height: gridHeight))
            vLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.07)
            container.addSubview(vLine)
        }
        let rightVLine = AdaptiveBoxView(frame: NSRect(x: timeColumnW + 7 * dayColumnW, y: topPadding, width: 1, height: gridHeight))
        rightVLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.07)
        container.addSubview(rightVLine)

        // 3. 绘制左侧整点时间刻度与横向参考线（整点实线 + 半点弱辅助线）
        for h in startHour...endHour {
            let y = topPadding + CGFloat(h - startHour) * hourHeight

            let timeLabel = NSTextField(labelWithString: String(format: "%02d:00", h))
            timeLabel.frame = NSRect(x: 6, y: y - 8, width: timeColumnW - 14, height: 16)
            timeLabel.alignment = .right
            timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            timeLabel.textColor = .secondaryLabelColor
            container.addSubview(timeLabel)

            let hLine = AdaptiveBoxView(frame: NSRect(x: timeColumnW - 4, y: y, width: 7 * dayColumnW + 4, height: 1))
            hLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.08)
            container.addSubview(hLine)

            if h < endHour {
                let halfY = y + hourHeight * 0.5
                let halfLine = AdaptiveBoxView(frame: NSRect(x: timeColumnW, y: halfY, width: 7 * dayColumnW, height: 0.5))
                halfLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.04)
                container.addSubview(halfLine)
            }
        }

        // 4. 按实际开始/结束时间精确定位绘制每日课程卡片（支持同时间段重叠并排）
        for d in 1...7 {
            let dayLessons = weekLessons.filter { $0.weekday == d }.sorted {
                if $0.startMinutes != $1.startMinutes { return $0.startMinutes < $1.startMinutes }
                return $0.endMinutes < $1.endMinutes
            }
            guard !dayLessons.isEmpty else { continue }

            // 将时间上有重叠的课程分组并分配并排子列
            var groups: [[CourseLesson]] = []
            var currentGroup: [CourseLesson] = []
            var groupMaxEnd: Int = -1

            for lesson in dayLessons {
                if currentGroup.isEmpty {
                    currentGroup = [lesson]
                    groupMaxEnd = lesson.endMinutes
                } else if lesson.startMinutes < groupMaxEnd {
                    currentGroup.append(lesson)
                    groupMaxEnd = max(groupMaxEnd, lesson.endMinutes)
                } else {
                    groups.append(currentGroup)
                    currentGroup = [lesson]
                    groupMaxEnd = lesson.endMinutes
                }
            }
            if !currentGroup.isEmpty {
                groups.append(currentGroup)
            }

            let colBaseX = timeColumnW + CGFloat(d - 1) * dayColumnW
            for group in groups {
                // 使用贪心区间着色分配并排子列，使同组内不重叠的课程复用子列，避免卡片被无谓压缩
                var columnEndMinutes: [Int] = []
                var assignedColumns: [Int] = []
                for course in group {
                    if let colIdx = columnEndMinutes.firstIndex(where: { $0 <= course.startMinutes }) {
                        columnEndMinutes[colIdx] = course.endMinutes
                        assignedColumns.append(colIdx)
                    } else {
                        assignedColumns.append(columnEndMinutes.count)
                        columnEndMinutes.append(course.endMinutes)
                    }
                }
                let colCount = CGFloat(max(1, columnEndMinutes.count))
                let subColW = (dayColumnW - 6) / colCount
                for (idx, course) in group.enumerated() {
                    let subColIdx = assignedColumns[idx]
                    let startOffsetMin = CGFloat(max(0, course.startMinutes - axisStartMin))
                    let durationMin = CGFloat(max(25, course.durationMinutes))
                    let cardY = topPadding + (startOffsetMin / 60.0) * hourHeight
                    let cardH = max(32.0, (durationMin / 60.0) * hourHeight)
                    let cardX = colBaseX + 3 + CGFloat(subColIdx) * subColW

                    let cardView = makeCourseCardView(
                        frame: NSRect(x: cardX, y: cardY + 1, width: subColW - 2, height: cardH - 2),
                        course: course
                    )
                    container.addSubview(cardView)
                }
            }
        }

        // 5. 若为本周且当前时间处于时间轴范围内，绘制苹果日历风格当前时间红线
        if isCurrentWeek {
            let comps = CourseCalendarHelper.beijingCalendar.dateComponents([.hour, .minute], from: now)
            let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            if nowMin >= axisStartMin && nowMin <= endHour * 60 {
                let nowY = topPadding + CGFloat(nowMin - axisStartMin) / 60.0 * hourHeight
                let todayColX = timeColumnW + CGFloat(currentWeekday - 1) * dayColumnW

                let fullLine = NSView(frame: NSRect(x: timeColumnW, y: nowY, width: 7 * dayColumnW, height: 1))
                fullLine.wantsLayer = true
                fullLine.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
                container.addSubview(fullLine)

                let todayLine = NSView(frame: NSRect(x: todayColX, y: nowY - 0.5, width: dayColumnW, height: 2))
                todayLine.wantsLayer = true
                todayLine.layer?.backgroundColor = NSColor.systemRed.cgColor
                container.addSubview(todayLine)

                let dot = NSView(frame: NSRect(x: todayColX - 4, y: nowY - 4, width: 8, height: 8))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 4
                dot.layer?.backgroundColor = NSColor.systemRed.cgColor
                container.addSubview(dot)
            }
        }
    }

    /// 创建单节课程卡片视图（基于翻转坐标系，从上往下排布：时间 -> 课程名 -> 教室与教师）
    private func makeCourseCardView(frame: NSRect, course: CourseLesson) -> NSView {
        let card = FlippedTimelineView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 7
        card.layer?.masksToBounds = true

        // 根据课程名称计算确定性无符号哈希（避免 String.hashValue 随机盐值跨次启动变色及 abs(Int.min) 溢出崩溃）
        let stableHash = course.courseName.utf8.reduce(UInt(5381)) { ($0 &<< 5) &+ $0 &+ UInt($1) }
        let colors: [NSColor] = [
            NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 0.90), // 蓝
            NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.52, alpha: 0.90), // 绿
            NSColor(calibratedRed: 0.86, green: 0.43, blue: 0.18, alpha: 0.90), // 橙
            NSColor(calibratedRed: 0.56, green: 0.32, blue: 0.82, alpha: 0.90), // 紫
            NSColor(calibratedRed: 0.18, green: 0.56, blue: 0.74, alpha: 0.90), // 青
            NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.45, alpha: 0.90), // 玫红
        ]
        let baseColor = colors[Int(stableHash % UInt(colors.count))]
        card.layer?.backgroundColor = baseColor.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        // 左侧高亮装饰条
        let sideBar = NSView(frame: NSRect(x: 0, y: 0, width: 3.5, height: frame.height))
        sideBar.wantsLayer = true
        sideBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        card.addSubview(sideBar)

        let padX: CGFloat = 7
        let contentW = max(10, frame.width - padX - 4)

        // 1. 顶部精确时间段 (如 08:00 - 09:40)
        let timeLabel = NSTextField(labelWithString: course.formattedTime)
        timeLabel.frame = NSRect(x: padX, y: 4, width: contentW, height: 14)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        timeLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(timeLabel)

        // 2. 中部课程名称（支持自动换行）
        let nameH = max(18, min(34, frame.height - 48))
        let nameLabel = NSTextField(wrappingLabelWithString: course.courseName)
        nameLabel.frame = NSRect(x: padX, y: 19, width: contentW, height: nameH)
        nameLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.maximumNumberOfLines = nameH >= 30 ? 2 : 1
        nameLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(nameLabel)

        // 3. 教室与教师信息
        let roomStr = course.classroom ?? "待定教室"
        if frame.height >= 74 {
            let roomLabel = NSTextField(labelWithString: roomStr)
            roomLabel.frame = NSRect(x: padX, y: frame.height - 32, width: contentW, height: 15)
            roomLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            roomLabel.textColor = NSColor.white.withAlphaComponent(0.92)
            roomLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(roomLabel)

            if let teacher = course.teacher, !teacher.isEmpty {
                let teacherLabel = NSTextField(labelWithString: teacher)
                teacherLabel.frame = NSRect(x: padX, y: frame.height - 16, width: contentW, height: 14)
                teacherLabel.font = NSFont.systemFont(ofSize: 9.5)
                teacherLabel.textColor = NSColor.white.withAlphaComponent(0.82)
                teacherLabel.lineBreakMode = .byTruncatingTail
                card.addSubview(teacherLabel)
            }
        } else if frame.height >= 52 {
            let bottomInfo = course.teacher.map { "\(roomStr) · \($0)" } ?? roomStr
            let infoLabel = NSTextField(labelWithString: bottomInfo)
            infoLabel.frame = NSRect(x: padX, y: frame.height - 17, width: contentW, height: 14)
            infoLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            infoLabel.textColor = NSColor.white.withAlphaComponent(0.9)
            infoLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(infoLabel)
        }

        card.toolTip = """
        【\(course.courseName)】
        时间: \(course.formattedTime) (\(course.durationMinutes) 分钟)
        日期: \(course.dateString) (\(CourseCalendarHelper.weekdayName(from: course.weekday)))
        教室: \(course.classroom ?? "未指定")
        教师: \(course.teacher ?? "未指定")
        周次: 第 \(course.weekIndex ?? 1) 周
        """

        return card
    }

    public override func showWindow(_ sender: Any?) {
        if let schedule = CourseScheduleService.shared.currentSchedule,
           let week = schedule.currentWeek() {
            currentWeek = week
        }
        renderSchedule()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func onScheduleUpdated() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.window?.isVisible != true,
               let schedule = CourseScheduleService.shared.currentSchedule,
               let week = schedule.currentWeek() {
                self.currentWeek = week
            }
            self.renderSchedule()
        }
    }

    @objc private func prevWeekAction() {
        if currentWeek > 1 {
            currentWeek -= 1
            renderSchedule()
        }
    }

    @objc private func nextWeekAction() {
        if currentWeek < maxWeek {
            currentWeek += 1
            renderSchedule()
        }
    }

    @objc private func todayWeekAction() {
        guard let week = CourseScheduleService.shared.currentSchedule?.currentWeek() else { return }
        currentWeek = week
        renderSchedule()
    }

    @objc private func weekChangedAction(_ sender: NSPopUpButton) {
        currentWeek = sender.indexOfSelectedItem + 1
        renderSchedule()
    }

    @objc private func openTextbooksAndCreditsAction() {
        AcademicWindowController.shared.showWindow(mode: 3)
    }

    @objc private func openLoginAuthAction() {
        CourseLoginWebViewController.shared.showLoginWindow()
    }

    @objc private func refreshScheduleAction() {
        statusInfoLabel?.stringValue = "正在从合工大教务系统同步课表..."
        CourseScheduleService.shared.syncSchedule { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let schedule):
                    self?.renderSchedule()
                    NotificationHelper.sendNotification(
                        title: "🎉 课表刷新成功",
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
                        self?.statusInfoLabel?.stringValue = "⚠️ 登录已过期或需授权，正在打开登录网页..."
                        CourseLoginWebViewController.shared.showLoginWindow()
                    } else {
                        self?.statusInfoLabel?.stringValue = "❌ 同步失败: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

// MARK: - 教室全学期课表查看器 (支持按周课表 & 全学期总览)

public class ClassroomScheduleWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = ClassroomScheduleWindowController()

    private var currentRoomId: Int = 0
    private var currentRoomName: String = ""
    private var currentCampusName: String = ""
    private var selectedSemesterId: Int = CourseCalendarHelper.inferSemesterId()
    private var currentWeek: Int = 1
    private var maxWeek: Int = 20
    /// 0: 按周课表 (单周时间轴), 1: 全学期总览 (全学期课程合并周次范围)
    private var viewMode: Int = 0
    private var scheduleData: CourseScheduleData?
    private var isLoading: Bool = false
    private var activeRequestToken: UUID = UUID()

    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var semesterPopUp: NSPopUpButton!
    private var viewModeSegment: NSSegmentedControl!
    private var prevWeekBtn: NSButton!
    private var weekPopUp: NSPopUpButton!
    private var nextWeekBtn: NSButton!
    private var todayWeekBtn: NSButton!
    private var refreshBtn: NSButton!

    private var headerBarView: FlippedTimelineView!
    private var gridScrollView: NSScrollView!
    private var gridContainerView: FlippedTimelineView!
    private var statusInfoLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "教室全学期课表"
        window.minSize = NSSize(width: 940, height: 600)
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func windowDidResize(_ notification: Notification) {
        renderClassroomSchedule()
    }

    public func showClassroomSchedule(
        roomId: Int,
        roomName: String,
        campusName: String,
        initialDateString: String? = nil
    ) {
        self.currentRoomId = roomId
        self.currentRoomName = roomName
        self.currentCampusName = campusName

        let maxAllowedSemId = CourseCalendarHelper.inferSemesterId()
        if let initDateStr = initialDateString,
           let initDate = CourseCalendarHelper.parseDate(initDateStr, "12:00") {
            let inferred = CourseCalendarHelper.inferSemesterId(at: initDate)
            self.selectedSemesterId = min(inferred, maxAllowedSemId)
        } else if let userSemStr = CourseScheduleService.shared.currentSchedule?.semesterId,
                  let userSem = Int(userSemStr), userSem > 0 {
            self.selectedSemesterId = min(userSem, maxAllowedSemId)
        } else {
            self.selectedSemesterId = maxAllowedSemId
        }
        rebuildSemesterPopUpMenu()
        syncSemesterPopUpSelection()

        window?.title = "\(roomName) - 教室学期课表"
        titleLabel?.stringValue = "\(roomName)"
        subtitleLabel?.stringValue = "\(campusName) · 正在加载全学期排课..."

        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loadSchedule(
            autoFallbackSemester: false,
            forceRefresh: false,
            targetDateString: initialDateString
        )
    }

    private func rebuildSemesterPopUpMenu() {
        guard let pop = semesterPopUp else { return }
        pop.removeAllItems()
        pop.autoenablesItems = false
        for sem in EmptyClassroomService.availableSemesters {
            pop.addItem(withTitle: sem.name)
            pop.lastItem?.tag = sem.id
        }
        pop.menu?.addItem(NSMenuItem.separator())
        let unscheduledItem = NSMenuItem(title: EmptyClassroomService.nextUnscheduledSemesterTitle, action: nil, keyEquivalent: "")
        unscheduledItem.tag = -1
        unscheduledItem.isEnabled = false
        pop.menu?.addItem(unscheduledItem)
    }

    private func setupUI() {
        guard let window = self.window else { return }

        let mainView = NSView(frame: window.contentView!.bounds)
        mainView.autoresizingMask = [.width, .height]

        let topBarH: CGFloat = 58
        let topBar = AdaptiveBoxView(frame: NSRect(x: 0, y: mainView.frame.height - topBarH, width: mainView.frame.width, height: topBarH))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.dynamicBackgroundColor = .windowBackgroundColor

        titleLabel = NSTextField(labelWithString: "教室课表")
        titleLabel.frame = NSRect(x: 18, y: 28, width: 220, height: 22)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        topBar.addSubview(titleLabel)

        subtitleLabel = NSTextField(labelWithString: "全学期排课")
        subtitleLabel.frame = NSRect(x: 18, y: 8, width: 220, height: 16)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        topBar.addSubview(subtitleLabel)

        semesterPopUp = NSPopUpButton(frame: NSRect(x: 240, y: 15, width: 192, height: 28), pullsDown: false)
        rebuildSemesterPopUpMenu()
        semesterPopUp.target = self
        semesterPopUp.action = #selector(semesterChangedAction(_:))
        topBar.addSubview(semesterPopUp)

        viewModeSegment = NSSegmentedControl(
            labels: ["按周课表", "全学期总览"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(viewModeChangedAction(_:))
        )
        viewModeSegment.frame = NSRect(x: 440, y: 16, width: 156, height: 26)
        viewModeSegment.selectedSegment = 0
        topBar.addSubview(viewModeSegment)

        prevWeekBtn = NSButton(title: "◀", target: self, action: #selector(prevWeekAction))
        prevWeekBtn.bezelStyle = .rounded
        prevWeekBtn.frame = NSRect(x: 604, y: 15, width: 34, height: 28)
        topBar.addSubview(prevWeekBtn)

        weekPopUp = NSPopUpButton(frame: NSRect(x: 642, y: 15, width: 118, height: 28), pullsDown: false)
        for w in 1...24 {
            weekPopUp.addItem(withTitle: "第 \(w) 周")
        }
        weekPopUp.target = self
        weekPopUp.action = #selector(weekChangedAction(_:))
        topBar.addSubview(weekPopUp)

        nextWeekBtn = NSButton(title: "▶", target: self, action: #selector(nextWeekAction))
        nextWeekBtn.bezelStyle = .rounded
        nextWeekBtn.frame = NSRect(x: 764, y: 15, width: 34, height: 28)
        topBar.addSubview(nextWeekBtn)

        todayWeekBtn = NSButton(title: "本周", target: self, action: #selector(todayWeekAction))
        todayWeekBtn.bezelStyle = .rounded
        todayWeekBtn.frame = NSRect(x: 802, y: 15, width: 54, height: 28)
        topBar.addSubview(todayWeekBtn)

        refreshBtn = NSButton(title: "刷新课表", target: self, action: #selector(refreshAction))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.frame = NSRect(x: topBar.frame.width - 104, y: 15, width: 88, height: 28)
        refreshBtn.autoresizingMask = [.minXMargin]
        topBar.addSubview(refreshBtn)

        mainView.addSubview(topBar)

        let headerBarH: CGFloat = 48
        headerBarView = FlippedTimelineView(frame: NSRect(x: 0, y: mainView.frame.height - topBarH - headerBarH, width: mainView.frame.width, height: headerBarH))
        headerBarView.autoresizingMask = [.width, .minYMargin]
        headerBarView.dynamicBackgroundColor = .windowBackgroundColor
        mainView.addSubview(headerBarView)

        let bottomBarH: CGFloat = 32
        let bottomBar = AdaptiveBoxView(frame: NSRect(x: 0, y: 0, width: mainView.frame.width, height: bottomBarH))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.dynamicBackgroundColor = .windowBackgroundColor

        statusInfoLabel = NSTextField(labelWithString: "正在加载教室全学期课表...")
        statusInfoLabel.frame = NSRect(x: 18, y: 6, width: mainView.frame.width - 36, height: 18)
        statusInfoLabel.autoresizingMask = [.width]
        statusInfoLabel.font = NSFont.systemFont(ofSize: 11)
        statusInfoLabel.textColor = .tertiaryLabelColor
        bottomBar.addSubview(statusInfoLabel)

        mainView.addSubview(bottomBar)

        let contentH = mainView.frame.height - topBarH - headerBarH - bottomBarH
        gridScrollView = NSScrollView(frame: NSRect(x: 0, y: bottomBarH, width: mainView.frame.width, height: contentH))
        gridScrollView.autoresizingMask = [.width, .height]
        gridScrollView.hasVerticalScroller = true
        gridScrollView.hasHorizontalScroller = false
        gridScrollView.borderType = .noBorder

        gridContainerView = FlippedTimelineView(frame: NSRect(x: 0, y: 0, width: mainView.frame.width, height: contentH))
        gridContainerView.autoresizingMask = [.width]
        gridScrollView.documentView = gridContainerView

        mainView.addSubview(gridScrollView)
        window.contentView = mainView
    }

    private func syncSemesterPopUpSelection() {
        guard let pop = semesterPopUp else { return }
        for i in 0..<pop.numberOfItems {
            if pop.item(at: i)?.tag == selectedSemesterId {
                pop.selectItem(at: i)
                return
            }
        }
        let insertIdx = max(0, pop.numberOfItems - 2)
        let customItem = NSMenuItem(title: EmptyClassroomService.semesterTitle(for: selectedSemesterId), action: nil, keyEquivalent: "")
        customItem.tag = selectedSemesterId
        pop.menu?.insertItem(customItem, at: insertIdx)
        pop.selectItem(at: insertIdx)
    }

    private func loadSchedule(
        autoFallbackSemester: Bool,
        forceRefresh: Bool,
        targetDateString: String? = nil
    ) {
        guard currentRoomId > 0 else { return }
        let reqToken = UUID()
        self.activeRequestToken = reqToken
        let reqRoomId = currentRoomId
        let reqSemesterId = selectedSemesterId

        isLoading = true
        semesterPopUp?.isEnabled = false
        refreshBtn?.isEnabled = false
        refreshBtn?.title = "加载中..."
        statusInfoLabel?.stringValue = "正在从教务系统查询 \(currentRoomName) 的全学期排课数据..."
        renderClassroomSchedule()

        EmptyClassroomService.shared.fetchClassroomSemesterSchedule(
            roomId: reqRoomId,
            roomName: currentRoomName,
            semesterId: reqSemesterId,
            autoFallbackSemester: autoFallbackSemester,
            forceRefresh: forceRefresh
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.activeRequestToken == reqToken else { return }
                self.isLoading = false
                self.semesterPopUp?.isEnabled = true
                self.refreshBtn?.isEnabled = true
                self.refreshBtn?.title = "刷新课表"

                switch result {
                case .success(let data):
                    self.scheduleData = data
                    if let actualSem = Int(data.semesterId), actualSem != self.selectedSemesterId {
                        self.selectedSemesterId = actualSem
                        self.syncSemesterPopUpSelection()
                    }
                    if let dateStr = targetDateString,
                       let dateObj = CourseCalendarHelper.parseDate(dateStr, "12:00"),
                       let matchedWeek = data.currentWeek(at: dateObj) {
                        self.currentWeek = matchedWeek
                    } else if let curW = data.currentWeek() {
                        self.currentWeek = curW
                    } else {
                        self.currentWeek = data.allWeeks.first ?? 1
                    }
                    self.renderClassroomSchedule()

                case .failure(let err):
                    self.scheduleData = nil
                    self.subtitleLabel?.stringValue = "\(self.currentCampusName) · 加载失败"
                    self.statusInfoLabel?.stringValue = "❌ 查询教室课表失败：\(err.localizedDescription)"
                    self.renderClassroomSchedule()
                }
            }
        }
    }

    /// 将整学期内同一课程、同一星期、同一时间段的课节合并为一条带周次范围（如 1-16周）的汇总课程
    private func buildSemesterConsolidatedLessons(from allLessons: [CourseLesson]) -> [CourseLesson] {
        struct SlotKey: Hashable {
            let courseName: String
            let weekday: Int
            let startTime: Int
            let endTime: Int
            let classroom: String
            let teacher: String
        }
        var grouped: [SlotKey: [CourseLesson]] = [:]
        var orderKeys: [SlotKey] = []
        for l in allLessons {
            let key = SlotKey(
                courseName: l.courseName,
                weekday: l.weekday,
                startTime: l.startTime,
                endTime: l.endTime,
                classroom: l.classroom ?? "",
                teacher: l.teacher ?? ""
            )
            if grouped[key] == nil {
                orderKeys.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(l)
        }

        var result: [CourseLesson] = []
        for (idx, key) in orderKeys.enumerated() {
            guard let items = grouped[key], let first = items.first else { continue }
            let weeks = Array(Set(items.compactMap { $0.weekIndex })).sorted()
            let weekDesc = Self.formatWeekRanges(weeks)
            let merged = CourseLesson(
                id: "consolidated-\(first.lessonId)-\(idx)",
                lessonId: first.lessonId,
                courseName: "\(first.courseName) [\(weekDesc)]",
                courseCode: first.courseCode,
                teacher: first.teacher,
                classroom: first.classroom,
                dateString: weekDesc,
                startTime: first.startTime,
                endTime: first.endTime,
                weekIndex: weeks.first,
                weekday: first.weekday
            )
            result.append(merged)
        }
        return result
    }

    private static func formatWeekRanges(_ weeks: [Int]) -> String {
        guard !weeks.isEmpty else { return "全学期" }
        var segments: [String] = []
        var start = weeks[0]
        var prev = weeks[0]
        for w in weeks.dropFirst() {
            if w == prev + 1 {
                prev = w
            } else {
                segments.append(start == prev ? "\(start)" : "\(start)-\(prev)")
                start = w
                prev = w
            }
        }
        segments.append(start == prev ? "\(start)" : "\(start)-\(prev)")
        return segments.joined(separator: ",") + "周"
    }

    public func renderClassroomSchedule() {
        guard let container = gridContainerView, let headerBar = headerBarView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        headerBar.subviews.forEach { $0.removeFromSuperview() }

        let isOverviewMode = (viewMode == 1)
        prevWeekBtn?.isEnabled = !isOverviewMode && !isLoading
        weekPopUp?.isEnabled = !isOverviewMode && !isLoading
        nextWeekBtn?.isEnabled = !isOverviewMode && !isLoading
        todayWeekBtn?.isEnabled = !isOverviewMode && !isLoading

        let schedule = scheduleData
        let allLessons = schedule?.lessons ?? []
        let distinctCourseCount = Set(allLessons.map { $0.courseName }).count
        let semTitle = EmptyClassroomService.semesterTitle(for: selectedSemesterId)
        if isLoading {
            subtitleLabel?.stringValue = "\(currentCampusName) · 正在查询 \(semTitle)..."
        } else {
            subtitleLabel?.stringValue = "\(currentCampusName) · 共 \(distinctCourseCount) 门课 / \(allLessons.count) 节排课"
        }

        let targetMaxWeek = max(20, schedule?.allWeeks.last ?? 20, currentWeek)
        maxWeek = targetMaxWeek
        if weekPopUp != nil {
            if weekPopUp.numberOfItems != maxWeek {
                weekPopUp.removeAllItems()
                for w in 1...maxWeek {
                    weekPopUp.addItem(withTitle: "第 \(w) 周")
                }
            }
            if currentWeek >= 1 && currentWeek <= maxWeek {
                weekPopUp.selectItem(at: currentWeek - 1)
            }
        }

        let displayLessons: [CourseLesson]
        let weekDates: [Int: Date]
        if isOverviewMode {
            displayLessons = buildSemesterConsolidatedLessons(from: allLessons)
            weekDates = [:]
        } else {
            displayLessons = schedule?.lessonsForWeek(currentWeek) ?? []
            weekDates = schedule?.datesForWeek(currentWeek) ?? [:]
        }

        if !isLoading {
            if allLessons.isEmpty {
                statusInfoLabel?.stringValue = "ℹ️ \(currentRoomName) 在 \(semTitle) 无排课记录（注：教务系统仅开放已排课学期，当前查不到下学期的课）"
            } else if isOverviewMode {
                let weekSpan = (schedule?.allWeeks.first != nil && schedule?.allWeeks.last != nil)
                    ? "第 \(schedule!.allWeeks.first!) - \(schedule!.allWeeks.last!) 周"
                    : "全学期"
                statusInfoLabel?.stringValue = "\(currentRoomName) · \(semTitle) (\(weekSpan)) 全学期总览：共 \(distinctCourseCount) 门课程、\(allLessons.count) 节排课  ｜  注：教务系统当前查不到下学期的课"
            } else {
                statusInfoLabel?.stringValue = "\(currentRoomName) · \(semTitle) 第 \(currentWeek) 周：本周共 \(displayLessons.count) 节排课（全学期共 \(allLessons.count) 节）  ｜  注：教务系统当前查不到下学期的课"
            }
        }

        let minLessonHour = displayLessons.map { $0.startMinutes / 60 }.min() ?? 8
        let maxLessonHour = displayLessons.map { ($0.endMinutes + 59) / 60 }.max() ?? 22
        let startHour = min(8, minLessonHour)
        let endHour = min(24, max(22, maxLessonHour))
        let totalHours = max(1, endHour - startHour)
        let axisStartMin = startHour * 60

        let containerW = max(gridScrollView.contentSize.width, 860)
        let timeColumnW: CGFloat = 72
        let rightPadding: CGFloat = 14
        let dayColumnW: CGFloat = (containerW - timeColumnW - rightPadding) / 7.0

        let topPadding: CGFloat = 14
        let bottomPadding: CGFloat = 20
        let availableH = gridScrollView.contentSize.height - topPadding - bottomPadding
        let hourHeight: CGFloat = max(54.0, availableH / CGFloat(totalHours))
        let totalH = topPadding + CGFloat(totalHours) * hourHeight + bottomPadding

        container.frame = NSRect(x: 0, y: 0, width: containerW, height: totalH)

        let now = Date()
        let todayStr = CourseCalendarHelper.dateString(from: now)
        let currentWeekday = CourseCalendarHelper.weekday(from: now)
        let isCurrentWeek = !isOverviewMode && (1...7).contains { d in
            guard let wDate = weekDates[d] else { return false }
            return CourseCalendarHelper.dateString(from: wDate) == todayStr
        }

        // 1. 顶部星期与日期表头
        let timeHeaderLabel = NSTextField(labelWithString: "时间")
        timeHeaderLabel.frame = NSRect(x: 8, y: 15, width: timeColumnW - 12, height: 18)
        timeHeaderLabel.alignment = .center
        timeHeaderLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        timeHeaderLabel.textColor = .tertiaryLabelColor
        headerBar.addSubview(timeHeaderLabel)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MM/dd"
        dateFmt.timeZone = CourseCalendarHelper.beijingCalendar.timeZone

        for d in 1...7 {
            let x = timeColumnW + CGFloat(d - 1) * dayColumnW
            let headerCard = FlippedTimelineView(frame: NSRect(x: x + 2, y: 4, width: dayColumnW - 4, height: 40))
            headerCard.dynamicCornerRadius = 6

            let isToday = (isCurrentWeek && d == currentWeekday)
            headerCard.dynamicBackgroundColor = isToday
                ? NSColor.systemBlue.withAlphaComponent(0.14)
                : NSColor.labelColor.withAlphaComponent(0.04)

            let dayTitle = CourseCalendarHelper.weekdayName(from: d) + (isToday ? " · 今天" : "")
            let nameLabel = NSTextField(labelWithString: dayTitle)
            nameLabel.frame = NSRect(x: 0, y: 4, width: dayColumnW - 4, height: 17)
            nameLabel.alignment = .center
            nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: isToday ? .bold : .semibold)
            nameLabel.textColor = isToday ? .systemBlue : .labelColor
            headerCard.addSubview(nameLabel)

            let subText: String
            if isOverviewMode {
                let dayCount = displayLessons.filter { $0.weekday == d }.count
                subText = dayCount == 0 ? "全学期无课" : "\(dayCount) 个固定排课时段"
            } else {
                subText = weekDates[d].map { dateFmt.string(from: $0) } ?? "--/--"
            }
            let dateLabel = NSTextField(labelWithString: subText)
            dateLabel.frame = NSRect(x: 0, y: 21, width: dayColumnW - 4, height: 15)
            dateLabel.alignment = .center
            dateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            dateLabel.textColor = isToday ? NSColor.systemBlue.withAlphaComponent(0.85) : .secondaryLabelColor
            headerCard.addSubview(dateLabel)

            headerBar.addSubview(headerCard)
        }

        let headerBottomLine = AdaptiveBoxView(frame: NSRect(x: 0, y: headerBar.frame.height - 1, width: headerBar.frame.width, height: 1))
        headerBottomLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.09)
        headerBar.addSubview(headerBottomLine)

        // 2. 7 天列背景与分隔线
        let gridHeight = CGFloat(totalHours) * hourHeight
        for d in 1...7 {
            let colX = timeColumnW + CGFloat(d - 1) * dayColumnW
            let isToday = (isCurrentWeek && d == currentWeekday)
            if isToday {
                let todayBg = AdaptiveBoxView(frame: NSRect(x: colX + 1, y: topPadding, width: dayColumnW - 2, height: gridHeight))
                todayBg.dynamicBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.035)
                container.addSubview(todayBg)
            }

            let vLine = AdaptiveBoxView(frame: NSRect(x: colX, y: topPadding, width: 1, height: gridHeight))
            vLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.07)
            container.addSubview(vLine)
        }
        let rightVLine = AdaptiveBoxView(frame: NSRect(x: timeColumnW + 7 * dayColumnW, y: topPadding, width: 1, height: gridHeight))
        rightVLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.07)
        container.addSubview(rightVLine)

        // 3. 时间刻度线
        for h in startHour...endHour {
            let y = topPadding + CGFloat(h - startHour) * hourHeight

            let timeLabel = NSTextField(labelWithString: String(format: "%02d:00", h))
            timeLabel.frame = NSRect(x: 6, y: y - 8, width: timeColumnW - 14, height: 16)
            timeLabel.alignment = .right
            timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            timeLabel.textColor = .secondaryLabelColor
            container.addSubview(timeLabel)

            let hLine = AdaptiveBoxView(frame: NSRect(x: timeColumnW - 4, y: y, width: 7 * dayColumnW + 4, height: 1))
            hLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.08)
            container.addSubview(hLine)

            if h < endHour {
                let halfY = y + hourHeight * 0.5
                let halfLine = AdaptiveBoxView(frame: NSRect(x: timeColumnW, y: halfY, width: 7 * dayColumnW, height: 0.5))
                halfLine.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.04)
                container.addSubview(halfLine)
            }
        }

        // 4. 每日课程卡片
        for d in 1...7 {
            let dayLessons = displayLessons.filter { $0.weekday == d }.sorted {
                if $0.startMinutes != $1.startMinutes { return $0.startMinutes < $1.startMinutes }
                return $0.endMinutes < $1.endMinutes
            }
            guard !dayLessons.isEmpty else { continue }

            var groups: [[CourseLesson]] = []
            var currentGroup: [CourseLesson] = []
            var groupMaxEnd: Int = -1

            for lesson in dayLessons {
                if currentGroup.isEmpty {
                    currentGroup = [lesson]
                    groupMaxEnd = lesson.endMinutes
                } else if lesson.startMinutes < groupMaxEnd {
                    currentGroup.append(lesson)
                    groupMaxEnd = max(groupMaxEnd, lesson.endMinutes)
                } else {
                    groups.append(currentGroup)
                    currentGroup = [lesson]
                    groupMaxEnd = lesson.endMinutes
                }
            }
            if !currentGroup.isEmpty {
                groups.append(currentGroup)
            }

            let colBaseX = timeColumnW + CGFloat(d - 1) * dayColumnW
            for group in groups {
                var columnEndMinutes: [Int] = []
                var assignedColumns: [Int] = []
                for course in group {
                    if let colIdx = columnEndMinutes.firstIndex(where: { $0 <= course.startMinutes }) {
                        columnEndMinutes[colIdx] = course.endMinutes
                        assignedColumns.append(colIdx)
                    } else {
                        assignedColumns.append(columnEndMinutes.count)
                        columnEndMinutes.append(course.endMinutes)
                    }
                }
                let colCount = CGFloat(max(1, columnEndMinutes.count))
                let subColW = (dayColumnW - 6) / colCount
                for (idx, course) in group.enumerated() {
                    let subColIdx = assignedColumns[idx]
                    let startOffsetMin = CGFloat(max(0, course.startMinutes - axisStartMin))
                    let durationMin = CGFloat(max(25, course.durationMinutes))
                    let cardY = topPadding + (startOffsetMin / 60.0) * hourHeight
                    let cardH = max(32.0, (durationMin / 60.0) * hourHeight)
                    let cardX = colBaseX + 3 + CGFloat(subColIdx) * subColW

                    let cardView = makeRoomCourseCardView(
                        frame: NSRect(x: cardX, y: cardY + 1, width: subColW - 2, height: cardH - 2),
                        course: course,
                        isOverviewMode: isOverviewMode
                    )
                    container.addSubview(cardView)
                }
            }
        }

        // 5. 若为本周且当前时间处于时间轴范围内，绘制当前时间指示红线
        if isCurrentWeek {
            let comps = CourseCalendarHelper.beijingCalendar.dateComponents([.hour, .minute], from: now)
            let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            if nowMin >= axisStartMin && nowMin <= endHour * 60 {
                let nowY = topPadding + CGFloat(nowMin - axisStartMin) / 60.0 * hourHeight
                let todayColX = timeColumnW + CGFloat(currentWeekday - 1) * dayColumnW

                let fullLine = NSView(frame: NSRect(x: timeColumnW, y: nowY, width: 7 * dayColumnW, height: 1))
                fullLine.wantsLayer = true
                fullLine.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
                container.addSubview(fullLine)

                let todayLine = NSView(frame: NSRect(x: todayColX, y: nowY - 0.5, width: dayColumnW, height: 2))
                todayLine.wantsLayer = true
                todayLine.layer?.backgroundColor = NSColor.systemRed.cgColor
                container.addSubview(todayLine)

                let dot = NSView(frame: NSRect(x: todayColX - 4, y: nowY - 4, width: 8, height: 8))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 4
                dot.layer?.backgroundColor = NSColor.systemRed.cgColor
                container.addSubview(dot)
            }
        }

        if !isLoading && allLessons.isEmpty {
            let noticeW: CGFloat = 440
            let noticeH: CGFloat = 86
            let noticeCard = FlippedTimelineView(frame: NSRect(
                x: timeColumnW + (7 * dayColumnW - noticeW) / 2.0,
                y: max(40, (totalH - noticeH) / 2.0 - 30),
                width: noticeW,
                height: noticeH
            ))
            noticeCard.dynamicCornerRadius = 10
            noticeCard.dynamicBackgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95)
            noticeCard.dynamicBorderColor = NSColor.labelColor.withAlphaComponent(0.12)
            noticeCard.dynamicBorderWidth = 1

            let t1 = NSTextField(labelWithString: "\(currentRoomName) 在「\(semTitle)」暂无排课记录")
            t1.frame = NSRect(x: 16, y: 18, width: noticeW - 32, height: 20)
            t1.alignment = .center
            t1.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
            t1.textColor = .labelColor
            noticeCard.addSubview(t1)

            let t2 = NSTextField(labelWithString: "该教室在本学期未安排课程，或可切换上方学期查看其他已排课学期。\n（注：教务系统当前查不到下学期的课）")
            t2.frame = NSRect(x: 16, y: 42, width: noticeW - 32, height: 34)
            t2.alignment = .center
            t2.font = NSFont.systemFont(ofSize: 11.5)
            t2.textColor = .secondaryLabelColor
            noticeCard.addSubview(t2)

            container.addSubview(noticeCard)
        }
    }

    private func makeRoomCourseCardView(frame: NSRect, course: CourseLesson, isOverviewMode: Bool) -> NSView {
        let card = FlippedTimelineView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 7
        card.layer?.masksToBounds = true

        let baseName = course.courseName.components(separatedBy: " [").first ?? course.courseName
        let stableHash = baseName.utf8.reduce(UInt(5381)) { ($0 &<< 5) &+ $0 &+ UInt($1) }
        let colors: [NSColor] = [
            NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 0.90),
            NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.52, alpha: 0.90),
            NSColor(calibratedRed: 0.86, green: 0.43, blue: 0.18, alpha: 0.90),
            NSColor(calibratedRed: 0.56, green: 0.32, blue: 0.82, alpha: 0.90),
            NSColor(calibratedRed: 0.18, green: 0.56, blue: 0.74, alpha: 0.90),
            NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.45, alpha: 0.90),
        ]
        let baseColor = colors[Int(stableHash % UInt(colors.count))]
        card.layer?.backgroundColor = baseColor.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        let sideBar = NSView(frame: NSRect(x: 0, y: 0, width: 3.5, height: frame.height))
        sideBar.wantsLayer = true
        sideBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        card.addSubview(sideBar)

        let padX: CGFloat = 7
        let contentW = max(10, frame.width - padX - 4)

        let timeLabel = NSTextField(labelWithString: course.formattedTime)
        timeLabel.frame = NSRect(x: padX, y: 4, width: contentW, height: 14)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        timeLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(timeLabel)

        let nameH = max(18, min(34, frame.height - 48))
        let nameLabel = NSTextField(wrappingLabelWithString: course.courseName)
        nameLabel.frame = NSRect(x: padX, y: 19, width: contentW, height: nameH)
        nameLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.maximumNumberOfLines = nameH >= 30 ? 2 : 1
        nameLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(nameLabel)

        let classInfoStr = course.classroom ?? currentRoomName
        if frame.height >= 74 {
            let classLabel = NSTextField(labelWithString: classInfoStr)
            classLabel.frame = NSRect(x: padX, y: frame.height - 32, width: contentW, height: 15)
            classLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            classLabel.textColor = NSColor.white.withAlphaComponent(0.92)
            classLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(classLabel)

            if let teacher = course.teacher, !teacher.isEmpty {
                let teacherLabel = NSTextField(labelWithString: "教师: \(teacher)")
                teacherLabel.frame = NSRect(x: padX, y: frame.height - 16, width: contentW, height: 14)
                teacherLabel.font = NSFont.systemFont(ofSize: 9.5)
                teacherLabel.textColor = NSColor.white.withAlphaComponent(0.84)
                teacherLabel.lineBreakMode = .byTruncatingTail
                card.addSubview(teacherLabel)
            }
        } else if frame.height >= 52 {
            let bottomInfo = course.teacher.map { "\($0) · \(classInfoStr)" } ?? classInfoStr
            let infoLabel = NSTextField(labelWithString: bottomInfo)
            infoLabel.frame = NSRect(x: padX, y: frame.height - 17, width: contentW, height: 14)
            infoLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            infoLabel.textColor = NSColor.white.withAlphaComponent(0.9)
            infoLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(infoLabel)
        }

        let dateOrWeeksLine = isOverviewMode
            ? "周次范围: \(course.dateString) (\(CourseCalendarHelper.weekdayName(from: course.weekday)))"
            : "日期: \(course.dateString) (第 \(course.weekIndex ?? currentWeek) 周 · \(CourseCalendarHelper.weekdayName(from: course.weekday)))"

        card.toolTip = """
        【\(course.courseName)】
        教室: \(currentRoomName)
        时间: \(course.formattedTime) (\(course.durationMinutes) 分钟)
        \(dateOrWeeksLine)
        教学班: \(classInfoStr)
        授课教师: \(course.teacher ?? "未指定")
        """

        return card
    }

    @objc private func semesterChangedAction(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, tag > 0 else { return }
        selectedSemesterId = tag
        loadSchedule(autoFallbackSemester: false, forceRefresh: false)
    }

    @objc private func viewModeChangedAction(_ sender: NSSegmentedControl) {
        viewMode = sender.selectedSegment
        renderClassroomSchedule()
    }

    @objc private func prevWeekAction() {
        if currentWeek > 1 {
            currentWeek -= 1
            renderClassroomSchedule()
        }
    }

    @objc private func nextWeekAction() {
        if currentWeek < maxWeek {
            currentWeek += 1
            renderClassroomSchedule()
        }
    }

    @objc private func todayWeekAction() {
        guard let week = scheduleData?.currentWeek() else { return }
        currentWeek = week
        renderClassroomSchedule()
    }

    @objc private func weekChangedAction(_ sender: NSPopUpButton) {
        currentWeek = sender.indexOfSelectedItem + 1
        renderClassroomSchedule()
    }

    @objc private func refreshAction() {
        loadSchedule(autoFallbackSemester: false, forceRefresh: true)
    }
}

