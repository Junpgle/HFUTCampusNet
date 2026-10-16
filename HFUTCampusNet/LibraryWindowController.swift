import Foundation
import AppKit

/// 合肥工业大学图书馆控制台（纯原生 Cocoa 界面）：
/// 上半部分展示读者当前真实在借书目、应还日期倒计时与借阅历史记录（通过统一身份认证自动拉取）；
/// 下半部分支持按照校区（全部 / 翡翠湖 / 屯溪路 / 宣城）原生精准筛选与全校 OPAC 检索；
/// 检索结果支持真实的读者业务操作：收藏图书、加入书架、图书预约（绝不加载任何原始网页）。
public final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public static let shared = LibraryWindowController()

    // 顶部顶栏
    private var topBar: AdaptiveBoxView!
    private var statusLabel: NSTextField!
    private var syncButton: NSButton!

    // 上半部：指标卡片与个人借阅列表
    private var cardBoxes: [AdaptiveBoxView] = []
    private var cardValueLabels: [NSTextField] = []
    private var cardSubLabels: [NSTextField] = []
    private var borrowTabSegment: NSSegmentedControl!
    private var borrowScrollView: NSScrollView!
    private var borrowTableView: NSTableView!
    private var borrowEmptyLabel: NSTextField!

    // 中间部：检索与校区筛选控制面板
    private var searchSectionSeparator: NSBox!
    private var searchSectionTitle: NSTextField!
    private var campusFilterSegment: NSSegmentedControl!
    private var onlyHoldingsCheckbox: NSButton!
    private var searchField: NSSearchField!
    private var searchButton: NSButton!
    private var tagButtons: [NSButton] = []
    private var searchStatusLabel: NSTextField!

    // 下半部：原生检索结果汇总展示表格
    private var resultScrollView: NSScrollView!
    private var resultTableView: NSTableView!
    private var resultEmptyLabel: NSTextField!

    // 数据状态
    private let borrowManager = LibraryBorrowManager.shared
    private let searchService = LibrarySearchService.shared
    private var currentBorrowTab: Int = 0 // 0: 当前在借, 1: 历史借阅

    // 检索与筛选状态
    private var searchResults: [CampusBookItem] = []
    private var selectedCampusIndex: Int = 0 // 0: 全部校区, 1: 翡翠湖校区, 2: 屯溪路校区, 3: 宣城校区
    private var onlyWithHoldings: Bool = false
    private var isSearching: Bool = false

    private let campusPrefKey = "cn.edu.hfut.campusnet.library_campus_filter"

    private var displayedBorrowBooks: [CampusBorrowedBook] {
        return currentBorrowTab == 0 ? borrowManager.currentLoans : borrowManager.historyLoans
    }

    /// 根据校区筛选条件与“仅显示有纸质馆藏”过滤后的检索列表
    private var filteredSearchResults: [CampusBookItem] {
        let campusKeywords = ["", "翡翠湖", "屯溪路", "宣城"]
        let kw = (selectedCampusIndex >= 0 && selectedCampusIndex < campusKeywords.count) ? campusKeywords[selectedCampusIndex] : ""

        return searchResults.filter { item in
            // 1. 校区匹配筛选
            if !kw.isEmpty {
                let hasCampus = item.holdings.contains { $0.campus.contains(kw) }
                if !hasCampus {
                    return false
                }
            }

            // 2. 仅看有纸质馆藏
            if onlyWithHoldings {
                if kw.isEmpty {
                    if item.holdings.isEmpty { return false }
                } else {
                    let campusHoldings = item.holdings.filter { $0.campus.contains(kw) }
                    if campusHoldings.isEmpty { return false }
                }
            }

            return true
        }
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1140, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "合肥工业大学图书馆 · 读者借阅中心与校内馆藏检索"
        window.minSize = NSSize(width: 980, height: 740)
        window.center()
        super.init(window: window)
        window.delegate = self

        // 读取用户校区筛选偏好，默认优先当前校区或全部校区
        let savedPref = UserDefaults.standard.integer(forKey: campusPrefKey)
        if savedPref >= 0 && savedPref <= 3 {
            selectedCampusIndex = savedPref
        } else if SettingsManager.shared.dormCampus.contains("宣城") {
            selectedCampusIndex = 3
        } else {
            selectedCampusIndex = 0
        }

        setupUI()

        borrowManager.onDataChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.reloadBorrowUI()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI 构建

    private func setupUI() {
        guard let window else { return }
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        // 1. 顶栏
        topBar = AdaptiveBoxView(frame: NSRect(x: 0, y: 806, width: 1140, height: 54))
        topBar.dynamicBackgroundColor = .windowBackgroundColor
        content.addSubview(topBar)

        let heading = NSTextField(labelWithString: "合工大读者借阅中心 · 校内馆藏检索")
        heading.frame = NSRect(x: 20, y: 28, width: 340, height: 20)
        heading.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        topBar.addSubview(heading)

        statusLabel = NSTextField(labelWithString: "正在连接校内系统…")
        statusLabel.frame = NSRect(x: 20, y: 8, width: 700, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        topBar.addSubview(statusLabel)

        syncButton = NSButton(title: "🔄 同步借阅", target: self, action: #selector(onSyncFromCAS))
        syncButton.bezelStyle = .rounded
        syncButton.frame = NSRect(x: 995, y: 12, width: 105, height: 30)
        topBar.addSubview(syncButton)

        // 2. 指标卡片 (4张)
        let cardNames = ["当前在借图书", "7天内待还提醒", "逾期待还书目", "历史累计借阅"]
        for index in 0..<4 {
            let card = AdaptiveBoxView(frame: .zero)
            card.dynamicCornerRadius = 10
            card.dynamicBackgroundColor = NSColor.labelColor.withAlphaComponent(0.035)
            card.dynamicBorderColor = NSColor.labelColor.withAlphaComponent(0.10)
            card.dynamicBorderWidth = 1

            let title = NSTextField(labelWithString: cardNames[index])
            title.frame = NSRect(x: 10, y: 52, width: 135, height: 15)
            title.font = NSFont.systemFont(ofSize: 10.5)
            title.textColor = .secondaryLabelColor
            card.addSubview(title)

            let value = NSTextField(labelWithString: "--")
            value.frame = NSRect(x: 10, y: 24, width: 135, height: 24)
            value.font = NSFont.systemFont(ofSize: 18, weight: .bold)
            card.addSubview(value)

            let detail = NSTextField(labelWithString: "读取中")
            detail.frame = NSRect(x: 10, y: 6, width: 135, height: 14)
            detail.font = NSFont.systemFont(ofSize: 10)
            detail.textColor = .tertiaryLabelColor
            card.addSubview(detail)

            content.addSubview(card)
            cardBoxes.append(card)
            cardValueLabels.append(value)
            cardSubLabels.append(detail)
        }

        // 3. 个人借阅书目列表区
        let tabSegment = NSSegmentedControl(labels: ["当前在借 (0)", "借阅历史 (0)"], trackingMode: .selectOne, target: self, action: #selector(onBorrowTabChanged))
        tabSegment.selectedSegment = 0
        content.addSubview(tabSegment)
        self.borrowTabSegment = tabSegment

        borrowScrollView = NSScrollView(frame: .zero)
        borrowScrollView.hasVerticalScroller = true
        borrowScrollView.borderType = .bezelBorder

        borrowTableView = NSTableView(frame: borrowScrollView.bounds)
        borrowTableView.rowHeight = 36
        borrowTableView.usesAlternatingRowBackgroundColors = true
        borrowTableView.headerView = NSTableHeaderView()
        borrowTableView.delegate = self
        borrowTableView.dataSource = self

        let bColTitle = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("b_title"))
        bColTitle.title = "书名 / 著者 / 出版社"
        bColTitle.resizingMask = [.autoresizingMask, .userResizingMask]
        borrowTableView.addTableColumn(bColTitle)

        let bColLoc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("b_loc"))
        bColLoc.title = "索书号 / 借出馆藏地"
        bColLoc.resizingMask = [.autoresizingMask, .userResizingMask]
        borrowTableView.addTableColumn(bColLoc)

        let bColDue = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("b_due"))
        bColDue.title = "借还日期 / 状态"
        bColDue.resizingMask = [.autoresizingMask, .userResizingMask]
        borrowTableView.addTableColumn(bColDue)

        borrowScrollView.documentView = borrowTableView
        content.addSubview(borrowScrollView)

        borrowEmptyLabel = NSTextField(wrappingLabelWithString: "暂无在借书目（全部借阅均已归还）")
        borrowEmptyLabel.alignment = .center
        borrowEmptyLabel.font = NSFont.systemFont(ofSize: 12)
        borrowEmptyLabel.textColor = .tertiaryLabelColor
        borrowEmptyLabel.isHidden = true
        borrowScrollView.addSubview(borrowEmptyLabel)

        // 4. 中间：分割线与检索控制面板
        searchSectionSeparator = NSBox(frame: .zero)
        searchSectionSeparator.boxType = .separator
        content.addSubview(searchSectionSeparator)

        searchSectionTitle = NSTextField(labelWithString: "校内图书借阅与全校馆藏检索")
        searchSectionTitle.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        content.addSubview(searchSectionTitle)

        // 校区筛选分段控制组件
        campusFilterSegment = NSSegmentedControl(labels: ["全部校区", "翡翠湖校区", "屯溪路校区", "宣城校区"], trackingMode: .selectOne, target: self, action: #selector(onCampusFilterChanged(_:)))
        campusFilterSegment.selectedSegment = selectedCampusIndex
        content.addSubview(campusFilterSegment)

        onlyHoldingsCheckbox = NSButton(checkboxWithTitle: "仅看有纸质馆藏", target: self, action: #selector(onOnlyHoldingsToggled(_:)))
        onlyHoldingsCheckbox.font = NSFont.systemFont(ofSize: 11)
        onlyHoldingsCheckbox.state = onlyWithHoldings ? .on : .off
        content.addSubview(onlyHoldingsCheckbox)

        // 搜索输入框与按钮
        searchField = NSSearchField(frame: .zero)
        searchField.placeholderString = "输入书名、著者、ISBN或索书号 (如：朝花夕拾 / 计算机网络)..."
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(onSearchTriggered)
        content.addSubview(searchField)

        searchButton = NSButton(title: "立即检索", target: self, action: #selector(onSearchTriggered))
        searchButton.bezelStyle = .rounded
        content.addSubview(searchButton)

        // 快捷搜索胶囊
        let tags = ["朝花夕拾", "编译原理", "计算机网络", "操作系统", "算法导论", "考研英语"]
        for tag in tags {
            let tagBtn = NSButton(title: tag, target: self, action: #selector(onTagClicked(_:)))
            tagBtn.bezelStyle = .inline
            tagBtn.font = NSFont.systemFont(ofSize: 11)
            content.addSubview(tagBtn)
            tagButtons.append(tagBtn)
        }

        searchStatusLabel = NSTextField(labelWithString: "输入关键词开始检索全校纸电馆藏与借阅状态")
        searchStatusLabel.font = NSFont.systemFont(ofSize: 11)
        searchStatusLabel.textColor = .secondaryLabelColor
        content.addSubview(searchStatusLabel)

        // 5. 原生检索结果汇总展示表格 (NSTableView)
        resultScrollView = NSScrollView(frame: .zero)
        resultScrollView.hasVerticalScroller = true
        resultScrollView.borderType = .bezelBorder

        resultTableView = NSTableView(frame: resultScrollView.bounds)
        resultTableView.rowHeight = 68
        resultTableView.usesAlternatingRowBackgroundColors = true
        resultTableView.headerView = NSTableHeaderView()
        resultTableView.delegate = self
        resultTableView.dataSource = self

        let rColBook = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r_book"))
        rColBook.title = "图书出版信息"
        rColBook.resizingMask = [.autoresizingMask, .userResizingMask]
        resultTableView.addTableColumn(rColBook)

        let rColHolding = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r_holding"))
        rColHolding.title = "校区借阅馆藏分布 (翡翠湖 / 屯溪路 / 宣城)"
        rColHolding.resizingMask = [.autoresizingMask, .userResizingMask]
        resultTableView.addTableColumn(rColHolding)

        let rColAction = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r_action"))
        rColAction.title = "读者操作"
        rColAction.width = 175
        resultTableView.addTableColumn(rColAction)

        resultScrollView.documentView = resultTableView
        content.addSubview(resultScrollView)

        resultEmptyLabel = NSTextField(wrappingLabelWithString: "暂无检索结果\n请在上方搜索框输入图书关键词并按回车")
        resultEmptyLabel.alignment = .center
        resultEmptyLabel.font = NSFont.systemFont(ofSize: 12)
        resultEmptyLabel.textColor = .tertiaryLabelColor
        resultEmptyLabel.frame = resultScrollView.bounds
        resultScrollView.addSubview(resultEmptyLabel)

        layoutSubviews()
        reloadBorrowUI()

        // 首次打开自动从 CAS SSO 同步在借书目
        onSyncFromCAS()

        // 默认检索
        searchField.stringValue = "朝花夕拾"
        performSearch(keyword: "朝花夕拾")
    }

    // MARK: - 几何排版与窗口自适应布局（严格杜绝重叠与错位）

    private func layoutSubviews() {
        guard let content = window?.contentView else { return }
        let width = content.bounds.width
        let height = content.bounds.height
        let side: CGFloat = 20

        // 1. 顶栏排版
        let topBarH: CGFloat = 52
        let topBarY = height - topBarH
        topBar?.frame = NSRect(x: 0, y: topBarY, width: width, height: topBarH)
        syncButton?.frame = NSRect(x: width - side - 110, y: 11, width: 110, height: 30)
        statusLabel?.frame = NSRect(x: 20, y: 8, width: max(200, width - 260), height: 16)

        // 2. 上半部分（个人借阅工作台）
        let upperH: CGFloat = 175
        let upperY = topBarY - upperH - 10
        let leftW: CGFloat = 310
        let rightW = max(420, width - side * 3 - leftW)

        // 2x2 指标卡片
        let cardW = floor((leftW - 10) / 2)
        let cardH: CGFloat = 78
        for (i, card) in cardBoxes.enumerated() {
            let col = i % 2
            let row = i / 2
            let x = side + CGFloat(col) * (cardW + 10)
            let y = upperY + (row == 0 ? cardH + 10 : 0)
            card.frame = NSRect(x: x, y: y, width: cardW, height: cardH)
        }

        // 右侧在借书目表格与标签
        let tableX = side + leftW + side
        borrowTabSegment?.frame = NSRect(x: tableX, y: upperY + upperH - 28, width: min(280, rightW), height: 26)
        borrowScrollView?.frame = NSRect(x: tableX, y: upperY, width: rightW, height: upperH - 34)
        borrowEmptyLabel?.frame = NSRect(x: 0, y: (upperH - 90) / 2, width: rightW, height: 40)

        // 自适应借阅表格各列宽度
        if let bTable = borrowTableView, bTable.tableColumns.count >= 3 {
            let bCols = bTable.tableColumns
            let bTotal = rightW - 20
            bCols[2].width = 180
            bCols[1].width = max(180, floor((bTotal - 180) * 0.45))
            bCols[0].width = max(240, bTotal - bCols[1].width - bCols[2].width)
        }

        // 3. 中间部分：检索控制面板（精确定位 3 行控制栏，彻底解决挤压与重叠）
        let sepY = upperY - 12
        searchSectionSeparator?.frame = NSRect(x: side, y: sepY, width: width - side * 2, height: 1)

        // 第 1 行 (y = sepY - 32)：板块标题 + 校区筛选 Segment + 仅看纸质 Checkbox
        let row1Y = sepY - 32
        searchSectionTitle?.frame = NSRect(x: side, y: row1Y + 3, width: 215, height: 20)
        let campusSegW: CGFloat = 330
        campusFilterSegment?.frame = NSRect(x: side + 220, y: row1Y, width: campusSegW, height: 26)
        onlyHoldingsCheckbox?.frame = NSRect(x: side + 220 + campusSegW + 16, y: row1Y + 3, width: 140, height: 20)

        // 第 2 行 (y = row1Y - 34)：检索框 + 检索按钮 + 快捷标签
        let row2Y = row1Y - 34
        let searchW: CGFloat = min(340, max(250, width * 0.28))
        searchField?.frame = NSRect(x: side, y: row2Y, width: searchW, height: 28)
        searchButton?.frame = NSRect(x: side + searchW + 8, y: row2Y - 1, width: 85, height: 30)

        var tagX = side + searchW + 101
        for tagBtn in tagButtons {
            let btnW = CGFloat(tagBtn.title.count * 14 + 18)
            if tagX + btnW <= width - side {
                tagBtn.frame = NSRect(x: tagX, y: row2Y + 3, width: btnW, height: 22)
                tagBtn.isHidden = false
                tagX += btnW + 8
            } else {
                tagBtn.isHidden = true
            }
        }

        // 第 3 行 (y = row2Y - 24)：检索汇总与统计状态文本（预留独立高度，绝不压在表格上）
        let row3Y = row2Y - 24
        searchStatusLabel?.frame = NSRect(x: side + 2, y: row3Y, width: width - side * 2, height: 18)

        // 4. 下半部分：全校馆藏检索表格（从 row3Y - 10 开始，顶部与文字完全留白）
        let tableTop = row3Y - 10
        let resultY: CGFloat = 16
        let resultH = max(220, tableTop - resultY)
        resultScrollView?.frame = NSRect(x: side, y: resultY, width: width - side * 2, height: resultH)
        resultEmptyLabel?.frame = NSRect(x: 0, y: (resultH - 60) / 2, width: width - side * 2, height: 50)

        // 自适应检索结果表格各列宽度
        if let rTable = resultTableView, rTable.tableColumns.count >= 3 {
            let rCols = rTable.tableColumns
            let rTotal = (width - side * 2) - 20
            rCols[2].width = 175
            rCols[0].width = max(340, floor((rTotal - 175) * 0.40))
            rCols[1].width = max(400, rTotal - rCols[0].width - rCols[2].width)
        }
    }

    public func windowDidResize(_ notification: Notification) {
        layoutSubviews()
    }

    public override func showWindow(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reloadBorrowUI()
        onSyncFromCAS()
    }

    // MARK: - 借阅数据与统一身份认证同步

    @objc private func onSyncFromCAS() {
        syncButton?.isEnabled = false
        syncButton?.title = "同步中…"
        statusLabel?.stringValue = "正在通过合工大统一身份认证 (CAS SSO) 同步借阅中心数据…"

        borrowManager.syncWithRemote(forceSSO: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncButton?.isEnabled = true
                self.syncButton?.title = "🔄 同步借阅"

                switch result {
                case .success:
                    let currentCount = self.borrowManager.currentLoans.count
                    let histCount = self.borrowManager.historyLoans.count
                    let user = SettingsManager.shared.portalUsername.isEmpty ? "" : "学号 \(SettingsManager.shared.portalUsername) · "
                    self.statusLabel?.stringValue = "\(user)同步成功：当前在借 \(currentCount) 册 · 借阅历史 \(histCount) 册 · \(self.borrowManager.statusSummaryText)"
                    self.reloadBorrowUI()

                case .failure(let error):
                    self.statusLabel?.stringValue = "同步提示：\(error.localizedDescription)"
                    self.reloadBorrowUI()
                }
            }
        }
    }

    private func reloadBorrowUI() {
        let current = borrowManager.currentLoans
        let history = borrowManager.historyLoans
        let overdue = borrowManager.overdueLoans
        let dueSoon = borrowManager.dueSoonLoans

        // 卡片 0: 当前在借
        cardValueLabels[0].stringValue = "\(current.count) 册"
        cardSubLabels[0].stringValue = current.isEmpty ? "无在借书目" : "在借书目正常"

        // 卡片 1: 7天内待还提醒
        cardValueLabels[1].stringValue = "\(dueSoon.count) 册"
        if dueSoon.isEmpty {
            cardValueLabels[1].textColor = .labelColor
            cardSubLabels[1].stringValue = "近期无到期图书"
        } else {
            cardValueLabels[1].textColor = .systemOrange
            cardSubLabels[1].stringValue = "请尽快前往归还"
        }

        // 卡片 2: 逾期待还
        cardValueLabels[2].stringValue = "\(overdue.count) 册"
        if overdue.isEmpty {
            cardValueLabels[2].textColor = .labelColor
            cardSubLabels[2].stringValue = "无超期借阅图书"
        } else {
            cardValueLabels[2].textColor = .systemRed
            cardSubLabels[2].stringValue = "已产生逾期记录"
        }

        // 卡片 3: 历史累计借阅
        let totalCount = max(history.count, borrowManager.totalBorrowStatsCount)
        cardValueLabels[3].stringValue = "\(totalCount) 册"
        cardSubLabels[3].stringValue = "校内官方历史借阅"

        // 标签栏动态更新数量
        borrowTabSegment.setLabel("当前在借 (\(current.count))", forSegment: 0)
        borrowTabSegment.setLabel("借阅历史 (\(history.count))", forSegment: 1)

        borrowTableView.reloadData()

        if currentBorrowTab == 0 {
            borrowEmptyLabel.stringValue = "暂无在借书目（全部借阅均已归还）\n如需借书可参考下方全校馆藏检索并前往借阅处"
            borrowEmptyLabel.isHidden = !current.isEmpty
        } else {
            borrowEmptyLabel.stringValue = "暂无借阅历史记录"
            borrowEmptyLabel.isHidden = !history.isEmpty
        }
    }

    @objc private func onBorrowTabChanged(_ sender: NSSegmentedControl) {
        currentBorrowTab = sender.selectedSegment
        borrowTableView.reloadData()
        if currentBorrowTab == 0 {
            borrowEmptyLabel.stringValue = "暂无在借书目（全部借阅均已归还）\n如需借书可参考下方全校馆藏检索并前往借阅处"
            borrowEmptyLabel.isHidden = !borrowManager.currentLoans.isEmpty
        } else {
            borrowEmptyLabel.stringValue = "暂无借阅历史记录"
            borrowEmptyLabel.isHidden = !borrowManager.historyLoans.isEmpty
        }
    }

    // MARK: - 校区筛选与纸本馆藏切换

    @objc private func onCampusFilterChanged(_ sender: NSSegmentedControl) {
        selectedCampusIndex = sender.selectedSegment
        UserDefaults.standard.set(selectedCampusIndex, forKey: campusPrefKey)
        applyFilterAndReload()
    }

    @objc private func onOnlyHoldingsToggled(_ sender: NSButton) {
        onlyWithHoldings = (sender.state == .on)
        applyFilterAndReload()
    }

    private func applyFilterAndReload() {
        resultTableView.reloadData()
        updateSearchStatusSummary()

        let filtered = filteredSearchResults
        resultEmptyLabel.isHidden = !filtered.isEmpty
        if filtered.isEmpty && !searchResults.isEmpty {
            let campusNames = ["全部校区", "翡翠湖校区", "屯溪路校区", "宣城校区"]
            let cName = (selectedCampusIndex >= 0 && selectedCampusIndex < campusNames.count) ? campusNames[selectedCampusIndex] : ""
            resultEmptyLabel.stringValue = "【\(cName)】暂无相关纸质在馆图书\n请尝试切换校区或取消「仅看纸质馆藏」"
        } else if searchResults.isEmpty {
            resultEmptyLabel.stringValue = "暂无检索结果\n请在上方搜索框输入图书关键词并按回车"
        }
    }

    private func updateSearchStatusSummary() {
        let total = searchResults.count
        let filtered = filteredSearchResults.count
        let campusNames = ["全部校区", "翡翠湖校区", "屯溪路校区", "宣城校区"]
        let campusKeywords = ["", "翡翠湖", "屯溪路", "宣城"]
        let cName = (selectedCampusIndex >= 0 && selectedCampusIndex < campusNames.count) ? campusNames[selectedCampusIndex] : "全部校区"
        let kw = (selectedCampusIndex >= 0 && selectedCampusIndex < campusKeywords.count) ? campusKeywords[selectedCampusIndex] : ""

        if total == 0 {
            searchStatusLabel.stringValue = "输入关键词开始检索全校纸电馆藏与借阅状态"
            return
        }

        if selectedCampusIndex == 0 {
            let physicalBooks = searchResults.filter { !$0.holdings.isEmpty }.count
            let totalCopies = searchResults.reduce(0) { $0 + $1.holdings.count }
            let availCopies = searchResults.reduce(0) { $0 + $1.availableCount }
            searchStatusLabel.stringValue = "检索完成：找到 \(total) 种图书 (其中 \(physicalBooks) 种有纸本馆藏) · 全校共 \(totalCopies) 册 · 可借 \(availCopies) 册"
        } else {
            let campusHoldings = searchResults.flatMap { $0.holdings.filter { $0.campus.contains(kw) } }
            let availCopies = campusHoldings.filter { $0.isAvailable }.count
            searchStatusLabel.stringValue = "已筛选【\(cName)】：共 \(filtered) 种图书在该校区在馆 · 馆藏 \(campusHoldings.count) 册 (可借 \(availCopies) 册) · 全校共检索到 \(total) 种"
        }
    }

    // MARK: - NSTableViewDataSource & Delegate (支持两个表格)

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == borrowTableView {
            return displayedBorrowBooks.count
        } else {
            return filteredSearchResults.count
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let cellId = col.identifier.rawValue

        if tableView == borrowTableView {
            guard row < displayedBorrowBooks.count else { return nil }
            let book = displayedBorrowBooks[row]
            return makeBorrowCell(identifier: cellId, book: book, row: row)
        } else {
            let filtered = filteredSearchResults
            guard row < filtered.count else { return nil }
            let item = filtered[row]
            return makeSearchResultCell(identifier: cellId, item: item, row: row)
        }
    }

    private func makeBorrowCell(identifier: String, book: CampusBorrowedBook, row: Int) -> NSView? {
        let cell = NSTextField()
        cell.isEditable = false
        cell.isBordered = false
        cell.drawsBackground = false
        cell.font = NSFont.systemFont(ofSize: 11.5)

        switch identifier {
        case "b_title":
            let titleText = book.author.isEmpty ? book.title : "《\(book.title)》 · \(book.author)"
            cell.stringValue = titleText
            cell.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            cell.toolTip = "书名：\(book.title)\n著者：\(book.author)\n出版社：\(book.publisher) (\(book.year))\nISBN：\(book.isbn)\n条形码：\(book.barcode)"
            return cell

        case "b_loc":
            let locText = book.callNumber.isEmpty ? book.location : "\(book.callNumber) · \(book.location)"
            cell.stringValue = locText
            cell.textColor = .secondaryLabelColor
            cell.toolTip = locText
            return cell

        case "b_due":
            if book.isReturned {
                let retDate = book.realReturnDate?.prefix(10) ?? "已归还"
                cell.stringValue = "还于 \(retDate) [已还]"
                cell.textColor = .secondaryLabelColor
            } else {
                let duePrefix = book.dueDate.prefix(10)
                cell.stringValue = "应还 \(duePrefix) [\(book.statusBadgeText)]"
                cell.textColor = book.statusColor
                cell.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            }
            return cell

        default:
            return nil
        }
    }

    private func makeSearchResultCell(identifier: String, item: CampusBookItem, row: Int) -> NSView? {
        switch identifier {
        case "r_book":
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 68))

            let titleLabel = NSTextField(labelWithString: "📖 《\(item.title)》")
            titleLabel.frame = NSRect(x: 6, y: 42, width: 370, height: 18)
            titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            container.addSubview(titleLabel)

            let authorText = item.authors.isEmpty ? item.publishers : "\(item.authors) · \(item.publishers) (\(item.year))"
            let authorLabel = NSTextField(labelWithString: authorText)
            authorLabel.frame = NSRect(x: 6, y: 23, width: 370, height: 16)
            authorLabel.font = NSFont.systemFont(ofSize: 11)
            authorLabel.textColor = .secondaryLabelColor
            container.addSubview(authorLabel)

            let isbnText = item.isbn.isEmpty ? "分类号: \(item.classNo)" : "ISBN: \(item.isbn) · 分类号: \(item.classNo)"
            let isbnLabel = NSTextField(labelWithString: isbnText)
            isbnLabel.frame = NSRect(x: 6, y: 5, width: 370, height: 14)
            isbnLabel.font = NSFont.systemFont(ofSize: 10)
            isbnLabel.textColor = .tertiaryLabelColor
            container.addSubview(isbnLabel)

            return container

        case "r_holding":
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 68))

            let campusKeywords = ["", "翡翠湖", "屯溪路", "宣城"]
            let filterKw = (selectedCampusIndex >= 0 && selectedCampusIndex < campusKeywords.count) ? campusKeywords[selectedCampusIndex] : ""

            // 根据校区筛选优先提取馆藏
            let relevantHoldings: [CampusBookHolding]
            if !filterKw.isEmpty {
                relevantHoldings = item.holdings.filter { $0.campus.contains(filterKw) }
            } else {
                relevantHoldings = item.holdings
            }

            if relevantHoldings.isEmpty {
                if item.holdings.isEmpty {
                    let emptyLbl = NSTextField(labelWithString: "暂无纸质在馆记录或为电子资源")
                    emptyLbl.frame = NSRect(x: 6, y: 25, width: 520, height: 18)
                    emptyLbl.font = NSFont.systemFont(ofSize: 11)
                    emptyLbl.textColor = .tertiaryLabelColor
                    container.addSubview(emptyLbl)
                } else {
                    let otherCampuses = Array(Set(item.holdings.map { $0.campus })).joined(separator: "、")
                    let otherLbl = NSTextField(labelWithString: "⚠️ 当前校区无馆藏 · 其它校区馆藏：\(otherCampuses) (全校共 \(item.holdings.count) 册)")
                    otherLbl.frame = NSRect(x: 6, y: 25, width: 520, height: 18)
                    otherLbl.font = NSFont.systemFont(ofSize: 11)
                    otherLbl.textColor = .systemOrange
                    container.addSubview(otherLbl)
                }
            } else {
                // 最多展示前两条馆藏位置
                let top2 = relevantHoldings.prefix(2)
                for (idx, h) in top2.enumerated() {
                    let y = idx == 0 ? 40 : 18
                    let statusColor: NSColor = h.isAvailable ? .systemGreen : .systemOrange
                    let statusBadge = h.status.isEmpty ? "在馆" : h.status
                    let holdingText = "📍 [\(h.campus)] \(h.location) · 索书号: \(h.callNumber) · 【\(statusBadge)】"
                    let hLabel = NSTextField(labelWithString: holdingText)
                    hLabel.frame = NSRect(x: 6, y: CGFloat(y), width: 525, height: 16)
                    hLabel.font = NSFont.systemFont(ofSize: 11)
                    if h.isAvailable {
                        hLabel.textColor = .labelColor
                    } else {
                        hLabel.textColor = statusColor
                    }
                    container.addSubview(hLabel)
                }

                if relevantHoldings.count > 2 {
                    let moreLabel = NSTextField(labelWithString: "该校区共有 \(relevantHoldings.count) 册馆藏，已展示主力借阅处")
                    moreLabel.frame = NSRect(x: 6, y: 2, width: 520, height: 13)
                    moreLabel.font = NSFont.systemFont(ofSize: 9.5)
                    moreLabel.textColor = .tertiaryLabelColor
                    container.addSubview(moreLabel)
                }
            }
            return container

        case "r_action":
            // 真实读者操作：收藏 / 书架 / 预约
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 175, height: 68))

            let collectBtn = NSButton(title: "⭐️ 收藏", target: self, action: #selector(onCollectBookAction(_:)))
            collectBtn.bezelStyle = .rounded
            collectBtn.font = NSFont.systemFont(ofSize: 11)
            collectBtn.frame = NSRect(x: 4, y: 22, width: 52, height: 24)
            collectBtn.tag = row
            collectBtn.toolTip = "将《\(item.title)》加入我的个人图书收藏"
            container.addSubview(collectBtn)

            let shelfBtn = NSButton(title: "🔖 书架", target: self, action: #selector(onAddShelfBookAction(_:)))
            shelfBtn.bezelStyle = .rounded
            shelfBtn.font = NSFont.systemFont(ofSize: 11)
            shelfBtn.frame = NSRect(x: 60, y: 22, width: 52, height: 24)
            shelfBtn.tag = row
            shelfBtn.toolTip = "将《\(item.title)》加入我的校内图书馆书架"
            container.addSubview(shelfBtn)

            let reserveBtn = NSButton(title: "📅 预约", target: self, action: #selector(onReserveBookAction(_:)))
            reserveBtn.bezelStyle = .rounded
            reserveBtn.font = NSFont.systemFont(ofSize: 11)
            reserveBtn.frame = NSRect(x: 116, y: 22, width: 52, height: 24)
            reserveBtn.tag = row
            reserveBtn.toolTip = "预约《\(item.title)》单册"
            container.addSubview(reserveBtn)

            return container

        default:
            return nil
        }
    }

    // MARK: - 真实业务操作：收藏 / 书架 / 预约

    @objc private func onCollectBookAction(_ sender: NSButton) {
        let row = sender.tag
        let filtered = filteredSearchResults
        guard row < filtered.count else { return }
        let item = filtered[row]

        sender.isEnabled = false
        searchService.collectBook(item: item) { [weak self] result in
            sender.isEnabled = true
            switch result {
            case .success(let msg):
                self?.showAlert(title: "收藏成功", message: msg)
            case .failure(let err):
                self?.showAlert(title: "收藏提示", message: err.localizedDescription)
            }
        }
    }

    @objc private func onAddShelfBookAction(_ sender: NSButton) {
        let row = sender.tag
        let filtered = filteredSearchResults
        guard row < filtered.count else { return }
        let item = filtered[row]

        sender.isEnabled = false
        searchService.addBookToShelf(item: item) { [weak self] result in
            sender.isEnabled = true
            switch result {
            case .success(let msg):
                self?.showAlert(title: "书架更新", message: msg)
            case .failure(let err):
                self?.showAlert(title: "书架提示", message: err.localizedDescription)
            }
        }
    }

    @objc private func onReserveBookAction(_ sender: NSButton) {
        let row = sender.tag
        let filtered = filteredSearchResults
        guard row < filtered.count else { return }
        let item = filtered[row]

        // 检查是否有物理条码
        let physicalHoldings = item.holdings.filter { !$0.barcode.isEmpty }
        guard !physicalHoldings.isEmpty else {
            showAlert(title: "暂无法预约", message: "《\(item.title)》暂无可预约的物理单册条码或为电子资源。")
            return
        }

        // 如果有多册，弹出选择；如果仅有一册，直接提交预约
        let selectedHolding: CampusBookHolding
        if physicalHoldings.count == 1 {
            selectedHolding = physicalHoldings[0]
        } else {
            let alert = NSAlert()
            alert.messageText = "选择预约校区单册"
            alert.informativeText = "请选择您希望预约的《\(item.title)》单册分布："
            for h in physicalHoldings.prefix(5) {
                alert.addButton(withTitle: "[\(h.campus)] \(h.location) · \(h.callNumber)")
            }
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if idx >= 0 && idx < physicalHoldings.count {
                selectedHolding = physicalHoldings[idx]
            } else {
                return
            }
        }

        sender.isEnabled = false
        searchService.reserveBook(barcode: selectedHolding.barcode) { [weak self] result in
            sender.isEnabled = true
            switch result {
            case .success(let msg):
                self?.showAlert(title: "预约申请已提交", message: "\(msg)\n预约单册：[\(selectedHolding.campus)] \(selectedHolding.location)")
            case .failure(let err):
                self?.showAlert(title: "预约提示", message: err.localizedDescription)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好的")
            alert.beginSheetModal(for: self.window ?? NSApp.mainWindow ?? NSWindow())
        }
    }

    // MARK: - 原生检索执行

    @objc private func onSearchTriggered() {
        let kw = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        performSearch(keyword: kw)
    }

    @objc private func onTagClicked(_ sender: NSButton) {
        searchField.stringValue = sender.title
        performSearch(keyword: sender.title)
    }

    private func performSearch(keyword: String) {
        isSearching = true
        searchStatusLabel.stringValue = "正在通过校内 OPAC 引擎检索「\(keyword)」全校馆藏与借阅状态…"
        resultEmptyLabel.stringValue = "正在检索全校图书…"
        resultEmptyLabel.isHidden = false

        searchService.search(keyword: keyword, page: 1, size: 20) { [weak self] result in
            guard let self else { return }
            self.isSearching = false
            switch result {
            case .success(let items):
                self.searchResults = items
                self.applyFilterAndReload()
            case .failure(let error):
                self.searchStatusLabel.stringValue = "检索失败：\(error.localizedDescription) · 请检查网络连接"
                self.resultEmptyLabel.stringValue = "检索失败，请点击「立即检索」重试"
                self.resultEmptyLabel.isHidden = false
            }
        }
    }
}
