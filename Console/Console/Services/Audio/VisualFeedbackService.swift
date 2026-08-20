import AppKit
import SwiftUI

enum VisualFeedbackEvent {
    case commandRecognized(String)
    case commandNotRecognized
    case commandFailure(String, String)
    case warning(String)
}

@Observable
@MainActor
final class VisualFeedbackService {
    static let shared = VisualFeedbackService()

    private var bannerWindow: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private var isCommandEnabled: Bool {
        UserDefaults.standard.bool(forKey: "showCommandPopups")
    }

    private var isErrorEnabled: Bool {
        UserDefaults.standard.bool(forKey: "showErrorPopups")
    }

    func show(_ event: VisualFeedbackEvent) {
        switch event {
        case .commandRecognized:
            guard isCommandEnabled else { return }
        case .commandNotRecognized, .commandFailure, .warning:
            guard isErrorEnabled else { return }
        }
        let (icon, text) = content(for: event)
        showBanner(icon: icon, text: text)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        bannerWindow?.orderOut(nil)
        bannerWindow = nil
    }

    // MARK: - Content Mapping

    private func content(for event: VisualFeedbackEvent) -> (String, String) {
        switch event {
        case .commandRecognized(let name):
            return ("fish.fill", name)
        case .commandNotRecognized:
            return ("exclamationmark.triangle.fill", "Command phrase not recognized")
        case .commandFailure(let name, _):
            return ("exclamationmark.triangle.fill", name)
        case .warning(let message):
            return ("exclamationmark.triangle.fill", message)
        }
    }

    // MARK: - Banner Window

    private func showBanner(icon: String, text: String) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = false

        let hostingView = NSHostingView(rootView: BannerContentView(
            icon: icon,
            text: text
        ))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)

        positionBanner(panel)
        panel.orderFront(nil)
        bannerWindow = panel
        
        let duration = max(1, min(30, UserDefaults.standard.integer(forKey: "popupDurationSeconds")))
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(Double(duration)))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            }
        }
    }

    private func positionBanner(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.maxY - panelSize.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Banner SwiftUI Content

fileprivate struct BannerContentView: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .font(.system(size: 14, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.35, green: 0.15, blue: 0.0).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    VStack(spacing: 12) {
        BannerContentView(icon: "fish.fill", text: "Open Safari")
        BannerContentView(icon: "exclamationmark.triangle.fill", text: "Command phrase not recognized")
        BannerContentView(icon: "exclamationmark.triangle.fill", text: "Open Photoshop")
        BannerContentView(icon: "exclamationmark.triangle.fill", text: "Listening services not ready. Try again.")
    }
    .padding(40)
    .background(Color.gray.opacity(0.2))
}
