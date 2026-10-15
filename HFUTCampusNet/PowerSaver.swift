import Foundation
import IOKit.ps

/// 省电措施的取值形态
public enum PowerSaverKind {
    case toggle   // 只有开关，没有可改数值
    case seconds  // 秒
    case minutes  // 分钟（持久化仍以秒存储）
    case cycles   // 每 N 个轮询周期一次
}

/// 一条应用内省电措施（默认仅电池供电时生效，可选择插电同样生效）
public struct PowerSaverMeasure {
    public let key: String
    public let title: String
    public let detail: String
    public let kind: PowerSaverKind
    /// 可填写的最小值（单位随 kind）；toggle 忽略
    public let minValue: Int
    /// 可填写的最大值（单位随 kind）；toggle 忽略
    public let maxValue: Int
    /// 插电时的行为，仅用于行内文案
    public let acHint: String
}

/// 应用内省电措施：清单、取值与生效后的实际间隔
/// 所有读写都走 SettingsManager，改动即时生效（post .powerModeConfigDidChange）
public enum PowerSaver {
    private static let powerSourceMonitor = PowerSourceStateMonitor()

    /// 插电时的固定行为
    public static let acHeartbeatSec = 30
    public static let acAcademicSec = 900
    public static let acStudyRoomSec = 60

    /// Install one run-loop source so power-mode changes are observed even when Settings is closed.
    public static func startMonitoringPowerSource() {
        _ = powerSourceMonitor
    }

    public static let measures: [PowerSaverMeasure] = [
        PowerSaverMeasure(key: "heartbeat", title: "网关心跳",
                          detail: "多久探测一次校园网网关是否在线",
                          kind: .seconds, minValue: 10, maxValue: 1800,
                          acHint: "插电 \(acHeartbeatSec) 秒"),
        PowerSaverMeasure(key: "dashboard", title: "自服务数据轮询",
                          detail: "流量余额、在线设备等数据的刷新周期",
                          kind: .minutes, minValue: 1, maxValue: 360,
                          acHint: "插电跟随「刷新间隔」"),
        PowerSaverMeasure(key: "secondary", title: "电费 · 一卡通降频",
                          detail: "每 N 个轮询周期拉取一次，1 表示不降频",
                          kind: .cycles, minValue: 1, maxValue: 12,
                          acHint: "插电每周期"),
        PowerSaverMeasure(key: "academic", title: "成绩 · 考场同步",
                          detail: "后台同步成绩、考试与考场安排的周期",
                          kind: .minutes, minValue: 1, maxValue: 480,
                          acHint: "插电 \(acAcademicSec / 60) 分钟"),
        PowerSaverMeasure(key: "studyroom", title: "自习室检查",
                          detail: "检查空教室提醒与跨天日切的周期",
                          kind: .seconds, minValue: 10, maxValue: 1800,
                          acHint: "插电 \(acStudyRoomSec) 秒"),
        PowerSaverMeasure(key: "hidespeed", title: "隐藏网速采样",
                          detail: "挂起网速采样，菜单栏与小组件改显省电状态",
                          kind: .toggle, minValue: 0, maxValue: 0, acHint: ""),
        PowerSaverMeasure(key: "pausecarousel", title: "暂停状态栏轮播",
                          detail: "停止多信息轮播定时器",
                          kind: .toggle, minValue: 0, maxValue: 0, acHint: ""),
        PowerSaverMeasure(key: "pausescreensleep", title: "息屏 / 睡眠时暂停",
                          detail: "屏幕熄灭或系统睡眠时停止监测与采样",
                          kind: .toggle, minValue: 0, maxValue: 0, acHint: ""),
    ]

    /// 当前省电是否应当介入（总开关开启，且处于电池供电或已选择插电同样生效）
    public static func savingActive(onBattery: Bool) -> Bool {
        let s = SettingsManager.shared
        guard s.powerSaverEnabled else { return false }
        return onBattery || s.powerSaverApplyOnAC
    }

    // MARK: - 措施开关与取值（由设置卡片读写）

    public static func isIncluded(_ key: String) -> Bool {
        let s = SettingsManager.shared
        switch key {
        case "heartbeat": return s.powerSaverIncludeHeartbeat
        case "dashboard": return s.powerSaverIncludeDashboard
        case "secondary": return s.powerSaverIncludeSecondary
        case "academic": return s.powerSaverIncludeAcademic
        case "studyroom": return s.powerSaverIncludeStudyRoom
        case "hidespeed": return s.hideSpeedOnBattery
        case "pausecarousel": return s.powerSaverPauseCarousel
        case "pausescreensleep": return s.powerSaverPauseScreenSleep
        default: return false
        }
    }

    public static func setIncluded(_ included: Bool, for key: String) {
        let s = SettingsManager.shared
        switch key {
        case "heartbeat": s.powerSaverIncludeHeartbeat = included
        case "dashboard": s.powerSaverIncludeDashboard = included
        case "secondary": s.powerSaverIncludeSecondary = included
        case "academic": s.powerSaverIncludeAcademic = included
        case "studyroom": s.powerSaverIncludeStudyRoom = included
        case "hidespeed": s.hideSpeedOnBattery = included
        case "pausecarousel": s.powerSaverPauseCarousel = included
        case "pausescreensleep": s.powerSaverPauseScreenSleep = included
        default: break
        }
    }

    /// 值控件显示用的数字（分钟类措施以分钟为单位）
    public static func displayValue(_ key: String) -> Int {
        let s = SettingsManager.shared
        switch key {
        case "heartbeat": return s.powerSaverHeartbeatSec
        case "dashboard": return s.powerSaverDashboardSec / 60
        case "secondary": return s.powerSaverSecondaryDivisor
        case "academic": return s.powerSaverAcademicSec / 60
        case "studyroom": return s.powerSaverStudyRoomSec
        default: return 0
        }
    }

    public static func setDisplayValue(_ value: Int, for key: String) {
        guard let measure = measures.first(where: { $0.key == key }) else { return }
        let clamped = clamp(value, measure: measure)
        let s = SettingsManager.shared
        switch key {
        case "heartbeat": s.powerSaverHeartbeatSec = clamped
        case "dashboard": s.powerSaverDashboardSec = clamped * 60
        case "secondary": s.powerSaverSecondaryDivisor = clamped
        case "academic": s.powerSaverAcademicSec = clamped * 60
        case "studyroom": s.powerSaverStudyRoomSec = clamped
        default: break
        }
    }

    /// 数值控件右侧的单位
    public static func unit(for kind: PowerSaverKind) -> String {
        switch kind {
        case .toggle: return ""
        case .seconds: return "秒"
        case .minutes: return "分钟"
        case .cycles: return "周期"
        }
    }

    /// 把数字限制在措施允许的范围内
    public static func clamp(_ value: Int, measure: PowerSaverMeasure) -> Int {
        min(max(value, measure.minValue), measure.maxValue)
    }

    /// 解析用户填写的文本并限制在合法范围内（无法解析时回退到当前值）
    public static func clamp(_ raw: String, fallback: Int, measure: PowerSaverMeasure) -> Int {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Int(cleaned) else { return fallback }
        return clamp(value, measure: measure)
    }

    /// 行内说明里的取值范围提示
    public static func rangeHint(for measure: PowerSaverMeasure) -> String {
        "可填 \(measure.minValue)~\(measure.maxValue) \(unit(for: measure.kind))"
    }

    // MARK: - 生效后的实际间隔

    public static func heartbeatInterval(onBattery: Bool) -> TimeInterval {
        guard savingActive(onBattery: onBattery),
              SettingsManager.shared.powerSaverIncludeHeartbeat else {
            return TimeInterval(acHeartbeatSec)
        }
        return TimeInterval(SettingsManager.shared.powerSaverHeartbeatSec)
    }

    public static func dashboardInterval(onBattery: Bool) -> TimeInterval {
        let base = SettingsManager.shared.refreshInterval
        guard savingActive(onBattery: onBattery),
              SettingsManager.shared.powerSaverIncludeDashboard else { return base }
        return max(base, TimeInterval(SettingsManager.shared.powerSaverDashboardSec))
    }

    /// 电费与一卡通的拉取倍数（1 = 每个周期都拉）
    public static func secondaryDivisor(onBattery: Bool) -> Int {
        guard savingActive(onBattery: onBattery),
              SettingsManager.shared.powerSaverIncludeSecondary else { return 1 }
        return SettingsManager.shared.powerSaverSecondaryDivisor
    }

    public static func academicInterval(onBattery: Bool) -> TimeInterval {
        guard savingActive(onBattery: onBattery),
              SettingsManager.shared.powerSaverIncludeAcademic else {
            return TimeInterval(acAcademicSec)
        }
        return TimeInterval(SettingsManager.shared.powerSaverAcademicSec)
    }

    public static func studyRoomInterval(onBattery: Bool) -> TimeInterval {
        guard savingActive(onBattery: onBattery),
              SettingsManager.shared.powerSaverIncludeStudyRoom else {
            return TimeInterval(acStudyRoomSec)
        }
        return TimeInterval(SettingsManager.shared.powerSaverStudyRoomSec)
    }

    /// 定时器容差：允许内核合并唤醒，最长 30 秒
    public static func tolerance(for interval: TimeInterval) -> TimeInterval {
        min(30.0, max(1.0, interval * 0.1))
    }

    /// 当前已生效的省电措施数（仅统计会改变轮询节奏的项）
    public static func activeCount(onBattery: Bool) -> Int {
        guard savingActive(onBattery: onBattery) else { return 0 }
        var count = 0
        for measure in measures where measure.kind != .toggle {
            if isIncluded(measure.key) { count += 1 }
        }
        if isIncluded("hidespeed") { count += 1 }
        return count
    }
}

private final class PowerSourceStateMonitor {
    private var runLoopSource: CFRunLoopSource?
    private var lastOnBattery = SettingsManager.isOnBatteryPower()

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(Self.powerSourceDidChange, context) else {
            return
        }
        let retainedSource = source.takeRetainedValue()
        runLoopSource = retainedSource
        CFRunLoopAddSource(CFRunLoopGetMain(), retainedSource, .commonModes)
    }

    private static let powerSourceDidChange: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        let monitor = Unmanaged<PowerSourceStateMonitor>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            monitor.publishIfPowerModeChanged()
        }
    }

    private func publishIfPowerModeChanged() {
        let isOnBattery = SettingsManager.isOnBatteryPower()
        guard isOnBattery != lastOnBattery else { return }
        lastOnBattery = isOnBattery
        NotificationCenter.default.post(name: .powerSourceDidChange, object: nil)
    }
}
