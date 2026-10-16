import Foundation
import AppKit

public class HistoryStatsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = HistoryStatsWindowController()

    private var topBarView: AdaptiveBoxView!
    private var segmentedControl: NSSegmentedControl!
    private var refreshBtn: NSButton!
    private var ehallBtn: NSButton!
    private var libraryBtn: NSButton!
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

    private var currentMode: Int = 0 // 0: 校园网流量, 1: 宿舍电费, 2: 校园卡, 3: EHALL综合画像
    private var currentEhallDomain: Int = 1 // 0: 餐饮消费, 1: 学业成就, 2: 综合素养
    private var currentEhallSubIndex: Int = 0 // 当前分类下的子项索引
    private var ehallDomainSegment: NSSegmentedControl!
    private var ehallSubSegment: NSSegmentedControl!

    private var currentEhallSubMode: Int {
        switch currentEhallDomain {
        case 0:
            switch currentEhallSubIndex {
            case 0: return 0 // 消费档口
            case 1: return 1 // 就餐频次
            case 2: return 2 // 月度日度
            default: return 6 // 学年总览
            }
        case 1:
            switch currentEhallSubIndex {
            case 0: return 3 // 学分绩点
            case 1: return 4 // 课程成绩
            default: return 7 // 荣誉表彰
            }
        case 2:
            switch currentEhallSubIndex {
            case 0: return 8 // 志愿公益
            case 1: return 9 // 体质健康
            case 2: return 5 // 第二课堂
            default: return 10 // 图书自习
            }
        default:
            return 3
        }
    }
    private var currentFlowRecords: [DailyFlowRecord] = []
    private var currentElectricityRecords: [DailyElectricityRecord] = []
    private var currentCardTransactions: [CampusCardTransaction] = []
    private var currentEhallData: StudentPortraitEatData?

    private struct GPARowItem {
        let semester: String
        let credits: String
        let gpa: String
        let avgGpa: String
        let status: String
        let isHighlight: Bool
    }

    private struct CourseRowItem {
        let category: String
        let courseName: String
        let score: String
        let extremes: String
        let status: String
        let isHighlight: Bool
    }

    private struct SecondClassRowItem {
        let module: String
        let scope: String
        let stars: String
        let standard: String
        let evaluation: String
        let isHighlight: Bool
    }

    private struct AwardRowItem {
        let level: String
        let name: String
        let count: String
        let money: String
        let status: String
        let isHighlight: Bool
    }

    private struct VolunteerRowItem {
        let module: String
        let scope: String
        let personal: String
        let average: String
        let evaluation: String
        let isHighlight: Bool
    }

    private struct HealthRowItem {
        let year: String
        let item: String
        let score: String
        let average: String
        let evaluation: String
        let isHighlight: Bool
    }

    private struct LibraryRowItem {
        let category: String
        let scope: String
        let value: String
        let benchmark: String
        let evaluation: String
        let isHighlight: Bool
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "校园用量统计与历史分析 - 合肥工业大学"
        window.minSize = NSSize(width: 980, height: 640)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadData),
            name: .campusCardDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadData),
            name: .studentPortraitDidUpdate,
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
        topBarView = AdaptiveBoxView(frame: NSRect(x: 0, y: 780 - 54, width: 1080, height: 54))
        topBarView.autoresizingMask = [.width, .minYMargin]
        topBarView.dynamicBackgroundColor = .windowBackgroundColor
        contentView.addSubview(topBarView)

        segmentedControl = NSSegmentedControl(labels: ["校园网流量统计", "宿舍用电与电费", "校园卡与消费账单", "EHALL综合画像"], trackingMode: .selectOne, target: self, action: #selector(onSegmentChanged(_:)))
        segmentedControl.selectedSegment = currentMode
        segmentedControl.frame = NSRect(x: 20, y: 12, width: 520, height: 30)
        topBarView.addSubview(segmentedControl)

        refreshBtn = NSButton(title: "立即刷新", target: self, action: #selector(onRefreshClicked))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.frame = NSRect(x: 970, y: 11, width: 90, height: 30)
        refreshBtn.autoresizingMask = [.minXMargin]
        topBarView.addSubview(refreshBtn)

        ehallBtn = NSButton(title: "EHALL授权 / 刷新", target: self, action: #selector(onEhallAuthorize))
        ehallBtn.bezelStyle = .rounded
        ehallBtn.frame = NSRect(x: 750, y: 11, width: 120, height: 30)
        ehallBtn.autoresizingMask = [.minXMargin]
        topBarView.addSubview(ehallBtn)

        libraryBtn = NSButton(title: "图书馆", target: self, action: #selector(onOpenLibrary))
        libraryBtn.bezelStyle = .rounded
        libraryBtn.frame = NSRect(x: 880, y: 11, width: 80, height: 30)
        libraryBtn.autoresizingMask = [.minXMargin]
        topBarView.addSubview(libraryBtn)

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
        tableTitleLabel.frame = NSRect(x: 20, y: chartY - 26, width: 840, height: 18)
        tableTitleLabel.autoresizingMask = [.width, .minYMargin]
        tableTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        tableTitleLabel.textColor = .secondaryLabelColor
        contentView.addSubview(tableTitleLabel)

        ehallDomainSegment = NSSegmentedControl(
            labels: ["🍽️ 餐饮消费", "🎓 学业成就", "🌟 综合素养"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onEhallDomainChanged(_:))
        )
        ehallDomainSegment.selectedSegment = currentEhallDomain
        ehallDomainSegment.autoresizingMask = [.maxXMargin, .minYMargin]
        ehallDomainSegment.isHidden = true
        contentView.addSubview(ehallDomainSegment)

        ehallSubSegment = NSSegmentedControl(
            labels: ["学分绩点", "课程成绩", "荣誉表彰"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onEhallSubSegmentChanged(_:))
        )
        ehallSubSegment.selectedSegment = currentEhallSubIndex
        ehallSubSegment.autoresizingMask = [.minXMargin, .minYMargin]
        ehallSubSegment.isHidden = true
        contentView.addSubview(ehallSubSegment)

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
        libraryBtn?.frame = NSRect(x: (refreshBtn?.frame.minX ?? totalW - sidePad - 90) - 10 - 80, y: 11, width: 80, height: 30)
        ehallBtn?.frame = NSRect(x: (libraryBtn?.frame.minX ?? 880) - 10 - 120, y: 11, width: 120, height: 30)
        settingsBtn?.frame = NSRect(x: (ehallBtn?.frame.minX ?? 750) - 10 - 110, y: 11, width: 110, height: 30)
        let segmentWidth = min(520, max(460, (settingsBtn?.frame.minX ?? 630) - sidePad - 10))
        segmentedControl?.frame = NSRect(x: sidePad, y: 12, width: segmentWidth, height: 30)

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
        quotaCardView?.isHidden = currentMode == 3

        let chartH: CGFloat = 184
        let chartY = (currentMode == 3 ? cardY : quotaY) - 12 - chartH
        chartView?.frame = NSRect(x: sidePad, y: chartY, width: contentW, height: chartH)

        let titleY = chartY - 26
        if currentMode == 3 {
            ehallDomainSegment?.isHidden = false
            ehallSubSegment?.isHidden = false
            let domainW: CGFloat = 260
            ehallDomainSegment?.frame = NSRect(x: sidePad, y: titleY - 5, width: domainW, height: 26)

            let subCount = ehallSubSegment?.segmentCount ?? 3
            let subW: CGFloat = CGFloat(subCount) * 85
            ehallSubSegment?.frame = NSRect(x: totalW - sidePad - subW, y: titleY - 5, width: subW, height: 26)

            let labelX = sidePad + domainW + 15
            let labelW = max(100, totalW - sidePad - subW - 10 - labelX)
            tableTitleLabel?.frame = NSRect(x: labelX, y: titleY, width: labelW, height: 18)
        } else {
            ehallDomainSegment?.isHidden = true
            ehallSubSegment?.isHidden = true
            tableTitleLabel?.frame = NSRect(x: sidePad, y: titleY, width: contentW, height: 18)
        }

        let tableBottom: CGFloat = 20
        let tableHeight = max(80, titleY - 8 - tableBottom)
        scrollTableView?.frame = NSRect(x: sidePad, y: tableBottom, width: contentW, height: tableHeight)
    }

    @objc private func onEhallDomainChanged(_ sender: NSSegmentedControl) {
        currentEhallDomain = sender.selectedSegment
        currentEhallSubIndex = 0
        updateEhallSubSegmentItems()
        reloadData()
    }

    private func updateEhallSubSegmentItems() {
        let labels: [String]
        switch currentEhallDomain {
        case 0: labels = ["消费档口", "就餐频次", "月度日度", "学年总览"]
        case 1: labels = ["学分绩点", "课程成绩", "荣誉表彰"]
        case 2: labels = ["志愿公益", "体质健康", "第二课堂", "图书自习"]
        default: labels = []
        }
        ehallSubSegment?.segmentCount = labels.count
        for (i, lbl) in labels.enumerated() {
            ehallSubSegment?.setLabel(lbl, forSegment: i)
        }
        ehallSubSegment?.selectedSegment = min(currentEhallSubIndex, max(0, labels.count - 1))
        layoutSubviewsForCurrentBounds()
    }

    @objc private func onEhallSubSegmentChanged(_ sender: NSSegmentedControl) {
        currentEhallSubIndex = sender.selectedSegment
        reloadData()
    }

    public func showWindow(mode: Int) {
        currentMode = max(0, min(3, mode))
        if let seg = segmentedControl {
            seg.selectedSegment = currentMode
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
        if currentMode == 2 || CampusCardService.shared.latestData == nil {
            CampusCardService.shared.fetchData { [weak self] _ in
                self?.reloadData()
            }
        }
        if currentMode == 0 || currentFlowRecords.isEmpty {
            CampusNetworkClient.shared.fetchData()
            CampusNetworkClient.shared.fetchOnlineDevices()
        }
        if currentMode == 3 {
            StudentPortraitEatService.shared.sync { [weak self] _ in self?.reloadData() }
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
        } else if currentMode == 2 && CampusCardService.shared.latestData == nil {
            CampusCardService.shared.fetchData { [weak self] _ in
                self?.reloadData()
            }
        } else if currentMode == 3 {
            StudentPortraitEatService.shared.sync { [weak self] _ in self?.reloadData() }
        }
    }

    @objc private func onRefreshClicked() {
        if currentMode == 3 {
            refreshBtn?.title = "刷新中..."
            refreshBtn?.isEnabled = false
            StudentPortraitEatService.shared.sync { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshBtn?.title = "立即刷新"
                    self?.refreshBtn?.isEnabled = true
                    self?.reloadData()
                }
            }
            return
        }
        CampusNetworkClient.shared.fetchData()
        CampusNetworkClient.shared.fetchOnlineDevices()
        ElectricityService.shared.fetchData { [weak self] _ in
            self?.reloadData()
        }
        CampusCardService.shared.fetchData { [weak self] _ in
            self?.reloadData()
        }
    }

    @objc private func onEhallAuthorize() {
        guard let tgc = SettingsManager.shared.casTgcCookie, !tgc.isEmpty else {
            UnifiedLoginWebViewController.shared.showLoginWindow()
            return
        }
        ehallBtn?.title = "授权中..."
        ehallBtn?.isEnabled = false
        StudentPortraitEatService.shared.sync { [weak self] result in
            DispatchQueue.main.async {
                self?.ehallBtn?.title = "EHALL授权 / 刷新"
                self?.ehallBtn?.isEnabled = true
                self?.reloadData()
                if case .failure(let error) = result, (error as NSError).code == 401 {
                    UnifiedLoginWebViewController.shared.showLoginWindow()
                }
            }
        }
    }

    @objc private func onOpenLibrary() {
        LibraryWindowController.shared.showWindow(nil)
    }

    @objc private func onOpenSettings() {
        if currentMode == 2 {
            promptCampusCardBudgetSettings()
        } else {
            SettingsWindowController.shared.showSettings()
        }
    }

    private func promptCampusCardBudgetSettings() {
        let alert = NSAlert()
        alert.messageText = "校园一卡通消费预算与预警设置"
        alert.informativeText = "可自定义单日餐饮/日常消费参考基准（默认 30 元）以及卡内余额不足提醒红线（默认 15 元）："
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "恢复默认 (30元 / 15元)")
        alert.addButton(withTitle: "取消")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 64))

        let budgetLabel = NSTextField(labelWithString: "单日消费预算基准：")
        budgetLabel.frame = NSRect(x: 0, y: 36, width: 125, height: 20)
        budgetLabel.alignment = .right
        container.addSubview(budgetLabel)

        let budgetField = NSTextField(frame: NSRect(x: 130, y: 36, width: 80, height: 22))
        budgetField.stringValue = String(format: "%.0f", SettingsManager.shared.campusCardDailyBudget)
        budgetField.placeholderString = "30"
        container.addSubview(budgetField)

        let budgetUnit = NSTextField(labelWithString: "元 / 天")
        budgetUnit.frame = NSRect(x: 216, y: 36, width: 60, height: 20)
        budgetUnit.textColor = .secondaryLabelColor
        container.addSubview(budgetUnit)

        let threshLabel = NSTextField(labelWithString: "低余额预警红线：")
        threshLabel.frame = NSRect(x: 0, y: 6, width: 125, height: 20)
        threshLabel.alignment = .right
        container.addSubview(threshLabel)

        let threshField = NSTextField(frame: NSRect(x: 130, y: 6, width: 80, height: 22))
        threshField.stringValue = String(format: "%.0f", SettingsManager.shared.campusCardLowWarningThreshold)
        threshField.placeholderString = "15"
        container.addSubview(threshField)

        let threshUnit = NSTextField(labelWithString: "元")
        threshUnit.frame = NSRect(x: 216, y: 6, width: 60, height: 20)
        threshUnit.textColor = .secondaryLabelColor
        container.addSubview(threshUnit)

        alert.accessoryView = container

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let b = Double(budgetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), b > 0 {
                SettingsManager.shared.campusCardDailyBudget = b
            }
            if let t = Double(threshField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), t > 0 {
                SettingsManager.shared.campusCardLowWarningThreshold = t
            }
            reloadData()
            NotificationCenter.default.post(name: .campusCardDidUpdate, object: CampusCardService.shared.latestData)
        } else if response == .alertSecondButtonReturn {
            SettingsManager.shared.campusCardDailyBudget = 30.0
            SettingsManager.shared.campusCardLowWarningThreshold = 15.0
            reloadData()
            NotificationCenter.default.post(name: .campusCardDidUpdate, object: CampusCardService.shared.latestData)
        }
    }

    @objc public func reloadData() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentFlowRecords = CampusHistoryManager.shared.getPastDaysFlowRecords(days: 90).reversed()
            self.currentElectricityRecords = CampusHistoryManager.shared.getPastDaysElectricityRecords(days: 90).reversed()
            self.currentCardTransactions = CampusCardService.shared.latestData?.transactions ?? []
            self.currentEhallData = StudentPortraitEatService.shared.latestData

            if self.currentMode == 0 {
                self.settingsBtn?.title = "宿舍配置..."
                self.tableTitleLabel?.stringValue = "校园网每日流量明细"
            } else if self.currentMode == 1 {
                self.settingsBtn?.title = "宿舍配置..."
                self.tableTitleLabel?.stringValue = "宿舍每日用电历史记录"
            } else if self.currentMode == 2 {
                self.settingsBtn?.title = "一卡通预算..."
                if let card = CampusCardService.shared.latestData {
                    let breakdown = card.expenseStructureBreakdown()
                    self.tableTitleLabel?.stringValue = String(
                        format: "校园一卡通历史归档 (%d笔 · 早 ¥%.0f / 午 ¥%.0f / 晚 ¥%.0f / 其他 ¥%.0f)",
                        self.currentCardTransactions.count,
                        breakdown.breakfastRMB,
                        breakdown.lunchRMB,
                        breakdown.dinnerRMB,
                        breakdown.otherRMB
                    )
                } else {
                    self.tableTitleLabel?.stringValue = "校园一卡通历史交易流水 (已归档 \(self.currentCardTransactions.count) 笔)"
                }
            } else {
                self.settingsBtn?.title = "宿舍配置..."
                if let data = self.currentEhallData {
                    switch self.currentEhallSubMode {
                    case 0:
                        let topCount = data.topMine.count
                        self.tableTitleLabel?.stringValue = "常去消费档口与金额排行 (已归档 Top \(topCount) 热门地点)"
                    case 1:
                        let totalFreq = data.frequencyMine.reduce(0) { $0 + $1.count }
                        self.tableTitleLabel?.stringValue = "消费就餐地点频次分布 (累计已记录 \(totalFreq) 次刷卡)"
                    case 2:
                        self.tableTitleLabel?.stringValue = "各学年月度与日度消费模型 (本人 vs 全校对比)"
                    case 3:
                        self.tableTitleLabel?.stringValue = "本科培养方案修读学分与历学期 GPA 走势对比"
                    case 4:
                        self.tableTitleLabel?.stringValue = "各类别课程均分与成绩极值对比分析"
                    case 5:
                        self.tableTitleLabel?.stringValue = "第二课堂成绩单考核与 8 大素养星级画像"
                    case 6:
                        self.tableTitleLabel?.stringValue = "各学年总消费归档 (\(data.annual.count) 个学年 · EHALL 授权独立)"
                    case 7:
                        let totalAwards = data.awardSummary?.totalCount ?? (data.awardList?.reduce(0) { $0 + $1.count } ?? 0)
                        let totalMoney = data.awardSummary?.totalMoney ?? (data.awardList?.reduce(0.0) { $0 + $1.totalMoney } ?? 0.0)
                        self.tableTitleLabel?.stringValue = "荣誉表彰与奖学金 (累计获奖 \(totalAwards) 项 · 奖金 ¥\(String(format: "%.0f", totalMoney)))"
                    case 8:
                        let totalHours = data.volunteerCompare?.myTotalHours ?? (data.volunteerWelfare?.reduce(0.0) { $0 + $1.hours } ?? 0.0)
                        let avgHours = data.volunteerCompare?.avgTotalHours ?? 0.0
                        self.tableTitleLabel?.stringValue = "志愿公益工时与德育积分 (本人 \(String(format: "%.1f", totalHours))h vs 全校均值 \(String(format: "%.1f", avgHours))h)"
                    case 9:
                        self.tableTitleLabel?.stringValue = "历年学生体质健康标准测试 (本人成绩 vs 全校平均)"
                    case 10:
                        let schoolH = data.libraryStudyTime?.campusHours ?? 0.0
                        let majorH = data.libraryStudyTime?.majorHours ?? 0.0
                        self.tableTitleLabel?.stringValue = "图书馆入馆学习时长与全校图书借阅分布 (全校均 \(String(format: "%.0f", schoolH))h · 专业均 \(String(format: "%.1f", majorH))h)"
                    default:
                        self.tableTitleLabel?.stringValue = "EHALL综合学生画像"
                    }
                } else if let error = StudentPortraitEatService.shared.lastErrorMessage {
                    self.tableTitleLabel?.stringValue = "EHALL画像未同步：\(error)"
                } else {
                    self.tableTitleLabel?.stringValue = "EHALL学生画像：点击「EHALL授权 / 刷新」同步"
                }
            }

            self.updateCards()
            self.quotaCardView.refresh(mode: self.currentMode)
            self.updateChart()
            self.setupTableColumns()
            self.layoutSubviewsForCurrentBounds()
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
            } else if let lastBal = currentFlowRecords.first?.balanceRMB ?? CampusHistoryManager.shared.latestFlowBalanceRMB {
                balText = String(format: "%.2f 元", lastBal)
            } else {
                balText = "-- 元"
            }
            let monthlyUsedStr: String
            let bestMonthlyMB = max(netData.usedMB ?? 0.0, CampusHistoryManager.shared.currentMonthUsedFlowMB ?? 0.0)
            if bestMonthlyMB > 0 || netData.usedMB != nil {
                monthlyUsedStr = "本月累计已用 \(formatMB(bestMonthlyMB))"
            } else {
                monthlyUsedStr = "校园网账户实时余额"
            }
            setCard(index: 3, title: "校园网账户余额", value: balText, sub: monthlyUsedStr, color: NSColor.systemGreen)
        } else if currentMode == 1 {
            // 宿舍电费模式
            if !SettingsManager.shared.isDormConfigured {
                setCard(index: 0, title: "当前剩余电费", value: "未配置", sub: "请先在「设置」中填写楼栋与房间号", color: NSColor.systemGray)
                setCard(index: 1, title: "今日消耗电费", value: "--", sub: "配置宿舍后可查看", color: NSColor.systemGray)
                setCard(index: 2, title: "近 7 天日均支出", value: "--", sub: "配置宿舍后可查看", color: NSColor.systemGray)
                setCard(index: 3, title: "预计可用天数", value: "--", sub: "配置宿舍后可查看", color: NSColor.systemGray)
                return
            }
            let elec = ElectricityService.shared.latestData
            let fallbackElec = currentElectricityRecords.first ?? CampusHistoryManager.shared.latestElectricityRecord
            let balRMB = elec?.balanceRMB ?? fallbackElec?.balanceRMB
            let kwhVal = elec?.remainingKWh ?? fallbackElec?.remainingKWh
            let isLow = (balRMB != nil && balRMB! < SettingsManager.shared.electricityLowWarningThreshold)
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
        } else if currentMode == 2 {
            // 校园卡（一卡通）与消费账单模式
            guard let card = CampusCardService.shared.latestData else {
                setCard(index: 0, title: "校园卡当前余额", value: "获取中...", sub: "正在向慧新易校查询一卡通", color: .systemGray)
                setCard(index: 1, title: "今日 / 本月消费", value: "--", sub: "等待同步账单流水", color: .systemGray)
                setCard(index: 2, title: "近 7 天日均消费", value: "--", sub: "等待同步账单流水", color: .systemGray)
                setCard(index: 3, title: "消费结构占比", value: "--", sub: "等待同步", color: .systemGray)
                return
            }

            let isLow = card.isLowBalance
            let balColor: NSColor = isLow ? .systemRed : .systemGreen
            let monthRecharged = card.currentMonthRechargedRMB()
            let subInfo: String
            if isLow {
                subInfo = "⚠️ 低于预警阈值 (\(String(format: "%.0f", SettingsManager.shared.campusCardLowWarningThreshold))元)"
            } else if monthRecharged > 0 {
                subInfo = String(format: "本月已充值 %.0f 元 · 状态%@", monthRecharged, card.cardStatusText)
            } else {
                subInfo = "卡号 \(card.cardAccount) · 状态\(card.cardStatusText)"
            }
            setCard(index: 0, title: "校园卡当前余额", value: card.displayBalance, sub: subInfo, color: balColor)

            let todaySpent = card.todaySpentRMB()
            let todayCount = card.todayExpenseCount()
            let monthSpent = card.currentMonthSpentRMB()
            let monthCount = card.currentMonthExpenseCount()
            setCard(
                index: 1,
                title: "今日消费 (\(todayCount)笔)",
                value: String(format: "%.2f 元", todaySpent),
                sub: String(format: "本月累计 %.2f 元 (%d笔)", monthSpent, monthCount),
                color: .systemOrange
            )

            let dailyList = card.dailyExpenseSummary(days: 7)
            let activeDays = max(1, dailyList.filter { $0.spentRMB > 0 }.count)
            let weekSum = dailyList.reduce(0.0) { $0 + $1.spentRMB }
            let dailyAvg = weekSum / Double(activeDays)
            setCard(
                index: 2,
                title: "近 7 日活跃日均",
                value: String(format: "%.2f 元/天", dailyAvg),
                sub: String(format: "近 7 日共支出 %.2f 元", weekSum),
                color: .systemIndigo
            )

            let breakdown = card.expenseStructureBreakdown()
            setCard(
                index: 3,
                title: "消费场景与三餐占比",
                value: breakdown.ratioSummaryText,
                sub: breakdown.topMerchantsText,
                color: .systemTeal
            )
        } else {
            guard let data = currentEhallData else {
                let message = StudentPortraitEatService.shared.lastErrorMessage ?? "点击上方 EHALL 授权 / 刷新"
                setCard(index: 0, title: "年度消费累计", value: "等待授权", sub: message, color: .systemGray)
                setCard(index: 1, title: "个人日均 / 校区日均", value: "--", sub: "学生画像授权后展示", color: .systemGray)
                setCard(index: 2, title: "常去消费地点", value: "--", sub: "EHALL 提供消费地点排行", color: .systemGray)
                setCard(index: 3, title: "每日消费频次", value: "--", sub: "EHALL 提供全校对比", color: .systemGray)
                return
            }

            switch currentEhallSubMode {
            case 3: // 学分绩点
                let latestGpa = data.gpaHistory?.last
                let gpaVal = latestGpa.map { String(format: "%.2f", $0.gpa) } ?? "--"
                let gpaSub = latestGpa.map { String(format: "%@ · 年级均值 %.2f", $0.semester, $0.averageGPA) } ?? "暂无学期绩点"
                setCard(index: 0, title: "最新学期绩点 (GPA)", value: gpaVal, sub: gpaSub, color: .systemPurple)

                let credits = data.completedCredits ?? latestGpa?.credits
                let totalReq = data.totalRequiredCredits ?? latestGpa?.totalCredits
                let creditVal = credits != nil ? String(format: "%.1f 学分", credits!) : "--"
                let pct = (credits != nil && totalReq != nil && totalReq! > 0) ? (credits! / totalReq! * 100) : 0
                let creditSub = totalReq != nil ? String(format: "总要求 %.0f 学分 · 完成 %.1f%%", totalReq!, pct) : "学业修读进展"
                setCard(index: 1, title: "已修学分 / 培养要求", value: creditVal, sub: creditSub, color: .systemBlue)

                if let latest = latestGpa {
                    let diff = latest.gpa - latest.averageGPA
                    let diffStr = String(format: "%@%.2f", diff >= 0 ? "+" : "", diff)
                    setCard(index: 2, title: "最新绩点相对优势", value: diffStr, sub: diff >= 0 ? "领先年级均值 · 表现优异" : "低于年级均值", color: diff >= 0 ? .systemGreen : .systemOrange)
                } else {
                    setCard(index: 2, title: "最新绩点相对优势", value: "--", sub: "暂无年级对比数据", color: .systemGray)
                }

                let allGpa = data.gpaHistory ?? []
                let avgGpaVal = allGpa.isEmpty ? 0.0 : (allGpa.reduce(0.0) { $0 + $1.gpa } / Double(allGpa.count))
                setCard(index: 3, title: "历年平均绩点 (GPA)", value: avgGpaVal > 0 ? String(format: "%.2f", avgGpaVal) : "--", sub: "\(allGpa.count) 个学期 · 稳居前列", color: .systemIndigo)

            case 4: // 课程成绩
                if let ext = data.courseExtremes {
                    setCard(index: 0, title: "历史最高课程成绩", value: String(format: "%.0f 分", ext.highestScore), sub: ext.highestCourseName + " · 满分优异", color: .systemGreen)
                    setCard(index: 1, title: "历史最低课程成绩", value: String(format: "%.0f 分", ext.lowestScore), sub: ext.lowestCourseName + " · 合格通过", color: .systemOrange)
                } else {
                    setCard(index: 0, title: "历史最高课程成绩", value: "--", sub: "暂无极值数据", color: .systemGray)
                    setCard(index: 1, title: "历史最低课程成绩", value: "--", sub: "暂无极值数据", color: .systemGray)
                }

                let pubStat = data.courseTypeStats?.first(where: { $0.categoryName.contains("公共") })
                let pubVal = pubStat.map { String(format: "%.2f 分", $0.averageScore) } ?? "--"
                let pubSub = pubStat.map { String(format: "最高 %.0f / 最低 %.0f", $0.highestScore, $0.lowestScore) } ?? "基础理论扎实"
                setCard(index: 2, title: "公共基础课均分", value: pubVal, sub: pubSub, color: .systemTeal)

                let reqStat = data.courseTypeStats?.first(where: { $0.categoryName.contains("必修") })
                let reqVal = reqStat.map { String(format: "%.2f 分", $0.averageScore) } ?? "--"
                let reqSub = reqStat.map { String(format: "最高 %.0f / 最低 %.0f", $0.highestScore, $0.lowestScore) } ?? "专业核心过硬"
                setCard(index: 3, title: "专业必修课均分", value: reqVal, sub: reqSub, color: .systemBlue)

            case 5: // 第二课堂
                if let sc = data.secondClass {
                    setCard(index: 0, title: "第二课堂必修等级", value: "\(sc.requiredLevel) 级", sub: "成绩单考核已合格达标", color: .systemGreen)
                    setCard(index: 1, title: "第二课堂选修等级", value: "\(sc.electiveLevel) 级", sub: "选修学时积分已达标", color: .systemBlue)
                    let starsSummary = "科创 \(sc.techInnovationStars)★ · 健身 \(sc.sportsFitnessStars)★ · 公益 \(sc.publicWelfareStars)★"
                    setCard(index: 2, title: "顶尖优势特长维度", value: "科创 / 体育 5★", sub: starsSummary, color: .systemOrange)
                    setCard(index: 3, title: "综合素养整体评定", value: "综合优秀", sub: "德智体美劳全面发展", color: .systemPurple)
                } else {
                    setCard(index: 0, title: "第二课堂必修等级", value: "--", sub: "等待同步二课数据", color: .systemGray)
                    setCard(index: 1, title: "第二课堂选修等级", value: "--", sub: "等待同步二课数据", color: .systemGray)
                    setCard(index: 2, title: "顶尖优势特长维度", value: "--", sub: "等待同步二课数据", color: .systemGray)
                    setCard(index: 3, title: "综合素养整体评定", value: "--", sub: "等待同步二课数据", color: .systemGray)
                }

            case 7: // 荣誉表彰与奖学金
                let count = data.awardSummary?.totalCount ?? (data.awardList?.reduce(0) { $0 + $1.count } ?? 0)
                let money = data.awardSummary?.totalMoney ?? (data.awardList?.reduce(0.0) { $0 + $1.totalMoney } ?? 0.0)
                setCard(index: 0, title: "累计获奖与荣誉总数", value: "\(count) 项", sub: "国家/省/市/校级荣誉汇总", color: .systemOrange)
                setCard(index: 1, title: "累计奖学金资助总额", value: String(format: "%.0f 元", money), sub: "各项奖学金与表彰奖励", color: .systemGreen)
                let schoolCount = data.awardList?.first(where: { $0.code == 4 })?.count ?? 0
                let provCount = data.awardList?.first(where: { $0.code == 2 })?.count ?? 0
                setCard(index: 2, title: "荣誉级别分布", value: "\(schoolCount) 项校级 / \(provCount) 项省级", sub: "多层级表彰奖励分布", color: .systemTeal)
                setCard(index: 3, title: "综合表彰等级", value: count > 0 ? "学业表彰优异" : "暂无表彰记录", sub: "表彰记录同步自学工系统", color: .systemPurple)

            case 8: // 志愿公益
                let myHours = data.volunteerCompare?.myTotalHours ?? (data.volunteerWelfare?.reduce(0.0) { $0 + $1.hours } ?? 0.0)
                let avgHours = data.volunteerCompare?.avgTotalHours ?? 36.15
                let multipleStr = avgHours > 0 ? String(format: " · %.1f倍", myHours / avgHours) : ""
                setCard(index: 0, title: "累计志愿服务工时", value: String(format: "%.1f 小时", myHours), sub: "全校均值 \(String(format: "%.1f", avgHours)) 小时\(multipleStr)", color: .systemGreen)
                let myTimes = data.volunteerCompare?.myTimes ?? 0
                let avgTimes = data.volunteerCompare?.avgTimes ?? 0.0
                setCard(index: 1, title: "志愿服务总频次", value: "\(myTimes) 次", sub: "全校均值 \(String(format: "%.1f", avgTimes)) 次", color: .systemBlue)
                let topOrg = data.volunteerCompare?.topOrganization.isEmpty == false ? data.volunteerCompare!.topOrganization : (data.volunteerWelfare?.first?.organization ?? "--")
                let topH = data.volunteerCompare?.topOrgHours ?? (data.volunteerWelfare?.first?.hours ?? 0.0)
                setCard(index: 2, title: "最高工时组织", value: topOrg, sub: String(format: "累计贡献 %.1f 小时工时", topH), color: .systemOrange)
                let topScore = data.virtueScores?.max(by: { $0.myScore < $1.myScore })
                let scoreVal = topScore != nil ? String(format: "%.0f 积分", topScore!.myScore) : "--"
                let scoreSub = topScore != nil ? "\(topScore!.name) (全校均 \(String(format: "%.1f", topScore!.avgScore)))" : "思想德育理论学习"
                setCard(index: 3, title: "德育示范积分", value: scoreVal, sub: scoreSub, color: .systemPurple)

            case 9: // 体质健康
                let latestTest = data.healthTests?.sorted(by: { $0.year > $1.year }).first
                let score = latestTest?.myScore ?? 0.0
                let avgScore = latestTest?.avgScore ?? 0.0
                setCard(index: 0, title: "最新体测总成绩", value: score > 0 ? String(format: "%.1f 分", score) : "--", sub: latestTest != nil ? "\(latestTest!.year)年体测 (全校均 \(String(format: "%.1f", avgScore)))" : "体测成绩档案", color: score >= 75 ? .systemGreen : .systemOrange)
                let level = score >= 85 ? "优秀" : (score >= 75 ? "良好" : (score >= 60 ? "及格" : "需加强"))
                setCard(index: 1, title: "体质健康等级", value: score > 0 ? level : "--", sub: "国家学生体质健康标准", color: score >= 75 ? .systemTeal : .systemOrange)
                let diff = score - avgScore
                let diffStr = String(format: "%@%.1f 分", diff >= 0 ? "+" : "", diff)
                setCard(index: 2, title: "相对全校均分差额", value: score > 0 ? diffStr : "--", sub: diff >= 0 ? "优于全校平均水平" : "低于全校平均水平", color: diff >= 0 ? .systemGreen : .systemRed)
                let countYears = data.healthTests?.count ?? 0
                setCard(index: 3, title: "参测学年累计", value: "\(countYears) 个学年", sub: "体质健康连续归档监测", color: .systemIndigo)

            case 10: // 图书自习
                let schoolH = data.libraryStudyTime?.campusHours ?? 0.0
                let schoolCount = data.libraryStudyTime?.campusCount ?? 0.0
                setCard(index: 0, title: "全校入馆自习均时", value: String(format: "%.0f 小时", schoolH), sub: "入馆总人次约 \(String(format: "%.0f", schoolCount)) 次", color: .systemIndigo)
                let majorH = data.libraryStudyTime?.majorHours ?? 0.0
                let majorCount = data.libraryStudyTime?.majorCount ?? 0.0
                setCard(index: 1, title: "班级专业在馆均时", value: String(format: "%.1f 小时", majorH), sub: "专业入馆约 \(String(format: "%.1f", majorCount)) 次", color: .systemBlue)
                let period = data.libraryStudyTime?.campusPeriod.isEmpty == false ? data.libraryStudyTime!.campusPeriod : "14:00-17:00"
                setCard(index: 2, title: "高频自习入馆时段", value: period, sub: "全校读者自习高峰时段", color: .systemTeal)
                let topRange = data.libraryBorrowRanges?.max(by: { $0.studentCount < $1.studentCount })
                let rangeVal = topRange?.range ?? "0-5本"
                let rangeSub = topRange != nil ? "占比最高借阅区间 (\(topRange!.studentCount)人)" : "全校图书借阅区间分布"
                setCard(index: 3, title: "主流借阅区间", value: rangeVal, sub: rangeSub, color: .systemOrange)

            default:
                let total = data.annual.reduce(0.0) { $0 + $1.personalRMB }
                let rangeText: String
                if let first = data.annual.first?.academicYear {
                    rangeText = data.annual.last.map { "\(first) - \($0.academicYear)" } ?? first
                } else {
                    rangeText = "尚无年度数据"
                }
                setCard(index: 0, title: "年度消费累计", value: String(format: "%.0f 元", total), sub: "\(data.annual.count) 个学年 · \(rangeText)", color: .systemOrange)

                let daily = String(format: "%.1f / %.1f 元", data.average.personalDayRMB, data.average.campusDayRMB)
                setCard(index: 1, title: "个人日均 / 校区日均", value: daily, sub: String(format: "月均 %.0f 元 / 校区 %.0f 元", data.average.personalMonthRMB, data.average.campusMonthRMB), color: .systemBlue)

                if let topPlace = data.topMine.first {
                    setCard(index: 2, title: "消费最多地点", value: topPlace.place, sub: String(format: "画像排行 · 消费 %.0f 元", topPlace.amountRMB), color: .systemTeal)
                } else {
                    setCard(index: 2, title: "消费最多地点", value: "暂无排行", sub: "画像接口未返回地点数据", color: .systemGray)
                }

                let breakfast = data.oneDay.personalFirstTime == "--" ? "--" : "\(data.oneDay.personalFirstTime) · \(data.oneDay.personalFirstPlace)"
                let frequentPlace = data.frequencyMine.first.map { "常去 \($0.place) · \($0.count) 次" } ?? "暂无消费频次排行"
                setCard(index: 3, title: "首笔消费 / 消费频次", value: breakfast, sub: frequentPlace, color: .systemIndigo)
            }
        }
    }

    private func setCard(index: Int, title: String, value: String, sub: String, color: NSColor) {
        guard index < cardViews.count else { return }
        cardTitleLabels[index].stringValue = title
        cardValueLabels[index].stringValue = value
        cardValueLabels[index].textColor = color
        cardSubLabels[index].stringValue = sub
        // 根据文字长度动态缩小字号，防止截断
        let charCount = value.count
        let fontSize: CGFloat = charCount <= 10 ? 20 : charCount <= 15 ? 17 : charCount <= 20 ? 14 : 12
        cardValueLabels[index].font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    }

    private func updateChart() {
        if currentMode == 0 {
            let records = CampusHistoryManager.shared.getPastDaysFlowRecords(days: 7)
            let items: [BarChartItem] = records.map {
                let shortDate = String($0.dateString.suffix(5))
                return BarChartItem(label: shortDate, value: max(0.0, $0.dailyDeltaMB), displayValue: formatMB($0.dailyDeltaMB))
            }
            chartView.setData(items: items, barColor: NSColor.systemBlue, unit: "MB")
        } else if currentMode == 1 {
            let records = CampusHistoryManager.shared.getPastDaysElectricityRecords(days: 7)
            let items: [BarChartItem] = records.map {
                let shortDate = String($0.dateString.suffix(5))
                return BarChartItem(label: shortDate, value: max(0.0, $0.dailyCostRMB), displayValue: String(format: "%.2f元", $0.dailyCostRMB))
            }
            chartView.setData(items: items, barColor: NSColor.systemOrange, unit: "元")
        } else if currentMode == 2 {
            let monthlySummary = CampusCardService.shared.latestData?.monthlyExpenseSummary(months: 12) ?? []
            let items: [BarChartItem] = monthlySummary.map {
                let shortDate = String($0.monthString.suffix(5))
                return BarChartItem(label: shortDate, value: max(0.0, $0.spentRMB), displayValue: String(format: "%.0f元", $0.spentRMB))
            }
            chartView.setData(items: items, barColor: NSColor.systemTeal, unit: "元")
        } else {
            guard let data = currentEhallData else {
                chartView.setData(items: [], barColor: .systemOrange, unit: "元")
                return
            }
            switch currentEhallSubMode {
            case 0: // 消费档口排行
                let items: [BarChartItem] = data.topMine.enumerated().map { (idx, item) in
                    let shortName = item.place.count > 6 ? String(item.place.prefix(6)) + ".." : item.place
                    return BarChartItem(label: shortName, value: max(0, item.amountRMB), displayValue: String(format: "%.0f元", item.amountRMB))
                }
                chartView.setData(items: items, barColor: NSColor.systemTeal, unit: "元")

            case 1: // 消费频次分布
                let items: [BarChartItem] = data.frequencyMine.enumerated().map { (idx, item) in
                    let shortName = item.place.count > 6 ? String(item.place.prefix(6)) + ".." : item.place
                    return BarChartItem(label: shortName, value: Double(max(0, item.count)), displayValue: "\(item.count)次")
                }
                chartView.setData(items: items, barColor: NSColor.systemIndigo, unit: "次")

            case 2: // 各学年月度日度
                let items: [BarChartItem] = data.yearAverages.map {
                    BarChartItem(label: $0.academicYear + "年", value: max(0, $0.average.personalMonthRMB), displayValue: String(format: "%.0f元/月", $0.average.personalMonthRMB))
                }
                chartView.setData(items: items, barColor: NSColor.systemBlue, unit: "元/月")

            case 3: // 学分绩点 (GPA趋势)
                let gpaList = data.gpaHistory ?? []
                let items: [BarChartItem] = gpaList.map {
                    let shortSem = $0.semester.replacingOccurrences(of: "20", with: "")
                    return BarChartItem(label: shortSem, value: max(0, $0.gpa), displayValue: String(format: "%.2f", $0.gpa))
                }
                chartView.setData(items: items, barColor: NSColor.systemPurple, unit: "GPA")

            case 4: // 课程成绩 (各类别课程均分)
                let stats = data.courseTypeStats ?? []
                let items: [BarChartItem] = stats.map {
                    BarChartItem(label: $0.categoryName, value: max(0, $0.averageScore), displayValue: String(format: "%.1f分", $0.averageScore))
                }
                chartView.setData(items: items, barColor: NSColor.systemTeal, unit: "分")

            case 5: // 第二课堂 (8大维度能力星级)
                if let sc = data.secondClass {
                    let starList: [(String, Int)] = [
                        ("科创", sc.techInnovationStars),
                        ("体育", sc.sportsFitnessStars),
                        ("公益", sc.publicWelfareStars),
                        ("劳动", sc.laborPracticeStars),
                        ("文娱", sc.artsCultureStars),
                        ("技能", sc.skillsProjectStars),
                        ("实践", sc.socialPracticeStars),
                        ("思政", sc.ideologicalStars)
                    ]
                    let items: [BarChartItem] = starList.map {
                        BarChartItem(label: $0.0, value: Double(max(0, $0.1)), displayValue: "\($0.1)星")
                    }
                    chartView.setData(items: items, barColor: NSColor.systemOrange, unit: "星")
                } else {
                    chartView.setData(items: [], barColor: NSColor.systemOrange, unit: "星")
                }

            case 6: // 学年总览
                let items: [BarChartItem] = data.annual.map {
                    let year = String($0.academicYear.prefix(4))
                    return BarChartItem(label: year + "学年", value: max(0, $0.personalRMB), displayValue: String(format: "%.0f元", $0.personalRMB))
                }
                chartView.setData(items: items, barColor: NSColor.systemOrange, unit: "元")

            case 7: // 荣誉表彰
                let list = (data.awardList ?? []).filter { $0.count > 0 }
                let items: [BarChartItem] = list.map {
                    BarChartItem(label: $0.name, value: Double($0.count), displayValue: "\($0.count)项")
                }
                chartView.setData(items: items, barColor: NSColor.systemOrange, unit: "项")

            case 8: // 志愿公益
                let list = data.volunteerWelfare ?? []
                let items: [BarChartItem] = list.map {
                    let shortOrg = $0.organization.count > 6 ? String($0.organization.prefix(6)) + ".." : $0.organization
                    return BarChartItem(label: shortOrg, value: $0.hours, displayValue: String(format: "%.1fh", $0.hours))
                }
                chartView.setData(items: items, barColor: NSColor.systemGreen, unit: "h")

            case 9: // 体质健康
                let list = (data.healthTests ?? []).sorted(by: { $0.year < $1.year })
                let items: [BarChartItem] = list.map {
                    BarChartItem(label: "\($0.year)年", value: $0.myScore, displayValue: String(format: "%.1f分", $0.myScore))
                }
                chartView.setData(items: items, barColor: NSColor.systemTeal, unit: "分")

            case 10: // 图书自习
                let list = data.libraryBorrowRanges ?? []
                let items: [BarChartItem] = list.map {
                    BarChartItem(label: $0.range, value: Double($0.studentCount), displayValue: "\($0.studentCount)人")
                }
                chartView.setData(items: items, barColor: NSColor.systemIndigo, unit: "人")

            default:
                break
            }
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
        } else if currentMode == 1 {
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
        } else if currentMode == 2 {
            let cols: [(String, String, CGFloat)] = [
                ("time", "交易时间", 160),
                ("merchant", "消费商户 / 档口名称", 265),
                ("scene", "消费场景与餐段", 125),
                ("amount", "交易金额", 120),
                ("balance", "交易后卡余额", 130)
            ]
            for (cid, ctitle, w) in cols {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cid))
                col.title = ctitle
                col.width = w
                tv.addTableColumn(col)
            }
        } else {
            let cols: [(String, String, CGFloat)]
            switch currentEhallSubMode {
            case 0:
                cols = [
                    ("rank", "排名", 65),
                    ("place", "消费档口 / 就餐地点名称", 320),
                    ("personal", "本人累计消费", 180),
                    ("ratio", "占消费比例", 150),
                    ("campus", "全校同期参考", 250)
                ]
            case 1:
                cols = [
                    ("rank", "频次排名", 75),
                    ("place", "就餐地点 / 消费商户", 340),
                    ("count", "本人刷卡频次", 180),
                    ("campusCount", "全校高频对比", 240),
                    ("analysis", "就餐习惯评估", 200)
                ]
            case 2:
                cols = [
                    ("year", "学年", 120),
                    ("myMonth", "本人月均消费", 170),
                    ("campusMonth", "校区月均消费", 170),
                    ("monthDiff", "月均偏差差额", 160),
                    ("myDay", "本人日均消费", 160),
                    ("campusDay", "校区日均消费", 160)
                ]
            case 3: // 学分绩点
                cols = [
                    ("semester", "学期 / 方案项目", 220),
                    ("credits", "修读学分", 160),
                    ("gpa", "个人绩点 (GPA)", 170),
                    ("avgGpa", "年级专业均值", 170),
                    ("status", "绩点相对优势 / 状态", 240)
                ]
            case 4: // 课程成绩
                cols = [
                    ("category", "课程类别 / 项目", 180),
                    ("name", "代表课程 / 范畴", 260),
                    ("score", "个人成绩 / 均分", 170),
                    ("extremes", "参考极值 / 分数区间", 170),
                    ("status", "学业评定 / 表现分析", 200)
                ]
            case 5: // 第二课堂
                cols = [
                    ("module", "素养培育模块", 180),
                    ("scope", "涵盖项目 / 活动范畴", 260),
                    ("stars", "获得星级 / 考核等级", 170),
                    ("standard", "满星标准 / 要求", 160),
                    ("evaluation", "素养表现评价", 210)
                ]
            case 6: // 学年总览
                cols = [
                    ("year", "学年", 140),
                    ("personal", "本人消费总额", 180),
                    ("average", "校区平均消费", 180),
                    ("difference", "与校区均值差", 180),
                    ("ratio", "相对校区消费水平", 180)
                ]
            case 7: // 荣誉表彰与奖学金
                cols = [
                    ("level", "奖项级别", 150),
                    ("name", "表彰项目 / 奖学金类型", 300),
                    ("count", "获奖项数", 140),
                    ("money", "获得奖金额度", 170),
                    ("status", "表彰归档状态", 210)
                ]
            case 8: // 志愿公益
                cols = [
                    ("module", "服务组织 / 德育项目", 300),
                    ("scope", "服务范畴 / 考评类型", 220),
                    ("personal", "本人服务工时 / 积分", 180),
                    ("average", "全校基准 / 对比", 180),
                    ("evaluation", "评价与成效", 210)
                ]
            case 9: // 体质健康
                cols = [
                    ("year", "测试学年", 140),
                    ("item", "测试项目", 220),
                    ("score", "本人总成绩", 170),
                    ("average", "全校平均分", 170),
                    ("evaluation", "体测等级评定 / 相对优势", 260)
                ]
            case 10: // 图书自习
                cols = [
                    ("category", "分析项目 / 借阅区间", 220),
                    ("scope", "指标范围 / 统计范畴", 260),
                    ("value", "指标数值 / 样本人数", 180),
                    ("benchmark", "全校基准 / 班级专业", 180),
                    ("evaluation", "自习与阅读习惯评定", 220)
                ]
            default:
                cols = []
            }
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
        } else if currentMode == 1 {
            return currentElectricityRecords.count
        } else if currentMode == 2 {
            return currentCardTransactions.count
        } else {
            guard let data = currentEhallData else { return 0 }
            switch currentEhallSubMode {
            case 0: return data.topMine.count
            case 1: return data.frequencyMine.count
            case 2: return data.yearAverages.count
            case 3: return gpaRowItems(data: data).count
            case 4: return courseRowItems(data: data).count
            case 5: return secondClassRowItems(data: data).count
            case 6: return data.annual.count
            case 7: return awardRowItems(data: data).count
            case 8: return volunteerRowItems(data: data).count
            case 9: return healthRowItems(data: data).count
            case 10: return libraryRowItems(data: data).count
            default: return 0
            }
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
        cell.textColor = .labelColor
        cell.font = NSFont.systemFont(ofSize: 11.5)

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
        } else if currentMode == 1 {
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
        } else if currentMode == 2 {
            guard row >= 0 && row < currentCardTransactions.count else { return nil }
            let tx = currentCardTransactions[row]
            switch cid {
            case "time":
                cell.stringValue = tx.dateTimeString
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
                cell.textColor = .secondaryLabelColor
            case "merchant":
                cell.stringValue = tx.cleanMerchantName
                cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            case "scene":
                let tag = tx.sceneCategoryTag
                cell.stringValue = tag
                if tag == "圈存充值" {
                    cell.textColor = .systemGreen
                } else if tag.hasPrefix("午餐") || tag.hasPrefix("晚餐") {
                    cell.textColor = .systemBlue
                } else if tag.hasPrefix("早餐") {
                    cell.textColor = .systemTeal
                } else {
                    cell.textColor = .secondaryLabelColor
                }
            case "amount":
                let sign = tx.isExpense ? "-" : "+"
                cell.stringValue = String(format: "%@%.2f 元", sign, tx.amountRMB)
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                cell.textColor = tx.isExpense ? .labelColor : .systemGreen
            case "balance":
                cell.stringValue = tx.balanceAfterRMB.map { String(format: "%.2f 元", $0) } ?? "--"
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            default: break
            }
        } else {
            guard let data = currentEhallData else { return nil }
            switch currentEhallSubMode {
            case 0: // 消费档口排行
                guard row >= 0 && row < data.topMine.count else { return nil }
                let item = data.topMine[row]
                let totalSpent = data.topMine.reduce(0.0) { $0 + $1.amountRMB }
                let ratio = totalSpent > 0 ? (item.amountRMB / totalSpent * 100.0) : 0
                let campusRef = (row < data.topCampus.count) ? "全校Top\(row+1): \(data.topCampus[row].place) (¥\(String(format: "%.0f", data.topCampus[row].amountRMB)))" : "--"
                switch cid {
                case "rank":
                    cell.stringValue = "第 \(row + 1) 名"
                    cell.textColor = row == 0 ? .systemOrange : .secondaryLabelColor
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: row == 0 ? .bold : .regular)
                case "place":
                    cell.stringValue = item.place
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                case "personal":
                    cell.stringValue = String(format: "%.2f 元", item.amountRMB)
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = .systemTeal
                case "ratio":
                    cell.stringValue = String(format: "%.1f%%", ratio)
                    cell.textColor = .secondaryLabelColor
                case "campus":
                    cell.stringValue = campusRef
                    cell.textColor = .tertiaryLabelColor
                default: break
                }

            case 1: // 消费频次分布
                guard row >= 0 && row < data.frequencyMine.count else { return nil }
                let item = data.frequencyMine[row]
                let totalFreq = data.frequencyMine.reduce(0) { $0 + $1.count }
                let ratio = totalFreq > 0 ? (Double(item.count) / Double(totalFreq) * 100.0) : 0
                let campusRef = (row < data.frequencyCampus.count) ? "全校Top\(row+1): \(data.frequencyCampus[row].place) (\(data.frequencyCampus[row].count)次)" : "--"
                let habits = [
                    "核心就餐地点 · 占绝对高频",
                    "日常优选用餐窗口",
                    "特色餐饮拓展点"
                ]
                let habitStr = row < habits.count ? habits[row] : "常规就餐去处"
                switch cid {
                case "rank":
                    cell.stringValue = "Top \(row + 1)"
                    cell.textColor = row == 0 ? .systemIndigo : .secondaryLabelColor
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: row == 0 ? .bold : .regular)
                case "place":
                    cell.stringValue = item.place
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                case "count":
                    cell.stringValue = "\(item.count) 次 (\(String(format: "%.1f%%", ratio)))"
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = .systemIndigo
                case "campusCount":
                    cell.stringValue = campusRef
                    cell.textColor = .tertiaryLabelColor
                case "analysis":
                    cell.stringValue = habitStr
                    cell.textColor = .secondaryLabelColor
                default: break
                }

            case 2: // 各学年月度日度
                guard row >= 0 && row < data.yearAverages.count else { return nil }
                let avg = data.yearAverages[row]
                let monthDiff = avg.average.personalMonthRMB - avg.average.campusMonthRMB
                switch cid {
                case "year":
                    cell.stringValue = "\(avg.academicYear) 学年"
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                case "myMonth":
                    cell.stringValue = String(format: "%.2f 元/月", avg.average.personalMonthRMB)
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                case "campusMonth":
                    cell.stringValue = String(format: "%.2f 元/月", avg.average.campusMonthRMB)
                    cell.textColor = .secondaryLabelColor
                case "monthDiff":
                    cell.stringValue = String(format: "%@%.2f 元", monthDiff > 0 ? "+" : "", monthDiff)
                    cell.textColor = monthDiff > 0 ? .systemOrange : .systemGreen
                case "myDay":
                    cell.stringValue = String(format: "%.2f 元/天", avg.average.personalDayRMB)
                case "campusDay":
                    cell.stringValue = String(format: "%.2f 元/天", avg.average.campusDayRMB)
                    cell.textColor = .secondaryLabelColor
                default: break
                }

            case 3: // 学分绩点
                let items = gpaRowItems(data: data)
                guard row >= 0 && row < items.count else { return nil }
                let item = items[row]
                switch cid {
                case "semester":
                    cell.stringValue = item.semester
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                case "credits":
                    cell.stringValue = item.credits
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = item.isHighlight ? .systemBlue : .labelColor
                case "gpa":
                    cell.stringValue = item.gpa
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
                    cell.textColor = item.isHighlight ? .systemPurple : .labelColor
                case "avgGpa":
                    cell.stringValue = item.avgGpa
                    cell.textColor = .secondaryLabelColor
                case "status":
                    cell.stringValue = item.status
                    cell.textColor = item.isHighlight ? .systemGreen : .secondaryLabelColor
                default: break
                }

            case 4: // 课程成绩
                let items = courseRowItems(data: data)
                guard row >= 0 && row < items.count else { return nil }
                let item = items[row]
                switch cid {
                case "category":
                    cell.stringValue = item.category
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                    cell.textColor = item.isHighlight ? .systemTeal : .labelColor
                case "name":
                    cell.stringValue = item.courseName
                    cell.textColor = .labelColor
                case "score":
                    cell.stringValue = item.score
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = item.isHighlight ? .systemGreen : .labelColor
                case "extremes":
                    cell.stringValue = item.extremes
                    cell.textColor = .secondaryLabelColor
                case "status":
                    cell.stringValue = item.status
                    cell.textColor = item.isHighlight ? .systemGreen : .secondaryLabelColor
                default: break
                }

            case 5: // 第二课堂
                let items = secondClassRowItems(data: data)
                guard row >= 0 && row < items.count else { return nil }
                let item = items[row]
                switch cid {
                case "module":
                    cell.stringValue = item.module
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                    cell.textColor = item.isHighlight ? .systemOrange : .labelColor
                case "scope":
                    cell.stringValue = item.scope
                    cell.textColor = .secondaryLabelColor
                case "stars":
                    cell.stringValue = item.stars
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = item.isHighlight ? .systemOrange : .labelColor
                case "standard":
                    cell.stringValue = item.standard
                    cell.textColor = .secondaryLabelColor
                case "evaluation":
                    cell.stringValue = item.evaluation
                    cell.textColor = item.isHighlight ? .systemGreen : .secondaryLabelColor
                default: break
                }

            case 6: // 学年消费总览
                guard row >= 0 && row < data.annual.count else { return nil }
                let record = data.annual[row]
                let difference = record.personalRMB - record.campusAverageRMB
                let pct = record.campusAverageRMB > 0 ? (difference / record.campusAverageRMB * 100.0) : 0
                switch cid {
                case "year": cell.stringValue = "\(record.academicYear) 学年"
                case "personal":
                    cell.stringValue = String(format: "%.2f 元", record.personalRMB)
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                case "average":
                    cell.stringValue = String(format: "%.2f 元", record.campusAverageRMB)
                    cell.textColor = .secondaryLabelColor
                case "difference":
                    cell.stringValue = String(format: "%@%.2f 元", difference > 0 ? "+" : "", difference)
                    cell.textColor = difference > 0 ? .systemOrange : .systemGreen
                case "ratio":
                    cell.stringValue = String(format: "%@%.1f%%", pct > 0 ? "高出 +" : "低于 ", abs(pct))
                    cell.textColor = pct > 0 ? .systemOrange : .systemGreen
                default: break
                }

            case 7: // 荣誉表彰与奖学金
                let items = awardRowItems(data: data)
                guard row >= 0 && row < items.count else { return nil }
                let item = items[row]
                switch cid {
                case "level":
                    cell.stringValue = item.level
                    cell.textColor = item.isHighlight ? .systemOrange : .secondaryLabelColor
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: item.isHighlight ? .semibold : .regular)
                case "name":
                    cell.stringValue = item.name
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: item.isHighlight ? .semibold : .regular)
                case "count":
                    cell.stringValue = item.count
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = item.isHighlight ? .systemOrange : .labelColor
                case "money":
                    cell.stringValue = item.money
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = item.isHighlight ? .systemGreen : .secondaryLabelColor
                case "status":
                    cell.stringValue = item.status
                    cell.textColor = item.isHighlight ? .systemGreen : .secondaryLabelColor
                default: break
                }

            case 8: // 志愿公益与德育工时
                let items = volunteerRowItems(data: data)
                guard row >= 0 && row < items.count else { return nil }
                let item = items[row]
                switch cid {
                case "module":
                    cell.stringValue = item.module
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: item.isHighlight ? .semibold : .regular)
                case "scope":
                    cell.stringValue = item.scope
                    cell.textColor = .secondaryLabelColor
                case "personal":
                    cell.stringValue = item.personal
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = item.isHighlight ? .systemGreen : .labelColor
                case "average":
                    cell.stringValue = item.average
                    cell.textColor = .secondaryLabelColor
                case "evaluation":
                    cell.stringValue = item.evaluation
                    cell.textColor = item.isHighlight ? .systemGreen : .secondaryLabelColor
                default: break
                }

            case 9: // 体质健康
                let items = healthRowItems(data: data)
                guard row >= 0 && row < items.count else { return nil }
                let item = items[row]
                switch cid {
                case "year":
                    cell.stringValue = item.year
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
                case "item":
                    cell.stringValue = item.item
                    cell.textColor = .labelColor
                case "score":
                    cell.stringValue = item.score
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = item.isHighlight ? .systemGreen : .systemOrange
                case "average":
                    cell.stringValue = item.average
                    cell.textColor = .secondaryLabelColor
                case "evaluation":
                    cell.stringValue = item.evaluation
                    cell.textColor = item.isHighlight ? .systemTeal : .systemOrange
                default: break
                }

            case 10: // 图书自习
                let items = libraryRowItems(data: data)
                guard row >= 0 && row < items.count else { return nil }
                let item = items[row]
                switch cid {
                case "category":
                    cell.stringValue = item.category
                    cell.font = NSFont.systemFont(ofSize: 11.5, weight: item.isHighlight ? .semibold : .regular)
                case "scope":
                    cell.stringValue = item.scope
                    cell.textColor = .secondaryLabelColor
                case "value":
                    cell.stringValue = item.value
                    cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                    cell.textColor = .systemIndigo
                case "benchmark":
                    cell.stringValue = item.benchmark
                    cell.textColor = .secondaryLabelColor
                case "evaluation":
                    cell.stringValue = item.evaluation
                    cell.textColor = item.isHighlight ? .systemGreen : .secondaryLabelColor
                default: break
                }

            default:
                break
            }
        }

        return cell
    }

    private func gpaRowItems(data: StudentPortraitEatData) -> [GPARowItem] {
        var items: [GPARowItem] = []
        if let gpaList = data.gpaHistory {
            for pt in gpaList {
                let diff = pt.gpa - pt.averageGPA
                let diffStr = String(format: "%@%.2f", diff >= 0 ? "+" : "", diff)
                let status = diff >= 0 ? "领先年级均值 (\(diffStr)) · 优异" : "低于年级均值 (\(diffStr))"
                let creditText = pt.credits > 0 ? String(format: "修读 %.1f 学分", pt.credits) : "--"
                items.append(GPARowItem(
                    semester: "\(pt.semester) 学期",
                    credits: creditText,
                    gpa: String(format: "GPA %.2f", pt.gpa),
                    avgGpa: String(format: "年级均值 %.2f", pt.averageGPA),
                    status: status,
                    isHighlight: diff >= 0
                ))
            }
        }
        if let xf = data.completedCredits, let total = data.totalRequiredCredits, total > 0 {
            let pct = xf / total * 100.0
            items.append(GPARowItem(
                semester: "本科培养方案修读总要求",
                credits: String(format: "已修 %.1f / %.0f 学分", xf, total),
                gpa: String(format: "完成度 %.1f%%", pct),
                avgGpa: "标准学制 4 年",
                status: pct >= 30 ? "学业修读推进正常达标" : "学业修读推进中",
                isHighlight: true
            ))
        }
        return items
    }

    private func courseRowItems(data: StudentPortraitEatData) -> [CourseRowItem] {
        var items: [CourseRowItem] = []
        if let ext = data.courseExtremes {
            items.append(CourseRowItem(
                category: "历史最高分课程",
                courseName: ext.highestCourseName,
                score: String(format: "%.0f 分", ext.highestScore),
                extremes: "历史最高分",
                status: ext.highestScore >= 95 ? "满分优异 · 顶尖表现" : "优异表现",
                isHighlight: true
            ))
            items.append(CourseRowItem(
                category: "历史最低分课程",
                courseName: ext.lowestCourseName,
                score: String(format: "%.0f 分", ext.lowestScore),
                extremes: "历史最低分",
                status: ext.lowestScore >= 60 ? "成绩合格 · 建议巩固核心基础" : "需注意重修",
                isHighlight: false
            ))
        }
        if let typeStats = data.courseTypeStats {
            for stat in typeStats {
                let rangeStr = String(format: "最高 %.0f / 最低 %.0f", stat.highestScore, stat.lowestScore)
                items.append(CourseRowItem(
                    category: stat.categoryName,
                    courseName: "最高: \(stat.highestCourse) / 最低: \(stat.lowestCourse)",
                    score: String(format: "均分 %.2f", stat.averageScore),
                    extremes: rangeStr,
                    status: stat.averageScore >= 85 ? "课程均分表现优异" : (stat.averageScore >= 75 ? "基础扎实良好" : "合格通过"),
                    isHighlight: stat.averageScore >= 85
                ))
            }
        }
        return items
    }

    private func secondClassRowItems(data: StudentPortraitEatData) -> [SecondClassRowItem] {
        var items: [SecondClassRowItem] = []
        guard let sc = data.secondClass else { return items }

        items.append(SecondClassRowItem(
            module: "第二课堂达标考核",
            scope: "第二课堂成绩单必修与选修学时达标",
            stars: "必修 \(sc.requiredLevel) 级 · 选修 \(sc.electiveLevel) 级",
            standard: "考核合格达标",
            evaluation: "第二课堂成绩单考核通过",
            isHighlight: true
        ))

        let starItems: [(String, String, Int)] = [
            ("科技创新与创业", "学科竞赛、大创项目、学术科研、专利发明", sc.techInnovationStars),
            ("体育健身与锻炼", "阳光长跑、运动打卡、校运动会、竞技比赛", sc.sportsFitnessStars),
            ("公益服务与奉献", "青年志愿服务、学雷锋行动、社区公益服务", sc.publicWelfareStars),
            ("劳动实践与教育", "宿舍文明卫生、劳动周实操、校园劳动实践", sc.laborPracticeStars),
            ("文娱活动与美育", "校园文化节、高雅艺术进校园、艺术社团", sc.artsCultureStars),
            ("技能项目与认证", "专业技能培训、考级考证、计算机软件技能", sc.skillsProjectStars),
            ("社会实践与调研", "暑期三下乡、社会调研报告、政企挂职见习", sc.socialPracticeStars),
            ("思想政治与德育", "青年大学习、青马工程培训、主题党团日", sc.ideologicalStars)
        ]
        for (name, scope, star) in starItems {
            let starStr = String(repeating: "★", count: star) + String(repeating: "☆", count: max(0, 5 - star))
            let eval = star >= 5 ? "高段位表现 · 满星拔尖" : (star >= 4 ? "高段位表现 · 积极参与" : (star >= 2 ? "达标良好 · 踏实参与" : "待拓展学时"))
            items.append(SecondClassRowItem(
                module: name,
                scope: scope,
                stars: "\(starStr) (\(star)星)",
                standard: "满星 5★",
                evaluation: eval,
                isHighlight: star >= 4
            ))
        }

        return items
    }

    private func awardRowItems(data: StudentPortraitEatData) -> [AwardRowItem] {
        var items: [AwardRowItem] = []
        if let summary = data.awardSummary {
            items.append(AwardRowItem(
                level: "全部荣誉汇总",
                name: "学工系统已归档表彰与奖学金总计",
                count: "\(summary.totalCount) 项",
                money: summary.totalMoney > 0 ? String(format: "¥%.0f", summary.totalMoney) : "--",
                status: summary.totalCount > 0 ? "已表彰授奖达标" : "暂无表彰",
                isHighlight: summary.totalCount > 0
            ))
        }
        if let list = data.awardList {
            for it in list {
                let statusStr = it.count > 0 ? "已获评 \(it.count) 项表彰" : "暂未获评"
                items.append(AwardRowItem(
                    level: "\(it.name) 表彰",
                    name: "\(it.name)优秀个人 / 综合奖学金等",
                    count: "\(it.count) 项",
                    money: it.totalMoney > 0 ? String(format: "¥%.0f", it.totalMoney) : "--",
                    status: statusStr,
                    isHighlight: it.count > 0
                ))
            }
        }
        return items
    }

    private func volunteerRowItems(data: StudentPortraitEatData) -> [VolunteerRowItem] {
        var items: [VolunteerRowItem] = []
        if let comp = data.volunteerCompare {
            let mult = comp.avgTotalHours > 0 ? String(format: " · %.1f倍", comp.myTotalHours / comp.avgTotalHours) : ""
            items.append(VolunteerRowItem(
                module: "累计志愿公益总时长",
                scope: "全校青年志愿服务工时累计",
                personal: String(format: "%.1f 小时", comp.myTotalHours),
                average: String(format: "全校均值 %.1f 小时", comp.avgTotalHours),
                evaluation: comp.myTotalHours >= comp.avgTotalHours ? "大幅领先全校均值\(mult) · 奉献先锋" : "积极奉献",
                isHighlight: true
            ))
            items.append(VolunteerRowItem(
                module: "志愿服务总参与场次",
                scope: "志愿公益活动参与频次",
                personal: "\(comp.myTimes) 次",
                average: String(format: "全校均值 %.1f 次", comp.avgTimes),
                evaluation: "累计多次躬行奉献",
                isHighlight: true
            ))
        }
        if let orgs = data.volunteerWelfare {
            for org in orgs {
                items.append(VolunteerRowItem(
                    module: org.organization,
                    scope: "服务组织 / 归属单位",
                    personal: String(format: "%.1f 小时", org.hours),
                    average: "组织认证工时",
                    evaluation: org.hours >= 20 ? "核心主力骨干 · 贡献突出" : "活跃奉献",
                    isHighlight: org.hours >= 20
                ))
            }
        }
        if let scores = data.virtueScores {
            for sc in scores {
                items.append(VolunteerRowItem(
                    module: sc.name,
                    scope: "德育积分与理论学习",
                    personal: String(format: "%.0f 积分", sc.myScore),
                    average: String(format: "全校均值 %.1f", sc.avgScore),
                    evaluation: sc.myScore >= sc.avgScore ? "达标领先 · 理论扎实" : "合格达标",
                    isHighlight: sc.myScore >= sc.avgScore
                ))
            }
        }
        return items
    }

    private func healthRowItems(data: StudentPortraitEatData) -> [HealthRowItem] {
        var items: [HealthRowItem] = []
        let tests = (data.healthTests ?? []).sorted(by: { $0.year > $1.year })
        for t in tests {
            let diff = t.myScore - t.avgScore
            let level = t.myScore >= 85 ? "优秀" : (t.myScore >= 75 ? "良好" : (t.myScore >= 60 ? "及格" : "需加强"))
            let diffStr = String(format: "%@%.1f分", diff >= 0 ? "+" : "", diff)
            items.append(HealthRowItem(
                year: "\(t.year) 年",
                item: "国家学生体质健康标准总分",
                score: String(format: "%.1f 分", t.myScore),
                average: String(format: "全校均值 %.2f 分", t.avgScore),
                evaluation: "\(level) · 相对全校均值 \(diffStr)",
                isHighlight: t.myScore >= 75
            ))
        }
        return items
    }

    private func libraryRowItems(data: StudentPortraitEatData) -> [LibraryRowItem] {
        var items: [LibraryRowItem] = []
        if let st = data.libraryStudyTime {
            items.append(LibraryRowItem(
                category: "全校学生在馆自习均时",
                scope: "全校读者年度在馆学习",
                value: String(format: "%.0f 小时", st.campusHours),
                benchmark: String(format: "入馆约 %.0f 次", st.campusCount),
                evaluation: "校园崇学尚读氛围浓厚",
                isHighlight: true
            ))
            items.append(LibraryRowItem(
                category: "班级专业在馆均时",
                scope: "所属专业班级在馆学习",
                value: String(format: "%.1f 小时", st.majorHours),
                benchmark: String(format: "入馆约 %.1f 次", st.majorCount),
                evaluation: "专业学习刻苦研读",
                isHighlight: true
            ))
            let period = st.campusPeriod.isEmpty ? "14:00-17:00" : st.campusPeriod
            items.append(LibraryRowItem(
                category: "读者高频入馆时段",
                scope: "全校自习入馆峰值区间",
                value: period,
                benchmark: "本专业: \(st.majorPeriod)",
                evaluation: "主流午后自习研讨时段",
                isHighlight: false
            ))
        }
        if let ranges = data.libraryBorrowRanges {
            for r in ranges {
                items.append(LibraryRowItem(
                    category: "图书借阅区间: \(r.range)",
                    scope: "全校借阅区间人数分布",
                    value: "\(r.studentCount) 人",
                    benchmark: "全校读者统计",
                    evaluation: r.studentCount >= 3000 ? "主力主流借阅群体" : "常态借阅群体",
                    isHighlight: r.studentCount >= 3000
                ))
            }
        }
        return items
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
            let headerStr: String
            if mode == 0 {
                headerStr = "套餐限额  ·  访问校内资源免费；校外资源日限 30GB、月限 400GB（每月前 200GB 免费，超出 0.5元/GB）；最多 3 个终端同时在线"
            } else if mode == 1 {
                headerStr = "宿舍用电限额与续航预估  ·  基于近期日均用电量动态测算剩余电费可用比例"
            } else {
                let bStr = String(format: "%.0f", SettingsManager.shared.campusCardDailyBudget)
                let tStr = String(format: "%.0f", SettingsManager.shared.campusCardLowWarningThreshold)
                headerStr = "校园一卡通充裕度与消费预算  ·  单日参考基准 \(bStr) 元 · 低于预警阈值 (\(tStr)元) 自动提醒充值（点击右上角「一卡通预算...」可自定义）"
            }
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
            let monthlyUsedMB = max(0.0, max(netData.usedMB ?? 0.0, fallbackUsedMB))
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
        } else if mode == 1 {
            // 宿舍电费模式下的进度展示
            let elec = ElectricityService.shared.latestData
            let fallbackElec = CampusHistoryManager.shared.latestElectricityRecord
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
        } else {
            // 校园一卡通模式下的进度展示
            let card = CampusCardService.shared.latestData
            let bal = card?.balanceRMB ?? 0.0
            let balDisplay = card?.displayBalance ?? "--"
            let ratio = max(0.0, min(1.0, bal / 200.0))
            let pct = Int(round(ratio * 100))

            drawQuotaRow(
                y: bounds.height - 68,
                padX: padX,
                title: "校园卡余额充裕度 (按 200 元常备基准)",
                subLeft: "当前卡内余额 \(balDisplay)  ·  预警红线 \(String(format: "%.0f", SettingsManager.shared.campusCardLowWarningThreshold)) 元",
                subRight: "充裕度 \(pct)%",
                remainRatio: ratio
            )

            let todaySpent = card?.todaySpentRMB() ?? 0.0
            let budget = max(1.0, SettingsManager.shared.campusCardDailyBudget)
            let budgetStr = String(format: "%.0f", budget)
            let budgetRemainRatio = max(0.0, min(1.0, (budget - todaySpent) / budget))
            drawQuotaRow(
                y: 14,
                padX: padX,
                title: "今日消费参考 (按单日 \(budgetStr) 元餐饮/日常基准)",
                subLeft: "今日已消费 \(String(format: "%.2f", todaySpent)) 元 (共 \(card?.todayExpenseCount() ?? 0) 笔交易)",
                subRight: String(format: "今日已用 %.0f%%", min(100.0, (todaySpent / budget) * 100.0)),
                remainRatio: budgetRemainRatio
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
