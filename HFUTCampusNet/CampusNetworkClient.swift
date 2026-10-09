import Foundation
import Network
import AppKit

public protocol CampusNetworkClientDelegate: AnyObject {
    func clientDidUpdate(data: CampusNetworkData)
    func clientDidFail(error: String)
}

public class CampusNetworkClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    public static let shared = CampusNetworkClient()

    public weak var delegate: CampusNetworkClientDelegate?
    public private(set) var latestData: CampusNetworkData = CampusNetworkData()

    private let dashboardURL = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/dashboard")!
    
    // 快速心跳定时器（每 8 秒探测一次网关在线状态）
    private var heartbeatTimer: Timer?
    // 完整数据抓取定时器（默认每 5 分钟抓取一次自服务）
    private var dashboardTimer: Timer?

    private var isHeartbeating: Bool = false
    private var isFetchingDashboard: Bool = false
    private var wasOffline: Bool = false

    // 系统网络路径监视器 (Wi-Fi 断开/重连毫秒级感知)
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "cn.edu.hfut.network.pathmonitor")

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 6.0
        config.httpShouldSetCookies = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        setupSystemWakeListener()
        setupPathMonitor()
    }

    /// 启动实时监测
    public func startMonitoring() {
        stopMonitoring()

        // 立即执行一次快速探测
        performHeartbeatCheck()

        // 启动快速心跳 (每 8 秒探测网关)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.performHeartbeatCheck()
        }

        // 启动自服务数据轮询 (默认 5 分钟)
        let interval = SettingsManager.shared.refreshInterval
        dashboardTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchDashboardData()
            ElectricityService.shared.fetchData { _ in }
        }
    }

    /// 停止监测
    public func stopMonitoring() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        dashboardTimer?.invalidate()
        dashboardTimer = nil
    }

    /// 重新设定自服务刷新周期
    public func updateInterval(_ interval: TimeInterval) {
        SettingsManager.shared.refreshInterval = interval
        startMonitoring()
    }

    /// 手动强制刷新
    public func fetchData() {
        performHeartbeatCheck(forceDashboard: true)
        ElectricityService.shared.fetchData { _ in }
    }

    // MARK: - 系统休眠唤醒与网络变化监听

    private func setupSystemWakeListener() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleSystemWake() {
        // 电脑掀开盖子或休眠唤醒，延时 1 秒后立即做一次心跳与重连
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.performHeartbeatCheck(forceDashboard: true)
        }
    }

    private func setupPathMonitor() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if path.status == .satisfied {
                    // Wi-Fi 重新连上，立刻触发检测与自动重连！
                    self.performHeartbeatCheck(forceDashboard: true)
                } else {
                    // Wi-Fi 物理断开，立刻将状态置为离线！
                    self.markOfflineInstantly(reason: "Wi-Fi 或网络已断开")
                }
            }
        }
        pathMonitor?.start(queue: monitorQueue)
    }

    /// 立即置为离线，秒级响应状态栏
    private func markOfflineInstantly(reason: String) {
        self.wasOffline = true
        var data = self.latestData
        data.isLoggedIn = false
        data.errorMessage = reason
        self.latestData = data
        self.delegate?.clientDidUpdate(data: data)
    }

    // MARK: - 快速轻量心跳（每 8 秒探测一次 172.18.3.3）

    private func performHeartbeatCheck(forceDashboard: Bool = false) {
        guard !isHeartbeating else { return }
        isHeartbeating = true

        PortalAuthService.shared.checkStatus { [weak self] portalStatus in
            guard let self = self else { return }
            self.isHeartbeating = false

            switch portalStatus {
            case .offline(let reason):
                // 掉线了！立刻将 UI 置为离线，秒级反应！
                self.wasOffline = true
                var data = self.latestData
                data.isLoggedIn = false
                data.errorMessage = "校园网离线 (\(reason))"
                self.latestData = data
                self.delegate?.clientDidUpdate(data: data)

                // 若开启了自动登录且设置了密码，立即触发无感重连！
                if SettingsManager.shared.autoLoginPortal && !SettingsManager.shared.portalPassword.isEmpty {
                    PortalAuthService.shared.login { success, msg in
                        if success {
                            // 重新检测状态并通知
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                self.performHeartbeatCheck(forceDashboard: true)
                            }
                        }
                    }
                }

            case .online(_, _, let flowMB, let fee, _):
                // 如果先前处于掉线状态，现在恢复了，触发系统横幅通知！
                if self.wasOffline {
                    self.wasOffline = false
                    let usedStr = String(format: "%.0f M", flowMB)
                    let balStr = String(format: "%.2f 元", fee)
                    NotificationHelper.showNotification(
                        title: "合工大校园网已自动重连",
                        subtitle: "设备重新认证成功，网络已恢复",
                        body: "📊 当前已用流量: \(usedStr)  💰 账户余额: \(balStr)"
                    )
                }

                var data = self.latestData
                data.isLoggedIn = true
                data.errorMessage = nil
                data.lastUpdated = Date()

                // 更新网关数据
                data.usedFlow = String(format: "%.0f M", flowMB)
                data.balance = String(format: "%.2f 元", fee)
                self.latestData = data

                self.delegate?.clientDidUpdate(data: data)

                // 记录历史流量
                CampusHistoryManager.shared.recordFlow(
                    usedFlowStr: data.usedFlow,
                    availableFlowStr: (data.availableFlow != "-- M") ? data.availableFlow : nil,
                    balanceStr: data.balance
                )

                if forceDashboard || data.availableFlow == "-- M" {
                    self.fetchDashboardData()
                }

            case .notInCampusNet:
                self.markOfflineInstantly(reason: "未连接校园网络 Wi-Fi")
            }
        }
    }

    // MARK: - 自服务平台数据拉取 (xywzz:8443)

    private func fetchDashboardData() {
        guard !isFetchingDashboard else { return }
        guard let cookie = SettingsManager.shared.sessionCookie, !cookie.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        isFetchingDashboard = true
        var request = URLRequest(url: dashboardURL)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.setValue(dashboardURL.absoluteString, forHTTPHeaderField: "Referer")

        let cleanCookie = cookie.contains("JSESSIONID=") ? cookie : "JSESSIONID=\(cookie)"
        request.setValue(cleanCookie, forHTTPHeaderField: "Cookie")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.isFetchingDashboard = false

            if let error = error {
                print("自服务抓取异常: \(error.localizedDescription)")
                return
            }

            guard let data = data, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return
            }

            if html.contains("欢迎登录用户自助服务系统") && !html.contains("已用流量") {
                return
            }

            if let parsed = self.parseDashboardHTML(html) {
                var result = self.latestData
                result.availableFlow = parsed.availableFlow
                result.flowProtection = parsed.flowProtection
                if parsed.usedFlow != "-- M" {
                    result.usedFlow = parsed.usedFlow
                }
                if parsed.balance != "-- 元" {
                    result.balance = parsed.balance
                }
                result.lastUpdated = Date()
                result.isLoggedIn = true
                self.latestData = result
                self.delegate?.clientDidUpdate(data: result)

                // 记录历史流量
                CampusHistoryManager.shared.recordFlow(
                    usedFlowStr: result.usedFlow,
                    availableFlowStr: result.availableFlow,
                    balanceStr: result.balance
                )
            }
        }
        task.resume()
    }

    public func parseDashboardHTML(_ html: String) -> CampusNetworkData? {
        var usedFlow: String?
        var availFlow: String?
        var protection: String?
        var balance: String?

        let targets: [(key: String, label: String, unitFallback: String)] = [
            ("used", "已用流量", "M"),
            ("avail", "可用流量", "M"),
            ("prot", "消费保护", "元"),
            ("bal", "账户余额", "元")
        ]

        for target in targets {
            let label = target.label
            guard let range = html.range(of: label) else { continue }

            let lowerIdx = html.index(range.lowerBound, offsetBy: -250, limitedBy: html.startIndex) ?? html.startIndex
            let upperIdx = html.index(range.upperBound, offsetBy: 250, limitedBy: html.endIndex) ?? html.endIndex
            let windowStr = String(html[lowerIdx..<upperIdx])
            let cleanStr = windowStr.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

            let prePattern = "([0-9]+(?:\\.[0-9]+)?)\\s*([GMK]B?|M|G|元)?\\s*\(label)"
            if let preRegex = try? NSRegularExpression(pattern: prePattern),
               let match = preRegex.firstMatch(in: cleanStr, range: NSRange(cleanStr.startIndex..., in: cleanStr)) {
                let num = (cleanStr as NSString).substring(with: match.range(at: 1))
                let unit = match.range(at: 2).location != NSNotFound ? (cleanStr as NSString).substring(with: match.range(at: 2)) : target.unitFallback
                assignValue(target.key, "\(num) \(unit)".trimmingCharacters(in: .whitespaces), &usedFlow, &availFlow, &protection, &balance)
                continue
            }

            let postPattern = "\(label)\\s*[:：]?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*([GMK]B?|M|G|元)?"
            if let postRegex = try? NSRegularExpression(pattern: postPattern),
               let match = postRegex.firstMatch(in: cleanStr, range: NSRange(cleanStr.startIndex..., in: cleanStr)) {
                let num = (cleanStr as NSString).substring(with: match.range(at: 1))
                let unit = match.range(at: 2).location != NSNotFound ? (cleanStr as NSString).substring(with: match.range(at: 2)) : target.unitFallback
                assignValue(target.key, "\(num) \(unit)".trimmingCharacters(in: .whitespaces), &usedFlow, &availFlow, &protection, &balance)
                continue
            }
        }

        if availFlow != nil || usedFlow != nil || balance != nil {
            return CampusNetworkData(
                usedFlow: usedFlow ?? latestData.usedFlow,
                availableFlow: availFlow ?? latestData.availableFlow,
                flowProtection: protection ?? latestData.flowProtection,
                balance: balance ?? latestData.balance,
                lastUpdated: Date(),
                isLoggedIn: true
            )
        }

        return nil
    }

    private func assignValue(_ key: String, _ value: String, _ used: inout String?, _ avail: inout String?, _ prot: inout String?, _ bal: inout String?) {
        switch key {
        case "used": used = value
        case "avail": avail = value
        case "prot": prot = value
        case "bal": bal = value
        default: break
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let location = response.allHeaderFields["Location"] as? String, location.contains("login") {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }
}
