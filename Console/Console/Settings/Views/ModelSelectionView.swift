import SwiftUI

struct ModelSelectionView: View {
    @Binding var selectedModel: String
    @Binding var showCustomField: Bool
    let provider: AIProvider
    let availableModels: [AvailableModel]
    let fetchStatus: ModelFetchStatus
    @Binding var autoFocusPicker: Bool
    let onRefresh: () -> Void

    @State private var modelSelection: String = "__select__"
    @FocusState private var isPickerFocused: Bool
    @FocusState private var isModelNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelPicker
            Text("Better models may be more effective at creating complex commands")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            modelInfoRow
            customFieldOrSelection
            validationRow
            statusIndicator
        }
        .onAppear { syncSelectionState() }
        .onChange(of: selectedModel) { _, _ in syncSelectionState() }
        .onChange(of: fetchStatus) { _, _ in syncSelectionState() }
        .onChange(of: autoFocusPicker) { _, shouldFocus in
            if shouldFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isPickerFocused = true
                    autoFocusPicker = false
                }
            }
        }
    }

    // MARK: - Picker

    private var modelPicker: some View {
        Picker("Model", selection: $modelSelection) {
            Text("Choose a model").tag("__select__")

            if !availableModels.isEmpty {
                Divider()

                ForEach(availableModels) { model in
                    Text(model.displayName)
                        .tag(model.id)
                }
            }

            Divider()

            Text(customPickerTitle)
                .tag("__custom__")
                .accessibilityIdentifier("Enter model name")
        }
        .pickerStyle(.menu)
        .focused($isPickerFocused)
        .accessibilityIdentifier("Model")
        .contextMenu {
            Button("Refresh Models") {
                onRefresh()
            }
        }
        .onChange(of: modelSelection) { _, newValue in
            handleModelSelection(newValue)
        }
    }

    // MARK: - Model Info

    @ViewBuilder
    private var modelInfoRow: some View {
        if let info = ModelInfo.info(for: selectedModel) {
            Text(info.tooltip)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Custom Field / Selection Display

    @ViewBuilder
    private var customFieldOrSelection: some View {
        if showCustomField {
            TextField("Model name", text: $selectedModel)
                .textFieldStyle(.roundedBorder)
                .focused($isModelNameFocused)
                .accessibilityIdentifier("Model name")
                .help("Enter the exact model name from the provider's documentation")
                .onChange(of: selectedModel) { _, newValue in
                    let sanitized = InputSanitizer.modelName(newValue)
                    if sanitized != newValue { selectedModel = sanitized }
                }
        }
    }

    // MARK: - Validation

    @ViewBuilder
    private var validationRow: some View {
        if showCustomField && !selectedModel.isEmpty {
            let result = ModelValidator.validate(selectedModel, for: provider)
            if case .invalid(let msg) = result {
                Label(msg, systemImage: "xmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        if fetchStatus == .fetching {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching models...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if case .failed(let message) = fetchStatus {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                Text(message.isEmpty ? "Unable to fetch available models" : message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button("Retry", action: onRefresh)
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Selection Logic

    private var customPickerTitle: String {
        if showCustomField && !selectedModel.isEmpty {
            return selectedModel
        }
        return "Enter model name"
    }

    private func handleModelSelection(_ value: String) {
        switch value {
        case "__select__":
            showCustomField = false
            selectedModel = ""
        case "__custom__":
            showCustomField = true
        default:
            showCustomField = false
            selectedModel = value
        }
    }

    // Keeps the picker in sync when selectedModel is set externally
    private func syncSelectionState() {
        if !selectedModel.isEmpty {
            let isKnown = availableModels.contains { $0.id == selectedModel }
            if isKnown {
                modelSelection = selectedModel
                showCustomField = false
            } else {
                modelSelection = "__custom__"
                showCustomField = true
            }
        } else if showCustomField {
            modelSelection = "__custom__"
        } else {
            modelSelection = "__select__"
        }
    }
}
