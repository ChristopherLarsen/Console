import SwiftUI

@available(macOS 26.0, *)
struct LiveView: View {
    @Environment(MenuBarViewModel.self) private var menuBarViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: CommandViewModel?
    @State private var inputText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcriberSection
                statusBar
                commandInputSection
                commandResultSection
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = CommandViewModel()
            }
        }
    }

    // MARK: - Transcriber Feed

    private var transcriberSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Mode Transcript")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            let activeMode = AudioSessionController.shared.activeMode

            VStack(alignment: .leading, spacing: 6) {
                Text("Mode")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(activeMode?.modeIdentifier ?? "none")
                    .font(.callout)
                    .foregroundStyle(.primary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Volatile")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(activeVolatileText)
                    .font(.callout)
                    .foregroundStyle(Color.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcript")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(activeTranscript)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var activeVolatileText: String {
        let mode = AudioSessionController.shared.activeMode
        if let cmd = mode as? CommandListeningMode {
            let text = cmd.volatileText
            return text.isEmpty ? "—" : text
        }
        if let note = mode as? NoteDictationMode {
            let text = note.volatileText
            return text.isEmpty ? "—" : text
        }
        return "—"
    }

    private var activeTranscript: String {
        let mode = AudioSessionController.shared.activeMode
        if let cmd = mode as? CommandListeningMode {
            let text = cmd.fullTranscript
            return text.isEmpty ? "Listening..." : text
        }
        if let note = mode as? NoteDictationMode {
            let text = note.fullTranscript
            return text.isEmpty ? "Listening..." : text
        }
        return "No active mode"
    }

    // MARK: - Status Bar

    private var listeningActive: Bool {
        menuBarViewModel.listeningState != .off
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(listeningActive ? Color(red: 0.1, green: 0.45, blue: 0.15) : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
                .shadow(color: listeningActive ? Color(red: 0.1, green: 0.45, blue: 0.15).opacity(0.5) : .clear, radius: 4)

            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            if viewModel?.isProcessing == true {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Processing")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var statusText: String {
        switch menuBarViewModel.listeningState {
        case .off:
            return "Inactive"
        case .passive:
            return "Listening for trigger"
        case .commandListening:
            return "Listening for command"
        case .awaitingAuthorization:
            return "Awaiting authorization"
        case .executing:
            return "Executing"
        }
    }

    // MARK: - Command Input Section

    private var commandInputSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trigger")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)

                    let trigger = menuBarViewModel.lastDetectedTrigger
                    Text(trigger.isEmpty ? "Waiting for trigger word..." : trigger)
                        .font(.callout)
                        .foregroundStyle(trigger.isEmpty ? .secondary : .primary)
                }

                Spacer()

                if triggerDetected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Color(red: 0.1, green: 0.45, blue: 0.15))
                }
            }

            Divider()
                .padding(.leading, 36)

            HStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.callout)
                    .foregroundStyle(displayedSpeechText == "Listening for speech..." ? Color.secondary : Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Speech")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(displayedSpeechText)
                        .font(.callout)
                        .foregroundStyle(displayedSpeechText == "Listening for speech..." ? .secondary : .primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !menuBarViewModel.lastMatchResult.isEmpty {
                Divider()
                    .padding(.leading, 36)

                HStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(matchResultColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Result")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)

                        Text(menuBarViewModel.lastMatchResult)
                            .font(.callout)
                            .foregroundStyle(matchResultColor)
                    }

                    Spacer()

                    Image(systemName: matchResultIcon)
                        .font(.callout)
                        .foregroundStyle(matchResultColor)
                }
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var triggerDetected: Bool {
        !menuBarViewModel.lastDetectedTrigger.isEmpty
    }

    private var matchResultColor: Color {
        let result = menuBarViewModel.lastMatchResult
        if result.hasPrefix("Matched:") || result.hasPrefix("Built-in:") {
            return Color(red: 0.1, green: 0.45, blue: 0.15)
        }
        return .red
    }

    private var matchResultIcon: String {
        let result = menuBarViewModel.lastMatchResult
        if result.hasPrefix("Matched:") || result.hasPrefix("Built-in:") {
            return "checkmark.circle.fill"
        }
        return "xmark.circle.fill"
    }

    private var displayedSpeechText: String {
        if !menuBarViewModel.fuzzyMatchInputText.isEmpty {
            return menuBarViewModel.fuzzyMatchInputText
        }
        return "Listening for speech..."
    }

    // MARK: - Command Result Section

    private var commandResultSection: some View {
        Group {
            if let viewModel, let latest = viewModel.commands.last {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Latest Command")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    CommandRow(entry: latest)
                        .padding(.horizontal, 16)
                }

                Spacer()
            } else {
                emptyState
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Spacer()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func submitCommand() {
        let text = inputText
        inputText = ""
        guard let viewModel else { return }
        Task {
            await viewModel.processCommand(text)
        }
    }
}

// MARK: - Command Row

@available(macOS 26.0, *)
private struct CommandRow: View {
    let entry: CommandEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIndicator

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.inputText)
                    .font(.body)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Text(toolBadge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.12))
                        .foregroundStyle(badgeColor)
                        .clipShape(Capsule())

                    Text(entry.status.displayLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(entry.status.indicatorColor)

                    Spacer()

                    Text(entry.createdAt.timeString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let result = entry.resultMessage, !result.isEmpty {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(entry.status == .failed ? .red : .primary)
                        .lineLimit(4)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch entry.status {
        case .executing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        default:
            Image(systemName: entry.status.indicatorIcon)
                .font(.body)
                .foregroundStyle(entry.status.indicatorColor)
                .frame(width: 22, height: 22)
        }
    }

    private var toolBadge: String {
        switch entry.toolName {
        case "controlGateway": return "Gateway"
        case "openApplication": return "App"
        case "systemControl": return "System"
        default: return "Command"
        }
    }

    private var badgeColor: Color {
        switch entry.toolName {
        case "openApplication": return .blue
        case "systemControl": return .purple
        case "controlGateway": return Color.accentColor
        default: return Color.accentColor
        }
    }
}
