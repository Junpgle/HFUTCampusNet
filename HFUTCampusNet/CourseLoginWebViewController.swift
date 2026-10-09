import Foundation
import AppKit
import WebKit

public class CourseLoginWebViewController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
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

        webView = WKWebView(frame: NSRect(x: 0, y: 52, width: 960, height: 628), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)

        // 底部状态与操作栏
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 52))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 16, y: 18, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        bottomBar.addSubview(progressIndicator)

        statusLabel = NSTextField(labelWithString: "正在连接合工大教务管理系统...")
        statusLabel.frame = NSRect(x: 42, y: 16, width: 560, height: 20)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        bottomBar.addSubview(statusLabel)

        let reloadBtn = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        reloadBtn.bezelStyle = .rounded
        reloadBtn.frame = NSRect(x: 610, y: 11, width: 85, height: 30)
        bottomBar.addSubview(reloadBtn)

        let goToTableBtn = NSButton(title: "前往课表页", target: self, action: #selector(navigateToCourseTable))
        goToTableBtn.bezelStyle = .rounded
        goToTableBtn.frame = NSRect(x: 700, y: 11, width: 95, height: 30)
        bottomBar.addSubview(goToTableBtn)

        let manualSyncBtn = NSButton(title: "从当前页读取课表", target: self, action: #selector(manualExtractCurrentPage))
        manualSyncBtn.bezelStyle = .rounded
        manualSyncBtn.frame = NSRect(x: 800, y: 11, width: 145, height: 30)
        bottomBar.addSubview(manualSyncBtn)

        containerView.addSubview(bottomBar)
        window.contentView = containerView
    }

    public func showLoginWindow(targetURLString: String? = nil) {
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let stdId = SettingsManager.shared.courseStudentId.isEmpty ? "178506" : SettingsManager.shared.courseStudentId
        let defaultURL = "https://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table/info/\(stdId)"
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
        let stdId = SettingsManager.shared.courseStudentId.isEmpty ? "178506" : SettingsManager.shared.courseStudentId
        let urlStr = "https://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table/info/\(stdId)"
        if let url = URL(string: urlStr) {
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func manualExtractCurrentPage() {
        triggerAutoExtraction()
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在加载页面..."
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        guard let currentURL = webView.url else { return }
        let urlStr = currentURL.absoluteString

        // 尝试自动填充学号
        let savedU = SettingsManager.shared.portalUsername
        if !savedU.isEmpty && (urlStr.contains("/login") || urlStr.contains("cas.hfut.edu.cn")) {
            let js = """
            if (document.getElementById('u') && !document.getElementById('u').value) {
                document.getElementById('u').value = '\(savedU)';
            }
            if (document.getElementById('username') && !document.getElementById('username').value) {
                document.getElementById('username').value = '\(savedU)';
            }
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // 检查是否到达课表页面
        if urlStr.contains("/for-std/course-table/info/") || urlStr.contains("/for-std/course-table") {
            triggerAutoExtraction()
        } else if urlStr.contains("/login") || urlStr.contains("cas.hfut.edu.cn") {
            statusLabel.stringValue = "请在上方网页输入密码并登录..."
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
        statusLabel.stringValue = "正在检测课表权限并抓取排课数据..."
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

        // 读取所有 Cookie
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            for cookie in cookies {
                if cookie.name == "SESSION" && (cookie.domain.contains("hfut.edu.cn") || cookie.domain.isEmpty) {
                    SettingsManager.shared.courseSessionCookie = cookie.value
                }
            }

            // 读取 HTML 获取 bizTypeId
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
                        self.isSyncing = false
                        self.progressIndicator.stopAnimation(nil)

                        switch result {
                        case .success(let schedule):
                            self.statusLabel.stringValue = "🎉 课表同步成功！已获取 \(schedule.lessons.count) 节课程，正在自动返回..."
                            self.statusLabel.textColor = NSColor.systemGreen
                            NotificationHelper.sendNotification(
                                title: "🎉 HFUT课表同步成功",
                                body: "已成功同步 \(schedule.lessons.count) 门课次数据，可在菜单栏与桌面组件随时查看！"
                            )
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                self.window?.close()
                                // 打开课表主窗口供用户查看
                                CourseScheduleWindowController.shared.showWindow(nil)
                            }
                        case .failure(let error):
                            self.statusLabel.stringValue = "❌ 课表同步失败: \(error.localizedDescription)"
                            self.statusLabel.textColor = NSColor.systemRed
                        }
                    }
                }
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
