import Foundation
import AppKit

public class SettingsManager {
    public static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let cookie = "campus_session_cookie"
        static let refreshInterval = "campus_refresh_interval" // 秒
        static let showDesktopWidget = "campus_show_desktop_widget"
        static let widgetX = "campus_widget_x"
        static let widgetY = "campus_widget_y"
        static let widgetOpacity = "campus_widget_opacity"
        static let menubarStyle = "campus_menubar_style" // 0: 智能轮播, 1: 仅流量余额, 2: 仅实时网速, 3: 并排显示
        static let carouselInterval = "campus_carousel_interval" // 轮播秒数 (默认 3.5s)
        static let portalUsername = "campus_portal_username"
        static let portalPassword = "campus_portal_password"
        static let autoLoginPortal = "campus_auto_login_portal"
    }

    private init() {
        if defaults.object(forKey: Keys.refreshInterval) == nil {
            defaults.set(300.0, forKey: Keys.refreshInterval)
        }
        if defaults.object(forKey: Keys.showDesktopWidget) == nil {
            defaults.set(true, forKey: Keys.showDesktopWidget)
        }
        if defaults.object(forKey: Keys.widgetOpacity) == nil {
            defaults.set(0.92, forKey: Keys.widgetOpacity)
        }
        if defaults.object(forKey: Keys.menubarStyle) == nil {
            defaults.set(0, forKey: Keys.menubarStyle) // 默认 0: 智能轮播！
        }
        if defaults.object(forKey: Keys.carouselInterval) == nil {
            defaults.set(3.5, forKey: Keys.carouselInterval)
        }
        if defaults.object(forKey: Keys.autoLoginPortal) == nil {
            defaults.set(true, forKey: Keys.autoLoginPortal)
        }
        // 账号默认留空，由用户首次在设置中填写

    }

    public var sessionCookie: String? {
        get { defaults.string(forKey: Keys.cookie) }
        set { defaults.set(newValue, forKey: Keys.cookie) }
    }

    public var refreshInterval: TimeInterval {
        get { defaults.double(forKey: Keys.refreshInterval) }
        set { defaults.set(newValue, forKey: Keys.refreshInterval) }
    }

    public var showDesktopWidget: Bool {
        get { defaults.bool(forKey: Keys.showDesktopWidget) }
        set { defaults.set(newValue, forKey: Keys.showDesktopWidget) }
    }

    public var widgetOpacity: CGFloat {
        get { CGFloat(defaults.float(forKey: Keys.widgetOpacity)) }
        set { defaults.set(Float(newValue), forKey: Keys.widgetOpacity) }
    }

    public var widgetOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Keys.widgetX) != nil,
                  defaults.object(forKey: Keys.widgetY) != nil else {
                return nil
            }
            return CGPoint(
                x: defaults.double(forKey: Keys.widgetX),
                y: defaults.double(forKey: Keys.widgetY)
            )
        }
        set {
            if let origin = newValue {
                defaults.set(origin.x, forKey: Keys.widgetX)
                defaults.set(origin.y, forKey: Keys.widgetY)
            } else {
                defaults.removeObject(forKey: Keys.widgetX)
                defaults.removeObject(forKey: Keys.widgetY)
            }
        }
    }

    public var menubarStyle: Int {
        get { defaults.integer(forKey: Keys.menubarStyle) }
        set { defaults.set(newValue, forKey: Keys.menubarStyle) }
    }

    public var carouselInterval: TimeInterval {
        get { defaults.double(forKey: Keys.carouselInterval) }
        set { defaults.set(newValue, forKey: Keys.carouselInterval) }
    }

    public var portalUsername: String {
        get { defaults.string(forKey: Keys.portalUsername) ?? "" }
        set { defaults.set(newValue, forKey: Keys.portalUsername) }
    }

    public var portalPassword: String {
        get { defaults.string(forKey: Keys.portalPassword) ?? "" }
        set { defaults.set(newValue, forKey: Keys.portalPassword) }
    }

    public var autoLoginPortal: Bool {
        get { defaults.bool(forKey: Keys.autoLoginPortal) }
        set { defaults.set(newValue, forKey: Keys.autoLoginPortal) }
    }
}
