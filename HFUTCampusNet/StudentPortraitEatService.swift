import Foundation
import AppKit

public struct StudentPortraitEatPlace: Codable, Equatable, Identifiable {
    public var id: String { place }
    public var place: String
    public var amountRMB: Double

    public init(place: String, amountRMB: Double) {
        self.place = place
        self.amountRMB = amountRMB
    }
}

public struct StudentPortraitAnnualSpend: Codable, Equatable, Identifiable {
    public var id: String { academicYear }
    public var academicYear: String
    public var personalRMB: Double
    public var campusAverageRMB: Double
}

public struct StudentPortraitEatFrequency: Codable, Equatable, Identifiable {
    public var id: String { place }
    public var place: String
    public var count: Int
}

public struct StudentPortraitEatDaySummary: Codable, Equatable {
    public var personalFirstTime: String
    public var personalFirstPlace: String
    public var personalMealCount: Int
    public var campusFirstTime: String
    public var campusFirstPlace: String
    public var campusMealCount: Int
}

public struct StudentPortraitEatAverage: Codable, Equatable {
    public var personalYearRMB: Double
    public var campusYearRMB: Double
    public var personalMonthRMB: Double
    public var campusMonthRMB: Double
    public var personalDayRMB: Double
    public var campusDayRMB: Double
}

public struct StudentPortraitYearAverage: Codable, Equatable, Identifiable {
    public var id: String { academicYear }
    public var academicYear: String
    public var average: StudentPortraitEatAverage
}

public struct StudentPortraitGPAPoint: Codable, Equatable, Identifiable {
    public var id: String { semester }
    public var semester: String        // xq, e.g. "2024-2025-1"
    public var gpa: Double             // jd, e.g. 3.73
    public var averageGPA: Double      // avgJd, e.g. 2.95
    public var credits: Double         // xf, e.g. 63.5
    public var totalCredits: Double    // totalFx, e.g. 165
}

public struct StudentPortraitCourseTypeStat: Codable, Equatable, Identifiable {
    public var id: String { categoryName }
    public var categoryName: String    // mc, e.g. "专业必修课"
    public var averageScore: Double    // pjf
    public var highestScore: Double    // zgf
    public var lowestScore: Double     // zdf
    public var highestCourse: String   // zgkcmc
    public var lowestCourse: String    // zdkcmc
}

public struct StudentPortraitSecondClass: Codable, Equatable {
    public var techInnovationStars: Int      // kjcxxj (科技创新)
    public var sportsFitnessStars: Int       // tyjsxj (体育健身)
    public var laborPracticeStars: Int       // ldsjxj (劳动实践)
    public var publicWelfareStars: Int       // gyfwxj (公益服务)
    public var socialPracticeStars: Int      // shsjxj (社会实践)
    public var artsCultureStars: Int         // wyhdxj (文娱活动)
    public var skillsProjectStars: Int       // jnxmxj (技能项目)
    public var ideologicalStars: Int         // szxxxj (思政学习)
    public var requiredLevel: Int            // bxdj (必修等级)
    public var electiveLevel: Int            // xxdj (选修等级)
}

public struct StudentPortraitCourseExtremes: Codable, Equatable {
    public var highestScore: Double          // zgf
    public var highestCourseName: String     // zgkcmc
    public var lowestScore: Double           // zdf
    public var lowestCourseName: String      // zdkcmc
}

public struct StudentPortraitVirtueWelfare: Codable, Equatable, Identifiable {
    public var id: String { organization }
    public var organization: String // zzmc
    public var hours: Double         // myfwsc
}

public struct StudentPortraitVirtueCompare: Codable, Equatable {
    public var myTotalHours: Double   // data3.myFwsc
    public var avgTotalHours: Double  // data3.avgFwsc
    public var myTimes: Int           // data4.myCs
    public var avgTimes: Double       // data4.avgCs
    public var topOrganization: String // data1.zzmc
    public var topOrgHours: Double    // data1.fwsc
}

public struct StudentPortraitVirtueScore: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String       // xmlxmc
    public var myScore: Double    // myJf
    public var avgScore: Double   // avgJf
}

public struct StudentPortraitHealthTest: Codable, Equatable, Identifiable {
    public var id: String { "\(year)" }
    public var year: Int          // year
    public var myScore: Double    // myScore
    public var avgScore: Double   // avgScore
}

public struct StudentPortraitAwardItem: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var code: Int          // code
    public var name: String       // name (国家级, 省级, 市级, 校级)
    public var count: Int         // num
    public var totalMoney: Double // totalMoney
}

public struct StudentPortraitAwardSummary: Codable, Equatable {
    public var totalCount: Int    // num
    public var totalMoney: Double // totalMoney
}

public struct StudentPortraitLibraryBorrowRange: Codable, Equatable, Identifiable {
    public var id: String { range }
    public var range: String      // jyqj
    public var studentCount: Int  // rs
}

public struct StudentPortraitLibraryStudyTime: Codable, Equatable {
    public var campusHours: Double   // all.xs
    public var campusCount: Double   // all.cs
    public var campusPeriod: String  // all.sd
    public var majorHours: Double    // bzy.xs
    public var majorCount: Double    // bzy.cs
    public var majorPeriod: String   // bzy.sd
}

public struct StudentPortraitEatData: Codable, Equatable {
    // 餐饮消费画像
    public var topMine: [StudentPortraitEatPlace]
    public var topCampus: [StudentPortraitEatPlace]
    public var annual: [StudentPortraitAnnualSpend]
    public var frequencyMine: [StudentPortraitEatFrequency]
    public var frequencyCampus: [StudentPortraitEatFrequency]
    public var oneDay: StudentPortraitEatDaySummary
    public var average: StudentPortraitEatAverage
    public var yearAverages: [StudentPortraitYearAverage]
    public var enrollmentYear: Int?
    public var lastSyncTime: Date

    // 学业与成就画像
    public var gpaHistory: [StudentPortraitGPAPoint]?
    public var courseExtremes: StudentPortraitCourseExtremes?
    public var courseTypeStats: [StudentPortraitCourseTypeStat]?
    public var secondClass: StudentPortraitSecondClass?
    public var completedCredits: Double?
    public var totalRequiredCredits: Double?
    public var awardSummary: StudentPortraitAwardSummary?
    public var awardList: [StudentPortraitAwardItem]?

    // 德育与志愿公益
    public var volunteerWelfare: [StudentPortraitVirtueWelfare]?
    public var volunteerCompare: StudentPortraitVirtueCompare?
    public var virtueScores: [StudentPortraitVirtueScore]?

    // 体质健康测试
    public var healthTests: [StudentPortraitHealthTest]?

    // 图书借阅与在馆自习
    public var libraryBorrowRanges: [StudentPortraitLibraryBorrowRange]?
    public var libraryStudyTime: StudentPortraitLibraryStudyTime?
}

/// 合工大信息门户学生画像消费数据。此授权和慧新易校/信息门户其他 Token 相互独立。
public final class StudentPortraitEatService {
    public static let shared = StudentPortraitEatService()

    private static let baseURL = "https://ehall.hfut.edu.cn/"
    private static let referer = "https://ehall.hfut.edu.cn/studentPortrait"
    private static let authorizationURL = "https://cas.hfut.edu.cn/cas/oauth2.0/authorize"
    private static let cacheFileName = "student_portrait_eat.json"

    public private(set) var latestData: StudentPortraitEatData?
    public private(set) var lastErrorMessage: String?
    private let stateLock = NSLock()
    private var syncing = false
    private var pendingSyncCompletions: [(Result<StudentPortraitEatData, Error>) -> Void] = []
    private let cacheURL: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent("cn.edu.hfut.campusnet.monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(StudentPortraitEatService.cacheFileName)
    }()

    public var isSyncing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return syncing
    }

    private init() {
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(StudentPortraitEatData.self, from: data) {
            latestData = decoded
        }
    }

    public func clearCache() {
        latestData = nil
        SettingsManager.shared.ehallAuthToken = nil
        try? FileManager.default.removeItem(at: cacheURL)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .studentPortraitDidUpdate, object: nil)
        }
    }

    /// 使用已保存的 EHALL Token 拉取画像；首次或过期时通过独立 CAS OAuth 重新授权。
    public func sync(completion: ((Result<StudentPortraitEatData, Error>) -> Void)? = nil) {
        stateLock.lock()
        if syncing {
            if let completion {
                pendingSyncCompletions.append(completion)
            }
            stateLock.unlock()
            return
        }
        syncing = true
        pendingSyncCompletions = completion.map { [$0] } ?? []
        stateLock.unlock()

        let finish: (Result<StudentPortraitEatData, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.stateLock.lock()
            if case .success(let data) = result {
                self.latestData = data
                self.lastErrorMessage = nil
            } else if case .failure(let error) = result {
                self.lastErrorMessage = error.localizedDescription
            }
            self.syncing = false
            let completions = self.pendingSyncCompletions
            self.pendingSyncCompletions.removeAll(keepingCapacity: false)
            self.stateLock.unlock()

            if case .success(let data) = result {
                if let encoded = try? JSONEncoder().encode(data) {
                    try? encoded.write(to: self.cacheURL, options: .atomic)
                }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .studentPortraitDidUpdate, object: self.latestData)
                completions.forEach { $0(result) }
            }
        }

        if let token = SettingsManager.shared.ehallAuthToken, !token.isEmpty {
            fetchReport(token: token) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result,
                   (error as NSError).code == 401 || (error as NSError).code == 403 {
                    SettingsManager.shared.ehallAuthToken = nil
                    self.authorizeAndFetch(finish: finish)
                } else {
                    finish(result)
                }
            }
        } else {
            authorizeAndFetch(finish: finish)
        }
    }

    private func authorizeAndFetch(finish: @escaping (Result<StudentPortraitEatData, Error>) -> Void) {
        obtainEhallToken { [weak self] tokenResult in
            guard let self else { return }
            switch tokenResult {
            case .failure(let error):
                finish(.failure(error))
            case .success(let token):
                SettingsManager.shared.ehallAuthToken = token
                self.fetchReport(token: token, completion: finish)
            }
        }
    }

    private func obtainEhallToken(completion: @escaping (Result<String, Error>) -> Void) {
        guard let tgc = SettingsManager.shared.casTgcCookie?.trimmingCharacters(in: .whitespacesAndNewlines), !tgc.isEmpty else {
            completion(.failure(Self.error("请先完成统一身份认证，再单独授权学生画像", code: 401)))
            return
        }
        guard var authComponents = URLComponents(string: Self.authorizationURL) else {
            completion(.failure(Self.error("无法构造 EHALL 授权地址")))
            return
        }
        let redirectURL = Self.referer
        authComponents.queryItems = [
            URLQueryItem(name: "client_id", value: "BsHfutEduEhall"),
            URLQueryItem(name: "redirect_uri", value: redirectURL),
            URLQueryItem(name: "response_type", value: "code")
        ]
        guard let authURL = authComponents.url else {
            completion(.failure(Self.error("无法构造 EHALL 授权地址")))
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        if let castgc = HTTPCookie(properties: [
            .domain: "cas.hfut.edu.cn", .path: "/", .name: "CASTGC", .value: tgc
        ]) {
            configuration.httpCookieStorage?.setCookie(castgc)
        }
        if let tgcCookie = HTTPCookie(properties: [
            .domain: "cas.hfut.edu.cn", .path: "/cas", .name: "TGC", .value: tgc
        ]) {
            configuration.httpCookieStorage?.setCookie(tgcCookie)
        }
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: authURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        func extractCode(from url: URL?) -> String? {
            guard let url else { return nil }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            return components?.queryItems?.first(where: { $0.name == "code" })?.value
        }

        session.dataTask(with: request) { [weak self] _, response, requestError in
            guard let self else { return }
            if let requestError {
                session.finishTasksAndInvalidate()
                completion(.failure(requestError))
                return
            }
            let callbackURL = (response as? HTTPURLResponse)?.url

            // 1. 若首次重定向已直接返回带 code 的跳转地址
            if let code = extractCode(from: callbackURL), !code.isEmpty {
                self.exchangeEhallCode(code: code, redirect: redirectURL, session: session, completion: completion)
                return
            }

            // 2. 若返回页面重定向到了登录页，说明 CAS TGC 已经过期失效
            if callbackURL?.path.contains("/login") == true {
                session.finishTasksAndInvalidate()
                completion(.failure(Self.error("统一身份认证已失效，请重新登录", code: 401)))
                return
            }

            // 3. CAS OAuth 2.0 首次授权确认流程：
            // CAS 经 TGC 认证后进入「是否授权该应用访问个人信息」确认页，并下发带授权会话的 CAS SESSION Cookie。
            // 使用同一 session 再次访问授权地址即可完成「允许」确认并获得最终包含 code 的重定向。
            var confirmRequest = URLRequest(url: authURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            confirmRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            session.dataTask(with: confirmRequest) { [weak self] _, secondResponse, secondError in
                guard let self else { return }
                if let secondError {
                    session.finishTasksAndInvalidate()
                    completion(.failure(secondError))
                    return
                }
                let secondURL = (secondResponse as? HTTPURLResponse)?.url
                if let code = extractCode(from: secondURL), !code.isEmpty {
                    self.exchangeEhallCode(code: code, redirect: redirectURL, session: session, completion: completion)
                } else {
                    session.finishTasksAndInvalidate()
                    completion(.failure(Self.error("EHALL OAuth 未返回授权码，请重新统一登录", code: 401)))
                }
            }.resume()
        }.resume()
    }

    private func exchangeEhallCode(
        code: String,
        redirect: String,
        session: URLSession,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard var components = URLComponents(string: Self.baseURL + "api/auth/oauth/getToken") else {
            session.finishTasksAndInvalidate()
            completion(.failure(Self.error("无法构造 EHALL Token 地址")))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "type", value: "ehall"),
            URLQueryItem(name: "redirect", value: redirect),
            URLQueryItem(name: "code", value: code)
        ]
        guard let url = components.url else {
            session.finishTasksAndInvalidate()
            completion(.failure(Self.error("无法构造 EHALL Token 地址")))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, requestError in
            session.finishTasksAndInvalidate()
            if let requestError {
                completion(.failure(requestError))
                return
            }
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                completion(.failure(Self.error("EHALL Token 交换失败（HTTP \(status)）", code: status)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokenData = json["data"] as? [String: Any],
                  let token = (tokenData["access_token"] as? String) ?? (tokenData["token"] as? String),
                  !token.isEmpty else {
                let responseJSON = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let message = responseJSON?["msg"] as? String
                completion(.failure(Self.error(message ?? "EHALL Token 交换响应无法解析")))
                return
            }
            let message = (json["msg"] as? String ?? "").lowercased()
            let codeVal = json["code"] as? Int
            guard message.contains("success") || codeVal == 1 else {
                completion(.failure(Self.error(json["msg"] as? String ?? "EHALL Token 交换失败", code: 401)))
                return
            }
            completion(.success(token.hasPrefix("Bearer ") ? token : "Bearer \(token)"))
        }.resume()
    }

    private func fetchReport(token: String, completion: @escaping (Result<StudentPortraitEatData, Error>) -> Void) {
        let normalizedToken = token.lowercased().hasPrefix("bearer ") ? String(token.dropFirst(7)) : token
        guard !normalizedToken.isEmpty else {
            completion(.failure(Self.error("EHALL 学生画像授权已失效", code: 401)))
            return
        }

        let enrollmentYear = Self.resolvedEnrollmentYear()
        var annualBody: [String: Any] = ["year": NSNull(), "env": "prod"]
        if let enrollmentYear {
            annualBody["nj"] = enrollmentYear
            annualBody["xdnx"] = "4"
        }
        let commonBody: [String: Any] = ["year": "all", "env": "prod"]
        let yearStr = enrollmentYear.map { "\($0)" } ?? "2024"
        let yearBody: [String: Any] = ["year": yearStr, "env": "prod"]
        let endpoints: [(String, String, [String: Any], Bool)] = [
            ("top3", "api/admin/dataway/xshx/eat/top3", commonBody, true),
            ("annual", "api/admin/dataway/xshx/eat/nianxiaofeiqingkuang", annualBody, false),
            ("frequency", "api/admin/dataway/xshx/eat/jydd", commonBody, false),
            ("oneDay", "api/admin/dataway/xshx/eat/oneday", commonBody, true),
            ("average", "api/admin/dataway/xshx/eat/average", commonBody, true),
            ("gpa", "api/admin/dataway/xshx/xue/jidianqushitu", ["env": "prod"], false),
            ("progress", "api/admin/dataway/xshx/xue/xueyejinzhan", ["env": "prod"], false),
            ("extremes", "api/admin/dataway/xshx/xue/zgzdf", ["env": "prod"], false),
            ("secondClass", "api/admin/dataway/xshx/xue/dierketang", ["env": "prod"], false),
            ("secondClassAnalysis", "api/admin/dataway/xshx/xue/dierketangfenxi", ["env": "prod"], false),
            ("courseTypeStats", "api/admin/dataway/xshx/xue/kccjdb", ["env": "prod"], false),
            ("welfareTime", "api/admin/dataway/xshx/virtue/welfareTime", yearBody, false),
            ("virtueCompare", "api/admin/dataway/xshx/virtue/compare", yearBody, false),
            ("virtueTotal", "api/admin/dataway/xshx/virtue/total", yearBody, false),
            ("healthTest", "api/admin/dataway/xshx/health/test", yearBody, false),
            ("awardTotal", "api/admin/dataway/xshx/xue/huojianggeshu", yearBody, false),
            ("awardList", "api/admin/dataway/xshx/xue/huojiangtongji", yearBody, false),
            ("libraryStudy", "api/admin/dataway/xshx/read/xuexishichang", yearBody, false),
            ("libraryBorrow", "api/admin/dataway/xshx/read/tushujieyuequjian", yearBody, false)
        ]

        let group = DispatchGroup()
        let resultLock = NSLock()
        var values: [String: Any] = [:]
        var firstError: Error?
        for (key, path, body, isCritical) in endpoints {
            group.enter()
            post(path: path, body: body, token: normalizedToken) { result in
                resultLock.lock()
                switch result {
                case .success(let value):
                    values[key] = value
                case .failure(let error):
                    if isCritical && firstError == nil {
                        firstError = error
                    }
                }
                resultLock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            resultLock.lock()
            let values = values
            let firstError = firstError
            resultLock.unlock()
            if let firstError {
                completion(.failure(firstError))
                return
            }
            guard let top = values["top3"] as? [String: Any],
                  let frequency = values["frequency"] as? [String: Any],
                  let oneDay = values["oneDay"] as? [String: Any],
                  let averageValue = values["average"] as? [String: Any] else {
                completion(.failure(Self.error("EHALL 学生画像响应缺少必要数据")))
                return
            }
            let annualRows = (values["annual"] as? [[String: Any]]) ?? []

            let annual = annualRows.map {
                StudentPortraitAnnualSpend(
                    academicYear: Self.string($0["xn"]) ?? "",
                    personalRMB: Self.number($0["myze"]) ?? 0,
                    campusAverageRMB: Self.number($0["avgze"]) ?? 0
                )
            }.filter { !$0.academicYear.isEmpty }

            let gpaRows = values["gpa"] as? [[String: Any]] ?? []
            let gpaHistory: [StudentPortraitGPAPoint] = gpaRows.compactMap { row in
                guard let semester = Self.string(row["xq"]), !semester.isEmpty else { return nil }
                return StudentPortraitGPAPoint(
                    semester: semester,
                    gpa: Self.number(row["jd"]) ?? 0,
                    averageGPA: Self.number(row["avgJd"]) ?? 0,
                    credits: Self.number(row["xf"]) ?? 0,
                    totalCredits: Self.number(row["totalFx"]) ?? 0
                )
            }

            var courseExtremes: StudentPortraitCourseExtremes?
            if let ext = values["extremes"] as? [String: Any] {
                courseExtremes = StudentPortraitCourseExtremes(
                    highestScore: Self.number(ext["zgf"]) ?? 0,
                    highestCourseName: Self.string(ext["zgkcmc"]) ?? "--",
                    lowestScore: Self.number(ext["zdf"]) ?? 0,
                    lowestCourseName: Self.string(ext["zdkcmc"]) ?? "--"
                )
            }

            let courseTypeRows = values["courseTypeStats"] as? [[String: Any]] ?? []
            let courseTypeStats: [StudentPortraitCourseTypeStat] = courseTypeRows.compactMap { row in
                guard let name = Self.string(row["mc"]), !name.isEmpty else { return nil }
                return StudentPortraitCourseTypeStat(
                    categoryName: name,
                    averageScore: Self.number(row["pjf"]) ?? 0,
                    highestScore: Self.number(row["zgf"]) ?? 0,
                    lowestScore: Self.number(row["zdf"]) ?? 0,
                    highestCourse: Self.string(row["zgkcmc"]) ?? "--",
                    lowestCourse: Self.string(row["zdkcmc"]) ?? "--"
                )
            }

            var secondClass: StudentPortraitSecondClass?
            if let sc = values["secondClass"] as? [String: Any] {
                let analysis = values["secondClassAnalysis"] as? [String: Any]
                secondClass = StudentPortraitSecondClass(
                    techInnovationStars: Self.integer(sc["kjcxxj"]) ?? 0,
                    sportsFitnessStars: Self.integer(sc["tyjsxj"]) ?? 0,
                    laborPracticeStars: Self.integer(sc["ldsjxj"]) ?? 0,
                    publicWelfareStars: Self.integer(sc["gyfwxj"]) ?? 0,
                    socialPracticeStars: Self.integer(sc["shsjxj"]) ?? 0,
                    artsCultureStars: Self.integer(sc["wyhdxj"]) ?? 0,
                    skillsProjectStars: Self.integer(sc["jnxmxj"]) ?? 0,
                    ideologicalStars: Self.integer(sc["szxxxj"]) ?? 0,
                    requiredLevel: Self.integer(analysis?["bxdj"]) ?? 0,
                    electiveLevel: Self.integer(analysis?["xxdj"]) ?? 0
                )
            }

            var completedCredits: Double?
            var totalRequiredCredits: Double?
            if let progress = values["progress"] as? [String: Any] {
                completedCredits = Self.number(progress["xf"])
                totalRequiredCredits = Self.number(progress["totalFx"])
            }

            // 德育与志愿服务解析
            let welfareRows = values["welfareTime"] as? [[String: Any]] ?? []
            let volunteerWelfare: [StudentPortraitVirtueWelfare] = welfareRows.compactMap { row in
                guard let org = Self.string(row["zzmc"]), !org.isEmpty else { return nil }
                return StudentPortraitVirtueWelfare(
                    organization: org,
                    hours: Self.number(row["myfwsc"]) ?? 0
                )
            }

            var volunteerCompare: StudentPortraitVirtueCompare?
            if let cmp = values["virtueCompare"] as? [String: Any] {
                let d1 = cmp["data1"] as? [String: Any]
                let d3 = cmp["data3"] as? [String: Any]
                let d4 = cmp["data4"] as? [String: Any]
                volunteerCompare = StudentPortraitVirtueCompare(
                    myTotalHours: Self.number(d3?["myFwsc"]) ?? 0,
                    avgTotalHours: Self.number(d3?["avgFwsc"]) ?? 0,
                    myTimes: Self.integer(d4?["myCs"]) ?? 0,
                    avgTimes: Self.number(d4?["avgCs"]) ?? 0,
                    topOrganization: Self.string(d1?["zzmc"]) ?? "--",
                    topOrgHours: Self.number(d1?["fwsc"]) ?? 0
                )
            }

            let virtueRows = values["virtueTotal"] as? [[String: Any]] ?? []
            let virtueScores: [StudentPortraitVirtueScore] = virtueRows.compactMap { row in
                guard let name = Self.string(row["xmlxmc"]), !name.isEmpty else { return nil }
                return StudentPortraitVirtueScore(
                    name: name,
                    myScore: Self.number(row["myJf"]) ?? 0,
                    avgScore: Self.number(row["avgJf"]) ?? 0
                )
            }

            // 体质健康测试解析
            let healthRows = values["healthTest"] as? [[String: Any]] ?? []
            let healthTests: [StudentPortraitHealthTest] = healthRows.compactMap { row in
                guard let year = Self.integer(row["year"]) else { return nil }
                return StudentPortraitHealthTest(
                    year: year,
                    myScore: Self.number(row["myScore"]) ?? 0,
                    avgScore: Self.number(row["avgScore"]) ?? 0
                )
            }

            // 荣誉表彰与奖学金解析
            var awardSummary: StudentPortraitAwardSummary?
            if let awSum = values["awardTotal"] as? [String: Any] {
                awardSummary = StudentPortraitAwardSummary(
                    totalCount: Self.integer(awSum["num"]) ?? 0,
                    totalMoney: Self.number(awSum["totalMoney"]) ?? 0
                )
            }

            let awardRows = values["awardList"] as? [[String: Any]] ?? []
            let awardList: [StudentPortraitAwardItem] = awardRows.compactMap { row in
                guard let name = Self.string(row["name"]), !name.isEmpty else { return nil }
                return StudentPortraitAwardItem(
                    code: Self.integer(row["code"]) ?? 0,
                    name: name,
                    count: Self.integer(row["num"]) ?? 0,
                    totalMoney: Self.number(row["totalMoney"]) ?? 0
                )
            }

            // 图书自习与借阅
            let borrowRows = values["libraryBorrow"] as? [[String: Any]] ?? []
            let libraryBorrowRanges: [StudentPortraitLibraryBorrowRange] = borrowRows.compactMap { row in
                guard let qj = Self.string(row["jyqj"]), !qj.isEmpty else { return nil }
                return StudentPortraitLibraryBorrowRange(
                    range: qj,
                    studentCount: Self.integer(row["rs"]) ?? 0
                )
            }

            var libraryStudyTime: StudentPortraitLibraryStudyTime?
            if let study = values["libraryStudy"] as? [String: Any] {
                let all = study["all"] as? [String: Any]
                let bzy = study["bzy"] as? [String: Any]
                libraryStudyTime = StudentPortraitLibraryStudyTime(
                    campusHours: Self.number(all?["xs"]) ?? 0,
                    campusCount: Self.number(all?["cs"]) ?? 0,
                    campusPeriod: Self.string(all?["sd"]) ?? "下午",
                    majorHours: Self.number(bzy?["xs"]) ?? 0,
                    majorCount: Self.number(bzy?["cs"]) ?? 0,
                    majorPeriod: Self.string(bzy?["sd"]) ?? "上午"
                )
            }

            let data = StudentPortraitEatData(
                topMine: Self.placeRows(top["myData"]),
                topCampus: Self.placeRows(top["allData"]),
                annual: annual,
                frequencyMine: Self.frequencyRows(frequency["my"]),
                frequencyCampus: Self.frequencyRows(frequency["all"]),
                oneDay: StudentPortraitEatDaySummary(
                    personalFirstTime: Self.string(oneDay["myFirstJysj"]) ?? "--",
                    personalFirstPlace: Self.string(oneDay["myFirstJydd"]) ?? "--",
                    personalMealCount: Self.integer(oneDay["myJycs"]) ?? 0,
                    campusFirstTime: Self.string(oneDay["allFirstJysj"]) ?? "--",
                    campusFirstPlace: Self.string(oneDay["allFirstJydd"]) ?? "--",
                    campusMealCount: Self.integer(oneDay["allJycs"]) ?? 0
                ),
                average: Self.average(averageValue),
                yearAverages: [],
                enrollmentYear: enrollmentYear,
                lastSyncTime: Date(),
                gpaHistory: gpaHistory,
                courseExtremes: courseExtremes,
                courseTypeStats: courseTypeStats,
                secondClass: secondClass,
                completedCredits: completedCredits,
                totalRequiredCredits: totalRequiredCredits,
                awardSummary: awardSummary,
                awardList: awardList,
                volunteerWelfare: volunteerWelfare,
                volunteerCompare: volunteerCompare,
                virtueScores: virtueScores,
                healthTests: healthTests,
                libraryBorrowRanges: libraryBorrowRanges,
                libraryStudyTime: libraryStudyTime
            )
            self.fetchYearAverages(token: normalizedToken, annual: annual) { yearAverages in
                var finalData = data
                finalData.yearAverages = yearAverages
                completion(.success(finalData))
            }
        }
    }

    private func fetchYearAverages(
        token: String,
        annual: [StudentPortraitAnnualSpend],
        completion: @escaping ([StudentPortraitYearAverage]) -> Void
    ) {
        let years = Array(Set(annual.map { String($0.academicYear.prefix(4)) }.filter { Int($0) != nil })).sorted()
        guard !years.isEmpty else { completion([]); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [String: StudentPortraitEatAverage] = [:]
        // Bound parallel requests while keeping the latest years in the trend.
        for year in years.suffix(8) {
            group.enter()
            post(path: "api/admin/dataway/xshx/eat/average", body: ["year": year, "env": "prod"], token: token) { result in
                if case .success(let value) = result, let dictionary = value as? [String: Any] {
                    lock.lock()
                    results[year] = Self.average(dictionary)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility)) {
            lock.lock()
            let copied = results
            lock.unlock()
            completion(copied.keys.sorted().map { StudentPortraitYearAverage(academicYear: $0, average: copied[$0]!) })
        }
    }

    private func post(
        path: String,
        body: [String: Any],
        token: String,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        guard let url = URL(string: Self.baseURL + path),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(Self.error("EHALL 请求构造失败")))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("TOKEN=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if !(200..<300).contains(status) {
                completion(.failure(Self.error("EHALL 消费画像请求失败（HTTP \(status)）", code: status)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(Self.error("EHALL 消费画像响应无法解析")))
                return
            }
            guard (json["success"] as? Bool) == true else {
                let code = Self.integer(json["code"]) ?? 0
                let message = Self.string(json["message"]) ?? "EHALL 消费画像接口返回失败"
                completion(.failure(Self.error(message, code: code == 0 ? 1 : code)))
                return
            }
            completion(.success(json["value"] ?? NSNull()))
        }.resume()
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private static func resolvedEnrollmentYear() -> Int? {
        if let year = enrollmentYear(from: SettingsManager.shared.portalUsername) {
            return year
        }
        if let cardAccount = CampusCardService.shared.latestData?.cardAccount,
           let year = enrollmentYear(from: cardAccount) {
            return year
        }
        if let token = SettingsManager.shared.huixinAuthToken,
           let year = enrollmentYearFromJWT(token) {
            return year
        }
        return nil
    }

    private static func enrollmentYearFromJWT(_ jwt: String) -> Int? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sno = (json["sno"] as? String) ?? (json["account"] as? String) else {
            return nil
        }
        return enrollmentYear(from: sno)
    }

    private static func enrollmentYear(from studentID: String) -> Int? {
        guard let year = Int(studentID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4)),
              (2000...Calendar.current.component(.year, from: Date())).contains(year) else { return nil }
        return year
    }

    private static func placeRows(_ value: Any?) -> [StudentPortraitEatPlace] {
        (value as? [[String: Any]] ?? []).compactMap { row in
            guard let place = string(row["jydd"]), !place.isEmpty else { return nil }
            return StudentPortraitEatPlace(place: place, amountRMB: number(row["jyze"]) ?? 0)
        }
    }

    private static func frequencyRows(_ value: Any?) -> [StudentPortraitEatFrequency] {
        (value as? [[String: Any]] ?? []).compactMap { row in
            guard let place = string(row["jydd"]), !place.isEmpty else { return nil }
            return StudentPortraitEatFrequency(place: place, count: integer(row["count"]) ?? 0)
        }
    }

    private static func average(_ value: [String: Any]) -> StudentPortraitEatAverage {
        StudentPortraitEatAverage(
            personalYearRMB: number(value["yearAvgMy"]) ?? 0,
            campusYearRMB: number(value["yearAvgAll"]) ?? 0,
            personalMonthRMB: number(value["monthAvgMy"]) ?? 0,
            campusMonthRMB: number(value["monthAvgAll"]) ?? 0,
            personalDayRMB: number(value["dayAvgMy"]) ?? 0,
            campusDayRMB: number(value["dayAvgAll"]) ?? 0
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func error(_ message: String, code: Int = 0) -> NSError {
        NSError(domain: "cn.edu.hfut.ehall", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

public extension Notification.Name {
    static let studentPortraitDidUpdate = Notification.Name("cn.edu.hfut.studentPortraitDidUpdate")
}
