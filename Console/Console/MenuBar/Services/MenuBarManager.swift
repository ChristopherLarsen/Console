import AppKit
import SwiftUI

extension Notification.Name {
    static let commandVocabularyDidChange = Notification.Name("commandVocabularyDidChange")
}

@MainActor
final class MenuBarManager: NSObject {
    static let shared = MenuBarManager()
    
    private(set) var statusItem: NSStatusItem?
    private var viewModel: MenuBarViewModel?
    private var globalKeyMonitor: Any?
    private var observationTask: Task<Void, Never>?
    private var terminationObservation: NSObjectProtocol?
    private let settings = AppSettings()
    private var previousListeningState: ListeningState = .off
    private var spinnerTimer: Timer?
    private var spinnerAngle: CGFloat = 0

    private var visualFeedbackEnabled: Bool {
        UserDefaults.standard.bool(forKey: "visualFeedbackEnabled")
    }

    private override init() {
        super.init()
    }

    func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
        updateStatusItemIcon()
    }

    func setup(viewModel: MenuBarViewModel) {
        self.viewModel = viewModel

        // Create status item if not already installed
        if statusItem == nil {
            installStatusItem()
        }

        installGlobalHotkey()
        startObservation()
        updateStatusItemIcon()
        registerTerminationHandler()
    }

    // MARK: - Click Handling

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            viewModel?.toggleListening()
        }
    }

    // MARK: - Right-Click Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let aboutItem = NSMenuItem(title: "About Console", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let showItem = NSMenuItem(title: "Show Console", action: #selector(showConsole), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let isOn = viewModel?.listeningState.isActive ?? false

        let titleLabel = NSTextField(labelWithString: "Listening")
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.sizeToFit()

        let stateLabel = NSTextField(labelWithString: isOn ? "On" : "Off")
        stateLabel.font = .menuFont(ofSize: 0)
        stateLabel.textColor = .labelColor
        stateLabel.sizeToFit()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 20))
        container.autoresizingMask = [.width]
        titleLabel.frame.origin = NSPoint(x: 14, y: (20 - titleLabel.frame.height) / 2)
        titleLabel.autoresizingMask = []
        stateLabel.autoresizingMask = [.minXMargin]
        stateLabel.frame.origin = NSPoint(x: container.frame.width - stateLabel.frame.width - 14, y: (20 - stateLabel.frame.height) / 2)
        container.addSubview(titleLabel)
        container.addSubview(stateLabel)

        let customItem = NSMenuItem()
        customItem.view = container
        menu.addItem(customItem)

        menu.addItem(.separator())

        let stopExecutionItem = NSMenuItem(
            title: "Stop Command",
            action: #selector(stopExecution),
            keyEquivalent: ""
        )
        stopExecutionItem.target = self
        stopExecutionItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop Command")
        stopExecutionItem.isEnabled = viewModel?.isExecutingCommand == true
        menu.addItem(stopExecutionItem)

        let recentCommandsItem = NSMenuItem(title: "List", action: #selector(showRecentCommands), keyEquivalent: "")
        recentCommandsItem.target = self
        recentCommandsItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")
        menu.addItem(recentCommandsItem)

        let noteItem = NSMenuItem(title: "Note", action: #selector(openNote), keyEquivalent: "")
        noteItem.target = self
        noteItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note")
        menu.addItem(noteItem)

        menu.addItem(.separator())

        let triggersItem = NSMenuItem(title: "Triggers", action: #selector(openTriggers), keyEquivalent: "")
        triggersItem.target = self
        triggersItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Triggers")
        menu.addItem(triggersItem)

        let commandsItem = NSMenuItem(title: "Commands", action: #selector(openCommands), keyEquivalent: "")
        commandsItem.target = self
        commandsItem.image = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "Commands")
        menu.addItem(commandsItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        if UserDefaults.standard.bool(forKey: "enableCommandLogging") {
            menu.addItem(.separator())
            addLoggingSection(to: menu)
        }

        #if DEBUG
        menu.addItem(.separator())

        let devModeOn = DeveloperModeManager.shared.isDeveloperModeEnabled

        let devModeTitleLabel = NSTextField(labelWithString: "Developer Mode")
        devModeTitleLabel.font = .menuFont(ofSize: 0)
        devModeTitleLabel.textColor = .labelColor
        devModeTitleLabel.sizeToFit()

        let devModeStateLabel = NSTextField(labelWithString: devModeOn ? "✓" : "")
        devModeStateLabel.font = .menuFont(ofSize: 0)
        devModeStateLabel.textColor = .secondaryLabelColor
        devModeStateLabel.sizeToFit()

        let devModeContainer = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 20))
        devModeContainer.autoresizingMask = [.width]
        devModeTitleLabel.frame.origin = NSPoint(x: 14, y: (20 - devModeTitleLabel.frame.height) / 2)
        devModeTitleLabel.autoresizingMask = []
        devModeStateLabel.autoresizingMask = [.minXMargin]
        devModeStateLabel.frame.origin = NSPoint(x: devModeContainer.frame.width - devModeStateLabel.frame.width - 14, y: (20 - devModeStateLabel.frame.height) / 2)
        devModeContainer.addSubview(devModeTitleLabel)
        devModeContainer.addSubview(devModeStateLabel)

        let devModeItem = NSMenuItem()
        devModeItem.view = devModeContainer
        menu.addItem(devModeItem)

        let devModeClickArea = ClickableMenuView(frame: devModeContainer.frame) { [weak self] in
            self?.toggleDeveloperMode()
        }
        devModeContainer.addSubview(devModeClickArea)
        devModeClickArea.frame = devModeContainer.bounds
        devModeClickArea.autoresizingMask = [.width, .height]

        #endif

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Console", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        guard let button = statusItem?.button else { return }
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func showAbout() {
        ConsoleWindowManager.bringToFront("about")
    }

    @objc private func showConsole() {
        bringAppToFront()
    }

    @objc private func showRecentCommands() {
        Task { @MainActor in
            await viewModel?.showRecentCommands()
        }
    }

    @objc private func openNote() {
        viewModel?.openNote()
    }

    @objc private func stopExecution() {
        viewModel?.stopExecution()
    }

    @objc private func openTriggers() {
        ConsoleNavigation.showTerminal(tab: .triggers)
        bringAppToFront()
    }

    @objc private func openCommands() {
        ConsoleNavigation.showTerminal(tab: .myCommands)
        bringAppToFront()
    }

    @objc private func openSettings() {
        ConsoleNavigation.showSettings()
        bringAppToFront()
    }

    private func bringAppToFront() {
        ConsoleWindowManager.bringToFront("main")
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    #if DEBUG
    @objc private func toggleDeveloperMode() {
        DeveloperModeManager.shared.toggleDeveloperMode()
    }
    #endif

    private func addLoggingSection(to menu: NSMenu) {
        if let vm = viewModel, !vm.recentLogs.isEmpty {
            let last = vm.recentLogs[0]
            let lastText = "\(last.statusEmoji) \(last.matchedCommand ?? last.strippedTranscript)"
            let lastItem = NSMenuItem(title: "Last: \(lastText)", action: nil, keyEquivalent: "")
            lastItem.isEnabled = false
            menu.addItem(lastItem)

            let recentFailures = vm.recentLogs.prefix(5).filter {
                $0.executionResult == .failed || $0.executionResult == .noMatch
            }.count
            if recentFailures > 0 {
                let failItem = NSMenuItem(title: "⚠ \(recentFailures) recent failure\(recentFailures == 1 ? "" : "s")", action: nil, keyEquivalent: "")
                failItem.isEnabled = false
                menu.addItem(failItem)
            }
        }
    }

    // MARK: - Global Hotkey

    private func installGlobalHotkey() {
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.command, .shift]),
                  event.keyCode == 49 else { return }
            Task { @MainActor [weak self] in
                self?.viewModel?.toggleListening()
            }
        }
    }

    // MARK: - Icon Updates

    private func startObservation() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            withObservationTracking {
                _ = self?.viewModel?.listeningState
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    let oldState = self?.previousListeningState ?? .off
                    let newState = self?.viewModel?.listeningState ?? .off
                    if oldState != newState {
                        self?.handleStateTransition(from: oldState, to: newState)
                        self?.previousListeningState = newState
                    } else {
                        self?.updateStatusItemIcon()
                    }
                    self?.startObservation()
                }
            }

            // Sync icon with current state after registering observation
            let currentState = self?.viewModel?.listeningState ?? .off
            if currentState != self?.previousListeningState {
                self?.previousListeningState = currentState
            }
            self?.updateStatusItemIcon()
        }
    }

    private func handleStateTransition(from oldState: ListeningState, to newState: ListeningState) {
        stopIconAnimations()
        updateStatusItemIcon()

        guard visualFeedbackEnabled else { return }

        switch newState {
        case .executing:
            startSpinnerAnimation()
        default:
            break
        }
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        let currentState = viewModel?.listeningState ?? .off
        let imageName = currentState.menuBarIcon
        guard let image = NSImage(named: imageName) else { return }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        button.image = image
        button.setAccessibilityLabel(currentState.displayLabel)
    }

    // MARK: - Icon Animations

    private func startSpinnerAnimation() {
        guard statusItem?.button != nil else { return }
        spinnerAngle = 0
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.spinnerAngle += 30
                if self.spinnerAngle >= 360 { self.spinnerAngle = 0 }

                guard let image = NSImage(named: "buddy_listening") else { return }
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
        }
    }

    private func stopIconAnimations() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    // MARK: - Lifecycle

    private func registerTerminationHandler() {
        if let existing = terminationObservation {
            NotificationCenter.default.removeObserver(existing)
        }
        terminationObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupResources()
            }
        }
    }

    private func cleanupResources() {
        stopIconAnimations()
        viewModel?.stopListening()
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let obs = terminationObservation {
            NotificationCenter.default.removeObserver(obs)
            terminationObservation = nil
        }
        observationTask?.cancel()
        observationTask = nil
    }

    func shutdown() {
        cleanupResources()
        statusItem = nil
    }
}

// MARK: - Clickable Menu View

private class ClickableMenuView: NSView {
    private let onClick: () -> Void

    init(frame: NSRect, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        onClick()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
