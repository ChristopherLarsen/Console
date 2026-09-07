import SwiftUI
import AppKit

enum ModelFetchStatus: Equatable {
    case idle
    case fetching
    case success
    case failed(String)

    static func == (lhs: ModelFetchStatus, rhs: ModelFetchStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.fetching, .fetching), (.success, .success): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

enum ModelSource {
    case picker
    case custom
}

struct AIProviderConfigSection: View {
    let provider: AIProvider
    var aiProviderManager: AIProviderManager
    var showEndpointField: Bool = true
    var showHelpText: Bool = true
    var showAPIKeyLabel: Bool = false
    var alwaysShowConnectionRow: Bool = false
    var autoFocusAPIKey: Bool = false
    var onTestSuccess: (() -> Void)?
    @Environment(InfoManager.self) private var infoManager

    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var endpointURL: String = ""
    @State private var testResult: AIProviderManager.ConnectionTestResult = .idle

    @State private var availableModels: [AvailableModel] = []
    @State private var modelFetchStatus: ModelFetchStatus = .idle
    @State private var showCustomModelField: Bool = false
    @State private var selectedModelSource: ModelSource = .picker
    @State private var keychainSaveError: String?
    @FocusState private var isAPIKeyFocused: Bool
    @FocusState private var isEndpointFocused: Bool
    @State private var focusModelPicker = false
    @State private var lastSavedAPIKey: String = ""
    @State private var hasEnteredAPIKey: Bool = false
    @State private var apiKeySaveTask: Task<Void, Never>?
    @AppStorage("hasGrantedKeychainAccess") private var hasGrantedKeychainAccess = false

    var body: some View {
        configFields
            .onAppear { loadConfig() }
            .onChange(of: provider) { _, _ in
                loadConfig()
                testResult = .idle
                showCustomModelField = false
                availableModels = []
                modelFetchStatus = .idle
            }
            .onChange(of: hasGrantedKeychainAccess) { _, granted in
                // Save deferred API key after user confirms Keychain popup
                if granted { saveAPIKeyIfNeeded() }
            }
            .alert("Keychain Error", isPresented: Binding(
                get: { keychainSaveError != nil },
                set: { if !$0 { keychainSaveError = nil } }
            )) {
                Button("OK", role: .cancel) { keychainSaveError = nil }
            } message: {
                if let error = keychainSaveError {
                    Text(error)
                }
            }
    }

    // MARK: - Config Fields (Wizard Flow)

    private var unlocksAdvancedFields: Bool {
        !provider.requiresAPIKey || !apiKey.isEmpty || hasEnteredAPIKey
    }

    private var configFields: some View {
        Group {
            if showHelpText {
                helpText
            }

            if provider.requiresAPIKey || showAPIKeyLabel {
                apiKeySection
            }

            if unlocksAdvancedFields {
                ModelSelectionView(
                    selectedModel: $modelName,
                    showCustomField: $showCustomModelField,
                    provider: provider,
                    availableModels: availableModels,
                    fetchStatus: modelFetchStatus,
                    autoFocusPicker: $focusModelPicker,
                    onRefresh: {
                        Task {
                            ModelCacheManager.shared.invalidateCache(for: provider)
                            if provider == .lmStudio {
                                // Retry doubles as the reconnect attempt: ping
                                // the server, mirror the outcome in the status
                                // row, and only search models if it connected.
                                let result = await aiProviderManager.testConnection(for: provider)
                                testResult = result
                                let state = Self.refreshStateAfterReconnect(
                                    connectionResult: result,
                                    previousModels: availableModels
                                )
                                guard state.shouldFetch else {
                                    availableModels = state.models
                                    modelFetchStatus = state.status
                                    return
                                }
                            }
                            await fetchAvailableModels()
                        }
                    }
                )
                .onChange(of: modelName) { _, _ in saveConfigValues() }

                if showEndpointField {
                    HStack(spacing: 6) {
                        Text("Endpoint URL")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        Button {
                            infoManager.present(.endpointURL)
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        TextField(
                            "",
                            text: $endpointURL,
                            prompt: Text(provider == .lmStudio ? LMStudioAPI.defaultOrigin : "Endpoint URL")
                        )
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isEndpointFocused ? Color.white : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .foregroundStyle(isEndpointFocused ? .black : .gray)
                            .focused($isEndpointFocused)
                            .onChange(of: endpointURL) { _, newValue in
                                let sanitized = InputSanitizer.endpointURL(newValue)
                                if sanitized != newValue { endpointURL = sanitized }
                                saveConfigValues()
                            }
                    }
                }
            }

            if alwaysShowConnectionRow || unlocksAdvancedFields {
                connectionRow
            }
        }
    }

    // MARK: - Help Text

    private var helpText: some View {
        Group {
            if provider == .lmStudio {
                Text("Start the LM Studio local server (Developer tab or lms server start), then pick a downloaded model.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("The AI provider is used to generate command actions from natural language. We recommend using the most capable model as they are better able to reliably generate commands.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showAPIKeyLabel {
                Text("API Key")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .focused($isAPIKeyFocused)
                .accessibilityIdentifier("API Key")
                .onAppear {
                    if autoFocusAPIKey {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            isAPIKeyFocused = true
                        }
                    }
                }
                .onSubmit {
                    if !apiKey.isEmpty { focusModelPicker = true }
                }
                .onChange(of: apiKey) { _, newValue in
                    if !newValue.isEmpty { hasEnteredAPIKey = true }
                    saveConfigValues()
                    Task { await fetchAvailableModels() }
                }
        }
    }

    // MARK: - Connection Status + Test

    private var connectionRow: some View {
        HStack(spacing: 8) {
            Text("Connection Status")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            if testResult != .idle {
                Text(statusValueText)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier(statusValueText)
            }

            if testResult == .testing {
                ProgressView().controlSize(.small)
            }

            Spacer()

            CapsuleButton(
                "Test Connection",
                systemImage: "bolt.fill",
                style: .primary,
                isDisabled: testResult == .testing || (provider.requiresAPIKey && apiKey.isEmpty)
            ) {
                testConnection()
            }
            .accessibilityIdentifier("Test Connection")
            .controlSize(.small)
        }
    }

    private var statusValueText: String {
        switch testResult {
        case .idle:
            return ""
        case .testing:
            return "Testing"
        case .success:
            return "Connected ✓"
        case .invalidKey, .rateLimited, .networkError, .error:
            return "Connection Failed"
        }
    }

    private var statusColor: Color {
        switch testResult {
        case .success: return Color(red: 0.2, green: 0.65, blue: 0.3)
        case .testing, .idle: return .secondary
        case .invalidKey, .rateLimited, .networkError, .error: return .red
        }
    }

    // MARK: - Data

    private func loadConfig() {
        let cfg = aiProviderManager.config(for: provider)
        endpointURL = cfg.endpointURL
        modelName = cfg.modelName
        if provider == .lmStudio {
            saveConfigValues()
        }
        Task {
            let result = await loadKeyWithRetry(for: provider)
            switch result {
            case .success(let loaded):
                apiKey = loaded ?? ""
                lastSavedAPIKey = apiKey
                if !apiKey.isEmpty || !provider.requiresAPIKey {
                    hasEnteredAPIKey = true
                    if modelName.isEmpty {
                        modelName = cfg.modelName
                    }
                }
            case .failure:
                apiKey = ""
                lastSavedAPIKey = ""
                if !provider.requiresAPIKey {
                    hasEnteredAPIKey = true
                }
            }
            if unlocksAdvancedFields {
                await fetchAvailableModels()
            }
        }
    }

    // Retries Keychain read on transient permission errors
    private func loadKeyWithRetry(for provider: AIProvider, maxAttempts: Int = 3) async -> Result<String?, KeychainManager.KeychainError> {
        for attempt in 1...maxAttempts {
            let result = await aiProviderManager.loadAPIKeyFromKeychain(for: provider)
            if case .failure(let error) = result {
                let isRetryable = {
                    switch error {
                    case .permissionDenied, .interactionNotAllowed: return true
                    default: return false
                    }
                }()
                if isRetryable && attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
            }
            return result
        }
        return .failure(.unexpectedError(-1))
    }

    private func testConnection() {
        testResult = .testing
        Task {
            saveConfigValues()
            // An un-awaited Keychain save from saveConfigValues must land
            // before the test reads the key back from the Keychain.
            await apiKeySaveTask?.value
            let result = await aiProviderManager.testConnection(for: provider)
            testResult = result
            if result.isSuccess {
                ModelCacheManager.shared.invalidateCache(for: provider)
                await fetchAvailableModels()
                onTestSuccess?()
            } else {
                printDebug("[Console] Connection test result: \(result.label)")
            }
        }
    }

    private func saveConfigValues() {
        let resolvedEndpoint = provider == .lmStudio
            ? LMStudioAPI.origin(from: endpointURL)
            : endpointURL
        if resolvedEndpoint != endpointURL {
            endpointURL = resolvedEndpoint
        }
        let cfg = AIProviderConfig(
            provider: provider,
            endpointURL: resolvedEndpoint,
            apiKeyKeychainRef: "ai-provider-\(provider.rawValue)",
            modelName: modelName
        )
        aiProviderManager.saveConfig(cfg)
        saveAPIKeyIfNeeded()
    }

    /// Saves the API key to Keychain only if permission is available and
    /// the key hasn't already been saved (dedup guard).
    private func saveAPIKeyIfNeeded() {
        guard !apiKey.isEmpty, apiKey != lastSavedAPIKey else { return }
        guard hasGrantedKeychainAccess || KeychainManager.checkKeychainAccessStatus() else { return }

        let keyToSave = apiKey
        lastSavedAPIKey = keyToSave
        apiKeySaveTask = Task {
            let result = await aiProviderManager.saveAPIKeyToKeychain(keyToSave, for: provider)
            if case .failure(let error) = result {
                lastSavedAPIKey = ""
                keychainSaveError = error.userMessage
            }
        }
    }

    private func fetchAvailableModels() async {
        let config = aiProviderManager.config(for: provider)
        let effectiveKey = aiProviderManager.effectiveAPIKey(stored: apiKey.isEmpty ? nil : apiKey, for: provider)

        // Return cached models if available
        if let cached = ModelCacheManager.shared.getCachedModels(
            for: provider,
            endpointURL: config.endpointURL,
            apiKey: effectiveKey
        ) {
            availableModels = cached
            modelFetchStatus = .success
            return
        }

        modelFetchStatus = .fetching

        guard let fetcher = ModelFetcherFactory.makeFetcher(
            provider: provider,
            apiKey: effectiveKey,
            config: config
        ) else {
            modelFetchStatus = .failed("Provider not supported")
            return
        }

        // Retry up to 2 times with exponential backoff (skip when the host is down)
        let maxRetries = 2
        for attempt in 0...maxRetries {
            do {
                let models = try await fetcher.fetchAvailableModels()
                ModelCacheManager.shared.cacheModels(
                    models,
                    for: provider,
                    endpointURL: config.endpointURL,
                    apiKey: effectiveKey
                )
                availableModels = models
                modelFetchStatus = .success
                return
            } catch let error as ModelFetchError {
                if case .serverUnreachable = error {
                    modelFetchStatus = .failed(error.localizedDescription)
                    return
                }
                if isAuthError(error) {
                    modelFetchStatus = .failed(error.localizedDescription)
                    return
                }
                if attempt < maxRetries {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                    continue
                }
                modelFetchStatus = .failed(error.localizedDescription)
            } catch {
                modelFetchStatus = .failed(error.localizedDescription)
                return
            }
        }
    }

    private func isAuthError(_ error: ModelFetchError) -> Bool {
        if case .unauthorized = error { return true }
        return false
    }

    /// Refresh outcome after the LM Studio reconnect ping. A failed reconnect
    /// must not leave the stale model list behind with a success fetch status.
    static func refreshStateAfterReconnect(
        connectionResult: AIProviderManager.ConnectionTestResult,
        previousModels: [AvailableModel]
    ) -> (models: [AvailableModel], status: ModelFetchStatus, shouldFetch: Bool) {
        guard connectionResult.isSuccess else {
            return (
                [],
                .failed("Could not connect to LM Studio — start the local server and try Refresh again."),
                false
            )
        }
        return (previousModels, .success, true)
    }

}
