import AppKit
import SwiftUI

@MainActor
final class NotePanelController {
    static let shared = NotePanelController()
    private var viewModel: NoteViewModel?
    private var dictationMode: (any ListeningMode)?
    private var aiProviderManager: AIProviderManager?
    private(set) var isDictationSuspended = false
    private(set) var isShowing = false
    var dismissAction: (() -> Void)?

    private init() {}

    func windowOpened(viewModel: NoteViewModel, aiProviderManager: AIProviderManager?) {
        self.viewModel = viewModel
        self.aiProviderManager = aiProviderManager
        self.isShowing = true

        if #available(macOS 26.0, *) {
            if let unwrappedProvider = aiProviderManager {
                let mode = NoteDictationMode(noteViewModel: viewModel, aiProviderManager: unwrappedProvider)
                self.dictationMode = mode
                Task {
                    await AudioSessionController.shared.requestMode(mode)
                }
            }
        }
    }

    func windowClosed() {
        cleanup()
    }

    func dismiss() {
        let action = dismissAction
        cleanup()
        action?()
    }

    private func cleanup() {
        guard isShowing else { return }
        isDictationSuspended = false
        viewModel?.isListeningPaused = false

        let activeMode = AudioSessionController.shared.activeMode
        let modeToRelease: (any ListeningMode)?
        if let activeMode, activeMode.modeIdentifier == "noteDictation" {
            modeToRelease = activeMode
        } else {
            modeToRelease = dictationMode
        }
        dictationMode = nil

        if let mode = modeToRelease {
            Task {
                // If this note mode is suspended behind another mode (e.g.
                // field dictation), drop it from the suspended stack so its
                // release cannot resurrect a dismissed panel.
                await AudioSessionController.shared.discardSuspendedMode(mode)
                await AudioSessionController.shared.releaseMode(mode)
                if AudioSessionController.shared.activeMode == nil,
                   let vm = MenuBarViewModel.shared,
                   vm.listeningState != .off {
                    vm.startListening()
                }
            }
        }

        NoteViewModel.shared = nil
        viewModel = nil
        aiProviderManager = nil
        isShowing = false
        dismissAction = nil
    }

    func bringToFront() {
        ConsoleWindowManager.bringToFront("note")
    }

    func setWindowPinned(_ pinned: Bool) {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("note") == true
        }) else { return }
        window.level = pinned ? .screenSaver : .normal
    }

    // MARK: - Dictation Suspend / Resume

    func markDictationSuspended() {
        dictationMode = nil
        isDictationSuspended = true
        viewModel?.isListeningPaused = true
    }

    func resumeDictation() async {
        guard let viewModel, let unwrappedProvider = aiProviderManager, isShowing else { return }
        isDictationSuspended = false
        viewModel.isListeningPaused = false

        if #available(macOS 26.0, *) {
            let mode = NoteDictationMode(noteViewModel: viewModel, aiProviderManager: unwrappedProvider)
            self.dictationMode = mode
            await AudioSessionController.shared.requestMode(mode)
        }
    }
}
