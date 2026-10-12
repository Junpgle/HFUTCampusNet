import Foundation
import AppKit

public class CampusCardService {
    public static let shared = CampusCardService()

    public private(set) var latestData: CampusCardData?

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
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CampusCardData.self, from: data) else {
            return
        }
        self.latestData = cached
    }

    private func saveCachedData(_ data: CampusCardData) {
        self.latestData = data
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
    }

    public func clearCache() {
        self.latestData = nil
        try? FileManager.default.removeItem(at: cacheURL)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .campusCardDidUpdate, object: nil)
        }
    }

    /// 拉取校园卡余额与近期消费账单（自动复用或静默获取慧新易校 Token）
    public func fetchData(completion: ((Result<CampusCardData, Error>) -> Void)? = nil) {
        if let token = SettingsManager.shared.huixinAuthToken, !token.isEmpty {
            executeCardQuery(token: token, allowRetry: true, completion: completion)
        } else {
            ElectricityService.shared.obtainHuiXinToken { [weak self] result in
                switch result {
                case .success(let token):
                    self?.executeCardQuery(token: token, allowRetry: false, completion: completion)
                case .failure(let err):
                    DispatchQueue.main.async { completion?(.failure(err)) }
                }
            }
        }
    }

    private func executeCardQuery(
        token: String,
        allowRetry: Bool,
        completion: ((Result<CampusCardData, Error>) -> Void)?
    ) {
        let authHeader = token.lowercased().hasPrefix("bearer ") ? token : "bearer \(token)"
        let cardURL = URL(string: "http://121.251.19.62/berserker-app/ykt/tsm/queryCard")!
        var cardReq = URLRequest(url: cardURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        cardReq.httpMethod = "GET"
        cardReq.setValue(authHeader, forHTTPHeaderField: "synjones-auth")
        cardReq.setValue(authHeader, forHTTPHeaderField: "Authorization")
        cardReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: cardReq) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let jsonCode = json?["code"] as? Int ?? httpStatus

            if httpStatus == 401 || httpStatus == 403 || jsonCode == 401 {
                SettingsManager.shared.huixinAuthToken = nil
                if allowRetry {
                    ElectricityService.shared.obtainHuiXinToken { retryRes in
                        switch retryRes {
                        case .success(let newToken):
                            self.executeCardQuery(token: newToken, allowRetry: false, completion: completion)
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

            guard let dataObj = json?["data"] as? [String: Any],
                  let cards = dataObj["card"] as? [[String: Any]],
                  let firstCard = cards.first else {
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

            // 接着拉取最近 150 笔一卡通消费流水（覆盖月度账单与三餐/商户结构分析）
            self.fetchTransactions(authHeader: authHeader, size: 150) { transactions in
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
                    self.saveCachedData(cardData)
                    self.checkLowBalanceWarning(cardData)
                    NotificationCenter.default.post(name: .campusCardDidUpdate, object: cardData)
                    completion?(.success(cardData))
                }
            }
        }.resume()
    }

    private func fetchTransactions(
        authHeader: String,
        size: Int,
        completion: @escaping ([CampusCardTransaction]) -> Void
    ) {
        guard let url = URL(string: "http://121.251.19.62/berserker-search/search/personal/turnover?current=1&size=\(size)") else {
            completion([])
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        req.httpMethod = "GET"
        req.setValue(authHeader, forHTTPHeaderField: "synjones-auth")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let records = dataObj["records"] as? [[String: Any]] else {
                completion([])
                return
            }

            var list: [CampusCardTransaction] = []
            for (idx, rec) in records.enumerated() {
                let orderId = (rec["orderId"] as? String) ?? "tx-\(idx)"
                let resume = (rec["resume"] as? String) ?? "校园卡交易"
                let turnoverType = (rec["turnoverType"] as? String) ?? "消费"
                let jnTimeStr = (rec["jndatetimeStr"] as? String) ?? (rec["effectdateStr"] as? String) ?? ""
                let tranAmtFen = (rec["tranamt"] as? Int) ?? Int((rec["tranamt"] as? Double) ?? 0)
                let cardBalFen = rec["cardBalance"] as? Int

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
            completion(list)
        }.resume()
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
