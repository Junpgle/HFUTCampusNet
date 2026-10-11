import Foundation
import CommonCrypto

public extension Notification.Name {
    static let courseScheduleDidUpdate = Notification.Name("CourseScheduleDidUpdateNotification")
}

public class CourseScheduleService {
    public static let shared = CourseScheduleService()

    public private(set) var currentSchedule: CourseScheduleData?

    private let fileManager = FileManager.default
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
        self.currentSchedule = schedule
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(schedule)
            try data.write(to: cacheFileURL, options: .atomic)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .courseScheduleDidUpdate, object: schedule)
            }
        } catch {
            print("⚠️ 保存课表缓存失败: \(error)")
        }
    }

    public func clearSchedule() {
        self.currentSchedule = nil
        try? fileManager.removeItem(at: cacheFileURL)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .courseScheduleDidUpdate, object: nil)
        }
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
        let std = (studentId ?? SettingsManager.shared.courseStudentId).trimmingCharacters(in: .whitespaces)
        guard !std.isEmpty else {
            completion(.failure(CourseSyncError.invalidStudentId))
            return
        }

        let sem = (semesterId ?? SettingsManager.shared.courseSemesterId).trimmingCharacters(in: .whitespaces)
        let semFinal = sem.isEmpty ? String(CourseCalendarHelper.inferSemesterId()) : sem
        let biz = (bizTypeId ?? SettingsManager.shared.courseBizTypeId).trimmingCharacters(in: .whitespaces)
        let bizFinal = (biz.isEmpty || biz == "2") ? "23" : biz

        // 尝试用现有 Cookie 请求
        fetchCourseData(studentId: std, semesterId: semFinal, bizTypeId: bizFinal) { [weak self] result in
            switch result {
            case .success(let schedule):
                self?.saveSchedule(schedule)
                completion(.success(schedule))
            case .failure(let error):
                // 如果会话过期，尝试通过已保存的 CAS TGC 或账号密码后台自动 SSO 登录教务系统
                if let syncErr = error as? CourseSyncError, case .needLogin = syncErr {
                    self?.tryBackgroundLogin { loginSuccess in
                        if loginSuccess {
                            let refreshedStd = SettingsManager.shared.courseStudentId.isEmpty ? std : SettingsManager.shared.courseStudentId
                            let refreshedSem = SettingsManager.shared.courseSemesterId.isEmpty ? semFinal : SettingsManager.shared.courseSemesterId
                            let refreshedBiz = (SettingsManager.shared.courseBizTypeId.isEmpty || SettingsManager.shared.courseBizTypeId == "2") ? "23" : SettingsManager.shared.courseBizTypeId
                            self?.fetchCourseData(studentId: refreshedStd, semesterId: refreshedSem, bizTypeId: refreshedBiz) { retryResult in
                                switch retryResult {
                                case .success(let schedule):
                                    self?.saveSchedule(schedule)
                                    completion(.success(schedule))
                                case .failure(let retryErr):
                                    completion(.failure(retryErr))
                                }
                            }
                        } else {
                            completion(.failure(CourseSyncError.needLogin))
                        }
                    }
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    /// 直接应用网页端 JS 获取到的 datum JSON 字符串并持久化保存课表
    public func applyDatumJSONString(
        _ jsonString: String,
        studentId: String,
        semesterId: String,
        bizTypeId: String
    ) throws -> CourseScheduleData {
        guard let data = jsonString.data(using: .utf8) else {
            throw CourseSyncError.invalidResponse
        }
        let parsedLessons = try CourseScheduleService.parseDatumJSON(data: data)
        if !studentId.isEmpty {
            SettingsManager.shared.courseStudentId = studentId
        }
        if !semesterId.isEmpty {
            SettingsManager.shared.courseSemesterId = semesterId
        }
        if !bizTypeId.isEmpty {
            SettingsManager.shared.courseBizTypeId = bizTypeId
        }
        let schedule = CourseScheduleData(
            studentId: studentId.isEmpty ? SettingsManager.shared.courseStudentId : studentId,
            semesterId: semesterId.isEmpty ? SettingsManager.shared.courseSemesterId : semesterId,
            semesterName: "当前学期",
            bizTypeId: bizTypeId.isEmpty ? SettingsManager.shared.courseBizTypeId : bizTypeId,
            lastSyncTime: Date(),
            lessons: parsedLessons
        )
        self.saveSchedule(schedule)
        return schedule
    }

    /// 直接使用给定数据更新课表（例如从网页提取后直接更新）
    public func fetchAndApplyFromHTML(
        html: String,
        studentId: String,
        cookies: [HTTPCookie],
        completion: @escaping (Result<CourseScheduleData, Error>) -> Void
    ) {
        // 仅保存 jxglstu.hfut.edu.cn 专属的 SESSION 与 SRVID Cookie
        if let jxCookieHeader = CourseScheduleService.extractJxglstuCookieHeader(from: cookies) {
            SettingsManager.shared.courseSessionCookie = jxCookieHeader
        }

        var detectedStd = studentId
        if let matchStd = matchRegex(pattern: #"var\s+studentId\s*=\s*(\d+)"#, in: html) {
            detectedStd = matchStd
        }
        if !detectedStd.isEmpty {
            SettingsManager.shared.courseStudentId = detectedStd
        }

        var detectedBiz = (SettingsManager.shared.courseBizTypeId.isEmpty || SettingsManager.shared.courseBizTypeId == "2") ? "23" : SettingsManager.shared.courseBizTypeId
        if let match = matchRegex(pattern: #"bizTypeId\s*:\s*(\d+)"#, in: html) {
            detectedBiz = match
            SettingsManager.shared.courseBizTypeId = match
        }

        var detectedSem = SettingsManager.shared.courseSemesterId.isEmpty ? String(CourseCalendarHelper.inferSemesterId()) : SettingsManager.shared.courseSemesterId
        if let match = matchRegex(pattern: #"'fileInfoAssoc'\s*:\s*null\s*,\s*'id'\s*:\s*(\d+)"#, in: html)
            ?? matchRegex(pattern: #"semesterId\s*:\s*(\d+)"#, in: html) {
            detectedSem = match
            SettingsManager.shared.courseSemesterId = match
        }

        fetchCourseData(studentId: detectedStd, semesterId: detectedSem, bizTypeId: detectedBiz) { [weak self] result in
            switch result {
            case .success(let schedule):
                self?.saveSchedule(schedule)
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

        if let cookieHeader = buildCookieHeader() {
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
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
                // 如果没有课程，返回空课表结构
                let emptyData = CourseScheduleData(
                    studentId: studentId,
                    semesterId: semesterId,
                    semesterName: "当前学期",
                    bizTypeId: bizTypeId,
                    lastSyncTime: Date(),
                    lessons: []
                )
                completion(.success(emptyData))
                return
            }

            // 第二步：请求 ws/schedule-table/datum 获取具体排课列表
            self?.fetchDatum(studentId: studentId, semesterId: semesterId, bizTypeId: bizTypeId, lessonIds: lessonIds, completion: completion)
        }.resume()
    }

    private func fetchDatum(
        studentId: String,
        semesterId: String,
        bizTypeId: String,
        lessonIds: [Int],
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

        if let cookieHeader = buildCookieHeader() {
            req.httpShouldHandleCookies = false
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let bodyObj: [String: Any] = [
            "lessonIds": lessonIds,
            "studentId": Int(studentId) ?? 178506,
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

            guard let data = data else {
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
            return []
        }

        let courseMap = Dictionary(uniqueKeysWithValues: lessons.map { ($0.id, $0) })

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

        return courseItems.sorted {
            if $0.dateString != $1.dateString {
                return $0.dateString < $1.dateString
            }
            return $0.startTime < $1.startTime
        }
    }

    // MARK: - 后台 CAS SSO 与账号自动登录辅助

    public func tryBackgroundLogin(completion: @escaping (Bool) -> Void) {
        // 优先使用统一身份认证 CAS TGC 票据无缝单点登录教务系统
        if let tgc = SettingsManager.shared.casTgcCookie?.trimmingCharacters(in: .whitespacesAndNewlines), !tgc.isEmpty {
            loginViaCASTgc(tgc: tgc) { [weak self] success in
                if success {
                    completion(true)
                } else {
                    self?.loginViaSaltPassword(completion: completion)
                }
            }
            return
        }
        loginViaSaltPassword(completion: completion)
    }

    /// 通过 CAS TGC Cookie 执行单点登录获取教务系统专属 SESSION + SRVID 及最新 studentId/semesterId/bizTypeId
    private func loginViaCASTgc(tgc: String, completion: @escaping (Bool) -> Void) {
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
            completion(false)
            return
        }

        var req = URLRequest(url: ssoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        ssoSession.dataTask(with: req) { [weak self] _, response, error in
            guard let self = self, error == nil,
                  let http = response as? HTTPURLResponse,
                  let finalURL = http.url?.absoluteString,
                  finalURL.contains("jxglstu.hfut.edu.cn"),
                  !finalURL.contains("cas.hfut.edu.cn/cas/login") else {
                completion(false)
                return
            }

            // 进一步请求 /for-std/course-table 以自动解析 studentId、semesterId、bizTypeId 并确认会话有效
            guard let tableURL = URL(string: "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table") else {
                completion(false)
                return
            }
            var tableReq = URLRequest(url: tableURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
            tableReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

            ssoSession.dataTask(with: tableReq) { [weak self] tData, tResp, tErr in
                guard let self = self, tErr == nil,
                      let tHttp = tResp as? HTTPURLResponse,
                      let tFinalURL = tHttp.url?.absoluteString,
                      !tFinalURL.contains("/login") else {
                    completion(false)
                    return
                }

                let allCookies = ssoSession.configuration.httpCookieStorage?.cookies ?? []
                for c in allCookies {
                    HTTPCookieStorage.shared.setCookie(c)
                }
                guard let jxCookieHeader = CourseScheduleService.extractJxglstuCookieHeader(from: allCookies) else {
                    completion(false)
                    return
                }
                SettingsManager.shared.courseSessionCookie = jxCookieHeader

                // 从重定向 URL 或 HTML 中提取 studentId、bizTypeId、semesterId
                if let stdFromURL = self.matchRegex(pattern: #"/for-std/course-table/info/(\d+)"#, in: tFinalURL) {
                    SettingsManager.shared.courseStudentId = stdFromURL
                }
                if let tData = tData, let html = String(data: tData, encoding: .utf8) {
                    if let stdFromHTML = self.matchRegex(pattern: #"var\s+studentId\s*=\s*(\d+)"#, in: html) {
                        SettingsManager.shared.courseStudentId = stdFromHTML
                    }
                    if let biz = self.matchRegex(pattern: #"bizTypeId\s*:\s*(\d+)"#, in: html) {
                        SettingsManager.shared.courseBizTypeId = biz
                    }
                    if let sem = self.matchRegex(pattern: #"'fileInfoAssoc'\s*:\s*null\s*,\s*'id'\s*:\s*(\d+)"#, in: html)
                        ?? self.matchRegex(pattern: #"semesterId\s*:\s*(\d+)"#, in: html) {
                        SettingsManager.shared.courseSemesterId = sem
                    }
                }
                completion(true)
            }.resume()
        }.resume()
    }

    private func loginViaSaltPassword(completion: @escaping (Bool) -> Void) {
        let u = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespaces)
        let casP = SettingsManager.shared.casPassword.trimmingCharacters(in: .whitespaces)
        let p = casP.isEmpty ? SettingsManager.shared.portalPassword.trimmingCharacters(in: .whitespaces) : casP
        guard !u.isEmpty, !p.isEmpty else {
            completion(false)
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config)

        let base = "http://jxglstu.hfut.edu.cn/eams5-student"
        guard let saltURL = URL(string: "\(base)/login-salt") else {
            completion(false)
            return
        }

        var saltReq = URLRequest(url: saltURL, timeoutInterval: 10.0)
        saltReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: saltReq) { data, _, _ in
            guard let data = data, let salt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !salt.isEmpty else {
                completion(false)
                return
            }

            let toHash = "\(salt)-\(p)"
            let sha1Pwd = CourseScheduleService.sha1Hex(toHash)

            guard let loginURL = URL(string: "\(base)/login") else {
                completion(false)
                return
            }

            var loginReq = URLRequest(url: loginURL, timeoutInterval: 10.0)
            loginReq.httpMethod = "POST"
            loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let postBody: [String: Any] = [
                "username": u,
                "password": sha1Pwd,
                "captcha": ""
            ]
            loginReq.httpBody = try? JSONSerialization.data(withJSONObject: postBody)

            session.dataTask(with: loginReq) { lData, _, _ in
                guard let lData = lData,
                      let json = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
                      let result = json["result"] as? Bool, result == true else {
                    completion(false)
                    return
                }

                let allCookies = session.configuration.httpCookieStorage?.cookies ?? []
                if let jxCookieHeader = CourseScheduleService.extractJxglstuCookieHeader(from: allCookies) {
                    SettingsManager.shared.courseSessionCookie = jxCookieHeader
                }
                completion(true)
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
