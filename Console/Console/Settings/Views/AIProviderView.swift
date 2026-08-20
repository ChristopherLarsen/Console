import SwiftUI

/// Dedicated main-view for choosing and configuring the LLM provider.
struct AIProviderView: View {
    @Environment(AIProviderManager.self) private var aiProviderManager
    @AppStorage("selectedAIProvider") private var selectedAIProvider: String = AIProvider.none.rawValue
    @AppStorage("hasGrantedKeychainAccess") private var hasGrantedKeychainAccess = false
    @State private var showKeychainAccessPopup = false

    var body: some View {
        ZStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("LLM Provider", selection: $selectedAIProvider) {
                                Text("Select Provider").tag(AIProvider.none.rawValue)
                                Divider()
                                ForEach(AIProvider.allCases.filter { $0 != .none }) { provider in
                                    Text(provider.displayName)
                                        .tag(provider.rawValue)
                                        .accessibilityIdentifier(provider.displayName)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("LLM Provider")
                            .onChange(of: selectedAIProvider) { _, newValue in
                                if let provider = AIProvider(rawValue: newValue) {
                                    aiProviderManager.selectedProvider = provider
                                }
                            }

                            if selectedAIProvider == AIProvider.none.rawValue {
                                noProviderFallback
                            }
                        }

                        if selectedAIProvider != AIProvider.none.rawValue,
                           let provider = AIProvider(rawValue: selectedAIProvider) {
                            Divider()

                            AIProviderConfigSection(
                                provider: provider,
                                aiProviderManager: aiProviderManager,
                                onTestSuccess: {
                                    guard provider.requiresAPIKey else { return }
                                    guard !hasGrantedKeychainAccess,
                                          !KeychainManager.checkKeychainAccessStatus() else { return }
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        showKeychainAccessPopup = true
                                    }
                                }
                            )
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Artificial Intelligence Provider")
                }
            }
            .formStyle(.grouped)
            .allowsHitTesting(!showKeychainAccessPopup)

            if showKeychainAccessPopup {
                keychainAccessOverlay
            }
        }
        .onAppear {
            // Keep AppStorage and manager in sync when opening this view.
            if let provider = AIProvider(rawValue: selectedAIProvider) {
                aiProviderManager.selectedProvider = provider
            }
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var noProviderFallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No AI provider configured")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("You can still use Console with the starter commands and any commands you create manually. An AI provider is only needed to generate new commands from natural language descriptions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var keychainAccessOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showKeychainAccessPopup = false
                    }
                }

            KeychainAccessPopup(
                onConfirm: {
                    hasGrantedKeychainAccess = true
                    showKeychainAccessPopup = false
                },
                onDismiss: {
                    showKeychainAccessPopup = false
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
    AIProviderView()
        .environment(AIProviderManager())
}
