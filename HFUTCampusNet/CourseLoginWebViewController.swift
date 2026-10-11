import Foundation
import AppKit
import WebKit

public class CourseLoginWebViewController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    public static let shared = CourseLoginWebViewController()

    private var webView: WKWebView!
    private var progressIndicator: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var isSyncing: Bool = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学教务系统 - 课表授权同步"
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
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.add(self, name: "casCredentialsHandler")

        webView = WKWebView(frame: NSRect(x: 0, y: 52, width: 960, height: 628), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)

        // 底部状态与操作栏
        let bottomBar = AdaptiveBoxView(frame: NSRect(x: 0, y: 0, width: 960, height: 52))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.dynamicBackgroundColor = .windowBackgroundColor

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 16, y: 18, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        bottomBar.addSubview(progressIndicator)

        statusLabel = NSTextField(labelWithString: "正在连接合工大教务管理系统...")
        statusLabel.frame = NSRect(x: 42, y: 16, width: 560, height: 20)
        statusLabel.autoresizingMask = [.width]
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        bottomBar.addSubview(statusLabel)

        let reloadBtn = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        reloadBtn.bezelStyle = .rounded
        reloadBtn.frame = NSRect(x: 610, y: 11, width: 85, height: 30)
        reloadBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(reloadBtn)

        let goToTableBtn = NSButton(title: "前往课表页", target: self, action: #selector(navigateToCourseTable))
        goToTableBtn.bezelStyle = .rounded
        goToTableBtn.frame = NSRect(x: 700, y: 11, width: 95, height: 30)
        goToTableBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(goToTableBtn)

        let manualSyncBtn = NSButton(title: "从当前页读取课表", target: self, action: #selector(manualExtractCurrentPage))
        manualSyncBtn.bezelStyle = .rounded
        manualSyncBtn.frame = NSRect(x: 800, y: 11, width: 145, height: 30)
        manualSyncBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(manualSyncBtn)

        containerView.addSubview(bottomBar)
        window.contentView = containerView
    }

    public func showLoginWindow(targetURLString: String? = nil) {
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let defaultURL = "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table"
        let finalURLStr = targetURLString ?? defaultURL

        guard let url = URL(string: finalURLStr) else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)

        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "请登录教务系统（如已登录将自动同步课表）..."
        statusLabel.textColor = .secondaryLabelColor
        isSyncing = false
        webView.load(request)
    }

    @objc private func reloadPage() {
        showLoginWindow()
    }

    @objc private func navigateToCourseTable() {
        let urlStr = "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table"
        if let url = URL(string: urlStr) {
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func manualExtractCurrentPage() {
        isSyncing = false
        triggerAutoExtraction()
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在加载页面..."
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "casCredentialsHandler",
              let dict = message.body as? [String: String] else { return }
        if let u = dict["username"]?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            SettingsManager.shared.portalUsername = u
        }
        if let p = dict["password"], !p.isEmpty {
            SettingsManager.shared.casPassword = p
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        guard let currentURL = webView.url else { return }
        let urlStr = currentURL.absoluteString

        // 自动填充已保存的信息门户账号与密码，并监听用户输入自动保存
        if urlStr.contains("/login") || urlStr.contains("cas.hfut.edu.cn") {
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

        // 检查是否到达课表页面
        if urlStr.contains("/for-std/course-table/info/") || urlStr.contains("/for-std/course-table") {
            triggerAutoExtraction()
        } else if urlStr.contains("/login") || urlStr.contains("cas.hfut.edu.cn") {
            statusLabel.stringValue = "已自动填充已存账号密码（首次登录输入后将自动保存）..."
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "已加载，如已登录可点击右下角「从当前页读取课表」"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func triggerAutoExtraction() {
        guard !isSyncing else { return }
        isSyncing = true
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在从当前页面直接提取排课数据..."
        statusLabel.textColor = NSColor.systemBlue

        guard let currentURL = webView.url else {
            isSyncing = false
            return
        }

        // 尝试从 URL 提取 studentId
        var detectedStudentId = SettingsManager.shared.courseStudentId
        let pattern = #"/for-std/course-table/info/(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: currentURL.path, range: NSRange(currentURL.path.startIndex..., in: currentURL.path)),
           let range = Range(match.range(at: 1), in: currentURL.path) {
            detectedStudentId = String(currentURL.path[range])
            SettingsManager.shared.courseStudentId = detectedStudentId
        }

        // 读取所有 Cookie，严格提取 jxglstu 专属 SESSION + SRVID，避免被 cas.hfut.edu.cn 的同名 SESSION 覆盖
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            if let jxCookieHeader = CourseScheduleService.extractJxglstuCookieHeader(from: cookies) {
                SettingsManager.shared.courseSessionCookie = jxCookieHeader
            }
            for cookie in cookies {
                if (cookie.name == "CASTGC" || cookie.name == "TGC") && cookie.domain.contains("hfut.edu.cn") {
                    SettingsManager.shared.casTgcCookie = cookie.value
                }
            }

            // 优先在当前已登录的 WKWebView 页面上下文内直接执行同源 fetch 获取课表 JSON（100% 复用页面自身有效会话）
            let inPageFetchScript = """
            let html = document.documentElement ? document.documentElement.outerHTML : '';
            let stdMatch = window.location.pathname.match(/\\/for-std\\/course-table\\/info\\/(\\d+)/) || html.match(/var\\s+studentId\\s*=\\s*(\\d+)/);
            let stdId = stdMatch ? stdMatch[1] : '\(detectedStudentId)';
            let bizMatch = html.match(/bizTypeId\\s*:\\s*(\\d+)/);
            let bizId = bizMatch ? bizMatch[1] : '23';
            let semSelect = document.getElementById('allSemesters');
            let semMatch = html.match(/'fileInfoAssoc'\\s*:\\s*null\\s*,\\s*'id'\\s*:\\s*(\\d+)/) || html.match(/semesterId\\s*:\\s*(\\d+)/);
            let semId = (semSelect && semSelect.value) ? semSelect.value : (semMatch ? semMatch[1] : '\(CourseCalendarHelper.inferSemesterId())');

            if (!stdId) {
                const tableResp = await fetch('/eams5-student/for-std/course-table', { credentials: 'include' });
                const tableHtml = await tableResp.text();
                const urlStd = (tableResp.url || '').match(/\\/for-std\\/course-table\\/info\\/(\\d+)/);
                const htmlStd = tableHtml.match(/var\\s+studentId\\s*=\\s*(\\d+)/);
                if (urlStd) stdId = urlStd[1];
                else if (htmlStd) stdId = htmlStd[1];
                const tBiz = tableHtml.match(/bizTypeId\\s*:\\s*(\\d+)/);
                if (tBiz) bizId = tBiz[1];
                const tSem = tableHtml.match(/'fileInfoAssoc'\\s*:\\s*null\\s*,\\s*'id'\\s*:\\s*(\\d+)/) || tableHtml.match(/semesterId\\s*:\\s*(\\d+)/);
                if (tSem) semId = tSem[1];
            }
            if (!stdId) {
                throw new Error('Missing stdId');
            }

            const getDataResp = await fetch(`/eams5-student/for-std/course-table/get-data?bizTypeId=${bizId}&semesterId=${semId}&dataId=${stdId}`, {
                credentials: 'include',
                headers: { 'Accept': 'application/json, text/javascript, */*; q=0.01' }
            });
            const getDataJson = await getDataResp.json();
            const lessonIds = getDataJson.lessonIds || [];
            if (lessonIds.length === 0) {
                return JSON.stringify({ stdId, semId, bizId, datum: JSON.stringify({ result: { lessonList: [], scheduleList: [] } }) });
            }
            const datumResp = await fetch('/eams5-student/ws/schedule-table/datum', {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/json;charset=UTF-8' },
                body: JSON.stringify({ lessonIds: lessonIds, studentId: parseInt(stdId, 10), weekIndex: '' })
            });
            const datumText = await datumResp.text();
            return JSON.stringify({ stdId, semId, bizId, datum: datumText });
            """

            self.webView.callAsyncJavaScript(inPageFetchScript, arguments: [:], in: nil, in: .page) { [weak self] jsResult in
                guard let self = self else { return }
                if case .success(let val) = jsResult,
                   let jsonStr = val as? String,
                   let wrapperData = jsonStr.data(using: .utf8),
                   let wrapper = try? JSONSerialization.jsonObject(with: wrapperData) as? [String: String],
                   let datumStr = wrapper["datum"],
                   let stdId = wrapper["stdId"],
                   let semId = wrapper["semId"],
                   let bizId = wrapper["bizId"],
                   let schedule = try? CourseScheduleService.shared.applyDatumJSONString(datumStr, studentId: stdId, semesterId: semId, bizTypeId: bizId) {
                    DispatchQueue.main.async {
                        self.handleSyncSuccess(schedule)
                    }
                    return
                }

                // 若页内 JS 拉取未成功，回退到 HTML + Cookie 解析请求
                self.webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] htmlObj, _ in
                    guard let self = self else { return }
                    let html = (htmlObj as? String) ?? ""
                    CourseScheduleService.shared.fetchAndApplyFromHTML(
                        html: html,
                        studentId: detectedStudentId,
                        cookies: cookies
                    ) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            switch result {
                            case .success(let schedule):
                                self.handleSyncSuccess(schedule)
                            case .failure(let error):
                                self.isSyncing = false
                                self.progressIndicator.stopAnimation(nil)
                                self.statusLabel.stringValue = "❌ 课表同步失败: \(error.localizedDescription)"
                                self.statusLabel.textColor = NSColor.systemRed
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleSyncSuccess(_ schedule: CourseScheduleData) {
        self.isSyncing = false
        self.progressIndicator.stopAnimation(nil)
        self.statusLabel.stringValue = "🎉 课表同步成功！已获取 \(schedule.lessons.count) 节课程，正在自动返回..."
        self.statusLabel.textColor = NSColor.systemGreen
        EmptyClassroomService.shared.syncTodayAndTomorrowStudyRooms(forceRefresh: true) { _ in }
        NotificationHelper.sendNotification(
            title: "🎉 HFUT课表同步成功",
            body: "已成功同步 \(schedule.lessons.count) 门课次数据，可在菜单栏与桌面组件随时查看！"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.window?.close()
            CourseScheduleWindowController.shared.showWindow(nil)
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
