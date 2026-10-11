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

        // 每分钟刷新一次当前时间指示线
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.renderSchedule()
        }

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

        semesterLabel = NSTextField(labelWithString: "2026-2027学年 第一学期 (std: 178506)")
        semesterLabel.frame = NSRect(x: 20, y: 8, width: 280, height: 16)
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
        statusInfoLabel.frame = NSRect(x: 20, y: 6, width: 800, height: 18)
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
        let stdId = schedule?.studentId ?? SettingsManager.shared.courseStudentId
        semesterLabel?.stringValue = "\(schedule?.semesterName ?? "当前学期") (stdId: \(stdId))"

        if let syncTime = schedule?.lastSyncTime {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            let count = schedule?.lessons.count ?? 0
            statusInfoLabel?.stringValue = "最后同步: \(f.string(from: syncTime)) | 本学期共有 \(count) 节排课 | 连续时间轴视图 (08:00 - 22:00)"
        } else {
            statusInfoLabel?.stringValue = "尚未同步教务课表，请点击右上角「网页登录同步」"
        }

        if weekPopUp != nil && currentWeek >= 1 && currentWeek <= 24 {
            weekPopUp.selectItem(at: currentWeek - 1)
        }

        let weekLessons = schedule?.lessonsForWeek(currentWeek) ?? []
        let weekDates = schedule?.datesForWeek(currentWeek) ?? [:]

        // 时间轴范围：默认 08:00 ~ 22:00，若本周有更早或更晚的课自动扩展
        let minLessonHour = weekLessons.map { $0.startTime / 100 }.min() ?? 8
        let maxLessonHour = weekLessons.map { ($0.endTime + 59) / 100 }.max() ?? 22
        let startHour = min(8, minLessonHour)
        let endHour = max(22, maxLessonHour)
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
        let currentWeekday = CourseCalendarHelper.weekday(from: now)
        let isCurrentWeek = (schedule?.currentWeek(at: now) == currentWeek)

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
                let count = CGFloat(group.count)
                let subColW = (dayColumnW - 6) / count
                for (idx, course) in group.enumerated() {
                    let startOffsetMin = CGFloat(max(0, course.startMinutes - axisStartMin))
                    let durationMin = CGFloat(max(25, course.durationMinutes))
                    let cardY = topPadding + (startOffsetMin / 60.0) * hourHeight
                    let cardH = max(32.0, (durationMin / 60.0) * hourHeight)
                    let cardX = colBaseX + 3 + CGFloat(idx) * subColW

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

        // 根据课程名称生成一致且柔和的色彩
        let hash = abs(course.courseName.hashValue)
        let colors: [NSColor] = [
            NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 0.90), // 蓝
            NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.52, alpha: 0.90), // 绿
            NSColor(calibratedRed: 0.86, green: 0.43, blue: 0.18, alpha: 0.90), // 橙
            NSColor(calibratedRed: 0.56, green: 0.32, blue: 0.82, alpha: 0.90), // 紫
            NSColor(calibratedRed: 0.18, green: 0.56, blue: 0.74, alpha: 0.90), // 青
            NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.45, alpha: 0.90), // 玫红
        ]
        let baseColor = colors[hash % colors.count]
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

    // MARK: - Actions

    @objc private func onScheduleUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.renderSchedule()
        }
    }

    @objc private func prevWeekAction() {
        if currentWeek > 1 {
            currentWeek -= 1
            renderSchedule()
        }
    }

    @objc private func nextWeekAction() {
        if currentWeek < 24 {
            currentWeek += 1
            renderSchedule()
        }
    }

    @objc private func todayWeekAction() {
        if let schedule = CourseScheduleService.shared.currentSchedule {
            currentWeek = schedule.currentWeek() ?? 1
        } else {
            currentWeek = 1
        }
        renderSchedule()
    }

    @objc private func weekChangedAction(_ sender: NSPopUpButton) {
        currentWeek = sender.indexOfSelectedItem + 1
        renderSchedule()
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
                    if let syncErr = error as? CourseScheduleService.CourseSyncError, case .needLogin = syncErr {
                        self?.statusInfoLabel?.stringValue = "⚠️ 登录已过期，正在打开登录网页..."
                        CourseLoginWebViewController.shared.showLoginWindow()
                    } else {
                        self?.statusInfoLabel?.stringValue = "❌ 同步失败: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
