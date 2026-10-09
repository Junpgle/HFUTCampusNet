import Foundation

public struct CampusNetworkData: Codable {
    public var usedFlow: String = "-- M"          // 已用流量，例如 "1191 M"
    public var availableFlow: String = "-- M"     // 可用流量，例如 "99809 M"
    public var flowProtection: String = "-- 元"  // 消费保护，例如 "1 元"
    public var balance: String = "-- 元"          // 账户余额，例如 "7.28 元"
    public var lastUpdated: Date? = nil
    public var errorMessage: String? = nil
    public var isLoggedIn: Bool = false

    public init(
        usedFlow: String = "-- M",
        availableFlow: String = "-- M",
        flowProtection: String = "-- 元",
        balance: String = "-- 元",
        lastUpdated: Date? = nil,
        errorMessage: String? = nil,
        isLoggedIn: Bool = false
    ) {
        self.usedFlow = usedFlow
        self.availableFlow = availableFlow
        self.flowProtection = flowProtection
        self.balance = balance
        self.lastUpdated = lastUpdated
        self.errorMessage = errorMessage
        self.isLoggedIn = isLoggedIn
    }

    /// 提取可用流量的纯数值（转为 MB）
    public var availableMB: Double? {
        parseMB(from: availableFlow)
    }

    /// 提取已用流量的纯数值（转为 MB）
    public var usedMB: Double? {
        parseMB(from: usedFlow)
    }

    /// 便捷显示：将可用流量转换为直观的 GB/MB
    public var formattedAvailable: String {
        guard let mb = availableMB else { return availableFlow }
        if mb >= 1024 {
            let gb = mb / 1024.0
            return String(format: "%.1f G", gb)
        } else {
            return String(format: "%.0f M", mb)
        }
    }

    /// 便捷显示：将已用流量转换为直观的 GB/MB
    public var formattedUsed: String {
        guard let mb = usedMB else { return usedFlow }
        if mb >= 1024 {
            let gb = mb / 1024.0
            return String(format: "%.2f G", gb)
        } else {
            return String(format: "%.0f M", mb)
        }
    }

    /// 流量使用百分比 0.0 ~ 1.0
    public var usagePercentage: Double {
        guard let used = usedMB, let avail = availableMB, (used + avail) > 0 else {
            return 0.0
        }
        return used / (used + avail)
    }

    private func parseMB(from text: String) -> Double? {
        let pattern = "([0-9]+(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let numStr = String(text[range])
        guard let num = Double(numStr) else { return nil }

        let upper = text.uppercased()
        if upper.contains("G") {
            return num * 1024.0
        } else if upper.contains("K") {
            return num / 1024.0
        }
        return num
    }
}
