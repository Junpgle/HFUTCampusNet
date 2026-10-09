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
        let bizFinal = biz.isEmpty ? "2" : biz

        // 尝试用现有 Cookie 请求
        fetchCourseData(studentId: std, semesterId: semFinal, bizTypeId: bizFinal) { [weak self] result in
            switch result {
            case .success(let schedule):
                self?.saveSchedule(schedule)
                completion(.success(schedule))
            case .failure(let error):
                // 如果是需要登录且有保存的账号密码，尝试后台自动登录一次
                if let syncErr = error as? CourseSyncError, case .needLogin = syncErr,
                   !SettingsManager.shared.portalUsername.isEmpty,
                   !SettingsManager.shared.portalPassword.isEmpty {
                    self?.tryBackgroundLogin { loginSuccess in
                        if loginSuccess {
                            self?.fetchCourseData(studentId: std, semesterId: semFinal, bizTypeId: bizFinal) { retryResult in
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

    /// 直接使用给定数据更新课表（例如从网页提取后直接更新）
    public func fetchAndApplyFromHTML(
        html: String,
        studentId: String,
        cookies: [HTTPCookie],
        completion: @escaping (Result<CourseScheduleData, Error>) -> Void
    ) {
        // 保存 Cookie
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
            if cookie.name == "SESSION" {
                SettingsManager.shared.courseSessionCookie = cookie.value
            }
        }

        var detectedBiz = "2"
        if let match = matchRegex(pattern: #"bizTypeId\s*:\s*(\d+)"#, in: html) {
            detectedBiz = match
            SettingsManager.shared.courseBizTypeId = match
        }

        var detectedSem = String(CourseCalendarHelper.inferSemesterId())
        if let match = matchRegex(pattern: #"semesterId\s*:\s*(\d+)"#, in: html) {
            detectedSem = match
            SettingsManager.shared.courseSemesterId = match
        }

        SettingsManager.shared.courseStudentId = studentId

        fetchCourseData(studentId: studentId, semesterId: detectedSem, bizTypeId: detectedBiz) { [weak self] result in
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

        if let savedSession = SettingsManager.shared.courseSessionCookie, !savedSession.isEmpty {
            req.setValue("SESSION=\(savedSession)", forHTTPHeaderField: "Cookie")
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

        if let savedSession = SettingsManager.shared.courseSessionCookie, !savedSession.isEmpty {
            req.setValue("SESSION=\(savedSession)", forHTTPHeaderField: "Cookie")
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

    // MARK: - 后台账号自动登录辅助

    private func tryBackgroundLogin(completion: @escaping (Bool) -> Void) {
        let u = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespaces)
        let p = SettingsManager.shared.portalPassword.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !p.isEmpty else {
            completion(false)
            return
        }

        let base = "https://jxglstu.hfut.edu.cn/eams5-student"
        guard let saltURL = URL(string: "\(base)/login-salt") else {
            completion(false)
            return
        }

        var saltReq = URLRequest(url: saltURL, timeoutInterval: 10.0)
        saltReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: saltReq) { data, response, error in
            guard let data = data, let salt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !salt.isEmpty else {
                completion(false)
                return
            }

            // 提取 Set-Cookie
            if let http = response as? HTTPURLResponse, let headerFields = http.allHeaderFields as? [String: String], let url = http.url {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                for cookie in cookies where cookie.name == "SESSION" {
                    SettingsManager.shared.courseSessionCookie = cookie.value
                }
            }

            // 计算 SHA1
            let toHash = "\(salt)-\(p)"
            let sha1Pwd = CourseScheduleService.sha1Hex(toHash)

            guard let loginURL = URL(string: "\(base)/login") else {
                completion(false)
                return
            }

            var loginReq = URLRequest(url: loginURL, timeoutInterval: 10.0)
            loginReq.httpMethod = "POST"
            loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let session = SettingsManager.shared.courseSessionCookie {
                loginReq.setValue("SESSION=\(session)", forHTTPHeaderField: "Cookie")
            }

            let postBody: [String: Any] = [
                "username": u,
                "password": sha1Pwd,
                "captcha": ""
            ]
            loginReq.httpBody = try? JSONSerialization.data(withJSONObject: postBody)

            URLSession.shared.dataTask(with: loginReq) { lData, lResp, lErr in
                guard let lData = lData,
                      let json = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
                      let result = json["result"] as? Bool, result == true else {
                    completion(false)
                    return
                }

                // 登录成功，提取更新后的 SESSION
                if let http = lResp as? HTTPURLResponse, let headerFields = http.allHeaderFields as? [String: String], let url = http.url {
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                    for cookie in cookies where cookie.name == "SESSION" {
                        SettingsManager.shared.courseSessionCookie = cookie.value
                    }
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
