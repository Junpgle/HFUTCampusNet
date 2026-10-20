import AppKit

final class HFUTCASLoginPanel: NSView {
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let captchaField = NSTextField()
    private let captchaImageView = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "刷新验证码", target: nil, action: nil)
    private let submitButton = NSButton(title: "通过 CAS 登录", target: nil, action: nil)
    private let webLoginButton = NSButton(title: "使用网页登录", target: nil, action: nil)
    private(set) var hasCaptchaImage = false

    var onRefresh: (() -> Void)?
    var onSubmit: ((String, String, String) -> Void)?
    var onUseWebLogin: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let title = NSTextField(labelWithString: "学校统一身份认证")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.frame = NSRect(x: 210, y: 402, width: 520, height: 26)
        addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "仅在学校 CAS 密码登录页出现。验证码和凭据仍由当前 CAS 页面提交验证。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 150, y: 369, width: 640, height: 28)
        addSubview(subtitle)

        addFieldLabel("账号", y: 319)
        usernameField.frame = NSRect(x: 280, y: 316, width: 480, height: 26)
        usernameField.placeholderString = "学号 / 统一身份认证账号"
        usernameField.font = .systemFont(ofSize: 13)
        usernameField.setAccessibilityLabel("统一身份认证账号")
        addSubview(usernameField)

        addFieldLabel("密码", y: 272)
        passwordField.frame = NSRect(x: 280, y: 269, width: 480, height: 26)
        passwordField.placeholderString = "信息门户密码"
        passwordField.font = .systemFont(ofSize: 13)
        passwordField.setAccessibilityLabel("统一身份认证密码")
        addSubview(passwordField)

        addFieldLabel("验证码", y: 218)
        captchaImageView.frame = NSRect(x: 280, y: 203, width: 126, height: 42)
        captchaImageView.imageScaling = .scaleProportionallyUpOrDown
        captchaImageView.wantsLayer = true
        captchaImageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        captchaImageView.layer?.borderColor = NSColor.separatorColor.cgColor
        captchaImageView.layer?.borderWidth = 1
        captchaImageView.layer?.cornerRadius = 4
        captchaImageView.setAccessibilityLabel("学校验证码图片")
        addSubview(captchaImageView)

        refreshButton.frame = NSRect(x: 413, y: 210, width: 106, height: 28)
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.setAccessibilityLabel("刷新学校验证码")
        addSubview(refreshButton)

        captchaField.frame = NSRect(x: 534, y: 209, width: 226, height: 30)
        captchaField.placeholderString = "输入图片中的验证码"
        captchaField.font = .systemFont(ofSize: 13)
        captchaField.setAccessibilityLabel("学校验证码")
        addSubview(captchaField)

        submitButton.frame = NSRect(x: 280, y: 149, width: 164, height: 32)
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r"
        submitButton.target = self
        submitButton.action = #selector(submitClicked)
        addSubview(submitButton)

        webLoginButton.frame = NSRect(x: 455, y: 149, width: 130, height: 32)
        webLoginButton.bezelStyle = .rounded
        webLoginButton.target = self
        webLoginButton.action = #selector(webLoginClicked)
        addSubview(webLoginButton)

        statusLabel.frame = NSRect(x: 280, y: 105, width: 480, height: 30)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        addSubview(statusLabel)

        setCaptchaImage(nil)
        setStatus("正在从学校登录页读取验证码…")
    }

    private func addFieldLabel(_ value: String, y: CGFloat) {
        let label = NSTextField(labelWithString: value)
        label.frame = NSRect(x: 210, y: y, width: 60, height: 20)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        addSubview(label)
    }

    func prepare(username: String, password: String) {
        usernameField.stringValue = username
        passwordField.stringValue = password
        captchaField.stringValue = ""
        setCaptchaImage(nil)
        setStatus("正在从学校登录页读取验证码…")
        setSubmitting(false)
    }

    var credentials: (username: String, password: String, captcha: String) {
        (usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
         passwordField.stringValue,
         captchaField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func setCaptchaImage(_ data: Data?) {
        let image = data.flatMap { NSImage(data: $0) }
        captchaImageView.image = image
        hasCaptchaImage = image != nil
        submitButton.isEnabled = hasCaptchaImage
    }

    func clearCaptchaEntry() {
        captchaField.stringValue = ""
    }

    func setStatus(_ value: String) {
        statusLabel.stringValue = value
    }

    func setSubmitting(_ submitting: Bool) {
        usernameField.isEnabled = !submitting
        passwordField.isEnabled = !submitting
        captchaField.isEnabled = !submitting
        refreshButton.isEnabled = !submitting
        submitButton.isEnabled = !submitting && hasCaptchaImage
        webLoginButton.isEnabled = !submitting
    }

    func clearSensitiveFields() {
        passwordField.stringValue = ""
        captchaField.stringValue = ""
        setCaptchaImage(nil)
    }

    @objc private func refreshClicked() {
        captchaField.stringValue = ""
        onRefresh?()
    }

    @objc private func submitClicked() {
        let values = credentials
        guard !values.username.isEmpty, !values.password.isEmpty, !values.captcha.isEmpty else {
            setStatus("请填写账号、密码和验证码。")
            return
        }
        guard hasCaptchaImage else {
            setStatus("验证码图片尚未就绪，请刷新或切换到网页登录。")
            return
        }
        onSubmit?(values.username, values.password, values.captcha)
    }

    @objc private func webLoginClicked() {
        onUseWebLogin?()
    }
}
