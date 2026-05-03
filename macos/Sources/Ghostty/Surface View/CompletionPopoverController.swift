import AppKit

/// Borderless floating window that hosts the prompt editor's
/// tab-completion list. NOT an NSPopover — NSPopover steals first
/// responder from the editor (which is why Tab/Enter weren't reaching
/// our key handler) and its positioning quirks made the anchor land
/// far from the cursor. A non-key window gives us pixel-precise
/// placement at the cursor + zero focus interference.
final class CompletionPopoverController: NSObject {
    var completions: [CompletionEngine.Completion] = []
    var selectedIndex: Int = 0

    private let window: CompletionPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// Compact font matching what an autocomplete dropdown should
    /// look like.
    private static let rowFont = NSFont.monospacedSystemFont(
        ofSize: 11, weight: .regular)
    private static let rowHeight: CGFloat = 16
    private static let popoverWidth: CGFloat = 240
    private static let visibleRowsMax: Int = 10

    var isVisible: Bool { window.isVisible }

    override init() {
        // Container — visual effect view gives us the system blur +
        // material that matches NSPopover's look without being one.
        let container = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 100))
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true

        window = CompletionPanel(
            contentRect: container.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.contentView = container
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating

        super.init()

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
        tableView.refusesFirstResponder = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.frame = container.bounds.insetBy(dx: 4, dy: 4)
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
    }

    /// Show the window at the given SCREEN-coordinate anchor. The
    /// popover anchors so its top-left edge sits at `anchor.maxX, anchor.minY`
    /// (i.e., immediately to the right of the cursor cell). If there's
    /// no room on the right, flip to anchor immediately above the
    /// cursor's row.
    func show(at anchor: NSRect, parentWindow: NSWindow?) {
        sizeToContent()
        let frame = computeFrame(for: anchor)
        window.setFrame(frame, display: false)
        if let parent = parentWindow {
            // Parent the panel to the editor window so it follows
            // window movement and closes when the editor closes.
            // Order WITHOUT activating so first responder stays put.
            parent.addChildWindow(window, ordered: .above)
        } else {
            window.orderFront(nil)
        }
    }

    func hide() {
        if window.isVisible {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
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
        sizeToContent()
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

    private func sizeToContent() {
        let rowsToShow = max(1, min(completions.count, Self.visibleRowsMax))
        let height = CGFloat(rowsToShow) * Self.rowHeight + 8
        var size = window.frame.size
        size.width = Self.popoverWidth
        size.height = height
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: false)
    }

    /// Compute the popover's screen frame so it sits right next to
    /// the anchor (the cursor's screen rect). Default placement: the
    /// popover's top-left corner sits at `(anchor.maxX + gap, anchor.maxY)`
    /// so it grows down and to the right of the cursor with a small
    /// gap for breathing room.
    private static let cursorGap: CGFloat = 2

    private func computeFrame(for anchor: NSRect) -> NSRect {
        let size = NSSize(
            width: Self.popoverWidth,
            height: window.frame.height)
        // macOS screen coords are y-up. anchor.maxY is the TOP of the
        // cursor's screen rect; we want the popover's TOP at that
        // same y so it grows downward.
        var x = anchor.maxX + Self.cursorGap
        var y = anchor.maxY - size.height
        // Clamp to the visible screen so it doesn't drift off-screen.
        if let screen = NSScreen.main?.visibleFrame {
            if x + size.width > screen.maxX {
                // Not enough room on the right — flip to LEFT of cursor.
                x = anchor.minX - size.width - Self.cursorGap
            }
            if y < screen.minY { y = screen.minY }
            if y + size.height > screen.maxY {
                y = screen.maxY - size.height
            }
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

/// Non-activating, non-key panel — keystrokes never go to it; first
/// responder stays on the editor's NSTextView.
private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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

    func tableView(
        _ tableView: NSTableView,
        shouldSelectRow row: Int
    ) -> Bool {
        // Disallow click-to-select since we're keyboard-only.
        return false
    }
}
