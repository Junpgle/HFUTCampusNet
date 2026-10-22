import AppKit
import WebKit

/// Shared native CAPTCHA UI for every WebKit flow that reaches the official CAS password page.
/// Credentials and CAPTCHA answers are submitted by clicking the current page's own form control.
final class HFUTCASLoginCoordinator: NSObject, WKScriptMessageHandler {
    private let panel: HFUTCASLoginPanel
    private weak var webView: WKWebView?
    private weak var overlayHost: NSView?
    private var enabled = true
    private var blockedForCurrentPage = false
    private var preferWebLogin = false
    private var formReady = false
    private var probeToken = UUID()
    private var refreshToken: UUID?
    private var pendingCredentials: (username: String, password: String)?

    var onStatus: ((String) -> Void)?

    init(frame: NSRect) {
        panel = HFUTCASLoginPanel(frame: frame)
        super.init()
        panel.onRefresh = { [weak self] in self?.refreshCaptcha() }
        panel.onSubmit = { [weak self] username, password, captcha in
            self?.submit(username: username, password: password, captcha: captcha)
        }
        panel.onUseWebLogin = { [weak self] in self?.showWebLogin() }
        panel.isHidden = true
    }

    func installMessageHandler(in controller: WKUserContentController) {
        controller.add(self, name: HFUTCASLoginSupport.messageName)
    }

    func attach(webView: WKWebView, overlayHost: NSView) {
        self.webView = webView
        self.overlayHost = overlayHost
        panel.frame = webView.frame
        panel.autoresizingMask = [.width, .height]
        if panel.superview !== overlayHost {
            panel.removeFromSuperview()
            overlayHost.addSubview(panel, positioned: .above, relativeTo: webView)
        }
        panel.isHidden = true
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            probeToken = UUID()
            refreshToken = nil
            pendingCredentials = nil
            formReady = false
            panel.isHidden = true
        }
    }

    func resetPendingCredentials() {
        pendingCredentials = nil
    }

    @discardableResult
    func commitPendingCredentials() -> (previousUsername: String, currentUsername: String)? {
        guard let credentials = pendingCredentials else { return nil }
        pendingCredentials = nil

        let settings = SettingsManager.shared
        let previousUsername = settings.portalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentUsername = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentUsername.isEmpty else { return nil }
        settings.portalUsername = currentUsername
        settings.casPassword = credentials.password
        return (previousUsername, currentUsername)
    }

    func blockCurrentPage() {
        blockedForCurrentPage = true
        formReady = false
        panel.isHidden = true
        webView?.isHidden = false
    }

    func navigationStarted(in webView: WKWebView) {
        guard self.webView === webView else { return }
        probeToken = UUID()
        refreshToken = nil
        formReady = false
        preferWebLogin = false
        blockedForCurrentPage = false
        panel.setSubmitting(false)
        panel.isHidden = true
        webView.isHidden = false
    }

    func navigationFinished(in webView: WKWebView) {
        guard enabled, self.webView === webView else { return }
        guard HFUTCASLoginSupport.isLoginPage(webView.url) else {
            formReady = false
            panel.isHidden = true
            return
        }
        inspect(webView)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == HFUTCASLoginSupport.messageName,
              let webView = self.webView,
              message.webView === webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host.lowercased() == "cas.hfut.edu.cn",
              let body = message.body as? [String: String],
              ["formChanged", "captchaChanged"].contains(body["event"] ?? "") else { return }
        if body["event"] == "captchaChanged" { refreshToken = nil }
        inspect(webView)
    }

    private func inspect(_ webView: WKWebView) {
        guard enabled, !blockedForCurrentPage, HFUTCASLoginSupport.isLoginPage(webView.url) else { return }
        let token = UUID()
        probeToken = token
        webView.evaluateJavaScript(HFUTCASLoginSupport.probeScript) { [weak self, weak webView] result, _ in
            DispatchQueue.main.async {
                guard let self, let webView, self.enabled, self.webView === webView,
                      self.probeToken == token, !self.blockedForCurrentPage,
                      HFUTCASLoginSupport.isLoginPage(webView.url) else { return }
                self.applyProbe(result, in: webView)
            }
        }
    }

    private func applyProbe(_ result: Any?, in webView: WKWebView) {
        guard let descriptor = result as? [String: Any], descriptor["ready"] as? Bool == true else {
            formReady = false
            panel.isHidden = true
            webView.isHidden = false
            return
        }
        if descriptor["captureFailed"] as? Bool == true {
            showWebFallback("验证码无法从当前 CAS 页面读取，已保留网页登录方式。")
            return
        }
        if refreshToken != nil {
            panel.setStatus("正在等待 CAS 页面加载新的验证码…")
            showPanelOrWebView(webView)
            return
        }
        if !formReady {
            panel.prepare(username: SettingsManager.shared.portalUsername,
                          password: SettingsManager.shared.casPassword)
        }
        formReady = true
        if let dataURL = descriptor["captchaDataURL"] as? String {
            guard let image = HFUTCASLoginSupport.captchaImageData(from: dataURL) else {
                showWebFallback("验证码图片格式不受支持，已保留学校网页登录方式。")
                return
            }
            panel.setCaptchaImage(image)
            panel.setStatus("验证码已从当前 CAS 页面读取。")
        } else {
            panel.setStatus("正在读取验证码；若图片未出现，可刷新或切换到网页登录。")
        }
        showPanelOrWebView(webView)
    }

    private func showPanelOrWebView(_ webView: WKWebView) {
        let usePanel = !preferWebLogin && !blockedForCurrentPage
        panel.isHidden = !usePanel
        webView.isHidden = usePanel
    }

    private func showWebFallback(_ message: String) {
        formReady = false
        probeToken = UUID()
        refreshToken = nil
        panel.setSubmitting(false)
        panel.isHidden = true
        webView?.isHidden = false
        panel.setStatus(message)
        onStatus?(message)
    }

    private func showWebLogin() {
        preferWebLogin = true
        panel.isHidden = true
        webView?.isHidden = false
        let message = "已切换到学校网页登录。登录仍由 CAS 页面完成。"
        panel.setStatus(message)
        onStatus?(message)
    }

    private func refreshCaptcha() {
        guard formReady, let webView = webView,
              HFUTCASLoginSupport.isLoginPage(webView.url) else {
            showWebFallback("当前验证码页面已变化，请在学校网页中继续登录。")
            return
        }
        let token = UUID()
        refreshToken = token
        panel.setCaptchaImage(nil)
        panel.clearCaptchaEntry()
        panel.setStatus("正在调用当前 CAS 页面的验证码刷新控件…")
        webView.evaluateJavaScript(HFUTCASLoginSupport.refreshCaptchaScript) { [weak self] result, _ in
            guard let self, self.refreshToken == token else { return }
            guard result as? Bool == true else {
                self.refreshToken = nil
                self.panel.setStatus("当前页面没有可识别的刷新控件；可切换到网页登录刷新。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.refreshToken == token else { return }
                self.refreshToken = nil
                self.panel.setStatus("尚未观察到新验证码；可重试或切换到网页登录。")
            }
        }
    }

    private func submit(username: String, password: String, captcha: String) {
        guard formReady, let webView = webView,
              HFUTCASLoginSupport.isLoginPage(webView.url), panel.hasCaptchaImage else {
            showWebFallback("当前 CAS 表单已变化，请在学校网页中继续登录。")
            return
        }
        guard let script = HFUTCASLoginSupport.submitScript(
            username: username, password: password, captcha: captcha
        ) else {
            panel.setStatus("无法准备当前 CAS 表单提交，请切换到网页登录。")
            return
        }
        pendingCredentials = (username, password)
        formReady = false
        preferWebLogin = false
        probeToken = UUID()
        panel.setSubmitting(true)
        panel.setStatus("正在提交到学校 CAS 页面并等待服务回跳…")
        panel.isHidden = true
        webView.isHidden = false
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            DispatchQueue.main.async {
                guard let self, let webView else { return }
                if result as? Bool == true {
                    let message = "已通过 CAS 页面提交登录，正在等待学校认证结果…"
                    self.panel.setStatus(message)
                    self.onStatus?(message)
                } else if HFUTCASLoginSupport.isLoginPage(webView.url) {
                    self.pendingCredentials = nil
                    self.formReady = true
                    self.panel.isHidden = false
                    webView.isHidden = true
                    self.panel.setSubmitting(false)
                    self.panel.setStatus("未能提交当前 CAS 表单；请检查页面或切换到网页登录。")
                }
            }
        }
    }
}
