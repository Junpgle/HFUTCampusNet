import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, CampusNetworkClientDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置为轻量级状态栏 Accessory 模式
        NSApp.setActivationPolicy(.accessory)

        CampusNetworkClient.shared.delegate = self

        // 初始化通知中心代理与状态栏控制器
        _ = NotificationHelper.shared
        _ = MenubarController.shared
        
        if SettingsManager.shared.showDesktopWidget {
            DesktopWidgetController.shared.showWidget()
        }

        // 无论如何都启动监测引擎！
        CampusNetworkClient.shared.startMonitoring()
        ElectricityService.shared.fetchData { _ in }
        CampusCardService.shared.fetchData { _ in }
        if SettingsManager.shared.courseTableEnabled {
            CourseScheduleService.shared.syncSchedule { _ in }
        }
        AcademicService.shared.startMonitoring()
        EmptyClassroomService.shared.startMonitoring()

        // 启动后延迟 3 秒在后台静默检查 GitHub Releases 更新
        if SettingsManager.shared.autoCheckUpdate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                UpdateChecker.shared.checkForUpdates(manual: false)
            }
        }

        // 如果既没有自服务 Cookie，也没有配置密码，延迟 1 秒提示打开设置
        let noCookie = SettingsManager.shared.sessionCookie == nil || SettingsManager.shared.sessionCookie?.isEmpty == true
        let noPassword = SettingsManager.shared.portalPassword.isEmpty && SettingsManager.shared.casPassword.isEmpty
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
        AcademicService.shared.stopMonitoring()
        EmptyClassroomService.shared.stopMonitoring()
        NetworkSpeedMonitor.shared.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
