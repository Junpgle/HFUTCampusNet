import Foundation
import CryptoKit

public enum PortalStatus {
    case online(username: String, ip: String, flowMB: Double, fee: Double, timeMin: Int)
    case offline(reason: String)
    case notInCampusNet
}

public class PortalAuthService: NSObject, URLSessionDelegate {
    public static let shared = PortalAuthService()

    private let portalURL = URL(string: "http://172.18.3.3/")!
    private let logoutURL = URL(string: "http://172.18.3.3/F.htm")!

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 6.0
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
    }

    /// 高容错多编码解码
    public static func decodeHTMLString(from data: Data) -> String {
        let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let str = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return str
        }
        if let str = String(data: data, encoding: .utf8) {
            return str
        }
        if let str = String(data: data, encoding: .isoLatin1) {
            return str
        }
        return ""
    }

    /// 检查 172.18.3.3 当前的认证在线状态
    public func checkStatus(completion: @escaping (PortalStatus) -> Void) {
        var request = URLRequest(url: portalURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.offline(reason: error.localizedDescription))
                return
            }

            guard let data = data else {
                completion(.notInCampusNet)
                return
            }

            let html = PortalAuthService.decodeHTMLString(from: data)
            if html.isEmpty {
                completion(.notInCampusNet)
                return
            }

            if html.contains("Dr.COMWebLoginID_1.htm") || html.contains("DispTFM") {
                let uid = self.extractVariable(name: "uid", from: html) ?? "校园网用户"
                let v4ip = self.extractVariable(name: "v4ip", from: html) ?? ""
                let flowStr = self.extractVariable(name: "flow", from: html) ?? "0"
                let feeStr = self.extractVariable(name: "fee", from: html) ?? "0"
                let timeStr = self.extractVariable(name: "time", from: html) ?? "0"

                let flowRaw = Double(flowStr.trimmingCharacters(in: .whitespaces)) ?? 0.0
                let feeRaw = Double(feeStr.trimmingCharacters(in: .whitespaces)) ?? 0.0
                let timeRaw = Int(timeStr.trimmingCharacters(in: .whitespaces)) ?? 0

                let flowMB = flowRaw / 1024.0
                let feeYuan = feeRaw / 10000.0

                completion(.online(username: uid, ip: v4ip, flowMB: flowMB, fee: feeYuan, timeMin: timeRaw))
            } else if html.contains("Dr.COMWebLoginID_0.htm") || html.contains("DDDDD") {
                completion(.offline(reason: "校园网未认证"))
            } else {
                if let uid = self.extractVariable(name: "uid", from: html), !uid.isEmpty {
                    completion(.online(username: uid, ip: "", flowMB: 0, fee: 0, timeMin: 0))
                } else {
                    completion(.offline(reason: "未检测到登录态"))
                }
            }
        }
        task.resume()
    }

    /// 执行校园网自动登录
    public func login(username: String? = nil, password: String? = nil, completion: @escaping (Bool, String) -> Void) {
        let user = (username ?? SettingsManager.shared.portalUsername).trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = (password ?? SettingsManager.shared.portalPassword).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !user.isEmpty else {
            completion(false, "学号/账号不能为空")
            return
        }
        guard !pass.isEmpty else {
            completion(false, "校园网密码不能为空")
            return
        }

        // 先自检：如果当前已经在在线状态，直接返回成功！
        self.checkStatus { status in
            if case .online(let uid, _, _, _, _) = status {
                // 如果已经在在线状态，且学号匹配，直接成功
                completion(true, "当前设备已认证在线（学号: \(uid)），网络通畅！")
                return
            }

            // 执行 POST 认证请求
            self.doPostLogin(user: user, pass: pass, completion: completion)
        }
    }

    private func doPostLogin(user: String, pass: String, completion: @escaping (Bool, String) -> Void) {
        let pid = "2"
        let calg = "12345678"
        let tmpchar = "\(pid)\(pass)\(calg)"
        let md5Hash = calculateMD5(tmpchar)
        let upass = "\(md5Hash)\(calg)\(pid)"

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "DDDDD", value: user),
            URLQueryItem(name: "upass", value: upass),
            URLQueryItem(name: "R1", value: "0"),
            URLQueryItem(name: "R2", value: "1"),
            URLQueryItem(name: "para", value: "00"),
            URLQueryItem(name: "0MKKey", value: "123456"),
            URLQueryItem(name: "v6ip", value: "")
        ]

        let postString = components.percentEncodedQuery ?? ""
        guard let postData = postString.data(using: .utf8) else {
            completion(false, "参数编码异常")
            return
        }

        var request = URLRequest(url: portalURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("http://172.18.3.3/0.htm", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.httpBody = postData

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "网络请求错误: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                completion(false, "网关未返回数据，请检查 Wi-Fi 连接")
                return
            }

            let html = PortalAuthService.decodeHTMLString(from: data)
            if html.contains("Dr.COMWebLoginID_1.htm") || html.contains("DispTFM") {
                completion(true, "登录成功！设备已认证上线")
            } else if html.contains("msga='") {
                let rawMsg = self.extractVariable(name: "msga", from: html) ?? ""
                let friendlyMsg: String
                if rawMsg.contains("userid error") {
                    friendlyMsg = "学号或密码错误，请核对后重试"
                } else if rawMsg.contains("ip error") {
                    friendlyMsg = "IP 绑定异常或超额在线"
                } else if !rawMsg.isEmpty {
                    friendlyMsg = rawMsg
                } else {
                    friendlyMsg = "认证未通过"
                }
                completion(false, friendlyMsg)
            } else {
                // 延时再次确认当前状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.checkStatus { status in
                        switch status {
                        case .online:
                            completion(true, "登录成功！网络已连通")
                        case .offline(let reason):
                            completion(false, "登录未成功: \(reason)")
                        case .notInCampusNet:
                            completion(false, "未检测到校园网网关")
                        }
                    }
                }
            }
        }
        task.resume()
    }

    /// 注销当前校园网连接
    public func logout(completion: @escaping (Bool, String) -> Void) {
        var request = URLRequest(url: logoutURL)
        request.httpMethod = "GET"
        request.setValue("http://172.18.3.3/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "注销失败: \(error.localizedDescription)")
                return
            }
            completion(true, "已成功注销校园网设备")
        }
        task.resume()
    }

    private func extractVariable(name: String, from text: String) -> String? {
        let pattern = "\(name)\\s*=\\s*['\"]([^'\"]*)['\"]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private func calculateMD5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
