import AppKit
import SwiftUI

struct PaneRowView: View {
    let positionLabel: String
    @Binding var pane: ExplorerSurfaceView
    let paneDiff: PaneDiff?
    let isTemplate: Bool
    let canDelete: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onChange: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                Rectangle()
                    .fill(Color.explorerBorder.opacity(0.50))
                    .frame(height: 1)

                editor
            }
        }
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? Color.explorerAccent.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onHover { isHovering = $0 }
        .onChange(of: isSelected) { selected in
            if selected {
                isExpanded = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.explorerMuted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            Text(positionLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.explorerMuted)
                .frame(width: 88, alignment: .leading)

            Text(displayWorkingDirectory)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.explorerText)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !startupSummary.isEmpty {
                Text(startupSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.explorerProcess)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.explorerProcess.opacity(0.14))
                    )
            }

            if !processName.isEmpty {
                Text(processName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.explorerProcess.opacity(0.85))
            }

            if let stateIDPrefix {
                Text(stateIDPrefix)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.explorerMuted.opacity(0.7))
                    .help(pane.stateID ?? "")
            }

            if let status = paneDiff?.status {
                SessionExplorerStatusDot(status: status, size: 6)
            }

            if isTemplate && canDelete && isHovering {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.explorerMissing)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SessionExplorerHeaderLabel(text: "Working Directory")
                SessionExplorerCommitTextField(
                    placeholder: "Working Directory",
                    text: pane.pwd ?? "",
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    onCommit: commitWorkingDirectory
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                SessionExplorerHeaderLabel(text: "Startup")

                Picker("Startup Mode", selection: commandModeBinding) {
                    ForEach(PaneCommandMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch commandMode {
                case .none:
                    Text(editingHint)
                        .font(.system(size: 11))
                        .foregroundColor(.explorerMuted)

                case .literal:
                    SessionExplorerCommitTextEditor(
                        text: literalCommandsText,
                        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                        onCommit: commitLiteralCommands
                    )
                        .frame(minHeight: 88)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.explorerBorder, lineWidth: 1)
                        }

                case .dynamic:
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Resolver", selection: resolverBinding) {
                            ForEach(BuiltinStartupResolver.allCases) { resolver in
                                Text(resolver.title).tag(resolver.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        if resolverName == BuiltinStartupResolver.claudeResumeNth.rawValue {
                            SessionExplorerCommitTextField(
                                placeholder: "n",
                                text: nthValue,
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                onCommit: commitNthValue
                            )
                        }

                        Text("Resolver runs at assert time. Failures fall back to an echo command in the pane.")
                            .font(.system(size: 11))
                            .foregroundColor(.explorerMuted)
                    }
                }
            }

            Text(editingHint)
                .font(.system(size: 11))
                .foregroundColor(.explorerMuted)
        }
        .padding(12)
    }

    private var backgroundColor: Color {
        if isSelected {
            return .explorerSurface4
        }
        if isHovering {
            return .explorerSurface3.opacity(0.45)
        }
        return .explorerSurface2.opacity(0.35)
    }

    private var displayWorkingDirectory: String {
        pane.pwd ?? paneDiff?.workingDirectory ?? "default shell"
    }

    private var startupSummary: String {
        pane.command?.summary ?? paneDiff?.startupCommand ?? ""
    }

    /// First 8 characters of this pane's persistent state ID, shown next to
    /// the status dot so we can visually confirm every pane has stable
    /// identity baked in. Hover for the full UUID.
    private var stateIDPrefix: String? {
        guard let id = pane.stateID, !id.isEmpty else { return nil }
        return String(id.prefix(8))
    }

    private var processName: String {
        paneDiff?.processName ?? pane.foregroundProcess ?? ""
    }

    private var editingHint: String {
        isTemplate ? "Template edits save immediately." : "Snapshot edits apply when you click Save Changes."
    }

    private var commandMode: PaneCommandMode {
        switch pane.command {
        case .some(.literal(_)):
            return .literal
        case .some(.dynamic(_, _)):
            return .dynamic
        case nil:
            return .none
        }
    }

    private var literalCommandsText: String {
        if case .literal(let commands) = pane.command {
            return commands.joined(separator: "\n")
        }
        return ""
    }

    private var nthValue: String {
        if case .some(.dynamic(_, let params)) = pane.command {
            return params["n"] ?? "0"
        }
        return "0"
    }

    private func commitWorkingDirectory(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pane.pwd = trimmed.isEmpty ? nil : trimmed
        onChange()
    }

    private func commitLiteralCommands(_ newValue: String) {
        let commands = newValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        pane.command = .literal(commands: commands)
        onChange()
    }

    private func commitNthValue(_ newValue: String) {
        var params = pane.command?.params ?? [:]
        params["n"] = newValue
        pane.command = .dynamic(resolver: resolverName, params: params)
        onChange()
    }

    private var commandModeBinding: Binding<PaneCommandMode> {
        Binding(
            get: { commandMode },
            set: { newMode in
                switch newMode {
                case .none:
                    pane.command = nil
                case .literal:
                    if case .some(.literal(_)) = pane.command {
                    } else {
                        pane.command = .literal(commands: [])
                    }
                case .dynamic:
                    if case .some(.dynamic(_, _)) = pane.command {
                    } else {
                        pane.command = .dynamic(
                            resolver: BuiltinStartupResolver.claudeResumeLatest.rawValue,
                            params: [:]
                        )
                    }
                }
                onChange()
            }
        )
    }

    private var resolverName: String {
        if case .some(.dynamic(let resolver, _)) = pane.command {
            return resolver
        }
        return BuiltinStartupResolver.claudeResumeLatest.rawValue
    }

    private var resolverBinding: Binding<String> {
        Binding(
            get: { resolverName },
            set: { newValue in
                let params = pane.command?.params ?? [:]
                pane.command = .dynamic(resolver: newValue, params: params)
                onChange()
            }
        )
    }
}
