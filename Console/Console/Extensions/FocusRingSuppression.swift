import AppKit
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
