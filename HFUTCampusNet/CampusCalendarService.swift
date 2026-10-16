import Foundation

public struct CampusCalendarTerm: Equatable {
    public var semesterId: Int
    public var startDate: String
    public var endDate: String
    public var examStartDate: String
    public var examEndDate: String
}

public struct CampusCalendarEvent: Equatable, Identifiable {
    public var id: String { "\(dateRange)-\(title)" }
    public var dateRange: String
    public var title: String
    public var campusName: String
}

/// 已核验的官方校历日期，以及按学生选定校区定位官方校历来源的入口。
public enum CampusCalendarService {
    public static let hefeiCalendarURL = URL(string: "https://jwc.hfut.edu.cn/info2025.jsp?urltype=news.NewsContentUrl&wbnewsid=5664&wbtreeid=1293")!
    public static let xuanChengCalendarURL = URL(string: "https://xcjwb.hfut.edu.cn/1180/list.htm")!

    private static let verifiedTerms: [Int: CampusCalendarTerm] = [
        354: CampusCalendarTerm(
            semesterId: 354,
            startDate: "2026-09-07",
            endDate: "2027-01-17",
            examStartDate: "2027-01-11",
            examEndDate: "2027-01-17"
        ),
        374: CampusCalendarTerm(
            semesterId: 374,
            startDate: "2027-02-22",
            endDate: "2027-07-04",
            examStartDate: "2027-06-28",
            examEndDate: "2027-07-04"
        )
    ]

    public static func selectedCampusName(_ configuredCampus: String = SettingsManager.shared.dormCampus) -> String {
        configuredCampus.hasPrefix("合肥") ? configuredCampus : "宣城校区"
    }

    public static func calendarURL(for campus: String = SettingsManager.shared.dormCampus) -> URL {
        campus.hasPrefix("合肥") ? hefeiCalendarURL : xuanChengCalendarURL
    }

    public static func term(semesterId: Int, campus: String = SettingsManager.shared.dormCampus) -> CampusCalendarTerm? {
        // 两份官方 2026-2027 学年校历的学期起止与第19周期末考试周一致。
        // campus 参数用于明确校区来源，后续校历日期有差异时可按来源单独扩展。
        _ = selectedCampusName(campus)
        return verifiedTerms[semesterId]
    }

    public static func upcomingEvents(
        campus: String = SettingsManager.shared.dormCampus,
        at now: Date = Date()
    ) -> [CampusCalendarEvent] {
        let campusName = selectedCampusName(campus)
        let schedule: [(String, String, String)] = [
            ("2026-09-05", "2026-09-06", "第一学期注册"),
            ("2026-09-07", "2026-09-07", "第一学期上课"),
            ("2027-01-11", "2027-01-17", "第一学期期末考试周"),
            ("2027-01-18", "2027-02-19", "寒假"),
            ("2027-02-20", "2027-02-21", "第二学期注册"),
            ("2027-02-22", "2027-02-22", "第二学期上课"),
            ("2027-05-13", "2027-05-14", "校区运动会（计划）"),
            ("2027-06-28", "2027-07-04", "第二学期期末考试周"),
            ("2027-07-05", "2027-07-05", "暑假开始（学期结束后）")
        ]
        let formatter = DateFormatter()
        formatter.calendar = CourseCalendarHelper.beijingCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let todayDate = formatter.date(from: today) ?? now
        return schedule.compactMap { start, end, title in
            guard formatter.date(from: start) != nil,
                  let endDate = formatter.date(from: end), endDate >= todayDate else { return nil }
            let range = start == end ? start : "\(start) 至 \(end)"
            return CampusCalendarEvent(dateRange: range, title: title, campusName: campusName)
        }
    }
}
