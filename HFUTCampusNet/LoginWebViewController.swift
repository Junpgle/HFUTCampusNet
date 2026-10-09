import Foundation
import AppKit
import WebKit

public class LoginWebViewController: NSWindowController, WKNavigationDelegate {
    public static let shared = LoginWebViewController()

    private var webView: WKWebView!
    private var progressIndicator: NSProgressIndicator!
    private var statusLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRange(location: 0, length: 0).toRect(width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学校园网自服务 - 授权登录"
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

        // 配置 Web 视图
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 44, width: 860, height: 556), configuration: config)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)

        // 底部工具条
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 44))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 16, y: 14, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        bottomBar.addSubview(progressIndicator)

        statusLabel = NSTextField(labelWithString: "正在加载校园网自服务登录页面...")
        statusLabel.frame = NSRect(x: 40, y: 12, width: 450, height: 20)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        bottomBar.addSubview(statusLabel)

        let manualButton = NSButton(title: "手动设置 Cookie", target: self, action: #selector(promptManualCookie))
        manualButton.bezelStyle = .rounded
        manualButton.frame = NSRect(x: 700, y: 7, width: 140, height: 28)
        bottomBar.addSubview(manualButton)

        containerView.addSubview(bottomBar)
        window.contentView = containerView
    }

    public func showLoginWindow() {
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let url = URL(string: "https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI")!
        let request = URLRequest(url: url)
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "请在下方网页中正常登录，登录成功将自动捕获凭证并开启监控..."
        webView.load(request)
    }

    // 网页加载完成回调
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        checkAndCaptureSession()
    }

    // 网页重定向与路由检测
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url?.absoluteString {
            if url.contains("dashboard") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.checkAndCaptureSession()
                }
            }
        }
        decisionHandler(.allow)
    }

    // 忽略 SSL 自签名证书错误
    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // 捕获 Cookie 并保存
    private func checkAndCaptureSession() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            for cookie in cookies {
                if cookie.name == "JSESSIONID" && !cookie.value.isEmpty {
                    // 确认页面是否进入了控制台
                    self.webView.evaluateJavaScript("document.body.innerText") { result, _ in
                        let text = (result as? String) ?? ""
                        if text.contains("已用流量") || text.contains("可用流量") || text.contains("退出") || text.contains("账户余额") {
                            // 登录成功！
                            SettingsManager.shared.sessionCookie = cookie.value
                            self.statusLabel.stringValue = "✓ 登录成功！已自动保存会话，正在开启后台监控..."
                            self.statusLabel.textColor = .systemGreen
                            
                            CampusNetworkClient.shared.fetchData()
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                self.window?.close()
                            }
                        }
                    }
                    break
                }
            }
        }
    }

    @objc private func promptManualCookie() {
        let alert = NSAlert()
        alert.messageText = "手动输入 JSESSIONID"
        alert.informativeText = "如果您已经在外部浏览器中登录，可以打开开发者工具(F12) -> Application -> Cookies，复制 JSESSIONID 的值填入下方："
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = SettingsManager.shared.sessionCookie ?? ""
        alert.accessoryView = input

        alert.addButton(withTitle: "保存")
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
