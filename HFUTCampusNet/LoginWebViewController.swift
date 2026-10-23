import Foundation
import AppKit
import WebKit

public class LoginWebViewController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    public static let shared = LoginWebViewController()

    private var webView: WKWebView!
    private var progressIndicator: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var isCapturingSession: Bool = false
    private var sessionToken: UUID = UUID()
    private var sessionUsername = ""
    private var sessionUsernameAtStart = ""
    private var pendingPortalCredentials: (username: String, password: String)?
    private var rejectedUsernameChange = false

    private init() {
        let window = NSWindow(
            contentRect: NSRange(location: 0, length: 0).toRect(width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学校园网自服务 - 授权登录 (获取可用流量与消费保护)"
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

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // 允许跨域与证书
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.add(self, name: "selfServiceCredentialsHandler")

        webView = WKWebView(frame: NSRect(x: 0, y: 48, width: 900, height: 572), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)

        // 底部工具条
        let bottomBar = AdaptiveBoxView(frame: NSRect(x: 0, y: 0, width: 900, height: 48))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.dynamicBackgroundColor = .windowBackgroundColor

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 16, y: 16, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        bottomBar.addSubview(progressIndicator)

        statusLabel = NSTextField(labelWithString: "正在连接校园网自服务平台...")
        statusLabel.frame = NSRect(x: 42, y: 14, width: 620, height: 20)
        statusLabel.autoresizingMask = [.width]
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        bottomBar.addSubview(statusLabel)

        let reloadBtn = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        reloadBtn.bezelStyle = .rounded
        reloadBtn.frame = NSRect(x: 670, y: 9, width: 85, height: 30)
        reloadBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(reloadBtn)

        let manualButton = NSButton(title: "手动填Cookie", target: self, action: #selector(promptManualCookie))
        manualButton.bezelStyle = .rounded
        manualButton.frame = NSRect(x: 760, y: 9, width: 125, height: 30)
        manualButton.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(manualButton)

        containerView.addSubview(bottomBar)
        window.contentView = containerView
    }

    public func showLoginWindow() {
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        isCapturingSession = false
        sessionToken = UUID()
        sessionUsernameAtStart = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionUsername = sessionUsernameAtStart
        pendingPortalCredentials = nil
        rejectedUsernameChange = false
        let url = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在连接校园网自服务，若已保存账号密码将自动填充并登录..."
        statusLabel.textColor = .secondaryLabelColor
        webView.load(request)
    }

    @objc private func reloadPage() {
        showLoginWindow()
    }

    private func isSelfServiceURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "xywzz.hfut.edu.cn",
              url.port == 8443 else { return false }
        let path = url.path.lowercased()
        return path == "/self" || path.hasPrefix("/self/")
    }

    private func isSelfServiceLoginURL(_ url: URL?) -> Bool {
        guard isSelfServiceURL(url), let path = url?.path.lowercased() else { return false }
        return path == "/self/login" || path == "/self/login/"
    }

    private func isSelfServiceDashboardURL(_ url: URL?) -> Bool {
        guard isSelfServiceURL(url), let path = url?.path.lowercased() else { return false }
        return path == "/self/dashboard" || path.hasPrefix("/self/dashboard/")
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "selfServiceCredentialsHandler",
              message.webView === webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host.lowercased() == "xywzz.hfut.edu.cn",
              isCurrentStoredAccount(),
              let dict = message.body as? [String: String] else { return }

        if let username = dict["username"]?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            guard sessionUsernameAtStart.isEmpty || username == sessionUsernameAtStart else {
                rejectedUsernameChange = true
                pendingPortalCredentials = nil
                return
            }
            rejectedUsernameChange = false
            if sessionUsername != username {
                sessionUsername = username
                pendingPortalCredentials = nil
            }
        }

        if let password = dict["password"] {
            if password.isEmpty {
                pendingPortalCredentials = nil
            } else if !sessionUsername.isEmpty {
                pendingPortalCredentials = (sessionUsername, password)
            }
        }
    }

    private func isCurrentStoredAccount() -> Bool {
        SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines) == sessionUsernameAtStart
    }

    private func isCurrentLoginSession(_ expectedUsername: String? = nil) -> Bool {
        guard isCurrentStoredAccount(), !rejectedUsernameChange else { return false }
        return expectedUsername.map { sessionUsername == $0 } ?? true
    }

    @discardableResult
    private func commitPendingPortalCredentialsIfNeeded(for expectedUsername: String) -> Bool {
        guard isCurrentLoginSession(expectedUsername),
              let pending = pendingPortalCredentials,
              pending.username == expectedUsername,
              !pending.password.isEmpty else { return false }

        let previousUsername = sessionUsernameAtStart
        let previousStudentID = SettingsManager.shared.courseStudentId
        SettingsManager.shared.portalUsername = pending.username
        SettingsManager.shared.portalPassword = pending.password
        pendingPortalCredentials = nil

        if pending.username != previousUsername {
            SettingsWindowController.shared.handleExternalAccountSwitch(
                previousUsername: previousUsername,
                previousStudentID: previousStudentID,
                preservePortalPassword: true
            )
        }

        sessionUsernameAtStart = pending.username
        return true
    }

    // 仅为自服务旧版 HTTPS 端口兼容证书；重定向到其他主机时走系统校验。
    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
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

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.startAnimation(nil)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = "❌ 页面连接失败: \(error.localizedDescription) (请确认已连上校园网)"
        statusLabel.textColor = .systemRed
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = "❌ 加载异常: \(error.localizedDescription)"
        statusLabel.textColor = .systemRed
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        guard isCurrentStoredAccount() else { return }
        if isSelfServiceLoginURL(webView.url) {
            let savedU = SettingsManager.shared.portalUsername
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let savedP = SettingsManager.shared.portalPassword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            let js = """
            (function() {
                var uInput = document.getElementById('account') || document.querySelector('input[name="account"]');
                var pInput = document.getElementById('password') || document.querySelector('input[name="password"]');

                function reportCreds() {
                    var u = uInput ? uInput.value.trim() : '';
                    var p = pInput ? pInput.value : '';
                    // 避免把提交时已被 calcMD5 转换的 32 位哈希覆盖原密码
                    if (p.length === 32 && /^[0-9a-f]{32}$/i.test(p)) {
                        return;
                    }
                    if ((u !== '' || p !== '') && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selfServiceCredentialsHandler) {
                        window.webkit.messageHandlers.selfServiceCredentialsHandler.postMessage({ username: u, password: p });
                    }
                }

                if (uInput && !uInput._hfutBound) {
                    uInput._hfutBound = true;
                    uInput.addEventListener('input', reportCreds);
                    uInput.addEventListener('change', reportCreds);
                    uInput.addEventListener('blur', reportCreds);
                }
                if (pInput && !pInput._hfutBound) {
                    pInput._hfutBound = true;
                    pInput.addEventListener('input', reportCreds);
                    pInput.addEventListener('change', reportCreds);
                    pInput.addEventListener('blur', reportCreds);
                }

                if (uInput && !uInput.value && '\(savedU)' !== '') {
                    uInput.value = '\(savedU)';
                }
                if (pInput && !pInput.value && '\(savedP)' !== '') {
                    pInput.value = '\(savedP)';
                }

                var errTip = document.getElementById('errorTip');
                var hasErr = errTip && errTip.innerText.trim().length > 0;
                var randDiv = document.getElementById('randomDiv');
                var needCode = randDiv && !randDiv.classList.contains('hide');

                if (!hasErr && !needCode && uInput && uInput.value && pInput && pInput.value) {
                    setTimeout(function() {
                        var btn = document.querySelector('button[name="submit"]') || document.querySelector('button[type="submit"]');
                        if (btn) { btn.click(); }
                    }, 250);
                }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        checkAndCaptureSession()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if isSelfServiceDashboardURL(navigationAction.request.url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.checkAndCaptureSession()
            }
        }
        decisionHandler(.allow)
    }

    // 捕获 Cookie 并就地直接提取页面数据！
    private func checkAndCaptureSession() {
        guard isSelfServiceDashboardURL(webView.url), !isCapturingSession else { return }
        let expectedSessionToken = sessionToken
        let expectedUsername = sessionUsername
        guard !expectedUsername.isEmpty,
              isCurrentLoginSession(expectedUsername) else { return }
        // 先检查 HTML 内容
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
            guard let self = self,
                  self.sessionToken == expectedSessionToken,
                  self.sessionUsername == expectedUsername,
                  self.isCurrentLoginSession(expectedUsername),
                  !self.isCapturingSession else { return }
            let text = (result as? String) ?? ""

            // 如果页面中包含了自服务的特征词
            if text.contains("可用流量") || text.contains("已用流量") || text.contains("消费保护") || text.contains("账户余额") {
                let committedCredentials = self.commitPendingPortalCredentialsIfNeeded(for: expectedUsername)
                if self.sessionUsernameAtStart.isEmpty && !committedCredentials {
                    return
                }
                self.isCapturingSession = true
                // 先提取最新的 xywzz 自服务专属 JSESSIONID Cookie，避免混入其它站点同名 JSESSIONID
                self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let self = self else { return }
                    guard self.sessionToken == expectedSessionToken,
                          self.sessionUsername == expectedUsername,
                          self.isCurrentLoginSession(expectedUsername) else {
                        self.isCapturingSession = false
                        return
                    }
                    var matchedSid: String?
                    for cookie in cookies where cookie.name == "JSESSIONID" && !cookie.value.isEmpty {
                        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        let path = cookie.path.lowercased()
                        let isSelfServiceDomain = domain == "xywzz.hfut.edu.cn" || domain.hasSuffix(".xywzz.hfut.edu.cn")
                        let isSelfServiceScopedRootCookie = domain == "hfut.edu.cn" &&
                            (path == "/self" || path.hasPrefix("/self/"))
                        if isSelfServiceDomain || isSelfServiceScopedRootCookie {
                            matchedSid = cookie.value
                            break
                        }
                    }
                    if let sid = matchedSid {
                        SettingsManager.shared.sessionCookie = sid
                    }
                    self.webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") { [weak self] htmlResult, _ in
                        guard let self = self else { return }
                        guard self.sessionToken == expectedSessionToken,
                              self.sessionUsername == expectedUsername,
                              self.isCurrentLoginSession(expectedUsername) else {
                            self.isCapturingSession = false
                            return
                        }
                        if let fullHtml = htmlResult as? String {
                            CampusNetworkClient.shared.applyParsedDashboardHTML(fullHtml)
                        }
                    }
                }

                self.statusLabel.stringValue = "✓ 授权成功！流量与消费保护配额已同步至小组件！"
                self.statusLabel.textColor = .systemGreen

                // 延时 1.5 秒自动关闭窗口
                let token = self.sessionToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self,
                          self.sessionToken == token,
                          self.sessionUsername == expectedUsername,
                          self.isCurrentLoginSession(expectedUsername) else { return }
                    self.window?.close()
                }
            }
        }
    }

    @objc private func promptManualCookie() {
        NSApp.activate(ignoringOtherApps: true)
        let expectedSessionToken = sessionToken
        let expectedUsername = sessionUsername
        let alert = NSAlert()
        alert.messageText = "手动填入自服务 JSESSIONID"
        alert.informativeText = "若你已在浏览器中打开了自服务网页，可按 F12 -> Application -> Cookies 复制 JSESSIONID 的值填入下方："
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
        input.stringValue = SettingsManager.shared.sessionCookie ?? ""
        input.placeholderString = "例如 22DE9FAF763DF1022CFE7C3923309937"
        alert.accessoryView = input

        alert.addButton(withTitle: "保存并刷新")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            guard sessionToken == expectedSessionToken,
                  sessionUsername == expectedUsername,
                  SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines) == expectedUsername else { return }
            let cookieVal = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cookieVal.isEmpty {
                SettingsManager.shared.sessionCookie = cookieVal
                CampusNetworkClient.shared.fetchData()
                self.window?.close()
            }
        }
    }
}

private extension NSRange {
    func toRect(width: CGFloat, height: CGFloat) -> NSRect {
        return NSRect(x: 0, y: 0, width: width, height: height)
    }
}
