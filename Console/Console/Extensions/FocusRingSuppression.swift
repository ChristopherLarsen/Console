import AppKit
import OSLog
import SwiftUI

extension View {
    /// Hides the keyboard-focus ring on a SwiftUI button. Shortcuts still work.
    func suppressedFocusRing() -> some View {
        focusEffectDisabled()
            .focusable(false)
    }
}

/// Icon button that cannot take keyboard focus, so macOS never draws a focus ring.
/// Home's header uses a borderless `Button`, and that AppKit control draws the ring
/// even when `focusEffectDisabled()` is set.
struct UnfocusedIconButton: NSViewRepresentable {
    var systemName: String
    var help: String
    var identifier: String
    var isEnabled: Bool = true
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NoFocusRingButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.pressed)
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        apply(to: button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.focusRingType = .none
        button.refusesFirstResponder = true
        apply(to: button, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: 28, height: 28)
    }

    private func apply(to button: NSButton, coordinator: Coordinator) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: help)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = isEnabled ? .controlAccentColor : .disabledControlTextColor
        button.isEnabled = isEnabled
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.setAccessibilityIdentifier(identifier)
        button.cell?.focusRingType = .none
        coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func pressed() {
            action()
        }
    }
}

private final class NoFocusRingButton: NSButton {
    override var acceptsFirstResponder: Bool { false }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }

    override func drawFocusRingMask() {}

    override var focusRingMaskBounds: NSRect { .zero }
}

/// Keeps a window from handing first responder to a button on its own.
///
/// With Full Keyboard Access on (`AppleKeyboardUIMode` = 3), every button is a key
/// view. When the window becomes key, or after `makeFirstResponder(nil)`, AppKit and
/// SwiftUI pick the first key view in the loop, and that control draws a focus ring
/// the user never asked for. This observer sends that focus back to the window unless
/// the responder takes text input or the user pressed Tab to get there.
@MainActor
final class FirstResponderGuard {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Console", category: "FirstResponder")
    private static var guards: [ObjectIdentifier: FirstResponderGuard] = [:]

    private weak var window: NSWindow?
    private var observation: NSKeyValueObservation?

    private static var keyObserver: NSObjectProtocol?

    /// Guards every window, including sheets and popovers, as it becomes key.
    static func installForAllWindows() {
        guard keyObserver == nil else { return }
        NSApp.windows.forEach(install(on:))
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow { install(on: window) }
            }
        }
    }

    static func install(on window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard guards[key] == nil else { return }
        guards[key] = FirstResponderGuard(window: window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = guards.removeValue(forKey: key) }
        }
    }

    private init(window: NSWindow) {
        self.window = window
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let window, let responder = window.firstResponder else { return }
        let event = NSApp.currentEvent
        let description = Self.describe(responder)
        guard Self.shouldClear(responder, window: window, event: event) else {
            Self.logger.debug("first responder \(description, privacy: .public) kept, event \(Self.describe(event), privacy: .public)")
            return
        }
        Self.logger.debug("first responder \(description, privacy: .public) cleared, event \(Self.describe(event), privacy: .public)")
        window.makeFirstResponder(nil)
    }

    private static func shouldClear(_ responder: NSResponder, window: NSWindow, event: NSEvent?) -> Bool {
        guard let view = responder as? NSView, view !== window.contentView else { return false }
        // Text fields, editors and the terminal keep focus they were given.
        if responder is NSText || responder is NSTextInputClient { return false }
        // Tab and Shift-Tab are the user keyboard-navigating; that ring is wanted.
        if event?.type == .keyDown, event?.keyCode == 48 { return false }
        return true
    }

    private static func describe(_ responder: NSResponder) -> String {
        var parts = [String(describing: type(of: responder))]
        if let view = responder as? NSView {
            if let id = view.identifier?.rawValue { parts.append("id=\(id)") }
            if let label = view.accessibilityLabel(), !label.isEmpty { parts.append("label=\(label)") }
        }
        return parts.joined(separator: " ")
    }

    private static func describe(_ event: NSEvent?) -> String {
        guard let event else { return "none" }
        if event.type == .keyDown { return "keyDown \(event.keyCode)" }
        return "\(event.type.rawValue)"
    }
}
