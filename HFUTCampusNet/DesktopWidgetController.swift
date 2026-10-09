import Foundation
import AppKit

public class DesktopWidgetController: NSWindowController, NetworkSpeedMonitorDelegate {
    public static let shared = DesktopWidgetController()

    private var visualEffectView: NSVisualEffectView!
    private var usedFlowNumLabel: NSTextField!
    private var usedFlowUnitLabel: NSTextField!
    private var availFlowNumLabel: NSTextField!
    private var availFlowUnitLabel: NSTextField!
    private var protNumLabel: NSTextField!
    private var protUnitLabel: NSTextField!
    private var balNumLabel: NSTextField!
    private var balUnitLabel: NSTextField!
    private var updateTimeLabel: NSTextField!
    private var speedBadgeLabel: NSTextField!
    private var progressBar: NSProgressIndicator!

    private var currentData: CampusNetworkData = CampusNetworkData()
    private var currentSpeedString: String = "↓ 0B/s  ↑ 0B/s"
    private var carouselTimer: Timer?
    private var carouselToggle: Bool = false

    private init() {
        let width: CGFloat = 340
        let height: CGFloat = 205

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let savedOrigin = SettingsManager.shared.widgetOrigin
        let initialX = savedOrigin?.x ?? (screen.maxX - width - 24)
        let initialY = savedOrigin?.y ?? (screen.maxY - height - 36)

        let window = CustomDraggableWindow(
            contentRect: NSRect(x: initialX, y: initialY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: window)
        setupUI(width: width, height: height)

        NetworkSpeedMonitor.shared.start()
        startSpeedCarousel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(width: CGFloat, height: CGFloat) {
        guard let window = self.window else { return }

        // 毛玻璃背景
        visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1.0
        visualEffectView.layer?.borderColor = NSColor.separatorColor.cgColor

        window.contentView = visualEffectView

        // 顶部小标题栏
        let titleLabel = NSTextField(labelWithString: "合工大校园网")
        titleLabel.frame = NSRect(x: 16, y: height - 28, width: 85, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        visualEffectView.addSubview(titleLabel)

        // 顶部微型实时网速胶囊标签
        speedBadgeLabel = NSTextField(labelWithString: "↓ 0K/s  ↑ 0K/s")
        speedBadgeLabel.frame = NSRect(x: 102, y: height - 28, width: 175, height: 18)
        speedBadgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        speedBadgeLabel.textColor = NSColor.systemTeal
        visualEffectView.addSubview(speedBadgeLabel)

        // 刷新按钮
        let refreshBtn = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新") ?? NSImage(), target: self, action: #selector(refreshClicked))
        refreshBtn.isBordered = false
        refreshBtn.frame = NSRect(x: width - 52, y: height - 28, width: 18, height: 18)
        refreshBtn.toolTip = "立即刷新数据"
        visualEffectView.addSubview(refreshBtn)

        // 关闭按钮
        let closeBtn = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "隐藏") ?? NSImage(), target: self, action: #selector(hideWidget))
        closeBtn.isBordered = false
        closeBtn.frame = NSRect(x: width - 30, y: height - 28, width: 18, height: 18)
        closeBtn.toolTip = "隐藏桌面组件 (可在顶部菜单栏重新开启)"
        visualEffectView.addSubview(closeBtn)

        // 四格卡片区域
        let cardW: CGFloat = 148
        let cardH: CGFloat = 62
        let marginX: CGFloat = 14
        let row1Y: CGFloat = height - 98
        let row2Y: CGFloat = height - 168

        // 卡片 1: 已用流量 (左上)
        let (card1, num1, unit1) = makeMetricCard(
            frame: NSRect(x: marginX, y: row1Y, width: cardW, height: cardH),
            label: "已用流量",
            defaultNum: "--",
            defaultUnit: "M"
        )
        usedFlowNumLabel = num1
        usedFlowUnitLabel = unit1
        visualEffectView.addSubview(card1)

        // 卡片 2: 可用流量 (右上)
        let (card2, num2, unit2) = makeMetricCard(
            frame: NSRect(x: marginX + cardW + 12, y: row1Y, width: cardW, height: cardH),
            label: "可用流量",
            defaultNum: "--",
            defaultUnit: "M"
        )
        availFlowNumLabel = num2
        availFlowUnitLabel = unit2
        visualEffectView.addSubview(card2)

        // 卡片 3: 消费保护 (左下)
        let (card3, num3, unit3) = makeMetricCard(
            frame: NSRect(x: marginX, y: row2Y, width: cardW, height: cardH),
            label: "消费保护",
            defaultNum: "--",
            defaultUnit: "元",
            hasHelpIcon: true
        )
        protNumLabel = num3
        protUnitLabel = unit3
        visualEffectView.addSubview(card3)

        // 卡片 4: 账户余额 (右下)
        let (card4, num4, unit4) = makeMetricCard(
            frame: NSRect(x: marginX + cardW + 12, y: row2Y, width: cardW, height: cardH),
            label: "账户余额",
            defaultNum: "--",
            defaultUnit: "元"
        )
        balNumLabel = num4
        balUnitLabel = unit4
        visualEffectView.addSubview(card4)

        // 底部进度条
        progressBar = NSProgressIndicator(frame: NSRect(x: marginX, y: 19, width: width - marginX * 2, height: 4))
        progressBar.isIndeterminate = false
        progressBar.minValue = 0.0
        progressBar.maxValue = 100.0
        progressBar.doubleValue = 0.0
        visualEffectView.addSubview(progressBar)

        // 底部轮播文本栏：轮播展示更新时间 / 实时上下行网速
        updateTimeLabel = NSTextField(labelWithString: "等待更新...")
        updateTimeLabel.frame = NSRect(x: marginX, y: 3, width: width - marginX * 2, height: 14)
        updateTimeLabel.font = NSFont.systemFont(ofSize: 9.5)
        updateTimeLabel.textColor = .tertiaryLabelColor
        visualEffectView.addSubview(updateTimeLabel)
    }

    private func makeMetricCard(frame: NSRect, label: String, defaultNum: String, defaultUnit: String, hasHelpIcon: Bool = false) -> (NSView, NSTextField, NSTextField) {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor

        if hasHelpIcon {
            let helpImg = NSImageView(frame: NSRect(x: 8, y: frame.height - 20, width: 12, height: 12))
            helpImg.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
            helpImg.contentTintColor = .tertiaryLabelColor
            card.addSubview(helpImg)
        }

        let numLabel = NSTextField(labelWithString: defaultNum)
        numLabel.frame = NSRect(x: 10, y: 22, width: frame.width - 40, height: 28)
        numLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        numLabel.textColor = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 1.0)
        numLabel.alignment = .center
        card.addSubview(numLabel)

        let unitLabel = NSTextField(labelWithString: defaultUnit)
        unitLabel.frame = NSRect(x: frame.width - 32, y: 24, width: 28, height: 16)
        unitLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        unitLabel.textColor = .secondaryLabelColor
        card.addSubview(unitLabel)

        let title = NSTextField(labelWithString: label)
        title.frame = NSRect(x: 0, y: 6, width: frame.width, height: 16)
        title.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        card.addSubview(title)

        return (card, numLabel, unitLabel)
    }

    private func startSpeedCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            self?.renderBottomLabel()
        }
    }

    public func speedMonitorDidUpdate(download: String, upload: String, compact: String) {
        currentSpeedString = "↓ \(download)   ↑ \(upload)"
        speedBadgeLabel?.stringValue = compact
    }

    public func updateData(_ data: CampusNetworkData) {
        currentData = data
        let (usedNum, usedUnit) = splitNumAndUnit(data.usedFlow, fallbackUnit: "M")
        let (availNum, availUnit) = splitNumAndUnit(data.availableFlow, fallbackUnit: "M")
        let (protNum, protUnit) = splitNumAndUnit(data.flowProtection, fallbackUnit: "元")
        let (balNum, balUnit) = splitNumAndUnit(data.balance, fallbackUnit: "元")

        usedFlowNumLabel.stringValue = usedNum
        usedFlowUnitLabel.stringValue = usedUnit

        availFlowNumLabel.stringValue = availNum
        availFlowUnitLabel.stringValue = availUnit

        protNumLabel.stringValue = protNum
        protUnitLabel.stringValue = protUnit

        balNumLabel.stringValue = balNum
        balUnitLabel.stringValue = balUnit

        let percentage = data.usagePercentage * 100.0
        progressBar.doubleValue = min(max(percentage, 0.0), 100.0)

        renderBottomLabel()
    }

    private func renderBottomLabel() {
        carouselToggle.toggle()

        if let err = currentData.errorMessage {
            updateTimeLabel.stringValue = err
            updateTimeLabel.textColor = .systemRed
            return
        }

        if carouselToggle {
            // 轮播屏 A: 实时网络上下行速率
            updateTimeLabel.stringValue = "🚀 实时速率: \(currentSpeedString)"
            updateTimeLabel.textColor = NSColor.systemTeal
        } else {
            // 轮播屏 B: 上次抓取时间与已用百分比
            let timeStr: String
            if let time = currentData.lastUpdated {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                timeStr = "更新于 \(formatter.string(from: time))"
            } else {
                timeStr = "未更新"
            }
            let percentage = currentData.usagePercentage * 100.0
            updateTimeLabel.stringValue = "\(timeStr) · 已用 \(String(format: "%.1f", percentage))%"
            updateTimeLabel.textColor = .tertiaryLabelColor
        }
    }

    private func splitNumAndUnit(_ text: String, fallbackUnit: String) -> (String, String) {
        let pattern = "^([0-9\\.]+)\\s*(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return (text, fallbackUnit)
        }
        let numRange = Range(match.range(at: 1), in: text)
        let unitRange = Range(match.range(at: 2), in: text)
        let num = numRange != nil ? String(text[numRange!]) : text
        let unit = (unitRange != nil && !text[unitRange!].isEmpty) ? String(text[unitRange!]) : fallbackUnit
        return (num, unit)
    }

    @objc private func refreshClicked() {
        CampusNetworkClient.shared.fetchData()
    }

    @objc public func hideWidget() {
        SettingsManager.shared.showDesktopWidget = false
        window?.orderOut(nil)
    }

    public func showWidget() {
        SettingsManager.shared.showDesktopWidget = true
        window?.makeKeyAndOrderFront(nil)
    }

    public func toggleWidget() {
        if window?.isVisible == true {
            hideWidget()
        } else {
            showWidget()
        }
    }
}

class CustomDraggableWindow: NSWindow {
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        SettingsManager.shared.widgetOrigin = self.frame.origin
    }
}
