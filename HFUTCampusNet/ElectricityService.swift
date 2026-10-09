import Foundation
import AppKit

public class ElectricityService {
    public static let shared = ElectricityService()

    public private(set) var latestData: ElectricityData?

    private let cacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("cn.edu.hfut.campusnet.monitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent("dorm_electricity.json")
    }()

    private init() {
        loadCachedData()
    }

    private func loadCachedData() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(ElectricityData.self, from: data) else {
            return
        }
        self.latestData = cached
    }

    private func saveCachedData(_ data: ElectricityData) {
        self.latestData = data
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: cacheURL)
        }
    }

    /// 查询宿舍电费信息
    public func fetchData(completion: ((Result<ElectricityData, Error>) -> Void)? = nil) {
        guard let token = SettingsManager.shared.huixinAuthToken, !token.isEmpty else {
            let err = NSError(domain: "cn.edu.hfut.electricity", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未授权慧新易校，请先通过统一身份认证登录"])
            completion?(.failure(err))
            return
        }

        let campus = SettingsManager.shared.dormCampus
        let building = SettingsManager.shared.dormBuilding
        let room = SettingsManager.shared.dormRoom
        let endNumber = SettingsManager.shared.dormEndNumber

        let url = URL(string: "http://121.251.19.62/charge/feeitem/getThirdData")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0

        let authHeader = token.lowercased().hasPrefix("bearer ") ? token : "bearer \(token)"
        request.setValue(authHeader, forHTTPHeaderField: "synjones-auth")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        var formParams: [String: String] = [:]
        if campus.contains("宣城") {
            // 宣城校区
            formParams["feeitemid"] = "261"
            formParams["type"] = "IEC"
            // 格式: 300 + 楼栋 + 房间 + 端口 (例如 300731511)
            let roomCode = "300\(building)\(room)\(endNumber)"
            formParams["room"] = roomCode
        } else {
            // 合肥校区本科生
            formParams["feeitemid"] = "1"
            formParams["type"] = "IEC"
            formParams["campus"] = "1sh"
            formParams["level"] = "1"
            formParams["building"] = building
            formParams["room"] = room
        }

        let bodyString = formParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    completion?(.failure(error))
                }
                return
            }

            guard let data = data,
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let err = NSError(domain: "cn.edu.hfut.electricity", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器响应格式非 JSON"])
                DispatchQueue.main.async {
                    completion?(.failure(err))
                }
                return
            }

            // 解析 map -> showData
            guard let map = jsonObject["map"] as? [String: Any],
                  let showData = map["showData"] as? [String: Any] else {
                let msg = (jsonObject["msg"] as? String) ?? "未能获取到电费详情，请核对楼栋与寝室号配置"
                let err = NSError(domain: "cn.edu.hfut.electricity", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])
                DispatchQueue.main.async {
                    completion?(.failure(err))
                }
                return
            }

            var stringMap: [String: String] = [:]
            var parsedBalance: Double? = nil
            var parsedKWh: Double? = nil

            for (k, v) in showData {
                let vStr = "\(v)"
                stringMap[k] = vStr

                // 提取剩余金额
                // 可能是: key = "当前剩余金额", value = "35.50元"
                // 或者是: value = "南7号楼315南边照明:剩余金额:35.50"
                if k.contains("剩余金额") || k.contains("余额") || vStr.contains("剩余金额") {
                    let cleanStr = vStr.replacingOccurrences(of: "剩余金额", with: "")
                        .replacingOccurrences(of: ":", with: "")
                        .replacingOccurrences(of: "：", with: "")
                        .replacingOccurrences(of: "元", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let val = Double(cleanStr) {
                        parsedBalance = val
                    } else {
                        // 正则捕获浮点数
                        if let match = cleanStr.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
                            parsedBalance = Double(cleanStr[match])
                        }
                    }
                }

                // 提取剩余电量
                if k.contains("剩余电量") || k.contains("度") || vStr.contains("剩余电量") {
                    let cleanStr = vStr.replacingOccurrences(of: "剩余电量", with: "")
                        .replacingOccurrences(of: ":", with: "")
                        .replacingOccurrences(of: "：", with: "")
                        .replacingOccurrences(of: "度", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let val = Double(cleanStr) {
                        parsedKWh = val
                    } else if let match = cleanStr.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
                        parsedKWh = Double(cleanStr[match])
                    }
                }
            }

            var elecData = ElectricityData(
                campus: campus,
                building: building,
                room: room,
                balanceRMB: parsedBalance,
                remainingKWh: parsedKWh,
                lastUpdated: Date(),
                rawDetails: stringMap
            )

            // 如果只抓到了金额而没有明确的度数，按工大标准电价 (~0.58元/度) 估算度数以备用
            if elecData.remainingKWh == nil, let b = parsedBalance {
                elecData.remainingKWh = (b / 0.58 * 10).rounded() / 10
            }

            DispatchQueue.main.async {
                self.saveCachedData(elecData)

                // 记录至历史统计管理器
                CampusHistoryManager.shared.recordElectricity(elecData)

                // 低电费预警通知
                self.checkLowBalanceWarning(elecData)

                // 发送全局广播
                NotificationCenter.default.post(name: .dormElectricityDidUpdate, object: elecData)
                completion?(.success(elecData))
            }
        }
        task.resume()
    }

    /// 检查低电费并推送通知
    private func checkLowBalanceWarning(_ data: ElectricityData) {
        guard let bal = data.balanceRMB else { return }
        let threshold = SettingsManager.shared.electricityLowWarningThreshold
        if bal < threshold {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let today = formatter.string(from: Date())

            if SettingsManager.shared.lastNotifiedLowElectricityDate != today {
                SettingsManager.shared.lastNotifiedLowElectricityDate = today
                NotificationHelper.showNotification(
                    title: "⚠️ 宿舍电费不足预警",
                    subtitle: "\(SettingsManager.shared.dormRoomName) 电费仅剩 \(data.displayBalance)",
                    body: "当前余额低于预警线 (\(String(format: "%.0f", threshold))元)，请及时充值以免宿舍断电影响使用！"
                )
            }
        }
    }

    /// 离线/校外模式下通过慧新易校查询校园网流量与余额 (feeitemid=281)
    public func fetchSchoolNetInfoFromHuiXin(completion: ((_ flow: String?, _ balance: String?) -> Void)? = nil) {
        guard let token = SettingsManager.shared.huixinAuthToken, !token.isEmpty else {
            completion?(nil, nil)
            return
        }

        let url = URL(string: "http://121.251.19.62/charge/feeitem/getThirdData")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8.0

        let authHeader = token.lowercased().hasPrefix("bearer ") ? token : "bearer \(token)"
        request.setValue(authHeader, forHTTPHeaderField: "synjones-auth")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let body = "feeitemid=281&type=IEC&level=0"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = json["map"] as? [String: Any],
                  let showData = map["showData"] as? [String: Any] else {
                DispatchQueue.main.async { completion?(nil, nil) }
                return
            }

            let flowStr = showData["本期已使用流量"] as? String
            let feeStr = showData["储值余额"] as? String

            let cleanFlow = flowStr?.components(separatedBy: CharacterSet(charactersIn: "（(")).first?.trimmingCharacters(in: .whitespaces)
            let cleanFee = feeStr?.components(separatedBy: CharacterSet(charactersIn: "（(")).first?.trimmingCharacters(in: .whitespaces)

            DispatchQueue.main.async {
                completion?(cleanFlow, cleanFee)
            }
        }.resume()
    }
}
