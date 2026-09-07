import Foundation
import Speech

actor PermissionStatusPoller {
    
    private var pollingTask: Task<Void, Never>?
    private let pollingInterval: TimeInterval = 5.0
    
    private let microphoneChecker = MicrophonePermissionChecker()
    private let accessibilityChecker = AccessibilityPermissionChecker()
    private var lastStatuses: [PermissionType: PermissionStatus] = [:]
    
    func start(viewModel: PermissionsViewModel) {
        pollingTask?.cancel()
        
        pollingTask = Task { [weak self] in
            guard let self = self else { return }
            
            await self.checkAllStatuses(viewModel: viewModel)
            
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pollingInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self.checkAllStatuses(viewModel: viewModel)
            }
        }
    }
    
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    var isPolling: Bool {
        pollingTask != nil && !pollingTask!.isCancelled
    }
    
    private func checkAllStatuses(viewModel: PermissionsViewModel) async {
        await withTaskGroup(of: (PermissionType, PermissionStatus).self) { group in
            group.addTask { await (.microphone, self.microphoneChecker.checkStatus()) }
            group.addTask { await (.accessibility, self.accessibilityChecker.checkStatus()) }
            group.addTask {
                let status = await MainActor.run { AutomationPermissionChecker.checkStatus() }
                return (.automation, status)
            }
            group.addTask {
                let sfStatus = SFSpeechRecognizer.authorizationStatus()
                return (.speechRecognition, Self.mapSpeechAuthorizationStatus(sfStatus))
            }
            
            for await (type, status) in group {
                let previousStatus = lastStatuses[type]
                lastStatuses[type] = status
                
                if previousStatus != status {
                    await MainActor.run {
                        viewModel.updateStatus(for: type, status: status)
                    }
                }
            }
        }
    }
    
    func checkStatus(for type: PermissionType, viewModel: PermissionsViewModel) async {
        let status: PermissionStatus
        
        switch type {
        case .microphone:
            status = await microphoneChecker.checkStatus()
        case .accessibility:
            status = await accessibilityChecker.checkStatus()
        case .automation:
            status = await MainActor.run { AutomationPermissionChecker.checkStatus() }
        case .speechRecognition:
            let sfStatus = SFSpeechRecognizer.authorizationStatus()
            status = Self.mapSpeechAuthorizationStatus(sfStatus)
        }
        
        lastStatuses[type] = status
        
        await MainActor.run {
            viewModel.updateStatus(for: type, status: status)
        }
    }

    /// Maps SFSpeechRecognizer authorization to a display status without
    /// collapsing denied/restricted into notGranted (mirrors the mic mapping).
    nonisolated static func mapSpeechAuthorizationStatus(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> PermissionStatus {
        switch status {
        case .notDetermined:
            return .notGranted
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .granted
        @unknown default:
            return .notGranted
        }
    }
}
