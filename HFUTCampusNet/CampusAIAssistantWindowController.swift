import Foundation
import AppKit
import WebKit

// Only final answer text and safe status labels cross into the AppKit UI.
private final class CampusAIStreamClient: NSObject, URLSessionDataDelegate {
    enum Event {
        case text(String)
        case status(String)
        case finished(String?)
    }

    private let onEvent: (Event) -> Void
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private var task: URLSessionDataTask?
    private var parser = CampusAISSEParser()
    private var completed = false

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func start(question: String, groupID: String, modelID: String,
               cookies: [HTTPCookie], aiFlow: String, referer: URL?) {
        var req = URLRequest(url: CampusAIEndpoint.api.appendingPathComponent("chat/send"))
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(aiFlow, forHTTPHeaderField: "aiflow")
        if let referer = referer, referer.host?.lowercased() == CampusAIEndpoint.host {
            req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let header = CampusAIEndpoint.cookieHeader(from: cookies) {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }
        let traceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        req.httpBody = CampusAIRequestBuilder.chatBody(
            text: question, groupID: groupID, modelID: modelID, traceID: traceID
        )
        task = session.dataTask(with: req)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        finish("已取消")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            completionHandler(.cancel)
            finish("AI 平台会话无效或已过期（HTTP \(status)）。请从信息门户重新进入合工大 AI 辅导员后重试。")
        } else if !(200...299).contains(status) {
            completionHandler(.cancel)
            finish("平台返回 HTTP \(status)，无法继续对话。")
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        consume(parser.append(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed else { return }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            finish("连接中断（网络错误）。请检查网络后重试。")
        } else if let error = error as NSError?, error.code == NSURLErrorCancelled {
            finish("连接已取消。")
        } else {
            consume(parser.finish())
            guard !completed else { return }
            finish(nil)
        }
    }

    private func consume(_ events: [CampusAISSEEvent]) {
        for event in events {
            switch event {
            case .text(let chunk):
                onEvent(.text(chunk))
            case .status(.thinking):
                onEvent(.status("AI 正在生成回复…"))
            case .status(.toolStarted):
                onEvent(.status("正在调用学校智能体工具…"))
            case .status(.toolSucceeded):
                onEvent(.status("工具执行完成，正在生成回复…"))
            case .status(.toolFailed):
                onEvent(.status("智能体工具未能完成。"))
            case .completed:
                finish(nil)
            case .failed:
                finish("智能体处理失败。平台错误详情未显示。")
                task?.cancel()
            case .incomplete:
                finish("回复连接提前结束，未收到完成标记。请重试。")
            case .responseTooLarge:
                finish("平台响应超过本地安全处理上限，已中止。")
                task?.cancel()
            }
            if completed { return }
        }
    }

    private func finish(_ error: String?) {
        guard !completed else { return }
        completed = true
        onEvent(.finished(error))
        session.invalidateAndCancel()
    }
}

private final class CampusAIWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private struct CampusAIPendingLookupSend {
    let question: String
    let agentID: String
    let modelID: String
    let cookies: [HTTPCookie]
    let saveCookies: [HTTPCookie]
    let aiFlow: String
    let referer: URL?
    let navigationID: UUID
}

public final class CampusAIAssistantWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    public static let shared = CampusAIAssistantWindowController()

    private let defaults = UserDefaults.standard
    private let agentField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let groupField = NSTextField(string: "")
    private let promptField = NSTextField(string: "")
    private let transcriptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "正在检查学校 AI 登录状态…")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let newSessionButton = NSButton(title: "新建会话", target: nil, action: nil)
    private let loginButton = NSButton(title: "信息门户", target: nil, action: nil)
    private let backButton = NSButton(title: "返回聊天", target: nil, action: nil)
    private let traceButton = NSButton(title: "复制脱敏轨迹", target: nil, action: nil)
    private let transcriptScroll = NSScrollView()
    private let scriptController = WKUserContentController()
    private let casLoginPanel = HFUTCASLoginPanel(frame: NSRect(x: 20, y: 128, width: 940, height: 458))
    private var chatOnlyViews: [NSView] = []
    private var captchaMessageProxy: CampusAIWeakScriptMessageHandler!
    private var loginWebView: WKWebView!
    private var portalWebViews: [WKWebView] = []
    private var navigationTrace: [String] = []
    private var activeClient: CampusAIStreamClient?
    private var activeLookupTask: URLSessionDataTask?
    private var activeLookupSession: URLSession?
    private var activeLookupID: UUID?
    private var pendingLookupSend: CampusAIPendingLookupSend?
    private var emptyHistoryAgentID: String?
    private var emptyHistoryNavigationID: UUID?
    private var sending = false
    private var activeAssistantMarkdown = ""
    private var activeAssistantStart: Int?
    private var displayingLogin = false
    private var nativeCASFormReady = false
    private var preferWebLoginForCurrentCASPage = false
    private var casTicketErrorDetected = false
    private var casProbeToken = UUID()
    private var captchaRefreshToken: UUID?
    private var automaticNavigationAttempts = Set<String>()
    // 完整 SSO 跳转由信息门户及其注册应用发起；本客户端不构造 ST/service。
    private var portalNavigationID = UUID()

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "校园 AI 助手 · 合肥工业大学"
        w.minSize = NSSize(width: 780, height: 550)
        w.center()
        super.init(window: w)
        w.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: 20)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func setupUI() {
        guard let window = window else { return }
        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let title = NSTextField(labelWithString: "合工大 AI 对话")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.frame = NSRect(x: 20, y: 653, width: 220, height: 26)
        title.autoresizingMask = [.minYMargin]
        root.addSubview(title)

        loginButton.frame = NSRect(x: 750, y: 650, width: 105, height: 30)
        loginButton.autoresizingMask = [.minXMargin, .minYMargin]
        loginButton.target = self
        loginButton.action = #selector(showInformationPortal)
        root.addSubview(loginButton)

        backButton.frame = NSRect(x: 860, y: 650, width: 100, height: 30)
        backButton.autoresizingMask = [.minXMargin, .minYMargin]
        backButton.target = self
        backButton.action = #selector(showChat)
        backButton.isEnabled = false
        root.addSubview(backButton)

        traceButton.frame = NSRect(x: 610, y: 650, width: 135, height: 30)
        traceButton.autoresizingMask = [.minXMargin, .minYMargin]
        traceButton.target = self
        traceButton.action = #selector(copyNavigationTrace)
        traceButton.isEnabled = false
        root.addSubview(traceButton)

        newSessionButton.frame = NSRect(x: 500, y: 650, width: 104, height: 30)
        newSessionButton.autoresizingMask = [.minXMargin, .minYMargin]
        newSessionButton.target = self
        newSessionButton.action = #selector(startNewSession)
        root.addSubview(newSessionButton)
        chatOnlyViews.append(newSessionButton)

        let agentLabel = label("智能体 ID", x: 20, y: 611, width: 75)
        root.addSubview(agentLabel)
        chatOnlyViews.append(agentLabel)
        agentField.frame = NSRect(x: 96, y: 608, width: 236, height: 24)
        agentField.stringValue = defaults.string(forKey: "campus_ai_agent_id") ?? CampusAIEndpoint.defaultAgentID
        root.addSubview(agentField)
        chatOnlyViews.append(agentField)
        let modelLabel = label("模型 ID", x: 345, y: 611, width: 58)
        root.addSubview(modelLabel)
        chatOnlyViews.append(modelLabel)
        modelField.frame = NSRect(x: 402, y: 608, width: 236, height: 24)
        modelField.stringValue = defaults.string(forKey: "campus_ai_model_id") ?? CampusAIEndpoint.defaultModelID
        root.addSubview(modelField)
        chatOnlyViews.append(modelField)
        let groupLabel = label("会话 ID", x: 648, y: 611, width: 60)
        root.addSubview(groupLabel)
        chatOnlyViews.append(groupLabel)
        groupField.frame = NSRect(x: 706, y: 608, width: 254, height: 24)
        groupField.placeholderString = "留空自动使用历史会话；空历史时首次发送会创建"
        root.addSubview(groupField)
        chatOnlyViews.append(groupField)
        for item in [agentField, modelField, groupField] {
            item.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            item.autoresizingMask = [.minYMargin]
        }
        groupField.autoresizingMask = [.minXMargin, .width, .minYMargin]

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // 与 App 现有统一登录 WebView 共用 Cookie 存储
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        captchaMessageProxy = CampusAIWeakScriptMessageHandler(target: self)
        scriptController.add(captchaMessageProxy, name: "campusAICaptcha")
        scriptController.add(captchaMessageProxy, name: "campusAIAutoNavigation")
        config.userContentController = scriptController
        loginWebView = WKWebView(frame: NSRect(x: 20, y: 128, width: 940, height: 458), configuration: config)
        loginWebView.navigationDelegate = self
        loginWebView.uiDelegate = self
        loginWebView.autoresizingMask = [.width, .height]
        loginWebView.isHidden = true
        root.addSubview(loginWebView)
        portalWebViews = [loginWebView]

        casLoginPanel.frame = loginWebView.frame
        casLoginPanel.autoresizingMask = [.width, .height]
        casLoginPanel.isHidden = true
        casLoginPanel.onRefresh = { [weak self] in self?.refreshNativeCaptcha() }
        casLoginPanel.onSubmit = { [weak self] username, password, captcha in
            self?.submitNativeCASLogin(username: username, password: password, captcha: captcha)
        }
        casLoginPanel.onUseWebLogin = { [weak self] in self?.showCASWebLogin() }
        root.addSubview(casLoginPanel)

        transcriptScroll.frame = loginWebView.frame
        transcriptScroll.autoresizingMask = [.width, .height]
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .bezelBorder
        transcriptView.frame = NSRect(x: 0, y: 0, width: 940, height: 458)
        transcriptView.autoresizingMask = [.width]
        transcriptView.isVerticallyResizable = true
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.font = .systemFont(ofSize: 13)
        transcriptView.textColor = .labelColor
        transcriptView.textContainerInset = NSSize(width: 12, height: 12)
        transcriptView.textStorage?.setAttributedString(CampusAITranscriptStyle.attributedString(
            "欢迎使用校园 AI 助手。\n\n本功能复用 App 的 WKWebView 网站登录状态。首次使用请从信息门户中的「AI 应用中台」进入「合工大辅导员」，以便由门户完成学校指定的服务认证。\n聊天记录仅保留在当前窗口内。\n\n",
            font: transcriptView.font ?? .systemFont(ofSize: 13)
        ))
        transcriptScroll.documentView = transcriptView
        root.addSubview(transcriptScroll)
        chatOnlyViews.append(transcriptScroll)

        promptField.frame = NSRect(x: 20, y: 72, width: 820, height: 32)
        promptField.placeholderString = "输入你想咨询的问题，例如：请查询我本人的课程成绩"
        promptField.font = .systemFont(ofSize: 13)
        promptField.autoresizingMask = [.width, .maxYMargin]
        promptField.target = self
        promptField.action = #selector(sendMessageFromKeyboard)
        root.addSubview(promptField)
        chatOnlyViews.append(promptField)

        sendButton.frame = NSRect(x: 851, y: 72, width: 109, height: 32)
        sendButton.autoresizingMask = [.minXMargin, .maxYMargin]
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        root.addSubview(sendButton)
        chatOnlyViews.append(sendButton)

        statusLabel.frame = NSRect(x: 20, y: 22, width: 940, height: 28)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(statusLabel)
    }

    public func showAssistant() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.hasAISession(cookies) {
                    self.displayChat(status: "检测到 AI 平台会话，正在自动准备最近会话…")
                    let agentID = self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.prepareRecentGroupIfNeeded(
                        agentID: agentID, allCookies: cookies,
                        referer: self.aiRefererURL(for: agentID),
                        navigationID: self.portalNavigationID
                    )
                } else {
                    self.openInformationPortal()
                }
            }
        }
    }

    private func hasAISession(_ cookies: [HTTPCookie]) -> Bool {
        let requestCookies = CampusAIEndpoint.cookies(from: cookies, requestPath: CampusAIEndpoint.chatSendPath)
        return CampusAIEndpoint.aiFlowCookie(from: requestCookies) != nil
    }

    private func displayChat(status: String) {
        displayingLogin = false
        nativeCASFormReady = false
        preferWebLoginForCurrentCASPage = false
        casTicketErrorDetected = false
        captchaRefreshToken = nil
        casLoginPanel.isHidden = true
        casLoginPanel.clearSensitiveFields()
        for view in chatOnlyViews { view.isHidden = false }
        for webView in portalWebViews { webView.isHidden = true }
        transcriptScroll.isHidden = false
        backButton.isEnabled = false
        statusLabel.stringValue = status
    }

    // 让学校信息门户发起 AI 应用的 SSO 跳转，不能自行猜测 CAS service 值。
    private func openInformationPortal() {
        if sending {
            activeClient?.cancel()
            if sending { complete("已取消") }
        }
        cancelGroupLookup()
        emptyHistoryAgentID = nil
        emptyHistoryNavigationID = nil
        groupField.stringValue = ""
        portalNavigationID = UUID()
        automaticNavigationAttempts.removeAll(keepingCapacity: true)
        navigationTrace.removeAll(keepingCapacity: true)
        traceButton.isEnabled = false
        displayingLogin = true
        nativeCASFormReady = false
        preferWebLoginForCurrentCASPage = false
        casTicketErrorDetected = false
        captchaRefreshToken = nil
        casProbeToken = UUID()
        casLoginPanel.prepare(username: SettingsManager.shared.portalUsername,
                              password: SettingsManager.shared.casPassword)
        casLoginPanel.isHidden = true
        for view in chatOnlyViews { view.isHidden = true }
        for webView in portalWebViews { webView.isHidden = (webView !== loginWebView) }
        loginWebView.isHidden = false
        transcriptScroll.isHidden = true
        backButton.isEnabled = true
        statusLabel.stringValue = "请沿学校正常路径进入 AI 应用中台 → AI 应用广场 → 合工大 AI 辅导员。"
        let url = URL(string: "https://one.hfut.edu.cn/")!
        loginWebView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    @objc private func showInformationPortal() {
        openInformationPortal()
    }

    @objc private func showChat() {
        let navigationID = portalNavigationID
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.portalNavigationID == navigationID else { return }
                let hasSession = self.hasAISession(cookies)
                self.displayChat(status: hasSession
                    ? "检测到 AI 平台会话，正在自动准备最近会话…"
                    : "尚未发现 AiFlow 会话。请返回信息门户，按学校的正常入口进入智能体。")
                if hasSession {
                    let agentID = self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.prepareRecentGroupIfNeeded(
                        agentID: agentID, allCookies: cookies,
                        referer: self.aiRefererURL(for: agentID), navigationID: navigationID
                    )
                }
            }
        }
    }

    @objc private func copyNavigationTrace() {
        guard !navigationTrace.isEmpty else {
            statusLabel.stringValue = "当前没有可复制的跳转记录。"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(navigationTrace.joined(separator: "\n"), forType: .string)
        statusLabel.stringValue = "已复制 \(navigationTrace.count) 条脱敏记录，仅含事件、host、path 和 query 参数名。"
    }

    private func recordNavigation(_ event: String, url: URL?, target: String = "main") {
        guard displayingLogin, let url = url else { return }
        let line = CampusAISafeNavigationTrace.line(event: event, url: url, target: target)
        if navigationTrace.last != line {
            navigationTrace.append(line)
            if navigationTrace.count > 100 { navigationTrace.removeFirst(navigationTrace.count - 100) }
        }
        traceButton.isEnabled = !navigationTrace.isEmpty
        statusLabel.stringValue = "SSO 跳转：\(line)"
    }

    private func inspectCASLoginPage(_ webView: WKWebView) {
        guard displayingLogin, webView === loginWebView,
              HFUTCASLoginSupport.isLoginPage(webView.url) else { return }
        let token = UUID()
        casProbeToken = token
        webView.evaluateJavaScript(HFUTCASLoginSupport.probeScript) { [weak self, weak webView] result, _ in
            DispatchQueue.main.async {
                guard let self = self, let webView = webView,
                      self.displayingLogin, webView === self.loginWebView,
                      self.casProbeToken == token,
                      HFUTCASLoginSupport.isLoginPage(webView.url) else { return }
                self.applyCASLoginProbe(result, in: webView)
            }
        }
    }

    private func applyCASLoginProbe(_ result: Any?, in webView: WKWebView) {
        guard !casTicketErrorDetected else {
            nativeCASFormReady = false
            casLoginPanel.isHidden = true
            webView.isHidden = false
            return
        }
        guard let descriptor = result as? [String: Any], descriptor["ready"] as? Bool == true else {
            nativeCASFormReady = false
            casLoginPanel.isHidden = true
            webView.isHidden = false
            if !preferWebLoginForCurrentCASPage && !casTicketErrorDetected {
                statusLabel.stringValue = "CAS 页面当前未提供可识别的密码与验证码表单。可在网页中选择密码登录或其他方式。"
            }
            return
        }

        if descriptor["captureFailed"] as? Bool == true {
            showCASWebLoginFallback("验证码无法从当前页面安全读取，已保留学校网页登录方式。")
            return
        }

        // A refresh click invalidates the old image immediately. Only accept a new
        // image after the page's own CAPTCHA image emits its load event.
        if captchaRefreshToken != nil {
            casLoginPanel.setStatus("正在等待 CAS 页面加载新的验证码…")
            if preferWebLoginForCurrentCASPage {
                casLoginPanel.isHidden = true
                webView.isHidden = false
            } else {
                casLoginPanel.isHidden = false
                webView.isHidden = true
            }
            return
        }

        let wasReady = nativeCASFormReady
        nativeCASFormReady = true
        if !wasReady {
            casLoginPanel.prepare(username: SettingsManager.shared.portalUsername,
                                  password: SettingsManager.shared.casPassword)
        }

        if let dataURL = descriptor["captchaDataURL"] as? String {
            guard let imageData = HFUTCASLoginSupport.captchaImageData(from: dataURL) else {
                showCASWebLoginFallback("验证码图片格式不受支持，已保留学校网页登录方式。")
                return
            }
            casLoginPanel.setCaptchaImage(imageData)
            casLoginPanel.setStatus("验证码已从当前 CAS 页面读取。")
            captchaRefreshToken = nil
        } else {
            casLoginPanel.setStatus("正在读取验证码；若图片未出现，可刷新或切换到网页登录。")
        }

        if preferWebLoginForCurrentCASPage {
            casLoginPanel.isHidden = true
            webView.isHidden = false
        } else {
            casLoginPanel.isHidden = false
            webView.isHidden = true
            statusLabel.stringValue = "检测到学校 CAS 密码登录表单。"
        }
    }

    private func showCASWebLoginFallback(_ message: String) {
        nativeCASFormReady = false
        casProbeToken = UUID()
        captchaRefreshToken = nil
        casLoginPanel.setSubmitting(false)
        casLoginPanel.isHidden = true
        loginWebView.isHidden = false
        statusLabel.stringValue = message
    }

    @objc private func showCASWebLogin() {
        preferWebLoginForCurrentCASPage = true
        casLoginPanel.isHidden = true
        loginWebView.isHidden = false
        statusLabel.stringValue = "已切换到学校网页登录。登录仍由 CAS 页面完成。"
    }

    private func refreshNativeCaptcha() {
        guard nativeCASFormReady, HFUTCASLoginSupport.isLoginPage(loginWebView.url) else {
            showCASWebLoginFallback("当前验证码页面已变化，请在学校网页中继续登录。")
            return
        }
        let token = UUID()
        captchaRefreshToken = token
        casLoginPanel.setCaptchaImage(nil)
        casLoginPanel.clearCaptchaEntry()
        casLoginPanel.setStatus("正在调用当前 CAS 页面的验证码刷新控件…")
        loginWebView.evaluateJavaScript(HFUTCASLoginSupport.refreshCaptchaScript) { [weak self] result, _ in
            guard let self = self, self.captchaRefreshToken == token else { return }
            guard result as? Bool == true else {
                self.captchaRefreshToken = nil
                self.casLoginPanel.setStatus("当前页面没有可识别的刷新控件；可切换到网页登录刷新。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, self.captchaRefreshToken == token else { return }
                self.captchaRefreshToken = nil
                self.casLoginPanel.setStatus("尚未观察到新验证码；可重试或切换到网页登录。")
            }
        }
    }

    private func submitNativeCASLogin(username: String, password: String, captcha: String) {
        guard nativeCASFormReady, HFUTCASLoginSupport.isLoginPage(loginWebView.url),
              casLoginPanel.hasCaptchaImage else {
            showCASWebLoginFallback("当前 CAS 表单已变化，请在学校网页中继续登录。")
            return
        }
        guard let script = HFUTCASLoginSupport.submitScript(
            username: username, password: password, captcha: captcha
        ) else {
            casLoginPanel.setStatus("无法准备原始 CAS 表单提交，请切换到网页登录。")
            return
        }

        // Match the existing unified-login behavior by updating its existing credential fields.
        SettingsManager.shared.portalUsername = username
        SettingsManager.shared.casPassword = password
        nativeCASFormReady = false
        preferWebLoginForCurrentCASPage = false
        casProbeToken = UUID()
        casLoginPanel.setSubmitting(true)
        casLoginPanel.setStatus("正在提交到学校 CAS 页面并等待门户回跳…")
        casLoginPanel.isHidden = true
        loginWebView.isHidden = false
        loginWebView.evaluateJavaScript(script) { [weak self] result, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.displayingLogin else { return }
                if result as? Bool == true {
                    self.statusLabel.stringValue = "已通过 CAS 页面提交登录，正在等待学校认证结果…"
                } else if HFUTCASLoginSupport.isLoginPage(self.loginWebView.url) {
                    self.nativeCASFormReady = true
                    self.casLoginPanel.isHidden = false
                    self.loginWebView.isHidden = true
                    self.casLoginPanel.setSubmitting(false)
                    self.casLoginPanel.setStatus("未能提交当前 CAS 表单；请检查页面或切换到网页登录。")
                }
            }
        }
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              let body = message.body as? [String: String] else { return }

        if message.name == "campusAIAutoNavigation" {
            handleAutomaticNavigationMessage(body, from: webView, host: message.frameInfo.securityOrigin.host.lowercased())
            return
        }

        guard message.name == "campusAICaptcha",
              webView === loginWebView,
              message.frameInfo.securityOrigin.host.lowercased() == "cas.hfut.edu.cn",
              displayingLogin,
              ["formChanged", "captchaChanged"].contains(body["event"] ?? "") else { return }
        if body["event"] == "captchaChanged" {
            captchaRefreshToken = nil
        }
        inspectCASLoginPage(webView)
    }

    private func handleAutomaticNavigationMessage(_ body: [String: String], from webView: WKWebView, host: String) {
        guard displayingLogin, portalWebViews.contains(where: { $0 === webView }),
              body["event"] == "autoNavigation",
              let step = body["step"], let result = body["result"] else { return }

        let expectedHost: String
        switch step {
        case "portal": expectedHost = "one.hfut.edu.cn"
        case "plaza", "advisor": expectedHost = CampusAIEndpoint.host
        default: return
        }
        guard host == expectedHost else { return }

        if result == "clicked" {
            switch step {
            case "portal": statusLabel.stringValue = "正在通过信息门户入口打开 AI 应用中台…"
            case "plaza": statusLabel.stringValue = "正在打开 AI 应用广场…"
            case "advisor": statusLabel.stringValue = "正在加载目标智能体并准备会话…"
            default: break
            }
        } else if result == "opened", step == "plaza" {
            statusLabel.stringValue = "已进入 AI 应用广场，正在打开合工大 AI 辅导员…"
        } else if result == "opened", step == "advisor" {
            statusLabel.stringValue = "已打开合工大 AI 辅导员，正在准备会话…"
        } else if result == "open-failed", step == "advisor" {
            statusLabel.stringValue = "已找到辅导员卡片，但页面没有完成跳转；请点开卡片后重试。"
        } else if result == "manual", step == "plaza" {
            statusLabel.stringValue = "已到达 AI 应用广场；当前智能体 ID 不是默认辅导员，请手动选择目标智能体。"
        } else if result == "missing" {
            switch step {
            case "portal": statusLabel.stringValue = "未找到门户中的 AI中台入口，请在网页中手动点击「AI中台」。"
            case "plaza": statusLabel.stringValue = "未找到 AI 应用广场或辅导员卡片，请在网页中手动继续。"
            case "advisor": statusLabel.stringValue = "未找到合工大 AI 辅导员卡片，请在应用广场中手动打开。"
            default: break
            }
        }
    }

    @objc private func sendMessage() {
        switch CampusAIInputActionPolicy.decision(for: .sendButton, isSending: sending) {
        case .submit:
            break
        case .cancel:
            if let client = activeClient {
                client.cancel()
            } else if let task = activeLookupTask {
                pendingLookupSend = nil
                activeLookupID = nil
                task.cancel()
                activeLookupSession?.invalidateAndCancel()
                activeLookupTask = nil
                activeLookupSession = nil
                complete("已取消")
            } else {
                complete("已取消")
            }
            return
        case .ignore:
            return
        }
        let question = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let agentID = agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CampusAIEndpoint.validID(agentID), CampusAIEndpoint.validID(modelID),
              (groupID.isEmpty || CampusAIEndpoint.validID(groupID)) else {
            statusLabel.stringValue = "智能体、模型或会话 ID 格式不正确。"
            return
        }

        defaults.set(agentID, forKey: "campus_ai_agent_id")
        defaults.set(modelID, forKey: "campus_ai_model_id")
        activeAssistantMarkdown = ""
        activeAssistantStart = nil
        sending = true
        sendButton.title = "停止"
        promptField.isEnabled = false
        appendText("\n你：\(question)\n\nAI：")
        statusLabel.stringValue = "检查当前学校 AI 登录会话…"

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] all in
            DispatchQueue.main.async {
                guard let self = self, self.sending else { return }
                let cookies = CampusAIEndpoint.cookies(from: all, requestPath: CampusAIEndpoint.chatSendPath)
                let saveCookies = CampusAIEndpoint.cookies(from: all, requestPath: CampusAIEndpoint.chatSavePath)
                guard let aiFlow = CampusAIEndpoint.aiFlowCookie(from: cookies)?.value else {
                    self.complete("当前没有 AI 会话。请点击「信息门户」，从「AI 应用中台」进入「合工大辅导员」。")
                    self.openInformationPortal()
                    return
                }
                let currentGroupID = self.groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentGroupID.isEmpty {
                    guard CampusAIEndpoint.validID(currentGroupID) else {
                        self.complete("会话 ID 格式不正确。")
                        return
                    }
                    if self.activeLookupTask != nil { self.cancelGroupLookup() }
                    let referer = self.aiRefererURL(for: agentID)
                    self.startStreaming(question: question, groupID: currentGroupID,
                                        modelID: modelID, cookies: cookies, aiFlow: aiFlow,
                                        referer: referer)
                } else {
                    let referer = self.aiRefererURL(for: agentID)
                    self.pendingLookupSend = CampusAIPendingLookupSend(
                        question: question, agentID: agentID, modelID: modelID,
                        cookies: cookies, saveCookies: saveCookies, aiFlow: aiFlow, referer: referer,
                        navigationID: self.portalNavigationID
                    )
                    if self.activeLookupTask != nil {
                        self.statusLabel.stringValue = "正在自动准备会话，准备完成后会立即发送…"
                    } else if self.emptyHistoryAgentID == agentID,
                              self.emptyHistoryNavigationID == self.portalNavigationID {
                        if let pending = self.pendingLookupSend {
                            self.createSessionAndSend(pending)
                        }
                    } else {
                        self.startRecentGroupLookup(
                            agentID: agentID, allCookies: all, aiFlow: aiFlow,
                            referer: referer, navigationID: self.portalNavigationID
                        )
                    }
                }
            }
        }
    }

    @objc private func startNewSession() {
        let agentID = agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CampusAIEndpoint.validID(agentID) else {
            statusLabel.stringValue = "智能体 ID 格式不正确，无法准备新会话。"
            return
        }

        if sending {
            activeClient?.cancel()
            cancelGroupLookup()
            if sending { complete("当前回复已取消。") }
        } else {
            cancelGroupLookup()
        }

        groupField.stringValue = ""
        emptyHistoryAgentID = agentID
        emptyHistoryNavigationID = portalNavigationID
        activeAssistantMarkdown = ""
        activeAssistantStart = nil
        transcriptView.textStorage?.setAttributedString(CampusAITranscriptStyle.attributedString(
            "已新建对话\n\n",
            font: transcriptView.font ?? .systemFont(ofSize: 13)
        ))
        statusLabel.stringValue = "新会话已准备；发送首条消息时会由平台创建正式会话。"
        promptField.becomeFirstResponder()
    }

    @objc private func sendMessageFromKeyboard() {
        // Return in the prompt field only submits. It must never become the Stop action
        // if AppKit delivers another action after the request has started.
        guard CampusAIInputActionPolicy.decision(for: .keyboardReturn, isSending: sending) == .submit else {
            return
        }
        sendMessage()
    }

    private func prepareRecentGroupIfNeeded(agentID: String, allCookies: [HTTPCookie],
                                            referer: URL?, navigationID: UUID) {
        guard CampusAIEndpoint.validID(agentID) else {
            statusLabel.stringValue = "智能体 ID 无效，无法自动准备会话。"
            return
        }
        let existingGroupID = groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if CampusAIEndpoint.validID(existingGroupID) {
            statusLabel.stringValue = "会话已准备，可以直接发送。"
            return
        }
        guard activeLookupTask == nil else { return }
        let historyCookies = CampusAIEndpoint.cookies(from: allCookies, requestPath: CampusAIEndpoint.historyPath)
        guard let aiFlow = CampusAIEndpoint.aiFlowCookie(from: historyCookies)?.value else {
            statusLabel.stringValue = "页面已打开，但尚未发现 AI 平台会话 Cookie。"
            return
        }
        startRecentGroupLookup(agentID: agentID, allCookies: allCookies, aiFlow: aiFlow,
                              referer: referer, navigationID: navigationID)
    }

    private func startRecentGroupLookup(agentID: String, allCookies: [HTTPCookie], aiFlow: String,
                                       referer: URL?, navigationID: UUID) {
        guard activeLookupTask == nil else { return }
        statusLabel.stringValue = "正在自动获取该智能体的最近会话…"
        var request = URLRequest(url: CampusAIEndpoint.api.appendingPathComponent("agent/getHistoryData"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(aiFlow, forHTTPHeaderField: "aiflow")
        if let referer = referer, referer.host?.lowercased() == CampusAIEndpoint.host {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let historyCookies = CampusAIEndpoint.cookies(from: allCookies, requestPath: CampusAIEndpoint.historyPath)
        if let cookie = CampusAIEndpoint.cookieHeader(from: historyCookies) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        guard let requestBody = CampusAIRequestBuilder.historyBody(agentID: agentID) else {
            finishGroupLookupFailure("智能体 ID 无法用于会话查询。", navigationID: navigationID)
            return
        }
        request.httpBody = requestBody

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let lookupID = UUID()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            let successful = (200...299).contains(http?.statusCode ?? 0)
            let lookupResult = successful
                ? (data.map { CampusAIHistoryResponse.lookup(from: $0, expectedAgentID: agentID) } ?? .invalid)
                : .invalid
            var statusMessage: String?
            if http?.statusCode == 401 || http?.statusCode == 403 {
                statusMessage = "AI 平台会话无效或已过期。请重新从信息门户进入目标智能体。"
            } else if error != nil {
                statusMessage = "查询会话时网络连接失败，请检查网络后重试。"
            } else if !successful {
                statusMessage = "平台查询会话失败（HTTP \(http?.statusCode ?? 0)）。"
            } else {
                statusMessage = nil
            }
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self = self, self.activeLookupID == lookupID,
                      self.portalNavigationID == navigationID else { return }
                self.activeLookupID = nil
                self.activeLookupTask = nil
                self.activeLookupSession = nil
                let currentAgentID = self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard currentAgentID == agentID else {
                    if self.pendingLookupSend != nil {
                        self.pendingLookupSend = nil
                        self.complete("智能体 ID 已变化，旧查询结果未应用；请重新发送。")
                    } else {
                        self.statusLabel.stringValue = "智能体 ID 已变化，旧查询结果未应用。"
                    }
                    return
                }
                switch lookupResult {
                case .session(let groupID):
                    self.emptyHistoryAgentID = nil
                    self.emptyHistoryNavigationID = nil
                    let manualGroupID = self.groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let selectedGroupID = CampusAIEndpoint.validID(manualGroupID) ? manualGroupID : groupID
                    self.groupField.stringValue = selectedGroupID
                    if let pending = self.pendingLookupSend {
                        self.pendingLookupSend = nil
                        guard pending.agentID == agentID,
                              pending.navigationID == self.portalNavigationID else {
                            self.complete("会话所属智能体已变化，请重新发送。")
                            return
                        }
                        self.startStreaming(question: pending.question, groupID: selectedGroupID,
                                            modelID: pending.modelID, cookies: pending.cookies,
                                            aiFlow: pending.aiFlow, referer: pending.referer)
                    } else {
                        self.statusLabel.stringValue = "会话已自动准备，可以直接发送。"
                    }
                case .empty:
                    self.emptyHistoryAgentID = agentID
                    self.emptyHistoryNavigationID = navigationID
                    if let pending = self.pendingLookupSend {
                        self.createSessionAndSend(pending)
                    } else {
                        self.statusLabel.stringValue = "暂无历史会话；首次发送时会自动创建新会话。"
                    }
                case .invalid:
                    let message = statusMessage ?? "平台历史会话响应无法识别；为避免误创建会话，请重试或填写已有会话 ID。"
                    if self.pendingLookupSend != nil {
                        self.pendingLookupSend = nil
                        self.complete(message)
                    } else {
                        self.statusLabel.stringValue = message
                    }
                }
            }
        }
        activeLookupID = lookupID
        activeLookupSession = session
        activeLookupTask = task
        task.resume()
    }

    private func createSessionAndSend(_ pending: CampusAIPendingLookupSend) {
        guard sending, pendingLookupSend?.navigationID == pending.navigationID,
              pending.navigationID == portalNavigationID,
              pending.agentID == agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
            complete("智能体页面已变化，未创建会话；请重新发送。")
            return
        }
        guard activeLookupTask == nil else { return }
        let saveCookies = CampusAIEndpoint.cookies(from: pending.saveCookies,
                                                   requestPath: CampusAIEndpoint.chatSavePath)
        guard let aiFlow = CampusAIEndpoint.aiFlowCookie(from: saveCookies)?.value,
              let body = CampusAIRequestBuilder.chatSaveBody(text: pending.question, agentID: pending.agentID) else {
            pendingLookupSend = nil
            complete("缺少可用于创建会话的 AI 平台会话，或请求参数无效。请重新从信息门户进入后重试。")
            return
        }

        emptyHistoryAgentID = nil
        emptyHistoryNavigationID = nil
        statusLabel.stringValue = "正在创建新会话…"
        var request = URLRequest(url: CampusAIEndpoint.api.appendingPathComponent("chat/save"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(aiFlow, forHTTPHeaderField: "aiflow")
        if let referer = pending.referer, referer.host?.lowercased() == CampusAIEndpoint.host {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookieHeader = CampusAIEndpoint.cookieHeader(from: saveCookies) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let lookupID = UUID()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            let successful = (200...299).contains(http?.statusCode ?? 0)
            let groupID = successful ? data.flatMap(CampusAIChatSaveResponse.groupID(from:)) : nil
            let statusMessage: String?
            if http?.statusCode == 401 || http?.statusCode == 403 {
                statusMessage = "AI 平台会话无效或已过期。请重新从信息门户进入目标智能体。"
            } else if error != nil {
                statusMessage = "创建会话时网络连接失败，请检查网络后重试。"
            } else if !successful {
                statusMessage = "平台创建会话失败（HTTP \(http?.statusCode ?? 0)）。"
            } else {
                statusMessage = nil
            }
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self = self, self.activeLookupID == lookupID,
                      self.portalNavigationID == pending.navigationID,
                      self.pendingLookupSend?.agentID == pending.agentID else { return }
                self.activeLookupID = nil
                self.activeLookupTask = nil
                self.activeLookupSession = nil
                guard let groupID = groupID else {
                    self.pendingLookupSend = nil
                    self.complete(statusMessage ?? "平台未返回有效的新会话 ID；未发送消息。请重试，应用不会自行生成会话 ID。")
                    return
                }
                self.groupField.stringValue = groupID
                self.pendingLookupSend = nil
                self.startStreaming(question: pending.question, groupID: groupID,
                                    modelID: pending.modelID, cookies: pending.cookies,
                                    aiFlow: pending.aiFlow, referer: pending.referer)
            }
        }
        activeLookupID = lookupID
        activeLookupSession = session
        activeLookupTask = task
        task.resume()
    }

    private func finishGroupLookupFailure(_ message: String, navigationID: UUID) {
        guard portalNavigationID == navigationID else { return }
        activeLookupID = nil
        if pendingLookupSend != nil {
            pendingLookupSend = nil
            complete(message)
        } else {
            statusLabel.stringValue = message
        }
    }

    private func cancelGroupLookup() {
        activeLookupID = nil
        activeLookupTask?.cancel()
        activeLookupTask = nil
        activeLookupSession?.invalidateAndCancel()
        activeLookupSession = nil
        pendingLookupSend = nil
    }

    private func aiRefererURL(for agentID: String) -> URL? {
        CampusAIEndpoint.referer(from: loginWebView.url, agentID: agentID)
            ?? CampusAIEndpoint.agentReferer(agentID: agentID)
    }

    private func startStreaming(question: String, groupID: String, modelID: String,
                                cookies: [HTTPCookie], aiFlow: String, referer: URL?) {
        statusLabel.stringValue = "已连接，等待智能体回复…"
        let client = CampusAIStreamClient { [weak self] event in
            guard let self = self else { return }
            switch event {
            case .text(let chunk):
                self.appendAssistantMarkdown(chunk)
            case .status(let message):
                self.statusLabel.stringValue = message
            case .finished(let error):
                self.complete(error)
            }
        }
        activeClient = client
        activeAssistantStart = transcriptView.textStorage?.length
        activeAssistantMarkdown = ""
        client.start(question: question, groupID: groupID, modelID: modelID,
                     cookies: cookies, aiFlow: aiFlow, referer: referer)
    }

    private func appendAssistantMarkdown(_ chunk: String) {
        activeAssistantMarkdown += chunk
        guard let storage = transcriptView.textStorage,
              let start = activeAssistantStart, start <= storage.length else {
            appendText(chunk)
            return
        }
        let currentRange = NSRange(location: start, length: storage.length - start)
        let rendered = CampusAITranscriptStyle.markdownAttributedString(
            activeAssistantMarkdown,
            font: transcriptView.font ?? .systemFont(ofSize: 13)
        )
        storage.replaceCharacters(in: currentRange, with: rendered)
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func appendText(_ value: String) {
        transcriptView.textStorage?.append(CampusAITranscriptStyle.attributedString(
            value,
            font: transcriptView.font ?? .systemFont(ofSize: 13)
        ))
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func complete(_ error: String?) {
        guard sending else { return }
        pendingLookupSend = nil
        activeLookupID = nil
        activeLookupTask?.cancel()
        activeLookupTask = nil
        activeLookupSession?.invalidateAndCancel()
        activeLookupSession = nil
        if !activeAssistantMarkdown.isEmpty {
            appendAssistantMarkdown("")
        }
        activeAssistantStart = nil
        activeAssistantMarkdown = ""
        sending = false
        activeClient = nil
        sendButton.title = "发送"
        promptField.isEnabled = true
        promptField.stringValue = ""
        appendText("\n\n")
        statusLabel.stringValue = error ?? "回复完成。"
    }

    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 门户有时使用 window.open() 或 target=_blank，然后继续更新窗口 location。
        // 返回真实的弹出 WKWebView 才能让后续浏览器导航和 CAS 回跳正常执行。
        recordNavigation("popup-request", url: navigationAction.request.url, target: "popup")
        guard navigationAction.targetFrame == nil else { return nil }
        if let url = navigationAction.request.url, url.scheme != "about" {
            let host = url.host?.lowercased() ?? ""
            guard url.scheme == "https",
                  (host == "hfut.edu.cn" || host.hasSuffix(".hfut.edu.cn")) else {
                statusLabel.stringValue = "已拦截非学校 HTTPS 域名的弹出窗口，请在官方门户确认应用入口。"
                return nil
            }
        }
        guard let parent = loginWebView.superview else { return nil }
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController = scriptController
        let popup = WKWebView(frame: loginWebView.frame, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.autoresizingMask = [.width, .height]
        for existing in portalWebViews { existing.isHidden = true }
        parent.addSubview(popup)
        portalWebViews.append(popup)
        loginWebView = popup
        statusLabel.stringValue = "信息门户正在新窗口中启动学校 AI 应用…"
        return popup
    }

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let target = navigationAction.targetFrame?.isMainFrame == false ? "frame" : "main"
        recordNavigation("navigate", url: navigationAction.request.url, target: target)
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        recordNavigation("start", url: webView.url)
        guard displayingLogin, webView === loginWebView else { return }
        automaticNavigationAttempts.removeAll(keepingCapacity: true)
        emptyHistoryAgentID = nil
        emptyHistoryNavigationID = nil
        casProbeToken = UUID()
        captchaRefreshToken = nil
        nativeCASFormReady = false
        preferWebLoginForCurrentCASPage = false
        casTicketErrorDetected = false
        casLoginPanel.setSubmitting(false)
        casLoginPanel.isHidden = true
        webView.isHidden = false
    }

    public func webView(_ webView: WKWebView,
                        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        recordNavigation("redirect", url: webView.url)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        recordNavigation("provisional-failure", url: webView.url)
        statusLabel.stringValue = "学校登录页面连接失败。可复制脱敏跳转轨迹用于排查。"
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let current = webView.url else { return }
        recordNavigation("finish", url: current)
        guard webView === loginWebView, displayingLogin else { return }
        let host = current.host?.lowercased() ?? ""
        captureSharedCASTGC()

        if HFUTCASLoginSupport.isLoginPage(current) {
            inspectCASLoginPage(webView)
        } else {
            nativeCASFormReady = false
            casLoginPanel.isHidden = true
            webView.isHidden = false
        }

        if host == "cas.hfut.edu.cn" || host == "one.hfut.edu.cn" || host == CampusAIEndpoint.host {
            // 只读取页面可见报错文字以便提示；绝不采集 ST 值或密码。
            let navigationID = portalNavigationID
            webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 1300) : ''") { [weak self] result, _ in
                guard let self = self, self.displayingLogin,
                      self.portalNavigationID == navigationID,
                      webView === self.loginWebView,
                      webView.url == current,
                      let body = result as? String else { return }
                if body.contains("不符合目标服务") || body.contains("INVALID_SERVICE") {
                    self.casTicketErrorDetected = true
                    self.nativeCASFormReady = false
                    self.casProbeToken = UUID()
                    self.captchaRefreshToken = nil
                    self.casLoginPanel.isHidden = true
                    webView.isHidden = false
                    self.statusLabel.stringValue = "CAS 服务票据校验失败。请确认通过信息门户的 AI 应用中台进入；复制脱敏跳转轨迹可帮助定位具体一跳。"
                }
            }
        }

        let agentID = agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let step = CampusAIEntryNavigation.step(for: current, agentID: agentID) {
            startAutomaticNavigation(step, in: webView, at: current)
            return
        }

        guard host == CampusAIEndpoint.host else { return }
        guard current.path == "/agent-detail" else {
            if current.path == "/index" {
                statusLabel.stringValue = agentID == CampusAIEndpoint.defaultAgentID
                    ? "已到达 AI 应用广场，请手动打开合工大 AI 辅导员。"
                    : "已到达 AI 应用广场；当前智能体 ID 不是默认辅导员，请手动选择目标智能体。"
            }
            return
        }
        guard let agent = URLComponents(url: current, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value,
              CampusAIEndpoint.validID(agent) else {
            statusLabel.stringValue = "智能体页面缺少有效 ID，无法自动准备会话。"
            return
        }
        if agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != agent {
            cancelGroupLookup()
            emptyHistoryAgentID = nil
            emptyHistoryNavigationID = nil
            groupField.stringValue = ""
        }
        agentField.stringValue = agent
        let navigationID = portalNavigationID
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.displayingLogin,
                      self.portalNavigationID == navigationID,
                      webView === self.loginWebView else { return }
                if self.hasAISession(cookies) {
                    self.displayChat(status: "已到达目标智能体页面，正在自动准备最近会话…")
                    let agentID = self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.prepareRecentGroupIfNeeded(
                        agentID: agentID, allCookies: cookies,
                        referer: self.aiRefererURL(for: agentID), navigationID: navigationID
                    )
                } else {
                    self.statusLabel.stringValue = "目标智能体页面已打开，但尚未发现 AI 会话 Cookie。请完成页面内登录后点击「返回聊天」。"
                }
            }
        }
    }

    private func captureSharedCASTGC() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            guard let tgc = HFUTCASLoginSupport.tgcCookieValue(from: cookies) else { return }
            SettingsManager.shared.casTgcCookie = tgc
        }
    }

    private func startAutomaticNavigation(_ step: CampusAIEntryNavigationStep, in webView: WKWebView, at url: URL) {
        let navigationID = portalNavigationID
        let key = "\(navigationID.uuidString):\(step.rawValue):\(url.host?.lowercased() ?? ""):\(url.path)"
        guard automaticNavigationAttempts.insert(key).inserted else { return }

        switch step {
        case .clickPortalAIPlatform:
            statusLabel.stringValue = "正在查找门户中的 AI中台入口…"
        case .clickAIPlaza:
            statusLabel.stringValue = "正在进入 AI 应用广场…"
        case .clickCampusAdvisor:
            statusLabel.stringValue = "正在查找合工大 AI 辅导员…"
        }

        webView.evaluateJavaScript(CampusAIEntryNavigation.script(
            for: step,
            agentID: agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )) { [weak self] result, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.displayingLogin,
                      self.portalNavigationID == navigationID,
                      self.portalWebViews.contains(where: { $0 === webView }) else { return }
                if result as? Bool != true {
                    self.statusLabel.stringValue = "自动入口脚本未能启动；可在信息门户页面手动继续。"
                }
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        recordNavigation("failure", url: webView.url)
        guard webView === loginWebView else { return }
        statusLabel.stringValue = "学校页面加载失败。可复制脱敏跳转轨迹用于排查。"
    }

    public func webViewDidClose(_ webView: WKWebView) {
        let wasActive = webView === loginWebView
        portalWebViews.removeAll { $0 === webView }
        webView.removeFromSuperview()
        if wasActive, let fallback = portalWebViews.last {
            loginWebView = fallback
            fallback.isHidden = false
        }
    }

    public func windowWillClose(_ notification: Notification) {
        if sending {
            if let client = activeClient {
                client.cancel()
            } else {
                complete("窗口已关闭，已取消请求。")
            }
        }
    }
}
