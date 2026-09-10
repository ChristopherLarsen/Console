import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(ThemeManager.self) private var themeManager

    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""
    @AppStorage("webViewMergeRequestsURL") private var webViewMergeRequestsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabReviewsURLKey) private var webViewGitLabReviewsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabMyMergeRequestsURLKey) private var webViewGitLabMyMergeRequestsURL: String = ""
    @AppStorage(AppSettings.mrScanEnabledKey) private var mrScanEnabled: Bool = false
    @AppStorage(AppSettings.mrScanIntervalMinutesKey) private var mrScanIntervalMinutes: Int = AppSettings.mrScanIntervalMinutesDefault
    @AppStorage(AppSettings.mrScanModelKey) private var mrScanModel: String = AppSettings.mrScanModelDefault

    @AppStorage(AppSettings.aiProviderEnabledKey) private var aiProviderEnabled: Bool = false

    @AppStorage(AppSettings.defaultTerminalFolderKey) private var defaultTerminalFolder: String = AppSettings.defaultTerminalFolderDefault

    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @Environment(UpdateManager.self) private var updateManager
    @State private var detectedClaudePath: String?
    private let locator = ClaudeExecutableLocator()
    @FocusState private var isJiraURLFocused: Bool
    @FocusState private var isMergeRequestsURLFocused: Bool
    @FocusState private var isGitLabReviewsURLFocused: Bool
    @FocusState private var isGitLabMyMRsURLFocused: Bool
    @FocusState private var isMRScanModelFocused: Bool

    var body: some View {
        Form {
            generalSection
            claudeSection
            ManagedClaudeAccessSection()
            terminalSection
            urlsSection
            mrReviewScansSection
            appearanceSection

            updatesSection

            aiProviderSection
        }
        .formStyle(.grouped)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            detectedClaudePath = locator.locate()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .themedToggleStyle()
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
                title: "Jira URL",
                prompt: "https://your-domain.atlassian.net",
                caption: "The JIRA sidebar WebView opens this URL",
                text: $webViewJiraURL,
                isFocused: $isJiraURLFocused,
                accessibilityIdentifier: "WebViewJiraURLField"
            )

            defaultURLField(
                title: "GitLab URL",
                prompt: "https://gitlab.com/dashboard/merge_requests",
                caption: "The Merge Requests sidebar WebView opens this URL",
                text: $webViewMergeRequestsURL,
                isFocused: $isMergeRequestsURLFocused,
                accessibilityIdentifier: "WebViewMergeRequestsURLField"
            )

            defaultURLField(
                title: "GitLab Reviews URL",
                prompt: "https://gitlab.com/dashboard/merge_requests",
                caption: "All open MRs of your project — scanned for Home review cards and opened by the GitLab Reviews panel",
                text: $webViewGitLabReviewsURL,
                isFocused: $isGitLabReviewsURLFocused,
                accessibilityIdentifier: "WebViewGitLabReviewsURLField"
            )

            defaultURLField(
                title: "GitLab My MRs URL",
                prompt: "https://gitlab.com/dashboard/merge_requests?state=opened",
                caption: "Exact GitLab list of merge requests you authored",
                text: $webViewGitLabMyMergeRequestsURL,
                isFocused: $isGitLabMyMRsURLFocused,
                accessibilityIdentifier: "WebViewGitLabMyMRsURLField"
            )
        }
    }

    // MARK: - MR Review Scans

    private var mrReviewScansSection: some View {
        Section("MR Review Scans") {
            Toggle("Periodically scan for MR's to review", isOn: $mrScanEnabled)
                .themedToggleStyle()
                .accessibilityIdentifier("MRScanEnabledToggle")

            HStack {
                Text("Scan every")

                Spacer()

                Picker("", selection: $mrScanIntervalMinutes) {
                    ForEach(AppSettings.mrScanIntervalChoices, id: \.self) { minutes in
                        Text("Every \(minutes) min").tag(minutes)
                    }
                }
                .frame(width: 140)
                .disabled(!mrScanEnabled)
                .accessibilityIdentifier("MRScanIntervalPicker")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 20) {
                    Text("Claude model")

                    TextField(
                        "",
                        text: $mrScanModel,
                        prompt: Text(AppSettings.mrScanModelDefault)
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isMRScanModelFocused ? Color.white : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .focused($isMRScanModelFocused)
                    .frame(maxWidth: .infinity)
                    .disabled(!mrScanEnabled)
                    .accessibilityIdentifier("MRScanModelField")
                }

                HStack {
                    Spacer()
                    Text("Claude model that classifies scan results (any version; default haiku)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
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
            Text(title)

            TextField(
                "",
                text: text,
                prompt: Text(prompt)
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
            )
                .textFieldStyle(.plain)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isFocused.wrappedValue ? Color.white : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .foregroundStyle(text.wrappedValue.isEmpty ? Color(nsColor: .placeholderTextColor) : Color.primary)
                .tint(Color.primary)
                .focused(isFocused)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(accessibilityIdentifier)

            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

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

    // MARK: - AI Provider

    private var aiProviderSection: some View {
        Section("AI Provider") {
            Toggle("Enable AI provider", isOn: $aiProviderEnabled)
                .themedToggleStyle()
                .accessibilityIdentifier("AIProviderEnabledToggle")
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
