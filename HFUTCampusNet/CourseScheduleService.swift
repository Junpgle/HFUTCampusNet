import Foundation
import CommonCrypto

public extension Notification.Name {
    static let courseScheduleDidUpdate = Notification.Name("CourseScheduleDidUpdateNotification")
}

public class CourseScheduleService {
    public static let shared = CourseScheduleService()

    public private(set) var currentSchedule: CourseScheduleData?

    private let stateLock = NSLock()
    private var scheduleGeneration = 0
    private let fileManager = FileManager.default

    public var cacheGenerationToken: Int {
        currentScheduleGeneration()
    }

    /// Starts a schedule update and invalidates results from older requests.
    @discardableResult
    public func beginScheduleUpdate() -> Int {
        stateLock.lock()
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        stateLock.unlock()
        return generation
    }

    private var cacheFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("cn.edu.hfut.campusnet.monitor", isDirectory: true)
        if !fileManager.fileExists(atPath: appDir.path) {
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir.appendingPathComponent("course_schedule.json")
    }

    private init() {
        loadLocalSchedule()
    }

    // MARK: - 本地持久化缓存

    public func loadLocalSchedule() {
        guard fileManager.fileExists(atPath: cacheFileURL.path),
              let data = try? Data(contentsOf: cacheFileURL) else {
            return
        }
        do {
            let decoder = JSONDecoder()
            let schedule = try decoder.decode(CourseScheduleData.self, from: data)
            self.currentSchedule = schedule
        } catch {
            print("⚠️ 读取本地课表缓存失败: \(error)")
        }
    }

    public func saveSchedule(_ schedule: CourseScheduleData) {
        _ = saveSchedule(schedule, generation: beginScheduleUpdate())
    }

    @discardableResult
    private func saveSchedule(
        _ schedule: CourseScheduleData,
        generation: Int,
        metadataUpdate: (() -> Void)? = nil
    ) -> Bool {
        stateLock.lock()
        guard scheduleGeneration == generation else {
            stateLock.unlock()
            return false
        }
        metadataUpdate?()
        currentSchedule = schedule

        var shouldNotify = false
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(schedule)
            try data.write(to: cacheFileURL, options: .atomic)
            shouldNotify = true
        } catch {
            print("⚠️ 保存课表缓存失败: \(error)")
        }
        stateLock.unlock()
        if shouldNotify {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentScheduleGeneration(generation) else { return }
                NotificationCenter.default.post(name: .courseScheduleDidUpdate, object: schedule)
            }
        }
        return true
    }

    public func clearSchedule() {
        stateLock.lock()
        scheduleGeneration &+= 1
        self.currentSchedule = nil
        try? fileManager.removeItem(at: cacheFileURL)
        stateLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .courseScheduleDidUpdate, object: nil)
        }
    }

    private func currentScheduleGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return scheduleGeneration
    }

    private func isCurrentScheduleGeneration(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return scheduleGeneration == generation
    }

    private func saveDiscoveredCourseMetadata(
        cookieHeader: String,
        studentId: String?,
        semesterId: String?,
        bizTypeId: String?,
        cookies: [HTTPCookie],
        generation: Int
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard scheduleGeneration == generation else { return false }

        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        SettingsManager.shared.courseSessionCookie = cookieHeader
        if let studentId, !studentId.isEmpty {
            SettingsManager.shared.courseStudentId = studentId
        }
        if let semesterId, !semesterId.isEmpty,
           !SettingsManager.shared.courseSemesterIdManuallySelected {
            SettingsManager.shared.courseSemesterId = semesterId
        }
        if let bizTypeId, !bizTypeId.isEmpty {
            SettingsManager.shared.courseBizTypeId = bizTypeId
        }
        return true
    }

    private static func staleScheduleCancellation() -> NSError {
        NSError(domain: "CourseScheduleService", code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "课表状态已更新，本次过期请求已取消"])
    }

    // MARK: - 网络同步接口

    public enum CourseSyncError: LocalizedError {
        case needLogin
        case invalidStudentId
        case invalidResponse
        case networkError(String)
        case emptySchedule

        public var errorDescription: String? {
            switch self {
            case .needLogin:
                return "教务系统会话已过期，请在网页中登录授权"
            case .invalidStudentId:
                return "无效的学生课表编号 (stdId)"
            case .invalidResponse:
                return "教务系统响应异常或无法解析课表数据"
            case .networkError(let msg):
                return "网络请求失败: \(msg)"
            case .emptySchedule:
                return "未获取到本学期的课程安排"
            }
        }
    }

    /// 从 Cookie 列表中仅提取教务系统 (jxglstu.hfut.edu.cn) 的专属 Cookie (包含 SESSION 与负载均衡粘性 Cookie SRVID)
    public static func extractJxglstuCookieHeader(from cookies: [HTTPCookie]) -> String? {
        var sessionVal: String?
        var srvidVal: String?
        for cookie in cookies {
            let dom = cookie.domain.lowercased()
            // 严格匹配 jxglstu 域名（或路径为 /eams5-student），绝不混入 cas.hfut.edu.cn / one.hfut.edu.cn 的同名 SESSION
            if dom.contains("jxglstu") || cookie.path.contains("eams5-student") {
                if cookie.name == "SESSION" {
                    sessionVal = cookie.value
                } else if cookie.name == "SRVID" {
                    srvidVal = cookie.value
                }
            } else if dom.isEmpty && cookie.name == "SRVID" {
                srvidVal = cookie.value
            }
        }
        guard let s = sessionVal, !s.isEmpty else { return nil }
        if let srv = srvidVal, !srv.isEmpty {
            return "SESSION=\(s); SRVID=\(srv)"
        }
        return "SESSION=\(s)"
    }

    /// 构造请求使用的 Cookie Header 字符串
    private func buildCookieHeader() -> String? {
        guard let saved = SettingsManager.shared.courseSessionCookie?.trimmingCharacters(in: .whitespacesAndNewlines),
              !saved.isEmpty else {
            return nil
        }
        if saved.contains("SESSION=") {
            return saved
        }
        return "SESSION=\(saved)"
    }

    /// 同步课表
    public func syncSchedule(
        studentId: String? = nil,
        semesterId: String? = nil,
        bizTypeId: String? = nil,
        completion: @escaping (Result<CourseScheduleData, Error>) -> Void
    ) {
        let generation = beginScheduleUpdate()
        let finish: (Result<CourseScheduleData, Error>) -> Void = { [weak self] result in
            guard let self else {
                completion(result)
                return
            }
            guard self.isCurrentScheduleGeneration(generation) else {
                completion(.failure(Self.staleScheduleCancellation()))
                return
            }
            if case .success(let schedule) = result,
               !self.saveSchedule(schedule, generation: generation) {
                completion(.failure(Self.staleScheduleCancellation()))
                return
            }
            completion(result)
        }

        let sem = (semesterId ?? SettingsManager.shared.courseSemesterId).trimmingCharacters(in: .whitespaces)
        let semFinal = sem.isEmpty ? String(CourseCalendarHelper.inferSemesterId()) : sem
        let preserveSelectedSemester = semesterId != nil || SettingsManager.shared.courseSemesterIdManuallySelected
        let biz = (bizTypeId ?? SettingsManager.shared.courseBizTypeId).trimmingCharacters(in: .whitespaces)
        let bizFinal = (biz.isEmpty || biz == "2") ? "23" : biz

        let std = (studentId ?? SettingsManager.shared.courseStudentId).trimmingCharacters(in: .whitespaces)
        if std.isEmpty {
            // 若尚未获取过学生 ID，先尝试通过统一身份认证自动后台登录教务系统并提取当前登录学生的 stdId
            tryBackgroundLogin(generation: generation) { [weak self] loginSuccess in
                guard let self = self else { return }
                guard self.isCurrentScheduleGeneration(generation) else {
                    finish(.failure(Self.staleScheduleCancellation()))
                    return
                }
                let discoveredStd = SettingsManager.shared.courseStudentId.trimmingCharacters(in: .whitespaces)
                guard loginSuccess, !discoveredStd.isEmpty else {
                    finish(.failure(CourseSyncError.needLogin))
                    return
                }
                let refreshedBiz = (SettingsManager.shared.courseBizTypeId.isEmpty || SettingsManager.shared.courseBizTypeId == "2") ? "23" : SettingsManager.shared.courseBizTypeId
                let refreshedSem = preserveSelectedSemester ? semFinal : SettingsManager.shared.courseSemesterId
                self.fetchCourseData(studentId: discoveredStd, semesterId: refreshedSem, bizTypeId: refreshedBiz) { retryResult in
                    switch retryResult {
                    case .success(let schedule):
                        finish(.success(schedule))
                    case .failure(let retryErr):
                        finish(.failure(retryErr))
                    }
                }
            }
            return
        }

        // 尝试用现有 Cookie 请求
        fetchCourseData(studentId: std, semesterId: semFinal, bizTypeId: bizFinal) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentScheduleGeneration(generation) else {
                finish(.failure(Self.staleScheduleCancellation()))
                return
            }
            switch result {
            case .success(let schedule):
                finish(.success(schedule))
            case .failure(let error):
                // 如果会话过期或返回空课程列表，尝试后台自动 SSO 登录后按本次选定的学期重试
                if let syncErr = error as? CourseSyncError,
                   case .needLogin = syncErr {
                    self.tryBackgroundLogin(generation: generation) { loginSuccess in
                        guard self.isCurrentScheduleGeneration(generation) else {
                            finish(.failure(Self.staleScheduleCancellation()))
                            return
                        }
                        if loginSuccess {
                            let refreshedStd = SettingsManager.shared.courseStudentId.isEmpty ? std : SettingsManager.shared.courseStudentId
                            let refreshedBiz = (SettingsManager.shared.courseBizTypeId.isEmpty || SettingsManager.shared.courseBizTypeId == "2") ? "23" : SettingsManager.shared.courseBizTypeId
                            let refreshedSem = preserveSelectedSemester ? semFinal : SettingsManager.shared.courseSemesterId
                            self.fetchCourseData(studentId: refreshedStd, semesterId: refreshedSem, bizTypeId: refreshedBiz) { retryResult in
                                switch retryResult {
                                case .success(let schedule):
                                    finish(.success(schedule))
                                case .failure(let retryErr):
                                    finish(.failure(retryErr))
                                }
                            }
                        } else {
                            finish(.failure(CourseSyncError.needLogin))
                        }
                    }
                } else if let syncErr = error as? CourseSyncError,
                          case .emptySchedule = syncErr {
                    self.tryBackgroundLogin(generation: generation) { loginSuccess in
                        guard self.isCurrentScheduleGeneration(generation) else {
                            finish(.failure(Self.staleScheduleCancellation()))
                            return
                        }
                        if loginSuccess {
                            let refreshedStd = SettingsManager.shared.courseStudentId.isEmpty ? std : SettingsManager.shared.courseStudentId
                            let refreshedBiz = (SettingsManager.shared.courseBizTypeId.isEmpty || SettingsManager.shared.courseBizTypeId == "2") ? "23" : SettingsManager.shared.courseBizTypeId
                            let refreshedSem = preserveSelectedSemester ? semFinal : SettingsManager.shared.courseSemesterId
                            self.fetchCourseData(studentId: refreshedStd, semesterId: refreshedSem, bizTypeId: refreshedBiz) { retryResult in
                                switch retryResult {
                                case .success(let schedule):
                                    finish(.success(schedule))
                                case .failure(let retryErr):
                                    finish(.failure(retryErr))
                                }
                            }
                        } else {
                            finish(.failure(CourseSyncError.emptySchedule))
                        }
                    }
                } else {
                    finish(.failure(error))
                }
            }
        }
    }

    /// 直接应用网页端 JS 获取到的 datum JSON 字符串并持久化保存课表
    public func applyDatumJSONString(
        _ jsonString: String,
        studentId: String,
        semesterId: String,
        bizTypeId: String,
        cookieHeader: String? = nil,
        casTgcCookie: String? = nil,
        expectedGeneration: Int? = nil
    ) throws -> CourseScheduleData {
        let generation = expectedGeneration ?? beginScheduleUpdate()
        guard isCurrentScheduleGeneration(generation) else {
            throw Self.staleScheduleCancellation()
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw CourseSyncError.invalidResponse
        }
        let parsedLessons = try CourseScheduleService.parseDatumJSON(data: data)
        let schedule = CourseScheduleData(
            studentId: studentId.isEmpty ? SettingsManager.shared.courseStudentId : studentId,
            semesterId: semesterId.isEmpty ? SettingsManager.shared.courseSemesterId : semesterId,
            semesterName: "当前学期",
            bizTypeId: bizTypeId.isEmpty ? SettingsManager.shared.courseBizTypeId : bizTypeId,
            lastSyncTime: Date(),
            lessons: parsedLessons
        )
        guard saveSchedule(schedule, generation: generation, metadataUpdate: {
            if !studentId.isEmpty {
                SettingsManager.shared.courseStudentId = studentId
            }
            if !semesterId.isEmpty, !SettingsManager.shared.courseSemesterIdManuallySelected {
                SettingsManager.shared.courseSemesterId = semesterId
            }
            if !bizTypeId.isEmpty {
                SettingsManager.shared.courseBizTypeId = bizTypeId
            }
            if let cookieHeader, !cookieHeader.isEmpty {
                SettingsManager.shared.courseSessionCookie = cookieHeader
            }
            if let casTgcCookie, !casTgcCookie.isEmpty {
                SettingsManager.shared.casTgcCookie = casTgcCookie
            }
        }) else {
            throw Self.staleScheduleCancellation()
        }
        return schedule
    }

    /// 直接使用给定数据更新课表（例如从网页提取后直接更新）
    public func fetchAndApplyFromHTML(
        html: String,
        studentId: String,
        cookies: [HTTPCookie],
        casTgcCookie: String? = nil,
        expectedGeneration: Int? = nil,
        completion: @escaping (Result<CourseScheduleData, Error>) -> Void
    ) {
        let generation = expectedGeneration ?? beginScheduleUpdate()
        guard isCurrentScheduleGeneration(generation) else {
            completion(.failure(Self.staleScheduleCancellation()))
            return
        }
        // 仅保存 jxglstu.hfut.edu.cn 专属的 SESSION 与 SRVID Cookie
        let jxCookieHeader = CourseScheduleService.extractJxglstuCookieHeader(from: cookies)

        var detectedStd = studentId
        if let matchStd = matchRegex(pattern: #"var\s+studentId\s*=\s*(\d+)"#, in: html) {
            detectedStd = matchStd
        }

        var detectedBiz = (SettingsManager.shared.courseBizTypeId.isEmpty || SettingsManager.shared.courseBizTypeId == "2") ? "23" : SettingsManager.shared.courseBizTypeId
        if let match = matchRegex(pattern: #"bizTypeId\s*:\s*(\d+)"#, in: html) {
            detectedBiz = match
        }

        var detectedSem = SettingsManager.shared.courseSemesterId.isEmpty ? String(CourseCalendarHelper.inferSemesterId()) : SettingsManager.shared.courseSemesterId
        if !SettingsManager.shared.courseSemesterIdManuallySelected,
           let match = matchRegex(pattern: #"'fileInfoAssoc'\s*:\s*null\s*,\s*'id'\s*:\s*(\d+)"#, in: html)
            ?? matchRegex(pattern: #"semesterId\s*:\s*(\d+)"#, in: html) {
            detectedSem = match
        }

        fetchCourseData(
            studentId: detectedStd,
            semesterId: detectedSem,
            bizTypeId: detectedBiz,
            cookieHeader: jxCookieHeader
        ) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentScheduleGeneration(generation) else {
                completion(.failure(Self.staleScheduleCancellation()))
                return
            }
            switch result {
            case .success(let schedule):
                guard self.saveSchedule(schedule, generation: generation, metadataUpdate: {
                    if let jxCookieHeader, !jxCookieHeader.isEmpty {
                        SettingsManager.shared.courseSessionCookie = jxCookieHeader
                    }
                    if !detectedStd.isEmpty {
                        SettingsManager.shared.courseStudentId = detectedStd
                    }
                    if !detectedSem.isEmpty, !SettingsManager.shared.courseSemesterIdManuallySelected {
                        SettingsManager.shared.courseSemesterId = detectedSem
                    }
                    if !detectedBiz.isEmpty {
                        SettingsManager.shared.courseBizTypeId = detectedBiz
                    }
                    if let casTgcCookie, !casTgcCookie.isEmpty {
                        SettingsManager.shared.casTgcCookie = casTgcCookie
                    }
                }) else {
                    completion(.failure(Self.staleScheduleCancellation()))
                    return
                }
                completion(.success(schedule))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - 内部数据请求与解析

    private func fetchCourseData(
        studentId: String,
        semesterId: String,
        bizTypeId: String,
        cookieHeader: String? = nil,
        completion: @escaping (Result<CourseScheduleData, Error>) -> Void
    ) {
        let base = "http://jxglstu.hfut.edu.cn/eams5-student"
        guard let getDataURL = URL(string: "\(base)/for-std/course-table/get-data?bizTypeId=\(bizTypeId)&semesterId=\(semesterId)&dataId=\(studentId)") else {
            completion(.failure(CourseSyncError.invalidResponse))
            return
        }

        var req = URLRequest(url: getDataURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")

        let requestCookieHeader = cookieHeader ?? buildCookieHeader()
        if let requestCookieHeader {
            req.httpShouldHandleCookies = false
            req.setValue(requestCookieHeader, forHTTPHeaderField: "Cookie")
        }

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(CourseSyncError.networkError(error.localizedDescription)))
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.failure(CourseSyncError.invalidResponse))
                return
            }

            // 检查重定向到登录页
            if let finalURL = http.url?.absoluteString, finalURL.contains("/login") || http.statusCode == 302 || http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(CourseSyncError.needLogin))
                return
            }

            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                completion(.failure(CourseSyncError.invalidResponse))
                return
            }

            if text.contains("login") && text.contains("html") {
                completion(.failure(CourseSyncError.needLogin))
                return
            }

            // 解析 lessonIds
            struct GetDataResponse: Decodable {
                let lessonIds: [Int]?
            }

            let lessonIds: [Int]
            do {
                let decoded = try JSONDecoder().decode(GetDataResponse.self, from: data)
                lessonIds = decoded.lessonIds ?? []
            } catch {
                completion(.failure(CourseSyncError.invalidResponse))
                return
            }

            guard !lessonIds.isEmpty else {
                completion(.failure(CourseSyncError.emptySchedule))
                return
            }

            // 第二步：请求 ws/schedule-table/datum 获取具体排课列表
            self?.fetchDatum(
                studentId: studentId,
                semesterId: semesterId,
                bizTypeId: bizTypeId,
                lessonIds: lessonIds,
                cookieHeader: requestCookieHeader,
                completion: completion
            )
        }.resume()
    }

    private func fetchDatum(
        studentId: String,
        semesterId: String,
        bizTypeId: String,
        lessonIds: [Int],
        cookieHeader: String? = nil,
        completion: @escaping (Result<CourseScheduleData, Error>) -> Void
    ) {
        let base = "http://jxglstu.hfut.edu.cn/eams5-student"
        guard let datumURL = URL(string: "\(base)/ws/schedule-table/datum") else {
            completion(.failure(CourseSyncError.invalidResponse))
            return
        }

        var req = URLRequest(url: datumURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)
        req.httpMethod = "POST"
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let requestCookieHeader = cookieHeader ?? buildCookieHeader()
        if let requestCookieHeader {
            req.httpShouldHandleCookies = false
            req.setValue(requestCookieHeader, forHTTPHeaderField: "Cookie")
        }

        guard let stdInt = Int(studentId) else {
            completion(.failure(CourseSyncError.invalidStudentId))
            return
        }

        let bodyObj: [String: Any] = [
            "lessonIds": lessonIds,
            "studentId": stdInt,
            "weekIndex": ""
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyObj) else {
            completion(.failure(CourseSyncError.invalidResponse))
            return
        }
        req.httpBody = bodyData

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(CourseSyncError.networkError(error.localizedDescription)))
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.failure(CourseSyncError.invalidResponse))
                return
            }

            if let finalURL = http.url?.absoluteString, finalURL.contains("/login") || http.statusCode == 302 || http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(CourseSyncError.needLogin))
                return
            }

            guard http.statusCode == 200, let data = data else {
                completion(.failure(CourseSyncError.invalidResponse))
                return
            }

            // 解析 Datum
            do {
                let parsedLessons = try CourseScheduleService.parseDatumJSON(data: data)
                let schedule = CourseScheduleData(
                    studentId: studentId,
                    semesterId: semesterId,
                    semesterName: "当前学期",
                    bizTypeId: bizTypeId,
                    lastSyncTime: Date(),
                    lessons: parsedLessons
                )
                completion(.success(schedule))
            } catch let syncError as CourseSyncError {
                completion(.failure(syncError))
            } catch {
                completion(.failure(CourseSyncError.invalidResponse))
            }
        }.resume()
    }

    /// 解析 datum 返回的 JSON 数据
    public static func parseDatumJSON(data: Data) throws -> [CourseLesson] {
        struct DatumRoot: Decodable {
            let result: DatumResult?
        }
        struct DatumResult: Decodable {
            let lessonList: [RawCourse]?
            let scheduleList: [RawSlot]?
        }
        struct RawCourse: Decodable {
            let id: String
            let courseName: String
            let code: String?

            enum CodingKeys: String, CodingKey {
                case id, courseName, code
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let str = try? c.decode(String.self, forKey: .id) {
                    id = str
                } else if let num = try? c.decode(Int.self, forKey: .id) {
                    id = String(num)
                } else {
                    id = ""
                }
                courseName = (try? c.decode(String.self, forKey: .courseName)) ?? "未命名课程"
                code = try? c.decode(String.self, forKey: .code)
            }
        }
        struct RawRoom: Decodable {
            let nameZh: String?
        }
        struct RawSlot: Decodable {
            let lessonId: Int
            let room: RawRoom?
            let personName: String?
            let weekIndex: Int?
            let weekday: Int?
            let startTime: Int
            let endTime: Int
            let date: String
        }

        let root = try JSONDecoder().decode(DatumRoot.self, from: data)
        guard let result = root.result,
              let lessons = result.lessonList,
              let schedules = result.scheduleList else {
            throw CourseSyncError.invalidResponse
        }

        var courseMap: [String: RawCourse] = [:]
        for lesson in lessons {
            let courseId = lesson.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !courseId.isEmpty, courseMap[courseId] == nil else { continue }
            courseMap[courseId] = lesson
        }

        var courseItems: [CourseLesson] = []

        for (idx, slot) in schedules.enumerated() {
            let course = courseMap[String(slot.lessonId)]
            let name = course?.courseName ?? "课程 \(slot.lessonId)"
            let code = course?.code

            // 计算星期几
            let weekday: Int
            if let w = slot.weekday, (1...7).contains(w) {
                weekday = w
            } else if let d = CourseCalendarHelper.parseDate(slot.date, "00:00") {
                weekday = CourseCalendarHelper.weekday(from: d)
            } else {
                weekday = 1
            }

            let item = CourseLesson(
                id: "\(slot.lessonId)-\(slot.date)-\(slot.startTime)-\(idx)",
                lessonId: slot.lessonId,
                courseName: name,
                courseCode: code,
                teacher: slot.personName,
                classroom: slot.room?.nameZh,
                dateString: slot.date,
                startTime: slot.startTime,
                endTime: slot.endTime,
                weekIndex: slot.weekIndex,
                weekday: weekday
            )
            courseItems.append(item)
        }

        guard !courseItems.isEmpty else {
            throw CourseSyncError.emptySchedule
        }

        return courseItems.sorted {
            if $0.dateString != $1.dateString {
                return $0.dateString < $1.dateString
            }
            return $0.startTime < $1.startTime
        }
    }

    // MARK: - 后台 CAS SSO 与账号自动登录辅助

    public func tryBackgroundLogin(completion: @escaping (Bool) -> Void) {
        tryBackgroundLogin(generation: currentScheduleGeneration(), completion: completion)
    }

    private func tryBackgroundLogin(generation: Int, completion: @escaping (Bool) -> Void) {
        guard isCurrentScheduleGeneration(generation) else {
            completion(false)
            return
        }

        // 优先使用统一身份认证 CAS TGC 票据无缝单点登录教务系统
        if let tgc = SettingsManager.shared.casTgcCookie?.trimmingCharacters(in: .whitespacesAndNewlines), !tgc.isEmpty {
            loginViaCASTgc(tgc: tgc, generation: generation) { [weak self] success in
                guard let self, self.isCurrentScheduleGeneration(generation) else {
                    completion(false)
                    return
                }
                if success {
                    completion(true)
                } else {
                    self.loginViaSaltPassword(generation: generation, completion: completion)
                }
            }
            return
        }
        loginViaSaltPassword(generation: generation, completion: completion)
    }

    /// 在已建立教务会话的 URLSession 中请求 /for-std/course-table，自动提取 SESSION/SRVID 与 studentId/semesterId/bizTypeId
    private func discoverCourseTableMetadata(
        using session: URLSession,
        generation: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard isCurrentScheduleGeneration(generation) else {
            completion(false)
            return
        }
        guard let tableURL = URL(string: "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table") else {
            completion(false)
            return
        }
        var tableReq = URLRequest(url: tableURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        tableReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: tableReq) { [weak self] tData, tResp, tErr in
            guard let self = self,
                  self.isCurrentScheduleGeneration(generation),
                  tErr == nil,
                  let tHttp = tResp as? HTTPURLResponse,
                  let tFinalURL = tHttp.url?.absoluteString,
                  !tFinalURL.contains("/login") else {
                completion(false)
                return
            }

            let allCookies = session.configuration.httpCookieStorage?.cookies ?? []
            guard let jxCookieHeader = CourseScheduleService.extractJxglstuCookieHeader(from: allCookies) else {
                completion(false)
                return
            }

            // 从重定向 URL 或 HTML 中提取 studentId、semesterId、bizTypeId
            var studentId: String?
            var discoveredSemesterId: String?
            var discoveredBizTypeId: String?
            if let stdFromURL = self.matchRegex(pattern: #"/for-std/course-table/info/(\d+)"#, in: tFinalURL) {
                studentId = stdFromURL
            }
            if let tData = tData, let html = String(data: tData, encoding: .utf8) {
                if let stdFromHTML = self.matchRegex(pattern: #"var\s+studentId\s*=\s*(\d+)"#, in: html) {
                    studentId = stdFromHTML
                }
                if let biz = self.matchRegex(pattern: #"bizTypeId\s*:\s*(\d+)"#, in: html) {
                    discoveredBizTypeId = biz
                }
                if let sem = self.matchRegex(pattern: #"'fileInfoAssoc'\s*:\s*null\s*,\s*'id'\s*:\s*(\d+)"#, in: html)
                    ?? self.matchRegex(pattern: #"semesterId\s*:\s*(\d+)"#, in: html) {
                    discoveredSemesterId = sem
                }
            }
            guard self.saveDiscoveredCourseMetadata(
                cookieHeader: jxCookieHeader,
                studentId: studentId,
                semesterId: discoveredSemesterId,
                bizTypeId: discoveredBizTypeId,
                cookies: allCookies,
                generation: generation
            ) else {
                completion(false)
                return
            }
            completion(true)
        }.resume()
    }

    /// 通过 CAS TGC Cookie 执行单点登录获取教务系统专属 SESSION + SRVID 及最新 studentId/semesterId/bizTypeId
    private func loginViaCASTgc(tgc: String, generation: Int, completion: @escaping (Bool) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true

        if let c1 = HTTPCookie(properties: [
            .domain: "cas.hfut.edu.cn",
            .path: "/",
            .name: "CASTGC",
            .value: tgc
        ]) {
            config.httpCookieStorage?.setCookie(c1)
        }
        if let c2 = HTTPCookie(properties: [
            .domain: "cas.hfut.edu.cn",
            .path: "/cas",
            .name: "TGC",
            .value: tgc
        ]) {
            config.httpCookieStorage?.setCookie(c2)
        }

        let ssoSession = URLSession(configuration: config)
        guard let ssoURL = URL(string: "https://cas.hfut.edu.cn/cas/login?service=http%3A%2F%2Fjxglstu.hfut.edu.cn%2Feams5-student%2Fneusoft-sso%2Flogin") else {
            ssoSession.finishTasksAndInvalidate()
            completion(false)
            return
        }

        var req = URLRequest(url: ssoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        ssoSession.dataTask(with: req) { [weak self] _, response, error in
            let finalURL = (response as? HTTPURLResponse)?.url
            guard let self = self,
                  self.isCurrentScheduleGeneration(generation),
                  error == nil,
                  let finalURL,
                  ["http", "https"].contains(finalURL.scheme?.lowercased() ?? ""),
                  finalURL.host?.lowercased() == "jxglstu.hfut.edu.cn",
                  finalURL.path == "/eams5-student" || finalURL.path.hasPrefix("/eams5-student/") else {
                ssoSession.finishTasksAndInvalidate()
                completion(false)
                return
            }

            self.discoverCourseTableMetadata(using: ssoSession, generation: generation) { ok in
                ssoSession.finishTasksAndInvalidate()
                completion(ok)
            }
        }.resume()
    }

    private func loginViaSaltPassword(generation: Int, completion: @escaping (Bool) -> Void) {
        let u = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespaces)
        var candidates: [String] = []
        if let defaultPwd = SettingsManager.shared.jxglstuDefaultPasswordCache?.trimmingCharacters(in: .whitespacesAndNewlines), !defaultPwd.isEmpty {
            candidates.append(defaultPwd)
        }
        let casP = SettingsManager.shared.casPassword.trimmingCharacters(in: .whitespaces)
        if !casP.isEmpty && !candidates.contains(casP) {
            candidates.append(casP)
        }
        let portalP = SettingsManager.shared.portalPassword.trimmingCharacters(in: .whitespaces)
        if !portalP.isEmpty && !candidates.contains(portalP) {
            candidates.append(portalP)
        }
        guard !u.isEmpty, !candidates.isEmpty else {
            completion(false)
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config)

        trySaltPasswordSequential(using: session, username: u, passwords: candidates, index: 0, generation: generation) { ok in
            session.finishTasksAndInvalidate()
            completion(ok)
        }
    }

    private func trySaltPasswordSequential(
        using session: URLSession,
        username: String,
        passwords: [String],
        index: Int,
        generation: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard isCurrentScheduleGeneration(generation) else {
            completion(false)
            return
        }
        guard index < passwords.count else {
            completion(false)
            return
        }
        let p = passwords[index]
        let base = "http://jxglstu.hfut.edu.cn/eams5-student"
        guard let saltURL = URL(string: "\(base)/login-salt") else {
            completion(false)
            return
        }

        var saltReq = URLRequest(url: saltURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        saltReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: saltReq) { [weak self] data, _, _ in
            guard let self = self,
                  self.isCurrentScheduleGeneration(generation),
                  let data = data,
                  let salt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !salt.isEmpty else {
                completion(false)
                return
            }

            let toHash = "\(salt)-\(p)"
            let sha1Pwd = CourseScheduleService.sha1Hex(toHash)

            guard let loginURL = URL(string: "\(base)/login") else {
                completion(false)
                return
            }

            var loginReq = URLRequest(url: loginURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
            loginReq.httpMethod = "POST"
            loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let postBody: [String: Any] = [
                "username": username,
                "password": sha1Pwd,
                "captcha": ""
            ]
            loginReq.httpBody = try? JSONSerialization.data(withJSONObject: postBody)

            session.dataTask(with: loginReq) { [weak self] lData, _, _ in
                guard let self = self, self.isCurrentScheduleGeneration(generation) else {
                    completion(false)
                    return
                }
                if let lData = lData,
                   let json = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
                   let result = json["result"] as? Bool, result == true {
                    // 登录成功后进一步访问 /for-std/course-table 以自动获取 SESSION、SRVID、studentId、semesterId
                    self.discoverCourseTableMetadata(using: session, generation: generation, completion: completion)
                } else {
                    self.trySaltPasswordSequential(
                        using: session,
                        username: username,
                        passwords: passwords,
                        index: index + 1,
                        generation: generation,
                        completion: completion
                    )
                }
            }.resume()
        }.resume()
    }

    private func matchRegex(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func sha1Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
