import AppKit
import SwiftUI

/// NSViewRepresentable that renders finalized text, volatile text, and a fish cursor
/// in a single NSTextView. This eliminates the SwiftUI Text overlay approach which
/// caused layout misalignment due to different text wrapping engines.
struct NoteTextView: NSViewRepresentable {
    @Binding var noteText: String
    let volatileText: String
    let fishIsActive: Bool

    private static let accentColor = NSColor(named: "AccentColor") ?? .controlAccentColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 12)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        if let scroller = scrollView.verticalScroller {
            scroller.controlSize = .mini
        }

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView,
              let textStorage = textView.textStorage else { return }

        // Avoid re-entrancy from textDidChange
        guard !coordinator.isUpdating else { return }
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        // Save selection so we can restore it after modifying storage
        let savedSelection = textView.selectedRange()

        // --- Update finalized portion ---
        let oldFinalizedLen = coordinator.finalizedLength
        let newFinalizedLen = (noteText as NSString).length

        if noteText != coordinator.lastNoteText {
            // Finalized text changed — replace that region
            let finalizedRange = NSRange(location: 0, length: oldFinalizedLen)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.textColor
            ]
            textStorage.replaceCharacters(
                in: finalizedRange,
                with: NSAttributedString(string: noteText, attributes: attrs)
            )
            coordinator.lastNoteText = noteText
            coordinator.finalizedLength = newFinalizedLen
        }

        // --- Replace volatile suffix (everything after finalized text) ---
        let currentFinalizedLen = coordinator.finalizedLength
        let suffixRange = NSRange(location: currentFinalizedLen, length: textStorage.length - currentFinalizedLen)
        let suffix = NSMutableAttributedString()

        // Volatile text in gray
        if !volatileText.isEmpty {
            let volatileAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            suffix.append(NSAttributedString(string: volatileText, attributes: volatileAttrs))
        }

        // Fish cursor — AccentColor when active, black when idle
        let fishColor: NSColor = fishIsActive ? Self.accentColor : .black
        suffix.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let fishAttachment = Self.makeFishAttachment(color: fishColor)
        suffix.append(NSAttributedString(attachment: fishAttachment))

        textStorage.replaceCharacters(in: suffixRange, with: suffix)

        // Restore selection (clamped to finalized region)
        let clampedLoc = min(savedSelection.location, currentFinalizedLen)
        let clampedLen = min(savedSelection.length, currentFinalizedLen - clampedLoc)
        textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))

        // Auto-scroll to bottom
        textView.scrollRangeToVisible(NSRange(location: textStorage.length, length: 0))
    }

    // MARK: - Fish Attachment

    private static func makeFishAttachment(color: NSColor) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let pointSize: CGFloat = 10.4
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)

        guard let base = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return attachment }

        let size = base.size

        // Rasterize the symbol with the desired color by drawing it then
        // compositing the color on top using sourceAtop (tints opaque pixels only)
        let tinted = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }

        attachment.image = tinted
        attachment.bounds = NSRect(x: 0, y: -3, width: size.width, height: size.height)
        return attachment
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        var textView: NSTextView?
        var lastNoteText: String = ""
        var finalizedLength: Int = 0
        var isUpdating: Bool = false

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = textView,
                  let textStorage = textView.textStorage else { return }

            // User edited in the finalized region.
            // Compute new finalized length: total length minus the volatile suffix length.
            let volatileLen = (parent.volatileText as NSString).length
            let fishSuffixLen = 3 // "  " + attachment character
            let suffixLen = volatileLen + fishSuffixLen
            let newFinalizedLen = max(0, textStorage.length - suffixLen)

            let newText = (textStorage.string as NSString).substring(to: newFinalizedLen)

            isUpdating = true
            parent.noteText = newText
            lastNoteText = newText
            finalizedLength = newFinalizedLen
            isUpdating = false
        }

        // Prevent user from editing inside the volatile/fish suffix
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if affectedCharRange.location > finalizedLength {
                return false
            }
            if NSMaxRange(affectedCharRange) > finalizedLength {
                return false
            }
            return true
        }
    }
}
