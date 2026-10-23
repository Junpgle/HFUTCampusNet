import Foundation
import AppKit
import WebKit

public class UnifiedLoginWebViewController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private static var sharedInstance: UnifiedLoginWebViewController?

    public static var shared: UnifiedLoginWebViewController {
        if let sharedInstance { return sharedInstance }
        let instance = UnifiedLoginWebViewController()
        sharedInstance = instance
        return instance
    }

    public static func clearCASLoginCookies() {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        cookieStore.getAllCookies { cookies in
            for cookie in cookies {
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let name = cookie.name.uppercased()
                let isCASDomain = domain == "cas.hfut.edu.cn" || domain == "hfut.edu.cn"
                if isCASDomain && (name == "CASTGC" || name == "TGC") {
                    cookieStore.delete(cookie)
                }
            }
        }
    }

    public static func invalidateAccountSession() {
        sharedInstance?.cancelPendingSyncForAccountSwitch()
        clearCASLoginCookies()
    }

    private var webView: WKWebView!
    private var casLoginCoordinator: HFUTCASLoginCoordinator!
    private var progressIndicator: NSProgressIndicator!
    private var statusTitleLabel: NSTextField!
    private var statusDetailLabel: NSTextField!
    private var stepLabels: [NSTextField] = []

    private var isSyncingAll: Bool = false
    private var isAccountAuthFlowEnabled = true
    private var syncCompletedCount: Int = 0
    private var syncSessionToken: UUID = UUID()
    private var loginSessionUsernameAtStart = ""
    private var loginSessionStudentIdAtStart = ""
    private var electricitySyncFailure: String?

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
        let topBar = AdaptiveBoxView(frame: NSRect(x: 0, y: 720 - 46, width: 1000, height: 46))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.dynamicBackgroundColor = .windowBackgroundColor

        let topIcon = NSImageView(frame: NSRect(x: 16, y: 11, width: 24, height: 24))
        topIcon.image = NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: nil)
        topIcon.contentTintColor = NSColor.systemBlue
        topBar.addSubview(topIcon)

        let topTitle = NSTextField(labelWithString: "合肥工业大学统一身份认证 (CAS SSO)")
        topTitle.frame = NSRect(x: 48, y: 22, width: 350, height: 18)
        topTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        topBar.addSubview(topTitle)

        let topSubtitle = NSTextField(labelWithString: "登录信息门户后，本应用将自动记住账号密码并无缝刷新课表排课、宿舍电费、校园网流量及历史统计！")
        topSubtitle.frame = NSRect(x: 48, y: 5, width: 650, height: 16)
        topSubtitle.autoresizingMask = [.width]
        topSubtitle.font = NSFont.systemFont(ofSize: 11)
        topSubtitle.textColor = .secondaryLabelColor
        topBar.addSubview(topSubtitle)

        let reloadBtn = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        reloadBtn.bezelStyle = .rounded
        reloadBtn.frame = NSRect(x: 885, y: 8, width: 95, height: 28)
        reloadBtn.autoresizingMask = [.minXMargin]
        topBar.addSubview(reloadBtn)

        containerView.addSubview(topBar)

        // Web 视图
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.add(self, name: "casCredentialsHandler")

        let webViewHeight: CGFloat = 720 - 46 - 86
        webView = WKWebView(frame: NSRect(x: 0, y: 86, width: 1000, height: webViewHeight), configuration: config)
        casLoginCoordinator = HFUTCASLoginCoordinator(frame: webView.frame)
        casLoginCoordinator.installMessageHandler(in: config.userContentController)
        casLoginCoordinator.onStatus = { [weak self] message in
            self?.statusDetailLabel.stringValue = message
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)
        casLoginCoordinator.attach(webView: webView, overlayHost: containerView)

        // 底部服务同步状态栏
        let bottomBar = AdaptiveBoxView(frame: NSRect(x: 0, y: 0, width: 1000, height: 86))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.dynamicBackgroundColor = .windowBackgroundColor

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
            label.autoresizingMask = [.minXMargin]
            label.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = .tertiaryLabelColor
            bottomBar.addSubview(label)
            stepLabels.append(label)
        }

        let viewScheduleBtn = NSButton(title: "查看课表", target: self, action: #selector(openCourseSchedule))
        viewScheduleBtn.bezelStyle = .rounded
        viewScheduleBtn.frame = NSRect(x: 770, y: 12, width: 95, height: 28)
        viewScheduleBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(viewScheduleBtn)

        let viewStatsBtn = NSButton(title: "用量统计", target: self, action: #selector(openHistoryStats))
        viewStatsBtn.bezelStyle = .rounded
        viewStatsBtn.frame = NSRect(x: 875, y: 12, width: 95, height: 28)
        viewStatsBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(viewStatsBtn)

        containerView.addSubview(bottomBar)
        window.contentView = containerView
    }

    private func cancelPendingSyncForAccountSwitch() {
        syncSessionToken = UUID()
        isSyncingAll = false
        syncCompletedCount = 0
        electricitySyncFailure = nil
        isAccountAuthFlowEnabled = false
        webView.stopLoading()
        casLoginCoordinator.setEnabled(false)
        progressIndicator.stopAnimation(nil)
    }

    public func showLoginWindow() {
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        isAccountAuthFlowEnabled = true
        isSyncingAll = false
        syncCompletedCount = 0
        syncSessionToken = UUID()
        loginSessionUsernameAtStart = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        loginSessionStudentIdAtStart = SettingsManager.shared.courseStudentId
        electricitySyncFailure = nil
        casLoginCoordinator.resetPendingCredentials()
        casLoginCoordinator.setEnabled(true)
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
            label.stringValue = "○ " + text
            label.textColor = .tertiaryLabelColor
        case .inProgress:
            label.stringValue = "● " + text
            label.textColor = NSColor.systemBlue
        case .success:
            label.stringValue = "● " + text
            label.textColor = NSColor.systemGreen
        case .failure:
            label.stringValue = "● " + text
            label.textColor = NSColor.systemRed
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.startAnimation(nil)
        casLoginCoordinator.navigationStarted(in: webView)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        progressIndicator.stopAnimation(nil)
        statusTitleLabel.stringValue = "❌ 统一身份认证页面连接失败"
        statusTitleLabel.textColor = .systemRed
        statusDetailLabel.stringValue = "\(error.localizedDescription)（请确认网络畅通后点击右上角「重新加载」）"
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        progressIndicator.stopAnimation(nil)
        statusTitleLabel.stringValue = "❌ 页面加载异常"
        statusTitleLabel.textColor = .systemRed
        statusDetailLabel.stringValue = error.localizedDescription
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isAccountAuthFlowEnabled,
              message.name == "casCredentialsHandler",
              message.webView === webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host.lowercased() == "jxglstu.hfut.edu.cn",
              HFUTCASLoginSupport.isEamsLoginPage(webView.url),
              let dict = message.body as? [String: String] else { return }
        casLoginCoordinator.stageCredentials(
            username: dict["username"] ?? "",
            password: dict["password"] ?? ""
        )
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        casLoginCoordinator.navigationFinished(in: webView)
        guard isAccountAuthFlowEnabled else { return }
        guard let url = webView.url else { return }

        // 自动填充已保存的信息门户账号与密码，并暂存本次登录输入，等待认证成功后提交
        if HFUTCASLoginSupport.isEamsLoginPage(url) {
            let savedU = SettingsManager.shared.portalUsername
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let savedP = SettingsManager.shared.casPassword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            let js = """
            (function() {
                var uInput = document.getElementById('username') || document.getElementById('u') || document.querySelector('input[name="username"]');
                var pInput = document.getElementById('pwd') || document.querySelector('input.password') || document.querySelector('input[type="password"]');

                if (uInput && !uInput.value && '\(savedU)' !== '') {
                    uInput.value = '\(savedU)';
                    uInput.dispatchEvent(new Event('input', { bubbles: true }));
                    uInput.dispatchEvent(new Event('change', { bubbles: true }));
                }
                if (pInput && !pInput.value && '\(savedP)' !== '') {
                    pInput.value = '\(savedP)';
                    pInput.dispatchEvent(new Event('input', { bubbles: true }));
                    pInput.dispatchEvent(new Event('change', { bubbles: true }));
                }

                function reportCredentials() {
                    var u = uInput ? uInput.value.trim() : '';
                    var p = pInput ? pInput.value : '';
                    if ((u !== '' || p !== '') && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.casCredentialsHandler) {
                        window.webkit.messageHandlers.casCredentialsHandler.postMessage({ username: u, password: p });
                    }
                }

                if (uInput && !uInput._hfutBound) {
                    uInput._hfutBound = true;
                    uInput.addEventListener('input', reportCredentials);
                    uInput.addEventListener('change', reportCredentials);
                    uInput.addEventListener('blur', reportCredentials);
                }
                if (pInput && !pInput._hfutBound) {
                    pInput._hfutBound = true;
                    pInput.addEventListener('input', reportCredentials);
                    pInput.addEventListener('change', reportCredentials);
                    pInput.addEventListener('blur', reportCredentials);
                }
                var btn = document.getElementById('sb2') || document.querySelector('.button-submit');
                if (btn && !btn._hfutBound) {
                    btn._hfutBound = true;
                    btn.addEventListener('click', reportCredentials, true);
                }
                var fm = document.getElementById('fm1') || document.querySelector('form');
                if (fm && !fm._hfutBound) {
                    fm._hfutBound = true;
                    fm.addEventListener('submit', reportCredentials, true);
                }

                // 若无需验证码且无报错提示，自动触发登录
                setTimeout(function() {
                    var errU = document.getElementById('errorusername');
                    var errP = document.getElementById('errorpassword');
                    var errG = document.getElementById('error');
                    var hasErr = (errU && errU.innerText.trim() !== '') || (errP && errP.innerText.trim() !== '') || (errG && errG.innerText.trim() !== '');
                    var needCode = (typeof isCodeShow !== 'undefined' && isCodeShow) || (typeof isDynamicVercode !== 'undefined' && isDynamicVercode);
                    if (!hasErr && !needCode && uInput && uInput.value && pInput && pInput.value && btn) {
                        btn.click();
                    }
                }, 350);
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // 检查是否已经登录成功
        checkCASAuthentication()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if isAccountAuthFlowEnabled,
           let token = HuiXinOAuthCallback.token(from: navigationAction.request.url) {
            SettingsManager.shared.huixinAuthToken = token
            updateStep(index: 2, text: "3. 宿舍电费与校园卡", status: .inProgress)
            ElectricityService.shared.fetchData { _ in }
            CampusCardService.shared.fetchData { _ in }
        }
        decisionHandler(.allow)
    }

    // MARK: - 检测 CAS 认证状态并触发全自动服务刷新

    private func checkCASAuthentication() {
        guard isAccountAuthFlowEnabled, !isSyncingAll else { return }
        let sessionToken = syncSessionToken

        // 获取全部 Cookie 并结合 DOM 判断是否真正脱离登录表单
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self,
                  self.isAccountAuthFlowEnabled,
                  self.syncSessionToken == sessionToken,
                  !self.isSyncingAll else { return }

            let tgc = HFUTCASLoginSupport.tgcCookieValue(from: cookies)
            let hasTGC = tgc != nil

            let currentURL = self.webView.url?.absoluteString ?? ""
            guard !currentURL.isEmpty else { return }

            let domCheckJS = """
            (function() {
                var pwd = document.querySelector('input[type="password"], #pwd');
                var hasPwd = !!(pwd && pwd.offsetParent !== null);
                var bodyText = document.body ? document.body.innerText : '';
                var hasSuccessText = bodyText.indexOf('登录成功') !== -1 || bodyText.indexOf('Log In Successful') !== -1 || bodyText.indexOf('退出') !== -1 || bodyText.indexOf('注销') !== -1;
                return { hasPwd: hasPwd, hasSuccessText: hasSuccessText };
            })();
            """
            self.webView.evaluateJavaScript(domCheckJS) { [weak self] res, _ in
                guard let self = self,
                      self.isAccountAuthFlowEnabled,
                      self.syncSessionToken == sessionToken,
                      !self.isSyncingAll else { return }
                let dict = res as? [String: Any]
                let hasPwdInput = (dict?["hasPwd"] as? Bool) ?? (currentURL.contains("/cas/login") || currentURL.contains("/login?"))
                let hasSuccessText = (dict?["hasSuccessText"] as? Bool) ?? false

                // 若页面上仍显示密码输入框，说明仍在等待用户登录，绝不因残留 Cookie 误触发
                guard !hasPwdInput else { return }

                let redirectedToService = currentURL.contains("ticket=") ||
                    currentURL.contains("one.hfut.edu.cn") ||
                    currentURL.contains("i.hfut.edu.cn") ||
                    currentURL.contains("jxglstu.hfut.edu.cn") ||
                    currentURL.contains("loginsuccess")

                let authenticationConfirmed = hasTGC || redirectedToService
                    || (currentURL.contains("cas.hfut.edu.cn") && hasSuccessText)
                guard authenticationConfirmed,
                      hasTGC || !self.casLoginCoordinator.hasPendingCredentials else { return }
                self.startFullSSORefreshChain(
                    cookies: cookies,
                    sessionToken: sessionToken,
                    confirmedTGC: tgc
                )
            }
        }
    }

    /// 核心：全自动无缝 SSO 链式刷新
    private func startFullSSORefreshChain(cookies: [HTTPCookie], sessionToken: UUID, confirmedTGC: String?) {
        guard isAccountAuthFlowEnabled,
              self.syncSessionToken == sessionToken,
              !isSyncingAll else { return }
        isSyncingAll = true
        if confirmedTGC != nil {
            casLoginCoordinator.commitPendingCredentials()
        }
        progressIndicator.startAnimation(nil)

        statusTitleLabel.stringValue = "统一身份认证成功，正在同步所有校园服务..."
        statusTitleLabel.textColor = NSColor.systemBlue
        statusDetailLabel.stringValue = "正在通过单点登录依次拉取课表、成绩考试、校园卡、宿舍电费与校园网..."
        updateStep(index: 0, text: "1. 统一身份认证", status: .success)

        // 尝试从页面或输入框提取学号（注意：不要将 10 位学号写入 courseStudentId，教务系统 stdId 为 6 位内部编号）
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.isAccountAuthFlowEnabled,
                  self.syncSessionToken == sessionToken else { return }
            self.clearPreviousAccountDataIfNeeded()
            if let confirmedTGC {
                SettingsManager.shared.casTgcCookie = confirmedTGC
            }
            self.startAccountDataRefresh(cookies: cookies, sessionToken: sessionToken)
        }
    }

    private func clearPreviousAccountDataIfNeeded() {
        let currentUsername = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentUsername.isEmpty,
              currentUsername != loginSessionUsernameAtStart else { return }

        SettingsWindowController.shared.handleExternalAccountSwitch(
            previousUsername: loginSessionUsernameAtStart,
            previousStudentID: loginSessionStudentIdAtStart,
            preserveUnifiedLoginSession: true,
            preserveCasPassword: true
        )

        loginSessionUsernameAtStart = currentUsername
        loginSessionStudentIdAtStart = SettingsManager.shared.courseStudentId
    }

    private func startAccountDataRefresh(cookies: [HTTPCookie], sessionToken: UUID) {
        guard isAccountAuthFlowEnabled, syncSessionToken == sessionToken else { return }

        let casCookies = cookies.filter {
            let dom = $0.domain.lowercased()
            return dom.contains("cas.hfut.edu.cn") || $0.name == "CASTGC" || $0.name == "TGC"
        }
        let cookieHeader = (casCookies.isEmpty ? cookies : casCookies)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        // 1. 同步教务系统课表 (EAMS 5.0)
        self.syncCourseTable(cookies: cookies, sessionToken: sessionToken)

        // 使用独立 EHALL audience 取得学生画像授权并同步消费分析。
        StudentPortraitEatService.shared.sync(completion: nil)

        // 2. 同步慧新易校 (宿舍电费与一卡通) 并联动同步校园网流量
        self.syncHuiXinElectricity(cookieHeader: cookieHeader, sessionToken: sessionToken)

        // 3. 同步图书馆借阅中心 (CAS SSO)
        LibraryBorrowManager.shared.syncWithRemote(forceSSO: true, completion: nil)
    }

    // MARK: - 1. 同步教务系统课表

    private func syncCourseTable(cookies: [HTTPCookie], sessionToken: UUID) {
        guard isAccountAuthFlowEnabled, syncSessionToken == sessionToken else { return }
        updateStep(index: 1, text: "2. 教务课表同步", status: .inProgress)

        // 仅当 cookies 中已包含 jxglstu 专属 Cookie 时才更新，绝不用 cas.hfut.edu.cn 的同名 SESSION 覆盖
        if let jxCookieHeader = CourseScheduleService.extractJxglstuCookieHeader(from: cookies) {
            SettingsManager.shared.courseSessionCookie = jxCookieHeader
        }

        // 通过 CAS TGC 票据执行单点登录，自动解析最新 studentId / semesterId / bizTypeId 并拉取课表
        CourseScheduleService.shared.tryBackgroundLogin { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.isAccountAuthFlowEnabled, self.syncSessionToken == sessionToken else { return }
                CourseScheduleService.shared.syncSchedule(
                    studentId: SettingsManager.shared.courseStudentId,
                    semesterId: SettingsManager.shared.courseSemesterId,
                    bizTypeId: SettingsManager.shared.courseBizTypeId
                ) { result in
                    DispatchQueue.main.async {
                        guard self.isAccountAuthFlowEnabled, self.syncSessionToken == sessionToken else { return }
                        // 课表同步拿到教务 Cookie 与 studentId 后，自动联动刷新空教室、考试安排与成绩单。
                        // 账号切换后不再从旧回调启动新一轮服务请求。
                        EmptyClassroomService.shared.syncTodayAndTomorrowStudyRooms(forceRefresh: true) { _ in }
                        AcademicService.shared.syncAll(silent: true)
                        switch result {
                        case .success(let schedule):
                            self.updateStep(index: 1, text: "2. 课表 (\(schedule.lessons.count)节)", status: .success)
                        case .failure:
                            if let cached = CourseScheduleService.shared.currentSchedule, !cached.lessons.isEmpty {
                                self.updateStep(index: 1, text: "2. 课表 (缓存\(cached.lessons.count)节)", status: .success)
                            } else {
                                self.updateStep(index: 1, text: "2. 课表同步失败", status: .failure)
                            }
                        }
                        self.checkAllSyncFinished(sessionToken: sessionToken)
                    }
                }
            }
        }
    }

    // MARK: - 2. 同步慧新易校电费

    private func syncHuiXinElectricity(cookieHeader: String, sessionToken: UUID) {
        guard isAccountAuthFlowEnabled, syncSessionToken == sessionToken else { return }
        updateStep(index: 2, text: "3. 电费与校园卡", status: .inProgress)
        updateStep(index: 3, text: "4. 校园网与历史用量", status: .inProgress)

        // 立即发起校园网网关/自服务拉取
        CampusNetworkClient.shared.fetchData()

        let oauthURLStr = "https://cas.hfut.edu.cn/cas/oauth2.0/authorize?client_id=Hfut2023Ydfwpt&redirect_uri=http%3A%2F%2F121.251.19.62%2Fberserker-auth%2Fcas%2Foauth2url%3Foauth2url%3Dhttp%3A%2F%2F121.251.19.62%2Fberserker-base%2Fredirect%3FappId%3D24%26type%3Dapp&response_type=code"
        guard let oauthURL = URL(string: oauthURLStr) else {
            self.syncCampusNetwork(sessionToken: sessionToken)
            self.checkAllSyncFinished(sessionToken: sessionToken)
            return
        }

        // 通过自定义 Session 捕获 Location 中的 synjones-auth
        let config = URLSessionConfiguration.default
        let delegate = RedirectCaptureDelegate { [weak self] capturedToken in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.isAccountAuthFlowEnabled, self.syncSessionToken == sessionToken else { return }
                if let token = capturedToken {
                    SettingsManager.shared.huixinAuthToken = token
                }
                // 在拿到当前账号的令牌后再启动慧新易校关联查询。
                self.syncCampusNetwork(sessionToken: sessionToken)
                CampusCardService.shared.fetchData { _ in }

                ElectricityService.shared.fetchData { [weak self] elecResult in
                    DispatchQueue.main.async {
                        guard let self = self,
                              self.isAccountAuthFlowEnabled,
                              self.syncSessionToken == sessionToken else { return }
                        switch elecResult {
                        case .success(let elec):
                            let balStr = elec.displayBalance
                            self.updateStep(index: 2, text: "3. 电费 (\(balStr))", status: .success)
                        case .failure(let error):
                            if !SettingsManager.shared.isDormConfigured {
                                self.updateStep(index: 2, text: "3. 电费 (未填宿舍)", status: .success)
                            } else {
                                self.electricitySyncFailure = error.localizedDescription
                                self.updateStep(index: 2, text: "3. 电费查询失败", status: .failure)
                                self.statusDetailLabel.stringValue = "电费查询失败：\(error.localizedDescription)"
                            }
                        }
                        self.checkAllSyncFinished(sessionToken: sessionToken)
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
        captureSession.finishTasksAndInvalidate()
    }

    // MARK: - 3. 同步校园网自服务与历史用量

    private func syncCampusNetwork(sessionToken: UUID) {
        guard isAccountAuthFlowEnabled, syncSessionToken == sessionToken else { return }
        // 从慧新易校拉取本期校园网流量与余额（支持校外/热点访问）
        ElectricityService.shared.fetchSchoolNetInfoFromHuiXin { [weak self] flow, balance in
            DispatchQueue.main.async {
                guard let self = self,
                      self.isAccountAuthFlowEnabled,
                      self.syncSessionToken == sessionToken else { return }
                CampusNetworkClient.shared.applyHuiXinFallback(usedFlow: flow, balance: balance)
                self.updateStep(index: 3, text: "4. 校园网与历史已同步", status: .success)
                self.checkAllSyncFinished(sessionToken: sessionToken)
            }
        }
    }

    private func checkAllSyncFinished(sessionToken: UUID) {
        guard isAccountAuthFlowEnabled, self.syncSessionToken == sessionToken else { return }
        syncCompletedCount += 1
        if syncCompletedCount >= 3 {
            progressIndicator.stopAnimation(nil)
            if let electricitySyncFailure {
                statusTitleLabel.stringValue = "校园服务已同步，电费查询失败"
                statusTitleLabel.textColor = NSColor.systemRed
                statusDetailLabel.stringValue = "电费查询失败：\(electricitySyncFailure)"
            } else {
                statusTitleLabel.stringValue = "全部校园服务已同步完成"
                statusTitleLabel.textColor = NSColor.systemGreen
                statusDetailLabel.stringValue = "课表排课、宿舍电费、校园网流量及历史统计均已同步就绪。"
            }

            NotificationHelper.showNotification(
                title: electricitySyncFailure == nil ? "统一身份认证全量同步完成" : "统一身份认证同步完成，电费查询失败",
                subtitle: electricitySyncFailure == nil ? "课表、宿舍电费、校园网与历史统计已自动刷新" : (electricitySyncFailure ?? "电费查询失败"),
                body: electricitySyncFailure == nil ? "可在顶部状态栏、桌面组件及历史分析窗口中查看全部数据。" : "请在设置中检查校区、楼栋、房间号与端口；错误：\(electricitySyncFailure ?? "未知错误")"
            )

            // 3 秒后自动关闭并打开桌面组件
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self,
                      self.isAccountAuthFlowEnabled,
                      self.syncSessionToken == sessionToken else { return }
                if SettingsManager.shared.showDesktopWidget {
                    DesktopWidgetController.shared.showWindow(nil)
                }
                self.window?.close()
            }
        }
    }

    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
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
        if !didCapture, let token = HuiXinOAuthCallback.token(from: request.url) {
            didCapture = true
            onCaptured(token)
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

private enum HuiXinOAuthCallback {
    static func token(from url: URL?) -> String? {
        guard let url,
              url.scheme?.lowercased() == "http",
              url.host?.lowercased() == "121.251.19.62",
              url.path == "/berserker-base/redirect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "synjones-auth" })?.value,
              !token.isEmpty else { return nil }
        return token
    }
}
