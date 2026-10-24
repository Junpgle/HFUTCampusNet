import Foundation
import AppKit
import IOKit.ps

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
        static let hideSpeedOnBattery = "campus_hide_speed_on_battery" // 隐藏网速以省电
        static let portalUsername = "campus_portal_username"
        static let portalPassword = "campus_portal_password"
        static let autoLoginPortal = "campus_auto_login_portal"
        static let courseStudentId = "campus_course_student_id"
        static let courseSemesterId = "campus_course_semester_id"
        static let courseSemesterIdManuallySelected = "campus_course_semester_id_manual"
        static let courseBizTypeId = "campus_course_biz_type_id"
        static let courseSessionCookie = "campus_course_session_cookie"
        static let courseTableEnabled = "campus_course_table_enabled"
        static let courseShowOnWidget = "campus_course_show_on_widget"
        static let huixinAuthToken = "campus_huixin_auth_token"
        static let ehallAuthToken = "campus_ehall_auth_token"
        static let casTgcCookie = "campus_cas_tgc_cookie"
        static let libraryToken = "campus_library_auth_token"
        static let libraryUserName = "campus_library_user_name"
        static let libraryBorrowCount = "campus_library_borrow_count"
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
        static let campusCardLowWarningThreshold = "campus_card_low_threshold"
        static let campusCardDailyBudget = "campus_card_daily_budget"
        static let lastNotifiedLowCardBalanceDate = "campus_last_notified_low_card_date"
        static let hideScoreInNotification = "campus_hide_score_in_notification"
        static let notifiedGradeIdsData = "campus_notified_grade_ids_data"
        static let unreadGradeIdsData = "campus_unread_grade_ids_data"
        static let widgetPinToDesktop = "campus_widget_pin_to_desktop"
        // 应用内省电措施（默认仅电池生效，可选择插电同样生效）
        static let powerSaverEnabled = "campus_power_saver_enabled"                    // 总开关
        static let powerSaverApplyOnAC = "campus_power_saver_apply_on_ac"              // 插电时也应用
        static let powerSaverIncludeHeartbeat = "campus_power_saver_include_heartbeat" // 心跳降频
        static let powerSaverHeartbeatSec = "campus_power_saver_heartbeat_sec"
        static let powerSaverIncludeDashboard = "campus_power_saver_include_dashboard"  // 自服务数据轮询降频
        static let powerSaverDashboardSec = "campus_power_saver_dashboard_sec"
        static let powerSaverIncludeSecondary = "campus_power_saver_include_secondary"  // 电费/一卡通降频
        static let powerSaverSecondaryDivisor = "campus_power_saver_secondary_divisor"
        static let powerSaverIncludeAcademic = "campus_power_saver_include_academic"    // 成绩/考场降频
        static let powerSaverAcademicSec = "campus_power_saver_academic_sec"
        static let powerSaverIncludeStudyRoom = "campus_power_saver_include_studyroom"  // 自习室检查降频
        static let powerSaverStudyRoomSec = "campus_power_saver_studyroom_sec"
        static let powerSaverPauseCarousel = "campus_power_saver_pause_carousel"        // 暂停状态栏轮播
        static let powerSaverPauseScreenSleep = "campus_power_saver_pause_screen_sleep" // 息屏/睡眠时暂停监测
    }

    private init() {
        if defaults.object(forKey: Keys.refreshInterval) == nil {
            defaults.set(300.0, forKey: Keys.refreshInterval)
        }
        if defaults.object(forKey: Keys.showDesktopWidget) == nil {
            defaults.set(true, forKey: Keys.showDesktopWidget)
        }
        if defaults.object(forKey: Keys.widgetPinToDesktop) == nil {
            defaults.set(true, forKey: Keys.widgetPinToDesktop)
        }
        if defaults.object(forKey: Keys.widgetOpacity) == nil {
            defaults.set(0.92, forKey: Keys.widgetOpacity)
        }
        if defaults.object(forKey: Keys.hideScoreInNotification) == nil {
            defaults.set(true, forKey: Keys.hideScoreInNotification)
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
        if defaults.object(forKey: Keys.campusCardLowWarningThreshold) == nil {
            defaults.set(15.0, forKey: Keys.campusCardLowWarningThreshold)
        }
        if defaults.object(forKey: Keys.hideScoreInNotification) == nil {
            defaults.set(false, forKey: Keys.hideScoreInNotification)
        }
        if defaults.object(forKey: Keys.autoCheckUpdate) == nil {
            defaults.set(true, forKey: Keys.autoCheckUpdate)
        }
        if defaults.object(forKey: Keys.powerSaverEnabled) == nil {
            defaults.set(true, forKey: Keys.powerSaverEnabled)
        }
        if defaults.object(forKey: Keys.powerSaverApplyOnAC) == nil {
            defaults.set(false, forKey: Keys.powerSaverApplyOnAC)
        }
        if defaults.object(forKey: Keys.powerSaverIncludeHeartbeat) == nil {
            defaults.set(true, forKey: Keys.powerSaverIncludeHeartbeat)
        }
        if defaults.object(forKey: Keys.powerSaverHeartbeatSec) == nil {
            defaults.set(90, forKey: Keys.powerSaverHeartbeatSec)
        }
        if defaults.object(forKey: Keys.powerSaverIncludeDashboard) == nil {
            defaults.set(true, forKey: Keys.powerSaverIncludeDashboard)
        }
        if defaults.object(forKey: Keys.powerSaverDashboardSec) == nil {
            defaults.set(900, forKey: Keys.powerSaverDashboardSec)
        }
        if defaults.object(forKey: Keys.powerSaverIncludeSecondary) == nil {
            defaults.set(true, forKey: Keys.powerSaverIncludeSecondary)
        }
        if defaults.object(forKey: Keys.powerSaverSecondaryDivisor) == nil {
            defaults.set(2, forKey: Keys.powerSaverSecondaryDivisor)
        }
        if defaults.object(forKey: Keys.powerSaverIncludeAcademic) == nil {
            defaults.set(true, forKey: Keys.powerSaverIncludeAcademic)
        }
        if defaults.object(forKey: Keys.powerSaverAcademicSec) == nil {
            defaults.set(3600, forKey: Keys.powerSaverAcademicSec)
        }
        if defaults.object(forKey: Keys.powerSaverIncludeStudyRoom) == nil {
            defaults.set(true, forKey: Keys.powerSaverIncludeStudyRoom)
        }
        if defaults.object(forKey: Keys.powerSaverStudyRoomSec) == nil {
            defaults.set(300, forKey: Keys.powerSaverStudyRoomSec)
        }
        if defaults.object(forKey: Keys.powerSaverPauseCarousel) == nil {
            defaults.set(true, forKey: Keys.powerSaverPauseCarousel)
        }
        if defaults.object(forKey: Keys.powerSaverPauseScreenSleep) == nil {
            defaults.set(true, forKey: Keys.powerSaverPauseScreenSleep)
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

    /// 是否将桌面小组件嵌入桌面图标层（true: 原生桌面小组件模式，不遮挡普通应用窗口，按 F11 显示桌面时驻留；false: 置顶悬浮窗模式）
    public var widgetPinToDesktop: Bool {
        get { defaults.object(forKey: Keys.widgetPinToDesktop) == nil ? true : defaults.bool(forKey: Keys.widgetPinToDesktop) }
        set { defaults.set(newValue, forKey: Keys.widgetPinToDesktop) }
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

    public var courseSemesterIdManuallySelected: Bool {
        get { defaults.bool(forKey: Keys.courseSemesterIdManuallySelected) }
        set { defaults.set(newValue, forKey: Keys.courseSemesterIdManuallySelected) }
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

    /// EHALL 学生画像独立 OAuth Token，不与信息门户或慧新易校 Token 混用。
    public var ehallAuthToken: String? {
        get { defaults.string(forKey: Keys.ehallAuthToken) }
        set { defaults.set(newValue, forKey: Keys.ehallAuthToken) }
    }

    public var casTgcCookie: String? {
        get { defaults.string(forKey: Keys.casTgcCookie) }
        set { defaults.set(newValue, forKey: Keys.casTgcCookie) }
    }

    public var libraryToken: String? {
        get { defaults.string(forKey: Keys.libraryToken) }
        set { defaults.set(newValue, forKey: Keys.libraryToken) }
    }

    public var libraryUserName: String? {
        get { defaults.string(forKey: Keys.libraryUserName) }
        set { defaults.set(newValue, forKey: Keys.libraryUserName) }
    }

    public var libraryBorrowCount: Int {
        get { defaults.integer(forKey: Keys.libraryBorrowCount) }
        set { defaults.set(newValue, forKey: Keys.libraryBorrowCount) }
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

    public var campusCardLowWarningThreshold: Double {
        get {
            let val = defaults.double(forKey: Keys.campusCardLowWarningThreshold)
            return val > 0 ? val : 15.0
        }
        set { defaults.set(newValue, forKey: Keys.campusCardLowWarningThreshold) }
    }

    public var campusCardDailyBudget: Double {
        get {
            let val = defaults.double(forKey: Keys.campusCardDailyBudget)
            return val > 0 ? val : 30.0
        }
        set { defaults.set(newValue, forKey: Keys.campusCardDailyBudget) }
    }

    public var lastNotifiedLowCardBalanceDate: String? {
        get { defaults.string(forKey: Keys.lastNotifiedLowCardBalanceDate) }
        set { defaults.set(newValue, forKey: Keys.lastNotifiedLowCardBalanceDate) }
    }

    public var hideScoreInNotification: Bool {
        get { defaults.bool(forKey: Keys.hideScoreInNotification) }
        set { defaults.set(newValue, forKey: Keys.hideScoreInNotification) }
    }

    public var notifiedGradeIds: Set<String> {
        get {
            guard let data = defaults.data(forKey: Keys.notifiedGradeIdsData),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                defaults.set(data, forKey: Keys.notifiedGradeIdsData)
            }
        }
    }

    public var unreadGradeIds: Set<String> {
        get {
            guard let data = defaults.data(forKey: Keys.unreadGradeIdsData),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                defaults.set(data, forKey: Keys.unreadGradeIdsData)
            }
        }
    }

    public var hideSpeedOnBattery: Bool {
        get { defaults.bool(forKey: Keys.hideSpeedOnBattery) }
        set {
            defaults.set(newValue, forKey: Keys.hideSpeedOnBattery)
            NotificationCenter.default.post(name: .powerModeConfigDidChange, object: nil)
        }
    }

    // MARK: - 应用内省电措施（仅电池供电时生效，插电立即恢复）

    private func postPowerConfigChanged() {
        NotificationCenter.default.post(name: .powerModeConfigDidChange, object: nil)
    }

    /// 省电措施总开关
    public var powerSaverEnabled: Bool {
        get { defaults.object(forKey: Keys.powerSaverEnabled) == nil ? true : defaults.bool(forKey: Keys.powerSaverEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverEnabled)
            postPowerConfigChanged()
        }
    }

    /// 插电时也应用省电措施（不再区分电源类型）
    public var powerSaverApplyOnAC: Bool {
        get { defaults.bool(forKey: Keys.powerSaverApplyOnAC) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverApplyOnAC)
            postPowerConfigChanged()
        }
    }

    /// 电池供电时降低网关心跳频率
    public var powerSaverIncludeHeartbeat: Bool {
        get { defaults.object(forKey: Keys.powerSaverIncludeHeartbeat) == nil ? true : defaults.bool(forKey: Keys.powerSaverIncludeHeartbeat) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverIncludeHeartbeat)
            postPowerConfigChanged()
        }
    }

    /// 电池供电下的心跳间隔（秒）
    public var powerSaverHeartbeatSec: Int {
        get { intOrDefault(Keys.powerSaverHeartbeatSec, fallback: 90) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverHeartbeatSec)
            postPowerConfigChanged()
        }
    }

    /// 电池供电时放慢自服务数据轮询
    public var powerSaverIncludeDashboard: Bool {
        get { defaults.object(forKey: Keys.powerSaverIncludeDashboard) == nil ? true : defaults.bool(forKey: Keys.powerSaverIncludeDashboard) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverIncludeDashboard)
            postPowerConfigChanged()
        }
    }

    /// 电池供电下的自服务数据轮询间隔（秒）
    public var powerSaverDashboardSec: Int {
        get { intOrDefault(Keys.powerSaverDashboardSec, fallback: 900) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverDashboardSec)
            postPowerConfigChanged()
        }
    }

    /// 电池供电时把电费与一卡通降为每 N 个轮询周期拉取一次
    public var powerSaverIncludeSecondary: Bool {
        get { defaults.object(forKey: Keys.powerSaverIncludeSecondary) == nil ? true : defaults.bool(forKey: Keys.powerSaverIncludeSecondary) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverIncludeSecondary)
            postPowerConfigChanged()
        }
    }

    /// 电费/一卡通的降频倍数（每 N 个周期一次，1 = 不降频）
    public var powerSaverSecondaryDivisor: Int {
        get { max(1, intOrDefault(Keys.powerSaverSecondaryDivisor, fallback: 2)) }
        set {
            defaults.set(max(1, newValue), forKey: Keys.powerSaverSecondaryDivisor)
            postPowerConfigChanged()
        }
    }

    /// 电池供电时降低成绩与考场同步频率
    public var powerSaverIncludeAcademic: Bool {
        get { defaults.object(forKey: Keys.powerSaverIncludeAcademic) == nil ? true : defaults.bool(forKey: Keys.powerSaverIncludeAcademic) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverIncludeAcademic)
            postPowerConfigChanged()
        }
    }

    /// 电池供电下的成绩与考场同步间隔（秒）
    public var powerSaverAcademicSec: Int {
        get { intOrDefault(Keys.powerSaverAcademicSec, fallback: 3600) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverAcademicSec)
            postPowerConfigChanged()
        }
    }

    /// 电池供电时降低自习室检查频率
    public var powerSaverIncludeStudyRoom: Bool {
        get { defaults.object(forKey: Keys.powerSaverIncludeStudyRoom) == nil ? true : defaults.bool(forKey: Keys.powerSaverIncludeStudyRoom) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverIncludeStudyRoom)
            postPowerConfigChanged()
        }
    }

    /// 电池供电下的自习室检查间隔（秒）
    public var powerSaverStudyRoomSec: Int {
        get { intOrDefault(Keys.powerSaverStudyRoomSec, fallback: 300) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverStudyRoomSec)
            postPowerConfigChanged()
        }
    }

    /// 电池供电时暂停状态栏轮播
    public var powerSaverPauseCarousel: Bool {
        get { defaults.object(forKey: Keys.powerSaverPauseCarousel) == nil ? true : defaults.bool(forKey: Keys.powerSaverPauseCarousel) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverPauseCarousel)
            postPowerConfigChanged()
        }
    }

    /// 息屏 / 睡眠时暂停网速采样与后台轮询
    public var powerSaverPauseScreenSleep: Bool {
        get { defaults.object(forKey: Keys.powerSaverPauseScreenSleep) == nil ? true : defaults.bool(forKey: Keys.powerSaverPauseScreenSleep) }
        set {
            defaults.set(newValue, forKey: Keys.powerSaverPauseScreenSleep)
            postPowerConfigChanged()
        }
    }

    private func intOrDefault(_ key: String, fallback: Int) -> Int {
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.integer(forKey: key)
    }

    /// 检测当前是否处于电池供电状态
    public static func isOnBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                if state == (kIOPSBatteryPowerValue as String) {
                    return true
                }
            }
        }
        return false
    }

    /// 当前是否应该压制/隐藏网速（开启了隐藏选项，且处于电池供电或已选择插电同样生效）
    public var shouldHideSpeedNow: Bool {
        guard powerSaverEnabled, hideSpeedOnBattery else { return false }
        return powerSaverApplyOnAC || Self.isOnBatteryPower()
    }

    /// 当前是否应该暂停状态栏轮播
    public var shouldPauseCarouselNow: Bool {
        guard powerSaverEnabled, powerSaverPauseCarousel else { return false }
        return powerSaverApplyOnAC || Self.isOnBatteryPower()
    }

    /// 息屏/睡眠时是否暂停监测
    public var shouldPauseOnScreenSleep: Bool {
        return powerSaverEnabled && powerSaverPauseScreenSleep
    }
}

extension Notification.Name {
    public static let dormElectricityDidUpdate = Notification.Name("cn.edu.hfut.dormElectricityDidUpdate")
    public static let historyStatsDidUpdate = Notification.Name("cn.edu.hfut.historyStatsDidUpdate")
    public static let emptyClassroomDidUpdate = Notification.Name("cn.edu.hfut.emptyClassroomDidUpdate")
    public static let academicDataDidUpdate = Notification.Name("cn.edu.hfut.academicDataDidUpdate")
    public static let campusCardDidUpdate = Notification.Name("cn.edu.hfut.campusCardDidUpdate")
    public static let powerModeConfigDidChange = Notification.Name("cn.edu.hfut.powerModeConfigDidChange")
    public static let powerSourceDidChange = Notification.Name("cn.edu.hfut.powerSourceDidChange")
}
