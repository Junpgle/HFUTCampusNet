import AppKit

final class CampusAIHistoryPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onPageRequested: ((Int) -> Void)?
    var onDeleteRequested: ((CampusAIHistoryEntry) -> Void)?
    var onRefreshRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    private let tableView = NSTableView()
    private let statusField = NSTextField(labelWithString: "")
    private let pageField = NSTextField(labelWithString: "")
    private let previousButton = NSButton(title: "上一页", target: nil, action: nil)
    private let nextButton = NSButton(title: "下一页", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    private var entries: [CampusAIHistoryEntry] = []
    private var currentPageNumber = 1
    private var pageCount = 1
    private var hasPreviousPage = false
    private var hasNextPage = false
    private var isLoading = false
    private var isDeleting = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 450))
        view = root

        let title = NSTextField(labelWithString: "历史会话")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 16, y: 414, width: 250, height: 24)
        root.addSubview(title)

        refreshButton.frame = NSRect(x: 438, y: 412, width: 52, height: 26)
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        root.addSubview(refreshButton)

        closeButton.frame = NSRect(x: 496, y: 412, width: 52, height: 26)
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        root.addSubview(closeButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history-entry"))
        column.width = 528
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.frame = NSRect(x: 0, y: 0, width: 536, height: 332)
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView(frame: NSRect(x: 12, y: 68, width: 536, height: 332))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        previousButton.frame = NSRect(x: 16, y: 34, width: 72, height: 24)
        previousButton.bezelStyle = .rounded
        previousButton.target = self
        previousButton.action = #selector(previousPageClicked)
        root.addSubview(previousButton)

        pageField.frame = NSRect(x: 96, y: 36, width: 120, height: 20)
        pageField.alignment = .center
        pageField.font = .systemFont(ofSize: 11)
        pageField.textColor = .secondaryLabelColor
        root.addSubview(pageField)

        nextButton.frame = NSRect(x: 224, y: 34, width: 72, height: 24)
        nextButton.bezelStyle = .rounded
        nextButton.target = self
        nextButton.action = #selector(nextPageClicked)
        root.addSubview(nextButton)

        statusField.frame = NSRect(x: 16, y: 9, width: 528, height: 20)
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        root.addSubview(statusField)

        updateControls()
    }

    func beginLoading(pageNumber: Int) {
        currentPageNumber = max(1, pageNumber)
        isLoading = true
        isDeleting = false
        statusField.stringValue = "正在获取历史会话…"
        updateControls()
    }

    func show(page: CampusAIHistoryPage) {
        entries = page.entries
        currentPageNumber = page.pageNumber
        pageCount = page.pageCount
        hasPreviousPage = page.hasPreviousPage
        hasNextPage = page.hasNextPage
        isLoading = false
        isDeleting = false
        statusField.stringValue = entries.isEmpty ? "暂无历史会话。" : "本页共 \(entries.count) 条记录。"
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        tableView.setFrameSize(NSSize(width: 536, height: max(332, CGFloat(entries.count) * rowHeight)))
        tableView.reloadData()
        updateControls()
    }

    func showError(_ message: String) {
        isLoading = false
        isDeleting = false
        statusField.stringValue = message
        updateControls()
    }

    func beginDeleting() {
        isDeleting = true
        statusField.stringValue = "正在删除并刷新历史会话…"
        updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 528, height: 50))

        let topic = NSTextField(labelWithString: entry.topic)
        topic.font = .systemFont(ofSize: 12, weight: .medium)
        topic.lineBreakMode = .byTruncatingTail
        topic.frame = NSRect(x: 10, y: 27, width: 400, height: 18)
        cell.addSubview(topic)

        let created = NSTextField(labelWithString: formattedDate(entry.createTime))
        created.font = .systemFont(ofSize: 10)
        created.textColor = .secondaryLabelColor
        created.frame = NSRect(x: 10, y: 7, width: 400, height: 16)
        cell.addSubview(created)

        let deleteButton = NSButton(title: "删除", target: self, action: #selector(deleteClicked(_:)))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.tag = row
        deleteButton.frame = NSRect(x: 446, y: 12, width: 62, height: 26)
        deleteButton.isEnabled = !isLoading && !isDeleting
        cell.addSubview(deleteButton)
        return cell
    }

    @objc private func refreshClicked() {
        guard !isLoading, !isDeleting else { return }
        onRefreshRequested?()
    }

    @objc private func closeClicked() {
        onCloseRequested?()
    }

    @objc private func previousPageClicked() {
        guard !isLoading, !isDeleting, currentPageNumber > 1 else { return }
        onPageRequested?(currentPageNumber - 1)
    }

    @objc private func nextPageClicked() {
        guard !isLoading, !isDeleting, currentPageNumber < pageCount else { return }
        onPageRequested?(currentPageNumber + 1)
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard !isLoading, !isDeleting, entries.indices.contains(sender.tag) else { return }
        onDeleteRequested?(entries[sender.tag])
    }

    private func formattedDate(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "时间未知" }
        return value.replacingOccurrences(of: "T", with: " ")
    }

    private func updateControls() {
        previousButton.isEnabled = !isLoading && !isDeleting && hasPreviousPage
        nextButton.isEnabled = !isLoading && !isDeleting && hasNextPage
        refreshButton.isEnabled = !isLoading && !isDeleting
        pageField.stringValue = "第 \(currentPageNumber) / \(pageCount) 页"
        tableView.reloadData()
    }
}
