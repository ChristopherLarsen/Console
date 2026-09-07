import SwiftUI
import SwiftData

struct CommandCreationView: View {
    var maxHeight: CGFloat = 650

    @Environment(AIProviderManager.self) private var aiProviderManager
    @Environment(LocalCommandExecutor.self) private var commandExecutor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum DictationTarget { case phrase, description }

    @State private var viewModel: CommandCreationViewModel?
    @State private var testResult: ExecutionResult?
    @State private var isTesting = false
    @State private var dictationTarget: DictationTarget?
    @State private var isDictating = false
    @FocusState private var focusedField: DictationTarget?

    // Stored as Any to avoid @available on the property
    @State private var _fieldMode: Any?

    @available(macOS 26.0, *)
    private var fieldMode: FieldDictationMode? {
        get { _fieldMode as? FieldDictationMode }
        set { _fieldMode = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    inputSection
                    if let viewModel, viewModel.hasGenerated {
                        reviewSection(viewModel: viewModel)
                    }
                }
                .padding(24)
            }
            Divider()
            footerButtons
        }
        .frame(minWidth: 520, maxWidth: 520, minHeight: 300, maxHeight: max(300, maxHeight))
        .onAppear {
            if viewModel == nil {
                viewModel = CommandCreationViewModel(
                    aiProviderManager: aiProviderManager,
                    modelContext: modelContext
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if isDictating { stopDictation() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Create Command")
                .font(.headline)
            Spacer()
            CloseButton { dismiss() }
        }
        .padding(16)
    }

    // MARK: - Input Section

    @State private var showAvailableCommands = false

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command Phrase")
                    .font(.subheadline.weight(.medium))
                Text("Say this to execute your command. Comma separated for multiple phrases.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .trailing) {
                TextField("e.g. open music, play tunes", text: Binding(
                    get: { viewModel?.triggerPhrasesText ?? "" },
                    set: { viewModel?.updateTriggerPhrasesText($0) }
                ))
                .focused($focusedField, equals: .phrase)
                .textFieldStyle(.roundedBorder)
                .onChange(of: viewModel?.triggerPhrasesText ?? "") { _, newValue in
                    let sanitized = InputSanitizer.commandPhrase(newValue)
                    if sanitized != newValue { viewModel?.updateTriggerPhrasesText(sanitized) }
                }
                .disabled(viewModel?.isGenerating == true)

                HStack(spacing: 4) {
                    if viewModel?.triggerPhrasesText.isEmpty == false {
                        Button {
                            viewModel?.updateTriggerPhrasesText("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        toggleVoiceInput(for: .phrase)
                    } label: {
                        Image(systemName: isDictating && dictationTarget == .phrase ? "mic.fill" : "mic")
                            .font(.caption)
                            .foregroundStyle(isDictating && dictationTarget == .phrase ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Voice input for command phrase")
                    .disabled(viewModel?.isGenerating == true)
                    .opacity(viewModel?.isGenerating == true ? 0.4 : 1.0)
                }
                .padding(.trailing, 6)
            }

            Text("Command Description")
                .font(.subheadline.weight(.medium))

            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { viewModel?.descriptionText ?? "" },
                    set: { viewModel?.descriptionText = $0 }
                ))
                .focused($focusedField, equals: .description)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .disabled(viewModel?.isGenerating == true)

                if viewModel?.descriptionText.isEmpty != false {
                    Text("e.g. 'Open Safari, go to google.com, and search for the weather'\n\nA command can chain multiple actions in sequence.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(12)
                        .allowsHitTesting(false)
                }

                // Mic button (top-right)
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            toggleVoiceInput(for: .description)
                        } label: {
                            Image(systemName: isDictating && dictationTarget == .description ? "mic.fill" : "mic")
                                .font(.caption)
                                .foregroundStyle(isDictating && dictationTarget == .description ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Voice input")
                        .disabled(viewModel?.isGenerating == true)
                        .opacity(viewModel?.isGenerating == true ? 0.4 : 1.0)
                        .padding(8)
                    }
                    Spacer()
                }
                .allowsHitTesting(true)

                // Clear button (bottom-right)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            viewModel?.descriptionText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear description")
                        .disabled(viewModel?.descriptionText.isEmpty != false || viewModel?.isGenerating == true)
                        .opacity((viewModel?.descriptionText.isEmpty != false || viewModel?.isGenerating == true) ? 0.4 : 1.0)
                        .padding(8)
                    }
                }
                .allowsHitTesting(true)
            }

            Text("Describe what you want in your own words and the AI will generate the automation. The AI might need a few tries to get it right.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let error = viewModel?.errorMessage {
                HStack(spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)

                    if error.contains("provider") || error.contains("Settings") || error.contains("AI Provider") {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                ConsoleNavigation.showAIProvider()
                            }
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Basic commands like 'Open Finder' and 'Close Safari' are always available without an AI provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Text("See what basic commands are available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button {
                        showAvailableCommands = true
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showAvailableCommands) {
            AvailableCommandsView()
        }
    }


    // MARK: - Review Section

    private func reviewSection(viewModel: CommandCreationViewModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: icon + editable name
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                TextField("Command name", text: Binding(
                    get: { viewModel.editableName },
                    set: { viewModel.updateName($0) }
                ))
                .font(.headline)
                .textFieldStyle(.plain)
                .onChange(of: viewModel.editableName) { _, newValue in
                    let sanitized = InputSanitizer.commandName(newValue)
                    if sanitized != newValue { viewModel.updateName(sanitized) }
                }

                Spacer()
            }

            safetyWarnings(for: viewModel.editableActions)

            if let warning = viewModel.validationWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(warning)
                        .font(.callout)
                }
                .foregroundStyle(.red)
            }

            if viewModel.hasConflict {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text("Conflict: Another command is using this phrase")
                        .font(.callout)
                }
                .foregroundStyle(.red)
            }

            // Command phrases
            VStack(alignment: .leading, spacing: 6) {
                Text("Command Phrases")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(viewModel.editableTriggerPhrases, id: \.self) { phrase in
                        Text(phrase)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }

            // Actions
            VStack(alignment: .leading, spacing: 8) {
                Text("Actions")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                ForEach(Array(viewModel.editableActions.enumerated()), id: \.element.id) { index, action in
                    actionRow(index: index, action: action)
                }
            }

            #if DEBUG
            if DeveloperModeManager.shared.isDeveloperModeEnabled {
                HStack {
                    Text("Mode:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.editableExecutionMode.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                }
            }
            #endif

            testResultBanner()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func safetyWarnings(for actions: [CommandAction]) -> some View {
        let warnings = ScriptSafetyChecker.analyze(actions: actions)
        if !warnings.isEmpty {
            SafetyWarningBanner(warnings: warnings)
        }
    }

    @ViewBuilder
    private func testResultBanner() -> some View {
        if let result = testResult {
            TestResultBanner(result: result)
        }
    }

    private func actionRow(index: Int, action: CommandAction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit().bold())
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(action.type.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Capsule())

                ScrollView {
                    Group {
                        if action.type == .appleScript {
                            Text(AppleScriptHighlighter.highlight(action.payload))
                        } else {
                            Text(action.payload)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 24, maxHeight: 80)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack(spacing: 12) {
            CapsuleButton("Cancel", style: .neutral) { dismiss() }

            Spacer()

            if viewModel?.hasGenerated == true {
                CapsuleButton(
                    "Test",
                    style: .neutral,
                    isDisabled: isTesting || viewModel?.editableActions.isEmpty == true
                ) {
                    testCommand()
                }
            }

            HStack(spacing: 8) {
                if viewModel?.isGenerating == true {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.accentColor)
                }
                CapsuleButton(
                    viewModel?.isGenerating == true ? "Generating..." : "Generate Command",
                    isDisabled: viewModel?.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                        || viewModel?.isGenerating == true
                ) {
                    Task { await viewModel?.generate() }
                }
            }

            if viewModel?.hasGenerated == true {
                CapsuleButton("Save", isDisabled: viewModel?.hasConflict == true) {
                    if viewModel?.save() == true {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func testCommand() {
        guard let viewModel else { return }
        switch viewModel.prepareDraftForExecution() {
        case .invalid:
            return
        case .ready:
            isTesting = true
            testResult = nil
            Task {
                let run = await viewModel.testDraft(using: commandExecutor)
                testResult = run?.result
                isTesting = false
            }
        }
    }

    // MARK: - Voice Input

    private func toggleVoiceInput(for target: DictationTarget) {
        if isDictating && dictationTarget == target {
            stopDictation()
        } else if isDictating && dictationTarget != target {
            // Switch target while already dictating
            dictationTarget = target
            focusedField = target
        } else {
            dictationTarget = target
            focusedField = target
            startDictation(for: target)
        }
    }

    private func startDictation(for target: DictationTarget) {
        guard #available(macOS 26.0, *) else { return }
        let mode = FieldDictationMode()
        mode.onTextFinalized = { [self] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            switch target {
            case .phrase:
                viewModel?.applyVoiceTranscriptToPhrase(trimmed)
            case .description:
                viewModel?.applyVoiceTranscript(trimmed)
            }
        }
        mode.onPauseDetected = { [self] in
            isDictating = false
            dictationTarget = nil
        }
        _fieldMode = mode
        isDictating = true
        Task {
            let accepted = await AudioSessionController.shared.requestMode(mode)
            if !accepted {
                isDictating = false
                dictationTarget = nil
                _fieldMode = nil
            }
        }
    }

    private func stopDictation() {
        isDictating = false
        dictationTarget = nil
        if #available(macOS 26.0, *), let mode = fieldMode {
            _fieldMode = nil
            Task {
                await AudioSessionController.shared.releaseMode(mode)
            }
        }
    }
}

// MARK: - Safety Warning Banner

private struct SafetyWarningBanner: View {
    let warnings: [ScriptSafetyChecker.Warning]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(warnings) { warning in
                HStack(spacing: 6) {
                    Image(systemName: warning.level == .dangerous
                          ? "exclamationmark.triangle.fill"
                          : "exclamationmark.circle.fill")
                        .foregroundStyle(warning.level == .dangerous ? .red : Color.blue)
                        .font(.caption)
                    Text(warning.message)
                        .font(.caption)
                        .foregroundStyle(warning.level == .dangerous ? .red : Color.blue)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.06)))
    }
}

// MARK: - Test Result Banner

private struct TestResultBanner: View {
    let result: ExecutionResult

    private var statusIcon: String {
        if result.alreadyRunning {
            return "exclamationmark.triangle.fill"
        }
        return result.overallSuccess ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var statusColor: Color {
        if result.alreadyRunning {
            return .orange
        }
        return result.overallSuccess ? .green : .red
    }

    private var statusText: String {
        if result.alreadyRunning {
            return CommandRun.alreadyRunningMessage
        }
        return result.overallSuccess ? "Test passed" : "Test failed"
    }

    private var bgColor: Color {
        if result.alreadyRunning {
            return Color.orange.opacity(0.08)
        }
        return result.overallSuccess ? Color.green.opacity(0.06) : Color.red.opacity(0.06)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            testHeader
            testLogEntries
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(bgColor))
    }

    private var testHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.caption.weight(.medium))
            Text("(\(result.totalDurationMs)ms)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var testLogEntries: some View {
        ForEach(result.logs) { log in
            TestLogRow(log: log)
        }
    }
}

private struct TestLogRow: View {
    let log: ExecutionLogEntry

    var body: some View {
        HStack(spacing: 4) {
            Text("Step \(log.actionIndex + 1):")
                .font(.caption2.weight(.medium))
            Text(log.message)
                .font(.caption2)
                .foregroundStyle(log.isSuccess ? Color.secondary : Color.red)
                .lineLimit(2)
        }
    }
}

// MARK: - FlowLayout

// FlowLayout is defined in Views/Components/FlowLayout.swift
