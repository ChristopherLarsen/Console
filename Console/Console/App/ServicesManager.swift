import Foundation
import SwiftData

@Observable
@MainActor
final class ServicesManager {
    private(set) var isInitialized = false
    private(set) var initializationError: String?

    private var localCommandExecutor: LocalCommandExecutor?
    private var permissionObserver: PermissionBackgroundObserver?
    private var menuBarViewModel: MenuBarViewModel?
    private var wakeWordManager: WakeWordManager?
    private var modelContext: ModelContext?
    private var commandVocabularyObserver: NSObjectProtocol?

    func initialize(
        localCommandExecutor: LocalCommandExecutor,
        aiProviderManager: AIProviderManager,
        permissionObserver: PermissionBackgroundObserver,
        menuBarViewModel: MenuBarViewModel,
        wakeWordManager: WakeWordManager,
        modelContext: ModelContext,
        transcriptSource: TranscriptSource? = nil
    ) {
        guard !isInitialized else { return }

        self.localCommandExecutor = localCommandExecutor
        self.permissionObserver = permissionObserver
        self.menuBarViewModel = menuBarViewModel
        self.wakeWordManager = wakeWordManager
        self.modelContext = modelContext

        permissionObserver.startObserving()

        menuBarViewModel.modelContext = modelContext
        menuBarViewModel.wakeWordManager = wakeWordManager
        menuBarViewModel.setListeningServices(
            localCommandExecutor: localCommandExecutor,
            aiProviderManager: aiProviderManager,
            transcriptSource: transcriptSource
        )
        MenuBarManager.shared.setup(viewModel: menuBarViewModel)

        wakeWordManager.onVocabularyChanged = { [weak self] in
            self?.scheduleLanguageModelRebuild()
        }

        commandVocabularyObserver = NotificationCenter.default.addObserver(
            forName: .commandVocabularyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.scheduleLanguageModelRebuild()
            }
        }

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            AudioCueManager.shared.warmUp()
        }

        isInitialized = true
        initializationError = nil

        Task {
            await performInitialLanguageModelBuild()
        }
    }

    func shutdown() {
        MenuBarManager.shared.shutdown()
        permissionObserver?.stopObserving()
        if let observer = commandVocabularyObserver {
            NotificationCenter.default.removeObserver(observer)
            commandVocabularyObserver = nil
        }
    }

    // MARK: - Custom Language Model

    private func scheduleLanguageModelRebuild() {
        guard let builder = CustomLanguageModelBuilder.shared,
              let wakeWordManager,
              let modelContext else { return }

        let wakeWords = wakeWordManager.enabledWords
        let commands = (try? modelContext.fetch(FetchDescriptor<Command>())) ?? []
        builder.scheduleRebuild(wakeWords: wakeWords, commands: commands)
    }

    private func performInitialLanguageModelBuild() async {
        guard let builder = CustomLanguageModelBuilder.shared,
              let wakeWordManager,
              let modelContext else { return }

        let wakeWords = wakeWordManager.enabledWords
        let commands = (try? modelContext.fetch(FetchDescriptor<Command>())) ?? []
        await builder.rebuildIfNeeded(wakeWords: wakeWords, commands: commands)
    }
}
