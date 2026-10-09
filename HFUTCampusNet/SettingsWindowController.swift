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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 285),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学校园网 - 自动登录与账号设置"
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
        title.frame = NSRect(x: 24, y: 240, width: 390, height: 22)
        title.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        contentView.addSubview(title)

        let subtitle = NSTextField(labelWithString: "配置账号密码后，休眠唤醒或断网时将自动完成无感登录并在通知栏提醒。")
        subtitle.frame = NSRect(x: 24, y: 216, width: 390, height: 18)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        contentView.addSubview(subtitle)

        // 学号/账号
        let userLabel = NSTextField(labelWithString: "学号 / 账号：")
        userLabel.frame = NSRect(x: 24, y: 172, width: 90, height: 20)
        contentView.addSubview(userLabel)

        usernameField = NSTextField(frame: NSRect(x: 120, y: 170, width: 280, height: 24))
        usernameField.placeholderString = "例如 2024xxxxxx"
        usernameField.stringValue = SettingsManager.shared.portalUsername
        contentView.addSubview(usernameField)

        // 密码
        let passLabel = NSTextField(labelWithString: "校园网密码：")
        passLabel.frame = NSRect(x: 24, y: 132, width: 90, height: 20)
        contentView.addSubview(passLabel)

        passwordField = NSSecureTextField(frame: NSRect(x: 120, y: 130, width: 280, height: 24))
        passwordField.placeholderString = "请输入校园网认证密码"
        passwordField.stringValue = SettingsManager.shared.portalPassword
        contentView.addSubview(passwordField)

        // 自动登录复选框
        autoLoginCheckbox = NSButton(checkboxWithTitle: "掉线或重连 Wi-Fi 时自动登录并发送系统通知", target: nil, action: nil)
        autoLoginCheckbox.frame = NSRect(x: 120, y: 96, width: 290, height: 20)
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        contentView.addSubview(autoLoginCheckbox)

        // 状态信息
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 24, y: 60, width: 390, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        // 底部按钮
        let testBtn = NSButton(title: "测试连接/登录", target: self, action: #selector(testLoginClicked))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: 110, y: 16, width: 105, height: 32)
        contentView.addSubview(testBtn)

        let logoutBtn = NSButton(title: "注销设备", target: self, action: #selector(logoutClicked))
        logoutBtn.bezelStyle = .rounded
        logoutBtn.frame = NSRect(x: 220, y: 16, width: 85, height: 32)
        contentView.addSubview(logoutBtn)

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 310, y: 16, width: 90, height: 32)
        contentView.addSubview(saveBtn)

        window.contentView = contentView
    }

    public func showSettings() {
        usernameField.stringValue = SettingsManager.shared.portalUsername
        passwordField.stringValue = SettingsManager.shared.portalPassword
        autoLoginCheckbox.state = SettingsManager.shared.autoLoginPortal ? .on : .off
        
        // 自动检查当前状态并展示
        PortalAuthService.shared.checkStatus { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .online(let uid, let ip, _, let fee, _):
                    self?.statusLabel.stringValue = "🟢 当前已认证在线 (学号: \(uid), IP: \(ip), 余额: \(String(format: "%.2f", fee))元)"
                    self?.statusLabel.textColor = .systemGreen
                case .offline(let reason):
                    self?.statusLabel.stringValue = "🟡 当前离线未认证: \(reason)"
                    self?.statusLabel.textColor = .systemOrange
                case .notInCampusNet:
                    self?.statusLabel.stringValue = "🔴 未连接校园网络 (无法连接 172.18.3.3)"
                    self?.statusLabel.textColor = .systemRed
                }
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
