import AppKit
import SwiftUI

struct SessionMainPanelView: View {
    let snapshot: SessionStore.StoredSession?
    let template: TemplateStore.StoredTemplate?
    let diff: SessionDiff?
    let onAssertSnapshot: ((ExplorerSnapshot) -> Void)?
    let onAssertWindow: ((ExplorerWindow) -> Void)?
    let onSaveSnapshot: ((SessionStore.StoredSession, ExplorerSnapshot) -> Void)?
    let onPromoteSnapshot: ((ExplorerSnapshot, String) -> Void)?
    let onSaveTemplate: ((SessionTemplate) -> Void)?
    let onAssertTemplate: ((SessionTemplate) -> Void)?
    let onDuplicateTemplate: ((TemplateStore.StoredTemplate) -> Void)?
    let onCopyTemplateJSON: ((TemplateStore.StoredTemplate) -> Void)?
    let onExportTemplate: ((TemplateStore.StoredTemplate) -> Void)?
    let onRecaptureWindow: ((Int) -> Void)?

    @State private var snapshotDraft: ExplorerSnapshot?
    @State private var templateDraft: SessionTemplate?
    @State private var pendingTemplateName = ""
    @State private var isPresentingPromoteSheet = false

    var body: some View {
        Group {
            if let snapshot {
                snapshotContent(snapshot)
            } else if let template {
                templateContent(template)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.explorerSurface1)
        .onAppear {
            loadDrafts()
        }
        .task(id: snapshot?.id) {
            loadSnapshotDraft()
        }
        .onChange(of: snapshot?.snapshot) { _ in
            loadSnapshotDraft()
        }
        .task(id: template?.id) {
            loadTemplateDraft()
        }
        .onChange(of: template?.template) { _ in
            loadTemplateDraft()
        }
        .sheet(isPresented: $isPresentingPromoteSheet) {
            TemplateNameSheet(
                name: $pendingTemplateName,
                onCancel: {
                    isPresentingPromoteSheet = false
                },
                onConfirm: {
                    guard let snapshotDraft else { return }
                    onPromoteSnapshot?(snapshotDraft, pendingTemplateName)
                    isPresentingPromoteSheet = false
                }
            )
            .frame(width: 420)
            .padding(24)
        }
    }

    private func snapshotContent(_ snapshot: SessionStore.StoredSession) -> some View {
        VStack(spacing: 0) {
            snapshotHeader(snapshot)

            if let snapshotDraft {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(snapshotDraft.windows.indices), id: \.self) { index in
                            WindowCardView(
                                window: Binding(
                                    get: { snapshotDraft.windows[index] },
                                    set: { newValue in
                                        self.snapshotDraft?.windows[index] = newValue
                                    }
                                ),
                                windowDiff: windowDiff(at: index),
                                isTemplate: false,
                                dirty: snapshotWindowDirty(snapshot, index: index),
                                onChange: {},
                                onAssertWindow: {
                                    onAssertWindow?(snapshotDraft.windows[index])
                                },
                                onRecaptureWindow: nil,
                                onAddTab: nil,
                                onDeleteTab: nil,
                                onMoveTab: nil
                            )
                        }
                    }
                    .padding(10)
                }
            } else {
                placeholder(message: "No windows in this snapshot")
            }
        }
    }

    private func templateContent(_ template: TemplateStore.StoredTemplate) -> some View {
        VStack(spacing: 0) {
            templateHeader(template)

            if let templateDraft {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(templateDraft.windows.indices), id: \.self) { index in
                            WindowCardView(
                                window: Binding(
                                    get: { templateDraft.windows[index] },
                                    set: { newValue in
                                        self.templateDraft?.windows[index] = newValue
                                    }
                                ),
                                windowDiff: windowDiff(at: index),
                                isTemplate: true,
                                dirty: false,
                                onChange: { persistTemplateDraft() },
                                onAssertWindow: {
                                    onAssertWindow?(templateDraft.windows[index])
                                },
                                onRecaptureWindow: {
                                    onRecaptureWindow?(index)
                                },
                                onAddTab: {
                                    addTab(toWindowAt: index)
                                },
                                onDeleteTab: { tabIndex in
                                    removeTab(windowIndex: index, tabIndex: tabIndex)
                                },
                                onMoveTab: { from, to in
                                    moveTab(windowIndex: index, from: from, to: to)
                                }
                            )
                        }
                    }
                    .padding(10)
                }
            } else {
                placeholder(message: "No windows in this template")
            }
        }
        .onAppear {
            if templateDraft == nil {
                templateDraft = template.template
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 28))
                .foregroundColor(.explorerMuted)

            Text("Select a snapshot or template")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.explorerMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundColor(.explorerMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func snapshotHeader(_ snapshot: SessionStore.StoredSession) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(SessionExplorerFormatters.headerTimestamp.string(from: snapshot.date))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.explorerText)

                diffSummary
            }

            Spacer(minLength: 16)

            Button("Save as Template") {
                pendingTemplateName = defaultTemplateName(for: snapshot)
                isPresentingPromoteSheet = true
            }
            .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))

            Button("Save Changes (⌘S)") {
                if let snapshotDraft {
                    onSaveSnapshot?(snapshot, snapshotDraft)
                }
            }
            .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))
            .keyboardShortcut("s", modifiers: .command)

            Button("Assert All") {
                if let snapshotDraft {
                    onAssertSnapshot?(snapshotDraft)
                }
            }
            .buttonStyle(SessionExplorerFilledButtonStyle(fill: .explorerAccent))
        }
        .padding(16)
        .background(Color.explorerSurface2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.explorerBorder)
                .frame(height: 1)
        }
    }

    private func templateHeader(_ template: TemplateStore.StoredTemplate) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SessionExplorerHeaderLabel(text: "Template")

                SessionExplorerCommitTextField(
                    placeholder: "Template Name",
                    text: templateDraft?.name ?? template.name,
                    font: .monospacedSystemFont(ofSize: 18, weight: .semibold),
                    onCommit: commitTemplateName
                )
                .frame(maxWidth: 380)
            }

            Spacer(minLength: 16)

            Button("Duplicate") {
                onDuplicateTemplate?(template)
            }
            .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))

            Button("Copy JSON") {
                onCopyTemplateJSON?(template)
            }
            .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))

            Button("Export…") {
                onExportTemplate?(template)
            }
            .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))

            Button("Assert Template") {
                if let templateDraft {
                    onAssertTemplate?(templateDraft)
                }
            }
            .buttonStyle(SessionExplorerFilledButtonStyle(fill: .explorerAccent))
        }
        .padding(16)
        .background(Color.explorerSurface2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.explorerBorder)
                .frame(height: 1)
        }
    }

    private var diffSummary: some View {
        let matchingCount = diff?.matchCount ?? 0
        let missingCount = diff?.missingCount ?? 0
        let partialCount = diff?.partialCount ?? 0

        var text =
            Text("\(missingCount)")
                .foregroundColor(.explorerMissing)
            + Text(" missing, ")
                .foregroundColor(.explorerMuted)
            + Text("\(matchingCount)")
                .foregroundColor(.explorerMatch)
            + Text(" matching")
                .foregroundColor(.explorerMuted)

        if partialCount > 0 {
            text = text
                + Text(", ")
                    .foregroundColor(.explorerMuted)
                + Text("\(partialCount)")
                    .foregroundColor(.explorerPartial)
                + Text(" partial")
                    .foregroundColor(.explorerMuted)
        }

        return text
            .font(.system(size: 12, design: .monospaced))
    }

    private func loadDrafts() {
        loadSnapshotDraft()
        loadTemplateDraft()
    }

    private func loadSnapshotDraft() {
        snapshotDraft = snapshot?.snapshot
    }

    private func loadTemplateDraft() {
        templateDraft = template?.template
    }

    private func snapshotDirty(_ snapshot: SessionStore.StoredSession) -> Bool {
        snapshotDraft != snapshot.snapshot
    }

    private func snapshotWindowDirty(_ snapshot: SessionStore.StoredSession, index: Int) -> Bool {
        guard let snapshotDraft else { return false }
        guard snapshotDraft.windows.indices.contains(index) else { return false }
        guard snapshot.snapshot.windows.indices.contains(index) else { return true }
        return snapshotDraft.windows[index] != snapshot.snapshot.windows[index]
    }

    private func windowDiff(at index: Int) -> WindowDiff? {
        guard let diff else { return nil }
        guard diff.windows.indices.contains(index) else { return nil }
        return diff.windows[index]
    }

    private func persistTemplateDraft() {
        guard let templateDraft else { return }
        onSaveTemplate?(templateDraft)
    }

    private func commitTemplateName(_ newValue: String) {
        templateDraft?.name = newValue
        persistTemplateDraft()
    }

    private func addTab(toWindowAt index: Int) {
        guard var templateDraft else { return }
        guard templateDraft.windows.indices.contains(index) else { return }

        let defaultPwd = templateDraft.windows[index].tabs.first?.workingDirectories.first
        let newTab = ExplorerTab(
            title: nil,
            surfaceTree: ExplorerSurfaceTree(
                root: .view(ExplorerSurfaceView(pwd: defaultPwd))
            )
        )
        templateDraft.windows[index].tabs.append(newTab)
        self.templateDraft = templateDraft
        persistTemplateDraft()
    }

    private func removeTab(windowIndex: Int, tabIndex: Int) {
        guard var templateDraft else { return }
        guard templateDraft.windows.indices.contains(windowIndex) else { return }
        guard templateDraft.windows[windowIndex].tabs.count > 1 else { return }
        guard templateDraft.windows[windowIndex].tabs.indices.contains(tabIndex) else { return }

        templateDraft.windows[windowIndex].tabs.remove(at: tabIndex)
        self.templateDraft = templateDraft
        persistTemplateDraft()
    }

    private func moveTab(windowIndex: Int, from: Int, to: Int) {
        guard var templateDraft else { return }
        guard templateDraft.windows.indices.contains(windowIndex) else { return }
        guard templateDraft.windows[windowIndex].tabs.indices.contains(from) else { return }
        guard templateDraft.windows[windowIndex].tabs.indices.contains(to) else { return }

        templateDraft.windows[windowIndex].tabs.swapAt(from, to)
        self.templateDraft = templateDraft
        persistTemplateDraft()
    }

    private func defaultTemplateName(for snapshot: SessionStore.StoredSession) -> String {
        let firstTitle = snapshot.snapshot.windows.first?.displayTitle ?? "Workspace"
        return "\(firstTitle) Template"
    }
}

private struct TemplateNameSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Snapshot as Template")
                .font(.system(size: 18, weight: .semibold))

            TextField("Template Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerMuted))

                Button("Save Template", action: onConfirm)
                    .buttonStyle(SessionExplorerFilledButtonStyle(fill: .explorerAccent))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(Color.explorerSurface1)
    }
}
