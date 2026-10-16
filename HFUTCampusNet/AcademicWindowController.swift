import Foundation
import AppKit

public class AcademicWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = AcademicWindowController()

    private var topBarView: AdaptiveBoxView!
    private var segmentedControl: NSSegmentedControl!
    private var termPopUp: NSPopUpButton!
    private var hideScoreCheckbox: NSButton!
    private var calendarSourceBtn: NSButton!
    private var syncBtn: NSButton!
    private var statusLabel: NSTextField!

    private var cardViews: [AdaptiveBoxView] = []
    private var cardTitleLabels: [NSTextField] = []
    private var cardValueLabels: [NSTextField] = []
    private var cardSubLabels: [NSTextField] = []

    private var sectionTitleLabel: NSTextField!
    private var scrollTableView: NSScrollView!
    private var tableView: NSTableView!

    private var currentMode: Int = 0 // 0: 成绩单与 GPA, 1: 考试与校历进度, 2: 培养方案与毕业学分, 3: 课程教材与评教
    private var selectedTermIndex: Int = 0 // 0 表示最新学期，最后一个选项表示「全部学期汇总」

    private var currentGrades: [GradeItem] = []
    private var currentExams: [ExamItem] = []
    private var currentModules: [ProgramModuleItem] = []
    private var currentTextbooks: [CourseTextbookItem] = []
    private var currentSurveys: [LessonSurveyItem] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "教务学业中心 (成绩 / 排考校历 / 培养方案 / 教材评教) - 合肥工业大学"
        window.minSize = NSSize(width: 880, height: 560)
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAcademicDataUpdated),
            name: .academicDataDidUpdate,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // 顶部工具栏
        topBarView = AdaptiveBoxView(frame: NSRect(x: 0, y: 700 - 56, width: 980, height: 56))
        topBarView.autoresizingMask = [.width, .minYMargin]
        topBarView.dynamicBackgroundColor = .windowBackgroundColor
        contentView.addSubview(topBarView)

        segmentedControl = NSSegmentedControl(
            labels: ["成绩单与 GPA", "考试与校历进度", "培养方案与毕业学分", "课程教材与评教"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onSegmentChanged(_:))
        )
        segmentedControl.selectedSegment = currentMode
        segmentedControl.frame = NSRect(x: 20, y: 13, width: 390, height: 30)
        topBarView.addSubview(segmentedControl)

        termPopUp = NSPopUpButton(frame: NSRect(x: 420, y: 13, width: 190, height: 28), pullsDown: false)
        termPopUp.target = self
        termPopUp.action = #selector(onTermChanged(_:))
        topBarView.addSubview(termPopUp)

        hideScoreCheckbox = NSButton(
            checkboxWithTitle: "通知隐藏具体分数",
            target: self,
            action: #selector(onHideScoreToggled(_:))
        )
        hideScoreCheckbox.font = NSFont.systemFont(ofSize: 11.5)
        hideScoreCheckbox.state = SettingsManager.shared.hideScoreInNotification ? .on : .off
        hideScoreCheckbox.frame = NSRect(x: 635, y: 18, width: 135, height: 20)
        topBarView.addSubview(hideScoreCheckbox)

        calendarSourceBtn = NSButton(title: "校历来源", target: self, action: #selector(openOfficialCalendar))
        calendarSourceBtn.bezelStyle = .rounded
        calendarSourceBtn.frame = NSRect(x: 780, y: 13, width: 75, height: 30)
        calendarSourceBtn.autoresizingMask = [.minXMargin]
        topBarView.addSubview(calendarSourceBtn)

        syncBtn = NSButton(title: "立即同步", target: self, action: #selector(onSyncClicked))
        syncBtn.bezelStyle = .rounded
        syncBtn.frame = NSRect(x: 865, y: 13, width: 95, height: 30)
        syncBtn.autoresizingMask = [.minXMargin]
        topBarView.addSubview(syncBtn)

        // 4 个核心指标卡片
        let cardW: CGFloat = 225
        let cardH: CGFloat = 76
        let gap: CGFloat = 13
        let startX: CGFloat = 20
        let cardY: CGFloat = 700 - 56 - 14 - cardH

        cardViews.removeAll()
        cardTitleLabels.removeAll()
        cardValueLabels.removeAll()
        cardSubLabels.removeAll()

        for i in 0..<4 {
            let card = AdaptiveBoxView(frame: NSRect(x: startX + CGFloat(i) * (cardW + gap), y: cardY, width: cardW, height: cardH))
            card.autoresizingMask = [.minYMargin]
            card.dynamicCornerRadius = 10
            card.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.035)
            card.dynamicBorderColor = NSColor.labelColor.withAlphaComponent(0.10)
            card.dynamicBorderWidth = 1.0

            let titleLabel = NSTextField(labelWithString: "指标")
            titleLabel.frame = NSRect(x: 14, y: cardH - 24, width: cardW - 28, height: 16)
            titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.autoresizingMask = [.width]
            card.addSubview(titleLabel)

            let valLabel = NSTextField(labelWithString: "--")
            valLabel.frame = NSRect(x: 14, y: 22, width: cardW - 28, height: 26)
            valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .bold)
            valLabel.textColor = NSColor.labelColor
            valLabel.lineBreakMode = .byTruncatingTail
            valLabel.autoresizingMask = [.width]
            card.addSubview(valLabel)

            let subLabel = NSTextField(labelWithString: "--")
            subLabel.frame = NSRect(x: 14, y: 5, width: cardW - 28, height: 14)
            subLabel.font = NSFont.systemFont(ofSize: 10.5)
            subLabel.textColor = .tertiaryLabelColor
            subLabel.lineBreakMode = .byTruncatingTail
            subLabel.autoresizingMask = [.width]
            card.addSubview(subLabel)

            contentView.addSubview(card)
            cardViews.append(card)
            cardTitleLabels.append(titleLabel)
            cardValueLabels.append(valLabel)
            cardSubLabels.append(subLabel)
        }

        // 表格上方标题与同步状态
        let titleY = cardY - 30
        sectionTitleLabel = NSTextField(labelWithString: "课程成绩明细")
        sectionTitleLabel.frame = NSRect(x: 20, y: titleY, width: 520, height: 18)
        sectionTitleLabel.autoresizingMask = [.minYMargin]
        sectionTitleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        sectionTitleLabel.textColor = .secondaryLabelColor
        contentView.addSubview(sectionTitleLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 540, y: titleY, width: 420, height: 18)
        statusLabel.autoresizingMask = [.minXMargin, .minYMargin]
        statusLabel.alignment = .right
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .tertiaryLabelColor
        contentView.addSubview(statusLabel)

        scrollTableView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 940, height: titleY - 8 - 20))
        scrollTableView.autoresizingMask = [.width, .height]
        scrollTableView.hasVerticalScroller = true
        scrollTableView.borderType = .bezelBorder

        tableView = NSTableView(frame: scrollTableView.bounds)
        tableView.autoresizingMask = [.width, .height]
        tableView.rowHeight = 26
        tableView.usesAlternatingRowBackgroundColors = true

        scrollTableView.documentView = tableView
        contentView.addSubview(scrollTableView)

        layoutSubviewsForCurrentBounds()
        reloadUI()
    }

    public func windowDidResize(_ notification: Notification) {
        layoutSubviewsForCurrentBounds()
    }

    private func layoutSubviewsForCurrentBounds() {
        guard let contentView = window?.contentView else { return }
        let totalW = contentView.bounds.width
        let totalH = contentView.bounds.height
        let sidePad: CGFloat = 20
        let contentW = max(840, totalW - sidePad * 2)

        topBarView?.frame = NSRect(x: 0, y: totalH - 56, width: totalW, height: 56)
        syncBtn?.frame = NSRect(x: totalW - sidePad - 95, y: 13, width: 95, height: 30)
        calendarSourceBtn?.frame = NSRect(x: (syncBtn?.frame.minX ?? totalW - sidePad - 95) - 10 - 75, y: 13, width: 75, height: 30)
        let checkboxX = (calendarSourceBtn?.frame.minX ?? 780) - 10 - 135
        hideScoreCheckbox?.frame = NSRect(x: checkboxX, y: 18, width: 135, height: 20)
        let segmentWidth = min(390, max(300, checkboxX - 10 - 125 - 10 - 20))
        segmentedControl?.frame = NSRect(x: sidePad, y: 13, width: segmentWidth, height: 30)
        let termX = sidePad + segmentWidth + 10
        let termWidth = max(125, min(190, checkboxX - termX - 10))
        termPopUp?.frame = NSRect(x: termX, y: 13, width: termWidth, height: 28)

        let cardH: CGFloat = 76
        let gap: CGFloat = 13
        let cardW = floor((contentW - gap * 3) / 4.0)
        let cardY = totalH - 56 - 14 - cardH
        for (i, card) in cardViews.enumerated() {
            card.frame = NSRect(x: sidePad + CGFloat(i) * (cardW + gap), y: cardY, width: cardW, height: cardH)
        }

        let titleY = cardY - 30
        sectionTitleLabel?.frame = NSRect(x: sidePad, y: titleY, width: 540, height: 18)
        statusLabel?.frame = NSRect(x: totalW - sidePad - 400, y: titleY, width: 400, height: 18)

        let tableBottom: CGFloat = 20
        let tableHeight = max(120, titleY - 8 - tableBottom)
        scrollTableView?.frame = NSRect(x: sidePad, y: tableBottom, width: contentW, height: tableHeight)
    }

    public func showWindow(mode: Int = 0) {
        currentMode = max(0, min(3, mode))
        segmentedControl?.selectedSegment = currentMode
        hideScoreCheckbox?.state = SettingsManager.shared.hideScoreInNotification ? .on : .off
        if currentMode == 0 {
            AcademicService.shared.markAllGradesAsRead()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reloadUI()

        let snap = AcademicService.shared.latestData
        if snap == nil || snap?.programCompletion == nil || snap?.textbooks.isEmpty == true {
            AcademicService.shared.syncAll(silent: false, completion: nil)
        }
    }

    public override func showWindow(_ sender: Any?) {
        showWindow(mode: currentMode)
    }

    @objc private func onSegmentChanged(_ sender: NSSegmentedControl) {
        currentMode = sender.selectedSegment
        if currentMode == 0 {
            AcademicService.shared.markAllGradesAsRead()
        }
        reloadUI()
    }

    @objc private func onTermChanged(_ sender: NSPopUpButton) {
        selectedTermIndex = max(0, sender.indexOfSelectedItem)
        reloadUI()
    }

    @objc private func onHideScoreToggled(_ sender: NSButton) {
        SettingsManager.shared.hideScoreInNotification = (sender.state == .on)
    }

    @objc private func onSyncClicked() {
        AcademicService.shared.syncAll(silent: false) { [weak self] result in
            DispatchQueue.main.async {
                self?.reloadUI()
                if case .failure(let err) = result {
                    let alert = NSAlert()
                    alert.messageText = "同步教务学业数据失败"
                    alert.informativeText = err.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openOfficialCalendar() {
        NSWorkspace.shared.open(CampusCalendarService.calendarURL())
    }

    @objc private func onAcademicDataUpdated() {
        DispatchQueue.main.async { [weak self] in
            self?.reloadUI()
        }
    }

    private func reloadUI() {
        let service = AcademicService.shared
        let snapshot = service.latestData
        let groups = snapshot?.termGroups ?? []

        // 更新学期下拉菜单（仅在成绩单标签页显示）
        termPopUp.isHidden = (currentMode != 0)
        if currentMode == 0 {
            termPopUp.removeAllItems()
            if groups.isEmpty {
                termPopUp.addItem(withTitle: "暂无学期成绩")
                selectedTermIndex = 0
            } else {
                for g in groups {
                    termPopUp.addItem(withTitle: "\(g.termName) (\(g.grades.count)门)")
                }
                termPopUp.menu?.addItem(NSMenuItem.separator())
                termPopUp.addItem(withTitle: "全部学期汇总 (\(snapshot?.allGrades.count ?? 0)门)")
                if selectedTermIndex >= termPopUp.numberOfItems {
                    selectedTermIndex = 0
                }
                if termPopUp.item(at: selectedTermIndex)?.isSeparatorItem == true {
                    selectedTermIndex = 0
                }
                termPopUp.selectItem(at: selectedTermIndex)
            }
        }

        // 更新同步状态文案
        if service.isSyncing {
            syncBtn.title = "同步中..."
            syncBtn.isEnabled = false
            statusLabel.stringValue = "正在向合工大教务系统同步最新成绩、排考、培养方案与教材..."
        } else {
            syncBtn.title = "立即同步"
            syncBtn.isEnabled = true
            if let syncTime = snapshot?.lastSyncTime {
                let fmt = DateFormatter()
                fmt.dateFormat = "MM-dd HH:mm:ss"
                statusLabel.stringValue = "上次同步：\(fmt.string(from: syncTime)) (每 15 分钟后台静默检测新出分)"
            } else if let err = service.lastErrorMessage {
                statusLabel.stringValue = "同步提示：\(err)"
            } else {
                statusLabel.stringValue = "尚未同步，点击右上角「立即同步」拉取数据"
            }
        }

        if currentMode == 0 {
            // 标签 0：成绩单与 GPA 测算
            let isAllTerms = (!groups.isEmpty && selectedTermIndex == termPopUp.numberOfItems - 1)
            let activeGroup: TermGradeGroup? = (!isAllTerms && selectedTermIndex < groups.count) ? groups[selectedTermIndex] : nil

            if isAllTerms, let snap = snapshot {
                currentGrades = snap.allGrades
                sectionTitleLabel.stringValue = "全部学期成绩单（共 \(currentGrades.count) 门课程）"

                let gpaStr = snap.overallWeightedGPA.map { String(format: "%.2f / 4.3", $0) } ?? "--"
                let scoreStr = snap.overallWeightedScore.map { String(format: "%.2f 分", $0) } ?? "--"
                let creditsStr = String(format: "%.1f 学分", snap.totalEarnedCredits)
                let passCount = currentGrades.filter { $0.passed }.count

                setCard(index: 0, title: "全学程加权 GPA", value: gpaStr, sub: "全部已修读计点课程加权", color: .systemBlue)
                setCard(index: 1, title: "全学程加权平均分", value: scoreStr, sub: "按课程学分加权折算", color: .systemIndigo)
                setCard(index: 2, title: "累计获得学分", value: creditsStr, sub: "共 \(groups.count) 个学期", color: .systemTeal)
                setCard(index: 3, title: "已出分科目数", value: "\(passCount) / \(currentGrades.count) 门", sub: "通过率 \(currentGrades.isEmpty ? 100 : Int(round(Double(passCount) / Double(currentGrades.count) * 100)))%", color: .systemGreen)
            } else if let group = activeGroup {
                currentGrades = group.grades
                sectionTitleLabel.stringValue = "\(group.termName) 成绩明细（共 \(currentGrades.count) 门）"

                let termGPAStr = group.weightedGPA.map { String(format: "%.2f", $0) } ?? "--"
                let termScoreStr = group.weightedScore.map { String(format: "%.2f 分", $0) } ?? "--"
                let overallGPAStr = snapshot?.overallWeightedGPA.map { String(format: "%.2f", $0) } ?? "--"
                let totalCredStr = snapshot.map { String(format: "总修 %.1f 学分", $0.totalEarnedCredits) } ?? "--"

                setCard(index: 0, title: "本学期加权 GPA", value: termGPAStr, sub: group.termName, color: .systemBlue)
                setCard(index: 1, title: "本学期加权平均分", value: termScoreStr, sub: "本学期共 \(currentGrades.count) 门已出分", color: .systemIndigo)
                setCard(index: 2, title: "本学期获得学分", value: String(format: "%.1f 学分", group.totalCredits), sub: "已通过科目学分合计", color: .systemTeal)
                setCard(index: 3, title: "全学程总 GPA", value: overallGPAStr, sub: totalCredStr, color: .systemGreen)
            } else {
                currentGrades = []
                sectionTitleLabel.stringValue = "课程成绩明细"
                setCard(index: 0, title: "本学期加权 GPA", value: "--", sub: "等待同步成绩数据", color: .systemGray)
                setCard(index: 1, title: "本学期加权平均分", value: "--", sub: "等待同步成绩数据", color: .systemGray)
                setCard(index: 2, title: "本学期获得学分", value: "--", sub: "等待同步成绩数据", color: .systemGray)
                setCard(index: 3, title: "全学程总 GPA", value: "--", sub: "等待同步成绩数据", color: .systemGray)
            }
        } else if currentMode == 1 {
            // 标签 1：考试安排与校历倒计时
            let allExams = snapshot?.exams ?? []
            let now = Date()
            let upcoming = allExams.filter { !$0.isFinished(at: now) }.sorted { $0.dateTimeString < $1.dateTimeString }
            let finished = allExams.filter { $0.isFinished(at: now) }.sorted { $0.dateTimeString > $1.dateTimeString }
            currentExams = upcoming + finished

            let milestone = SemesterMilestoneInfo.calculate(at: now)
            let nextCampusEvent = CampusCalendarService.upcomingEvents(at: now).first
            let nextEventText = nextCampusEvent.map { " · 下一项：\($0.title) \($0.dateRange)" } ?? ""

            if currentExams.isEmpty {
                sectionTitleLabel.stringValue = "\(milestone.campusName) · \(milestone.semesterName)（暂未发布排考）\(nextEventText)"
            } else {
                sectionTitleLabel.stringValue = "\(milestone.campusName) · 考试安排（共 \(currentExams.count) 场，待考 \(upcoming.count) 场 · \(milestone.semesterName)）\(nextEventText)"
            }

            if let nextExam = upcoming.first {
                let badge = nextExam.countdownBadgeText(at: now)
                setCard(index: 0, title: "最近一场考试", value: nextExam.courseName, sub: "\(nextExam.dateString) \(nextExam.startTimeString)~\(nextExam.endTimeString)", color: .systemOrange)
                setCard(index: 1, title: "考试倒计时", value: badge, sub: "考场：\(nextExam.displayLocation)", color: nextExam.daysRemaining(at: now) <= 3 ? .systemRed : .systemBlue)
            } else {
                setCard(index: 0, title: "最近一场考试", value: "暂无待考科目", sub: allExams.isEmpty ? "教务系统尚未公布本学期排考" : "本学期考试已全部结束", color: .systemGreen)
                let examWeek = [milestone.examWeekStartDateString, milestone.examWeekEndDateString].compactMap { $0 }.joined(separator: " 至 ")
                setCard(index: 1, title: "期末考试周倒计时", value: milestone.daysUntilExamWeek > 0 ? "还有 \(milestone.daysUntilExamWeek) 天" : "已进入期末阶段", sub: examWeek.isEmpty ? "待考 \(upcoming.count) 场 / 已考 \(finished.count) 场" : "官方考试周：\(examWeek)", color: .systemBlue)
            }

            setCard(
                index: 2,
                title: "本学期校历进度",
                value: "第 \(milestone.currentWeek)/\(milestone.totalWeeks) 周 (\(milestone.progressPercentage)%)",
                sub: "\(milestone.startDateString) ~ \(milestone.endDateString) · 官方校历",
                color: .systemIndigo
            )
            setCard(
                index: 3,
                title: "距离\(milestone.vacationName)放假",
                value: milestone.remainingDays > 0 ? "还有 \(milestone.remainingDays) 天" : "假期进行中",
                sub: "\(milestone.campusName) · 学期结束日：\(milestone.endDateString)",
                color: .systemTeal
            )
        } else if currentMode == 2 {
            // 标签 2：培养方案与毕业学分审计
            if let prog = snapshot?.programCompletion {
                currentModules = prog.modules
                sectionTitleLabel.stringValue = "\(prog.programName)（共 \(currentModules.count) 个模块分类）"

                setCard(
                    index: 0,
                    title: "毕业要求总学分进度",
                    value: String(format: "%.1f / %.0f 分", prog.passedCredits, prog.requiredCredits),
                    sub: String(format: "已修占 %.1f%% (已通过 %d 门)", prog.completionPercentage, prog.passedCourseCount),
                    color: .systemBlue
                )
                setCard(
                    index: 1,
                    title: "本学期在修学分",
                    value: String(format: "+%.1f 学分", prog.takingCredits),
                    sub: "本学期计划内在修 \(prog.takingCourseCount) 门" + (prog.outerTakingCredits > 0 ? " · 计划外 \(String(format: "%.1f", prog.outerTakingCredits))分" : ""),
                    color: .systemIndigo
                )
                setCard(
                    index: 2,
                    title: "含在修预计完成度",
                    value: String(format: "%.1f%% (%.1f分)", prog.projectedPercentageWithTaking, prog.passedCredits + prog.takingCredits),
                    sub: "本学期全部修过后的预计总学分",
                    color: .systemGreen
                )
                let remain = prog.remainingCreditsAfterTaking
                setCard(
                    index: 3,
                    title: "扣除在修后净缺口",
                    value: remain <= 0.01 ? "已满额" : String(format: "还差 %.1f 分", remain),
                    sub: remain <= 0.01 ? "已达到毕业总学分要求" : "后续学期还需选修/必修学分",
                    color: remain <= 0.01 ? .systemGreen : .systemOrange
                )
            } else {
                currentModules = []
                sectionTitleLabel.stringValue = "培养方案与毕业学分完成情况（等待同步）"
                setCard(index: 0, title: "毕业要求总学分进度", value: "--", sub: "正在同步培养方案数据", color: .systemGray)
                setCard(index: 1, title: "本学期在修学分", value: "--", sub: "正在同步培养方案数据", color: .systemGray)
                setCard(index: 2, title: "含在修预计完成度", value: "--", sub: "正在同步培养方案数据", color: .systemGray)
                setCard(index: 3, title: "扣除在修后净缺口", value: "--", sub: "正在同步培养方案数据", color: .systemGray)
            }
        } else {
            // 标签 3：本学期课程教材清单与期末评教状态
            currentTextbooks = snapshot?.textbooks ?? []
            currentSurveys = snapshot?.surveys ?? []

            let totalCredits = currentTextbooks.reduce(0.0) { $0 + $1.credits }
            let withBookCount = currentTextbooks.filter {
                let d = $0.displayTextbook
                return !d.contains("暂未指定") && !d.contains("不需要教材")
            }.count
            let examCourseCount  = currentTextbooks.filter { $0.examMode.contains("考试") && !$0.examMode.contains("笔试") }.count
            let writtenCount     = currentTextbooks.filter { $0.examMode.contains("笔试") }.count
            let checkCourseCount = currentTextbooks.filter { $0.examMode.contains("考查") }.count
            let otherCount       = currentTextbooks.count - examCourseCount - writtenCount - checkCourseCount
            // 构建考核分布文本，只显示数量 > 0 的类型
            var examDistParts: [String] = []
            if examCourseCount  > 0 { examDistParts.append("考试 \(examCourseCount)") }
            if writtenCount     > 0 { examDistParts.append("笔试 \(writtenCount)") }
            if checkCourseCount > 0 { examDistParts.append("考查 \(checkCourseCount)") }
            if otherCount       > 0 { examDistParts.append("其他 \(otherCount)") }
            let examDistText = examDistParts.isEmpty ? "--" : examDistParts.joined(separator: " · ")
            let pendingSurveys = snapshot?.pendingSurveyCount ?? 0

            let surveyTag = currentSurveys.isEmpty
                ? "当前教务未开放评教"
                : (pendingSurveys == 0 ? "本学期评教已全部完成" : "⚠️ 尚有 \(pendingSurveys) 位教师待评教")
            sectionTitleLabel.stringValue = "本学期所修课程教材与教学任务清单（共 \(currentTextbooks.count) 门 · \(surveyTag)）"

            setCard(
                index: 0,
                title: "本学期修读课程",
                value: "\(currentTextbooks.count) 门",
                sub: String(format: "合计 %.1f 学分", totalCredits),
                color: .systemBlue
            )
            setCard(
                index: 1,
                title: "指定教材课程数",
                value: "\(withBookCount) / \(currentTextbooks.count) 门",
                sub: "含 ISBN 官方教材或自编讲义",
                color: .systemIndigo
            )
            setCard(
                index: 2,
                title: "考核方式分布",
                value: examDistText,
                sub: "本学期期末考核类型",
                color: .systemTeal
            )
            setCard(
                index: 3,
                title: "期末教学评价 (评教)",
                value: pendingSurveys > 0 ? "待评 \(pendingSurveys) 项" : "无待评任务",
                sub: surveyTag,
                color: pendingSurveys > 0 ? .systemRed : .systemGreen
            )
        }

        setupTableColumns()
        tableView.reloadData()
    }

    private func setCard(index: Int, title: String, value: String, sub: String, color: NSColor) {
        guard index < cardViews.count else { return }
        cardTitleLabels[index].stringValue = title
        cardValueLabels[index].stringValue = value
        cardValueLabels[index].textColor = color
        cardSubLabels[index].stringValue = sub
        // 根据文字长度动态缩小字号，防止截断
        let charCount = value.count
        let fontSize: CGFloat = charCount <= 10 ? 19 : charCount <= 15 ? 16 : charCount <= 20 ? 14 : 12
        cardValueLabels[index].font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        // 同步调整 valLabel 的 frame 高度以垂直居中
        let cardH = cardViews[index].bounds.height > 0 ? cardViews[index].bounds.height : 74
        let labelH: CGFloat = fontSize >= 16 ? 26 : 22
        let yPos = (cardH - labelH) / 2 - 4
        cardValueLabels[index].frame.size.height = labelH
        cardValueLabels[index].frame.origin.y = max(18, yPos)
    }

    private func setupTableColumns() {
        guard let tv = tableView else { return }
        tv.dataSource = nil
        tv.delegate = nil

        while !tv.tableColumns.isEmpty {
            tv.removeTableColumn(tv.tableColumns.last!)
        }

        if currentMode == 0 {
            let cols: [(String, String, CGFloat)] = [
                ("course", "课程名称", 220),
                ("term", "学期", 150),
                ("credits", "学分", 65),
                ("gpa", "绩点", 65),
                ("score", "总评成绩", 80),
                ("detail", "平时/期末分项成绩明细", 330)
            ]
            for (cid, ctitle, w) in cols {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cid))
                col.title = ctitle
                col.width = w
                tv.addTableColumn(col)
            }
        } else if currentMode == 1 {
            let cols: [(String, String, CGFloat)] = [
                ("countdown", "倒计时状态", 115),
                ("course", "考试科目", 240),
                ("datetime", "考试日期与时间", 200),
                ("place", "考场地点", 230),
                ("type", "考试性质", 120)
            ]
            for (cid, ctitle, w) in cols {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cid))
                col.title = ctitle
                col.width = w
                tv.addTableColumn(col)
            }
        } else if currentMode == 2 {
            let cols: [(String, String, CGFloat)] = [
                ("module", "培养方案课程模块", 215),
                ("req", "要求学分", 75),
                ("passed", "已获学分", 75),
                ("taking", "本学期在修", 80),
                ("status", "达标状态与学分缺口", 165),
                ("courses", "在修与待修计划内课程明细", 310)
            ]
            for (cid, ctitle, w) in cols {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cid))
                col.title = ctitle
                col.width = w
                tv.addTableColumn(col)
            }
        } else {
            let cols: [(String, String, CGFloat)] = [
                ("course", "课程名称", 195),
                ("type", "课程性质", 100),
                ("credits", "学分/考核", 80),
                ("textbook", "指定教材 / 参考书 (含 ISBN 与版次)", 340),
                ("schedule", "开课学院与排课教师", 205)
            ]
            for (cid, ctitle, w) in cols {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cid))
                col.title = ctitle
                col.width = w
                tv.addTableColumn(col)
            }
        }

        tv.dataSource = self
        tv.delegate = self
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        switch currentMode {
        case 0: return currentGrades.count
        case 1: return max(1, currentExams.count)
        case 2: return max(1, currentModules.count)
        default: return max(1, currentTextbooks.count)
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let cid = col.identifier.rawValue

        let cell = (tableView.makeView(withIdentifier: col.identifier, owner: self) as? NSTextField) ?? {
            let tf = NSTextField(labelWithString: "")
            tf.identifier = col.identifier
            tf.isEditable = false
            tf.isBordered = false
            tf.backgroundColor = .clear
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            return tf
        }()

        cell.textColor = .labelColor
        cell.font = NSFont.systemFont(ofSize: 12)
        cell.toolTip = nil

        if currentMode == 0 {
            guard row >= 0 && row < currentGrades.count else { return nil }
            let g = currentGrades[row]
            switch cid {
            case "course":
                cell.stringValue = g.courseName
                cell.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            case "term":
                cell.stringValue = g.termName
                cell.textColor = .secondaryLabelColor
            case "credits":
                cell.stringValue = String(format: "%.1f", g.credits)
            case "gpa":
                cell.stringValue = g.gpa.map { String(format: "%.1f", $0) } ?? "--"
            case "score":
                cell.stringValue = g.scoreText
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
                if !g.passed {
                    cell.textColor = .systemRed
                } else if (g.numericScore ?? 0) >= 90 || g.gpa == 4.3 || g.gpa == 4.0 {
                    cell.textColor = .systemGreen
                } else {
                    cell.textColor = .systemBlue
                }
            case "detail":
                cell.stringValue = g.detailText.isEmpty ? "无分项明细" : g.detailText
                cell.textColor = .secondaryLabelColor
                cell.toolTip = g.detailText
            default:
                break
            }
        } else if currentMode == 1 {
            if currentExams.isEmpty {
                if cid == "course" {
                    cell.stringValue = "当前学期暂未查询到排考信息（期末排考公布后将自动展示）"
                    cell.textColor = .secondaryLabelColor
                } else {
                    cell.stringValue = "--"
                    cell.textColor = .tertiaryLabelColor
                }
                return cell
            }
            guard row >= 0 && row < currentExams.count else { return nil }
            let exam = currentExams[row]
            let now = Date()
            let finished = exam.isFinished(at: now)
            let days = exam.daysRemaining(at: now)

            switch cid {
            case "countdown":
                cell.stringValue = exam.countdownBadgeText(at: now)
                cell.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
                if finished {
                    cell.textColor = .tertiaryLabelColor
                } else if exam.isOngoing(at: now) || days <= 2 {
                    cell.textColor = .systemRed
                } else if days <= 7 {
                    cell.textColor = .systemOrange
                } else {
                    cell.textColor = .systemBlue
                }
            case "course":
                cell.stringValue = exam.courseName
                cell.font = NSFont.systemFont(ofSize: 12, weight: finished ? .regular : .medium)
                if finished { cell.textColor = .secondaryLabelColor }
            case "datetime":
                cell.stringValue = exam.dateTimeString
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
                if finished { cell.textColor = .tertiaryLabelColor }
            case "place":
                cell.stringValue = exam.displayLocation
                if finished { cell.textColor = .tertiaryLabelColor }
            case "type":
                cell.stringValue = exam.examType ?? "期末考试"
                cell.textColor = .secondaryLabelColor
            default:
                break
            }
        } else if currentMode == 2 {
            if currentModules.isEmpty {
                if cid == "module" {
                    cell.stringValue = "正在从树维教务同步培养方案完成度数据..."
                    cell.textColor = .secondaryLabelColor
                } else {
                    cell.stringValue = "--"
                    cell.textColor = .tertiaryLabelColor
                }
                return cell
            }
            guard row >= 0 && row < currentModules.count else { return nil }
            let m = currentModules[row]
            switch cid {
            case "module":
                cell.stringValue = m.indentedDisplayName
                if m.level == 0 {
                    cell.font = NSFont.systemFont(ofSize: 12, weight: .bold)
                } else if m.level == 1 {
                    cell.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                } else {
                    cell.font = NSFont.systemFont(ofSize: 11.5)
                    cell.textColor = .secondaryLabelColor
                }
            case "req":
                cell.stringValue = m.requiredCredits > 0 ? String(format: "%g", m.requiredCredits) : "--"
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            case "passed":
                cell.stringValue = String(format: "%g", m.passedCredits)
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                cell.textColor = m.passedCredits > 0 ? .systemGreen : .secondaryLabelColor
            case "taking":
                cell.stringValue = m.takingCredits > 0 ? String(format: "+%g", m.takingCredits) : "--"
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                cell.textColor = m.takingCredits > 0 ? .systemBlue : .tertiaryLabelColor
            case "status":
                // 通识选修特殊子规则：七大类至少修读五大类、美育 ≥ 2 分、跨专业 ≥ 2 分、四史 ≥ 1 分
                if m.name.contains("通识选修") && m.level == 1 {
                    let subMods = currentModules.filter { $0.level == 2 }
                    let coveredCats = subMods.filter { $0.passedCredits + $0.takingCredits > 0.01 }.count
                    let totalCats = subMods.count   // should be 7
                    let catRule = coveredCats >= 5 ? "✅ 已覆盖 \(coveredCats)/\(totalCats) 类" : "⚠️ 仅覆盖 \(coveredCats)/\(totalCats) 类（≥5）"
                    let artMod = subMods.first { $0.name.contains("艺术审美") || $0.name.contains("美育") }
                    let artCredits = (artMod?.passedCredits ?? 0) + (artMod?.takingCredits ?? 0)
                    let artRule = artCredits >= 2.0 - 0.01 ? "美育✅" : String(format: "美育⚠️%.1f/2", artCredits)
                    cell.stringValue = "\(catRule) · \(artRule)"
                    cell.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                    cell.textColor = (coveredCats >= 5 && artCredits >= 1.99) ? .systemGreen : .systemOrange
                } else {
                    let badge = m.statusBadgeText
                    cell.stringValue = badge
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                    if badge.hasPrefix("✅") {
                        cell.textColor = .systemGreen
                    } else if badge.hasPrefix("⏳") {
                        cell.textColor = .systemBlue
                    } else if badge.hasPrefix("差") {
                        cell.textColor = .systemOrange
                    } else {
                        cell.textColor = .secondaryLabelColor
                    }
                }
            case "courses":
                // 通识选修显示七大类覆盖明细
                if m.name.contains("通识选修") && m.level == 1 {
                    let subMods = currentModules.filter { $0.level == 2 }
                    let parts = subMods.map { sub -> String in
                        let cr = sub.passedCredits + sub.takingCredits
                        let shortName = sub.name.count > 8 ? String(sub.name.prefix(8)) : sub.name
                        return cr > 0.01 ? "\(shortName)(✅\(String(format: "%g", cr))分)" : "\(shortName)(未选)"
                    }
                    cell.stringValue = parts.joined(separator: " · ")
                    cell.textColor = .secondaryLabelColor
                    // 完整提示：加上跨专业/四史说明
                    cell.toolTip = subMods.map { "\($0.name): 已获 \($0.passedCredits) 分" + ($0.takingCredits > 0 ? "，在修 \($0.takingCredits) 分" : "") }.joined(separator: "\n")
                        + "\n\n⚠️ 跨专业选修（≥2学分）、四史类（≥1学分）需在教务系统确认，无法从模块数据自动检测。"
                } else {
                    let summary = m.courseDetailSummary
                    cell.stringValue = summary
                    cell.textColor = .secondaryLabelColor
                    let fullTooltip = (m.takingCourseNames.isEmpty ? "" : "【在修】" + m.takingCourseNames.joined(separator: "、") + "\n")
                        + (m.unrepairedCourseNames.isEmpty ? "" : "【待修】" + m.unrepairedCourseNames.joined(separator: "、"))
                    if !fullTooltip.isEmpty {
                        cell.toolTip = fullTooltip.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            default:
                break
            }
        } else {
            if currentTextbooks.isEmpty {
                if cid == "course" {
                    cell.stringValue = "正在从树维教务同步本学期课程教材数据..."
                    cell.textColor = .secondaryLabelColor
                } else {
                    cell.stringValue = "--"
                    cell.textColor = .tertiaryLabelColor
                }
                return cell
            }
            guard row >= 0 && row < currentTextbooks.count else { return nil }
            let tb = currentTextbooks[row]
            switch cid {
            case "course":
                cell.stringValue = tb.courseName
                cell.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                cell.toolTip = "\(tb.courseName) (\(tb.lessonCode))"
            case "type":
                cell.stringValue = tb.courseType
                cell.textColor = .secondaryLabelColor
            case "credits":
                cell.stringValue = String(format: "%g分 · %@", tb.credits, tb.examMode)
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            case "textbook":
                let disp = tb.displayTextbook
                cell.stringValue = disp
                cell.toolTip = disp
                if disp.contains("暂未指定") || disp.contains("不需要") {
                    cell.textColor = .tertiaryLabelColor
                } else {
                    cell.textColor = .systemBlue
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                }
            case "schedule":
                let info = tb.department.isEmpty ? tb.scheduleSummary : "\(tb.department) · \(tb.scheduleSummary)"
                cell.stringValue = info
                cell.textColor = .secondaryLabelColor
                cell.toolTip = tb.scheduleSummary
            default:
                break
            }
        }

        return cell
    }
}

