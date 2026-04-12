import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionExplorerView: View {
    @StateObject private var store = SessionStore()
    @StateObject private var templateStore = TemplateStore()
    @State private var selection: SessionExplorerSelection?
    @State private var diff: SessionDiff?
    @State private var liveState: ExplorerSnapshot?
    @State private var liveRefreshTask: Task<Void, Never>?
    @State private var importJSONString = ""
    @State private var isPresentingImportJSONSheet = false
    @State private var errorMessage: String?

    let refreshLiveState: (() async -> ExplorerSnapshot?)?
    let computeDiff: ((SessionStore.StoredSession, ExplorerSnapshot?) -> SessionDiff?)?
    let onSnapshotCurrent: (() -> Void)?
    let onAssertSnapshot: ((ExplorerSnapshot) -> Void)?
    let onAssertWindow: ((ExplorerWindow) -> Void)?
    let onAssertTemplate: ((SessionTemplate) -> Void)?

    init(
        refreshLiveState: (() async -> ExplorerSnapshot?)? = nil,
        computeDiff: ((SessionStore.StoredSession, ExplorerSnapshot?) -> SessionDiff?)? = nil,
        onSnapshotCurrent: (() -> Void)? = nil,
        onAssertSnapshot: ((ExplorerSnapshot) -> Void)? = nil,
        onAssertWindow: ((ExplorerWindow) -> Void)? = nil,
        onAssertTemplate: ((SessionTemplate) -> Void)? = nil
    ) {
        self.refreshLiveState = refreshLiveState
        self.computeDiff = computeDiff
        self.onSnapshotCurrent = onSnapshotCurrent
        self.onAssertSnapshot = onAssertSnapshot
        self.onAssertWindow = onAssertWindow
        self.onAssertTemplate = onAssertTemplate
    }

    var body: some View {
        HSplitView {
            SessionSidebarView(
                store: store,
                templateStore: templateStore,
                selection: $selection,
                onSnapshotCurrent: onSnapshotCurrent,
                onDeleteSnapshot: deleteSnapshot,
                onDeleteTemplate: deleteTemplate,
                onImportTemplateFile: importTemplateFromFile,
                onPasteTemplateJSON: {
                    importJSONString = ""
                    isPresentingImportJSONSheet = true
                }
            )
            .frame(minWidth: 290, idealWidth: 290, maxWidth: 290)
            .background(Color.explorerSurface2)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.explorerBorder)
                    .frame(width: 1)
            }

            SessionMainPanelView(
                snapshot: selectedSnapshot,
                template: selectedTemplate,
                diff: diff,
                onAssertSnapshot: onAssertSnapshot,
                onAssertWindow: onAssertWindow,
                onSaveSnapshot: saveSnapshot,
                onPromoteSnapshot: promoteSnapshot,
                onSaveTemplate: saveTemplate,
                onAssertTemplate: onAssertTemplate,
                onDuplicateTemplate: duplicateTemplate,
                onCopyTemplateJSON: copyTemplateJSON,
                onExportTemplate: exportTemplate,
                onRecaptureWindow: recaptureTemplateWindow(at:)
            )
        }
        .frame(minWidth: 1180, minHeight: 760)
        .background(Color.explorerSurface1)
        .preferredColorScheme(.dark)
        .task {
            await handleInitialLoad()
        }
        .onDisappear {
            liveRefreshTask?.cancel()
            liveRefreshTask = nil
        }
        .onChange(of: selection) { _ in
            refreshDiff()
        }
        .onChange(of: store.sessions.map(\.id)) { _ in
            maintainSelection()
            refreshDiff()
        }
        .onChange(of: templateStore.templates.map(\.id)) { _ in
            maintainSelection()
        }
        .sheet(isPresented: $isPresentingImportJSONSheet) {
            ImportTemplateJSONSheet(
                json: $importJSONString,
                onCancel: {
                    isPresentingImportJSONSheet = false
                },
                onImport: {
                    importTemplateFromJSON()
                }
            )
            .frame(width: 640, height: 420)
            .padding(20)
        }
        .alert(
            "Session Explorer Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var selectedSnapshot: SessionStore.StoredSession? {
        guard case .snapshot(let id) = selection else { return nil }
        return store.sessions.first(where: { $0.id == id })
    }

    private var selectedTemplate: TemplateStore.StoredTemplate? {
        guard case .template(let id) = selection else { return nil }
        return templateStore.templates.first(where: { $0.id == id })
    }

    @MainActor
    private func handleInitialLoad() async {
        store.loadSessions()
        templateStore.loadTemplates()
        maintainSelection()
        refreshDiff()
        startLiveRefreshLoop()
    }

    @MainActor
    private func maintainSelection() {
        switch selection {
        case .template(let id):
            if templateStore.templates.contains(where: { $0.id == id }) {
                return
            }
        case .snapshot(let id):
            if store.sessions.contains(where: { $0.id == id }) {
                return
            }
        case nil:
            break
        }

        if let template = templateStore.templates.first {
            selection = .template(template.id)
        } else if let snapshot = store.sessions.first {
            selection = .snapshot(snapshot.id)
        } else {
            selection = nil
        }
    }

    @MainActor
    private func refreshDiff() {
        if let selectedSnapshot, let computeDiff {
            diff = computeDiff(selectedSnapshot, liveState)
        } else if let selectedTemplate, let liveState {
            diff = SessionDiff.diff(session: selectedTemplate.template.asSnapshot, live: liveState)
        } else {
            diff = nil
        }
    }

    @MainActor
    private func startLiveRefreshLoop() {
        liveRefreshTask?.cancel()
        guard let refreshLiveState else { return }

        liveRefreshTask = Task {
            await refreshLiveStateOnce(using: refreshLiveState)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await refreshLiveStateOnce(using: refreshLiveState)
            }
        }
    }

    private func refreshLiveStateOnce(using provider: @escaping () async -> ExplorerSnapshot?) async {
        let snapshot = await provider()
        await MainActor.run {
            liveState = snapshot
            refreshDiff()
        }
    }

    private func deleteSnapshot(_ session: SessionStore.StoredSession) {
        do {
            try store.delete(session: session)
        } catch {
            errorMessage = "Failed to delete snapshot: \(error.localizedDescription)"
        }
    }

    private func deleteTemplate(_ template: TemplateStore.StoredTemplate) {
        do {
            try templateStore.delete(template: template)
        } catch {
            errorMessage = "Failed to delete template: \(error.localizedDescription)"
        }
    }

    private func saveSnapshot(_ session: SessionStore.StoredSession, snapshot: ExplorerSnapshot) {
        do {
            try store.updateSnapshot(session: session, snapshot: snapshot)
        } catch {
            errorMessage = "Failed to save snapshot edits: \(error.localizedDescription)"
        }
    }

    private func promoteSnapshot(_ snapshot: ExplorerSnapshot, name: String) {
        do {
            let stored = try templateStore.save(
                template: SessionTemplate.promote(snapshot: snapshot, name: name)
            )
            selection = .template(stored.id)
        } catch {
            errorMessage = "Failed to save template: \(error.localizedDescription)"
        }
    }

    private func saveTemplate(_ template: SessionTemplate) {
        do {
            _ = try templateStore.silentSave(template: template)
        } catch {
            errorMessage = "Failed to save template edits: \(error.localizedDescription)"
        }
    }

    private func duplicateTemplate(_ template: TemplateStore.StoredTemplate) {
        do {
            let duplicated = try templateStore.duplicate(template: template)
            selection = .template(duplicated.id)
        } catch {
            errorMessage = "Failed to duplicate template: \(error.localizedDescription)"
        }
    }

    private func copyTemplateJSON(_ template: TemplateStore.StoredTemplate) {
        do {
            let data = try TemplateStore.jsonEncoder.encode(template.template)
            guard let json = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadUnknown)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
        } catch {
            errorMessage = "Failed to copy template JSON: \(error.localizedDescription)"
        }
    }

    private func exportTemplate(_ template: TemplateStore.StoredTemplate) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "\(template.name).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try TemplateStore.jsonEncoder.encode(template.template)
            try data.write(to: url, options: [.atomic])
        } catch {
            errorMessage = "Failed to export template: \(error.localizedDescription)"
        }
    }

    private func importTemplateFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let template = try TemplateStore.jsonDecoder.decode(SessionTemplate.self, from: data)
            let stored = try templateStore.save(template: template)
            selection = .template(stored.id)
        } catch {
            errorMessage = "Failed to import template: \(error.localizedDescription)"
        }
    }

    private func importTemplateFromJSON() {
        do {
            guard let data = importJSONString.data(using: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let template = try TemplateStore.jsonDecoder.decode(SessionTemplate.self, from: data)
            let stored = try templateStore.save(template: template)
            selection = .template(stored.id)
            isPresentingImportJSONSheet = false
        } catch {
            errorMessage = "Failed to import pasted template JSON: \(error.localizedDescription)"
        }
    }

    private func recaptureTemplateWindow(at windowIndex: Int) {
        guard var template = selectedTemplate?.template else { return }
        guard let liveState else { return }
        guard template.windows.indices.contains(windowIndex) else { return }

        let templateWindow = template.windows[windowIndex]
        guard let liveWindow = liveState.windows.first(where: {
            $0.normalizedTitle == templateWindow.normalizedTitle
        }) else {
            return
        }

        var newTabs: [ExplorerTab] = []
        newTabs.reserveCapacity(liveWindow.tabs.count)

        for (tabIndex, liveTab) in liveWindow.tabs.enumerated() {
            let matchingOldTab = matchingTemplateTab(
                for: liveTab,
                at: tabIndex,
                in: templateWindow
            )
            let mergedTree = mergeTreePreservingCommands(
                liveTree: liveTab.surfaceTree,
                templateTree: matchingOldTab?.surfaceTree
            )

            newTabs.append(
                ExplorerTab(
                    title: liveTab.title ?? matchingOldTab?.title,
                    surfaceTree: mergedTree
                )
            )
        }

        template.windows[windowIndex].tabs = newTabs
        template.updatedAt = Date()
        saveTemplate(template)
    }

    private func matchingTemplateTab(
        for liveTab: ExplorerTab,
        at tabIndex: Int,
        in templateWindow: ExplorerWindow
    ) -> ExplorerTab? {
        if templateWindow.tabs.indices.contains(tabIndex) {
            return templateWindow.tabs[tabIndex]
        }

        return templateWindow.tabs.first(where: {
            $0.workingDirectorySignature == liveTab.workingDirectorySignature
        })
    }

    private func mergeTreePreservingCommands(
        liveTree: ExplorerSurfaceTree,
        templateTree: ExplorerSurfaceTree?
    ) -> ExplorerSurfaceTree {
        var merged = liveTree
        let livePanes = liveTree.root.flattenedPanes()
        let templatePanes = templateTree?.root.flattenedPanes() ?? []

        for livePane in livePanes {
            if let match = templatePanes.first(where: {
                $0.path == livePane.path && sameWorkingDirectory($0.view.pwd, livePane.view.pwd)
            }) {
                if let command = match.view.command {
                    merged.updateView(at: livePane.path) { view in
                        view.command = command
                    }
                }
                continue
            }

            if shouldDefaultLeftColumnCommand(path: livePane.path, tree: liveTree) {
                merged.updateView(at: livePane.path) { view in
                    view.command = .dynamic(resolver: "claudeResumeLatest", params: [:])
                }
            }
        }

        return merged
    }

    private func shouldDefaultLeftColumnCommand(path: [Int], tree: ExplorerSurfaceTree) -> Bool {
        guard path.count > 0 else { return false }
        guard case .split(let split) = tree.root else { return false }
        return split.direction.lowercased() == "horizontal" && path.first == 0
    }

    private func sameWorkingDirectory(_ lhs: String?, _ rhs: String?) -> Bool {
        lhs?.normalizedForMatching == rhs?.normalizedForMatching
    }
}

private struct ImportTemplateJSONSheet: View {
    @Binding var json: String
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste Template JSON")
                .font(.system(size: 18, weight: .semibold))

            TextEditor(text: $json)
                .font(.system(size: 12, design: .monospaced))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.explorerBorder, lineWidth: 1)
                }

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerMuted))

                Button("Import", action: onImport)
                    .buttonStyle(SessionExplorerFilledButtonStyle(fill: .explorerAccent))
                    .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(Color.explorerSurface1)
    }
}

struct SessionExplorerCommitTextField: NSViewRepresentable {
    let placeholder: String
    let text: String
    let font: NSFont
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.font = font
        field.focusRingType = .default
        field.backgroundColor = NSColor(Color.explorerSurface1)
        field.textColor = NSColor(Color.explorerText)
        field.isAutomaticTextCompletionEnabled = false
        field.usesSingleLineMode = true
        context.coordinator.applyModelText(text, to: field, force: true)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.placeholderString = placeholder
        field.font = font
        field.backgroundColor = NSColor(Color.explorerSurface1)
        field.textColor = NSColor(Color.explorerText)
        context.coordinator.applyModelText(text, to: field, force: false)
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.commitIfNeeded(from: field)
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var modelText: String
        private var onCommit: (String) -> Void
        private var isEditing = false

        init(text: String, onCommit: @escaping (String) -> Void) {
            self.modelText = text
            self.onCommit = onCommit
        }

        func applyModelText(_ text: String, to field: NSTextField, force: Bool) {
            guard force || !isEditing else { return }
            modelText = text
            if field.stringValue != text {
                field.stringValue = text
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            guard let field = obj.object as? NSTextField else { return }
            commitIfNeeded(from: field)
        }

        func commitIfNeeded(from field: NSTextField) {
            let currentText = field.stringValue
            guard currentText != modelText else { return }
            modelText = currentText
            onCommit(currentText)
        }
    }
}

struct SessionExplorerCommitTextEditor: NSViewRepresentable {
    let text: String
    let font: NSFont
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> SessionExplorerTextEditorScrollView {
        let scrollView = SessionExplorerTextEditorScrollView()
        scrollView.textView.delegate = context.coordinator
        scrollView.textView.font = font
        context.coordinator.applyModelText(text, to: scrollView.textView, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: SessionExplorerTextEditorScrollView, context: Context) {
        scrollView.textView.font = font
        context.coordinator.applyModelText(text, to: scrollView.textView, force: false)
    }

    static func dismantleNSView(
        _ scrollView: SessionExplorerTextEditorScrollView,
        coordinator: Coordinator
    ) {
        coordinator.commitIfNeeded(from: scrollView.textView)
        scrollView.textView.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var modelText: String
        private var onCommit: (String) -> Void
        private var isEditing = false

        init(text: String, onCommit: @escaping (String) -> Void) {
            self.modelText = text
            self.onCommit = onCommit
        }

        func applyModelText(_ text: String, to textView: NSTextView, force: Bool) {
            guard force || !isEditing else { return }
            modelText = text
            if textView.string != text {
                textView.string = text
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            guard let textView = notification.object as? NSTextView else { return }
            commitIfNeeded(from: textView)
        }

        func commitIfNeeded(from textView: NSTextView) {
            let currentText = textView.string
            guard currentText != modelText else { return }
            modelText = currentText
            onCommit(currentText)
        }
    }
}

final class SessionExplorerTextEditorScrollView: NSScrollView {
    let textView: NSTextView

    init() {
        let contentSize = NSSize(width: 0, height: 0)
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(Color.explorerSurface1)
        textView.textColor = NSColor(Color.explorerText)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        super.init(frame: .zero)

        borderType = .noBorder
        drawsBackground = true
        backgroundColor = NSColor(Color.explorerSurface1)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .clear
            return
        }

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch cleaned.count {
        case 8:
            alpha = Double((value & 0xFF000000) >> 24) / 255
            red = Double((value & 0x00FF0000) >> 16) / 255
            green = Double((value & 0x0000FF00) >> 8) / 255
            blue = Double(value & 0x000000FF) / 255
        case 6:
            alpha = 1
            red = Double((value & 0xFF0000) >> 16) / 255
            green = Double((value & 0x00FF00) >> 8) / 255
            blue = Double(value & 0x0000FF) / 255
        default:
            self = .clear
            return
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    static let explorerSurface1 = Color(hex: "#0f0f17")
    static let explorerSurface2 = Color(hex: "#13131e")
    static let explorerSurface3 = Color(hex: "#1a1a2e")
    static let explorerSurface4 = Color(hex: "#1e1e2e")
    static let explorerAccent = Color(hex: "#00d4aa")
    static let explorerBorder = Color(hex: "#252538")
    static let explorerText = Color(hex: "#e2e2f0")
    static let explorerMuted = Color(hex: "#6e6e88")
    static let explorerMatch = Color(hex: "#4ade80")
    static let explorerMissing = Color(hex: "#f87171")
    static let explorerPartial = Color(hex: "#fbbf24")
    static let explorerProcess = Color(hex: "#a5b4fc")
}

struct SessionExplorerStatusBadge: View {
    let status: DiffStatus

    var body: some View {
        let presentation = sessionExplorerStatusPresentation(for: status)

        Text(presentation.label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(presentation.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(presentation.color.opacity(0.15))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(presentation.color.opacity(0.30), lineWidth: 1)
            }
    }
}

struct SessionExplorerWorkspaceBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.explorerMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.explorerSurface3.opacity(0.65))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.explorerBorder.opacity(0.85), lineWidth: 1)
            }
    }
}

struct SessionExplorerStatusDot: View {
    let status: DiffStatus
    let size: CGFloat

    init(status: DiffStatus, size: CGFloat = 8) {
        self.status = status
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(sessionExplorerStatusPresentation(for: status).color)
            .frame(width: size, height: size)
    }
}

struct SessionExplorerOutlineButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(configuration.isPressed ? 0.45 : 0.30), lineWidth: 1)
            }
    }
}

struct SessionExplorerFilledButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color

    init(fill: Color, foreground: Color = .explorerSurface1) {
        self.fill = fill
        self.foreground = foreground
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}

struct SessionExplorerHeaderLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color.explorerMuted)
            .kerning(1.1)
            .textCase(.uppercase)
    }
}

struct SessionExplorerStatusPresentation {
    let label: String
    let color: Color
}

func sessionExplorerStatusPresentation(for status: DiffStatus) -> SessionExplorerStatusPresentation {
    switch status {
    case .match:
        SessionExplorerStatusPresentation(label: "Match", color: .explorerMatch)
    case .missing:
        SessionExplorerStatusPresentation(label: "Missing", color: .explorerMissing)
    case .partial:
        SessionExplorerStatusPresentation(label: "Partial", color: .explorerPartial)
    default:
        SessionExplorerStatusPresentation(label: "Unknown", color: .explorerMuted)
    }
}

func sessionExplorerIsMatch(_ status: DiffStatus) -> Bool {
    switch status {
    case .match:
        true
    default:
        false
    }
}

enum SessionExplorerFormatters {
    static let sidebarTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    static let headerTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' HH:mm"
        return formatter
    }()
}
