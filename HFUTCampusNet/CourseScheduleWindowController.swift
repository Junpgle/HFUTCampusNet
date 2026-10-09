import Foundation
import AppKit

public class CourseScheduleWindowController: NSWindowController {
    public static let shared = CourseScheduleWindowController()

    private var currentWeek: Int = 1
    private var maxWeek: Int = 20
    private var weekPopUp: NSPopUpButton!
    private var semesterLabel: NSTextField!
    private var statusInfoLabel: NSTextField!
    private var gridScrollView: NSScrollView!
    private var gridContainerView: NSView!

    // 标准合工大作息时间段定义
    private struct TimeSlot {
        let periodName: String       // 例如 "1-2 节"
        let timeRange: String        // 例如 "08:00 - 09:40"
        let startVal: Int            // 例如 800
        let endVal: Int              // 例如 940
    }

    private let timeSlots: [TimeSlot] = [
        TimeSlot(periodName: "1 - 2 节", timeRange: "08:00 - 09:40", startVal: 750, endVal: 950),
        TimeSlot(periodName: "3 - 4 节", timeRange: "10:00 - 11:40", startVal: 950, endVal: 1250),
        TimeSlot(periodName: "5 - 6 节", timeRange: "14:00 - 15:40", startVal: 1300, endVal: 1545),
        TimeSlot(periodName: "7 - 8 节", timeRange: "15:50 - 17:30", startVal: 1545, endVal: 1830),
        TimeSlot(periodName: "9 - 11 节", timeRange: "19:20 - 21:00", startVal: 1830, endVal: 2200),
    ]

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "📅 合肥工业大学课程表"
        window.minSize = NSSize(width: 880, height: 600)
        window.center()
        super.init(window: window)
        setupUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScheduleUpdated),
            name: .courseScheduleDidUpdate,
            object: nil
        )

        // 初始化当前周次
        if let schedule = CourseScheduleService.shared.currentSchedule {
            currentWeek = schedule.currentWeek() ?? 1
        }
        renderSchedule()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window else { return }

        let mainView = NSView(frame: window.contentView!.bounds)
        mainView.autoresizingMask = [.width, .height]

        // 1. 顶部控制栏
        let topBar = NSView(frame: NSRect(x: 0, y: mainView.frame.height - 56, width: mainView.frame.width, height: 56))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

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

        let syncBtn = NSButton(title: "🔄 立即刷新", target: self, action: #selector(refreshScheduleAction))
        syncBtn.bezelStyle = .rounded
        syncBtn.frame = NSRect(x: topBar.frame.width - 105, y: 13, width: 90, height: 28)
        syncBtn.autoresizingMask = [.minXMargin]
        topBar.addSubview(syncBtn)

        mainView.addSubview(topBar)

        // 2. 底部信息栏
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: mainView.frame.width, height: 32))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        statusInfoLabel = NSTextField(labelWithString: "正在加载课表...")
        statusInfoLabel.frame = NSRect(x: 20, y: 6, width: 800, height: 18)
        statusInfoLabel.font = NSFont.systemFont(ofSize: 11)
        statusInfoLabel.textColor = .tertiaryLabelColor
        bottomBar.addSubview(statusInfoLabel)

        mainView.addSubview(bottomBar)

        // 3. 中间课表网格滚动视图
        let contentH = mainView.frame.height - 56 - 32
        gridScrollView = NSScrollView(frame: NSRect(x: 0, y: 32, width: mainView.frame.width, height: contentH))
        gridScrollView.autoresizingMask = [.width, .height]
        gridScrollView.hasVerticalScroller = true
        gridScrollView.hasHorizontalScroller = false
        gridScrollView.borderType = .noBorder

        gridContainerView = NSView(frame: NSRect(x: 0, y: 0, width: mainView.frame.width, height: contentH))
        gridContainerView.autoresizingMask = [.width]
        gridScrollView.documentView = gridContainerView

        mainView.addSubview(gridScrollView)
        window.contentView = mainView
    }

    // MARK: - 渲染周课表

    public func renderSchedule() {
        guard let container = gridContainerView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }

        let schedule = CourseScheduleService.shared.currentSchedule
        let stdId = schedule?.studentId ?? SettingsManager.shared.courseStudentId
        semesterLabel?.stringValue = "\(schedule?.semesterName ?? "当前学期") (stdId: \(stdId))"

        if let syncTime = schedule?.lastSyncTime {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            let count = schedule?.lessons.count ?? 0
            statusInfoLabel?.stringValue = "最后同步: \(f.string(from: syncTime)) | 本学期共有 \(count) 节排课 | 数据源: 合肥工业大学 EAMS 5.0"
        } else {
            statusInfoLabel?.stringValue = "尚未同步教务课表，请点击右上角「网页登录同步」"
        }

        // 更新下拉选择框
        if weekPopUp != nil && currentWeek >= 1 && currentWeek <= 24 {
            weekPopUp.selectItem(at: currentWeek - 1)
        }

        // 网格尺寸计算
        let containerW = max(gridScrollView.bounds.width, 860)
        let timeColumnW: CGFloat = 85
        let dayColumnW: CGFloat = (containerW - timeColumnW - 20) / 7.0
        let headerH: CGFloat = 38
        let rowH: CGFloat = 110
        let totalH = headerH + CGFloat(timeSlots.count) * rowH + 20

        container.frame = NSRect(x: 0, y: 0, width: containerW, height: max(totalH, gridScrollView.bounds.height))

        let currentWeekday = CourseCalendarHelper.weekday(from: Date())
        let isCurrentWeek = (schedule?.currentWeek() == currentWeek)

        // 1. 绘制表头 (周一 ~ 周日)
        let headerY = container.frame.height - headerH - 8
        for d in 1...7 {
            let x = timeColumnW + CGFloat(d - 1) * dayColumnW + 10
            let headerCard = NSView(frame: NSRect(x: x, y: headerY, width: dayColumnW - 4, height: headerH))
            headerCard.wantsLayer = true
            headerCard.layer?.cornerRadius = 6

            let isToday = (isCurrentWeek && d == currentWeekday)
            if isToday {
                headerCard.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
            } else {
                headerCard.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4).cgColor
            }

            let nameLabel = NSTextField(labelWithString: CourseCalendarHelper.weekdayName(from: d))
            nameLabel.frame = NSRect(x: 0, y: 10, width: dayColumnW - 4, height: 18)
            nameLabel.alignment = .center
            nameLabel.font = NSFont.systemFont(ofSize: 13, weight: isToday ? .bold : .medium)
            if isToday {
                nameLabel.textColor = NSColor.systemBlue
            }
            headerCard.addSubview(nameLabel)
            container.addSubview(headerCard)
        }

        // 获取本周的所有课程
        let weekLessons = schedule?.lessonsForWeek(currentWeek) ?? []

        // 2. 绘制各节次网格与课程卡片
        for (slotIndex, slot) in timeSlots.enumerated() {
            let rowY = headerY - CGFloat(slotIndex + 1) * rowH

            // 左侧时间列
            let timeCard = NSView(frame: NSRect(x: 10, y: rowY, width: timeColumnW - 4, height: rowH - 6))
            timeCard.wantsLayer = true
            timeCard.layer?.cornerRadius = 6
            timeCard.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor

            let pLabel = NSTextField(labelWithString: slot.periodName)
            pLabel.frame = NSRect(x: 4, y: timeCard.frame.height - 30, width: timeCard.frame.width - 8, height: 18)
            pLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            pLabel.alignment = .center
            timeCard.addSubview(pLabel)

            let tLabel = NSTextField(labelWithString: slot.timeRange)
            tLabel.frame = NSRect(x: 2, y: 18, width: timeCard.frame.width - 4, height: 30)
            tLabel.font = NSFont.systemFont(ofSize: 10)
            tLabel.textColor = .secondaryLabelColor
            tLabel.alignment = .center
            timeCard.addSubview(tLabel)

            container.addSubview(timeCard)

            // 7 天的单元格
            for d in 1...7 {
                let cellX = timeColumnW + CGFloat(d - 1) * dayColumnW + 10
                let cellCard = NSView(frame: NSRect(x: cellX, y: rowY, width: dayColumnW - 4, height: rowH - 6))
                cellCard.wantsLayer = true
                cellCard.layer?.cornerRadius = 8
                cellCard.layer?.borderWidth = 0.5
                cellCard.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor

                let isToday = (isCurrentWeek && d == currentWeekday)
                if isToday {
                    cellCard.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.04).cgColor
                } else {
                    cellCard.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.25).cgColor
                }

                // 筛选落在该节次范围内的课程
                let matchedCourses = weekLessons.filter { lesson in
                    guard lesson.weekday == d else { return false }
                    // 检查时间是否有交集 (startTime < slot.endVal && endTime > slot.startVal)
                    return lesson.startTime < slot.endVal && lesson.endTime > slot.startVal
                }

                if !matchedCourses.isEmpty {
                    for (cIdx, course) in matchedCourses.enumerated() {
                        let subCardH = (cellCard.frame.height - CGFloat(matchedCourses.count - 1) * 4) / CGFloat(matchedCourses.count)
                        let subCardY = cellCard.frame.height - CGFloat(cIdx + 1) * subCardH - CGFloat(cIdx) * 4
                        let courseView = makeCourseCardView(
                            frame: NSRect(x: 3, y: subCardY, width: cellCard.frame.width - 6, height: subCardH),
                            course: course
                        )
                        cellCard.addSubview(courseView)
                    }
                }

                container.addSubview(cellCard)
            }
        }
    }

    /// 创建单节课程卡片视图
    private func makeCourseCardView(frame: NSRect, course: CourseLesson) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 6

        // 根据课程名称生成一致且柔和的色彩
        let hash = abs(course.courseName.hashValue)
        let colors: [NSColor] = [
            NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 0.88), // 蓝
            NSColor(calibratedRed: 0.18, green: 0.65, blue: 0.55, alpha: 0.88), // 绿
            NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.20, alpha: 0.88), // 橙
            NSColor(calibratedRed: 0.58, green: 0.32, blue: 0.85, alpha: 0.88), // 紫
            NSColor(calibratedRed: 0.22, green: 0.58, blue: 0.75, alpha: 0.88), // 青
            NSColor(calibratedRed: 0.85, green: 0.30, blue: 0.45, alpha: 0.88), // 玫红
        ]
        let baseColor = colors[hash % colors.count]
        card.layer?.backgroundColor = baseColor.cgColor

        let nameLabel = NSTextField(labelWithString: course.courseName)
        nameLabel.frame = NSRect(x: 4, y: frame.height - 24, width: frame.width - 8, height: 20)
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(nameLabel)

        let roomStr = course.classroom ?? "待定教室"
        let roomLabel = NSTextField(labelWithString: "📍 \(roomStr) (\(course.formattedTime))")
        roomLabel.frame = NSRect(x: 4, y: 18, width: frame.width - 8, height: 16)
        roomLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        roomLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        roomLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(roomLabel)

        let teacherStr = course.teacher ?? ""
        let teacherLabel = NSTextField(labelWithString: "👤 \(teacherStr)")
        teacherLabel.frame = NSRect(x: 4, y: 2, width: frame.width - 8, height: 15)
        teacherLabel.font = NSFont.systemFont(ofSize: 9.5)
        teacherLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        teacherLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(teacherLabel)

        card.toolTip = """
        【\(course.courseName)】
        时间: \(course.formattedTime)
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
