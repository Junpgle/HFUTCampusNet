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

    /// 当前客户端版本号（从 Info.plist 读取，兜底为 2.0.0）
    public var currentVersion: String {
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !ver.isEmpty {
            return ver
        }
        return "2.0.0"
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
            alert.accessoryView = Self.makeReleaseNotesView(markdown: notes)
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

    /// 构建原生 NSTextView + NSScrollView 的 Release Notes 预览视图（显式 TextKit 栈，滚动跟手，自动适配深浅色）
    static func makeReleaseNotesView(markdown: String, width: CGFloat = 460, height: CGFloat = 300) -> NSView {
        let scroll = ImmediateScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let inset: CGFloat = 12
        let contentW = width - 4

        // 显式构建 TextKit 栈：container 固定尺寸，滚动阶段不触发任何文字重排
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: contentW - 2 * inset, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentW, height: height), textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: inset, height: inset)
        // 高度由下方按内容实测后手动设定，禁止文本视图自行调整，避免滚动时与 scroll view 反馈打架
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // 关闭拼写/语法/数据检测，避免滚动布局时触发额外文本检查造成卡顿
        textView.enabledTextCheckingTypes = 0

        textStorage.setAttributedString(releaseNotesAttributedText(from: markdown))

        // 按内容自适应高度（上限 400pt，下限 160pt）
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let contentH = used + 2 * inset + 8
        let fitted = min(400, max(160, contentH))
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: fitted)
        // documentView 高度 = 内容实际高度，保证超出弹窗时可滚动
        textView.frame = NSRect(x: 0, y: 0, width: contentW, height: max(contentH, fitted))

        scroll.documentView = textView
        return scroll
    }

    /// 解析 GitHub Release Notes 常用 Markdown 子集（标题 / 加粗 / 行内代码 / 列表 / 链接 / 分隔线），
    /// 生成使用动态系统颜色（labelColor / linkColor）的富文本，自动适配深浅色外观
    static func releaseNotesAttributedText(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 12.5)
        let headingFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineSpacing = 2
        bodyPara.paragraphSpacing = 4

        let headingPara = NSMutableParagraphStyle()
        headingPara.lineSpacing = 2
        headingPara.paragraphSpacing = 6

        let listPara = NSMutableParagraphStyle()
        listPara.lineSpacing = 2
        listPara.paragraphSpacing = 3
        listPara.firstLineHeadIndent = 0
        listPara.headIndent = 16

        func appendInline(_ text: String, baseFont: NSFont, para: NSParagraphStyle) {
            // 按 **加粗** / `行内代码` / [链接](url) 切分，其余为普通文本
            let pattern = "(\\*\\*[^*]+\\*\\*|`[^`]+`|\\[[^\\]]+\\]\\(https?://[^\\s\\)]+\\))"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para
                ]
                result.append(NSAttributedString(string: text, attributes: attrs))
                return
            }
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            var lastEnd = 0
            for match in regex.matches(in: text, range: full) {
                if match.range.location > lastEnd {
                    let plain = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                    result.append(NSAttributedString(string: plain, attributes: [
                        .font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para
                    ]))
                }
                let token = ns.substring(with: match.range)
                if token.hasPrefix("**") {
                    let inner = String(token.dropFirst(2).dropLast(2))
                    let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                    result.append(NSAttributedString(string: inner, attributes: [
                        .font: bold, .foregroundColor: NSColor.labelColor, .paragraphStyle: para
                    ]))
                } else if token.hasPrefix("`") {
                    let inner = String(token.dropFirst().dropLast())
                    result.append(NSAttributedString(string: inner, attributes: [
                        .font: codeFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para
                    ]))
                } else if token.hasPrefix("["),
                          let openRange = token.range(of: "]("),
                          let closeRange = token.range(of: ")") {
                    let linkText = String(token[token.index(token.startIndex, offsetBy: 1)..<openRange.lowerBound])
                    let urlStr = String(token[openRange.upperBound..<closeRange.lowerBound])
                    result.append(NSAttributedString(string: linkText, attributes: [
                        .font: baseFont,
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .link: URL(string: urlStr) as Any,
                        .paragraphStyle: para
                    ]))
                }
                lastEnd = match.range.location + match.range.length
            }
            if lastEnd < ns.length {
                let plain = ns.substring(from: lastEnd)
                result.append(NSAttributedString(string: plain, attributes: [
                    .font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para
                ]))
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont, .paragraphStyle: bodyPara
                ]))
                continue
            }

            if line.hasPrefix("---") || line.hasPrefix("***") || line.hasPrefix("___") {
                let sep = String(repeating: "─", count: 40)
                result.append(NSAttributedString(string: sep + "\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.separatorColor,
                    .paragraphStyle: bodyPara
                ]))
                continue
            }

            if let hashRange = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let text = String(line[hashRange.upperBound...])
                appendInline(text, baseFont: headingFont, para: headingPara)
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: headingFont, .paragraphStyle: headingPara
                ]))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                result.append(NSAttributedString(string: "• ", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: listPara
                ]))
                appendInline(String(line.dropFirst(2)), baseFont: bodyFont, para: listPara)
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont, .paragraphStyle: listPara
                ]))
                continue
            }

            appendInline(line, baseFont: bodyFont, para: bodyPara)
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: bodyFont, .paragraphStyle: bodyPara
            ]))
        }
        return result
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

/// 强制滚动零时长的 NSScrollView：NSAlert 内嵌滚动视图默认会把触摸板滚动当作动画插值，
/// 导致「划完才跳到最终位置」；包裹一层 NSAnimationContext(duration: 0) 后可跟手实时滚动
private final class ImmediateScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            super.scrollWheel(with: event)
        }
    }
}

extension Notification.Name {
    public static let updateCheckDidFinish = Notification.Name("cn.edu.hfut.updateCheckDidFinish")
}
