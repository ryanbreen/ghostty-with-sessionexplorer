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

    /// Compact font matching what an autocomplete dropdown should
    /// look like — smaller than the editor itself so it reads as
    /// "metadata about the input" rather than another input field.
    private static let rowFont = NSFont.monospacedSystemFont(
        ofSize: 11, weight: .regular)
    private static let rowHeight: CGFloat = 16
    private static let popoverWidth: CGFloat = 240
    private static let visibleRowsMax: Int = 10

    override func loadView() {
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("text"))
        column.width = Self.popoverWidth - 16
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = Self.rowHeight
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 100))
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
        let rowsToShow = max(1, min(completions.count, Self.visibleRowsMax))
        let height = CGFloat(rowsToShow) * Self.rowHeight + 8
        preferredContentSize = NSSize(
            width: Self.popoverWidth,
            height: height)
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
        label.font = Self.rowFont
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIndex = max(0, tableView.selectedRow)
    }
}
