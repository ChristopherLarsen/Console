import Foundation
import Observation

@MainActor
protocol CommandAuthorizing: AnyObject {
    func requestAuthorization(for command: Command) async -> Bool
}

@Observable
@MainActor
final class AuthorizationManager: CommandAuthorizing {
    static let shared = AuthorizationManager()

    private(set) var pendingCommand: Command?
    private(set) var isShowingDialog = false

    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    private var timeoutSeconds: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: "authorizationTimeoutSeconds")
        return stored > 0 ? TimeInterval(stored) : 15
    }

    var isVoiceOnly: Bool {
        UserDefaults.standard.bool(forKey: "voiceOnlyAuthorization")
    }

    private(set) var totalRequests = 0
    private(set) var totalApproved = 0
    private(set) var totalDenied = 0

    private init() {}

    // MARK: - Authorization Check

    /// Returns true when the command needs user approval before execution
    func requiresAuthorization(_ command: Command) -> Bool {
        // AppSettings uses @AppStorage, so a temporary instance reads the same UserDefaults
        let settings = AppSettings()

        if settings.requireAuthorizationForAllCommands {
            return true
        }

        if settings.requireConfirmationForDangerous && CommandValidator().needsConfirmation(command) {
            return true
        }

        return false
    }

    // MARK: - Authorization Flow

    /// Presents the authorization dialog and awaits a decision
    func requestAuthorization(for command: Command) async -> Bool {
        guard !isShowingDialog else { return false }

        totalRequests += 1
        pendingCommand = command
        isShowingDialog = true
        SoundFeedbackService.shared.play(.authorizationRequested)

        AuthorizationPanelController.shared.show(command: command)

        let authorized = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont
            self.startTimeout()
        }

        if authorized {
            totalApproved += 1
            SoundFeedbackService.shared.play(.authorizationGranted)
        } else {
            totalDenied += 1
            SoundFeedbackService.shared.play(.authorizationDenied)
        }

        return authorized
    }

    /// Called when the user approves via button or voice
    func approve() {
        resolve(authorized: true)
    }

    /// Called when the user cancels via button, voice, or timeout
    func deny() {
        resolve(authorized: false)
    }

    // MARK: - Timeout

    private func startTimeout() {
        timeoutTask?.cancel()
        let seconds = timeoutSeconds
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.deny()
        }
    }

    // MARK: - Resolution

    private func resolve(authorized: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        isShowingDialog = false
        pendingCommand = nil
        AuthorizationPanelController.shared.dismiss()
        continuation?.resume(returning: authorized)
        continuation = nil
    }
}
