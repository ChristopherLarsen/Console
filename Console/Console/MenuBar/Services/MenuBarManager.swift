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
    private var spinnerAngle: Int = 0

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

    private func bringAppToFront() {
        ConsoleWindowManager.bringToFront("main")
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
                self.spinnerAngle = (self.spinnerAngle + 30) % 360
                if let image = Self.rotatedSpinnerImage(angle: self.spinnerAngle) {
                    button.image = image
                }
            }
        }
    }

    /// The executing spinner rotates the listening glyph; build the rotated
    /// variant (cached per 30° step) that the timer actually shows.
    private static func rotatedSpinnerImage(angle: Int) -> NSImage? {
        guard let base = NSImage(named: "buddy_listening") else { return nil }
        let step = ((angle % 360) + 360) % 360
        if let cached = spinnerImageCache[step] { return cached }

        let size = NSSize(width: 18, height: 18)
        let rotated = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: CGFloat(step) * .pi / 180)
            base.draw(
                in: NSRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
            )
            return true
        }
        rotated.isTemplate = true
        rotated.size = size
        spinnerImageCache[step] = rotated
        return rotated
    }

    @MainActor
    private static var spinnerImageCache: [Int: NSImage] = [:]

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
