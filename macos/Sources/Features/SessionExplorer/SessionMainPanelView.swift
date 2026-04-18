import AppKit
import SwiftUI

struct SessionMainPanelView: View {
    let state: StateStore.StoredState?
    let backup: StateStore.StoredBackup?
    let diff: SessionDiff?
    let onSaveState: ((SessionTemplate) -> Void)?
    let onSyncFromLive: (() -> Void)?
    let onAssertState: ((SessionTemplate) -> Void)?
    let onAssertWindow: ((ExplorerWindow) -> Void)?
    let onRecaptureWindow: ((Int) -> Void)?
    let onRestoreBackup: ((StateStore.StoredBackup) -> Void)?

    @State private var stateDraft: SessionTemplate?

    var body: some View {
        Group {
            if let backup {
                backupContent(backup)
            } else if let state {
                stateContent(state)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.explorerSurface1)
        .onAppear {
            loadStateDraft()
        }
        .task(id: state?.id) {
            loadStateDraft()
        }
        .onChange(of: state?.template) { _ in
            loadStateDraft()
        }
    }

    private func stateContent(_ state: StateStore.StoredState) -> some View {
        VStack(spacing: 0) {
            stateHeader(state)

            if let stateDraft {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(stateDraft.windows.indices), id: \.self) { index in
                            WindowCardView(
                                window: Binding(
                                    get: { stateDraft.windows[index] },
                                    set: { newValue in
                                        self.stateDraft?.windows[index] = newValue
                                    }
                                ),
                                windowDiff: windowDiff(at: index),
                                isTemplate: true,
                                dirty: false,
                                onChange: { persistStateDraft() },
                                onAssertWindow: {
                                    onAssertWindow?(stateDraft.windows[index])
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
                placeholder(message: "No windows in state.json")
            }
        }
        .onAppear {
            if stateDraft == nil {
                stateDraft = state.template
            }
        }
    }

    private func backupContent(_ backup: StateStore.StoredBackup) -> some View {
        VStack(spacing: 0) {
            backupHeader(backup)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(backup.template.windows.indices), id: \.self) { index in
                        WindowCardView(
                            window: .constant(backup.template.windows[index]),
                            windowDiff: nil,
                            isTemplate: false,
                            dirty: false,
                            onChange: {},
                            onAssertWindow: nil,
                            onRecaptureWindow: nil,
                            onAddTab: nil,
                            onDeleteTab: nil,
                            onMoveTab: nil
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 28))
                .foregroundColor(.explorerMuted)

            Text("No Ghostty state")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.explorerMuted)

            Text("Create ~/.config/ghostty/state.json by saving window state or migrating an existing template.")
                .font(.system(size: 12))
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

    private func stateHeader(_ state: StateStore.StoredState) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SessionExplorerHeaderLabel(text: "Ghostty State")

                SessionExplorerCommitTextField(
                    placeholder: "State Name",
                    text: stateDraft?.name ?? state.name,
                    font: .monospacedSystemFont(ofSize: 18, weight: .semibold),
                    onCommit: commitStateName
                )
                .frame(maxWidth: 380)

                diffSummary
            }

            Spacer(minLength: 16)

            Button("Sync from Live") {
                onSyncFromLive?()
            }
            .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))

            Button("Assert All") {
                if let stateDraft {
                    onAssertState?(stateDraft)
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

    private func backupHeader(_ backup: StateStore.StoredBackup) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SessionExplorerHeaderLabel(text: "Backup")

                Text(SessionExplorerFormatters.headerTimestamp.string(from: backup.date))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.explorerText)

                Text("\(backup.windowCount) windows, \(backup.tabCount) tabs")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.explorerMuted)
            }

            Spacer(minLength: 16)

            Button("Restore Backup") {
                onRestoreBackup?(backup)
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

    private func loadStateDraft() {
        stateDraft = state?.template
    }

    private func windowDiff(at index: Int) -> WindowDiff? {
        guard let diff else { return nil }
        guard diff.windows.indices.contains(index) else { return nil }
        return diff.windows[index]
    }

    private func persistStateDraft() {
        guard let stateDraft else { return }
        onSaveState?(stateDraft)
    }

    private func commitStateName(_ newValue: String) {
        stateDraft?.name = newValue
        persistStateDraft()
    }

    private func addTab(toWindowAt index: Int) {
        guard var stateDraft else { return }
        guard stateDraft.windows.indices.contains(index) else { return }

        let defaultPwd = stateDraft.windows[index].tabs.first?.workingDirectories.first
        let newTab = ExplorerTab(
            title: nil,
            surfaceTree: ExplorerSurfaceTree(
                root: .view(ExplorerSurfaceView(pwd: defaultPwd))
            )
        )
        stateDraft.windows[index].tabs.append(newTab)
        self.stateDraft = stateDraft
        persistStateDraft()
    }

    private func removeTab(windowIndex: Int, tabIndex: Int) {
        guard var stateDraft else { return }
        guard stateDraft.windows.indices.contains(windowIndex) else { return }
        guard stateDraft.windows[windowIndex].tabs.count > 1 else { return }
        guard stateDraft.windows[windowIndex].tabs.indices.contains(tabIndex) else { return }

        stateDraft.windows[windowIndex].tabs.remove(at: tabIndex)
        self.stateDraft = stateDraft
        persistStateDraft()
    }

    private func moveTab(windowIndex: Int, from: Int, to: Int) {
        guard var stateDraft else { return }
        guard stateDraft.windows.indices.contains(windowIndex) else { return }
        guard stateDraft.windows[windowIndex].tabs.indices.contains(from) else { return }
        guard stateDraft.windows[windowIndex].tabs.indices.contains(to) else { return }

        stateDraft.windows[windowIndex].tabs.swapAt(from, to)
        self.stateDraft = stateDraft
        persistStateDraft()
    }
}
