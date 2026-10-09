import Foundation

/// 单节课程安排模型
public struct CourseLesson: Codable, Identifiable, Equatable {
    public var id: String                  // 唯一标识：如 "lessonId-date-startTime-idx"
    public var lessonId: Int               // 教学班 ID
    public var courseName: String          // 课程名称，例如 "高等数学A(1)"
    public var courseCode: String?         // 课程代码，例如 "MATH1001"
    public var teacher: String?            // 授课教师，例如 "张三"
    public var classroom: String?          // 教室位置，例如 "翠十二教302"
    public var dateString: String          // 上课日期，例如 "2026-10-12"
    public var startTime: Int              // 开始时间数值，例如 800 (代表 08:00)
    public var endTime: Int                // 结束时间数值，例如 940 (代表 09:40)
    public var weekIndex: Int?             // 当前周次，例如 6
    public var weekday: Int                // 星期几 (1: 星期一, ..., 7: 星期日)

    public init(
        id: String,
        lessonId: Int,
        courseName: String,
        courseCode: String? = nil,
        teacher: String? = nil,
        classroom: String? = nil,
        dateString: String,
        startTime: Int,
        endTime: Int,
        weekIndex: Int? = nil,
        weekday: Int = 1
    ) {
        self.id = id
        self.lessonId = lessonId
        self.courseName = courseName
        self.courseCode = courseCode
        self.teacher = teacher
        self.classroom = classroom
        self.dateString = dateString
        self.startTime = startTime
        self.endTime = endTime
        self.weekIndex = weekIndex
        self.weekday = weekday
    }

    /// 格式化时间字符串，例如 "08:00 - 09:40"
    public var formattedTime: String {
        let sh = startTime / 100
        let sm = startTime % 100
        let eh = endTime / 100
        let em = endTime % 100
        return String(format: "%02d:%02d - %02d:%02d", sh, sm, eh, em)
    }

    /// 开始时间格式，例如 "08:00"
    public var formattedStartTime: String {
        let sh = startTime / 100
        let sm = startTime % 100
        return String(format: "%02d:%02d", sh, sm)
    }

    /// 结束时间格式，例如 "09:40"
    public var formattedEndTime: String {
        let eh = endTime / 100
        let em = endTime % 100
        return String(format: "%02d:%02d", eh, em)
    }

    /// 解析后的开始日期对象
    public var startDate: Date? {
        let sh = startTime / 100
        let sm = startTime % 100
        let timeStr = String(format: "%02d:%02d", sh, sm)
        return CourseCalendarHelper.parseDate(dateString, timeStr)
    }

    /// 解析后的结束日期对象
    public var endDate: Date? {
        let eh = endTime / 100
        let em = endTime % 100
        let timeStr = String(format: "%02d:%02d", eh, em)
        return CourseCalendarHelper.parseDate(dateString, timeStr)
    }

    /// 是否正在上课中
    public func isOngoing(at date: Date = Date()) -> Bool {
        guard let s = startDate, let e = endDate else { return false }
        return s <= date && date <= e
    }

    /// 是否尚未开始（即将开始）
    public func isUpcoming(at date: Date = Date()) -> Bool {
        guard let s = startDate else { return false }
        return s > date
    }

    /// 单行紧凑摘要
    public var compactSummary: String {
        let roomStr = classroom.map { "@ \($0)" } ?? ""
        let teacherStr = teacher.map { "(\($0))" } ?? ""
        return "\(formattedStartTime) \(courseName) \(roomStr) \(teacherStr)".trimmingCharacters(in: .whitespaces)
    }
}

/// 完整课表缓存数据集
public struct CourseScheduleData: Codable, Equatable {
    public var studentId: String                   // 树维教务 stdId, 例如 "178506"
    public var semesterId: String                  // 学期 ID, 例如 "354"
    public var semesterName: String?               // 学期名称，例如 "2026-2027学年第一学期"
    public var bizTypeId: String                   // 业务类型 ID, 默认 "2"
    public var lastSyncTime: Date?                 // 上次同步时间
    public var lessons: [CourseLesson]             // 所有课节列表

    public init(
        studentId: String = "178506",
        semesterId: String = "354",
        semesterName: String? = nil,
        bizTypeId: String = "2",
        lastSyncTime: Date? = nil,
        lessons: [CourseLesson] = []
    ) {
        self.studentId = studentId
        self.semesterId = semesterId
        self.semesterName = semesterName
        self.bizTypeId = bizTypeId
        self.lastSyncTime = lastSyncTime
        self.lessons = lessons
    }

    /// 获取某一天的所有课程
    public func lessonsForDate(_ dateStr: String) -> [CourseLesson] {
        lessons.filter { $0.dateString == dateStr }.sorted { $0.startTime < $1.startTime }
    }

    /// 获取指定周次的所有课程
    public func lessonsForWeek(_ week: Int) -> [CourseLesson] {
        lessons.filter { $0.weekIndex == week }.sorted {
            if $0.weekday != $1.weekday {
                return $0.weekday < $1.weekday
            }
            return $0.startTime < $1.startTime
        }
    }

    /// 获取今天的所有课程（根据当前时间）
    public func todayLessons(at now: Date = Date()) -> [CourseLesson] {
        let dateStr = CourseCalendarHelper.dateString(from: now)
        return lessonsForDate(dateStr)
    }

    /// 当前正在进行的课程
    public func currentLesson(at now: Date = Date()) -> CourseLesson? {
        todayLessons(at: now).first { $0.isOngoing(at: now) }
    }

    /// 今天下一节尚未开始的课程
    public func nextLesson(at now: Date = Date()) -> CourseLesson? {
        todayLessons(at: now).first { $0.isUpcoming(at: now) }
    }

    /// 包含的所有有效周次列表（从小到大排序）
    public var allWeeks: [Int] {
        let set = Set(lessons.compactMap { $0.weekIndex })
        return set.sorted()
    }

    /// 推测当前处于第几周
    public func currentWeek(at now: Date = Date()) -> Int? {
        let todayStr = CourseCalendarHelper.dateString(from: now)
        if let match = lessons.first(where: { $0.dateString == todayStr && $0.weekIndex != nil }) {
            return match.weekIndex
        }
        // 如果今天没课，寻找未来最近的一门课所在的周次
        let future = lessons.filter { $0.dateString >= todayStr && $0.weekIndex != nil }.sorted { $0.dateString < $1.dateString }
        return future.first?.weekIndex ?? allWeeks.first
    }
}

/// 日期与时间工具类
public enum CourseCalendarHelper {
    public static var beijingCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        cal.locale = Locale(identifier: "zh_CN")
        cal.firstWeekday = 2 // 星期一为每周第一天
        return cal
    }

    public static func parseDate(_ dateStr: String, _ timeStr: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = beijingCalendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(dateStr) \(timeStr)")
    }

    public static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = beijingCalendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func weekday(from date: Date) -> Int {
        let comps = beijingCalendar.dateComponents([.weekday], from: date)
        // 苹果标准中 Sunday = 1, Monday = 2, ..., Saturday = 7
        // 转换为中国习惯: Monday = 1, ..., Sunday = 7
        let w = comps.weekday ?? 2
        return w == 1 ? 7 : (w - 1)
    }

    public static func weekdayName(from weekday: Int) -> String {
        switch weekday {
        case 1: return "周一"
        case 2: return "周二"
        case 3: return "周三"
        case 4: return "周四"
        case 5: return "周五"
        case 6: return "周六"
        case 7: return "周日"
        default: return "周\(weekday)"
        }
    }

    /// 自动根据当前年份和月份推算学期代码（树维系统规律）
    public static func inferSemesterId(at date: Date = Date()) -> Int {
        let comps = beijingCalendar.dateComponents([.year, .month], from: date)
        let month = comps.month ?? 10
        let year = (comps.year ?? 2026) - (month <= 7 ? 1 : 0)
        let isSpring = (2...7).contains(month)
        return ((year - 2018) * 4 + 3) * 10 + 4 + (isSpring ? 20 : 0)
    }
}
