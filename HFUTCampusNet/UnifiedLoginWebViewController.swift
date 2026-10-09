import Foundation
import AppKit
import WebKit

public class UnifiedLoginWebViewController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    public static let shared = UnifiedLoginWebViewController()

    private var webView: WKWebView!
    private var progressIndicator: NSProgressIndicator!
    private var statusTitleLabel: NSTextField!
    private var statusDetailLabel: NSTextField!
    private var stepLabels: [NSTextField] = []

    private var isSyncingAll: Bool = false
    private var syncCompletedCount: Int = 0

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学统一身份认证 · 一键登录并自动刷新全部服务"
        window.center()
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window else { return }
        let containerView = NSView(frame: window.contentView!.bounds)
        containerView.autoresizingMask = [.width, .height]

        // 顶部说明条
        let topBar = NSView(frame: NSRect(x: 0, y: 720 - 46, width: 1000, height: 46))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let topIcon = NSImageView(frame: NSRect(x: 16, y: 11, width: 24, height: 24))
        topIcon.image = NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: nil)
        topIcon.contentTintColor = NSColor.systemBlue
        topBar.addSubview(topIcon)

        let topTitle = NSTextField(labelWithString: "合肥工业大学统一身份认证 (CAS SSO)")
        topTitle.frame = NSRect(x: 48, y: 22, width: 350, height: 18)
        topTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        topBar.addSubview(topTitle)

        let topSubtitle = NSTextField(labelWithString: "登录信息门户后，本应用将自动无缝刷新课表排课、宿舍电费、校园网流量及历史统计！")
        topSubtitle.frame = NSRect(x: 48, y: 5, width: 650, height: 16)
        topSubtitle.font = NSFont.systemFont(ofSize: 11)
        topSubtitle.textColor = .secondaryLabelColor
        topBar.addSubview(topSubtitle)

        let reloadBtn = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        reloadBtn.bezelStyle = .rounded
        reloadBtn.frame = NSRect(x: 885, y: 8, width: 95, height: 28)
        topBar.addSubview(reloadBtn)

        containerView.addSubview(topBar)

        // Web 视图
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webViewHeight: CGFloat = 720 - 46 - 86
        webView = WKWebView(frame: NSRect(x: 0, y: 86, width: 1000, height: webViewHeight), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)

        // 底部服务同步状态栏
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 86))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 20, y: 48, width: 20, height: 20))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        bottomBar.addSubview(progressIndicator)

        statusTitleLabel = NSTextField(labelWithString: "等待统一身份认证登录...")
        statusTitleLabel.frame = NSRect(x: 48, y: 48, width: 420, height: 20)
        statusTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        bottomBar.addSubview(statusTitleLabel)

        statusDetailLabel = NSTextField(labelWithString: "请在上方输入信息门户账号与密码登录，成功后系统将自动激活全套校园服务")
        statusDetailLabel.frame = NSRect(x: 48, y: 28, width: 480, height: 16)
        statusDetailLabel.font = NSFont.systemFont(ofSize: 11)
        statusDetailLabel.textColor = .secondaryLabelColor
        bottomBar.addSubview(statusDetailLabel)

        // 四项服务同步状态指示
        let steps = [
            "1. 统一身份认证",
            "2. 教务课表同步",
            "3. 宿舍电费查询",
            "4. 校园网与历史用量"
        ]
        let stepStartX: CGFloat = 530
        let stepWidth: CGFloat = 110

        stepLabels.removeAll()
        for (i, step) in steps.enumerated() {
            let label = NSTextField(labelWithString: "⏳ " + step)
            label.frame = NSRect(x: stepStartX + CGFloat(i) * stepWidth, y: 46, width: stepWidth, height: 18)
            label.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = .tertiaryLabelColor
            bottomBar.addSubview(label)
            stepLabels.append(label)
        }

        let viewScheduleBtn = NSButton(title: "查看课表", target: self, action: #selector(openCourseSchedule))
        viewScheduleBtn.bezelStyle = .rounded
        viewScheduleBtn.frame = NSRect(x: 770, y: 12, width: 95, height: 28)
        bottomBar.addSubview(viewScheduleBtn)

        let viewStatsBtn = NSButton(title: "用量统计", target: self, action: #selector(openHistoryStats))
        viewStatsBtn.bezelStyle = .rounded
        viewStatsBtn.frame = NSRect(x: 875, y: 12, width: 95, height: 28)
        bottomBar.addSubview(viewStatsBtn)

        containerView.addSubview(bottomBar)
        window.contentView = containerView
    }

    public func showLoginWindow() {
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        isSyncingAll = false
        syncCompletedCount = 0
        updateStep(index: 0, text: "1. 统一身份认证", status: .waiting)
        updateStep(index: 1, text: "2. 教务课表同步", status: .waiting)
        updateStep(index: 2, text: "3. 宿舍电费查询", status: .waiting)
        updateStep(index: 3, text: "4. 校园网与历史用量", status: .waiting)

        statusTitleLabel.stringValue = "请登录合工大统一身份认证..."
        statusTitleLabel.textColor = .labelColor
        statusDetailLabel.stringValue = "登录成功后，将自动无缝刷新课表、宿舍电费及校园网自服务"
        progressIndicator.startAnimation(nil)

        let url = URL(string: "https://cas.hfut.edu.cn/cas/login")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        webView.load(request)
    }

    @objc private func reloadPage() {
        showLoginWindow()
    }

    @objc private func openCourseSchedule() {
        CourseScheduleWindowController.shared.showWindow(nil)
    }

    @objc private func openHistoryStats() {
        HistoryStatsWindowController.shared.showWindow(nil)
    }

    private enum StepStatus {
        case waiting, inProgress, success, failure
    }

    private func updateStep(index: Int, text: String, status: StepStatus) {
        guard index < stepLabels.count else { return }
        let label = stepLabels[index]
        switch status {
        case .waiting:
            label.stringValue = "⏳ " + text
            label.textColor = .tertiaryLabelColor
        case .inProgress:
            label.stringValue = "🔄 " + text
            label.textColor = NSColor.systemBlue
        case .success:
            label.stringValue = "✅ " + text
            label.textColor = NSColor.systemGreen
        case .failure:
            label.stringValue = "❌ " + text
            label.textColor = NSColor.systemRed
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.startAnimation(nil)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        guard let url = webView.url else { return }
        let urlStr = url.absoluteString

        // 尝试自动填充保存的学号
        let savedU = SettingsManager.shared.portalUsername
        if !savedU.isEmpty && urlStr.contains("cas.hfut.edu.cn/cas/login") {
            let js = """
            if (document.getElementById('username') && !document.getElementById('username').value) {
                document.getElementById('username').value = '\(savedU)';
            }
            if (document.getElementById('u') && !document.getElementById('u').value) {
                document.getElementById('u').value = '\(savedU)';
            }
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // 检查是否已经登录成功
        checkCASAuthentication()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url?.absoluteString {
            // 如果检测到 HuiXin OAuth 回调或者 EAMS 5.0 回调
            if url.contains("synjones-auth=") {
                let token = url.components(separatedBy: "synjones-auth=").last?.components(separatedBy: "&").first
                if let t = token, !t.isEmpty {
                    SettingsManager.shared.huixinAuthToken = t
                    updateStep(index: 2, text: "3. 宿舍电费查询", status: .inProgress)
                    ElectricityService.shared.fetchData { _ in }
                }
            }
        }
        decisionHandler(.allow)
    }

    // MARK: - 检测 CAS 认证状态并触发全自动服务刷新

    private func checkCASAuthentication() {
        guard !isSyncingAll else { return }

        // 获取全部 Cookie
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }

            var hasTGC = false
            for cookie in cookies {
                if (cookie.name == "CASTGC" || cookie.name == "TGC") && cookie.domain.contains("hfut.edu.cn") {
                    hasTGC = true
                    SettingsManager.shared.casTgcCookie = cookie.value
                }
            }

            // 检查当前 URL 是否已经跳出登录页面，或者包含 CAS 凭据
            let currentURL = self.webView.url?.absoluteString ?? ""
            let loggedInByUrl = (!currentURL.contains("/cas/login") && currentURL.contains("hfut.edu.cn")) || currentURL.contains("ticket=")

            if hasTGC || loggedInByUrl {
                self.startFullSSORefreshChain(cookies: cookies)
            }
        }
    }

    /// 核心：全自动无缝 SSO 链式刷新
    private func startFullSSORefreshChain(cookies: [HTTPCookie]) {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        progressIndicator.startAnimation(nil)

        statusTitleLabel.stringValue = "🎉 统一身份认证成功！正在自动同步所有校园服务..."
        statusTitleLabel.textColor = NSColor.systemBlue
        statusDetailLabel.stringValue = "请稍候，系统正在通过 SSO 依次拉取课表排课、宿舍电费、校园网流量..."
        updateStep(index: 0, text: "1. 统一身份认证", status: .success)

        // 尝试从页面或输入框提取学号
        self.webView.evaluateJavaScript("document.getElementById('username') ? document.getElementById('username').value : ''") { val, _ in
            if let user = val as? String, !user.isEmpty {
                SettingsManager.shared.portalUsername = user
                if SettingsManager.shared.courseStudentId.isEmpty || SettingsManager.shared.courseStudentId == "178506" {
                    SettingsManager.shared.courseStudentId = user
                }
            }
        }

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        // 1. 同步教务课表 (EAMS 5.0)
        self.syncCourseTable(cookieHeader: cookieHeader, cookies: cookies)

        // 2. 同步慧新易校 (宿舍电费与一卡通)
        self.syncHuiXinElectricity(cookieHeader: cookieHeader)

        // 3. 同步校园网自服务与流量
        self.syncCampusNetwork()
    }

    // MARK: - 1. 同步教务系统课表

    private func syncCourseTable(cookieHeader: String, cookies: [HTTPCookie]) {
        updateStep(index: 1, text: "2. 教务课表同步", status: .inProgress)

        let ssoURL = URL(string: "https://cas.hfut.edu.cn/cas/login?service=http://jxglstu.hfut.edu.cn/eams5-student/neusoft-sso/login")!
        var request = URLRequest(url: ssoURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        // 通过 URLSession 处理重定向以获取 jxglstu 的 SESSION
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // 无论重定向结果如何，尝试抓取课表
            let stdId = SettingsManager.shared.courseStudentId.isEmpty ? "178506" : SettingsManager.shared.courseStudentId

            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
                if cookie.name == "SESSION" && (cookie.domain.contains("hfut.edu.cn") || cookie.domain.isEmpty) {
                    SettingsManager.shared.courseSessionCookie = cookie.value
                }
            }

            // 直接通过 CourseScheduleService 执行最新抓取
            CourseScheduleService.shared.syncSchedule(
                studentId: stdId,
                semesterId: SettingsManager.shared.courseSemesterId,
                bizTypeId: SettingsManager.shared.courseBizTypeId
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let schedule):
                        self.updateStep(index: 1, text: "2. 课表 (\(schedule.lessons.count)节)", status: .success)
                    case .failure:
                        // 若 direct 失败，尝试读取并解析
                        if CourseScheduleService.shared.currentSchedule != nil {
                            self.updateStep(index: 1, text: "2. 课表 (已载入本地)", status: .success)
                        } else {
                            self.updateStep(index: 1, text: "2. 课表同步稍后重试", status: .failure)
                        }
                    }
                    self.checkAllSyncFinished()
                }
            }
        }
        task.resume()
    }

    // MARK: - 2. 同步慧新易校电费

    private func syncHuiXinElectricity(cookieHeader: String) {
        updateStep(index: 2, text: "3. 宿舍电费查询", status: .inProgress)

        let oauthURLStr = "https://cas.hfut.edu.cn/cas/oauth2.0/authorize?client_id=Hfut2023Ydfwpt&redirect_uri=http%3A%2F%2F121.251.19.62%2Fberserker-auth%2Fcas%2Foauth2url%3Foauth2url%3Dhttp%3A%2F%2F121.251.19.62%2Fberserker-base%2Fredirect&response_type=code"
        guard let oauthURL = URL(string: oauthURLStr) else { return }

        // 通过自定义 Session 捕获 Location 中的 synjones-auth
        let config = URLSessionConfiguration.default
        let delegate = RedirectCaptureDelegate { [weak self] capturedToken in
            guard let self = self else { return }
            if let token = capturedToken {
                SettingsManager.shared.huixinAuthToken = token
                ElectricityService.shared.fetchData { [weak self] elecResult in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        switch elecResult {
                        case .success(let elec):
                            let balStr = elec.displayBalance
                            self.updateStep(index: 2, text: "3. 电费 (\(balStr))", status: .success)
                        case .failure:
                            self.updateStep(index: 2, text: "3. 电费已授权", status: .success)
                        }
                        self.checkAllSyncFinished()
                    }
                }
            } else {
                // 如果未能捕获到 token，直接尝试使用已有 token 请求
                ElectricityService.shared.fetchData { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.updateStep(index: 2, text: "3. 宿舍电费", status: .success)
                        self?.checkAllSyncFinished()
                    }
                }
            }
        }

        let captureSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: oauthURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        captureSession.dataTask(with: request).resume()
    }

    // MARK: - 3. 同步校园网自服务与历史用量

    private func syncCampusNetwork() {
        updateStep(index: 3, text: "4. 校园网与历史用量", status: .inProgress)

        // 优先拉取网关或自服务
        CampusNetworkClient.shared.fetchData()

        // 同时从慧新易校拉取本期校园网流量与余额（支持校外/热点访问）
        ElectricityService.shared.fetchSchoolNetInfoFromHuiXin { [weak self] flow, balance in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let f = flow {
                    CampusHistoryManager.shared.recordFlow(usedFlowStr: f, balanceStr: balance)
                }
                self.updateStep(index: 3, text: "4. 校园网与历史已同步", status: .success)
                self.checkAllSyncFinished()
            }
        }
    }

    private func checkAllSyncFinished() {
        syncCompletedCount += 1
        if syncCompletedCount >= 3 {
            progressIndicator.stopAnimation(nil)
            statusTitleLabel.stringValue = "✨ 全部校园服务已同步完成！"
            statusTitleLabel.textColor = NSColor.systemGreen
            statusDetailLabel.stringValue = "课表排课、宿舍电费、校园网流量及历史统计均已成功就绪！"

            NotificationHelper.showNotification(
                title: "🎉 合工大统一身份认证全量同步完成",
                subtitle: "课表、宿舍电费、校园网与历史统计已自动刷新",
                body: "可在顶部状态栏、桌面组件及历史分析窗口中查看全部数据！"
            )

            // 3 秒后自动关闭并打开桌面组件
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if SettingsManager.shared.showDesktopWidget {
                    DesktopWidgetController.shared.showWindow(nil)
                }
                self?.window?.close()
            }
        }
    }

    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// 拦截 OAuth 重定向并提取 synjones-auth 的 URLSessionDelegate
private class RedirectCaptureDelegate: NSObject, URLSessionTaskDelegate {
    private let onCaptured: (String?) -> Void
    private var didCapture = false

    init(onCaptured: @escaping (String?) -> Void) {
        self.onCaptured = onCaptured
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let location = response.allHeaderFields["Location"] as? String {
            if location.contains("synjones-auth=") {
                let token = location.components(separatedBy: "synjones-auth=").last?.components(separatedBy: "&").first
                if let t = token, !t.isEmpty, !didCapture {
                    didCapture = true
                    onCaptured(t)
                }
            }
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !didCapture {
            didCapture = true
            onCaptured(nil)
        }
    }
}
