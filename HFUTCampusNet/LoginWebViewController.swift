import Foundation
import AppKit
import WebKit

public class LoginWebViewController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    public static let shared = LoginWebViewController()

    private var webView: WKWebView!
    private var progressIndicator: NSProgressIndicator!
    private var statusLabel: NSTextField!

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

        webView = WKWebView(frame: NSRect(x: 0, y: 48, width: 900, height: 572), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)

        // 底部工具条
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 48))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 16, y: 16, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        bottomBar.addSubview(progressIndicator)

        statusLabel = NSTextField(labelWithString: "正在连接校园网自服务平台...")
        statusLabel.frame = NSRect(x: 42, y: 14, width: 620, height: 20)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        bottomBar.addSubview(statusLabel)

        let reloadBtn = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        reloadBtn.bezelStyle = .rounded
        reloadBtn.frame = NSRect(x: 670, y: 9, width: 85, height: 30)
        bottomBar.addSubview(reloadBtn)

        let manualButton = NSButton(title: "手动填Cookie", target: self, action: #selector(promptManualCookie))
        manualButton.bezelStyle = .rounded
        manualButton.frame = NSRect(x: 760, y: 9, width: 125, height: 30)
        bottomBar.addSubview(manualButton)

        containerView.addSubview(bottomBar)
        window.contentView = containerView
    }

    public func showLoginWindow() {
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let url = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "请在下方网页输入学号与密码登录，成功后将自动获取可用流量与保护配额..."
        statusLabel.textColor = .secondaryLabelColor
        webView.load(request)
    }

    @objc private func reloadPage() {
        showLoginWindow()
    }

    // 处理自签名证书信任（关键：确保 HTTPS 8443 不报错白屏）
    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.startAnimation(nil)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = "❌ 页面连接失败: \(error.localizedDescription) (请确认已连上校园网)"
        statusLabel.textColor = .systemRed
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = "❌ 加载异常: \(error.localizedDescription)"
        statusLabel.textColor = .systemRed
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        checkAndCaptureSession()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url?.absoluteString {
            if url.contains("dashboard") || url.contains("navlist") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.checkAndCaptureSession()
                }
            }
        }
        decisionHandler(.allow)
    }

    // 捕获 Cookie 并就地直接提取页面数据！
    private func checkAndCaptureSession() {
        // 先检查 HTML 内容
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
            guard let self = self else { return }
            let text = (result as? String) ?? ""

            // 如果页面中包含了自服务的特征词
            if text.contains("可用流量") || text.contains("已用流量") || text.contains("消费保护") || text.contains("账户余额") {
                self.webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") { htmlResult, _ in
                    if let fullHtml = htmlResult as? String {
                        // 直接通过解析器提取
                        if let parsed = CampusNetworkClient.shared.parseDashboardHTML(fullHtml) {
                            var data = CampusNetworkClient.shared.latestData
                            if parsed.availableFlow != "-- M" {
                                data.availableFlow = parsed.availableFlow
                            }
                            if parsed.flowProtection != "-- 元" {
                                data.flowProtection = parsed.flowProtection
                            }
                            if parsed.balance != "-- 元" {
                                data.balance = parsed.balance
                            }
                            if parsed.usedFlow != "-- M" {
                                data.usedFlow = parsed.usedFlow
                            }
                            data.lastUpdated = Date()
                            data.isLoggedIn = true
                            CampusNetworkClient.shared.delegate?.clientDidUpdate(data: data)
                        }
                    }
                }

                // 提取最新的 JSESSIONID Cookie
                self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    for cookie in cookies {
                        if cookie.name == "JSESSIONID" && !cookie.value.isEmpty {
                            SettingsManager.shared.sessionCookie = cookie.value
                            break
                        }
                    }
                }

                self.statusLabel.stringValue = "✓ 授权成功！可用流量与保护配额已同步至小组件！"
                self.statusLabel.textColor = .systemGreen

                // 延时 1.5 秒自动关闭窗口
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.window?.close()
                }
            }
        }
    }

    @objc private func promptManualCookie() {
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
