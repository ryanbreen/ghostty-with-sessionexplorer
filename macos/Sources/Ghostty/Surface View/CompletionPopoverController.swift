import AppKit

/// Popover content for the prompt editor's tab-completion candidate list.
/// Shows when the user invokes Tab and there are 2+ matches; navigable
/// with Up/Down arrows; types-to-filter; Tab or Right arrow accepts the
/// highlighted item.
final class CompletionPopoverController: NSViewController {
    var completions: [CompletionEngine.Completion] = []
    var selectedIndex: Int = 0

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    override func loadView() {
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("text"))
        column.width = 280
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.rowHeight = 20
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        self.view = container
    }

    func reload() {
        tableView.reloadData()
        if !completions.isEmpty {
            let safeIndex = min(selectedIndex, completions.count - 1)
            selectedIndex = safeIndex
            tableView.selectRowIndexes(
                IndexSet(integer: safeIndex),
                byExtendingSelection: false)
            tableView.scrollRowToVisible(safeIndex)
        }
        sizePopoverToContent()
    }

    func selectNext() {
        guard !completions.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, completions.count - 1)
        tableView.selectRowIndexes(
            IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    func selectPrevious() {
        guard !completions.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        tableView.selectRowIndexes(
            IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    func currentSelection() -> CompletionEngine.Completion? {
        guard selectedIndex < completions.count else { return nil }
        return completions[selectedIndex]
    }

    private func sizePopoverToContent() {
        // Cap height at ~12 rows; let width breathe a bit for long
        // path completions.
        let rowsToShow = min(completions.count, 12)
        let height = max(60, CGFloat(rowsToShow) * 22 + 8)
        let width: CGFloat = 320
        preferredContentSize = NSSize(width: width, height: height)
    }
}

extension CompletionPopoverController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return completions.count
    }
}

extension CompletionPopoverController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < completions.count else { return nil }
        let comp = completions[row]
        let label = NSTextField(labelWithString: comp.text)
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.isBordered = false
        label.drawsBackground = false
        // Tag dirs with a trailing slash visually, kind icons could
        // come later (folder, gear for executable, etc.).
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIndex = max(0, tableView.selectedRow)
    }
}
