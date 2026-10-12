import Foundation
import AppKit
import WebKit

public struct GitHubReleaseInfo {
    public let tagName: String
    public let version: String
    public let name: String
    public let body: String
    public let htmlUrl: String
    public let downloadUrl: String?
    public let publishedAt: String?
}

public class UpdateChecker {
    public static let shared = UpdateChecker()

    public let repoOwner = "Junpgle"
    public let repoName = "HFUTCampusNet"

    /// 最新检测到的可用新版本（如有）
    public private(set) var availableUpdate: GitHubReleaseInfo?
    public private(set) var isChecking: Bool = false
    private var pendingManualFeedback: Bool = false

    private init() {}

    /// 当前客户端版本号（从 Info.plist 读取，兜底为 1.8.1）
    public var currentVersion: String {
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !ver.isEmpty {
            return ver
        }
        return "1.8.1"
    }

    /// 检查 GitHub Releases 最新版本
    /// - Parameter manual: 是否为用户手动点击触发（手动触发会弹窗提示“已是最新”或错误；自动后台检查仅在发现新版本时提醒）
    public func checkForUpdates(manual: Bool = true, completion: ((Result<GitHubReleaseInfo?, Error>) -> Void)? = nil) {
        if isChecking {
            if manual { pendingManualFeedback = true }
            return
        }
        isChecking = true
        pendingManualFeedback = manual

        let latestUrlStr = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: latestUrlStr) else {
            isChecking = false
            pendingManualFeedback = false
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HFUTCampusNet/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    let showManual = manual || self.pendingManualFeedback
                    self.isChecking = false
                    self.pendingManualFeedback = false
                    completion?(.failure(error))
                    if showManual {
                        self.showErrorAlert(message: "无法连接到 GitHub 检查更新，请检查网络连接。\n(\(error.localizedDescription))")
                    }
                }
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 如果 /releases/latest 返回 404（例如仓库仅有 Pre-release 或暂未发布 Release），尝试拉取 /releases 列表
            if httpStatus == 404 {
                self.fetchReleasesListFallback(manual: manual || self.pendingManualFeedback, completion: completion)
                return
            }

            guard httpStatus == 200, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let releaseInfo = self.parseReleaseJSON(json) else {
                DispatchQueue.main.async {
                    let showManual = manual || self.pendingManualFeedback
                    self.isChecking = false
                    self.pendingManualFeedback = false
                    let err = NSError(domain: "UpdateChecker", code: httpStatus, userInfo: [NSLocalizedDescriptionKey: "GitHub API 响应异常 (HTTP \(httpStatus))"])
                    completion?(.failure(err))
                    if showManual {
                        self.showErrorAlert(message: "获取版本信息失败 (HTTP \(httpStatus))，请稍后再试。")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                let showManual = manual || self.pendingManualFeedback
                self.isChecking = false
                self.pendingManualFeedback = false
                self.handleReleaseResult(releaseInfo, manual: showManual, completion: completion)
            }
        }.resume()
    }

    private func fetchReleasesListFallback(manual: Bool, completion: ((Result<GitHubReleaseInfo?, Error>) -> Void)?) {
        let listUrlStr = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=5"
        guard let url = URL(string: listUrlStr) else {
            DispatchQueue.main.async {
                self.isChecking = false
                self.pendingManualFeedback = false
            }
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HFUTCampusNet/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let showManual = manual || self.pendingManualFeedback
                self.isChecking = false
                self.pendingManualFeedback = false

                if let error = error {
                    completion?(.failure(error))
                    if showManual {
                        self.showErrorAlert(message: "无法连接到 GitHub 检查更新：\(error.localizedDescription)")
                    }
                    return
                }

                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard httpStatus == 200, let data = data,
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    if showManual {
                        self.showUpToDateAlert(latestVersion: self.currentVersion)
                    }
                    completion?(.success(nil))
                    return
                }

                if let first = list.first, let releaseInfo = self.parseReleaseJSON(first) {
                    self.handleReleaseResult(releaseInfo, manual: showManual, completion: completion)
                } else {
                    // 仓库尚未发布任何 Release，视为当前已是最新
                    if showManual {
                        self.showUpToDateAlert(latestVersion: self.currentVersion)
                    }
                    completion?(.success(nil))
                }
            }
        }.resume()
    }

    private func parseReleaseJSON(_ json: [String: Any]) -> GitHubReleaseInfo? {
        guard let tagName = json["tag_name"] as? String, !tagName.isEmpty else {
            return nil
        }
        let cleanVer = normalizeVersion(tagName)
        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (name?.isEmpty == false) ? name! : tagName
        let body = (json["body"] as? String) ?? ""
        let htmlUrl = (json["html_url"] as? String) ?? "https://github.com/\(repoOwner)/\(repoName)/releases"
        let publishedAt = json["published_at"] as? String

        var downloadUrl: String? = nil
        if let assets = json["assets"] as? [[String: Any]] {
            // 优先匹配 .dmg 或 .zip 安装包资源
            for asset in assets {
                if let assetName = (asset["name"] as? String)?.lowercased(),
                   let url = asset["browser_download_url"] as? String,
                   (assetName.hasSuffix(".zip") || assetName.hasSuffix(".dmg") || assetName.hasSuffix(".pkg")) {
                    downloadUrl = url
                    break
                }
            }
            if downloadUrl == nil, let firstAsset = assets.first,
               let url = firstAsset["browser_download_url"] as? String {
                downloadUrl = url
            }
        }

        return GitHubReleaseInfo(
            tagName: tagName,
            version: cleanVer,
            name: displayTitle,
            body: body,
            htmlUrl: htmlUrl,
            downloadUrl: downloadUrl,
            publishedAt: publishedAt
        )
    }

    private func handleReleaseResult(_ release: GitHubReleaseInfo, manual: Bool, completion: ((Result<GitHubReleaseInfo?, Error>) -> Void)?) {
        let isNewer = isVersion(release.version, newerThan: currentVersion)

        if isNewer {
            self.availableUpdate = release
            NotificationCenter.default.post(name: .updateCheckDidFinish, object: release)
            completion?(.success(release))

            // 如果是后台自动检查，且用户曾选择跳过该版本，则不弹窗打扰
            if !manual && SettingsManager.shared.skippedUpdateVersion == release.version {
                return
            }
            showUpdateAvailableAlert(release: release, manual: manual)
        } else {
            self.availableUpdate = nil
            NotificationCenter.default.post(name: .updateCheckDidFinish, object: nil)
            completion?(.success(nil))

            if manual {
                showUpToDateAlert(latestVersion: release.version)
            }
        }
    }

    /// 去除前导 v/V 及附加构建后缀，提取纯版本号部分
    public func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        if let dashIdx = s.firstIndex(of: "-") {
            s = String(s[..<dashIdx])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 语义化版本号对比：判断 remoteVer 是否严格大于 localVer
    public func isVersion(_ remoteVer: String, newerThan localVer: String) -> Bool {
        let rParts = normalizeVersion(remoteVer).split(separator: ".").map { Int($0) ?? 0 }
        let lParts = normalizeVersion(localVer).split(separator: ".").map { Int($0) ?? 0 }
        let maxCount = max(rParts.count, lParts.count)
        for i in 0..<maxCount {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    // MARK: - 弹窗提示

    private func showUpdateAvailableAlert(release: GitHubReleaseInfo, manual: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(release.version)"
        alert.informativeText = "当前版本：v\(currentVersion)\n最新版本：v\(release.version)"
        alert.alertStyle = .informational

        let notes = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let webView = ReleaseNotesWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
            webView.loadHTMLString(Self.releaseNotesHTML(from: notes), baseURL: nil)
            alert.accessoryView = webView
        }

        if release.downloadUrl != nil {
            alert.addButton(withTitle: "立即下载更新包")
            alert.addButton(withTitle: "查看完整更新日志")
        } else {
            alert.addButton(withTitle: "前往 GitHub 下载")
        }
        alert.addButton(withTitle: "稍后提醒")
        if !manual {
            alert.addButton(withTitle: "忽略此版本")
        }

        let response = alert.runModal()
        if release.downloadUrl != nil {
            if response == .alertFirstButtonReturn {
                if let dl = release.downloadUrl, let url = URL(string: dl) {
                    NSWorkspace.shared.open(url)
                }
            } else if response == .alertSecondButtonReturn {
                if let url = URL(string: release.htmlUrl) {
                    NSWorkspace.shared.open(url)
                }
            } else if !manual && response.rawValue == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1 {
                SettingsManager.shared.skippedUpdateVersion = release.version
            }
        } else {
            if response == .alertFirstButtonReturn {
                if let url = URL(string: release.htmlUrl) {
                    NSWorkspace.shared.open(url)
                }
            } else if !manual && response == .alertThirdButtonReturn {
                SettingsManager.shared.skippedUpdateVersion = release.version
            }
        }
    }

    // MARK: - Release Notes Markdown 渲染

    /// 将 GitHub Release Notes 的 Markdown 子集（标题 / 加粗 / 行内代码 / 列表 / 分隔线 / 链接）渲染为自适应深浅色的 HTML
    static func releaseNotesHTML(from markdown: String) -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor = isDark ? "#EBEBF5" : "#1D1D1F"
        let mutedColor = isDark ? "#98989D" : "#6E6E73"
        let accentColor = isDark ? "#64B5FF" : "#007AFF"
        let codeBg = isDark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.06)"

        var bodyHTML = ""
        var inList = false

        func closeList() {
            if inList {
                bodyHTML += "</ul>"
                inList = false
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                // GitHub 风格列表项之间常有空行，不在此闭合 <ul>，留到下一个非列表元素处统一闭合
                continue
            }

            if line.hasPrefix("---") || line.hasPrefix("***") || line.hasPrefix("___") {
                closeList()
                bodyHTML += "<hr>"
                continue
            }

            if let hashRange = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                closeList()
                let text = inlineHTML(from: String(line[hashRange.upperBound...]))
                bodyHTML += "<div class=\"heading\">\(text)</div>"
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                if !inList {
                    bodyHTML += "<ul>"
                    inList = true
                }
                let item = inlineHTML(from: String(line.dropFirst(2)))
                bodyHTML += "<li>\(item)</li>"
                continue
            }

            closeList()
            bodyHTML += "<p>\(inlineHTML(from: line))</p>"
        }
        closeList()

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            html, body {
                margin: 0;
                padding: 0;
                background: transparent;
            }
            body {
                font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
                font-size: 12.5px;
                line-height: 1.55;
                color: \(textColor);
                padding: 2px 6px 8px 2px;
                word-break: break-word;
            }
            .heading {
                font-weight: 600;
                font-size: 13px;
                margin: 12px 0 6px 0;
                color: \(textColor);
            }
            p { margin: 4px 0; }
            ul {
                margin: 4px 0 8px 0;
                padding-left: 18px;
            }
            li { margin: 2px 0; }
            hr {
                border: none;
                border-top: 1px solid \(mutedColor);
                opacity: 0.35;
                margin: 10px 0;
            }
            strong { font-weight: 600; }
            code {
                font-family: "SF Mono", Menlo, monospace;
                font-size: 11.5px;
                background: \(codeBg);
                border-radius: 3px;
                padding: 1px 4px;
            }
            a { color: \(accentColor); text-decoration: none; }
        </style>
        </head>
        <body>\(bodyHTML)</body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inlineHTML(from text: String) -> String {
        var s = escapeHTML(text)
        // [text](url)
        s = s.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\((https?://[^\\s\\)]+)\\)",
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )
        // **bold**
        s = s.replacingOccurrences(
            of: "\\*\\*(.+?)\\*\\*",
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        // `code`
        s = s.replacingOccurrences(
            of: "`([^`]+)`",
            with: "<code>$1</code>",
            options: .regularExpression
        )
        return s
    }

    private func showUpToDateAlert(latestVersion: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "当前已是最新版本"
        alert.informativeText = "您当前使用的 HFUT 校园网助手版本为 v\(currentVersion)（GitHub 最新版本：v\(latestVersion)），无需更新。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "查看 GitHub 仓库")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showErrorAlert(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开 GitHub Releases")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// 更新弹窗内嵌的 Release Notes 预览 WebView：拦截链接点击并用浏览器打开，避免跳转后丢失弹窗
private final class ReleaseNotesWebView: WKWebView, WKNavigationDelegate {
    init(frame: NSRect) {
        super.init(frame: frame, configuration: WKWebViewConfiguration())
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

extension Notification.Name {
    public static let updateCheckDidFinish = Notification.Name("cn.edu.hfut.updateCheckDidFinish")
}
