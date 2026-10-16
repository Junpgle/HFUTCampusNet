import Foundation
import AppKit
import WebKit

private struct LibraryPortalSnapshot {
    var totalSeats = "--"
    var occupiedSeats = "--"
    var availableSeats = "--"
    var visitsToday = "--"
    var visitsThisMonth = "--"
    var loansToday = "--"
    var loansThisMonth = "--"
    var events: [(String, String, String)] = []
}

/// 展示图书馆门户公开统计，并在同一窗口内使用学校自身登录查询借阅/续借与座位服务。
public final class LibraryWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    public static let shared = LibraryWindowController()

    private let portalURL = URL(string: "https://lib.hfut.edu.cn/portal/")!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var valueLabels: [NSTextField] = []
    private var titleLabels: [NSTextField] = []
    private var detailLabels: [NSTextField] = []
    private var activityLabel: NSTextField!
    private var currentSnapshot = LibraryPortalSnapshot()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "合工大图书馆 · 座位与借阅服务"
        window.minSize = NSSize(width: 880, height: 650)
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window else { return }
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let topBar = AdaptiveBoxView(frame: NSRect(x: 0, y: 746, width: 1080, height: 54))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.dynamicBackgroundColor = .windowBackgroundColor
        content.addSubview(topBar)

        let heading = NSTextField(labelWithString: "图书馆公开数据")
        heading.frame = NSRect(x: 20, y: 28, width: 180, height: 18)
        heading.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        topBar.addSubview(heading)

        statusLabel = NSTextField(labelWithString: "正在读取学校图书馆门户…")
        statusLabel.frame = NSRect(x: 20, y: 7, width: 620, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 10.5)
        statusLabel.textColor = .secondaryLabelColor
        topBar.addSubview(statusLabel)

        let myLibraryButton = NSButton(title: "我的图书馆 / 登录", target: self, action: #selector(openMyLibrary))
        myLibraryButton.bezelStyle = .rounded
        myLibraryButton.frame = NSRect(x: 820, y: 12, width: 125, height: 30)
        myLibraryButton.autoresizingMask = [.minXMargin]
        topBar.addSubview(myLibraryButton)

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshPortal))
        refreshButton.bezelStyle = .rounded
        refreshButton.frame = NSRect(x: 955, y: 12, width: 90, height: 30)
        refreshButton.autoresizingMask = [.minXMargin]
        topBar.addSubview(refreshButton)

        let cardNames = ["可用座位", "今日入馆", "本月入馆", "今日借阅"]
        for index in 0..<4 {
            let x = 20 + CGFloat(index) * 260
            let card = AdaptiveBoxView(frame: NSRect(x: x, y: 650, width: 245, height: 76))
            card.autoresizingMask = [.minYMargin]
            card.dynamicCornerRadius = 10
            card.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.035)
            card.dynamicBorderColor = NSColor.labelColor.withAlphaComponent(0.10)
            card.dynamicBorderWidth = 1

            let title = NSTextField(labelWithString: cardNames[index])
            title.frame = NSRect(x: 14, y: 52, width: 217, height: 16)
            title.font = NSFont.systemFont(ofSize: 11)
            title.textColor = .secondaryLabelColor
            card.addSubview(title)

            let value = NSTextField(labelWithString: "--")
            value.frame = NSRect(x: 14, y: 24, width: 217, height: 24)
            value.font = NSFont.systemFont(ofSize: 19, weight: .bold)
            card.addSubview(value)

            let detail = NSTextField(labelWithString: "等待门户数据")
            detail.frame = NSRect(x: 14, y: 6, width: 217, height: 14)
            detail.font = NSFont.systemFont(ofSize: 10)
            detail.textColor = .tertiaryLabelColor
            card.addSubview(detail)

            content.addSubview(card)
            titleLabels.append(title)
            valueLabels.append(value)
            detailLabels.append(detail)
        }

        activityLabel = NSTextField(wrappingLabelWithString: "图书馆活动：读取中…")
        activityLabel.frame = NSRect(x: 20, y: 586, width: 1040, height: 48)
        activityLabel.autoresizingMask = [.width, .minYMargin]
        activityLabel.font = NSFont.systemFont(ofSize: 11)
        activityLabel.textColor = .secondaryLabelColor
        content.addSubview(activityLabel)

        let separator = NSBox(frame: NSRect(x: 20, y: 576, width: 1040, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        content.addSubview(separator)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1080, height: 568), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)

        layoutSubviews()
        webView.load(URLRequest(url: portalURL))
    }

    private func layoutSubviews() {
        guard let content = window?.contentView else { return }
        let width = content.bounds.width
        let height = content.bounds.height
        let side = CGFloat(20)
        let cardGap = CGFloat(12)
        let cardWidth = floor((width - side * 2 - cardGap * 3) / 4)

        if let topBar = content.subviews.first(where: { $0 is AdaptiveBoxView }) {
            topBar.frame = NSRect(x: 0, y: height - 54, width: width, height: 54)
        }
        let cardsY = height - 54 - 12 - 76
        let cards = content.subviews.compactMap { $0 as? AdaptiveBoxView }.dropFirst()
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: side + CGFloat(index) * (cardWidth + cardGap), y: cardsY, width: cardWidth, height: 76)
        }
        let activityY = cardsY - 57
        activityLabel.frame = NSRect(x: side, y: activityY, width: width - side * 2, height: 48)
        let separator = content.subviews.first(where: { $0 is NSBox })
        separator?.frame = NSRect(x: side, y: activityY - 10, width: width - side * 2, height: 1)
        webView.frame = NSRect(x: 0, y: 0, width: width, height: max(250, activityY - 22))
    }

    public func windowDidResize(_ notification: Notification) {
        layoutSubviews()
    }

    public override func showWindow(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if webView.url == nil { webView.load(URLRequest(url: portalURL)) }
    }

    @objc private func refreshPortal() {
        statusLabel.stringValue = "正在刷新图书馆门户数据…"
        webView.reload()
    }

    @objc private func openMyLibrary() {
        if webView.url?.host == "lib.hfut.edu.cn" {
            webView.evaluateJavaScript("(() => { const e=[...document.querySelectorAll('span')].find(x=>(x.innerText||'').trim()==='我的图书馆'); if(e){e.click();return true;} return false; })()") { [weak self] result, _ in
                guard let self, (result as? Bool) != true else { return }
                self.webView.load(URLRequest(url: self.portalURL))
            }
        } else {
            webView.load(URLRequest(url: portalURL))
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.host == "lib.hfut.edu.cn",
              webView.url?.path == "/portal/" || webView.url?.path == "/portal" else { return }
        let script = """
        (() => {
          const items = [...document.querySelectorAll('.dashboard-item')];
          const metric = label => {
            const item = items.find(node => (node.innerText || '').includes(label));
            if (!item) return '';
            const value = item.querySelector('p span')?.innerText || (item.innerText || '').replace(label, '').trim();
            return value.replace(/,/g, '').trim();
          };
          const events = [...document.querySelectorAll('.itemCard')].slice(0, 5).map(node => ({
            title: node.querySelector('.textflowDouble')?.innerText?.trim() || '',
            type: node.querySelector('.cardType')?.innerText?.trim() || '',
            summary: (node.innerText || '').replace(/\\s+/g, ' ').trim()
          })).filter(item => item.title || item.summary);
          return {
            totalSeats: metric('座位总数'), occupiedSeats: metric('已使用数'), availableSeats: metric('剩余座位'),
            visitsToday: metric('今日入馆'), visitsThisMonth: metric('当月入馆'),
            loansToday: metric('今日借阅'), loansThisMonth: metric('当月借阅'), events
          };
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            guard error == nil, let dictionary = result as? [String: Any] else {
                self.statusLabel.stringValue = "图书馆页面已打开，公开统计暂时无法读取。"
                return
            }
            self.applySnapshot(dictionary)
        }
    }

    private func applySnapshot(_ dictionary: [String: Any]) {
        func value(_ key: String) -> String { (dictionary[key] as? String).map { $0.isEmpty ? "--" : $0 } ?? "--" }
        currentSnapshot.totalSeats = value("totalSeats")
        currentSnapshot.occupiedSeats = value("occupiedSeats")
        currentSnapshot.availableSeats = value("availableSeats")
        currentSnapshot.visitsToday = value("visitsToday")
        currentSnapshot.visitsThisMonth = value("visitsThisMonth")
        currentSnapshot.loansToday = value("loansToday")
        currentSnapshot.loansThisMonth = value("loansThisMonth")

        valueLabels[0].stringValue = "\(currentSnapshot.availableSeats) / \(currentSnapshot.totalSeats)"
        detailLabels[0].stringValue = "占用 \(currentSnapshot.occupiedSeats) 个座位"
        valueLabels[1].stringValue = currentSnapshot.visitsToday
        detailLabels[1].stringValue = "本月累计 \(currentSnapshot.visitsThisMonth) 人次"
        valueLabels[2].stringValue = currentSnapshot.visitsThisMonth
        detailLabels[2].stringValue = "今日入馆 \(currentSnapshot.visitsToday) 人次"
        valueLabels[3].stringValue = currentSnapshot.loansToday
        detailLabels[3].stringValue = "本月借阅 \(currentSnapshot.loansThisMonth) 册"

        let events = (dictionary["events"] as? [[String: Any]] ?? []).prefix(3).map { event in
            let summary = (event["summary"] as? String ?? "").replacingOccurrences(of: "去查看", with: "")
            return "• \(summary)"
        }
        activityLabel.stringValue = events.isEmpty ? "图书馆活动：门户当前未列出活动。" : "近期活动（图书馆门户）：\n" + events.joined(separator: "\n")
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        statusLabel.stringValue = "公开统计已从学校图书馆门户读取 · 更新于 \(time) · 登录与借阅数据由门户直接处理"
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        webView.load(navigationAction.request)
        return nil
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let host = url.host?.lowercased() ?? ""
        if host == "lib.hfut.edu.cn" || host == "cas.hfut.edu.cn" || host.hasSuffix(".hfut.edu.cn") || host == "210.45.242.57" {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}
