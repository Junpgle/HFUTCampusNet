import Foundation
import AppKit

public class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    private var usernameField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var autoLoginCheckbox: NSButton!
    private var statusLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 325),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学校园网 - 自动登录与自服务配置"
        window.center()
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)

        // 标题与说明
        let title = NSTextField(labelWithString: "校园网认证设置 (http://172.18.3.3)")
        title.frame = NSRect(x: 24, y: 282, width: 400, height: 22)
        title.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        contentView.addSubview(title)

        let subtitle = NSTextField(labelWithString: "配置账号密码后，休眠唤醒或断网时将自动完成无感登录并在通知栏提醒。")
        subtitle.frame = NSRect(x: 24, y: 258, width: 400, height: 18)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        contentView.addSubview(subtitle)

        // 学号/账号
        let userLabel = NSTextField(labelWithString: "学号 / 账号：")
        userLabel.frame = NSRect(x: 24, y: 216, width: 90, height: 20)
        contentView.addSubview(userLabel)

        usernameField = NSTextField(frame: NSRect(x: 120, y: 214, width: 290, height: 24))
        usernameField.placeholderString = "例如 2024xxxxxx"
        usernameField.stringValue = SettingsManager.shared.portalUsername
        contentView.addSubview(usernameField)

        // 密码
        let passLabel = NSTextField(labelWithString: "校园网密码：")
        passLabel.frame = NSRect(x: 24, y: 178, width: 90, height: 20)
        contentView.addSubview(passLabel)

        passwordField = NSSecureTextField(frame: NSRect(x: 120, y: 176, width: 290, height: 24))
        passwordField.placeholderString = "请输入校园网认证密码"
        passwordField.stringValue = SettingsManager.shared.portalPassword
        contentView.addSubview(passwordField)

        // 自动登录复选框
        autoLoginCheckbox = NSButton(checkboxWithTitle: "掉线或重连 Wi-Fi 时自动登录并发送系统通知", target: nil, action: nil)
        autoLoginCheckbox.frame = NSRect(x: 120, y: 144, width: 290, height: 20)
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        contentView.addSubview(autoLoginCheckbox)

        // 分割线
        let sep = NSBox(frame: NSRect(x: 24, y: 130, width: 402, height: 1))
        sep.boxType = .separator
        contentView.addSubview(sep)

        // 自服务授权区域
        let selfTitle = NSTextField(labelWithString: "自服务平台 (xywzz:8443 可用流量与消费保护)：")
        selfTitle.frame = NSRect(x: 24, y: 98, width: 275, height: 20)
        selfTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        contentView.addSubview(selfTitle)

        let openSelfBtn = NSButton(title: "🔑 登录自服务授权...", target: self, action: #selector(openSelfLoginWindow))
        openSelfBtn.bezelStyle = .rounded
        openSelfBtn.frame = NSRect(x: 300, y: 92, width: 125, height: 28)
        contentView.addSubview(openSelfBtn)

        // 状态信息
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 24, y: 58, width: 400, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        // 底部按钮
        let testBtn = NSButton(title: "测试连接/登录", target: self, action: #selector(testLoginClicked))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: 115, y: 14, width: 105, height: 32)
        contentView.addSubview(testBtn)

        let logoutBtn = NSButton(title: "注销设备", target: self, action: #selector(logoutClicked))
        logoutBtn.bezelStyle = .rounded
        logoutBtn.frame = NSRect(x: 228, y: 14, width: 85, height: 32)
        contentView.addSubview(logoutBtn)

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 320, y: 14, width: 90, height: 32)
        contentView.addSubview(saveBtn)

        window.contentView = contentView
    }

    public func showSettings() {
        usernameField.stringValue = SettingsManager.shared.portalUsername
        passwordField.stringValue = SettingsManager.shared.portalPassword
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        
        PortalAuthService.shared.checkStatus { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .online(let uid, let ip, _, let fee, _):
                    self?.statusLabel.stringValue = "🟢 网关已认证在线 (学号: \(uid), IP: \(ip), 余额: \(String(format: "%.2f", fee))元)"
                    self?.statusLabel.textColor = .systemGreen
                case .offline(let reason):
                    self?.statusLabel.stringValue = "🟡 网关离线未认证: \(reason)"
                    self?.statusLabel.textColor = .systemOrange
                case .notInCampusNet:
                    self?.statusLabel.stringValue = "🔴 未连接校园网络 Wi-Fi"
                    self?.statusLabel.textColor = .systemRed
                }
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSelfLoginWindow() {
        LoginWebViewController.shared.showLoginWindow()
    }

    @objc private func testLoginClicked() {
        let user = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !user.isEmpty else {
            statusLabel.stringValue = "⚠️ 请先输入学号"
            statusLabel.textColor = .systemOrange
            return
        }

        statusLabel.stringValue = "正在检测与认证..."
        statusLabel.textColor = .secondaryLabelColor

        PortalAuthService.shared.login(username: user, password: pass) { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = (success ? "✓ " : "❌ ") + msg
                self?.statusLabel.textColor = success ? .systemGreen : .systemRed
                if success {
                    self?.saveCredentials()
                    CampusNetworkClient.shared.fetchData()
                }
            }
        }
    }

    @objc private func logoutClicked() {
        statusLabel.stringValue = "正在注销当前设备..."
        PortalAuthService.shared.logout { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = msg
                self?.statusLabel.textColor = success ? .systemOrange : .systemRed
                CampusNetworkClient.shared.fetchData()
            }
        }
    }

    @objc private func saveClicked() {
        saveCredentials()
        window?.close()
        CampusNetworkClient.shared.fetchData()
    }

    private func saveCredentials() {
        SettingsManager.shared.portalUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.portalPassword = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.autoLoginPortal = (autoLoginCheckbox.state == .on)
    }
}
