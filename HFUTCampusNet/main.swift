import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, CampusNetworkClientDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置为轻量级状态栏 Accessory 模式
        NSApp.setActivationPolicy(.accessory)

        CampusNetworkClient.shared.delegate = self

        // 初始化状态栏控制器与桌面小组件
        _ = MenubarController.shared
        
        if SettingsManager.shared.showDesktopWidget {
            DesktopWidgetController.shared.showWidget()
        }

        // 无论如何都启动监测引擎！
        CampusNetworkClient.shared.startMonitoring()

        // 如果既没有自服务 Cookie，也没有配置密码，延迟 1 秒提示打开设置
        let noCookie = SettingsManager.shared.sessionCookie == nil || SettingsManager.shared.sessionCookie?.isEmpty == true
        let noPassword = SettingsManager.shared.portalPassword.isEmpty
        if noCookie && noPassword {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                SettingsWindowController.shared.showSettings()
            }
        }
    }

    func clientDidUpdate(data: CampusNetworkData) {
        MenubarController.shared.updateData(data)
        DesktopWidgetController.shared.updateData(data)
    }

    func clientDidFail(error: String) {
        var data = CampusNetworkClient.shared.latestData
        data.errorMessage = error
        MenubarController.shared.updateData(data)
        DesktopWidgetController.shared.updateData(data)
    }

    func applicationWillTerminate(_ notification: Notification) {
        CampusNetworkClient.shared.stopMonitoring()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
