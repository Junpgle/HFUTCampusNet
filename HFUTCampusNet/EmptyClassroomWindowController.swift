import Foundation
import AppKit

/// 单间教室的 08:00 - 22:00 横向时间轴（采用纯 CoreGraphics 绘制，零子视图开销，切换丝滑无卡顿）
public class ClassroomTimelineBarView: NSView {
    private var occupations: [ClassroomOccupation] = []
    private var isToday: Bool = true
    private var nowMinutes: Int = 0

    public override var isFlipped: Bool { true }

    private static let hourLabels: [(Int, NSString)] = [
        (8, "08:00"), (10, "10:00"), (12, "12:00"), (14, "14:00"),
        (16, "16:00"), (18, "18:00"), (20, "20:00"), (22, "22:00")
    ]

    private static let timeTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
        .foregroundColor: NSColor.tertiaryLabelColor
    ]

    private static let blockTextStyle: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    private static let blockTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
        .foregroundColor: NSColor.white,
        .paragraphStyle: blockTextStyle
    ]

    public func update(occupations: [ClassroomOccupation], isToday: Bool, nowMinutes: Int) {
        self.occupations = occupations
        self.isToday = isToday
        self.nowMinutes = nowMinutes
        if occupations.isEmpty {
            self.toolTip = "08:00 - 22:00 全天无排课"
        } else {
            self.toolTip = occupations.map { occ in
                let teacher = occ.teacherName.map { " · \($0)" } ?? ""
                return "\(occ.startTimeString)-\(occ.endTimeString) [\(occ.causeTitle)] \(occ.shortCourseName)\(teacher)"
            }.joined(separator: "\n")
        }
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let startMin = 8 * 60   // 08:00 (480)
        let endMin = 22 * 60    // 22:00 (1320)
        let totalMinutes = CGFloat(endMin - startMin)
        let barY: CGFloat = 2
        let barH: CGFloat = 20
        let totalW = bounds.width
        guard totalW > 20 else { return }

        // 1. 中性浅底轨（使用 labelColor 低透明度，浅色模式下为清爽浅灰 #F2F2F4，深色模式下为柔和深灰）
        let trackRect = NSRect(x: 0.5, y: barY + 0.5, width: totalW - 1, height: barH - 1)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 4, yRadius: 4)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        trackPath.fill()
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        trackPath.lineWidth = 1.0
        trackPath.stroke()

        // 2. 整点刻度与底部时间文字
        let tickColor = NSColor.labelColor.withAlphaComponent(0.08)
        for (h, label) in Self.hourLabels {
            let ratio = CGFloat((h * 60) - startMin) / totalMinutes
            let x = ratio * totalW

            if h > 8 && h < 22 {
                tickColor.setFill()
                NSRect(x: floor(x), y: barY + 1, width: 1, height: barH - 2).fill()
            }

            let labelW: CGFloat = 30
            let labelX = min(max(0, x - labelW / 2), totalW - labelW)
            label.draw(
                in: NSRect(x: labelX, y: barY + barH + 2, width: labelW, height: 12),
                withAttributes: Self.timeTextAttrs
            )
        }

        // 3. 占用时段色块
        for occ in occupations {
            let sMin = max(startMin, min(endMin, occ.startMinutes))
            let eMin = max(startMin, min(endMin, occ.endMinutes))
            guard eMin > sMin else { continue }

            let x = CGFloat(sMin - startMin) / totalMinutes * totalW
            let w = max(4, CGFloat(eMin - sMin) / totalMinutes * totalW)
            let blockRect = NSRect(x: x, y: barY + 1, width: w, height: barH - 2)
            let blockPath = NSBezierPath(roundedRect: blockRect, xRadius: 3, yRadius: 3)

            switch ClassroomOccupiedCause(rawValue: occ.activityType) {
            case .exam:
                NSColor.systemRed.withAlphaComponent(0.82).setFill()
            case .borrowed:
                NSColor.systemOrange.withAlphaComponent(0.80).setFill()
            default:
                NSColor.systemBlue.withAlphaComponent(0.76).setFill()
            }
            blockPath.fill()

            if w >= 36 {
                let titleStr = (w >= 88 ? "\(occ.startTimeString) \(occ.shortCourseName)" : occ.shortCourseName) as NSString
                titleStr.draw(
                    in: NSRect(x: x + 3, y: barY + 4, width: w - 6, height: 14),
                    withAttributes: Self.blockTextAttrs
                )
            }
        }

        // 4. 当前时间细线指示
        if isToday && nowMinutes >= startMin && nowMinutes <= endMin {
            let nowX = CGFloat(nowMinutes - startMin) / totalMinutes * totalW
            NSColor.systemRed.withAlphaComponent(0.85).setFill()
            NSRect(x: nowX - 0.75, y: barY - 1, width: 1.5, height: barH + 2).fill()
        }
    }
}

/// 自适应浅色/深色模式的卡片容器（在 draw(_:) 中实时解析动态 NSColor，避免 CALayer.cgColor 在浅色模式下残留深色背景）
private class ThemedCardView: FlippedTimelineView {
    var fillColor: NSColor = NSColor.labelColor.withAlphaComponent(0.035) {
        didSet { needsDisplay = true }
    }
    var strokeColor: NSColor? = NSColor.labelColor.withAlphaComponent(0.10) {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = 8.0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let insetRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: insetRect, xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        if let stroke = strokeColor {
            stroke.setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
    }
}

/// 自适应浅色/深色模式的细分隔线视图
private final class ThemedSeparatorView: NSView {
    var lineAlpha: CGFloat = 0.08
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(lineAlpha).setFill()
        bounds.fill()
    }
}

/// 自适应浅色/深色模式的圆点指示器视图
private final class ColorDotView: NSView {
    var dotColor: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = 3.0

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        dotColor.setFill()
        path.fill()
    }
}

/// 可复用的教室列表行视图（基于 NSTableCellView 虚拟化复用，仅创建屏幕可见的十余行）
private final class EmptyClassroomRowCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let statusDot = ColorDotView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let timelineBar = ClassroomTimelineBarView()
    private let actionButton = NSButton(title: "设为自习", target: nil, action: nil)
    private let bottomSeparator = ThemedSeparatorView()
    private var isHighlightedStudyRow: Bool = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)

        statusDot.cornerRadius = 3
        addSubview(statusDot)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        addSubview(timelineBar)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = NSFont.systemFont(ofSize: 11)
        addSubview(actionButton)

        bottomSeparator.lineAlpha = 0.07
        addSubview(bottomSeparator)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlightedStudyRow {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height

        nameLabel.frame = NSRect(x: 10, y: 8, width: 125, height: 18)
        metaLabel.frame = NSRect(x: 136, y: 10, width: 84, height: 15)
        statusDot.frame = NSRect(x: 10, y: 33, width: 6, height: 6)
        statusLabel.frame = NSRect(x: 20, y: 28, width: 202, height: 15)

        let timelineX: CGFloat = 230
        let actionW: CGFloat = 88
        let timelineW = max(240, w - timelineX - actionW - 20)
        timelineBar.frame = NSRect(x: timelineX, y: 8, width: timelineW, height: 36)
        actionButton.frame = NSRect(x: w - actionW - 6, y: 14, width: actionW - 4, height: 24)
        bottomSeparator.frame = NSRect(x: 8, y: h - 1, width: max(0, w - 16), height: 1)
    }

    func configure(
        room: EmptyClassroomItem,
        isToday: Bool,
        isTomorrow: Bool,
        nowMin: Int,
        isCurrentStudy: Bool,
        isNextDayStudy: Bool,
        target: AnyObject,
        action: Selector
    ) {
        if isHighlightedStudyRow != isCurrentStudy {
            isHighlightedStudyRow = isCurrentStudy
            needsDisplay = true
        }

        nameLabel.stringValue = room.nameZh

        if isCurrentStudy {
            metaLabel.stringValue = "当前自习"
            metaLabel.textColor = .controlAccentColor
        } else if isNextDayStudy {
            metaLabel.stringValue = "明日预约"
            metaLabel.textColor = .controlAccentColor
        } else if let seats = room.seatsForLesson, seats > 0 {
            metaLabel.stringValue = "\(room.inferredFloor)楼 · \(seats)座"
            metaLabel.textColor = .tertiaryLabelColor
        } else {
            metaLabel.stringValue = "\(room.inferredFloor)楼"
            metaLabel.textColor = .tertiaryLabelColor
        }

        let statusInfo = room.statusSummary(isToday: isToday, nowMin: nowMin)
        let dotColor: NSColor
        switch statusInfo.level {
        case .allDayFree, .restOfDayFree:
            dotColor = .systemGreen
        case .partiallyFree:
            dotColor = .systemTeal
        case .soonOccupied:
            dotColor = .systemOrange
        case .occupied:
            dotColor = .systemRed
        }
        statusDot.dotColor = dotColor
        statusLabel.stringValue = statusInfo.text
        statusLabel.toolTip = statusInfo.text

        timelineBar.update(occupations: room.sortedOccupations, isToday: isToday, nowMinutes: nowMin)

        if isTomorrow {
            actionButton.title = isNextDayStudy ? "已约明日" : "预约明日"
            actionButton.isEnabled = !isNextDayStudy
        } else {
            actionButton.title = isCurrentStudy ? "自习中" : "设为自习"
            actionButton.isEnabled = !isCurrentStudy
        }
        actionButton.tag = room.id
        actionButton.target = target
        actionButton.action = action
    }
}

/// 支持触控板横向滑动与鼠标滚轮上下滚动转横向滑动的容器
private final class HorizontalBuildingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else if let docView = documentView {
            let clip = contentView
            var newOrigin = clip.bounds.origin
            let delta = event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY : -event.scrollingDeltaY * 12.0
            let maxX = max(0, docView.bounds.width - clip.bounds.width)
            newOrigin.x = min(max(0, newOrigin.x + delta), maxX)
            clip.scroll(to: newOrigin)
            reflectScrolledClipView(clip)
        }
    }
}

/// 拦截鼠标点击与滚轮事件的遮罩视图（用于刷新期间置灰并禁止点击教室列表与推荐条，自适应深浅色模式）
private final class BlockingMaskView: FlippedTimelineView {
    var maskAlpha: CGFloat = 0.60
    var cornerRadius: CGFloat = 0.0

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(maskAlpha).setFill()
        path.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

public class EmptyClassroomWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = EmptyClassroomWindowController()

    private static let rowCellIdentifier = NSUserInterfaceItemIdentifier("EmptyClassroomRowCell")

    private var selectedCampus: StudyCampus = .xuancheng
    private var selectedDateString: String = EmptyClassroomService.todayDateString()
    /// nil 表示常用主力自习楼，正整数表示指定单栋教学楼 ID
    private var selectedBuildingId: Int? = nil
    /// nil 表示全部楼层，1...5 表示指定楼层
    private var selectedFloor: Int? = nil
    /// 0 全部，1 全天无课，2 余下无课，3 当前空闲
    private var statusFilterMode: Int = 0
    private var searchKeyword: String = ""

    private var currentRooms: [EmptyClassroomItem] = []
    private var filteredRooms: [EmptyClassroomItem] = []
    private var isWindowLoading: Bool = false
    private var loadingBaseMessage: String = "正在刷新空教室排课数据"
    private var loadingStartTime: Date?
    private var loadingElapsedTimer: Timer?
    private var feedbackHideWorkItem: DispatchWorkItem?

    // 顶部与筛选栏控件
    private var campusPopUp: NSPopUpButton!
    private var dateSegment: NSSegmentedControl!
    private var buildingScrollView: HorizontalBuildingScrollView!
    private var buildingDocView: FlippedTimelineView!
    private var buildingSegment: NSSegmentedControl!
    private var moreBuildingPopUp: NSPopUpButton!
    private var floorLabel: NSTextField!
    private var floorSegment: NSSegmentedControl!
    private var statusFilterSegment: NSSegmentedControl!
    private var searchField: NSSearchField!
    private var lastSyncLabel: NSTextField!
    private var syncButton: NSButton!

    private var summaryBarView: ThemedCardView!
    private var filterBarView: FlippedTimelineView!
    private var listScrollView: NSScrollView!
    private var tableView: NSTableView!
    private var emptyStateLabel: NSTextField!
    private var bottomStatusLabel: NSTextField!
    private var refreshTimer: Timer?

    // 刷新置灰遮罩与完成提示条
    private var summaryMaskView: BlockingMaskView!
    private var listLoadingMaskView: BlockingMaskView!
    private var loadingSpinner: NSProgressIndicator!
    private var loadingTextLabel: NSTextField!
    private var loadingSubtextLabel: NSTextField!
    private var feedbackBannerView: ThemedCardView!
    private var feedbackDotView: ColorDotView!
    private var feedbackTextLabel: NSTextField!

    private var mainBuildings: [ClassroomBuilding] = []
    private var extraBuildings: [ClassroomBuilding] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "空教室查询与自习室管理"
        window.minSize = NSSize(width: 940, height: 560)
        window.center()
        super.init(window: window)
        window.delegate = self

        selectedCampus = EmptyClassroomService.shared.currentPreferredCampus
        selectedDateString = EmptyClassroomService.todayDateString()

        setupUI()
        updateLastSyncTimeDisplay()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onEmptyClassroomUpdated),
            name: .emptyClassroomDidUpdate,
            object: nil
        )

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true, !self.isWindowLoading else { return }
            self.updateLastSyncTimeDisplay()
            self.renderSummaryBar()
            self.reloadFilteredRooms()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showWindowAndSync(selectTomorrow: Bool = false) {
        selectedCampus = EmptyClassroomService.shared.currentPreferredCampus
        if selectTomorrow {
            selectedDateString = EmptyClassroomService.tomorrowDateString()
            dateSegment?.selectedSegment = 1
        } else {
            selectedDateString = EmptyClassroomService.todayDateString()
            dateSegment?.selectedSegment = 0
        }
        selectCampusInPopUp(selectedCampus)
        updateLastSyncTimeDisplay()

        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        reloadCurrentCampusAndDate(forceRefresh: false, isManual: false)
    }

    // MARK: - 界面布局构建

    private func setupUI() {
        guard let window = self.window else { return }
        let root = FlippedTimelineView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        // 1. 顶部自习摘要栏（克制三栏信息条，自适应深浅色模式）
        summaryBarView = ThemedCardView(frame: NSRect(x: 16, y: 12, width: 948, height: 84))
        summaryBarView.autoresizingMask = [.width]
        summaryBarView.fillColor = NSColor.labelColor.withAlphaComponent(0.035)
        summaryBarView.strokeColor = NSColor.labelColor.withAlphaComponent(0.10)
        summaryBarView.cornerRadius = 8
        root.addSubview(summaryBarView)

        // 2. 工具与筛选栏
        filterBarView = FlippedTimelineView(frame: NSRect(x: 16, y: 106, width: 948, height: 68))
        filterBarView.autoresizingMask = [.width]
        root.addSubview(filterBarView)
        setupFilterControls()

        let topSep = NSBox(frame: NSRect(x: 16, y: 178, width: 948, height: 1))
        topSep.boxType = .separator
        topSep.autoresizingMask = [.width]
        root.addSubview(topSep)

        // 3. 原生虚拟化 NSTableView 列表区（仅渲染屏幕可见行，切换选项零延迟）
        listScrollView = NSScrollView(frame: NSRect(x: 16, y: 184, width: 948, height: 462))
        listScrollView.autoresizingMask = [.width, .height]
        listScrollView.hasVerticalScroller = true
        listScrollView.drawsBackground = false
        listScrollView.borderType = .noBorder

        tableView = NSTableView(frame: listScrollView.bounds)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        if #available(macOS 11.0, *) {
            tableView.style = .plain
        }
        let col = NSTableColumn(identifier: Self.rowCellIdentifier)
        col.resizingMask = .autoresizingMask
        col.width = 932
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self

        listScrollView.documentView = tableView
        root.addSubview(listScrollView)

        emptyStateLabel = NSTextField(labelWithString: "")
        emptyStateLabel.frame = NSRect(x: 16, y: 360, width: 948, height: 24)
        emptyStateLabel.autoresizingMask = [.width]
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.isHidden = true
        root.addSubview(emptyStateLabel)

        // 3.5 刷新期间的置灰拦截遮罩与完成结果浮层（全部基于 draw(_:) 动态适配深浅色模式）
        summaryMaskView = BlockingMaskView(frame: NSRect(x: 16, y: 12, width: 948, height: 84))
        summaryMaskView.autoresizingMask = [.width]
        summaryMaskView.cornerRadius = 8
        summaryMaskView.maskAlpha = 0.55
        summaryMaskView.isHidden = true
        root.addSubview(summaryMaskView)

        listLoadingMaskView = BlockingMaskView(frame: NSRect(x: 16, y: 184, width: 948, height: 462))
        listLoadingMaskView.autoresizingMask = [.width, .height]
        listLoadingMaskView.maskAlpha = 0.62
        listLoadingMaskView.isHidden = true

        let loadingBox = ThemedCardView(frame: NSRect(x: (948 - 410) / 2, y: (462 - 80) / 2, width: 410, height: 80))
        loadingBox.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        loadingBox.fillColor = .windowBackgroundColor
        loadingBox.strokeColor = NSColor.labelColor.withAlphaComponent(0.16)
        loadingBox.cornerRadius = 8

        loadingSpinner = NSProgressIndicator(frame: NSRect(x: 24, y: 29, width: 22, height: 22))
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingBox.addSubview(loadingSpinner)

        loadingTextLabel = NSTextField(labelWithString: "正在刷新空教室排课数据...")
        loadingTextLabel.frame = NSRect(x: 58, y: 17, width: 336, height: 18)
        loadingTextLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        loadingTextLabel.textColor = .labelColor
        loadingTextLabel.lineBreakMode = .byTruncatingTail
        loadingBox.addSubview(loadingTextLabel)

        loadingSubtextLabel = NSTextField(labelWithString: "需向教务系统汇总多栋教学楼今明两天课表，约需 10 秒，请耐心等待")
        loadingSubtextLabel.frame = NSRect(x: 58, y: 41, width: 336, height: 22)
        loadingSubtextLabel.font = NSFont.systemFont(ofSize: 11)
        loadingSubtextLabel.textColor = .secondaryLabelColor
        loadingSubtextLabel.lineBreakMode = .byTruncatingTail
        loadingBox.addSubview(loadingSubtextLabel)

        listLoadingMaskView.addSubview(loadingBox)
        root.addSubview(listLoadingMaskView)

        // 刷新结果提示浮层（成功/失败）
        feedbackBannerView = ThemedCardView(frame: NSRect(x: (980 - 380) / 2, y: 194, width: 380, height: 32))
        feedbackBannerView.autoresizingMask = [.minXMargin, .maxXMargin]
        feedbackBannerView.fillColor = .windowBackgroundColor
        feedbackBannerView.strokeColor = NSColor.labelColor.withAlphaComponent(0.18)
        feedbackBannerView.cornerRadius = 6
        feedbackBannerView.isHidden = true

        feedbackDotView = ColorDotView(frame: NSRect(x: 14, y: 12, width: 8, height: 8))
        feedbackDotView.cornerRadius = 4
        feedbackBannerView.addSubview(feedbackDotView)

        feedbackTextLabel = NSTextField(labelWithString: "")
        feedbackTextLabel.frame = NSRect(x: 28, y: 7, width: 340, height: 18)
        feedbackTextLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        feedbackTextLabel.textColor = .labelColor
        feedbackTextLabel.lineBreakMode = .byTruncatingTail
        feedbackBannerView.addSubview(feedbackTextLabel)
        root.addSubview(feedbackBannerView)

        // 4. 底部状态栏
        let bottomSep = NSBox(frame: NSRect(x: 16, y: 650, width: 948, height: 1))
        bottomSep.boxType = .separator
        bottomSep.autoresizingMask = [.width, .minYMargin]
        root.addSubview(bottomSep)

        bottomStatusLabel = NSTextField(labelWithString: "正在加载空教室数据...")
        bottomStatusLabel.frame = NSRect(x: 18, y: 656, width: 696, height: 16)
        bottomStatusLabel.autoresizingMask = [.width, .minYMargin]
        bottomStatusLabel.font = NSFont.systemFont(ofSize: 11)
        bottomStatusLabel.textColor = .secondaryLabelColor
        bottomStatusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(bottomStatusLabel)

        let legendView = FlippedTimelineView(frame: NSRect(x: 720, y: 656, width: 244, height: 16))
        legendView.autoresizingMask = [.minXMargin, .minYMargin]
        let legends: [(String, NSColor)] = [
            ("上课", NSColor.systemBlue.withAlphaComponent(0.75)),
            ("考试", NSColor.systemRed.withAlphaComponent(0.75)),
            ("借用/晚自习", NSColor.systemOrange.withAlphaComponent(0.75))
        ]
        var lx: CGFloat = 0
        for (name, color) in legends {
            let dot = ColorDotView(frame: NSRect(x: lx, y: 3, width: 8, height: 8))
            dot.cornerRadius = 2
            dot.dotColor = color
            legendView.addSubview(dot)

            let lbl = NSTextField(labelWithString: name)
            lbl.frame = NSRect(x: lx + 12, y: 0, width: 64, height: 14)
            lbl.font = NSFont.systemFont(ofSize: 11)
            lbl.textColor = .secondaryLabelColor
            lbl.sizeToFit()
            legendView.addSubview(lbl)
            lx += lbl.frame.width + 24
        }
        root.addSubview(legendView)
    }

    private func setupFilterControls() {
        let totalW = filterBarView.bounds.width // 948

        campusPopUp = NSPopUpButton(frame: NSRect(x: 0, y: 2, width: 104, height: 26), pullsDown: false)
        for c in StudyCampus.allCases {
            campusPopUp.addItem(withTitle: c.displayName)
            campusPopUp.lastItem?.representedObject = c.rawValue
        }
        selectCampusInPopUp(selectedCampus)
        campusPopUp.target = self
        campusPopUp.action = #selector(campusChanged(_:))
        filterBarView.addSubview(campusPopUp)

        dateSegment = NSSegmentedControl(
            labels: ["今天 (\(EmptyClassroomService.todayDateString().suffix(5)))", "明天 (\(EmptyClassroomService.tomorrowDateString().suffix(5)))"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(dateSegmentChanged(_:))
        )
        dateSegment.frame = NSRect(x: 110, y: 3, width: 184, height: 24)
        dateSegment.selectedSegment = 0
        filterBarView.addSubview(dateSegment)

        statusFilterSegment = NSSegmentedControl(
            labels: ["全部", "全天无课", "余下无课", "当前空闲"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(statusFilterChanged(_:))
        )
        statusFilterSegment.frame = NSRect(x: 300, y: 3, width: 248, height: 24)
        statusFilterSegment.selectedSegment = 0
        filterBarView.addSubview(statusFilterSegment)

        searchField = NSSearchField(frame: NSRect(x: 564, y: 3, width: 150, height: 24))
        searchField.autoresizingMask = [.minXMargin]
        searchField.placeholderString = "搜索教室号 (如 325)"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        filterBarView.addSubview(searchField)

        lastSyncLabel = NSTextField(labelWithString: "上次刷新：暂未同步")
        lastSyncLabel.frame = NSRect(x: 720, y: 7, width: 148, height: 16)
        lastSyncLabel.autoresizingMask = [.minXMargin]
        lastSyncLabel.alignment = .right
        lastSyncLabel.font = NSFont.systemFont(ofSize: 11)
        lastSyncLabel.textColor = .secondaryLabelColor
        lastSyncLabel.lineBreakMode = .byTruncatingTail
        filterBarView.addSubview(lastSyncLabel)

        syncButton = NSButton(title: "刷新", target: self, action: #selector(forceRefreshClicked))
        syncButton.bezelStyle = .rounded
        syncButton.frame = NSRect(x: 874, y: 1, width: 74, height: 28)
        syncButton.autoresizingMask = [.minXMargin]
        filterBarView.addSubview(syncButton)

        // 第二行左侧：教学楼标签 + 可横向滚动的常用教学楼分段条
        let bLabel = NSTextField(labelWithString: "教学楼")
        bLabel.frame = NSRect(x: 2, y: 40, width: 40, height: 16)
        bLabel.font = NSFont.systemFont(ofSize: 11.5)
        bLabel.textColor = .secondaryLabelColor
        filterBarView.addSubview(bLabel)

        let rightReservedW: CGFloat = 436 // 右侧固定留给「其他楼栋...」与「楼层」分段
        let scrollW = max(220, totalW - 44 - rightReservedW)
        buildingScrollView = HorizontalBuildingScrollView(frame: NSRect(x: 44, y: 34, width: scrollW, height: 28))
        buildingScrollView.autoresizingMask = [.width]
        buildingScrollView.drawsBackground = false
        buildingScrollView.borderType = .noBorder
        buildingScrollView.hasHorizontalScroller = false
        buildingScrollView.hasVerticalScroller = false
        buildingScrollView.toolTip = "楼栋较多时可左右滑动或使用鼠标滚轮切换"

        buildingDocView = FlippedTimelineView(frame: NSRect(x: 0, y: 0, width: scrollW, height: 28))
        buildingSegment = NSSegmentedControl(
            labels: ["常用教学楼"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(buildingSegmentChanged(_:))
        )
        buildingSegment.frame = NSRect(x: 0, y: 2, width: 180, height: 24)
        buildingSegment.selectedSegment = 0
        buildingDocView.addSubview(buildingSegment)
        buildingScrollView.documentView = buildingDocView
        filterBarView.addSubview(buildingScrollView)

        // 第二行右侧（固定锚定在右端，绝不会被左侧教学楼挤出窗口）：其他楼栋下拉框 + 楼层分段
        moreBuildingPopUp = NSPopUpButton(frame: NSRect(x: totalW - 428, y: 35, width: 124, height: 26), pullsDown: false)
        moreBuildingPopUp.autoresizingMask = [.minXMargin]
        moreBuildingPopUp.target = self
        moreBuildingPopUp.action = #selector(moreBuildingChanged(_:))
        filterBarView.addSubview(moreBuildingPopUp)

        floorLabel = NSTextField(labelWithString: "楼层")
        floorLabel.frame = NSRect(x: totalW - 294, y: 40, width: 30, height: 16)
        floorLabel.autoresizingMask = [.minXMargin]
        floorLabel.font = NSFont.systemFont(ofSize: 11.5)
        floorLabel.textColor = .secondaryLabelColor
        filterBarView.addSubview(floorLabel)

        floorSegment = NSSegmentedControl(
            labels: ["全部", "1楼", "2楼", "3楼", "4楼", "5楼"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(floorSegmentChanged(_:))
        )
        floorSegment.frame = NSRect(x: totalW - 262, y: 36, width: 262, height: 24)
        floorSegment.autoresizingMask = [.minXMargin]
        floorSegment.selectedSegment = 0
        filterBarView.addSubview(floorSegment)
    }

    public func windowDidResize(_ notification: Notification) {
        renderSummaryBar()
    }

    // MARK: - 刷新置灰状态、耗时读秒提示与上次刷新时间标注

    private func updateLastSyncTimeDisplay() {
        let service = EmptyClassroomService.shared
        let shortText = service.formattedShortLastSync(for: selectedCampus)
        let fullText = service.formattedFullLastSync(for: selectedCampus)
        lastSyncLabel?.stringValue = shortText
        lastSyncLabel?.toolTip = "\(selectedCampus.displayName) · \(fullText)"
        if #available(macOS 11.0, *) {
            window?.subtitle = "\(selectedCampus.displayName) · \(fullText)"
        }
    }

    private func setLoadingState(_ loading: Bool, message: String = "正在刷新空教室排课数据") {
        isWindowLoading = loading
        loadingElapsedTimer?.invalidate()
        loadingElapsedTimer = nil

        campusPopUp?.isEnabled = !loading
        dateSegment?.isEnabled = !loading
        statusFilterSegment?.isEnabled = !loading
        searchField?.isEnabled = !loading
        buildingSegment?.isEnabled = !loading
        moreBuildingPopUp?.isEnabled = !loading
        floorSegment?.isEnabled = !loading
        syncButton?.isEnabled = !loading
        tableView?.isEnabled = !loading

        if loading {
            loadingBaseMessage = message.replacingOccurrences(of: "...", with: "")
            loadingStartTime = Date()
            feedbackHideWorkItem?.cancel()
            feedbackBannerView?.isHidden = true

            syncButton?.title = "刷新中..."
            loadingTextLabel?.stringValue = "\(loadingBaseMessage)..."
            loadingSubtextLabel?.stringValue = "需向教务系统汇总多栋教学楼今明两天课表，约需 10 秒，请耐心等待"
            loadingSpinner?.startAnimation(nil)
            summaryMaskView?.isHidden = false
            listLoadingMaskView?.isHidden = false
            summaryBarView?.alphaValue = 0.45
            listScrollView?.alphaValue = 0.38
            bottomStatusLabel?.stringValue = "\(loadingBaseMessage)（通常耗时约 10 秒，请耐心等待）..."

            loadingElapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isWindowLoading, let start = self.loadingStartTime else { return }
                let secs = max(1, Int(Date().timeIntervalSince(start)))
                self.syncButton?.title = "刷新 \(secs)s"
                self.loadingTextLabel?.stringValue = "\(self.loadingBaseMessage)...（已等待 \(secs) 秒）"
                if secs >= 9 {
                    self.loadingSubtextLabel?.stringValue = "正在解析各教学楼全天排课数据，即将完成，请稍候..."
                }
                self.bottomStatusLabel?.stringValue = "\(self.loadingBaseMessage)（已等待 \(secs) 秒 · 教务接口汇总约需 10 秒，请耐心等待）..."
            }
        } else {
            loadingStartTime = nil
            syncButton?.title = "刷新"
            loadingSpinner?.stopAnimation(nil)
            summaryMaskView?.isHidden = true
            listLoadingMaskView?.isHidden = true
            summaryBarView?.alphaValue = 1.0
            listScrollView?.alphaValue = 1.0
            updateLastSyncTimeDisplay()
        }
    }

    private func showRefreshFeedback(success: Bool, message: String, showModalOnFail: Bool = false) {
        feedbackHideWorkItem?.cancel()

        feedbackDotView.dotColor = success ? .systemGreen : .systemRed
        feedbackBannerView.strokeColor = (success ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.45)
        feedbackTextLabel.stringValue = message
        feedbackTextLabel.sizeToFit()

        let bannerW = min(max(240, feedbackTextLabel.frame.width + 46), (window?.contentView?.bounds.width ?? 980) - 60)
        let rootW = window?.contentView?.bounds.width ?? 980
        feedbackBannerView.frame = NSRect(x: (rootW - bannerW) / 2, y: 194, width: bannerW, height: 32)
        feedbackTextLabel.frame = NSRect(x: 28, y: 7, width: bannerW - 40, height: 18)
        feedbackBannerView.alphaValue = 1.0
        feedbackBannerView.isHidden = false

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.feedbackBannerView.animator().alphaValue = 0.0
            }, completionHandler: {
                self.feedbackBannerView.isHidden = true
                self.feedbackBannerView.alphaValue = 1.0
            })
        }
        feedbackHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 2.8 : 4.5), execute: workItem)

        if !success && showModalOnFail, let win = self.window {
            let alert = NSAlert()
            alert.messageText = "空教室数据刷新失败"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: win, completionHandler: nil)
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredRooms.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < filteredRooms.count else { return nil }
        let room = filteredRooms[row]

        let cell: EmptyClassroomRowCellView
        if let reused = tableView.makeView(withIdentifier: Self.rowCellIdentifier, owner: self) as? EmptyClassroomRowCellView {
            cell = reused
        } else {
            cell = EmptyClassroomRowCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 52))
            cell.identifier = Self.rowCellIdentifier
        }

        let isToday = (selectedDateString == EmptyClassroomService.todayDateString())
        let isTomorrow = (selectedDateString == EmptyClassroomService.tomorrowDateString())
        let nowMin = EmptyClassroomService.currentMinutesOfDay()
        let isCurrentStudy = (room.id == SettingsManager.shared.currentStudyRoom?.roomId)
        let isNextDayStudy = (room.id == SettingsManager.shared.nextDayStudyRoom?.roomId)

        cell.configure(
            room: room,
            isToday: isToday,
            isTomorrow: isTomorrow,
            nowMin: nowMin,
            isCurrentStudy: isCurrentStudy,
            isNextDayStudy: isNextDayStudy,
            target: self,
            action: #selector(rowSetStudyRoomClicked(_:))
        )
        return cell
    }

    // MARK: - 数据拉取与筛选

    @objc private func onEmptyClassroomUpdated() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.window?.isVisible == true else { return }
            // 若当前正在由本窗口主动刷新，则等待刷新回调统一更新，避免中途闪烁
            guard !self.isWindowLoading, !EmptyClassroomService.shared.isSyncing else { return }
            self.rebuildBuildingControls()
            self.renderSummaryBar()
            self.reloadFilteredRooms()
        }
    }

    private func reloadCurrentCampusAndDate(forceRefresh: Bool, isManual: Bool = false) {
        let service = EmptyClassroomService.shared
        let hasCachedToday = !service.cachedStudyRooms(campus: selectedCampus, dateString: selectedDateString).isEmpty

        if forceRefresh || !hasCachedToday {
            setLoadingState(true, message: "正在刷新 \(selectedCampus.displayName) (\(selectedDateString)) 排课数据...")
        }

        service.syncTodayAndTomorrowStudyRooms(
            campus: selectedCampus,
            forceRefresh: forceRefresh
        ) { [weak self] syncResult in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rebuildBuildingControls()

                switch syncResult {
                case .failure(let err):
                    self.setLoadingState(false)
                    self.renderSummaryBar()
                    self.reloadFilteredRooms()
                    self.bottomStatusLabel.stringValue = "刷新失败：\(err.localizedDescription)"
                    self.showRefreshFeedback(
                        success: false,
                        message: "刷新失败：\(err.localizedDescription)",
                        showModalOnFail: isManual
                    )

                case .success:
                    // 若当前选中的是某栋非主力楼栋，则单独拉取该楼栋；否则直接读取刚刚同步好的主力楼栋缓存
                    self.applyCurrentRoomsFromCacheOrFetch(
                        forceRefresh: forceRefresh,
                        showCompletionFeedback: isManual || forceRefresh
                    )
                }
            }
        }
    }

    private func applyCurrentRoomsFromCacheOrFetch(
        forceRefresh: Bool = false,
        showCompletionFeedback: Bool = false
    ) {
        let service = EmptyClassroomService.shared
        let allBuildings = service.allBuildings.filter { $0.campusAssoc == selectedCampus.rawValue }
        let preferredIds = Set(allBuildings.filter { $0.isPreferredStudyBuilding }.map { $0.id })

        if selectedBuildingId == nil || (selectedBuildingId != nil && preferredIds.contains(selectedBuildingId!)) {
            let cached = service.cachedStudyRooms(campus: selectedCampus, dateString: selectedDateString)
            if !cached.isEmpty {
                if let bid = selectedBuildingId {
                    self.currentRooms = cached.filter { $0.buildingId == bid }
                } else {
                    self.currentRooms = cached
                }
                self.setLoadingState(false)
                self.renderSummaryBar()
                self.reloadFilteredRooms()
                if showCompletionFeedback {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "HH:mm:ss"
                    let timeStr = fmt.string(from: Date())
                    self.showRefreshFeedback(
                        success: true,
                        message: "刷新成功 · 已同步 \(selectedCampus.displayName) \(self.currentRooms.count) 间教室 (\(timeStr))"
                    )
                }
                return
            }
        }

        let targetIds: [Int]
        if let bid = selectedBuildingId {
            targetIds = [bid]
        } else if !preferredIds.isEmpty {
            targetIds = Array(preferredIds)
        } else {
            targetIds = allBuildings.map { $0.id }
        }

        guard !targetIds.isEmpty else {
            self.currentRooms = []
            self.setLoadingState(false)
            self.renderSummaryBar()
            self.reloadFilteredRooms()
            return
        }

        setLoadingState(true, message: "正在加载所选教学楼教室数据...")
        service.fetchRooms(
            dateString: selectedDateString,
            campus: selectedCampus,
            buildingIds: targetIds,
            forceRefresh: forceRefresh
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setLoadingState(false)
                switch result {
                case .success(let rooms):
                    self.currentRooms = rooms
                    self.renderSummaryBar()
                    self.reloadFilteredRooms()
                    if showCompletionFeedback {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "HH:mm:ss"
                        let timeStr = fmt.string(from: Date())
                        self.showRefreshFeedback(
                            success: true,
                            message: "刷新成功 · 已同步 \( rooms.count ) 间教室 (\(timeStr))"
                        )
                    }
                case .failure(let err):
                    self.renderSummaryBar()
                    self.reloadFilteredRooms()
                    self.bottomStatusLabel.stringValue = "加载失败：\(err.localizedDescription)"
                    self.showRefreshFeedback(
                        success: false,
                        message: "刷新失败：\(err.localizedDescription)",
                        showModalOnFail: showCompletionFeedback
                    )
                }
            }
        }
    }

    private func rebuildBuildingControls() {
        let buildings = EmptyClassroomService.shared.allBuildings.filter { $0.campusAssoc == selectedCampus.rawValue }
        mainBuildings = buildings.filter { $0.isPreferredStudyBuilding }
        extraBuildings = buildings.filter { !$0.isPreferredStudyBuilding }

        var segLabels = ["常用教学楼"]
        for b in mainBuildings {
            segLabels.append(b.cleanName)
        }
        buildingSegment.segmentCount = segLabels.count
        for (i, title) in segLabels.enumerated() {
            buildingSegment.setLabel(title, forSegment: i)
            buildingSegment.setWidth(0, forSegment: i)
        }
        buildingSegment.sizeToFit()
        var segFrame = buildingSegment.frame
        segFrame.origin.x = 0
        segFrame.origin.y = 2
        segFrame.size.height = 24
        buildingSegment.frame = segFrame
        buildingDocView.frame = NSRect(x: 0, y: 0, width: max(buildingScrollView.bounds.width, segFrame.width + 4), height: 28)

        moreBuildingPopUp.removeAllItems()
        moreBuildingPopUp.addItem(withTitle: "其他楼栋...")
        moreBuildingPopUp.lastItem?.representedObject = nil
        for b in mainBuildings {
            moreBuildingPopUp.addItem(withTitle: b.cleanName)
            moreBuildingPopUp.lastItem?.representedObject = b.id
        }
        if !mainBuildings.isEmpty && !extraBuildings.isEmpty {
            moreBuildingPopUp.menu?.addItem(NSMenuItem.separator())
        }
        for b in extraBuildings {
            moreBuildingPopUp.addItem(withTitle: b.cleanName)
            moreBuildingPopUp.lastItem?.representedObject = b.id
        }
        moreBuildingPopUp.isHidden = (mainBuildings.isEmpty && extraBuildings.isEmpty)

        if let bid = selectedBuildingId {
            if let mainIdx = mainBuildings.firstIndex(where: { $0.id == bid }) {
                buildingSegment.selectedSegment = mainIdx + 1
                moreBuildingPopUp.selectItem(at: 0)
            } else {
                buildingSegment.selectedSegment = -1
                for i in 0..<moreBuildingPopUp.numberOfItems {
                    if let itemBid = moreBuildingPopUp.item(at: i)?.representedObject as? Int, itemBid == bid {
                        moreBuildingPopUp.selectItem(at: i)
                        break
                    }
                }
            }
        } else {
            buildingSegment.selectedSegment = 0
            moreBuildingPopUp.selectItem(at: 0)
            buildingScrollView.contentView.scroll(to: .zero)
            buildingScrollView.reflectScrolledClipView(buildingScrollView.contentView)
        }
    }

    // MARK: - 1. 顶部三栏摘要条渲染

    private func renderSummaryBar() {
        summaryBarView.subviews.forEach { $0.removeFromSuperview() }

        let totalW = summaryBarView.bounds.width
        let colW = floor(totalW / 3.0)
        let service = EmptyClassroomService.shared

        for i in 1...2 {
            let vLine = ThemedSeparatorView(frame: NSRect(x: colW * CGFloat(i), y: 12, width: 1, height: 60))
            vLine.lineAlpha = 0.09
            summaryBarView.addSubview(vLine)
        }

        // --- 左栏：当前自习室与冲突换座 ---
        let col1 = FlippedTimelineView(frame: NSRect(x: 14, y: 10, width: colW - 28, height: 64))
        summaryBarView.addSubview(col1)

        let c1Header = NSTextField(labelWithString: "当前自习室")
        c1Header.frame = NSRect(x: 0, y: 0, width: 80, height: 15)
        c1Header.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        c1Header.textColor = .secondaryLabelColor
        col1.addSubview(c1Header)

        if let record = SettingsManager.shared.currentStudyRoom {
            let currentItem = service.currentStudyRoomItem()

            let clearBtn = NSButton(title: "取消", target: self, action: #selector(clearStudyRoomClicked))
            clearBtn.bezelStyle = .inline
            clearBtn.font = NSFont.systemFont(ofSize: 10.5)
            clearBtn.frame = NSRect(x: col1.bounds.width - 42, y: -1, width: 42, height: 17)
            col1.addSubview(clearBtn)

            let roomTitle = NSTextField(labelWithString: record.roomName)
            roomTitle.frame = NSRect(x: 72, y: -1, width: col1.bounds.width - 118, height: 17)
            roomTitle.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            roomTitle.textColor = .labelColor
            roomTitle.lineBreakMode = .byTruncatingTail
            col1.addSubview(roomTitle)

            if let room = currentItem {
                let (conflict, isOngoing, minsUntil, recs) = service.nearbySwitchRecommendations(for: room, limit: 3)
                if let occ = conflict {
                    let dot = makeDot(color: (isOngoing || (minsUntil ?? 99) <= 30) ? .systemOrange : .systemGreen, y: 24)
                    col1.addSubview(dot)

                    let statusStr: String
                    if isOngoing {
                        statusStr = "当前有\(occ.causeTitle)：\(occ.shortCourseName) (\(occ.startTimeString)-\(occ.endTimeString))，建议换至："
                    } else if let m = minsUntil, m <= 35 {
                        statusStr = "\(m)分钟后有\(occ.causeTitle) (\(occ.startTimeString) \(occ.shortCourseName))，建议换至："
                    } else {
                        statusStr = "可自习至 \(occ.startTimeString)（后续有\(occ.shortCourseName)），附近全空："
                    }
                    let statusLbl = NSTextField(labelWithString: statusStr)
                    statusLbl.frame = NSRect(x: 12, y: 20, width: col1.bounds.width - 12, height: 15)
                    statusLbl.font = NSFont.systemFont(ofSize: 11)
                    statusLbl.textColor = (isOngoing || (minsUntil ?? 99) <= 35) ? .systemOrange : .secondaryLabelColor
                    statusLbl.lineBreakMode = .byTruncatingTail
                    col1.addSubview(statusLbl)

                    var px: CGFloat = 0
                    for rec in recs.prefix(3) {
                        let btnTitle = "\(rec.room.shortRoomCode) (\(rec.proximity.badgeText.replacingOccurrences(of: "同楼层 · ", with: "")))"
                        let pill = makeCompactPillButton(
                            title: btnTitle,
                            toolTip: "点击切换自习室至 \(rec.room.nameZh)（\(rec.freeUntilText)）",
                            tag: rec.room.id,
                            action: #selector(quickSelectTodayRoom(_:))
                        )
                        if px + pill.frame.width <= col1.bounds.width {
                            pill.frame.origin = NSPoint(x: px, y: 40)
                            col1.addSubview(pill)
                            px += pill.frame.width + 4
                        }
                    }
                } else {
                    col1.addSubview(makeDot(color: .systemGreen, y: 24))
                    let statusLbl = NSTextField(labelWithString: "今日余下时段无课（至 22:00 闭楼无需换座）")
                    statusLbl.frame = NSRect(x: 12, y: 20, width: col1.bounds.width - 12, height: 15)
                    statusLbl.font = NSFont.systemFont(ofSize: 11)
                    statusLbl.textColor = .secondaryLabelColor
                    col1.addSubview(statusLbl)

                    let subLbl = NSTextField(labelWithString: "当所选教室排课变动时会自动提醒附近空教室")
                    subLbl.frame = NSRect(x: 0, y: 42, width: col1.bounds.width, height: 15)
                    subLbl.font = NSFont.systemFont(ofSize: 11)
                    subLbl.textColor = .tertiaryLabelColor
                    col1.addSubview(subLbl)
                }
            }
        } else {
            let statusLbl = NSTextField(labelWithString: "未设定")
            statusLbl.frame = NSRect(x: 72, y: 0, width: 80, height: 15)
            statusLbl.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            statusLbl.textColor = .tertiaryLabelColor
            col1.addSubview(statusLbl)

            let hintLbl = NSTextField(labelWithString: "点击右侧推荐教室或下方列表中的「设为自习」，即可在有课前收到隔壁空教室切换提醒。")
            hintLbl.frame = NSRect(x: 0, y: 22, width: col1.bounds.width, height: 34)
            hintLbl.font = NSFont.systemFont(ofSize: 11)
            hintLbl.textColor = .secondaryLabelColor
            hintLbl.maximumNumberOfLines = 2
            hintLbl.cell?.wraps = true
            col1.addSubview(hintLbl)
        }

        // --- 中栏：今日全天无课推荐 ---
        let col2 = FlippedTimelineView(frame: NSRect(x: colW + 14, y: 10, width: colW - 28, height: 64))
        summaryBarView.addSubview(col2)

        let c2Header = NSTextField(labelWithString: "今日全天无课推荐")
        c2Header.frame = NSRect(x: 0, y: 0, width: 140, height: 15)
        c2Header.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        c2Header.textColor = .secondaryLabelColor
        col2.addSubview(c2Header)

        let c2Sub = NSTextField(labelWithString: "08:00 - 22:00 无排课，点击即可设为当前自习室：")
        c2Sub.frame = NSRect(x: 0, y: 20, width: col2.bounds.width, height: 15)
        c2Sub.font = NSFont.systemFont(ofSize: 11)
        c2Sub.textColor = .tertiaryLabelColor
        col2.addSubview(c2Sub)

        let todayPicks = service.recommendedTodayAllDayFreeRooms(campus: selectedCampus, limit: 6)
        if todayPicks.isEmpty {
            let emptyLbl = NSTextField(labelWithString: service.isSyncing ? "正在同步..." : "暂无数据")
            emptyLbl.frame = NSRect(x: 0, y: 42, width: 150, height: 16)
            emptyLbl.font = NSFont.systemFont(ofSize: 11)
            emptyLbl.textColor = .tertiaryLabelColor
            col2.addSubview(emptyLbl)
        } else {
            var px: CGFloat = 0
            let curId = SettingsManager.shared.currentStudyRoom?.roomId
            for room in todayPicks {
                let isSelected = (room.id == curId)
                let pill = makeCompactPillButton(
                    title: room.nameZh,
                    toolTip: "\(room.nameZh)（\(room.inferredFloor)楼 · 全天无课）",
                    tag: room.id,
                    isHighlighted: isSelected,
                    action: #selector(quickSelectTodayRoom(_:))
                )
                if px + pill.frame.width <= col2.bounds.width {
                    pill.frame.origin = NSPoint(x: px, y: 40)
                    col2.addSubview(pill)
                    px += pill.frame.width + 4
                }
            }
        }

        // --- 右栏：晚间离校前 · 明日空教室推荐 ---
        let col3 = FlippedTimelineView(frame: NSRect(x: colW * 2 + 14, y: 10, width: colW - 28, height: 64))
        summaryBarView.addSubview(col3)

        let tomorrowRec = service.buildTomorrowRecommendation(campus: selectedCampus, limit: 5)
        let c3Header = NSTextField(labelWithString: "明日全天无课 (\(tomorrowRec.tomorrowDateString.suffix(5)))")
        c3Header.frame = NSRect(x: 0, y: 0, width: 180, height: 15)
        c3Header.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        c3Header.textColor = .secondaryLabelColor
        col3.addSubview(c3Header)

        let c3StatusStr: String
        if let curName = tomorrowRec.currentStudyRoomName {
            if tomorrowRec.isCurrentRoomAllDayFreeTomorrow {
                c3StatusStr = "\(curName) 明天继续全天无课，无需搬书"
            } else if let firstOcc = tomorrowRec.currentRoomTomorrowFirstOccupation {
                c3StatusStr = "\(curName) 明天 \(firstOcc.startTimeString) 有课，离校前建议搬至："
            } else {
                c3StatusStr = "离校前可预约明日全天无课且今晚空闲的教室："
            }
        } else {
            c3StatusStr = "离校前可提前搬书至明日全天无课教室："
        }
        let c3Sub = NSTextField(labelWithString: c3StatusStr)
        c3Sub.frame = NSRect(x: 0, y: 20, width: col3.bounds.width, height: 15)
        c3Sub.font = NSFont.systemFont(ofSize: 11)
        c3Sub.textColor = tomorrowRec.isCurrentRoomAllDayFreeTomorrow ? .labelColor : .tertiaryLabelColor
        c3Sub.lineBreakMode = .byTruncatingTail
        col3.addSubview(c3Sub)

        var tx: CGFloat = 0
        let nextId = SettingsManager.shared.nextDayStudyRoom?.roomId
        for cand in tomorrowRec.candidates {
            let isReserved = (cand.room.id == nextId)
            let pill = makeCompactPillButton(
                title: cand.room.nameZh,
                toolTip: "\(cand.room.nameZh)（\(cand.badgeText)，点击预约为明日自习室）",
                tag: cand.room.id,
                isHighlighted: isReserved,
                action: #selector(quickSelectTomorrowRoom(_:))
            )
            if tx + pill.frame.width <= col3.bounds.width {
                pill.frame.origin = NSPoint(x: tx, y: 40)
                col3.addSubview(pill)
                tx += pill.frame.width + 4
            }
        }
    }

    private func makeDot(color: NSColor, y: CGFloat) -> NSView {
        let dot = ColorDotView(frame: NSRect(x: 0, y: y, width: 6, height: 6))
        dot.cornerRadius = 3
        dot.dotColor = color
        return dot
    }

    private func makeCompactPillButton(
        title: String,
        toolTip: String,
        tag: Int,
        isHighlighted: Bool = false,
        action: Selector
    ) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.font = NSFont.systemFont(ofSize: 11, weight: isHighlighted ? .semibold : .regular)
        btn.tag = tag
        btn.toolTip = toolTip
        if isHighlighted {
            btn.contentTintColor = .controlAccentColor
        }
        btn.sizeToFit()
        var f = btn.frame
        f.size.height = 22
        btn.frame = f
        return btn
    }

    // MARK: - 2. 极速过滤与刷新 NSTableView

    private func reloadFilteredRooms() {
        let isToday = (selectedDateString == EmptyClassroomService.todayDateString())
        let nowMin = EmptyClassroomService.currentMinutesOfDay()
        let currentStudyId = SettingsManager.shared.currentStudyRoom?.roomId
        let kw = searchKeyword.lowercased()

        var filtered = currentRooms.filter { room in
            if let floor = selectedFloor, room.inferredFloor != floor {
                return false
            }
            if !kw.isEmpty {
                if !room.nameZh.lowercased().contains(kw) && !(room.code?.lowercased().contains(kw) ?? false) {
                    return false
                }
            }
            switch statusFilterMode {
            case 1:
                return room.isAllDayFree
            case 2:
                return isToday ? room.isRestOfDayFree(atMinutes: nowMin) : room.isAllDayFree
            case 3:
                return isToday ? (room.currentOccupation(atMinutes: nowMin) == nil) : true
            default:
                return true
            }
        }

        filtered.sort { a, b in
            let aIsCurrent = (a.id == currentStudyId)
            let bIsCurrent = (b.id == currentStudyId)
            if aIsCurrent != bIsCurrent {
                return aIsCurrent
            }
            if a.buildingPrefix != b.buildingPrefix {
                return a.buildingPrefix < b.buildingPrefix
            }
            if a.inferredFloor != b.inferredFloor {
                return a.inferredFloor < b.inferredFloor
            }
            return a.inferredRoomNumber < b.inferredRoomNumber
        }

        self.filteredRooms = filtered
        tableView.reloadData()

        if filtered.isEmpty {
            let msg = EmptyClassroomService.shared.isSyncing
                ? "正在同步教室占用数据..."
                : (EmptyClassroomService.shared.lastErrorMessage ?? "没有符合当前筛选条件的教室")
            emptyStateLabel.stringValue = msg
            emptyStateLabel.isHidden = false
        } else {
            emptyStateLabel.isHidden = true
        }

        let allDayCount = filtered.filter { $0.isAllDayFree }.count
        let restFreeCount = filtered.filter { $0.isRestOfDayFree(atMinutes: nowMin) }.count
        let syncInfo = EmptyClassroomService.shared.formattedFullLastSync(for: selectedCampus)
        updateLastSyncTimeDisplay()
        bottomStatusLabel.stringValue = "共 \(filtered.count) 间教室  ·  全天无课 \(allDayCount) 间  ·  余下无课 \(restFreeCount) 间   ｜   \(syncInfo)"
    }

    // MARK: - 交互事件处理

    private func selectCampusInPopUp(_ campus: StudyCampus) {
        guard let pop = campusPopUp else { return }
        for i in 0..<pop.numberOfItems {
            if let raw = pop.item(at: i)?.representedObject as? Int, raw == campus.rawValue {
                pop.selectItem(at: i)
                break
            }
        }
    }

    @objc private func campusChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? Int,
              let campus = StudyCampus(rawValue: raw) else { return }
        selectedCampus = campus
        selectedBuildingId = nil
        selectedFloor = nil
        floorSegment.selectedSegment = 0
        updateLastSyncTimeDisplay()
        reloadCurrentCampusAndDate(forceRefresh: false)
    }

    @objc private func dateSegmentChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 {
            selectedDateString = EmptyClassroomService.tomorrowDateString()
        } else {
            selectedDateString = EmptyClassroomService.todayDateString()
        }
        applyCurrentRoomsFromCacheOrFetch(forceRefresh: false)
    }

    @objc private func buildingSegmentChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        moreBuildingPopUp.selectItem(at: 0)
        if idx <= 0 {
            selectedBuildingId = nil
        } else if idx - 1 < mainBuildings.count {
            selectedBuildingId = mainBuildings[idx - 1].id
        }
        applyCurrentRoomsFromCacheOrFetch(forceRefresh: false)
    }

    @objc private func moreBuildingChanged(_ sender: NSPopUpButton) {
        guard let bid = sender.selectedItem?.representedObject as? Int else {
            selectedBuildingId = nil
            buildingSegment.selectedSegment = 0
            buildingScrollView.contentView.scroll(to: .zero)
            buildingScrollView.reflectScrolledClipView(buildingScrollView.contentView)
            applyCurrentRoomsFromCacheOrFetch(forceRefresh: false)
            return
        }
        selectedBuildingId = bid
        if let mainIdx = mainBuildings.firstIndex(where: { $0.id == bid }) {
            buildingSegment.selectedSegment = mainIdx + 1
            let count = CGFloat(max(1, buildingSegment.segmentCount))
            let approxX = (buildingSegment.frame.width / count) * CGFloat(mainIdx + 1)
            let clipW = buildingScrollView.contentView.bounds.width
            let maxX = max(0, buildingDocView.bounds.width - clipW)
            let targetX = min(max(0, approxX - clipW / 2), maxX)
            buildingScrollView.contentView.scroll(to: NSPoint(x: targetX, y: 0))
            buildingScrollView.reflectScrolledClipView(buildingScrollView.contentView)
        } else {
            buildingSegment.selectedSegment = -1
        }
        applyCurrentRoomsFromCacheOrFetch(forceRefresh: false)
    }

    @objc private func floorSegmentChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        selectedFloor = (idx <= 0) ? nil : idx
        reloadFilteredRooms()
    }

    @objc private func statusFilterChanged(_ sender: NSSegmentedControl) {
        statusFilterMode = sender.selectedSegment
        reloadFilteredRooms()
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchKeyword = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        reloadFilteredRooms()
    }

    public func controlTextDidChange(_ obj: Notification) {
        if let sf = obj.object as? NSSearchField, sf == searchField {
            searchKeyword = sf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            reloadFilteredRooms()
        }
    }

    @objc private func forceRefreshClicked() {
        reloadCurrentCampusAndDate(forceRefresh: true, isManual: true)
    }

    @objc private func clearStudyRoomClicked() {
        EmptyClassroomService.shared.clearCurrentStudyRoom()
        renderSummaryBar()
        reloadFilteredRooms()
    }

    @objc private func quickSelectTodayRoom(_ sender: NSButton) {
        let roomId = sender.tag
        let todayRooms = EmptyClassroomService.shared.cachedStudyRooms(
            campus: selectedCampus,
            dateString: EmptyClassroomService.todayDateString()
        )
        if let room = todayRooms.first(where: { $0.id == roomId }) ?? currentRooms.first(where: { $0.id == roomId }) {
            EmptyClassroomService.shared.setCurrentStudyRoom(room, campus: selectedCampus)
            renderSummaryBar()
            reloadFilteredRooms()
        }
    }

    @objc private func quickSelectTomorrowRoom(_ sender: NSButton) {
        let roomId = sender.tag
        let tomorrowRooms = EmptyClassroomService.shared.cachedStudyRooms(
            campus: selectedCampus,
            dateString: EmptyClassroomService.tomorrowDateString()
        )
        if let room = tomorrowRooms.first(where: { $0.id == roomId }) ?? currentRooms.first(where: { $0.id == roomId }) {
            EmptyClassroomService.shared.setNextDayStudyRoom(room, campus: selectedCampus)
            renderSummaryBar()
            reloadFilteredRooms()
        }
    }

    @objc private func rowSetStudyRoomClicked(_ sender: NSButton) {
        let roomId = sender.tag
        guard let room = currentRooms.first(where: { $0.id == roomId }) else { return }
        if selectedDateString == EmptyClassroomService.tomorrowDateString() {
            EmptyClassroomService.shared.setNextDayStudyRoom(room, campus: selectedCampus)
        } else {
            EmptyClassroomService.shared.setCurrentStudyRoom(room, campus: selectedCampus)
        }
        renderSummaryBar()
        reloadFilteredRooms()
    }
}
