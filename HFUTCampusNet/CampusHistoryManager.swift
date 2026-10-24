import Foundation
import AppKit
import CryptoKit

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
    /// 2 means stored traffic values use actual (up + down) volume rather than the billable half-sum.
    public var flowAccountingVersion: Int? = nil
    public var flowHistoryPartitionVersion: Int? = nil
    public var flowRecordsByAccount: [String: [DailyFlowRecord]]? = nil
    public var flowRecords: [DailyFlowRecord] = []
    public var electricityRecords: [DailyElectricityRecord] = []
    public var electricityDormKey: String? = nil
    /// 非当前宿舍的电费历史；旧版的 electricityRecords/electricityDormKey 仍表示当前分区。
    public var archivedElectricityRecords: [String: [DailyElectricityRecord]]? = nil

    @discardableResult
    public mutating func activateElectricityHistory(for dormKey: String) -> Bool {
        guard electricityDormKey != dormKey else { return false }

        var archived = archivedElectricityRecords ?? [:]
        if let previousKey = electricityDormKey {
            if !electricityRecords.isEmpty {
                archived[previousKey] = electricityRecords
            }
        } else if !electricityRecords.isEmpty {
            // 老数据缺少宿舍标识时仍保留原记录，但不将其误并入当前宿舍。
            archived["__legacy_unassigned__"] = electricityRecords
        }

        electricityRecords = archived.removeValue(forKey: dormKey) ?? []
        electricityDormKey = dormKey
        archivedElectricityRecords = archived.isEmpty ? nil : archived
        return true
    }
}

/// 校园网与电费历史统计管理器
public class CampusHistoryManager {
    public static let shared = CampusHistoryManager()
    private static let currentFlowAccountingVersion = 2
    private static let currentFlowHistoryPartitionVersion = 1

    private var store: CampusHistoryStore = CampusHistoryStore()
    private let queue = DispatchQueue(label: "cn.edu.hfut.history.queue", qos: .utility)
    private var historyBackupRequired = false
    private var flowAccountPartitionBackupRequired = false
    private var flowAccountingMigrationBackupRequired = false
    private var flowHistoryContinuityBackupRequired = false
    private var activeFlowAccountKey = ""

    private let storeURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("cn.edu.hfut.campusnet.monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent("history_stats.json")
    }()

    private init() {
        activeFlowAccountKey = Self.flowAccountKey(for: SettingsManager.shared.portalUsername)
        loadStore()
    }

    private func loadStore() {
        var loaded: CampusHistoryStore?
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let data = try Data(contentsOf: storeURL)
                loaded = try JSONDecoder().decode(CampusHistoryStore.self, from: data)
            } catch {
                print("历史记录加载失败: \(error.localizedDescription)")
                historyBackupRequired = !backupUnreadableHistory()
            }
        }
        if let loaded {
            self.store = loaded
        }

        let hasFlowHistoryPartitions = (store.flowHistoryPartitionVersion ?? 0) >= Self.currentFlowHistoryPartitionVersion
            && store.flowRecordsByAccount != nil
        let needsFlowPartitionMigration = loaded != nil && !hasFlowHistoryPartitions
        if hasFlowHistoryPartitions {
            var partitions = store.flowRecordsByAccount ?? [:]
            store.flowRecords = partitions.removeValue(forKey: activeFlowAccountKey) ?? []
            store.flowRecordsByAccount = partitions
        } else if needsFlowPartitionMigration {
            if !backupHistoryBeforeFlowPartitionMigration() {
                flowAccountPartitionBackupRequired = true
            }
            store.flowHistoryPartitionVersion = Self.currentFlowHistoryPartitionVersion
            store.flowRecordsByAccount = [:]
        }

        let needsFlowMigration = (store.flowAccountingVersion ?? 0) < Self.currentFlowAccountingVersion
        if needsFlowMigration {
            flowAccountingMigrationBackupRequired = true
            _ = completeFlowAccountingMigrationIfNeeded()
        }

        let continuityBeforeSelection = reconcileContinuity()
        if continuityBeforeSelection {
            flowHistoryContinuityBackupRequired = true
        }
        let currentDormKey = Self.electricityDormKey(
            campus: SettingsManager.shared.dormCampus,
            building: SettingsManager.shared.dormBuilding,
            room: SettingsManager.shared.dormRoom,
            endNumber: SettingsManager.shared.dormEndNumber
        )
        let selectedCurrentHistory = store.activateElectricityHistory(for: currentDormKey)
        let continuityAfterSelection = selectedCurrentHistory ? reconcileContinuity() : false
        if continuityAfterSelection {
            flowHistoryContinuityBackupRequired = true
        }

        if loaded != nil && (needsFlowPartitionMigration || needsFlowMigration || continuityBeforeSelection || selectedCurrentHistory || continuityAfterSelection) {
            saveStore()
        }
    }

    private static func flowAccountKey(for username: String) -> String {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let identity = normalizedUsername.isEmpty ? "UNCONFIGURED" : normalizedUsername
        let digest = SHA256.hash(data: Data("portal-username:\(identity)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func backupHistoryBeforeFlowPartitionMigration() -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return true }
        let backupURL = storeURL.appendingPathExtension("pre-flow-account-partition-v1.bak")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return true }
        do {
            try FileManager.default.copyItem(at: storeURL, to: backupURL)
            return true
        } catch {
            print("流量账号历史分区迁移前备份失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 切换校园网流量历史分区；旧版无账号标记的记录在首次加载时归入当前保存账号。
    public func activateFlowHistory(for username: String) {
        let targetAccountKey = Self.flowAccountKey(for: username)
        let didChange = queue.sync {
            guard activeFlowAccountKey != targetAccountKey else { return false }

            var partitions = store.flowRecordsByAccount ?? [:]
            let unconfiguredAccountKey = Self.flowAccountKey(for: "")
            if activeFlowAccountKey == unconfiguredAccountKey && partitions.isEmpty {
                // Legacy records migrated before a username was configured belong to the first configured account.
                flowHistoryContinuityBackupRequired = true
                if backupHistoryBeforeFlowContinuityAdjustment() {
                    flowHistoryContinuityBackupRequired = false
                }
                activeFlowAccountKey = targetAccountKey
                store.flowRecordsByAccount = partitions
                reconcileContinuity()
                saveStore()
                return true
            }

            flowHistoryContinuityBackupRequired = true
            if backupHistoryBeforeFlowContinuityAdjustment() {
                flowHistoryContinuityBackupRequired = false
            }

            partitions[activeFlowAccountKey] = store.flowRecords
            store.flowRecords = partitions.removeValue(forKey: targetAccountKey) ?? []
            store.flowRecordsByAccount = partitions
            activeFlowAccountKey = targetAccountKey
            reconcileContinuity()
            saveStore()
            return true
        }

        if didChange {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyStatsDidUpdate, object: nil)
            }
        }
    }

    private func backupHistoryBeforeFlowMigration() -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return true }
        let backupURL = storeURL.appendingPathExtension("pre-traffic-scale-v2.bak")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return true }
        do {
            try FileManager.default.copyItem(at: storeURL, to: backupURL)
            return true
        } catch {
            print("流量历史迁移前备份失败: \(error.localizedDescription)")
            return false
        }
    }

    private func backupHistoryBeforeFlowContinuityAdjustment() -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return true }
        let backupURL = storeURL.appendingPathExtension("pre-flow-continuity-v1.bak")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return true }
        do {
            try FileManager.default.copyItem(at: storeURL, to: backupURL)
            return true
        } catch {
            print("流量连续性校准前备份失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func completeFlowAccountingMigrationIfNeeded() -> Bool {
        guard flowAccountingMigrationBackupRequired else { return true }
        guard backupHistoryBeforeFlowMigration() else { return false }

        func scale(_ record: inout DailyFlowRecord) {
            record.totalUsedMB *= 2.0
            record.startOfDayUsedMB *= 2.0
            record.dailyDeltaMB *= 2.0
            record.availableMB = record.availableMB.map { $0 * 2.0 }
        }

        for index in store.flowRecords.indices {
            scale(&store.flowRecords[index])
        }
        if var partitions = store.flowRecordsByAccount {
            for accountKey in Array(partitions.keys) {
                guard var records = partitions[accountKey] else { continue }
                for index in records.indices {
                    scale(&records[index])
                }
                partitions[accountKey] = records
            }
            store.flowRecordsByAccount = partitions
        }
        store.flowAccountingVersion = Self.currentFlowAccountingVersion
        flowAccountingMigrationBackupRequired = false
        return true
    }

    private static func electricityDormKey(campus: String, building: String, room: String, endNumber: String) -> String {
        "\(campus)|\(building)|\(room)|\(endNumber)"
    }

    /// 切换当前宿舍对应的电费历史分区，历史记录按身份保留。
    public func activateElectricityHistory(campus: String, building: String, room: String, endNumber: String) {
        let dormKey = Self.electricityDormKey(campus: campus, building: building, room: room, endNumber: endNumber)
        let didChange = queue.sync {
            guard self.store.activateElectricityHistory(for: dormKey) else { return false }
            if self.reconcileContinuity() {
                self.flowHistoryContinuityBackupRequired = true
            }
            self.saveStore()
            return true
        }

        if didChange {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyStatsDidUpdate, object: nil)
            }
        }
    }

    /// 跨日连续性校准：将每日起始基准与上一日末尾余额/累计流量对齐，并对多日未开机的断档期按日均平滑回填，防止单日消耗暴增或漏计
    @discardableResult
    private func reconcileContinuity() -> Bool {
        var modified = false

        // 1. 校准电费记录连续性（含多日断档平滑回填）
        if store.electricityRecords.count > 1 {
            store.electricityRecords.sort { $0.dateString < $1.dateString }
            var expandedElec: [DailyElectricityRecord] = [store.electricityRecords[0]]
            for i in 1..<store.electricityRecords.count {
                let prev = expandedElec.last!
                var curr = store.electricityRecords[i]
                let gap = daysBetween(prev.dateString, curr.dateString)
                let hasBalanceRechargeEvidence = prev.balanceRMB.isFinite && curr.startOfDayBalanceRMB.isFinite &&
                    curr.startOfDayBalanceRMB > prev.balanceRMB + 0.05
                let hasKWhRechargeEvidence: Bool = {
                    guard let previousKWh = prev.remainingKWh, previousKWh.isFinite else { return false }
                    let currentKWhIncreased = curr.remainingKWh.map {
                        $0.isFinite && $0 > previousKWh + 0.05
                    } ?? false
                    let startOfDayKWhIncreased = curr.startOfDayKWh.map {
                        $0.isFinite && $0 > previousKWh + 0.05
                    } ?? false
                    return currentKWhIncreased || startOfDayKWhIncreased
                }()

                if gap > 1 && gap <= 30 && curr.balanceRMB < prev.balanceRMB - 0.001 &&
                    !hasBalanceRechargeEvidence && !hasKWhRechargeEvidence {
                    // 若 curr 的起始余额仍停留在多日前的 prev.balanceRMB，将期间总消耗均摊到断档的每一天
                    let targetEndOfPrevDay: Double
                    if abs(curr.startOfDayBalanceRMB - prev.balanceRMB) < 0.001 {
                        let stepCost = (prev.balanceRMB - curr.balanceRMB) / Double(gap)
                        targetEndOfPrevDay = prev.balanceRMB - stepCost * Double(gap - 1)
                    } else if curr.startOfDayBalanceRMB <= prev.balanceRMB && curr.startOfDayBalanceRMB >= curr.balanceRMB {
                        targetEndOfPrevDay = curr.startOfDayBalanceRMB
                    } else {
                        let stepCost = (prev.balanceRMB - curr.balanceRMB) / Double(gap)
                        targetEndOfPrevDay = prev.balanceRMB - stepCost * Double(gap - 1)
                    }

                    let offlineCostPerDay = max(0.0, (prev.balanceRMB - targetEndOfPrevDay) / Double(gap - 1))
                    let offlineKWhPerDay: Double? = {
                        if let pk = prev.remainingKWh, let ck = curr.remainingKWh, ck <= pk {
                            let targetPrevK = (curr.startOfDayKWh != nil && abs(curr.startOfDayKWh! - pk) > 0.001 && curr.startOfDayKWh! <= pk)
                                ? curr.startOfDayKWh!
                                : (pk - (pk - ck) / Double(gap) * Double(gap - 1))
                            return max(0.0, (pk - targetPrevK) / Double(gap - 1))
                        }
                        return nil
                    }()

                    for step in 1..<gap {
                        if let midDate = addDays(step, to: prev.dateString) {
                            let sBal = prev.balanceRMB - offlineCostPerDay * Double(step - 1)
                            let eBal = prev.balanceRMB - offlineCostPerDay * Double(step)
                            let sKWh = (prev.remainingKWh != nil && offlineKWhPerDay != nil)
                                ? (prev.remainingKWh! - offlineKWhPerDay! * Double(step - 1))
                                : nil
                            let eKWh = (prev.remainingKWh != nil && offlineKWhPerDay != nil)
                                ? (prev.remainingKWh! - offlineKWhPerDay! * Double(step))
                                : nil
                            expandedElec.append(DailyElectricityRecord(
                                dateString: midDate,
                                balanceRMB: eBal,
                                startOfDayBalanceRMB: sBal,
                                remainingKWh: eKWh,
                                startOfDayKWh: sKWh,
                                dailyCostRMB: offlineCostPerDay,
                                dailyUsedKWh: offlineKWhPerDay ?? 0.0,
                                lastUpdated: curr.lastUpdated
                            ))
                        }
                    }
                    curr.startOfDayBalanceRMB = targetEndOfPrevDay
                    curr.dailyCostRMB = max(0.0, curr.startOfDayBalanceRMB - curr.balanceRMB)
                    if let pk = prev.remainingKWh, let kStep = offlineKWhPerDay {
                        let targetPrevK = pk - kStep * Double(gap - 1)
                        curr.startOfDayKWh = targetPrevK
                        if let ck = curr.remainingKWh {
                            curr.dailyUsedKWh = max(0.0, targetPrevK - ck)
                        }
                    }
                    modified = true
                }
                expandedElec.append(curr)
            }
            store.electricityRecords = expandedElec

            for i in 1..<store.electricityRecords.count {
                let prev = store.electricityRecords[i - 1]
                var curr = store.electricityRecords[i]
                let gap = daysBetween(prev.dateString, curr.dateString)

                // 相邻日期且未发生充值（当前余额 <= 前一日末尾余额且起始基准低于前一日末尾余额），当日 00:00 起始余额衔接前一日末尾余额
                if gap == 1 && curr.balanceRMB <= prev.balanceRMB && curr.startOfDayBalanceRMB < prev.balanceRMB - 0.001 {
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

                if gap == 1, let prevK = prev.remainingKWh, let currK = curr.remainingKWh, currK <= prevK {
                    if curr.startOfDayKWh == nil || curr.startOfDayKWh! < prevK - 0.001 {
                        curr.startOfDayKWh = prevK
                        modified = true
                    }
                    let startK = curr.startOfDayKWh ?? prevK
                    let expectedKWh = max(0.0, startK - currK)
                    if abs(curr.dailyUsedKWh - expectedKWh) > 0.001 {
                        curr.dailyUsedKWh = expectedKWh
                        modified = true
                    }
                }
                store.electricityRecords[i] = curr
            }
        }

        // 2. 校准同月校园网流量记录连续性（含多日未开机断档均摊回填，避免多日手机流量全部算进今日已用）
        if store.flowRecords.count > 1 {
            store.flowRecords.sort { $0.dateString < $1.dateString }
            var expandedFlow: [DailyFlowRecord] = [store.flowRecords[0]]
            for i in 1..<store.flowRecords.count {
                let prev = expandedFlow.last!
                var curr = store.flowRecords[i]
                let gap = daysBetween(prev.dateString, curr.dateString)

                if prev.dateString.prefix(7) == curr.dateString.prefix(7),
                   curr.totalUsedMB >= prev.totalUsedMB {
                    if gap > 1 && gap <= 30 {
                        let targetEndOfPrevDay: Double
                        if curr.startOfDayUsedMB > prev.totalUsedMB + 0.01 && curr.startOfDayUsedMB <= curr.totalUsedMB {
                            targetEndOfPrevDay = curr.startOfDayUsedMB
                        } else {
                            let stepMB = (curr.totalUsedMB - prev.totalUsedMB) / Double(gap)
                            targetEndOfPrevDay = prev.totalUsedMB + stepMB * Double(gap - 1)
                        }
                        let offlineDailyMB = max(0.0, (targetEndOfPrevDay - prev.totalUsedMB) / Double(gap - 1))
                        for step in 1..<gap {
                            if let midDate = addDays(step, to: prev.dateString) {
                                let sMB = prev.totalUsedMB + offlineDailyMB * Double(step - 1)
                                let eMB = prev.totalUsedMB + offlineDailyMB * Double(step)
                                expandedFlow.append(DailyFlowRecord(
                                    dateString: midDate,
                                    totalUsedMB: eMB,
                                    startOfDayUsedMB: sMB,
                                    dailyDeltaMB: offlineDailyMB,
                                    availableMB: nil,
                                    balanceRMB: prev.balanceRMB,
                                    peakSpeedMBs: 0.0,
                                    lastUpdated: curr.lastUpdated
                                ))
                            }
                        }
                        curr.startOfDayUsedMB = targetEndOfPrevDay
                        curr.dailyDeltaMB = max(0.0, curr.totalUsedMB - curr.startOfDayUsedMB)
                        modified = true
                    } else if gap == 1 && abs(curr.startOfDayUsedMB - prev.totalUsedMB) > 0.01 {
                        curr.startOfDayUsedMB = prev.totalUsedMB
                        curr.dailyDeltaMB = max(0.0, curr.totalUsedMB - curr.startOfDayUsedMB)
                        modified = true
                    }
                }
                expandedFlow.append(curr)
            }
            store.flowRecords = expandedFlow
        }

        return modified
    }

    private func saveStore() {
        if historyBackupRequired {
            guard backupUnreadableHistory() else { return }
            historyBackupRequired = false
        }
        if flowAccountPartitionBackupRequired {
            guard backupHistoryBeforeFlowPartitionMigration() else { return }
            flowAccountPartitionBackupRequired = false
        }
        guard completeFlowAccountingMigrationIfNeeded() else { return }
        if flowHistoryContinuityBackupRequired {
            guard backupHistoryBeforeFlowContinuityAdjustment() else { return }
            flowHistoryContinuityBackupRequired = false
        }
        var partitions = store.flowRecordsByAccount ?? [:]
        partitions[activeFlowAccountKey] = store.flowRecords
        store.flowRecordsByAccount = partitions
        store.flowHistoryPartitionVersion = Self.currentFlowHistoryPartitionVersion
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func backupUnreadableHistory() -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return true }
        let backupURL = storeURL.appendingPathExtension("load-failure-\(UUID().uuidString).bak")
        do {
            try FileManager.default.copyItem(at: storeURL, to: backupURL)
            return true
        } catch {
            print("损坏的历史记录备份失败: \(error.localizedDescription)")
            return false
        }
    }

    private func todayString() -> String {
        CourseCalendarHelper.dateString(from: Date())
    }

    private func daysBetween(_ startStr: String, _ endStr: String) -> Int {
        guard let d1 = CourseCalendarHelper.parseDate(startStr, "00:00"),
              let d2 = CourseCalendarHelper.parseDate(endStr, "00:00") else {
            return 0
        }
        return CourseCalendarHelper.beijingCalendar.dateComponents([.day], from: d1, to: d2).day ?? 0
    }

    private func addDays(_ days: Int, to dateStr: String) -> String? {
        guard let date = CourseCalendarHelper.parseDate(dateStr, "00:00"),
              let next = CourseCalendarHelper.beijingCalendar.date(byAdding: .day, value: days, to: date) else {
            return nil
        }
        return CourseCalendarHelper.dateString(from: next)
    }

    // MARK: - 记录校园网流量

    public func recordFlow(
        usedFlowStr: String,
        availableFlowStr: String? = nil,
        balanceStr: String? = nil,
        currentSpeedMBs: Double? = nil,
        observedAt: Date = Date()
    ) {
        // Bind the sample to the account that produced it before crossing onto the
        // history queue. A delayed callback must not land in a newly active account.
        let targetAccountKey = Self.flowAccountKey(for: SettingsManager.shared.portalUsername)
        queue.async {
            guard self.activeFlowAccountKey == targetAccountKey else { return }
            let today = CourseCalendarHelper.dateString(from: observedAt)
            let currentDay = self.todayString()
            // 网关月累计值在请求过程中遇到月初重置时可能已经过期；不要把上月值写入本月历史。
            guard today.prefix(7) == currentDay.prefix(7) else { return }
            guard let totalMB = self.parseFlowToMB(usedFlowStr) else { return }
            guard self.completeFlowAccountingMigrationIfNeeded() else { return }

            let availMB = availableFlowStr != nil ? self.parseFlowToMB(availableFlowStr!) : nil
            let balRMB = balanceStr != nil ? self.parseRMB(balanceStr!) : nil

            let prevSameMonthRecord = self.store.flowRecords
                .filter { $0.dateString < today && $0.dateString.prefix(7) == today.prefix(7) }
                .sorted { $0.dateString < $1.dateString }
                .last
            let prevMonthFloorMB = prevSameMonthRecord?.totalUsedMB ?? 0.0

            if let idx = self.store.flowRecords.firstIndex(where: { $0.dateString == today }) {
                var record = self.store.flowRecords[idx]
                if let a = availMB { record.availableMB = a }
                if let b = balRMB { record.balanceRMB = b }

                // 计算今日新增消耗
                let todayOnlineMB = CampusNetworkClient.shared.latestData.onlineDevices
                    .filter { $0.loginTime.hasPrefix(today) }
                    .reduce(0.0) { $0 + $1.usedFlowMB }

                let isMonthlyReset = today.hasSuffix("-01") && totalMB < record.startOfDayUsedMB * 0.5
                let effectiveTotalMB = isMonthlyReset ? totalMB : max(totalMB, record.totalUsedMB, prevMonthFloorMB)
                record.totalUsedMB = effectiveTotalMB

                if isMonthlyReset {
                    // 仅在月初 1 日且总流量大幅归零时才判定为月度重置
                    record.startOfDayUsedMB = 0
                    record.dailyDeltaMB = effectiveTotalMB
                } else if effectiveTotalMB >= record.startOfDayUsedMB {
                    record.dailyDeltaMB = max(effectiveTotalMB - record.startOfDayUsedMB, todayOnlineMB)
                    if record.dailyDeltaMB == todayOnlineMB && effectiveTotalMB >= todayOnlineMB {
                        record.startOfDayUsedMB = max(prevMonthFloorMB, min(record.startOfDayUsedMB, effectiveTotalMB - todayOnlineMB))
                    }
                } else {
                    record.startOfDayUsedMB = max(prevMonthFloorMB, min(effectiveTotalMB, effectiveTotalMB - record.dailyDeltaMB))
                    record.dailyDeltaMB = max(effectiveTotalMB - record.startOfDayUsedMB, todayOnlineMB)
                }

                if let spd = currentSpeedMBs, spd > record.peakSpeedMBs {
                    record.peakSpeedMBs = spd
                }
                record.lastUpdated = Date()
                self.store.flowRecords[idx] = record
            } else {
                // 今日首次记录：仅当上一条记录为昨天 (gap == 1) 时直接将今日起点对齐到昨日末尾；
                // 若存在多日断档 (gap > 1)，今日起点取 max(prev.totalUsedMB, effectiveTotalMB - todayOnlineMB)，断档期流量交由 reconcileContinuity 均摊到断档日
                let todayOnlineMB = CampusNetworkClient.shared.latestData.onlineDevices
                    .filter { $0.loginTime.hasPrefix(today) }
                    .reduce(0.0) { $0 + $1.usedFlowMB }
                let isMonthlyReset = today.hasSuffix("-01") && totalMB < prevMonthFloorMB * 0.5
                let effectiveTotalMB = isMonthlyReset ? totalMB : max(totalMB, prevMonthFloorMB)
                var startMB = isMonthlyReset ? max(0.0, effectiveTotalMB - todayOnlineMB) : max(prevMonthFloorMB, effectiveTotalMB - todayOnlineMB)

                if !isMonthlyReset, let prev = prevSameMonthRecord,
                   effectiveTotalMB >= prev.totalUsedMB {
                    let gap = self.daysBetween(prev.dateString, today)
                    if gap == 1 {
                        startMB = prev.totalUsedMB
                    } else if gap > 1 {
                        startMB = max(prev.totalUsedMB, startMB)
                    }
                }

                let newRecord = DailyFlowRecord(
                    dateString: today,
                    totalUsedMB: effectiveTotalMB,
                    startOfDayUsedMB: startMB,
                    dailyDeltaMB: max(0.0, effectiveTotalMB - startMB),
                    availableMB: availMB,
                    balanceRMB: balRMB,
                    peakSpeedMBs: currentSpeedMBs ?? 0.0,
                    lastUpdated: Date()
                )
                self.store.flowRecords.append(newRecord)
            }

            if self.reconcileContinuity() {
                self.flowHistoryContinuityBackupRequired = true
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

    /// 实时更新当日监测到的峰值网速 (MB/s)
    public func updatePeakSpeed(speedMBs: Double) {
        guard speedMBs > 0 else { return }
        queue.async {
            let today = self.todayString()
            if let idx = self.store.flowRecords.firstIndex(where: { $0.dateString == today }) {
                if speedMBs > self.store.flowRecords[idx].peakSpeedMBs {
                    self.store.flowRecords[idx].peakSpeedMBs = speedMBs
                    self.saveStore()
                }
            }
        }
    }

    // MARK: - 记录宿舍电费

    public func recordElectricity(_ data: ElectricityData) {
        queue.async {
            guard let bal = data.balanceRMB else { return }
            let dormKey = Self.electricityDormKey(
                campus: data.campus,
                building: data.building,
                room: data.room,
                endNumber: data.endNumber
            )
            self.store.activateElectricityHistory(for: dormKey)

            let today = self.todayString()
            let kwh = data.remainingKWh

            if let idx = self.store.electricityRecords.firstIndex(where: { $0.dateString == today }) {
                var record = self.store.electricityRecords[idx]
                let prevSampledBal = record.balanceRMB
                let prevSampledKWh = record.remainingKWh

                // 计算今日消耗：若较上次采样发生充值（余额上升），保留充值前已累计消耗并平移今日起始基准
                if bal > prevSampledBal + 0.05 {
                    record.startOfDayBalanceRMB = bal + record.dailyCostRMB
                } else if bal <= record.startOfDayBalanceRMB {
                    record.dailyCostRMB = max(record.dailyCostRMB, record.startOfDayBalanceRMB - bal)
                } else {
                    record.startOfDayBalanceRMB = bal
                }
                record.balanceRMB = bal

                if let currentK = kwh {
                    if let prevK = prevSampledKWh, currentK > prevK + 0.05 {
                        record.startOfDayKWh = currentK + record.dailyUsedKWh
                    } else if let startK = record.startOfDayKWh {
                        if currentK <= startK {
                            record.dailyUsedKWh = max(record.dailyUsedKWh, startK - currentK)
                        } else {
                            record.startOfDayKWh = currentK
                        }
                    } else {
                        record.startOfDayKWh = currentK
                    }
                    record.remainingKWh = currentK
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

            if self.reconcileContinuity() {
                self.flowHistoryContinuityBackupRequired = true
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
        let recorded = queue.sync {
            store.flowRecords.first(where: { $0.dateString == today })?.dailyDeltaMB ?? 0.0
        }
        let onlineToday = CampusNetworkClient.shared.latestData.onlineDevices
            .filter { $0.loginTime.hasPrefix(today) }
            .reduce(0.0) { $0 + $1.usedFlowMB }
        return max(recorded, onlineToday)
    }

    /// 距离次日 00:00 单日限额重置倒计时文案
    public var dailyResetCountdownString: String {
        let cal = CourseCalendarHelper.beijingCalendar
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
        let cal = CourseCalendarHelper.beijingCalendar
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

    /// 当月最新记录的累计已用流量 (MB)，跨月自动失效避免上月流量误作本月流量
    public var currentMonthUsedFlowMB: Double? {
        let today = todayString()
        let monthPrefix = String(today.prefix(7))
        return queue.sync {
            guard let last = store.flowRecords
                .filter({ $0.dateString <= today && $0.dateString.hasPrefix(monthPrefix) })
                .max(by: { $0.dateString < $1.dateString }) else {
                return nil
            }
            return last.totalUsedMB
        }
    }

    /// 历史记录中最近一次校园网账户余额 (元)
    public var latestFlowBalanceRMB: Double? {
        let today = todayString()
        return queue.sync {
            store.flowRecords
                .filter { $0.dateString <= today }
                .sorted(by: { $0.dateString < $1.dateString })
                .last(where: { $0.balanceRMB != nil })?.balanceRMB
        }
    }

    /// 历史记录中最近一次宿舍电费记录
    public var latestElectricityRecord: DailyElectricityRecord? {
        let today = todayString()
        return queue.sync {
            store.electricityRecords
                .filter { $0.dateString <= today }
                .sorted(by: { $0.dateString < $1.dateString })
                .last
        }
    }

    /// 今日消耗电费 (元)
    public var todayElectricityCostRMB: Double {
        let today = todayString()
        return queue.sync {
            store.electricityRecords.first(where: { $0.dateString == today })?.dailyCostRMB ?? 0.0
        }
    }

    /// 今日消耗电量 (度)
    public var todayElectricityUsedKWh: Double {
        let today = todayString()
        return queue.sync {
            store.electricityRecords.first(where: { $0.dateString == today })?.dailyUsedKWh ?? 0.0
        }
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
        let latestBalance: Double? = ElectricityService.shared.latestData?.balanceRMB ?? latestElectricityRecord?.balanceRMB
        guard let latest = latestBalance, latest > 0 else {
            return nil
        }
        let dailyAvg = past7DaysElectricityDailyAverageCostRMB
        guard dailyAvg > 0.001 else { return nil }
        let days = Int(round(latest / dailyAvg))
        return max(1, days)
    }

    /// 获取近 N 天流量历史记录 (按自然日过滤并由旧到新排序)
    public func getPastDaysFlowRecords(days: Int) -> [DailyFlowRecord] {
        let dayCount = max(1, days)
        let today = todayString()
        let cutoff = addDays(-(dayCount - 1), to: today) ?? ""
        let sorted = queue.sync {
            store.flowRecords
                .filter { $0.dateString >= cutoff && $0.dateString <= today }
                .sorted { $0.dateString < $1.dateString }
        }
        if sorted.count <= dayCount {
            return sorted
        }
        return Array(sorted.suffix(dayCount))
    }

    /// 获取近 N 天电费历史记录 (按自然日过滤并由旧到新排序)
    public func getPastDaysElectricityRecords(days: Int) -> [DailyElectricityRecord] {
        let dayCount = max(1, days)
        let today = todayString()
        let cutoff = addDays(-(dayCount - 1), to: today) ?? ""
        let sorted = queue.sync {
            store.electricityRecords
                .filter { $0.dateString >= cutoff && $0.dateString <= today }
                .sorted { $0.dateString < $1.dateString }
        }
        if sorted.count <= dayCount {
            return sorted
        }
        return Array(sorted.suffix(dayCount))
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
