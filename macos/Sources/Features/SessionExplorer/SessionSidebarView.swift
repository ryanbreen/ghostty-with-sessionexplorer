import SwiftUI

struct SessionSidebarView: View {
    @ObservedObject var stateStore: StateStore
    @Binding var selection: SessionExplorerSelection?
    let onRestoreBackup: (StateStore.StoredBackup) -> Void

    @State private var backupsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let state = stateStore.state {
                        SessionSidebarStateRowView(
                            title: state.name,
                            subtitle: "\(state.windowCount) windows, \(state.tabCount) tabs",
                            isSelected: selection == .state,
                            onSelect: {
                                selection = .state
                            }
                        )
                    } else {
                        SessionSidebarStateRowView(
                            title: "Ghostty State",
                            subtitle: "No canonical state file",
                            isSelected: selection == .state,
                            onSelect: {
                                selection = .state
                            }
                        )
                    }

                    sectionHeader(
                        title: "Backups",
                        isExpanded: $backupsExpanded,
                        count: stateStore.backups.count
                    )

                    if backupsExpanded {
                        ForEach(stateStore.backups) { backup in
                            SessionSidebarBackupRowView(
                                title: SessionExplorerFormatters.sidebarTimestamp.string(from: backup.date),
                                subtitle: "\(backup.windowCount) windows, \(backup.tabCount) tabs",
                                isSelected: selection == .backup(backup.id),
                                onView: {
                                    selection = .backup(backup.id)
                                },
                                onRestore: {
                                    onRestoreBackup(backup)
                                }
                            )
                        }
                    }
                }
            }
        }
        .background(Color.explorerSurface2)
    }

    private var header: some View {
        SessionExplorerHeaderLabel(text: "Ghostty State")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.explorerBorder)
                    .frame(height: 1)
            }
    }

    private func sectionHeader(title: String, isExpanded: Binding<Bool>, count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.explorerMuted)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.explorerMuted)
                    .kerning(1.0)
                    .textCase(.uppercase)

                Spacer()

                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.explorerMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.explorerSurface2)
        }
        .buttonStyle(.plain)
    }
}

private struct SessionSidebarStateRowView: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.split.3x1.fill")
                .font(.system(size: 12))
                .foregroundColor(.explorerAccent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? .explorerAccent : .explorerText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.explorerMuted)
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(backgroundColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Color.explorerAccent : Color.clear)
                .frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.explorerBorder.opacity(0.50))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if isSelected { return .explorerSurface4 }
        if isHovering { return .explorerSurface3 }
        return .clear
    }
}

private struct SessionSidebarBackupRowView: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onView: () -> Void
    let onRestore: () -> Void

    @State private var isHovering = false
    @State private var isPresentingRestoreConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 11))
                    .foregroundColor(.explorerProcess)

                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? .explorerAccent : .explorerText)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                Text(subtitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.explorerMuted)

                Spacer(minLength: 8)

                Button("View", action: onView)
                    .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerMuted))

                Button("Restore") {
                    isPresentingRestoreConfirmation = true
                }
                .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(backgroundColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Color.explorerAccent : Color.clear)
                .frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.explorerBorder.opacity(0.50))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onView)
        .onHover { isHovering = $0 }
        .alert("Restore backup?", isPresented: $isPresentingRestoreConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive, action: onRestore)
        } message: {
            Text("This replaces state.json after first backing up the current canonical state.")
        }
    }

    private var backgroundColor: Color {
        if isSelected { return .explorerSurface4 }
        if isHovering { return .explorerSurface3 }
        return .clear
    }
}
