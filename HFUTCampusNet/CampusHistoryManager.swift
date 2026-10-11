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
        if reconcileContinuity() {
            saveStore()
        }
    }

    /// 跨日连续性校准：将每日起始基准与上一日末尾余额/累计流量对齐，防止夜间或未开机时段消耗漏计
    @discardableResult
    private func reconcileContinuity() -> Bool {
        var modified = false

        // 1. 校准电费记录连续性
        if store.electricityRecords.count > 1 {
            store.electricityRecords.sort { $0.dateString < $1.dateString }
            for i in 1..<store.electricityRecords.count {
                let prev = store.electricityRecords[i - 1]
                var curr = store.electricityRecords[i]

                // 若当日未发生充值（当前余额 <= 前一日末尾余额），则当日 00:00 起始余额应衔接前一日末尾余额
                if curr.balanceRMB <= prev.balanceRMB && abs(curr.startOfDayBalanceRMB - prev.balanceRMB) > 0.001 {
                    curr.startOfDayBalanceRMB = prev.balanceRMB
                    modified = true
                }
                let expectedCost = curr.balanceRMB <= curr.startOfDayBalanceRMB
                    ? max(0.0, curr.startOfDayBalanceRMB - curr.balanceRMB)
                    : 0.0
                if abs(curr.dailyCostRMB - expectedCost) > 0.001 {
                    curr.dailyCostRMB = expectedCost
                    modified = true
                }

                if let prevK = prev.remainingKWh, let currK = curr.remainingKWh, currK <= prevK {
                    if curr.startOfDayKWh == nil || abs(curr.startOfDayKWh! - prevK) > 0.001 {
                        curr.startOfDayKWh = prevK
                        modified = true
                    }
                    let expectedKWh = max(0.0, prevK - currK)
                    if abs(curr.dailyUsedKWh - expectedKWh) > 0.001 {
                        curr.dailyUsedKWh = expectedKWh
                        modified = true
                    }
                }
                store.electricityRecords[i] = curr
            }
        }

        // 2. 校准同月校园网流量记录连续性
        if store.flowRecords.count > 1 {
            store.flowRecords.sort { $0.dateString < $1.dateString }
            for i in 1..<store.flowRecords.count {
                let prev = store.flowRecords[i - 1]
                var curr = store.flowRecords[i]

                // 同一个自然月内且累计流量单调递增时，当日起始已用流量不应高于前一日末尾累计流量
                if prev.dateString.prefix(7) == curr.dateString.prefix(7),
                   curr.totalUsedMB >= prev.totalUsedMB,
                   curr.startOfDayUsedMB > prev.totalUsedMB + 0.01 {
                    curr.startOfDayUsedMB = prev.totalUsedMB
                    curr.dailyDeltaMB = max(curr.dailyDeltaMB, curr.totalUsedMB - curr.startOfDayUsedMB)
                    store.flowRecords[i] = curr
                    modified = true
                }
            }
        }

        return modified
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
                let todayOnlineMB = CampusNetworkClient.shared.latestData.onlineDevices
                    .filter { $0.loginTime.hasPrefix(today) }
                    .reduce(0.0) { $0 + $1.usedFlowMB }

                if totalMB >= record.startOfDayUsedMB {
                    record.dailyDeltaMB = max(totalMB - record.startOfDayUsedMB, todayOnlineMB)
                    if record.dailyDeltaMB == todayOnlineMB && totalMB >= todayOnlineMB {
                        record.startOfDayUsedMB = totalMB - todayOnlineMB
                    }
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
                // 今日首次记录：优先衔接同月上一日末尾的累计流量
                let todayOnlineMB = CampusNetworkClient.shared.latestData.onlineDevices
                    .filter { $0.loginTime.hasPrefix(today) }
                    .reduce(0.0) { $0 + $1.usedFlowMB }
                var startMB = max(0.0, totalMB - todayOnlineMB)

                if let prev = self.store.flowRecords.sorted(by: { $0.dateString < $1.dateString }).last,
                   prev.dateString.prefix(7) == today.prefix(7),
                   totalMB >= prev.totalUsedMB {
                    startMB = min(startMB, prev.totalUsedMB)
                }

                let newRecord = DailyFlowRecord(
                    dateString: today,
                    totalUsedMB: totalMB,
                    startOfDayUsedMB: startMB,
                    dailyDeltaMB: max(0.0, totalMB - startMB),
                    availableMB: availMB,
                    balanceRMB: balRMB,
                    peakSpeedMBs: currentSpeedMBs ?? 0.0,
                    lastUpdated: Date()
                )
                self.store.flowRecords.append(newRecord)
            }

            self.reconcileContinuity()

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
                // 今日首次记录：优先以前一日末尾记录的剩余电费/电量作为今日起始基准
                let prevRecord = self.store.electricityRecords.sorted { $0.dateString < $1.dateString }.last
                let startBal: Double
                let initialCost: Double
                if let prevBal = prevRecord?.balanceRMB, bal <= prevBal {
                    startBal = prevBal
                    initialCost = max(0.0, prevBal - bal)
                } else {
                    startBal = bal
                    initialCost = 0.0
                }

                let startKWh: Double?
                let initialUsedKWh: Double
                if let curK = kwh, let prevK = prevRecord?.remainingKWh, curK <= prevK {
                    startKWh = prevK
                    initialUsedKWh = max(0.0, prevK - curK)
                } else {
                    startKWh = kwh
                    initialUsedKWh = 0.0
                }

                let newRecord = DailyElectricityRecord(
                    dateString: today,
                    balanceRMB: bal,
                    startOfDayBalanceRMB: startBal,
                    remainingKWh: kwh,
                    startOfDayKWh: startKWh,
                    dailyCostRMB: initialCost,
                    dailyUsedKWh: initialUsedKWh,
                    lastUpdated: Date()
                )
                self.store.electricityRecords.append(newRecord)
            }

            self.reconcileContinuity()

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
        let recorded = store.flowRecords.first(where: { $0.dateString == today })?.dailyDeltaMB ?? 0.0
        let onlineToday = CampusNetworkClient.shared.latestData.onlineDevices
            .filter { $0.loginTime.hasPrefix(today) }
            .reduce(0.0) { $0 + $1.usedFlowMB }
        return max(recorded, onlineToday)
    }

    /// 距离次日 00:00 单日限额重置倒计时文案
    public var dailyResetCountdownString: String {
        let cal = Calendar.current
        let now = Date()
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) {
            let diff = Int(tomorrow.timeIntervalSince(now))
            let hours = max(0, diff / 3600)
            let mins = max(0, (diff % 3600) / 60)
            return "\(hours) 小时 \(mins) 分钟后重置"
        }
        return "每日 00:00 重置"
    }

    /// 距离下月 1 日 00:00 月度限额重置倒计时文案
    public var monthlyResetCountdownString: String {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month], from: now)
        if let m = comps.month, let y = comps.year {
            if m == 12 {
                comps.year = y + 1
                comps.month = 1
            } else {
                comps.month = m + 1
            }
            comps.day = 1
            comps.hour = 0
            comps.minute = 0
            comps.second = 0
            if let nextMonthStart = cal.date(from: comps) {
                let diff = Int(nextMonthStart.timeIntervalSince(now))
                let days = max(0, diff / 86400)
                let hours = max(0, (diff % 86400) / 3600)
                return "\(days) 天 \(hours) 小时后重置"
            }
        }
        return "每月 1 日重置"
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
        guard !records.isEmpty else { return 0.0 }

        // 若首条记录是初次安装时的基准快照（当日消耗为 0），且已有后续跨日记录，则按实际产生跨日消耗的有效天数计算日均
        var effectiveRecords = records
        if effectiveRecords.count > 1, let first = effectiveRecords.first, first.dailyCostRMB < 0.001 {
            effectiveRecords.removeFirst()
        }

        let total = effectiveRecords.reduce(0.0) { $0 + $1.dailyCostRMB }
        guard !effectiveRecords.isEmpty, total > 0.0001 else { return 0.0 }
        return total / Double(effectiveRecords.count)
    }

    /// 智能预测：剩余电费预计可用天数
    public var estimatedElectricityDaysRemaining: Int? {
        guard let latest = store.electricityRecords.last?.balanceRMB, latest > 0 else {
            return nil
        }
        let dailyAvg = past7DaysElectricityDailyAverageCostRMB
        guard dailyAvg > 0.001 else { return nil }
        let days = Int(round(latest / dailyAvg))
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
