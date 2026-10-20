import Foundation

// MARK: - 1. 教务考试安排与成绩/绩点 (GPA) 模型

/// 单场考试安排
public struct ExamItem: Codable, Identifiable, Equatable {
    public var id: String               // "\(courseName)|\(dateTimeString)"
    public var courseName: String       // 课程名称，例如 "高等数学A(1)"
    public var courseCode: String?      // 课程代码
    public var dateTimeString: String   // 标准时间格式 "YYYY-MM-DD HH:mm~HH:mm"
    public var dateString: String       // 考试日期 "YYYY-MM-DD"
    public var startTimeString: String  // 开始时间 "HH:mm"
    public var endTimeString: String    // 结束时间 "HH:mm"
    public var place: String?           // 考场位置，例如 "敬亭学堂201"
    public var building: String?        // 楼宇
    public var campus: String?          // 校区
    public var examType: String?        // 考试类型，如 "期末考试" / "期中考试"

    public init(
        courseName: String,
        courseCode: String? = nil,
        dateTimeString: String,
        dateString: String,
        startTimeString: String,
        endTimeString: String,
        place: String? = nil,
        building: String? = nil,
        campus: String? = nil,
        examType: String? = nil
    ) {
        self.id = "\(courseName)|\(dateTimeString)"
        self.courseName = courseName
        self.courseCode = courseCode
        self.dateTimeString = dateTimeString
        self.dateString = dateString
        self.startTimeString = startTimeString
        self.endTimeString = endTimeString
        self.place = place
        self.building = building
        self.campus = campus
        self.examType = examType
    }

    public var startDate: Date? {
        CourseCalendarHelper.parseDate(dateString, startTimeString)
    }

    public var endDate: Date? {
        CourseCalendarHelper.parseDate(dateString, endTimeString)
    }

    /// 距离考试是否已经结束
    public func isFinished(at now: Date = Date()) -> Bool {
        guard let e = endDate else { return false }
        return now >= e
    }

    /// 是否正在考试中
    public func isOngoing(at now: Date = Date()) -> Bool {
        guard let s = startDate, let e = endDate else { return false }
        return s <= now && now < e
    }

    /// 距离考试的自然日天数（0 表示今天考，>0 表示还有 N 天，<0 表示已过去）
    public func daysRemaining(at now: Date = Date()) -> Int {
        let cal = CourseCalendarHelper.beijingCalendar
        let todayStr = CourseCalendarHelper.dateString(from: now)
        guard let todayDate = CourseCalendarHelper.parseDate(todayStr, "00:00"),
              let examDay = CourseCalendarHelper.parseDate(dateString, "00:00") else {
            return 0
        }
        return cal.dateComponents([.day], from: todayDate, to: examDay).day ?? 0
    }

    /// 格式化倒计时徽章文案
    public func countdownBadgeText(at now: Date = Date()) -> String {
        if isOngoing(at: now) {
            return "正在考试"
        }
        if isFinished(at: now) {
            return "已结束"
        }
        let days = daysRemaining(at: now)
        if days == 0 {
            return "今天 \(startTimeString)"
        } else if days == 1 {
            return "明天 \(startTimeString)"
        } else if days == 2 {
            return "后天 \(startTimeString)"
        } else {
            return "还有 \(days) 天"
        }
    }

    public var displayLocation: String {
        let parts = [campus, building, place].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // 去重包含关系
        var unique: [String] = []
        for p in parts {
            if !unique.contains(where: { $0.contains(p) || p.contains($0) }) {
                unique.append(p)
            } else if let idx = unique.firstIndex(where: { p.contains($0) && p.count > $0.count }) {
                unique[idx] = p
            }
        }
        return unique.isEmpty ? "考场待定" : unique.joined(separator: " · ")
    }
}

/// Approximate final-exam date inferred from the last scheduled lesson.
/// It deliberately has no time or location because neither is available from the course schedule.
public struct CourseExamForecast: Equatable, Identifiable {
    public var id: String { "\(lessonId)|\(predictedDateString)" }
    public var lessonId: Int
    public var courseName: String
    public var courseCode: String?
    public var lastLessonDateString: String
    public var predictedDateString: String

    public var predictedDateDisplayText: String { "\(predictedDateString)（预计）" }
    public var basisDisplayText: String { "最后一次课 \(lastLessonDateString) · 按所在周取次次周周一" }
}

public enum CourseExamForecastService {
    /// Estimates each teaching group's final-exam day as the Monday of the second week after its final lesson's week.
    /// A published final-exam record takes precedence; midterm records do not suppress the estimate.
    public static func upcoming(
        schedule: CourseScheduleData? = CourseScheduleService.shared.currentSchedule,
        officialExams: [ExamItem] = [],
        at now: Date = Date()
    ) -> [CourseExamForecast] {
        guard let schedule, !schedule.lessons.isEmpty else { return [] }

        let calendar = CourseCalendarHelper.beijingCalendar
        let todayString = CourseCalendarHelper.dateString(from: now)
        let today = CourseCalendarHelper.parseDate(todayString, "00:00") ?? now
        let publishedFinalExams = officialExams.filter { exam in
            guard let type = exam.examType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else {
                return true
            }
            return !type.localizedCaseInsensitiveContains("期中")
        }

        return Dictionary(grouping: schedule.lessons, by: \.lessonId)
            .compactMap { lessonId, lessons -> CourseExamForecast? in
                guard lessonId > 0 else { return nil }
                let datedLessons = lessons.compactMap { lesson -> (CourseLesson, Date)? in
                    guard let date = CourseCalendarHelper.parseDate(lesson.dateString, "00:00") else { return nil }
                    return (lesson, date)
                }
                guard let lastLesson = datedLessons.max(by: { $0.1 < $1.1 }) else { return nil }
                let daysUntilSecondNextMonday = 15 - CourseCalendarHelper.weekday(from: lastLesson.1)
                guard let predictedDate = calendar.date(byAdding: .day, value: daysUntilSecondNextMonday, to: lastLesson.1),
                      predictedDate >= today else {
                    return nil
                }

                let course = lastLesson.0
                guard !publishedFinalExams.contains(where: {
                    Self.matches(courseName: course.courseName, courseCode: course.courseCode,
                                 examName: $0.courseName, examCode: $0.courseCode)
                }) else {
                    return nil
                }

                return CourseExamForecast(
                    lessonId: lessonId,
                    courseName: course.courseName,
                    courseCode: course.courseCode,
                    lastLessonDateString: CourseCalendarHelper.dateString(from: lastLesson.1),
                    predictedDateString: CourseCalendarHelper.dateString(from: predictedDate)
                )
            }
            .sorted {
                if $0.predictedDateString != $1.predictedDateString {
                    return $0.predictedDateString < $1.predictedDateString
                }
                return $0.courseName.localizedCaseInsensitiveCompare($1.courseName) == .orderedAscending
            }
    }

    private static func matches(courseName: String, courseCode: String?, examName: String, examCode: String?) -> Bool {
        if let courseCode = normalized(courseCode), let examCode = normalized(examCode) {
            return courseCode == examCode
        }
        guard let normalizedCourseName = normalized(courseName),
              let normalizedExamName = normalized(examName) else {
            return false
        }
        return normalizedCourseName == normalizedExamName
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined()
            .uppercased()
        return normalized.isEmpty ? nil : normalized
    }
}

/// 单门课程成绩项
public struct GradeItem: Codable, Identifiable, Equatable {
    public var id: String               // "\(termName)|\(lessonCode.isEmpty ? courseName : lessonCode)"
    public var termName: String         // 学期名称，例如 "2025-2026学年第二学期"
    public var semesterId: Int?         // 学期 ID（若从移动端获取则有，便于按学期排序）
    public var courseName: String       // 课程名称
    public var courseCode: String       // 课程代码
    public var lessonCode: String       // 教学班代码，例如 "0570080X--001"
    public var credits: Double          // 学分，例如 3.0
    public var gpa: Double?             // 绩点，例如 4.0（等级制如 P/NP 或科研训练可能为 nil）
    public var scoreText: String        // 总评成绩文本，例如 "93" 或 "优秀" / "良"
    public var numericScore: Double?    // 数值化分数（五级制自动折算：优95/良85/中75/及格65/不及格50，通过/不通过不计入）
    public var detailText: String       // 成绩分项明细，例如 "期末考试:93 · 平时成绩:95"
    public var passed: Bool             // 是否及格

    public init(
        termName: String,
        semesterId: Int? = nil,
        courseName: String,
        courseCode: String,
        lessonCode: String,
        credits: Double,
        gpa: Double?,
        scoreText: String,
        detailText: String,
        passed: Bool
    ) {
        let cleanCourse = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLesson = lessonCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = "\(termName)|\(cleanLesson.isEmpty ? cleanCourse : cleanLesson)"
        self.termName = termName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.semesterId = semesterId
        self.courseName = cleanCourse
        self.courseCode = courseCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lessonCode = cleanLesson
        self.credits = credits
        self.gpa = gpa
        self.scoreText = scoreText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.numericScore = GradeItem.parseNumericScore(from: self.scoreText)
        self.detailText = detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.passed = passed
    }

    public static func parseNumericScore(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let val = Double(trimmed) {
            return val
        }
        switch trimmed {
        case "优", "优秀": return 95.0
        case "良", "良好": return 85.0
        case "中", "中等": return 75.0
        case "及格": return 65.0
        case "不及格": return 50.0
        default: return nil
        }
    }
}

/// 按学期分组的成绩单与统计汇总
public struct TermGradeGroup: Codable, Equatable {
    public var termName: String
    public var semesterId: Int?
    public var grades: [GradeItem]

    public var totalCredits: Double {
        grades.filter { $0.passed }.reduce(0.0) { $0 + $1.credits }
    }

    /// 加权平均绩点 (GPA)
    public var weightedGPA: Double? {
        let valid = grades.filter { $0.gpa != nil && $0.credits > 0 }
        let sumCredits = valid.reduce(0.0) { $0 + $1.credits }
        guard sumCredits > 0 else { return nil }
        let sumPoints = valid.reduce(0.0) { $0 + ($1.gpa ?? 0.0) * $1.credits }
        return sumPoints / sumCredits
    }

    /// 加权平均分（百分制）
    public var weightedScore: Double? {
        let valid = grades.filter { $0.numericScore != nil && $0.credits > 0 }
        let sumCredits = valid.reduce(0.0) { $0 + $1.credits }
        guard sumCredits > 0 else { return nil }
        let sumScores = valid.reduce(0.0) { $0 + ($1.numericScore ?? 0.0) * $1.credits }
        return sumScores / sumCredits
    }
}

/// 培养方案模块/子模块完成进度项
public struct ProgramModuleItem: Codable, Identifiable, Equatable {
    public var id: String                   // 模块路径标识
    public var name: String                 // 模块名称，如 "通识必修" / "专业选修"
    public var level: Int                   // 层级：0 顶级模块，1 子模块，2 孙模块(如通识选修七大模块)
    public var requiredCredits: Double      // 要求学分
    public var passedCredits: Double        // 已修通过学分
    public var takingCredits: Double        // 本学期在修学分
    public var passedCourseCount: Int       // 已通过门数
    public var takingCourseCount: Int       // 在修门数
    public var takingCourseNames: [String]  // 在修课程列表，如 ["操作系统(3.5)", "计算机网络(3.0)"]
    public var unrepairedCourseNames: [String] // 尚未修读的计划内课程列表

    public init(
        id: String,
        name: String,
        level: Int,
        requiredCredits: Double,
        passedCredits: Double,
        takingCredits: Double,
        passedCourseCount: Int,
        takingCourseCount: Int,
        takingCourseNames: [String] = [],
        unrepairedCourseNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.level = level
        self.requiredCredits = requiredCredits
        self.passedCredits = passedCredits
        self.takingCredits = takingCredits
        self.passedCourseCount = passedCourseCount
        self.takingCourseCount = takingCourseCount
        self.takingCourseNames = takingCourseNames
        self.unrepairedCourseNames = unrepairedCourseNames
    }

    /// 树形缩进标题
    public var indentedDisplayName: String {
        switch level {
        case 0: return "📦 \(name)"
        case 1: return "    ├─ \(name)"
        default: return "        • \(name)"
        }
    }

    /// 扣除已获学分后的剩余缺口
    public var deficitAfterPassed: Double {
        max(0.0, requiredCredits - passedCredits)
    }

    /// 扣除已获 + 在修学分后的净缺口
    public var deficitAfterTaking: Double {
        max(0.0, requiredCredits - passedCredits - takingCredits)
    }

    /// 状态徽章文案
    public var statusBadgeText: String {
        if requiredCredits <= 0 {
            if passedCredits > 0 || takingCredits > 0 {
                return String(format: "已修 %.1f 分", passedCredits + takingCredits)
            }
            return "任选子模块"
        }
        if passedCredits >= requiredCredits - 0.01 {
            return "✅ 已达标 (100%)"
        }
        if passedCredits + takingCredits >= requiredCredits - 0.01 {
            return "⏳ 含在修达标"
        }
        return String(format: "差 %.1f 学分 (含在修差 %.1f)", deficitAfterPassed, deficitAfterTaking)
    }

    /// 在修与待修课程摘要
    public var courseDetailSummary: String {
        var parts: [String] = []
        if !takingCourseNames.isEmpty {
            let preview = takingCourseNames.prefix(5).joined(separator: "、")
            let suffix = takingCourseNames.count > 5 ? " 等\(takingCourseNames.count)门" : ""
            parts.append("【在修】\(preview)\(suffix)")
        }
        if !unrepairedCourseNames.isEmpty && level <= 1 {
            let preview = unrepairedCourseNames.prefix(5).joined(separator: "、")
            let suffix = unrepairedCourseNames.count > 5 ? " 等\(unrepairedCourseNames.count)门" : ""
            parts.append("【待修】\(preview)\(suffix)")
        }
        if parts.isEmpty {
            return passedCourseCount > 0 ? "已修过 \(passedCourseCount) 门课程" : "--"
        }
        return parts.joined(separator: "  ")
    }
}

/// 培养方案与毕业学分总体审计模型
public struct ProgramCompletionSummary: Codable, Equatable {
    public var programName: String              // 方案名称，如 "2024级智能科学与技术专业指导性教学计划"
    public var gradeYear: String                // 年级，如 "2024"
    public var auditDateTime: String            // 教务审计时间
    public var requiredCredits: Double          // 毕业要求总学分，如 165.0
    public var passedCredits: Double            // 已修得计划内学分，如 116.0
    public var takingCredits: Double            // 本学期在修计划内学分，如 22.75
    public var passedCourseCount: Int           // 已修门数
    public var takingCourseCount: Int           // 在修门数
    public var outerPassedCredits: Double       // 计划外已获学分
    public var outerTakingCredits: Double       // 计划外在修学分
    public var modules: [ProgramModuleItem]     // 模块层级明细

    public init(
        programName: String,
        gradeYear: String = "",
        auditDateTime: String = "",
        requiredCredits: Double,
        passedCredits: Double,
        takingCredits: Double,
        passedCourseCount: Int,
        takingCourseCount: Int,
        outerPassedCredits: Double = 0,
        outerTakingCredits: Double = 0,
        modules: [ProgramModuleItem] = []
    ) {
        self.programName = programName
        self.gradeYear = gradeYear
        self.auditDateTime = auditDateTime
        self.requiredCredits = requiredCredits
        self.passedCredits = passedCredits
        self.takingCredits = takingCredits
        self.passedCourseCount = passedCourseCount
        self.takingCourseCount = takingCourseCount
        self.outerPassedCredits = outerPassedCredits
        self.outerTakingCredits = outerTakingCredits
        self.modules = modules
    }

    public var completionPercentage: Double {
        guard requiredCredits > 0 else { return 0 }
        return min(100.0, (passedCredits / requiredCredits) * 100.0)
    }

    public var projectedPercentageWithTaking: Double {
        guard requiredCredits > 0 else { return 0 }
        return min(100.0, ((passedCredits + takingCredits) / requiredCredits) * 100.0)
    }

    public var remainingCreditsAfterTaking: Double {
        max(0.0, requiredCredits - passedCredits - takingCredits)
    }
}

/// 本学期课程教材与教学任务项
public struct CourseTextbookItem: Codable, Identifiable, Equatable {
    public var id: String                   // lessonCode 或 courseCode
    public var courseName: String           // 课程名称
    public var courseCode: String           // 课程代码
    public var lessonCode: String           // 教学班号
    public var credits: Double              // 学分
    public var courseType: String           // 课程类别，如 "通识必修课" / "专业核心课"
    public var examMode: String             // 考核方式，如 "考试" / "考查"
    public var department: String           // 开课学院
    public var textbookName: String         // 基本教材名称与 ISBN
    public var referenceBookName: String    // 辅助/自编教材或实验指导书
    public var scheduleSummary: String      // 排课与教师简述

    public init(
        courseName: String,
        courseCode: String,
        lessonCode: String,
        credits: Double,
        courseType: String,
        examMode: String,
        department: String,
        textbookName: String,
        referenceBookName: String,
        scheduleSummary: String
    ) {
        self.id = lessonCode.isEmpty ? courseName : lessonCode
        self.courseName = courseName
        self.courseCode = courseCode
        self.lessonCode = lessonCode
        self.credits = credits
        self.courseType = courseType
        self.examMode = examMode
        self.department = department
        self.textbookName = textbookName
        self.referenceBookName = referenceBookName
        self.scheduleSummary = scheduleSummary
    }

    public var displayTextbook: String {
        let t1 = textbookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let t2 = referenceBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t1.isEmpty && !t2.isEmpty && t1 != t2 {
            return "\(t1) · 附：\(t2)"
        }
        if !t1.isEmpty { return t1 }
        if !t2.isEmpty { return t2 }
        return "暂未指定教材 / 教师讲义"
    }
}

/// 期末学生评教任务项
public struct LessonSurveyItem: Codable, Identifiable, Equatable {
    public var id: String                   // lessonCode
    public var lessonCode: String           // 教学班代码
    public var courseName: String           // 课程名称
    public var openEndTimeText: String      // 开放起止时间
    public var pendingTeachers: [String]    // 尚未评教的教师姓名
    public var completedTeachers: [String]  // 已完成评教的教师姓名

    public init(
        lessonCode: String,
        courseName: String,
        openEndTimeText: String,
        pendingTeachers: [String],
        completedTeachers: [String]
    ) {
        self.id = lessonCode.isEmpty ? courseName : lessonCode
        self.lessonCode = lessonCode
        self.courseName = courseName
        self.openEndTimeText = openEndTimeText
        self.pendingTeachers = pendingTeachers
        self.completedTeachers = completedTeachers
    }

    public var isAllCompleted: Bool {
        pendingTeachers.isEmpty
    }
}

/// 校历与学期进度里程碑计算模型
public struct SemesterMilestoneInfo: Equatable {
    public var semesterName: String
    public var campusName: String
    public var startDateString: String
    public var endDateString: String
    public var examWeekStartDateString: String?
    public var examWeekEndDateString: String?
    public var calendarSourceURL: String
    public var currentWeek: Int
    public var totalWeeks: Int
    public var elapsedDays: Int
    public var totalDays: Int
    public var remainingDays: Int
    public var daysUntilExamWeek: Int       // 距离期末考试周（通常倒数第2周）天数
    public var vacationName: String         // "寒假" 或 "暑假"

    public var progressPercentage: Int {
        guard totalDays > 0 else { return 0 }
        return min(100, max(0, Int(round(Double(elapsedDays) / Double(totalDays) * 100.0))))
    }

    /// 根据当前课表与合工大官方校历推算本学期进度里程碑
    public static func calculate(
        schedule: CourseScheduleData? = CourseScheduleService.shared.currentSchedule,
        campus: String = SettingsManager.shared.dormCampus,
        at now: Date = Date()
    ) -> SemesterMilestoneInfo {
        let cal = CourseCalendarHelper.beijingCalendar
        let semId = Int(schedule?.semesterId ?? "") ?? CourseCalendarHelper.inferSemesterId(at: now)
        let semName = schedule?.semesterName ?? CourseCalendarHelper.formatSemesterName(for: semId)

        // 合工大树维教务系统官方校历起止日期表（源自 /eams5-student 校历元数据）
        let officialDates: [Int: (start: String, end: String)] = [
            374: ("2027-02-22", "2027-07-04"), // 2026-2027学年第二学期
            354: ("2026-09-07", "2027-01-17"), // 2026-2027学年第一学期
            334: ("2026-03-02", "2026-07-12"), // 2025-2026学年第二学期
            314: ("2025-09-08", "2026-01-25"), // 2025-2026学年第一学期
            294: ("2025-02-24", "2025-07-13"), // 2024-2025学年第二学期
            274: ("2024-09-09", "2025-01-19")  // 2024-2025学年第一学期
        ]

        let campusTerm = CampusCalendarService.term(semesterId: semId, campus: campus)
        var startStr = campusTerm?.startDate ?? officialDates[semId]?.start ?? "2026-09-07"
        var endStr = campusTerm?.endDate ?? officialDates[semId]?.end ?? "2027-01-17"

        // 若本地课表包含第 1 周的锚点日期，也可用于动态校准非预设学期
        if officialDates[semId] == nil, let sched = schedule {
            let w1Dates = sched.datesForWeek(1)
            if let d1 = w1Dates[1] {
                startStr = CourseCalendarHelper.dateString(from: d1)
            }
            let maxW = max(19, sched.allWeeks.last ?? 19)
            let wEndDates = sched.datesForWeek(maxW)
            if let d7 = wEndDates[7] {
                endStr = CourseCalendarHelper.dateString(from: d7)
            }
        }

        let todayStr = CourseCalendarHelper.dateString(from: now)
        let todayDate = CourseCalendarHelper.parseDate(todayStr, "00:00") ?? now
        let startDate = CourseCalendarHelper.parseDate(startStr, "00:00") ?? todayDate
        let endDate = CourseCalendarHelper.parseDate(endStr, "23:59") ?? todayDate

        let totalDays = max(1, (cal.dateComponents([.day], from: startDate, to: endDate).day ?? 132) + 1)
        let rawElapsed = (cal.dateComponents([.day], from: startDate, to: todayDate).day ?? 0) + 1
        let elapsedDays = min(totalDays, max(0, rawElapsed))
        let remainingDays = max(0, totalDays - elapsedDays)

        let totalWeeks = max(18, Int(ceil(Double(totalDays) / 7.0)))
        let computedWeek = schedule?.currentWeek(at: now) ?? min(totalWeeks, max(1, (elapsedDays - 1) / 7 + 1))
        let daysUntilExamWeek: Int
        if let examStart = campusTerm?.examStartDate,
           let examStartDate = CourseCalendarHelper.parseDate(examStart, "00:00") {
            daysUntilExamWeek = max(0, cal.dateComponents([.day], from: todayDate, to: examStartDate).day ?? 0)
        } else {
            daysUntilExamWeek = max(0, remainingDays - 14) // 旧版校历未提供考试周细节时沿用估算
        }
        let isAutumn = semName.contains("第一学期") || semName.contains("第1学期") || startStr.contains("-09-")

        return SemesterMilestoneInfo(
            semesterName: semName,
            campusName: CampusCalendarService.selectedCampusName(campus),
            startDateString: startStr,
            endDateString: endStr,
            examWeekStartDateString: campusTerm?.examStartDate,
            examWeekEndDateString: campusTerm?.examEndDate,
            calendarSourceURL: CampusCalendarService.calendarURL(for: campus).absoluteString,
            currentWeek: computedWeek,
            totalWeeks: totalWeeks,
            elapsedDays: elapsedDays,
            totalDays: totalDays,
            remainingDays: remainingDays,
            daysUntilExamWeek: daysUntilExamWeek,
            vacationName: isAutumn ? "寒假" : "暑假"
        )
    }
}

/// 教务学术数据总缓存（包含考试安排、全学期成绩单、培养方案完成度、本学期教材与评教状态）
public struct AcademicDataSnapshot: Codable, Equatable {
    public var exams: [ExamItem]
    public var termGroups: [TermGradeGroup]
    public var programCompletion: ProgramCompletionSummary?
    public var textbooks: [CourseTextbookItem]
    public var surveys: [LessonSurveyItem]
    public var lastSyncTime: Date

    public init(
        exams: [ExamItem] = [],
        termGroups: [TermGradeGroup] = [],
        programCompletion: ProgramCompletionSummary? = nil,
        textbooks: [CourseTextbookItem] = [],
        surveys: [LessonSurveyItem] = [],
        lastSyncTime: Date = Date()
    ) {
        self.exams = exams
        self.termGroups = termGroups
        self.programCompletion = programCompletion
        self.textbooks = textbooks
        self.surveys = surveys
        self.lastSyncTime = lastSyncTime
    }

    enum CodingKeys: String, CodingKey {
        case exams
        case termGroups
        case programCompletion
        case textbooks
        case surveys
        case lastSyncTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exams = (try? c.decode([ExamItem].self, forKey: .exams)) ?? []
        self.termGroups = (try? c.decode([TermGradeGroup].self, forKey: .termGroups)) ?? []
        self.programCompletion = try? c.decode(ProgramCompletionSummary.self, forKey: .programCompletion)
        self.textbooks = (try? c.decode([CourseTextbookItem].self, forKey: .textbooks)) ?? []
        self.surveys = (try? c.decode([LessonSurveyItem].self, forKey: .surveys)) ?? []
        self.lastSyncTime = (try? c.decode(Date.self, forKey: .lastSyncTime)) ?? Date()
    }

    public var allGrades: [GradeItem] {
        termGroups.flatMap { $0.grades }
    }

    public var totalEarnedCredits: Double {
        allGrades.filter { $0.passed }.reduce(0.0) { $0 + $1.credits }
    }

    public var overallWeightedGPA: Double? {
        let valid = allGrades.filter { $0.gpa != nil && $0.credits > 0 }
        let sumCredits = valid.reduce(0.0) { $0 + $1.credits }
        guard sumCredits > 0 else { return nil }
        let sumPoints = valid.reduce(0.0) { $0 + ($1.gpa ?? 0.0) * $1.credits }
        return sumPoints / sumCredits
    }

    public var overallWeightedScore: Double? {
        let valid = allGrades.filter { $0.numericScore != nil && $0.credits > 0 }
        let sumCredits = valid.reduce(0.0) { $0 + $1.credits }
        guard sumCredits > 0 else { return nil }
        let sumScores = valid.reduce(0.0) { $0 + ($1.numericScore ?? 0.0) * $1.credits }
        return sumScores / sumCredits
    }

    /// 尚未结束的近期考试（按时间从近到远排序）
    public func upcomingExams(at now: Date = Date()) -> [ExamItem] {
        exams.filter { !$0.isFinished(at: now) }.sorted { $0.dateTimeString < $1.dateTimeString }
    }

    /// 待完成的评教任务数量
    public var pendingSurveyCount: Int {
        surveys.reduce(0) { $0 + $1.pendingTeachers.count }
    }
}

// MARK: - 2. 校园一卡通余额与消费流水模型

public struct CampusCardTransaction: Codable, Identifiable, Equatable {
    public var id: String               // orderId
    public var merchantName: String     // 商户/摘要名称，例如 "合肥黄山大厦餐饮-持卡人消费"
    public var amountRMB: Double        // 交易金额（元），例如 9.00
    public var balanceAfterRMB: Double? // 交易后卡余额（元），例如 304.19
    public var turnoverType: String     // 交易类型，例如 "消费"、"充值"、"电费"
    public var dateTimeString: String   // 交易发生时间 "YYYY-MM-DD HH:mm:ss"

    public init(
        id: String,
        merchantName: String,
        amountRMB: Double,
        balanceAfterRMB: Double?,
        turnoverType: String,
        dateTimeString: String
    ) {
        self.id = id
        self.merchantName = merchantName
        self.amountRMB = amountRMB
        self.balanceAfterRMB = balanceAfterRMB
        self.turnoverType = turnoverType
        self.dateTimeString = dateTimeString
    }

    public var dateOnlyString: String {
        String(dateTimeString.prefix(10))
    }

    public var monthPrefixString: String {
        String(dateTimeString.prefix(7))
    }

    public var timeOnlyString: String {
        if dateTimeString.count >= 19 {
            let start = dateTimeString.index(dateTimeString.startIndex, offsetBy: 11)
            let end = dateTimeString.index(dateTimeString.startIndex, offsetBy: 19)
            return String(dateTimeString[start..<end])
        }
        return dateTimeString
    }

    public var hourOfDay: Int? {
        let t = timeOnlyString
        guard t.count >= 2 else { return nil }
        return Int(t.prefix(2))
    }

    /// 是否属于支出消费类（排除圈存/充值）
    public var isExpense: Bool {
        !turnoverType.contains("充值") && !turnoverType.contains("补助") && !merchantName.contains("充值")
    }

    /// 简化商户显示名称
    public var cleanMerchantName: String {
        var s = merchantName
            .replacingOccurrences(of: "-持卡人消费", with: "")
            .replacingOccurrences(of: "持卡人消费", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = turnoverType }
        return s
    }

    /// 智能识别消费场景与三餐时段分类
    public var sceneCategoryTag: String {
        if !isExpense {
            return "圈存充值"
        }
        let m = cleanMerchantName
        if m.contains("电") || turnoverType.contains("电") {
            return "电费水控"
        }
        if m.contains("浴") || m.contains("水") || m.contains("淋浴") || m.contains("开水") {
            return "洗浴饮水"
        }
        if m.contains("超市") || m.contains("商贸") || m.contains("百货") || m.contains("便利") || m.contains("店") {
            return "超市购物"
        }
        if m.contains("医") || m.contains("门诊") {
            return "校医院医疗"
        }
        // 餐饮或默认食堂消费：结合刷卡时间自动归类早/午/晚餐
        if let h = hourOfDay {
            if (5...9).contains(h) {
                return "早餐 · 食堂"
            } else if (10...14).contains(h) {
                return "午餐 · 食堂"
            } else if (16...20).contains(h) {
                return "晚餐 · 食堂"
            } else {
                return "加餐 · 餐饮"
            }
        }
        return "食堂餐饮"
    }
}

public struct CampusCardData: Codable, Equatable {
    public var cardAccount: String                  // 卡号/账号，例如 "57919"
    public var holderName: String                   // 持卡人姓名
    public var departmentName: String?              // 专业/部门
    public var balanceRMB: Double                   // 当前可用余额（元）
    public var unsettleAmountRMB: Double            // 待圈存/过渡余额（元）
    public var cardStatusText: String               // 状态："正常" / "挂失" / "冻结"
    public var transactions: [CampusCardTransaction]// 最近消费流水列表
    public var lastUpdated: Date

    public init(
        cardAccount: String = "",
        holderName: String = "",
        departmentName: String? = nil,
        balanceRMB: Double = 0.0,
        unsettleAmountRMB: Double = 0.0,
        cardStatusText: String = "正常",
        transactions: [CampusCardTransaction] = [],
        lastUpdated: Date = Date()
    ) {
        self.cardAccount = cardAccount
        self.holderName = holderName
        self.departmentName = departmentName
        self.balanceRMB = balanceRMB
        self.unsettleAmountRMB = unsettleAmountRMB
        self.cardStatusText = cardStatusText
        self.transactions = transactions
        self.lastUpdated = lastUpdated
    }

    public var displayBalance: String {
        String(format: "%.2f 元", balanceRMB)
    }

    public var isLowBalance: Bool {
        balanceRMB < SettingsManager.shared.campusCardLowWarningThreshold
    }

    /// 今日累计消费总额（元）
    public func todaySpentRMB(at now: Date = Date()) -> Double {
        let todayStr = CourseCalendarHelper.dateString(from: now)
        return transactions
            .filter { $0.dateOnlyString == todayStr && $0.isExpense }
            .reduce(0.0) { $0 + $1.amountRMB }
    }

    /// 今日消费笔数
    public func todayExpenseCount(at now: Date = Date()) -> Int {
        let todayStr = CourseCalendarHelper.dateString(from: now)
        return transactions.filter { $0.dateOnlyString == todayStr && $0.isExpense }.count
    }

    /// 本月累计消费总额（元）
    public func currentMonthSpentRMB(at now: Date = Date()) -> Double {
        let monthPrefix = String(CourseCalendarHelper.dateString(from: now).prefix(7))
        return transactions
            .filter { $0.monthPrefixString == monthPrefix && $0.isExpense }
            .reduce(0.0) { $0 + $1.amountRMB }
    }

    /// 本月累计消费笔数
    public func currentMonthExpenseCount(at now: Date = Date()) -> Int {
        let monthPrefix = String(CourseCalendarHelper.dateString(from: now).prefix(7))
        return transactions.filter { $0.monthPrefixString == monthPrefix && $0.isExpense }.count
    }

    /// 本月累计充值金额（元）
    public func currentMonthRechargedRMB(at now: Date = Date()) -> Double {
        let monthPrefix = String(CourseCalendarHelper.dateString(from: now).prefix(7))
        return transactions
            .filter { $0.monthPrefixString == monthPrefix && !$0.isExpense }
            .reduce(0.0) { $0 + $1.amountRMB }
    }

    /// 消费场景与三餐结构占比统计
    public func expenseStructureBreakdown() -> (
        breakfastRMB: Double,
        lunchRMB: Double,
        dinnerRMB: Double,
        otherRMB: Double,
        topMerchantsText: String,
        ratioSummaryText: String
    ) {
        let expenses = transactions.filter { $0.isExpense }
        let total = max(0.01, expenses.reduce(0.0) { $0 + $1.amountRMB })

        var breakfast = 0.0
        var lunch = 0.0
        var dinner = 0.0
        var other = 0.0
        var merchantSum: [String: Double] = [:]

        for tx in expenses {
            let tag = tx.sceneCategoryTag
            if tag.hasPrefix("早餐") {
                breakfast += tx.amountRMB
            } else if tag.hasPrefix("午餐") {
                lunch += tx.amountRMB
            } else if tag.hasPrefix("晚餐") {
                dinner += tx.amountRMB
            } else {
                other += tx.amountRMB
            }
            let mName = tx.cleanMerchantName
                .replacingOccurrences(of: "管理有限公司", with: "")
                .replacingOccurrences(of: "有限公司", with: "")
                .replacingOccurrences(of: "合肥", with: "")
                .replacingOccurrences(of: "安徽", with: "")
                .replacingOccurrences(of: "山东", with: "")
            merchantSum[mName, default: 0.0] += tx.amountRMB
        }

        let bPct = Int(round(breakfast / total * 100))
        let lPct = Int(round(lunch / total * 100))
        let dPct = Int(round(dinner / total * 100))
        let oPct = max(0, 100 - bPct - lPct - dPct)

        var ratioParts: [String] = []
        if lPct > 0 { ratioParts.append("午\(lPct)%") }
        if dPct > 0 { ratioParts.append("晚\(dPct)%") }
        if bPct > 0 { ratioParts.append("早\(bPct)%") }
        if oPct > 0 { ratioParts.append("其他\(oPct)%") }
        let ratioSummary = ratioParts.isEmpty ? "暂无消费结构" : ratioParts.joined(separator: " · ")

        let topMerchants = merchantSum.sorted { $0.value > $1.value }.prefix(2).map { $0.key }
        let topText = topMerchants.isEmpty ? "暂无常去商户" : "常去：" + topMerchants.joined(separator: " / ")

        return (breakfast, lunch, dinner, other, topText, ratioSummary)
    }

    /// 按日期聚合近期每日消费总额（用于柱状图展示）
    public func dailyExpenseSummary(days: Int = 7, at now: Date = Date()) -> [(dateString: String, spentRMB: Double)] {
        let cal = CourseCalendarHelper.beijingCalendar
        var result: [(String, Double)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            if let d = cal.date(byAdding: .day, value: -offset, to: now) {
                let dStr = CourseCalendarHelper.dateString(from: d)
                let sum = transactions
                    .filter { $0.dateOnlyString == dStr && $0.isExpense }
                    .reduce(0.0) { $0 + $1.amountRMB }
                result.append((dStr, (sum * 100).rounded() / 100.0))
            }
        }
        return result
    }

    /// 按自然月聚合归档流水，供较长周期消费趋势图使用。
    public func monthlyExpenseSummary(months: Int = 12, at now: Date = Date()) -> [(monthString: String, spentRMB: Double, count: Int)] {
        guard months > 0 else { return [] }
        let calendar = CourseCalendarHelper.beijingCalendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM"

        return stride(from: months - 1, through: 0, by: -1).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { return nil }
            let month = formatter.string(from: date)
            let expenses = transactions.filter { $0.monthPrefixString == month && $0.isExpense }
            let total = expenses.reduce(0.0) { $0 + $1.amountRMB }
            return (month, (total * 100).rounded() / 100.0, expenses.count)
        }
    }
}

