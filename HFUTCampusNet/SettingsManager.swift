import Foundation
import AppKit

public class SettingsManager {
    public static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let cookie = "campus_session_cookie"
        static let refreshInterval = "campus_refresh_interval" // 秒
        static let showDesktopWidget = "campus_show_desktop_widget"
        static let widgetX = "campus_widget_x"
        static let widgetY = "campus_widget_y"
        static let widgetOpacity = "campus_widget_opacity"
        static let menubarStyle = "campus_menubar_style" // 0: 智能轮播, 1: 仅流量余额, 2: 仅实时网速, 3: 并排显示
        static let carouselInterval = "campus_carousel_interval" // 轮播秒数 (默认 3.5s)
        static let portalUsername = "campus_portal_username"
        static let portalPassword = "campus_portal_password"
        static let autoLoginPortal = "campus_auto_login_portal"
        static let courseStudentId = "campus_course_student_id"
        static let courseSemesterId = "campus_course_semester_id"
        static let courseBizTypeId = "campus_course_biz_type_id"
        static let courseSessionCookie = "campus_course_session_cookie"
        static let courseTableEnabled = "campus_course_table_enabled"
        static let courseShowOnWidget = "campus_course_show_on_widget"
        static let huixinAuthToken = "campus_huixin_auth_token"
        static let casTgcCookie = "campus_cas_tgc_cookie"
        static let dormCampus = "campus_dorm_campus"
        static let dormBuilding = "campus_dorm_building"
        static let dormRoom = "campus_dorm_room"
        static let dormEndNumber = "campus_dorm_end_number"
        static let dormRoomName = "campus_dorm_room_name"
        static let electricityLowWarningThreshold = "campus_electricity_low_threshold"
        static let lastNotifiedLowElectricityDate = "campus_last_notified_low_electricity_date"
        static let casPassword = "campus_cas_password"
        static let skippedUpdateVersion = "campus_skipped_update_version"
        static let autoCheckUpdate = "campus_auto_check_update"
        static let uniAppJwt = "campus_uniapp_jwt"
        static let jxglstuDefaultPasswordCache = "campus_jxglstu_default_pwd_cache"
        static let currentStudyRoomData = "campus_current_study_room_data"
        static let nextDayStudyRoomData = "campus_next_day_study_room_data"
        static let lastNotifiedStudyMorningDate = "campus_last_notified_study_morning_date"
        static let lastNotifiedStudyEveningDate = "campus_last_notified_study_evening_date"
        static let lastNotifiedStudyConflictId = "campus_last_notified_study_conflict_id"
    }

    private init() {
        if defaults.object(forKey: Keys.refreshInterval) == nil {
            defaults.set(300.0, forKey: Keys.refreshInterval)
        }
        if defaults.object(forKey: Keys.showDesktopWidget) == nil {
            defaults.set(true, forKey: Keys.showDesktopWidget)
        }
        if defaults.object(forKey: Keys.widgetOpacity) == nil {
            defaults.set(0.92, forKey: Keys.widgetOpacity)
        }
        if defaults.object(forKey: Keys.menubarStyle) == nil {
            defaults.set(0, forKey: Keys.menubarStyle) // 默认 0: 智能轮播！
        }
        if defaults.object(forKey: Keys.carouselInterval) == nil {
            defaults.set(3.5, forKey: Keys.carouselInterval)
        }
        if defaults.object(forKey: Keys.autoLoginPortal) == nil {
            defaults.set(true, forKey: Keys.autoLoginPortal)
        }
        if defaults.object(forKey: Keys.dormCampus) == nil {
            defaults.set("宣城校区", forKey: Keys.dormCampus)
        }
        if defaults.object(forKey: Keys.dormBuilding) == nil {
            defaults.set("", forKey: Keys.dormBuilding)
        }
        if defaults.object(forKey: Keys.dormRoom) == nil {
            defaults.set("", forKey: Keys.dormRoom)
        }
        if defaults.object(forKey: Keys.dormEndNumber) == nil {
            defaults.set("11", forKey: Keys.dormEndNumber) // 11: 南边照明, 12: 南边空调, 21: 北边照明, 22: 北边空调
        }
        if defaults.object(forKey: Keys.electricityLowWarningThreshold) == nil {
            defaults.set(10.0, forKey: Keys.electricityLowWarningThreshold)
        }
        if defaults.object(forKey: Keys.autoCheckUpdate) == nil {
            defaults.set(true, forKey: Keys.autoCheckUpdate)
        }
        // 账号默认留空，由用户首次在设置中填写
    }

    public var sessionCookie: String? {
        get { defaults.string(forKey: Keys.cookie) }
        set { defaults.set(newValue, forKey: Keys.cookie) }
    }

    public var refreshInterval: TimeInterval {
        get { defaults.double(forKey: Keys.refreshInterval) }
        set { defaults.set(newValue, forKey: Keys.refreshInterval) }
    }

    public var showDesktopWidget: Bool {
        get { defaults.bool(forKey: Keys.showDesktopWidget) }
        set { defaults.set(newValue, forKey: Keys.showDesktopWidget) }
    }

    public var widgetOpacity: CGFloat {
        get { CGFloat(defaults.float(forKey: Keys.widgetOpacity)) }
        set { defaults.set(Float(newValue), forKey: Keys.widgetOpacity) }
    }

    public var widgetOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Keys.widgetX) != nil,
                  defaults.object(forKey: Keys.widgetY) != nil else {
                return nil
            }
            return CGPoint(
                x: defaults.double(forKey: Keys.widgetX),
                y: defaults.double(forKey: Keys.widgetY)
            )
        }
        set {
            if let origin = newValue {
                defaults.set(origin.x, forKey: Keys.widgetX)
                defaults.set(origin.y, forKey: Keys.widgetY)
            } else {
                defaults.removeObject(forKey: Keys.widgetX)
                defaults.removeObject(forKey: Keys.widgetY)
            }
        }
    }

    public var menubarStyle: Int {
        get { defaults.integer(forKey: Keys.menubarStyle) }
        set { defaults.set(newValue, forKey: Keys.menubarStyle) }
    }

    public var carouselInterval: TimeInterval {
        get { defaults.double(forKey: Keys.carouselInterval) }
        set { defaults.set(newValue, forKey: Keys.carouselInterval) }
    }

    public var portalUsername: String {
        get { defaults.string(forKey: Keys.portalUsername) ?? "" }
        set { defaults.set(newValue, forKey: Keys.portalUsername) }
    }

    /// 校园网认证 (172.18.3.3) 与用户自服务系统 (xywzz:8443) 专用密码
    public var portalPassword: String {
        get { defaults.string(forKey: Keys.portalPassword) ?? "" }
        set { defaults.set(newValue, forKey: Keys.portalPassword) }
    }

    /// 统一身份认证 / 信息门户 (cas.hfut.edu.cn) 专用密码（与校园网密码完全独立）
    public var casPassword: String {
        get { defaults.string(forKey: Keys.casPassword) ?? "" }
        set { defaults.set(newValue, forKey: Keys.casPassword) }
    }

    public var autoLoginPortal: Bool {
        get { defaults.bool(forKey: Keys.autoLoginPortal) }
        set { defaults.set(newValue, forKey: Keys.autoLoginPortal) }
    }

    public var courseStudentId: String {
        get { defaults.string(forKey: Keys.courseStudentId) ?? "" }
        set { defaults.set(newValue, forKey: Keys.courseStudentId) }
    }

    public var courseSemesterId: String {
        get {
            if let val = defaults.string(forKey: Keys.courseSemesterId)?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
            return String(CourseCalendarHelper.inferSemesterId())
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Keys.courseSemesterId)
            } else {
                defaults.set(trimmed, forKey: Keys.courseSemesterId)
            }
        }
    }

    public var courseBizTypeId: String {
        get {
            if let val = defaults.string(forKey: Keys.courseBizTypeId)?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
            return "23"
        }
        set { defaults.set(newValue, forKey: Keys.courseBizTypeId) }
    }

    public var courseSessionCookie: String? {
        get { defaults.string(forKey: Keys.courseSessionCookie) }
        set { defaults.set(newValue, forKey: Keys.courseSessionCookie) }
    }

    public var courseTableEnabled: Bool {
        get { defaults.object(forKey: Keys.courseTableEnabled) == nil ? true : defaults.bool(forKey: Keys.courseTableEnabled) }
        set { defaults.set(newValue, forKey: Keys.courseTableEnabled) }
    }

    public var courseShowOnWidget: Bool {
        get { defaults.object(forKey: Keys.courseShowOnWidget) == nil ? true : defaults.bool(forKey: Keys.courseShowOnWidget) }
        set { defaults.set(newValue, forKey: Keys.courseShowOnWidget) }
    }

    public var huixinAuthToken: String? {
        get { defaults.string(forKey: Keys.huixinAuthToken) }
        set { defaults.set(newValue, forKey: Keys.huixinAuthToken) }
    }

    public var casTgcCookie: String? {
        get { defaults.string(forKey: Keys.casTgcCookie) }
        set { defaults.set(newValue, forKey: Keys.casTgcCookie) }
    }

    public var dormCampus: String {
        get { defaults.string(forKey: Keys.dormCampus) ?? "宣城校区" }
        set { defaults.set(newValue, forKey: Keys.dormCampus) }
    }

    public var isDormConfigured: Bool {
        let b = dormBuilding.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = dormRoom.trimmingCharacters(in: .whitespacesAndNewlines)
        return !b.isEmpty && !r.isEmpty
    }

    public var dormBuilding: String {
        get { defaults.string(forKey: Keys.dormBuilding) ?? "" }
        set { defaults.set(newValue, forKey: Keys.dormBuilding) }
    }

    public var dormRoom: String {
        get { defaults.string(forKey: Keys.dormRoom) ?? "" }
        set { defaults.set(newValue, forKey: Keys.dormRoom) }
    }

    public var dormEndNumber: String {
        get { defaults.string(forKey: Keys.dormEndNumber) ?? "11" }
        set { defaults.set(newValue, forKey: Keys.dormEndNumber) }
    }

    public var dormRoomName: String {
        get {
            if !isDormConfigured {
                return "未配置宿舍"
            }
            let endDesc: String
            switch dormEndNumber {
            case "11": endDesc = "南楼/南照明"
            case "12": endDesc = "南楼空调"
            case "21": endDesc = "北楼/北照明"
            case "22": endDesc = "北楼空调"
            default: endDesc = dormEndNumber
            }
            return "\(dormCampus) \(dormBuilding)号楼 \(dormRoom)室 (\(endDesc))"
        }
        set { defaults.set(newValue, forKey: Keys.dormRoomName) }
    }

    public var electricityLowWarningThreshold: Double {
        get {
            let val = defaults.double(forKey: Keys.electricityLowWarningThreshold)
            return val > 0 ? val : 10.0
        }
        set { defaults.set(newValue, forKey: Keys.electricityLowWarningThreshold) }
    }

    public var lastNotifiedLowElectricityDate: String? {
        get { defaults.string(forKey: Keys.lastNotifiedLowElectricityDate) }
        set { defaults.set(newValue, forKey: Keys.lastNotifiedLowElectricityDate) }
    }

    public var skippedUpdateVersion: String? {
        get { defaults.string(forKey: Keys.skippedUpdateVersion) }
        set { defaults.set(newValue, forKey: Keys.skippedUpdateVersion) }
    }

    public var autoCheckUpdate: Bool {
        get { defaults.object(forKey: Keys.autoCheckUpdate) == nil ? true : defaults.bool(forKey: Keys.autoCheckUpdate) }
        set { defaults.set(newValue, forKey: Keys.autoCheckUpdate) }
    }

    public var uniAppJwt: String? {
        get { defaults.string(forKey: Keys.uniAppJwt) }
        set { defaults.set(newValue, forKey: Keys.uniAppJwt) }
    }

    public var jxglstuDefaultPasswordCache: String? {
        get { defaults.string(forKey: Keys.jxglstuDefaultPasswordCache) }
        set { defaults.set(newValue, forKey: Keys.jxglstuDefaultPasswordCache) }
    }

    public var currentStudyRoom: CurrentStudyRoomRecord? {
        get {
            guard let data = defaults.data(forKey: Keys.currentStudyRoomData) else { return nil }
            return try? JSONDecoder().decode(CurrentStudyRoomRecord.self, from: data)
        }
        set {
            if let record = newValue, let data = try? JSONEncoder().encode(record) {
                defaults.set(data, forKey: Keys.currentStudyRoomData)
            } else {
                defaults.removeObject(forKey: Keys.currentStudyRoomData)
            }
        }
    }

    public var nextDayStudyRoom: CurrentStudyRoomRecord? {
        get {
            guard let data = defaults.data(forKey: Keys.nextDayStudyRoomData) else { return nil }
            return try? JSONDecoder().decode(CurrentStudyRoomRecord.self, from: data)
        }
        set {
            if let record = newValue, let data = try? JSONEncoder().encode(record) {
                defaults.set(data, forKey: Keys.nextDayStudyRoomData)
            } else {
                defaults.removeObject(forKey: Keys.nextDayStudyRoomData)
            }
        }
    }

    public var lastNotifiedStudyMorningDate: String? {
        get { defaults.string(forKey: Keys.lastNotifiedStudyMorningDate) }
        set { defaults.set(newValue, forKey: Keys.lastNotifiedStudyMorningDate) }
    }

    public var lastNotifiedStudyEveningDate: String? {
        get { defaults.string(forKey: Keys.lastNotifiedStudyEveningDate) }
        set { defaults.set(newValue, forKey: Keys.lastNotifiedStudyEveningDate) }
    }

    public var lastNotifiedStudyConflictId: String? {
        get { defaults.string(forKey: Keys.lastNotifiedStudyConflictId) }
        set { defaults.set(newValue, forKey: Keys.lastNotifiedStudyConflictId) }
    }
}

extension Notification.Name {
    public static let dormElectricityDidUpdate = Notification.Name("cn.edu.hfut.dormElectricityDidUpdate")
    public static let historyStatsDidUpdate = Notification.Name("cn.edu.hfut.historyStatsDidUpdate")
    public static let emptyClassroomDidUpdate = Notification.Name("cn.edu.hfut.emptyClassroomDidUpdate")
}
