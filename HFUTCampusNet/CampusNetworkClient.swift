import Foundation
import Network
import AppKit
import CryptoKit

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
    private var pendingForceDashboard: Bool = false
    private var isFetchingDashboard: Bool = false
    private var isMonitoring = false
    private var isPausedForSleep = false
    private var wasOffline: Bool = false
    private var isManuallyLoggedOut: Bool = false
    private var manualLogoutTimestamp: Date? = nil
    private var hasFetchedHuiXinFallback: Bool = false
    private var lastDashboardAttemptTime: Date? = nil
    private var latestRedirectSessionId: String? = nil
    private var accountGeneration = 0

    private func isCurrentPortalAccount(_ username: String) -> Bool {
        SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines) == username
    }

    private func isCurrentPortalAccount(_ username: String, generation: Int) -> Bool {
        accountGeneration == generation && isCurrentPortalAccount(username)
    }

    private func tagAccountScopedTask(_ task: URLSessionTask, generation: Int) {
        task.taskDescription = "portal-account-generation:\(generation)"
    }

    private func isTaskForCurrentAccount(_ task: URLSessionTask) -> Bool {
        guard let description = task.taskDescription,
              description.hasPrefix("portal-account-generation:"),
              let generation = Int(description.dropFirst("portal-account-generation:".count)) else {
            return true
        }
        return generation == accountGeneration
    }

    public func clearAccountScopedData() {
        accountGeneration &+= 1
        isHeartbeating = false
        pendingForceDashboard = false
        isFetchingDashboard = false
        wasOffline = false
        isManuallyLoggedOut = false
        manualLogoutTimestamp = nil
        hasFetchedHuiXinFallback = false
        lastDashboardAttemptTime = nil
        latestRedirectSessionId = nil
        latestData = CampusNetworkData()
        if let usedMB = CampusHistoryManager.shared.currentMonthUsedFlowMB, usedMB > 0 {
            latestData.usedFlow = String(format: "%.0f M", usedMB)
        }
        if let balance = CampusHistoryManager.shared.latestFlowBalanceRMB {
            latestData.balance = String(format: "%.2f 元", balance)
        }
        delegate?.clientDidUpdate(data: latestData)
    }

    // 系统网络路径监视器 (Wi-Fi 断开/重连毫秒级感知)
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "cn.edu.hfut.network.pathmonitor")

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 20.0
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        if let usedMB = CampusHistoryManager.shared.currentMonthUsedFlowMB, usedMB > 0 {
            latestData.usedFlow = String(format: "%.0f M", usedMB)
        }
        if let bal = CampusHistoryManager.shared.latestFlowBalanceRMB {
            latestData.balance = String(format: "%.2f 元", bal)
        }
        setupSystemWakeListener()
        setupPathMonitor()
    }

    /// 启动实时监测
    public func startMonitoring() {
        isMonitoring = true

        // 立即执行一次快速探测
        performHeartbeatCheck()

        scheduleMonitoringTimers()
    }

    /// 仅重排定时器，不立即发起网络请求。
    private func scheduleMonitoringTimers() {
        heartbeatTimer?.invalidate()
        dashboardTimer?.invalidate()

        let onBattery = SettingsManager.isOnBatteryPower()

        // 心跳间隔：插电 30 秒，电池下按省电设置放宽（内核级 NWPathMonitor 已毫秒级重连，心跳无需频繁探测）
        let heartbeatInterval = PowerSaver.heartbeatInterval(onBattery: onBattery)
        let hTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.performHeartbeatCheck()
        }
        hTimer.tolerance = PowerSaver.tolerance(for: heartbeatInterval)
        heartbeatTimer = hTimer

        // 自服务数据轮询：电池下按省电设置放宽，降低后台 TLS 握手与无线射频功耗
        let interval = PowerSaver.dashboardInterval(onBattery: onBattery)
        let divisor = PowerSaver.secondaryDivisor(onBattery: onBattery)
        var pollCounter = 0
        let dTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.fetchDashboardData()
            pollCounter += 1
            // 电费与一卡通每 N 个周期拉取一次（插电时 N = 1）
            if pollCounter % divisor == 0 {
                ElectricityService.shared.fetchData { _ in }
                CampusCardService.shared.fetchData { _ in }
            }
        }
        dTimer.tolerance = PowerSaver.tolerance(for: interval)
        dashboardTimer = dTimer
    }

    /// 停止监测
    public func stopMonitoring() {
        isMonitoring = false
        invalidateMonitoringTimers()
    }

    private func invalidateMonitoringTimers() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        dashboardTimer?.invalidate()
        dashboardTimer = nil
    }

    @objc private func handlePowerSourceChange() {
        guard isMonitoring else { return }
        scheduleMonitoringTimers()
    }

    /// 重新设定自服务刷新周期
    public func updateInterval(_ interval: TimeInterval) {
        SettingsManager.shared.refreshInterval = interval
        startMonitoring()
    }

    /// 记录用户主动点击了注销网关，暂停自动重连直到用户再次主动登录
    public func markManualLogout() {
        isManuallyLoggedOut = true
        manualLogoutTimestamp = Date()
        markOfflineInstantly(reason: "已手动注销校园网")
    }

    /// 清除手动注销标记，恢复自动重连
    public func clearManualLogout() {
        isManuallyLoggedOut = false
        manualLogoutTimestamp = nil
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerConfigChange),
            name: .powerModeConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerSourceChange),
            name: .powerSourceDidChange,
            object: nil
        )
    }

    @objc private func handleSystemSleep() {
        // 睡眠前停止心跳与轮询定时器，杜绝睡眠期间唤醒系统
        guard SettingsManager.shared.shouldPauseOnScreenSleep, !isPausedForSleep else { return }
        isPausedForSleep = true
        stopMonitoring()
    }

    @objc private func handleSystemWake() {
        // 唤醒后恢复定时监测
        guard isPausedForSleep else { return }
        isPausedForSleep = false
        startMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.performHeartbeatCheck(forceDashboard: true)
        }
    }

    @objc private func handlePowerConfigChange() {
        // 省电配置变化时重设心跳与数据轮询定时器
        if isPausedForSleep {
            guard !SettingsManager.shared.shouldPauseOnScreenSleep else { return }
            isPausedForSleep = false
            startMonitoring()
            return
        }
        guard isMonitoring else { return }
        scheduleMonitoringTimers()
    }

    private func setupPathMonitor() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self, !self.isPausedForSleep else { return }
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
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = accountGeneration
        if forceDashboard {
            pendingForceDashboard = true
        }
        guard !isHeartbeating else { return }
        isHeartbeating = true

        PortalAuthService.shared.checkStatus { [weak self] portalStatus in
            guard let self = self else { return }
            guard self.isCurrentPortalAccount(username, generation: generation) else { return }
            self.isHeartbeating = false
            let shouldForceDashboard = forceDashboard || self.pendingForceDashboard
            self.pendingForceDashboard = false

            switch portalStatus {
            case .offline(let reason):
                // 掉线了！立刻将 UI 置为离线，秒级反应！
                self.wasOffline = true
                var data = self.latestData
                data.isLoggedIn = false
                data.errorMessage = self.isManuallyLoggedOut ? "已手动注销校园网" : "校园网离线 (\(reason))"
                self.latestData = data
                self.delegate?.clientDidUpdate(data: data)

                // 若开启了自动登录、设置了密码且非用户手动注销，立即触发无感重连！
                if !self.isManuallyLoggedOut && SettingsManager.shared.autoLoginPortal && !SettingsManager.shared.portalPassword.isEmpty {
                    PortalAuthService.shared.login { success, msg in
                        guard self.isCurrentPortalAccount(username, generation: generation) else { return }
                        if success {
                            // 重新检测状态并通知
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                guard self.isCurrentPortalAccount(username, generation: generation) else { return }
                                self.performHeartbeatCheck(forceDashboard: true)
                            }
                        }
                    }
                }

            case .online(_, _, let flowMB, let fee, _):
                // 若用户刚在 6 秒内手动点击了注销，网关会话可能尚在异步拆除中，忽略此过渡态在线响应，防止清除 isManuallyLoggedOut 后触发自动重连
                if self.isManuallyLoggedOut,
                   let logoutTime = self.manualLogoutTimestamp,
                   Date().timeIntervalSince(logoutTime) < 6.0 {
                    return
                }
                self.isManuallyLoggedOut = false
                self.manualLogoutTimestamp = nil
                // 如果先前处于掉线状态，现在恢复了，触发系统横幅通知！
                if self.wasOffline {
                    self.wasOffline = false
                    let usedStr = flowMB >= 0
                        ? String(format: "%.0f M", flowMB * 2.0)
                        : self.latestData.usedFlow
                    let balStr = fee >= 0 ? String(format: "%.2f 元", fee) : self.latestData.balance
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

                // 更新网关数据（仅当返回有效非负数值时覆盖）
                if flowMB >= 0 {
                    data.usedFlow = String(format: "%.0f M", flowMB * 2.0)
                }
                if fee >= 0 {
                    data.balance = String(format: "%.2f 元", fee)
                }
                self.latestData = data

                self.delegate?.clientDidUpdate(data: data)

                // 记录历史流量
                let currentSpd = max(NetworkSpeedMonitor.shared.currentDownloadBytes, NetworkSpeedMonitor.shared.currentUploadBytes) / (1024.0 * 1024.0)
                CampusHistoryManager.shared.recordFlow(
                    usedFlowStr: data.usedFlow,
                    availableFlowStr: (data.availableFlow != "-- M") ? data.availableFlow : nil,
                    balanceStr: data.balance,
                    currentSpeedMBs: currentSpd
                )

                let shouldRetryMissingFlow = (data.availableFlow == "-- M") &&
                    (self.lastDashboardAttemptTime == nil || Date().timeIntervalSince(self.lastDashboardAttemptTime!) >= 60.0)
                if shouldForceDashboard || shouldRetryMissingFlow {
                    self.fetchDashboardData()
                }

            case .notInCampusNet:
                self.markOfflineInstantly(reason: "未连接校园网络 Wi-Fi")
                if shouldForceDashboard || !self.hasFetchedHuiXinFallback {
                    ElectricityService.shared.fetchSchoolNetInfoFromHuiXin { [weak self] flow, balance in
                        DispatchQueue.main.async {
                            guard let self = self,
                                  self.isCurrentPortalAccount(username, generation: generation) else { return }
                            self.applyHuiXinFallback(usedFlow: flow, balance: balance, expectedAccountGeneration: generation)
                        }
                    }
                }
            }
        }
    }

    /// 当处于校外/热点或网关暂不可达时，利用慧新易校接口返回的校园网已用流量与余额更新 UI 及历史统计
    public func applyHuiXinFallback(
        usedFlow: String?,
        balance: String?,
        expectedAccountGeneration: Int? = nil
    ) {
        let generation = expectedAccountGeneration ?? accountGeneration
        guard generation == accountGeneration else { return }
        guard usedFlow != nil || balance != nil else { return }
        var updated = self.latestData
        var gotValid = false
        if let f = usedFlow, !f.isEmpty, f != "-- M" {
            let actualFlow = CampusNetworkData.actualTrafficFlow(fromBillableFlow: f) ?? f
            let newMB = CampusNetworkData(usedFlow: actualFlow).usedMB ?? 0
            let curMB = updated.usedMB ?? -1
            if updated.usedFlow == "-- M" || (!updated.isLoggedIn && newMB >= curMB) {
                updated.usedFlow = actualFlow
                gotValid = true
            }
        }
        if let b = balance, !b.isEmpty, b != "-- 元" {
            if !updated.isLoggedIn || updated.balance == "-- 元" {
                updated.balance = b
                gotValid = true
            }
        }
        guard gotValid else { return }
        self.hasFetchedHuiXinFallback = true
        updated.lastUpdated = Date()
        self.latestData = updated
        self.delegate?.clientDidUpdate(data: updated)
        if updated.usedFlow != "-- M" && !updated.usedFlow.isEmpty {
            CampusHistoryManager.shared.recordFlow(usedFlowStr: updated.usedFlow, balanceStr: updated.balance)
        }
    }

    // MARK: - 自服务平台数据拉取 (xywzz:8443)

    private func fetchDashboardData() {
        guard !isFetchingDashboard else { return }
        lastDashboardAttemptTime = Date()
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = accountGeneration
        guard let cookie = SettingsManager.shared.sessionCookie, !cookie.trimmingCharacters(in: .whitespaces).isEmpty else {
            silentLoginSelfServiceAndFetch()
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
            guard self.isCurrentPortalAccount(username, generation: generation) else { return }
            self.isFetchingDashboard = false

            if let error = error {
                print("自服务抓取异常: \(error.localizedDescription)")
                return
            }

            if let httpResp = response as? HTTPURLResponse, (httpResp.statusCode == 302 || httpResp.statusCode == 301) {
                // Cookie 已过期，清空失效 Cookie 并静默重新登录自服务系统
                SettingsManager.shared.sessionCookie = nil
                self.silentLoginSelfServiceAndFetch()
                return
            }

            guard let data = data, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return
            }

            if html.contains("欢迎登录用户自助服务系统") && !html.contains("已用流量") {
                SettingsManager.shared.sessionCookie = nil
                self.silentLoginSelfServiceAndFetch()
                return
            }

            if !self.applyParsedDashboardHTML(html, expectedAccountGeneration: generation) {
                SettingsManager.shared.sessionCookie = nil
                self.silentLoginSelfServiceAndFetch()
            }
        }
        task.resume()
    }

    @discardableResult
    public func applyParsedDashboardHTML(_ html: String, expectedAccountGeneration: Int? = nil) -> Bool {
        let generation = expectedAccountGeneration ?? accountGeneration
        guard generation == accountGeneration else { return false }
        guard let parsed = self.parseDashboardHTML(html) else { return false }
        var result = self.latestData
        result.availableFlow = parsed.availableFlow
        result.flowProtection = parsed.flowProtection
        if parsed.usedFlow != "-- M" {
            // 若当前已有网关精确到 MB 的数值，且自服务面板返回的粗粒度 GB 折算值因两位小数截断略小于当前值（相差 15 MB 以内），保留精确 MB 值防止倒退
            if let curMB = result.usedMB, let newMB = parsed.usedMB, curMB > newMB && (curMB - newMB) <= 15.0 {
                // keep result.usedFlow
            } else {
                result.usedFlow = parsed.usedFlow
            }
        }
        if parsed.balance != "-- 元" {
            result.balance = parsed.balance
        }
        result.lastUpdated = Date()
        self.latestData = result
        self.delegate?.clientDidUpdate(data: result)

        let currentSpd = max(NetworkSpeedMonitor.shared.currentDownloadBytes, NetworkSpeedMonitor.shared.currentUploadBytes) / (1024.0 * 1024.0)
        CampusHistoryManager.shared.recordFlow(
            usedFlowStr: result.usedFlow,
            availableFlowStr: result.availableFlow,
            balanceStr: result.balance,
            currentSpeedMBs: currentSpd
        )
        self.fetchOnlineDevices()
        return true
    }

    /// 获取当前自服务平台在线设备列表 (dashboard/getOnlineList)
    public func fetchOnlineDevices(completion: (() -> Void)? = nil) {
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = accountGeneration
        guard let cookie = SettingsManager.shared.sessionCookie, !cookie.trimmingCharacters(in: .whitespaces).isEmpty else {
            completion?()
            return
        }
        let cleanCookie = cookie.contains("JSESSIONID=") ? cookie : "JSESSIONID=\(cookie)"
        let url = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/dashboard/getOnlineList")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cleanCookie, forHTTPHeaderField: "Cookie")
        req.setValue(dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else {
                completion?()
                return
            }
            guard self.isCurrentPortalAccount(username, generation: generation) else {
                DispatchQueue.main.async { completion?() }
                return
            }
            guard error == nil, let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion?()
                return
            }

            var sessions: [OnlineDeviceSession] = []
            for item in arr {
                let sid = "\(item["sessionId"] ?? "")"
                guard !sid.isEmpty else { continue }
                let ip = (item["ip"] as? String) ?? "--"
                let mac = (item["mac"] as? String) ?? ""
                let loginTime = (item["loginTime"] as? String) ?? "--"
                let useTimeSec = Int("\(item["useTime"] ?? "0")") ?? 0
                let useMinutes = max(0, Int(round(Double(useTimeSec) / 60.0)))
                let downKB = Double("\(item["downFlow"] ?? "0")") ?? 0
                let upKB = Double("\(item["upFlow"] ?? "0")") ?? 0
                let usedMB = (downKB + upKB) / 1024.0
                var termType = (item["terminalType"] as? String) ?? "未知终端"
                if termType.hasPrefix("#") {
                    termType = String(termType.dropFirst())
                }
                if termType.isEmpty { termType = "在线终端" }
                let hostName = (item["hostName"] as? String) ?? ""

                sessions.append(OnlineDeviceSession(
                    sessionId: sid,
                    ip: ip,
                    mac: mac,
                    loginTime: loginTime,
                    useMinutes: useMinutes,
                    usedFlowMB: usedMB,
                    terminalType: termType,
                    hostName: hostName
                ))
            }

            DispatchQueue.main.async {
                guard self.isCurrentPortalAccount(username, generation: generation) else {
                    completion?()
                    return
                }
                var updated = self.latestData
                updated.onlineDevices = sessions
                self.latestData = updated
                self.delegate?.clientDidUpdate(data: updated)
                if updated.usedFlow != "-- M" && !updated.usedFlow.isEmpty {
                    CampusHistoryManager.shared.recordFlow(
                        usedFlowStr: updated.usedFlow,
                        availableFlowStr: (updated.availableFlow != "-- M") ? updated.availableFlow : nil,
                        balanceStr: updated.balance
                    )
                } else {
                    NotificationCenter.default.post(name: .historyStatsDidUpdate, object: nil)
                }
                completion?()
            }
        }.resume()
    }

    /// 强制注销指定在线设备 (dashboard/tooffline?sessionid=xxx)
    public func kickOnlineDevice(sessionId: String, completion: @escaping (Bool, String) -> Void) {
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = accountGeneration
        guard let cookie = SettingsManager.shared.sessionCookie, !cookie.trimmingCharacters(in: .whitespaces).isEmpty else {
            completion(false, "自服务会话未就绪，请稍后重试")
            return
        }
        let cleanCookie = cookie.contains("JSESSIONID=") ? cookie : "JSESSIONID=\(cookie)"
        let encodedSid = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionId
        let url = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/dashboard/tooffline?sessionid=\(encodedSid)")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cleanCookie, forHTTPHeaderField: "Cookie")
        req.setValue(dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else { return }
            guard self.isCurrentPortalAccount(username, generation: generation) else {
                DispatchQueue.main.async { completion(false, "账号已切换，本次操作已取消") }
                return
            }
            if let error = error {
                DispatchQueue.main.async {
                    completion(false, "网络异常: \(error.localizedDescription)")
                }
                return
            }
            var ok = false
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool {
                ok = success
            }

            DispatchQueue.main.async {
                guard self.isCurrentPortalAccount(username, generation: generation) else {
                    completion(false, "账号已切换，本次操作已取消")
                    return
                }
                if ok {
                    var updated = self.latestData
                    updated.onlineDevices.removeAll { $0.sessionId == sessionId }
                    self.latestData = updated
                    self.delegate?.clientDidUpdate(data: updated)
                    self.fetchOnlineDevices()
                    self.fetchData()
                    completion(true, "设备已成功强制下线！")
                } else {
                    completion(false, "注销失败，该设备可能已下线或会话已过期")
                }
            }
        }.resume()
    }

    /// 静默后台登录校园网自服务系统 (xywzz.hfut.edu.cn:8443) 并抓取可用流量与消费保护
    public func silentLoginSelfServiceAndFetch() {
        let username = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = SettingsManager.shared.portalPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = accountGeneration
        guard !username.isEmpty, !password.isEmpty, !isFetchingDashboard else { return }

        isFetchingDashboard = true
        let loginPageURL = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI")!
        var step1Req = URLRequest(url: loginPageURL)
        step1Req.httpMethod = "GET"
        step1Req.httpShouldHandleCookies = false
        step1Req.cachePolicy = .reloadIgnoringLocalCacheData
        step1Req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let step1Task = session.dataTask(with: step1Req) { [weak self] data, response, error in
            guard let self = self else { return }
            guard self.isCurrentPortalAccount(username, generation: generation) else { return }
            guard error == nil, let data = data,
                  let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                self.isFetchingDashboard = false
                return
            }

            // 1. 提取 JSESSIONID
            var jsessionId: String? = nil
            if let httpResp = response as? HTTPURLResponse,
               let setCookie = httpResp.value(forHTTPHeaderField: "Set-Cookie"),
               let match = setCookie.range(of: #"JSESSIONID=([0-9A-Za-z_]+)"#, options: .regularExpression) {
                jsessionId = String(setCookie[match]).replacingOccurrences(of: "JSESSIONID=", with: "")
            }
            if jsessionId == nil,
               let match = html.range(of: #"jsessionid=([0-9A-Za-z_]+)"#, options: .regularExpression) {
                jsessionId = String(html[match]).replacingOccurrences(of: "jsessionid=", with: "")
            }

            // 2. 提取隐藏字段 checkcode
            var checkcode = ""
            if let regex = try? NSRegularExpression(pattern: #"name="checkcode"\s+value="([^"]*)""#),
               let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                checkcode = (html as NSString).substring(with: m.range(at: 1))
            }

            guard let sid = jsessionId, !sid.isEmpty else {
                self.isFetchingDashboard = false
                return
            }

            let cookieHeader = "JSESSIONID=\(sid)"

            // 3. 触发一次 randomCode 初始化会话验证码状态
            let randomURL = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/login/randomCode?t=\(Double.random(in: 0.1...0.9))")!
            var step2Req = URLRequest(url: randomURL)
            step2Req.httpShouldHandleCookies = false
            step2Req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            step2Req.setValue(loginPageURL.absoluteString, forHTTPHeaderField: "Referer")

            let step2Task = self.session.dataTask(with: step2Req) { [weak self] _, _, _ in
                guard let self = self else { return }
                guard self.isCurrentPortalAccount(username, generation: generation) else { return }

                // 4. 计算 MD5 密码并提交 POST /Self/login/verify
                let md5Password = Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
                let verifyURL = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/login/verify")!
                var step3Req = URLRequest(url: verifyURL)
                step3Req.httpMethod = "POST"
                step3Req.httpShouldHandleCookies = false
                step3Req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                step3Req.setValue(loginPageURL.absoluteString, forHTTPHeaderField: "Referer")
                step3Req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                step3Req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

                let encUser = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
                let bodyStr = "foo=&bar=&checkcode=\(checkcode)&account=\(encUser)&password=\(md5Password)&code="
                step3Req.httpBody = bodyStr.data(using: .utf8)

                self.latestRedirectSessionId = nil
                let step3Task = self.session.dataTask(with: step3Req) { [weak self] verifyData, verifyResp, _ in
                    guard let self = self else { return }
                    guard self.isCurrentPortalAccount(username, generation: generation) else { return }
                    self.isFetchingDashboard = false

                    var finalSid = self.latestRedirectSessionId ?? sid
                    if let httpResp = verifyResp as? HTTPURLResponse,
                       let setCookie = httpResp.value(forHTTPHeaderField: "Set-Cookie"),
                       let match = setCookie.range(of: #"JSESSIONID=([0-9A-Za-z_]+)"#, options: .regularExpression) {
                        finalSid = String(setCookie[match]).replacingOccurrences(of: "JSESSIONID=", with: "")
                    }

                    if let verifyData = verifyData,
                       let dashHTML = String(data: verifyData, encoding: .utf8) ?? String(data: verifyData, encoding: .ascii),
                       dashHTML.contains("可用流量") || dashHTML.contains("已用流量") {
                        SettingsManager.shared.sessionCookie = finalSid
                        self.applyParsedDashboardHTML(dashHTML, expectedAccountGeneration: generation)
                    }
                }
                self.tagAccountScopedTask(step3Task, generation: generation)
                step3Task.resume()
            }
            self.tagAccountScopedTask(step2Task, generation: generation)
            step2Task.resume()
        }
        tagAccountScopedTask(step1Task, generation: generation)
        step1Task.resume()
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

            // 1. 优先精确匹配自服务面板的 <dl><dt>数值 <small>单位</small></dt><dd>标签</dd></dl> 结构
            // 注意：JSP 模板在“消费保护”的 <dt>...</dt> 内部有 8 行超长缩进空白（超过 500 个空格字符），且不能跨越前一个指标的 </dt>
            let dlPattern = "<dt[^>]*>((?:(?!</dt>)[\\s\\S]){1,1500}?)</dt>\\s*<dd[^>]*>\\s*\(NSRegularExpression.escapedPattern(for: label))\\s*</dd>"
            if let dlRegex = try? NSRegularExpression(pattern: dlPattern, options: [.caseInsensitive]),
               let dlMatch = dlRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let dtRange = Range(dlMatch.range(at: 1), in: html) {
                let dtClean = String(html[dtRange])
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let valPattern = "(-?[0-9]+(?:\\.[0-9]+)?)\\s*([GMK]B?|M|G|元)?"
                if let valRegex = try? NSRegularExpression(pattern: valPattern),
                   let valMatch = valRegex.firstMatch(in: dtClean, range: NSRange(dtClean.startIndex..., in: dtClean)) {
                    let num = (dtClean as NSString).substring(with: valMatch.range(at: 1))
                    let unit = valMatch.range(at: 2).location != NSNotFound
                        ? (dtClean as NSString).substring(with: valMatch.range(at: 2))
                        : target.unitFallback
                    assignValue(target.key, "\(num) \(unit)".trimmingCharacters(in: .whitespaces), &usedFlow, &availFlow, &protection, &balance)
                    continue
                } else if target.key == "prot" && (dtClean.contains("--") || dtClean.contains("未设置") || dtClean.contains("无") || dtClean.isEmpty) {
                    // 用户未开启/未设置消费保护时，自服务页面 <dt> 内为 "--" 或 "未设置"
                    assignValue(target.key, "未设置", &usedFlow, &availFlow, &protection, &balance)
                    continue
                }
            }

            // 2. 兜底：遍历 HTML 中该标签的所有出现位置（扩大上下文窗口至 1000 字符以跨越 JSP 大量缩进空白）
            var searchStart = html.startIndex
            var matched = false
            while !matched, searchStart < html.endIndex,
                  let range = html.range(of: label, range: searchStart..<html.endIndex) {
                searchStart = range.upperBound

                let lowerIdx = html.index(range.lowerBound, offsetBy: -1000, limitedBy: html.startIndex) ?? html.startIndex
                let upperIdx = html.index(range.upperBound, offsetBy: 400, limitedBy: html.endIndex) ?? html.endIndex
                let windowStr = String(html[lowerIdx..<upperIdx])
                let cleanStr = windowStr
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

                let prePattern = "(-?[0-9]+(?:\\.[0-9]+)?)\\s*([GMK]B?|M|G|元)?\\s*\(label)"
                if let preRegex = try? NSRegularExpression(pattern: prePattern),
                   let match = preRegex.firstMatch(in: cleanStr, range: NSRange(cleanStr.startIndex..., in: cleanStr)) {
                    let num = (cleanStr as NSString).substring(with: match.range(at: 1))
                    let unit = match.range(at: 2).location != NSNotFound ? (cleanStr as NSString).substring(with: match.range(at: 2)) : target.unitFallback
                    assignValue(target.key, "\(num) \(unit)".trimmingCharacters(in: .whitespaces), &usedFlow, &availFlow, &protection, &balance)
                    matched = true
                    break
                }

                let postPattern = "\(label)\\s*[:：]?\\s*(-?[0-9]+(?:\\.[0-9]+)?)\\s*([GMK]B?|M|G|元)?"
                if let postRegex = try? NSRegularExpression(pattern: postPattern),
                   let match = postRegex.firstMatch(in: cleanStr, range: NSRange(cleanStr.startIndex..., in: cleanStr)) {
                    let num = (cleanStr as NSString).substring(with: match.range(at: 1))
                    let unit = match.range(at: 2).location != NSNotFound ? (cleanStr as NSString).substring(with: match.range(at: 2)) : target.unitFallback
                    assignValue(target.key, "\(num) \(unit)".trimmingCharacters(in: .whitespaces), &usedFlow, &availFlow, &protection, &balance)
                    matched = true
                    break
                }
            }
        }

        if availFlow != nil || usedFlow != nil || balance != nil || protection != nil {
            return CampusNetworkData(
                usedFlow: usedFlow.flatMap { CampusNetworkData.actualTrafficFlow(fromBillableFlow: $0) } ?? latestData.usedFlow,
                availableFlow: availFlow.flatMap { CampusNetworkData.actualTrafficFlow(fromBillableFlow: $0) } ?? latestData.availableFlow,
                flowProtection: protection ?? latestData.flowProtection,
                balance: balance ?? latestData.balance,
                lastUpdated: Date(),
                isLoggedIn: latestData.isLoggedIn
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
        let protectionSpace = challenge.protectionSpace
        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           protectionSpace.host.caseInsensitiveCompare("xywzz.hfut.edu.cn") == .orderedSame,
           protectionSpace.port == 8443,
           let serverTrust = protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard isTaskForCurrentAccount(task) else {
            completionHandler(nil)
            return
        }
        if let location = response.value(forHTTPHeaderField: "Location"), location.contains("login") {
            completionHandler(nil)
        } else {
            var redirectReq = request
            redirectReq.httpShouldHandleCookies = false
            if let setCookie = response.value(forHTTPHeaderField: "Set-Cookie"),
               let match = setCookie.range(of: #"JSESSIONID=([0-9A-Za-z_]+)"#, options: .regularExpression) {
                let cookieKV = String(setCookie[match])
                self.latestRedirectSessionId = cookieKV.replacingOccurrences(of: "JSESSIONID=", with: "")
                redirectReq.setValue(cookieKV, forHTTPHeaderField: "Cookie")
            } else if let origCookie = task.originalRequest?.value(forHTTPHeaderField: "Cookie") {
                redirectReq.setValue(origCookie, forHTTPHeaderField: "Cookie")
            }
            completionHandler(redirectReq)
        }
    }
}
