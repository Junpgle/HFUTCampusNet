import Foundation
import AppKit

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

    /// 当前客户端版本号（从 Info.plist 读取，兜底为 1.7.0）
    public var currentVersion: String {
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !ver.isEmpty {
            return ver
        }
        return "1.7.0"
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
        alert.messageText = "发现新版本 \(release.tagName)"
        let notes = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesText = notes.isEmpty ? "暂无详细更新说明。" : notes
        alert.informativeText = "当前版本：v\(currentVersion)\n最新版本：\(release.name)\n\n更新内容：\n\(notesText)"
        alert.alertStyle = .informational

        if release.downloadUrl != nil {
            alert.addButton(withTitle: "立即下载更新包")
            alert.addButton(withTitle: "查看 Release 页面")
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

extension Notification.Name {
    public static let updateCheckDidFinish = Notification.Name("cn.edu.hfut.updateCheckDidFinish")
}
