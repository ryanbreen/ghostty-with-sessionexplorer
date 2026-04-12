import AppKit
import SwiftUI

struct WindowCardView: View {
    @Binding var window: ExplorerWindow
    let windowDiff: WindowDiff?
    let isTemplate: Bool
    let dirty: Bool
    let onChange: () -> Void
    let onAssertWindow: (() -> Void)?
    let onAddTab: (() -> Void)?
    let onDeleteTab: ((Int) -> Void)?
    let onMoveTab: ((Int, Int) -> Void)?

    @State private var isExpanded = true
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .background(isHovering ? Color.explorerSurface3.opacity(0.35) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .onHover { isHovering = $0 }

            if isExpanded {
                Rectangle()
                    .fill(Color.explorerBorder)
                    .frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(Array(window.tabs.indices), id: \.self) { index in
                        TabRowView(
                            index: index + 1,
                            tab: Binding(
                                get: { window.tabs[index] },
                                set: { newValue in
                                    window.tabs[index] = newValue
                                    onChange()
                                }
                            ),
                            tabDiff: tabDiff(at: index),
                            isTemplate: isTemplate,
                            onChange: onChange,
                            onDelete: onDeleteTab.map { callback in { callback(index) } },
                            onMoveUp: index > 0 ? onMoveTab.map { callback in { callback(index, index - 1) } } : nil,
                            onMoveDown: index < window.tabs.count - 1 ? onMoveTab.map { callback in { callback(index, index + 1) } } : nil
                        )

                        if index < window.tabs.count - 1 {
                            Rectangle()
                                .fill(Color.explorerBorder.opacity(0.50))
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.explorerSurface1)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(dirty ? Color.explorerAccent.opacity(0.45) : Color.explorerBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.explorerMuted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            Image(systemName: isTemplate ? "square.stack.3d.up.fill" : "rectangle.split.3x1")
                .font(.system(size: 12))
                .foregroundColor(isTemplate ? .explorerAccent : .explorerProcess)

            if isTemplate {
                SessionExplorerCommitTextField(
                    placeholder: "Window Title",
                    text: window.title ?? "",
                    font: .monospacedSystemFont(ofSize: 13, weight: .medium),
                    onCommit: commitTitle
                )
            } else {
                Text(window.displayTitle)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.explorerText)
                    .lineLimit(1)
            }

            Text("· \(window.tabs.count) \(window.tabs.count == 1 ? "tab" : "tabs")")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.explorerMuted)

            if isTemplate {
                SessionExplorerCommitTextField(
                    placeholder: "Space",
                    text: window.workspace.map(String.init) ?? "",
                    font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                    onCommit: commitWorkspace
                )
                    .frame(width: 72)
            } else if let workspace = window.workspace {
                SessionExplorerWorkspaceBadge(label: "Space \(workspace)")
            }

            if dirty {
                Text("UNSAVED")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.explorerAccent)
                    .kerning(0.8)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.explorerAccent.opacity(0.14))
                    )
            }

            Spacer(minLength: 16)

            if let status = windowDiff?.status {
                SessionExplorerStatusBadge(status: status)
            }

            if let onAddTab {
                Button {
                    onAddTab()
                } label: {
                    Label("Add Tab", systemImage: "plus")
                }
                .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))
            }

            if let onAssertWindow {
                let shouldShow: Bool = {
                    guard let status = windowDiff?.status else { return true }
                    return !sessionExplorerIsMatch(status)
                }()
                if shouldShow {
                    Button("Assert Window") {
                        onAssertWindow()
                    }
                    .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func commitTitle(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = trimmed.isEmpty ? nil : trimmed
        onChange()
    }

    private func commitWorkspace(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window.workspace = Int(trimmed)
        onChange()
    }

    private func tabDiff(at index: Int) -> TabDiff? {
        guard let windowDiff else { return nil }
        guard windowDiff.tabDiffs.indices.contains(index) else { return nil }
        return windowDiff.tabDiffs[index]
    }
}
