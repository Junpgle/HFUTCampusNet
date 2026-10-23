import Foundation
import AppKit

/// 借阅状态枚举（对齐 HFUT-Schedule BorrowedStatus）
public enum CampusBorrowStatus: String, Codable {
    case returned = "0"      // 已还
    case borrowing = "2"     // 借阅中
    case overdue = "02"      // 逾期待还

    public var title: String {
        switch self {
        case .returned: return "已归还"
        case .borrowing: return "借阅中"
        case .overdue: return "逾期待还"
        }
    }
}

/// 读者借阅图书模型（对齐 HFUT-Schedule LibraryBorrowRecord 与本地持久化）
public struct CampusBorrowedBook: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var author: String
    public var publisher: String
    public var year: String
    public var isbn: String
    public var callNumber: String       // 索书号，如 TP3/284(3)
    public var barcode: String          // 条形码
    public var location: String         // 借出馆藏地，如 宣城校区/宣城校区图书借阅处
    public var borrowDate: String       // 借阅日期 YYYY-MM-DD HH:mm:ss 或 YYYY-MM-DD
    public var dueDate: String          // 应还日期 YYYY-MM-DD
    public var statusRaw: String        // "0"已还, "2"借阅中, "02"逾期
    public var realReturnDate: String?  // 实际归还日期

    public init(
        id: String = UUID().uuidString,
        title: String,
        author: String = "",
        publisher: String = "",
        year: String = "",
        isbn: String = "",
        callNumber: String = "",
        barcode: String = "",
        location: String = "合工大图书馆",
        borrowDate: String = "",
        dueDate: String = "",
        statusRaw: String = "2",
        realReturnDate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.publisher = publisher
        self.year = year
        self.isbn = isbn
        self.callNumber = callNumber
        self.barcode = barcode
        self.location = location
        self.borrowDate = borrowDate
        self.dueDate = dueDate
        self.statusRaw = statusRaw
        self.realReturnDate = realReturnDate
    }

    public var isReturned: Bool {
        if statusRaw == "0" { return true }
        if let ret = realReturnDate, !ret.isEmpty { return true }
        return false
    }

    /// 计算距离应还日期的剩余天数（负数代表逾期）
    public var daysRemaining: Int? {
        guard !isReturned, !dueDate.isEmpty else { return nil }
        let dateStr = String(dueDate.prefix(10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = CourseCalendarHelper.beijingCalendar
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        guard let due = formatter.date(from: dateStr) else { return nil }
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfDue = calendar.startOfDay(for: due)
        let components = calendar.dateComponents([.day], from: startOfToday, to: startOfDue)
        return components.day
    }

    /// 状态徽标文本
    public var statusBadgeText: String {
        if isReturned {
            if let ret = realReturnDate, !ret.isEmpty {
                return "已还 (\(ret.prefix(10)))"
            }
            return "已还"
        }
        guard let days = daysRemaining else {
            return "借阅中"
        }
        if days < 0 {
            return "已逾期 \(-days) 天"
        } else if days == 0 {
            return "今日到期"
        } else if days <= 3 {
            return "剩 \(days) 天到期"
        } else {
            return "剩 \(days) 天"
        }
    }

    /// 状态指示颜色
    public var statusColor: NSColor {
        if isReturned {
            return .secondaryLabelColor
        }
        guard let days = daysRemaining else {
            return .systemBlue
        }
        if days < 0 {
            return .systemRed
        } else if days <= 3 {
            return .systemOrange
        } else {
            return .systemGreen
        }
    }
}

/// 内部处理 CAS SSO 302 重定向以提取 Authorization JWT 的 Session Delegate
private final class LibrarySSORedirectDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    var capturedToken: String?

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let allHeaders = response.allHeaderFields as? [String: Any] {
            for (k, v) in allHeaders {
                if k.lowercased() == "set-cookie", let s = v as? String {
                    if let range = s.range(of: "Authorization=") {
                        let tokenPart = s[range.upperBound...].components(separatedBy: ";")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        if tokenPart.hasPrefix("ey") {
                            capturedToken = tokenPart
                        }
                    }
                }
            }
        }
        completionHandler(request)
    }
}

/// 读者借阅数据管理（对齐 HFUT-Schedule LibraryRepository，支持 CAS SSO 自动登录与真实接口拉取）
public final class LibraryBorrowManager {
    public static let shared = LibraryBorrowManager()

    private let storageKey = "cn.edu.hfut.campusnet.borrow_records_v3"
    private let lastSyncKey = "cn.edu.hfut.campusnet.borrow_sync_time_v3"
    private let stateLock = NSLock()
    private var syncGeneration = 0
    private var accountGeneration = 0
    private static let readerRecordPageSize = 100
    private static let maximumReaderRecordPages = 100

    public private(set) var books: [CampusBorrowedBook] = []
    public private(set) var isSyncing: Bool = false
    public private(set) var totalBorrowStatsCount: Int = 0
    public private(set) var totalBookshelfStatsCount: Int = 0

    public var onDataChanged: (() -> Void)?
    private var pendingSyncCompletions: [(Result<[CampusBorrowedBook], Error>) -> Void] = []

    private init() {
        loadFromStorage()
        // 清理任何历史虚构种子数据
        books.removeAll { $0.id.hasPrefix("seed-") }
    }

    /// 借阅中书目（按临期从近到远排序，先还最近到期的）
    public var currentLoans: [CampusBorrowedBook] {
        return books.filter { !$0.isReturned }.sorted {
            ($0.daysRemaining ?? 999) < ($1.daysRemaining ?? 999)
        }
    }

    /// 历史已还记录（按还书或借书时间倒序）
    public var historyLoans: [CampusBorrowedBook] {
        return books.filter { $0.isReturned }.sorted {
            let t0 = $0.realReturnDate ?? $0.borrowDate
            let t1 = $1.realReturnDate ?? $1.borrowDate
            return t0 > t1
        }
    }

    /// 逾期待还书目
    public var overdueLoans: [CampusBorrowedBook] {
        return currentLoans.filter { ($0.daysRemaining ?? 0) < 0 }
    }

    /// 7 天内待还书目
    public var dueSoonLoans: [CampusBorrowedBook] {
        return currentLoans.filter {
            if let d = $0.daysRemaining {
                return d >= 0 && d <= 7
            }
            return false
        }
    }

    /// 最近应还的一本书
    public var nearestDueBook: CampusBorrowedBook? {
        return currentLoans.first
    }

    /// 状态说明文字
    public var statusSummaryText: String {
        guard let date = UserDefaults.standard.object(forKey: lastSyncKey) as? Date else {
            return "尚未从校内同步"
        }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return "同步于 " + df.string(from: date)
    }

    public func addOrUpdate(book: CampusBorrowedBook) {
        if let idx = books.firstIndex(where: { $0.id == book.id || (!book.barcode.isEmpty && $0.barcode == book.barcode) }) {
            books[idx] = book
        } else {
            books.insert(book, at: 0)
        }
        saveToStorage()
    }

    public func markReturned(id: String) {
        guard let idx = books.firstIndex(where: { $0.id == id }) else { return }
        books[idx].statusRaw = "0"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        books[idx].realReturnDate = df.string(from: Date())
        saveToStorage()
    }

    public func deleteBook(id: String) {
        books.removeAll { $0.id == id }
        saveToStorage()
    }

    public func recordSync() {
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
    }

    public func clearCache() {
        stateLock.lock()
        syncGeneration &+= 1
        accountGeneration &+= 1
        SettingsManager.shared.libraryToken = nil
        SettingsManager.shared.libraryBorrowCount = 0
        books.removeAll()
        totalBorrowStatsCount = 0
        totalBookshelfStatsCount = 0
        isSyncing = false
        let completions = pendingSyncCompletions
        pendingSyncCompletions.removeAll(keepingCapacity: false)
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        stateLock.unlock()

        let cancellation = Self.cancelledError()
        DispatchQueue.main.async {
            self.onDataChanged?()
            completions.forEach { $0(.failure(cancellation)) }
        }
    }

    private func isCurrentSyncGeneration(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return syncGeneration == generation
    }

    private func setLibraryToken(_ token: String?, generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard syncGeneration == generation else { return false }
        SettingsManager.shared.libraryToken = token
        return true
    }

    private static func cancelledError() -> NSError {
        NSError(domain: "LibraryBorrowManager", code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "账号已切换，本次图书借阅同步已取消"])
    }

    // MARK: - 从合工大图书馆 API (CAS SSO) 同步真实借阅与历史

    /// 核心同步入口：自动利用 CAS TGC 换取图书馆 JWT Token，并拉取真实在借与借阅历史
    public func syncWithRemote(forceSSO: Bool = false, completion: ((Result<[CampusBorrowedBook], Error>) -> Void)? = nil) {
        stateLock.lock()
        if isSyncing {
            if let completion {
                pendingSyncCompletions.append(completion)
            }
            guard forceSSO else {
                stateLock.unlock()
                return
            }
        } else {
            isSyncing = true
            pendingSyncCompletions = completion.map { [$0] } ?? []
        }
        // A forced SSO request supersedes any active fetch; its result completes
        // all callers waiting on the previous request as well as this one.
        syncGeneration &+= 1
        let generation = syncGeneration
        let requestAccountGeneration = accountGeneration
        stateLock.unlock()

        let finishSync: (Result<[CampusBorrowedBook], Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.stateLock.lock()
            guard self.syncGeneration == generation else {
                self.stateLock.unlock()
                return
            }
            self.isSyncing = false
            let completions = self.pendingSyncCompletions
            self.pendingSyncCompletions.removeAll(keepingCapacity: false)
            self.stateLock.unlock()

            DispatchQueue.main.async {
                self.stateLock.lock()
                let isCurrentAccount = self.accountGeneration == requestAccountGeneration
                self.stateLock.unlock()
                guard isCurrentAccount else {
                    let cancellation = Self.cancelledError()
                    completions.forEach { $0(.failure(cancellation)) }
                    return
                }
                completions.forEach { $0(result) }
            }
        }

        let existingToken = SettingsManager.shared.libraryToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !forceSSO, let token = existingToken, !token.isEmpty {
            // 直接尝试拉取借阅记录
            fetchReaderRecord(token: token, generation: generation) { [weak self] result in
                guard let self else { return }
                guard self.isCurrentSyncGeneration(generation) else { return }
                switch result {
                case .success(let items):
                    self.fetchLibraryStats(token: token, generation: generation)
                    finishSync(.success(items))
                case .failure:
                    // Token 可能过期，退化为 CAS SSO 重新获取
                    self.loginViaCASTgc(generation: generation) { ssoResult in
                        guard self.isCurrentSyncGeneration(generation) else { return }
                        switch ssoResult {
                        case .success(let newToken):
                            self.fetchReaderRecord(token: newToken, generation: generation) { finalRes in
                                guard self.isCurrentSyncGeneration(generation) else { return }
                                if case .success = finalRes {
                                    self.fetchLibraryStats(token: newToken, generation: generation)
                                }
                                finishSync(finalRes)
                            }
                        case .failure(let err):
                            finishSync(.failure(err))
                        }
                    }
                }
            }
            return
        }

        // 无 Token 或强制 SSO 重新登录
        loginViaCASTgc(generation: generation) { [weak self] ssoResult in
            guard let self else { return }
            guard self.isCurrentSyncGeneration(generation) else { return }
            switch ssoResult {
            case .success(let newToken):
                self.fetchReaderRecord(token: newToken, generation: generation) { finalRes in
                    guard self.isCurrentSyncGeneration(generation) else { return }
                    if case .success = finalRes {
                        self.fetchLibraryStats(token: newToken, generation: generation)
                    }
                    finishSync(finalRes)
                }
            case .failure(let err):
                finishSync(.failure(err))
            }
        }
    }

    /// 使用 CAS TGC Cookie 单点登录图书馆系统，获取 Authorization Header Token
    private func loginViaCASTgc(generation: Int, completion: @escaping (Result<String, Error>) -> Void) {
        guard isCurrentSyncGeneration(generation) else {
            completion(.failure(Self.cancelledError()))
            return
        }
        guard let tgc = SettingsManager.shared.casTgcCookie?.trimmingCharacters(in: .whitespacesAndNewlines), !tgc.isEmpty else {
            completion(.failure(NSError(domain: "LibraryBorrowManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未登录统一身份认证 (CAS)，请先在一键登录中完成认证"])))
            return
        }

        let delegate = LibrarySSORedirectDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true

        if let c1 = HTTPCookie(properties: [.domain: "cas.hfut.edu.cn", .path: "/", .name: "CASTGC", .value: tgc]),
           let c2 = HTTPCookie(properties: [.domain: "cas.hfut.edu.cn", .path: "/cas", .name: "TGC", .value: tgc]) {
            config.httpCookieStorage?.setCookie(c1)
            config.httpCookieStorage?.setCookie(c2)
        }

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        guard let ssoURL = URL(string: "https://cas.hfut.edu.cn/cas/login?service=https%3A%2F%2Flib.hfut.edu.cn%2Fsvc%2Fsso%2Flogin%2Fcallback%2Fportal%2Fhfut") else {
            completion(.failure(NSError(domain: "LibraryBorrowManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的图书馆 SSO 登录地址"])))
            return
        }

        var req = URLRequest(url: ssoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { data, response, error in
            session.finishTasksAndInvalidate()

            if let error = error {
                completion(.failure(error))
                return
            }

            // 检查 delegate 捕获的 token 或从 cookie storage 获取
            var token: String? = delegate.capturedToken
            if token == nil {
                let cookies = config.httpCookieStorage?.cookies ?? []
                for c in cookies {
                    if c.name == "Authorization" && c.value.hasPrefix("ey") {
                        token = c.value
                        break
                    }
                }
            }

            guard let token = token, !token.isEmpty else {
                completion(.failure(NSError(domain: "LibraryBorrowManager", code: 403, userInfo: [NSLocalizedDescriptionKey: "统一身份认证登录图书馆未返回凭证，可能登录状态已过期"])))
                return
            }

            guard self.setLibraryToken(token, generation: generation) else {
                completion(.failure(Self.cancelledError()))
                return
            }
            completion(.success(token))
        }.resume()
    }

    /// 调用 readerRecord 分页接口，完整读取在借与历史记录。
    private func fetchReaderRecord(
        token: String,
        generation: Int,
        completion: @escaping (Result<[CampusBorrowedBook], Error>) -> Void
    ) {
        fetchReaderRecordPage(token: token, generation: generation, page: 1, accumulated: [], completion: completion)
    }

    private func fetchReaderRecordPage(
        token: String,
        generation: Int,
        page: Int,
        accumulated: [CampusBorrowedBook],
        completion: @escaping (Result<[CampusBorrowedBook], Error>) -> Void
    ) {
        guard isCurrentSyncGeneration(generation) else {
            completion(.failure(Self.cancelledError()))
            return
        }
        guard page <= Self.maximumReaderRecordPages,
              var components = URLComponents(string: "https://lib.hfut.edu.cn/svc/circulate/readerRecord") else {
            completion(.failure(NSError(domain: "LibraryBorrowManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的借阅查询 URL"])))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "status", value: ""),
            URLQueryItem(name: "limit", value: String(Self.readerRecordPageSize))
        ]
        guard let url = components.url else {
            completion(.failure(NSError(domain: "LibraryBorrowManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的借阅查询 URL"])))
            return
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        let authHeader = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        req.setValue(authHeader, forHTTPHeaderField: "authorization")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            guard self.isCurrentSyncGeneration(generation) else {
                completion(.failure(Self.cancelledError()))
                return
            }
            if let error = error {
                completion(.failure(error))
                return
            }

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let message = http.statusCode == 401 || http.statusCode == 403
                    ? "借阅凭证已失效"
                    : "借阅记录请求失败 (HTTP \(http.statusCode))"
                completion(.failure(NSError(domain: "LibraryBorrowManager", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "LibraryBorrowManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "服务端返回空响应"])))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "LibraryBorrowManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "响应 JSON 格式解析失败"])
                }

                let responseCode = (json["code"] as? String) ?? (json["code"] as? NSNumber)?.stringValue
                if let code = responseCode, code != "0" {
                    let msg = json["message"] as? String ?? "请求失败"
                    throw NSError(domain: "LibraryBorrowManager", code: -4, userInfo: [NSLocalizedDescriptionKey: msg])
                }

                guard let dataObj = json["data"] as? [String: Any],
                      let list = dataObj["list"] as? [[String: Any]] else {
                    throw NSError(domain: "LibraryBorrowManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "无借阅数据字段"])
                }

                var parsedBooks: [CampusBorrowedBook] = []
                for item in list {
                    let libraryDetail = item["libraryDetail"] as? [String: Any]
                    let detail = libraryDetail?["detail"] as? [String: Any]

                    let itemId = (item["id"] as? String) ?? (item["id"] as? NSNumber)?.stringValue ?? UUID().uuidString
                    let title = (detail?["title"] as? String) ?? (item["title"] as? String) ?? "未知书名"
                    let author = (detail?["authors"] as? String) ?? (detail?["author"] as? String) ?? ""
                    let publisher = (detail?["publishers"] as? String) ?? ""
                    let year = (detail?["cbrq"] as? String) ?? ""
                    let isbn = (detail?["isbn"] as? String) ?? ""
                    let callNo = (item["callNo"] as? String) ?? (detail?["classno"] as? String) ?? ""
                    let barcode = (item["barCode"] as? String) ?? ""
                    let location = (item["location"] as? String) ?? (libraryDetail?["locationLibrary"] as? String) ?? "合工大图书馆"
                    let borrowDate = (item["createdTime"] as? String) ?? ""
                    let dueDate = (item["returnTime"] as? String) ?? ""
                    let realReturnDate = item["realReturnTime"] as? String
                    let statusRaw = (item["status"] as? String) ?? (item["status"] as? NSNumber)?.stringValue ?? "2"

                    let book = CampusBorrowedBook(
                        id: itemId,
                        title: title,
                        author: author,
                        publisher: publisher,
                        year: year,
                        isbn: isbn,
                        callNumber: callNo,
                        barcode: barcode,
                        location: location,
                        borrowDate: borrowDate,
                        dueDate: dueDate,
                        statusRaw: statusRaw,
                        realReturnDate: realReturnDate
                    )
                    parsedBooks.append(book)
                }

                if parsedBooks.count == Self.readerRecordPageSize {
                    guard page < Self.maximumReaderRecordPages else {
                        completion(.failure(NSError(
                            domain: "LibraryBorrowManager",
                            code: -6,
                            userInfo: [NSLocalizedDescriptionKey: "借阅记录超过分页上限，未覆盖本地数据"]
                        )))
                        return
                    }
                    self.fetchReaderRecordPage(
                        token: token,
                        generation: generation,
                        page: page + 1,
                        accumulated: accumulated + parsedBooks,
                        completion: completion
                    )
                    return
                }

                let allBooks = accumulated + parsedBooks
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    guard self.syncGeneration == generation else {
                        self.stateLock.unlock()
                        completion(.failure(Self.cancelledError()))
                        return
                    }
                    self.books = allBooks
                    self.recordSync()
                    self.saveToStorage()
                    self.stateLock.unlock()
                    completion(.success(allBooks))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// 获取读者借阅统计（书架、借阅册数、预约等）
    public func fetchLibraryStats(token: String, generation: Int) {
        guard isCurrentSyncGeneration(generation) else { return }
        guard let url = URL(string: "https://lib.hfut.edu.cn/svc/circulate/myLibCall/listMyLibStatis") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authHeader = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        req.setValue(authHeader, forHTTPHeaderField: "authorization")
        req.httpBody = "{}".data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]] else { return }

            var borrowCount: Int?
            var bookshelfCount: Int?
            for item in list {
                let code = item["code"] as? String ?? ""
                let count = item["count"] as? Int ?? 0
                if code == "myborrow" {
                    borrowCount = count
                } else if code == "mybookshelf" {
                    bookshelfCount = count
                }
            }

            DispatchQueue.main.async {
                self.stateLock.lock()
                guard self.syncGeneration == generation else {
                    self.stateLock.unlock()
                    return
                }
                if let borrowCount {
                    self.totalBorrowStatsCount = borrowCount
                    SettingsManager.shared.libraryBorrowCount = borrowCount
                }
                if let bookshelfCount {
                    self.totalBookshelfStatsCount = bookshelfCount
                }
                self.stateLock.unlock()
                self.onDataChanged?()
            }
        }.resume()
    }

    private func saveToStorage() {
        do {
            let data = try JSONEncoder().encode(books)
            UserDefaults.standard.set(data, forKey: storageKey)
            DispatchQueue.main.async { [weak self] in
                self?.onDataChanged?()
            }
        } catch {
            print("Failed to save borrow records: \(error)")
        }
    }

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            books = try JSONDecoder().decode([CampusBorrowedBook].self, from: data)
        } catch {
            print("Failed to decode borrow records: \(error)")
        }
    }
}
