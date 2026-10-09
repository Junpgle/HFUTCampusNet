import Foundation

/// 宿舍电费与用电数据模型
public struct ElectricityData: Codable, Equatable {
    public var campus: String                      // 校区，例如 "合肥校区 (翡翠湖/屯溪路)" 或 "宣城校区"
    public var building: String                    // 楼栋，例如 "11"
    public var room: String                        // 房间号，例如 "502"
    public var balanceRMB: Double?                 // 剩余电费金额（元），例如 35.50
    public var remainingKWh: Double?               // 剩余电量（度），例如 58.20
    public var lastUpdated: Date?                  // 上次更新时间
    public var rawDetails: [String: String]        // 原始返回键值对，例如 "当前剩余金额": "35.50元"

    public init(
        campus: String = "宣城校区",
        building: String = "",
        room: String = "",
        balanceRMB: Double? = nil,
        remainingKWh: Double? = nil,
        lastUpdated: Date? = nil,
        rawDetails: [String: String] = [:]
    ) {
        self.campus = campus
        self.building = building
        self.room = room
        self.balanceRMB = balanceRMB
        self.remainingKWh = remainingKWh
        self.lastUpdated = lastUpdated
        self.rawDetails = rawDetails
    }

    /// 宿舍完整名称
    public var formattedRoom: String {
        if building.isEmpty && room.isEmpty {
            return "未配置宿舍"
        }
        return "\(building)号楼 \(room)室"
    }

    /// 剩余金额展示
    public var displayBalance: String {
        guard let b = balanceRMB else { return "-- 元" }
        return String(format: "%.2f 元", b)
    }

    /// 剩余度数展示
    public var displayPower: String {
        guard let k = remainingKWh else { return "-- 度" }
        return String(format: "%.1f 度", k)
    }

    /// 是否处于低电费预警状态 (低于 10 元)
    public var isLowBalance: Bool {
        guard let b = balanceRMB else { return false }
        return b < 10.0
    }
}
