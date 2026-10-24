import Foundation
import AppKit
import CryptoKit

private struct AccountScopedCampusCardCache: Codable {
    let accountKey: String
    let data: CampusCardData
}

public class CampusCardService {
    public static let shared = CampusCardService()

    public private(set) var latestData: CampusCardData?
    private let stateLock = NSLock()
    private var dataGeneration = 0

    private let cacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("cn.edu.hfut.campusnet.monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent("campus_card.json")
    }()

    private init() {
        loadCachedData()
    }

    private func loadCachedData() {
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty,
              let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(AccountScopedCampusCardCache.self, from: data),
              cached.accountKey == Self.cacheAccountKey(for: username) else {
            return
        }
        self.latestData = cached.data
    }

    private func saveCachedData(_ data: CampusCardData, generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard dataGeneration == generation else { return false }
        latestData = data
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let cache = AccountScopedCampusCardCache(accountKey: Self.cacheAccountKey(for: username), data: data)
        if preserveLegacyCacheBackup(), let encoded = try? JSONEncoder().encode(cache) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return true
    }

    private func preserveLegacyCacheBackup() -> Bool {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return true }
        if let data = try? Data(contentsOf: cacheURL),
           (try? JSONDecoder().decode(AccountScopedCampusCardCache.self, from: data)) != nil {
            return true
        }

        let backupURL = cacheURL.appendingPathExtension("pre-account-scope-v1.bak")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return true }
        do {
            try FileManager.default.copyItem(at: cacheURL, to: backupURL)
            return true
        } catch {
            print("校园卡缓存账号标记迁移备份失败: \(error.localizedDescription)")
            return false
        }
    }

    private static func cacheAccountKey(for username: String) -> String {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let identity = normalizedUsername.isEmpty ? "UNCONFIGURED" : normalizedUsername
        let digest = SHA256.hash(data: Data("portal-username:\(identity)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func clearCache() {
        stateLock.lock()
        dataGeneration &+= 1
        latestData = nil
        try? FileManager.default.removeItem(at: cacheURL)
        stateLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .campusCardDidUpdate, object: nil)
        }
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return dataGeneration == generation
    }

    private func beginFetchGeneration() -> Int {
        stateLock.lock()
        dataGeneration &+= 1
        let generation = dataGeneration
        stateLock.unlock()
        return generation
    }

    private func clearHuixinToken(generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard dataGeneration == generation else { return false }
        SettingsManager.shared.huixinAuthToken = nil
        return true
    }

    private func cachedTransactions(account: String, generation: Int) -> [CampusCardTransaction] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard dataGeneration == generation, latestData?.cardAccount == account else { return [] }
        return latestData?.transactions ?? []
    }

    private static func cancelledError() -> NSError {
        NSError(domain: "cn.edu.hfut.card", code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "账号已切换，本次校园卡同步已取消"])
    }

    /// 拉取校园卡余额与近期消费账单（自动复用或静默获取慧新易校 Token）
    public func fetchData(completion: ((Result<CampusCardData, Error>) -> Void)? = nil) {
        let generation = beginFetchGeneration()

        if let token = SettingsManager.shared.huixinAuthToken, !token.isEmpty {
            executeCardQuery(token: token, allowRetry: true, generation: generation, completion: completion)
        } else {
            ElectricityService.shared.obtainHuiXinToken { [weak self] result in
                guard let self, self.isCurrentGeneration(generation) else {
                    DispatchQueue.main.async { completion?(.failure(Self.cancelledError())) }
                    return
                }
                switch result {
                case .success(let token):
                    self.executeCardQuery(token: token, allowRetry: false, generation: generation, completion: completion)
                case .failure(let err):
                    DispatchQueue.main.async { completion?(.failure(err)) }
                }
            }
        }
    }

    private func executeCardQuery(
        token: String,
        allowRetry: Bool,
        useLegacyEndpoint: Bool = false,
        generation: Int,
        completion: ((Result<CampusCardData, Error>) -> Void)?
    ) {
        guard isCurrentGeneration(generation) else {
            DispatchQueue.main.async { completion?(.failure(Self.cancelledError())) }
            return
        }
        let authHeader = token.lowercased().hasPrefix("bearer ") ? token : "bearer \(token)"
        let cardURLString = useLegacyEndpoint
            ? "http://121.251.19.62/berserker-app/ykt/tsm/queryCard"
            : "http://121.251.19.62/berserker-app/ykt/tsm/getCampusCards?synAccessSource=h5"
        let cardURL = URL(string: cardURLString)!
        var cardReq = URLRequest(url: cardURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        cardReq.httpMethod = "GET"
        cardReq.setValue(authHeader, forHTTPHeaderField: "synjones-auth")
        cardReq.setValue(authHeader, forHTTPHeaderField: "Authorization")
        cardReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: cardReq) { [weak self] data, response, error in
            guard let self = self else { return }
            guard self.isCurrentGeneration(generation) else {
                DispatchQueue.main.async { completion?(.failure(Self.cancelledError())) }
                return
            }

            if let error = error {
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let jsonCode = json?["code"] as? Int ?? httpStatus

            if httpStatus == 401 || httpStatus == 403 || jsonCode == 401 || jsonCode == 403 {
                guard self.clearHuixinToken(generation: generation) else {
                    DispatchQueue.main.async { completion?(.failure(Self.cancelledError())) }
                    return
                }
                if allowRetry {
                    ElectricityService.shared.obtainHuiXinToken { retryRes in
                        guard self.isCurrentGeneration(generation) else {
                            DispatchQueue.main.async { completion?(.failure(Self.cancelledError())) }
                            return
                        }
                        switch retryRes {
                        case .success(let newToken):
                            self.executeCardQuery(token: newToken, allowRetry: false, useLegacyEndpoint: useLegacyEndpoint, generation: generation, completion: completion)
                        case .failure(let err):
                            DispatchQueue.main.async { completion?(.failure(err)) }
                        }
                    }
                } else {
                    let err = NSError(domain: "cn.edu.hfut.card", code: 401, userInfo: [NSLocalizedDescriptionKey: "慧新易校授权已过期，请核对学号与密码"])
                    DispatchQueue.main.async { completion?(.failure(err)) }
                }
                return
            }

            let dataObject = json?["data"] as? [String: Any]
            let cards = (dataObject?["card"] as? [[String: Any]])
                ?? (dataObject?["cards"] as? [[String: Any]])
                ?? (dataObject?["cardList"] as? [[String: Any]])
                ?? (json?["data"] as? [[String: Any]])
            guard let firstCard = cards?.first else {
                if !useLegacyEndpoint {
                    self.executeCardQuery(token: token, allowRetry: false, useLegacyEndpoint: true, generation: generation, completion: completion)
                    return
                }
                let err = NSError(domain: "cn.edu.hfut.card", code: -2, userInfo: [NSLocalizedDescriptionKey: "未能解析到校园一卡通账户信息"])
                DispatchQueue.main.async { completion?(.failure(err)) }
                return
            }

            let account = (firstCard["account"] as? String) ?? ""
            let holderName = (firstCard["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let deptName = (firstCard["department_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let dbBalanceFen = (firstCard["db_balance"] as? Int) ?? Int((firstCard["db_balance"] as? Double) ?? 0)
            let unsettleFen = (firstCard["unsettle_amount"] as? Int) ?? Int((firstCard["unsettle_amount"] as? Double) ?? 0)
            let lostFlag = (firstCard["lostflag"] as? Int) ?? 0
            let freezeFlag = (firstCard["freezeflag"] as? Int) ?? 0

            let statusText: String
            if lostFlag != 0 {
                statusText = "已挂失"
            } else if freezeFlag != 0 {
                statusText = "已冻结"
            } else {
                statusText = "正常"
            }

            let balanceRMB = Double(dbBalanceFen) / 100.0
            let unsettleRMB = Double(unsettleFen) / 100.0

            // 分页同步历史流水，并与本地归档合并，避免接口分页上限或短暂失败缩短已有历史。
            self.fetchTransactions(authHeader: authHeader, generation: generation, page: 1, size: 150, accumulated: []) { fetchedTransactions in
                let previousTransactions = self.cachedTransactions(account: account, generation: generation)
                let transactions = self.mergeTransactions(previousTransactions + fetchedTransactions)
                let cardData = CampusCardData(
                    cardAccount: account,
                    holderName: holderName,
                    departmentName: deptName,
                    balanceRMB: balanceRMB,
                    unsettleAmountRMB: unsettleRMB,
                    cardStatusText: statusText,
                    transactions: transactions,
                    lastUpdated: Date()
                )

                DispatchQueue.main.async {
                    guard self.saveCachedData(cardData, generation: generation) else {
                        completion?(.failure(Self.cancelledError()))
                        return
                    }
                    self.checkLowBalanceWarning(cardData)
                    NotificationCenter.default.post(name: .campusCardDidUpdate, object: cardData)
                    completion?(.success(cardData))
                }
            }
        }.resume()
    }

    private func fetchTransactions(
        authHeader: String,
        generation: Int,
        page: Int,
        size: Int,
        accumulated: [CampusCardTransaction],
        completion: @escaping ([CampusCardTransaction]) -> Void
    ) {
        guard isCurrentGeneration(generation) else {
            completion(accumulated)
            return
        }
        // 防止异常分页元数据造成无限请求；正常情况下按接口总页数提前结束。
        let maximumPages = 100
        guard page <= maximumPages,
              var components = URLComponents(string: "http://121.251.19.62/berserker-search/search/personal/turnover") else {
            completion(accumulated)
            return
        }
        components.queryItems = [
            URLQueryItem(name: "current", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "synAccessSource", value: "h5")
        ]
        guard let url = components.url else {
            completion(accumulated)
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        req.httpMethod = "GET"
        req.setValue(authHeader, forHTTPHeaderField: "synjones-auth")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            guard self.isCurrentGeneration(generation) else {
                completion(accumulated)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let records = dataObj["records"] as? [[String: Any]] else {
                // 后续页失败时仍保留已取到的记录和旧缓存。
                _ = response
                _ = error
                completion(accumulated)
                return
            }

            var list: [CampusCardTransaction] = []
            for rec in records {
                let resume = (rec["resume"] as? String) ?? "校园卡交易"
                let turnoverType = (rec["turnoverType"] as? String) ?? "消费"
                let jnTimeStr = (rec["jndatetimeStr"] as? String) ?? (rec["effectdateStr"] as? String) ?? ""
                let tranAmtFen = Self.integerValue(rec["tranamt"]) ?? 0
                let cardBalFen = Self.integerValue(rec["cardBalance"])
                let orderId = (rec["orderId"] as? String)
                    ?? (rec["orderId"] as? NSNumber)?.stringValue
                    ?? "tx-\(jnTimeStr)|\(resume)|\(turnoverType)|\(tranAmtFen)|\(cardBalFen ?? -1)"

                let amountRMB = Double(abs(tranAmtFen)) / 100.0
                let balAfterRMB = cardBalFen.map { Double($0) / 100.0 }

                let item = CampusCardTransaction(
                    id: orderId,
                    merchantName: resume,
                    amountRMB: amountRMB,
                    balanceAfterRMB: balAfterRMB,
                    turnoverType: turnoverType,
                    dateTimeString: jnTimeStr
                )
                list.append(item)
            }

            let combined = accumulated + list
            let total = Self.integerValue(dataObj["total"])
            let totalPages = Self.integerValue(dataObj["pages"])
            let uniqueCount = self.mergeTransactions(combined).count
            let hasTotal = total.map { $0 > 0 } ?? false
            let hasPageCount = totalPages.map { $0 > 0 } ?? false
            let metadataShowsMore = (hasTotal && uniqueCount < (total ?? 0)) ||
                (hasPageCount && page < (totalPages ?? 0))
            let hasPaginationMetadata = hasTotal || hasPageCount
            let reachedEnd = records.isEmpty ||
                (hasPaginationMetadata && !metadataShowsMore) ||
                (!hasPaginationMetadata && records.count < size) ||
                page >= maximumPages
            if reachedEnd {
                completion(self.mergeTransactions(combined))
            } else {
                self.fetchTransactions(
                    authHeader: authHeader,
                    generation: generation,
                    page: page + 1,
                    size: size,
                    accumulated: combined,
                    completion: completion
                )
            }
        }.resume()
    }

    private func mergeTransactions(_ transactions: [CampusCardTransaction]) -> [CampusCardTransaction] {
        var byID: [String: CampusCardTransaction] = [:]
        for (index, transaction) in transactions.enumerated() {
            let stableID = transaction.id.isEmpty
                ? "\(transaction.dateTimeString)|\(transaction.merchantName)|\(transaction.amountRMB)|\(index)"
                : transaction.id
            byID[stableID] = transaction
        }
        return byID.values.sorted {
            if $0.dateTimeString != $1.dateTimeString {
                return $0.dateTimeString > $1.dateTimeString
            }
            return $0.id > $1.id
        }
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func checkLowBalanceWarning(_ data: CampusCardData) {
        let threshold = SettingsManager.shared.campusCardLowWarningThreshold
        guard data.balanceRMB < threshold else { return }

        let todayStr = CourseCalendarHelper.dateString(from: Date())
        guard SettingsManager.shared.lastNotifiedLowCardBalanceDate != todayStr else { return }
        SettingsManager.shared.lastNotifiedLowCardBalanceDate = todayStr

        NotificationHelper.showNotification(
            title: "💳 校园一卡通余额不足预警",
            subtitle: "当前卡内余额仅剩 \(data.displayBalance)",
            body: "已低于您设定的预警线 (\(String(format: "%.0f", threshold))元)，去食堂或超市前请记得在慧新易校或支付宝充值！"
        )
    }
}
