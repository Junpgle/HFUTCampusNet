import Foundation
import AppKit
import WebKit

// Thinking and final answer chunks are rendered in separate transcript sections.
// Raw tool payloads and metadata values remain outside the UI.
private final class CampusAIStreamClient: NSObject, URLSessionDataDelegate {
    enum Event {
        case thinkingStarted
        case thinking(String)
        case thinkingEnded
        case text(String)
        case toolCallStarted
        case toolCallResult(success: Bool)
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
    private var activeTraceID: String?
    private var abortCookies: [HTTPCookie] = []
    private var abortAiFlow: String?
    private var abortReferer: URL?

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func start(question: String, groupID: String, modelID: String,
               thinkingMode: CampusAIThinkingMode,
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
        activeTraceID = traceID
        abortCookies = CampusAIEndpoint.cookies(from: cookies, requestPath: CampusAIEndpoint.chatAbortPath)
        abortAiFlow = aiFlow
        abortReferer = referer
        req.httpBody = CampusAIRequestBuilder.chatBody(
            text: question, groupID: groupID, modelID: modelID,
            thinkingMode: thinkingMode, traceID: traceID
        )
        task = session.dataTask(with: req)
        task?.resume()
    }

    func cancel() {
        if !completed, let traceID = activeTraceID,
           let aiFlow = abortAiFlow {
            sendAbort(traceID: traceID, cookies: abortCookies, aiFlow: aiFlow, referer: abortReferer)
        }
        task?.cancel()
        finish("已取消")
    }

    private func sendAbort(traceID: String, cookies: [HTTPCookie], aiFlow: String, referer: URL?) {
        guard let body = CampusAIRequestBuilder.chatAbortBody(traceID: traceID) else { return }
        var request = URLRequest(url: CampusAIEndpoint.api.appendingPathComponent("chat/abort"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(aiFlow, forHTTPHeaderField: "aiflow")
        if let referer = referer, referer.host?.lowercased() == CampusAIEndpoint.host {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookie = CampusAIEndpoint.cookieHeader(from: cookies) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let abortSession = URLSession(configuration: configuration,
                                      delegate: CampusAIAuthenticatedRedirectDelegate.shared,
                                      delegateQueue: nil)
        let abortTask = abortSession.dataTask(with: request) { _, _, _ in
            abortSession.finishTasksAndInvalidate()
        }
        abortTask.resume()
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

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(CampusAIAuthenticatedRedirectDelegate.permitsRedirect(to: request.url) ? request : nil)
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
            case .thinkingStarted:
                onEvent(.thinkingStarted)
            case .thinking(let chunk):
                onEvent(.thinking(chunk))
            case .thinkingEnded:
                onEvent(.thinkingEnded)
            case .text(let chunk):
                onEvent(.text(chunk))
            case .toolCallStarted:
                onEvent(.toolCallStarted)
                onEvent(.status("正在调用学校智能体工具…"))
            case .toolCallResult(let success):
                onEvent(.toolCallResult(success: success))
                if success {
                    onEvent(.status("工具执行完成，正在生成回复…"))
                } else {
                    onEvent(.status("智能体工具未能完成。"))
                }
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
    let sendRequestID: UUID
    let question: String
    let agentID: String
    let modelID: String
    let thinkingMode: CampusAIThinkingMode
    let attachments: [CampusAIAttachmentDraft]
    let allCookies: [HTTPCookie]
    let cookies: [HTTPCookie]
    let saveCookies: [HTTPCookie]
    let aiFlow: String
    let referer: URL?
    let navigationID: UUID
}

private struct CampusAIPendingCASCredentials {
    let username: String
    let password: String?
    let previousUsername: String
    let previousStudentID: String
    let navigationID: UUID
}

public final class CampusAIAssistantWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate, NSPopoverDelegate {
    public static let shared = CampusAIAssistantWindowController()

    private let defaults = UserDefaults.standard
    private let agentField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let groupField = NSTextField(string: "")
    private let promptField = NSTextField(string: "")
    private let attachmentButton = NSButton(title: "添加文件", target: nil, action: nil)
    private let clearAttachmentsButton = NSButton(title: "清除", target: nil, action: nil)
    private let attachmentSummaryLabel = NSTextField(labelWithString: "未添加附件")
    private let thinkingModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let transcriptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "正在检查学校 AI 登录状态…")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let historyButton = NSButton(title: "历史会话", target: nil, action: nil)
    private let newSessionButton = NSButton(title: "新建会话", target: nil, action: nil)
    private let loginButton = NSButton(title: "信息门户", target: nil, action: nil)
    private let backButton = NSButton(title: "返回聊天", target: nil, action: nil)
    private let transcriptScroll = NSScrollView()
    private let scriptController = WKUserContentController()
    private let casLoginPanel = HFUTCASLoginPanel(frame: NSRect(x: 20, y: 128, width: 940, height: 458))
    private var chatOnlyViews: [NSView] = []
    private var captchaMessageProxy: CampusAIWeakScriptMessageHandler!
    private var loginWebView: WKWebView!
    private var portalWebViews: [WKWebView] = []
    private var activeClient: CampusAIStreamClient?
    private var activeAttachmentClient: CampusAIAttachmentClient?
    private var selectedAttachments: [CampusAIAttachmentDraft] = []
    private var activeLookupTask: URLSessionDataTask?
    private var activeLookupSession: URLSession?
    private var activeLookupID: UUID?
    private var historyPopover: NSPopover?
    private var historyPopoverController: CampusAIHistoryPopoverViewController?
    private var historyListTask: URLSessionDataTask?
    private var historyListSession: URLSession?
    private var historyListRequestID: UUID?
    private var historyDeleteTask: URLSessionDataTask?
    private var historyDeleteSession: URLSession?
    private var historyDeleteRequestID: UUID?
    private var pendingLookupSend: CampusAIPendingLookupSend?
    private var pendingCASCredentials: CampusAIPendingCASCredentials?
    private var activeSendRequestID: UUID?
    private var emptyHistoryAgentID: String?
    private var emptyHistoryNavigationID: UUID?
    private var sending = false
    private var activeThinkingMarkdown = ""
    private var activeThinkingStart: Int?
    private var activeAssistantMarkdown = ""
    private var activeAssistantStart: Int?
    private var hasStartedFinalAnswer = false
    private var displayingLogin = false
    private var nativeCASFormReady = false
    private var preferWebLoginForCurrentCASPage = false
    private var casTicketErrorDetected = false
    private var casProbeToken = UUID()
    private var captchaRefreshToken: UUID?
    private var automaticNavigationAttempts = Set<String>()
    // 完整 SSO 跳转由信息门户及其注册应用发起；本客户端不构造 ST/service。
    private var portalNavigationID = UUID()
    private var assistantViewRequestID = UUID()
    private var portalSessionUsername = ""

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

        historyButton.frame = NSRect(x: 380, y: 650, width: 104, height: 30)
        historyButton.autoresizingMask = [.minXMargin, .minYMargin]
        historyButton.target = self
        historyButton.action = #selector(showHistoryPopover)
        root.addSubview(historyButton)
        chatOnlyViews.append(historyButton)

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

        attachmentButton.frame = NSRect(x: 20, y: 72, width: 88, height: 32)
        attachmentButton.bezelStyle = .rounded
        attachmentButton.target = self
        attachmentButton.action = #selector(chooseAttachments)
        root.addSubview(attachmentButton)
        chatOnlyViews.append(attachmentButton)

        attachmentSummaryLabel.frame = NSRect(x: 20, y: 45, width: 830, height: 18)
        attachmentSummaryLabel.font = .systemFont(ofSize: 11)
        attachmentSummaryLabel.textColor = .secondaryLabelColor
        attachmentSummaryLabel.lineBreakMode = .byTruncatingMiddle
        attachmentSummaryLabel.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(attachmentSummaryLabel)
        chatOnlyViews.append(attachmentSummaryLabel)

        clearAttachmentsButton.frame = NSRect(x: 870, y: 42, width: 72, height: 24)
        clearAttachmentsButton.bezelStyle = .rounded
        clearAttachmentsButton.controlSize = .small
        clearAttachmentsButton.target = self
        clearAttachmentsButton.action = #selector(clearAttachments)
        clearAttachmentsButton.isEnabled = false
        clearAttachmentsButton.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(clearAttachmentsButton)
        chatOnlyViews.append(clearAttachmentsButton)

        promptField.frame = NSRect(x: 116, y: 72, width: 592, height: 32)
        promptField.placeholderString = "输入你想咨询的问题，例如：请查询我本人的课程成绩"
        promptField.font = .systemFont(ofSize: 13)
        promptField.autoresizingMask = [.width, .maxYMargin]
        promptField.target = self
        promptField.action = #selector(sendMessageFromKeyboard)
        root.addSubview(promptField)
        chatOnlyViews.append(promptField)

        for mode in CampusAIThinkingMode.allCases {
            thinkingModePopup.addItem(withTitle: mode.title)
        }
        thinkingModePopup.frame = NSRect(x: 718, y: 72, width: 123, height: 32)
        thinkingModePopup.autoresizingMask = [.minXMargin, .maxYMargin]
        thinkingModePopup.target = self
        thinkingModePopup.action = #selector(thinkingModeChanged)
        thinkingModePopup.selectItem(withTitle: selectedThinkingMode().title)
        root.addSubview(thinkingModePopup)
        chatOnlyViews.append(thinkingModePopup)

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
        let requestID = UUID()
        assistantViewRequestID = requestID
        let navigationID = portalNavigationID
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.assistantViewRequestID == requestID,
                      self.portalNavigationID == navigationID else { return }
                if self.hasAISession(cookies) {
                    self.displayChat(status: "检测到 AI 平台会话，正在自动准备最近会话…")
                    let agentID = self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.prepareRecentGroupIfNeeded(
                        agentID: agentID, allCookies: cookies,
                        referer: self.aiRefererURL(for: agentID),
                        navigationID: navigationID
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
        assistantViewRequestID = UUID()
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
        assistantViewRequestID = UUID()
        closeHistoryPopover()
        if sending {
            activeClient?.cancel()
            if sending { complete("已取消") }
        }
        cancelGroupLookup()
        emptyHistoryAgentID = nil
        emptyHistoryNavigationID = nil
        groupField.stringValue = ""
        portalNavigationID = UUID()
        pendingCASCredentials = nil
        portalSessionUsername = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        automaticNavigationAttempts.removeAll(keepingCapacity: true)
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
        let requestID = UUID()
        assistantViewRequestID = requestID
        let navigationID = portalNavigationID
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.assistantViewRequestID == requestID,
                      self.portalNavigationID == navigationID else { return }
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
        pendingCASCredentials = nil
        nativeCASFormReady = false
        casProbeToken = UUID()
        captchaRefreshToken = nil
        casLoginPanel.setSubmitting(false)
        casLoginPanel.isHidden = true
        loginWebView.isHidden = false
        statusLabel.stringValue = message
    }

    @objc private func showCASWebLogin() {
        pendingCASCredentials = nil
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

        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else {
            casLoginPanel.setStatus("学号不能为空，请填写后重试。")
            return
        }
        let previousUsername = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard portalSessionUsername == previousUsername else {
            casLoginPanel.setStatus("账号设置已变化，请重新打开信息门户登录流程后重试。")
            return
        }
        let navigationID = portalNavigationID
        pendingCASCredentials = CampusAIPendingCASCredentials(
            username: normalizedUsername,
            password: password,
            previousUsername: previousUsername,
            previousStudentID: SettingsManager.shared.courseStudentId,
            navigationID: navigationID
        )
        portalSessionUsername = normalizedUsername
        nativeCASFormReady = false
        preferWebLoginForCurrentCASPage = false
        casProbeToken = UUID()
        casLoginPanel.setSubmitting(true)
        casLoginPanel.setStatus("正在提交到学校 CAS 页面并等待门户回跳…")
        casLoginPanel.isHidden = true
        loginWebView.isHidden = false
        loginWebView.evaluateJavaScript(script) { [weak self] result, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.displayingLogin,
                      self.portalNavigationID == navigationID,
                      self.pendingCASCredentials?.navigationID == navigationID,
                      self.pendingCASCredentials?.username == normalizedUsername else { return }
                if result as? Bool == true {
                    self.statusLabel.stringValue = "已通过 CAS 页面提交登录，正在等待学校认证结果…"
                } else if HFUTCASLoginSupport.isLoginPage(self.loginWebView.url) {
                    self.pendingCASCredentials = nil
                    self.portalSessionUsername = previousUsername
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
              let event = body["event"] else { return }
        if event == "loginSubmitting" {
            stageWebCASLoginUsername(body["username"] ?? "")
            return
        }
        guard ["formChanged", "captchaChanged"].contains(event) else { return }
        if event == "captchaChanged" {
            captchaRefreshToken = nil
        }
        inspectCASLoginPage(webView)
    }

    private func stageWebCASLoginUsername(_ username: String) {
        guard pendingCASCredentials == nil,
              HFUTCASLoginSupport.isLoginPage(loginWebView.url) else { return }
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousUsername = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty,
              normalizedUsername != previousUsername,
              portalSessionUsername == previousUsername else { return }

        pendingCASCredentials = CampusAIPendingCASCredentials(
            username: normalizedUsername,
            password: nil,
            previousUsername: previousUsername,
            previousStudentID: SettingsManager.shared.courseStudentId,
            navigationID: portalNavigationID
        )
        portalSessionUsername = normalizedUsername
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
            } else if let client = activeAttachmentClient {
                activeAttachmentClient = nil
                client.cancel()
                complete("已取消")
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
        let typedQuestion = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = selectedAttachments
        guard !typedQuestion.isEmpty || !attachments.isEmpty else { return }
        let question = typedQuestion.isEmpty ? "请阅读并分析我上传的文件。" : typedQuestion
        let agentID = agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CampusAIEndpoint.validID(agentID), CampusAIEndpoint.validID(modelID),
              (groupID.isEmpty || CampusAIEndpoint.validID(groupID)) else {
            statusLabel.stringValue = "智能体、模型或会话 ID 格式不正确。"
            return
        }

        assistantViewRequestID = UUID()
        defaults.set(agentID, forKey: "campus_ai_agent_id")
        defaults.set(modelID, forKey: "campus_ai_model_id")
        let sendRequestID = UUID()
        activeSendRequestID = sendRequestID
        let thinkingMode = selectedThinkingMode()
        activeThinkingMarkdown = ""
        activeThinkingStart = nil
        activeAssistantMarkdown = ""
        activeAssistantStart = nil
        hasStartedFinalAnswer = false
        sending = true
        sendButton.title = "停止"
        promptField.isEnabled = false
        attachmentButton.isEnabled = false
        clearAttachmentsButton.isEnabled = false
        thinkingModePopup.isEnabled = false
        historyButton.isEnabled = false
        let attachmentNames = attachments.map(\.originalFileName).joined(separator: "、")
        let userBlock = CampusAITranscriptStyle.userBlock(question: question, attachments: attachmentNames)
        transcriptView.textStorage?.append(userBlock)
        transcriptView.scrollToEndOfDocument(nil)
        statusLabel.stringValue = "检查当前学校 AI 登录会话…"

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] all in
            DispatchQueue.main.async {
                guard let self = self, self.sending,
                      self.activeSendRequestID == sendRequestID else { return }
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
                    let pending = CampusAIPendingLookupSend(
                        sendRequestID: sendRequestID,
                        question: question, agentID: agentID, modelID: modelID,
                        thinkingMode: thinkingMode, attachments: attachments,
                        allCookies: all,
                        cookies: cookies, saveCookies: saveCookies, aiFlow: aiFlow,
                        referer: referer, navigationID: self.portalNavigationID
                    )
                    if attachments.isEmpty {
                        self.startStreaming(sendRequestID: sendRequestID,
                                            question: question, groupID: currentGroupID,
                                            modelID: modelID, thinkingMode: thinkingMode,
                                            cookies: cookies, aiFlow: aiFlow,
                                            referer: referer)
                    } else {
                        self.prepareAttachmentsAndSend(pending, existingGroupID: currentGroupID)
                    }
                } else {
                    let referer = self.aiRefererURL(for: agentID)
                    self.pendingLookupSend = CampusAIPendingLookupSend(
                        sendRequestID: sendRequestID,
                        question: question, agentID: agentID, modelID: modelID,
                        thinkingMode: thinkingMode, attachments: attachments,
                        allCookies: all,
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
        closeHistoryPopover()
        let agentID = agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CampusAIEndpoint.validID(agentID) else {
            statusLabel.stringValue = "智能体 ID 格式不正确，无法准备新会话。"
            return
        }

        assistantViewRequestID = UUID()
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
        activeThinkingMarkdown = ""
        activeThinkingStart = nil
        activeAssistantMarkdown = ""
        activeAssistantStart = nil
        hasStartedFinalAnswer = false
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

    @objc private func chooseAttachments() {
        guard !sending, let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加到对话"
        panel.message = "选择要上传并由 AI 阅读的文件（单个文件最大 100 MB）。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self else { return }
            let urls = panel.urls
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let uidBase = Int64(Date().timeIntervalSince1970 * 1000)
                    var loaded: [CampusAIAttachmentDraft] = []
                    for (index, url) in urls.enumerated() {
                        let hasScope = url.startAccessingSecurityScopedResource()
                        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey])
                        guard let fileSize = values.fileSize, fileSize > 0,
                              fileSize <= CampusAIAttachmentProtocol.maximumFileSize else {
                            throw CampusAIAttachmentClient.Failure.invalidFile
                        }
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard data.count == fileSize else { throw CampusAIAttachmentClient.Failure.invalidFile }
                        loaded.append(CampusAIAttachmentDraft(
                            originalFileName: url.lastPathComponent,
                            data: data,
                            uid: uidBase + Int64(index)
                        ))
                    }
                    DispatchQueue.main.async {
                        self.selectedAttachments.append(contentsOf: loaded)
                        self.updateAttachmentSummary()
                        self.statusLabel.stringValue = "已添加 \(loaded.count) 个附件；发送时会先上传并提取文本。"
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.statusLabel.stringValue = "读取所选附件失败；请确认文件可访问且小于 100 MB。"
                    }
                }
            }
        }
    }

    @objc private func clearAttachments() {
        guard !sending else { return }
        selectedAttachments.removeAll()
        updateAttachmentSummary()
    }

    private func updateAttachmentSummary() {
        guard !selectedAttachments.isEmpty else {
            attachmentSummaryLabel.stringValue = "未添加附件"
            clearAttachmentsButton.isEnabled = false
            return
        }
        let names = selectedAttachments.map(\.originalFileName).joined(separator: "、")
        attachmentSummaryLabel.stringValue = "已添加 \(selectedAttachments.count) 个文件：\(names)"
        clearAttachmentsButton.isEnabled = !sending
    }

    @objc private func showHistoryPopover() {
        guard !sending else { return }
        if historyPopover?.isShown == true {
            historyPopover?.performClose(nil)
            return
        }

        let controller = CampusAIHistoryPopoverViewController()
        controller.onPageRequested = { [weak self] pageNumber in
            self?.loadHistoryPage(pageNumber)
        }
        controller.onRefreshRequested = { [weak self] in
            self?.loadHistoryPage(1)
        }
        controller.onDeleteRequested = { [weak self] entry in
            self?.confirmDeleteHistory(entry)
        }
        controller.onCloseRequested = { [weak self] in
            self?.historyPopover?.performClose(nil)
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 560, height: 450)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        historyPopoverController = controller
        historyPopover = popover
        popover.show(relativeTo: historyButton.bounds, of: historyButton, preferredEdge: .minY)
        loadHistoryPage(1)
    }

    private func loadHistoryPage(_ requestedPageNumber: Int) {
        let agentID = agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CampusAIEndpoint.validID(agentID), requestedPageNumber > 0 else {
            showHistoryError("智能体 ID 无效，无法获取历史会话。")
            return
        }
        let navigationID = portalNavigationID
        historyPopoverController?.beginLoading(pageNumber: requestedPageNumber)
        cancelHistoryListRequest()
        let requestID = UUID()
        historyListRequestID = requestID

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] allCookies in
            DispatchQueue.main.async {
                guard let self = self, self.historyListRequestID == requestID,
                      self.portalNavigationID == navigationID,
                      self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == agentID else { return }

                let requestCookies = CampusAIEndpoint.cookies(from: allCookies, requestPath: CampusAIEndpoint.historyPath)
                guard let aiFlow = CampusAIEndpoint.aiFlowCookie(from: requestCookies)?.value,
                      let body = CampusAIRequestBuilder.historyBody(agentID: agentID, pageNumber: requestedPageNumber) else {
                    self.historyListRequestID = nil
                    self.showHistoryError("请先从信息门户进入合工大 AI 辅导员，再获取历史会话。")
                    return
                }

                var request = URLRequest(url: CampusAIEndpoint.api.appendingPathComponent("agent/getHistoryData"))
                request.httpMethod = "POST"
                request.httpShouldHandleCookies = false
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
                request.setValue(aiFlow, forHTTPHeaderField: "aiflow")
                if let referer = self.aiRefererURL(for: agentID) {
                    request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                }
                if let cookie = CampusAIEndpoint.cookieHeader(from: requestCookies) {
                    request.setValue(cookie, forHTTPHeaderField: "Cookie")
                }
                request.httpBody = body

                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieAcceptPolicy = .never
                configuration.httpShouldSetCookies = false
                configuration.timeoutIntervalForRequest = 30
                let session = URLSession(configuration: configuration,
                                         delegate: CampusAIAuthenticatedRedirectDelegate.shared,
                                         delegateQueue: nil)
                let task = session.dataTask(with: request) { [weak self] data, response, error in
                    let http = response as? HTTPURLResponse
                    let successful = (200...299).contains(http?.statusCode ?? 0)
                    let page = successful
                        ? data.flatMap { CampusAIHistoryResponse.page(from: $0, expectedAgentID: agentID,
                                                                       requestedPageNumber: requestedPageNumber) }
                        : nil
                    let message: String?
                    if http?.statusCode == 401 || http?.statusCode == 403 {
                        message = "AI 平台会话无效或已过期，请重新从信息门户进入。"
                    } else if error != nil {
                        message = "获取历史会话时网络连接失败，请检查网络后重试。"
                    } else if !successful {
                        message = "平台获取历史会话失败（HTTP \(http?.statusCode ?? 0)）。"
                    } else if page == nil {
                        message = "平台历史会话响应无法识别。"
                    } else {
                        message = nil
                    }
                    session.finishTasksAndInvalidate()
                    DispatchQueue.main.async {
                        guard let self = self, self.historyListRequestID == requestID,
                              self.portalNavigationID == navigationID,
                              self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == agentID else { return }
                        self.historyListRequestID = nil
                        self.historyListTask = nil
                        self.historyListSession = nil
                        if let message = message {
                            self.showHistoryError(message)
                            return
                        }
                        guard let page = page else {
                            self.showHistoryError("平台历史会话响应无法识别。")
                            return
                        }

                        self.historyPopoverController?.show(page: page)
                    }
                }
                self.historyListSession = session
                self.historyListTask = task
                task.resume()
            }
        }
    }

    private func confirmDeleteHistory(_ entry: CampusAIHistoryEntry) {
        guard CampusAIEndpoint.validID(entry.id), let window = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这条历史会话？"
        alert.informativeText = "该记录将从 AI 平台删除，此操作无法撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deleteHistory(entryID: entry.id)
        }
    }

    private func deleteHistory(entryID: String) {
        let agentID = agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CampusAIEndpoint.validID(entryID), CampusAIEndpoint.validID(agentID),
              let path = CampusAIEndpoint.historyDeletePath(sessionID: entryID),
              let url = URL(string: "https://\(CampusAIEndpoint.host)\(path)") else {
            showHistoryError("历史会话 ID 无效，无法删除。")
            return
        }
        let navigationID = portalNavigationID
        historyPopoverController?.beginDeleting()
        cancelHistoryDeleteRequest()
        let requestID = UUID()
        historyDeleteRequestID = requestID

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] allCookies in
            DispatchQueue.main.async {
                guard let self = self, self.historyDeleteRequestID == requestID,
                      self.portalNavigationID == navigationID,
                      self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == agentID else { return }
                let requestCookies = CampusAIEndpoint.cookies(from: allCookies, requestPath: path)
                guard let aiFlow = CampusAIEndpoint.aiFlowCookie(from: requestCookies)?.value else {
                    self.historyDeleteRequestID = nil
                    self.showHistoryError("AI 平台会话无效或已过期，请重新从信息门户进入。")
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpShouldHandleCookies = false
                request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
                request.setValue(aiFlow, forHTTPHeaderField: "aiflow")
                if let referer = self.aiRefererURL(for: agentID) {
                    request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                }
                if let cookie = CampusAIEndpoint.cookieHeader(from: requestCookies) {
                    request.setValue(cookie, forHTTPHeaderField: "Cookie")
                }

                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieAcceptPolicy = .never
                configuration.httpShouldSetCookies = false
                configuration.timeoutIntervalForRequest = 30
                let session = URLSession(configuration: configuration,
                                         delegate: CampusAIAuthenticatedRedirectDelegate.shared,
                                         delegateQueue: nil)
                let task = session.dataTask(with: request) { [weak self] data, response, error in
                    let http = response as? HTTPURLResponse
                    let successfulHTTP = (200...299).contains(http?.statusCode ?? 0)
                    let deleted = successfulHTTP && (data.map { CampusAIHistoryDeleteResponse.deleted(from: $0) } ?? false)
                    let message: String?
                    if http?.statusCode == 401 || http?.statusCode == 403 {
                        message = "AI 平台会话无效或已过期，请重新从信息门户进入。"
                    } else if error != nil {
                        message = "删除历史会话时网络连接失败，请检查网络后重试。"
                    } else if !successfulHTTP {
                        message = "平台删除历史会话失败（HTTP \(http?.statusCode ?? 0)）。"
                    } else if !deleted {
                        message = "平台未确认删除成功，历史列表未刷新。"
                    } else {
                        message = nil
                    }
                    session.finishTasksAndInvalidate()
                    DispatchQueue.main.async {
                        guard let self = self, self.historyDeleteRequestID == requestID,
                              self.portalNavigationID == navigationID,
                              self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == agentID else { return }
                        self.historyDeleteRequestID = nil
                        self.historyDeleteTask = nil
                        self.historyDeleteSession = nil
                        if let message = message {
                            self.showHistoryError(message)
                            return
                        }
                        let deletedCurrentSession = self.groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == entryID
                        if deletedCurrentSession {
                            self.groupField.stringValue = ""
                            self.emptyHistoryAgentID = nil
                            self.emptyHistoryNavigationID = nil
                            self.activeThinkingMarkdown = ""
                            self.activeThinkingStart = nil
                            self.activeAssistantMarkdown = ""
                            self.activeAssistantStart = nil
                            self.hasStartedFinalAnswer = false
                            self.transcriptView.textStorage?.setAttributedString(CampusAITranscriptStyle.attributedString(
                                "当前会话已删除。\n\n",
                                font: self.transcriptView.font ?? .systemFont(ofSize: 13)
                            ))
                        }
                        self.loadHistoryPage(1)
                    }
                }
                self.historyDeleteSession = session
                self.historyDeleteTask = task
                task.resume()
            }
        }
    }

    private func showHistoryError(_ message: String) {
        historyPopoverController?.showError(message)
        statusLabel.stringValue = message
    }

    private func cancelHistoryListRequest() {
        historyListRequestID = nil
        historyListTask?.cancel()
        historyListTask = nil
        historyListSession?.invalidateAndCancel()
        historyListSession = nil
    }

    private func cancelHistoryDeleteRequest() {
        historyDeleteRequestID = nil
        historyDeleteTask?.cancel()
        historyDeleteTask = nil
        historyDeleteSession?.invalidateAndCancel()
        historyDeleteSession = nil
    }

    private func closeHistoryPopover() {
        let popover = historyPopover
        historyPopover = nil
        historyPopoverController = nil
        popover?.performClose(nil)
        cancelHistoryListRequest()
    }

    public func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === historyPopover else { return }
        historyPopover = nil
        historyPopoverController = nil
        cancelHistoryListRequest()
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
        let session = URLSession(configuration: configuration,
                                 delegate: CampusAIAuthenticatedRedirectDelegate.shared,
                                 delegateQueue: nil)
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
                        if pending.attachments.isEmpty {
                            self.startStreaming(sendRequestID: pending.sendRequestID,
                                                question: pending.question, groupID: selectedGroupID,
                                                modelID: pending.modelID, thinkingMode: pending.thinkingMode,
                                                cookies: pending.cookies,
                                                aiFlow: pending.aiFlow, referer: pending.referer)
                        } else {
                            self.prepareAttachmentsAndSend(pending, existingGroupID: selectedGroupID)
                        }
                    } else {
                        self.statusLabel.stringValue = "会话已自动准备，可以直接发送。"
                    }
                case .empty:
                    self.emptyHistoryAgentID = agentID
                    self.emptyHistoryNavigationID = navigationID
                    if let pending = self.pendingLookupSend {
                        if pending.attachments.isEmpty {
                            self.createSessionAndSend(pending)
                        } else {
                            self.pendingLookupSend = nil
                            self.prepareAttachmentsAndSend(pending, existingGroupID: nil)
                        }
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
        guard sending, activeSendRequestID == pending.sendRequestID,
              pendingLookupSend?.sendRequestID == pending.sendRequestID,
              pendingLookupSend?.navigationID == pending.navigationID,
              pending.navigationID == portalNavigationID,
              pending.agentID == agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
            complete("智能体页面已变化，未创建会话；请重新发送。")
            return
        }
        guard activeLookupTask == nil else { return }
        if !pending.attachments.isEmpty {
            pendingLookupSend = nil
            prepareAttachmentsAndSend(pending, existingGroupID: nil)
            return
        }
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
        let session = URLSession(configuration: configuration,
                                 delegate: CampusAIAuthenticatedRedirectDelegate.shared,
                                 delegateQueue: nil)
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
                      self.activeSendRequestID == pending.sendRequestID,
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
                self.startStreaming(sendRequestID: pending.sendRequestID,
                                    question: pending.question, groupID: groupID,
                                    modelID: pending.modelID, thinkingMode: pending.thinkingMode,
                                    cookies: pending.cookies,
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

    private func prepareAttachmentsAndSend(_ pending: CampusAIPendingLookupSend, existingGroupID: String?) {
        guard sending, activeSendRequestID == pending.sendRequestID,
              pending.navigationID == portalNavigationID,
              pending.agentID == agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !pending.attachments.isEmpty else {
            complete("智能体页面已变化，附件未发送；请重新发送。")
            return
        }
        statusLabel.stringValue = "正在准备附件…"
        let client = CampusAIAttachmentClient(
            files: pending.attachments,
            question: pending.question,
            agentID: pending.agentID,
            existingGroupID: existingGroupID,
            cookies: pending.allCookies,
            referer: pending.referer,
            onProgress: { [weak self] message in
                guard let self = self, self.sending,
                      self.activeSendRequestID == pending.sendRequestID,
                      self.portalNavigationID == pending.navigationID else { return }
                self.statusLabel.stringValue = message
            },
            completion: { [weak self] result in
                guard let self = self, self.sending,
                      self.activeSendRequestID == pending.sendRequestID,
                      self.portalNavigationID == pending.navigationID,
                      self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == pending.agentID else { return }
                self.activeAttachmentClient = nil
                switch result {
                case .success(let (identifiers, messageText)):
                    self.groupField.stringValue = identifiers.groupID
                    self.statusLabel.stringValue = "附件已登记，正在发送问题…"
                    self.startStreaming(
                        sendRequestID: pending.sendRequestID,
                        question: messageText,
                        groupID: identifiers.groupID,
                        modelID: pending.modelID,
                        thinkingMode: pending.thinkingMode,
                        cookies: pending.cookies,
                        aiFlow: pending.aiFlow,
                        referer: pending.referer
                    )
                case .failure(let failure):
                    let message: String
                    switch failure {
                    case .invalidFile:
                        message = "附件为空、过大或无法读取。请检查文件后重试。"
                    case .platformRejected:
                        message = "AI 平台会话无效或已过期，请重新从信息门户进入。"
                    case .network:
                        message = "附件上传或登记失败，请检查网络后重试。"
                    case .invalidResponse(let stage):
                        message = stage.userMessage
                    case .cancelled:
                        message = "已取消附件发送。"
                    }
                    self.complete(message)
                }
            }
        )
        activeAttachmentClient = client
        client.start()
    }

    private func aiRefererURL(for agentID: String) -> URL? {
        CampusAIEndpoint.referer(from: loginWebView.url, agentID: agentID)
            ?? CampusAIEndpoint.agentReferer(agentID: agentID)
    }

    private func startStreaming(sendRequestID: UUID, question: String, groupID: String, modelID: String,
                                thinkingMode: CampusAIThinkingMode,
                                cookies: [HTTPCookie], aiFlow: String, referer: URL?) {
        statusLabel.stringValue = "已连接，等待智能体回复…"
        let client = CampusAIStreamClient { [weak self] event in
            guard let self = self,
                  self.activeSendRequestID == sendRequestID else { return }
            switch event {
            case .thinkingStarted:
                self.beginThinkingSection()
            case .thinking(let chunk):
                self.appendThinkingMarkdown(chunk)
            case .thinkingEnded:
                self.finishThinkingSection()
            case .text(let chunk):
                self.appendAssistantMarkdown(chunk)
            case .toolCallStarted:
                self.appendToolCallBlock(result: nil)
            case .toolCallResult(let success):
                self.appendToolCallBlock(result: success)
            case .status(let message):
                self.statusLabel.stringValue = message
            case .finished(let error):
                self.complete(error)
            }
        }
        activeClient = client
        activeThinkingMarkdown = ""
        activeThinkingStart = nil
        activeAssistantMarkdown = ""
        activeAssistantStart = nil
        hasStartedFinalAnswer = false
        client.start(question: question, groupID: groupID, modelID: modelID,
                     thinkingMode: thinkingMode, cookies: cookies, aiFlow: aiFlow, referer: referer)
    }

    private func beginThinkingSection() {
        guard activeThinkingStart == nil else { return }
        finishAssistantSection()
        transcriptView.textStorage?.append(CampusAITranscriptStyle.thinkingHeader())
        activeThinkingMarkdown = ""
        activeThinkingStart = transcriptView.textStorage?.length
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func appendThinkingMarkdown(_ chunk: String) {
        if activeThinkingStart == nil { beginThinkingSection() }
        activeThinkingMarkdown += chunk
        renderMarkdown(activeThinkingMarkdown, startingAt: activeThinkingStart, isThinking: true)
    }

    private func finishThinkingSection() {
        guard activeThinkingStart != nil else { return }
        renderMarkdown(activeThinkingMarkdown, startingAt: activeThinkingStart, isThinking: true)
        activeThinkingStart = nil
        activeThinkingMarkdown = ""
        transcriptView.textStorage?.append(CampusAITranscriptStyle.thinkingFooter())
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func beginFinalAnswerSection() {
        finishThinkingSection()
        guard !hasStartedFinalAnswer else { return }
        transcriptView.textStorage?.append(CampusAITranscriptStyle.assistantHeader())
        activeAssistantStart = transcriptView.textStorage?.length
        activeAssistantMarkdown = ""
        hasStartedFinalAnswer = true
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func appendAssistantMarkdown(_ chunk: String) {
        beginFinalAnswerSection()
        activeAssistantMarkdown += chunk
        renderMarkdown(activeAssistantMarkdown, startingAt: activeAssistantStart, isThinking: false)
    }

    private func finishAssistantSection() {
        guard activeAssistantStart != nil else { return }
        renderMarkdown(activeAssistantMarkdown, startingAt: activeAssistantStart, isThinking: false)
        activeAssistantMarkdown = ""
        activeAssistantStart = nil
        hasStartedFinalAnswer = false
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func appendToolCallBlock(result: Bool?) {
        finishThinkingSection()
        finishAssistantSection()
        transcriptView.textStorage?.append(CampusAITranscriptStyle.toolCallStatus(result: result))
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func appendMarkdownBlock(_ markdown: String) {
        transcriptView.textStorage?.append(CampusAITranscriptStyle.markdownAttributedString(
            markdown, font: transcriptView.font ?? .systemFont(ofSize: 13)
        ))
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func renderMarkdown(_ markdown: String, startingAt start: Int?, isThinking: Bool = false) {
        guard let storage = transcriptView.textStorage,
              let start = start, start <= storage.length else { return }
        let currentRange = NSRange(location: start, length: storage.length - start)
        let rendered = CampusAITranscriptStyle.markdownAttributedString(
            markdown, font: transcriptView.font ?? .systemFont(ofSize: 13), isThinking: isThinking
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
        activeSendRequestID = nil
        activeAttachmentClient?.cancel()
        activeAttachmentClient = nil
        pendingLookupSend = nil
        activeLookupID = nil
        activeLookupTask?.cancel()
        activeLookupTask = nil
        activeLookupSession?.invalidateAndCancel()
        activeLookupSession = nil
        finishThinkingSection()
        if !activeAssistantMarkdown.isEmpty { renderMarkdown(activeAssistantMarkdown, startingAt: activeAssistantStart) }
        activeThinkingStart = nil
        activeThinkingMarkdown = ""
        activeAssistantStart = nil
        activeAssistantMarkdown = ""
        hasStartedFinalAnswer = false
        sending = false
        activeClient = nil
        sendButton.title = "发送"
        promptField.isEnabled = true
        attachmentButton.isEnabled = true
        clearAttachmentsButton.isEnabled = !selectedAttachments.isEmpty
        thinkingModePopup.isEnabled = true
        historyButton.isEnabled = true
        promptField.stringValue = ""
        if error == nil {
            selectedAttachments.removeAll()
        }
        updateAttachmentSummary()
        appendText("\n\n")
        statusLabel.stringValue = error ?? "回复完成。"
    }

    @objc private func thinkingModeChanged() {
        let modes = CampusAIThinkingMode.allCases
        let selectedIndex = thinkingModePopup.indexOfSelectedItem
        let selected = modes.indices.contains(selectedIndex) ? modes[selectedIndex] : .balanced
        defaults.set(selected.rawValue, forKey: "campus_ai_thinking_mode")
    }

    private func selectedThinkingMode() -> CampusAIThinkingMode {
        guard let rawValue = defaults.string(forKey: "campus_ai_thinking_mode"),
              let mode = CampusAIThinkingMode(rawValue: rawValue) else { return .balanced }
        return mode
    }

    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 门户有时使用 window.open() 或 target=_blank，然后继续更新窗口 location。
        // 返回真实的弹出 WKWebView 才能让后续浏览器导航和 CAS 回跳正常执行。
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
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
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

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        resetPendingCASCredentialsAfterFailedLogin(in: webView)
        statusLabel.stringValue = "学校登录页面连接失败，请检查网络后重试。"
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let current = webView.url else { return }
        guard webView === loginWebView, displayingLogin else { return }
        let host = current.host?.lowercased() ?? ""
        captureSharedCASTGC(
            from: webView,
            pageURL: current,
            navigationID: portalNavigationID,
            username: portalSessionUsername
        )

        if HFUTCASLoginSupport.isLoginPage(current) {
            resetPendingCASCredentialsAfterFailedLogin(in: webView)
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
                    self.statusLabel.stringValue = "CAS 服务票据校验失败。请确认通过信息门户的 AI 应用中台进入后重试。"
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

    private func captureSharedCASTGC(from webView: WKWebView, pageURL: URL,
                                     navigationID: UUID, username: String) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
            DispatchQueue.main.async {
                guard let self = self, let webView = webView,
                      self.portalNavigationID == navigationID,
                      self.portalSessionUsername == username,
                      webView === self.loginWebView,
                      webView.url == pageURL,
                      !username.isEmpty,
                      !HFUTCASLoginSupport.isLoginPage(pageURL),
                      let tgc = HFUTCASLoginSupport.tgcCookieValue(from: cookies) else { return }

                let host = pageURL.host?.lowercased() ?? ""
                let hasServiceTicket = ["one.hfut.edu.cn", "i.hfut.edu.cn", "jxglstu.hfut.edu.cn", CampusAIEndpoint.host].contains(host)
                    && (URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.queryItems?
                        .contains(where: { $0.name.caseInsensitiveCompare("ticket") == .orderedSame && !($0.value ?? "").isEmpty }) ?? false)
                let hasConfirmedAISession = host == CampusAIEndpoint.host && self.hasAISession(cookies)
                let hasPendingCASCredentials = self.pendingCASCredentials.map {
                    $0.navigationID == navigationID && $0.username == username
                } ?? false
                guard hasServiceTicket || (!hasPendingCASCredentials && hasConfirmedAISession) else { return }

                if let pending = self.pendingCASCredentials,
                   pending.navigationID == navigationID,
                   pending.username == username {
                    let currentUsername = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard currentUsername == pending.previousUsername else {
                        self.pendingCASCredentials = nil
                        if currentUsername == username {
                            SettingsManager.shared.casTgcCookie = tgc
                        }
                        return
                    }
                    SettingsManager.shared.portalUsername = pending.username
                    if let password = pending.password {
                        SettingsManager.shared.casPassword = password
                    }
                    SettingsWindowController.shared.handleExternalAccountSwitch(
                        previousUsername: pending.previousUsername,
                        previousStudentID: pending.previousStudentID,
                        preserveCasPassword: pending.password != nil
                    )
                    self.portalSessionUsername = pending.username
                    self.pendingCASCredentials = nil
                    SettingsManager.shared.casTgcCookie = tgc
                    return
                }

                guard SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines) == username else { return }
                SettingsManager.shared.casTgcCookie = tgc
            }
        }
    }

    private func resetPendingCASCredentialsAfterFailedLogin(in webView: WKWebView) {
        guard webView === loginWebView,
              pendingCASCredentials?.navigationID == portalNavigationID,
              HFUTCASLoginSupport.isLoginPage(webView.url) else { return }
        pendingCASCredentials = nil
        portalSessionUsername = SettingsManager.shared.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard webView === loginWebView else { return }
        statusLabel.stringValue = "学校页面加载失败，请检查网络后重试。"
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
