import Foundation
import AppKit
import Security

public class EmptyClassroomService: NSObject, URLSessionDelegate {
    public static let shared = EmptyClassroomService()

    private static let uniAppBaseURL = "https://jwglapp.hfut.edu.cn"
    private static let rsaPublicKeyBase64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCFY5N+9UX+0BF+xz1svFguI4CIDvmQTfINkOZ1HOO3ltBNHGQTUirUPQTyEph/+q/l8b16YYw3I2fyTH6y15s3tHf5jMei+R/20jFRGo5udwVJUwq/RozKQIRzCtPYkXG4YWBnHKhXalZ5K2fhd5i/QtB016nVugH/7eiBDWbKVwIDAQAB"
    private static let roomPageSize = 350
    private static let maximumRoomPages = 50

    public private(set) var allBuildings: [ClassroomBuilding] = []
    /// 内存缓存：key 为 "\(campus.rawValue)|\(dateString)|\(buildingIdsKey)"
    private var roomsCache: [String: [EmptyClassroomItem]] = [:]
    /// 单间教室全学期课表缓存：key 为 "\(roomId)|\(semesterId)"
    private var roomSemesterScheduleCache: [String: CourseScheduleData] = [:]
    /// 按校区 + 日期汇总的主力教学楼空教室缓存：key 为 "\(campus.rawValue)|\(dateString)"
    public private(set) var studyRoomsByDate: [String: [EmptyClassroomItem]] = [:]
    /// 校区级统计单独缓存，不混入主力自习楼列表缓存。
    public private(set) var campusDiningEstimateCache: [String: CampusDiningEstimate] = [:]

    public static var availableSemesters: [(id: Int, name: String)] {
        let currentSemId = CourseCalendarHelper.inferSemesterId()
        return (0..<5).map { idx in
            let semId = currentSemId - idx * 20
            let base = CourseCalendarHelper.formatSemesterName(for: semId)
            let name = (idx == 0) ? "\(base) (本学期)" : base
            return (semId, name)
        }
    }

    public static var nextUnscheduledSemesterTitle: String {
        let nextSemId = CourseCalendarHelper.inferSemesterId() + 20
        return "\(CourseCalendarHelper.formatSemesterName(for: nextSemId)) (下学期 · 教务暂未排课)"
    }

    public static func semesterTitle(for semesterId: Int) -> String {
        if let found = availableSemesters.first(where: { $0.id == semesterId }) {
            return found.name
        }
        return CourseCalendarHelper.formatSemesterName(for: semesterId)
    }
    public private(set) var lastSyncTime: Date?
    /// 各校区上次成功刷新时间：key 为 campus.rawValue
    public private(set) var lastSyncTimeByCampus: [Int: Date] = [:]
    public private(set) var isSyncing: Bool = false
    public private(set) var lastErrorMessage: String?
    private var pendingSyncCompletions: [Int: [(Result<Void, Error>) -> Void]] = [:]
    private var activeSyncTokenByCampus: [Int: UUID] = [:]
    private var lastRolloverDateString: String = EmptyClassroomService.todayDateString()

    private let tokenStateLock = NSLock()
    private var tokenGeneration = 0

    private var monitorTimer: Timer?
    private var isMonitoring = false
    private var isPausedForSleep = false
    private let fileManager = FileManager.default

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35.0
        config.timeoutIntervalForResource = 40.0
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var appSupportDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("cn.edu.hfut.campusnet.monitor", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var buildingsCacheURL: URL {
        appSupportDir.appendingPathComponent("classroom_buildings.json")
    }

    private var studyRoomsCacheURL: URL {
        appSupportDir.appendingPathComponent("study_rooms_cache.json")
    }

    private var syncMetaCacheURL: URL {
        appSupportDir.appendingPathComponent("study_rooms_sync_meta.json")
    }

    private override init() {
        super.init()
        loadLocalCache()
        checkStudyRoomDayRollover()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerConfigChange),
            name: .powerModeConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerSourceChange),
            name: .powerSourceDidChange,
            object: nil
        )
    }

    @objc private func handleSystemSleep() {
        guard SettingsManager.shared.shouldPauseOnScreenSleep, !isPausedForSleep else { return }
        isPausedForSleep = true
        stopMonitoring()
    }

    @objc private func handlePowerConfigChange() {
        if isPausedForSleep {
            guard !SettingsManager.shared.shouldPauseOnScreenSleep else { return }
            isPausedForSleep = false
            startMonitoring()
            return
        }
        guard isMonitoring else { return }
        scheduleMonitorTimer()
    }

    @objc private func handlePowerSourceChange() {
        guard isMonitoring else { return }
        scheduleMonitorTimer()
    }

    // MARK: - SSL Trust Delegate (仅兼容教务移动端证书)

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           protectionSpace.host.caseInsensitiveCompare("jwglapp.hfut.edu.cn") == .orderedSame,
           protectionSpace.port == 443,
           let trust = protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - 本地缓存读写

    private func loadLocalCache() {
        if fileManager.fileExists(atPath: buildingsCacheURL.path),
           let data = try? Data(contentsOf: buildingsCacheURL),
           let decoded = try? JSONDecoder().decode([ClassroomBuilding].self, from: data) {
            self.allBuildings = decoded
        }
        if fileManager.fileExists(atPath: studyRoomsCacheURL.path),
           let data = try? Data(contentsOf: studyRoomsCacheURL),
           let decoded = try? JSONDecoder().decode([String: [EmptyClassroomItem]].self, from: data) {
            let uniqueRoomsByDate = decoded.mapValues(Self.uniqueRooms)
            self.studyRoomsByDate = uniqueRoomsByDate
            for (key, rooms) in uniqueRoomsByDate {
                let parts = key.split(separator: "|")
                guard parts.count >= 2 else { continue }
                let campusPart = String(parts[0])
                let datePart = String(parts[1])
                let grouped = Dictionary(grouping: rooms, by: { $0.buildingId })
                for (bidOpt, bRooms) in grouped {
                    if let bid = bidOpt, !bRooms.isEmpty {
                        self.roomsCache["\(campusPart)|\(datePart)|\(bid)"] = bRooms
                    }
                }
            }
        }
        if fileManager.fileExists(atPath: syncMetaCacheURL.path),
           let data = try? Data(contentsOf: syncMetaCacheURL),
           let decoded = try? JSONDecoder().decode([Int: Date].self, from: data) {
            self.lastSyncTimeByCampus = decoded
            self.lastSyncTime = decoded.values.max()
        } else if fileManager.fileExists(atPath: studyRoomsCacheURL.path),
                  let attrs = try? fileManager.attributesOfItem(atPath: studyRoomsCacheURL.path),
                  let modDate = attrs[.modificationDate] as? Date {
            // 兼容已有缓存文件：用缓存文件的最后修改时间初始化对应校区的刷新时间
            for key in studyRoomsByDate.keys {
                let parts = key.split(separator: "|")
                if let first = parts.first, let rawCampus = Int(first) {
                    lastSyncTimeByCampus[rawCampus] = modDate
                }
            }
            self.lastSyncTime = modDate
        }
    }

    private static func uniqueRooms(_ rooms: [EmptyClassroomItem]) -> [EmptyClassroomItem] {
        var seenIds = Set<Int>()
        return rooms.filter { seenIds.insert($0.id).inserted }
    }

    private func saveBuildingsCache(_ buildings: [ClassroomBuilding]) {
        self.allBuildings = buildings
        if let data = try? JSONEncoder().encode(buildings) {
            try? data.write(to: buildingsCacheURL, options: .atomic)
        }
    }

    private func saveStudyRoomsCache() {
        // 仅保留今天、明天与近期缓存，避免无限增长
        let today = Self.todayDateString()
        let filtered = studyRoomsByDate.filter { key, _ in
            let parts = key.split(separator: "|")
            guard parts.count >= 2 else { return false }
            return String(parts[1]) >= today
        }
        self.studyRoomsByDate = filtered
        self.roomsCache = self.roomsCache.filter { key, _ in
            let parts = key.split(separator: "|")
            guard parts.count >= 2 else { return false }
            return String(parts[1]) >= today
        }
        if let data = try? JSONEncoder().encode(filtered) {
            try? data.write(to: studyRoomsCacheURL, options: .atomic)
        }
    }

    public func recordCampusSyncTime(_ campus: StudyCampus, date: Date = Date()) {
        lastSyncTime = date
        lastSyncTimeByCampus[campus.rawValue] = date
        if let data = try? JSONEncoder().encode(lastSyncTimeByCampus) {
            try? data.write(to: syncMetaCacheURL, options: .atomic)
        }
    }

    public func lastSyncDate(for campus: StudyCampus) -> Date? {
        if !lastSyncTimeByCampus.isEmpty {
            return lastSyncTimeByCampus[campus.rawValue]
        }
        return lastSyncTime
    }

    /// 供顶部筛选栏刷新按钮旁展示的简短上次刷新时间（如「上次刷新 19:12 (刚刚)」）
    public func formattedShortLastSync(for campus: StudyCampus) -> String {
        guard let date = lastSyncDate(for: campus) else {
            return "上次刷新：暂未同步"
        }
        let fmt = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            fmt.dateFormat = "HH:mm"
        } else {
            fmt.dateFormat = "MM-dd HH:mm"
        }
        let timeStr = fmt.string(from: date)
        let rel = Self.relativeTimeDescription(from: date)
        return "上次刷新 \(timeStr) (\(rel))"
    }

    /// 供底部状态栏与悬停提示展示的完整上次刷新时间（如「上次刷新：今天 19:12:08（2 分钟前）」）
    public func formattedFullLastSync(for campus: StudyCampus) -> String {
        guard let date = lastSyncDate(for: campus) else {
            return "上次刷新：暂未同步"
        }
        let fmt = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            fmt.dateFormat = "HH:mm:ss"
            let rel = Self.relativeTimeDescription(from: date)
            return "上次刷新：今天 \(fmt.string(from: date))（\(rel)）"
        } else {
            fmt.dateFormat = "MM-dd HH:mm:ss"
            let rel = Self.relativeTimeDescription(from: date)
            return "上次刷新：\(fmt.string(from: date))（\(rel)）"
        }
    }

    private static func relativeTimeDescription(from date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 {
            return "刚刚"
        }
        let mins = secs / 60
        if mins < 60 {
            return "\(mins)分钟前"
        }
        let hours = mins / 60
        if hours < 24 {
            return "\(hours)小时前"
        }
        let days = hours / 24
        return "\(days)天前"
    }

    // MARK: - 定时监测与每日自动推进

    public func startMonitoring() {
        isMonitoring = true
        scheduleMonitorTimer()
        checkStudyRoomDayRollover(triggerSyncIfNeeded: false)

        // 启动时自动拉取今日与明日的主力自习教学楼空教室数据
        let campus = currentPreferredCampus
        syncTodayAndTomorrowStudyRooms(campus: campus) { [weak self] _ in
            self?.evaluateAndNotifyIfNeeded()
        }

    }

    private func scheduleMonitorTimer() {
        monitorTimer?.invalidate()

        // 自习室检查周期：插电 60 秒，电池下按省电设置放宽，减少对能效核心的打扰
        let onBattery = SettingsManager.isOnBatteryPower()
        let interval = PowerSaver.studyRoomInterval(onBattery: onBattery)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkStudyRoomDayRollover(triggerSyncIfNeeded: true)
            self.evaluateAndNotifyIfNeeded()
        }
        t.tolerance = PowerSaver.tolerance(for: interval)
        monitorTimer = t
    }

    public func stopMonitoring() {
        isMonitoring = false
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    @objc private func handleSystemWake() {
        guard isPausedForSleep else { return }
        isPausedForSleep = false
        startMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isMonitoring, !self.isPausedForSleep else { return }
            self.checkStudyRoomDayRollover(triggerSyncIfNeeded: true)
            let campus = self.currentPreferredCampus
            let todayEmpty = self.cachedStudyRooms(campus: campus, dateString: Self.todayDateString()).isEmpty
            let tomorrowEmpty = self.cachedStudyRooms(campus: campus, dateString: Self.tomorrowDateString()).isEmpty
            if todayEmpty || tomorrowEmpty {
                self.syncTodayAndTomorrowStudyRooms(campus: campus) { [weak self] _ in
                    self?.evaluateAndNotifyIfNeeded()
                }
            } else {
                self.evaluateAndNotifyIfNeeded()
            }
        }
    }

    public var currentPreferredCampus: StudyCampus {
        if let record = SettingsManager.shared.currentStudyRoom,
           let c = StudyCampus(rawValue: record.campusAssoc) {
            return c
        }
        return StudyCampus.from(dormCampusString: SettingsManager.shared.dormCampus)
    }

    /// 检查跨天结转：若昨晚预订了「明日自习教室」，到了今天自动切换为「当前自习教室」；跨天时自动触发新一天的今明两天数据同步
    public func checkStudyRoomDayRollover(triggerSyncIfNeeded: Bool = false) {
        let todayStr = Self.todayDateString()
        let dayChanged = (lastRolloverDateString != todayStr)
        if dayChanged {
            lastRolloverDateString = todayStr
        }

        if let nextRoom = SettingsManager.shared.nextDayStudyRoom {
            if nextRoom.dateString == todayStr {
                SettingsManager.shared.currentStudyRoom = nextRoom
                SettingsManager.shared.nextDayStudyRoom = nil
                notifyUIUpdate()
            } else if nextRoom.dateString < todayStr {
                SettingsManager.shared.nextDayStudyRoom = nil
            }
        }
        if let curRoom = SettingsManager.shared.currentStudyRoom,
           curRoom.dateString < todayStr,
           currentStudyRoomItem(on: todayStr) != nil {
            // 跨天后若旧自习室仍存在于今日缓存，则自动续期日期以便继续监测或提醒
            var updated = curRoom
            updated.dateString = todayStr
            SettingsManager.shared.currentStudyRoom = updated
        }

        if dayChanged {
            saveStudyRoomsCache()
            notifyUIUpdate()
            if triggerSyncIfNeeded {
                let campus = currentPreferredCampus
                syncTodayAndTomorrowStudyRooms(campus: campus) { [weak self] _ in
                    self?.evaluateAndNotifyIfNeeded()
                }
            }
        }
    }

    // MARK: - 设定与切换当前自习空教室

    /// 根据教室所属 buildingId 从教学楼列表反推真实校区
    public func inferCampus(for room: EmptyClassroomItem, fallback: StudyCampus? = nil) -> StudyCampus {
        if let bid = room.buildingId,
           let matchedBuilding = allBuildings.first(where: { $0.id == bid }),
           let campus = StudyCampus(rawValue: matchedBuilding.campusAssoc) {
            return campus
        }
        return fallback ?? currentPreferredCampus
    }

    public func setCurrentStudyRoom(_ room: EmptyClassroomItem, campus: StudyCampus, roomDateString: String? = nil) {
        let todayStr = Self.todayDateString()
        let actualCampus = inferCampus(for: room, fallback: campus)
        let record = CurrentStudyRoomRecord(
            roomId: room.id,
            roomName: room.nameZh,
            buildingId: room.buildingId,
            campusAssoc: actualCampus.rawValue,
            dateString: todayStr
        )
        SettingsManager.shared.currentStudyRoom = record
        SettingsManager.shared.lastNotifiedStudyConflictId = nil

        let isFromToday = (roomDateString == nil || roomDateString == todayStr)
        if isFromToday {
            let cacheKey = "\(actualCampus.rawValue)|\(todayStr)"
            // 仅当该校区今日主力教学楼缓存已非空且 room 来自今日数据时追加，防止把其他日期的排课混入今日缓存
            if var list = studyRoomsByDate[cacheKey], !list.isEmpty {
                if !list.contains(where: { $0.id == room.id }) {
                    list.append(room)
                    studyRoomsByDate[cacheKey] = list
                    saveStudyRoomsCache()
                }
            }
            if let bid = room.buildingId {
                let bKey = "\(actualCampus.rawValue)|\(todayStr)|\(bid)"
                var bList = roomsCache[bKey] ?? []
                if !bList.contains(where: { $0.id == room.id }) {
                    bList.append(room)
                    roomsCache[bKey] = bList
                }
            }
        } else if currentStudyRoomItem(on: todayStr) == nil, let bid = room.buildingId {
            // 若用户在查看其他日期时点击了「设为自习」，后台补充拉取该教学楼今日的真实排课数据
            fetchRooms(dateString: todayStr, campus: actualCampus, buildingIds: [bid], forceRefresh: false) { [weak self] _ in
                self?.notifyUIUpdate()
                self?.evaluateAndNotifyIfNeeded(forceConflictCheck: true)
            }
        }

        notifyUIUpdate()
        evaluateAndNotifyIfNeeded(forceConflictCheck: true)
    }

    public func clearCurrentStudyRoom() {
        SettingsManager.shared.currentStudyRoom = nil
        SettingsManager.shared.lastNotifiedStudyConflictId = nil
        notifyUIUpdate()
    }

    public func setNextDayStudyRoom(_ room: EmptyClassroomItem, campus: StudyCampus) {
        let tomorrowStr = Self.tomorrowDateString()
        let actualCampus = inferCampus(for: room, fallback: campus)
        let record = CurrentStudyRoomRecord(
            roomId: room.id,
            roomName: room.nameZh,
            buildingId: room.buildingId,
            campusAssoc: actualCampus.rawValue,
            dateString: tomorrowStr
        )
        SettingsManager.shared.nextDayStudyRoom = record

        let cacheKey = "\(actualCampus.rawValue)|\(tomorrowStr)"
        if var list = studyRoomsByDate[cacheKey], !list.isEmpty {
            if !list.contains(where: { $0.id == room.id }) {
                list.append(room)
                studyRoomsByDate[cacheKey] = list
                saveStudyRoomsCache()
            }
        }
        if let bid = room.buildingId {
            let bKey = "\(actualCampus.rawValue)|\(tomorrowStr)|\(bid)"
            var bList = roomsCache[bKey] ?? []
            if !bList.contains(where: { $0.id == room.id }) {
                bList.append(room)
                roomsCache[bKey] = bList
            }
        }

        notifyUIUpdate()
    }

    public func clearNextDayStudyRoom() {
        SettingsManager.shared.nextDayStudyRoom = nil
        notifyUIUpdate()
    }

    private func notifyUIUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .emptyClassroomDidUpdate, object: nil)
        }
    }

    // MARK: - 智能推荐算法（全天空闲推荐 / 上课附近换座推荐 / 晚间明日搬书推荐）

    /// 获取指定日期与校区缓存的自习室列表
    public func cachedStudyRooms(campus: StudyCampus? = nil, dateString: String? = nil) -> [EmptyClassroomItem] {
        let c = campus ?? currentPreferredCampus
        let d = dateString ?? Self.todayDateString()
        return studyRoomsByDate["\(c.rawValue)|\(d)"] ?? []
    }

    /// 获取单栋教学楼的内存缓存（若已拉取过该教学楼，即使该楼返回 0 间教室也返回非 nil 数组）
    public func cachedBuildingRooms(campus: StudyCampus, dateString: String, buildingId: Int) -> [EmptyClassroomItem]? {
        return roomsCache["\(campus.rawValue)|\(dateString)|\(buildingId)"]
    }

    /// 判断指定查询条件是否已有内存缓存
    public func hasCachedRooms(dateString: String, campus: StudyCampus, buildingIds: [Int]?) -> Bool {
        let sortedIds = (buildingIds ?? []).sorted()
        let cacheKey = "\(campus.rawValue)|\(dateString)|\(sortedIds.map(String.init).joined(separator: ","))"
        if roomsCache[cacheKey] != nil {
            return true
        }
        return false
    }

    /// 查找当前自习室对应的最新详情对象（同时检索主力教学楼缓存与单栋教学楼缓存）
    public func currentStudyRoomItem(on dateString: String? = nil) -> EmptyClassroomItem? {
        guard let record = SettingsManager.shared.currentStudyRoom else { return nil }
        let targetDate = dateString ?? Self.todayDateString()
        let campus = StudyCampus(rawValue: record.campusAssoc) ?? currentPreferredCampus
        let rooms = cachedStudyRooms(campus: campus, dateString: targetDate)
        if let matchById = rooms.first(where: { $0.id == record.roomId }) {
            return matchById
        }
        if let matchByName = rooms.first(where: { $0.nameZh == record.roomName }) {
            return matchByName
        }
        let prefix = "\(campus.rawValue)|\(targetDate)|"
        for (key, cachedList) in roomsCache where key.hasPrefix(prefix) {
            if let match = cachedList.first(where: { $0.id == record.roomId || $0.nameZh == record.roomName }) {
                return match
            }
        }
        return nil
    }

    /// 【功能 1】当天刚打开时推荐一批全天空闲的教室（优先主力教学楼低楼层，一坐一整天不用搬）
    public func recommendedTodayAllDayFreeRooms(campus: StudyCampus? = nil, limit: Int = 12) -> [EmptyClassroomItem] {
        let c = campus ?? currentPreferredCampus
        let todayStr = Self.todayDateString()
        let rooms = cachedStudyRooms(campus: c, dateString: todayStr)
        let nowMin = Self.currentMinutesOfDay()

        // 优先筛选全天完全无课 (08:00-22:00) 的教室
        let allDayFree = rooms.filter { $0.isAllDayFree }
        let sortedAllDay = sortRoomsForSelfStudy(allDayFree, campus: c)

        if sortedAllDay.count >= limit {
            return Array(sortedAllDay.prefix(limit))
        }

        // 若全天无课教室不足，补充「当前至 22:00 余下全空」的教室
        let restOfDayFree = rooms.filter { !$0.isAllDayFree && $0.isRestOfDayFree(atMinutes: nowMin) }
        let combined = sortedAllDay + sortRoomsForSelfStudy(restOfDayFree, campus: c)
        return Array(combined.prefix(limit))
    }

    /// 【功能 2】当当前自习教室有课程/占用时，推荐附近的空教室进行切换（同楼层隔壁优先 + 余下全空优先）
    public func nearbySwitchRecommendations(
        for sourceRoom: EmptyClassroomItem? = nil,
        campus: StudyCampus? = nil,
        limit: Int = 6
    ) -> (conflictOccupation: ClassroomOccupation?, isCurrentlyOccupied: Bool, minutesUntilConflict: Int?, recommendations: [RecommendedSwitchRoom]) {
        guard let currentRoom = sourceRoom ?? currentStudyRoomItem() else {
            return (nil, false, nil, [])
        }
        let c = campus ?? currentPreferredCampus
        let todayStr = Self.todayDateString()
        let nowMin = Self.currentMinutesOfDay()

        let ongoing = currentRoom.currentOccupation(atMinutes: nowMin)
        let upcoming = currentRoom.nextOccupation(afterMinutes: nowMin)
        guard let conflict = ongoing ?? upcoming else {
            // 当前教室今日余下时间全空，无需换座
            return (nil, false, nil, [])
        }

        let isOngoing = (ongoing != nil)
        let minsUntil = isOngoing ? 0 : max(0, conflict.startMinutes - nowMin)

        // 需要保证目标教室在 [min(nowMin, conflict.startMinutes), conflict.endMinutes] 内完全空闲且当前也空闲
        let requiredFreeStart = min(nowMin, conflict.startMinutes)
        let requiredFreeEnd = max(conflict.endMinutes, requiredFreeStart + 45)

        let allRooms = cachedStudyRooms(campus: c, dateString: todayStr)
        var candidates: [RecommendedSwitchRoom] = []

        for candidate in allRooms where candidate.id != currentRoom.id {
            // 候选教室当前不能正在上课，且在整个冲突时间段内必须空闲
            guard candidate.currentOccupation(atMinutes: nowMin) == nil,
                  candidate.isFree(from: requiredFreeStart, to: requiredFreeEnd) else {
                continue
            }
            let prox = candidate.proximity(to: currentRoom)
            let restFree = candidate.isRestOfDayFree(atMinutes: requiredFreeStart)
            let freeUntilText: String
            if candidate.isAllDayFree {
                freeUntilText = "全天空闲 (至22:00)"
            } else if restFree {
                freeUntilText = "今日余下全空 (至22:00)"
            } else if let nextOcc = candidate.nextOccupation(afterMinutes: requiredFreeStart) {
                freeUntilText = "可自习至 \(nextOcc.startTimeString)"
            } else {
                freeUntilText = "今日余下全空"
            }

            candidates.append(
                RecommendedSwitchRoom(
                    room: candidate,
                    proximity: prox,
                    isRestOfDayFree: restFree,
                    freeUntilText: freeUntilText
                )
            )
        }

        // 排序规则：
        // 1. 同教学楼同楼层且余下全空 最优先
        // 2. 物理距离层级 (tier: 同楼层 0 -> 同楼相邻层 1 -> 邻楼 2)
        // 3. 是否今日余下全空 (避免换一次又要换第二次)
        // 4. 房间间隔距离 sortScore
        candidates.sort { a, b in
            if a.proximity.tier != b.proximity.tier {
                return a.proximity.tier < b.proximity.tier
            }
            if a.isRestOfDayFree != b.isRestOfDayFree {
                return a.isRestOfDayFree && !b.isRestOfDayFree
            }
            return a.proximity.sortScore < b.proximity.sortScore
        }

        return (conflict, isOngoing, minsUntil, Array(candidates.prefix(limit)))
    }

    /// 【功能 3】晚上要走之前推荐第二天空闲的教室方便搬东西过去
    public func buildTomorrowRecommendation(campus: StudyCampus? = nil, limit: Int = 8) -> TomorrowStudyRecommendation {
        let c = campus ?? currentPreferredCampus
        let todayStr = Self.todayDateString()
        let tomorrowStr = Self.tomorrowDateString()
        let nowMin = Self.currentMinutesOfDay()

        let todayRooms = cachedStudyRooms(campus: c, dateString: todayStr)
        let tomorrowRooms = cachedStudyRooms(campus: c, dateString: tomorrowStr)
        var todayRoomMap: [Int: EmptyClassroomItem] = [:]
        for room in todayRooms {
            todayRoomMap[room.id] = room
        }

        let rawRecord = SettingsManager.shared.currentStudyRoom
        let isSameCampus = (rawRecord?.campusAssoc == c.rawValue)
        let curRecord = isSameCampus ? rawRecord : nil
        let curTodayItem = isSameCampus ? currentStudyRoomItem(on: todayStr) : nil
        let curTomorrowItem = isSameCampus ? currentStudyRoomItem(on: tomorrowStr) : nil

        // 判断明天当前自习室是否全天空闲
        let isCurrentFreeTomorrow = curTomorrowItem?.isAllDayFree ?? false
        let currentFirstOccTomorrow = curTomorrowItem?.sortedOccupations.first

        // 筛选明天全天空闲的教室，并结合今晚当前是否空闲、距离当前自习室远近排序
        var candidates: [TomorrowCandidateRoom] = []
        for rm in tomorrowRooms where rm.isAllDayFree {
            if let cur = curTomorrowItem, rm.id == cur.id {
                continue
            }
            let todayCounterpart = todayRoomMap[rm.id]
            let tonightFree = (todayCounterpart?.currentOccupation(atMinutes: nowMin) == nil)
            let prox = curTodayItem.map { rm.proximity(to: $0) }

            let badge: String
            if let p = prox {
                badge = tonightFree ? "\(p.badgeText) · 今晚空闲可搬" : "\(p.badgeText) · 明日全空"
            } else {
                badge = tonightFree ? "\(rm.inferredFloor)F · 今晚空闲 · 明日全空" : "\(rm.inferredFloor)F · 明日全天空闲"
            }

            candidates.append(
                TomorrowCandidateRoom(
                    room: rm,
                    isTonightCurrentlyFree: tonightFree,
                    proximityToCurrent: prox,
                    badgeText: badge
                )
            )
        }

        candidates.sort { a, b in
            // 优先今晚此刻空闲（方便现在直接把书搬过去不打扰别人上课）
            if a.isTonightCurrentlyFree != b.isTonightCurrentlyFree {
                return a.isTonightCurrentlyFree && !b.isTonightCurrentlyFree
            }
            // 若设定了当前自习室，优先同楼层隔壁
            if let pa = a.proximityToCurrent, let pb = b.proximityToCurrent {
                if pa.tier != pb.tier { return pa.tier < pb.tier }
                if pa.sortScore != pb.sortScore { return pa.sortScore < pb.sortScore }
            }
            // 否则按低楼层与房间号排序
            if a.room.inferredFloor != b.room.inferredFloor {
                return a.room.inferredFloor < b.room.inferredFloor
            }
            return a.room.inferredRoomNumber < b.room.inferredRoomNumber
        }

        let topCandidates = Array(candidates.prefix(limit))

        let headline: String
        let subheadline: String

        if let cur = curTomorrowItem {
            if isCurrentFreeTomorrow {
                headline = "🎉 当前自习室「\(cur.nameZh)」明天全天无课！东西不用搬！"
                subheadline = "明日 (08:00 - 22:00) 没有任何排课或占用，今晚离开前可将书本直接留在原位，或参考下方同楼层明日全空教室。"
            } else if let firstOcc = currentFirstOccTomorrow {
                let occCount = cur.sortedOccupations.count
                let topNames = topCandidates.prefix(3).map { $0.room.nameZh }.joined(separator: "、")
                headline = "📦 当前「\(cur.nameZh)」明天 \(firstOcc.startTimeString) 有课（共\(occCount)节），走前建议搬书！"
                subheadline = topNames.isEmpty
                    ? "明天最早 \(firstOcc.startTimeString) 将有《\(firstOcc.shortCourseName)》，建议今晚走前切换至明日全空教室。"
                    : "为您精选最近的【明日全天空闲 + 今晚可随时搬入】教室：\(topNames)"
            } else {
                headline = "🌙 明日 (\(tomorrowStr)) 全天空闲教室搬书推荐"
                subheadline = "晚上离开前可挑选一间明日全天无课的教室提前放书占座"
            }
        } else {
            let topNames = topCandidates.prefix(4).map { $0.room.nameZh }.joined(separator: "、")
            headline = "🌙 明日 (\(tomorrowStr)) 全天空闲教室推荐 · 方便今晚提前搬书"
            subheadline = topNames.isEmpty
                ? "正在同步明日空教室排课数据..."
                : "明日全天无课且今晚当前空闲首选：\(topNames)"
        }

        return TomorrowStudyRecommendation(
            tomorrowDateString: tomorrowStr,
            currentStudyRoomName: curTomorrowItem?.nameZh ?? curRecord?.roomName,
            isCurrentRoomAllDayFreeTomorrow: isCurrentFreeTomorrow,
            currentRoomTomorrowFirstOccupation: currentFirstOccTomorrow,
            headline: headline,
            subheadline: subheadline,
            candidates: topCandidates
        )
    }

    private func sortRoomsForSelfStudy(_ rooms: [EmptyClassroomItem], campus: StudyCampus) -> [EmptyClassroomItem] {
        return rooms.sorted { a, b in
            let idxA = campus.buildingSortRank(for: a.buildingPrefix)
            let idxB = campus.buildingSortRank(for: b.buildingPrefix)
            if idxA != idxB {
                return idxA < idxB
            }
            if a.inferredFloor != b.inferredFloor {
                return a.inferredFloor < b.inferredFloor
            }
            return a.inferredRoomNumber < b.inferredRoomNumber
        }
    }

    // MARK: - 智能通知提醒触发（早间全空推荐 / 课前附近换座提醒 / 晚间明日搬书提醒）

    public func evaluateAndNotifyIfNeeded(forceConflictCheck: Bool = false) {
        let todayStr = Self.todayDateString()
        let nowMin = Self.currentMinutesOfDay()

        // 1. 当天刚打开时（且尚未设置今日自习室）：每天首次同步成功后推送一次「今日全天空闲教室推荐」
        if SettingsManager.shared.lastNotifiedStudyMorningDate != todayStr {
            let todayAllFree = recommendedTodayAllDayFreeRooms(limit: 5)
            if !todayAllFree.isEmpty {
                SettingsManager.shared.lastNotifiedStudyMorningDate = todayStr
                if SettingsManager.shared.currentStudyRoom == nil {
                    let names = todayAllFree.prefix(4).map { $0.nameZh }.joined(separator: "、")
                    NotificationHelper.showNotification(
                        title: "☀️ 今日自习全天空闲教室推荐",
                        subtitle: "一坐一整天无需换座（共 \(todayAllFree.count)+ 间全空）",
                        body: "推荐前往：\(names)。可在状态栏「🏫 自习空教室」中一键设为当前自习室！"
                    )
                }
            }
        }

        // 2. 当前自习教室即将上课（提前 25 分钟内）或正在上课时，自动推送附近空教室切换提醒
        if let currentRoom = currentStudyRoomItem(on: todayStr) {
            let (conflict, isOngoing, minsUntil, recs) = nearbySwitchRecommendations(for: currentRoom, limit: 3)
            if let occ = conflict, let mins = minsUntil, (isOngoing || mins <= 25 || forceConflictCheck) {
                if isOngoing || mins <= 30 {
                    let conflictKey = "\(todayStr)-\(currentRoom.id)-\(occ.startTimeString)"
                    if SettingsManager.shared.lastNotifiedStudyConflictId != conflictKey {
                        SettingsManager.shared.lastNotifiedStudyConflictId = conflictKey
                        let recText = recs.isEmpty
                            ? "请打开空教室窗口查看附近空闲教室"
                            : recs.map { "\($0.room.nameZh)(\($0.proximity.badgeText))" }.joined(separator: "、")
                        let statusDesc = isOngoing
                            ? "当前正在上《\(occ.shortCourseName)》(\(occ.startTimeString)-\(occ.endTimeString))"
                            : "\(mins)分钟后 (\(occ.startTimeString)) 将有《\(occ.shortCourseName)》"
                        NotificationHelper.showNotification(
                            title: "⚠️ 自习室换座提醒 · \(currentRoom.nameZh)",
                            subtitle: statusDesc,
                            body: "推荐就近切换至：\(recText)"
                        )
                    }
                }
            }
        }

        // 3. 晚上 18:30 之后（离开教学楼前）：每天推送一次「第二天空闲教室搬书/留座指南」
        if nowMin >= 18 * 60 + 30 && SettingsManager.shared.lastNotifiedStudyEveningDate != todayStr {
            let tomorrowRooms = cachedStudyRooms(dateString: Self.tomorrowDateString())
            if !tomorrowRooms.isEmpty {
                SettingsManager.shared.lastNotifiedStudyEveningDate = todayStr
                let tomorrowRec = buildTomorrowRecommendation(limit: 4)
                if tomorrowRec.isCurrentRoomAllDayFreeTomorrow, let curName = tomorrowRec.currentStudyRoomName {
                    NotificationHelper.showNotification(
                        title: "🌙 明日自习留座好消息 · \(curName)",
                        subtitle: "当前自习室明天全天无课，东西不用搬！",
                        body: "明天 08:00-22:00 全天无排课，书本可直接留原位。"
                    )
                } else if !tomorrowRec.candidates.isEmpty {
                    let names = tomorrowRec.candidates.prefix(3).map { "\($0.room.nameZh)(\($0.badgeText))" }.joined(separator: "、")
                    NotificationHelper.showNotification(
                        title: "🌙 晚上走前 · 明日空教室搬书推荐",
                        subtitle: tomorrowRec.headline,
                        body: "推荐搬至：\(names)"
                    )
                }
            }
        }
    }

    // MARK: - 网络同步（自动登录合工大教务移动端接口 + 同步今日与明日自习教室）

    /// 一键同步指定校区「今天」和「明天」的主力教学楼空教室数据
    public func syncTodayAndTomorrowStudyRooms(
        campus: StudyCampus? = nil,
        additionalBuildingIds: [Int] = [],
        forceRefresh: Bool = false,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let targetCampus = campus ?? currentPreferredCampus
        let todayStr = Self.todayDateString()
        let tomorrowStr = Self.tomorrowDateString()

        let extraIdsCached = additionalBuildingIds.allSatisfy { bid in
            roomsCache["\(targetCampus.rawValue)|\(todayStr)|\(bid)"] != nil &&
            roomsCache["\(targetCampus.rawValue)|\(tomorrowStr)|\(bid)"] != nil
        }

        if !forceRefresh,
           extraIdsCached,
           let todayCached = studyRoomsByDate["\(targetCampus.rawValue)|\(todayStr)"], !todayCached.isEmpty,
           let tomorrowCached = studyRoomsByDate["\(targetCampus.rawValue)|\(tomorrowStr)"], !tomorrowCached.isEmpty {
            completion(.success(()))
            return
        }

        let campusKey = targetCampus.rawValue
        let completeAfterRequestedBuildings: (Result<Void, Error>) -> Void = { [weak self] result in
            guard case .success = result, !additionalBuildingIds.isEmpty else {
                completion(result)
                return
            }
            guard let self else {
                completion(result)
                return
            }
            self.ensureAdditionalBuildingCaches(
                campus: targetCampus,
                buildingIds: additionalBuildingIds,
                completion: completion
            )
        }

        if !forceRefresh, pendingSyncCompletions[campusKey] != nil {
            pendingSyncCompletions[campusKey]?.append(completeAfterRequestedBuildings)
            return
        }
        pendingSyncCompletions[campusKey, default: []].append(completeAfterRequestedBuildings)
        let syncToken = UUID()
        activeSyncTokenByCampus[campusKey] = syncToken

        isSyncing = true
        lastErrorMessage = nil
        notifyUIUpdate()

        let finishSync: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self = self else { return }
            // 若在非强制同步进行期间用户又发起了新的 forceRefresh，忽略旧同步的收尾以免提前消费回调
            guard self.activeSyncTokenByCampus[campusKey] == syncToken else { return }
            self.activeSyncTokenByCampus.removeValue(forKey: campusKey)
            let callbacks = self.pendingSyncCompletions.removeValue(forKey: campusKey) ?? [completion]
            self.isSyncing = !self.pendingSyncCompletions.isEmpty
            self.notifyUIUpdate()
            for cb in callbacks {
                cb(result)
            }
        }

        fetchBuildings(forceRefresh: forceRefresh) { [weak self] bResult in
            guard let self = self else { return }
            guard self.activeSyncTokenByCampus[campusKey] == syncToken else { return }
            switch bResult {
            case .failure(let err):
                self.lastErrorMessage = err.localizedDescription
                finishSync(.failure(err))

            case .success(let buildings):
                let campusBuildings = buildings.filter { $0.campusAssoc == targetCampus.rawValue }
                let preferredIds = campusBuildings.filter { $0.isPreferredStudyBuilding }.map { $0.id }
                var targetBuildingIds = preferredIds.isEmpty ? campusBuildings.map { $0.id } : preferredIds
                if let curRec = SettingsManager.shared.currentStudyRoom,
                   curRec.campusAssoc == targetCampus.rawValue,
                   let bid = curRec.buildingId,
                   !targetBuildingIds.contains(bid) {
                    targetBuildingIds.append(bid)
                }
                if let nextRec = SettingsManager.shared.nextDayStudyRoom,
                   nextRec.campusAssoc == targetCampus.rawValue,
                   let bid = nextRec.buildingId,
                   !targetBuildingIds.contains(bid) {
                    targetBuildingIds.append(bid)
                }
                for bid in additionalBuildingIds where !targetBuildingIds.contains(bid) {
                    targetBuildingIds.append(bid)
                }

                let group = DispatchGroup()
                var firstError: Error?
                var todaySucceeded = false
                var tomorrowSucceeded = false

                group.enter()
                self.fetchRooms(
                    dateString: todayStr,
                    campus: targetCampus,
                    buildingIds: targetBuildingIds,
                    forceRefresh: forceRefresh,
                    syncToken: syncToken
                ) { res in
                    guard self.activeSyncTokenByCampus[campusKey] == syncToken else {
                        group.leave()
                        return
                    }
                    if case .success(let rooms) = res {
                        self.studyRoomsByDate["\(targetCampus.rawValue)|\(todayStr)"] = rooms
                        todaySucceeded = true
                    } else if case .failure(let e) = res {
                        firstError = e
                    }
                    group.leave()
                }

                group.enter()
                self.fetchRooms(
                    dateString: tomorrowStr,
                    campus: targetCampus,
                    buildingIds: targetBuildingIds,
                    forceRefresh: forceRefresh,
                    syncToken: syncToken
                ) { res in
                    guard self.activeSyncTokenByCampus[campusKey] == syncToken else {
                        group.leave()
                        return
                    }
                    if case .success(let rooms) = res {
                        self.studyRoomsByDate["\(targetCampus.rawValue)|\(tomorrowStr)"] = rooms
                        tomorrowSucceeded = true
                    } else if case .failure(let e) = res, firstError == nil {
                        firstError = e
                    }
                    group.leave()
                }

                group.notify(queue: .main) {
                    guard self.activeSyncTokenByCampus[campusKey] == syncToken else { return }
                    if let err = firstError, (!todaySucceeded && !tomorrowSucceeded) || (forceRefresh && !todaySucceeded) {
                        self.lastErrorMessage = err.localizedDescription
                        finishSync(.failure(err))
                    } else {
                        self.recordCampusSyncTime(targetCampus)
                        self.lastErrorMessage = nil
                        self.saveStudyRoomsCache()
                        self.evaluateAndNotifyIfNeeded()
                        finishSync(.success(()))
                    }
                }
            }
        }
    }

    // MARK: - 获取全部教学楼列表

    public func fetchBuildings(
        forceRefresh: Bool = false,
        completion: @escaping (Result<[ClassroomBuilding], Error>) -> Void
    ) {
        if !forceRefresh, !allBuildings.isEmpty {
            completion(.success(allBuildings))
            return
        }

        ensureValidToken(forceRelogin: false) { [weak self] tokenResult in
            guard let self = self else { return }
            switch tokenResult {
            case .failure(let err):
                completion(.failure(err))
            case .success(let token):
                self.requestBuildingsWithToken(token, allowRetry: true, completion: completion)
            }
        }
    }

    public func fetchCampusDiningEstimate(
        campus: StudyCampus,
        dateString: String,
        forceRefresh: Bool = false,
        completion: @escaping (Result<CampusDiningEstimate, Error>) -> Void
    ) {
        let cacheKey = "\(campus.rawValue)|\(dateString)"
        if !forceRefresh, let cached = campusDiningEstimateCache[cacheKey] {
            completion(.success(cached))
            return
        }

        fetchBuildings(forceRefresh: forceRefresh) { [weak self] buildingResult in
            guard let self else { return }
            switch buildingResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let buildings):
                let buildingIds = buildings.filter { $0.campusAssoc == campus.rawValue }.map(\.id).sorted()
                guard !buildingIds.isEmpty else {
                    completion(.failure(NSError(domain: "EmptyClassroom", code: -2, userInfo: [NSLocalizedDescriptionKey: "没有可用于统计的教学楼数据"])))
                    return
                }
                self.fetchCampusDiningPages(
                    campus: campus,
                    dateString: dateString,
                    buildingIds: buildingIds,
                    cacheKey: cacheKey,
                    page: 1,
                    seenRoomIds: [],
                    rooms: [],
                    completion: completion
                )
            }
        }
    }

    private func fetchCampusDiningPages(
        campus: StudyCampus,
        dateString: String,
        buildingIds: [Int],
        cacheKey: String,
        page: Int,
        seenRoomIds: Set<Int>,
        rooms: [EmptyClassroomItem],
        completion: @escaping (Result<CampusDiningEstimate, Error>) -> Void
    ) {
        let cacheKeyForRequest = "\(cacheKey)|campus-dining"
        ensureValidToken(forceRelogin: false) { [weak self] tokenResult in
            guard let self else { return }
            switch tokenResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                self.requestRoomsWithToken(
                    token: token,
                    dateString: dateString,
                    campus: campus,
                    buildingIds: buildingIds,
                    cacheKey: cacheKeyForRequest,
                    allowRetry: true,
                    currentPage: page,
                    cacheResult: false
                ) { pageResult in
                    switch pageResult {
                    case .failure:
                        let estimate = CampusDiningEstimate.calculate(campus: campus, dateString: dateString, rooms: rooms, isComplete: false)
                        completion(.success(estimate))
                    case .success(let pageRooms):
                        var accumulated = rooms
                        var knownIds = seenRoomIds
                        let freshRooms = pageRooms.filter { knownIds.insert($0.id).inserted }
                        accumulated.append(contentsOf: freshRooms)

                        guard pageRooms.count == Self.roomPageSize else {
                            let sortedRooms = accumulated.sorted { a, b in
                                if a.buildingPrefix != b.buildingPrefix {
                                    return campus.compareBuildingNames(a.buildingPrefix, b.buildingPrefix)
                                }
                                if a.inferredFloor != b.inferredFloor {
                                    return a.inferredFloor < b.inferredFloor
                                }
                                return a.inferredRoomNumber < b.inferredRoomNumber
                            }
                            let estimate = CampusDiningEstimate.calculate(campus: campus, dateString: dateString, rooms: sortedRooms, isComplete: true)
                            self.campusDiningEstimateCache[cacheKey] = estimate
                            completion(.success(estimate))
                            return
                        }

                        guard !freshRooms.isEmpty, page < Self.maximumRoomPages else {
                            let estimate = CampusDiningEstimate.calculate(campus: campus, dateString: dateString, rooms: accumulated, isComplete: false)
                            completion(.success(estimate))
                            return
                        }

                        self.fetchCampusDiningPages(
                            campus: campus,
                            dateString: dateString,
                            buildingIds: buildingIds,
                            cacheKey: cacheKey,
                            page: page + 1,
                            seenRoomIds: knownIds,
                            rooms: accumulated,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    private func requestBuildingsWithToken(
        _ token: String,
        allowRetry: Bool,
        completion: @escaping (Result<[ClassroomBuilding], Error>) -> Void
    ) {
        guard let url = URL(string: "\(Self.uniAppBaseURL)/eams-micro-server/api/v1/room/place/building?campusAssoc=") else {
            completion(.failure(NSError(domain: "EmptyClassroom", code: -1, userInfo: [NSLocalizedDescriptionKey: "教学楼请求地址无效"])))
            return
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30.0)
        req.httpMethod = "GET"
        req.setValue(token, forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }

            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0

            struct BuildingResponseRoot: Decodable {
                let data: [ClassroomBuilding]?
            }

            if statusCode == 200,
               let data = data,
               let root = try? JSONDecoder().decode(BuildingResponseRoot.self, from: data),
               let list = root.data, !list.isEmpty {
                let validCampuses = Set(StudyCampus.allCases.map { $0.rawValue })
                let filtered = list.filter { validCampuses.contains($0.campusAssoc) }
                self.saveBuildingsCache(filtered)
                completion(.success(filtered))
                return
            }

            // Token 失效或返回 401/500，自动重新登录一次
            if allowRetry {
                self.ensureValidToken(forceRelogin: true) { retryTokenRes in
                    switch retryTokenRes {
                    case .success(let newToken):
                        self.requestBuildingsWithToken(newToken, allowRetry: false, completion: completion)
                    case .failure(let err):
                        completion(.failure(err))
                    }
                }
            } else {
                completion(.failure(NSError(domain: "EmptyClassroom", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "拉取教学楼列表失败 (HTTP \(statusCode))"])))
            }
        }.resume()
    }

    // MARK: - 获取指定条件下的空教室与占用时间轴列表

    public func fetchRooms(
        dateString: String,
        campus: StudyCampus,
        buildingIds: [Int]?,
        forceRefresh: Bool = false,
        completion: @escaping (Result<[EmptyClassroomItem], Error>) -> Void
    ) {
        fetchRooms(
            dateString: dateString,
            campus: campus,
            buildingIds: buildingIds,
            forceRefresh: forceRefresh,
            syncToken: nil,
            completion: completion
        )
    }

    private func ensureAdditionalBuildingCaches(
        campus: StudyCampus,
        buildingIds: [Int],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let today = Self.todayDateString()
        let tomorrow = Self.tomorrowDateString()
        let required = Set(buildingIds).flatMap { buildingId in
            [today, tomorrow].compactMap { date in
                let key = "\(campus.rawValue)|\(date)|\(buildingId)"
                return roomsCache[key] == nil ? (date, buildingId) : nil
            }
        }
        guard !required.isEmpty else {
            completion(.success(()))
            return
        }

        let group = DispatchGroup()
        let errorLock = NSLock()
        var firstError: Error?
        for (date, buildingId) in required {
            group.enter()
            fetchRooms(dateString: date, campus: campus, buildingIds: [buildingId]) { result in
                if case .failure(let error) = result {
                    errorLock.lock()
                    if firstError == nil { firstError = error }
                    errorLock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            errorLock.lock()
            let fetchError = firstError
            errorLock.unlock()
            if let fetchError {
                completion(.failure(fetchError))
                return
            }

            let allCached = Set(buildingIds).allSatisfy { buildingId in
                self.roomsCache["\(campus.rawValue)|\(today)|\(buildingId)"] != nil &&
                self.roomsCache["\(campus.rawValue)|\(tomorrow)|\(buildingId)"] != nil
            }
            if allCached {
                completion(.success(()))
            } else {
                completion(.failure(NSError(
                    domain: "EmptyClassroom",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "部分指定教学楼的空教室数据未能加载"]
                )))
            }
        }
    }

    private func fetchRooms(
        dateString: String,
        campus: StudyCampus,
        buildingIds: [Int]?,
        forceRefresh: Bool,
        syncToken: UUID?,
        completion: @escaping (Result<[EmptyClassroomItem], Error>) -> Void
    ) {
        let sortedIds = (buildingIds ?? []).sorted()
        let cacheKey = "\(campus.rawValue)|\(dateString)|\(sortedIds.map(String.init).joined(separator: ","))"
        if !forceRefresh, let cached = roomsCache[cacheKey] {
            completion(.success(cached))
            return
        }

        ensureValidToken(forceRelogin: false) { [weak self] tokenResult in
            guard let self = self else { return }
            if let syncToken, self.activeSyncTokenByCampus[campus.rawValue] != syncToken {
                completion(.success([]))
                return
            }
            switch tokenResult {
            case .failure(let err):
                completion(.failure(err))
            case .success(let token):
                self.requestRoomsWithToken(
                    token: token,
                    dateString: dateString,
                    campus: campus,
                    buildingIds: sortedIds,
                    cacheKey: cacheKey,
                    syncToken: syncToken,
                    allowRetry: true,
                    completion: completion
                )
            }
        }
    }

    private func requestRoomsWithToken(
        token: String,
        dateString: String,
        campus: StudyCampus,
        buildingIds: [Int],
        cacheKey: String,
        syncToken: UUID? = nil,
        allowRetry: Bool,
        currentPage: Int = 1,
        cacheResult: Bool = true,
        accumulatedRooms: [EmptyClassroomItem] = [],
        completion: @escaping (Result<[EmptyClassroomItem], Error>) -> Void
    ) {
        guard let url = URL(string: "\(Self.uniAppBaseURL)/eams-micro-server/api/v1/room/place/rooms") else {
            completion(.failure(NSError(domain: "EmptyClassroom", code: -1, userInfo: [NSLocalizedDescriptionKey: "空教室请求地址无效"])))
            return
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35.0)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")

        var bodyDict: [String: Any] = [
            "currentPage": currentPage,
            "date": dateString,
            "campusAssoc": campus.rawValue,
            "pageSize": Self.roomPageSize
        ]
        if !buildingIds.isEmpty {
            bodyDict["buildingIds"] = buildingIds
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            if let syncToken, self.activeSyncTokenByCampus[campus.rawValue] != syncToken {
                completion(.success(accumulatedRooms))
                return
            }
            if let error = error {
                completion(.failure(error))
                return
            }

            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0

            struct RoomsResponseRoot: Decodable {
                struct RoomsDataWrapper: Decodable {
                    let data: [EmptyClassroomItem]?
                }
                let data: RoomsDataWrapper?
            }

            if statusCode == 200,
               let data = data,
               let root = try? JSONDecoder().decode(RoomsResponseRoot.self, from: data),
               let rooms = root.data?.data {
                if cacheResult, rooms.count == Self.roomPageSize {
                    guard currentPage < Self.maximumRoomPages else {
                        completion(.failure(NSError(
                            domain: "EmptyClassroom",
                            code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "空教室数据超过分页上限，未保存不完整结果"]
                        )))
                        return
                    }
                    self.requestRoomsWithToken(
                        token: token,
                        dateString: dateString,
                        campus: campus,
                        buildingIds: buildingIds,
                        cacheKey: cacheKey,
                        syncToken: syncToken,
                        allowRetry: true,
                        currentPage: currentPage + 1,
                        cacheResult: true,
                        accumulatedRooms: accumulatedRooms + rooms,
                        completion: completion
                    )
                    return
                }

                let sortedRooms = Self.uniqueRooms(accumulatedRooms + rooms).sorted { a, b in
                    if a.buildingPrefix != b.buildingPrefix {
                        return campus.compareBuildingNames(a.buildingPrefix, b.buildingPrefix)
                    }
                    if a.inferredFloor != b.inferredFloor {
                        return a.inferredFloor < b.inferredFloor
                    }
                    return a.inferredRoomNumber < b.inferredRoomNumber
                }
                let syncIsCurrent = syncToken.map {
                    activeSyncTokenByCampus[campus.rawValue] == $0
                } ?? true
                if cacheResult && syncIsCurrent {
                    self.roomsCache[cacheKey] = sortedRooms
                    if !buildingIds.isEmpty {
                        let grouped = Dictionary(grouping: sortedRooms, by: { $0.buildingId })
                        for bid in buildingIds {
                            self.roomsCache["\(campus.rawValue)|\(dateString)|\(bid)"] = grouped[bid] ?? []
                        }
                    }
                    if syncToken == nil {
                        DispatchQueue.main.async {
                            self.recordCampusSyncTime(campus)
                        }
                    }
                }
                completion(.success(sortedRooms))
                return
            }

            if allowRetry {
                self.ensureValidToken(forceRelogin: true) { retryRes in
                    switch retryRes {
                    case .success(let newToken):
                        self.requestRoomsWithToken(
                            token: newToken,
                            dateString: dateString,
                            campus: campus,
                            buildingIds: buildingIds,
                            cacheKey: cacheKey,
                            syncToken: syncToken,
                            allowRetry: false,
                            currentPage: currentPage,
                            cacheResult: cacheResult,
                            accumulatedRooms: accumulatedRooms,
                            completion: completion
                        )
                    case .failure(let err):
                        completion(.failure(err))
                    }
                }
            } else {
                completion(.failure(NSError(domain: "EmptyClassroom", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "获取空教室数据失败 (HTTP \(statusCode))"])))
            }
        }.resume()
    }

    // MARK: - 查询指定教室全学期课表 (教室课表)

    public func fetchClassroomSemesterSchedule(
        roomId: Int,
        roomName: String,
        semesterId: Int,
        autoFallbackSemester: Bool = false,
        forceRefresh: Bool = false,
        completion: @escaping (Result<CourseScheduleData, Error>) -> Void
    ) {
        let cacheKey = "\(roomId)|\(semesterId)"
        if !forceRefresh, let cached = roomSemesterScheduleCache[cacheKey] {
            completion(.success(cached))
            return
        }

        ensureValidToken(forceRelogin: false) { [weak self] tokenResult in
            guard let self = self else { return }
            switch tokenResult {
            case .failure(let err):
                completion(.failure(err))
            case .success(let token):
                self.requestClassroomSemesterScheduleWithToken(
                    token: token,
                    roomId: roomId,
                    roomName: roomName,
                    semesterId: semesterId,
                    cacheKey: cacheKey,
                    allowRetry: true,
                    completion: completion
                )
            }
        }
    }

    private func requestClassroomSemesterScheduleWithToken(
        token: String,
        roomId: Int,
        roomName: String,
        semesterId: Int,
        cacheKey: String,
        allowRetry: Bool,
        completion: @escaping (Result<CourseScheduleData, Error>) -> Void
    ) {
        guard let url = URL(string: "\(Self.uniAppBaseURL)/eams-micro-server/api/v1/lesson/room/getLessons?semesterAssoc=\(semesterId)&roomAssoc=\(roomId)") else {
            completion(.failure(NSError(domain: "EmptyClassroom", code: -1, userInfo: [NSLocalizedDescriptionKey: "教室课表请求地址无效"])))
            return
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30.0)
        req.httpMethod = "GET"
        req.setValue(token, forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }

            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0

            struct RoomLessonsRoot: Decodable {
                let result: Int?
                let data: [RoomLessonDTO]?
            }
            struct RoomLessonDTO: Decodable {
                let id: Int?
                let nameZh: String?
                let code: String?
                let stdCount: Int?
                let course: RoomCourseDTO?
                let teacherAssignmentList: [String]?
                let schedules: [RoomScheduleDTO]?
            }
            struct RoomCourseDTO: Decodable {
                let nameZh: String?
                let code: String?
                let credits: Double?
            }
            struct RoomScheduleDTO: Decodable {
                struct RoomRefDTO: Decodable {
                    let id: Int?
                    let nameZh: String?
                }
                let date: String?
                let weekday: Int?
                let weekIndex: Int?
                let startTime: Int?
                let endTime: Int?
                let teacherName: String?
                let room: RoomRefDTO?
            }

            if statusCode == 200,
               let data = data,
               let root = try? JSONDecoder().decode(RoomLessonsRoot.self, from: data),
               let rawLessons = root.data {
                var parsedLessons: [CourseLesson] = []
                for dto in rawLessons {
                    let lessonId = dto.id ?? 0
                    let courseName = (dto.course?.nameZh?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (dto.nameZh?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? "未知课程"
                    let courseCode = dto.course?.code ?? dto.code
                    let classTitle = dto.nameZh?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stdCountText = (dto.stdCount ?? 0) > 0 ? "\(dto.stdCount!)人" : ""
                    let classSummary: String
                    if !classTitle.isEmpty && !stdCountText.isEmpty {
                        classSummary = "\(classTitle) (\(stdCountText))"
                    } else if !classTitle.isEmpty {
                        classSummary = classTitle
                    } else if !stdCountText.isEmpty {
                        classSummary = stdCountText
                    } else {
                        classSummary = roomName
                    }

                    let teacherAssignments = dto.teacherAssignmentList?
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty } ?? []
                    let fallbackTeacher = teacherAssignments.isEmpty
                        ? nil
                        : teacherAssignments.joined(separator: ",")

                    for (idx, sched) in (dto.schedules ?? []).enumerated() {
                        // 仅保留在当前目标教室上课的课节（排除同一教学班在其他周次去机房/实验室的课节）
                        if let rId = sched.room?.id, rId != roomId {
                            continue
                        }
                        let dateStr = sched.date ?? ""
                        guard !dateStr.isEmpty else { continue }
                        let sTime = sched.startTime ?? 800
                        let eTime = sched.endTime ?? 950
                        let wDay = sched.weekday ?? (CourseCalendarHelper.parseDate(dateStr, "00:00").map { CourseCalendarHelper.weekday(from: $0) } ?? 1)
                        let teacherStr = (sched.teacherName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                            ?? fallbackTeacher

                        let item = CourseLesson(
                            id: "room-\(roomId)-\(lessonId)-\(dateStr)-\(sTime)-\(idx)",
                            lessonId: lessonId,
                            courseName: courseName,
                            courseCode: courseCode,
                            teacher: teacherStr,
                            classroom: classSummary,
                            dateString: dateStr,
                            startTime: sTime,
                            endTime: eTime,
                            weekIndex: sched.weekIndex,
                            weekday: wDay
                        )
                        parsedLessons.append(item)
                    }
                }

                let scheduleData = CourseScheduleData(
                    studentId: "room_\(roomId)",
                    semesterId: "\(semesterId)",
                    semesterName: Self.semesterTitle(for: semesterId),
                    bizTypeId: "room",
                    lastSyncTime: Date(),
                    lessons: parsedLessons
                )
                self.roomSemesterScheduleCache[cacheKey] = scheduleData
                completion(.success(scheduleData))
                return
            }

            if allowRetry {
                self.ensureValidToken(forceRelogin: true) { retryRes in
                    switch retryRes {
                    case .success(let newToken):
                        self.requestClassroomSemesterScheduleWithToken(
                            token: newToken,
                            roomId: roomId,
                            roomName: roomName,
                            semesterId: semesterId,
                            cacheKey: cacheKey,
                            allowRetry: false,
                            completion: completion
                        )
                    case .failure(let err):
                        completion(.failure(err))
                    }
                }
            } else {
                completion(.failure(NSError(domain: "EmptyClassroom", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "获取教室全学期课表失败 (HTTP \(statusCode))"])))
            }
        }.resume()
    }

    // MARK: - 合工大教务移动端 (UniApp) 自动认证与 RSA 加密

    public func ensureValidToken(
        forceRelogin: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let requestGeneration = currentTokenGeneration()
        if !forceRelogin,
           let savedJwt = SettingsManager.shared.uniAppJwt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !savedJwt.isEmpty {
            guard isCurrentTokenGeneration(requestGeneration) else {
                completion(.failure(tokenLoginCancelledError()))
                return
            }
            completion(.success(savedJwt))
            return
        }

        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            completion(.failure(NSError(domain: "EmptyClassroom", code: 401, userInfo: [NSLocalizedDescriptionKey: "请先在偏好设置或统一身份认证中填写学号"])))
            return
        }

        // 获取候选教务密码列表（1. 教务系统学生信息推导的默认密码 Hfut@#$%+身份证后6位；2. 门户密码；3. 校园网密码）
        resolveCandidatePasswords(tokenGeneration: requestGeneration) { [weak self] passwords in
            guard let self = self else { return }
            guard self.isCurrentTokenGeneration(requestGeneration) else {
                completion(.failure(self.tokenLoginCancelledError()))
                return
            }
            guard !passwords.isEmpty else {
                completion(.failure(NSError(domain: "EmptyClassroom", code: 401, userInfo: [NSLocalizedDescriptionKey: "无法获取教务系统登录凭证，请先完成统一身份认证或教务授权"])))
                return
            }
            self.tryLoginUniAppSequential(
                username: username,
                passwords: passwords,
                index: 0,
                tokenGeneration: requestGeneration,
                completion: completion)
        }
    }

    public func cancelPendingAuthentication() {
        tokenStateLock.lock()
        tokenGeneration &+= 1
        tokenStateLock.unlock()
    }

    private func currentTokenGeneration() -> Int {
        tokenStateLock.lock()
        defer { tokenStateLock.unlock() }
        return tokenGeneration
    }

    private func isCurrentTokenGeneration(_ generation: Int) -> Bool {
        tokenStateLock.lock()
        defer { tokenStateLock.unlock() }
        return tokenGeneration == generation
    }

    private func persistTokenIfCurrent(_ token: String, generation: Int) -> Bool {
        tokenStateLock.lock()
        defer { tokenStateLock.unlock() }
        guard tokenGeneration == generation else { return false }
        SettingsManager.shared.uniAppJwt = token
        return true
    }

    private func persistDefaultPasswordIfCurrent(_ password: String, generation: Int) -> Bool {
        tokenStateLock.lock()
        defer { tokenStateLock.unlock() }
        guard tokenGeneration == generation else { return false }
        SettingsManager.shared.jxglstuDefaultPasswordCache = password
        return true
    }

    private func tokenLoginCancelledError() -> NSError {
        NSError(domain: "EmptyClassroom", code: 499, userInfo: [NSLocalizedDescriptionKey: "教务登录已取消"])
    }

    private func tryLoginUniAppSequential(
        username: String,
        passwords: [String],
        index: Int,
        tokenGeneration: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard isCurrentTokenGeneration(tokenGeneration) else {
            completion(.failure(tokenLoginCancelledError()))
            return
        }
        guard index < passwords.count else {
            completion(.failure(NSError(domain: "EmptyClassroom", code: 401, userInfo: [NSLocalizedDescriptionKey: "登录合工大教务移动端失败，请检查账号或重新执行统一身份认证"])))
            return
        }

        let rawPwd = passwords[index]
        guard let encryptedPwd = Self.rsaEncrypt(rawPwd, publicKeyBase64: Self.rsaPublicKeyBase64) else {
            tryLoginUniAppSequential(
                username: username,
                passwords: passwords,
                index: index + 1,
                tokenGeneration: tokenGeneration,
                completion: completion)
            return
        }

        var comps = URLComponents(string: "\(Self.uniAppBaseURL)/token/password/passwordLogin")!
        comps.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: encryptedPwd),
            URLQueryItem(name: "appId", value: "APP_ID"),
            URLQueryItem(name: "deviceId", value: "DEVICE_ID")
        ]

        guard let loginURL = comps.url else {
            tryLoginUniAppSequential(
                username: username,
                passwords: passwords,
                index: index + 1,
                tokenGeneration: tokenGeneration,
                completion: completion)
            return
        }

        var req = URLRequest(url: loginURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30.0)
        req.httpMethod = "POST"
        req.httpBody = Data() // 必须发送空 Body 以带上 Content-Length: 0

        session.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self else { return }
            guard self.isCurrentTokenGeneration(tokenGeneration) else {
                completion(.failure(self.tokenLoginCancelledError()))
                return
            }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let idToken = dataObj["idToken"] as? String,
               !idToken.isEmpty {
                guard self.persistTokenIfCurrent(idToken, generation: tokenGeneration) else {
                    completion(.failure(self.tokenLoginCancelledError()))
                    return
                }
                completion(.success(idToken))
            } else {
                self.tryLoginUniAppSequential(
                    username: username,
                    passwords: passwords,
                    index: index + 1,
                    tokenGeneration: tokenGeneration,
                    completion: completion)
            }
        }.resume()
    }

    /// 自动从树维教务 `for-std/student-info/info/{studentId}` 提取身份证后6位拼接 `Hfut@#$%`（与 HFUT-Schedule 一致）
    private func resolveCandidatePasswords(
        tokenGeneration: Int,
        completion: @escaping ([String]) -> Void
    ) {
        var list: [String] = []
        if let cachedDefault = SettingsManager.shared.jxglstuDefaultPasswordCache, !cachedDefault.isEmpty {
            list.append(cachedDefault)
        }
        let casPwd = SettingsManager.shared.casPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !casPwd.isEmpty && !list.contains(casPwd) {
            list.append(casPwd)
        }
        let portalPwd = SettingsManager.shared.portalPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !portalPwd.isEmpty && !list.contains(portalPwd) {
            list.append(portalPwd)
        }

        // 如果已经缓存过 Hfut@#$% 默认密码，直接返回
        if SettingsManager.shared.jxglstuDefaultPasswordCache != nil {
            completion(list)
            return
        }

        fetchJxglstuDefaultPassword(tokenGeneration: tokenGeneration) { [weak self] derivedPwd in
            guard let self = self, self.isCurrentTokenGeneration(tokenGeneration) else {
                completion([])
                return
            }
            if let pwd = derivedPwd, !pwd.isEmpty {
                guard self.persistDefaultPasswordIfCurrent(pwd, generation: tokenGeneration) else {
                    completion([])
                    return
                }
                list.insert(pwd, at: 0)
            }
            completion(list)
        }
    }

    private func fetchJxglstuDefaultPassword(
        tokenGeneration: Int,
        completion: @escaping (String?) -> Void
    ) {
        let performFetch: (@escaping (String?) -> Void) -> Void = { done in
            let stdId = SettingsManager.shared.courseStudentId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stdId.isEmpty,
                  let infoURL = URL(string: "http://jxglstu.hfut.edu.cn/eams5-student/for-std/student-info/info/\(stdId)"),
                  let savedCookie = SettingsManager.shared.courseSessionCookie?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !savedCookie.isEmpty else {
                done(nil)
                return
            }
            let cookieHeader = savedCookie.contains("SESSION=") ? savedCookie : "SESSION=\(savedCookie)"
            var req = URLRequest(url: infoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12.0)
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data = data, let html = String(data: data, encoding: .utf8) else {
                    done(nil)
                    return
                }
                let pattern = #"证件号[\s\S]{0,200}?<span[^>]*>\s*([0-9Xx]{15,18})\s*</span>"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let range = Range(match.range(at: 1), in: html) {
                    let idCard = String(html[range])
                    let last6 = String(idCard.suffix(6))
                    done("Hfut@#$%\(last6)")
                } else {
                    done(nil)
                }
            }.resume()
        }

        performFetch { firstTry in
            guard self.isCurrentTokenGeneration(tokenGeneration) else {
                completion(nil)
                return
            }
            if let pwd = firstTry {
                completion(pwd)
            } else {
                // 若尚未获取 studentId 或教务 Cookie 过期，先触发一次后台登录自动获取 studentId 与 Cookie 再重试
                CourseScheduleService.shared.tryBackgroundLogin { success in
                    guard self.isCurrentTokenGeneration(tokenGeneration) else {
                        completion(nil)
                        return
                    }
                    if success {
                        performFetch(completion)
                    } else {
                        completion(nil)
                    }
                }
            }
        }
    }

    /// RSA/ECB/PKCS1Padding 加密（与 HFUT-Schedule 的 CryptoUtil.rsaEncrypt 完全一致）
    public static func rsaEncrypt(_ plainText: String, publicKeyBase64: String) -> String? {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let plainData = plainText.data(using: .utf8) else {
            return nil
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error),
              let cipherData = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, plainData as CFData, &error) as Data? else {
            return nil
        }
        return cipherData.base64EncodedString()
    }

    // MARK: - 日期与时间辅助函数

    public static func todayDateString(at now: Date = Date()) -> String {
        CourseCalendarHelper.dateString(from: now)
    }

    public static func tomorrowDateString(at now: Date = Date()) -> String {
        let cal = CourseCalendarHelper.beijingCalendar
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400)
        return CourseCalendarHelper.dateString(from: tomorrow)
    }

    public static func currentMinutesOfDay(at now: Date = Date()) -> Int {
        let comps = CourseCalendarHelper.beijingCalendar.dateComponents([.hour, .minute], from: now)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}
