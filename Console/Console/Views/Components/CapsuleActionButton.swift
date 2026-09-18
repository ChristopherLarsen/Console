import SwiftUI

/// The compact capsule "pill" used for inline actions across the app: the
/// Sessions header's Open in JIRA button and merge-request badge, and the
/// Home board cards' bottom-row actions. One visual grammar everywhere —
/// control-background fill, hairline separator stroke, caption type with an
/// optional leading glyph.
struct CapsuleActionButton: View {
    let title: String
    let systemImage: String?
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

/// Cross-app hand-off button. The `Service` fixes the glyph and the default
/// label, so "Open in JIRA" and "Open in GitLab" render identically wherever
/// they appear. Pass `title` only for a dynamic label, e.g. a merge-request
/// badge's "MR !42".
struct ServiceCapsuleButton: View {
    enum Service {
        case jira
        case gitlab
        case mergeRequest

        var defaultTitle: String {
            switch self {
            case .jira: return "Open in JIRA"
            case .gitlab: return "Open in GitLab"
            case .mergeRequest: return "Open merge request"
            }
        }

        var systemImage: String {
            switch self {
            case .jira: return "text.page"
            case .gitlab, .mergeRequest: return "arrow.triangle.merge"
            }
        }
    }

    let service: Service
    let title: String?
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ service: Service,
        title: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.service = service
        self.title = title
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        CapsuleActionButton(
            title ?? service.defaultTitle,
            systemImage: service.systemImage,
            isDisabled: isDisabled,
            action: action
        )
    }
}
