import Foundation
import AppKit

public class HistoryStatsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = HistoryStatsWindowController()

    private var topBarView: AdaptiveBoxView!
    private var segmentedControl: NSSegmentedControl!
    private var refreshBtn: NSButton!
    private var ssoBtn: NSButton!
    private var settingsBtn: NSButton!
    private var quotaCardView: CampusQuotaCardView!
    private var chartView: HistoryBarChartView!
    private var tableTitleLabel: NSTextField!
    private var scrollTableView: NSScrollView!
    private var tableView: NSTableView!
    private var cardViews: [NSView] = []
    private var cardTitleLabels: [NSTextField] = []
    private var cardValueLabels: [NSTextField] = []
    private var cardSubLabels: [NSTextField] = []

    private var currentMode: Int = 0 // 0: 校园网流量, 1: 宿舍电费
    private var currentFlowRecords: [DailyFlowRecord] = []
    private var currentElectricityRecords: [DailyElectricityRecord] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "校园用量统计与历史分析 - 合肥工业大学"
        window.minSize = NSSize(width: 820, height: 640)
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadData),
            name: .historyStatsDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadData),
            name: .dormElectricityDidUpdate,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // 顶部控制条
        topBarView = AdaptiveBoxView(frame: NSRect(x: 0, y: 780 - 54, width: 880, height: 54))
        topBarView.autoresizingMask = [.width, .minYMargin]
        topBarView.dynamicBackgroundColor = .windowBackgroundColor
        contentView.addSubview(topBarView)

        segmentedControl = NSSegmentedControl(labels: ["校园网流量统计", "宿舍用电与电费"], trackingMode: .selectOne, target: self, action: #selector(onSegmentChanged(_:)))
        segmentedControl.selectedSegment = currentMode
        segmentedControl.frame = NSRect(x: 20, y: 12, width: 260, height: 30)
        topBarView.addSubview(segmentedControl)

        refreshBtn = NSButton(title: "立即刷新", target: self, action: #selector(onRefreshClicked))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.frame = NSRect(x: 770, y: 11, width: 90, height: 30)
        refreshBtn.autoresizingMask = [.minXMargin]
        topBarView.addSubview(refreshBtn)

        ssoBtn = NSButton(title: "统一身份认证同步", target: self, action: #selector(onOpenUnifiedLogin))
        ssoBtn.bezelStyle = .rounded
        ssoBtn.frame = NSRect(x: 620, y: 11, width: 140, height: 30)
        ssoBtn.autoresizingMask = [.minXMargin]
        topBarView.addSubview(ssoBtn)

        settingsBtn = NSButton(title: "宿舍配置...", target: self, action: #selector(onOpenSettings))
        settingsBtn.bezelStyle = .rounded
        settingsBtn.frame = NSRect(x: 500, y: 11, width: 110, height: 30)
        settingsBtn.autoresizingMask = [.minXMargin]
        topBarView.addSubview(settingsBtn)

        // 4 个指标统计卡片
        let cardW: CGFloat = 200
        let cardH: CGFloat = 72
        let gap: CGFloat = 13
        let startX: CGFloat = 20
        let cardY: CGFloat = 780 - 54 - 12 - cardH

        cardViews.removeAll()
        cardTitleLabels.removeAll()
        cardValueLabels.removeAll()
        cardSubLabels.removeAll()

        for i in 0..<4 {
            let card = AdaptiveBoxView(frame: NSRect(x: startX + CGFloat(i) * (cardW + gap), y: cardY, width: cardW, height: cardH))
            card.autoresizingMask = [.minYMargin]
            card.dynamicCornerRadius = 10
            card.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.035)
            card.dynamicBorderColor = NSColor.labelColor.withAlphaComponent(0.10)
            card.dynamicBorderWidth = 1.0

            let titleLabel = NSTextField(labelWithString: "指标")
            titleLabel.frame = NSRect(x: 14, y: cardH - 24, width: cardW - 28, height: 16)
            titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.autoresizingMask = [.width]
            card.addSubview(titleLabel)

            let valLabel = NSTextField(labelWithString: "--")
            valLabel.frame = NSRect(x: 14, y: 20, width: cardW - 28, height: 26)
            valLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
            valLabel.textColor = NSColor.labelColor
            valLabel.autoresizingMask = [.width]
            card.addSubview(valLabel)

            let subLabel = NSTextField(labelWithString: "--")
            subLabel.frame = NSRect(x: 14, y: 4, width: cardW - 28, height: 14)
            subLabel.font = NSFont.systemFont(ofSize: 10)
            subLabel.textColor = .tertiaryLabelColor
            subLabel.autoresizingMask = [.width]
            card.addSubview(subLabel)

            contentView.addSubview(card)
            cardViews.append(card)
            cardTitleLabels.append(titleLabel)
            cardValueLabels.append(valLabel)
            cardSubLabels.append(subLabel)
        }

        // 套餐限额进度条卡片 (单日 30GB / 月度 200GB免费·400GB上限 / 3终端同时在线)
        let quotaY: CGFloat = cardY - 148
        quotaCardView = CampusQuotaCardView(frame: NSRect(x: 20, y: quotaY, width: 840, height: 138))
        quotaCardView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(quotaCardView)

        // 中间图表区域
        let chartY: CGFloat = quotaY - 196
        chartView = HistoryBarChartView(frame: NSRect(x: 20, y: chartY, width: 840, height: 184))
        chartView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(chartView)

        // 底部历史明细表格标题（必须添加 .minYMargin 并随窗口高度同步计算，防止缩放时浮到柱状图中央）
        tableTitleLabel = NSTextField(labelWithString: "历史详细记录")
        tableTitleLabel.frame = NSRect(x: 20, y: chartY - 26, width: 200, height: 18)
        tableTitleLabel.autoresizingMask = [.minYMargin]
        tableTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        tableTitleLabel.textColor = .secondaryLabelColor
        contentView.addSubview(tableTitleLabel)

        scrollTableView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 840, height: chartY - 34 - 20))
        scrollTableView.autoresizingMask = [.width, .height]
        scrollTableView.hasVerticalScroller = true
        scrollTableView.borderType = .bezelBorder

        tableView = NSTableView(frame: scrollTableView.bounds)
        tableView.autoresizingMask = [.width, .height]
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true

        scrollTableView.documentView = tableView
        contentView.addSubview(scrollTableView)

        layoutSubviewsForCurrentBounds()
        reloadData()
    }

    public func windowDidResize(_ notification: Notification) {
        layoutSubviewsForCurrentBounds()
    }

    private func layoutSubviewsForCurrentBounds() {
        guard let contentView = window?.contentView else { return }
        let totalW = contentView.bounds.width
        let totalH = contentView.bounds.height
        let sidePad: CGFloat = 20
        let contentW = max(780, totalW - sidePad * 2)

        topBarView?.frame = NSRect(x: 0, y: totalH - 54, width: totalW, height: 54)
        refreshBtn?.frame = NSRect(x: totalW - sidePad - 90, y: 11, width: 90, height: 30)
        ssoBtn?.frame = NSRect(x: totalW - sidePad - 90 - 10 - 140, y: 11, width: 140, height: 30)
        settingsBtn?.frame = NSRect(x: totalW - sidePad - 90 - 10 - 140 - 10 - 110, y: 11, width: 110, height: 30)

        let cardH: CGFloat = 72
        let gap: CGFloat = 13
        let cardW = floor((contentW - gap * 3) / 4.0)
        let cardY = totalH - 54 - 12 - cardH
        for (i, card) in cardViews.enumerated() {
            card.frame = NSRect(x: sidePad + CGFloat(i) * (cardW + gap), y: cardY, width: cardW, height: cardH)
        }

        let quotaH: CGFloat = 138
        let quotaY = cardY - 10 - quotaH
        quotaCardView?.frame = NSRect(x: sidePad, y: quotaY, width: contentW, height: quotaH)

        let chartH: CGFloat = 184
        let chartY = quotaY - 12 - chartH
        chartView?.frame = NSRect(x: sidePad, y: chartY, width: contentW, height: chartH)

        let titleY = chartY - 26
        tableTitleLabel?.frame = NSRect(x: sidePad, y: titleY, width: 200, height: 18)

        let tableBottom: CGFloat = 20
        let tableHeight = max(80, titleY - 8 - tableBottom)
        scrollTableView?.frame = NSRect(x: sidePad, y: tableBottom, width: contentW, height: tableHeight)
    }

    public func showWindow(mode: Int) {
        currentMode = mode
        if let seg = segmentedControl {
            seg.selectedSegment = mode
        }
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reloadData()

        // 自动拉取最新数据，避免显示空值或 -- 元
        if currentMode == 1 || ElectricityService.shared.latestData == nil {
            ElectricityService.shared.fetchData { [weak self] _ in
                self?.reloadData()
            }
        }
        if currentMode == 0 || currentFlowRecords.isEmpty {
            CampusNetworkClient.shared.fetchData()
            CampusNetworkClient.shared.fetchOnlineDevices()
        }
    }

    public override func showWindow(_ sender: Any?) {
        showWindow(mode: currentMode)
    }

    @objc private func onSegmentChanged(_ sender: NSSegmentedControl) {
        currentMode = sender.selectedSegment
        reloadData()
        if currentMode == 1 && ElectricityService.shared.latestData == nil {
            ElectricityService.shared.fetchData { [weak self] _ in
                self?.reloadData()
            }
        }
    }

    @objc private func onRefreshClicked() {
        CampusNetworkClient.shared.fetchData()
        CampusNetworkClient.shared.fetchOnlineDevices()
        ElectricityService.shared.fetchData { [weak self] _ in
            self?.reloadData()
        }
    }

    @objc private func onOpenUnifiedLogin() {
        UnifiedLoginWebViewController.shared.showLoginWindow()
    }

    @objc private func onOpenSettings() {
        SettingsWindowController.shared.showSettings()
    }

    @objc public func reloadData() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentFlowRecords = CampusHistoryManager.shared.getPastDaysFlowRecords(days: 90).reversed()
            self.currentElectricityRecords = CampusHistoryManager.shared.getPastDaysElectricityRecords(days: 90).reversed()

            self.updateCards()
            self.quotaCardView.refresh(mode: self.currentMode)
            self.updateChart()
            self.setupTableColumns()
            self.tableView.reloadData()
        }
    }

    private func updateCards() {
        if currentMode == 0 {
            // 校园网流量模式
            setCard(index: 0, title: "今日新增用量", value: formatMB(CampusHistoryManager.shared.todayFlowDeltaMB), sub: "今日产生流量消耗", color: NSColor.systemBlue)
            setCard(index: 1, title: "近 7 天累计消耗", value: formatMB(CampusHistoryManager.shared.past7DaysFlowTotalMB), sub: "近一周网络流量总计", color: NSColor.systemIndigo)
            setCard(index: 2, title: "近 7 天日均消耗", value: formatMB(CampusHistoryManager.shared.past7DaysFlowDailyAverageMB) + "/天", sub: "每日平均使用水平", color: NSColor.systemTeal)

            let netData = CampusNetworkClient.shared.latestData
            let balText: String
            if netData.balance != "-- 元" && !netData.balance.isEmpty {
                balText = netData.balance
            } else if let lastBal = currentFlowRecords.first?.balanceRMB {
                balText = String(format: "%.2f 元", lastBal)
            } else {
                balText = "-- 元"
            }
            let monthlyUsedStr: String
            if let usedMB = netData.usedMB {
                monthlyUsedStr = "本月累计已用 \(formatMB(usedMB))"
            } else if let lastUsed = CampusHistoryManager.shared.currentMonthUsedFlowMB {
                monthlyUsedStr = "本月累计已用 \(formatMB(lastUsed))"
            } else {
                monthlyUsedStr = "校园网账户实时余额"
            }
            setCard(index: 3, title: "校园网账户余额", value: balText, sub: monthlyUsedStr, color: NSColor.systemGreen)
        } else {
            // 宿舍电费模式
            if !SettingsManager.shared.isDormConfigured {
                setCard(index: 0, title: "当前剩余电费", value: "未配置", sub: "请先在「设置」中填写楼栋与房间号", color: NSColor.systemGray)
                setCard(index: 1, title: "今日消耗电费", value: "--", sub: "配置宿舍后可查看", color: NSColor.systemGray)
                setCard(index: 2, title: "近 7 天日均支出", value: "--", sub: "配置宿舍后可查看", color: NSColor.systemGray)
                setCard(index: 3, title: "预计可用天数", value: "--", sub: "配置宿舍后可查看", color: NSColor.systemGray)
                return
            }
            let elec = ElectricityService.shared.latestData
            let fallbackElec = currentElectricityRecords.first
            let balRMB = elec?.balanceRMB ?? fallbackElec?.balanceRMB
            let kwhVal = elec?.remainingKWh ?? fallbackElec?.remainingKWh
            let isLow = (balRMB != nil && balRMB! < 20.0)
            let balStr = elec?.displayBalance ?? (balRMB != nil ? String(format: "%.2f 元", balRMB!) : "获取中...")
            let balColor = isLow ? NSColor.systemRed : NSColor.systemOrange
            let powerStr = elec?.displayPower ?? (kwhVal != nil ? String(format: "剩余 %.1f 度", kwhVal!) : "正在查询电量...")
            let warnText = isLow ? "⚠️ 余额偏低，请及时充值" : powerStr
            setCard(index: 0, title: "当前剩余电费", value: balStr, sub: warnText, color: balColor)

            let todayCost = CampusHistoryManager.shared.todayElectricityCostRMB
            let todayKWh = CampusHistoryManager.shared.todayElectricityUsedKWh
            setCard(index: 1, title: "今日消耗电费", value: String(format: "%.2f 元", todayCost), sub: "今日用电约 \(String(format: "%.1f", todayKWh)) 度", color: NSColor.systemPurple)

            let dailyAvg = CampusHistoryManager.shared.past7DaysElectricityDailyAverageCostRMB
            setCard(index: 2, title: "近 7 天日均支出", value: String(format: "%.2f 元/天", dailyAvg), sub: "基于一周消费模型测算", color: NSColor.systemBrown)

            let daysLeft = CampusHistoryManager.shared.estimatedElectricityDaysRemaining
            let daysStr = daysLeft != nil ? "约 \(daysLeft!) 天" : "测算中..."
            setCard(index: 3, title: "预计可用天数", value: daysStr, sub: "智能预测电费耗尽时间", color: NSColor.systemGreen)
        }
    }

    private func setCard(index: Int, title: String, value: String, sub: String, color: NSColor) {
        guard index < cardViews.count else { return }
        cardTitleLabels[index].stringValue = title
        cardValueLabels[index].stringValue = value
        cardValueLabels[index].textColor = color
        cardSubLabels[index].stringValue = sub
    }

    private func updateChart() {
        if currentMode == 0 {
            let records = CampusHistoryManager.shared.getPastDaysFlowRecords(days: 7)
            let items: [BarChartItem] = records.map {
                let shortDate = String($0.dateString.suffix(5))
                return BarChartItem(label: shortDate, value: max(0.0, $0.dailyDeltaMB), displayValue: formatMB($0.dailyDeltaMB))
            }
            chartView.setData(items: items, barColor: NSColor.systemBlue, unit: "MB")
        } else {
            let records = CampusHistoryManager.shared.getPastDaysElectricityRecords(days: 7)
            let items: [BarChartItem] = records.map {
                let shortDate = String($0.dateString.suffix(5))
                return BarChartItem(label: shortDate, value: max(0.0, $0.dailyCostRMB), displayValue: String(format: "%.2f元", $0.dailyCostRMB))
            }
            chartView.setData(items: items, barColor: NSColor.systemOrange, unit: "元")
        }
    }

    private func setupTableColumns() {
        guard let tv = tableView else { return }
        // 关键防护：在移除和重新添加列前，临时解除代理与数据源，彻底杜绝 re-entrant viewForTableColumn 越界崩溃！
        tv.dataSource = nil
        tv.delegate = nil

        while !tv.tableColumns.isEmpty {
            tv.removeTableColumn(tv.tableColumns.last!)
        }

        if currentMode == 0 {
            let cols: [(String, String, CGFloat)] = [
                ("date", "日期", 120),
                ("delta", "今日新增用量", 145),
                ("total", "当月累计已用", 145),
                ("avail", "月免费剩余 (200G)", 145),
                ("bal", "校园网余额", 130),
                ("time", "更新时间", 125)
            ]
            for (cid, ctitle, w) in cols {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cid))
                col.title = ctitle
                col.width = w
                tv.addTableColumn(col)
            }
        } else {
            let cols: [(String, String, CGFloat)] = [
                ("date", "日期", 120),
                ("cost", "当日消耗电费", 145),
                ("kwh", "当日用电度数", 135),
                ("bal", "最新剩余电费", 145),
                ("remKwh", "剩余度数", 130),
                ("time", "更新时间", 130)
            ]
            for (cid, ctitle, w) in cols {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cid))
                col.title = ctitle
                col.width = w
                tv.addTableColumn(col)
            }
        }

        tv.dataSource = self
        tv.delegate = self
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if currentMode == 0 {
            return currentFlowRecords.count
        } else {
            return currentElectricityRecords.count
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let cid = col.identifier.rawValue

        let cell = (tableView.makeView(withIdentifier: col.identifier, owner: self) as? NSTextField) ?? {
            let tf = NSTextField(labelWithString: "")
            tf.identifier = col.identifier
            tf.isEditable = false
            tf.isBordered = false
            tf.backgroundColor = .clear
            tf.font = NSFont.systemFont(ofSize: 11.5)
            tf.alignment = .left
            return tf
        }()

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        if currentMode == 0 {
            guard row >= 0 && row < currentFlowRecords.count else { return nil }
            let record = currentFlowRecords[row]

            switch cid {
            case "date": cell.stringValue = record.dateString
            case "delta": cell.stringValue = record.formattedDailyDelta
            case "total": cell.stringValue = formatMB(record.totalUsedMB)
            case "avail":
                let freeRemMB = max(0.0, 200.0 * 1024.0 - record.totalUsedMB)
                cell.stringValue = formatMB(freeRemMB)
            case "bal": cell.stringValue = record.balanceRMB != nil ? String(format: "%.2f 元", record.balanceRMB!) : "--"
            case "time": cell.stringValue = timeFormatter.string(from: record.lastUpdated)
            default: break
            }
        } else {
            guard row >= 0 && row < currentElectricityRecords.count else { return nil }
            let record = currentElectricityRecords[row]

            switch cid {
            case "date": cell.stringValue = record.dateString
            case "cost": cell.stringValue = record.formattedDailyCost
            case "kwh": cell.stringValue = record.formattedDailyKWh
            case "bal": cell.stringValue = String(format: "%.2f 元", record.balanceRMB)
            case "remKwh": cell.stringValue = record.remainingKWh != nil ? String(format: "%.1f 度", record.remainingKWh!) : "--"
            case "time": cell.stringValue = timeFormatter.string(from: record.lastUpdated)
            default: break
            }
        }

        return cell
    }

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }
}

// MARK: - 自定义高精绘图柱状图控件

public struct BarChartItem {
    public let label: String
    public let value: Double
    public let displayValue: String
}

public class HistoryBarChartView: NSView {
    private var items: [BarChartItem] = []
    private var barColor: NSColor = .systemBlue
    private var unit: String = ""

    public func setData(items: [BarChartItem], barColor: NSColor, unit: String) {
        self.items = items
        self.barColor = barColor
        self.unit = unit
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 背景卡片
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.withAlphaComponent(0.4).setFill()
        bgPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
        bgPath.lineWidth = 0.5
        bgPath.stroke()

        guard !items.isEmpty else {
            let emptyText = "暂无充足历史统计数据，系统将随日常使用自动积累"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = emptyText.size(withAttributes: attrs)
            let pt = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            emptyText.draw(at: pt, withAttributes: attrs)
            return
        }

        let maxVal = max(items.map { $0.value }.max() ?? 0.1, 0.05)
        let chartBottom: CGFloat = 30
        let chartTop: CGFloat = bounds.height - 30
        let chartHeight = max(10.0, chartTop - chartBottom)
        let count = max(1, items.count)
        let barWidth: CGFloat = min(42.0, max(8.0, (bounds.width - 60) / CGFloat(count * 2)))
        let slotWidth = (bounds.width - 40) / CGFloat(count)

        // 绘制刻度参考虚线
        context.saveGState()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        context.setLineDash(phase: 0, lengths: [4, 4])
        for step in 1...3 {
            let y = chartBottom + chartHeight * CGFloat(step) / 3.0
            context.move(to: CGPoint(x: 20, y: y))
            context.addLine(to: CGPoint(x: bounds.width - 20, y: y))
        }
        context.strokePath()
        context.restoreGState()

        for (i, item) in items.enumerated() {
            let centerX = 20 + slotWidth * CGFloat(i) + slotWidth / 2
            let barX = centerX - barWidth / 2
            let ratio = max(0.0, CGFloat(item.value / maxVal))
            let bH = max(4.0, chartHeight * ratio)
            let barRect = NSRect(x: barX, y: chartBottom, width: barWidth, height: bH)

            // 绘制渐变圆角柱子
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4)
            let gradient = NSGradient(starting: barColor.withAlphaComponent(0.75), ending: barColor)
            gradient?.draw(in: barPath, angle: 90)

            // 柱顶数值
            let valStr = item.displayValue
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let vSize = valStr.size(withAttributes: valAttrs)
            valStr.draw(at: NSPoint(x: centerX - vSize.width / 2, y: chartBottom + bH + 4), withAttributes: valAttrs)

            // 底部日期
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let dSize = item.label.size(withAttributes: dateAttrs)
            item.label.draw(at: NSPoint(x: centerX - dSize.width / 2, y: 10), withAttributes: dateAttrs)
        }
    }
}

/// 套餐限额进度条卡片（单日限额 30GB + 每月限额 200GB免费/400GB上限 + 3终端同时在线）
public class CampusQuotaCardView: NSView {
    private var mode: Int = 0
    public var isCompactMenuMode: Bool = false

    public func refresh(mode: Int = 0) {
        self.mode = mode
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 外框圆角容器
        let radius: CGFloat = isCompactMenuMode ? 8 : 10
        let insetBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bgPath = NSBezierPath(roundedRect: insetBounds, xRadius: radius, yRadius: radius)
        if isCompactMenuMode {
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            bgPath.fill()
            NSColor.separatorColor.withAlphaComponent(0.22).setStroke()
            bgPath.lineWidth = 0.5
            bgPath.stroke()
        } else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.65).setFill()
            bgPath.fill()
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            bgPath.lineWidth = 0.8
            bgPath.stroke()
        }

        let padX: CGFloat = isCompactMenuMode ? 12 : 18

        // 顶部说明标题
        if !isCompactMenuMode {
            let headerStr = (mode == 0)
                ? "套餐限额  ·  访问校内资源免费；校外资源日限 30GB、月限 400GB（每月前 200GB 免费，超出 0.5元/GB）；最多 3 个终端同时在线"
                : "宿舍用电限额与续航预估  ·  基于近期日均用电量动态测算剩余电费可用比例"
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            headerStr.draw(at: NSPoint(x: padX, y: bounds.height - 24), withAttributes: headerAttrs)
        }

        if mode == 0 {
            // 1. 单日限额 (30 GB = 30720 MB)
            let dailyLimitMB = 30.0 * 1024.0
            let dailyUsedMB = max(0.0, CampusHistoryManager.shared.todayFlowDeltaMB)
            let dailyRemainRatio = max(0.0, min(1.0, (dailyLimitMB - dailyUsedMB) / dailyLimitMB))
            let dailyRemainPct = Int(round(dailyRemainRatio * 100))
            let dailyUsedGBStr = String(format: "%.2f GB", dailyUsedMB / 1024.0)
            let dailySubLeft = isCompactMenuMode
                ? "\(CampusHistoryManager.shared.dailyResetCountdownString) · 已用 \(dailyUsedGBStr)"
                : "\(CampusHistoryManager.shared.dailyResetCountdownString)  ·  已用 \(dailyUsedGBStr) / 30 GB"
            let dailySubRight = "剩余 \(dailyRemainPct)%"

            // 2. 每月限额 (前 200 GB 免费，月总限额 400 GB)
            let netData = CampusNetworkClient.shared.latestData
            let fallbackUsedMB = CampusHistoryManager.shared.currentMonthUsedFlowMB ?? 0.0
            let monthlyUsedMB = max(0.0, netData.usedMB ?? fallbackUsedMB)
            let freeLimitMB = 200.0 * 1024.0
            let maxLimitMB = 400.0 * 1024.0

            let monthlyTitle: String
            let monthlySubLeft: String
            let monthlySubRight: String
            let monthlyRemainRatio: Double

            let onlineCount = netData.onlineDevices.count
            let onlineBadge = isCompactMenuMode ? " · \(onlineCount)/3 台在线" : "  (当前在线 \(onlineCount)/3 台终端)"

            if monthlyUsedMB <= freeLimitMB {
                monthlyRemainRatio = max(0.0, min(1.0, (freeLimitMB - monthlyUsedMB) / freeLimitMB))
                let pct = Int(round(monthlyRemainRatio * 100))
                let usedGB = String(format: "%.2f GB", monthlyUsedMB / 1024.0)
                monthlyTitle = isCompactMenuMode
                    ? "每月限额 (200 GB 免费 / 400 GB\(onlineBadge))"
                    : "每月免费限额 (200 GB 免费 / 月上限 400 GB)\(onlineBadge)"
                monthlySubLeft = isCompactMenuMode
                    ? "\(CampusHistoryManager.shared.monthlyResetCountdownString) · 已用 \(usedGB)"
                    : "\(CampusHistoryManager.shared.monthlyResetCountdownString)  ·  已用 \(usedGB) / 200 GB 免费额度"
                monthlySubRight = "剩余 \(pct)%"
            } else {
                monthlyRemainRatio = max(0.0, min(1.0, (maxLimitMB - monthlyUsedMB) / maxLimitMB))
                let pct = Int(round(monthlyRemainRatio * 100))
                let usedGB = monthlyUsedMB / 1024.0
                let extraGB = max(0.0, usedGB - 200.0)
                let extraFee = extraGB * 0.5
                monthlyTitle = isCompactMenuMode
                    ? "每月限额 (400 GB 上限 · 0.5 元/G\(onlineBadge))"
                    : "每月总限额 (400 GB 上限 · 超出 0.5元/GB)\(onlineBadge)"
                monthlySubLeft = isCompactMenuMode
                    ? String(format: "%@ · 已用 %.1f G (超 %.1f G)", CampusHistoryManager.shared.monthlyResetCountdownString, usedGB, extraGB)
                    : String(format: "%@  ·  已用 %.2f GB (超免费 %.1f GB ≈ ¥%.2f)", CampusHistoryManager.shared.monthlyResetCountdownString, usedGB, extraGB, extraFee)
                monthlySubRight = "剩余 \(pct)%"
            }

            let row1Y: CGFloat = isCompactMenuMode ? bounds.height - 50 : bounds.height - 68
            let row2Y: CGFloat = isCompactMenuMode ? 10 : 14

            drawQuotaRow(
                y: row1Y,
                padX: padX,
                title: "单日限额 (30 GB)",
                subLeft: dailySubLeft,
                subRight: dailySubRight,
                remainRatio: dailyRemainRatio
            )

            drawQuotaRow(
                y: row2Y,
                padX: padX,
                title: monthlyTitle,
                subLeft: monthlySubLeft,
                subRight: monthlySubRight,
                remainRatio: monthlyRemainRatio
            )
        } else {
            // 宿舍电费模式下的进度展示
            let elec = ElectricityService.shared.latestData
            let fallbackElec = CampusHistoryManager.shared.getPastDaysElectricityRecords(days: 30).last
            let bal = elec?.balanceRMB ?? fallbackElec?.balanceRMB ?? 0.0
            let kwh = elec?.remainingKWh ?? fallbackElec?.remainingKWh
            let balDisplay = elec?.displayBalance ?? (fallbackElec != nil ? String(format: "%.2f 元", fallbackElec!.balanceRMB) : "--")
            let pwrDisplay = elec?.displayPower ?? (kwh != nil ? String(format: "剩余 %.1f 度", kwh!) : "--")
            let ratio = max(0.0, min(1.0, bal / 200.0))
            let pct = Int(round(ratio * 100))
            let daysLeft = CampusHistoryManager.shared.estimatedElectricityDaysRemaining ?? 0

            drawQuotaRow(
                y: bounds.height - 68,
                padX: padX,
                title: "宿舍电费余额充裕度 (按 200 元满额基准)",
                subLeft: "当前余额 \(balDisplay)  ·  \(pwrDisplay)",
                subRight: "充裕度 \(pct)%",
                remainRatio: ratio
            )

            let dayRatio = max(0.0, min(1.0, Double(daysLeft) / 60.0))
            drawQuotaRow(
                y: 14,
                padX: padX,
                title: "预计续航周期 (按 60 天满周期基准)",
                subLeft: "近 7 天日均消费 \(String(format: "%.2f", CampusHistoryManager.shared.past7DaysElectricityDailyAverageCostRMB)) 元/天",
                subRight: daysLeft > 0 ? "约余 \(daysLeft) 天" : "测算中",
                remainRatio: dayRatio
            )
        }
    }

    private func drawQuotaRow(
        y: CGFloat,
        padX: CGFloat,
        title: String,
        subLeft: String,
        subRight: String,
        remainRatio: Double
    ) {
        let totalW = bounds.width - padX * 2

        // 标题行
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isCompactMenuMode ? 11.5 : 13.0, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        title.draw(at: NSPoint(x: padX, y: y + (isCompactMenuMode ? 24 : 26)), withAttributes: titleAttrs)

        // 副标题左（重置时间）与右（剩余百分比）
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: isCompactMenuMode ? 10.5 : 11.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        subLeft.draw(at: NSPoint(x: padX, y: y + (isCompactMenuMode ? 8 : 10)), withAttributes: subAttrs)

        let rightSize = subRight.size(withAttributes: subAttrs)
        subRight.draw(at: NSPoint(x: padX + totalW - rightSize.width, y: y + (isCompactMenuMode ? 8 : 10)), withAttributes: subAttrs)

        // 进度条轨道
        let barH: CGFloat = isCompactMenuMode ? 5.0 : 6.0
        let trackRect = NSRect(x: padX, y: y, width: totalW, height: barH)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: barH / 2, yRadius: barH / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.45).setFill()
        trackPath.fill()

        // 进度条填充（长度对应剩余额度占比）
        let fillW = max(barH, totalW * CGFloat(max(0.0, min(1.0, remainRatio))))
        let fillRect = NSRect(x: padX, y: y, width: fillW, height: barH)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barH / 2, yRadius: barH / 2)
        let fillColor: NSColor = remainRatio < 0.15
            ? .systemRed
            : (remainRatio < 0.3 ? .systemOrange : NSColor.labelColor.withAlphaComponent(0.78))
        fillColor.setFill()
        fillPath.fill()
    }
}
