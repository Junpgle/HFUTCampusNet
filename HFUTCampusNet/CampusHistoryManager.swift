import Foundation
import AppKit

/// 每日校园网流量历史记录
public struct DailyFlowRecord: Codable, Identifiable {
    public var id: String { dateString }
    public var dateString: String         // "2026-10-09"
    public var totalUsedMB: Double         // 当日最新记录的已用流量 (MB)
    public var startOfDayUsedMB: Double    // 当日初次记录的起始已用流量基准 (MB)
    public var dailyDeltaMB: Double        // 今日新增消耗流量 (MB)
    public var availableMB: Double?        // 剩余可用流量 (MB)
    public var balanceRMB: Double?         // 校园网账户余额 (元)
    public var peakSpeedMBs: Double        // 当日监测到的最高瞬时网速 (MB/s)
    public var lastUpdated: Date

    public init(
        dateString: String,
        totalUsedMB: Double,
        startOfDayUsedMB: Double,
        dailyDeltaMB: Double,
        availableMB: Double? = nil,
        balanceRMB: Double? = nil,
        peakSpeedMBs: Double = 0.0,
        lastUpdated: Date = Date()
    ) {
        self.dateString = dateString
        self.totalUsedMB = totalUsedMB
        self.startOfDayUsedMB = startOfDayUsedMB
        self.dailyDeltaMB = dailyDeltaMB
        self.availableMB = availableMB
        self.balanceRMB = balanceRMB
        self.peakSpeedMBs = peakSpeedMBs
        self.lastUpdated = lastUpdated
    }

    public var formattedDailyDelta: String {
        if dailyDeltaMB >= 1024.0 {
            return String(format: "%.2f GB", dailyDeltaMB / 1024.0)
        } else {
            return String(format: "%.0f MB", dailyDeltaMB)
        }
    }
}

/// 每日宿舍电费历史记录
public struct DailyElectricityRecord: Codable, Identifiable {
    public var id: String { dateString }
    public var dateString: String         // "2026-10-09"
    public var balanceRMB: Double          // 当日最新剩余电费 (元)
    public var startOfDayBalanceRMB: Double// 当日初次记录的起始电费基准 (元)
    public var remainingKWh: Double?       // 当日最新剩余电量 (度)
    public var startOfDayKWh: Double?      // 当日初次记录的起始电量基准 (度)
    public var dailyCostRMB: Double        // 当日消耗电费 (元)
    public var dailyUsedKWh: Double        // 当日消耗电量 (度)
    public var lastUpdated: Date

    public init(
        dateString: String,
        balanceRMB: Double,
        startOfDayBalanceRMB: Double,
        remainingKWh: Double? = nil,
        startOfDayKWh: Double? = nil,
        dailyCostRMB: Double = 0.0,
        dailyUsedKWh: Double = 0.0,
        lastUpdated: Date = Date()
    ) {
        self.dateString = dateString
        self.balanceRMB = balanceRMB
        self.startOfDayBalanceRMB = startOfDayBalanceRMB
        self.remainingKWh = remainingKWh
        self.startOfDayKWh = startOfDayKWh
        self.dailyCostRMB = dailyCostRMB
        self.dailyUsedKWh = dailyUsedKWh
        self.lastUpdated = lastUpdated
    }

    public var formattedDailyCost: String {
        return String(format: "%.2f 元", dailyCostRMB)
    }

    public var formattedDailyKWh: String {
        return String(format: "%.1f 度", dailyUsedKWh)
    }
}

/// 历史统计总存储模型
public struct CampusHistoryStore: Codable {
    public var flowRecords: [DailyFlowRecord] = []
    public var electricityRecords: [DailyElectricityRecord] = []
}

/// 校园网与电费历史统计管理器
public class CampusHistoryManager {
    public static let shared = CampusHistoryManager()

    private var store: CampusHistoryStore = CampusHistoryStore()
    private let queue = DispatchQueue(label: "cn.edu.hfut.history.queue", qos: .utility)

    private let storeURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("cn.edu.hfut.campusnet.monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent("history_stats.json")
    }()

    private init() {
        loadStore()
    }

    private func loadStore() {
        guard let data = try? Data(contentsOf: storeURL),
              let loaded = try? JSONDecoder().decode(CampusHistoryStore.self, from: data) else {
            return
        }
        self.store = loaded
    }

    private func saveStore() {
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: storeURL)
        }
    }

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - 记录校园网流量

    public func recordFlow(
        usedFlowStr: String,
        availableFlowStr: String? = nil,
        balanceStr: String? = nil,
        currentSpeedMBs: Double? = nil
    ) {
        queue.async {
            let today = self.todayString()
            guard let totalMB = self.parseFlowToMB(usedFlowStr) else { return }

            let availMB = availableFlowStr != nil ? self.parseFlowToMB(availableFlowStr!) : nil
            let balRMB = balanceStr != nil ? self.parseRMB(balanceStr!) : nil

            if let idx = self.store.flowRecords.firstIndex(where: { $0.dateString == today }) {
                var record = self.store.flowRecords[idx]
                record.totalUsedMB = totalMB
                if let a = availMB { record.availableMB = a }
                if let b = balRMB { record.balanceRMB = b }

                // 计算今日新增消耗
                if totalMB >= record.startOfDayUsedMB {
                    record.dailyDeltaMB = totalMB - record.startOfDayUsedMB
                } else {
                    // 月初重置或计数器归零
                    record.startOfDayUsedMB = 0
                    record.dailyDeltaMB = totalMB
                }

                if let spd = currentSpeedMBs, spd > record.peakSpeedMBs {
                    record.peakSpeedMBs = spd
                }
                record.lastUpdated = Date()
                self.store.flowRecords[idx] = record
            } else {
                // 今日首次记录
                let newRecord = DailyFlowRecord(
                    dateString: today,
                    totalUsedMB: totalMB,
                    startOfDayUsedMB: totalMB,
                    dailyDeltaMB: 0.0,
                    availableMB: availMB,
                    balanceRMB: balRMB,
                    peakSpeedMBs: currentSpeedMBs ?? 0.0,
                    lastUpdated: Date()
                )
                self.store.flowRecords.append(newRecord)
            }

            // 保留近 90 天
            if self.store.flowRecords.count > 90 {
                self.store.flowRecords.sort { $0.dateString < $1.dateString }
                self.store.flowRecords.removeFirst(self.store.flowRecords.count - 90)
            }

            self.saveStore()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyStatsDidUpdate, object: nil)
            }
        }
    }

    // MARK: - 记录宿舍电费

    public func recordElectricity(_ data: ElectricityData) {
        queue.async {
            guard let bal = data.balanceRMB else { return }
            let today = self.todayString()
            let kwh = data.remainingKWh

            if let idx = self.store.electricityRecords.firstIndex(where: { $0.dateString == today }) {
                var record = self.store.electricityRecords[idx]
                record.balanceRMB = bal
                if let k = kwh { record.remainingKWh = k }

                // 计算今日消耗：若余额下降则记为当日支出；若余额显著增加说明充值了，重置基准
                if bal <= record.startOfDayBalanceRMB {
                    record.dailyCostRMB = record.startOfDayBalanceRMB - bal
                } else {
                    // 今日充值了，更新起始基准为充值后金额
                    record.startOfDayBalanceRMB = bal
                    record.dailyCostRMB = 0.0
                }

                if let currentK = kwh, let startK = record.startOfDayKWh {
                    if currentK <= startK {
                        record.dailyUsedKWh = startK - currentK
                    } else {
                        record.startOfDayKWh = currentK
                        record.dailyUsedKWh = 0.0
                    }
                } else if let currentK = kwh {
                    record.startOfDayKWh = currentK
                }

                record.lastUpdated = Date()
                self.store.electricityRecords[idx] = record
            } else {
                // 今日首次记录
                let newRecord = DailyElectricityRecord(
                    dateString: today,
                    balanceRMB: bal,
                    startOfDayBalanceRMB: bal,
                    remainingKWh: kwh,
                    startOfDayKWh: kwh,
                    dailyCostRMB: 0.0,
                    dailyUsedKWh: 0.0,
                    lastUpdated: Date()
                )
                self.store.electricityRecords.append(newRecord)
            }

            // 保留近 90 天
            if self.store.electricityRecords.count > 90 {
                self.store.electricityRecords.sort { $0.dateString < $1.dateString }
                self.store.electricityRecords.removeFirst(self.store.electricityRecords.count - 90)
            }

            self.saveStore()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyStatsDidUpdate, object: nil)
            }
        }
    }

    // MARK: - 统计查询计算

    /// 今日新增流量消耗 (MB)
    public var todayFlowDeltaMB: Double {
        let today = todayString()
        return store.flowRecords.first(where: { $0.dateString == today })?.dailyDeltaMB ?? 0.0
    }

    /// 近 7 天流量总消耗 (MB)
    public var past7DaysFlowTotalMB: Double {
        let records = getPastDaysFlowRecords(days: 7)
        return records.reduce(0.0) { $0 + $1.dailyDeltaMB }
    }

    /// 近 7 天日均流量消耗 (MB)
    public var past7DaysFlowDailyAverageMB: Double {
        let records = getPastDaysFlowRecords(days: 7)
        guard !records.isEmpty else { return 0.0 }
        return past7DaysFlowTotalMB / Double(records.count)
    }

    /// 近 30 天流量总消耗 (MB)
    public var past30DaysFlowTotalMB: Double {
        let records = getPastDaysFlowRecords(days: 30)
        return records.reduce(0.0) { $0 + $1.dailyDeltaMB }
    }

    /// 今日消耗电费 (元)
    public var todayElectricityCostRMB: Double {
        let today = todayString()
        return store.electricityRecords.first(where: { $0.dateString == today })?.dailyCostRMB ?? 0.0
    }

    /// 今日消耗电量 (度)
    public var todayElectricityUsedKWh: Double {
        let today = todayString()
        return store.electricityRecords.first(where: { $0.dateString == today })?.dailyUsedKWh ?? 0.0
    }

    /// 近 7 天电费总消耗 (元)
    public var past7DaysElectricityTotalCostRMB: Double {
        let records = getPastDaysElectricityRecords(days: 7)
        return records.reduce(0.0) { $0 + $1.dailyCostRMB }
    }

    /// 近 7 天日均电费消耗 (元/天)
    public var past7DaysElectricityDailyAverageCostRMB: Double {
        let records = getPastDaysElectricityRecords(days: 7)
        guard !records.isEmpty else { return 2.0 } // 缺省日均按 2.0 元预估
        let avg = past7DaysElectricityTotalCostRMB / Double(records.count)
        return avg > 0.1 ? avg : 2.0
    }

    /// 智能预测：剩余电费预计可用天数
    public var estimatedElectricityDaysRemaining: Int? {
        guard let latest = store.electricityRecords.last?.balanceRMB, latest > 0 else {
            return nil
        }
        let dailyAvg = past7DaysElectricityDailyAverageCostRMB
        guard dailyAvg > 0 else { return nil }
        let days = Int(latest / dailyAvg)
        return max(1, days)
    }

    /// 获取近 N 天流量历史记录 (按日期由旧到新排序)
    public func getPastDaysFlowRecords(days: Int) -> [DailyFlowRecord] {
        let sorted = store.flowRecords.sorted { $0.dateString < $1.dateString }
        if sorted.count <= days {
            return sorted
        }
        return Array(sorted.suffix(days))
    }

    /// 获取近 N 天电费历史记录 (按日期由旧到新排序)
    public func getPastDaysElectricityRecords(days: Int) -> [DailyElectricityRecord] {
        let sorted = store.electricityRecords.sorted { $0.dateString < $1.dateString }
        if sorted.count <= days {
            return sorted
        }
        return Array(sorted.suffix(days))
    }

    // MARK: - 辅助解析器

    private func parseFlowToMB(_ str: String) -> Double? {
        let upper = str.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if upper.hasSuffix("G") || upper.hasSuffix("GB") {
            let numStr = upper.replacingOccurrences(of: "GB", with: "").replacingOccurrences(of: "G", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Double(numStr) { return val * 1024.0 }
        } else if upper.hasSuffix("M") || upper.hasSuffix("MB") {
            let numStr = upper.replacingOccurrences(of: "MB", with: "").replacingOccurrences(of: "M", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Double(numStr) { return val }
        } else if upper.hasSuffix("K") || upper.hasSuffix("KB") {
            let numStr = upper.replacingOccurrences(of: "KB", with: "").replacingOccurrences(of: "K", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Double(numStr) { return val / 1024.0 }
        } else if let val = Double(upper) {
            return val
        }
        return nil
    }

    private func parseRMB(_ str: String) -> Double? {
        let clean = str.replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(clean)
    }
}
