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
        guard SettingsManager.shared.isDormConfigured,
              let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(ElectricityData.self, from: data) else {
            return
        }
        // 若配置与缓存宿舍不一致，丢弃旧缓存
        if cached.building != SettingsManager.shared.dormBuilding || cached.room != SettingsManager.shared.dormRoom {
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

    /// 查询宿舍电费信息（支持静默自动登录）
    public func fetchData(completion: ((Result<ElectricityData, Error>) -> Void)? = nil) {
        guard SettingsManager.shared.isDormConfigured else {
            let err = NSError(domain: "cn.edu.hfut.electricity", code: 400, userInfo: [NSLocalizedDescriptionKey: "尚未配置宿舍楼栋与房间号，请在「设置」中填写您的宿舍信息"])
            DispatchQueue.main.async {
                completion?(.failure(err))
            }
            return
        }

        if let token = SettingsManager.shared.huixinAuthToken, !token.isEmpty {
            self.executeFeeQuery(token: token) { [weak self] result in
                switch result {
                case .success(let data):
                    completion?(.success(data))
                case .failure:
                    // Token 可能失效，尝试通过已保存学号密码静默重新登录
                    self?.loginHuiXinAndRetry(completion: completion)
                }
            }
        } else {
            // 没有 Token，直接尝试通过已保存学号密码静默登录
            self.loginHuiXinAndRetry(completion: completion)
        }
    }

    /// 静默调用慧新易校 OAuth 登录获取 Token
    private func loginHuiXinAndRetry(completion: ((Result<ElectricityData, Error>) -> Void)? = nil) {
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = SettingsManager.shared.portalPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty else {
            let err = NSError(domain: "cn.edu.hfut.electricity", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未配置学号或密码，请在设置中保存学号与密码，或通过「统一身份认证同步」登录"])
            DispatchQueue.main.async {
                completion?(.failure(err))
            }
            return
        }

        let url = URL(string: "http://121.251.19.62/berserker-auth/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        // Basic mobile_service_platform:mobile_service_platform_secret
        request.setValue("Basic bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm06bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm1fc2VjcmV0", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(username)&password=\(password)&grant_type=password&logintype=sno"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String, !token.isEmpty else {
                let err = NSError(domain: "cn.edu.hfut.electricity", code: 401, userInfo: [NSLocalizedDescriptionKey: "慧新易校授权失败，请核对学号与密码"])
                DispatchQueue.main.async { completion?(.failure(err)) }
                return
            }

            SettingsManager.shared.huixinAuthToken = token
            self.executeFeeQuery(token: token, completion: completion)
        }.resume()
    }

    /// 执行电费接口查询
    private func executeFeeQuery(token: String, completion: ((Result<ElectricityData, Error>) -> Void)? = nil) {
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
            let cleanBuilding = building.filter { $0.isNumber }
            let cleanRoom = room.filter { $0.isNumber }
            let cleanEnd = endNumber.filter { $0.isNumber }
            let roomCode: String
            if cleanRoom.hasPrefix("30") && cleanRoom.count == 9 {
                // 用户直接输入了 9 位标准代码 (例如 300731511)
                roomCode = cleanRoom
            } else {
                // 宣城校区官方规范: 30 + 楼宇(2位) + 房间号(3位) + 端口(11/12/21/22)
                let bNum = Int(cleanBuilding) ?? 0
                let bStr = String(format: "%02d", bNum)
                let rNum = Int(cleanRoom) ?? 0
                let rStr = cleanRoom.count >= 3 ? cleanRoom : String(format: "%03d", rNum)
                let suffix = cleanEnd.isEmpty ? "11" : cleanEnd
                roomCode = "30\(bStr)\(rStr)\(suffix)"
            }
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
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            }

            guard let data = data,
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let err = NSError(domain: "cn.edu.hfut.electricity", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器响应格式非 JSON"])
                DispatchQueue.main.async { completion?(.failure(err)) }
                return
            }

            // 检查是否有 401 权限问题
            if let code = jsonObject["code"] as? Int, code == 401 {
                let err = NSError(domain: "cn.edu.hfut.electricity", code: 401, userInfo: [NSLocalizedDescriptionKey: "登录凭据已过期"])
                DispatchQueue.main.async { completion?(.failure(err)) }
                return
            }

            // 解析 map -> showData
            guard let map = jsonObject["map"] as? [String: Any],
                  let showData = map["showData"] as? [String: Any] else {
                let msg = (jsonObject["msg"] as? String) ?? "未能获取到电费详情，请核对楼栋与寝室号配置"
                let err = NSError(domain: "cn.edu.hfut.electricity", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])
                DispatchQueue.main.async { completion?(.failure(err)) }
                return
            }

            var stringMap: [String: String] = [:]
            var parsedBalance: Double? = nil
            var parsedKWh: Double? = nil

            for (k, v) in showData {
                let vStr = "\(v)"
                stringMap[k] = vStr

                // 精准提取剩余金额：
                // 常见返回：例如 "房间名称: 300731511 剩余金额:33.815300"
                // 关键点：必须截取 "剩余金额" 后方的子字符串进行正则数字匹配，严防把房间号 (300731511) 误识别为金额！
                if vStr.contains("剩余金额") {
                    let afterKeyword = vStr.components(separatedBy: "剩余金额").last ?? ""
                    if let match = afterKeyword.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
                        if let val = Double(afterKeyword[match]) {
                            parsedBalance = (val * 100).rounded() / 100.0
                        }
                    }
                } else if k.contains("剩余金额") || k.contains("余额") {
                    if let match = vStr.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
                        if let val = Double(vStr[match]) {
                            parsedBalance = (val * 100).rounded() / 100.0
                        }
                    }
                }

                // 精准提取剩余电量：
                if vStr.contains("剩余电量") {
                    let afterKeyword = vStr.components(separatedBy: "剩余电量").last ?? ""
                    if let match = afterKeyword.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
                        parsedKWh = Double(afterKeyword[match])
                    }
                } else if k.contains("剩余电量") || k.contains("度") {
                    if let match = vStr.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
                        parsedKWh = Double(vStr[match])
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

            // 若只抓取到了金额而无明确度数，按工大标准电价 (~0.58元/度) 智能折算
            if elecData.remainingKWh == nil, let b = parsedBalance {
                elecData.remainingKWh = (b / 0.58 * 10).rounded() / 10.0
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
        func query(token: String) {
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

        if let token = SettingsManager.shared.huixinAuthToken, !token.isEmpty {
            query(token: token)
        } else {
            loginHuiXinAndRetry { _ in
                if let token = SettingsManager.shared.huixinAuthToken {
                    query(token: token)
                } else {
                    completion?(nil, nil)
                }
            }
        }
    }
}
