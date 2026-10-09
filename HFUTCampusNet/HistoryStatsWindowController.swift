import Foundation
import AppKit

public class HistoryStatsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = HistoryStatsWindowController()

    private var segmentedControl: NSSegmentedControl!
    private var chartView: HistoryBarChartView!
    private var tableView: NSTableView!
    private var cardViews: [NSView] = []
    private var cardValueLabels: [NSTextField] = []
    private var cardSubLabels: [NSTextField] = []

    private var currentMode: Int = 0 // 0: 校园网流量, 1: 宿舍电费
    private var currentFlowRecords: [DailyFlowRecord] = []
    private var currentElectricityRecords: [DailyElectricityRecord] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "校园用量统计与历史分析 - 合肥工业大学"
        window.center()
        super.init(window: window)
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
        let topBar = NSView(frame: NSRect(x: 0, y: 640 - 54, width: 880, height: 54))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView.addSubview(topBar)

        segmentedControl = NSSegmentedControl(labels: ["📶 校园网流量统计", "⚡ 宿舍用电与电费"], trackingMode: .selectOne, target: self, action: #selector(onSegmentChanged(_:)))
        segmentedControl.selectedSegment = currentMode
        segmentedControl.frame = NSRect(x: 20, y: 12, width: 280, height: 30)
        topBar.addSubview(segmentedControl)

        let refreshBtn = NSButton(title: "立即刷新", target: self, action: #selector(onRefreshClicked))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.frame = NSRect(x: 770, y: 11, width: 90, height: 30)
        topBar.addSubview(refreshBtn)

        let ssoBtn = NSButton(title: "统一身份认证同步", target: self, action: #selector(onOpenUnifiedLogin))
        ssoBtn.bezelStyle = .rounded
        ssoBtn.frame = NSRect(x: 480, y: 11, width: 140, height: 30)
        topBar.addSubview(ssoBtn)

        let settingsBtn = NSButton(title: "⚙️ 宿舍配置", target: self, action: #selector(onOpenSettings))
        settingsBtn.bezelStyle = .rounded
        settingsBtn.frame = NSRect(x: 330, y: 11, width: 110, height: 30)
        topBar.addSubview(settingsBtn)

        // 4 个指标统计卡片
        let cardW: CGFloat = 200
        let cardH: CGFloat = 72
        let gap: CGFloat = 13
        let startX: CGFloat = 20
        let cardY: CGFloat = 640 - 54 - 12 - cardH

        cardViews.removeAll()
        cardValueLabels.removeAll()
        cardSubLabels.removeAll()

        for i in 0..<4 {
            let card = NSView(frame: NSRect(x: startX + CGFloat(i) * (cardW + gap), y: cardY, width: cardW, height: cardH))
            card.autoresizingMask = [.minYMargin]
            card.wantsLayer = true
            card.layer?.cornerRadius = 10
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
            card.layer?.borderWidth = 0.5
            card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor

            let titleLabel = NSTextField(labelWithString: "指标")
            titleLabel.frame = NSRect(x: 14, y: cardH - 24, width: cardW - 28, height: 16)
            titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            titleLabel.textColor = .secondaryLabelColor
            card.addSubview(titleLabel)

            let valLabel = NSTextField(labelWithString: "--")
            valLabel.frame = NSRect(x: 14, y: 20, width: cardW - 28, height: 26)
            valLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
            valLabel.textColor = NSColor.labelColor
            card.addSubview(valLabel)

            let subLabel = NSTextField(labelWithString: "--")
            subLabel.frame = NSRect(x: 14, y: 4, width: cardW - 28, height: 14)
            subLabel.font = NSFont.systemFont(ofSize: 10)
            subLabel.textColor = .tertiaryLabelColor
            card.addSubview(subLabel)

            contentView.addSubview(card)
            cardViews.append(card)
            cardValueLabels.append(valLabel)
            cardSubLabels.append(subLabel)
        }

        // 中间图表区域
        let chartY: CGFloat = cardY - 210
        chartView = HistoryBarChartView(frame: NSRect(x: 20, y: chartY, width: 840, height: 198))
        chartView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(chartView)

        // 底部历史明细表格
        let tableTitle = NSTextField(labelWithString: "历史详细记录")
        tableTitle.frame = NSRect(x: 20, y: chartY - 26, width: 200, height: 18)
        tableTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        tableTitle.textColor = .secondaryLabelColor
        contentView.addSubview(tableTitle)

        let scrollTable = NSScrollView(frame: NSRect(x: 20, y: 20, width: 840, height: chartY - 34 - 20))
        scrollTable.autoresizingMask = [.width, .height]
        scrollTable.hasVerticalScroller = true
        scrollTable.borderType = .bezelBorder

        tableView = NSTableView(frame: scrollTable.bounds)
        tableView.autoresizingMask = [.width, .height]
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true

        scrollTable.documentView = tableView
        contentView.addSubview(scrollTable)

        reloadData()
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

            let peak = currentFlowRecords.map { $0.peakSpeedMBs }.max() ?? 0.0
            setCard(index: 3, title: "近日峰值网速", value: String(format: "%.2f MB/s", peak), sub: "网络传输峰值测速", color: NSColor.systemGreen)
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
            let balStr = elec?.displayBalance ?? "获取中..."
            let balColor = (elec?.isLowBalance == true) ? NSColor.systemRed : NSColor.systemOrange
            let warnText = (elec?.isLowBalance == true) ? "⚠️ 余额偏低，请及时充值" : (elec?.displayPower ?? "正在查询电量...")
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
        if let tLabel = cardViews[index].subviews.first as? NSTextField {
            tLabel.stringValue = title
        }
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
                ("date", "日期", 100),
                ("delta", "今日新增用量", 130),
                ("total", "累计已用流量", 130),
                ("avail", "剩余可用流量", 130),
                ("bal", "校园网余额", 110),
                ("peak", "峰值网速", 110),
                ("time", "更新时间", 120)
            ]
            for (cid, ctitle, w) in cols {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cid))
                col.title = ctitle
                col.width = w
                tv.addTableColumn(col)
            }
        } else {
            let cols: [(String, String, CGFloat)] = [
                ("date", "日期", 100),
                ("cost", "当日消耗电费", 140),
                ("kwh", "当日用电度数", 130),
                ("bal", "最新剩余电费", 140),
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
            case "avail": cell.stringValue = record.availableMB != nil ? formatMB(record.availableMB!) : "--"
            case "bal": cell.stringValue = record.balanceRMB != nil ? String(format: "%.2f 元", record.balanceRMB!) : "--"
            case "peak": cell.stringValue = String(format: "%.2f MB/s", record.peakSpeedMBs)
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

        let maxVal = max(items.map { $0.value }.max() ?? 1.0, 1.0)
        let chartBottom: CGFloat = 30
        let chartTop: CGFloat = bounds.height - 30
        let chartHeight = max(10.0, chartTop - chartBottom)
        let count = max(1, items.count)
        let barWidth: CGFloat = min(42.0, max(8.0, (bounds.width - 60) / CGFloat(count * 2)))
        let slotWidth = (bounds.width - 40) / CGFloat(count)

        // 绘制刻度参考虚线
        context.saveGState()
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.25).cgColor)
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
