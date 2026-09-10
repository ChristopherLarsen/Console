import SwiftUI
import SwiftData

struct SettingsView: View {
    var modelContext: ModelContext
    @Environment(ThemeManager.self) private var themeManager

    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("listenOnStartup") private var listenOnStartup: Bool = true
    @AppStorage("soundFeedbackEnabled") private var soundFeedbackEnabled: Bool = true
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""
    @AppStorage("webViewMergeRequestsURL") private var webViewMergeRequestsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabReviewsURLKey) private var webViewGitLabReviewsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabMyMergeRequestsURLKey) private var webViewGitLabMyMergeRequestsURL: String = ""

    @AppStorage("cueTriggerRecognized") private var cueTriggerRecognized: String = AppSettings.CueSound.fishListening.rawValue
    @AppStorage("cueCommandRecognized") private var cueCommandRecognized: String = AppSettings.CueSound.happyFish.rawValue
    @AppStorage("cueCommandNotRecognized") private var cueCommandNotRecognized: String = AppSettings.CueSound.sadFish.rawValue
    @AppStorage("feedbackSoundVolume") private var feedbackSoundVolume: Double = 0.7
    @AppStorage("confidenceLevel") private var confidenceLevel: String = AppSettings.ConfidenceLevel.normal.rawValue
    @AppStorage("requireConfirmationForDangerous") private var requireConfirmationForDangerous: Bool = true
    @AppStorage("voiceOnlyAuthorization") private var voiceOnlyAuthorization: Bool = true
    @AppStorage("requireAuthorizationForAllCommands") private var requireAuthorizationForAllCommands: Bool = false
    @AppStorage("customAuthorizationWords") private var customAuthorizationWords: String = "Authorized, Proceed, Ok, Go, Sure"
    @AppStorage("authorizationTimeoutSeconds") private var authorizationTimeoutSeconds: Int = 15
    @AppStorage("enableCommandLogging") private var enableCommandLogging: Bool = false
    @AppStorage("recognizeBuiltInCommands") private var recognizeBuiltInCommands: Bool = true
    @AppStorage("enableBuiltInCommands") private var enableBuiltInCommands: Bool = true
    @AppStorage("showCommandPopups") private var showCommandPopups: Bool = false
    @AppStorage("showErrorPopups") private var showErrorPopups: Bool = false
    @AppStorage("popupDurationSeconds") private var popupDurationSeconds: Int = 3
    @AppStorage("sleepAfterInterval") private var sleepAfterInterval: String = AppSettings.SleepInterval.thirtyMinutes.rawValue
    @AppStorage(AppSettings.defaultTerminalFolderKey) private var defaultTerminalFolder: String = AppSettings.defaultTerminalFolderDefault
    
    @Environment(InfoManager.self) private var infoManager
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @Environment(PermissionBackgroundObserver.self) private var permissionObserver: PermissionBackgroundObserver?
    @Environment(UpdateManager.self) private var updateManager
    @State private var showHotkeyRecorder = false
    @State private var showPermissions = false
    @State private var showAvailableCommands = false
    /// Sensitive-confirmation preference before "every command" cleared it, so
    /// turning every-command off restores the prior value.
    @State private var priorRequireConfirmationForDangerous = true
    @State private var detectedClaudePath: String?
    private let locator = ClaudeExecutableLocator()
    @FocusState private var isAuthWordsFocused: Bool
    @FocusState private var isJiraURLFocused: Bool
    @FocusState private var isMergeRequestsURLFocused: Bool
    @FocusState private var isGitLabReviewsURLFocused: Bool
    @FocusState private var isGitLabMyMRsURLFocused: Bool
    @State private var importExportMessage: String?
    @State private var importExportSucceeded = false
    @State private var showImportExportAlert = false

    var body: some View {
        ZStack {
            Form {
                generalSection
                claudeSection
                terminalSection
                urlsSection
                popupsSection
                permissionsSection
                soundFeedbackSection
                commandsSection
                fuzzyMatchingSection
                securitySection
                appearanceSection

                updatesSection

                #if DEBUG
                debugSection
                #endif
            }
            .formStyle(.grouped)
            .allowsHitTesting(!showHotkeyRecorder && !showAvailableCommands && !showImportExportAlert)

            if showAvailableCommands {
                availableCommandsOverlay
            }

            if showHotkeyRecorder {
                hotkeyRecorderOverlay
            }

            if showImportExportAlert {
                importExportOverlay
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            detectedClaudePath = locator.locate()
        }
        .sheet(isPresented: $showPermissions) {
            PermissionsView(onDismiss: { showPermissions = false })
                .frame(minWidth: 520, maxWidth: 520, minHeight: 400, maxHeight: 700)
        }
    }

    // MARK: - Available Commands Overlay

    private var availableCommandsOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showAvailableCommands = false
                    }
                }

            AvailableCommandsView(onClose: {
                withAnimation(.easeOut(duration: 0.2)) {
                    showAvailableCommands = false
                }
            })
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    // MARK: - Hotkey Recorder Overlay

    private var hotkeyRecorderOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showHotkeyRecorder = false
                    }
                }

            HotkeyRecorderView(
                onSave: { keyCode, modifiers in
                    GlobalHotkeyManager.shared.update(keyCode: keyCode, modifiers: modifiers)
                    withAnimation(.easeOut(duration: 0.2)) {
                        showHotkeyRecorder = false
                    }
                },
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showHotkeyRecorder = false
                    }
                }
            )
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    // MARK: - Import/Export Overlay

    private var importExportOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showImportExportAlert = false
                    }
                }

            VStack(spacing: 16) {
                Image(systemName: importExportSucceeded ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(importExportSucceeded ? Color.accentColor : .red)

                Text(importExportMessage ?? "")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                CapsuleButton("OK") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showImportExportAlert = false
                    }
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 32)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .themedToggleStyle()

            Toggle("Listen on startup", isOn: $listenOnStartup)
                .themedToggleStyle()

            HStack {
                Text("Sleep After")

                Button {
                    infoManager.present(.sleepAfter)
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
                Picker("", selection: $sleepAfterInterval) {
                    Text("Never").tag(AppSettings.SleepInterval.never.rawValue)
                    Divider()
                    ForEach(AppSettings.SleepInterval.allCases.filter { $0 != .never }) { interval in
                        Text(interval.displayName).tag(interval.rawValue)
                    }
                }
                .frame(width: 120)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Global Hotkey")
                    Spacer()
                    Text(GlobalHotkeyManager.shared.displayString)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text("Press twice to also show Commands")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showHotkeyRecorder = true
                }
            }
        }
    }

    // MARK: - Claude Executable

    private var claudeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Claude Executable")

                    Spacer()

                    Button("Reset to Automatic") {
                        locator.storeOverride(nil)
                        detectedClaudePath = locator.locate()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("Settings.Claude.ResetButton")
                    .disabled(locator.storedOverride == nil)

                    Button("Choose…") { chooseClaudeExecutable() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("Settings.Claude.ChooseButton")
                }

                Text(detectedClaudePath ?? "Not found — install Claude Code or choose its executable.")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(detectedClaudePath == nil ? Color.orange : .secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("Settings.Claude.PathText")
            }

            Divider()

            sessionFolderRow
        } header: {
            Text("Claude")
        }
    }

    /// The single Session Folder every Claude session starts in. Replaces
    /// the deleted multi-workspace management.
    private var sessionFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Session Folder")

                Spacer()

                if workspaceStore.defaultFolderPath.isEmpty {
                    Text("Not set — sessions cannot start")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button("Choose…") { chooseSessionFolder() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("Settings.Claude.SessionFolderChoose")

                if !workspaceStore.defaultFolderPath.isEmpty {
                    Button("Clear") { workspaceStore.setDefaultFolderPath(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("Settings.Claude.SessionFolderClear")
                }
            }

            Text(workspaceStore.defaultFolderPath.isEmpty
                 ? "Every Claude session starts in this folder."
                 : workspaceStore.defaultFolderPath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(
                    workspaceStore.defaultFolderPath.isEmpty ? .secondary
                    : (workspaceStore.defaultFolder == nil ? Color.orange : .secondary)
                )
                .textSelection(.enabled)
                .accessibilityIdentifier("Settings.Claude.SessionFolderPath")
        }
    }

    private func chooseSessionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            workspaceStore.setDefaultFolderPath(url.standardizedFileURL.path)
        }
    }

    private func chooseClaudeExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())

        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.path
            guard locator.isValidExecutable(path) else { return }
            locator.storeOverride(path)
            detectedClaudePath = path
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Default Terminal Folder")

                    Spacer()

                    Button("Choose…") { chooseTerminalFolder() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("Settings.Terminal.ChooseButton")
                }

                TextField(
                    "",
                    text: $defaultTerminalFolder,
                    prompt: Text(AppSettings.defaultTerminalFolderDefault)
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                )
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("Settings.Terminal.FolderField")
            }
        } header: {
            Text("Terminal")
        } footer: {
            Text("New Terminal sessions start in this folder. \"~\" means your home directory.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseTerminalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(
            fileURLWithPath: AppSettings.resolvedTerminalStartDirectory(from: defaultTerminalFolder)
        )

        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            defaultTerminalFolder = url.path
        }
    }

    // MARK: - URL's

    private var urlsSection: some View {
        Section("URL's") {
            defaultURLField(
                title: "Web View JIRA URL",
                prompt: "https://your-domain.atlassian.net",
                caption: "The JIRA sidebar WebView opens this URL",
                text: $webViewJiraURL,
                isFocused: $isJiraURLFocused,
                accessibilityIdentifier: "WebViewJiraURLField"
            )

            defaultURLField(
                title: "Web View Merge Requests URL",
                prompt: "https://gitlab.com/dashboard/merge_requests",
                caption: "The Merge Requests sidebar WebView opens this URL",
                text: $webViewMergeRequestsURL,
                isFocused: $isMergeRequestsURLFocused,
                accessibilityIdentifier: "WebViewMergeRequestsURLField"
            )

            defaultURLField(
                title: "Web View GitLab Reviews URL",
                prompt: "https://gitlab.com/dashboard/merge_requests",
                caption: "Exact GitLab list of merge requests awaiting your review (Home MRs to Review panel)",
                text: $webViewGitLabReviewsURL,
                isFocused: $isGitLabReviewsURLFocused,
                accessibilityIdentifier: "WebViewGitLabReviewsURLField"
            )

            defaultURLField(
                title: "Web View GitLab My MRs URL",
                prompt: "https://gitlab.com/dashboard/merge_requests?state=opened",
                caption: "Exact GitLab list of merge requests you authored",
                text: $webViewGitLabMyMergeRequestsURL,
                isFocused: $isGitLabMyMRsURLFocused,
                accessibilityIdentifier: "WebViewGitLabMyMRsURLField"
            )
        }
    }

    private func defaultURLField(
        title: String,
        prompt: String,
        caption: String,
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 20) {
                Text(title)

                TextField(
                    "",
                    text: text,
                    prompt: Text(prompt)
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isFocused.wrappedValue ? Color.white : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .foregroundStyle(isFocused.wrappedValue ? Color.primary : Color.secondary)
                    .tint(Color.secondary)
                    .focused(isFocused)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }

            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pop-ups

    private var popupsSection: some View {
        Section("Pop-ups") {
            Toggle("Show confirmation pop-up for commands", isOn: $showCommandPopups)
                .themedToggleStyle()

            Toggle("Show warning pop-up for errors", isOn: $showErrorPopups)
                .themedToggleStyle()

            HStack {
                Text("Pop-up Duration")
                Spacer()
                Picker("", selection: $popupDurationSeconds) {
                    ForEach(1...30, id: \.self) { seconds in
                        Text("\(seconds)s").tag(seconds)
                    }
                }
                .frame(width: 80)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            HStack {
                Text("Show Permissions")
                Spacer()
                if let observer = permissionObserver {
                    Text("\(observer.viewModel.grantedCount) of \(observer.viewModel.totalCount) granted")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                showPermissions = true
            }
        }
    }

    // MARK: - Commands

    private var commandsSection: some View {
        Section("Built-in Commands") {
            HStack {
                Label("View Built-in Commands for Installed Apps", systemImage: "list.bullet.rectangle")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAvailableCommands = true
                }
            }
        }
    }

    // MARK: - Fuzzy Command Matching

    private var fuzzyMatchingSection: some View {
        Section("Fuzzy Command Matching") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Matching Confidence")
                        .font(.subheadline.weight(.medium))

                    Button {
                        infoManager.present(.confidenceLevel)
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(AppSettings.ConfidenceLevel.allCases) { level in
                    HStack(spacing: 8) {
                        Image(systemName: confidenceLevel == level.rawValue ? "circle.inset.filled" : "circle")
                            .foregroundStyle(confidenceLevel == level.rawValue ? Color.accentColor : .secondary)
                            .font(.system(size: 14))

                        Text(level.label)
                            .font(.subheadline)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        confidenceLevel = level.rawValue
                    }
                }
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Require authorization for every command", isOn: $requireAuthorizationForAllCommands)
                    .themedToggleStyle()
                    .onChange(of: requireAuthorizationForAllCommands) { _, newValue in
                        if newValue {
                            priorRequireConfirmationForDangerous = requireConfirmationForDangerous
                            requireConfirmationForDangerous = false
                        } else {
                            requireConfirmationForDangerous = priorRequireConfirmationForDangerous
                        }
                    }
                Text("Every voice command will require explicit approval before execution")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Require confirmation for sensitive commands", isOn: $requireConfirmationForDangerous)
                    .themedToggleStyle()
                    .disabled(requireAuthorizationForAllCommands)
                    .foregroundStyle(requireAuthorizationForAllCommands ? .secondary : .primary)

                Text("Only commands that delete data or make system changes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if requireConfirmationForDangerous || requireAuthorizationForAllCommands {
                Toggle("Accept voice authorizations", isOn: $voiceOnlyAuthorization)
                    .themedToggleStyle()

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 20) {
                        Text("Authorization words")
                            .foregroundStyle(.primary)

                        TextField("", text: $customAuthorizationWords)
                            .textFieldStyle(.plain)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isAuthWordsFocused ? Color.white : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .foregroundStyle(isAuthWordsFocused ? .black : .gray)
                            .focused($isAuthWordsFocused)
                            .frame(maxWidth: .infinity)
                            .onChange(of: customAuthorizationWords) { _, newValue in
                                let sanitized = InputSanitizer.authorizationWords(newValue)
                                if sanitized != newValue { customAuthorizationWords = sanitized }
                            }
                    }

                    HStack {
                        Spacer()
                        Text("Say any of these words to authorize a command (comma-separated)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                dangerousCommandTypes

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Authorization timeout")
                        Spacer()
                        Text("\(authorizationTimeoutSeconds)s")
                            .foregroundStyle(.secondary)
                        Stepper("", value: $authorizationTimeoutSeconds, in: 5...30)
                            .labelsHidden()
                            .fixedSize()
                    }
                    Text("How long the authorization prompt stays before auto-cancelling")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Command Authorization")
            }
        } footer: {
            if requireConfirmationForDangerous || requireAuthorizationForAllCommands {
                Text("When enabled, commands will require you to say an authorization word or click the Proceed button before they execute.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dangerousCommandTypes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Commands requiring authorization")
            }
            .font(.subheadline)
            .padding(.bottom, 4)

            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ], spacing: 6) {
                Label("File deletion", systemImage: "trash")
                Label("Data modification", systemImage: "pencil.line")
                Label("Network operations", systemImage: "globe")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sound Feedback

    private var soundFeedbackSection: some View {
        Section {
            Toggle("Enable sound cues", isOn: $soundFeedbackEnabled)
                .themedToggleStyle()

            if soundFeedbackEnabled {
                triggerRecognizedPicker
                    .padding(.leading, 16)
                commandRecognizedPicker
                    .padding(.leading, 16)
                commandNotRecognizedPicker
                    .padding(.leading, 16)
                volumePicker
                    .padding(.leading, 16)
            }
        } header: {
            Text("Sound Feedback")
        } footer: {
            Text("Choose which sound plays when a trigger word is detected, a command is recognized, or a command is not recognized.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var triggerRecognizedPicker: some View {
        Picker(selection: $cueTriggerRecognized) {
            ForEach(AppSettings.CueSound.allCases) { sound in
                Text(sound.displayName).tag(sound.rawValue)
            }
        } label: {
            Label("Trigger recognized", systemImage: "waveform")
        }
        .onChange(of: cueTriggerRecognized) { _, newValue in
            if let sound = AppSettings.CueSound(rawValue: newValue) {
                SoundFeedbackService.shared.previewCue(sound)
            }
        }
    }

    private var commandRecognizedPicker: some View {
        Picker(selection: $cueCommandRecognized) {
            ForEach(AppSettings.CueSound.allCases) { sound in
                Text(sound.displayName).tag(sound.rawValue)
            }
        } label: {
            Label("Command recognized", systemImage: "waveform")
        }
        .onChange(of: cueCommandRecognized) { _, newValue in
            if let sound = AppSettings.CueSound(rawValue: newValue) {
                SoundFeedbackService.shared.previewCue(sound)
            }
        }
    }

    private var commandNotRecognizedPicker: some View {
        Picker(selection: $cueCommandNotRecognized) {
            ForEach(AppSettings.CueSound.allCases) { sound in
                Text(sound.displayName).tag(sound.rawValue)
            }
        } label: {
            Label("Command not recognized", systemImage: "waveform")
        }
        .onChange(of: cueCommandNotRecognized) { _, newValue in
            if let sound = AppSettings.CueSound(rawValue: newValue) {
                SoundFeedbackService.shared.previewCue(sound)
            }
        }
    }

    private var volumePicker: some View {
        HStack {
            Text("Feedback Volume")
            Slider(value: $feedbackSoundVolume, in: 0...1.0)
            Text("\(Int(feedbackSoundVolume * 100))%")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    // TODO: Re-enable note formatting toggle in the General section when AI-powered note formatting is ready
    // private var noteFormattingToggle: some View {
    //     VStack(alignment: .leading, spacing: 4) {
    //         Toggle("Enable Note Formatting", isOn: $noteFormattingEnabled)
    //             .themedToggleStyle()
    //             .disabled(selectedAIProvider == AIProvider.none.rawValue)
    //
    //         Text("Saying \"format\" during a note session sends your text to the selected provider for cleanup. This uses API tokens.")
    //             .font(.subheadline)
    //             .foregroundStyle(.secondary)
    //
    //         if selectedAIProvider == AIProvider.none.rawValue && noteFormattingEnabled {
    //             Text("Configure an AI provider in AI Provider to use formatting.")
    //                 .font(.subheadline)
    //                 .foregroundStyle(Color.accentColor)
    //         }
    //     }
    // }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            @Bindable var tm = themeManager
            Picker("Theme", selection: $tm.currentTheme) {
                Text("System Default").tag(AppSettings.AppTheme.systemDefault)
                Text("Light").tag(AppSettings.AppTheme.systemLight)
                Text("Dark").tag(AppSettings.AppTheme.systemDark)
            }
        }
    }

    // MARK: - Debug

    #if DEBUG
    private var debugSection: some View {
        Section {
            Toggle("Enable command execution logging", isOn: $enableCommandLogging)
                .themedToggleStyle()

            if enableCommandLogging {
                HStack {
                    Text("Open Logs Folder")

                    Spacer()

                    logsStats

                    Button("Delete logs") {
                        CommandLogFileManager.shared.deleteAllLogs()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: CommandLogFileManager.shared.logsDirectory.path
                    )
                }
            }

            HStack {
                Text("Developer Commands")
                Spacer()
                Button("Open Folder") {
                    let url = CommandExporter.developerCommandsFile.deletingLastPathComponent()
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: url.path) {
                        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
                    }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Divider()
                    .frame(height: 16)

                Button("Import") {
                    do {
                        let count = try CommandImporter.importAllFromFile(into: modelContext)
                        importExportMessage = "Import complete. \(count) command\(count == 1 ? "" : "s") imported."
                        importExportSucceeded = true
                        withAnimation(.easeOut(duration: 0.2)) { showImportExportAlert = true }
                    } catch {
                        importExportMessage = "Import failed: \(error.localizedDescription)"
                        importExportSucceeded = false
                        withAnimation(.easeOut(duration: 0.2)) { showImportExportAlert = true }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Divider()
                    .frame(height: 16)

                Button("Export") {
                    let descriptor = FetchDescriptor<Command>()
                    guard let commands = try? modelContext.fetch(descriptor) else { return }
                    do {
                        let count = try CommandExporter.exportAllToFile(commands)
                        importExportMessage = "Export complete. \(count) command\(count == 1 ? "" : "s") exported."
                        importExportSucceeded = true
                        withAnimation(.easeOut(duration: 0.2)) { showImportExportAlert = true }
                    } catch {
                        importExportMessage = "Export failed: \(error.localizedDescription)"
                        importExportSucceeded = false
                        withAnimation(.easeOut(duration: 0.2)) { showImportExportAlert = true }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Records voice commands and execution results for troubleshooting.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 50)
        }
    }

    private var logsStats: some View {
        let logManager = CommandLogFileManager.shared
        let fileCount = logManager.getAllLogFiles().count
        let totalBytes = logManager.totalLogsSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeString = formatter.string(fromByteCount: totalBytes)

        return Text("\(fileCount) file\(fileCount == 1 ? "" : "s") · \(sizeString)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
    #endif

    // MARK: - Direct Release Sections

    private var updatesSection: some View {
        Section {
            if let appVersion {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("Updates.VersionText")
            }

            HStack(spacing: 12) {
                Text(updatesStatusText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("Updates.StatusText")

                Spacer()

                if updateManager.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("Updates.ProgressSpinner")
                }

                if updateManager.canRetryPreparation {
                    Button("Update") {
                        updateManager.prepareOfferedUpdate()
                    }
                    .accessibilityIdentifier("Updates.UpdateButton")
                }

                Button("Check for Updates") {
                    updateManager.checkForUpdates()
                }
                .disabled(updateManager.isBusy)
                .accessibilityIdentifier("Updates.CheckButton")
            }

            if let errorMessage = updateManager.errorMessage, updateManager.phase == .failed {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("Updates.ErrorText")
            }

            if updateManager.phase == .prepared, let source = updateManager.preparedSource {
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.directoryPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("Updates.PreparedSourceText")

                    HStack(spacing: 8) {
                        if let projectPath = source.xcodeProjectPath {
                            Button("Open in Xcode") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: projectPath))
                            }
                        }
                        Text("Then build the Release configuration yourself — Console does not install anything.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Checks public GitHub Releases of ChristopherLarsen/Console. A qualifying release downloads its source to ~/Developer/ConsoleUpdates for a manual Release build in Xcode.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var updatesStatusText: String {
        switch updateManager.phase {
        case .idle:
            return "Not checked yet"
        case .checking:
            return "Checking…"
        case .current:
            return "You're up to date"
        case .available:
            if let release = updateManager.offeredRelease,
               let version = release.semanticVersion {
                return "Version \(version.displayString) is available"
            }
            return "An update is available"
        case .preparing:
            return "Downloading source…"
        case .prepared:
            return "Source downloaded"
        case .failed:
            return "Update failed"
        }
    }

    private var appVersion: String? { BuildConfiguration.versionDisplay }

}
