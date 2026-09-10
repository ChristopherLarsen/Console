import SwiftUI
import SwiftData

/// Voice-command feature configuration, rendered as the third segment of the
/// Commands hub. Holds every setting that governs listening, matching,
/// execution feedback, and authorization for voice commands.
struct CommandConfigView: View {
    @Environment(InfoManager.self) private var infoManager
    @Environment(PermissionBackgroundObserver.self) private var permissionObserver: PermissionBackgroundObserver?

    @AppStorage("listenOnStartup") private var listenOnStartup: Bool = true
    @AppStorage("soundFeedbackEnabled") private var soundFeedbackEnabled: Bool = true

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
    @AppStorage("showCommandPopups") private var showCommandPopups: Bool = false
    @AppStorage("showErrorPopups") private var showErrorPopups: Bool = false
    @AppStorage("popupDurationSeconds") private var popupDurationSeconds: Int = 3
    @AppStorage("sleepAfterInterval") private var sleepAfterInterval: String = AppSettings.SleepInterval.thirtyMinutes.rawValue

    @State private var showHotkeyRecorder = false
    @State private var showPermissions = false
    @State private var showAvailableCommands = false
    /// Sensitive-confirmation preference before "every command" cleared it, so
    /// turning every-command off restores the prior value.
    @State private var priorRequireConfirmationForDangerous = true
    @FocusState private var isAuthWordsFocused: Bool

    var body: some View {
        ZStack {
            Form {
                voiceGeneralSection
                popupsSection
                permissionsSection
                soundFeedbackSection
                commandsSection
                fuzzyMatchingSection
                securitySection
            }
            .formStyle(.grouped)
            .allowsHitTesting(!showHotkeyRecorder && !showAvailableCommands)

            if showAvailableCommands {
                availableCommandsOverlay
            }

            if showHotkeyRecorder {
                hotkeyRecorderOverlay
            }
        }
        .sheet(isPresented: $showPermissions) {
            PermissionsView(onDismiss: { showPermissions = false })
                .frame(minWidth: 520, maxWidth: 520, minHeight: 400, maxHeight: 700)
        }
    }

    // MARK: - Listening

    private var voiceGeneralSection: some View {
        Section("Listening") {
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

    // MARK: - Built-in Commands

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

    // MARK: - Command Authorization

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
}

#Preview {
    CommandConfigView()
        .environment(InfoManager())
        .environment(PermissionBackgroundObserver())
}
