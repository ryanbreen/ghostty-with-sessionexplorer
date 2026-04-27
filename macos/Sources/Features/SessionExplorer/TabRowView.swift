import AppKit
import SwiftUI

struct TabRowView: View {
    let index: Int
    @Binding var tab: ExplorerTab
    let tabDiff: TabDiff?
    let isTemplate: Bool
    let onChange: () -> Void
    let onDelete: (() -> Void)?
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    @State private var selectedPanePathKey: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    SplitTreeMiniMapView(
                        node: tab.surfaceTree.root,
                        selectedPanePathKey: selectedPanePathKey,
                        onSelect: { path in
                            selectedPanePathKey = path.sessionExplorerPathKey
                        }
                    )
                    .frame(height: 110)

                    VStack(spacing: 0) {
                        ForEach(Array(panes.enumerated()), id: \.offset) { index, pane in
                            PaneRowView(
                                positionLabel: pane.position,
                                pane: binding(for: pane.path),
                                paneDiff: paneDiff(at: index),
                                isTemplate: isTemplate,
                                canDelete: isTemplate && panes.count > 1,
                                isSelected: selectedPanePathKey == pane.path.sessionExplorerPathKey,
                                onSelect: {
                                    selectedPanePathKey = pane.path.sessionExplorerPathKey
                                },
                                onChange: onChange,
                                onDelete: {
                                    tab.surfaceTree.removePane(at: pane.path)
                                    onChange()
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Toggle hit area is restricted to the leading chevron + index
            // so the title text field below can actually receive focus —
            // a row-wide .onTapGesture eats the click that SwiftUI would
            // otherwise hand to the embedded NSTextField.
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.explorerMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)

                Text("\(index)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.explorerMuted)
                    .frame(width: 24, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }

            if isTemplate {
                SessionExplorerCommitTextField(
                    placeholder: "Tab Title",
                    text: tab.title ?? "",
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    onCommit: commitTitle
                )
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.explorerText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(layoutDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.explorerMuted)
                .lineLimit(1)

            if let status = tabDiff?.status {
                SessionExplorerStatusDot(status: status, size: 8)
            }

            if isTemplate {
                if let onMoveUp {
                    Button(action: onMoveUp) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.explorerMuted)
                }

                if let onMoveDown {
                    Button(action: onMoveDown) {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.explorerMuted)
                }

                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.explorerMissing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var panes: [ExplorerSurfaceNode.FlattenedPane] {
        tab.surfaceTree.root.flattenedPanes()
    }

    private var layoutDescription: String {
        let count = panes.count
        return count == 1 ? "single pane" : "\(count) panes"
    }

    private func paneDiff(at index: Int) -> PaneDiff? {
        guard let tabDiff else { return nil }
        guard tabDiff.paneDiffs.indices.contains(index) else { return nil }
        return tabDiff.paneDiffs[index]
    }

    private func commitTitle(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.title = trimmed.isEmpty ? nil : trimmed
        onChange()
    }

    private func binding(for path: [Int]) -> Binding<ExplorerSurfaceView> {
        Binding(
            get: { tab.surfaceTree.view(at: path) ?? ExplorerSurfaceView() },
            set: { newValue in
                tab.surfaceTree.updateView(at: path) { pane in
                    pane = newValue
                }
                onChange()
            }
        )
    }
}

private struct SplitTreeMiniMapView: View {
    let node: ExplorerSurfaceNode
    let selectedPanePathKey: String?
    let onSelect: ([Int]) -> Void

    var body: some View {
        GeometryReader { proxy in
            SplitTreeMiniNodeView(
                node: node,
                path: [],
                selectedPanePathKey: selectedPanePathKey,
                onSelect: onSelect
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.explorerSurface2)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.explorerBorder, lineWidth: 1)
        }
    }
}

private struct SplitTreeMiniNodeView: View {
    let node: ExplorerSurfaceNode
    let path: [Int]
    let selectedPanePathKey: String?
    let onSelect: ([Int]) -> Void

    var body: some View {
        GeometryReader { proxy in
            content(size: proxy.size)
        }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        switch node {
        case .view(let view):
            Button {
                onSelect(path)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fillColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Spacer()
                        Text(path.sessionExplorerPathKey == "root" ? "root" : path.sessionExplorerPathKey)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.explorerText)

                        Text(miniLabel(for: view))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.explorerMuted)
                            .lineLimit(1)
                    }
                    .padding(8)
                }
            }
            .buttonStyle(.plain)

        case .split(let split):
            if split.direction == "vertical" {
                VStack(spacing: 4) {
                    SplitTreeMiniNodeView(
                        node: split.left,
                        path: path + [0],
                        selectedPanePathKey: selectedPanePathKey,
                        onSelect: onSelect
                    )
                    .frame(height: max(size.height * split.ratio - 2, 24))

                    SplitTreeMiniNodeView(
                        node: split.right,
                        path: path + [1],
                        selectedPanePathKey: selectedPanePathKey,
                        onSelect: onSelect
                    )
                    .frame(height: max(size.height * (1 - split.ratio) - 2, 24))
                }
            } else {
                HStack(spacing: 4) {
                    SplitTreeMiniNodeView(
                        node: split.left,
                        path: path + [0],
                        selectedPanePathKey: selectedPanePathKey,
                        onSelect: onSelect
                    )
                    .frame(width: max(size.width * split.ratio - 2, 24))

                    SplitTreeMiniNodeView(
                        node: split.right,
                        path: path + [1],
                        selectedPanePathKey: selectedPanePathKey,
                        onSelect: onSelect
                    )
                    .frame(width: max(size.width * (1 - split.ratio) - 2, 24))
                }
            }
        }
    }

    private var fillColor: Color {
        selectedPanePathKey == path.sessionExplorerPathKey
            ? .explorerAccent.opacity(0.28)
            : .explorerSurface4
    }

    private func miniLabel(for view: ExplorerSurfaceView) -> String {
        if let pwd = view.pwd, !pwd.isEmpty {
            return URL(fileURLWithPath: pwd).lastPathComponent
        }
        if let summary = view.command?.summary, !summary.isEmpty {
            return summary
        }
        return "shell"
    }
}
