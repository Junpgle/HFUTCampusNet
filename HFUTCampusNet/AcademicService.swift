import Foundation
import AppKit
import CryptoKit

private struct AccountScopedAcademicCache: Codable {
    let accountKey: String
    let snapshot: AcademicDataSnapshot
}

public class AcademicService: NSObject, URLSessionDelegate {
    public static let shared = AcademicService()

    private static let uniAppBaseURL = "https://jwglapp.hfut.edu.cn"
    private static let eamsBaseURL = "http://jxglstu.hfut.edu.cn/eams5-student"

    public private(set) var latestData: AcademicDataSnapshot?
    public private(set) var isSyncing: Bool = false
    public private(set) var lastErrorMessage: String?

    private var monitorTimer: Timer?
    private var pendingSyncCompletions: [(Result<AcademicDataSnapshot, Error>) -> Void] = []
    private var isMonitoring = false
    private var isPausedForSleep = false
    private var monitorGeneration = 0
    private var syncGeneration = 0
    private let fileManager = FileManager.default

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25.0
        config.timeoutIntervalForResource = 30.0
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var cacheFileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("cn.edu.hfut.campusnet.monitor", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("academic_data.json")
    }

    private override init() {
        super.init()
        loadCachedData()

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

    @objc private func handleSystemWake() {
        guard isPausedForSleep else { return }
        isPausedForSleep = false
        startMonitoring()
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
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: - 本地持久化缓存

    private func loadCachedData() {
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty,
              fileManager.fileExists(atPath: cacheFileURL.path),
              let data = try? Data(contentsOf: cacheFileURL),
              let cached = try? JSONDecoder().decode(AccountScopedAcademicCache.self, from: data),
              cached.accountKey == Self.cacheAccountKey(for: username) else {
            return
        }
        let decoded = cached.snapshot
        self.latestData = decoded
        // 确保已缓存过的成绩已记录在 notifiedGradeIds 中，避免升级/重启后把旧成绩当新成绩刷屏
        var notified = SettingsManager.shared.notifiedGradeIds
        if notified.isEmpty && !decoded.allGrades.isEmpty {
            for g in decoded.allGrades {
                notified.insert(g.id)
            }
            SettingsManager.shared.notifiedGradeIds = notified
        }
    }

    private func saveCachedData(_ snapshot: AcademicDataSnapshot) {
        self.latestData = snapshot
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let cache = AccountScopedAcademicCache(accountKey: Self.cacheAccountKey(for: username), snapshot: snapshot)
        if preserveLegacyCacheBackup(), let encoded = try? JSONEncoder().encode(cache) {
            try? encoded.write(to: cacheFileURL, options: .atomic)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .academicDataDidUpdate, object: snapshot)
        }
    }

    private func preserveLegacyCacheBackup() -> Bool {
        guard fileManager.fileExists(atPath: cacheFileURL.path) else { return true }
        if let data = try? Data(contentsOf: cacheFileURL),
           (try? JSONDecoder().decode(AccountScopedAcademicCache.self, from: data)) != nil {
            return true
        }

        let backupURL = cacheFileURL.appendingPathExtension("pre-account-scope-v1.bak")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return true }
        do {
            try fileManager.copyItem(at: cacheFileURL, to: backupURL)
            return true
        } catch {
            print("教务缓存账号标记迁移备份失败: \(error.localizedDescription)")
            return false
        }
    }

    private static func cacheAccountKey(for username: String) -> String {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let identity = normalizedUsername.isEmpty ? "UNCONFIGURED" : normalizedUsername
        let digest = SHA256.hash(data: Data("portal-username:\(identity)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public var unreadGradeCount: Int {
        SettingsManager.shared.unreadGradeIds.count
    }

    public func markAllGradesAsRead() {
        guard !SettingsManager.shared.unreadGradeIds.isEmpty else { return }
        SettingsManager.shared.unreadGradeIds = []
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .academicDataDidUpdate, object: self.latestData)
        }
    }

    public func clearCache() {
        syncGeneration &+= 1
        isSyncing = false
        self.latestData = nil
        try? fileManager.removeItem(at: cacheFileURL)
        SettingsManager.shared.notifiedGradeIds = []
        SettingsManager.shared.unreadGradeIds = []
        lastErrorMessage = nil
        let completions = pendingSyncCompletions
        pendingSyncCompletions.removeAll(keepingCapacity: false)
        let cancellation = NSError(
            domain: "AcademicService",
            code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "账号已切换，本次学业数据同步已取消"]
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .academicDataDidUpdate, object: nil)
            completions.forEach { $0(.failure(cancellation)) }
        }
    }

    // MARK: - 后台定时轮询监控（出分静默监控 & 考场同步）

    public func startMonitoring() {
        isMonitoring = true
        monitorGeneration += 1
        let generation = monitorGeneration
        // 启动后延迟 5 秒执行首次静默同步
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.isMonitoring, self.monitorGeneration == generation else { return }
            self.syncAll(silent: true, completion: nil)
        }
        scheduleMonitorTimer()
    }

    private func scheduleMonitorTimer() {
        monitorTimer?.invalidate()
        // 成绩与考场同步周期：插电 15 分钟，电池下按省电设置放宽
        let onBattery = SettingsManager.isOnBatteryPower()
        let interval = PowerSaver.academicInterval(onBattery: onBattery)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.syncAll(silent: true, completion: nil)
        }
        t.tolerance = PowerSaver.tolerance(for: interval)
        monitorTimer = t
    }

    public func stopMonitoring() {
        isMonitoring = false
        monitorGeneration += 1
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    // MARK: - 全量同步（合并 UniApp 移动端接口与 EAMS 5.0 网页端接口）

    public func syncAll(
        silent: Bool = false,
        completion: ((Result<AcademicDataSnapshot, Error>) -> Void)? = nil
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.syncAll(silent: silent, completion: completion)
            }
            return
        }

        if isSyncing {
            if let completion {
                pendingSyncCompletions.append(completion)
            }
            return
        }
        isSyncing = true
        pendingSyncCompletions = completion.map { [$0] } ?? []
        lastErrorMessage = nil
        let generation = syncGeneration
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .academicDataDidUpdate, object: self.latestData)
        }

        let finishSync: (Result<AcademicDataSnapshot, Error>) -> Void = { [weak self] result in
            guard let self, self.syncGeneration == generation else { return }
            self.isSyncing = false
            let completions = self.pendingSyncCompletions
            self.pendingSyncCompletions.removeAll(keepingCapacity: false)
            completions.forEach { $0(result) }
        }

        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "AcademicService.syncResults.\(generation)")

        var uniAppGrades: [TermGradeGroup]?
        var eamsGrades: [TermGradeGroup]?
        var uniAppExams: [ExamItem] = []
        var eamsExams: [ExamItem] = []
        var eamsProgram: ProgramCompletionSummary?
        var eamsTextbooks: [CourseTextbookItem] = []
        var eamsSurveys: [LessonSurveyItem] = []
        var lastErr: Error?

        // 通道 1：合工大教务移动端 (UniApp JWT)
        group.enter()
        fetchFromUniApp { resGrades, resExams, err in
            resultQueue.sync {
                if let g = resGrades, !g.isEmpty {
                    uniAppGrades = g
                }
                if let e = resExams {
                    uniAppExams = e
                }
                if let err = err {
                    lastErr = err
                }
            }
            group.leave()
        }

        // 通道 2：树维教务系统网页端 (jxglstu EAMS 5.0：含成绩、排考、培养方案完成度、本学期教材与评教状态)
        group.enter()
        fetchFromEamsWeb { resGrades, resExams, resProgram, resTextbooks, resSurveys, err in
            resultQueue.sync {
                if let g = resGrades, !g.isEmpty {
                    eamsGrades = g
                }
                if let e = resExams {
                    eamsExams = e
                }
                if let p = resProgram {
                    eamsProgram = p
                }
                if let tb = resTextbooks, !tb.isEmpty {
                    eamsTextbooks = tb
                }
                if let sv = resSurveys {
                    eamsSurveys = sv
                }
                if let err = err, lastErr == nil {
                    lastErr = err
                }
            }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, self.syncGeneration == generation else { return }
            let collected = resultQueue.sync {
                (
                    uniAppGrades: uniAppGrades,
                    eamsGrades: eamsGrades,
                    uniAppExams: uniAppExams,
                    eamsExams: eamsExams,
                    eamsProgram: eamsProgram,
                    eamsTextbooks: eamsTextbooks,
                    eamsSurveys: eamsSurveys,
                    lastError: lastErr
                )
            }

            // 合并成绩（优先使用包含 semesterId 的 UniApp 数据，并补充 EAMS 独有的条目；若 UniApp 失败则使用 EAMS 数据）
            let mergedTermGroups = self.mergeTermGradeGroups(primary: collected.uniAppGrades, secondary: collected.eamsGrades)
            // 合并考试安排（去重并保留字段最完整的一条）
            let mergedExams = self.mergeExams(uniAppExams: collected.uniAppExams, eamsExams: collected.eamsExams)

            if mergedTermGroups.isEmpty && mergedExams.isEmpty && collected.eamsProgram == nil && collected.eamsTextbooks.isEmpty && collected.eamsSurveys.isEmpty,
               let prev = self.latestData, !prev.allGrades.isEmpty {
                // 如果本次网络完全失败且已有本地缓存，保留本地缓存
                self.lastErrorMessage = collected.lastError?.localizedDescription
                NotificationCenter.default.post(name: .academicDataDidUpdate, object: prev)
                if let err = collected.lastError {
                    finishSync(.failure(err))
                } else {
                    finishSync(.success(prev))
                }
                return
            }

            if mergedTermGroups.isEmpty && mergedExams.isEmpty && collected.eamsProgram == nil && collected.eamsTextbooks.isEmpty && collected.eamsSurveys.isEmpty,
               let err = collected.lastError {
                self.lastErrorMessage = err.localizedDescription
                NotificationCenter.default.post(name: .academicDataDidUpdate, object: nil)
                finishSync(.failure(err))
                return
            }

            let oldSnapshot = self.latestData
            let finalExams = mergedExams.isEmpty ? (oldSnapshot?.exams ?? []) : mergedExams
            let finalGroups = mergedTermGroups.isEmpty ? (oldSnapshot?.termGroups ?? []) : mergedTermGroups
            let finalProgram = collected.eamsProgram ?? oldSnapshot?.programCompletion
            let finalTextbooks = collected.eamsTextbooks.isEmpty ? (oldSnapshot?.textbooks ?? []) : collected.eamsTextbooks
            let finalSurveys = collected.eamsSurveys.isEmpty ? (oldSnapshot?.surveys ?? []) : collected.eamsSurveys

            let newSnapshot = AcademicDataSnapshot(
                exams: finalExams,
                termGroups: finalGroups,
                programCompletion: finalProgram,
                textbooks: finalTextbooks,
                surveys: finalSurveys,
                lastSyncTime: Date()
            )

            // 检测是否有新出分的科目并推送通知
            self.detectAndNotifyNewGrades(oldSnapshot: oldSnapshot, newSnapshot: newSnapshot)

            self.saveCachedData(newSnapshot)
            finishSync(.success(newSnapshot))
        }
    }

    // MARK: - 出分静默监控与 GPA 变动通知

    private func detectAndNotifyNewGrades(oldSnapshot: AcademicDataSnapshot?, newSnapshot: AcademicDataSnapshot) {
        let allNewGrades = newSnapshot.allGrades
        guard !allNewGrades.isEmpty else { return }

        var notifiedIds = SettingsManager.shared.notifiedGradeIds
        // 如果之前从未记录过任何已通知成绩（首次安装同步全部历史学期成绩），将当前所有成绩标记为已知，不逐门轰炸通知
        if notifiedIds.isEmpty && (oldSnapshot == nil || oldSnapshot?.allGrades.isEmpty == true) {
            for g in allNewGrades {
                notifiedIds.insert(g.id)
            }
            SettingsManager.shared.notifiedGradeIds = notifiedIds
            return
        }

        let newlyPublished = allNewGrades.filter { !notifiedIds.contains($0.id) }
        guard !newlyPublished.isEmpty else { return }

        var unreadIds = SettingsManager.shared.unreadGradeIds
        for g in newlyPublished {
            notifiedIds.insert(g.id)
            unreadIds.insert(g.id)
        }
        SettingsManager.shared.notifiedGradeIds = notifiedIds
        SettingsManager.shared.unreadGradeIds = unreadIds

        let hideScore = SettingsManager.shared.hideScoreInNotification
        if hideScore {
            NotificationHelper.showNotification(
                title: "🎉 教务系统成绩有更新",
                subtitle: "检测到 \(newlyPublished.count) 门课程刚刚出分",
                body: "点击状态栏「考试与成绩」打开面板即可查看具体成绩与 GPA 详情。"
            )
            return
        }

        let oldGPA = oldSnapshot?.overallWeightedGPA
        let newGPA = newSnapshot.overallWeightedGPA

        let gpaChangeText: String = {
            guard let n = newGPA else { return "" }
            if let o = oldGPA, abs(n - o) >= 0.001 {
                let diff = n - o
                let sign = diff >= 0 ? "+" : ""
                return String(format: "总 GPA: %.2f (%@%.2f)", n, sign, diff)
            }
            return String(format: "当前总 GPA: %.2f", n)
        }()

        for course in newlyPublished.prefix(3) {
            let gpaPart = course.gpa.map { String(format: "绩点 %.1f", $0) } ?? "等级制"
            let detailPart = course.detailText.isEmpty ? "" : " (\(course.detailText))"
            NotificationHelper.showNotification(
                title: "🎉 新成绩出分 · 《\(course.courseName)》: \(course.scoreText)",
                subtitle: "学分 \(String(format: "%.1f", course.credits)) · \(gpaPart)  \(gpaChangeText)",
                body: "明细：\(detailPart.isEmpty ? "总评 \(course.scoreText)" : course.detailText)"
            )
        }

        if newlyPublished.count > 3 {
            NotificationHelper.showNotification(
                title: "🎓 共有 \(newlyPublished.count) 门课程新出分",
                subtitle: gpaChangeText,
                body: "可在「考试与成绩」面板查看全部最新成绩与加权分。"
            )
        }
    }

    // MARK: - 通道 1：合工大教务移动端 (UniApp) 请求与解析

    private func fetchFromUniApp(
        completion: @escaping (_ grades: [TermGradeGroup]?, _ exams: [ExamItem]?, _ error: Error?) -> Void
    ) {
        EmptyClassroomService.shared.ensureValidToken(forceRelogin: false) { [weak self] tokenRes in
            guard let self = self else {
                completion(nil, nil, nil)
                return
            }
            switch tokenRes {
            case .failure(let err):
                completion(nil, nil, err)
            case .success(let token):
                self.requestUniAppGradesAndExams(token: token, allowRetry: true, completion: completion)
            }
        }
    }

    private func requestUniAppGradesAndExams(
        token: String,
        allowRetry: Bool,
        completion: @escaping (_ grades: [TermGradeGroup]?, _ exams: [ExamItem]?, _ error: Error?) -> Void
    ) {
        let group = DispatchGroup()
        var parsedGrades: [TermGradeGroup]?
        var parsedExams: [ExamItem]?
        var needRelogin = false
        var reqError: Error?

        // 1. 拉取成绩单
        if let gradesURL = URL(string: "\(Self.uniAppBaseURL)/eams-micro-server/api/v1/grade/student/grades") {
            group.enter()
            var req = URLRequest(url: gradesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)
            req.httpMethod = "GET"
            req.setValue(token, forHTTPHeaderField: "Authorization")

            session.dataTask(with: req) { [weak self] data, response, err in
                defer { group.leave() }
                if let err = err {
                    reqError = err
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 {
                    needRelogin = true
                    return
                }
                if code == 200, let data = data {
                    if let groups = self?.parseUniAppGradesJSON(data) {
                        parsedGrades = groups
                    } else {
                        needRelogin = true
                    }
                }
            }.resume()
        }

        // 2. 拉取考试安排
        if let examsURL = URL(string: "\(Self.uniAppBaseURL)/eams-micro-server/api/v1/exam/student/exam") {
            group.enter()
            var req = URLRequest(url: examsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)
            req.httpMethod = "GET"
            req.setValue(token, forHTTPHeaderField: "Authorization")

            session.dataTask(with: req) { [weak self] data, response, _ in
                defer { group.leave() }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, let data = data {
                    parsedExams = self?.parseUniAppExamsJSON(data)
                }
            }.resume()
        }

        group.notify(queue: .global()) { [weak self] in
            guard let self = self else { return }
            if needRelogin && allowRetry {
                EmptyClassroomService.shared.ensureValidToken(forceRelogin: true) { retryRes in
                    switch retryRes {
                    case .success(let newToken):
                        self.requestUniAppGradesAndExams(token: newToken, allowRetry: false, completion: completion)
                    case .failure(let err):
                        completion(parsedGrades, parsedExams, err)
                    }
                }
            } else {
                completion(parsedGrades, parsedExams, reqError)
            }
        }
    }

    private func parseUniAppGradesJSON(_ data: Data) -> [TermGradeGroup]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            return nil
        }

        var grouped: [String: (semId: Int?, items: [GradeItem])] = [:]
        var termOrder: [String] = []

        for raw in list {
            let courseName = (raw["courseNameZh"] as? String) ?? "未命名课程"
            let courseCode = (raw["courseCode"] as? String) ?? ""
            let lessonCode = (raw["lessonCode"] as? String) ?? ""
            let credits = (raw["credits"] as? Double) ?? Double((raw["credits"] as? Int) ?? 0)
            let gp = raw["gp"] as? Double
            let passed = (raw["passed"] as? Bool) ?? true
            let finalGrade = (raw["finalGrade"] as? String) ?? "--"
            let rawDetail = (raw["gradeDetail"] as? String) ?? ""
            let cleanDetail = rawDetail
                .replacingOccurrences(of: ";", with: " · ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·"))

            var termName = "未知学期"
            var semId: Int? = nil
            if let semObj = raw["semester"] as? [String: Any] {
                termName = (semObj["nameZh"] as? String) ?? (semObj["name"] as? String) ?? termName
                semId = semObj["id"] as? Int
            }

            let item = GradeItem(
                termName: termName,
                semesterId: semId,
                courseName: courseName,
                courseCode: courseCode,
                lessonCode: lessonCode,
                credits: credits,
                gpa: gp,
                scoreText: finalGrade,
                detailText: cleanDetail,
                passed: passed
            )

            if grouped[termName] == nil {
                termOrder.append(termName)
                grouped[termName] = (semId, [item])
            } else {
                let currentSemId = grouped[termName]?.semId ?? semId
                var arr = grouped[termName]?.items ?? []
                arr.append(item)
                grouped[termName] = (currentSemId, arr)
            }
        }

        let groups: [TermGradeGroup] = termOrder.compactMap { tName in
            guard let entry = grouped[tName] else { return nil }
            return TermGradeGroup(termName: tName, semesterId: entry.semId, grades: entry.items)
        }

        // 按学期从新到旧排序（优先按 semesterId 降序，否则按学期名称降序）
        return groups.sorted { a, b in
            if let sa = a.semesterId, let sb = b.semesterId, sa != sb {
                return sa > sb
            }
            return a.termName > b.termName
        }
    }

    private func parseUniAppExamsJSON(_ data: Data) -> [ExamItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            return []
        }

        var result: [ExamItem] = []
        for raw in list {
            let courseName = ((raw["courseNameZh"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !courseName.isEmpty else { continue }
            let courseCode = raw["courseCode"] as? String
            let examDate = ((raw["examDate"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let startInt = Self.examTimeValue(raw["startTime"]),
                  let endInt = Self.examTimeValue(raw["endTime"]),
                  Self.isValidExamTimeValue(startInt),
                  Self.isValidExamTimeValue(endInt) else {
                continue
            }
            let startStr = String(format: "%02d:%02d", startInt / 100, startInt % 100)
            let endStr = String(format: "%02d:%02d", endInt / 100, endInt % 100)
            let dateTimeStr = "\(examDate) \(startStr)~\(endStr)"

            guard Self.isValidExamDateTime(dateTimeStr) else { continue }

            let rawPlace = (raw["place"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var examType: String? = nil
            if let typeObj = raw["examType"] as? [String: Any] {
                examType = (typeObj["nameZh"] as? String) ?? (typeObj["name"] as? String)
            }

            let item = ExamItem(
                courseName: courseName,
                courseCode: courseCode,
                dateTimeString: dateTimeStr,
                dateString: examDate,
                startTimeString: startStr,
                endTimeString: endStr,
                place: rawPlace,
                building: nil,
                campus: nil,
                examType: examType
            )
            result.append(item)
        }
        return result
    }

    // MARK: - 通道 2：树维教务系统网页端 (jxglstu EAMS 5.0) 请求与解析

    private func fetchFromEamsWeb(
        completion: @escaping (
            _ grades: [TermGradeGroup]?,
            _ exams: [ExamItem]?,
            _ program: ProgramCompletionSummary?,
            _ textbooks: [CourseTextbookItem]?,
            _ surveys: [LessonSurveyItem]?,
            _ error: Error?
        ) -> Void
    ) {
        let stdId = SettingsManager.shared.courseStudentId.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedCookie = SettingsManager.shared.courseSessionCookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if stdId.isEmpty || savedCookie.isEmpty {
            CourseScheduleService.shared.tryBackgroundLogin { [weak self] ok in
                guard let self = self, ok else {
                    completion(nil, nil, nil, nil, nil, CourseScheduleService.CourseSyncError.needLogin)
                    return
                }
                self.requestEamsGradesAndExams(allowRetry: false, completion: completion)
            }
            return
        }

        requestEamsGradesAndExams(allowRetry: true, completion: completion)
    }

    private func requestEamsGradesAndExams(
        allowRetry: Bool,
        completion: @escaping (
            _ grades: [TermGradeGroup]?,
            _ exams: [ExamItem]?,
            _ program: ProgramCompletionSummary?,
            _ textbooks: [CourseTextbookItem]?,
            _ surveys: [LessonSurveyItem]?,
            _ error: Error?
        ) -> Void
    ) {
        let stdId = SettingsManager.shared.courseStudentId.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedCookie = SettingsManager.shared.courseSessionCookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stdId.isEmpty, !savedCookie.isEmpty else {
            completion(nil, nil, nil, nil, nil, CourseScheduleService.CourseSyncError.needLogin)
            return
        }

        let cookieHeader = savedCookie.contains("SESSION=") ? savedCookie : "SESSION=\(savedCookie)"
        let rawSem = SettingsManager.shared.courseSemesterId.trimmingCharacters(in: .whitespacesAndNewlines)
        let semesterId = rawSem.isEmpty ? String(CourseCalendarHelper.inferSemesterId()) : rawSem
        let rawBiz = SettingsManager.shared.courseBizTypeId.trimmingCharacters(in: .whitespacesAndNewlines)
        let bizTypeId = (rawBiz.isEmpty || rawBiz == "2") ? "23" : rawBiz

        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "AcademicService.eamsResultCollector")

        var htmlGrades: [TermGradeGroup]?
        var htmlExams: [ExamItem]?
        var parsedProgram: ProgramCompletionSummary?
        var parsedTextbooks: [CourseTextbookItem]?
        var parsedSurveys: [LessonSurveyItem]?
        var sessionExpired = false

        // 1. 网页端成绩单 HTML
        if let gradeURL = URL(string: "\(Self.eamsBaseURL)/for-std/grade/sheet/info/\(stdId)?semester=") {
            group.enter()
            var req = URLRequest(url: gradeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
                defer { group.leave() }
                let http = response as? HTTPURLResponse
                if let urlStr = http?.url?.absoluteString, urlStr.contains("/login") || http?.statusCode == 302 {
                    resultQueue.sync { sessionExpired = true }
                    return
                }
                if let data = data, let html = String(data: data, encoding: .utf8) {
                    if html.contains("/login") && html.contains("password") {
                        resultQueue.sync { sessionExpired = true }
                        return
                    }
                    let grades = self?.parseEamsGradeHTML(html)
                    resultQueue.sync { htmlGrades = grades }
                }
            }.resume()
        }

        // 2. 网页端考场安排 HTML
        if let examURL = URL(string: "\(Self.eamsBaseURL)/for-std/exam-arrange/info/\(stdId)") {
            group.enter()
            var req = URLRequest(url: examURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
                defer { group.leave() }
                let http = response as? HTTPURLResponse
                if let urlStr = http?.url?.absoluteString, urlStr.contains("/login") || http?.statusCode == 302 {
                    resultQueue.sync { sessionExpired = true }
                    return
                }
                if let data = data, let html = String(data: data, encoding: .utf8) {
                    let exams = self?.parseEamsExamHTML(html)
                    resultQueue.sync { htmlExams = exams }
                }
            }.resume()
        }

        // 3. 培养方案与毕业学分完成情况 JSON
        if let progURL = URL(string: "\(Self.eamsBaseURL)/for-std/program-completion-preview/json/\(stdId)") {
            group.enter()
            var req = URLRequest(url: progURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25.0)
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
                defer { group.leave() }
                let http = response as? HTTPURLResponse
                if let urlStr = http?.url?.absoluteString, urlStr.contains("/login") || http?.statusCode == 302 {
                    return
                }
                if let data = data {
                    let program = self?.parseProgramCompletionJSON(data)
                    resultQueue.sync { parsedProgram = program }
                }
            }.resume()
        }

        // 4. 本学期课程教材清单 JSON
        if let tbURL = URL(string: "\(Self.eamsBaseURL)/for-std/lesson-textbook/get-data?bizTypeId=\(bizTypeId)&semesterId=\(semesterId)&dataId=\(stdId)") {
            group.enter()
            var req = URLRequest(url: tbURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
                defer { group.leave() }
                let http = response as? HTTPURLResponse
                if http?.statusCode == 200, let data = data {
                    let textbooks = self?.parseTextbooksJSON(data)
                    resultQueue.sync { parsedTextbooks = textbooks }
                }
            }.resume()
        }

        // 5. 本学期学生评教任务 JSON
        if let surveyURL = URL(string: "\(Self.eamsBaseURL)/for-std/lesson-survey/\(semesterId)/search/\(stdId)") {
            group.enter()
            var req = URLRequest(url: surveyURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
                defer { group.leave() }
                let http = response as? HTTPURLResponse
                if http?.statusCode == 200, let data = data {
                    let surveys = self?.parseLessonSurveysJSON(data)
                    resultQueue.sync { parsedSurveys = surveys }
                }
            }.resume()
        }

        group.notify(queue: .global()) { [weak self] in
            guard let self = self else { return }
            let resultSnapshot = resultQueue.sync {
                (grades: htmlGrades,
                 exams: htmlExams,
                 program: parsedProgram,
                 textbooks: parsedTextbooks,
                 surveys: parsedSurveys,
                 sessionExpired: sessionExpired)
            }
            if resultSnapshot.sessionExpired && allowRetry {
                CourseScheduleService.shared.tryBackgroundLogin { ok in
                    if ok {
                        self.requestEamsGradesAndExams(allowRetry: false, completion: completion)
                    } else {
                        completion(resultSnapshot.grades, resultSnapshot.exams, resultSnapshot.program,
                                   resultSnapshot.textbooks, resultSnapshot.surveys, CourseScheduleService.CourseSyncError.needLogin)
                    }
                }
            } else {
                completion(resultSnapshot.grades, resultSnapshot.exams, resultSnapshot.program,
                           resultSnapshot.textbooks, resultSnapshot.surveys, nil)
            }
        }
    }

    public func parseProgramCompletionJSON(_ data: Data) -> ProgramCompletionSummary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let progObj = root["program"] as? [String: Any]
        let programName = (progObj?["nameZh"] as? String) ?? "本科专业培养方案"
        let gradeYear = (progObj?["grade"] as? String) ?? ""
        let auditDateTime = (root["auditDateTime"] as? String) ?? ""

        let reqObj = root["requireInfo"] as? [String: Any]
        let requiredCredits = Self.doubleValue(reqObj?["credits"])

        let sumObj = root["completionSummary"] as? [String: Any]
        let passedCredits = Self.doubleValue(sumObj?["passedCredits"])
        let takingCredits = Self.doubleValue(sumObj?["takingCredits"])
        let passedCourseCount = (sumObj?["passedCourseNum"] as? Int) ?? 0
        let takingCourseCount = (sumObj?["takingCourseNum"] as? Int) ?? 0

        let outerObj = root["outerCompletionSummary"] as? [String: Any]
        let outerPassedCredits = Self.doubleValue(outerObj?["passedCredits"])
        let outerTakingCredits = Self.doubleValue(outerObj?["takingCredits"])

        var modules: [ProgramModuleItem] = []

        func traverseModule(_ mod: [String: Any], level: Int, parentPath: String) {
            let name = (mod["nameZh"] as? String) ?? "课程模块"
            let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
            let mReq = (mod["requireInfo"] as? [String: Any])
            let mSum = (mod["completionSummary"] as? [String: Any])

            let reqCred = Self.doubleValue(mReq?["credits"])
            let passCred = Self.doubleValue(mSum?["passedCredits"])
            let takeCred = Self.doubleValue(mSum?["takingCredits"])
            let passNum = (mSum?["passedCourseNum"] as? Int) ?? 0
            let takeNum = (mSum?["takingCourseNum"] as? Int) ?? 0

            var takingList: [String] = []
            var unrepairedList: [String] = []

            if let courses = mod["courseList"] as? [[String: Any]] {
                for c in courses {
                    let cName = ((c["nameZh"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cName.isEmpty else { continue }
                    let cCred = Self.doubleValue(c["credits"])
                    let resType = (c["resultType"] as? String) ?? ""
                    let credStr = String(format: "%g", cCred)
                    if resType == "TAKING" {
                        takingList.append("\(cName)(\(credStr)分)")
                    } else if resType == "UNREPAIRED" && level <= 1 {
                        unrepairedList.append("\(cName)(\(credStr)分)")
                    }
                }
            }

            let item = ProgramModuleItem(
                id: path,
                name: name,
                level: level,
                requiredCredits: reqCred,
                passedCredits: passCred,
                takingCredits: takeCred,
                passedCourseCount: passNum,
                takingCourseCount: takeNum,
                takingCourseNames: takingList,
                unrepairedCourseNames: unrepairedList
            )
            modules.append(item)

            if let children = mod["children"] as? [[String: Any]] {
                for ch in children {
                    traverseModule(ch, level: level + 1, parentPath: path)
                }
            }
        }

        if let modList = root["moduleList"] as? [[String: Any]] {
            for m in modList {
                traverseModule(m, level: 0, parentPath: "")
            }
        }

        return ProgramCompletionSummary(
            programName: programName,
            gradeYear: gradeYear,
            auditDateTime: auditDateTime,
            requiredCredits: requiredCredits,
            passedCredits: passedCredits,
            takingCredits: takingCredits,
            passedCourseCount: passedCourseCount,
            takingCourseCount: takingCourseCount,
            outerPassedCredits: outerPassedCredits,
            outerTakingCredits: outerTakingCredits,
            modules: modules
        )
    }

    public func parseTextbooksJSON(_ data: Data) -> [CourseTextbookItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lessons = root["lessons"] as? [[String: Any]] else {
            return []
        }

        let tbMap = (root["textbookAssignMap"] as? [String: [String: Any]]) ?? [:]
        var items: [CourseTextbookItem] = []

        for l in lessons {
            guard let course = l["course"] as? [String: Any] else { continue }
            let courseName = ((course["nameZh"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !courseName.isEmpty else { continue }

            let courseIdStr: String = {
                if let cid = course["id"] as? Int { return String(cid) }
                if let cidStr = course["id"] as? String { return cidStr }
                return ""
            }()

            let courseCode = (course["code"] as? String) ?? ""
            let lessonCode = (l["code"] as? String) ?? ""
            let credits = Self.doubleValue(course["credits"])
            let courseType = ((course["courseType"] as? [String: Any])?["nameZh"] as? String) ?? "专业/通识课"
            let examMode = ((l["examMode"] as? [String: Any])?["nameZh"] as? String)
                ?? ((course["defaultExamMode"] as? [String: Any])?["nameZh"] as? String)
                ?? "考试"
            let department = ((l["openDepartment"] as? [String: Any])?["nameZh"] as? String)
                ?? ((course["defaultOpenDepart"] as? [String: Any])?["nameZh"] as? String)
                ?? ""

            let tbEntry = tbMap[courseIdStr]
            let rawTb = Self.stripHTML((tbEntry?["textbook"] as? String) ?? "")
            let rawSpecial = Self.stripHTML((tbEntry?["specialTextbook"] as? String) ?? "")

            let schedObj = (l["scheduleText"] as? [String: Any])?["dateTimePlacePersonText"] as? [String: Any]
            let rawSched = Self.stripHTML((schedObj?["textZh"] as? String) ?? "")

            let item = CourseTextbookItem(
                courseName: courseName,
                courseCode: courseCode,
                lessonCode: lessonCode,
                credits: credits,
                courseType: courseType,
                examMode: examMode,
                department: department,
                textbookName: rawTb,
                referenceBookName: rawSpecial,
                scheduleSummary: rawSched
            )
            items.append(item)
        }

        return items
    }

    public func parseLessonSurveysJSON(_ data: Data) -> [LessonSurveyItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vms = root["forStdLessonSurveySearchVms"] as? [[String: Any]] else {
            return []
        }

        var items: [LessonSurveyItem] = []
        for vm in vms {
            let lessonCode = (vm["code"] as? String) ?? ""
            let courseObj = vm["course"] as? [String: Any]
            let courseName = (courseObj?["nameZh"] as? String) ?? "未命名课程"
            let openEndText = (vm["openEndTimeContent"] as? String) ?? ""
            let tasks = (vm["lessonSurveyTasks"] as? [[String: Any]]) ?? []

            var pending: [String] = []
            var completed: [String] = []
            for t in tasks {
                let submitted = (t["submitted"] as? Bool) ?? false
                let teacherObj = t["teacher"] as? [String: Any]
                let personObj = teacherObj?["person"] as? [String: Any]
                let tName = (personObj?["nameZh"] as? String) ?? "任课教师"
                if submitted {
                    completed.append(tName)
                } else {
                    pending.append(tName)
                }
            }

            items.append(
                LessonSurveyItem(
                    lessonCode: lessonCode,
                    courseName: courseName,
                    openEndTimeText: openEndText,
                    pendingTeachers: pending,
                    completedTeachers: completed
                )
            )
        }
        return items
    }

    private static func doubleValue(_ anyVal: Any?) -> Double {
        if let d = anyVal as? Double { return d }
        if let i = anyVal as? Int { return Double(i) }
        if let s = anyVal as? String, let d = Double(s) { return d }
        return 0.0
    }

    public func parseEamsGradeHTML(_ html: String) -> [TermGradeGroup] {
        var groups: [TermGradeGroup] = []
        // 匹配每个学期块：<h3>学期名</h3> ... <table class="student-grade-table...">...</table>
        let blockPattern = #"<h3>\s*([^<]+?)\s*</h3>[\s\S]*?<table[^>]*student-grade-table[^>]*>([\s\S]*?)</table>"#
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: [.caseInsensitive]) else {
            return []
        }

        let matches = blockRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let termRange = Range(match.range(at: 1), in: html),
                  let tableRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            let termName = Self.stripHTML(String(html[termRange]))
            let tableBody = String(html[tableRange])

            let rows = Self.extractTableRows(from: tableBody)
            var gradeItems: [GradeItem] = []

            for tds in rows where tds.count >= 6 {
                let courseName = tds[0]
                let courseCode = tds[1]
                let lessonCode = tds[2]
                let credits = Double(tds[3]) ?? 0.0
                let gpa = Double(tds[4])
                let scoreText = tds[5]
                let detailRaw = tds.count >= 7 ? tds[6] : ""
                let passed: Bool = {
                    if let num = GradeItem.parseNumericScore(from: scoreText) {
                        return num >= 60.0
                    }
                    return !scoreText.contains("不及格") && !scoreText.contains("未通过") && !scoreText.contains("旷考")
                }()

                let item = GradeItem(
                    termName: termName,
                    semesterId: nil,
                    courseName: courseName,
                    courseCode: courseCode,
                    lessonCode: lessonCode,
                    credits: credits,
                    gpa: gpa,
                    scoreText: scoreText,
                    detailText: detailRaw,
                    passed: passed
                )
                gradeItems.append(item)
            }

            if !gradeItems.isEmpty {
                groups.append(TermGradeGroup(termName: termName, semesterId: nil, grades: gradeItems))
            }
        }
        return groups
    }

    public func parseEamsExamHTML(_ html: String) -> [ExamItem] {
        // 提取 <table id="exams"...> 中的 tbody
        let tbodyPattern = #"<table[^>]*id=["']exams["'][^>]*>[\s\S]*?<tbody>([\s\S]*?)</tbody>"#
        let targetHTML: String
        if let regex = try? NSRegularExpression(pattern: tbodyPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            targetHTML = String(html[range])
        } else {
            targetHTML = html
        }

        let rows = Self.extractTableRows(from: targetHTML)
        var exams: [ExamItem] = []

        for tds in rows where tds.count >= 3 {
            let courseName = tds[0]
            let dateTimeRaw = tds[1]
            let place = tds[2]
            let building = tds.count >= 4 ? tds[3] : nil
            let campus = tds.count >= 5 ? tds[4] : nil

            guard Self.isValidExamDateTime(dateTimeRaw) else { continue }
            let parts = dateTimeRaw.split(separator: " ")
            guard parts.count == 2 else { continue }
            let datePart = String(parts[0])
            let timeParts = parts[1].split(separator: "~")
            guard timeParts.count == 2 else { continue }

            let item = ExamItem(
                courseName: courseName,
                courseCode: nil,
                dateTimeString: dateTimeRaw,
                dateString: datePart,
                startTimeString: String(timeParts[0]),
                endTimeString: String(timeParts[1]),
                place: place,
                building: building,
                campus: campus,
                examType: "教务排考"
            )
            exams.append(item)
        }
        return exams
    }

    // MARK: - 合并与辅助函数

    private func mergeTermGradeGroups(primary: [TermGradeGroup]?, secondary: [TermGradeGroup]?) -> [TermGradeGroup] {
        let p = primary ?? []
        let s = secondary ?? []
        if p.isEmpty { return s }
        if s.isEmpty { return p }

        var mapByTerm: [String: TermGradeGroup] = [:]
        var order: [String] = []

        for g in p {
            mapByTerm[g.termName] = g
            order.append(g.termName)
        }
        for g in s {
            if var existing = mapByTerm[g.termName] {
                let existingIds = Set(existing.grades.map { $0.id })
                for item in g.grades where !existingIds.contains(item.id) {
                    existing.grades.append(item)
                }
                mapByTerm[g.termName] = existing
            } else {
                mapByTerm[g.termName] = g
                order.append(g.termName)
            }
        }
        return order.compactMap { mapByTerm[$0] }.sorted { a, b in
            if let sa = a.semesterId, let sb = b.semesterId, sa != sb {
                return sa > sb
            }
            return a.termName > b.termName
        }
    }

    private func mergeExams(uniAppExams: [ExamItem], eamsExams: [ExamItem]) -> [ExamItem] {
        var map: [String: ExamItem] = [:]
        for e in eamsExams {
            map[e.id] = e
        }
        for u in uniAppExams {
            if var existing = map[u.id] {
                if (existing.place == nil || existing.place?.isEmpty == true), let p = u.place {
                    existing.place = p
                }
                if let t = u.examType, !t.isEmpty {
                    existing.examType = t
                }
                if existing.courseCode == nil {
                    existing.courseCode = u.courseCode
                }
                map[u.id] = existing
            } else {
                map[u.id] = u
            }
        }
        return map.values.sorted { $0.dateTimeString < $1.dateTimeString }
    }

    private static func isValidExamDateTime(_ str: String) -> Bool {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}~\d{2}:\d{2}$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return false }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else { return false }
        let timeParts = parts[1].split(separator: "~", omittingEmptySubsequences: false)
        guard timeParts.count == 2,
              let startMinutes = Self.examMinutes(String(timeParts[0])),
              let endMinutes = Self.examMinutes(String(timeParts[1])),
              endMinutes >= startMinutes else {
            return false
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = CourseCalendarHelper.beijingCalendar
        formatter.timeZone = CourseCalendarHelper.beijingCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        return formatter.date(from: "\(parts[0]) \(timeParts[0])") != nil
            && formatter.date(from: "\(parts[0]) \(timeParts[1])") != nil
    }

    private static func examTimeValue(_ value: Any?) -> Int? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed) {
                return value
            }
            guard let minutes = Self.examMinutes(trimmed) else { return nil }
            return (minutes / 60) * 100 + (minutes % 60)
        }
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              (0...2359).contains(doubleValue),
              doubleValue.rounded(.towardZero) == doubleValue else {
            return nil
        }
        return Int(doubleValue)
    }

    private static func examMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...2).contains(parts[0].count),
              parts[1].count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private static func isValidExamTimeValue(_ value: Int) -> Bool {
        (0..<24).contains(value / 100) && (0..<60).contains(value % 100)
    }

    private static func extractTableRows(from html: String) -> [[String]] {
        var rows: [[String]] = []
        let trPattern = #"<tr[^>]*>([\s\S]*?)</tr>"#
        let tdPattern = #"<td[^>]*>([\s\S]*?)</td>"#
        guard let trRegex = try? NSRegularExpression(pattern: trPattern, options: [.caseInsensitive]),
              let tdRegex = try? NSRegularExpression(pattern: tdPattern, options: [.caseInsensitive]) else {
            return []
        }

        let trMatches = trRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for trMatch in trMatches {
            guard let trRange = Range(trMatch.range(at: 1), in: html) else { continue }
            let rowContent = String(html[trRange])
            let tdMatches = tdRegex.matches(in: rowContent, range: NSRange(rowContent.startIndex..., in: rowContent))
            guard !tdMatches.isEmpty else { continue }

            var cells: [String] = []
            for tdMatch in tdMatches {
                if let tdRange = Range(tdMatch.range(at: 1), in: rowContent) {
                    let rawCell = String(rowContent[tdRange])
                    cells.append(stripHTML(rawCell))
                }
            }
            if !cells.isEmpty {
                rows.append(cells)
            }
        }
        return rows
    }

    private static func stripHTML(_ input: String) -> String {
        var s = input.replacingOccurrences(of: #"<br\s*/?>"#, with: " · ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let lines = s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
    }
}
