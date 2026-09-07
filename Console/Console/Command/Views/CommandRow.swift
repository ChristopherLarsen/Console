import SwiftUI

struct ExpandableCommandRow: View {
    @Bindable var command: Command
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onDelete: () -> Void
    let onTest: () async -> Void
    var onStop: (() -> Void)?
    let onEdit: () -> Void
    var onSave: (() -> Void)?

    @State private var isTesting = false
    @State private var isHovered = false
    @State private var cachedDescriptionKey: LocalizedStringKey?
    @State private var cachedDescriptionSource = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedContent

            if isExpanded {
                expandedContent
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(command.isConsole ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.1))
                .shadow(color: .black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 4 : 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isTesting ? Color.accentColor.opacity(0.5) : command.isConsole ? Color.accentColor.opacity(0.3) : Color.clear,
                    lineWidth: (isTesting || command.isConsole) ? 0.5 : 0
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isExpanded)
        .onHover { isHovered = $0 }
        .onAppear { fillMissingAIFields() }
        .onChange(of: command.isEnabled) { _, _ in onSave?() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var rowAccessibilityLabel: String {
        var parts = [command.name]
        if !command.isEnabled { parts.append("disabled") }
        if isTesting { parts.append("testing") }
        if isExpanded { parts.append("expanded") }
        return parts.joined(separator: ", ")
    }

    private func fillMissingAIFields() {
        var changed = false
        if command.shortSummary.isEmpty {
            let placeholder = command.generatePlaceholderSummary()
            if !placeholder.isEmpty {
                command.shortSummary = placeholder
                changed = true
            }
        }
        if command.actionDescription.isEmpty {
            let placeholder = command.generatePlaceholderActionDescription()
            if !placeholder.isEmpty {
                command.actionDescription = placeholder
                changed = true
            }
        }
        if changed { onSave?() }
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if command.isConsole {
                        Image(systemName: "fish.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }

                    if command.requiresConfirmation {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                            .help("Requires authorization before executing")
                    }

                    Text(command.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if !command.isEnabled {
                        Text("(disabled)")
                            .font(.caption)
                            .foregroundStyle(.gray.opacity(0.6))
                    }
                }

                if let phrase = command.triggerPhrases.first, !phrase.isEmpty {
                    HStack(spacing: 3) {
                        Text("Say:")
                            .font(.caption)
                            .foregroundStyle(.gray)
                        Text("\"\(phrase)\"")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .lineLimit(1)
                }

                if !command.shortSummary.isEmpty {
                    Text(command.shortSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle("", isOn: $command.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            .accessibilityHint("Toggle command on or off")
        }
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.top, 8)

            if command.triggerPhrases.count > 0 {
                triggerPhrasesSection
            }

            actionsSection

            Divider()

            expandedFooter
        }
    }

    private var triggerPhrasesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command.triggerPhrases.count == 1 ? "COMMAND PHRASE" : "COMMAND PHRASES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(command.triggerPhrases, id: \.self) { phrase in
                    Text(phrase)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("ACTIONS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("\(command.actions.count) step\(command.actions.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            let sortedActions = command.actions.sorted(by: { $0.order < $1.order })
            ForEach(Array(sortedActions.enumerated()), id: \.element.id) { index, action in
                actionStepRow(index: index, action: action)
            }
        }
    }

    private func actionStepRow(index: Int, action: CommandAction) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(action.type.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())

                Text(action.payload)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var expandedFooter: some View {
        HStack {
            Button {
                onDelete()
            } label: {
                Text("Delete")
                    .font(.callout)
                    .accessibilityIdentifier("Delete")
            }
            .buttonStyle(.plain)
            .foregroundStyle(command.isProtected ? .gray : .red)
            .disabled(command.isProtected)
            .help(command.isProtected ? "This command is protected" : "Delete command")
            .accessibilityLabel("Delete \(command.name)")

            Spacer()

            authorizationButton

            Divider()
                .frame(height: 14)
                .foregroundStyle(.tertiary)

            testButton

            Divider()
                .frame(height: 14)
                .foregroundStyle(.tertiary)

            Button {
                onEdit()
            } label: {
                Text("Edit")
                    .font(.callout)
                    .accessibilityIdentifier("Edit")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Edit command details")
            .accessibilityLabel("Edit \(command.name)")
        }
    }

    private var authorizationButton: some View {
        Button {
            command.requiresConfirmation.toggle()
        } label: {
            Text(command.requiresConfirmation ? "Authorization: Required" : "Authorization: No")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private var testButton: some View {
        Button {
            if isTesting {
                onStop?()
            } else {
                testCommand()
            }
        } label: {
            HStack(spacing: 4) {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Stop")
                        .font(.callout)
                } else {
                    Text("Test")
                        .font(.callout)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(isTesting && onStop == nil)
        .help(isTesting ? "Stop command" : "Test command")
        .accessibilityLabel(isTesting ? "Stop command" : "Test command")
    }

    private func testCommand() {
        isTesting = true
        Task {
            await onTest()
            isTesting = false
        }
    }

    // Cached markdown key, recomputed only when actionDescription changes
    private var descriptionKey: LocalizedStringKey {
        if cachedDescriptionSource == command.actionDescription, let key = cachedDescriptionKey {
            return key
        }
        let key = LocalizedStringKey(command.actionDescription)
        DispatchQueue.main.async {
            cachedDescriptionSource = command.actionDescription
            cachedDescriptionKey = key
        }
        return key
    }
}
