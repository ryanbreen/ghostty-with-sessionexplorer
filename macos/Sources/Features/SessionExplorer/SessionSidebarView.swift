import SwiftUI

struct SessionSidebarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var templateStore: TemplateStore
    @Binding var selection: SessionExplorerSelection?
    let onSnapshotCurrent: (() -> Void)?
    let onDeleteSnapshot: (SessionStore.StoredSession) -> Void
    let onDeleteTemplate: (TemplateStore.StoredTemplate) -> Void
    let onImportTemplateFile: () -> Void
    let onPasteTemplateJSON: () -> Void

    @State private var templatesExpanded = true
    @State private var snapshotsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    sectionHeader(
                        title: "Templates",
                        isExpanded: $templatesExpanded,
                        count: templateStore.templates.count
                    )

                    if templatesExpanded {
                        ForEach(templateStore.templates) { template in
                            SessionSidebarRowView(
                                kind: .template,
                                title: template.name,
                                subtitle: "\(template.windowCount) windows, \(template.tabCount) tabs",
                                badge: nil,
                                isSelected: selection == .template(template.id),
                                onSelect: {
                                    selection = .template(template.id)
                                },
                                onDelete: {
                                    onDeleteTemplate(template)
                                }
                            )
                        }
                    }

                    sectionHeader(
                        title: "Snapshots",
                        isExpanded: $snapshotsExpanded,
                        count: store.sessions.count
                    )

                    if snapshotsExpanded {
                        ForEach(store.sessions) { session in
                            SessionSidebarRowView(
                                kind: .snapshot,
                                title: SessionExplorerFormatters.sidebarTimestamp.string(from: session.date),
                                subtitle: "\(session.windowCount) windows, \(session.tabCount) tabs",
                                badge: session.isLatest ? "ACTIVE" : nil,
                                isSelected: selection == .snapshot(session.id),
                                onSelect: {
                                    selection = .snapshot(session.id)
                                },
                                onDelete: {
                                    onDeleteSnapshot(session)
                                }
                            )
                        }
                    }
                }
            }

            footer
        }
        .background(Color.explorerSurface2)
    }

    private var header: some View {
        SessionExplorerHeaderLabel(text: "Session Explorer")
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

    private var footer: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(Color.explorerBorder)
                .frame(height: 1)

            Button("Snapshot Current") {
                explorerDebugLog("SessionSidebarView button action fired: onSnapshotCurrent=\(onSnapshotCurrent == nil ? "nil" : "set")")
                onSnapshotCurrent?()
            }
            .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))

            HStack(spacing: 8) {
                Button("Import File…", action: onImportTemplateFile)
                    .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))

                Button("Paste JSON", action: onPasteTemplateJSON)
                    .buttonStyle(SessionExplorerOutlineButtonStyle(tint: .explorerAccent))
            }
        }
        .padding(12)
        .background(Color.explorerSurface2)
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

private struct SessionSidebarRowView: View {
    enum Kind {
        case template
        case snapshot
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let badge: String?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isPresentingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: kind == .template ? "square.stack.3d.up.fill" : "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 11))
                    .foregroundColor(kind == .template ? .explorerAccent : .explorerProcess)

                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? .explorerAccent : .explorerText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.explorerAccent)
                        .kerning(0.8)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.explorerAccent.opacity(0.15))
                        )
                }

                if isHovering {
                    Button(role: .destructive) {
                        isPresentingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.explorerMissing)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(subtitle)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.explorerMuted)
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
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .alert(
            kind == .template ? "Delete template?" : "Delete snapshot?",
            isPresented: $isPresentingDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("This removes the JSON file from disk.")
        }
    }

    private var backgroundColor: Color {
        if isSelected { return .explorerSurface4 }
        if isHovering { return .explorerSurface3 }
        return .clear
    }
}
