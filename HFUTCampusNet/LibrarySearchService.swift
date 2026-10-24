import Foundation

/// 馆藏单册物理分布与借阅状态
public struct CampusBookHolding: Codable, Equatable {
    public var campus: String        // 校区，如 翡翠湖校区 / 屯溪路校区 / 宣城校区
    public var location: String      // 馆藏借阅处，如 翡翠湖校区《中图法》自科借阅处（A301-302)
    public var callNumber: String    // 索书号，如 TP303/205
    public var status: String        // 状态，如 可借 / 借出 / 阅览
    public var barcode: String       // 条形码 / 登录号

    public init(campus: String, location: String, callNumber: String, status: String, barcode: String = "") {
        self.campus = campus
        self.location = location
        self.callNumber = callNumber
        self.status = status
        self.barcode = barcode
    }

    public var isAvailable: Bool {
        guard !status.contains("不可借") else { return false }
        return status.contains("可借") || status.contains("在馆")
    }
}

/// 检索返回的图书条目
public struct CampusBookItem: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var authors: String
    public var publishers: String
    public var year: String
    public var isbn: String
    public var classNo: String
    public var holdings: [CampusBookHolding]
    public var rawRow: [String: Any]?

    public init(
        id: String,
        title: String,
        authors: String,
        publishers: String,
        year: String,
        isbn: String,
        classNo: String,
        holdings: [CampusBookHolding] = [],
        rawRow: [String: Any]? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.publishers = publishers
        self.year = year
        self.isbn = isbn
        self.classNo = classNo
        self.holdings = holdings
        self.rawRow = rawRow
    }

    public static func == (lhs: CampusBookItem, rhs: CampusBookItem) -> Bool {
        return lhs.id == rhs.id && lhs.title == rhs.title
    }

    /// 可借册数
    public var availableCount: Int {
        return holdings.filter { $0.isAvailable }.count
    }

    /// 馆藏总结文本
    public var holdingSummaryText: String {
        if holdings.isEmpty {
            return "暂无纸本馆藏或仅有电子资源"
        }
        let available = availableCount
        let total = holdings.count
        let campuses = Array(Set(holdings.map { $0.campus })).joined(separator: " · ")
        return "馆藏 \(total) 册 · 可借 \(available) 册 (分布于 \(campuses))"
    }
}

/// 图书馆公开统计
public struct LibraryPublicStats {
    public var totalSeats: String = "--"
    public var occupiedSeats: String = "--"
    public var availableSeats: String = "--"
    public var visitsToday: String = "--"
    public var loansToday: String = "--"
}

/// 校内图书检索服务（直接调用合工大 OPAC 原生 API，返回结构化 JSON，并支持收藏、书架、预约）
public final class LibrarySearchService: NSObject {
    public static let shared = LibrarySearchService()

    private struct AccountOperationSnapshot {
        let username: String
        let token: String?
        let libraryUserName: String
        let generation: Int
    }

    private let searchAPI = "https://lib.hfut.edu.cn/svc/circulate/collectionSearch/getCollectionSearch"
    private var session: URLSession!
    private let accountOperationLock = NSLock()
    private var accountOperationGeneration = 0

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        session = URLSession(configuration: config)
    }

    public func cancelPendingAccountOperations() {
        accountOperationLock.lock()
        accountOperationGeneration &+= 1
        accountOperationLock.unlock()
    }

    private func accountOperationSnapshot() -> AccountOperationSnapshot {
        accountOperationLock.lock()
        let generation = accountOperationGeneration
        accountOperationLock.unlock()
        return AccountOperationSnapshot(
            username: SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            token: SettingsManager.shared.libraryToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            libraryUserName: SettingsManager.shared.libraryUserName ?? "合工大读者",
            generation: generation
        )
    }

    private func isCurrentAccountOperation(_ snapshot: AccountOperationSnapshot) -> Bool {
        accountOperationLock.lock()
        let isCurrentGeneration = accountOperationGeneration == snapshot.generation
        accountOperationLock.unlock()
        return isCurrentGeneration &&
            SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot.username
    }

    private func deliverAccountOperationResult(
        _ result: Result<String, Error>,
        snapshot: AccountOperationSnapshot,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            guard self.isCurrentAccountOperation(snapshot) else {
                completion(.failure(Self.cancelledAccountOperationError()))
                return
            }
            completion(result)
        }
    }

    private static func cancelledAccountOperationError() -> NSError {
        NSError(
            domain: "LibrarySearchService",
            code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "账号已切换，本次图书馆操作已取消"]
        )
    }

    /// 执行校内图书检索
    public func search(keyword: String, page: Int = 1, size: Int = 20, completion: @escaping (Result<[CampusBookItem], Error>) -> Void) {
        let cleanKw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKw.isEmpty else {
            completion(.success([]))
            return
        }
        guard let url = URL(string: searchAPI) else {
            completion(.failure(NSError(domain: "LibrarySearch", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的检索接口地址"])))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "page": page,
            "size": size,
            "sort": "-11",
            "key": cleanKw,
            "stats": true,
            "unitId": "hfut"
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let message = statusCode >= 0 ? "图书检索请求失败 (HTTP \(statusCode))" : "图书检索响应状态无效"
                let responseError = NSError(domain: "LibrarySearch", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
                DispatchQueue.main.async { completion(.failure(responseError)) }
                return
            }
            guard let data = data else {
                let responseError = NSError(domain: "LibrarySearch", code: -2, userInfo: [NSLocalizedDescriptionKey: "图书检索响应为空"])
                DispatchQueue.main.async { completion(.failure(responseError)) }
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataObj = json["data"] as? [String: Any],
                      let innerData = dataObj["data"] as? [String: Any],
                      let rows = innerData["rows"] as? [[String: Any]] else {
                    let responseError = NSError(domain: "LibrarySearch", code: -3, userInfo: [NSLocalizedDescriptionKey: "图书检索响应格式异常"])
                    DispatchQueue.main.async { completion(.failure(responseError)) }
                    return
                }

                let items: [CampusBookItem] = rows.compactMap { row in
                    let rawTitle = (row["title"] as? String ?? "")
                        .replacingOccurrences(of: "<span class='keywords'>", with: "")
                        .replacingOccurrences(of: "</span>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawTitle.isEmpty else { return nil }

                    let authors = row["authors"] as? String ?? ""
                    let publishers = row["publishers"] as? String ?? ""
                    let yearVal = row["year"]
                    let yearStr = (yearVal as? Int).map { "\($0)" } ?? (yearVal as? String ?? "")
                    let isbn = row["isbn"] as? String ?? ""
                    let classNo = row["classNo"] as? String ?? ""
                    let id = row["id"] as? String ?? UUID().uuidString

                    // 解析馆藏分布
                    let rawGc = row["gc"] as? [[String: Any]] ?? []
                    let holdings: [CampusBookHolding] = rawGc.map { g in
                        let campus = g["c1"] as? String ?? "合肥校区"
                        let loc = g["c2"] as? String ?? ""
                        let call = g["in"] as? String ?? classNo
                        let status = g["js"] as? String ?? "在馆"
                        let barcode = g["po"] as? String ?? ""
                        return CampusBookHolding(campus: campus, location: loc, callNumber: call, status: status, barcode: barcode)
                    }

                    return CampusBookItem(
                        id: id,
                        title: rawTitle,
                        authors: authors,
                        publishers: publishers,
                        year: yearStr,
                        isbn: isbn,
                        classNo: classNo,
                        holdings: holdings,
                        rawRow: row
                    )
                }

                DispatchQueue.main.async {
                    completion(.success(items))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    // MARK: - 真实读者功能：收藏图书 (POST /svc/circulate/myCollect/insertMyCollect)

    public func collectBook(item: CampusBookItem, completion: @escaping (Result<String, Error>) -> Void) {
        let snapshot = accountOperationSnapshot()
        guard !snapshot.username.isEmpty else {
            completion(.failure(NSError(domain: "LibrarySearchService", code: 401, userInfo: [NSLocalizedDescriptionKey: "缺少当前读者学号，请先在偏好设置中保存学号"])))
            return
        }
        guard let token = snapshot.token, !token.isEmpty else {
            completion(.failure(NSError(domain: "LibrarySearchService", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未完成统一身份认证，请先点击「同步借阅」"])))
            return
        }
        guard isCurrentAccountOperation(snapshot) else {
            deliverAccountOperationResult(.failure(Self.cancelledAccountOperationError()), snapshot: snapshot, completion: completion)
            return
        }
        guard let url = URL(string: "https://lib.hfut.edu.cn/svc/circulate/myCollect/insertMyCollect") else { return }
        let finish: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.deliverAccountOperationResult(result, snapshot: snapshot, completion: completion)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authHeader = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        req.setValue(authHeader, forHTTPHeaderField: "authorization")

        let literatureObj: [String: Any] = item.rawRow ?? [
            "id": item.id,
            "title": item.title,
            "authors": item.authors,
            "publishers": item.publishers,
            "isbn": item.isbn,
            "classNo": item.classNo
        ]
        let payload: [String: Any] = ["literature": literatureObj]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: req) { data, _, error in
            if let error = error {
                finish(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                finish(.failure(NSError(domain: "LibrarySearchService", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器响应格式错误"])))
                return
            }
            let success = (json["success"] as? Bool) ?? false
            if success {
                finish(.success("已将《\(item.title)》加入您的个人收藏！"))
            } else {
                let msg = (json["message"] as? String) ?? "收藏失败"
                finish(.failure(NSError(domain: "LibrarySearchService", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])))
            }
        }.resume()
    }

    // MARK: - 真实读者功能：加入书架 (POST /svc/circulate/readerBook/insert)

    public func addBookToShelf(item: CampusBookItem, completion: @escaping (Result<String, Error>) -> Void) {
        let snapshot = accountOperationSnapshot()
        guard let token = snapshot.token, !token.isEmpty else {
            completion(.failure(NSError(domain: "LibrarySearchService", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未完成统一身份认证，请先点击「同步借阅」"])))
            return
        }
        let user = snapshot.username
        guard !user.isEmpty else {
            completion(.failure(NSError(domain: "LibrarySearchService", code: 401, userInfo: [NSLocalizedDescriptionKey: "缺少当前读者学号，请先在偏好设置中保存学号再加入书架"])))
            return
        }
        guard isCurrentAccountOperation(snapshot) else {
            deliverAccountOperationResult(.failure(Self.cancelledAccountOperationError()), snapshot: snapshot, completion: completion)
            return
        }
        guard let url = URL(string: "https://lib.hfut.edu.cn/svc/circulate/readerBook/insert") else { return }
        let finish: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.deliverAccountOperationResult(result, snapshot: snapshot, completion: completion)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authHeader = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        req.setValue(authHeader, forHTTPHeaderField: "authorization")

        let bookObj: [String: Any] = item.rawRow ?? [
            "id": item.id,
            "title": item.title,
            "authors": item.authors,
            "publishers": item.publishers,
            "isbn": item.isbn,
            "classNo": item.classNo
        ]
        let payload: [String: Any] = [
            "book": bookObj,
            "sourceType": "1",
            "tenantId": "hfut",
            "tenantName": "合肥工业大学",
            "userId": user,
            "userName": snapshot.libraryUserName
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: req) { data, _, error in
            if let error = error {
                finish(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                finish(.failure(NSError(domain: "LibrarySearchService", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器响应格式错误"])))
                return
            }
            let code = json["code"] as? String
            let success = (json["success"] as? Bool) ?? (code == "0")
            if success {
                finish(.success("已将《\(item.title)》加入您的图书馆书架！"))
            } else {
                let msg = (json["message"] as? String) ?? "加入书架失败"
                finish(.failure(NSError(domain: "LibrarySearchService", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])))
            }
        }.resume()
    }

    // MARK: - 真实读者功能：预约在馆图书 (POST /svc/circulate/readerBooking/insert)

    public func reserveBook(barcode: String, completion: @escaping (Result<String, Error>) -> Void) {
        let snapshot = accountOperationSnapshot()
        guard !snapshot.username.isEmpty else {
            completion(.failure(NSError(domain: "LibrarySearchService", code: 401, userInfo: [NSLocalizedDescriptionKey: "缺少当前读者学号，请先在偏好设置中保存学号"])))
            return
        }
        guard let token = snapshot.token, !token.isEmpty else {
            completion(.failure(NSError(domain: "LibrarySearchService", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未完成统一身份认证，请先点击「同步借阅」"])))
            return
        }
        guard isCurrentAccountOperation(snapshot) else {
            deliverAccountOperationResult(.failure(Self.cancelledAccountOperationError()), snapshot: snapshot, completion: completion)
            return
        }
        guard let url = URL(string: "https://lib.hfut.edu.cn/svc/circulate/readerBooking/insert") else { return }
        let finish: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.deliverAccountOperationResult(result, snapshot: snapshot, completion: completion)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authHeader = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        req.setValue(authHeader, forHTTPHeaderField: "authorization")

        let payload: [String: Any] = ["barCode": barcode]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: req) { data, _, error in
            if let error = error {
                finish(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                finish(.failure(NSError(domain: "LibrarySearchService", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器响应格式错误"])))
                return
            }
            let success = (json["success"] as? Bool) ?? (json["code"] as? String == "0")
            if success {
                finish(.success("图书预约申请已成功提交！到馆后将为您保留。"))
            } else {
                let msg = (json["message"] as? String) ?? "当前图书暂不可预约（可能在架可直接外借或已被他人预约）"
                finish(.failure(NSError(domain: "LibrarySearchService", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])))
            }
        }.resume()
    }
}
