import AppKit
import SwiftUI

/// Puts the editable text field in its window into keyboard focus.
///
/// Sheets and alerts do not focus a `TextField` when they appear, so the
/// user would otherwise have to click the field before typing. Focus is
/// claimed again for a short moment so a late default-button assignment
/// does not leave the field unselected.
struct TextFieldAutofocus: NSViewRepresentable {
    var selectAll = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start(from: view, selectAll: selectAll)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.selectAll = selectAll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        .zero
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var selectAll = false
        private var didSelect = false
        private var timer: Timer?

        func start(from view: NSView, selectAll: Bool) {
            self.selectAll = selectAll
            stop()
            let deadline = Date().addingTimeInterval(0.4)
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak view] timer in
                MainActor.assumeIsolated {
                    guard let self, let view else {
                        timer.invalidate()
                        return
                    }
                    _ = self.focus(from: view)
                    if Date() >= deadline {
                        timer.invalidate()
                    }
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func focus(from view: NSView) -> Bool {
            guard let window = view.window,
                  let field = Self.editableTextField(in: window.contentView) else { return false }
            let editor = field.currentEditor()
            let alreadyEditing = editor.map { window.firstResponder === $0 } == true
            if !alreadyEditing {
                window.makeFirstResponder(field)
            }
            guard let editor = field.currentEditor(), window.firstResponder === editor else { return false }
            if selectAll, !didSelect {
                editor.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).length)
                didSelect = true
            }
            return true
        }

        private static func editableTextField(in view: NSView?) -> NSTextField? {
            guard let view, !view.isHidden else { return nil }
            if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
            for subview in view.subviews {
                if let found = editableTextField(in: subview) { return found }
            }
            return nil
        }
    }
}
