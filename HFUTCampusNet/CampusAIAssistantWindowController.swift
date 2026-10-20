import Foundation
import AppKit
import WebKit

// HFUT AI-Flow 官方聊天入口。仅使用当前用户登录后获得的 AiFlow 会话，
// 不在 App 配置文件/源码中另存 Cookie、账号密码或数据库 SQL；
// WKWebView 默认网站数据存储按学校 Cookie 自身有效期维护会话。
private enum CampusAIEndpoint {
    static let host = "aipt.hfut.edu.cn"
    static let api = URL(string: "https://aipt.hfut.edu.cn/api/af-api-agent/")!
    static let defaultAgentID = "1966078115428446208"
    static let defaultModelID = "2097156176776544256"

    static func validID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^[0-9]{1,19}$", options: .regularExpression) != nil
            && Int64(trimmed) != nil
    }

    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              let result = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(result.dropFirst().dropLast())
    }

    static func cookies(from all: [HTTPCookie]) -> [HTTPCookie] {
        all.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let path = "/api/af-api-agent/chat/send"
            // 不要把 CAS 等其他路径的 Cookie 扩大范围发送给 AI-Flow。
            let pathMatches = path.hasPrefix(cookie.path)
            let notExpired = cookie.expiresDate.map { $0 > Date() } ?? true
            return (domain == host || domain == "hfut.edu.cn")
                && pathMatches && notExpired
        }
    }
}

// 在 macOS 原生 URLSession 中解析 SSE，避免 WKWebView 隐藏后 JS 流可能被节流。
// 回调都在主线程执行，流中的 SQL 和完整工具返回值不记录、不持久化。
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
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private var task: URLSessionDataTask?
    private var pending = Data()
    private var completed = false
    private var httpStatus: Int?

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func start(question: String, groupID: String, modelID: String,
               agentID: String, cookies: [HTTPCookie], aiFlow: String) {
        var req = URLRequest(url: CampusAIEndpoint.api.appendingPathComponent("chat/send"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(aiFlow, forHTTPHeaderField: "aiflow")
        req.setValue("https://aipt.hfut.edu.cn/agent-detail?id=\(agentID)", forHTTPHeaderField: "Referer")
        if let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }
        // ID 必须作为 JSON int64 原样传输；不能通过 JavaScript Number 处理。
        let payload = "{\"text\":\(CampusAIEndpoint.jsonString(question)),"
            + "\"groupId\":\(groupID),\"aiLargeModelId\":\(modelID),"
            + "\"thinkingMode\":\"balanced\",\"debug\":false,"
            + "\"traceId\":\"\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased())\"}"
        req.httpBody = Data(payload.utf8)
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
        httpStatus = status
        if status == 401 || status == 403 {
            completionHandler(.cancel)
            finish("平台拒绝请求（HTTP \(status)），请在网页登录后重试。")
        } else if !(200...299).contains(status) {
            completionHandler(.cancel)
            finish("平台返回 HTTP \(status)，无法继续对话。")
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pending.append(data)
        // 同时支持 LF 与 CRLF；按完整帧切割可避免拆分 UTF-8 汉字。
        while true {
            let lf = pending.range(of: Data("\n\n".utf8))
            let crlf = pending.range(of: Data("\r\n\r\n".utf8))
            guard let range = [lf, crlf].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { break }
            readFrame(pending.subdata(in: 0..<range.lowerBound))
            pending.removeSubrange(0..<range.upperBound)
        }
        if pending.count > 2_000_000 {
            finish("返回的单个 SSE 数据帧异常过大，已中止。")
            task?.cancel()
        }
    }

    private func readFrame(_ data: Data) {
        guard let frame = String(data: data, encoding: .utf8) else { return }
        let lines = frame.components(separatedBy: .newlines)
        let json = lines.filter { $0.hasPrefix("data:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        guard !json.isEmpty, let bytes = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return }
        let type = object["type"] as? String ?? ""
        switch type {
        case "text":
            if let content = object["content"] as? String { onEvent(.text(content)) }
        case "thinking_start":
            onEvent(.status("AI 正在思考…"))
        case "tool_call_start":
            onEvent(.status("正在调用学校智能体工具…"))
        case "tool_call_result":
            let call = object["tool_call"] as? [String: Any]
            let state = call?["status"] as? String ?? ""
            onEvent(.status(state == "success" ? "工具执行完成，正在生成回复…" : "工具返回状态：\(state)"))
        case "error":
            let msg = object["error"] as? String ?? "智能体执行失败"
            onEvent(.status(msg))
        default:
            break
        }
        if object["is_end"] as? Bool == true {
            onEvent(.status("回复已完成"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            finish("连接中断：\(error.localizedDescription)")
        } else {
            // SSE 最后一个数据帧可能没有以空行终止。
            if !pending.isEmpty { readFrame(pending) }
            finish(nil)
        }
    }

    private func finish(_ error: String?) {
        guard !completed else { return }
        completed = true
        pending.removeAll()
        onEvent(.finished(error))
        session.invalidateAndCancel()
    }
}

public final class CampusAIAssistantWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    public static let shared = CampusAIAssistantWindowController()

    private let defaults = UserDefaults.standard
    private let agentField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let groupField = NSTextField(string: "")
    private let promptField = NSTextField(string: "")
    private let transcriptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "正在检查已有 CAS 会话…")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let loginButton = NSButton(title: "重连 AI", target: nil, action: nil)
    private let backButton = NSButton(title: "返回聊天", target: nil, action: nil)
    private let transcriptScroll = NSScrollView()
    private var loginWebView: WKWebView!
    private var activeClient: CampusAIStreamClient?
    private var sending = false
    private var displayingLogin = false
    private enum SSOStage { case idle, homepage, agentPage }
    private var ssoStage: SSOStage = .idle
    private var ssoAttempt = UUID()

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
        loginButton.action = #selector(reconnectAI)
        root.addSubview(loginButton)

        backButton.frame = NSRect(x: 860, y: 650, width: 100, height: 30)
        backButton.autoresizingMask = [.minXMargin, .minYMargin]
        backButton.target = self
        backButton.action = #selector(showChat)
        backButton.isEnabled = false
        root.addSubview(backButton)

        root.addSubview(label("智能体 ID", x: 20, y: 611, width: 75))
        agentField.frame = NSRect(x: 96, y: 608, width: 236, height: 24)
        agentField.stringValue = defaults.string(forKey: "campus_ai_agent_id") ?? CampusAIEndpoint.defaultAgentID
        root.addSubview(agentField)
        root.addSubview(label("模型 ID", x: 345, y: 611, width: 58))
        modelField.frame = NSRect(x: 402, y: 608, width: 236, height: 24)
        modelField.stringValue = defaults.string(forKey: "campus_ai_model_id") ?? CampusAIEndpoint.defaultModelID
        root.addSubview(modelField)
        root.addSubview(label("会话 ID", x: 648, y: 611, width: 60))
        groupField.frame = NSRect(x: 706, y: 608, width: 254, height: 24)
        groupField.placeholderString = "留空尝试获取最近会话"
        root.addSubview(groupField)
        for item in [agentField, modelField, groupField] {
            item.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            item.autoresizingMask = [.minYMargin]
        }
        groupField.autoresizingMask = [.minXMargin, .width, .minYMargin]

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // 与 App 现有统一登录 WebView 共用 Cookie 存储
        loginWebView = WKWebView(frame: NSRect(x: 20, y: 128, width: 940, height: 458), configuration: config)
        loginWebView.navigationDelegate = self
        loginWebView.autoresizingMask = [.width, .height]
        loginWebView.isHidden = true
        root.addSubview(loginWebView)

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
        transcriptView.textContainerInset = NSSize(width: 12, height: 12)
        transcriptView.string = "欢迎使用校园 AI 助手。\n\n正在尝试复用 App 的统一 CAS 登录状态。\n如果 CAS 会话失效，请先在 App 内完成统一认证，再点击「重连 AI」。\n聊天记录仅保留在当前窗口内。\n\n"
        transcriptScroll.documentView = transcriptView
        root.addSubview(transcriptScroll)

        promptField.frame = NSRect(x: 20, y: 72, width: 820, height: 32)
        promptField.placeholderString = "输入你想咨询的问题，例如：请查询我本人的课程成绩"
        promptField.font = .systemFont(ofSize: 13)
        promptField.autoresizingMask = [.width, .maxYMargin]
        promptField.target = self
        promptField.action = #selector(sendMessage)
        root.addSubview(promptField)

        sendButton.frame = NSRect(x: 851, y: 72, width: 109, height: 32)
        sendButton.autoresizingMask = [.minXMargin, .maxYMargin]
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        sendButton.keyEquivalent = "\r"
        root.addSubview(sendButton)

        statusLabel.frame = NSRect(x: 20, y: 22, width: 940, height: 28)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(statusLabel)
    }

    public func showAssistant() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        prepareAIFromCAS()
    }

    /// 使用 App 现有 CAS Cookie 进行 AI 服务自己的 SSO 认证，而不是将 CASTGC 当作 AiFlow。
    private func prepareAIFromCAS(forceRefresh: Bool = false) {
        let attempt = UUID()
        ssoAttempt = attempt
        ssoStage = .idle
        statusLabel.stringValue = "正在复用统一身份认证登录态…"
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { [weak self] all in
            DispatchQueue.main.async { [weak self] in
            guard let self = self, self.ssoAttempt == attempt else { return }
            if forceRefresh, let oldAI = all.first(where: { cookie in
                cookie.name == "AiFlow" && cookie.domain.lowercased().contains("aipt.hfut.edu.cn")
            }) {
                store.delete(oldAI) { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.ssoAttempt == attempt else { return }
                        self.continueCASBootstrap(cookies: all, attempt: attempt, store: store)
                    }
                }
                return
            }
            if self.hasAISession(all) {
                self.statusLabel.stringValue = "已发现 AI 平台会话，可直接发送消息。"
                return
            }
            self.continueCASBootstrap(cookies: all, attempt: attempt, store: store)
            }
        }
    }

    private func continueCASBootstrap(cookies all: [HTTPCookie], attempt: UUID, store: WKHTTPCookieStore) {
            guard ssoAttempt == attempt else { return }
            let validCAS = all.contains { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (cookie.name == "CASTGC" || cookie.name == "TGC")
                    && (domain == "cas.hfut.edu.cn" || domain == "hfut.edu.cn")
                    && "/cas/login".hasPrefix(cookie.path)
                    && (cookie.expiresDate.map { $0 > Date() } ?? true)
            }
            if validCAS {
                self.loadAIHomepage()
                return
            }
            // 旧版统一登录已将 CAS TGC 保存于 SettingsManager。
            // 只在本机原始 CAS 域名恢复它，绝不跨域设置到 aipt.hfut.edu.cn。
            let savedTGC = SettingsManager.shared.casTgcCookie ?? ""
            guard !savedTGC.isEmpty else {
                self.statusLabel.stringValue = "未找到统一 CAS 会话。请先在 App 内完成统一认证，再点击「重连 AI」。"
                return
            }
            let props: [HTTPCookiePropertyKey: Any] = [
                .domain: "cas.hfut.edu.cn",
                .path: "/cas",
                .name: "CASTGC",
                .value: savedTGC,
                .secure: "TRUE",
                .discard: "TRUE"
            ]
            guard let restored = HTTPCookie(properties: props) else {
                self.statusLabel.stringValue = "无法恢复 CAS 会话，请在 App 中重新统一登录。"
                return
            }
            store.setCookie(restored) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.ssoAttempt == attempt else { return }
                    self.loadAIHomepage()
                }
            }
    }

    private func hasAISession(_ cookies: [HTTPCookie]) -> Bool {
        CampusAIEndpoint.cookies(from: cookies).contains { cookie in
            cookie.name == "AiFlow" && !cookie.value.isEmpty
        }
    }

    private func loadAIHomepage() {
        ssoStage = .homepage
        // 先访问网站主页，让目标服务自行申请并校验 CAS Service Ticket。
        // 不能直接拿其他服务的 ST，也不能自行拼接 service/ticket。
        statusLabel.stringValue = "已有 CAS 会话，正在为 AI 平台建立独立登录态…"
        loginWebView.load(URLRequest(
            url: URL(string: "https://aipt.hfut.edu.cn/")!,
            cachePolicy: .reloadIgnoringLocalCacheData
        ))
    }

    @objc private func reconnectAI() {
        prepareAIFromCAS(forceRefresh: true)
    }

    @objc private func showChat() {
        displayingLogin = false
        loginWebView.isHidden = true
        transcriptScroll.isHidden = false
        backButton.isEnabled = false
        statusLabel.stringValue = "正在检查 AI 会话…"
        prepareAIFromCAS()
    }

    private func revealBrowserError(_ message: String) {
        ssoStage = .idle
        displayingLogin = true
        loginWebView.isHidden = false
        transcriptScroll.isHidden = true
        backButton.isEnabled = true
        statusLabel.stringValue = message
    }

    @objc private func sendMessage() {
        if sending {
            if let client = activeClient {
                client.cancel()
            } else {
                complete("已取消")
            }
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
        sending = true
        sendButton.title = "停止"
        promptField.isEnabled = false
        appendText("\n你：\(question)\n\nAI：")
        statusLabel.stringValue = "检查当前学校 AI 登录会话…"

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] all in
            DispatchQueue.main.async {
                guard let self = self, self.sending else { return }
                let cookies = CampusAIEndpoint.cookies(from: all)
                guard let aiFlow = cookies.first(where: { $0.name == "AiFlow" })?.value,
                      !aiFlow.isEmpty else {
                    self.complete("AI 专属会话尚未建立。请检查 CAS 自动连接状态，必要时先在 App 中统一登录再重连 AI。")
                    self.prepareAIFromCAS()
                    return
                }
                if !groupID.isEmpty {
                    self.startStreaming(question: question, groupID: groupID,
                                        modelID: modelID, agentID: agentID,
                                        cookies: cookies, aiFlow: aiFlow)
                } else {
                    self.findRecentGroup(question: question, agentID: agentID, modelID: modelID,
                                         cookies: cookies, aiFlow: aiFlow)
                }
            }
        }
    }

    private func findRecentGroup(question: String, agentID: String, modelID: String,
                                 cookies: [HTTPCookie], aiFlow: String) {
        statusLabel.stringValue = "正在查询该智能体的最近会话…"
        var request = URLRequest(url: CampusAIEndpoint.api.appendingPathComponent("chat/lastGroup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(aiFlow, forHTTPHeaderField: "aiflow")
        if let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        // businessType=1 为智能体会话候选类型，具体平台版本可能不同；失败时让用户手动提供会话 ID。
        request.httpBody = Data("{\"businessId\":\(agentID),\"businessType\":1}".utf8)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            var resolvedID: String?
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let data = data,
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (object["status"] as? NSNumber)?.intValue == 1,
               let group = object["data"] as? [String: Any] {
                // Foundation 的 NSNumber 支持 int64，无 JavaScript Number 精度问题。
                let id = (group["id"] as? NSNumber)?.stringValue ?? (group["id"] as? String)
                let returnedAgent = (group["agentId"] as? NSNumber)?.stringValue ?? (group["agentId"] as? String)
                if let id = id, CampusAIEndpoint.validID(id),
                   returnedAgent == nil || returnedAgent == agentID {
                    resolvedID = id
                }
            }
            DispatchQueue.main.async {
                guard let self = self, self.sending else { return }
                guard let groupID = resolvedID else {
                    self.complete("无法自动获取会话 ID。请先在网页登录页打开对话，再从该页面 /chat/send 请求中复制 groupId 到上方会话 ID 输入框。")
                    return
                }
                self.groupField.stringValue = groupID
                self.startStreaming(question: question, groupID: groupID,
                                    modelID: modelID, agentID: agentID,
                                    cookies: cookies, aiFlow: aiFlow)
            }
        }.resume()
    }

    private func startStreaming(question: String, groupID: String, modelID: String,
                                agentID: String, cookies: [HTTPCookie], aiFlow: String) {
        statusLabel.stringValue = "已连接，等待智能体回复…"
        let client = CampusAIStreamClient { [weak self] event in
            guard let self = self else { return }
            switch event {
            case .text(let chunk):
                self.appendText(chunk)
            case .status(let message):
                self.statusLabel.stringValue = message
            case .finished(let error):
                self.complete(error)
            }
        }
        activeClient = client
        client.start(question: question, groupID: groupID, modelID: modelID,
                     agentID: agentID, cookies: cookies, aiFlow: aiFlow)
    }

    private func appendText(_ value: String) {
        transcriptView.textStorage?.append(NSAttributedString(string: value))
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func complete(_ error: String?) {
        guard sending else { return }
        sending = false
        activeClient = nil
        sendButton.title = "发送"
        promptField.isEnabled = true
        promptField.stringValue = ""
        appendText("\n\n")
        statusLabel.stringValue = error ?? "回复完成。"
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let current = webView.url else { return }
        // CAS 报错必须停止自动重试：ST 与 Service 绑定，不能复用其他服务的票据。
        if current.host == "cas.hfut.edu.cn" {
            webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 2000) : ''") { [weak self] result, _ in
                guard let self = self, let body = result as? String else { return }
                if body.contains("不符合目标服务") || body.contains("INVALID_SERVICE") {
                    self.revealBrowserError("CAS 票据与 AI 服务地址不匹配；请联系学校平台维护方检查 service 配置。")
                } else if body.contains("登录") && (body.contains("密码") || body.contains("Password")) {
                    self.revealBrowserError("CAS 会话可能已过期。请使用 App 原有的「统一身份认证同步」重新登录，然后重连 AI。")
                }
            }
            return
        }
        guard current.host == CampusAIEndpoint.host else { return }
        let stage = ssoStage
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] all in
            DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.hasAISession(all) {
                self.ssoStage = .idle
                self.statusLabel.stringValue = "已复用 CAS 登录并建立 AI 会话，可发送消息。"
                if self.displayingLogin {
                    self.displayingLogin = false
                    self.loginWebView.isHidden = true
                    self.transcriptScroll.isHidden = false
                    self.backButton.isEnabled = false
                }
            } else if stage == .homepage {
                // 主页认证完成后再进入智能体页面，避免直接对深层路径申请票据。
                self.ssoStage = .agentPage
                let agent = self.agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if CampusAIEndpoint.validID(agent),
                   let url = URL(string: "https://aipt.hfut.edu.cn/agent-detail?id=\(agent)") {
                    self.loginWebView.load(URLRequest(url: url))
                }
            } else if stage == .agentPage {
                self.statusLabel.stringValue = "AI 页面已加载，但尚未产生 AiFlow 会话。请确认智能体已成功打开。"
            }
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        statusLabel.stringValue = "AI 单点登录加载失败：\(error.localizedDescription)"
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
