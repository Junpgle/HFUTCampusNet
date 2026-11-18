import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class CampusCardExportDialog: NSObject, NSTextFieldDelegate {
    private let transactions: [CampusCardTransaction]
    private let cardData: CampusCardData?

    private let alert = NSAlert()
    private var exportButton: NSButton!

    private var presetPopup: NSPopUpButton!
    private var startDatePicker: NSDatePicker!
    private var endDatePicker: NSDatePicker!
    private var keywordField: NSTextField!
    private var scenePopup: NSPopUpButton!
    private var directionPopup: NSPopUpButton!
    private var formatPopup: NSPopUpButton!
    private var neutralRechargeCheck: NSButton!
    private var previewLabel: NSTextField!

    private var isUpdatingControls = false

    private init(transactions: [CampusCardTransaction], cardData: CampusCardData?) {
        self.transactions = transactions
        self.cardData = cardData
        super.init()
        setupDialog()
    }

    public static func present(
        from parentWindow: NSWindow?,
        transactions: [CampusCardTransaction],
        cardData: CampusCardData?
    ) {
        guard !transactions.isEmpty else {
            let emptyAlert = NSAlert()
            emptyAlert.messageText = "暂无可导出的一卡通账单"
            emptyAlert.informativeText = "请先点击「立即刷新」同步校园一卡通流水后再导出。"
            emptyAlert.alertStyle = .informational
            emptyAlert.addButton(withTitle: "好")
            if let window = parentWindow {
                emptyAlert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                emptyAlert.runModal()
            }
            return
        }

        let dialog = CampusCardExportDialog(transactions: transactions, cardData: cardData)
        dialog.run(attachedTo: parentWindow)
    }

    private func setupDialog() {
        alert.messageText = "导出校园一卡通账单"
        alert.informativeText = "支持按日期、商家关键字、场景与收支筛选，并默认导出为兼容微信支付对账单的 CSV 格式。"
        alert.alertStyle = .informational

        exportButton = alert.addButton(withTitle: "选择保存位置...")
        alert.addButton(withTitle: "取消")

        let width: CGFloat = 460
        let height: CGFloat = 256
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let labelW: CGFloat = 92
        let fieldX: CGFloat = 100
        let fieldW: CGFloat = width - fieldX

        func addLabel(_ text: String, y: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 0, y: y + 2, width: labelW, height: 18)
            label.alignment = .right
            label.font = NSFont.systemFont(ofSize: 12)
            container.addSubview(label)
        }

        // 1. 日期范围预设 + 起止日期
        var y: CGFloat = height - 28
        addLabel("日期范围：", y: y)

        presetPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y, width: 120, height: 24), pullsDown: false)
        presetPopup.addItems(withTitles: ["全部日期", "近 7 天", "近 30 天", "本月", "上月", "自定义"])
        presetPopup.target = self
        presetPopup.action = #selector(onPresetChanged)
        container.addSubview(presetPopup)

        startDatePicker = NSDatePicker(frame: NSRect(x: fieldX + 126, y: y, width: 108, height: 24))
        startDatePicker.datePickerStyle = .textFieldAndStepper
        startDatePicker.datePickerElements = .yearMonthDay
        startDatePicker.target = self
        startDatePicker.action = #selector(onDatePickerChanged)
        container.addSubview(startDatePicker)

        let toLabel = NSTextField(labelWithString: "至")
        toLabel.frame = NSRect(x: fieldX + 236, y: y + 2, width: 16, height: 18)
        toLabel.alignment = .center
        toLabel.textColor = .secondaryLabelColor
        container.addSubview(toLabel)

        endDatePicker = NSDatePicker(frame: NSRect(x: fieldX + 254, y: y, width: 108, height: 24))
        endDatePicker.datePickerStyle = .textFieldAndStepper
        endDatePicker.datePickerElements = .yearMonthDay
        endDatePicker.target = self
        endDatePicker.action = #selector(onDatePickerChanged)
        container.addSubview(endDatePicker)

        initializeDefaultDateRange()

        // 2. 商家 / 关键字
        y -= 34
        addLabel("商家/关键字：", y: y)
        keywordField = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 24))
        keywordField.placeholderString = "输入商家名称、摘要或订单号（留空不限）"
        keywordField.delegate = self
        container.addSubview(keywordField)

        // 3. 消费场景
        y -= 34
        addLabel("消费场景：", y: y)
        scenePopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y, width: 170, height: 24), pullsDown: false)
        let sceneTags = CampusCardBillExporter.availableSceneTags(from: transactions)
        scenePopup.addItems(withTitles: ["全部分类"] + sceneTags)
        scenePopup.target = self
        scenePopup.action = #selector(onFilterChanged)
        container.addSubview(scenePopup)

        // 4. 收支类型
        let dirLabel = NSTextField(labelWithString: "收支：")
        dirLabel.frame = NSRect(x: fieldX + 178, y: y + 2, width: 44, height: 18)
        dirLabel.alignment = .right
        dirLabel.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(dirLabel)

        directionPopup = NSPopUpButton(frame: NSRect(x: fieldX + 224, y: y, width: fieldW - 224, height: 24), pullsDown: false)
        directionPopup.addItems(withTitles: CampusCardBillDirectionFilter.allCases.map(\.displayName))
        directionPopup.target = self
        directionPopup.action = #selector(onFilterChanged)
        container.addSubview(directionPopup)

        // 5. 导出格式
        y -= 34
        addLabel("导出格式：", y: y)
        formatPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y, width: fieldW, height: 24), pullsDown: false)
        formatPopup.addItems(withTitles: CampusCardBillExportFormat.allCases.map(\.displayName))
        formatPopup.target = self
        formatPopup.action = #selector(onFilterChanged)
        container.addSubview(formatPopup)

        // 6. 圈存/充值处理选项
        y -= 32
        neutralRechargeCheck = NSButton(
            checkboxWithTitle: "圈存/充值记为「不计收支」（推荐，避免重复计入收入）",
            target: self,
            action: #selector(onFilterChanged)
        )
        neutralRechargeCheck.frame = NSRect(x: fieldX, y: y, width: fieldW, height: 22)
        neutralRechargeCheck.state = .on
        neutralRechargeCheck.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(neutralRechargeCheck)

        // 7. 实时预览统计
        y -= 48
        let previewBox = NSBox(frame: NSRect(x: 0, y: y, width: width, height: 38))
        previewBox.boxType = .custom
        previewBox.cornerRadius = 6
        previewBox.borderWidth = 1
        previewBox.borderColor = NSColor.separatorColor
        previewBox.fillColor = NSColor.labelColor.withAlphaComponent(0.035)
        previewBox.titlePosition = .noTitle
        container.addSubview(previewBox)

        previewLabel = NSTextField(labelWithString: "")
        previewLabel.frame = NSRect(x: 10, y: 10, width: width - 20, height: 18)
        previewLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewBox.addSubview(previewLabel)

        alert.accessoryView = container
        updatePreview()
    }

    private func initializeDefaultDateRange() {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"

        let minDate = transactions.map(\.dateOnlyString).min().flatMap { df.date(from: $0) } ?? Date()
        let maxDate = transactions.map(\.dateOnlyString).max().flatMap { df.date(from: $0) } ?? Date()
        startDatePicker.dateValue = minDate
        endDatePicker.dateValue = maxDate
        startDatePicker.isEnabled = false
        endDatePicker.isEnabled = false
    }

    @objc private func onPresetChanged() {
        guard !isUpdatingControls else { return }
        isUpdatingControls = true
        defer {
            isUpdatingControls = false
            updatePreview()
        }

        let cal = Calendar.current
        let now = Date()
        let idx = presetPopup.indexOfSelectedItem

        switch idx {
        case 0: // 全部日期
            startDatePicker.isEnabled = false
            endDatePicker.isEnabled = false
        case 1: // 近 7 天
            startDatePicker.isEnabled = true
            endDatePicker.isEnabled = true
            startDatePicker.dateValue = cal.date(byAdding: .day, value: -6, to: now) ?? now
            endDatePicker.dateValue = now
        case 2: // 近 30 天
            startDatePicker.isEnabled = true
            endDatePicker.isEnabled = true
            startDatePicker.dateValue = cal.date(byAdding: .day, value: -29, to: now) ?? now
            endDatePicker.dateValue = now
        case 3: // 本月
            startDatePicker.isEnabled = true
            endDatePicker.isEnabled = true
            let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
            startDatePicker.dateValue = startOfMonth
            endDatePicker.dateValue = now
        case 4: // 上月
            startDatePicker.isEnabled = true
            endDatePicker.isEnabled = true
            let startOfThisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
            let startOfLastMonth = cal.date(byAdding: .month, value: -1, to: startOfThisMonth) ?? now
            let endOfLastMonth = cal.date(byAdding: .day, value: -1, to: startOfThisMonth) ?? now
            startDatePicker.dateValue = startOfLastMonth
            endDatePicker.dateValue = endOfLastMonth
        default: // 自定义
            startDatePicker.isEnabled = true
            endDatePicker.isEnabled = true
        }
    }

    @objc private func onDatePickerChanged() {
        guard !isUpdatingControls else { return }
        isUpdatingControls = true
        presetPopup.selectItem(at: 5) // 自定义
        if startDatePicker.dateValue > endDatePicker.dateValue {
            endDatePicker.dateValue = startDatePicker.dateValue
        }
        isUpdatingControls = false
        updatePreview()
    }

    @objc private func onFilterChanged() {
        updatePreview()
    }

    public func controlTextDidChange(_ obj: Notification) {
        updatePreview()
    }

    private func currentFilter() -> CampusCardBillFilter {
        let useDateRange = presetPopup.indexOfSelectedItem != 0
        let startStr = useDateRange ? CampusCardBillExporter.dateString(from: startDatePicker.dateValue) : nil
        let endStr = useDateRange ? CampusCardBillExporter.dateString(from: endDatePicker.dateValue) : nil
        let scene = scenePopup.titleOfSelectedItem
        let direction = CampusCardBillDirectionFilter(rawValue: directionPopup.indexOfSelectedItem) ?? .all
        return CampusCardBillFilter(
            startDateString: startStr,
            endDateString: endStr,
            merchantKeyword: keywordField.stringValue,
            sceneTag: scene,
            direction: direction
        )
    }

    private func currentOptions() -> CampusCardBillExportOptions {
        let format = CampusCardBillExportFormat(rawValue: formatPopup.indexOfSelectedItem) ?? .wechatCSV
        let treatNeutral = (neutralRechargeCheck.state == .on)
        return CampusCardBillExportOptions(
            format: format,
            treatRechargeAsNeutral: treatNeutral
        )
    }

    private func updatePreview() {
        let filter = currentFilter()
        let options = currentOptions()
        neutralRechargeCheck.isEnabled = (options.format != .json)

        let matched = filter.apply(to: transactions)
        let summary = CampusCardBillExporter.summarize(
            matched,
            treatRechargeAsNeutral: options.treatRechargeAsNeutral
        )

        if matched.isEmpty {
            previewLabel.stringValue = "当前筛选条件下没有匹配的交易流水"
            previewLabel.textColor = .systemOrange
            exportButton.isEnabled = false
        } else {
            previewLabel.stringValue = String(
                format: "命中 %d 笔流水 · 支出 ¥%.2f (%d笔) · 收入 ¥%.2f (%d笔) · 不计收支 ¥%.2f (%d笔)",
                summary.count,
                summary.expenseRMB,
                summary.expenseCount,
                summary.incomeRMB,
                summary.incomeCount,
                summary.neutralRMB,
                summary.neutralCount
            )
            previewLabel.textColor = .labelColor
            exportButton.isEnabled = true
        }
    }

    private func run(attachedTo parentWindow: NSWindow?) {
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let filter = currentFilter()
        let options = currentOptions()
        let data = CampusCardBillExporter.exportData(
            transactions: transactions,
            cardData: cardData,
            filter: filter,
            options: options
        )
        let matchedCount = filter.apply(to: transactions).count

        let savePanel = NSSavePanel()
        savePanel.title = "保存一卡通账单"
        savePanel.nameFieldStringValue = CampusCardBillExporter.suggestedFilename(
            format: options.format,
            filter: filter,
            date: options.exportDate
        )
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [
            options.format == .json ? UTType.json : UTType.commaSeparatedText
        ]

        let panelResult = savePanel.runModal()
        guard panelResult == .OK, let targetURL = savePanel.url else { return }

        do {
            try data.write(to: targetURL, options: .atomic)
            showExportSuccess(url: targetURL, count: matchedCount, format: options.format, attachedTo: parentWindow)
        } catch {
            let errAlert = NSAlert(error: error)
            if let window = parentWindow {
                errAlert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                errAlert.runModal()
            }
        }
    }

    private func showExportSuccess(
        url: URL,
        count: Int,
        format: CampusCardBillExportFormat,
        attachedTo parentWindow: NSWindow?
    ) {
        let done = NSAlert()
        done.messageText = "账单导出成功"
        done.informativeText = "已导出 \(count) 笔流水（\(format.displayName)）至：\n\(url.path)"
        done.alertStyle = .informational
        done.addButton(withTitle: "在访达中显示")
        done.addButton(withTitle: "完成")

        let handle: (NSApplication.ModalResponse) -> Void = { resp in
            if resp == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        if let window = parentWindow {
            done.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(done.runModal())
        }
    }
}
